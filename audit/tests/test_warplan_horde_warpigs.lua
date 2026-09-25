-- Round 4 user feature, WarPigs side: Infernal Hordes War Plans are entered
-- through the War Plan teleport (warplan.teleport_to_activity()), never with
-- an Infernal Compass. settings.horde_warplan_entry (GUI 'Hordes: enter via
-- War Plan teleport (no compass)', default ON) and horde_compass_fallback
-- (GUI 'Allow compass entry if the War Plan teleport fails', default OFF).
-- Part A loads the real orchestrator with QQT-shaped host mocks (as
-- test_integration_warpigs_dispatch.lua); part B runs the real WarPigs,
-- HordeDev and the other seven plugins in the joint host.
-- Every case fails on d275b9d (HordeDev enabled in town with enable() and no
-- War Plan teleport; the WPD-3 bypass enables it outside the Horde).
local ROOT = assert(SUITE_ROOT)
local root = ROOT .. '/WarPigs-1.0.0/'
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
    local ok, err = xpcall(run, debug.traceback)
    if not ok then failures[#failures + 1] = name .. ': ' .. tostring(err) end
end

local BSK_WORLD, BSK_ZONE = 'S05_BSK_Prototype02', 'S05_BSK_Prototype02'

-- ── part A: real orchestrator, host mocks ───────────────────────────────────
local function fixture(opts)
    opts = opts or {}
    local f = {now = 100, world = opts.world or 'Sanctuary', zone = opts.zone or 'Skov_Temis',
        town = opts.town ~= false, quests = {}, aether = 0, minute = 30, actors = {},
        waypoints = 0, teleports = 0, teleport_at = {}, logs = {}, alfred_triggers = {}, casting = false}
    local e = setmetatable({}, {__index = _G}); e._G = e
    e.console = {print = function(m) f.logs[#f.logs + 1] = string.format('%.1f %s', f.now, tostring(m)) end}
    e.os = setmetatable({date = function(fmt, ...)
        if fmt == '%M' then return string.format('%02d', f.minute) end
        return os.date(fmt, ...)
    end}, {__index = os})
    e.attributes = {PLAYER_IN_TOWN_LEVEL_AREA = 'town'}
    e.get_time_since_inject = function() return f.now end
    e.get_local_player = function() return {
        is_dead = function() return f.dead == true end,
        get_attribute = function() return f.town and 1 or 0 end,
        get_buffs = function() return {} end,
        get_position = function() return {} end,
        get_active_spell_id = function() return f.casting and 186139 or -1 end,
    } end
    e.get_current_world = function() return {
        get_name = function() return f.world end,
        get_current_zone_name = function() return f.zone end,
    } end
    e.get_quests = function()
        local out = {}
        for _, name in ipairs(f.quests) do out[#out + 1] = {get_name = function() return name end} end
        return out
    end
    e.actors_manager = {get_all_actors = function()
        local out = {}
        for _, name in ipairs(f.actors) do
            out[#out + 1] = {get_skin_name = function() return name end, get_position = function() return {} end}
        end
        return out
    end}
    e.teleport_to_waypoint = function(wp)
        f.waypoints = f.waypoints + 1
        if f.on_waypoint then f.on_waypoint(wp) end
    end
    if opts.no_warplan ~= true then
        e.warplan = {teleport_to_activity = function()
            f.teleports = f.teleports + 1
            f.teleport_at[#f.teleport_at + 1] = f.now
            if f.on_warplan then return f.on_warplan() end
        end}
    end
    e.get_aether_count = function() return f.aether end
    e.revive_at_checkpoint = function() end
    e.pathfinder = {request_move = function() end}
    e.orbwalker = {set_clear_toggle = function() end, set_block_movement = function() end}
    f.settings = {enabled = true, manage_whispers = false,
        use_teleport_transition = opts.teleport == true, manage_orbwalker = false,
        horde_warplan_entry = opts.warplan ~= false, horde_compass_fallback = opts.fallback == true}
    local modules = {['core.settings'] = f.settings,
        ['core.tasks.turn_in_rewards'] = {tick = function() end, get_state = function() return 'IDLE' end}}
    e.require = function(name)
        if modules[name] ~= nil then return modules[name] end
        local value = assert(loadfile(root .. name:gsub('%.', '/') .. '.lua', 't', e))()
        modules[name] = value
        return value
    end
    f.e = e
    f.o = e.require('core.orchestrator')
    function f.plugin(name, fields)
        local p = {enabled = false, enables = 0, disables = 0, args = {}, st = fields or {}}
        p.enable = function(o)
            p.enabled = true; p.enables = p.enables + 1
            p.args[#p.args + 1] = type(o) == 'table' and tostring(o.entry) or 'none'
            p.st.entry_mode = type(o) == 'table' and o.entry == 'warplan' and 'warplan' or 'compass'
        end
        p.disable = function() p.enabled = false; p.disables = p.disables + 1; p.st.entry_mode = 'compass' end
        p.status = function()
            local s = {enabled = p.enabled}
            for k, v in pairs(p.st) do s[k] = v end
            return s
        end
        e[name] = p
        return p
    end
    function f.horde(fields)
        local h = f.plugin('InfernalHordesPlugin', fields)
        h.chests_done = function() return h.done == true end
        h.getState = function() return 'IDLE' end
        return h
    end
    function f.alfred(status)
        f.alfred_status = status
        e.AlfredTheButlerPlugin = {
            get_status = function() return f.alfred_status end,
            trigger_tasks = function(caller, callback)
                f.alfred_triggers[#f.alfred_triggers + 1] = {zone = f.zone, at = f.now, caller = caller}
                return true
            end,
        }
    end
    function f.looter(busy)
        f.looting = busy
        e.LooteerPlugin = {get_enabled = function() return true end,
            is_actively_looting = function() return f.looting end}
    end
    -- Native travel: `seconds` of channel and loading, then `fn` (the host
    -- reports the Limbo loading world meanwhile).
    f.events = {}
    function f.travel(seconds, fn)
        f.casting = true
        f.events[#f.events + 1] = {at = f.now + seconds, fn = fn}
    end
    function f.tick(dt)
        f.now = f.now + (dt or 0.5)
        local keep = {}
        for _, ev in ipairs(f.events) do
            if f.now >= ev.at then f.casting = false; ev.fn() else keep[#keep + 1] = ev end
        end
        f.events = keep
        f.o.tick()
    end
    function f.run(seconds, each)
        local stop = f.now + seconds
        while f.now < stop - 1e-9 do
            f.tick(0.5)
            if each then each() end
        end
    end
    function f.until_true(predicate, seconds, each)
        local start, stop = f.now, f.now + seconds
        while f.now < stop - 1e-9 do
            f.tick(0.5)
            if each then each() end
            if predicate() then return f.now - start end
        end
        return nil
    end
    function f.logged(text)
        local n = 0
        for _, m in ipairs(f.logs) do if m:find(text, 1, true) then n = n + 1 end end
        return n
    end
    function f.set_zone(world, zone, town) f.world, f.zone, f.town = world, zone, town end
    function f.to_bsk() f.set_zone(BSK_WORLD, BSK_ZONE, false) end
    function f.to_gate() f.set_zone('Sanctuary_Eastern_Continent', 'Kehj_Caldeum', true) end
    function f.warplan_to(fn) f.on_warplan = function() f.travel(3.5, fn) end end
    function f.dump() return table.concat(f.logs, '\n') end
    return f
end

local HORDE = 'WarPlans_QST_InfernalHordes_BSK'

case('F-W1 teleport off: WarPigs fires the War Plan teleport itself; HordeDev only inside the Horde, War Plan mode', function()
    local f = fixture()
    local horde = f.horde()
    f.warplan_to(f.to_bsk)
    f.quests = {HORDE}
    f.run(2)
    eq(horde.enables, 0, 'HordeDev is not started in Temis (d275b9d: enable() in town -> compass)')
    eq(f.teleports, 1, 'WarPigs called warplan.teleport_to_activity() with Use teleport off')
    eq(f.waypoints, 0, 'no via-Temis detour with Use teleport off')
    truthy(f.until_true(function() return horde.enables == 1 end, 10), 'HordeDev enabled after arrival\n' .. f.dump())
    eq(horde.args[1], 'warplan', 'enable({entry = "warplan"})')
    eq(f.teleports, 1, 'one War Plan teleport')
    eq(f.logged('landed world=' .. BSK_WORLD .. ' zone=' .. BSK_ZONE .. ', inside the Horde'), 1,
        'landing logged once per delivery')
    f.run(20)
    eq(horde.enables, 1, 'no re-enable'); eq(f.teleports, 1, 'no teleport while HordeDev runs')
end)

case('F-W1 the War Plan teleport waits for cleanup, the post-disable gap, live Alfred work and the Looter (bounded)', function()
    local f = fixture()
    local ark = f.plugin('ArkhamAsylumPlugin'); ark.enabled = true
    f.quests = {'WarPlans_QST_ThePit'}; f.tick()
    local horde = f.horde()
    f.warplan_to(f.to_bsk)
    f.quests = {HORDE}
    f.tick()
    eq(ark.disables, 1, 'Pit released in town')
    local released_at = f.now
    truthy(f.until_true(function() return f.teleports == 1 end, 10), 'teleport after the gap')
    truthy(f.teleport_at[1] - released_at >= 5 - 1e-6, string.format('post-disable gap kept (%.1fs)', f.teleport_at[1] - released_at))
    -- Live Alfred work and a Looter pickup hold it; both holds are bounded.
    local g = fixture()
    g.horde()
    g.alfred({enabled = true, trigger_tasks = true, running = true})
    g.quests = {HORDE}
    g.run(30)
    eq(g.teleports, 0, 'no War Plan teleport over a live Alfred cycle')
    truthy(g.o.get_status_line():find('Alfred cycle in progress', 1, true), 'hold shown: ' .. g.o.get_status_line())
    g.alfred_status = {enabled = true}
    truthy(g.until_true(function() return g.teleports == 1 end, 3), 'fires once Alfred is idle')
    local l = fixture({world = 'Sanctuary', zone = 'Kehj_Caldeum'})
    l.horde()
    l.looter(true)
    l.quests = {HORDE}
    l.run(20)
    eq(l.teleports, 0, 'no War Plan teleport over a Looter pickup')
    truthy(l.until_true(function() return l.teleports == 1 end, 15), 'Looter hold bounded (30 s)')
    -- In Temis the suite-wide town-traffic Looter hold (120 s) comes first,
    -- then this gate's own Looter bound (30 s): still bounded.
    local t = fixture()
    t.horde()
    t.looter(true)
    t.quests = {HORDE}
    t.run(60)
    eq(t.teleports, 0, 'no War Plan teleport over a Looter pickup in Temis')
    truthy(t.until_true(function() return t.teleports == 1 end, 100), 'Temis Looter hold bounded')
end)

case('F-W1 channel debounce, pcall and a stuck channel', function()
    local f = fixture()
    f.horde()
    f.casting = true              -- the channel keeps casting (bounded by the cast cap)
    f.quests = {HORDE}
    f.run(40)
    truthy(f.teleports >= 2 and f.teleports <= 3, 'one call per channel window under a stuck cast: ' .. f.teleports)
    for i = 2, #f.teleport_at do
        truthy(f.teleport_at[i] - f.teleport_at[i - 1] >= 6 - 1e-6, 'debounced: ' .. (f.teleport_at[i] - f.teleport_at[i - 1]))
    end
    local g = fixture()
    local horde = g.horde()
    g.on_warplan = function() error('host binding failed') end
    g.quests = {HORDE}
    g.run(30)
    truthy(g.logged('warplan.teleport_to_activity() threw') >= 1, 'a throwing binding is logged')
    eq(horde.enables, 0, 'and never becomes a compass entry')
    local n = fixture({no_warplan = true})
    local h2 = n.horde()
    n.quests = {HORDE}
    n.run(30)
    eq(h2.enables, 0, 'no warplan binding: HordeDev is not started outside the Horde')
    truthy(n.logged('unavailable') >= 1, 'unavailable binding logged')
end)

case('F-W1 three missed deliveries: no compass (fallback off), visible reason, rate-limited log, 60 s backoff', function()
    local f = fixture()
    local horde = f.horde()
    f.warplan_to(f.to_gate)   -- lands at the Caldeum gate
    f.quests = {HORDE}
    f.run(25)
    eq(f.teleports, 3, 'three War Plan teleports')
    eq(horde.enables, 0, 'HordeDev never enabled outside the Horde')
    eq(f.logged('not inside the Horde (1 of 3)'), 1, 'landing of delivery 1 logged once')
    eq(f.logged('not inside the Horde (3 of 3)'), 1, 'landing of delivery 3 logged once')
    truthy(f.logged('Kehj_Caldeum') >= 3, 'landing zone logged')
    eq(f.logged('not using a compass (compass fallback off)'), 1, 'reason logged')
    local line = f.o.get_status_line()
    truthy(line:find('did not reach the Horde', 1, true) and line:find('compass fallback off', 1, true)
        and line:find('retrying the War Plan teleport in', 1, true), 'status line: ' .. line)
    local lines = f.logged('War Plan Horde entry')
    f.run(50)
    eq(f.teleports, 3, 'backoff: no teleport for 60 s')
    truthy(f.logged('War Plan Horde entry') - lines <= 2, 'rate-limited log during the backoff')
    truthy(f.until_true(function() return f.teleports == 4 end, 15), 'retried after the backoff')
    eq(f.logged('round 2'), 2, 'second round logged')
    f.run(120)
    eq(horde.enables, 0, 'still no compass entry')
    truthy(f.teleports <= 9, 'bounded retries (3 per round, 60 s apart): ' .. f.teleports)
    -- The War Plan teleport finally lands in the Horde.
    f.warplan_to(f.to_bsk)
    truthy(f.until_true(function() return horde.enables == 1 end, 80), 'enabled once it lands in the Horde')
    eq(horde.args[1], 'warplan')
    f.tick()
    truthy(not f.o.get_status_line():find('Horde:', 1, true), 'reason cleared: ' .. f.o.get_status_line())
end)

case('F-W1 compass fallback ticked: enable() without arguments after three missed deliveries, logged', function()
    local f = fixture({fallback = true})
    local horde = f.horde()
    f.warplan_to(f.to_gate)
    f.quests = {HORDE}
    truthy(f.until_true(function() return horde.enables == 1 end, 40), 'compass fallback engaged\n' .. f.dump())
    eq(f.teleports, 3, 'only after three War Plan teleports')
    eq(horde.args[1], 'none', 'enable() without arguments = compass mode')
    eq(f.logged('compass fallback is on'), 1, 'fallback logged')
    eq(f.logged('starting HordeDev in compass mode (compass fallback'), 1)
    f.run(60)
    eq(horde.enables, 1, 'HordeDev keeps its compass cycle (not released as finished)')
    eq(horde.disables, 0)
end)

case('F-W1 Use teleport on: via-Temis preamble first, direct retries, the WPD-3 bypass never enables outside the Horde', function()
    local f = fixture({teleport = true})
    local horde = f.horde()
    f.on_waypoint = function() f.set_zone('Sanctuary', 'Skov_Temis', true) end
    f.warplan_to(f.to_gate)
    f.set_zone('Sanctuary_Eastern_Continent', 'Kehj_Caldeum', true)
    f.quests = {HORDE}
    truthy(f.until_true(function() return f.logged('not using a compass') == 1 end, 150), 'round 1 missed\n' .. f.dump())
    eq(horde.enables, 0, 'd275b9d: WPD-3 enabled HordeDev at the gate after 2 deliveries')
    eq(f.waypoints, 1, 'one via-Temis detour in the round')
    eq(f.teleports, 3, 'three deliveries in round 1 (preamble + 2 direct)')
    f.run(100)
    eq(horde.enables, 0, 'never outside the Horde')
    eq(f.waypoints, 2, 'the next round starts with the via-Temis preamble again')
    eq(f.logged('still denied after'), 0, 'no WPD-3 bypass')
    eq(f.logged('via-Temis warplan teleport arrived'), 2, 'each preamble delivery is counted and logged')
    -- Lands in the Horde: enabled in War Plan mode.
    f.warplan_to(f.to_bsk)
    truthy(f.until_true(function() return horde.enables == 1 end, 120), 'enabled inside the Horde\n' .. f.dump())
    eq(horde.args[1], 'warplan')
end)

case('F-W1 Use teleport on, landing in the Horde: enabled once in War Plan mode', function()
    local f = fixture({teleport = true})
    local horde = f.horde()
    f.warplan_to(f.to_bsk)
    f.quests = {HORDE}
    truthy(f.until_true(function() return horde.enables == 1 end, 60), 'enabled\n' .. f.dump())
    eq(horde.args[1], 'warplan'); eq(f.teleports, 1)
    eq(f.logged('via-Temis warplan teleport arrived — landed world=' .. BSK_WORLD), 1, 'landing logged once')
end)

case('F-W1 option off: identical to d275b9d (enable() in place; WPD-3 bypass with Use teleport on)', function()
    local f = fixture({warplan = false})
    local horde = f.horde()
    f.quests = {HORDE}
    f.tick()
    eq(horde.enables, 1, 'enabled at once, wherever the player is')
    eq(horde.args[1], 'none', 'enable() without arguments')
    eq(f.teleports, 0, 'no War Plan teleport')
    local g = fixture({warplan = false, teleport = true})
    local h2 = g.horde()
    g.on_waypoint = function() g.set_zone('Sanctuary', 'Skov_Temis', true) end
    g.warplan_to(g.to_gate)
    g.quests = {HORDE}
    truthy(g.until_true(function() return h2.enables >= 1 end, 300), 'WPD-3 bypass unchanged')
    eq(h2.args[1], 'none')
    truthy(g.logged('still denied after 2 warplan teleports') == 1, 'WPD-3 log unchanged')
end)

case('F-W1 cold start inside the Horde: War Plan mode in place, no teleport', function()
    local f = fixture({world = BSK_WORLD, zone = BSK_ZONE, town = false})
    local horde = f.horde()
    f.quests = {HORDE}
    f.run(5)
    eq(horde.enables, 1); eq(horde.args[1], 'warplan'); eq(f.teleports, 0); eq(f.waypoints, 0)
    local g = fixture({teleport = true, world = BSK_WORLD, zone = BSK_ZONE, town = false})
    local h2 = g.horde()
    g.quests = {HORDE}
    g.run(5)
    eq(h2.enables, 1); eq(h2.args[1], 'warplan'); eq(g.teleports, 0); eq(g.waypoints, 0)
end)

case('F-W1 a HordeDev persisted on outside the Horde is not adopted; WarPigs enters via the War Plan', function()
    for _, tp in ipairs({false, true}) do
        local f = fixture({teleport = tp})
        local horde = f.horde({in_run = false}); horde.enabled = true   -- persisted main toggle
        f.warplan_to(f.to_bsk)
        f.on_waypoint = function() f.set_zone('Sanctuary', 'Skov_Temis', true) end
        f.quests = {HORDE}
        f.tick()
        eq(f.logged('adopted active InfernalHordesPlugin'), 0, 'not adopted outside the Horde')
        eq(horde.disables, 1, 'stopped before it can walk to the Library')
        truthy(f.until_true(function() return horde.enables == 1 end, 60), 'War Plan entry\n' .. f.dump())
        eq(horde.args[1], 'warplan', 'teleport=' .. tostring(tp))
        truthy(f.teleports >= 1, 'War Plan teleport')
    end
    -- A HordeDev in a run outside the Horde (its own Alfred trip, a pending
    -- transaction) is adopted as before.
    local g = fixture({world = 'Sanctuary', zone = 'Kehj_Caldeum'})
    local h2 = g.horde({in_run = true}); h2.enabled = true
    g.quests = {HORDE}
    g.tick()
    eq(g.logged('adopted active InfernalHordesPlugin'), 1, 'run in progress adopted')
    eq(h2.disables, 0)
end)

case('F-W1 back-to-back War Plan Hordes: a finished run is released; the next Horde gets a new War Plan teleport', function()
    local f = fixture()
    local horde = f.horde({in_run = true})
    f.warplan_to(f.to_bsk)
    f.quests = {HORDE}
    truthy(f.until_true(function() return horde.enables == 1 end, 10), 'first Horde')
    f.run(10)
    -- The run finishes (6 waves, chests, exit): HordeDev leaves the Horde and
    -- reports in_run=false with last_result 'completed' (W5-2: the finish
    -- signal in War Plan mode); it never starts a second cycle itself.
    horde.st.in_run, horde.done, horde.st.last_result = false, true, 'completed'
    f.to_gate()
    f.quests = {HORDE, 'WarPlans_QST_InfernalHordes_BSK_2'}
    truthy(f.until_true(function() return horde.disables == 1 end, 10), 'finished run released\n' .. f.dump())
    eq(f.logged('finished its War Plan run (completed)'), 1)
    horde.st.in_run = true
    truthy(f.until_true(function() return horde.enables == 2 end, 20), 'next Horde entered\n' .. f.dump())
    horde.st.last_result = nil   -- enable() starts a fresh run (HordeDev resets last_result)
    eq(f.teleports, 2, 'a new War Plan teleport for the second Horde')
    eq(horde.args[2], 'warplan')
    -- HordeDev's 'completed' result counts even if stale in-Horde flags keep
    -- in_run true outside the Horde (not during its own Alfred trip).
    horde.st.last_result, horde.st.alfred_trip = 'completed', true
    f.to_gate()
    f.run(10)
    eq(horde.disables, 1, 'kept during its own Alfred trip')
    horde.st.alfred_trip, horde.done = false, true
    truthy(f.until_true(function() return horde.disables == 2 end, 10), 'completed run released\n' .. f.dump())
    -- An adopted run HordeDev still reports in compass mode (W5-1: it refused
    -- the War Plan retag) is released right after its exit (its own
    -- start_dungeon would use a compass 5 s later).
    local g = fixture({world = BSK_WORLD, zone = BSK_ZONE, town = false})
    local h2 = g.horde({in_run = true, entry_mode = 'compass'}); h2.enabled = true
    h2.enable = function() h2.enables = h2.enables + 1 end   -- ignores {entry = 'warplan'}
    g.quests = {HORDE}
    g.tick()
    eq(g.logged('adopted active InfernalHordesPlugin'), 1, 'adopted inside the Horde')
    g.run(5)
    eq(h2.enables, 1, 'War Plan retag tried once')
    h2.st.in_run = false
    g.to_gate()
    g.tick()
    eq(h2.disables, 1, 'released at once after the exit')
end)

case('F-W1 no War Plan teleport into the Horde when HordeDev is not loaded', function()
    local f = fixture()
    f.quests = {HORDE}
    f.run(20)
    eq(f.teleports, 0, 'nothing would run the Horde')
    truthy(f.o.get_status_line():find('InfernalHordesPlugin not loaded', 1, true), f.o.get_status_line())
end)

case('F-W1 the status line shows the War Plan wait at once', function()
    local f = fixture()
    f.horde()
    f.quests = {HORDE}
    f.tick()
    local line = f.o.get_status_line()
    truthy(line:find('War Plan teleport', 1, true), 'status line: ' .. line)
end)

-- ── round 5, part A ─────────────────────────────────────────────────────────
-- W5-1 (critic r4 regression 2): a HordeDev WarPigs adopts (or finds on and
-- owns) inside the Horde in compass mode is switched to War Plan mode once.
case('W5-1 an adopted HordeDev running inside the Horde in compass mode is switched to War Plan mode once', function()
    for _, tp in ipairs({false, true}) do
        local label = tp and 'teleport on' or 'teleport off'
        local f = fixture({teleport = tp, world = BSK_WORLD, zone = BSK_ZONE, town = false})
        -- A QQT reload mid-horde: HordeDev's toggle was persisted on by WarPigs.
        local horde = f.horde({in_run = true, entry_mode = 'compass'}); horde.enabled = true
        f.quests = {HORDE}
        f.tick()
        eq(f.logged('adopted active InfernalHordesPlugin'), 1, label .. ': adopted in place')
        eq(horde.enables, 1, label .. ': one enable (d275b9d/9e01f67: none, compass mode kept)')
        eq(horde.args[1], 'warplan', label .. ": enable({entry = 'warplan'})")
        eq(horde.st.entry_mode, 'warplan', label)
        eq(f.logged('switching it to War Plan entry mode'), 1, label .. ': logged')
        f.run(30)
        eq(horde.enables, 1, label .. ': once'); eq(horde.disables, 0, label .. ': the run is kept')
        eq(f.teleports, 0, label); eq(f.waypoints, 0, label)
        -- War Plan completion and exit: released after the settle.
        horde.st.in_run, horde.st.last_result, horde.done = false, 'completed', true
        f.to_gate()
        truthy(f.until_true(function() return horde.disables == 1 end, 5), label .. ': released after the War Plan exit')
    end
    -- Found on and owned: an owned HordeDev that reports compass mode inside
    -- the Horde (e.g. enabled by hand meanwhile) is switched back once.
    local g = fixture()
    local h2 = g.horde({in_run = true})
    g.warplan_to(g.to_bsk)
    g.quests = {HORDE}
    truthy(g.until_true(function() return h2.enables == 1 end, 10), 'entered in War Plan mode')
    h2.st.entry_mode = 'compass'
    g.run(2)
    eq(h2.enables, 2, 'switched back to War Plan mode'); eq(h2.args[2], 'warplan')
    h2.st.entry_mode = 'compass'
    g.run(10)
    eq(h2.enables, 2, 'once per ownership')
    -- Not: War Plan entry off, a HordeDev without entry_mode, the explicit
    -- compass fallback, a HordeDev outside the Horde.
    local off = fixture({warplan = false, world = BSK_WORLD, zone = BSK_ZONE, town = false})
    local h3 = off.horde({in_run = true, entry_mode = 'compass'}); h3.enabled = true
    off.quests = {HORDE}; off.run(5)
    eq(h3.enables, 0, 'option off: unchanged')
    local legacy = fixture({world = BSK_WORLD, zone = BSK_ZONE, town = false})
    local h4 = legacy.horde({in_run = true}); h4.enabled = true
    legacy.quests = {HORDE}; legacy.run(5)
    eq(h4.enables, 0, 'no entry_mode published: not switched')
    local fb = fixture({fallback = true})
    local h5 = fb.horde()
    fb.warplan_to(fb.to_gate)
    fb.quests = {HORDE}
    truthy(fb.until_true(function() return h5.enables == 1 end, 40), 'compass fallback engaged')
    h5.st.in_run = true
    fb.to_bsk()
    fb.run(10)
    eq(h5.enables, 1, 'the explicit compass fallback keeps compass mode inside the Horde')
    local out = fixture({world = 'Sanctuary', zone = 'Kehj_Caldeum'})
    local h6 = out.horde({in_run = true, entry_mode = 'compass'}); h6.enabled = true
    out.quests = {HORDE}; out.run(5)
    eq(h6.enables, 0, 'outside the Horde: not switched')
end)

-- W5-2 (critic r4 regression 3): in War Plan mode a trip out of the Horde
-- HordeDev did not start is not the end of the run.
case('W5-2 a War Plan run out of the Horde without "completed" is kept during Alfred work and a cast; bounded 30 s', function()
    local f = fixture()
    local horde = f.horde({in_run = true})
    f.warplan_to(f.to_bsk)
    f.quests = {HORDE}
    truthy(f.until_true(function() return horde.enables == 1 end, 10), 'War Plan horde')
    f.run(5)
    -- Alfred's own with-teleport cycle takes the player to Temis mid-wave.
    f.alfred({enabled = true, trigger_tasks = true, running = true, teleport = true})
    horde.st.in_run = false
    f.set_zone('Sanctuary', 'Skov_Temis', true)
    f.run(60)
    eq(horde.disables, 0, 'not released during Alfred live work (9e01f67: "finished" after 3 s)\n' .. f.dump())
    eq(f.logged('finished its War Plan run'), 0, 'no false "finished" line')
    eq(f.waypoints, 0); eq(f.teleports, 1)
    -- Alfred's portal returns the player into the same Horde.
    f.alfred_status = {enabled = true}
    f.to_bsk(); horde.st.in_run = true
    f.run(40)
    eq(horde.disables, 0, 'the same run continues')
    -- A revive outside the Horde: no Alfred work; a teleport cast restarts the
    -- window; released after HORDE_LEFT_SETTLE with the real reason.
    horde.st.in_run = false
    f.to_gate()
    f.run(20)
    f.casting = true; f.run(5); f.casting = false
    f.run(20)
    eq(horde.disables, 0, 'the teleport cast restarted the window')
    truthy(f.until_true(function() return horde.disables == 1 end, 15), 'released after 30 s outside\n' .. f.dump())
    eq(f.logged('left the Horde without a completed run'), 1, 'the real reason is logged')
    eq(f.logged('finished its War Plan run'), 0)
    -- 'completed' is the finish signal: released after the 3 s settle.
    local g = fixture()
    local h2 = g.horde({in_run = true})
    g.warplan_to(g.to_bsk)
    g.quests = {HORDE}
    truthy(g.until_true(function() return h2.enables == 1 end, 10), 'War Plan horde')
    h2.st.in_run, h2.st.last_result, h2.done = false, 'completed', true
    g.to_gate()
    g.run(2)
    eq(h2.disables, 0, 'settle')
    truthy(g.until_true(function() return h2.disables == 1 end, 3), 'released ~3 s after "completed"')
    eq(g.logged('finished its War Plan run (completed)'), 1)
end)

case('W5-2 Use teleport on: the via-Temis preamble never teleports out of a Horde the War Plan flow wants', function()
    -- (a) The transition is armed (a foreign HordeDev stopped in Temis) and
    -- the player stands in the Horde when the preamble would start.
    local f = fixture({teleport = true})
    local horde = f.horde({in_run = false}); horde.enabled = true
    f.quests = {HORDE}
    f.tick()
    eq(horde.disables, 1, 'the foreign HordeDev is stopped (arms the transition)')
    f.to_bsk()
    f.run(15)
    eq(f.waypoints, 0, 'no teleport_to_waypoint(Temis) from inside the Horde (9e01f67: sent)\n' .. f.dump())
    eq(f.teleports, 0, 'no War Plan teleport from inside the Horde')
    eq(f.logged('already inside the incoming activity (InfernalHordesPlugin)'), 1, 'in place')
    eq(horde.enables, 1, 'started in place'); eq(horde.args[1], 'warplan')
    -- (b) The preamble's Alfred step runs in Temis and Alfred's portal puts the
    -- player back into the Horde before the warplan teleport would fire.
    local g = fixture({teleport = true})
    local h2 = g.horde()
    g.alfred({enabled = true})
    g.quests = {HORDE}
    truthy(g.until_true(function() return #g.alfred_triggers == 1 end, 10), 'preamble Alfred step\n' .. g.dump())
    g.alfred_status = {enabled = true, trigger_tasks = true, running = true}
    g.run(2)
    g.to_bsk()
    g.alfred_status = {enabled = true}
    g.run(20)
    eq(g.teleports, 0, 'no warplan teleport from inside the Horde (9e01f67: fired from BSK)\n' .. g.dump())
    eq(g.waypoints, 0)
    eq(h2.enables, 1, 'started in place'); eq(h2.args[1], 'warplan')
end)

-- W5-3 (critic r4 new low item): a War Plan landing in a BSK world/zone that
-- is not the Horde never engages the compass fallback.
case('W5-3 a landing in a BSK zone HordeDev does not know keeps the backoff; the fallback stays for other landings', function()
    for _, v in ipairs({{'S05_BSK_Prototype02', 'S05_BSK_Lobby'}, {'WarPlan_Hordes', BSK_ZONE}}) do
        for _, fallback in ipairs({true, false}) do
            local label = v[2] .. '/' .. v[1] .. (fallback and ', fallback on' or ', fallback off')
            local f = fixture({fallback = fallback})
            local horde = f.horde()
            f.warplan_to(function() f.set_zone(v[1], v[2], false) end)
            f.quests = {HORDE}
            f.run(40)
            eq(f.teleports, 3, label .. ': three War Plan teleports')
            eq(horde.enables, 0, label .. ': no compass entry (9e01f67 with the fallback: enable() after the third miss)')
            eq(f.logged('compass fallback is on'), 0, label)
            eq(f.logged('landed in a BSK zone HordeDev does not know (zone=' .. v[2] .. ', world=' .. v[1] .. ') — please report'),
                1, label .. ': reason logged once\n' .. f.dump())
            local line = f.o.get_status_line()
            truthy(line:find('landed in a BSK zone HordeDev does not know (zone=' .. v[2], 1, true)
                and line:find('please report', 1, true) and line:find('retrying the War Plan teleport in', 1, true),
                label .. ': status line: ' .. line)
            f.run(30)
            eq(f.teleports, 3, label .. ': 60 s backoff')
            truthy(f.until_true(function() return f.teleports == 4 end, 20), label .. ': retried after the backoff')
            eq(horde.enables, 0, label .. ': still no compass')
        end
    end
    -- A landing outside the BSK family (the Caldeum gate) still engages the
    -- ticked fallback (unchanged).
    local g = fixture({fallback = true})
    local h2 = g.horde()
    g.warplan_to(g.to_gate)
    g.quests = {HORDE}
    truthy(g.until_true(function() return h2.enables == 1 end, 40), 'fallback at the gate')
    eq(h2.args[1], 'none'); eq(g.logged('landed in a BSK zone'), 0)
end)

-- ── part B: the joint host (all nine real plugins) ──────────────────────────
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local WP, PUG, SR, HD = 'WarPigs-1.0.0', 'WarPug-1.0.0', 'SilentRaven-0.1.3', 'HordeDev-1.3.9'
local function el(h, dir) return assert(h.mod(dir, dir == SR and 'silent_raven.gui' or 'gui'), dir).elements end
local function joint(opts)
    local h = J.new({})
    h.assert_clean('load')
    h.instrument_exports()
    el(h, WP).main_toggle:set(true); el(h, PUG).main_toggle:set(true); el(h, SR).main_toggle:set(true)
    if opts.teleport then el(h, WP).use_teleport_transition:set(true) end
    local items = {}
    h.G.use_item = function(item) items[#items + 1] = {t = h.now, item = item} end
    h.items = items
    local args = {}
    local enable = h.G.InfernalHordesPlugin.enable
    h.G.InfernalHordesPlugin.enable = function(o)
        args[#args + 1] = type(o) == 'table' and tostring(o.entry) or 'none'
        return enable(o)
    end
    h.horde_args = args
    return h
end

case('F-W1 joint: GUI defaults, Temis -> War Plan teleport -> Horde -> HordeDev War Plan mode, no compass', function()
    for _, tp in ipairs({false, true}) do
        local label = tp and 'teleport on' or 'teleport off'
        local h = joint({teleport = tp})
        eq(el(h, WP).horde_warplan_entry:get(), true, 'War Plan entry default ON')
        eq(el(h, WP).horde_compass_fallback:get(), false, 'compass fallback default OFF')
        h.warplan_dest = 'bsk'
        h.set_quests({HORDE})
        local ok = h.run_until(function()
            return h.as(WP, function() return h.G.InfernalHordesPlugin.status().enabled end) == true
        end, 40)
        truthy(ok, label .. ': HordeDev enabled\n' .. h.tail())
        eq(h.place, h.P.bsk, label .. ': enabled inside the Horde')
        eq(h.horde_args[1], 'warplan', label .. ': enable({entry = "warplan"})')
        eq(#h.horde_args, 1, label .. ': one enable')
        eq(h.count(h.warplans, function(w) return w.kind == 'teleport' and w.context == WP end), 1,
            label .. ': one War Plan teleport by WarPigs')
        eq(h.logged('landed world=' .. BSK_WORLD .. ' zone=' .. BSK_ZONE .. ', inside the Horde'), 1,
            label .. ': landing logged once')
        h.run(10)
        eq(#h.items, 0, label .. ': no use_item (compass)')
        eq(h.count(h.waypoints, function(w) return w.context == HD end), 0, label .. ': no HordeDev waypoint (Library)')
        h.assert_clean(label)
    end
end)

case('F-W1 joint: the War Plan teleport lands at the gate three times -> no compass, HordeDev never started', function()
    local h = joint({})
    h.warplan_dest = 'caldeum'
    h.set_quests({HORDE})
    h.run(60)
    eq(#h.horde_args, 0, 'HordeDev never enabled outside the Horde')
    eq(#h.items, 0, 'no use_item (compass)')
    eq(h.count(h.warplans, function(w) return w.kind == 'teleport' end), 3, 'three War Plan teleports, then the backoff')
    eq(h.logged('not using a compass (compass fallback off)'), 1)
    local line = h.as(WP, function() return h.mod(WP, 'core.orchestrator').get_status_line() end)
    truthy(line:find('did not reach the Horde', 1, true), 'status line: ' .. line)
    h.assert_clean('gate x3')
end)

-- ── round 5, part B (the critic's round-4 probes as joint regressions) ──────
local LIBRARY_WP = 0x10D63D
local function wp_horde_calls(h, name)
    local out = {}
    for _, c in ipairs(h.api_calls) do
        if c.export == 'InfernalHordesPlugin' and c.name == name and c.context == WP then out[#out + 1] = c end
    end
    return out
end
local function log_at(h, text)
    for _, line in ipairs(h.log) do
        if line:find(text, 1, true) then return tonumber(line:match('^(%-?[%d%.]+)')) end
    end
    return nil
end
local function horde_status(h) return h.as(WP, function() return h.G.InfernalHordesPlugin.status() end) end
local function first_arrival_after(h, t, place)
    for _, a in ipairs(h.arrivals) do if a.t >= t and a.place == place then return a end end
    return nil
end

-- probe_reload_midhorde: a QQT reload in the middle of a War Plan horde. The
-- toggles were persisted on (WarPigs sets HordeDev's main_toggle); WarPigs
-- adopts the running HordeDev. 9e01f67: compass mode stays, a horde without a
-- chest room never exits ('cleanup still pending', 600 s in BSK).
case('W5-1 joint: reload mid-horde (persisted toggles, place=bsk): War Plan mode at once, the run completes and exits', function()
    local PERSISTED = {infernal_horde_main_toggle = true, war_pigs_main_toggle = true, war_pug_main_toggle = true,
        silent_raven_main_toggle = true}
    for _, v in ipairs({{'chest room', true, true}, {'no chest room, no stash', false, false},
        {'no chest room, stash', false, true}, {'no chest room, Use teleport on', false, false, true}}) do
        local label = 'W5-1 ' .. v[1]
        local persisted = J.copy(PERSISTED)
        if v[4] then persisted.war_pigs_use_teleport_transition = true end
        local h = J.new({place = 'bsk', persisted = persisted})
        h.assert_clean('load')
        h.instrument_exports()
        h.give_compasses(3)
        local A = h.setup_horde({chest_room = v[2], stash = v[3]})
        h.warplan_dest = 'bsk'
        h.set_quests({HORDE})
        local mode_at
        local done = h.run_until(function()
            if not mode_at and horde_status(h).entry_mode == 'warplan' then mode_at = h.now end
            return #h.quests == 0
        end, 300)
        truthy(done, label .. ': the horde and the turn-in complete (9e01f67: stuck in BSK)\n' .. h.tail())
        h.run(3)
        h.assert_clean(label)
        truthy(mode_at and mode_at <= 1001.0 + 1e-6, label .. ': War Plan mode within 1 s: ' .. tostring(mode_at))
        eq(h.logged('adopted active InfernalHordesPlugin'), 1, label .. ': adopted')
        eq(h.logged('switching it to War Plan entry mode'), 1, label .. ': retag logged once')
        local enables = wp_horde_calls(h, 'enable')
        eq(#enables, 1, label .. ': one enable'); eq(enables[1].entry, 'warplan', label); eq(enables[1].place, 'bsk', label)
        eq(h.logged('No enable/disable from WarPigs within 5s'), 0, label .. ': the F-H2 wait ends at once')
        eq(A.runs, 1, label .. ': one horde'); eq(A.wave, 6, label); truthy(A.council_dead_at, label .. ': Council dead')
        eq(h.leaves, 1, label .. ': Leave Dungeon')
        eq(h.logged('War Plan horde complete; no new cycle'), 1, label .. ': completed')
        eq(h.logged('cleanup still pending'), 0, label)
        eq(#h.items, 0, label .. ': no compass')
        eq(h.count(h.waypoints, function(w) return w.sno == LIBRARY_WP end), 0, label .. ': no Library teleport')
        eq(h.logged('turn-in cycle completed'), 1, label .. ': turn-in')
    end
end)

-- probe_alfred_selfstart_trace: Alfred's own with-teleport cycle mid-wave
-- (another caller) takes the player to Temis and its portal returns him into
-- the same horde. 9e01f67: WarPigs released HordeDev as 'finished'; with
-- 'Use teleport' on its preamble then sent teleport_to_waypoint(Temis) from
-- inside BSK and a second horde started.
case('W5-2 joint: Alfred\'s own teleport trip mid-wave: HordeDev kept, no Temis teleport from BSK, one horde', function()
    for _, tp in ipairs({false, true}) do
        local label = 'W5-2 ' .. (tp and 'teleport on' or 'teleport off')
        local h = joint({teleport = tp})
        local A = h.setup_horde({})
        h.warplan_dest = 'bsk'
        h.set_quests({HORDE})
        truthy(h.run_until(function() return A.wave >= 3 end, 300), label .. ': wave 3\n' .. h.tail())
        local mark = h.now
        h.as(h.alfred_ctx, function() h.G.AlfredTheButlerPlugin.trigger_tasks_with_teleport('AlfredTheButler', nil) end)
        h.alfred.work = 20
        truthy(h.run_until(function() return #h.quests == 0 end, 400), label .. ': horde and turn-in\n' .. h.tail())
        h.run(3)
        h.assert_clean(label)
        truthy(first_arrival_after(h, mark, 'temis'), label .. ': Alfred took the player to Temis')
        eq(A.runs, 1, label .. ': one horde (9e01f67 teleport on: 2)'); eq(A.wave, 6, label)
        truthy(A.council_dead_at, label .. ': Council dead')
        local completed = log_at(h, 'War Plan horde complete; no new cycle')
        truthy(completed, label .. ': completed')
        for _, c in ipairs(wp_horde_calls(h, 'disable')) do
            truthy(c.t >= completed, string.format('%s: HordeDev released only after its completion (disable at %.1f, '
                .. 'completed %.1f)', label, c.t, completed))
        end
        eq(#wp_horde_calls(h, 'enable'), 1, label .. ': one enable')
        eq(h.count(h.waypoints, function(w) return w.from == 'bsk' end), 0, label .. ': no teleport_to_waypoint from BSK')
        eq(h.count(h.warplans, function(w) return w.kind == 'teleport' and w.from == 'bsk' end), 0,
            label .. ': no War Plan teleport from BSK')
        eq(h.logged('finished its War Plan run'), 0, label .. ': no false "finished" line')
        eq(h.logged('left the Horde without a completed run'), 0, label)
        eq(#h.items, 0, label .. ': no compass')
        eq(h.logged('turn-in cycle completed'), 1, label .. ': turn-in')
    end
end)

-- probe_landing_variants: the War Plan teleport lands in a BSK lobby (a BSK
-- world, another zone) with the compass fallback ticked. 9e01f67: enable()
-- in the lobby, then a Library teleport and a compass.
case('W5-3 joint: War Plan landings in a BSK lobby with the fallback ticked: no compass, reason and report shown', function()
    local h = joint({})
    el(h, WP).horde_compass_fallback:set(true)
    local lobby = {key = 'lobby', name = 'S05_BSK_Prototype02', zone = 'S05_BSK_Lobby', id = 6, town = false,
        spawn = h.v(0, 0), box = {-80, 80, -80, 80}, actors = {}}
    h.P.lobby = lobby
    h.give_compasses(2)
    h.warplan_dest = lobby
    h.set_quests({HORDE})
    local seen
    h.run(100, function()
        local line = h.as(WP, function() return h.mod(WP, 'core.orchestrator').get_status_line() end)
        if line:find('landed in a BSK zone HordeDev does not know (zone=S05_BSK_Lobby', 1, true)
            and line:find('please report', 1, true) then seen = line end
    end)
    h.assert_clean('W5-3')
    eq(#h.horde_args, 0, 'HordeDev never enabled (9e01f67: enable() in the lobby at +19 s)')
    eq(#h.items, 0, 'no compass')
    eq(h.count(h.waypoints, function(w) return w.sno == LIBRARY_WP end), 0, 'no Library teleport')
    local tps = h.count(h.warplans, function(w) return w.kind == 'teleport' end)
    truthy(tps >= 3 and tps <= 6, 'War Plan teleports with the backoff: ' .. tps)
    eq(h.logged('compass fallback is on'), 0)
    truthy(h.logged('landed in a BSK zone HordeDev does not know (zone=S05_BSK_Lobby, world=S05_BSK_Prototype02) — please report') >= 1,
        'reported in the log')
    truthy(seen, 'status line shows the BSK landing and asks for a report')
end)

if #failures > 0 then error(#failures .. ' War Plan Horde (WarPigs) regressions failed:\n' .. table.concat(failures, '\n\n')) end
print('PASS War Plan Horde entry (WarPigs): ' .. checks .. ' checks')
