-- QQT_Warpigz_v3 WonderCity 2.2.6 (review undercity_teleports_2026-09-28):
-- teleport_kurast re-cast every 8 s forever and silently when a channel was
-- cut, and any tracker 'outside' key change wiped its debounce. Loads the real
-- task with QQT-shaped doubles.
local root = assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/WonderCity/'
local failures, checks = {}, 0
local function check(label, fn)
    checks = checks + 1
    local ok, err = pcall(fn)
    if not ok then failures[#failures + 1] = label .. ': ' .. tostring(err) end
end
local function eq(a, b, m) assert(a == b, (m or 'mismatch') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end

local TOWN = 'Kehj_Kurast'

-- channel: seconds each cast channels before it is cut (nil = never casting).
local function fixture(channel)
    local f = {now = 100, teleports = 0, cast_end = -1, world = 'Sanctuary', zone = 'Hawe_Zarbinzet', logs = {}, events = {}}
    local settings = {town_zone = TOWN, town_waypoint = 0x1234}
    local utils = {
        player_in_zone = function(z) return f.zone == z end,
        player_in_undercity = function() return false end,
        stop_movement = function() end,
        raven_claim_active = function() return false end,
    }
    local modules = {['core.utils'] = utils, ['core.settings'] = settings}
    local env = setmetatable({
        require = function(n) return assert(modules[n], 'unexpected require ' .. n) end,
        get_time_since_inject = function() return f.now end,
        get_local_player = function()
            return {get_active_spell_id = function() return f.now < f.cast_end and 186139 or 0 end}
        end,
        get_current_world = function()
            return {get_name = function() return f.world end, get_current_zone_name = function() return f.zone end}
        end,
        teleport_to_waypoint = function()
            f.teleports = f.teleports + 1
            f.events[#f.events + 1] = 'tp'
            if channel then f.cast_end = f.now + channel end
        end,
        console = {print = function(l) f.logs[#f.logs + 1] = l; f.events[#f.events + 1] = l end},
        BatmobilePlugin = setmetatable({}, {__index = function() return function() return true end end}),
    }, {__index = _G})
    env._G = env
    f.tp = assert(loadfile(root .. 'tasks/teleport_kurast.lua', 't', env))()
    -- One task_manager pulse: shouldExecute gates Execute.
    f.pulse = function(dt)
        f.now = f.now + (dt or 0.05)
        if f.tp.shouldExecute() then f.tp.Execute() end
    end
    f.run = function(secs) local stop = f.now + secs; while f.now < stop - 1e-9 do f.pulse() end end
    return f
end

local function count(list, pat)
    local n = 0
    for _, l in ipairs(list) do if type(l) == 'string' and l:find(pat) then n = n + 1 end end
    return n
end
local CAST = '^%[wonder_city teleport_kurast%] cast %d+ to ' .. TOWN .. ' from '
local BACKOFF = 'backing off'

-- Casts recorded before the first back-off line.
local function casts_before_backoff(f, from)
    local n = 0
    for i = from or 1, #f.events do
        local e = f.events[i]
        if e == 'tp' then n = n + 1 elseif e:find(BACKOFF, 1, true) then return n, true end
    end
    return n, false
end

check('T1: channels cut after 1.5 s -> at most 4 casts before one back-off, one log per cast', function()
    local f = fixture(1.5)
    f.run(120)
    local n, backed = casts_before_backoff(f)
    assert(backed, 'no back-off line after undelivered casts (casts=' .. f.teleports .. ', logs=' .. #f.logs .. ')')
    assert(n <= 4, 'casts before back-off: ' .. n)
    eq(count(f.logs, BACKOFF), 1, 'back-off lines in 120 s')
    eq(count(f.logs, CAST), f.teleports, 'one cast log line per cast')
    assert(f.logs[1]:find('cast 1 to ' .. TOWN .. ' from Hawe_Zarbinzet', 1, true), 'cast log text: ' .. tostring(f.logs[1]))
    assert(f.teleports <= 8, 'casts in 120 s: ' .. f.teleports)
end)

check("T3: reset('outside') 0.5 s after a cast keeps the debounce (no second cast within 8 s)", function()
    local f = fixture(1.5)
    f.pulse(); eq(f.teleports, 1, 'first cast')
    f.run(0.5)
    f.zone = 'Hawe_Intermediate' -- intermediate key before town
    f.tp.reset('outside')
    f.run(7.3)
    eq(f.teleports, 1, 'second cast within 8 s after an outside transition')
end)

check('T4: a clean arrival resets the count; the next trip gets its full 4 casts', function()
    local f = fixture(1.5)
    f.run(20) -- 3 undelivered casts
    eq(f.teleports, 3, 'undelivered casts in trip A')
    f.zone = TOWN; f.tp.reset('outside'); f.run(2) -- arrived
    f.zone = 'Hawe_Zarbinzet'; f.tp.reset('outside') -- next trip
    local from = #f.events + 1
    f.run(60)
    local n, backed = casts_before_backoff(f, from)
    assert(backed, 'trip B never backed off (casts=' .. f.teleports .. ', logs=' .. #f.logs .. ')')
    eq(n, 4, 'trip B casts before back-off')
    eq(count(f.logs, 'cast 1 to '), 2, 'count restarts at 1 for trip B')
end)

check('a long uncut channel (186139) is never re-cast', function()
    local f = fixture(30)
    f.run(29)
    eq(f.teleports, 1, 'casts while channelling')
end)

check("run/floor transitions and a bare reset() still clear the trip", function()
    local f = fixture(1.5)
    f.run(33) -- 4 casts + back-off
    assert(f.tp.backoff_until ~= nil, 'expected back-off')
    f.tp.reset('run')
    f.pulse(); eq(f.teleports, 5, 'cast allowed right after a run transition')
end)

if #failures > 0 then error('WonderCity teleport_kurast v3 regressions failed:\n' .. table.concat(failures, '\n')) end
print(string.format('PASS: WonderCity teleport_kurast v3 regressions (%d checks)', checks))
