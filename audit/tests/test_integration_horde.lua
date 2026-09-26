-- Integration regressions for HordeDev (InfernalHordesPlugin): terminal chest
-- faults and the exit leave path (HRD-1), latched transactions, revive and
-- restart (HRD-4), the C2 status contract (in_run/fault, CRT-2), the Alfred
-- return window (HRD-5), use_alfred and bounded unknown Alfred status (HRD-6),
-- keybind-aware enabled (HRD-7), teleport re-fire debounces (HRD-8/HRD-10),
-- the Pit fallback (HRD-9), the C1 teleport latch (WPT-1), captured modules
-- instead of undefined globals, C5 yield accounting, and round 3: C2
-- exit_pending (R7), external control with an unbound keybind and re-enable
-- without a reset (R8), and the bounded paused-Alfred holds (C1); round 4:
-- keep_run_on_enable keeps a run only where it is (F-H3, the round-3 critic's
-- hotkey probe as a joint regression, War Plan entry off and on), no
-- advisory-only Alfred trip at activity start under WarPigs (F-H4) and the
-- War Plan entry end to end with the real WarPigs (R4 joint); round 5: the
-- keep rule also keeps HordeDev's own built-in Cerrigar salvage trip and a
-- pause keeps its flags (H5-3), under WarPigs an advisory-only flag never
-- starts a HordeDev Alfred trip at the gate whatever WarPigs' alfred_idle
-- (H5-4), and the hotkey-pause joint cases hold whether WarPigs treats the
-- pause as a pause or as a self-disable. The real HordeDev plugin is loaded
-- in an isolated environment with QQT-shaped host mocks; the joint cases
-- also load the real WarPigs orchestrator.
local ROOT = assert(SUITE_ROOT) .. '/HordeDev-1.3.9/'
local WROOT = SUITE_ROOT .. '/WarPigs-1.0.0/'
local checks, failures = 0, {}
local function eq(a, b, message)
    if a ~= b then error((message or 'mismatch') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
    checks = checks + 1
end
local function truthy(value, message)
    if not value then error(message or 'expected a true value', 2) end
    checks = checks + 1
end
local function case(name, run)
    local ok, err = pcall(run)
    if not ok then failures[#failures + 1] = name .. ': ' .. tostring(err) end
end

local vec = {}; vec.__index = vec
function vec:new(x, y, z) return setmetatable({_x = x or 0, _y = y or 0, _z = z or 0}, vec) end
function vec:x() return self._x end
function vec:y() return self._y end
function vec:z() return self._z end
function vec:dist_to(p) return math.sqrt((self._x - p:x()) ^ 2 + (self._y - p:y()) ^ 2 + (self._z - p:z()) ^ 2) end
function vec:dist_to_ignore_z(p) return math.sqrt((self._x - p:x()) ^ 2 + (self._y - p:y()) ^ 2) end
function vec:is_zero() return self._x == 0 and self._y == 0 and self._z == 0 end

local function widget(value)
    local w = {v = value, state = 0, key = 0x0A}
    function w:get() return self.v end
    function w:set(v) self.v = v; if type(v) == 'boolean' then self.state = v and 1 or 0 end end
    function w:render() end
    function w:push() return false end
    function w:pop() end
    function w:get_key() return self.key end
    function w:get_state() return self.state end
    return w
end

local function actor(name, x, y, opts)
    opts = opts or {}
    local a = {name = name, pos = vec:new(x or 0, y or 0, 0), interactable = opts.interactable ~= false,
        health = opts.health or 10, enemy = opts.enemy == true}
    function a:get_skin_name() return self.name end
    function a:get_position() return self.pos end
    function a:is_interactable() return self.interactable end
    function a:get_current_health() return self.health end
    function a:is_enemy() return self.enemy end
    function a:is_boss() return false end
    function a:is_elite() return false end
    function a:is_champion() return false end
    return a
end

-- Full HordeDev: real main.lua, gui.lua, core/*, tasks/*; only the host is mocked.
local function horde(opts)
    opts = opts or {}
    local s = {now = 100, aether = opts.aether or 0, world = 'S05_BSK_Prototype02', zone = 'S05_BSK_Prototype02',
        id = 1, pos = vec:new(0, 0, 0), actors = {}, interactions = {}, logs = {}, teleports = {}, stamps = {},
        updates = {}, item_count = 0, dead = false, leaves = 0, resets = 0, revives = 0, keys = {}}
    local player = {
        get_position = function() return s.pos end,
        is_dead = function() return s.dead end,
        get_item_count = function() return s.item_count end,
        get_buffs = function() return {} end,
        get_character_class_id = function() return 0 end,
        is_spell_ready = function() return false end,
        get_move_destination = function() return s.pos end,
        is_moving = function() return false end,
        get_dungeon_key_items = function() return s.keys end,
        get_inventory_items = function() return {} end,
        get_active_spell_id = function() return s.casting and 186139 or 0 end,
        get_attribute = function() return s.in_town and 1 or 0 end,
    }
    local world = {
        get_name = function() return s.world end,
        get_current_zone_name = function() return s.zone end,
        get_world_id = function() return s.id end,
    }
    local env = {
        vec3 = vec, vec2 = vec,
        get_hash = function(x) return x end,
        checkbox = {new = function(_, v) return widget(v) end},
        slider_int = {new = function(_, _, _, d) return widget(d) end},
        slider_float = {new = function(_, _, _, d) return widget(d) end},
        combo_box = {new = function(_, d) return widget(d) end},
        keybind = {new = function(_, key) local w = widget(false); w.key = key; return w end},
        tree_node = {new = function() return widget(false) end},
        console = {print = function(m) s.logs[#s.logs + 1] = tostring(m) end},
        get_time_since_inject = function() return s.now end,
        get_local_player = function() return player end,
        get_player_position = function() return s.pos end,
        get_current_world = function() return world end,
        actors_manager = {get_all_actors = function() return s.actors end},
        loot_manager = {any_item_around = function() return false end},
        interact_object = function(a) s.interactions[#s.interactions + 1] = a and a.name; return true end,
        teleport_to_waypoint = function(id)
            s.teleports[#s.teleports + 1] = id; s.stamps[#s.stamps + 1] = s.now
            if s.on_teleport then s.on_teleport(id) end
        end,
        pathfinder = {request_move = function() end, force_move_raw = function() end, clear_stored_path = function() end},
        utility = {set_height_of_valid_position = function(p) return p end, is_point_walkeable = function() return true end},
        evade = {register_circular_spell = function() end, is_dangerous_position = function() return false end},
        color = {new = function() return {} end}, danger_level = {high = 3},
        color_white = function() return {} end, color_red = function() return {} end, color_green = function() return {} end,
        color_yellow = function() return {} end, color_orange = function() return {} end,
        graphics = {text_3d = function() end, text_2d = function() end},
        target_selector = {is_valid_enemy = function(a) return a.enemy and a.health > 1 end, get_near_target_list = function() return {} end},
        orbwalker = {get_orb_mode = function() return 0 end, set_clear_toggle = function() end},
        revive_at_checkpoint = function() s.revives = s.revives + 1 end,
        on_update = function(fn) s.updates[#s.updates + 1] = fn end,
        on_render = function() end, on_render_menu = function() end,
        leave_dungeon = function()
            s.leaves = s.leaves + 1
            if s.on_leave then s.on_leave() end
        end,
        reset_all_dungeons = function() s.resets = s.resets + 1 end,
        use_item = function() s.used = (s.used or 0) + 1 end,
        cast_spell = {position = function() return false end},
        get_quests = function() return {} end,
        os = os, math = math, string = string, table = table, pairs = pairs, ipairs = ipairs, type = type,
        tostring = tostring, tonumber = tonumber, pcall = pcall, error = error, assert = assert, next = next,
        setmetatable = setmetatable, getmetatable = getmetatable, select = select, rawget = rawget,
        print = function() end,
    }
    env.get_aether_count = function() return s.aether end
    for k, v in pairs(opts.globals or {}) do env[k] = v end
    env._G = env
    local loaded = {}
    env.require = function(name)
        if loaded[name] ~= nil then return loaded[name] end
        local chunk = assert(loadfile(ROOT .. name:gsub('%.', '/') .. '.lua', 't', env))
        local result = chunk()
        if result == nil then result = true end
        loaded[name] = result
        return result
    end
    env.package = {loaded = loaded}
    assert(loadfile(ROOT .. 'main.lua', 't', env))()
    s.env, s.loaded, s.P = env, loaded, env.InfernalHordesPlugin
    s.gui = loaded.gui
    function s:tick(dt)
        self.now = self.now + (dt or 0.2)
        for _, fn in ipairs(self.updates) do fn() end
    end
    function s:run(seconds, dt, each)
        dt = dt or 0.2
        for _ = 1, math.floor(seconds / dt + 0.5) do
            self:tick(dt)
            if each then each() end
        end
    end
    function s:task_name() return self.P.status().task.name end
    function s:outside() self.world, self.zone, self.id = 'Sanctuary', 'Kehj_Caldeum', self.id + 1 end
    function s:town(zone) self.world, self.zone, self.id, self.in_town = 'Sanctuary', zone or 'Skov_Temis', self.id + 1, true end
    function s:logged(text)
        local n = 0
        for _, m in ipairs(self.logs) do if m:find(text, 1, true) then n = n + 1 end end
        return n
    end
    return s
end

local function chest_room(s, materials_open, gold_open)
    s.actors = {
        actor('BSK_UniqueOpChest_Materials', 0.5, 0, {interactable = materials_open}),
        actor('BSK_UniqueOpChest_Gold', 1.0, 0, {interactable = gold_open}),
        actor('Stash', 1.5, 0),
    }
end

-- ── HRD-1: a chest fault is terminal and the Horde is left ────────────────
case('HRD-1 unspendable aether publishes a fault and leaves through the RESET exit', function()
    local s = horde({aether = 30})
    s.P.enable()
    chest_room(s, false, false)
    s.on_leave = function() s.outside_at = s.now + 2 end
    s:run(60, 0.2, function() if s.outside_at and s.now >= s.outside_at then s.outside_at = nil; s:outside() end end)
    local st = s.P.status()
    truthy(s.leaves >= 1, 'Leave Dungeon was attempted with the unspendable aether')
    truthy(type(st.fault) == 'string' and st.fault:find('chests:', 1, true), 'status().fault names the chest fault')
    eq(s.loaded['tasks.open_chests'].current_state, 'FAULT')
    s:run(10)
    eq(s.resets, 1, 'RESET sent outside the Horde')
    eq(s.P.chests_done(), true, 'handoff signal after the faulted run left BSK')
    eq(s.P.status().in_run, false, 'no longer committed to the horde')
    truthy(s.P.getState() ~= 'OPENING_CHESTS', 'no longer reported as opening chests')
    s.P.enable()
    eq(s.P.status().fault, nil, 'a fresh enable clears the chest fault')
end)

case('HRD-1 teleport exit also leaves after a chest fault', function()
    local s = horde({aether = 30})
    s.P.enable(); s.P.setSettings('exit_mode', 1)
    chest_room(s, false, false)
    s:run(60)
    truthy(#s.teleports >= 1, 'teleport exit fired despite the unspendable aether')
    s:outside(); s.zone = 'Library_Zone'; s:run(1)
    eq(s.P.status().in_run, false)
end)

-- ── HRD-4: revive during a pending transaction; restart clears latches ─────
case('HRD-4 death during the pending RESET revives and does not time the exit out', function()
    local s = horde({aether = 0})
    s.P.enable()
    s.actors = {actor('Stash', 1.5, 0)}
    s.loaded['core.tracker'].finished_chest_looting = true
    s:run(1)
    eq(s.loaded['core.tracker'].reset_exit_pending, true, 'RESET committed')
    s.dead = true
    s:run(90)
    truthy(s.revives >= 1, 'revive_at_checkpoint called while the RESET was pending')
    eq(s.loaded['tasks.exit_horde'].reset_phase ~= 'FAULT', true, 'dead time does not count toward the exit timeout')
    s.dead = false
    s.on_leave = function() s.outside_at = s.now + 2 end
    s:run(20, 0.2, function() if s.outside_at and s.now >= s.outside_at then s.outside_at = nil; s:outside() end end)
    eq(s.loaded['tasks.exit_horde'].reset_phase, 'DONE', 'RESET finishes after the revive')
    eq(s.P.chests_done(), true)
end)

case('HRD-4 a latched exit FAULT is published and cleared by the GUI toggle', function()
    local s = horde({aether = 0})
    s.P.enable()
    s.actors = {actor('Stash', 1.5, 0)}
    s.loaded['core.tracker'].finished_chest_looting = true
    s:run(45) -- three Leave attempts that never leave BSK
    local st = s.P.status()
    truthy(type(st.fault) == 'string' and st.fault:find('exit:', 1, true), 'exit fault published: ' .. tostring(st.fault))
    eq(st.in_run, true)
    s:run(60)
    eq(s.loaded['core.tracker'].reset_exit_pending, true, 'still latched without a restart')
    s.gui.elements.main_toggle:set(false); s:run(1)
    s.gui.elements.main_toggle:set(true); s:run(1)
    eq(s.P.status().fault, nil, 'toggle off/on clears the latched fault')
    eq(s.loaded['core.tracker'].reset_exit_pending, false, 'pending RESET released')
    eq(s:logged('Clearing latched fault on stop'), 1)
end)

case('HRD-4 an incomplete sigil state is cleared by WarPigs-style disable/enable and by the toggle', function()
    local s = horde({aether = 0})
    s.P.enable(); s:outside()
    s.actors = {actor('QST_Caldeum_GatesToHell_Seal', 3, 0)} -- at the gate: no walking
    local tr = s.loaded['core.tracker']
    tr.sigil_used = true
    s:run(8)
    local st = s.P.status()
    truthy(type(st.fault) == 'string' and st.fault:find('entry:', 1, true), 'start fault published: ' .. tostring(st.fault))
    s.P.disable()
    eq(tr.sigil_activation_pending, false, 'disable() clears the latched start transaction')
    eq(tr.sigil_used, false)
    eq(s.P.status().fault, nil)
    -- healthy pending transactions survive a pause
    s.P.enable(); s:outside(); tr.reset_exit_pending = true
    s.loaded['tasks.exit_horde'].reset_started = s.now
    s.gui.elements.main_toggle:set(false); s:run(1); s.gui.elements.main_toggle:set(true); s:run(0.2)
    eq(tr.reset_exit_pending, true, 'a pause keeps a healthy RESET')
end)

-- ── C2 / CRT-2: status contract ────────────────────────────────────────────
case('C2 in_run is false for an idle HordeDev in town and true once committed', function()
    local s = horde({aether = 0})
    s:town('Skov_Temis')
    s.P.enable(); s:run(1)
    local st = s.P.status()
    eq(st.enabled, true); eq(st.in_run, false, 'enabled in town (persisted toggle) is not a run'); eq(st.fault, nil)
    s.loaded['core.tracker'].sigil_activation_pending = true
    eq(s.P.status().in_run, true, 'sigil activation pending')
    s.loaded['core.tracker'].sigil_activation_pending = false
    s.loaded['core.tracker'].horde_opened = true
    eq(s.P.status().in_run, true, 'portal opened, not yet entered')
    s.loaded['core.tracker'].horde_opened = false
    s.world, s.zone = 'S05_BSK_Prototype02', 'S05_BSK_Prototype02'
    eq(s.P.status().in_run, true, 'inside the Horde')
end)

-- ── HRD-5: Alfred callback before the return portal ────────────────────────
local function mid_chest_trip(st)
    local cb
    local alfred = {get_status = function() return st end,
        trigger_tasks_with_teleport = function(_, fn) cb = fn; st.trigger_tasks = true; return true end}
    local s = horde({aether = 40, globals = {AlfredTheButlerPlugin = alfred}})
    s.P.enable()
    chest_room(s, true, true)
    s:run(20)
    eq(s:task_name(), 'alfred_running'); eq(s.loaded['tasks.open_chests'].current_state, 'PAUSED_FOR_SALVAGE')
    truthy(cb ~= nil, 'HordeDev requested the salvage trip')
    eq(s.P.status().alfred_trip, true); eq(s.P.status().in_run, true)
    s:town('Skov_Temis'); s.actors = {}
    s:run(10)
    return s, function() cb() end
end

case('HRD-5 callback in town before the return portal: no Library teleport inside the window', function()
    local st = {enabled = true, need_trigger = true, trigger_tasks = false}
    local s, callback = mid_chest_trip(st)
    st.trigger_tasks, st.need_trigger = false, false
    callback()
    s:run(15)
    eq(#s.teleports, 0, 'nothing teleports away while the return portal may still come')
    eq(s:task_name(), 'alfred_running')
    eq(s.P.status().in_run, true)
    eq(s:logged('callback arrived outside the Horde'), 1, 'one diagnostic line')
    s:run(10)
    local fault = s.P.status().fault
    truthy(type(fault) == 'string' and fault:find('Alfred trip ended outside the Horde', 1, true),
        'window expiry reports the lost chest run: ' .. tostring(fault))
end)

case('HRD-5 live Alfred work after the callback keeps the hold without consuming the window', function()
    local st = {enabled = true, need_trigger = true, trigger_tasks = false}
    local s, callback = mid_chest_trip(st)
    st.trigger_tasks, st.need_trigger = false, false
    st.teleport = true -- return portal step still running after the callback
    callback()
    s:run(60)
    eq(#s.teleports, 0, 'no teleport while Alfred still owns the return')
    s.world, s.zone = 'S05_BSK_Prototype02', 'S05_BSK_Prototype02'
    st.teleport_done = true
    chest_room(s, true, true)
    s:run(10)
    eq(s.P.status().fault, nil, 'the chest run resumes after the return')
    eq(s.loaded['core.tracker'].has_salvaged, false, 'return_from_salvage consumed the trip')
end)

case('HRD-5 built-in Cerrigar salvage does not run after a delegated Alfred trip', function()
    local st = {enabled = true, need_trigger = false}
    local s = horde({aether = 0, globals = {AlfredTheButlerPlugin = {get_status = function() return st end}}})
    s.P.enable(); s:town('Scos_Cerrigar')
    local tr = s.loaded['core.tracker']
    tr.has_salvaged = true
    eq(s.loaded['tasks.town_salvage'].shouldExecute(), false, 'Alfred owns the town work')
    st.enabled = false
    eq(s.loaded['tasks.town_salvage'].shouldExecute(), true, 'built-in path when Alfred is disabled')
end)

-- ── HRD-6: use_alfred first; bounded unknown status ────────────────────────
case('HRD-6 odd Alfred status with use_alfred off never stalls the wave', function()
    local alfred = {get_status = function() return {enabled = 1} end}
    local s = horde({aether = 0, globals = {AlfredTheButlerPlugin = alfred}})
    s.P.enable(); s.P.setSettings('use_alfred', false)
    s.actors = {actor('Monster', 5, 0, {enemy = true, health = 100})}
    s:run(5)
    eq(s:task_name(), 'Infernal Horde')
end)

case('HRD-6 unreadable Alfred status holds at most ~10 s, logged once', function()
    local alfred = {get_status = function() error('reloading') end}
    local s = horde({aether = 0, globals = {AlfredTheButlerPlugin = alfred}})
    s.P.enable()
    s.actors = {actor('Monster', 5, 0, {enemy = true, health = 100})}
    s:run(5)
    eq(s:task_name(), 'alfred_running', 'short hold while the status is unknown')
    s:run(8)
    eq(s:task_name(), 'Infernal Horde', 'unknown status stops holding after the bound')
    eq(s:logged('Alfred status unreadable'), 1)
    s:run(30)
    eq(s:logged('Alfred status unreadable'), 1, 'logged once')
end)

case('HRD-6 a salvage pause resumes when Alfred becomes unreadable and the bag is not full', function()
    local st = {enabled = true, need_trigger = true}
    local broken = false
    local alfred = {get_status = function() if broken then error('reloading') end return st end,
        trigger_tasks_with_teleport = function() st.trigger_tasks = true; return true end}
    local s = horde({aether = 40, globals = {AlfredTheButlerPlugin = alfred}})
    s.P.enable()
    chest_room(s, true, true)
    s:run(20)
    eq(s.loaded['tasks.open_chests'].current_state, 'PAUSED_FOR_SALVAGE')
    broken = true
    s:run(30)
    truthy(s.loaded['tasks.open_chests'].current_state ~= 'PAUSED_FOR_SALVAGE', 'chests resume without a salvage owner')
    eq(s:logged('No salvage owner available'), 1)
    eq(s.loaded['core.tracker'].needs_salvage, false)
end)

-- ── HRD-7: keybind-aware enabled ───────────────────────────────────────────
case('HRD-7 status().enabled includes the keybind gate', function()
    local s = horde({aether = 0})
    s.P.enable()
    s.gui.elements.use_keybind:set(true); s.gui.elements.keybind_toggle.key = 0x70; s.gui.elements.keybind_toggle.state = 0
    s:run(1)
    eq(s.P.status().enabled, false, 'paused by hotkey')
    s.gui.elements.keybind_toggle.state = 1; s:run(0.2)
    eq(s.P.status().enabled, true)
end)

-- ── HRD-8: built-in salvage never re-fires into its own channel ────────────
case('HRD-8 built-in salvage teleports are at least 6 s apart and skip while casting', function()
    local s = horde({aether = 40})
    s.P.enable()
    s.item_count = 33
    chest_room(s, true, true)
    s:run(40)
    truthy(#s.stamps >= 2, 'salvage teleport retried: ' .. #s.stamps)
    for i = 2, #s.stamps do
        truthy(s.stamps[i] - s.stamps[i - 1] >= 6 - 1e-6, string.format('gap %.1f s between teleport %d and %d', s.stamps[i] - s.stamps[i - 1], i - 1, i))
    end
    local before = #s.stamps
    s.casting = true
    s:run(12)
    truthy(#s.stamps - before <= 1, 'no repeated re-fire while the channel casts')
end)

-- ── HRD-9: Pit fallback ────────────────────────────────────────────────────
local function out_of_compasses(globals)
    local s = horde({aether = 0, globals = globals})
    s.P.enable(); s.P.setSettings('run_pit', true); s.P.setSettings('use_alfred', false)
    s:outside()
    s.actors = {actor('QST_Caldeum_GatesToHell_Seal', 3, 0)} -- at the gate: no walking
    s:run(15)
    return s
end

case('HRD-9 Run pit starts ArkhamAsylumPlugin when WarPigs is not managing', function()
    local pit = {enables = 0}; pit.enable = function() pit.enables = pit.enables + 1 end
    local s = out_of_compasses({ArkhamAsylumPlugin = pit})
    eq(pit.enables >= 1, true, 'ArkhamAsylumPlugin.enable called')
    eq(s.P.status().enabled, false, 'HordeDev handed off to the Pit')
end)

case('HRD-9 Run pit is skipped while WarPigs is on', function()
    local pit = {enables = 0}; pit.enable = function() pit.enables = pit.enables + 1 end
    local wp = {status = function() return {enabled = true} end}
    local s = out_of_compasses({ArkhamAsylumPlugin = pit, WarPigsPlugin = wp})
    eq(pit.enables, 0, 'WarPigs owns activity handoffs')
    eq(s.P.status().enabled, true)
    eq(s:logged("'Run pit' skipped"), 1)
end)

-- ── WPT-1 / C1: teleport latch ─────────────────────────────────────────────
case('WPT-1 latched teleport is not work for is_inventory_full or movement ownership', function()
    local st = {enabled = true, teleport = true, teleport_done = true, inventory_full = false, restock_count = 0, need_repair = false}
    local s = horde({aether = 0, globals = {PLUGIN_alfred_the_butler = {get_status = function() return st end}}})
    local utils, guard = s.loaded['core.utils'], s.loaded['core.loot_guard']
    eq(utils.is_inventory_full(), false, 'finished trip latch')
    st.teleport_done, st.teleport_failed = nil, true
    eq(utils.is_inventory_full(), false, 'failed trip latch')
    eq(guard.companion_may_own_movement(), false, 'failed trip latch does not own movement')
    st.teleport_failed = nil
    eq(utils.is_inventory_full(), true, 'a live teleport still counts')
    eq(guard.companion_may_own_movement(), true)
end)

case('C1 advisory need_trigger cannot re-pause chests inside the sticky grace; a hard need can', function()
    local st = {enabled = true, need_trigger = true}
    local s = horde({aether = 40, globals = {AlfredTheButlerPlugin = {get_status = function() return st end}}})
    s.P.enable()
    local utils, tr = s.loaded['core.utils'], s.loaded['core.tracker']
    tr.alfred_completed_at = s.now
    eq(utils.alfred_trip_wanted(st, tr.alfred_completed_at), false, 'sticky advisory flag inside the grace')
    st.inventory_full = true
    eq(utils.alfred_trip_wanted(st, tr.alfred_completed_at), true, 'hard need')
    st.inventory_full = false; s.now = s.now + 31
    eq(utils.alfred_trip_wanted(st, tr.alfred_completed_at), true, 'after the grace')
    s.loaded['tasks.alfred'].reset()
    eq(tr.alfred_completed_at ~= nil, true, 'cancel/reset keeps the grace')
end)

-- ── undefined globals ──────────────────────────────────────────────────────
case('navigation helpers use captured modules, not undefined globals', function()
    local s = horde({aether = 0})
    local nav = s.env.require('core.navigation')
    truthy(pcall(function() nav:pathfind_to(vec:new(1, 2, 0)) end), 'pathfind_to without an explorer global')
    truthy(pcall(s.loaded['core.utils'].navigate_to, vec:new(1, 2, 0)), 'navigate_to without a navigation global')
end)

-- ── C5: yield time is not "no progress" ────────────────────────────────────
case('C5 walking watchdog does not count time spent yielding to Alfred', function()
    local st = {enabled = true}
    local s = horde({aether = 0, globals = {AlfredTheButlerPlugin = {get_status = function() return st end}}})
    s.P.enable(); s:outside()
    s.loaded['core.tracker'].teleported_from_town = true
    s:run(6)
    eq(s:task_name(), 'Walking to Horde')
    st.trigger_tasks = true -- another caller's Alfred work owns the queue
    s:run(20)
    eq(s:task_name(), 'alfred_running')
    st.trigger_tasks = false
    s:run(3)
    eq(s:logged('STAGE 3'), 0, 'resume after the yield does not re-teleport at once')
end)

case('C5 Bartuc pylon give-up window excludes preemption time', function()
    local st = {enabled = true}
    local s = horde({aether = 0, globals = {AlfredTheButlerPlugin = {get_status = function() return st end}}})
    s.P.enable(); s.P.setSettings('merry_go_round', false); s.P.setSettings('do_bartuc', true)
    s.actors = {actor('BSK_PylChoiceGizmo_SelectBartuc', 1, 0)}
    s:run(4)
    eq(s:logged('Interacting with Bartuc pylon'), 1, 'Bartuc attempt started')
    st.trigger_tasks = true; s:run(10); st.trigger_tasks = false
    s:run(1)
    eq(s:logged('Bartuc pylon interaction timed out'), 0, 'yield time does not exhaust the Bartuc window')
    s:run(8)
    eq(s:logged('Bartuc pylon interaction timed out'), 1, 'the real window still applies')
end)

-- ── C6: a never-idle Looter cannot hold the exit forever ───────────────────
case('C6 Looter hold is bounded and visible', function()
    local s = horde({aether = 0, globals = {LooteerPlugin = {get_enabled = function() return true end,
        is_actively_looting = function() error('broken') end}}})
    local guard = s.loaded['core.loot_guard']
    eq(guard.ready(), false)
    s.now = s.now + 60
    eq(guard.ready(), false)
    truthy(guard.hold_reason() and guard.hold_reason():find('Looter', 1, true), 'hold reason exposed')
    s.now = s.now + 61
    eq(guard.ready(), true, 'released after the bound')
    eq(s:logged('Looter busy for'), 1)
end)

case('HRD-4 a chest fault outside a pending exit is restarted by the toggle', function()
    local s = horde({aether = 0})
    s.P.enable(); s:outside()
    s.actors = {actor('QST_Caldeum_GatesToHell_Seal', 3, 0)}
    local tr = s.loaded['core.tracker']
    tr.sigil_used, tr.horde_opened, tr.has_entered = true, true, true
    tr.chest_fault, tr.finished_chest_looting = 'Alfred trip ended outside the Horde', true
    s:run(2)
    truthy(s.P.status().fault ~= nil and s.P.status().in_run == true, 'fault published while the old run is still committed')
    s.gui.elements.main_toggle:set(false); s:run(1); s.gui.elements.main_toggle:set(true); s:run(0.2)
    eq(s.P.status().fault, nil); eq(tr.sigil_used, false); eq(tr.horde_opened, false)
end)

-- ── C3: owner-aware Batmobile release ──────────────────────────────────────
case('C3 HordeDev movement release uses BatmobilePlugin.release when available', function()
    local calls = {}
    local bm = {release = function(who) calls[#calls + 1] = 'release:' .. tostring(who) end,
        stop_long_path = function() calls[#calls + 1] = 'stop_long_path' end,
        clear_target = function() calls[#calls + 1] = 'clear_target' end,
        pause = function() calls[#calls + 1] = 'pause' end}
    local s = horde({aether = 0, globals = {BatmobilePlugin = bm}})
    local m = s.loaded['core.movement']
    m.claim(true); m.stop()
    eq(#calls, 1); eq(calls[1], 'release:infernal_horde')
    bm.release = nil; calls = {}
    m.claim(true); m.stop()
    eq(table.concat(calls, ','), 'stop_long_path,clear_target,pause', 'legacy sequence without release')
end)

-- ── joint: real WarPigs orchestrator + real HordeDev ───────────────────────
local function joint(opts)
    local s = horde(opts)
    local f = {s = s, quests = {}, logs = {}}
    local e = setmetatable({}, {__index = _G}); e._G = e
    e.console = {print = function(m) f.logs[#f.logs + 1] = tostring(m) end}
    e.attributes = {PLAYER_IN_TOWN_LEVEL_AREA = 'town'}
    e.get_time_since_inject = function() return s.now end
    e.get_local_player = function() return {
        is_dead = function() return false end,
        get_attribute = function() return s.in_town and 1 or 0 end,
        get_buffs = function() return {} end,
        get_position = function() return s.pos end,
    } end
    e.get_current_world = s.env.get_current_world
    e.get_quests = function()
        local out = {}
        for _, name in ipairs(f.quests) do out[#out + 1] = {get_name = function() return name end} end
        return out
    end
    e.actors_manager = s.env.actors_manager
    e.get_player_position = function() return s.pos end
    e.teleport_to_waypoint = function(id) s.teleports[#s.teleports + 1] = 'WP:' .. tostring(id) end
    e.warplan = {teleport_to_activity = function() f.warplans = (f.warplans or 0) + 1 end}
    e.get_aether_count = s.env.get_aether_count
    e.revive_at_checkpoint = function() end
    e.loot_manager = {interact_with_object = function() end}
    e.pathfinder = {request_move = function() end}
    e.orbwalker = {set_clear_toggle = function() end, set_block_movement = function() end}
    e.InfernalHordesPlugin = s.P
    local arkham = {enabled = false, enables = 0}
    arkham.enable = function() arkham.enabled = true; arkham.enables = arkham.enables + 1 end
    arkham.disable = function() arkham.enabled = false end
    arkham.status = function() return {enabled = arkham.enabled} end
    e.ArkhamAsylumPlugin = arkham
    -- Round 4: War Plan Horde entry off unless a case asks for it (off =
    -- exactly the d275b9d behaviour).
    local settings = {enabled = true, manage_whispers = false, use_teleport_transition = false, manage_orbwalker = false,
        horde_warplan_entry = opts and opts.warplan == true or false, horde_compass_fallback = false}
    local modules = {['core.settings'] = settings,
        ['core.tasks.turn_in_rewards'] = {tick = function() end, get_state = function() return 'IDLE' end}}
    e.require = function(name)
        if modules[name] ~= nil then return modules[name] end
        modules[name] = assert(loadfile(WROOT .. name:gsub('%.', '/') .. '.lua', 't', e))()
        return modules[name]
    end
    f.o = e.require('core.orchestrator')
    f.arkham = arkham
    f.settings, f.env = settings, e
    function f.run(seconds, each)
        for i = 1, math.floor(seconds / 0.25 + 0.5) do
            s:tick(0.25)
            if i % 2 == 0 then f.o.tick() end
            if each then each() end
        end
    end
    function f.until_true(predicate, seconds, each)
        for i = 1, math.floor(seconds / 0.25 + 0.5) do
            s:tick(0.25)
            if i % 2 == 0 then f.o.tick() end
            if each then each() end
            if predicate() then return true end
        end
        return false
    end
    return f
end

case('HRD-1 joint: a faulted horde leaves BSK and WarPigs moves on to the Pit', function()
    local f = joint({aether = 30})
    local s = f.s
    f.quests = {'WarPlans_QST_InfernalHordes_BSK'}
    f.run(3)
    eq(s.P.status().enabled, true, 'WarPigs enabled HordeDev in BSK')
    f.quests = {}
    chest_room(s, false, false)
    s.on_leave = function() s.outside_at = s.now + 2 end
    local function step() if s.outside_at and s.now >= s.outside_at then s.outside_at = nil; s:outside() end end
    f.run(30, step)
    f.quests = {'WarPlans_QST_ThePit'}
    truthy(f.until_true(function() return f.arkham.enables >= 1 end, 240, step),
        'Pit started after the faulted horde (horde enabled=' .. tostring(s.P.status().enabled) .. ', leaves=' .. s.leaves .. ')')
    eq(s.P.status().enabled, false, 'HordeDev released')
    truthy(s.leaves >= 1, 'HordeDev left through its own exit')
end)

case('CRT-2 joint: an idle, persisted-on HordeDev in town is released for the Pit', function()
    local f = joint({aether = 0})
    local s = f.s
    s:town('Skov_Temis')
    s.P.enable()
    f.quests = {'WarPlans_QST_ThePit'}
    truthy(f.until_true(function() return f.arkham.enables >= 1 end, 120),
        'Pit started (horde enabled=' .. tostring(s.P.status().enabled) .. ', task=' .. s:task_name() .. ')')
    eq(s.P.status().enabled, false, 'HordeDev released')
end)

-- ── Round 3 ────────────────────────────────────────────────────────────────
local function busy_looter(get_s)
    return {get_enabled = function() return true end,
        is_actively_looting = function() return get_s().looting == true end}
end
local function leave_after(s, delay)
    s.on_leave = function() s.outside_at = s.now + (delay or 2) end
    return function() if s.outside_at and s.now >= s.outside_at then s.outside_at = nil; s:outside() end end
end

-- R7 (C2): status().exit_pending covers the exit's Looter hold and Leave/RESET.
case('R7 exit_pending covers the Looter hold and the Leave/RESET after a chest fault', function()
    local s
    s = horde({aether = 30, globals = {LooteerPlugin = busy_looter(function() return s end)}})
    s.P.enable()
    chest_room(s, false, false)
    eq(s.P.status().exit_pending, false, 'no exit while the chest phase runs')
    local fault_at
    s:run(60, 0.2, function()
        if not fault_at and s.P.status().fault then fault_at = s.now; s.looting = true end
    end)
    truthy(fault_at, 'chest fault published')
    local st = s.P.status()
    eq(s.leaves, 0, 'the Looter still holds the exit')
    eq(st.exit_pending, true, 'an exit held by the Looter is in progress')
    truthy(st.hold and st.hold:find('Looter', 1, true), 'Looter hold visible: ' .. tostring(st.hold))
    s.gui.elements.main_toggle:set(false)
    eq(s.P.status().exit_pending, false, 'a stopped HordeDev has no exit in progress')
    s.gui.elements.main_toggle:set(true)
    s.looting = false
    local step, during = leave_after(s), true
    s:run(30, 0.2, function()
        step()
        if s.loaded['core.tracker'].reset_exit_pending and s.P.status().exit_pending ~= true then during = false end
    end)
    eq(s.leaves, 1); eq(s.resets, 1, 'RESET sent outside')
    truthy(during, 'exit_pending stays true through Leave Dungeon, the outside wait and the RESET settle')
    eq(s.P.status().exit_pending, false, 'exit finished')
end)

case('R7 exit_pending: Teleport exit in flight; a latched exit FAULT is not progress', function()
    local s = horde({aether = 0})
    s.P.enable(); s.P.setSettings('exit_mode', 1)
    s.actors = {actor('Stash', 1.5, 0)}
    s.loaded['core.tracker'].finished_chest_looting = true
    s:run(1)
    truthy(#s.teleports >= 1, 'teleport exit fired')
    eq(s.P.status().exit_pending, true, 'teleport channel still in the Horde')
    s:outside(); s:run(0.4)
    eq(s.P.status().exit_pending, false, 'landed outside the Horde')
    local r = horde({aether = 0})
    r.P.enable()
    r.actors = {actor('Stash', 1.5, 0)}
    r.loaded['core.tracker'].finished_chest_looting = true
    r:run(45) -- Leave Dungeon never leaves BSK: latched FAULT
    truthy(r.P.status().fault and r.P.status().fault:find('exit:', 1, true), 'exit fault latched')
    eq(r.P.status().exit_pending, false, 'a latched FAULT is not an exit in progress')
end)

-- R8: 'Use keybind' on with no key bound (as Arkham's ARK-7).
case('R8 external enable runs with an unbound keybind; a bound key still pauses; manual gate unchanged', function()
    local s = horde({aether = 0})
    s.gui.elements.use_keybind:set(true); s:tick() -- ticked, never bound (0x0A)
    s.P.enable()
    eq(s.P.status().enabled, true, 'enable() results in enabled status')
    s.actors = {actor('Monster', 5, 0, {enemy = true, health = 100})}
    s:run(5)
    eq(s:task_name(), 'Infernal Horde', 'HordeDev runs under external control')
    eq(s:logged('no key is bound'), 1, 'misconfiguration logged')
    s.P.enable() -- re-asserted while running
    eq(s:logged('no key is bound'), 1, 'logged once')
    eq(s:logged('fresh_run_reset'), 1, 'a re-enable while running does not reset the run')
    s.P.disable()
    eq(s.P.status().enabled, false, 'disable() sticks')
    s.gui.elements.main_toggle:set(true); s:run(1) -- the user, not an external controller
    eq(s.P.status().enabled, false, 'manual keybind gate unchanged')
    s.gui.elements.main_toggle:set(false); s:run(0.4)
    s.gui.elements.keybind_toggle.key = 0x70 -- the user binds a key
    s.P.enable(); s:run(1)
    eq(s.P.status().enabled, true)
    s.gui.elements.keybind_toggle.state = 0; s:run(1)
    eq(s.P.status().enabled, false, 'a bound key still pauses HordeDev')
    eq(s:task_name(), 'Idle')
end)

case('R8 enable() during a healthy run keeps it; a latched fault is still restarted', function()
    local s = horde({aether = 0})
    s.P.enable()
    s.actors = {actor('Stash', 1.5, 0)}
    local tr, exit = s.loaded['core.tracker'], s.loaded['tasks.exit_horde']
    tr.finished_chest_looting = true
    s:run(1)
    eq(tr.reset_exit_pending, true, 'RESET committed')
    local phase = exit.reset_phase
    s.P.enable() -- WarPigs re-asserting ownership mid-run
    eq(tr.reset_exit_pending, true, 'pending RESET kept')
    eq(exit.reset_phase, phase, 'exit phase kept')
    eq(s:logged('keeping the current run'), 1)
    local step = leave_after(s)
    s:run(25, 0.2, step)
    eq(exit.reset_phase, 'DONE'); eq(s.resets, 1, 'the kept RESET completes')
    -- after a hotkey pause mid-run, a re-enable resumes the same run
    local p = horde({aether = 0})
    p.gui.elements.use_keybind:set(true); p.gui.elements.keybind_toggle.key = 0x70
    p.P.enable()
    p.actors = {actor('Stash', 1.5, 0)}
    p.loaded['core.tracker'].finished_chest_looting = true
    p:run(1)
    eq(p.loaded['core.tracker'].reset_exit_pending, true)
    p.gui.elements.keybind_toggle.state = 0; p:run(1)
    p.P.enable()
    eq(p.loaded['core.tracker'].reset_exit_pending, true, 're-enable after a pause keeps the RESET')
    eq(p.P.status().enabled, true)
    -- a latched exit FAULT: enable() is the restart
    local r = horde({aether = 0})
    r.P.enable()
    r.actors = {actor('Stash', 1.5, 0)}
    r.loaded['core.tracker'].finished_chest_looting = true
    r:run(45)
    truthy(r.P.status().fault, 'exit fault latched')
    r.P.enable()
    eq(r.P.status().fault, nil, 'enable() clears a latched fault')
    eq(r.loaded['core.tracker'].reset_exit_pending, false)
end)

-- C1: HordeDev's own WAITING request and needs_salvage hold on a foreign
-- Alfred pause are bounded (60 s, logged), as in the other plugins.
local function paused_chest_trip(st, pause_on_trigger)
    local calls = 0
    local alfred = {get_status = function() return st end,
        trigger_tasks_with_teleport = function() calls = calls + 1; if pause_on_trigger then st.paused = true end; return true end}
    local s = horde({aether = 40, globals = {AlfredTheButlerPlugin = alfred}})
    s.P.enable()
    chest_room(s, true, true)
    return s, function() return calls end
end

case('C1 own Alfred request waiting on a paused Alfred is retired after 60 s; chests continue', function()
    local st = {enabled = true, need_trigger = true}
    local s, calls = paused_chest_trip(st, true)
    s:run(20)
    eq(calls(), 1, 'salvage trip requested'); eq(st.paused, true)
    eq(s:task_name(), 'alfred_running')
    local hold = s.P.status().hold
    s:run(30)
    eq(s:task_name(), 'alfred_running', 'short pauses still hold')
    local interactions = #s.interactions
    s:run(45)
    truthy(s:task_name() ~= 'alfred_running', 'no unbounded hold: ' .. s:task_name())
    truthy(#s.interactions > interactions, 'the chests continue')
    eq(s:logged("paused for 60s with HordeDev's request pending"), 1, 'retirement logged once')
    eq(hold, 'waiting for a paused Alfred', 'visible hold')
    eq(#s.teleports, 0, 'no built-in Cerrigar trip while Alfred is enabled')
    eq(calls(), 1, 'a paused Alfred is never re-triggered')
    eq(s.P.status().alfred_trip, false)
end)

case('C1 needs_salvage hold on a paused Alfred is bounded and does not re-pause the chests', function()
    local st = {enabled = true, need_trigger = true, paused = true}
    local s, calls = paused_chest_trip(st, false)
    s:run(20)
    eq(s.loaded['tasks.open_chests'].current_state, 'PAUSED_FOR_SALVAGE')
    eq(s:task_name(), 'alfred_running'); eq(s.P.status().hold, 'waiting for a paused Alfred')
    local repaused = 0
    s:run(75, 0.2, function()
        if s.loaded['core.tracker'].alfred_pause_expired
            and s.loaded['tasks.open_chests'].current_state == 'PAUSED_FOR_SALVAGE' then repaused = repaused + 1 end
    end)
    eq(s:logged('with salvage pending; continuing without it'), 1, 'logged once')
    eq(s:logged('No salvage owner available (Alfred paused'), 1, 'chests resumed once')
    truthy(repaused <= 1, 'no re-pause loop while Alfred stays paused: ' .. repaused)
    eq(calls(), 0, 'a paused Alfred is never triggered')
    eq(#s.teleports, 0, 'no built-in Cerrigar trip')
    truthy(#s.interactions >= 1, 'a chest was opened')
    st.paused = false; s:run(0.4)
    eq(s.loaded['core.tracker'].alfred_pause_expired, false, 'the bound re-arms once Alfred resumes')
end)

-- R7 joint: the real WarPigs orchestrator does not cut HordeDev's own exit.
case('R7 joint: WarPigs keeps a faulted HordeDev while its exit (Looter hold + RESET) is in progress', function()
    local f
    f = joint({aether = 30, globals = {LooteerPlugin = busy_looter(function() return f.s end)}})
    local s = f.s
    f.quests = {'WarPlans_QST_InfernalHordes_BSK'}
    f.run(3)
    eq(s.P.status().enabled, true, 'WarPigs enabled HordeDev in BSK')
    f.quests = {}
    chest_room(s, false, false)
    local step = leave_after(s)
    local fault_at, resets_at_release
    f.run(240, function()
        step()
        if not fault_at and s.P.status().fault then fault_at = s.now; s.looting = true end
        if fault_at and s.looting and s.now - fault_at >= 90 then s.looting = false end
        if resets_at_release == nil and not s.gui.elements.main_toggle:get() then resets_at_release = s.resets end
    end)
    truthy(fault_at, 'chest fault published')
    eq(resets_at_release, 1, 'HordeDev released only after its own Leave/RESET (90 s Looter hold)')
end)

-- R8 joint: an unbound keybind no longer makes WarPigs re-enable (and reset) HordeDev.
case('R8 joint: with Use keybind on and no key bound WarPigs enables HordeDev once', function()
    local f = joint({aether = 0})
    local s = f.s
    s.gui.elements.use_keybind:set(true); s:tick()
    f.quests = {'WarPlans_QST_InfernalHordes_BSK'}
    f.run(75)
    eq(s.P.status().enabled, true, 'enable() took effect')
    eq(s:logged('HORDE ACTIVATING'), 1, 'enabled once')
    eq(s:logged('fresh_run_reset'), 1, 'run state reset once')
end)

-- ── Round 4 ────────────────────────────────────────────────────────────────
-- F-H3 (round-3 critic regression 1): keep_run_on_enable keeps the run only
-- where it actually is. Stale horde_opened / sigil_used / has_entered with the
-- player outside BSK and nothing pending take the full reset (as at 86340d4).
local function hotkey_pause_to_gate(f)
    local s = f.s
    f.settings.use_teleport_transition = true
    s.gui.elements.use_keybind:set(true); s.gui.elements.keybind_toggle.key = 0x70; s:tick()
    f.quests = {'WarPlans_QST_InfernalHordes_BSK'}
    f.run(5)
    local tr = s.loaded['core.tracker']
    tr.horde_opened, tr.has_entered, tr.sigil_used = true, true, true
    f.run(3)
    -- host: the Temis waypoint lands in Temis; the Horde warplan lands at the Caldeum gate
    f.env.teleport_to_waypoint = function(id) s.teleports[#s.teleports + 1] = 'WP:' .. tostring(id); s.pending_move = 'town' end
    f.env.warplan.teleport_to_activity = function() f.warplans = (f.warplans or 0) + 1; s.pending_move = 'gate' end
    local function host()
        if s.pending_move == 'town' then s.pending_move = nil; s:town(); s.actors = {}
        elseif s.pending_move == 'gate' then s.pending_move = nil; s:outside(); s.in_town = false
            s.actors = {actor('QST_Caldeum_GatesToHell_Seal', 3, 0)} end
    end
    s.gui.elements.keybind_toggle.state = 0 -- the user presses HordeDev's bound hotkey mid-horde
    return host
end
local function hordedev_teleports(s)
    local n = 0
    for _, t in ipairs(s.teleports) do if type(t) == 'number' then n = n + 1 end end
    return n
end

-- Round 5: WarPigs may treat the hotkey pause of a HordeDev in a run as a
-- pause (W5-4: no detour, no re-enable until the user resumes) instead of a
-- self-disable (detour via Temis; the warplan lands at the gate and WarPigs
-- re-enables HordeDev there). Either way HordeDev must not stall silently
-- (task Idle with in_run == true outside BSK, the round-3 symptom): after
-- the user resumes it runs the horde in BSK or restarts cleanly at the gate.
local function after_hotkey_pause(f, host, each)
    local s = f.s
    local w = {stall = 0, max_stall = 0, last = s.now, started = false, resumed_in_bsk = false}
    local function sample()
        host()
        local st = s.P.status()
        local dt = s.now - w.last
        w.last = s.now
        if st.enabled and st.in_run and st.task.name == 'Idle' and s.zone ~= 'S05_BSK_Prototype02' then
            w.stall = w.stall + dt
            w.max_stall = math.max(w.max_stall, w.stall)
        else
            w.stall = 0
        end
        if st.enabled and st.task.name == 'Start Dungeon' then w.started = true end
        if w.resumed and st.enabled and st.task.name == 'Infernal Horde' and s.zone == 'S05_BSK_Prototype02' then
            w.resumed_in_bsk = true
        end
        if each then each(st) end
    end
    f.run(30, sample)                            -- WarPigs handles the pause
    s.gui.elements.keybind_toggle.state = 1      -- the user resumes with the hotkey
    w.resumed = true
    f.run(210, sample)
    return w
end

case('F-H3 joint: hotkey pause mid-horde: no silent stall; at the gate the re-enable restarts with Start Dungeon', function()
    local f = joint({aether = 0})
    local s = f.s
    local host = hotkey_pause_to_gate(f)
    local w = after_hotkey_pause(f, host)
    truthy(w.max_stall <= 3, string.format('no silent Idle+in_run stall outside BSK (%.1fs)', w.max_stall))
    truthy(w.started or w.resumed_in_bsk, string.format(
        'Start Dungeon at the gate or the same horde resumed in BSK (task=%s in_run=%s zone=%s)',
        s:task_name(), tostring(s.P.status().in_run), s.zone))
    if s.zone ~= 'S05_BSK_Prototype02' then
        truthy(w.started, 'at the gate: the compass chain restarts')
        eq(s:logged('keeping the current run'), 0, 'stale in-Horde flags at the gate are not a run')
    end
    eq(s.P.status().enabled, true)
    eq(s.P.status().entry_mode, 'compass', 'War Plan entry off: compass mode as at d275b9d')
end)

case('F-H3 re-enable outside BSK: stale flags reset; pending transaction, BSK or own Alfred trip keep the run', function()
    -- stale flags at the gate (compass): full reset, then Start Dungeon
    local s = horde({aether = 0})
    s.P.enable()
    s:outside(); s.actors = {actor('QST_Caldeum_GatesToHell_Seal', 3, 0)}
    local tr = s.loaded['core.tracker']
    tr.horde_opened, tr.has_entered, tr.sigil_used = true, true, true
    s:run(2)
    eq(s:task_name(), 'Idle', 'the stale state blocks every entry task (the round-3 symptom)')
    eq(s.P.status().in_run, true)
    s.P.enable()
    eq(s:logged('keeping the current run'), 0)
    eq(tr.horde_opened, false, 'full reset')
    s:run(2)
    eq(s:task_name(), 'Start Dungeon', 'restarts the compass chain')
    -- ... and in War Plan mode the same re-enable idles visibly, never a compass
    local w = horde({aether = 0})
    w.P.enable()
    w:outside(); w.actors = {actor('QST_Caldeum_GatesToHell_Seal', 3, 0)}
    w.keys = {{get_name = function() return 'S05_DungeonSigil_BSK_Wave6' end}}
    local wtr = w.loaded['core.tracker']
    wtr.horde_opened, wtr.has_entered, wtr.sigil_used = true, true, true
    w:run(1)
    w.P.enable({entry = 'warplan'})
    w:run(60)
    eq(w:task_name(), 'Waiting for War Plan teleport')
    eq(w.P.status().hold, 'waiting for War Plan teleport')
    eq(w.used, nil, 'no compass'); eq(#w.teleports, 0, 'no Library teleport')
    -- own Alfred trip in town (outside BSK): the chest run is kept
    local st = {enabled = true, need_trigger = true}
    local a = horde({aether = 40, globals = {AlfredTheButlerPlugin = {get_status = function() return st end,
        trigger_tasks_with_teleport = function() st.running = true; return true end}}})
    a.P.enable()
    a.actors = {actor('BSK_UniqueOpChest_Materials', 0.5, 0), actor('BSK_UniqueOpChest_Gold', 1.0, 0), actor('Stash', 1.5, 0)}
    a:run(20)
    eq(a.P.status().alfred_trip, true, 'HordeDev Alfred trip in flight')
    a:town('Skov_Temis'); a:run(1)
    a.P.enable()
    eq(a:logged('keeping the current run'), 1, 'own Alfred trip outside BSK keeps the run')
    eq(a.P.status().alfred_trip, true)
end)

case('F-H3 joint (War Plan entry on): the same hotkey pause never leads to a compass or a Library teleport', function()
    local f = joint({aether = 0, warplan = true})
    local s = f.s
    local host = hotkey_pause_to_gate(f)
    s.keys = {{get_name = function() return 'S05_DungeonSigil_BSK_Wave6' end}}
    local outside_modes, outside_in_run = {}, false
    local w = after_hotkey_pause(f, host, function(st)
        if st.enabled and s.zone ~= 'S05_BSK_Prototype02' then
            outside_modes[st.entry_mode .. ':' .. st.task.name] = true
            if st.in_run then outside_in_run = true end
        end
    end)
    truthy(w.max_stall <= 3, string.format('no silent Idle+in_run stall outside BSK (%.1fs)', w.max_stall))
    eq(w.started, false, 'never Start Dungeon')
    eq(s.used, nil, 'no compass used')
    eq(hordedev_teleports(s), 0, 'no HordeDev Library teleport')
    eq(s.loaded['core.tracker'].sigil_activation_pending, false)
    eq(outside_in_run, false, 'stale compass flags outside BSK are not a War Plan run')
    for key in pairs(outside_modes) do
        truthy(key == 'warplan:Waiting for War Plan teleport' or key == 'warplan:Idle',
            'HordeDev on outside the Horde only as a visible War Plan wait: ' .. key)
    end
    if s.zone == 'S05_BSK_Prototype02' then
        truthy(w.resumed_in_bsk, 'the resumed run plays the horde in BSK (task=' .. s:task_name() .. ')')
        eq(s.P.status().entry_mode, 'warplan', 'the resumed run stays in War Plan mode')
    elseif s.P.status().enabled then
        eq(s:task_name(), 'Waiting for War Plan teleport', 'outside BSK: the visible War Plan wait')
        eq(s.P.status().hold, 'waiting for War Plan teleport')
    end
end)

-- The contract end to end with the real WarPigs orchestrator: War Plan
-- teleport (Use teleport off) -> BSK -> enable({entry = 'warplan'}) -> chests
-- -> Leave Dungeon -> released with last_result 'completed'; no compass.
case('R4 joint: War Plan entry, HordeDev runs in War Plan mode inside BSK, exits and is released', function()
    local f = joint({aether = 0, warplan = true})
    local s = f.s
    s:town('Skov_Temis'); s.actors = {}
    s.keys = {{get_name = function() return 'S05_DungeonSigil_BSK_Wave6' end}}
    f.env.warplan.teleport_to_activity = function() f.warplans = (f.warplans or 0) + 1; s.pending_move = 'bsk' end
    local modes = {}
    local function step()
        if s.pending_move == 'bsk' then
            s.pending_move = nil
            s.world, s.zone, s.id, s.in_town = 'S05_BSK_Prototype02', 'S05_BSK_Prototype02', s.id + 1, false
            chest_room(s, true, true)
        end
        if s.outside_at and s.now >= s.outside_at then s.outside_at = nil; s:outside(); s.actors = {} end
        local st = s.P.status()
        if st.enabled then modes[st.entry_mode] = true end
    end
    s.on_leave = function() s.outside_at = s.now + 2 end
    f.quests = {'WarPlans_QST_InfernalHordes_BSK'}
    truthy(f.until_true(function() return s.P.status().enabled end, 30, step), 'HordeDev enabled after the War Plan teleport')
    eq(s.zone, 'S05_BSK_Prototype02', 'enabled inside the Horde')
    eq(s.P.status().entry_mode, 'warplan', 'War Plan entry mode')
    eq(f.warplans, 1, 'one War Plan teleport')
    truthy(f.until_true(function() return s.leaves >= 1 end, 180, step), 'Leave Dungeon')
    f.quests = {'WarPlans_QST_TurnIn_Rewards'}
    truthy(f.until_true(function() return not s.gui.elements.main_toggle:get() end, 60, step), 'HordeDev released')
    eq(s.P.status().last_result, 'completed', 'completed result visible')
    eq(s.P.chests_done(), true)
    eq(s.used, nil, 'no compass'); eq(hordedev_teleports(s), 0, 'no HordeDev teleport')
    eq(modes.compass, nil, 'never enabled in compass mode')
end)

-- Round-5 critic blocker: at the gate with NO compass the stash restock is
-- the activity's own blocking need. The suite policy that leaves advisory
-- flags to WarPigs (H5-4, still applied in the War Plan chest room) must not
-- apply here, or a compass-mode HordeDev under WarPigs (compass fallback, or
-- War Plan entry off) waits at the gate forever. The sticky grace after
-- HordeDev's own completed Alfred cycle still bounds re-triggers.
local function advisory_at_gate(st, wp, completed_ago)
    local triggers = 0
    local alfred = {get_status = function() return st end,
        trigger_tasks_with_teleport = function() triggers = triggers + 1; return true end}
    local s = horde({aether = 0, globals = {AlfredTheButlerPlugin = alfred, WarPigsPlugin = wp}})
    s.P.enable()
    s:outside(); s.actors = {actor('QST_Caldeum_GatesToHell_Seal', 3, 0)} -- at the gate, no compass
    if completed_ago then s.loaded['core.tracker'].alfred_completed_at = s.now - completed_ago end
    s:run(completed_ago and 10 or 40)
    return s, triggers
end
case('out of compasses at the gate: the restock is a blocking need, also under WarPigs; the sticky grace still bounds it', function()
    local restock = {enabled = true, need_trigger = true, restock_count = 2}
    for _, reading in ipairs({{enabled = true, alfred_idle = true}, {enabled = true, alfred_idle = false}, {enabled = true}}) do
        local wp = {status = function() return reading end}
        local s, n = advisory_at_gate(restock, wp)
        truthy(n >= 1, 'WarPigs enabled (alfred_idle=' .. tostring(reading.alfred_idle) .. '): compass restock requested')
        eq(s:logged('Advisory Alfred restock skipped'), 0, 'never skipped at the gate')
        eq(s:logged('Out of compasses: asking Alfred to restock them'), 1, 'logged once')
        local _, full = advisory_at_gate({enabled = true, need_trigger = true, inventory_full = true}, wp)
        truthy(full >= 1, 'inventory_full still triggers')
        local _, repair = advisory_at_gate({enabled = true, need_trigger = true, need_repair = true}, wp)
        truthy(repair >= 1, 'need_repair still triggers')
        -- A stash without compasses cannot loop faster than the grace allows.
        local g, graced = advisory_at_gate(restock, wp, 5)
        eq(graced, 0, 'no re-trigger within the sticky grace after HordeDev\'s own cycle')
        eq(g:task_name(), 'Start Dungeon')
    end
    local off_wp = {status = function() return {enabled = false, alfred_idle = true} end}
    local _, off = advisory_at_gate({enabled = true, need_trigger = true, restock_count = 2}, off_wp)
    truthy(off >= 1, 'WarPigs off: standalone rule')
    local _, alone = advisory_at_gate({enabled = true, need_trigger = true, restock_count = 2}, nil)
    truthy(alone >= 1, 'no WarPigs: standalone rule')
end)

-- ── Round 5 ────────────────────────────────────────────────────────────────
-- H5-3: F-H3's keep rule also keeps HordeDev's own built-in Cerrigar salvage
-- trip (compass mode, no Alfred): the chest phase is paused for it and the
-- player is in Cerrigar. The pause keeps the salvage flags, so the resumed or
-- re-enabled run finishes the salvage instead of taking the Library/compass
-- path. Stale flags at the gate still take the full reset.
local CERRIGAR, LIBRARY_WP = 0x76D58, 0x10D63D
local function salvage_trip_in_cerrigar(opts)
    opts = opts or {}
    local s = horde({aether = 40})   -- no Alfred: the built-in salvage services a full bag
    s.gui.elements.use_keybind:set(true); s.gui.elements.keybind_toggle.key = 0x70
    s.P.enable()
    s.item_count = 40
    chest_room(s, true, true)
    local oc, tr = s.loaded['tasks.open_chests'], s.loaded['core.tracker']
    local reached = false
    for _ = 1, 300 do
        s:tick(0.2)
        if #s.teleports > 0 then reached = true; break end
    end
    assert(reached and s.teleports[1] == CERRIGAR, 'the built-in salvage teleports to Cerrigar')
    assert(oc.current_state == 'PAUSED_FOR_SALVAGE' and tr.needs_salvage == true, 'the chest phase is paused for it')
    tr.ga_chest_opened = true -- a chest of this horde was already opened
    s:town('Scos_Cerrigar'); s.in_town = false; s.actors = {}
    s:run(2)
    if opts.salvaged then tr.has_salvaged, tr.needs_salvage = true, false end -- blacksmith done, walking to the portal
    return s, oc, tr
end
local function library_teleports(s)
    local n = 0
    for _, id in ipairs(s.teleports) do if id == LIBRARY_WP then n = n + 1 end end
    return n
end

case('H5-3 hotkey pause during the built-in Cerrigar salvage: the re-enable keeps the chest phase and the salvage goes on', function()
    for _, salvaged in ipairs({false, true}) do
        local label = salvaged and 'salvage done, walking to the portal' or 'salvage pending'
        local s, oc, tr = salvage_trip_in_cerrigar({salvaged = salvaged})
        eq(s:task_name(), 'Town Salvage', label .. ': on the built-in salvage trip')
        eq(s.P.status().in_run, true, label)
        s.gui.elements.keybind_toggle.state = 0 -- the user presses HordeDev's hotkey
        s:run(2)
        s.P.enable() -- WarPigs re-enables it after its post-disable gap
        eq(s:logged('keeping the current run'), 1, label .. ': the salvage trip keeps the run')
        eq(oc.current_state, 'PAUSED_FOR_SALVAGE', label .. ': chest phase kept')
        eq(tr.ga_chest_opened, true, label .. ': opened chests kept')
        eq(tr.needs_salvage, not salvaged, label .. ': needs_salvage survives the pause')
        eq(tr.has_salvaged, salvaged, label .. ': has_salvaged survives the pause')
        eq(s.P.status().in_run, true, label)
        local names = {}
        s:run(10, 0.2, function() names[s:task_name()] = true end)
        eq(library_teleports(s), 0, label .. ': no Library teleport (no new compass cycle)')
        eq(names['Walking to Horde'], nil, label .. ': never walking to the Horde')
        eq(s:task_name(), 'Town Salvage', label .. ': the salvage goes on')
        eq(s.P.status().fault, nil)
    end
    -- the same pause resumed with the hotkey (no enable()): the salvage goes on
    local r = salvage_trip_in_cerrigar()
    r.gui.elements.keybind_toggle.state = 0; r:run(2)
    r.gui.elements.keybind_toggle.state = 1; r:run(10)
    eq(library_teleports(r), 0, 'hotkey resume: no Library teleport')
    eq(r:task_name(), 'Town Salvage', 'hotkey resume: the salvage goes on')
end)

case('H5-3 stale salvage / run flags outside Cerrigar, or a switch to War Plan entry, still take the full reset', function()
    -- the chest phase paused for the salvage, but the player is at the gate
    local g = salvage_trip_in_cerrigar()
    g:outside(); g.in_town = false; g.actors = {actor('QST_Caldeum_GatesToHell_Seal', 3, 0)}
    local gtr = g.loaded['core.tracker']
    gtr.horde_opened, gtr.has_entered, gtr.sigil_used = true, true, true
    g:run(1)
    g.P.enable()
    eq(g:logged('keeping the current run'), 0, 'gate: not where the run is')
    eq(g.loaded['tasks.open_chests'].current_state, 'INIT', 'gate: full reset')
    eq(gtr.needs_salvage, false); eq(gtr.horde_opened, false)
    g:run(2)
    eq(g:task_name(), 'Start Dungeon', 'gate: restarts the compass chain')
    -- a salvage flag without a started chest phase (e.g. the gate's restock flag) in Cerrigar
    local c = horde({aether = 0})
    c.P.enable()
    c:town('Scos_Cerrigar'); c.in_town = false
    c.loaded['core.tracker'].needs_salvage = true
    c:run(0.4)
    c.P.enable()
    eq(c:logged('keeping the current run'), 0, 'no chest phase: not a salvage trip')
    eq(c.loaded['core.tracker'].needs_salvage, false, 'full reset')
    -- a switch to War Plan entry in Cerrigar never keeps the compass salvage
    local w = salvage_trip_in_cerrigar()
    w.P.enable({entry = 'warplan'})
    eq(w:logged('keeping the current run'), 0, 'War Plan switch: not kept')
    eq(w.loaded['tasks.open_chests'].current_state, 'INIT', 'War Plan switch: full reset')
    local before = #w.teleports
    w:run(20)
    eq(#w.teleports, before, 'War Plan switch: no teleport')
    eq(w:task_name(), 'Waiting for War Plan teleport')
    -- a latched fault is still restarted
    local f = salvage_trip_in_cerrigar()
    f.loaded['tasks.exit_horde'].reset_phase, f.loaded['tasks.exit_horde'].reset_error = 'FAULT', 'test'
    f.P.enable()
    eq(f:logged('keeping the current run'), 0, 'latched fault: full restart')
end)

for _, failure in ipairs(failures) do print('FAIL ' .. failure) end
print(string.format('HordeDev integration: %d checks, %d failures', checks, #failures))
assert(#failures == 0, 'HordeDev integration regressions failed')
print(string.format('PASS: HordeDev integration regressions (%d checks)', checks))
