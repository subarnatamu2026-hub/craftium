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
