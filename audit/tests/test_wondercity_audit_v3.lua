-- QQT_Warpigz_v3 WonderCity 2.2.4: auditor findings (area wondercity).
-- Each case failed on the pre-fix tree and passes after the fix:
--   A1 a hard Alfred need (full bag) does not start a NEW town trip during a
--      live boss fight; bounded to 90 s (one log line), then the trip starts;
--      a trip already running is never interrupted
--   A2 walk_kurast (Temis long path) holds while a SilentRaven claim runs:
--      no long path is started, its own running route is stopped
-- Unit fixtures (loadfile with stubbed modules). Runs under Lua 5.4 and LuaJIT.
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local checks, failures = 0, {}
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
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS WonderCity audit v3: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL WonderCity audit v3: ' .. name .. ': ' .. tostring(err)) end
end
local function vec(x, y, z)
    local v = {}
    v.x = function() return x end; v.y = function() return y end; v.z = function() return z or 0 end
    return v
end
local function dist(a, b)
    return math.max(math.abs(a:x() - b:x()), math.abs(a:y() - b:y()))
end

-- A1 fixture: WonderCity alfred.lua inside an Undercity with a full bag.
local function alfred_fixture(tracker)
    local f = {now = 100, calls = {}, logs = {}, pauses = 0}
    f.status = {enabled = true, need_trigger = true, inventory_full = true}
    f.alfred = {
        get_status = function() return f.status end,
        trigger_tasks = function() f.calls[#f.calls + 1] = 'plain'; return true end,
        trigger_tasks_with_teleport = function(_, cb) f.calls[#f.calls + 1] = 'teleport'; f.cb = cb; return true end,
    }
    local utils = {player_in_undercity = function() return true end, player_in_zone = function() return false end}
    local modules = {['core.utils'] = utils, ['core.settings'] = {town_zone = 'Skov_Temis', town_waypoint = 1},
        ['core.tracker'] = tracker}
    local env = setmetatable({
        require = function(n) return assert(modules[n], n) end,
        get_time_since_inject = function() return f.now end,
        get_player_position = function() return vec(0, 0) end,
        loot_manager = {any_item_around = function() return false end},
        teleport_to_waypoint = function() end,
        console = {print = function(l) f.logs[#f.logs + 1] = l end},
        AlfredTheButlerPlugin = f.alfred,
        BatmobilePlugin = setmetatable({pause = function() f.pauses = f.pauses + 1 end},
            {__index = function() return function() return true end end}),
    }, {__index = _G})
    f.task = assert(loadfile(ROOT .. '/WonderCity/tasks/alfred.lua', 't', env))()
    f.pulse = function(seconds)
        local steps = math.floor(seconds / 0.5 + 0.5)
        for _ = 1, steps do
            f.now = f.now + 0.5
            if f.task.shouldExecute() then f.task.Execute() end
        end
    end
    return f
end
local function boss_logs(f)
    local n = 0
    for _, l in ipairs(f.logs) do if l:find('boss fight', 1, true) then n = n + 1 end end
    return n
end

case('A1 full bag during a live boss fight: no new trip for 90 s, then one log line and the trip', function()
    local f = alfred_fixture({boss_alive = true})
    f.pulse(0.5)
    eq(#f.calls, 0, 'WonderCity started a ' .. tostring(f.calls[1]) .. ' Alfred trip mid boss fight')
    f.pulse(88)
    eq(#f.calls, 0, 'Alfred trip started before the 90 s boss-fight bound')
    f.pulse(3)
    eq(#f.calls, 1, 'Alfred trip after the 90 s boss-fight bound')
    eq(boss_logs(f), 1, 'boss-fight defer log lines')
    f.pulse(30)
    eq(boss_logs(f), 1, 'boss-fight defer log lines after the trip')
end)

case('A1 kill_monster boss gate (boss seen within its window) also defers the trip', function()
    local f = alfred_fixture({boss_alive = false, boss_gate_active = function() return true end})
    f.pulse(10)
    eq(#f.calls, 0, 'WonderCity started an Alfred trip while kill_monster fights a boss')
end)

case('A1 no boss: the full-bag trip starts at once', function()
    local tracker = {boss_alive = false, boss_gate_active = function() return false end}
    local f = alfred_fixture(tracker)
    f.pulse(0.5)
    eq(#f.calls, 1, 'Alfred trip without a boss')
end)

case('A1 a running trip is never interrupted when a boss appears', function()
    local tracker = {boss_alive = false}
    local f = alfred_fixture(tracker)
    f.pulse(0.5)
    eq(#f.calls, 1, 'trip started')
    f.status.running = true
    tracker.boss_alive = true
    f.pulse(1)
    ok(f.task.shouldExecute(), 'alfred released control of a running trip because of a boss')
    ok(f.task.own_trip(), 'own trip dropped because of a boss')
    f.status.running = false
    f.cb(nil)
    eq(#f.calls, 1, 'no second trip')
end)

case('A1 boss gone: the defer window re-arms for the next fight', function()
    local tracker = {boss_alive = true}
    local f = alfred_fixture(tracker)
    f.pulse(50)
    tracker.boss_alive = false
    f.status.need_trigger, f.status.inventory_full = false, false
    f.pulse(1)
    tracker.boss_alive = true
    f.status.need_trigger, f.status.inventory_full = true, true
    f.pulse(60)
    eq(#f.calls, 0, 'second fight lost its full defer window')
end)

-- A2 fixture: walk_kurast in Temis (long-path town) during a SilentRaven claim.
local function walk_fixture()
    local f = {now = 100, pos = vec(2400, -500), navs = 0, stops = 0, claim = true, navigating = false, teleports = 0}
    local settings = {town_zone = 'Skov_Temis', town_waypoint = 1, town_long_path_target = vec(2557, -506)}
    f.utils = {
        player_in_zone = function(z) return z == 'Skov_Temis' end,
        distance = dist, stop_movement = function() end,
        get_spirit_brazier = function() return nil end, get_entrance_portal = function() return nil end,
        raven_claim_active = function() return f.claim end,
    }
    local modules = {['core.utils'] = f.utils, ['core.settings'] = settings, ['data.path'] = {vec(0, 0), vec(1, 1)}}
    local env = setmetatable({
        require = function(n) return assert(modules[n], n) end,
        get_time_since_inject = function() return f.now end,
        get_local_player = function()
            return {get_position = function() return f.pos end, get_active_spell_id = function() return 0 end}
        end,
        teleport_to_waypoint = function() f.teleports = f.teleports + 1 end,
        console = {print = function() end},
        BatmobilePlugin = setmetatable({
            is_long_path_navigating = function() return f.navigating end,
            navigate_long_path = function() f.navs = f.navs + 1; f.navigating = true; return true end,
            stop_long_path = function() f.stops = f.stops + 1; f.navigating = false end,
        }, {__index = function() return function() return true end end}),
    }, {__index = _G})
    f.task = assert(loadfile(ROOT .. '/WonderCity/tasks/walk_kurast.lua', 't', env))()
    f.pulse = function(seconds)
        for _ = 1, math.floor(seconds / 0.05 + 0.5) do
            f.now = f.now + 0.05
            if f.task.shouldExecute() then f.task.Execute() end
        end
    end
    return f
end

case('A2 walk_kurast starts no long path while SilentRaven claims (Temis)', function()
    local f = walk_fixture()
    f.pulse(5)
    eq(f.navs, 0, 'walk_kurast long paths started while SilentRaven claims')
    eq(f.teleports, 0, 'stuck watchdog re-teleported during the claim')
    f.claim = false
    f.pulse(1)
    eq(f.navs, 1, 'long path after the claim ended')
end)

case('A2 walk_kurast stops its own running long path when a claim starts', function()
    local f = walk_fixture()
    f.claim = false
    f.pulse(0.5)
    eq(f.navs, 1, 'walk started')
    f.claim = true
    f.pulse(20)
    ok(not f.navigating, 'own long path still running during the SilentRaven claim')
    eq(f.navs, 1, 'no new long path during the claim')
    eq(f.teleports, 0, 'stuck watchdog re-teleported during a 20 s claim')
    eq(f.utils.own_long_path, false, 'own_long_path flag after the claim stop')
end)

if #failures > 0 then error(#failures .. ' WonderCity audit v3 case(s) failed:\n' .. table.concat(failures, '\n')) end
print(string.format('PASS: WonderCity audit v3 (%d checks)', checks))
