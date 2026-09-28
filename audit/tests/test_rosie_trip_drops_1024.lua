-- QQT_Warpigz_v3 Rosie 1.0.24 (owner, live 3.3.5 log, Worldstone + Navigator):
-- "A Mythic dropped exactly during the Town Portal cast and Rosie teleported
-- to town and left it on the ground" (TP buff 169.00, town 178.72; Worldstone
-- then went on from town). A wanted drop is never abandoned by a trip:
--  D1 it drops mid-cast and fits the bag: pickup takes it (the walk interrupts
--     the cast, which is refunded), then the cast goes on;
--  D2 it drops mid-cast and the bag is full (the trip's reason): the spot is
--     remembered and, back through the Town Portal, pickup takes it before the
--     trip completes (the trip stays busy meanwhile);
--  D3 a trip requested while a wanted drop lies in range: the cast waits until
--     pickup has taken it;
--  D4 a drop pickup cannot take holds the cast at most PICK_BUDGET s.
-- As in the game, a move during the channel interrupts it (modelled here).
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
    if passed then print('PASS trip drops 1.0.24: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL trip drops 1.0.24: ' .. name .. ': ' .. tostring(err)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function new()
    local h = J.new({rosie = true, dirs = {}, place = 'pit'})
    h.assert_clean('load')
    h.pos = h.v(0, 0)
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(15)
    return h
end
local function st(h) return h.as(CONSUMER, function() return h.G.AlfredTheButlerPlugin.get_status() end) end
local function fill_bag(h, n)
    h.inventory = {}
    for i = 1, n do h.inventory[i] = h.gear() end
end
local function start_trip(h)
    local r = {}
    eq(h.as(CONSUMER, function()
        return h.G.AlfredTheButlerPlugin.trigger_tasks_with_teleport('Consumer', function(err, res)
            r.err, r.res, r.done = err, res, true
        end)
    end), true, 'trip accepted')
    return r
end
-- A move during the channel interrupts the cast (as in the game).
local function channel_model(h)
    local m = {interrupts = 0}
    function m.step(hh)
        if hh.travel and hh.travel.phase == 'channel' and hh.goal ~= nil then
            hh.travel, hh.casting = nil, false
            m.interrupts = m.interrupts + 1
        end
    end
    return m
end
local function mythic(h, x, y, name)
    return h.drop('pit', x, y, {rarity = 6, ga = 4, name = name or 'Helm_Unique_Mythic_Test'})
end

case('D1 a wanted drop that falls during the cast, bag with room: picked up, the cast resumes, the trip completes', function()
    local h = new()
    fill_bag(h, 25)
    local m = channel_model(h)
    local r = start_trip(h)
    ok(h.run_until(function() return h.casting == true end, 10, m.step), 'the cast starts\n' .. h.tail())
    h.run(0.1, m.step)
    local item = mythic(h, 6, 0)
    ok(h.run_until(function() return r.done end, 200, m.step), 'trip ends\n' .. h.tail())
    eq(item.picked, true, 'the drop was picked up\n' .. h.tail(12))
    eq(st(h).outcome, 'completed', 'completed\n' .. h.tail())
    eq(h.logged('teleport_failed'), 0)
    ok(h.logged('dropped near the Town Portal: picking it up before the cast') >= 1, 'logged\n' .. h.tail(12))
    ok(#h.waypoints >= 2, 'recast after the pickup: ' .. #h.waypoints)
    h.assert_clean('D1')
end)

case('D2 a wanted drop that falls during the cast, full bag: remembered, picked up after the town service, then the trip completes', function()
    local h = new()
    fill_bag(h, 33)
    local r = start_trip(h)
    ok(h.run_until(function() return h.casting == true end, 10), 'the cast starts\n' .. h.tail())
    h.run(0.1)
    local item = mythic(h, 6, 0)
    local running_at_pick
    ok(h.run_until(function() return r.done end, 300, function(hh)
        if item.picked and running_at_pick == nil then running_at_pick = st(hh).running end
    end), 'trip ends\n' .. h.tail())
    eq(item.picked, true, 'the drop was picked up on the way back\n' .. h.tail(12))
    eq(running_at_pick, true, 'the trip was still busy when it was picked up')
    eq(st(h).outcome, 'completed', 'completed\n' .. h.tail())
    ok(h.logged('but the bag is full: Rosie picks it up when it comes back') >= 1, 'remembered\n' .. h.tail(12))
    ok(h.logged('Back from town: picking up') >= 1, 'picked on the way back\n' .. h.tail(12))
    h.assert_clean('D2')
end)

case('D3 a trip requested while a wanted drop lies in range: the cast waits until pickup has taken it', function()
    local h = new()
    fill_bag(h, 25)
    local m = channel_model(h)
    local item = mythic(h, 8, 0)
    local r = start_trip(h) -- same frame: pickup has not moved yet
    local picked_at
    ok(h.run_until(function() return r.done end, 200, function(hh)
        m.step(hh)
        if item.picked and not picked_at then picked_at = hh.now end
    end), 'trip ends\n' .. h.tail())
    eq(item.picked, true, 'picked up\n' .. h.tail(12))
    ok(#h.waypoints >= 1 and h.waypoints[1].t >= picked_at, 'the first cast came after the pickup')
    eq(st(h).outcome, 'completed')
    h.assert_clean('D3')
end)

case('D4 a drop pickup cannot take holds the cast at most PICK_BUDGET s', function()
    local h = new()
    fill_bag(h, 25)
    local m = channel_model(h)
    local item = h.drop('pit', 6, 0, {rarity = 6, ga = 4, name = 'Helm_Unique_Mythic_Refused',
        refuse = function() return true end})
    local t0 = h.now
    local r = start_trip(h)
    ok(h.run_until(function() return #h.waypoints >= 1 end, 60, m.step), 'the cast happens\n' .. h.tail())
    local budget = h.mod('Rosie', 'rosie.private.town.tasks.teleport').PICK_BUDGET or 20
    ok(h.waypoints[1].t - t0 <= budget + 5, 'cast within the pickup budget: ' .. (h.waypoints[1].t - t0))
    ok(h.run_until(function() return r.done end, 200, m.step), 'trip ends\n' .. h.tail())
    eq(st(h).outcome, 'completed', 'completed\n' .. h.tail())
    ok(item.picked ~= true, 'the game never took it')
    h.assert_clean('D4')
end)

case('D5 no drop: the cast is immediate (one cast, nothing logged)', function()
    local h = new()
    fill_bag(h, 25)
    local t0 = h.now
    local r = start_trip(h)
    ok(h.run_until(function() return r.done end, 200), 'trip ends\n' .. h.tail())
    eq(#h.waypoints, 1, 'one cast')
    ok(h.waypoints[1].t - t0 < 2, 'at once: ' .. (h.waypoints[1].t - t0))
    eq(h.logged('before the cast'), 0)
    h.assert_clean('D5')
end)

print(string.format('trip drops 1.0.24: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
