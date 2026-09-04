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
-- Keep the player's spawn at least this many blocks from any water (used only
-- for choosing the spawn location; there is no in-episode steering any more).
local WATER_AVOID_RADIUS = _setting_number("water_avoid_radius", 12)

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

-- Foliage / tree material we must not treat as ground (no spawning on leaves).
local function _is_leaflike(name)
	return minetest.get_item_group(name, "leaves") > 0
	    or minetest.get_item_group(name, "tree") > 0
	    or minetest.get_item_group(name, "sapling") > 0
end

-- No solid node within `up` blocks above -> open to the sky (not a cave/tunnel).
local function _open_sky(x, y, z, up)
	for dy = 1, up do
		local n = minetest.get_node_or_nil({x = x, y = y + dy, z = z})
		if n ~= nil and minetest.registered_nodes[n.name]
		   and minetest.registered_nodes[n.name].walkable then
			return false
		end
	end
	return true
end

-- Top solid, non-liquid, non-leaf surface height at column (x,z) near y, or nil.
local function _surface_y(x, y, z)
	for yy = y + 6, y - 24, -1 do
		local n = minetest.get_node_or_nil({x = x, y = yy, z = z})
		if n ~= nil then
			local def = minetest.registered_nodes[n.name]
			if def and def.walkable and not _is_liquid(n.name) and not _is_leaflike(n.name) then
				return yy
			end
		end
	end
	return nil
end

-- Is the ground around (x,z) roughly level (no cliff edge / pit rim)? Every
-- neighbour column within `radius` must have ground no more than `max_drop`
-- below (and not missing) -> not on the lip of a cliff or a hole.
local function _flat_around(x, y, z, radius, max_drop)
	for dx = -radius, radius do
		for dz = -radius, radius do
			if dx ~= 0 or dz ~= 0 then
				local sy = _surface_y(x + dx, y, z + dz)
				if sy == nil or (y - sy) > max_drop or (sy - y) > max_drop then
					return false
				end
			end
		end
	end
	return true
end

-- No solid nodes at body height within `radius` -> not wedged inside trees/walls.
local function _clear_around(x, y, z, radius)
	for dx = -radius, radius do
		for dz = -radius, radius do
			for dy = 1, 2 do
				local n = minetest.get_node_or_nil({x = x + dx, y = y + dy, z = z + dz})
				if n ~= nil and minetest.registered_nodes[n.name]
				   and minetest.registered_nodes[n.name].walkable then
					return false
				end
			end
		end
	end
	return true
end

-- Is the surface node at (x,y,z) a good place to stand? `strict` additionally
-- requires open sky (not a cave), flat surroundings (not a cliff edge / pit) and
-- clear body space (not inside trees/walls).
local function _good_surface(x, y, z, avoid_radius, strict)
	local n = minetest.get_node_or_nil({x = x, y = y, z = z})
	if n == nil or not _is_solid(n.name) or _is_leaflike(n.name) then return false end
	local a1 = minetest.get_node_or_nil({x = x, y = y + 1, z = z})
	local a2 = minetest.get_node_or_nil({x = x, y = y + 2, z = z})
	if a1 == nil or a2 == nil then return false end
	if minetest.registered_nodes[a1.name].walkable or _is_liquid(a1.name) or _is_liquid(a2.name) then
		return false
	end
	if avoid_radius > 0 and has_water_near(x, y, z, avoid_radius) then return false end
	if strict then
		if not _open_sky(x, y, z, 8) then return false end        -- not a cave
		if not _clear_around(x, y, z, 1) then return false end     -- not in trees/walls
		if not _flat_around(x, y, z, 2, 2) then return false end   -- not a cliff edge / pit
	end
	return true
end

-- Find a good standing position near `pos`. Two passes: first STRICT (open sky,
-- flat, clear of trees, dry) so the player never spawns in a cave, on a cliff
-- edge, inside trees, or by water; then a RELAXED pass (dry, real ground) as a
-- fallback so spawning never fails. Returns standing pos (surface+1) or nil.
local function find_dry_ground(pos, avoid_radius)
	avoid_radius = avoid_radius or 0
	local cx, cy, cz = math.floor(pos.x + 0.5), math.floor(pos.y + 0.5), math.floor(pos.z + 0.5)
	local map_ready = false
	for _, strict in ipairs({true, false}) do
		for r = 0, 40, 2 do
			for dx = -r, r, 2 do
				for dz = -r, r, 2 do
					if math.abs(dx) == r or math.abs(dz) == r or r == 0 then
						local x, z = cx + dx, cz + dz
						for y = cy + 12, cy - 16, -1 do
							local n = minetest.get_node_or_nil({x = x, y = y, z = z})
							if n ~= nil then
								map_ready = true
								if _good_surface(x, y, z, avoid_radius, strict) then
									return {x = x, y = y + 1, z = z}, map_ready
								end
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

-- NOTE: the player is NOT steered away from walls, trees or cliff edges - only
-- water is guarded against (see the globalstep below). Any level where the
-- player walks into a wall/tree can simply be discarded during dataset cleanup.

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

	-- Keep the player out of the water for the whole episode - and ONLY the water.
	-- No velocity is ever added or cancelled here. Each frame we simply remember
	-- the last dry-land position; the instant a step lands the player on/into
	-- water we set the position back to that anchor. The player is held at the
	-- water's edge (position-only, one step back). Walls, trees and cliff edges
	-- are left completely alone - normal Craftium movement is untouched.
	if KEEP_ON_LAND then
		if player_over_water(player) then
			if last_ground_pos ~= nil then
				pcall(function() player:set_pos(last_ground_pos) end)
			end
		else
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
