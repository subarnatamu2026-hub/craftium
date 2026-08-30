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

-- Seed the RNG deterministically from the level seed so the chosen count and
-- the mix of mob types are reproducible per level.
local _seed = tonumber(minetest.settings:get("fixed_map_seed"))
if _seed then math.randomseed(_seed) end

-- Entity type(s). `dynamic_agents_entities` is a comma-separated list to mix
-- different animals; falls back to the single `dynamic_agents_entity`.
local function parse_list(s)
	local out = {}
	if s then
		for item in string.gmatch(s, "([^,]+)") do
			item = item:gsub("^%s+", ""):gsub("%s+$", "")
			if item ~= "" then table.insert(out, item) end
		end
	end
	return out
end
local ENTITY_LIST = parse_list(minetest.settings:get("dynamic_agents_entities"))
if #ENTITY_LIST == 0 then
	ENTITY_LIST = {minetest.settings:get("dynamic_agents_entity") or "mobs_mc:sheep"}
end

-- Keep only entities that are actually registered in this game build. Requesting
-- an unregistered id makes minetest.add_entity spawn an "unknown object"
-- placeholder, so we must never try to spawn those.
local function is_registered(name)
	return minetest.registered_entities ~= nil
	       and minetest.registered_entities[name] ~= nil
end
do
	local valid = {}
	for _, n in ipairs(ENTITY_LIST) do
		if is_registered(n) then
			table.insert(valid, n)
		else
			minetest.log("warning", "[dynamic_agents] entity not registered, skipping: " .. tostring(n))
		end
	end
	if #valid == 0 then
		valid = is_registered("mobs_mc:sheep") and {"mobs_mc:sheep"} or ENTITY_LIST
		minetest.log("warning", "[dynamic_agents] no requested entities registered; using fallback")
	end
	ENTITY_LIST = valid
end
local AGENT_NAME = ENTITY_LIST[1]

-- Number of agents: random in [count_min, count_max] if given, else count.
local COUNT_MIN = math.floor(setting_number("dynamic_agents_count_min",
                    setting_number("dynamic_agents_count", 10)))
local COUNT_MAX = math.floor(setting_number("dynamic_agents_count_max", COUNT_MIN))
if COUNT_MAX < COUNT_MIN then COUNT_MAX = COUNT_MIN end
local NUM_AGENTS = math.random(COUNT_MIN, COUNT_MAX)

local MIN_RADIUS    = setting_number("dynamic_agents_min_radius", 4.0)
local MAX_RADIUS    = setting_number("dynamic_agents_max_radius", 10.0)
-- Keep the population topped up if mobs die/despawn during the episode.
local MAINTAIN      = setting_true("dynamic_agents_maintain", true)
-- Keep mobs near the player (so they stay observable within the episode): any
-- mob that strays beyond this horizontal distance is relocated back near the
-- player. 0 disables.
local LEASH_RADIUS  = setting_number("dynamic_agents_leash_radius", 8.0)
-- Make every spawned mob behave like a passive land animal: no attacking /
-- chasing, no self-destruct, no environmental death - just wander around.
local NEUTRAL       = setting_true("dynamic_agents_neutral", true)

-- Reconfigure a mob's luaentity so its AI never hunts/attacks and it does not
-- die to sunlight/fire/water. Safe to over-set fields a given mob doesn't use.
local function neutralize(lua)
	if lua == nil then return end
	lua.type = "animal"          -- animals wander instead of hunting
	lua.attack = nil             -- drop any current target
	lua.attack_type = nil        -- disable melee/shoot/explode behaviour
	lua.attack_players = false
	lua.attack_animals = false
	lua.attack_npcs = false
	lua.attacks_monsters = false
	lua.group_attack = false
	lua.specific_attack = nil
	lua.damage = 0
	lua.docile_by_day = false
	lua.passive = true
	lua.runaway = false          -- don't flee from the player either
	if lua.state == "attack" then lua.state = "stand" end
	-- survive the environment so hostile bodies keep wandering
	lua.ignited_by_sunlight = false
	lua.light_damage = 0
	lua.sunlight_damage = 0
	lua.fire_damage = 0
	lua.water_damage = 0
	lua.fire_resistant = true
	-- creeper / self-destruct safety
	lua.explosion_radius = 0
	lua.explosion_damage_radius = 0
	lua.explosion_strength = 0
end

