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
local MAX_RADIUS    = setting_number("dynamic_agents_max_radius", 12.0)
-- Minimum horizontal spacing between mobs at spawn/relocation, so the herd is
-- spread out (sparse) instead of clustered in one spot.
local MIN_SEPARATION = setting_number("dynamic_agents_min_separation", 4.0)
-- Keep the population topped up if mobs die/despawn during the episode.
local MAINTAIN      = setting_true("dynamic_agents_maintain", true)
-- Keep mobs near the player (so they stay observable within the episode): any
-- mob that strays beyond this horizontal distance is relocated back near the
-- player. 0 disables.
local LEASH_RADIUS  = setting_number("dynamic_agents_leash_radius", 14.0)
-- Make every spawned mob behave like a passive land animal: no attacking /
-- chasing, no self-destruct, no environmental death - just wander around.
local NEUTRAL       = setting_true("dynamic_agents_neutral", true)

-- View-cone gate: a mob is only ever (re)spawned or relocated to a spot that is
-- OUTSIDE this half-angle (degrees) from the player's look direction, so the
-- player never witnesses a mob appear or teleport into the frame - it only ever
-- discovers mobs by turning toward them. Wide default = conservative (anything
-- near the screen edge still counts as visible and is left untouched).
local VIEW_HALF_ANGLE = setting_number("dynamic_agents_view_half_angle", 65.0)
local VIEW_COS        = math.cos(math.rad(VIEW_HALF_ANGLE))
local VIEW_EYE_HEIGHT = 1.5   -- approx player eye height above feet

-- The base game (VoxeLibre) keeps spawning its own ambient mobs all over the
-- terrain, which would flood the scene with far more creatures than our fixed
-- set. We remove any mob (mobs_mc:*) that we did not spawn ourselves - ours are
-- tagged with `_dyn_slot`. This is a hard guarantee independent of any engine
-- "mobs_spawn" config toggle. CULL_RADIUS covers the visible area around the
-- player.
local CULL_WILD   = setting_true("dynamic_agents_cull_wild", true)
local CULL_RADIUS = setting_number("dynamic_agents_cull_radius", 96.0)

-- Cap how fast a mob may move (blocks/second, horizontal). Some VoxeLibre mobs
-- (horses, spiders, etc.) run very fast, which looks unnatural in the dataset.
-- We both lower their configured walk/run speeds (source) and hard-clamp their
-- actual horizontal velocity every frame (safety net). Vertical velocity
-- (falling/jumping) is left alone.
local MAX_SPEED = setting_number("dynamic_agents_max_speed", 3.0)

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
	-- cap configured movement speeds so mobs don't zip around unnaturally fast
	if lua.walk_velocity ~= nil then lua.walk_velocity = math.min(lua.walk_velocity, MAX_SPEED) end
	if lua.run_velocity ~= nil then lua.run_velocity = math.min(lua.run_velocity, MAX_SPEED) end
end

-- True if the ground under `p` (or the node at foot level) is a liquid.
local function _node_is_liquid(name)
	local def = minetest.registered_nodes[name]
	return def ~= nil and def.liquidtype ~= nil and def.liquidtype ~= "none"
end
local function mob_over_water(p)
	local at = minetest.get_node_or_nil({x = p.x, y = p.y + 0.1, z = p.z})
	local below = minetest.get_node_or_nil({x = p.x, y = p.y - 0.3, z = p.z})
	return (at ~= nil and _node_is_liquid(at.name))
	    or (below ~= nil and _node_is_liquid(below.name))
end

-- Hard-clamp a live mob's horizontal velocity to MAX_SPEED (keeps vertical
-- velocity for natural falling/jumping). Safety net for physics/push spikes.
local function clamp_speed(obj)
	if MAX_SPEED <= 0 then return end
	local ok, v = pcall(function() return obj:get_velocity() end)
	if not ok or v == nil then return end
	local h = math.sqrt(v.x * v.x + v.z * v.z)
	if h > MAX_SPEED then
		local s = MAX_SPEED / h
		pcall(function() obj:set_velocity({x = v.x * s, y = v.y, z = v.z * s}) end)
	end
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

-- Find the top walkable SURFACE near `pos`, scanning downwards. A surface is a
-- solid node with a non-solid node above it (so we don't pick the underside of
-- an overhang). Returns a spawn position resting ON that surface (feet just above
-- it, so the mob does NOT drop from the sky), or nil if the map isn't loaded yet.
local function find_ground(pos)
	local map_ready = false
	local base = math.floor(pos.y + 0.5)
	for dy = 6, -24, -1 do
		local p = {x = pos.x, y = base + dy, z = pos.z}
		local node = minetest.get_node_or_nil(p)
		if node ~= nil then
			map_ready = true
			local def = minetest.registered_nodes[node.name]
			if def and def.walkable then
				local above = minetest.get_node_or_nil({x = p.x, y = p.y + 1, z = p.z})
				local adef = above and minetest.registered_nodes[above.name]
				if not (adef and adef.walkable) then
					-- node centre is p.y; its top is p.y+0.5 -> place feet just above
					return {x = pos.x, y = p.y + 0.6, z = pos.z}, map_ready
				end
			end
		end
	end
	return nil, map_ready
