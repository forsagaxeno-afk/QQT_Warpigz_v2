-- QQT_Warpigz_v3 Arkham 2.1.5 (sweep 2026-09-28 A4 / S2 F5): the second Rosie
-- trip logged '[alfred] holding for Ns: Alfred busy with another caller' with
-- N counted from the first trip (the same reason string kept the old clock).
--   H1 a 90 s hold, a 310 s gap (the task does not run), a new hold: nothing
--      is logged at once; the first new line reports about 60 s.
--   H2 a cancel (task switch) clears the hold as well.
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local checks, failures = 0, {}
local function ok(value, message)
    if not value then error(message or 'expected a true value', 2) end
    checks = checks + 1
end
local function case(name, fn)
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS arkham-hold-log: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL arkham-hold-log: ' .. name .. ': ' .. tostring(err)) end
end

local function fixture()
    local f = {now = 100, logs = {}}
    -- Alfred (Rosie) busy with a foreign caller's trip.
    f.status = {enabled = true, running = true, external_caller = 'Rosie'}
    local modules = {
        ['core.utils'] = {player_in_pit = function() return true end, player_in_zone = function() return false end,
            looter_hold = function() return false end, get_glyph_upgrade_gizmo = function() return nil end},
        ['core.settings'] = {town_zone = 'Scos_Cerrigar', town_waypoint = 1, upgrade_toggle = true,
            return_for_loot = false},
        ['core.tracker'] = {glyph_done = false},
    }
    local env = {
        require = function(n) return assert(modules[n], n) end,
        AlfredTheButlerPlugin = {get_status = function() return f.status end},
        get_time_since_inject = function() return f.now end,
        get_player_position = function() return nil end,
        loot_manager = {any_item_around = function() return false end},
        get_current_world = function() return nil end,
        console = {print = function(l) f.logs[#f.logs + 1] = {t = f.now, line = tostring(l)} end},
        BatmobilePlugin = setmetatable({}, {__index = function() return function() return true end end}),
    }
    setmetatable(env, {__index = _G})
    f.task = assert(loadfile(ROOT .. '/ArkhamAsylum/tasks/alfred.lua', 't', env))()
    function f.hold(seconds)
        local stop = f.now + seconds
        while f.now < stop do
            if f.task.shouldExecute() then f.task.Execute() end
            f.now = f.now + 0.1
        end
    end
    function f.holds_after(t)
        local out = {}
        for _, l in ipairs(f.logs) do
            if l.t >= t and l.line:find('[alfred] holding for', 1, true) then out[#out + 1] = l end
        end
        return out
    end
    return f
end

local function check_second_hold(f, t1)
    local early = f.holds_after(t1)
    ok(#early == 0 or early[1].t - t1 >= 59, string.format('a hold line %.1f s into the new hold: %s',
        early[1] and early[1].t - t1 or -1, early[1] and early[1].line or ''))
    f.hold(70)
    local lines = f.holds_after(t1)
    ok(#lines >= 1, 'the new hold is logged after a minute')
    local n = tonumber(lines[1].line:match('holding for (%d+)s'))
    ok(n and n >= 59 and n <= 62, 'first new line reports about 60 s: ' .. lines[1].line)
end

case('H1 90 s hold, 310 s gap, new hold: no line at once, the first new line reports ~60 s', function()
    local f = fixture()
    f.hold(90)
    ok(#f.holds_after(0) >= 1, 'setup: the first hold was logged')
    f.now = f.now + 310 -- the task did not run (other tasks, the trip itself)
    local t1 = f.now
    f.hold(2)
    check_second_hold(f, t1)
end)

case('H2 a cancel between the holds clears the hold', function()
    local f = fixture()
    f.hold(90)
    f.task.on_cancel()
    f.now = f.now + 1
    local t1 = f.now
    f.hold(2)
    check_second_hold(f, t1)
end)

if #failures > 0 then error(#failures .. ' arkham hold-log case(s) failed:\n' .. table.concat(failures, '\n')) end
print(string.format('PASS: arkham hold log, %d checks', checks))
