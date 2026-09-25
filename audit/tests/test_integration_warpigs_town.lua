-- Integration regressions for WarPigs' town side: the canonical Alfred reading
-- (C1: WPT-1, WPD-5/WPT-5), the Whisper slot / plan-creator circular wait
-- (WPT-2 = WPG-3 = SRV-1), the Temis Alfred kick versus WarPug (WPT-3 /
-- WPG-4), the bounded Whisper admission and in-visit retry (SRV-2), the
-- Looter quiet window (L7) and the bounded town traffic hold (C6).
-- Loads the real orchestrator, SilentRaven bridge, turn-in task and external
-- API (and, in one case, the real WarPug planner) with QQT-shaped host mocks
-- in an isolated environment. Companion plugins are mocked by their public
-- status contracts.
local root = assert(SUITE_ROOT) .. '/WarPigs-1.0.0/'
local pug_root = SUITE_ROOT .. '/WarPug-1.0.0/'
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

local function fixture(opts)
    opts = opts or {}
    local f = {now = 100, zone = opts.zone or 'Skov_Temis', world = 'Sanctuary', town = opts.town ~= false,
        quests = {}, logs = {}, waypoints = 0, teleports = 0, alfred_calls = {}, sr_triggers = 0,
        interacts = 0, moves = 0, dist = 1}
    local e = setmetatable({}, {__index = _G}); e._G = e
    e.console = {print = function(m) f.logs[#f.logs + 1] = string.format('%.1f %s', f.now, tostring(m)) end}
    e.attributes = {PLAYER_IN_TOWN_LEVEL_AREA = 'town'}
    e.get_time_since_inject = function() return f.now end
    e.get_local_player = function() return {
        is_dead = function() return false end,
        get_attribute = function() return f.town and 1 or 0 end,
        get_buffs = function() return {} end,
        get_position = function() return {} end,
    } end
    e.get_current_world = function() return {
        get_name = function() return f.world end,
        get_current_zone_name = function() return f.zone end,
        get_world_id = function() return 7 end,
    } end
    e.get_quests = function()
        local out = {}
        for _, name in ipairs(f.quests) do out[#out + 1] = {get_name = function() return name end} end
        return out
    end
    local function actor(name) return {get_skin_name = function() return name end, get_position = function() return {} end} end
    f.actors = {actor('NPC_QST_X2_Tyrael_NonCombat'), actor('Warplans_Vendor')}
    e.actors_manager = {get_all_actors = function() return f.actors end}
    e.get_player_position = function() return {dist_to = function() return f.dist end} end
    e.loot_manager = {interact_with_object = function() f.interacts = f.interacts + 1 end}
    e.pathfinder = {request_move = function() f.moves = f.moves + 1 end}
    e.teleport_to_waypoint = function() f.waypoints = f.waypoints + 1 end
    e.warplan = {teleport_to_activity = function()
        f.teleports = f.teleports + 1
        if f.on_warplan then f.on_warplan() end
    end}
    e.get_aether_count = function() return 0 end
    e.revive_at_checkpoint = function() end
    f.settings = {enabled = true, manage_whispers = opts.whispers == true,
        use_teleport_transition = opts.teleport == true, run_pit_after_turnin = false,
        manage_orbwalker = false, get_keybind_state = function() return true end,
        update_settings = function() end, plugin_label = 'war_pigs', plugin_version = 'test'}
    local modules = {['core.settings'] = f.settings,
        gui = {elements = {main_toggle = {get = function() return true end, set = function() end}}}}
    if opts.task_stub then modules['core.tasks.turn_in_rewards'] = opts.task_stub end
    e.require = function(name)
        if modules[name] ~= nil then return modules[name] end
        local value = assert(loadfile(root .. name:gsub('%.', '/') .. '.lua', 't', e))()
        modules[name] = value
        return value
    end
    f.e = e
    f.o = e.require('core.orchestrator')
    f.task = e.require('core.tasks.turn_in_rewards')
    e.WarPigsPlugin = e.require('core.external')

    -- Alfred mock: a trigger starts a `cycle`-second run (running=true), then
    -- clears `clears` flags and calls the completion callback.
    function f.alfred(status, cycle, clears)
        f.alfred_status, f.alfred_cycle, f.alfred_clears = status, cycle, clears
        e.AlfredTheButlerPlugin = {
            get_status = function()
                if f.alfred_throw then error('status unavailable') end
                return f.alfred_status
            end,
            trigger_tasks = function(caller, callback)
                f.alfred_calls[#f.alfred_calls + 1] = {caller = caller, at = f.now, zone = f.zone}
                f.alfred_cb = callback
                if f.alfred_cycle then
                    f.alfred_status.running = true
                    f.alfred_done_at = f.now + f.alfred_cycle
                end
                return true
            end,
            resume = function() return true end,
        }
    end
    -- SilentRaven v2 contract mock (managed request, guard, cancel). With
    -- `yield_aware` it implements the R15 contract: a guard answer
    -- (false, 'yield:<reason>') pauses the request and keeps it; the walk
    -- (walked seconds) resumes where it stopped. Without it, any false is a
    -- cancel (an older SilentRaven).
    function f.sr(enabled, yield_aware)
        local s = {api_version = 2, enabled = enabled ~= false, running = false, pending = false}
        f.sr_status, f.sr_yield_aware, f.sr_pauses, f.sr_walked = s, yield_aware == true, 0, 0
        e.SilentRavenPlugin = {
            get_status = function() return s end,
            set_managed = function(caller, value) s.managed_by = value and caller or nil; return true end,
            trigger_tasks = function(caller, callback, guard)
                if s.running or s.pending then return false end
                f.sr_triggers = f.sr_triggers + 1; f.sr_trigger_at = f.now
                f.sr_callback, f.sr_guard = callback, guard
                s.pending, s.owner = true, caller
                return true
            end,
            cancel = function(caller)
                if s.owner ~= caller then return false end
                s.running, s.pending, s.owner, s.last_result = false, false, nil, 'cancelled'
                if f.sr_callback then local cb = f.sr_callback; f.sr_callback = nil; cb('cancelled') end
                return true
            end,
        }
    end
    function f.sr_finish(result, reason)
        local s = f.sr_status
        s.pending, s.running, s.owner, s.last_result, s.last_reason = false, false, nil, result, reason
        s.state, s.yield = nil, nil
        if f.sr_callback then local cb = f.sr_callback; f.sr_callback = nil; cb(result) end
    end
    function f.looter(busy)
        f.looting = busy
        e.LooteerPlugin = {get_enabled = function() return true end,
            is_actively_looting = function()
            if f.looting then f.last_busy_read = f.now end
            return f.looting
        end}
    end
    function f.warpug(state)
        f.pug_state = state
        e.WarPugPlugin = {status = function() return {enabled = true, state = f.pug_state} end}
    end
    function f.plugin(name, enabled)
        local p = {enabled = enabled == true, enables = 0, disables = 0}
        p.enable = function() p.enabled = true; p.enables = p.enables + 1 end
        p.disable = function() p.enabled = false; p.disables = p.disables + 1 end
        p.status = function() return {enabled = p.enabled} end
        e[name] = p
        return p
    end
    function f.tick(dt)
        f.now = f.now + (dt or 0.5)
        if f.alfred_done_at and f.now >= f.alfred_done_at then
            f.alfred_done_at = nil
            f.alfred_status.running = false
            for _, k in ipairs(f.alfred_clears or {}) do f.alfred_status[k] = nil end
            if f.alfred_cb then local cb = f.alfred_cb; f.alfred_cb = nil; cb('success') end
        end
        -- SilentRaven consults the continuation guard on every pulse.
        local s = f.sr_status
        if s and (s.pending or s.running) and f.sr_guard then
            local ok, why = f.sr_guard()
            if not ok and f.sr_yield_aware and type(why) == 'string' and why:find('yield:', 1, true) == 1 then
                if not s.yield then f.sr_pauses = f.sr_pauses + 1 end
                s.yield = why
            elseif not ok then
                f.sr_finish('cancelled', why)
            elseif f.sr_yield_aware then
                s.yield = nil
                if s.pending then s.pending, s.running, s.state = false, true, 'WALK_NPC' end
                if s.state == 'WALK_NPC' then f.sr_walked = f.sr_walked + 0.5 end
            end
        end
        f.o.tick()
        if f.each then f.each() end
    end
    function f.run(seconds)
        local stop = f.now + seconds
        while f.now < stop - 1e-9 do f.tick(0.5) end
    end
    function f.until_true(predicate, seconds)
        local start, stop = f.now, f.now + seconds
        while f.now < stop - 1e-9 do
            f.tick(0.5)
            if predicate() then return f.now - start end
        end
        return nil
    end
    function f.logged(text)
        local n = 0
        for _, m in ipairs(f.logs) do if m:find(text, 1, true) then n = n + 1 end end
        return n
    end
    return f
end

-- ── C1 / WPT-1 ──────────────────────────────────────────────────────────────
case('WPT-1 a latched finished teleport is not live Alfred work', function()
    local f = fixture()
    for _, terminal in ipairs({'teleport_done', 'teleport_failed'}) do
        f.alfred({enabled = true, teleport = true, [terminal] = true})
        eq(f.o.alfred_idle(), true, 'latched teleport with ' .. terminal .. ' is idle')
        eq(f.e.WarPigsPlugin.status().alfred_idle, true, 'exported alfred_idle follows C1')
    end
    f.alfred({enabled = true, teleport = true})
    eq(f.o.alfred_idle(), false, 'a teleport still in flight is live work')
    for _, live in ipairs({'trigger_tasks', 'external_trigger', 'pending', 'running'}) do
        f.alfred({enabled = true, [live] = true})
        eq(f.o.alfred_idle(), false, live .. ' is live work')
    end
    f.alfred({enabled = false, running = true, inventory_full = true})
    eq(f.o.alfred_idle(), true, 'a disabled Alfred is never busy')
end)

case('WPT-1 via-Temis preamble triggers Alfred instead of joining a finished trip', function()
    local f = fixture({teleport = true})
    local ark = f.plugin('ArkhamAsylumPlugin')
    f.alfred({enabled = true, teleport = true, teleport_done = true}, 5)
    f.on_warplan = function() f.world = 'PIT_Test_World' end
    f.quests = {'WarPlans_QST_ThePit'}
    truthy(f.until_true(function() return #f.alfred_calls > 0 end, 10), 'Alfred was actually triggered')
    eq(f.alfred_calls[1].caller, 'WarPigs')
    truthy(f.until_true(function() return f.teleports > 0 end, 40),
        'warplan teleport fires after the Alfred cycle (no 180 s join/bounce loop)')
    truthy(f.until_true(function() return ark.enables > 0 end, 30), 'Arkham enabled for the Pit')
    eq(f.logged('Alfred max wait'), 0, 'never waited for a phantom cycle')
    eq(f.logged('re-armed during settle'), 0)
end)

case('WPT-1 turn-in walks to Tyrael with a latched teleport, yields to one in flight', function()
    local f = fixture()
    f.alfred({enabled = true, teleport = true})
    f.quests = {'WarPlans_QST_TurnIn_Rewards'}
    f.run(10)
    eq(f.interacts, 0, 'teleport in flight: turn-in yields')
    f.alfred_status.teleport_done = true
    truthy(f.until_true(function() return f.interacts > 0 end, 10), 'turn-in reached Tyrael')
    eq(f.task.get_state(), 'APPROACH_NPC')
end)

case('C1 unreadable Alfred status: busy at most ~10 s, then unavailable (logged once)', function()
    local f = fixture()
    f.alfred({enabled = true}); f.alfred_throw = true
    f.quests = {'WarPlans_QST_TurnIn_Rewards'}
    f.run(8)
    eq(f.o.alfred_idle(), false, 'unreadable Alfred briefly holds')
    eq(f.interacts, 0, 'turn-in holds while Alfred is unreadable')
    f.run(4)
    eq(f.o.alfred_idle(), true, 'unreadable Alfred stops holding')
    truthy(f.until_true(function() return f.interacts > 0 end, 5), 'turn-in continues without Alfred')
    eq(f.logged('[WarPigs] Alfred unavailable'), 1, 'one orchestrator diagnostic')
    eq(f.logged('[WarPigs:turn_in] Alfred status unreadable'), 1, 'one turn-in diagnostic')
    f.alfred_throw = false; f.alfred({enabled = true})
    eq(f.o.alfred_idle(), true, 'a readable sample ends the unreadable episode')
    f.alfred({enabled = 'yes'})
    f.run(3); eq(f.o.alfred_idle(), false, 'a non-boolean enabled is unreadable too (new bounded episode)')
end)

-- ── WPD-5 / WPT-5 ───────────────────────────────────────────────────────────
case('WPD-5 a paused Alfred without hard work is idle for the turn-in', function()
    local f = fixture({zone = 'Kehj_Kurast'})
    f.alfred({enabled = true, paused = true, paused_by = 'D4Assistant', need_trigger = true, restock_count = 2})
    f.quests = {'WarPlans_QST_TurnIn_Rewards'}
    eq(f.o.alfred_idle(), true, 'paused, advisory only: idle')
    truthy(f.until_true(function() return f.waypoints > 0 end, 10), 'turn-in teleports to Temis')
    f.zone = 'Skov_Temis'
    truthy(f.until_true(function() return f.interacts > 0 end, 10), 'turn-in reaches Tyrael')
    eq(#f.alfred_calls, 0, 'a paused Alfred is never triggered')
end)

case('WPT-5 paused Alfred with hard work: bounded, logged holds (turn-in and preamble)', function()
    local f = fixture()
    f.alfred({enabled = true, paused = true, paused_by = 'D4Assistant', inventory_full = true})
    f.quests = {'WarPlans_QST_TurnIn_Rewards'}
    f.run(50)
    eq(f.interacts, 0, 'turn-in holds for the paused Alfred with work')
    eq(f.logged('[WarPigs:turn_in] waiting — Alfred is paused by D4Assistant with pending work'), 1,
        'hold logged when it starts')
    truthy(f.until_true(function() return f.interacts > 0 end, 15), 'turn-in continues after its bounded hold')
    eq(f.logged('continuing the turn-in'), 1)

    local g = fixture({teleport = true})
    local ark = g.plugin('ArkhamAsylumPlugin')
    g.alfred({enabled = true, paused = true, paused_by = 'D4Assistant', need_trigger = true, inventory_full = true})
    g.on_warplan = function() g.world = 'PIT_Test_World' end
    g.quests = {'WarPlans_QST_ThePit'}
    g.run(150)
    eq(g.teleports, 0, 'preamble holds for the paused Alfred with work')
    truthy(g.logged('holding for it up to 180s') == 1, 'hold is logged')
    truthy(g.until_true(function() return g.teleports > 0 end, 60), 'preamble proceeds after the bounded hold')
    eq(g.logged('no longer holding for it (bounded hold)'), 1)
    truthy(g.until_true(function() return ark.enables > 0 end, 30), 'Arkham enabled')
    eq(#g.alfred_calls, 0, 'a foreign pause is never overridden')
end)

-- ── WPT-2 / WPG-3 / SRV-1 ───────────────────────────────────────────────────
case('WPT-2 a pending teleport with nothing incoming opens the Whisper slot', function()
    local f = fixture({teleport = true, whispers = true})
    f.sr(); f.warpug('IDLE')
    local ark = f.plugin('ArkhamAsylumPlugin', true)   -- persisted toggle after a restart
    f.run(2)
    eq(ark.disables, 1, 'unwanted Arkham disabled in town (arms teleport_pending)')
    eq(f.o.is_busy(), true, 'the Whisper visit is reserved first')
    truthy(f.until_true(function() return f.sr_triggers > 0 end, 15),
        'Whisper check runs although a teleport is pending with no incoming quest')
    eq(f.o.is_busy(), true, 'plan creator waits for the running check')
    f.sr_finish('skipped_not_ready', 'no_completed_whispers')
    truthy(f.until_true(function() return not f.o.is_busy() end, 3), 'WarPug may plan after the visit check')
    eq(f.teleports, 0, 'no warplan teleport without an incoming activity')
    -- The plan appears: the pending teleport now proceeds (no Alfred loaded).
    f.on_warplan = function() f.world = 'PIT_Test_World' end
    f.quests = {'WarPlans_QST_ThePit'}
    truthy(f.until_true(function() return f.teleports > 0 end, 20), 'pending teleport delivers the new plan')
    eq(f.sr_triggers, 1, 'one Whisper check per visit')
end)

case('WPT-2 an incoming quest still keeps the IDLE slot closed until the preamble', function()
    local f = fixture({teleport = true, whispers = true})
    f.sr(); f.warpug('IDLE')
    f.alfred({enabled = true}, 20)
    f.quests = {'WarPlans_QST_ThePit'}           -- cold start: pending WITH incoming
    f.run(2)
    eq(f.sr_triggers, 0, 'no Whisper walk while the incoming activity settles')
    truthy(f.until_true(function() return #f.alfred_calls > 0 end, 5), 'preamble Alfred step')
    f.run(10)
    eq(f.sr_triggers, 0, 'no Whisper walk during the preamble Alfred cycle')
end)

case('WPT-2 / C6 the plan creator is not held when the slot is never offered', function()
    local stub = {tick = function() end, get_state = function() return 'TELEPORTING' end}
    local f = fixture({whispers = true, task_stub = stub})
    f.sr(); f.warpug('IDLE')
    f.run(30)
    eq(f.sr_triggers, 0, 'slot closed (a task is mid-flight)')
    eq(f.o.is_busy(), true, 'Whisper visit still reserved')
    truthy(f.until_true(function() return not f.o.is_busy() end, 40), 'WarPug is released after the bound')
    eq(f.logged('Whisper check not admitted for'), 1, 'release is logged once')
end)

-- ── WPT-3 / WPG-4 ───────────────────────────────────────────────────────────
case('WPT-3 an advisory need_trigger is kicked once per Temis visit', function()
    local f = fixture()
    f.alfred({enabled = true, need_trigger = true, restock_count = 1}, 6)   -- never clears
    f.run(300)
    eq(#f.alfred_calls, 1, 'one no-progress restock trip per visit, not one every ~26 s')
    eq(f.o.alfred_idle(), true, 'the handled advisory flag stays idle for this visit')
    -- A new Temis visit allows one new kick.
    f.zone = 'Kehj_Kurast'; f.run(5)
    eq(#f.alfred_calls, 1, 'no kick outside Temis')
    f.zone = 'Skov_Temis'; f.run(20)
    eq(#f.alfred_calls, 2, 'one kick on the next visit')
    -- Hard need is not limited by the advisory latch.
    f.alfred_status.inventory_full = true; f.run(10)
    truthy(#f.alfred_calls >= 3, 'inventory_full is kicked again')
end)

case('WPG-4 the Temis kick never starts Alfred under an active WarPug session', function()
    for _, flags in ipairs({{need_trigger = true}, {inventory_full = true}}) do
        local f = fixture()
        f.warpug('APPROACH_TABLE')
        local status = {enabled = true}
        for k, v in pairs(flags) do status[k] = v end
        f.alfred(status)
        f.run(20); f.pug_state = 'REROLL_WAIT1'; f.run(20)
        eq(#f.alfred_calls, 0, 'kick deferred while WarPug plans')
        eq(f.logged('not triggering it while WarPug is planning'), 1, 'deferral logged once')
        f.pug_state = 'DONE_WAIT'; f.run(2)
        eq(#f.alfred_calls, 1, 'kick fires once WarPug is done')
    end
end)

case('WPT-3 real WarPug completes and WarPigs kicks the sticky restock only once', function()
    local f = fixture()
    local e = f.e
    -- WarPug planner + external in their own require context.
    local pug = {path = {}, required = 2, confirms = 0, ready = false, clicks = 0,
        edges = {root = {3}, [3] = {4}}, names = {[3] = 'Warplans_Helltide', [4] = 'Warplans_InfernalHordes'}}
    local pug_settings = {enabled = true, table_actor_name = 'Warplans_Vendor', verbose_logs = false,
        reroll_set = true, confirm_set = true, reroll_click_x = 150, reroll_click_y = 700,
        reroll_confirm_x = 700, reroll_confirm_y = 550}
    e.warplan.is_ready = function() return pug.ready end
    e.warplan.required_picks = function() return pug.required end
    e.warplan.selected_count = function() return #pug.path end
    e.warplan.selected_path = function() local c = {}; for i, v in ipairs(pug.path) do c[i] = v end; return c end
    e.warplan.is_complete = function() return #pug.path == pug.required end
    e.warplan.get_selectable_now = function() return pug.edges[pug.path[#pug.path] or 'root'] or {} end
    e.warplan.node_name = function(id) return pug.names[id] end
    e.warplan.select_node = function(id) pug.path[#pug.path + 1] = id; return true end
    e.warplan.deselect_last = function() return table.remove(pug.path) ~= nil end
    e.warplan.confirm = function() pug.confirms = pug.confirms + 1 end
    e.utility = {send_mouse_move = function() end, send_mouse_click = function() pug.clicks = pug.clicks + 1 end}
    e.interact_vendor = function() pug.ready = true end
    e.get_screen_width = function() return 1000 end
    e.get_screen_height = function() return 800 end
    -- A long walk to the table outlasts WarPigs' 20 s completed-cycle grace.
    f.dist = 12
    e.pathfinder.request_move = function() f.moves = f.moves + 1; f.dist = math.max(0, f.dist - 0.1) end
    local modules = {['core.settings'] = pug_settings}
    local env = setmetatable({}, {__index = e})
    env.require = function(name)
        if modules[name] ~= nil then return modules[name] end
        local value = assert(loadfile(pug_root .. name:gsub('%.', '/') .. '.lua', 't', env))()
        modules[name] = value
        return value
    end
    local planner = env.require('core.planner')
    e.WarPugPlugin = env.require('core.external')
    f.each = function() planner.tick() end
    f.alfred({enabled = true, need_trigger = true, restock_count = 1}, 6)
    local started, done_at, halted_before_done
    for _ = 1, 600 do
        f.tick()
        local state = planner.get_current_state()
        if not started and state ~= 'IDLE' then started = f.now end
        if state == 'DONE_WAIT' and not done_at then done_at = f.now end
        if state == 'HALTED' and not done_at then halted_before_done = planner.get_status_line() end
    end
    -- (Without a quest showing up after the confirm, WarPug later halts on its
    -- own DONE_WAIT timeout; that is outside this regression.)
    eq(halted_before_done, nil, 'WarPug never stopped mid-session')
    truthy(done_at, 'WarPug reached DONE_WAIT')
    eq(pug.confirms, 1)
    truthy(started and done_at and done_at - started > 20, 'the session outlived the 20 s grace')
    eq(#f.alfred_calls, 1, 'WarPigs triggered Alfred once in 300 s (was every ~26 s)')
end)

-- ── SRV-2 / L7 ──────────────────────────────────────────────────────────────
case('SRV-2 a 30 s Alfred cycle does not forfeit the Temis Whisper visit', function()
    local f = fixture({whispers = true})
    f.sr()
    f.alfred({enabled = true, need_trigger = true}, 30, {'need_trigger'})
    truthy(f.until_true(function() return #f.alfred_calls > 0 end, 5), 'WarPigs kicks Alfred in Temis')
    local kicked_at = f.alfred_calls[1].at
    f.run(15)
    truthy(tostring(f.o.get_status_line()):find('Whisper check waiting for alfred_busy', 1, true),
        'the admission wait is visible: ' .. tostring(f.o.get_status_line()))
    truthy(f.until_true(function() return f.sr_triggers > 0 end, 30), 'Whisper claimed after Alfred finished')
    truthy(f.sr_trigger_at >= kicked_at + 30, 'not while Alfred was working')
    eq(f.logged('skipped:alfred_busy'), 0, 'the visit was not forfeited at 20 s')
    eq(f.logged('waiting: alfred_busy'), 1, 'wait logged once')
end)

case('SRV-2 a request cancelled by a companion is retried in the visit (bounded)', function()
    local f = fixture({whispers = true})
    f.sr(); f.looter(false)
    truthy(f.until_true(function() return f.sr_triggers == 1 end, 10), 'first request')
    for attempt = 2, 3 do
        f.looting = true; f.run(3)
        eq(f.sr_status.pending, false, 'a Looter pickup revokes the running request')
        f.looting = false
        truthy(f.until_true(function() return f.sr_triggers == attempt end, 10), 'retried in the same visit')
    end
    f.looting = true; f.run(3); f.looting = false; f.run(30)
    eq(f.sr_triggers, 3, 'at most 3 requests per visit')
    -- The bridge reports SilentRaven's own result of the cancelled request,
    -- with the companion cause (joint suite: a finished request's result wins).
    truthy(f.logged('visit 1: cancelled (yield:looter_busy)') + f.logged('visit 1: looter_busy') >= 1,
        'the last cancellation finishes the visit')
    -- A real outcome is never retried.
    local g = fixture({whispers = true})
    g.sr()
    truthy(g.until_true(function() return g.sr_triggers == 1 end, 10))
    g.sr_finish('failed', 'no_valid_reward'); g.run(30)
    eq(g.sr_triggers, 1, 'failed result is final for the visit')
    -- Unknown companion data still gives up early (not after 120 s).
    local h = fixture({whispers = true})
    h.sr(); h.e.LooteerPlugin = {getSettings = function() error('missing') end}
    h.run(25)
    eq(h.sr_triggers, 0); eq(h.logged('skipped:looter_status_unavailable'), 1)
end)

case('L7 the Whisper walk waits for a Looter quiet window (bounded)', function()
    local f = fixture({whispers = true})
    f.sr(); f.looter(false)
    -- approach_stall retries: busy 1 s out of every 3 s.
    local phase = 0
    f.each = function() phase = (phase + 1) % 6; f.looting = phase < 2 end
    f.looting = true
    f.run(30)
    eq(f.sr_triggers, 0, 'no Whisper walk between Looter retries')
    f.each = nil; f.looting = false
    truthy(f.until_true(function() return f.sr_triggers > 0 end, 10), 'walk starts once the Looter is quiet')
    local quiet = f.sr_trigger_at - f.last_busy_read
    truthy(quiet >= 4, 'walk starts after >= 4 s of continuous Looter quiet, got ' .. tostring(quiet))
    -- A Looter that never settles cannot hold the visit forever.
    local g = fixture({whispers = true})
    g.sr(); g.looter(false)
    local p = 0
    g.each = function() p = (p + 1) % 6; g.looting = p < 2 end
    g.run(100)
    eq(g.logged('visit 1: skipped:looter'), 0, 'still waiting (only waiting pulses count)')
    g.run(100)
    eq(g.sr_triggers, 0)
    eq(g.logged('visit 1: skipped:looter'), 1, 'visit given up after the bounded wait')
    eq(g.o.is_busy(), false, 'WarPug is not held after the visit was given up')
end)

-- ── C6 / L5 traffic hold ────────────────────────────────────────────────────
case('C6 the Looter town-traffic hold is bounded and keeps is_busy current', function()
    local f = fixture()
    f.looter(true)
    f.quests = {'WarPlans_QST_TurnIn_Rewards'}
    f.run(10)
    eq(f.interacts, 0, 'Tyrael walk held while the Looter collects')
    eq(f.o.is_busy(), true)
    f.quests = {}; f.run(2)
    eq(f.o.is_busy(), false, 'a vanished quest is not reported busy during the hold')
    f.quests = {'WarPlans_QST_TurnIn_Rewards'}
    truthy(f.until_true(function() return f.interacts > 0 end, 125), 'hold released after its bound')
    eq(f.logged('no longer holding WarPigs town movement'), 1, 'release logged once')
end)

-- ── Round 3 ─────────────────────────────────────────────────────────────────
-- R5: with 'Use teleport' off no teleport is ever pending, so the IDLE Whisper
-- slot stayed open with an activity incoming and the admission wait (up to
-- 120 s) returned from tick() before the ENABLE PHASE.
case('R5 an incoming activity is not held behind the Whisper admission wait', function()
    local f = fixture({whispers = true})
    f.sr()
    local ark = f.plugin('ArkhamAsylumPlugin')
    f.alfred({enabled = true, running = true})   -- a long foreign Alfred cycle in Temis
    f.run(10)
    truthy(tostring(f.o.get_status_line()):find('Whisper check waiting for alfred_busy', 1, true),
        'admission is waiting: ' .. tostring(f.o.get_status_line()))
    f.quests = {'WarPlans_QST_ThePit'}
    local dt = f.until_true(function() return ark.enables > 0 end, 30)
    truthy(dt and dt <= 2, 'Pit enabled at once, got ' .. tostring(dt))
    eq(f.sr_triggers, 0, 'no Whisper walk into the activity start')
    -- Same with 'Use teleport' on and nothing pending (the turn-in consumed it).
    local g = fixture({whispers = true})
    g.sr()
    g.alfred({enabled = true, running = true})
    local reaper = g.plugin('ReaperPlugin')
    reaper.run_once = function() reaper.enabled = true; return true end
    g.run(10)
    g.quests = {'WarPlans_QST_BossLair_Zir'}
    truthy(g.until_true(function() return reaper.enabled end, 5), 'Reaper started at once')
end)

-- R6 / WPG-7: the turn-in consumed teleport_pending (task-only skip), so the
-- first activity of the next plan started without the native transition.
case('R6 the first activity after the turn-in gets the native warplan transition', function()
    local f = fixture({teleport = true})
    local ark = f.plugin('ArkhamAsylumPlugin')
    f.on_warplan = function() f.world = 'PIT_Test_World' end
    f.quests = {'WarPlans_QST_TurnIn_Rewards'}
    truthy(f.until_true(function() return f.interacts > 0 end, 20), 'turn-in reached Tyrael')
    eq(f.teleports, 0, 'the turn-in itself needs no warplan teleport')
    f.quests = {}                                   -- reward claimed
    f.run(5)
    eq(f.logged('teleport queued — turn-in finished'), 1)
    eq(f.o.is_busy(), false, 'a pending teleport with nothing incoming does not hold WarPug')
    f.quests = {'WarPlans_QST_ThePit'}              -- WarPug created the next plan
    truthy(f.until_true(function() return ark.enables > 0 end, 30), 'Pit enabled')
    eq(f.teleports, 1, 'warplan transition before the first activity of the next plan')
    truthy(f.logged('teleport confirmed') >= 1, 'enabled after the confirmed transition')
    -- 'Use teleport' off: nothing is queued.
    local g = fixture()
    g.quests = {'WarPlans_QST_TurnIn_Rewards'}
    truthy(g.until_true(function() return g.interacts > 0 end, 20))
    g.quests = {}; g.run(3)
    eq(g.logged('teleport queued'), 0)
end)

-- F-W2 (round-3 critic regression 2): the R6 re-arm after the turn-in ran a
-- second full WarPigs Alfred cycle in the same Temis visit because the J2
-- join applied only within 20 s of the first cycle's completion. WPT-3 is per
-- visit: a completed WarPigs cycle of this visit is joined whatever its age;
-- a hard need that came back since still triggers Alfred.
case('F-W2 one WarPigs Alfred cycle per Temis visit across the turn-in and the next plan', function()
    for _, hard in ipairs({false, true}) do
        local f = fixture({teleport = true})
        local ark = f.plugin('ArkhamAsylumPlugin')
        f.alfred({enabled = true}, 5, {'inventory_full'})
        f.actors[#f.actors + 1] = {get_skin_name = function() return 'TWN_Kehj_IronWolves_PitKey_Crafter' end,
            get_position = function() return {} end}
        f.quests = {'WarPlans_QST_TurnIn_Rewards'}
        truthy(f.until_true(function() return f.interacts > 0 end, 40), 'turn-in reached Tyrael')
        eq(#f.alfred_calls, 1, 'the turn-in preamble ran one Alfred cycle')
        f.quests = {}                                   -- reward claimed
        f.run(5)
        eq(f.logged('teleport queued — turn-in finished'), 1)
        f.run(25)                                       -- the plan is made: > 20 s after the cycle
        if hard then f.alfred_status.inventory_full = true end
        local started = f.now
        f.quests = {'WarPlans_QST_ThePit'}
        truthy(f.until_true(function() return ark.enables > 0 end, 40), 'Pit enabled')
        if hard then
            eq(#f.alfred_calls, 2, 'hard work that came back still triggers Alfred')
        else
            eq(#f.alfred_calls, 1, 'no second Alfred cycle in the visit (d275b9d: 2)')
            eq(f.logged('Alfred already serviced this visit'), 1, 'the preamble skips the Alfred step')
            truthy(f.now - started <= 4, string.format('Pit enabled %.1fs after the plan (incoming settle only)', f.now - started))
        end
        eq(f.teleports, 0, 'Pit tower in Temis: no warplan teleport')
    end
    -- A new Temis visit gets its own cycle.
    local g = fixture({teleport = true})
    g.plugin('ArkhamAsylumPlugin')
    g.alfred({enabled = true}, 5)
    g.quests = {'WarPlans_QST_TurnIn_Rewards'}
    truthy(g.until_true(function() return g.interacts > 0 end, 40))
    g.quests = {}; g.run(30)
    g.zone = 'Kehj_Caldeum'; g.run(2)                -- left Temis
    g.zone = 'Skov_Temis'; g.run(2)
    g.actors[#g.actors + 1] = {get_skin_name = function() return 'TWN_Kehj_IronWolves_PitKey_Crafter' end,
        get_position = function() return {} end}
    g.quests = {'WarPlans_QST_ThePit'}
    truthy(g.until_true(function() return #g.alfred_calls == 2 end, 20), 'a new visit triggers Alfred again')
end)

-- R15 (live L7): a short Looter burst before accept pauses the managed
-- Whisper request instead of cancelling it; the walk resumes.
case('R15 a Looter burst before accept pauses the managed Whisper request', function()
    local f = fixture({whispers = true})
    f.sr(true, true); f.looter(false)
    truthy(f.until_true(function() return f.sr_status.running end, 12), 'walk started')
    -- approach_stall retries: short bursts with gaps (live L7 pattern).
    for _ = 1, 3 do
        f.looting = true; f.run(1.5)
        truthy(f.sr_status.yield == 'yield:looter_busy', 'SilentRaven asked to pause')
        f.looting = false; f.run(4)
    end
    eq(f.sr_triggers, 1, 'one request: the walk was not restarted')
    eq(f.sr_pauses, 3, 'paused once per burst')
    eq(f.sr_status.running, true, 'request kept')
    eq(f.logged('Looter busy before accept — pausing the Whisper request'), 1, 'pause logged once')
    -- C5: a long pause does not age the 60 s request budget.
    local walked = f.sr_walked
    f.looting = true; f.run(50)
    truthy(tostring(f.o.get_status_line()):find('paused — Looter busy', 1, true),
        'pause visible: ' .. tostring(f.o.get_status_line()))
    f.looting = false; f.run(20)
    eq(f.sr_status.running, true, 'not timed out by the pause')
    truthy(f.sr_walked > walked, 'the walk continued after the pause')
    f.sr_finish('success')
    truthy(f.until_true(function() return f.logged('visit 1: success') > 0 end, 3), 'visit completes')
    eq(f.sr_triggers, 1)
end)

case('R15 the Looter pause is bounded; hard cancels are unchanged; a post-accept burst never cancels', function()
    -- A latched Looter: the bridge stops pausing after its bound (backstop
    -- for SilentRaven's own 120 s cap).
    local f = fixture({whispers = true})
    f.sr(true, true); f.looter(false)
    truthy(f.until_true(function() return f.sr_status.running end, 12))
    local t0 = f.now
    f.looting = true
    truthy(f.until_true(function() return not f.sr_status.running end, 160), 'pause bounded')
    local held = f.now - t0
    truthy(held >= 125 and held <= 140, 'paused ~130 s, got ' .. held)
    eq(f.sr_status.last_reason, 'looter_busy:is_actively_looting', 'then a hard cancel')
    eq(f.logged('no longer pausing'), 1)
    -- Hard cancels: live Alfred work, leaving Temis, WarPigs disabled.
    local function started()
        local g = fixture({whispers = true})
        g.sr(true, true); g.looter(false)
        truthy(g.until_true(function() return g.sr_status.running end, 12))
        return g
    end
    local g = started()
    g.alfred({enabled = true, trigger_tasks = true}); g.tick()
    eq(g.sr_status.running, false); eq(g.sr_status.last_reason, 'alfred_busy')
    local h = started()
    h.zone = 'Kehj_Kurast'; h.town = true; h.run(3)
    eq(h.sr_status.running, false, 'leaving Temis cancels')
    eq(h.sr_pauses, 0)
    local k = started()
    k.settings.manage_whispers = false; k.tick()
    eq(k.sr_status.running, false, 'WarPigs Whispers disabled cancels')
    eq(k.sr_pauses, 0)
    -- After accept (API_CLAIMING) SilentRaven only verifies the cache
    -- receipt: a Looter burst neither cancels nor pauses the request, and
    -- its result is reported (joint suite: a claimed reward was reported
    -- 'cancelled' and re-requested twice).
    local m = started()
    m.sr_status.state = 'API_CLAIMING'
    m.looting = true; m.tick(); m.tick()
    eq(m.sr_status.running, true, 'verification continues during a post-accept burst')
    eq(m.logged('pausing the Whisper request'), 0, 'no pause budget spent after accept')
    m.sr_finish('success'); m.tick()
    eq(m.logged('visit 1: success'), 1, 'the claim is reported as a success')
end)

case('R15 an older SilentRaven treats the yield as a cancel: safe, retried in the visit', function()
    local f = fixture({whispers = true})
    f.sr(); f.looter(false)                        -- any false answer cancels
    truthy(f.until_true(function() return f.sr_triggers == 1 end, 10), 'first request')
    f.looting = true; f.tick()
    eq(f.sr_status.pending, false, 'older SilentRaven cancelled the request')
    eq(f.sr_status.last_reason, 'yield:looter_busy', 'it saw the yield answer')
    f.run(2); f.looting = false
    truthy(f.until_true(function() return f.sr_triggers == 2 end, 10), 'retried in the same visit')
end)

if #failures > 0 then
    error('WarPigs town integration failures:\n  ' .. table.concat(failures, '\n  '))
end
print('PASS WarPigs town integration: ' .. checks .. ' checks (C1 Alfred reading, Whisper slot, Temis kick vs WarPug, bounded Whisper admission/retry, Looter quiet window, bounded traffic hold)')