end

-- Is world position `pos` currently inside the player's view cone (and in front
-- of them)? Used so we never spawn/relocate a mob where the player would see it
-- appear. VIEW_COS uses a wide (conservative) half-angle, so anything near the
-- screen edge still counts as visible and is left alone.
local function in_view(player, pos)
	local eye = player:get_pos()
	eye.y = eye.y + VIEW_EYE_HEIGHT
	local dir = player:get_look_dir()
	local dx, dy, dz = pos.x - eye.x, pos.y - eye.y, pos.z - eye.z
	local len = math.sqrt(dx * dx + dy * dy + dz * dz)
	if len < 1e-3 then return true end
	local dot = (dx * dir.x + dy * dir.y + dz * dir.z) / len
	return dot >= VIEW_COS
end

-- Is `pos` too close (horizontally) to an already-placed mob? Keeps the herd
-- sparse so mobs don't clump in one spot.
local function too_close(pos)
	local d2 = MIN_SEPARATION * MIN_SEPARATION
	for slot = 1, NUM_AGENTS do
		local o = tracked[slot]
		if o ~= nil and o:get_luaentity() ~= nil then
			local q = o:get_pos()
			if q ~= nil then
				local dx, dz = pos.x - q.x, pos.z - q.z
				if (dx * dx + dz * dz) < d2 then
					return true
				end
			end
		end
	end
	return false
end

-- Find a walkable ground spot in the ring [MIN_RADIUS, MAX_RADIUS] around the
-- player, distributed at a random bearing (full 360 degrees) and kept sparse via
-- too_close(). When `avoid_view` is set, the spot must also be OUTSIDE the
-- player's current view cone (used for mid-episode respawn/relocation so mobs are
-- never seen to appear). Returns (ground_pos, map_ready).
local function find_spawn_ground(player, player_pos, avoid_view)
	local map_ready = false
	local gate = avoid_view and player ~= nil
	for _ = 1, 24 do
		local angle = math.random() * 2 * math.pi
		local r = MIN_RADIUS + math.random() * (MAX_RADIUS - MIN_RADIUS)
		local cand = {x = player_pos.x + r * math.cos(angle),
		              y = player_pos.y,
		              z = player_pos.z + r * math.sin(angle)}
		if not (gate and in_view(player, cand)) then
			local ground, ready = find_ground(cand)
			map_ready = map_ready or ready
			if ground ~= nil and not too_close(ground)
			   and not (gate and in_view(player, ground)) then
				return ground, true
			end
		end
	end
	return nil, map_ready
end

-- Spawn a single agent for the given slot. The initial population is distributed
-- sparsely all around the player (avoid_view=false: it's the starting scene, in
-- or out of view). Mid-episode respawns pass avoid_view=true so a replacement is
-- only ever placed off-screen and never pops into the frame.
local function spawn_agent(slot, player_pos, player, avoid_view)
	local name = slot_entity[slot] or AGENT_NAME

	-- Never try to spawn an unregistered entity (it would create an "unknown
	-- object" placeholder). Mark the slot failed so it is not retried.
	if not is_registered(name) then
		slot_failed[slot] = true
		return false, true
	end

	local ground, map_ready = find_spawn_ground(player, player_pos, avoid_view)
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
-- The initial population (spawned == false) is distributed sparsely all around
-- the player; later top-ups (spawned == true) are placed off-screen so they
-- never pop into the frame.
local function ensure_population(player, player_pos)
	local map_ready = true
	for slot = 1, NUM_AGENTS do
		if not slot_failed[slot] then
			local obj = tracked[slot]
			local alive = obj ~= nil and obj:get_luaentity() ~= nil
			if not alive and (MAINTAIN or not spawned) then
				-- Initial population (not yet `spawned`): place on the ground right
				-- away so ALL mobs are present from the start (a few may be in the
				-- opening view - that's fine, they don't "appear", they're just
				-- there). Later top-ups spawn off-screen so they never pop in.
				local ok, ready = spawn_agent(slot, player_pos, player, spawned)
				map_ready = map_ready and ready
			end
		end
	end
	return map_ready
end

-- Remove ambient mobs the base game spawned (any mobs_mc:* without our
-- `_dyn_slot` tag) within CULL_RADIUS of the player, so only our fixed set is
-- ever present. Items, projectiles, the player, etc. are left untouched.
local function cull_wild_mobs(player_pos)
	if not CULL_WILD then
		return
	end
	local objs = minetest.get_objects_inside_radius(player_pos, CULL_RADIUS)
	for _, o in ipairs(objs) do
		local lua = o:get_luaentity()
		if lua ~= nil and lua._dyn_slot == nil then
			local n = lua.name or ""
			if n:sub(1, 8) == "mobs_mc:" then
				o:remove()
			end
		end
	end
end

-- Gently push apart any two mobs that are closer than MIN_SEPARATION, so the
-- herd doesn't pile up on top of each other. Uses a small velocity nudge (not a
-- teleport) so it looks natural and doesn't cause pop-in.
local function declump_agents()
	local d2 = MIN_SEPARATION * MIN_SEPARATION
	for i = 1, NUM_AGENTS do
		local oi = tracked[i]
		if oi ~= nil and oi:get_luaentity() ~= nil then
			local pi = oi:get_pos()
			if pi ~= nil then
				for j = i + 1, NUM_AGENTS do
					local oj = tracked[j]
					if oj ~= nil and oj:get_luaentity() ~= nil then
						local pj = oj:get_pos()
						if pj ~= nil then
							local dx, dz = pi.x - pj.x, pi.z - pj.z
							local dd = dx * dx + dz * dz
							if dd > 1e-6 and dd < d2 then
								local d = math.sqrt(dd)
								local nx, nz = dx / d, dz / d
								local push = 0.6
								pcall(function() oi:add_velocity({x = nx * push, y = 0, z = nz * push}) end)
								pcall(function() oj:add_velocity({x = -nx * push, y = 0, z = -nz * push}) end)
							end
						end
					end
				end
			end
		end
	end