-- Assign each slot a (random) entity type from the list, fixed for the episode
-- so a respawned/topped-up slot keeps the same species.
local slot_entity = {}
for slot = 1, NUM_AGENTS do
	slot_entity[slot] = ENTITY_LIST[math.random(1, #ENTITY_LIST)]
end

local LOG_PATH = minetest.get_worldpath() .. "/data_dynamic.jsonl"

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local frame = 0                -- server step counter (matches Python receives)
local spawned = false          -- whether the initial population has been spawned
local tracked = {}             -- slot index -> ObjectRef
local slot_failed = {}         -- slots whose species can't spawn a real mob (skip forever)
local log_file = nil
local agent_meta = {}          -- slot index -> static visual metadata (mesh, textures, ...)
local player_meta = nil        -- static visual metadata for the player body
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
	local name = slot_entity[slot] or AGENT_NAME

	-- Never try to spawn an unregistered entity (it would create an "unknown
	-- object" placeholder). Mark the slot failed so it is not retried.
	if not is_registered(name) then
		slot_failed[slot] = true
		return false, true
	end

	local ground, map_ready = find_ground(target)
	if ground == nil then
		return false, map_ready
	end

	local obj = minetest.add_entity(ground, name)
	if obj == nil then
		return false, map_ready
	end

	-- A real mob has a luaentity. If not (placeholder / failed spawn), remove it
	-- and stop retrying this slot so we never accumulate "unknown object"s.
	local lua = obj:get_luaentity()
	if lua == nil then
		obj:remove()
		slot_failed[slot] = true
		return false, map_ready
	end

	-- Tag the entity so it survives despawn logic where the mob framework
	-- honours these fields, and remember its slot.
	lua.persistent = true
	lua.despawn_immediately = false
	lua._dyn_slot = slot
	if NEUTRAL then neutralize(lua) end
	tracked[slot] = obj
	return true, map_ready
end

-- Spawn the whole population, retrying on later frames until the map is ready.
local function ensure_population(player_pos)
	local map_ready = true
	for slot = 1, NUM_AGENTS do
		if not slot_failed[slot] then
			local obj = tracked[slot]
			local alive = obj ~= nil and obj:get_luaentity() ~= nil
			if not alive and (MAINTAIN or not spawned) then
				local ok, ready = spawn_agent(slot, player_pos)
				map_ready = map_ready and ready
			end
		end
	end
	return map_ready
end

-- Keep the herd near the player so it stays observable: any live mob that has
-- strayed beyond LEASH_RADIUS (horizontal) is relocated to a fresh ground spot
-- within the normal spawn ring around the player.
local function leash_agents(player_pos)
	if LEASH_RADIUS <= 0 then
		return
	end
	for slot = 1, NUM_AGENTS do
		local obj = tracked[slot]
		if obj ~= nil and obj:get_luaentity() ~= nil then
			local p = obj:get_pos()
			if p ~= nil then
				local dx, dz = p.x - player_pos.x, p.z - player_pos.z
				if (dx * dx + dz * dz) > (LEASH_RADIUS * LEASH_RADIUS) then
					-- Relocate strictly inside the leash so the mob isn't teleported
					-- again next frame (avoids visible jitter). Ring upper bound is
					-- clamped to just under LEASH_RADIUS.
					local r_max = math.min(MAX_RADIUS, LEASH_RADIUS - 1.0)
					if r_max < MIN_RADIUS then r_max = MIN_RADIUS end
					local angle = math.random() * 2 * math.pi
					local r = MIN_RADIUS + math.random() * (r_max - MIN_RADIUS)
					local ground = find_ground({
						x = player_pos.x + r * math.cos(angle),
						y = player_pos.y,
						z = player_pos.z + r * math.sin(angle),
					})
					if ground ~= nil then
						obj:set_pos(ground)
					end
				end
			end
		end
	end
end

-- Bone names to probe on engines without get_bone_overrides() (legacy fallback).
local BONE_PROBE = {"head", "Head", "Head_Control", "body", "Body",
                    "Arm_Right", "Arm_Left",
                    "Arm_Right_Pitch_Control", "Arm_Left_Pitch_Control"}

-- Which animation clip is currently playing (frame range + speed).
local function read_animation(obj)
	local ok, range, speed, blend = pcall(function()
		return obj:get_animation()
	end)
	if ok and range then
		return {range = {x = range.x or 0, y = range.y or 0},
		        speed = speed or 0, blend = blend or 0}
	end
	return {range = {x = 0, y = 0}, speed = 0, blend = 0}
end

-- Per-frame bone overrides (articulation a mod has explicitly posed, e.g. head
-- swivel, player arm/head pitch). Rotations are normalized to radians. Returns
-- a map bone_name -> {rot={x,y,z}, pos={x,y,z}}. Only overridden bones appear.
local function read_bones(obj)
	local out = {}
	-- Preferred: get_bone_overrides() returns all set overrides (Luanti 5.9+),
	-- rotations already in radians.
	local ok, all = pcall(function() return obj:get_bone_overrides() end)
	if ok and type(all) == "table" then
		for bone, ov in pairs(all) do
			local rec = {}
			if ov.rotation and ov.rotation.vec then
				local r = ov.rotation.vec
				rec.rot = {x = r.x, y = r.y, z = r.z}
			end
			if ov.position and ov.position.vec then
				local p = ov.position.vec
				rec.pos = {x = p.x, y = p.y, z = p.z}
			end
			if rec.rot or rec.pos then out[bone] = rec end
		end
		return out
	end
	-- Legacy fallback: probe known bone names (get_bone_position returns
	-- rotation in degrees, so convert to radians).
	for _, bone in ipairs(BONE_PROBE) do
		local ok2, pos, rot = pcall(function() return obj:get_bone_position(bone) end)
		if ok2 and rot then
			out[bone] = {
				rot = {x = math.rad(rot.x), y = math.rad(rot.y), z = math.rad(rot.z)},
				pos = pos and {x = pos.x, y = pos.y, z = pos.z} or nil,
			}
		end
	end
	return out
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

	-- Re-assert neutral behaviour each frame so the AI can't re-arm.
	if NEUTRAL then neutralize(lua) end

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
		anim = read_animation(obj),
		bones = read_bones(obj),
	}
end

-- Read the player body state, capturing its static visual metadata once.
local function read_player(player)
	local pos = player:get_pos()

	local yaw = 0
	local ok_y, y = pcall(function() return player:get_look_horizontal() end)
	if ok_y and y then yaw = y end
	local pitch = 0
	local ok_p, p = pcall(function() return player:get_look_vertical() end)
	if ok_p and p then pitch = p end

	local props = nil
	local ok_pr, pr = pcall(function() return player:get_properties() end)
	if ok_pr and pr then props = pr end

	local cbox = {0, 0, 0, 0, 0, 0}
	if props and props.collisionbox then cbox = props.collisionbox end

	if player_meta == nil and props then
		player_meta = {
			name = "player",
			mesh = props.mesh or "",
			textures = props.textures or {},
			visual = props.visual or "",
			visual_size = props.visual_size or {x = 1, y = 1, z = 1},
			collisionbox = cbox,
		}
		meta_dirty = true
	end

	return {
		present = 1,
		pos = {x = pos.x, y = pos.y, z = pos.z},
		yaw = yaw,
		rotation = {x = pitch, y = yaw, z = 0},
		collisionbox = cbox,
		anim = read_animation(player),
		bones = read_bones(player),
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
		metas[slot] = agent_meta[slot] or {slot = slot, name = slot_entity[slot] or AGENT_NAME}
	end
	local record = {kind = "meta", num_agents = NUM_AGENTS, agents = metas,
	                player = player_meta or {name = "player"}}
	local ok, line = pcall(minetest.write_json, record)
	if ok and line then
		log_file:write(line .. "\n")
		log_file:flush()
	end
	meta_dirty = false
end

-- Write one JSON record for the current frame.
local function log_frame(player)
	if log_file == nil then
		return
	end
	local player_body = read_player(player)
	local player_pos = player_body.pos

	local agents = {}
	for slot = 1, NUM_AGENTS do
		local rec = read_agent(slot)
		if rec == nil then
			rec = {slot = slot, name = slot_entity[slot] or AGENT_NAME, present = 0,
			       pos = {x = 0, y = 0, z = 0}, vel = {x = 0, y = 0, z = 0},
			       yaw = 0, rotation = {x = 0, y = 0, z = 0},
			       collisionbox = {0, 0, 0, 0, 0, 0}, hp = 0,
			       sheared = 0, baby = 0, color = "",
			       anim = {range = {x = 0, y = 0}, speed = 0, blend = 0}, bones = {}}
		end
		agents[slot] = rec
	end

	-- Flush metadata whenever a newly-seen agent (or the player) contributed some.
	if meta_dirty then
		write_meta()
	end

	local record = {
		kind = "frame",
		frame = frame,
		time = minetest.get_gametime(),
		player_pos = {x = player_pos.x, y = player_pos.y, z = player_pos.z},
		player = player_body,
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

	-- Keep the herd near the player so it stays observable within the episode.
	if spawned then
		leash_agents(player_pos)
	end

	frame = frame + 1
	log_frame(player)
end)
