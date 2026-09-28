-- Orchestrator self-review (QQT_Warpigz_v3, WarPigs 1.1.7): step transitions
-- that could hang or loop forever. Each case failed on WarPigs 1.1.6.
--   H1  Temis preamble, hard Alfred need an Alfred cycle cannot clear
--       (inventory_full stays after every cycle, no stuck flag): the IDLE
--       gate held forever and the kick re-triggered Alfred every ~10 s.
--   H2  Temis preamble, an Alfred live-work flag that never clears: the IDLE
--       gate held forever; ALFRED_MAX_SECONDS in TEMIS_ALFRED was defeated by
--       the POST_ALFRED_SETTLE bounce (fresh 180 s window on every bounce).
--   H3  Turn-in task, an Alfred live-work flag that never clears: the task
--       yielded forever (its companion gate ctx.hold is bounded, the task's
--       own Alfred yield was not).
--   H4  SilentRaven status unreadable during a WarPigs-owned Whisper
--       request: the bridge waited for a cancel confirmation forever and
--       tick() returned early on every pulse.
-- Loads the real orchestrator, SilentRaven bridge, turn-in task and external
-- API with QQT-shaped host mocks (same fixture as the town integration test).
local root = assert(SUITE_ROOT) .. '/WarPigs/'
local pug_root = SUITE_ROOT .. '/WarPug/'
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

-- ── H1 ──────────────────────────────────────────────────────────────────────
case('H1 hard Alfred need that a cycle cannot clear: the preamble proceeds (bounded), no endless re-trigger', function()
    local f = fixture({teleport = true})
    local ark = f.plugin('ArkhamAsylumPlugin')
    -- Every trigger runs a 5 s cycle; inventory_full stays (stash full,
    -- nothing to salvage) and the provider exposes no stuck flag.
    f.alfred({enabled = true, inventory_full = true}, 5, {})
    f.on_warplan = function() f.world = 'PIT_Test_World' end
    f.quests = {'WarPlans_QST_ThePit'}
    truthy(f.until_true(function() return f.teleports > 0 end, 420),
        'warplan teleport fires after a bounded Alfred wait in Temis')
    -- 5 s mock cycles + 5 s kick cooldown: at most one trigger per ~5 s
    -- inside the 180 s budget, none after it.
    truthy(#f.alfred_calls <= 40, 'Alfred re-triggers are bounded (got ' .. #f.alfred_calls .. ')')
    truthy(f.logged('Alfred budget of this Temis visit spent') == 1, 'the expiry is logged once')
    truthy(f.until_true(function() return ark.enables > 0 end, 30), 'Arkham enabled for the Pit')
    local calls = #f.alfred_calls
    f.run(30)
    eq(#f.alfred_calls, calls, 'no Alfred trigger after leaving Temis')
end)

-- ── H2 ──────────────────────────────────────────────────────────────────────
case('H2 Alfred live work that never clears: the preamble proceeds (bounded)', function()
    local f = fixture({teleport = true})
    local ark = f.plugin('ArkhamAsylumPlugin')
    f.alfred({enabled = true, running = true})     -- latched, never finishes
    f.on_warplan = function() f.world = 'PIT_Test_World' end
    f.quests = {'WarPlans_QST_ThePit'}
    f.run(150)
    eq(f.teleports, 0, 'a live Alfred cycle is waited for first')
    truthy(f.until_true(function() return f.teleports > 0 end, 480),
        'warplan teleport fires once the bounded holds expire')
    truthy(f.until_true(function() return ark.enables > 0 end, 30), 'Arkham enabled for the Pit')
    eq(#f.alfred_calls, 0, 'a live cycle is joined, never re-triggered')
end)

case('H2 a normal Alfred cycle in the preamble is unchanged', function()
    local f = fixture({teleport = true})
    f.plugin('ArkhamAsylumPlugin')
    f.alfred({enabled = true, inventory_full = true}, 20, {'inventory_full'})
    f.on_warplan = function() f.world = 'PIT_Test_World' end
    f.quests = {'WarPlans_QST_ThePit'}
    truthy(f.until_true(function() return f.teleports > 0 end, 60), 'teleport after the cycle')
    eq(#f.alfred_calls, 1, 'one Alfred cycle')
    eq(f.logged('Alfred budget of this Temis visit spent'), 0, 'budget not reached')
end)

-- ── H3 ──────────────────────────────────────────────────────────────────────
case('H3 turn-in: Alfred live work that never clears is a bounded yield', function()
    local f = fixture({zone = 'Kehj_Kurast'})
    f.alfred({enabled = true, running = true})
    f.quests = {'WarPlans_QST_TurnIn_Rewards'}
    f.run(120)
    eq(f.waypoints, 0, 'turn-in yields to a live Alfred cycle first')
    truthy(f.until_true(function() return f.waypoints > 0 end, 120), 'turn-in teleports after the bounded yield')
    eq(f.logged('continuing the turn-in'), 1, 'the expiry is logged once')
    f.zone = 'Skov_Temis'
    truthy(f.until_true(function() return f.interacts > 0 end, 20), 'turn-in reaches Tyrael')
    -- A new live episode (the flag clears, then a real cycle starts) waits again.
    f.alfred_status.running = false; f.tick()
    f.alfred_status.running = true
    local n = f.interacts
    f.run(20)
    eq(f.interacts, n, 'a new live episode is yielded to again')
end)

-- ── H4 ──────────────────────────────────────────────────────────────────────
case('H4 SilentRaven status unreadable during an owned request: bounded', function()
    local f = fixture({whispers = true})
    f.sr()
    truthy(f.until_true(function() return f.sr_triggers == 1 end, 15), 'request submitted')
    f.sr_status.running, f.sr_status.pending = true, false
    local get_status = f.e.SilentRavenPlugin.get_status
    f.e.SilentRavenPlugin.get_status = function() error('status broke') end
    f.run(30)
    eq(f.o.get_status_line(), 'WarPigs: SilentRaven reward check', 'held while the request may still run')
    truthy(f.until_true(function() return f.o.get_status_line() ~= 'WarPigs: SilentRaven reward check' end, 120),
        'the bridge gives up the request')
    eq(f.logged('SilentRaven status unreadable'), 1, 'logged once')
    f.run(20)
    eq(f.sr_triggers, 1, 'never submitted twice in the visit')
    f.e.SilentRavenPlugin.get_status = get_status
end)

if #failures > 0 then
    error('WarPigs hang review failures:\n  ' .. table.concat(failures, '\n  '))
end
print('PASS WarPigs hang review: ' .. checks .. ' checks (H1 unclearable hard need, H2 latched live Alfred, H3 turn-in yield, H4 unreadable SilentRaven)')
