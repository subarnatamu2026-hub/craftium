-- Sheep-Info (Minetest Game) Craftium environment
--
-- Same idea as sheep-info-vl, but on Minetest Game + Mobs Redo (mobs_animal),
-- which renders under software GL / WSL where VoxeLibre's client does not.
-- Spawns a flock of sheep around the agent and, every step, writes the full
-- state (incl. AI intent) of every nearby sheep to sheep_obs.json in the world
-- directory. The Python side reads that file after each env.step().

voxel_radius = {
	x = minetest.settings:get("voxel_obs_rx"),
	y = minetest.settings:get("voxel_obs_ry"),
	z = minetest.settings:get("voxel_obs_rz")
}

if minetest.settings:has("fixed_map_seed") then
	math.randomseed(minetest.settings:get("fixed_map_seed"))
end

local num_sheep     = tonumber(minetest.settings:get("num_sheep")) or 50
local spawn_radius  = tonumber(minetest.settings:get("sheep_spawn_radius")) or 10
local report_radius = tonumber(minetest.settings:get("sheep_report_radius")) or 40
-- Hold every sheep pinned in place for this many steps after spawn, then let
-- them move. Lets you establish an identical, static start before the dynamics
-- take over. 0 = no freeze.
local freeze_steps  = tonumber(minetest.settings:get("sheep_freeze_steps")) or 0

-- mobs_animal registers sheep per wool colour, e.g. mobs_animal:sheep_white.
local SHEEP_COLORS = { "white", "grey", "dark_grey", "black", "brown" }

local agent_pos = {x = 0, y = 2.5, z = 0}
local obs_path = minetest.get_worldpath() .. DIR_DELIM .. "sheep_obs.json"

local step_count = 0
local next_id = 0
local frozen_until = -1   -- hold sheep in place while step_count <= this

-- Deterministic-grid spawn makes the flock start in the EXACT same layout on
-- every run (positions and colours computed from the index, not math.random),
-- so two runs are provably identical at step 0. Toggle with the setting
-- `sheep_grid_spawn`.
local grid_spawn = minetest.settings:get_bool("sheep_grid_spawn")

