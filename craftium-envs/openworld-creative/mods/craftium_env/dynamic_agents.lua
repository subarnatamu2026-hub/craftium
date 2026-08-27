-- dynamic_agents.lua
--
-- Craftium extension that spawns a fixed set of "dynamic agents" (mobs/animals)
-- around the player and logs their per-frame state to a file so that the PERSIST
-- data pipeline can save it as an extra `data_dynamic` dataset file.
--
-- For now the only dynamic agent type is the VoxeLibre sheep ("mobs_mc:sheep").
-- The log is written to <worldpath>/data_dynamic.jsonl, one JSON object per
-- server step (globalstep). Each record contains the current frame index, the
-- player position (used by the pipeline to align records with the collected
-- frames) and the list of tracked agents with their pose/velocity/health.
--
-- The whole feature is opt-in and guarded by the `dynamic_agents_enable`
-- setting, so normal Craftium/PERSIST runs are unaffected.

local function setting_true(name, default)
	local v = minetest.settings:get(name)
	if v == nil then
		return default
	end
	v = string.lower(tostring(v))
	return v == "true" or v == "1" or v == "yes"
end

local function setting_number(name, default)
	local v = tonumber(minetest.settings:get(name))
	if v == nil then
		return default
	end
	return v
end

-- Feature disabled: do nothing (keeps default Craftium behaviour intact).
if not setting_true("dynamic_agents_enable", false) then
	return
end

-- ---------------------------------------------------------------------------
-- Configuration (all overridable through minetest.conf / minetest_conf)
-- ---------------------------------------------------------------------------
local AGENT_NAME    = minetest.settings:get("dynamic_agents_entity") or "mobs_mc:sheep"
local NUM_AGENTS    = math.floor(setting_number("dynamic_agents_count", 10))
local MIN_RADIUS    = setting_number("dynamic_agents_min_radius", 4.0)
local MAX_RADIUS    = setting_number("dynamic_agents_max_radius", 10.0)
-- Keep the population topped up if mobs die/despawn during the episode.
local MAINTAIN      = setting_true("dynamic_agents_maintain", true)

local LOG_PATH = minetest.get_worldpath() .. "/data_dynamic.jsonl"

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local frame = 0                -- server step counter (matches Python receives)
local spawned = false          -- whether the initial population has been spawned
local tracked = {}             -- slot index -> ObjectRef
local log_file = nil
local agent_meta = {}          -- slot index -> static visual metadata (mesh, textures, ...)
local meta_dirty = false       -- whether new metadata needs to be flushed to the log

local function open_log()
	-- Truncate any stale file from a previous run of the same world dir.
	log_file = io.open(LOG_PATH, "w")
	if log_file == nil then
		minetest.log("error", "[dynamic_agents] could not open log file: " .. LOG_PATH)
	end
end

-- Find a walkable surface near `pos`, scanning downwards. Returns a spawn
-- position slightly above the ground, or nil if the map is not loaded yet.
local function find_ground(pos)
	local map_ready = false
	for dy = 8, -10, -1 do
		local p = {x = pos.x, y = pos.y + dy, z = pos.z}
		local node = minetest.get_node_or_nil(p)
		if node ~= nil then
			map_ready = true
			local def = minetest.registered_nodes[node.name]
			if def and def.walkable then
				return {x = pos.x, y = p.y + 1.5, z = pos.z}, map_ready
			end
		end
	end
	return nil, map_ready
end

-- Spawn a single agent for the given slot near the player.
local function spawn_agent(slot, player_pos)
	local angle = math.random() * 2 * math.pi
	local radius = MIN_RADIUS + math.random() * (MAX_RADIUS - MIN_RADIUS)
	local target = {
		x = player_pos.x + radius * math.cos(angle),
		y = player_pos.y,
		z = player_pos.z + radius * math.sin(angle),
	}
	local ground, map_ready = find_ground(target)
	if ground == nil then
		return false, map_ready
	end

	local obj = minetest.add_entity(ground, AGENT_NAME)
	if obj == nil then
		return false, map_ready
	end

	-- Tag the entity so it survives despawn logic where the mob framework
	-- honours these fields, and remember its slot.
	local lua = obj:get_luaentity()
	if lua then
		lua.persistent = true
		lua.despawn_immediately = false
		lua._dyn_slot = slot
	end
	tracked[slot] = obj
	return true, map_ready
end

-- Spawn the whole population, retrying on later frames until the map is ready.
local function ensure_population(player_pos)
	local map_ready = true
	for slot = 1, NUM_AGENTS do
		local obj = tracked[slot]
		local alive = obj ~= nil and obj:get_luaentity() ~= nil
		if not alive and (MAINTAIN or not spawned) then
			local ok, ready = spawn_agent(slot, player_pos)
			map_ready = map_ready and ready
		end
	end
	return map_ready
end

