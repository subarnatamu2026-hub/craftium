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
-- If enabled, keep the player on dry land for the WHOLE episode. Instead of a
-- hard snap-back at the water's edge (which jerks the camera), the player is now
-- steered smoothly away from water it is approaching (see the globalstep below).
local KEEP_ON_LAND = _setting_true("keep_player_on_land")
local player_relocated = false
local last_ground_pos = nil

local function _setting_number(name, default)
	local v = tonumber(minetest.settings:get(name))
	if v == nil then return default end
	return v
end
-- Keep the player at least this many blocks from any water (used both for the
-- spawn location and the in-episode steering look-ahead).
local WATER_AVOID_RADIUS = _setting_number("water_avoid_radius", 12)
local WATER_LOOKAHEAD    = _setting_number("water_lookahead", 12)
local WATER_PUSH         = _setting_number("water_push_strength", 2.5)

local function _is_liquid(name)
	local def = minetest.registered_nodes[name]
	return def ~= nil and def.liquidtype ~= nil and def.liquidtype ~= "none"
end

local function _is_solid(name)
	local def = minetest.registered_nodes[name]
	return def ~= nil and def.walkable == true and not _is_liquid(name)
end

-- Is there any liquid within `radius` (horizontal) of column (x,z), near the
-- surface level `y`? Used to keep the player away from shorelines.
local function has_water_near(x, y, z, radius)
	for dx = -radius, radius, 2 do
		for dz = -radius, radius, 2 do
			for dy = 2, -4, -1 do
				local n = minetest.get_node_or_nil({x = x + dx, y = y + dy, z = z + dz})
				if n ~= nil and _is_liquid(n.name) then
					return true
				end
			end
		end
	end
	return false
end

-- Find a dry ground surface near `pos`. Scans expanding rings and returns a
-- standing position (surface + 1) whose surface node is solid and the two nodes
-- above are air/non-liquid. When `avoid_radius` > 0 the spot must also have NO
-- water within that radius (so the player spawns away from shorelines). Returns
-- nil if none found or the map isn't ready.
local function find_dry_ground(pos, avoid_radius)
	avoid_radius = avoid_radius or 0
	local cx, cy, cz = math.floor(pos.x + 0.5), math.floor(pos.y + 0.5), math.floor(pos.z + 0.5)
	local map_ready = false
	for r = 0, 40, 2 do
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
							   and not _is_liquid(above2.name)
							   and (avoid_radius <= 0 or not has_water_near(x, y, z, avoid_radius)) then
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

-- Look around the player for water within WATER_LOOKAHEAD and return a unit
-- direction pointing AWAY from it (plus the distance to the nearest water), or
-- nil if there's no water nearby. Sampled along 12 rays so the push points away
-- from whichever shore is closest.
local _WATER_DIRS = {}
for i = 0, 11 do
	local a = i * (math.pi / 6)
	_WATER_DIRS[#_WATER_DIRS + 1] = {math.cos(a), math.sin(a)}
end
local function water_repel(pos)
	local ax, az, nearest = 0, 0, nil
	for _, d in ipairs(_WATER_DIRS) do
		local cx, cz = d[1], d[2]
		for r = 2, WATER_LOOKAHEAD, 2 do
			local x, z = pos.x + cx * r, pos.z + cz * r
			local hit = false
			for dy = 1, -3, -1 do
				local n = minetest.get_node_or_nil({x = x, y = pos.y + dy, z = z})
				if n ~= nil and _is_liquid(n.name) then hit = true break end
			end
			if hit then
				local w = (WATER_LOOKAHEAD - r + 1)   -- closer water pushes harder
				ax = ax - cx * w
				az = az - cz * w
				if nearest == nil or r < nearest then nearest = r end
				break   -- only the nearest water along this ray
			end
		end
	end
	if nearest == nil then return nil end
	local m = math.sqrt(ax * ax + az * az)
	if m < 1e-6 then return nil end
	return ax / m, az / m, nearest
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
		-- Apply the HUD flags immediately at join too (not just from the first
		-- globalstep), so the very first captured frame already hides the hotbar
		-- and the first-person wielded hand/item.
		pcall(player.hud_set_flags, player, {
			crosshair = false, basic_debug = false, chat = false,
			hotbar = false, wielditem = false, healthbar = false,
			breathbar = false, minimap = false, minimap_radar = false,
		})
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
			local on_water = _is_liquid(feet.name) or _is_liquid(here.name)
			local near_water = has_water_near(math.floor(ppos.x + 0.5),
				math.floor(ppos.y + 0.5), math.floor(ppos.z + 0.5), WATER_AVOID_RADIUS)
			if on_water or near_water then
				-- Prefer a spot with NO water within WATER_AVOID_RADIUS; if none
				-- exists nearby, fall back to any dry spot so spawn never fails.
				local dry, ready = find_dry_ground(ppos, WATER_AVOID_RADIUS)
				if dry == nil and ready then
					dry, ready = find_dry_ground(ppos, 0)
				end
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
				player_relocated = true  -- already on land, away from water
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
			-- Failsafe only (should be rare now): the player is actually on water,
			-- ease it back to the last safe ground and kill horizontal velocity.
			if last_ground_pos ~= nil then
				pcall(function()
					player:set_pos(last_ground_pos)
					local v = player:get_velocity()
					if v then player:add_velocity({x = -v.x, y = math.min(0, -v.y), z = -v.z}) end
				end)
			end
		else
			-- On safe land: remember it as the anchor, AND steer smoothly away from
			-- any water within WATER_LOOKAHEAD by cancelling the velocity heading
			-- toward it and adding a gentle outward push (no snap = no camera jerk).
			last_ground_pos = player:get_pos()
			local ax, az, nearest = water_repel(player:get_pos())
			if ax ~= nil then
				pcall(function()
					local v = player:get_velocity() or {x = 0, y = 0, z = 0}
					local tx, tz = -ax, -az                 -- toward-water direction
					local comp = v.x * tx + v.z * tz        -- speed heading into water
					local imp = {x = 0, y = 0, z = 0}
					if comp > 0 then                        -- cancel the into-water part
						imp.x = imp.x - comp * tx
						imp.z = imp.z - comp * tz
					end
					local strength = WATER_PUSH * (1 - (nearest - 1) / WATER_LOOKAHEAD)
					if strength < 0 then strength = 0 end
					imp.x = imp.x + ax * strength
					imp.z = imp.z + az * strength
					player:add_velocity(imp)
				end)
			end
			-- (kept for structure; the original branch also updated last_ground_pos)
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
