-- WarPigs 1.1.10 (QQT_Warpigz_v3): the turn-in never stands in Temis forever
-- when Tyrael is not in the actor list (live 3.3.5: 'NPC not found' every
-- 4 s for 800+ s). Each case fails on WarPigs 1.1.9.
--   Y1  Tyrael streams in only near him: the turn-in walks toward his known
--       position and reaches him; 'NPC not found' is logged once.
--   Y2  Tyrael never appears: one re-teleport to Temis, then the turn-in is
--       given up within the bound, WarPigs continues with the next War Plan
--       step, and the turn-in is retried later.
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

-- Positions: the player walks 4 yards per request_move toward the goal;
-- Tyrael (2574, -484) is in the actor list only within STREAM yards.
local STREAM = 50
local function world_model(f, px, py, tyrael)
    f.px, f.py = px, py
    local function pos(x, y)
        return {x = function() return x end, y = function() return y end, z = function() return 31.5 end,
            dist_to = function(_, o) local dx, dy = x - o:x(), y - o:y(); return math.sqrt(dx * dx + dy * dy) end}
    end
    f.e.vec3 = {new = function(_, x, y) return pos(x, y) end}
    f.e.get_player_position = function() return pos(f.px, f.py) end
    f.e.pathfinder = {request_move = function(goal)
        f.moves = f.moves + 1
        local dx, dy = goal:x() - f.px, goal:y() - f.py
        local d = math.sqrt(dx * dx + dy * dy)
        if d > 0 then local k = math.min(1, 4 / d); f.px, f.py = f.px + dx * k, f.py + dy * k end
    end}
    local ty = {get_skin_name = function() return 'NPC_QST_X2_Tyrael_NonCombat' end,
        get_position = function() return pos(2574, -484) end}
    f.e.actors_manager = {get_all_actors = function()
        local out = {{get_skin_name = function() return 'Warplans_Vendor' end, get_position = function() return pos(2580, -480) end}}
        local dx, dy = f.px - 2574, f.py - (-484)
        if tyrael and math.sqrt(dx * dx + dy * dy) <= STREAM then out[#out + 1] = ty end
        return out
    end}
end

case('Y1 Tyrael out of streaming range: walk toward him, find him, interact', function()
    local f = fixture()
    world_model(f, 2750, -650, true)
    f.quests = {'WarPlans_QST_TurnIn_Rewards'}
    truthy(f.until_true(function() return f.interacts > 0 end, 120), 'reached Tyrael and interacted')
    eq(f.logged('NPC not found (NPC_QST_X2_Tyrael_NonCombat)'), 1, 'logged once per episode')
    eq(f.logged('Tyrael found after'), 1)
    eq(f.logged('giving the turn-in up'), 0)
end)

case('Y2 Tyrael never appears: one re-teleport, bounded give-up, WarPigs continues, retried later', function()
    local f = fixture()
    world_model(f, 2750, -650, false)
    local ark = f.plugin('ArkhamAsylumPlugin')
    f.on_teleport = nil
    f.quests = {'WarPlans_QST_TurnIn_Rewards', 'WarPlans_QST_ThePit'}
    f.run(30)
    eq(ark.enables, 0, 'the turn-in has priority while it can still find Tyrael')
    truthy(f.until_true(function() return f.logged('re-teleporting to the Temis waypoint once') == 1 end, 60),
        're-teleport once after ~60 s')
    local wp = f.waypoints
    truthy(f.until_true(function() return f.logged('giving the turn-in up') == 1 end, 150), 'given up within ~180 s')
    eq(f.waypoints, wp, 'no further teleports')
    truthy(f.until_true(function() return ark.enables > 0 end, 30), 'WarPigs continues with the next War Plan step')
    truthy(f.logged('NPC not found') <= 10, 'no per-4 s log spam (' .. f.logged('NPC not found') .. ')')
    eq(f.logged('turn-in cycle completed'), 0, 'a suspended turn-in is not a completed one')
    -- Retry after the suspension (the activity finished; its quest is gone).
    f.quests = {'WarPlans_QST_TurnIn_Rewards'}
    ark.enabled = false
    truthy(f.until_true(function() return f.task.get_state() ~= 'IDLE' end, 700), 'the turn-in is retried later')
end)

if #failures > 0 then
    error('WarPigs Tyrael turn-in failures:\n  ' .. table.concat(failures, '\n  '))
end
print('PASS WarPigs Tyrael turn-in: ' .. checks .. ' checks (Y1 walk toward Tyrael, Y2 bounded give-up and retry)')
