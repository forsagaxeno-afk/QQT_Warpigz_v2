-- QQT_Warpigz_v3 HordeDev 2.2.8 (scenario sweep 2026-09-28, D1 / #3, High):
-- tasks/horde.lua bomber:move_in_pattern shares move_index / reached_target /
-- target_reach_time between the wave pattern and the victory lap. A reached
-- point stored target_reach_time = get_time_since_inject(), and the '== 3'
-- dwell counter was reset only when the player was > 2 m from the next
-- point. When the lap started with reached_target left true by the wave
-- pattern, the next point was the arena centre the player already stood on:
-- the counter counted up from a timestamp, never equalled 3, and HordeDev
-- stood there forever (no door, no Council). Real HordeDev + Batmobile +
-- Rosie in the joint host; the door appears exactly on the pulse where the
-- wave pattern has just reached a point (read through debug.getupvalue, as
-- the sweep's S4 probe did). Fails on 2.2.7.
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local checks, failures = 0, {}
local function ok(value, message)
    if not value then error(message or 'expected a true value', 2) end
    checks = checks + 1
end
local function case(name, fn)
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS horde-victory-lap: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL horde-victory-lap: ' .. name .. ': ' .. tostring(err)) end
end
local HD = 'HordeDev'

local function pattern_state(h)
    local task = h.mod(HD, 'tasks.horde')
    local bomber
    for i = 1, 120 do
        local name, val = debug.getupvalue(task.Execute, i)
        if not name then break end
        if name == 'bomber' then bomber = val end
    end
    assert(type(bomber) == 'table' and type(bomber.move_in_pattern) == 'function', 'bomber not found')
    local s = {}
    for i = 1, 120 do
        local name, val = debug.getupvalue(bomber.move_in_pattern, i)
        if not name then break end
        s[name] = val
    end
    return s
end

local function run(release_when_reached)
    -- QQT_Warpigz_v3 owner-build: no Rosie; the Alfred/Looter mocks stand in.
    local h = J.new({rosie = false, dirs = {'Batmobile', HD}, place = 'caldeum'})
    h.assert_clean('load')
    h.give_compasses(1)
    local A = h.setup_horde({})
    -- Hold back the locked door after the last wave; release it on the pulse
    -- where the wave pattern has just reached a point (or after 3 s).
    local held
    local at = h.at
    h.at = function(delay, fn)
        local last = A.events[#A.events]
        if not held and last and last.what == 'wave ' .. A.waves .. ' cleared' then
            held = {fn = fn, since = h.now}
            return
        end
        return at(delay, fn)
    end
    h.mod(HD, 'gui').elements.main_toggle:set(true)
    local released
    local function door_opened()
        for _, e in ipairs(A.events) do if e.what == 'door opened' then return e.t end end
    end
    h.run_until(function() return door_opened() ~= nil end, 700, function(hh)
        if held and not released and hh.now - held.since >= 1 then
            local s = pattern_state(hh)
            if (release_when_reached and s.reached_target == true) or (not release_when_reached and hh.now - held.since >= 3) then
                released = hh.now
                held.fn()
            end
        end
    end)
    return h, A, released, door_opened()
end

case('D1 the door appears on the pulse the wave pattern reached a point: the victory lap still ends and the door opens (2.2.7: stands at the centre forever)', function()
    local h, A, released, opened = run(true)
    ok(released ~= nil, 'the wave pattern reached a point after the last wave\n' .. h.tail(10))
    ok(opened ~= nil and opened - released <= 120, string.format('door opened %s s after it appeared\n%s',
        tostring(opened and opened - released), h.tail(12)))
end)

case('D1 control: a door that appears 3 s after the last wave opens', function()
    local h, A, released, opened = run(false)
    ok(opened ~= nil and opened - released <= 120, 'door opened\n' .. h.tail(10))
end)

print(string.format('horde victory lap: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(#failures .. ' HordeDev victory-lap regression(s) failed') end
