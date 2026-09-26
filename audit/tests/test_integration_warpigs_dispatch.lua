-- Integration regressions for the WarPigs dispatcher: outgoing teleport gates,
-- cold-start/in-place handoffs, provider completion signals (C2), Reaper
-- results, orbwalker restore, warplan error handling and bounded gates (C6).
-- Loads the real orchestrator (and, where noted, the real turn-in task) with
-- QQT-shaped host mocks in an isolated environment.
local root = assert(SUITE_ROOT) .. '/WarPigs-1.0.0/'
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
    local f = {now = 100, world = opts.world or 'Sanctuary', zone = opts.zone or 'Skov_Temis',
        town = opts.town ~= false, quests = {}, aether = 0, minute = 30, actors = {},
        waypoints = 0, teleports = 0, logs = {}, orb = {}, alfred_triggers = {}}
    local e = setmetatable({}, {__index = _G}); e._G = e
    e.console = {print = function(m) f.logs[#f.logs + 1] = tostring(m) end}
    e.os = setmetatable({date = function(fmt, ...)
        if fmt == '%M' then return string.format('%02d', f.minute) end
        return os.date(fmt, ...)
    end}, {__index = os})
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
    e.get_player_position = function() return {dist_to = function() return 0 end} end
    e.teleport_to_waypoint = function(wp)
        f.waypoints = f.waypoints + 1; f.last_waypoint_at = f.now
        if f.on_waypoint then f.on_waypoint(wp) end
    end
    e.warplan = {teleport_to_activity = function()
        f.teleports = f.teleports + 1
        if f.on_warplan then return f.on_warplan() end
    end}
    e.get_aether_count = function() return f.aether end
    e.revive_at_checkpoint = function() end
    e.loot_manager = {interact_with_object = function() f.interactions = (f.interactions or 0) + 1 end}
    e.pathfinder = {request_move = function() end}
    e.orbwalker = {
        set_clear_toggle = function(v) f.orb.clear = v; f.orb[#f.orb + 1] = 'clear=' .. tostring(v) end,
        set_block_movement = function(v) f.orb.block = v; f.orb[#f.orb + 1] = 'block=' .. tostring(v) end,
    }
    f.settings = {enabled = true, manage_whispers = false,
        use_teleport_transition = opts.teleport == true, manage_orbwalker = opts.orb == true}
    local modules = {['core.settings'] = f.settings}
    if not opts.real_turnin then
        modules['core.tasks.turn_in_rewards'] = {
            tick = function(active, ctx) f.task_active = active; f.task_ctx = ctx end,
            get_state = function() return 'IDLE' end,
        }
    end
    e.require = function(name)
        if modules[name] ~= nil then return modules[name] end
        local value = assert(loadfile(root .. name:gsub('%.', '/') .. '.lua', 't', e))()
        modules[name] = value
        return value
    end
    f.e = e
    f.o = e.require('core.orchestrator')
    f.task = e.require('core.tasks.turn_in_rewards')
    function f.plugin(name, fields)
        local p = {enabled = false, enables = 0, disables = 0, st = fields or {}}
        p.enable = function() p.enabled = true; p.enables = p.enables + 1 end
        p.disable = function() p.enabled = false; p.disables = p.disables + 1 end
        p.status = function()
            local s = {enabled = p.enabled}
            for k, v in pairs(p.st) do s[k] = v end
            return s
        end
        e[name] = p
        return p
    end
    function f.alfred(status)
        f.alfred_status = status
        e.AlfredTheButlerPlugin = {
            get_status = function() return f.alfred_status end,
            trigger_tasks = function(caller, callback)
                f.alfred_triggers[#f.alfred_triggers + 1] = {zone = f.zone, at = f.now, caller = caller}
                f.alfred_callback = callback
                return true
            end,
        }
    end
    function f.looter(busy)
        f.looting = busy
        e.LooteerPlugin = {get_enabled = function() return true end,
            is_actively_looting = function() return f.looting end}
    end
    function f.tick(dt) f.now = f.now + (dt or 0.5); f.o.tick() end
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
    return f
end

local function horde_plugin(f, fields)
    local horde = f.plugin('InfernalHordesPlugin', fields)
    horde.chests_done = function() return false end
    horde.getState = function() return 'IDLE' end
    return horde
end

-- ── WPD-1: outgoing teleports vs companions in any zone ─────────────────────
case('WPD-1 no Alfred kick outside Temis while a teleport is pending', function()
    local f = fixture({teleport = true, world = 'X1_Undercity', zone = 'X1_Undercity_SnakeTemple_02', town = false})
    local wc = f.plugin('WonderCityPlugin'); wc.enabled = true
    f.quests = {'WarPlans_QST_Undercity'}; f.tick()
    -- The run is over: WonderCity exited to Kurast with a full bag; next plan is Zir.
    f.set_zone('Sanctuary', 'Kehj_Kurast', true)
    f.alfred({enabled = true, need_trigger = true, inventory_full = true})
    f.on_waypoint = function() f.set_zone('Sanctuary', 'Skov_Temis', true) end
    f.quests = {'WarPlans_QST_BossLair_Zir'}
    f.run(20)
    eq(wc.disables, 1, 'Undercity released in town when Alfred has no live work')
    truthy(f.waypoints >= 1, 'the via-Temis preamble still runs')
    for _, trigger in ipairs(f.alfred_triggers) do
        eq(trigger.zone, 'Skov_Temis', 'WarPigs starts Alfred only in Temis while a teleport is pending')
    end
end)

case('WPD-1/WCY-3 a live Alfred cycle in Kurast holds the release and the Temis hop', function()
    local f = fixture({teleport = true, world = 'X1_Undercity', zone = 'X1_Undercity_SnakeTemple_02', town = false})
    local wc = f.plugin('WonderCityPlugin'); wc.enabled = true
    f.quests = {'WarPlans_QST_Undercity'}; f.tick()
    f.set_zone('Sanctuary', 'Kehj_Kurast', true)
    f.alfred({enabled = true, trigger_tasks = true, teleport = true, running = true})
    f.quests = {'WarPlans_QST_BossLair_Zir'}
    f.run(40)
    eq(wc.disables, 0, 'WonderCity kept while the Alfred cycle it started runs')
    eq(f.waypoints, 0, 'no Temis hop over a live Alfred cycle')
    -- Finished; the with-teleport flag stays latched (C1: not live work).
    f.alfred_status = {enabled = true, teleport = true, teleport_done = true}
    truthy(f.until_true(function() return f.waypoints >= 1 end, 15), 'Temis hop follows once Alfred is done')
    eq(wc.disables, 1)
end)

case('WPD-1 live Alfred work outside any town holds the outgoing hop', function()
    local f = fixture({teleport = true, world = 'Sanctuary', zone = 'Hawe_Verge', town = false})
    local hr = f.plugin('HelltideRevampedPlugin'); hr.enabled = true
    f.quests = {'WarPlans_QST_Helltide_TorturedGifts'}; f.tick()
    f.alfred({enabled = true, trigger_tasks = true, external_trigger = true})
    f.quests = {'WarPlans_QST_TurnIn_Rewards'}
    f.run(60)
    eq(hr.disables, 1); eq(f.waypoints, 0, 'Temis hop waits for the live Alfred cycle')
    truthy(f.logged('Alfred') > 0, 'hold reason logged')
    f.alfred_status = {enabled = true}
    truthy(f.until_true(function() return f.waypoints >= 1 end, 3), 'hop fires once Alfred is idle')
end)

case('WPD-1/C6 the Alfred hold is bounded', function()
    local f = fixture({teleport = true, world = 'Sanctuary', zone = 'Hawe_Verge', town = false})
    local hr = f.plugin('HelltideRevampedPlugin'); hr.enabled = true
    f.quests = {'WarPlans_QST_Helltide_TorturedGifts'}; f.tick()
    f.alfred({enabled = true, running = true})
    f.quests = {'WarPlans_QST_TurnIn_Rewards'}
    f.run(170); eq(f.waypoints, 0)
    truthy(f.until_true(function() return f.waypoints >= 1 end, 30), 'Alfred hold bounded (~180 s)')
    truthy(f.logged('proceeding') > 0, 'bound expiry logged')
end)

case('WPD-1 an unreadable Alfred status holds at most ~10 s', function()
    local f = fixture({teleport = true, world = 'Sanctuary', zone = 'Hawe_Verge', town = false})
    local hr = f.plugin('HelltideRevampedPlugin'); hr.enabled = true
    f.quests = {'WarPlans_QST_Helltide_TorturedGifts'}; f.tick()
    f.e.AlfredTheButlerPlugin = {get_status = function() error('stale handle') end}
    f.quests = {'WarPlans_QST_TurnIn_Rewards'}
    truthy(f.until_true(function() return f.waypoints >= 1 end, 20), 'unreadable Alfred does not block forever')
    eq(f.logged('Alfred unavailable'), 1, 'one log line')
end)

case('WPD-1 Looter pickup outside Temis delays the hop, bounded', function()
    local f = fixture({teleport = true, world = 'Sanctuary', zone = 'Hawe_Verge', town = false})
    local hr = f.plugin('HelltideRevampedPlugin'); hr.enabled = true
    f.quests = {'WarPlans_QST_Helltide_TorturedGifts'}; f.tick()
    f.looter(true)
    f.quests = {'WarPlans_QST_TurnIn_Rewards'}
    f.run(12); eq(f.waypoints, 0, 'no hop while Looter collects the last chest')
    f.looting = false
    truthy(f.until_true(function() return f.waypoints >= 1 end, 2), 'hop once Looter is idle')
    local g = fixture({teleport = true, world = 'Sanctuary', zone = 'Hawe_Verge', town = false})
    local hr2 = g.plugin('HelltideRevampedPlugin'); hr2.enabled = true
    g.quests = {'WarPlans_QST_Helltide_TorturedGifts'}; g.tick()
    g.looter(true)
    g.quests = {'WarPlans_QST_TurnIn_Rewards'}
    g.run(25); eq(g.waypoints, 0)
    truthy(g.until_true(function() return g.waypoints >= 1 end, 15), 'Looter hold bounded (~30 s)')
end)

case('WPD-1 a later companion hold gets its own full bound', function()
    local f = fixture({teleport = true, world = 'Sanctuary', zone = 'Hawe_Verge', town = false})
    local hr = f.plugin('HelltideRevampedPlugin'); hr.enabled = true
    f.quests = {'WarPlans_QST_Helltide_TorturedGifts'}; f.tick()
    f.looter(true)
    f.on_waypoint = function() f.set_zone('Sanctuary', 'Skov_Temis', true) end
    -- R6: the first activity after the turn-in gets the native transition.
    f.on_warplan = function() f.set_zone('Sanctuary', 'Hawe_Verge', false) end
    f.quests = {'WarPlans_QST_TurnIn_Rewards'}
    truthy(f.until_true(function() return f.waypoints >= 1 end, 40), 'first hold bounded')
    f.looting = false
    f.quests = {'WarPlans_QST_Helltide_TorturedGifts'}
    truthy(f.until_true(function() return hr.enabled end, 30), 'next helltide starts')
    f.set_zone('Sanctuary', 'Hawe_Verge', false)
    f.run(60)
    f.looting = true                             -- a new pickup at the end of this helltide
    f.quests = {'WarPlans_QST_TurnIn_Rewards'}
    f.run(20); eq(f.waypoints, 1, 'the second hold does not inherit the expired first one')
    truthy(f.until_true(function() return f.waypoints == 2 end, 20))
end)

case('WPD-1/C5 TO_TEMIS retries wait for companions and do not count the wait', function()
    local f = fixture({teleport = true, world = 'Sanctuary', zone = 'Hawe_Verge', town = false})
    local hr = f.plugin('HelltideRevampedPlugin'); hr.enabled = true
    f.quests = {'WarPlans_QST_Helltide_TorturedGifts'}; f.tick()
    f.quests = {'WarPlans_QST_TurnIn_Rewards'}
    truthy(f.until_true(function() return f.waypoints == 1 end, 10))
    f.run(10)                                   -- the channel broke; still outside
    f.alfred({enabled = true, running = true})  -- a foreign Alfred trip starts
    f.run(60)
    eq(f.waypoints, 1, 'no waypoint retry over a live Alfred trip')
    f.alfred_status = {enabled = true}
    f.run(20); eq(f.waypoints, 1, 'hold time does not count toward the retry timeout')
    truthy(f.until_true(function() return f.waypoints == 2 end, 15), 'retry resumes after the full timeout')
end)

-- ── WPD-2 / WCY-4: cold start inside the activity ───────────────────────────
case('WPD-2 WarPigs off/on mid-horde resumes HordeDev in place', function()
    for _, aether in ipairs({12, 0}) do
        local f = fixture({teleport = true, world = 'S05_BSK_Prototype02', zone = 'S05_BSK_Prototype02', town = false})
        local horde = horde_plugin(f); horde.enabled = true
        f.quests = {'WarPlans_QST_InfernalHordes_BSK'}; f.tick()
        f.aether = aether
        f.o.release_all(); eq(horde.enabled, false)
        f.run(10)
        eq(horde.enables, 1, 'HordeDev resumed in BSK (aether=' .. aether .. ')')
        eq(f.waypoints, 0, 'no Temis hop out of the running horde (aether=' .. aether .. ')')
        eq(f.teleports, 0)
    end
end)

case('WCY-4 cold start inside an Undercity or Pit enables the owner in place', function()
    local f = fixture({teleport = true, world = 'X1_Undercity', zone = 'X1_Undercity_SnakeTemple_02', town = false})
    local wc = f.plugin('WonderCityPlugin')
    f.quests = {'WarPlans_QST_Undercity'}; f.run(10)
    eq(wc.enables, 1); eq(f.waypoints, 0); eq(f.teleports, 0)
    local g = fixture({teleport = true, world = 'PIT_Subzone_Foo', zone = 'PIT_Subzone_Foo', town = false})
    local ark = g.plugin('ArkhamAsylumPlugin')
    g.quests = {'WarPlans_QST_ThePit'}; g.run(10)
    eq(ark.enables, 1); eq(g.waypoints, 0); eq(g.teleports, 0)
end)

-- ── HRD-1 / CRT-2: HordeDev fault and idle release ──────────────────────────
case('HRD-1 a faulted HordeDev is released after a grace; unspendable aether does not hold', function()
    local f = fixture({teleport = true, world = 'S05_BSK_Prototype02', zone = 'S05_BSK_Prototype02', town = false})
    local horde = horde_plugin(f); horde.enabled = true
    horde.getState = function() return 'OPENING_CHESTS' end
    local ark = f.plugin('ArkhamAsylumPlugin')
    f.quests = {'WarPlans_QST_InfernalHordes_BSK'}; f.tick()
    f.aether = 30
    horde.st.fault = 'Gold chest could not be opened; aether remains'
    f.quests = {'WarPlans_QST_ThePit'}
    f.on_waypoint = function()
        f.set_zone('Sanctuary', 'Skov_Temis', true)
        f.actors = {'TWN_Kehj_IronWolves_PitKey_Crafter'}
    end
    f.run(30); eq(horde.disables, 0, 'HordeDev gets a grace to leave BSK on its own')
    truthy(f.until_true(function() return horde.disables == 1 end, 45), 'faulted HordeDev released')
    truthy(f.until_true(function() return f.waypoints >= 1 end, 20), 'no has_aether deadlock')
    truthy(f.until_true(function() return ark.enables == 1 end, 30), 'next plan starts')
end)

case('CRT-2 an idle HordeDev that reports in_run=false is released at once', function()
    local f = fixture()
    local horde = horde_plugin(f, {in_run = false}); horde.enabled = true
    local ark = f.plugin('ArkhamAsylumPlugin')
    f.quests = {'WarPlans_QST_ThePit'}; f.tick()
    eq(horde.disables, 1, 'not committed to a horde: nothing to wait for')
    truthy(f.until_true(function() return ark.enables == 1 end, 7))
    local g = fixture()
    local legacy = horde_plugin(g); legacy.enabled = true   -- no in_run field: keep the chest gate
    g.quests = {'WarPlans_QST_ThePit'}; g.run(30)
    eq(legacy.disables, 0, 'unknown in_run keeps the chests_done gate')
end)

-- ── RPR-2 / WPD-6 / RPR-7: Reaper ownership and results ─────────────────────
case('RPR-2 a Reaper that WarPigs did not start is released when unwanted', function()
    for _, fields in ipairs({{external_run = false, in_run = true}, {}}) do
        local f = fixture()
        local reaper = f.plugin('ReaperPlugin', fields); reaper.enabled = true
        reaper.run_once = function() error('run_once not expected') end
        local ark = f.plugin('ArkhamAsylumPlugin')
        f.quests = {'WarPlans_QST_ThePit'}; f.tick()
        eq(reaper.disables, 1, 'foreign Reaper run released')
        truthy(f.until_true(function() return ark.enables == 1 end, 7), 'Pit starts')
    end
end)

case('WPD-6/RPR-7 failed Reaper runs back off and let other plans run', function()
    for _, contract in ipairs({'callback', 'legacy'}) do
        local f = fixture()
        local reaper = f.plugin('ReaperPlugin'); local runs, started_at, callback = 0, 0, nil
        reaper.run_once = function(_, _, cb)
            if reaper.enabled then return false, 'busy' end
            reaper.enabled = true; runs = runs + 1; started_at = f.now; callback = cb
            reaper.st.last_result = nil
            return true
        end
        local wc = f.plugin('WonderCityPlugin')
        f.quests = {'WarPlans_QST_BossLair_Varshan', 'WarPlans_QST_Undercity'}
        local wc_ran = false
        f.run(600, function()
            if reaper.enabled and f.now - started_at >= 10 then
                reaper.enabled = false   -- 'No recorded path': Reaper gives up and stops
                if contract == 'callback' then
                    reaper.st.last_result, reaper.st.last_error = 'failed', 'No recorded path'
                    callback('failed')
                end
            end
            if wc.enabled then wc_ran = true end
        end)
        truthy(runs <= 2, contract .. ': failing boss dispatched ' .. runs .. ' times in 10 min')
        truthy(wc_ran, contract .. ': Undercity runs during the Reaper cooldown')
        truthy(f.logged('back') > 0, contract .. ': backoff logged')
    end
end)

case('WPD-6 a busy run_once refusal is not retried every tick', function()
    local f = fixture()
    local hr = f.plugin('HelltideRevampedPlugin'); hr.enabled = true
    f.quests = {'WarPlans_QST_Helltide_TorturedGifts'}; f.tick()
    local reaper = f.plugin('ReaperPlugin'); reaper.enabled = true   -- the user runs Reaper by hand
    local calls = 0
    reaper.run_once = function() calls = calls + 1; return false, 'busy' end
    f.quests = {'WarPlans_QST_BossLair_Zir'}
    f.run(20)
    truthy(calls <= 1, 'run_once attempts in 20 s: ' .. calls)
    truthy(f.logged('refused') <= 1, 'refusal logged once')
    local g = fixture({orb = true})
    local hr2 = g.plugin('HelltideRevampedPlugin'); hr2.enabled = true
    g.quests = {'WarPlans_QST_Helltide_TorturedGifts'}; g.tick()
    local busy = g.plugin('ReaperPlugin'); busy.enabled = true
    busy.run_once = function() return false, 'busy' end
    g.quests = {'WarPlans_QST_BossLair_Zir'}
    g.run(20)
    local clears = 0
    for _, call in ipairs(g.orb) do if call == 'clear=true' then clears = clears + 1 end end
    truthy(clears <= 4, 'orbwalker clear re-forced ' .. clears .. ' times in 20 s while Reaper is busy')
end)

-- ── WPD-7 / RPR-10 / HLT-6: orbwalker clear restore ────────────────────────
case('WPD-7/RPR-10/HLT-6 manage_orbwalker restores clear around every handoff', function()
    local f = fixture({orb = true})
    local reaper = f.plugin('ReaperPlugin')
    reaper.run_once = function() f.e.orbwalker.set_clear_toggle(false); reaper.enabled = true; return true end
    f.quests = {'WarPlans_QST_BossLair_Zir'}; f.tick()
    eq(reaper.enabled, true); eq(f.orb.clear, true, 'a synchronous run_once reset cannot leave clear OFF')
    local g = fixture({orb = true, world = 'Sanctuary', zone = 'Hawe_Verge', town = false})
    local hr = g.plugin('HelltideRevampedPlugin'); hr.enabled = true
    hr.disable = function() hr.enabled = false; hr.disables = hr.disables + 1; g.e.orbwalker.set_clear_toggle(false) end
    g.quests = {'WarPlans_QST_Helltide_TorturedGifts'}; g.tick()
    g.quests = {}; g.tick()
    eq(hr.disables, 1); eq(g.orb.clear, true, 'clear restored after the outgoing plugin stopped')
    local h = fixture()
    local hr3 = h.plugin('HelltideRevampedPlugin')
    h.quests = {'WarPlans_QST_Helltide_TorturedGifts'}; h.tick()
    h.quests = {}; h.tick()
    eq(#h.orb, 0, 'manage_orbwalker off leaves the orbwalker alone')
    eq(hr3.disables, 1)
end)

-- ── WPD-8: helltide off-window on every path ────────────────────────────────
case('WPD-8 helltide off-window holds the warplan teleport without Alfred', function()
    local f = fixture({teleport = true})
    f.minute = 57
    f.plugin('HelltideRevampedPlugin')
    f.quests = {'WarPlans_QST_Helltide_TorturedGifts'}
    f.run(60); eq(f.teleports, 0, 'no warplan teleport into minute 55-59')
    f.minute = 0
    truthy(f.until_true(function() return f.teleports >= 1 end, 10), 'teleport once the hour turns')
end)

-- ── WPT-6: warplan errors and silent no-ops are bounded ─────────────────────
case('WPT-6 a throwing or silent warplan teleport is bounded and releases the gate', function()
    local f = fixture({teleport = true})
    local reaper = f.plugin('ReaperPlugin')
    reaper.run_once = function() reaper.enabled = true; return true end
    f.on_warplan = function() error('no active war plan activity') end
    f.quests = {'WarPlans_QST_BossLair_Zir'}
    local errors = 0
    for _ = 1, 60 do
        f.now = f.now + 0.5
        if not pcall(f.o.tick) then errors = errors + 1 end
    end
    eq(errors, 0, 'warplan errors never escape tick()')
    eq(reaper.enabled, true, 'the plugin navigates itself after a warplan error')
    local g = fixture({teleport = true})
    local r2 = g.plugin('ReaperPlugin')
    r2.run_once = function() r2.enabled = true; return true end
    g.quests = {'WarPlans_QST_BossLair_Zir'}
    g.run(120)
    truthy(g.teleports <= 6, 'retries capped: ' .. g.teleports)
    eq(r2.enabled, true, 'gate released after the retry cap')
end)

-- ── WPD-3 (NEEDS_LIVE_CHECK): capped enable_gate re-arms ────────────────────
case('WPD-3 Horde enable_gate re-arms are capped when the warplan lands outside BSK', function()
    local f = fixture({teleport = true})
    local horde = horde_plugin(f)
    f.on_waypoint = function() f.set_zone('Sanctuary', 'Skov_Temis', true) end
    f.on_warplan = function() f.set_zone('Sanctuary_Eastern_Continent', 'Kehj_Caldeum', false) end
    f.quests = {'WarPlans_QST_InfernalHordes_BSK'}
    truthy(f.until_true(function() return horde.enables >= 1 end, 300), 'HordeDev enabled to self-navigate')
    truthy(f.waypoints <= 2, 'Temis waypoints: ' .. f.waypoints)
    truthy(f.teleports <= 3, 'warplan teleports: ' .. f.teleports)
    truthy(f.logged('Kehj_Caldeum') > 0, 'landing zone logged')
end)

-- ── WPD-4 / ARK-2 / WCY-7: provider service trips and committed entry ───────
case('WPD-4/ARK-2 the Pit owner survives its own Alfred round trip', function()
    for _, with_c2 in ipairs({true, false}) do
        local f = fixture({world = 'PIT_Subzone_Foo', zone = 'PIT_Subzone_Foo', town = false})
        local ark = f.plugin('ArkhamAsylumPlugin'); ark.enabled = true
        local hr = f.plugin('HelltideRevampedPlugin')
        f.quests = {'WarPlans_QST_ThePit'}; f.tick()
        f.quests = {'WarPlans_QST_Helltide_TorturedGifts'}; f.run(2)
        -- Floor loot + full bag: Arkham starts Alfred's with-teleport trip (town leg).
        if with_c2 then ark.st.alfred_trip = true end
        f.alfred({enabled = true, running = true, teleport = true})
        f.set_zone('Sanctuary', 'Skov_Temis', true)
        f.run(10); eq(ark.disables, 0, 'town leg is not the end of the run (C2=' .. tostring(with_c2) .. ')')
        -- Alfred portals back into the pit.
        f.alfred_status = {enabled = true, teleport = true, teleport_done = true}
        f.set_zone('PIT_Subzone_Foo', 'PIT_Subzone_Foo', false)
        f.run(10); eq(ark.disables, 0); eq(hr.enables, 0)
        ark.st.alfred_trip = nil
        f.set_zone('Sanctuary', 'Skov_Temis', true)
        f.tick(); eq(ark.disables, 1, 'released after the real exit')
        truthy(f.until_true(function() return hr.enables == 1 end, 7))
    end
    local g = fixture()
    local ark = g.plugin('ArkhamAsylumPlugin', {alfred_trip = true}); ark.enabled = true
    g.quests = {'WarPlans_QST_ThePit'}; g.tick()
    g.quests = {}
    g.run(170); eq(ark.disables, 0)
    truthy(g.until_true(function() return ark.disables == 1 end, 20), 'alfred_trip hold bounded')
end)

case('WCY-7 an Undercity entry under way is not released in town', function()
    local f = fixture({world = 'Sanctuary', zone = 'Kehj_Kurast', town = true})
    local wc = f.plugin('WonderCityPlugin'); wc.enabled = true
    f.plugin('ArkhamAsylumPlugin')
    f.quests = {'WarPlans_QST_Undercity'}; f.tick()
    wc.st.committed_entry = true
    f.quests = {'WarPlans_QST_ThePit'}
    f.run(20); eq(wc.disables, 0, 'tribute/portal already committed')
    wc.st.committed_entry = false
    f.tick(); eq(wc.disables, 1)
    local g = fixture({world = 'Sanctuary', zone = 'Kehj_Kurast', town = true})
    local stuck = g.plugin('WonderCityPlugin', {committed_entry = true}); stuck.enabled = true
    g.quests = {'WarPlans_QST_Undercity'}; g.tick()
    g.quests = {}
    g.run(50); eq(stuck.disables, 0)
    truthy(g.until_true(function() return stuck.disables == 1 end, 20), 'committed_entry hold bounded')
end)

-- ── CRT-5: unmapped WarPlans quests ─────────────────────────────────────────
case('CRT-5 an unmapped WarPlans quest is logged once and shown', function()
    local f = fixture()
    f.quests = {'WarPlans_QST_BossLair_Bartuc'}
    f.run(600)
    eq(f.logged('WarPlans_QST_BossLair_Bartuc'), 1)
    truthy(f.o.get_status_line():find('Bartuc', 1, true), f.o.get_status_line())
end)

-- ── CRT-6 / L4: turn-in settle after the last activity ──────────────────────
case('CRT-6/L4 turn-in teleports shortly after the last activity stopped', function()
    local f = fixture({real_turnin = true, world = 'Sanctuary', zone = 'Kehj_Caldeum', town = false})
    local horde = horde_plugin(f); horde.enabled = true
    horde.chests_done = function() return true end   -- RESET finished outside BSK
    f.quests = {'WarPlans_QST_InfernalHordes_BSK'}; f.tick()
    f.quests = {'WarPlans_QST_TurnIn_Rewards'}
    f.tick(); eq(horde.disables, 1)
    local t0 = f.now
    truthy(f.until_true(function() return f.waypoints >= 1 end, 30))
    truthy(f.last_waypoint_at - t0 <= 10, 'turn-in dead time ' .. (f.last_waypoint_at - t0) .. ' s')
    -- Without the orchestrator's quiet signal the 20 s exit-plugin fallback stays.
    local g = fixture({real_turnin = true, world = 'Sanctuary', zone = 'Kehj_Caldeum', town = false})
    for _ = 1, 30 do g.now = g.now + 0.5; g.task.tick(true, {activity_quiet = false}) end
    eq(g.waypoints, 0, 'fallback window kept while an activity may still be exiting')
end)

case('CRT-6/WPD-1 the turn-in hop yields to a busy Looter (bounded)', function()
    local f = fixture({real_turnin = true, world = 'Sanctuary', zone = 'Hawe_Verge', town = false})
    local hr = f.plugin('HelltideRevampedPlugin'); hr.enabled = true
    f.quests = {'WarPlans_QST_Helltide_TorturedGifts'}; f.tick()
    f.looter(true)
    f.quests = {'WarPlans_QST_TurnIn_Rewards'}
    f.run(20); eq(f.waypoints, 0, 'no hop while Looter collects the last chest')
    truthy(f.until_true(function() return f.waypoints >= 1 end, 30), 'Looter hold bounded')
end)

-- ── L5: cleanup is not blocked by the town traffic hold ─────────────────────
case('L5 a vanished turn-in quest is reset while the town traffic hold is active', function()
    local f = fixture({real_turnin = true})
    f.quests = {'WarPlans_QST_TurnIn_Rewards'}
    f.run(2); eq(f.task.get_state(), 'APPROACH_NPC')
    f.looter(true)
    f.quests = {}
    f.tick(); eq(f.task.get_state(), 'IDLE', 'task cleanup issues no movement')
end)

-- ── C6: bounded / visible gates ─────────────────────────────────────────────
case('C6 a gate held for minutes is logged (rate-limited) and shown', function()
    local f = fixture({world = 'S05_BSK_Prototype02', zone = 'S05_BSK_Prototype02', town = false})
    local horde = horde_plugin(f); horde.enabled = true
    f.plugin('ArkhamAsylumPlugin')
    f.quests = {'WarPlans_QST_InfernalHordes_BSK'}; f.tick()
    f.quests = {'WarPlans_QST_ThePit'}
    f.run(130)
    truthy(f.o.get_status_line():find('held', 1, true), 'status line: ' .. f.o.get_status_line())
    truthy(f.logged('watchdog') >= 1, 'watchdog logged')
    f.run(470)
    truthy(f.logged('watchdog') <= 5, 'watchdog rate-limited: ' .. f.logged('watchdog'))
    eq(horde.disables, 0, 'the watchdog reports; it does not force a loot-unsafe handoff')
end)

-- ── Round 3 ─────────────────────────────────────────────────────────────────
-- R1 (critic probe_p1): the TELEPORTING retry consults the companion gate only
-- every TELEPORT_CHECK_INTERVAL (6 s). The old 2 s episode reset restarted the
-- bound on every consult, so a latched Looter or Alfred flag blocked the retry
-- forever (1 warplan call in 300 s / 600 s).
case('R1 TELEPORTING retry hold is bounded under a latched busy Looter (~30 s)', function()
    local f = fixture({teleport = true, world = 'Sanctuary', zone = 'Hawe_Verge', town = false})
    f.e.teleport_to_waypoint = nil   -- no via-Temis detour: warplan directly
    local wc = f.plugin('WonderCityPlugin')
    f.quests = {'WarPlans_QST_Undercity'}
    truthy(f.until_true(function() return f.teleports == 1 end, 10), 'first warplan call')
    f.looter(true)                   -- approach_stall retries: Looter reports busy throughout
    local dt = f.until_true(function() return f.teleports >= 2 end, 120)
    truthy(dt and dt >= 25 and dt <= 45, 'retry after the ~30 s Looter bound, got ' .. tostring(dt))
    truthy(f.logged('Looter busy for') >= 1, 'bound expiry logged')
    truthy(f.until_true(function() return wc.enables >= 1 end, 120), 'gate released after the retry cap')
end)

case('R1 TELEPORTING retry hold is bounded under a latched Alfred running flag (~180 s) and shown', function()
    local f = fixture({teleport = true, world = 'Sanctuary', zone = 'Hawe_Verge', town = false})
    f.e.teleport_to_waypoint = nil
    local wc = f.plugin('WonderCityPlugin')
    f.quests = {'WarPlans_QST_Undercity'}
    truthy(f.until_true(function() return f.teleports == 1 end, 10), 'first warplan call')
    local t0 = f.now
    f.alfred({enabled = true, running = true})
    f.run(100)
    eq(f.teleports, 1, 'no retry over live Alfred work')
    local line = f.o.get_status_line()
    truthy(line:find('held', 1, true) and line:find('TELEPORTING', 1, true)
        and line:find('Alfred cycle in progress', 1, true), 'hold reason in the status line: ' .. line)
    truthy(f.until_true(function() return f.teleports >= 2 end, 120), 'retry after the Alfred bound')
    local waited = f.now - t0
    truthy(waited >= 170 and waited <= 200, 'retry after ~180 s, got ' .. waited)
    local watchdog = 0
    for _, m in ipairs(f.logs) do
        if m:find('watchdog', 1, true) and m:find('Alfred cycle in progress', 1, true) then watchdog = watchdog + 1 end
    end
    truthy(watchdog >= 1, 'watchdog log names the companion hold')
    truthy(f.until_true(function() return wc.enables >= 1 end, 120), 'WonderCity starts')
end)

-- R2 (critic probe_p4): only a denial after a warplan TELEPORTING confirmed or
-- released counts toward MAX_GATE_DENIALS.
case('R2 WPD-3 counts only enable_gate denials that follow a warplan teleport', function()
    -- Exactly probe_p4: a new Horde plan after the turn-in.
    local f = fixture({teleport = true})
    local horde = horde_plugin(f)
    f.on_waypoint = function() f.set_zone('Sanctuary', 'Skov_Temis', true) end
    f.on_warplan = function() f.set_zone('Sanctuary_Eastern_Continent', 'Kehj_Caldeum', false) end
    f.quests = {'WarPlans_QST_TurnIn_Rewards'}
    f.run(30)
    f.quests = {}
    f.run(10)
    local t0 = f.teleports
    f.logs = {}
    f.quests = {'WarPlans_QST_InfernalHordes_BSK'}
    truthy(f.until_true(function() return horde.enables >= 1 end, 300), 'HordeDev enabled to self-navigate')
    eq(f.teleports - t0, 2, 'two warplan deliveries before the bypass')
    for _, m in ipairs(f.logs) do
        if m:find('enable_gate for', 1, true) then
            truthy(not m:find('Skov_Temis', 1, true), 'no denial counted in Temis: ' .. m)
            truthy(m:find('warplan teleport', 1, true), 'wording names the warplan teleport: ' .. m)
        end
    end
    -- 'Use teleport' switched on in Temis with the Horde quest already up:
    -- the first denial has no teleport before it.
    local g = fixture()                                    -- 'Use teleport' off
    local h2 = horde_plugin(g)
    g.on_waypoint = function() g.set_zone('Sanctuary', 'Skov_Temis', true) end
    g.on_warplan = function() g.set_zone('Sanctuary_Eastern_Continent', 'Kehj_Caldeum', false) end
    g.quests = {'WarPlans_QST_TurnIn_Rewards'}; g.run(5)   -- session under way
    g.quests = {}; g.run(5)
    g.settings.use_teleport_transition = true              -- the user switches it on
    g.quests = {'WarPlans_QST_InfernalHordes_BSK'}
    truthy(g.until_true(function() return h2.enables >= 1 end, 300), 'HordeDev enabled to self-navigate')
    eq(g.teleports, 2, 'two warplan deliveries, the teleport-less denial not counted')
end)

-- R3 (critic probe_p2 P3): C2 in_run decides for a Reaper WarPigs did not start.
case('R3 an adopted Reaper run that reports in_run is held when its quest vanishes (bounded)', function()
    local f = fixture()
    local reaper = f.plugin('ReaperPlugin', {in_run = true, external_run = true}); reaper.enabled = true
    reaper.run_once = function() return false, 'busy' end
    f.quests = {'WarPlans_QST_BossLair_Zir'}; f.tick()
    eq(f.logged('adopted active ReaperPlugin'), 1)
    f.quests = {}   -- boss dead, Reaper still opening the chest
    f.run(60)
    eq(reaper.disables, 0, 'an adopted run still in its chest phase is not cut')
    reaper.st.in_run = false
    f.tick(); eq(reaper.disables, 1, 'released once Reaper reports in_run == false')
    local g = fixture()
    local stuck = g.plugin('ReaperPlugin', {in_run = true, external_run = true}); stuck.enabled = true
    g.quests = {'WarPlans_QST_BossLair_Zir'}; g.tick()
    g.quests = {}
    g.run(290); eq(stuck.disables, 0)
    truthy(g.until_true(function() return stuck.disables == 1 end, 20), 'hold bounded (300 s)')
    eq(g.logged('releasing it (bounded hold)'), 1)
    -- A legacy Reaper without in_run keeps the old rule (not started: release).
    local h = fixture()
    local legacy = h.plugin('ReaperPlugin'); legacy.enabled = true
    h.quests = {'WarPlans_QST_BossLair_Zir'}; h.tick()
    h.quests = {}; h.tick()
    eq(legacy.disables, 1, 'legacy Reaper released at once')
end)

-- R4 (critic probe_p2 P2): a refusal that repeats forever is visible (C6).
case('R4 a Reaper run_once refused forever is shown with boss and reason', function()
    local f = fixture()
    local reaper = f.plugin('ReaperPlugin')
    local calls = 0
    reaper.run_once = function() calls = calls + 1; return false, 'belial_chest_disabled' end
    f.quests = {'WarPlans_QST_BossLair_Belial'}
    f.run(5)
    local line = f.o.get_status_line()
    truthy(line:find('Reaper refused belial: belial_chest_disabled', 1, true), 'status line: ' .. line)
    f.run(300)
    truthy(calls >= 9 and calls <= 12, 'retried on its 30 s cooldown: ' .. calls)
    line = f.o.get_status_line()
    truthy(line:find('held', 1, true) and line:find('Reaper refused belial: belial_chest_disabled', 1, true),
        'watchdog status: ' .. line)
    local logged = 0
    for _, m in ipairs(f.logs) do
        if m:find('watchdog', 1, true) and m:find('Reaper refused belial', 1, true) then logged = logged + 1 end
    end
    truthy(logged >= 1 and logged <= 3, 'watchdog log (rate-limited): ' .. logged)
    f.quests = {}; f.tick()
    truthy(not f.o.get_status_line():find('refused', 1, true), 'cleared with the quest: ' .. f.o.get_status_line())
end)

-- R7: HordeDev's own exit (C2 exit_pending) is not cut by the 60 s fault grace.
case('R7 a faulted HordeDev whose exit is in progress keeps the longer, bounded grace', function()
    local function start(fields)
        local f = fixture({world = 'S05_BSK_Prototype02', zone = 'S05_BSK_Prototype02', town = false})
        local horde = horde_plugin(f, {in_run = true}); horde.enabled = true
        f.plugin('ArkhamAsylumPlugin')
        f.quests = {'WarPlans_QST_InfernalHordes_BSK'}; f.tick()
        horde.st.fault = 'chests: Gold chest could not be opened'
        for k, v in pairs(fields) do horde.st[k] = v end
        f.quests = {'WarPlans_QST_ThePit'}
        return f, horde
    end
    local f, horde = start({exit_pending = true})
    f.run(150)
    eq(horde.disables, 0, 'HordeDev exit (Looter hold + Leave/Reset) not cut at 60 s')
    eq(f.logged('extending the fault grace'), 1)
    truthy(f.until_true(function() return horde.disables == 1 end, 40), 'still bounded (~180 s)')
    eq(f.logged('fault grace expired'), 1)
    -- The exit finishes on its own inside the grace: released as soon as in_run clears.
    local g, h2 = start({exit_pending = true})
    g.run(100); eq(h2.disables, 0)
    h2.st.exit_pending, h2.st.in_run = false, false
    g.tick(); eq(h2.disables, 1)
    -- Missing field (older HordeDev) and exit_pending == false keep the 60 s grace.
    for _, fields in ipairs({{}, {exit_pending = false}}) do
        local k, h3 = start(fields)
        k.run(50); eq(h3.disables, 0)
        truthy(k.until_true(function() return h3.disables == 1 end, 15), 'released after ~60 s')
    end
end)

-- R8: an enable() that never reports enabled (HordeDev, 'Use keybind' on and
-- no key bound) is retried every ~30 s, logged once and shown.
case('R8 an unconfirmed enable is rate-limited, logged once and shown', function()
    local f = fixture()
    local horde = horde_plugin(f)
    horde.enable = function() horde.enables = horde.enables + 1 end   -- status stays enabled=false
    f.quests = {'WarPlans_QST_InfernalHordes_BSK'}
    f.run(120)
    truthy(horde.enables >= 4 and horde.enables <= 5, 'enable() calls in 120 s: ' .. horde.enables)
    eq(f.logged('did not result in enabled status'), 1, 'logged once')
    local line = f.o.get_status_line()
    truthy(line:find('InfernalHordesPlugin enable not confirmed', 1, true), 'status line: ' .. line)
    -- The user binds the key: the next retry takes ownership.
    horde.enable = function() horde.enabled = true; horde.enables = horde.enables + 1 end
    truthy(f.until_true(function() return horde.enabled end, 35), 'enabled on the next retry')
    f.tick()
    truthy(not f.o.get_status_line():find('not confirmed', 1, true), f.o.get_status_line())
    -- Orbwalker handoff is not re-forced every tick in between (manage_orbwalker on).
    local g = fixture({orb = true})
    local h2 = horde_plugin(g)
    h2.enable = function() h2.enables = h2.enables + 1 end
    g.quests = {'WarPlans_QST_InfernalHordes_BSK'}
    g.run(20)
    eq(h2.enables, 1, 'one enable() in 20 s')
    truthy(#g.orb <= 2, 'orbwalker touched ' .. #g.orb .. ' times in 20 s')
end)

-- Round-3 audit (F-W4): a plugin that reports enabled during the R8 cooldown
-- is adopted at once, without calling enable() again.
case('F-W4 R8 cooldown: a plugin that turns on by itself is adopted at once, no second enable()', function()
    local f = fixture()
    local horde = horde_plugin(f)
    horde.enable = function() horde.enables = horde.enables + 1 end   -- status stays enabled=false
    local ark = f.plugin('ArkhamAsylumPlugin')
    ark.enable = function() ark.enables = ark.enables + 1 end
    f.quests = {'WarPlans_QST_ThePit'}
    f.run(5)
    eq(ark.enables, 1, 'one unconfirmed enable()')
    truthy(f.o.get_status_line():find('ArkhamAsylumPlugin enable not confirmed', 1, true), f.o.get_status_line())
    -- The user fixes the keybind: Arkham now reports enabled (10 s into the 30 s cooldown).
    ark.enabled = true
    f.run(1)
    eq(ark.enables, 1, 'adopted without another enable() (d275b9d: owned only after the next retry)')
    eq(f.logged('adopted without another enable()'), 1, 'adoption logged')
    local line = f.o.get_status_line()
    truthy(line:find('managing ArkhamAsylumPlugin', 1, true), 'owned at once: ' .. line)
    truthy(not line:find('not confirmed', 1, true), 'unconfirmed cleared: ' .. line)
    f.run(40)
    eq(ark.enables, 1, 'no enable() on the adopted plugin after the cooldown')
    -- Released normally when its quest ends (owned).
    f.quests = {}
    f.actors = {}
    f.run(1)
    eq(ark.disables, 1, 'the adopted plugin is released by WarPigs')
end)

-- Round-3 audit / joint (F-W5): the post-disable countdown is not part of the
-- dedup key, so the line prints once per episode, not every tick.
case('F-W5 "deferring enable — post-disable cooldown" is logged once per episode', function()
    local f = fixture()
    local ark = f.plugin('ArkhamAsylumPlugin'); ark.enabled = true
    local wc = f.plugin('WonderCityPlugin')
    f.quests = {'WarPlans_QST_ThePit'}; f.tick()
    f.quests = {'WarPlans_QST_Undercity'}
    truthy(f.until_true(function() return wc.enables == 1 end, 10), 'WonderCity after the gap')
    eq(ark.disables, 1)
    eq(f.logged('deferring enable of WonderCityPlugin — post-disable cooldown'), 1,
        'one line per episode (d275b9d: one per tick)')
    -- A second hand-off is a new episode.
    f.quests = {'WarPlans_QST_ThePit'}
    f.run(1)
    wc.enabled = false
    truthy(f.until_true(function() return ark.enables == 1 end, 10), 'Pit after the gap')
    eq(f.logged('deferring enable of ArkhamAsylumPlugin — post-disable cooldown'), 1, 'new episode logged once')
end)

if #failures > 0 then error(#failures .. ' WarPigs dispatch regressions failed:\n' .. table.concat(failures, '\n')) end
print('PASS WarPigs dispatch integration: ' .. checks .. ' checks')
