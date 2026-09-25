-- HelltideRevamped integration regressions: CRT-4/L11 (a Looter/Alfred yield
-- never counts toward the chest and chest-recall stuck windows), HLT-1..HLT-9
-- and the suite contract items C1 (canonical Alfred reading), C3 (Batmobile
-- release), C4 (orbwalker release), C5 (yield accounting), A5-2 (advisory
-- flags under WarPigs, guard) and C6 (bounded,
-- published holds). Loads the real HelltideRevamped main.lua, task_manager,
-- tasks and core modules with QQT-shaped host mocks; Alfred, Batmobile,
-- Looteer and the orbwalker are the synthetic boundaries. Runs under Lua 5.4
-- and LuaJIT.
local root = assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/HelltideRevamped-0.4/'
local checks, cases, failures = 0, 0, {}
local function ok(cond, message)
    checks = checks + 1
    if not cond then error(message or 'assertion failed', 2) end
end
local function eq(actual, expected, message)
    checks = checks + 1
    if actual ~= expected then
        error((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
end
local function case(name, fn)
    cases = cases + 1
    local passed, err = pcall(fn)
    if passed then
        print('PASS Helltide integration: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Helltide integration: ' .. name .. ': ' .. tostring(err))
    end
end

local Vec = {}; Vec.__index = Vec
function Vec:new(x, y, z) return setmetatable({xx = x or 0, yy = y or 0, zz = z or 0}, self) end
function Vec:x() return self.xx end
function Vec:y() return self.yy end
function Vec:z() return self.zz end
function Vec:dist_to(o) return math.sqrt((self.xx - o:x())^2 + (self.yy - o:y())^2 + (self.zz - o:z())^2) end
function Vec:dist_to_ignore_z(o) return math.sqrt((self.xx - o:x())^2 + (self.yy - o:y())^2) end
local function v(x, y, z) return Vec:new(x, y, z) end

-- Actor handles; navigate_to() treats non-userdata targets as positions, so
-- the mock also answers the vector accessors.
local function actor(skin, x, y, opts)
    opts = opts or {}
    local a = {skin = skin, pos = v(x, y, opts.z or 0), interactable = opts.interactable ~= false}
    function a:get_skin_name() return self.skin end
    function a:get_position() return self.pos end
    function a:is_interactable() return self.interactable end
    function a:x() return self.pos:x() end
    function a:y() return self.pos:y() end
    function a:z() return self.pos:z() end
    function a:dist_to(o) return self.pos:dist_to(o) end
    return a
end

local HELLTIDE_BUFF, TELEPORT_BUFF = 1066539, 44010
local TOWN_ZONE = 'Skov_Temis'

local function session(opts)
    opts = opts or {}
    local s = {now = 100, minute = opts.minute or 10, pos = v(0, 0, 0),
        world = opts.world or 'Sanctuary_Eastern_Continent', zone = opts.zone or 'Test_Zone',
        in_helltide = opts.in_helltide ~= false, teleporting = false, cinders = opts.cinders or 311,
        items = 0, actors = {}, loot = {}, logs = {}, teleports = {}, interactions = {}, triggers = {},
        looting = false, orb = {clear = true, block = false}, task_ticks = {}, name_ticks = {}}
    local bm = {target = nil, paused = false, resets = 0, releases = {}, clears = 0, sets = {},
        long_paths = {}, long_active = false, giving_up = false, moves = 0}
    s.bm = bm
    local batmobile = {
        pause = function() bm.paused = true end,
        resume = function() bm.paused = false end,
        set_target = function(_, t) bm.target = t; bm.sets[#bm.sets + 1] = {at = s.now, target = t}; return true end,
        clear_target = function() bm.target = nil; bm.clears = bm.clears + 1 end,
        stop_long_path = function() bm.long_active = false end,
        update = function() end,
        move = function() bm.moves = bm.moves + 1 end,
        is_paused = function() return bm.paused end,
        is_done = function() return false end,
        reset = function() bm.resets = bm.resets + 1; bm.target = nil end,
        reset_movement = function() bm.target = nil end,
        get_target = function() return bm.target end,
        clear_giving_up = function() bm.giving_up = false end,
        is_giving_up = function() return bm.giving_up end,
        navigate_long_path = function() bm.long_paths[#bm.long_paths + 1] = s.now; bm.long_active = true; return true end,
        is_long_path_navigating = function() return bm.long_active end,
        get_closeby_node = function(_, p) return p end,
        clear_traversal_blacklist = function() end,
    }
    if opts.release then
        batmobile.release = function(caller)
            bm.releases[#bm.releases + 1] = caller
            bm.target, bm.paused, bm.long_active = nil, true, false
        end
    end
    local player = {
        get_position = function() return s.pos end,
        get_current_speed = function() return 0 end,
        is_dead = function() return false end,
        get_item_count = function() return s.items end,
        get_consumable_items = function() return {} end,
        get_attribute = function() return 0 end,
        get_buffs = function()
            local buffs = {}
            if s.in_helltide then buffs[#buffs + 1] = {name_hash = HELLTIDE_BUFF} end
            if s.teleporting then buffs[#buffs + 1] = {name_hash = TELEPORT_BUFF} end
            return buffs
        end,
    }
    local world = {get_name = function() return s.world end,
        get_current_zone_name = function() return s.zone end,
        get_world_id = function() return 1 end}
    local env = setmetatable({}, {__index = _G})
    env._G = env
    env.vec3 = Vec
    env.get_time_since_inject = function() return s.now end
    env.get_helltide_coin_cinders = function() return s.cinders end
    env.get_player_position = function() return s.pos end
    env.get_local_player = function() return player end
    env.get_current_world = function() return world end
    env.on_render = function() end
    env.on_render_menu = function() end
    env.on_update = function(fn) s.update = fn end
    env.console = {print = function(line) s.logs[#s.logs + 1] = tostring(line) end}
    env.target_selector = {get_near_target_list = function() return {} end}
    env.actors_manager = {get_all_actors = function() return s.actors end, get_enemy_actors = function() return {} end}
    env.loot_manager = {get_all_items_chest_sort_by_distance = function() return s.loot end,
        any_item_around = function() return false end}
    env.utility = {set_height_of_valid_position = function(p) return p end, is_point_walkeable = function() return true end}
    env.pathfinder = {request_move = function() end, clear_stored_path = function() end}
    env.teleport_to_waypoint = function(id) s.teleports[#s.teleports + 1] = {at = s.now, id = id} end
    env.interact_object = function(a) s.interactions[#s.interactions + 1] = a end
    env.revive_at_checkpoint = function() end
    env.attributes = {PLAYER_IN_TOWN_LEVEL_AREA = 1}
    env.orbwalker = {set_clear_toggle = function(on) s.orb.clear = on end,
        set_block_movement = function(on) s.orb.block = on end}
    -- utils.helltide_active()/do_events() read the local minute.
    env.os = setmetatable({date = function(fmt, ...)
        if fmt == '%M' then return string.format('%02d', s.minute) end
        return os.date(fmt, ...)
    end}, {__index = os})
    env.BatmobilePlugin = batmobile
    env.LooteerPlugin = {get_enabled = function() return true end,
        is_actively_looting = function() return s.looting end}

    local function control(value)
        return {value = value, get = function(self) return self.value end, set = function(self, n) self.value = n end}
    end
    local controls = setmetatable({}, {__index = function(t, k) local c = control(false); rawset(t, k, c); return c end})
    local defaults = {main_toggle = opts.enabled == true, town = 0, salvage_toggle = opts.salvage == true,
        helltide_chest_toggle = true, kill_monsters_toggle = false, kill_monsters_rarity = 0,
        farm_cinder_threshold = 0, maiden_disable_cinders = 0, manage_orbwalker = opts.manage_orbwalker == true,
        prioritize_traversals_toggle = opts.prioritize_traversals == true}
    for k, value in pairs(defaults) do controls[k] = control(value) end
    s.controls = controls
    local noop = setmetatable({}, {__index = function() return function() end end})
    local modules = {
        gui = {elements = controls, render = function() end,
            town_data = {[0] = {zone_name = TOWN_ZONE, waypoint_sno = 0x1CE51E},
                [1] = {zone_name = 'Scos_Cerrigar', waypoint_sno = 0x76D58}}},
        ['core.perf'] = noop,
        ['core.helltide_explorer'] = noop,
    }
    env.require = function(name)
        if modules[name] == nil then
            modules[name] = assert(loadfile(root .. name:gsub('%.', '/') .. '.lua', 't', env))()
        end
        return modules[name]
    end
    s.env = env
    s.settings = env.require('core.settings')
    s.settings:update_settings()
    s.tracker = env.require('core.tracker')
    s.utils = env.require('core.utils')
    s.tm = env.require('core.task_manager')
    s.helltide = env.require('tasks.helltide')
    s.search = env.require('tasks.search_helltide')
    s.loot_guard = env.require('core.loot_guard')

    function s.tick(seconds, dt)
        dt = dt or 0.1
        for _ = 1, math.floor(seconds / dt + 0.5) do
            s.now = s.now + dt
            if s.before_tick then s.before_tick() end
            if s.main_loaded then s.update() else s.tm.execute_tasks() end
            local name = s.tm.get_current_task().name or '?'
            local key = name:match('^Explore Helltide') and 'helltide' or name
            s.task_ticks[key] = (s.task_ticks[key] or 0) + 1
            s.name_ticks[name] = (s.name_ticks[name] or 0) + 1
        end
    end
    function s.load_main()
        assert(loadfile(root .. 'main.lua', 't', env))()
        s.main_loaded = true
        s.plugin = env.HelltideRevampedPlugin
    end
    function s.logged(pattern)
        local n = 0
        for _, line in ipairs(s.logs) do if line:find(pattern, 1, true) then n = n + 1 end end
        return n
    end
    function s.sets_after(t)
        local out = {}
        for _, set in ipairs(s.bm.sets) do if set.at > t then out[#out + 1] = set end end
        return out
    end
    return s
end

-- Alfred boundary: a with-teleport trip completes (callback) 10 s after the
-- trigger; status() builds each read from the session state.
local function alfred(s, status_fn, global_name)
    local a = {}
    a.get_status = function() return status_fn(s) end
    a.trigger_tasks_with_teleport = function(_, cb)
        s.triggers[#s.triggers + 1] = s.now
        s.alfred_busy, s.alfred_cb, s.alfred_cb_at = true, cb, s.now + 10
    end
    s.before_tick = function()
        if s.alfred_cb_at and s.now >= s.alfred_cb_at then
            local cb = s.alfred_cb
            s.alfred_busy, s.alfred_cb, s.alfred_cb_at, s.latched = false, nil, nil, true
            cb()
        end
    end
    s.env[global_name or 'AlfredTheButlerPlugin'] = a
    return a
end

local function chest_session(opts)
    local s = session(opts)
    s.chest = actor('usz_rewardGizmo_1H', opts and opts.chest_x or 22.7, 0)
    s.actors = {s.chest}
    return s
end

-- ── CRT-4 / L11: Looter yield vs. chest stuck windows ─────────────────────
case('CRT-4/L11 Looter busy longer than the chest window, then idle: chest approached, not blacklisted', function()
    local s = chest_session()
    s.tick(0.5)
    eq(s.helltide.current_state, 'MOVING_TO_HELLTIDE_CHEST', 'chest selected')
    s.looting = true
    s.tick(26)                                   -- live log: 25.7 s of approach_stall retries
    eq(#s.sets_after(s.now - 25), 0, 'HR issued no movement while the Looter owned it')
    s.looting = false
    local resumed = s.now
    s.tick(1)
    eq(s.logged('Stuck near'), 0, 'reachable chest blacklisted right after the yield')
    eq(s.helltide.current_state, 'MOVING_TO_HELLTIDE_CHEST', 'still going for the chest')
    local sets = s.sets_after(resumed)
    ok(#sets > 0 and sets[#sets].target:dist_to(s.chest:get_position()) < 1, 'chest re-targeted after the yield')
    s.pos = v(21.5, 0, 0)
    s.tick(0.3)
    eq(#s.interactions, 1, 'chest opened once reached')
end)

case('CRT-4 Looter bursts with short idle gaps are all excluded from the chest window', function()
    local s = chest_session()
    s.tick(0.5)
    for _ = 1, 6 do
        s.looting = true; s.tick(4)
        s.looting = false; s.tick(0.2)
    end
    eq(s.logged('Stuck near'), 0, '24 s of Looter bursts did not count as no-progress time')
    eq(s.helltide.current_state, 'MOVING_TO_HELLTIDE_CHEST')
end)

case('CRT-4 control: a genuinely stuck chest (no yield) is still blacklisted by geometry', function()
    local s = chest_session()
    s.tick(0.5)
    s.tick(13)
    eq(s.logged('Stuck near usz_rewardGizmo_1H'), 1, 'geometry blacklist kept')
    eq(s.helltide.current_state, 'EXPLORE_HELLTIDE')
end)

case('CRT-4 remembered-chest recall: Looter yield does not trip the recall stuck/no-progress windows', function()
    local s = chest_session({chest_x = 55})
    s.tick(0.5)
    eq(s.helltide.current_state, 'MOVING_TO_REMEMBERED_CHEST', 'recall selected')
    local issued = #s.bm.long_paths
    ok(issued >= 1, 'long path issued')
    s.looting = true
    s.tick(30)
    s.looting = false
    s.tick(1)
    eq(s.logged('[CHEST RECALL] Stuck near'), 0, 'recall blacklisted after the yield')
    eq(s.logged('no progress toward'), 0, 'recall no-progress watchdog counted the yield')
    eq(s.helltide.current_state, 'MOVING_TO_REMEMBERED_CHEST')
    ok(#s.bm.long_paths > issued, 'long path re-issued after the yield')
end)

case('CRT-4 recall control: a genuinely stuck recall is still blacklisted', function()
    local s = chest_session({chest_x = 55})
    s.tick(0.5)
    s.tick(13)
    eq(s.logged('[CHEST RECALL] Stuck near'), 1)
    eq(s.helltide.current_state, 'EXPLORE_HELLTIDE')
end)

case('C5 patrol re-issues its goal after a Looter yield instead of idling into FREE_EXPLORE', function()
    local s = session({zone = 'Scos_Coast'})
    s.tick(0.2)                                  -- INIT loads the marowen route
    local wps = s.tracker.waypoints
    ok(#wps > 10, 'route loaded')
    s.pos = v(wps[1]:x(), wps[1]:y(), wps[1]:z())
    s.tick(1)
    s.looting = true; s.tick(3); s.looting = false
    local resumed = s.now
    s.tick(0.3)
    ok(#s.sets_after(resumed) > 0, 'patrol goal re-sent after the yield')
    ok(s.bm.target ~= nil and not s.bm.paused, 'Batmobile has a goal and is running')
    eq(s.logged('switching to FREE_EXPLORE'), 0)
end)

-- ── HLT-1 / HLT-2 / C1: Alfred reading ────────────────────────────────────
local function gaps_ok(triggers, min_gap)
    for i = 2, #triggers do
        if triggers[i] - triggers[i - 1] < min_gap then return false, triggers[i] - triggers[i - 1] end
    end
    return true
end

-- R12 (HLT-1 completion): an advisory-only flag (restock / stash extras)
-- never starts a with-teleport trip from inside a helltide, however long it
-- stays sticky (was: one trip every 40 s, EXPLORE_HELLTIDE ~71%). A hard
-- need still leaves at once.
local EXPLORE = 'Explore Helltide (EXPLORE_HELLTIDE)'
case('R12/HLT-1 a sticky advisory need_trigger never leaves the helltide: zero trips, EXPLORE_HELLTIDE > 80%', function()
    local s = session({salvage = true})
    alfred(s, function(st)
        return {enabled = true, need_trigger = true, inventory_full = st.full == true, need_repair = false,
            trigger_tasks = st.alfred_busy == true, restock_count = 1}
    end)
    s.tick(150)
    eq(#s.triggers, 0, 'advisory-only trips started from inside the helltide')
    local explore = s.name_ticks[EXPLORE] or 0
    ok(explore > 0.8 * 1500, 'EXPLORE_HELLTIDE ticks ' .. explore .. ' of 1500')
    eq(s.tracker.needs_salvage, false, 'advisory need never sets the hard town request')
    eq(s.tm.get_current_task().hold_reason, nil, 'an advisory flag is not a hold')
    s.full = true                                -- a hard need on top of the sticky flag
    s.tick(0.5)
    eq(#s.triggers, 1, 'a hard need still triggers at once')
end)

case('R12/HLT-2 legacy restock_count is advisory: no trip from inside a helltide', function()
    local s = session({salvage = true})
    alfred(s, function(st)
        return {enabled = true, inventory_full = false, need_repair = false, restock_count = 1,
            trigger_tasks = st.alfred_busy == true}
    end, 'PLUGIN_alfred_the_butler')
    s.tick(100)
    eq(#s.triggers, 0, 'legacy restock trips')
    ok((s.name_ticks[EXPLORE] or 0) > 0.8 * 1000, 'legacy EXPLORE_HELLTIDE ticks ' .. tostring(s.name_ticks[EXPLORE]))
end)

case('R12 a provider publishing only need_trigger keeps it as its signal, behind the 30 s grace', function()
    local s = session({salvage = true})
    alfred(s, function(st)
        return {enabled = true, need_trigger = true, trigger_tasks = st.alfred_busy == true}
    end)
    s.tick(150)
    ok(#s.triggers >= 1 and #s.triggers <= 4, 'triggers in 150 s: ' .. #s.triggers)
    local fine, gap = gaps_ok(s.triggers, 39.5)          -- 10 s trip + 30 s grace
    ok(fine, 're-triggered after ' .. tostring(gap) .. ' s')
    eq(s.tracker.needs_salvage, false, 'the need_trigger-only signal goes through alfred.lua, not needs_salvage')
end)

case('HLT-1 a hard need (inventory_full) still triggers at once, even inside the grace', function()
    local s = session({salvage = true})
    s.full = true
    alfred(s, function(st)
        return {enabled = true, need_trigger = st.full, inventory_full = st.full, need_repair = false,
            trigger_tasks = st.alfred_busy == true}
    end)
    s.tick(1)
    eq(#s.triggers, 1, 'hard need triggers promptly')
    s.full = false
    s.tick(15)                                   -- trip done at +10, grace running
    s.full = true
    s.tick(1)
    eq(#s.triggers, 2, 'hard need is not held by the advisory grace')
end)

case('HLT-2 legacy fork: a latched teleport_done/teleport_failed is neither work nor a town need', function()
    for _, terminal in ipairs({'teleport_done', 'teleport_failed'}) do
        local s = session({salvage = true})
        alfred(s, function()
            return {enabled = true, need_trigger = false, inventory_full = false, need_repair = false,
                restock_count = 0, teleport = true, [terminal] = true}
        end, 'PLUGIN_alfred_the_butler')
        eq(s.utils.is_inventory_full(), false, terminal .. ' latch read as inventory full')
        s.tick(60)
        eq(#s.triggers, 0, terminal .. ' latch re-triggered Alfred')
        s.env.LooteerPlugin = nil
        eq(s.loot_guard.companion_may_own_movement(), false, terminal .. ' latch treated as live movement')
    end
    local s = session()
    alfred(s, function() return {enabled = true, teleport = true} end, 'PLUGIN_alfred_the_butler')
    s.env.LooteerPlugin = nil
    eq(s.loot_guard.companion_may_own_movement(), true, 'a live teleport still owns movement')
end)

case('C1 unreadable Alfred status holds HR at most ~10 s, then counts as unavailable (one log line)', function()
    local s = session({salvage = true})
    s.env.AlfredTheButlerPlugin = {get_status = function() error('loading') end,
        trigger_tasks_with_teleport = function() s.triggers[#s.triggers + 1] = s.now end}
    s.tick(5)
    eq(s.task_ticks.helltide or 0, 0, 'unknown status holds inside the grace')
    s.tick(10)
    ok((s.task_ticks.helltide or 0) > 30, 'farm resumed after the bounded hold')
    ok(s.bm.moves > 0, 'HR drives movement again')
    eq(#s.triggers, 0)
    ok(s.logged('unreadable') >= 1 and s.logged('unreadable') <= 2, 'logged once per reader')
end)

case('C1 a foreign Alfred pause: advisory need is idle at once; hard need holds <= 60 s then farms on', function()
    local s = session({salvage = true})
    alfred(s, function() return {enabled = true, paused = true, need_trigger = true, inventory_full = false} end)
    s.tick(3)
    ok((s.task_ticks.helltide or 0) > 20, 'paused advisory Alfred does not hold HR')
    eq(#s.triggers, 0)

    local p = session({salvage = true})
    alfred(p, function() return {enabled = true, paused = true, need_trigger = true, inventory_full = true} end)
    p.tick(30)
    ok((p.task_ticks.helltide or 0) < 10, 'hard need waits on the pause first')
    p.tick(40)
    ok((p.task_ticks.helltide or 0) > 50, 'hold is bounded; the farm continues')
    eq(#p.triggers, 0, 'a paused Alfred is never triggered')
    eq(p.logged('farming on without Alfred'), 1, 'bounded hold logged once')
end)

case('C1 cancelling HR does not erase the sticky grace', function()
    local s = session({salvage = true})
    alfred(s, function(st)                       -- need_trigger-only provider (R12)
        return {enabled = true, need_trigger = true, trigger_tasks = st.alfred_busy == true}
    end)
    s.tick(12)                                   -- trigger + callback at +10
    eq(#s.triggers, 1)
    s.tm.stop()
    s.tick(10)
    eq(#s.triggers, 1, 'restart inside the grace re-triggered advisory work')
end)

-- ── HLT-3: Batmobile give-up recovery ─────────────────────────────────────
case('HLT-3 give-up: interrupted channel re-fires the town teleport; no Alfred trip from the trap', function()
    local s = session({salvage = true})
    s.full = false
    alfred(s, function(st)
        return {enabled = true, need_trigger = st.full, inventory_full = st.full, need_repair = false,
            trigger_tasks = st.alfred_busy == true}
    end)
    s.tick(2)
    s.bm.giving_up = true
    s.tick(0.1)
    eq(#s.teleports, 1, 'give-up teleport')
    eq(s.helltide.current_state, 'BACK_TO_TOWN')
    s.full = true                                -- a hard need shows up while still trapped
    s.tick(6.5)                                  -- channel interrupted: buff still present
    eq(#s.teleports, 2, 'second teleport within 7 s')
    eq(#s.triggers, 0, 'Alfred with-teleport started from inside the trap')
    eq(s.tracker.needs_salvage, false)
    s.tick(6.5)
    eq(#s.teleports, 3, 'keeps retrying on the 6 s debounce')
end)

case('HLT-3 give-up with salvage off still retries instead of parking in BACK_TO_TOWN', function()
    local s = session({salvage = false})
    s.tick(1)
    s.bm.giving_up = true
    s.tick(7)
    eq(#s.teleports, 2)
end)

case('HLT-8 the give-up teleport and its retries wait for an active Looter pickup', function()
    local s = session()
    s.tick(1)
    s.looting = true
    s.bm.giving_up = true
    s.tick(3)
    eq(#s.teleports, 0, 'give-up teleport abandoned the Looter pickup')
    s.looting = false
    s.tick(0.2)
    eq(#s.teleports, 1)
    s.looting = true
    s.tick(8)
    eq(#s.teleports, 1, 'retry while the Looter collects')
    s.looting = false
    s.tick(0.2)
    eq(#s.teleports, 2)
end)

-- ── HLT-4 / HLT-8: off-window idle trip ───────────────────────────────────
case('HLT-4 minute 55-59: HR teleports first; salvage only after arrival and only for a hard need', function()
    local s = session({salvage = true, minute = 56, in_helltide = false, zone = 'Scos_Coast'})
    s.full = true
    alfred(s, function(st)
        return {enabled = true, need_trigger = true, inventory_full = st.full, need_repair = false,
            trigger_tasks = st.alfred_busy == true}
    end)
    s.tick(2)
    eq(#s.teleports, 1, 'HR idle teleport')
    eq(#s.triggers, 0, 'Alfred started a second mover during our channel')
    s.zone = TOWN_ZONE
    s.tick(2)
    eq(#s.triggers, 1, 'hard need serviced after arrival')
    eq(#s.teleports, 1, 'one mover at a time')

    local a = session({salvage = true, minute = 56, in_helltide = false, zone = TOWN_ZONE})
    alfred(a, function() return {enabled = true, need_trigger = true, inventory_full = false, need_repair = false} end)
    a.tick(10)
    eq(#a.triggers, 0, 'advisory restock cost an off-window trip')
end)

-- A5-2 (round-5 policy check, guard): HelltideRevamped never starts an
-- advisory-only Alfred trip anywhere. In town at activity start only
-- tracker.needs_salvage (set for hard needs) triggers; inside a helltide
-- advisory flags never do (R12). The policy "WarPigs enabled => advisory
-- idle" therefore needs no HR change. Pinned with WarPigs enabled (alfred_idle
-- false) and standalone.
case('A5-2 guard: a sticky advisory flag starts no HR trip in town or in the helltide, with or without WarPigs', function()
    for _, with_wp in ipairs({true, false}) do
        local label = with_wp and 'WarPigs enabled' or 'standalone'
        local s = session({salvage = true, in_helltide = false, zone = TOWN_ZONE})
        if with_wp then
            s.env.WarPigsPlugin = {status = function() return {enabled = true, alfred_idle = false} end}
        end
        alfred(s, function(st)
            return {enabled = true, need_trigger = true, inventory_full = st.full == true, need_repair = false,
                trigger_tasks = st.alfred_busy == true, restock_count = 2}
        end)
        s.tick(30)                                   -- activity start in town
        eq(#s.triggers, 0, label .. ': advisory trip in town')
        eq(s.tracker.needs_salvage, false, label .. ': an advisory need never sets the town request')
        s.in_helltide, s.zone = true, 'Scos_Coast'
        s.tick(60)
        eq(#s.triggers, 0, label .. ': advisory trip from inside the helltide')
        s.full = true
        s.tick(0.5)
        eq(#s.triggers, 1, label .. ': a hard need still triggers at once')
    end
end)

case('HLT-8 search teleports wait for the Looter (bounded 20 s)', function()
    local s = session({minute = 56, in_helltide = false, zone = 'Scos_Coast'})
    s.looting = true
    s.tick(10)
    eq(#s.teleports, 0, 'idle-town teleport while the Looter collects the chest drop')
    s.looting = false
    s.tick(0.3)
    eq(#s.teleports, 1, 'teleports once the Looter is idle')

    local b = session({minute = 56, in_helltide = false, zone = 'Scos_Coast'})
    b.looting = true
    b.tick(19)
    eq(#b.teleports, 0)
    b.tick(2)
    eq(#b.teleports, 1, 'bounded: a Looter that never idles cannot pin the search')
    eq(b.logged('teleporting anyway'), 1)

    local c = session({minute = 10, in_helltide = false, zone = 'Scos_Coast'})
    c.looting = true
    c.tick(5)
    eq(#c.teleports, 0, 'search-cycle teleport while looting')
    c.looting = false
    c.tick(0.5)
    eq(#c.teleports, 1)
end)

-- ── HLT-7: fresh external arrival (needs live confirmation) ───────────────
case('HLT-7 external enable without the buff: bounded grace before search teleports away', function()
    local s = session({in_helltide = false, zone = 'Skov_Skartara'})
    s.load_main()
    s.plugin.enable()
    s.tick(10)
    eq(#s.teleports, 0, 'WarPigs arrival undone immediately')
    eq(s.logged('External enable in Sanctuary_Eastern_Continent/Skov_Skartara'), 1, 'diagnostic logged once')
    s.tick(6.5)
    ok(#s.teleports >= 1, 'grace is bounded')
    eq(s.logged('Still no helltide buff'), 1)

    local b = session({in_helltide = false, zone = 'Skov_Ferry'})
    b.load_main()
    b.plugin.enable()
    b.tick(5)
    b.in_helltide = true
    b.tick(20)
    eq(#b.teleports, 0, 'buff applied inside the grace: no teleport at all')
    ok((b.task_ticks.helltide or 0) > 100, 'helltide task farms the landing zone')

    local m = session({in_helltide = false, zone = 'Scos_Coast', enabled = true})
    m.load_main()
    m.tick(2)
    eq(#m.teleports, 1, 'a manual (already enabled) session searches at once')
end)

-- ── HLT-5: Batmobile exploration per session ──────────────────────────────
case('HLT-5 direct entry into a helltide resets Batmobile exploration once per session', function()
    local s = session()
    s.tick(1)
    eq(s.bm.resets, 1, 'first tick of the session resets Batmobile')
    s.looting = true; s.tick(2); s.looting = false
    s.tick(5)
    eq(s.bm.resets, 1, 'no reset mid-session')
    s.tm.stop()
    eq(s.bm.resets, 1, 'cancel does not reset another owner')
    s.tick(1)
    eq(s.bm.resets, 2, 'next session starts clean')
end)

-- ── HLT-6 / C4: orbwalker release ─────────────────────────────────────────
case('HLT-6 disabling HR restores orbwalker clear (cinder gate) and unblocks movement', function()
    local s = session({enabled = true, manage_orbwalker = true, cinders = 200})
    s.load_main()
    s.tick(1)
    eq(s.orb.clear, false, 'cinder gate forced clear OFF above 150')
    s.orb.block = true
    s.plugin.disable()
    eq(s.orb.clear, true, 'clear left OFF for the next activity')
    eq(s.orb.block, false)
    local other = session({enabled = true, manage_orbwalker = false, cinders = 200})
    other.load_main(); other.tick(1); other.orb.clear = false
    other.plugin.disable()
    eq(other.orb.clear, false, 'an unmanaged orbwalker is never touched')
end)

-- R13 (C4/L12b): a state HR forced is handed back even after 'Manage
-- orbwalker' was switched off mid-run (like WonderCity's orb_forced).
case('R13/L12b disable after Manage orbwalker is unticked still restores the clear OFF / block ON HR forced', function()
    local s = session({enabled = true, manage_orbwalker = true, cinders = 200})
    s.load_main()
    s.tick(1)
    eq(s.orb.clear, false, 'cinder gate forced clear OFF above 150')
    s.settings.orb_set_block(true)
    eq(s.orb.block, true, 'HR blocked movement')
    s.controls.manage_orbwalker:set(false)       -- unticked; no HR tick before the exit
    s.plugin.disable()
    eq(s.settings.manage_orbwalker, false)
    eq(s.orb.clear, true, 'forced clear OFF survived the release')
    eq(s.orb.block, false, 'forced block ON survived the release')
end)

case('R13/L12b unticked mid-run: the forced clear is handed back, suspend unblocks, then HR leaves the orbwalker alone', function()
    local t = session({enabled = true, manage_orbwalker = true, cinders = 200})
    t.load_main()
    t.tick(1)
    eq(t.orb.clear, false)
    t.settings.orb_set_block(true)
    t.controls.manage_orbwalker:set(false)
    t.tick(1)
    eq(t.orb.clear, true, 'the gate left its forced clear OFF after management was switched off')
    eq(t.orb.block, true, 'block is released on exit, not mid-run')
    t.in_helltide = false                        -- task switch to search: suspend
    t.tick(0.5)
    eq(t.orb.block, false, 'suspend left a forced block ON behind')

    -- Once handed back, an unmanaged orbwalker is never touched again.
    t.orb.clear, t.orb.block = false, true       -- the user's own choice
    t.in_helltide = true
    t.tick(1)
    t.plugin.disable()
    eq(t.orb.clear, false, 'unmanaged clear overwritten after the hand-back')
    eq(t.orb.block, true, 'unmanaged block overwritten after the hand-back')
end)

-- ── HLT-9: traversal routing ──────────────────────────────────────────────
case('HLT-9 MOVING_TO_TRAVERSAL drops the stale patrol goal so Batmobile can select the traversal', function()
    local s = session({prioritize_traversals = true})
    s.actors = {}
    s.tick(0.5)
    s.bm.target = v(40, 40, 0)                   -- earlier custom patrol goal
    s.actors = {actor('Traversal_Gizmo_Ladder', 20, 0)}
    s.tick(1.5)
    eq(s.helltide.current_state, 'MOVING_TO_TRAVERSAL')
    eq(s.bm.target, nil, 'patrol custom goal still steers Batmobile')
    eq(s.bm.paused, false, 'Batmobile runs its own selection')
end)

-- ── C3: Batmobile release on HR exit paths ────────────────────────────────
case('C3 HR release paths call BatmobilePlugin.release(helltide_revamped)', function()
    local s = session({release = true})
    s.tick(1)
    s.tm.stop()
    ok(#s.bm.releases >= 1, 'no release on disable')
    for _, caller in ipairs(s.bm.releases) do eq(caller, 'helltide_revamped') end
    local before = #s.bm.releases
    s.in_helltide = false                        -- task switch to search
    s.tick(0.5)
    ok(#s.bm.releases > before, 'no release on task switch-away')
end)

-- ── C6: long companion holds are published and logged ─────────────────────
case('C6 a Looter hold over a minute is logged once a minute and published in status', function()
    local s = session({enabled = true})
    s.load_main()
    s.tick(1)
    s.looting = true
    s.tick(70)
    eq(s.logged('Holding for 60s: waiting for Looter to finish'), 1)
    eq(s.plugin.status().hold, 'waiting for Looter to finish')
    s.looting = false
    s.tick(0.5)
    eq(s.plugin.status().hold, nil)

    local a = session({enabled = true, salvage = true})
    a.load_main()
    a.alfred_live = true
    alfred(a, function(st) return {enabled = true, trigger_tasks = st.alfred_live, external_caller = 'WarPigs'} end)
    a.tick(70)
    eq(a.plugin.status().hold, 'Alfred busy', 'a long foreign Alfred trip is published')
    eq(a.logged('holding for 60s: Alfred busy'), 1, 'and logged once a minute')
    eq(#a.triggers, 0, 'a live foreign trip is never replaced')
    a.alfred_live = false
    a.tick(1)
    eq(a.plugin.status().hold, nil)
end)

print(string.format('Helltide integration: %d cases, %d checks, %d failures', cases, checks, #failures))
if #failures > 0 then error('Helltide integration failures:\n' .. table.concat(failures, '\n')) end
print('PASS: test_integration_helltide (' .. cases .. ' cases)')
