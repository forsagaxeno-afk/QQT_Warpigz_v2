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
    -- reports in_run=false; it never starts a second cycle itself.
    horde.st.in_run, horde.done = false, true
    f.to_gate()
    f.quests = {HORDE, 'WarPlans_QST_InfernalHordes_BSK_2'}
    truthy(f.until_true(function() return horde.disables == 1 end, 10), 'finished run released\n' .. f.dump())
    eq(f.logged('finished its War Plan run'), 1)
    horde.st.in_run = true
    truthy(f.until_true(function() return horde.enables == 2 end, 20), 'next Horde entered\n' .. f.dump())
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
    -- An adopted run HordeDev reports in compass mode is released right after
    -- its exit (its own start_dungeon would use a compass 5 s later).
    local g = fixture({world = BSK_WORLD, zone = BSK_ZONE, town = false})
    local h2 = g.horde({in_run = true, entry_mode = 'compass'}); h2.enabled = true
    g.quests = {HORDE}
    g.tick()
    eq(g.logged('adopted active InfernalHordesPlugin'), 1, 'adopted inside the Horde')
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

if #failures > 0 then error(#failures .. ' War Plan Horde (WarPigs) regressions failed:\n' .. table.concat(failures, '\n\n')) end
print('PASS War Plan Horde entry (WarPigs): ' .. checks .. ' checks')