end

-- Soft leash: mobs wander freely; only a mob that has strayed beyond
-- LEASH_RADIUS *and* is currently OUT of view is quietly relocated to another
-- sparse, off-screen ground spot near the player. The player never witnesses the
-- move, and in-view mobs are left to walk around on their own.
local function leash_agents(player, player_pos)
	if LEASH_RADIUS <= 0 then
		return
	end
	for slot = 1, NUM_AGENTS do
		local obj = tracked[slot]
		if obj ~= nil and obj:get_luaentity() ~= nil then
			local p = obj:get_pos()
			if p ~= nil then
				local dx, dz = player_pos.x - p.x, player_pos.z - p.z  -- toward player
				local d2 = dx * dx + dz * dz
				if d2 > (LEASH_RADIUS * LEASH_RADIUS) then
					local d = math.sqrt(d2)
					-- SOFT leash: steer the mob to WALK back toward the player (a
					-- velocity nudge, capped later by clamp_speed) instead of
					-- teleporting it. This is what stops mobs vanishing and
					-- reappearing elsewhere - they now move continuously.
					local pull = math.min(MAX_SPEED, d - LEASH_RADIUS + 0.5)
					pcall(function()
						obj:add_velocity({x = (dx / d) * pull, y = 0, z = (dz / d) * pull})
					end)
					-- Failsafe ONLY: if a mob got extremely far (e.g. stuck across
					-- water/a wall and cannot walk back) AND is off-screen, relocate
					-- it once. This is rare and never happens in normal wandering.
					if d > LEASH_RADIUS * 3 and not in_view(player, p) then
						local ground = find_spawn_ground(player, player_pos, true)
						if ground ~= nil then
							obj:set_pos(ground)
						end
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
		local map_ready = ensure_population(player, player_pos)
		-- Keep trying every frame until ALL slots are placed (or permanently
		-- failed), so the full initial population spawns even when MAINTAIN is off
		-- (free-roam). A deadline stops us retrying forever on bad terrain.
		if map_ready then
			local all_done = true
			for slot = 1, NUM_AGENTS do
				if tracked[slot] == nil and not slot_failed[slot] then
					all_done = false
					break
				end
			end
			if all_done or frame > 90 then
				spawned = true
			end
		end
	elseif MAINTAIN then
		ensure_population(player, player_pos)
	end

	-- Purge any ambient mobs the base game spawned, so only our fixed set exists.
	cull_wild_mobs(player_pos)

	-- Keep the herd loosely near the player so it stays observable within the
	-- episode (relocation happens only off-screen; see leash_agents).
	if spawned then
		leash_agents(player, player_pos)
		declump_agents()
		-- Pull any water-straying mob back toward the (land) player, then cap every
		-- mob's speed AFTER leash/declump/AI have set velocities, so the logged
		-- velocities and the on-screen motion are both within MAX_SPEED.
		for slot = 1, NUM_AGENTS do
			local obj = tracked[slot]
			if obj ~= nil and obj:get_luaentity() ~= nil then
				local p = obj:get_pos()
				if p ~= nil and mob_over_water(p) then
					local dx, dz = player_pos.x - p.x, player_pos.z - p.z
					local d = math.sqrt(dx * dx + dz * dz)
					if d > 0.01 then
						pcall(function() obj:add_velocity({x = (dx / d) * 2.0, y = 0, z = (dz / d) * 2.0}) end)
					end
				end
				clamp_speed(obj)
			end
		end
	end

	frame = frame + 1
	log_frame(player)
end)