-- Read the current state of a tracked agent, or nil if it is gone.
local function read_agent(slot)
	local obj = tracked[slot]
	if obj == nil then
		return nil
	end
	local lua = obj:get_luaentity()
	if lua == nil then
		return nil
	end

	local pos = obj:get_pos()
	if pos == nil then
		return nil
	end

	local vel = {x = 0, y = 0, z = 0}
	local ok_v, v = pcall(function() return obj:get_velocity() end)
	if ok_v and v then vel = v end

	local yaw = 0
	local ok_y, y = pcall(function() return obj:get_yaw() end)
	if ok_y and y then yaw = y end

	local hp = 0
	if lua.health ~= nil then
		hp = lua.health
	else
		local ok_h, h = pcall(function() return obj:get_hp() end)
		if ok_h and h then hp = h end
	end

	-- Full rotation (radians): x = pitch, y = yaw, z = roll.
	local rot = {x = 0, y = yaw, z = 0}
	local ok_r, r = pcall(function() return obj:get_rotation() end)
	if ok_r and r then rot = r end

	-- Static object properties: collision box + mesh/visual info.
	local props = nil
	local ok_p, p = pcall(function() return obj:get_properties() end)
	if ok_p and p then props = p end

	-- Collision box relative to pos, in Minetest axes {x1,y1,z1,x2,y2,z2}.
	local cbox = {0, 0, 0, 0, 0, 0}
	if props and props.collisionbox then cbox = props.collisionbox end

	-- Mob state (mcl_mobs specific; captured defensively).
	local sheared = (lua.gotten == true) and 1 or 0
	local baby = (lua.child == true or lua.baby == true) and 1 or 0
	local color = lua.color or lua.dye or ""

	-- Capture static visual metadata once per slot (for later mesh drawing).
	if agent_meta[slot] == nil and props then
		agent_meta[slot] = {
			slot = slot,
			name = lua.name or AGENT_NAME,
			mesh = props.mesh or "",
			textures = props.textures or {},
			visual = props.visual or "",
			visual_size = props.visual_size or {x = 1, y = 1, z = 1},
			collisionbox = cbox,
			selectionbox = props.selectionbox or cbox,
		}
		meta_dirty = true
	end

	return {
		slot = slot,
		name = lua.name or AGENT_NAME,
		present = 1,
		pos = {x = pos.x, y = pos.y, z = pos.z},
		vel = {x = vel.x, y = vel.y, z = vel.z},
		yaw = yaw,
		rotation = {x = rot.x, y = rot.y, z = rot.z},
		collisionbox = cbox,
		hp = hp,
		sheared = sheared,
		baby = baby,
		color = color,
	}
end

-- Write a one-off "meta" record with the static visual metadata per slot.
-- The PERSIST reader keeps the last meta record it sees.
local function write_meta()
	if log_file == nil then
		return
	end
	local metas = {}
	for slot = 1, NUM_AGENTS do
		metas[slot] = agent_meta[slot] or {slot = slot, name = AGENT_NAME}
	end
	local record = {kind = "meta", num_agents = NUM_AGENTS, agents = metas}
	local ok, line = pcall(minetest.write_json, record)
	if ok and line then
		log_file:write(line .. "\n")
		log_file:flush()
	end
	meta_dirty = false
end

-- Write one JSON record for the current frame.
local function log_frame(player_pos)
	if log_file == nil then
		return
	end
	local agents = {}
	for slot = 1, NUM_AGENTS do
		local rec = read_agent(slot)
		if rec == nil then
			rec = {slot = slot, name = AGENT_NAME, present = 0,
			       pos = {x = 0, y = 0, z = 0}, vel = {x = 0, y = 0, z = 0},
			       yaw = 0, rotation = {x = 0, y = 0, z = 0},
			       collisionbox = {0, 0, 0, 0, 0, 0}, hp = 0,
			       sheared = 0, baby = 0, color = ""}
		end
		agents[slot] = rec
	end

	-- Flush metadata whenever a newly-seen agent contributed some.
	if meta_dirty then
		write_meta()
	end

	local record = {
		kind = "frame",
		frame = frame,
		time = minetest.get_gametime(),
		player_pos = {x = player_pos.x, y = player_pos.y, z = player_pos.z},
		num_agents = NUM_AGENTS,
		agents = agents,
	}

	local ok, line = pcall(minetest.write_json, record)
	if ok and line then
		log_file:write(line .. "\n")
		log_file:flush()
	end
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------
minetest.register_on_joinplayer(function(_player, _last_login)
	open_log()
end)

minetest.register_globalstep(function(_dtime)
	local player = minetest.get_connected_players()[1]
	if player == nil then
		return
	end

	local player_pos = player:get_pos()

	if not spawned then
		local map_ready = ensure_population(player_pos)
		-- Consider the population "spawned" once the map was ready and at
		-- least one agent exists.
		if map_ready then
			for slot = 1, NUM_AGENTS do
				if tracked[slot] ~= nil then
					spawned = true
					break
				end
			end
		end
	elseif MAINTAIN then
		ensure_population(player_pos)
	end

	frame = frame + 1
	log_frame(player_pos)
end)
