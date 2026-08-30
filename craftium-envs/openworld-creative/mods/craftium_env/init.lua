if minetest.settings:has("fixed_map_seed") then
	math.randomseed(minetest.settings:get("fixed_map_seed"))
	minetest.set_mapgen_setting("seed", minetest.settings:get("fixed_map_seed"), true)
	minetest.log("action", "Overriding World seed = " .. minetest.get_mapgen_setting("seed"))
end

voxel_radius = {
	x = minetest.settings:get("voxel_obs_rx"),
	y = minetest.settings:get("voxel_obs_ry"),
	z = minetest.settings:get("voxel_obs_rz")
}

local init_inv_string = minetest.settings:get("starting_inventory_creative")
-- Parse into a Lua table
init_inv = {}
if init_inv_string then
    for item in string.gmatch(init_inv_string, '([^,]+)') do
        table.insert(init_inv, item)
    end
end

timeofday = tonumber(minetest.settings:get("world_start_time"))/24000

-- Whether to hide all HUD elements and the first-person wielded hand/item from
-- the RGB observation (purely visual; does not affect actions/observations).
local function _setting_true(name)
	local v = minetest.settings:get(name)
	if v == nil then return false end
	v = string.lower(tostring(v))
	return v == "true" or v == "1" or v == "yes"
end
local CLEAN_RGB = _setting_true("clean_rgb")

-- If enabled, relocate the player onto solid, dry ground at episode start so the
-- agent does not spawn in a water body (and then jump in place).
local SPAWN_ON_LAND = _setting_true("spawn_on_land")
-- If enabled, keep the player on dry land for the WHOLE episode: any step onto
-- or into water is undone by snapping back to the last solid-ground position.
local KEEP_ON_LAND = _setting_true("keep_player_on_land")
local player_relocated = false
local last_ground_pos = nil

local function _is_liquid(name)
	local def = minetest.registered_nodes[name]
	return def ~= nil and def.liquidtype ~= nil and def.liquidtype ~= "none"
end

local function _is_solid(name)
	local def = minetest.registered_nodes[name]
	return def ~= nil and def.walkable == true and not _is_liquid(name)
end

-- Find a dry ground surface near `pos`. Scans expanding rings and returns a
-- standing position (surface + 1) whose surface node is solid and the two nodes
-- above are air/non-liquid; returns nil if none found or the map isn't ready.
local function find_dry_ground(pos)
	local cx, cy, cz = math.floor(pos.x + 0.5), math.floor(pos.y + 0.5), math.floor(pos.z + 0.5)
	local map_ready = false
	for r = 0, 24, 2 do
		for dx = -r, r, 2 do
			for dz = -r, r, 2 do
				-- only the ring at radius r
				if math.abs(dx) == r or math.abs(dz) == r or r == 0 then
					local x, z = cx + dx, cz + dz
					for y = cy + 12, cy - 16, -1 do
						local n = minetest.get_node_or_nil({x = x, y = y, z = z})
						if n ~= nil then
							map_ready = true
							local above = minetest.get_node_or_nil({x = x, y = y + 1, z = z})
							local above2 = minetest.get_node_or_nil({x = x, y = y + 2, z = z})
							if _is_solid(n.name) and above ~= nil and above2 ~= nil
							   and not minetest.registered_nodes[above.name].walkable
							   and not _is_liquid(above.name)
							   and not _is_liquid(above2.name) then
								return {x = x, y = y + 1, z = z}, map_ready
							end
						end
					end
				end
			end
		end
	end
	return nil, map_ready
end

-- True if the player is standing on/inside water (feet node or the support
-- node just below is a liquid). Jumping over land is NOT flagged (support is air
-- but not liquid), so normal navigation is unaffected.
local function player_over_water(player)
	local p = player:get_pos()
	local at = minetest.get_node_or_nil({x = p.x, y = p.y + 0.1, z = p.z})
	local below = minetest.get_node_or_nil({x = p.x, y = p.y - 0.5, z = p.z})
	if at ~= nil and _is_liquid(at.name) then return true end
	if below ~= nil and _is_liquid(below.name) then return true end
	return false
end

