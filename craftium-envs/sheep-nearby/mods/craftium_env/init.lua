-- Sheep-Nearby Craftium environment
-- Spawns a flock of 50 sheep around the agent (player) when it joins the world.

voxel_radius = {
	x = minetest.settings:get("voxel_obs_rx"),
	y = minetest.settings:get("voxel_obs_ry"),
	z = minetest.settings:get("voxel_obs_rz")
}

-- Set the random seed so the flock layout is reproducible across resets
if minetest.settings:has("fixed_map_seed") then
	math.randomseed(minetest.settings:get("fixed_map_seed"))
end

-- Number of sheep to spawn around the agent. Overridable from the Python side
-- via the `num_sheep` setting (see the SheepNearby-v0 registration).
local num_sheep = tonumber(minetest.settings:get("num_sheep")) or 50

-- Radius (in nodes) of the ring the sheep are scattered within.
local spawn_radius = tonumber(minetest.settings:get("sheep_spawn_radius")) or 10

-- The agent's starting position on the superflat world (ground top is y = 1).
local agent_pos = {x = 0, y = 2.5, z = 0}
local agent_yaw = 0

-- Sheep in mobs_animal are registered per wool colour, e.g. mobs_animal:sheep_white.
local sheep_colors = {
	"white", "grey", "dark_grey", "black", "brown",
}

local function random_sheep_name()
	return "mobs_animal:sheep_" .. sheep_colors[math.random(#sheep_colors)]
end

-- Spawn a single sheep at `pos`, ignoring the per-area mob cap so the whole
-- flock always appears regardless of how crowded the area is.
local function spawn_sheep(pos)
	local sheep = mobs:add_mob(pos, {
		name = random_sheep_name(),
		ignore_count = true,
	})
	-- Some spawns can be rejected (e.g. no room); guard the returned handle.
	if sheep ~= nil and sheep ~= false then
		-- Hide the floating name tag above each sheep.
		sheep.update_tag = function() end
	end
	return sheep
end

-- Scatter `n` sheep in a disk of the given radius centred on `center`.
local function spawn_flock(center, n, radius)
	for _ = 1, n do
		local angle = math.random() * 2 * math.pi
		-- sqrt keeps the sheep uniformly distributed across the disk area.
		local dist = math.sqrt(math.random()) * radius
		local pos = {
			x = center.x + math.cos(angle) * dist,
			y = center.y,
			z = center.z + math.sin(angle) * dist,
		}
		spawn_sheep(pos)
	end
end

-- Executed when the agent joins the game
minetest.register_on_joinplayer(function(player, _last_login)
	-- Place the agent and point it at the flock.
	player:set_pos(agent_pos)
	player:set_look_horizontal(agent_yaw)

	-- Give the world a moment to load around the agent, then spawn the flock.
	minetest.after(1, function()
		spawn_flock(agent_pos, num_sheep, spawn_radius)
	end)

	-- Disable HUD elements so the observation is a clean view of the flock.
	player:hud_set_flags({
		hotbar = false,
		crosshair = false,
		healthbar = false,
	})
end)

minetest.register_globalstep(function(_dtime)
	-- Keep it midday so the flock is well lit.
	minetest.set_timeofday(0.5)

	local player = minetest.get_connected_players()[1]
	if player == nil then
		return nil
	end

	-- Provide voxel observations when the Python side requests them.
	if minetest.settings:get("voxel_obs") then
		local player_pos = player:get_pos()
		local voxel_data, voxel_light_data, voxel_param2_data =
			voxel_api:get_voxel_data(player_pos, voxel_radius)
		set_voxel_data(voxel_data)
		set_voxel_light_data(voxel_light_data)
		set_voxel_param2_data(voxel_param2_data)
	end
end)

minetest.register_on_dieplayer(function(_player, _reason)
	-- End the episode if the agent dies.
	set_termination()
end)
