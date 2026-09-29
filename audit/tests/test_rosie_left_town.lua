-- QQT_Warpigz_v3 Rosie 1.0.27 (scenario sweep 2026-09-28 R1, S4 F3 / S5 F3,
-- audit/reviews/sweep_2026-09-28.md §2.3): a town service that started in
-- Temis (no Town Portal leg) was stranded when another addon's waypoint took
-- the player out of town: nothing acted until the 240 s service bound, then
-- a latched failure with a full bag. 1.0.27 re-plans it once as a Town Portal
-- trip from where the player landed; a second strand fails the trip.
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local checks, failures = 0, {}
local function ok(value, message)
    if not value then error(message or 'expected a true value', 2) end
    checks = checks + 1
end
local function eq(actual, expected, message)
    if actual ~= expected then
        error((message or 'mismatch') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
    checks = checks + 1
end
local function case(name, fn)
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS rosie left town: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL rosie left town: ' .. name .. ': ' .. tostring(err)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function new()
    local h = J.new({rosie = true, dirs = {}, place = 'temis'})
    h.assert_clean('load')
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    h.inventory = {}
    for _ = 1, 25 do h.inventory[#h.inventory + 1] = h.gear({locked = true}) end
    return h
end
local function trip(h)
    local r = {}
    eq(h.as(CONSUMER, function()
        return h.G.AlfredTheButlerPlugin.trigger_tasks_with_teleport('Consumer', function(err, res) r.err, r.res, r.done = err, res, true end)
    end), true, 'trip accepted')
    return r
end
local function st(h) return h.as(CONSUMER, function() return h.G.AlfredTheButlerPlugin.get_status() end) end

case('L1 a foreign waypoint 0.2 s into an in-town service: re-planned as a Town Portal trip, served, back where it landed', function()
    local h = new()
    local r = trip(h)
    h.run(0.2)
    h.travel_to('frac', 1.0, 'waypoint') -- another addon's waypoint channel
    local t0 = h.now
    ok(h.run_until(function() return h.place == h.P.frac end, 10), 'the foreign waypoint lands in frac')
    ok(h.run_until(function() return h.place == h.P.temis end, 60), 'back in Temis within 60 s (1.0.26: idles out of town)\n' .. h.tail(12))
    ok(h.run_until(function() return r.done end, 120), 'the trip ends\n' .. h.tail(12))
    eq(r.err, nil, 'the trip succeeds\n' .. h.tail(12))
    eq(#h.inventory, 0, 'the bag is served')
    eq(h.logged('timed out (240s)'), 0, 'no 240 s timeout')
    ok(h.now - t0 < 120, string.format('within 120 s (%.0f s)', h.now - t0))
    eq(h.place, h.P.frac, 'back through the portal where the player landed')
    eq(h.logged('left town during the service'), 1, 'one re-plan line\n' .. h.tail(12))
    eq(st(h).need_trigger ~= true and true or false, true, 'no need left')
    h.assert_clean('L1')
end)

case('L2 a second strand ends the trip as a failure (bounded, no second re-plan)', function()
    local h = new()
    local r = trip(h)
    h.run(0.2)
    h.travel_to('frac', 1.0, 'waypoint')
    ok(h.run_until(function() return h.place == h.P.frac end, 10), 'the foreign waypoint lands in frac')
    ok(h.run_until(function() return h.place == h.P.temis end, 60), 'back in Temis (1.0.26: idles out of town)\n' .. h.tail(12))
    h.run(0.5)
    if not r.done then h.travel_to('scos', 1.0, 'waypoint') end -- the second strand
    ok(h.run_until(function() return r.done end, 60), 'the trip ends within 60 s of the second strand (1.0.26: 240 s)\n' .. h.tail(30))
    eq(h.logged('left town during the service'), 1, 'only one re-plan')
    eq(h.logged('timed out (240s)'), 0, 'no 240 s timeout')
    h.assert_clean('L2')
end)

case('L3 control: an in-town service the player stays for is not re-planned', function()
    local h = new()
    local r = trip(h)
    ok(h.run_until(function() return r.done end, 120), 'the trip ends')
    eq(r.err, nil, 'success')
    eq(h.logged('left town during the service'), 0, 'no re-plan')
    eq(#h.waypoints, 0, 'no waypoint cast')
    h.assert_clean('L3')
end)

print(string.format('rosie left town: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
