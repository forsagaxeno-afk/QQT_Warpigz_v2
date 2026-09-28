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

case('D4 drops pickup cannot take hold the cast PICK_BUDGET s at most, then one bounded try on the way back', function()
    local h = new()
    fill_bag(h, 25)
    local m = channel_model(h)
    local refused = {}
    for i = 1, 3 do
        refused[i] = h.drop('pit', 4 + i, i, {rarity = 6, ga = 4, name = 'Helm_Unique_Mythic_Refused_' .. i,
            refuse = function() return true end})
    end
    local t0 = h.now
    local r = start_trip(h)
    ok(h.run_until(function() return #h.waypoints >= 1 end, 60, m.step), 'the cast happens\n' .. h.tail())
    local budget = h.mod('Rosie', 'rosie.private.town.tasks.teleport').PICK_BUDGET or 20
    local at = h.waypoints[1].t - t0
    ok(at >= budget and at <= budget + 1.5, 'the budget releases the cast: ' .. at)
    eq(h.logged('Pickup before the Town Portal took ' .. budget .. 's; casting now'), 1, 'logged\n' .. h.tail(10))
    ok(h.logged('was not picked up before the cast: Rosie picks it up when it comes back') >= 1, 'not left silently\n' .. h.tail(10))
    ok(h.run_until(function() return r.done end, 300, m.step), 'trip ends\n' .. h.tail())
    eq(st(h).outcome, 'completed', 'completed\n' .. h.tail())
    h.assert_clean('D4')
end)

case('D6 the cast lands while pickup walks: the lend ends on arrival (pickup paused in town), the drop is taken on the way back', function()
    local h = new()
    fill_bag(h, 25)
    local r = start_trip(h) -- no channel model: the walk does not break this cast
    ok(h.run_until(function() return h.casting == true end, 10), 'the cast starts\n' .. h.tail())
    h.run(0.1)
    local item = mythic(h, 12, 0, 'Helm_Unique_Mythic_Late')
    local life = h.mod('Rosie', 'rosie.private.town.core.lifecycle')
    local lent_in_town, unpaused_in_town, town_frames = 0, 0, 0
    ok(h.run_until(function() return r.done end, 300, function(hh)
        if hh.place == hh.P.temis then
            town_frames = town_frames + 1
            if life.pickup_lent() then lent_in_town = lent_in_town + 1 end
            if hh.as(CONSUMER, function() return hh.G.LooteerPlugin.status().paused end) ~= true then unpaused_in_town = unpaused_in_town + 1 end
        end
    end), 'trip ends\n' .. h.tail())
    ok(town_frames > 10, 'the trip went to town')
    eq(lent_in_town, 0, 'never lent in town')
    eq(unpaused_in_town, 0, 'pickup paused by the trip on every town frame')
    eq(item.picked, true, 'taken on the way back\n' .. h.tail(12))
    eq(st(h).outcome, 'completed')
    h.assert_clean('D6')
end)

case('D7 a drop the fight holds before the cast is not left silently: taken on the way back once the fight is over', function()
    local h = new()
    fill_bag(h, 25)
    local m = channel_model(h)
    local enemy = h.actor('pit', 'Dark_Conjurer', 3, 0, {enemy = true, elite = true, health = 1e9, reach = 0})
    local item = mythic(h, -8, 0, 'Helm_Unique_Mythic_Fight')
    local r = start_trip(h)
    ok(h.run_until(function() return h.place == h.P.temis end, 90, m.step), 'the trip goes to town\n' .. h.tail())
    enemy.health = 0; h.remove_actor(enemy) -- killed meanwhile
    ok(h.run_until(function() return r.done end, 300, m.step), 'trip ends\n' .. h.tail())
    ok(h.logged('was not picked up before the cast: Rosie picks it up when it comes back') >= 1, 'remembered\n' .. h.tail(12))
    eq(item.picked, true, 'taken on the way back\n' .. h.tail(12))
    eq(st(h).outcome, 'completed')
    h.assert_clean('D7')
end)

case('D8 the return pickup is not service time, and a pickup walk that crosses a zone border still completes the trip', function()
    local h = new()
    fill_bag(h, 33)
    local r = start_trip(h)
    ok(h.run_until(function() return h.casting == true end, 10), 'the cast starts\n' .. h.tail())
    h.run(0.1)
    local item = mythic(h, 6, 0, 'Helm_Unique_Mythic_Border')
    local tracker = h.mod('Rosie', 'rosie.private.town.core.tracker')
    ok(h.run_until(function() return h.logged('Back from town: picking up') >= 1 end, 300), 'back\n' .. h.tail())
    tracker.service_elapsed = 238.5 -- a slow service: the pickup must not time the trip out
    local zone = h.P.pit.zone
    h.P.pit.zone = 'PIT_Subzone_Next' -- the walk crosses into the next zone
    ok(h.run_until(function() return r.done end, 60), 'trip ends\n' .. h.tail())
    h.P.pit.zone = zone
    eq(item.picked, true, 'picked\n' .. h.tail(10))
    eq(st(h).outcome, 'completed', 'completed, not timed out or teleport_failed\n' .. h.tail(10))
    h.assert_clean('D8')
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

-- QQT_Warpigz_v3 1.0.24 (Undercity "~5 teleports", cause 3): the outbound
-- cast was re-cast every 3 s while the channel ran.
case('C1 a 5 s Town Portal channel is cast exactly once (no re-cast while it runs)', function()
    local h = new()
    fill_bag(h, 25)
    local real = h.G.teleport_to_waypoint
    h.G.teleport_to_waypoint = function(...)
        local r = real(...)
        if h.travel and h.travel.phase == 'channel' then h.travel.at = h.now + 5 end -- a 5 s channel
        return r
    end
    local r = start_trip(h)
    ok(h.run_until(function() return r.done end, 200), 'trip ends\n' .. h.tail())
    eq(#h.waypoints, 1, 'one cast for one channel\n' .. h.tail(10))
    eq(st(h).outcome, 'completed')
    eq(h.logged('[Rosie] Town Portal cast 1'), 1, 'the cast is logged with its number')
    eq(h.logged('[Rosie] Town Portal cast 2'), 0)
    h.assert_clean('C1')
end)

print(string.format('trip drops 1.0.24: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