local function random_sheep_name()
	return "mobs_animal:sheep_" .. SHEEP_COLORS[math.random(#SHEEP_COLORS)]
end

-- Deterministic colour for grid spawn (no RNG).
local function sheep_name_for(i)
	return "mobs_animal:sheep_" .. SHEEP_COLORS[(i % #SHEEP_COLORS) + 1]
end

-- Spawn one sheep at pos and tag it with a stable id for cross-step tracking.
-- `name` is optional; when omitted a random colour is used.
local function spawn_one(pos, name)
	local obj = mobs:add_mob(pos, {
		name = name or random_sheep_name(),
		ignore_count = true,
	})
	if obj ~= nil and obj ~= false then
		obj.update_tag = function() end
		if obj._flock_id == nil then
			obj._flock_id = next_id
			next_id = next_id + 1
		end
		-- Remember the spawn spot so we can pin the sheep there during freeze.
		obj._home = {x = pos.x, y = pos.y, z = pos.z}
	end
	return obj
end

-- Random scatter in a disk (default).
local function spawn_flock_random(center, n, radius)
	for _ = 1, n do
		local angle = math.random() * 2 * math.pi
		local dist = math.sqrt(math.random()) * radius
		spawn_one({
			x = center.x + math.cos(angle) * dist,
			y = center.y + 1,
			z = center.z + math.sin(angle) * dist,
		})
	end
end

-- Deterministic square grid centred on `center` (identical on every run).
local function spawn_flock_grid(center, n, spacing)
	spacing = spacing or 1.5
	local cols = math.ceil(math.sqrt(n))
	local half = (cols - 1) * spacing / 2
	for i = 0, n - 1 do
		local c = i % cols
		local r = math.floor(i / cols)
		spawn_one({
			x = center.x - half + c * spacing,
			y = center.y + 1,
			z = center.z - half + r * spacing,
		}, sheep_name_for(i))
	end
end

local function spawn_flock(center, n, radius)
	if grid_spawn then
		spawn_flock_grid(center, n)
	else
		spawn_flock_random(center, n, radius)
	end
end

-- Safely read an ObjectRef's position (following/attack targets may be stale).
local function obj_pos(o)
	if o == nil then
		return nil
	end
	local ok, p = pcall(function() return o:get_pos() end)
	if ok and p then
		return {x = p.x, y = p.y, z = p.z}
	end
	return nil
end

-- Is this luaentity a sheep? (matches any mobs_animal:sheep_<colour>)
local function is_sheep(le)
	return le ~= nil and type(le.name) == "string" and le.name:find("sheep") ~= nil
end

local function collect_sheep(center)
	local sheep = {}
	for _, obj in ipairs(minetest.get_objects_inside_radius(center, report_radius)) do
		local le = obj:get_luaentity()
		if is_sheep(le) then
			local p = obj:get_pos()
			local v = obj:get_velocity()
			local dx, dy, dz = p.x - center.x, p.y - center.y, p.z - center.z
			local follow_pos = obj_pos(le.following)
			local attack_pos = obj_pos(le.attack)
			sheep[#sheep + 1] = {
				id = le._flock_id,
				name = le.name,
				hp = le.health or obj:get_hp(),
				pos = {x = p.x, y = p.y, z = p.z},
				vel = {x = v.x, y = v.y, z = v.z},
				yaw = obj:get_yaw(),
				dist = math.sqrt(dx * dx + dy * dy + dz * dz),
				intent = {
					state = le.state,                -- "stand"/"walk"/"runaway"/"eat"/...
					eating = le.state == "eat",
					fleeing = le.state == "runaway",
					following = follow_pos ~= nil,
					follow_target = follow_pos,
					attacking = attack_pos ~= nil,
					attack_target = attack_pos,
					sheared = le.gotten == true,     -- true = no wool right now
				},
			}
		end
	end
	return sheep
end

-- Pin every sheep at its spawn spot (velocity 0) — used during the freeze window.
local function hold_flock(center)
	for _, o in ipairs(minetest.get_objects_inside_radius(center, report_radius)) do
		local le = o:get_luaentity()
		if is_sheep(le) and le._home then
			o:set_pos(le._home)
			o:set_velocity({x = 0, y = 0, z = 0})
		end
	end
end

local function write_obs(player)
	local pos = player:get_pos()
	local data = {
		step = step_count,
		time_of_day = minetest.get_timeofday(),
		player = {
			pos = {x = pos.x, y = pos.y, z = pos.z},
			yaw = player:get_look_horizontal(),
			pitch = player:get_look_vertical(),
		},
		sheep = collect_sheep(pos),
	}
	data.num_sheep = #data.sheep
	minetest.safe_file_write(obs_path, minetest.write_json(data))
end

minetest.register_on_joinplayer(function(player, _last_login)
	minetest.set_timeofday(0.5)
	player:set_pos(agent_pos)

	minetest.after(1, function()
		if player and player:is_player() then
			spawn_flock(player:get_pos(), num_sheep, spawn_radius)
			-- Begin the freeze window (if any) now that the flock exists.
			frozen_until = step_count + freeze_steps
		end
	end)

	player:hud_set_flags({
		crosshair = false,
		basic_debug = false,
	})
end)

minetest.register_globalstep(function(_dtime)
	minetest.set_timeofday(0.5)

	local player = minetest.get_connected_players()[1]
	if player == nil then
		return nil
	end

	step_count = step_count + 1

	if minetest.settings:get("voxel_obs") then
		local player_pos = player:get_pos()
		local voxel_data, voxel_light_data, voxel_param2_data =
			voxel_api:get_voxel_data(player_pos, voxel_radius)
		set_voxel_data(voxel_data)
		set_voxel_light_data(voxel_light_data)
		set_voxel_param2_data(voxel_param2_data)
	end

	-- Hold the flock static during the freeze window, then let it move.
	if freeze_steps > 0 and frozen_until >= 0 and step_count <= frozen_until then
		hold_flock(player:get_pos())
	end

	write_obs(player)
end)

minetest.register_on_dieplayer(function(_player, _reason)
	set_termination()
end)