-- executed when the player joins the game
minetest.register_on_joinplayer(function(player, _last_login)

	-- set the player's view to the next yaw
	player:set_look_vertical(math.rad(math.random(-20, 20)))
	player:set_look_horizontal(math.rad(math.random(0, 360)))

	-- setup initial inventory
	local inv = player:get_inventory()
	for i=1, #init_inv do
		inv:add_item("main", init_inv[i])
	end

	minetest.set_timeofday(timeofday)

	-- Hide VoxeLibre's mod-drawn HUD bars (health/hunger/armor/xp) when a
	-- clean RGB observation is requested. Guarded so it is a no-op if the mods
	-- are absent.
	if CLEAN_RGB then
		if minetest.global_exists("hb") and hb.hide_hudbar then
			for _, bar in ipairs({"health", "breath", "armor", "hunger",
			                      "exhaustion", "saturation", "absorption"}) do
				pcall(hb.hide_hudbar, player, bar)
			end
		end
		if minetest.global_exists("mcl_experience") and mcl_experience.remove_hud then
			pcall(mcl_experience.remove_hud, player)
		end
	end

end)

-- turn on the termination flag if the agent dies
minetest.register_on_dieplayer(function(ObjectRef, reason)
	set_termination()
end)

-- make game's time match with learning timesteps
minetest.register_globalstep(function(dtime)

	local player = minetest.get_connected_players()[1]

	-- if the player is not connected end here
	if player == nil then
		return nil
	end

	-- Relocate the player onto dry ground once, before data collection, if the
	-- spawn is on/over water. Runs as soon as the surrounding map is loaded.
	if SPAWN_ON_LAND and not player_relocated then
		local ppos = player:get_pos()
		local feet = minetest.get_node_or_nil({x = ppos.x, y = ppos.y - 0.5, z = ppos.z})
		local here = minetest.get_node_or_nil({x = ppos.x, y = ppos.y + 0.1, z = ppos.z})
		if feet ~= nil and here ~= nil then
			-- Map is loaded around the player; decide if relocation is needed.
			if _is_liquid(feet.name) or _is_liquid(here.name) then
				local dry, ready = find_dry_ground(ppos)
				if dry ~= nil then
					player:set_pos(dry)
					pcall(function() player:add_velocity(vector.multiply(player:get_velocity() or {x=0,y=0,z=0}, -1)) end)
					player_relocated = true
					last_ground_pos = dry
				elseif ready then
					-- Map loaded but no dry ground within range; give up trying.
					player_relocated = true
				end
			else
				player_relocated = true  -- already on land
				last_ground_pos = ppos
			end
		end
	end

	-- Keep the player on dry land for the whole episode. Each step we remember
	-- the immediately-previous non-water position; the instant a step would put
	-- the player on/into water we restore that position and cancel velocity. The
	-- anchor is at most one small step away, so the player is simply *held at the
	-- water's edge* (an invisible wall) rather than teleported backwards - it
	-- never enters the water. Normal walking/jumping on land is untouched.
	if KEEP_ON_LAND then
		if player_over_water(player) then
			if last_ground_pos ~= nil then
					local cur = player:get_pos()
					player:set_pos(last_ground_pos)
					pcall(function()
						local v = player:get_velocity()
						if v then player:add_velocity({x = -v.x, y = math.min(0, -v.y), z = -v.z}) end
						-- Nudge the player away from the water so it drifts back
						-- onto land instead of pressing at the shoreline.
						local dx = last_ground_pos.x - cur.x
						local dz = last_ground_pos.z - cur.z
						local d = math.sqrt(dx * dx + dz * dz)
						if d > 0.01 then
							local push = 3.0
							player:add_velocity({x = (dx / d) * push, y = 0, z = (dz / d) * push})
						end
					end)
				end
		else
			-- not over water: this position is safe, keep it as the anchor
			last_ground_pos = player:get_pos()
		end
	end

	-- disable HUD elements -- normal HUD todo: check moving up in script
	if CLEAN_RGB then
		-- Also hide the hotbar and, crucially, the first-person wielded
		-- hand/item (`wielditem`), for a clean RGB observation.
		player:hud_set_flags({
			crosshair = false,
			basic_debug = false,
			chat = false,
			hotbar = false,
			wielditem = false,
			healthbar = false,
			breathbar = false,
			minimap = false,
			minimap_radar = false,
		})
	else
		player:hud_set_flags({
			crosshair = false,
			basic_debug = false,
			chat = false,
		})
	end

	-- if the player is connected:
	local player_pos = player:get_pos()
	if minetest.settings:get("voxel_obs") then
		get_voxel_data_cpp(player_pos, voxel_radius)
	end
end)

-- Optional dynamic-agent (mobs/animals) spawning + per-frame logging.
-- Only active when `dynamic_agents_enable` is set; see dynamic_agents.lua.
dofile(minetest.get_modpath("craftium_env") .. "/dynamic_agents.lua")
