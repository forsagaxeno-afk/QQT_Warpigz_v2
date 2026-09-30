-- QQT_Warpigz_v3 (Activities review of Rosie 3.3.2): while a wanted drop
-- waits out a fight, Rosie's pickup reports busy but does not move, capped
-- at 45 s (pickup.lua FIGHT.max). Real Rosie + the activity plugins in the
-- joint host. For each activity: the loot wait neither ends the run before
-- the drop is taken nor waits forever, and no in-run "yield to the Looter"
-- stands the player still while Rosie itself waits for that fight.
--   A1 Reaper loot_ready: an enemy that never dies beside the lair keeps the
--      fight hold for its full 45 s; the lair exit still waits for the drop
--      (pre-fix: left at 30 s, drop lost), then proceeds (bounded).
--   A2 Pit: a drop off the feet and an enemy out of rotation reach: the
--      in-pit pickup yield never keeps the player from the fight (its native
--      path to the enemy carries on; guard, passes pre-fix too).
--   A3 Pit exit_pit: waits while the fight holds the drop, exits after it.
--   A4 Hordes chest phase (loot_guard.ready): waits for the drop, bounded.
--   A5 Undercity reward phase (can_exit): waits for the drop, then exits.
-- A1 failed on the pre-fix tree (Reaper 1.10.3); A2-A5 confirm the others.
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
    if passed then print('PASS activities-fight: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL activities-fight: ' .. name .. ': ' .. tostring(err)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function new(dirs, place)
    local h = J.new({rosie = true, dirs = dirs or {}, place = place or 'pit'})
    h.assert_clean('load')
    h.pos = h.v(0, 0)
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(30)
    return h
end
local function busy(h) return h.as(CONSUMER, function() return h.G.LooteerPlugin.is_actively_looting() end) end
local function legendary(h, place, x, y, n)
    return h.drop(place, x, y, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_0' .. tostring(n or 20)})
end
-- An enemy the rotation cannot reach (8 m, reach 4) and that never dies:
-- Rosie's fight hold runs its full 45 s cap.
local function immortal(h, place, x, y)
    return h.actor(place, 'Joint_Monster', x, y, {enemy = true, health = 1e9})
end
-- Samples fn() every frame until the drop is taken; returns the first time
-- fn() said "go" before the pickup (nil: never), and whether it was taken.
local function go_before_pickup(h, item, seconds, fn)
    local early
    local t0 = h.now
    h.run_until(function() return item.picked == true end, seconds, function(hh)
        if item.picked then return end
        if not early and fn(hh) then early = hh.now - t0 end
    end)
    return early, item.picked == true
end

case('A1 Reaper loot_ready waits out a 45 s fight hold, then for the pickup; proceeds after it (bounded)', function()
    local h = new({'Reaper'})
    local utils = h.mod('Reaper', 'core.utils')
    local ready = function(hh) return hh.as('Reaper', function() return utils.loot_ready() end) end
    local item = legendary(h, 'pit', -12, 0, 21)
    local enemy = immortal(h, 'pit', 8, 0)
    h.run(1)
    ok(busy(h), 'pickup busy while the drop waits for the fight')
    local early, taken = go_before_pickup(h, item, 90, ready)
    ok(taken, 'the drop is taken after the fight hold cap\n' .. h.tail(10))
    eq(early, nil, string.format('Reaper left the lair before the pickup (at %s s; pre-fix: 30 s)', tostring(early)))
    ok(h.logged('[Rosie pickup] A fight kept pickup waiting 45s') >= 1, 'Rosie capped its fight hold')
    ok(h.run_until(ready, 10), 'loot_ready once the pickup is done (bounded)')
    enemy.health = 0
end)

case('A2 Pit: a drop waits for the fight; Arkham still fights it (the pickup yield does not stall it)', function()
    local h = new({'Batmobile', 'ArkhamAsylum'})
    h.mod('ArkhamAsylum', 'gui').elements.main_toggle:set(true)
    h.run(3)
    local x, y = h.pos:x(), h.pos:y()
    local enemy = h.actor('pit', 'Joint_Monster', x + 8, y, {enemy = true, health = 200})
    local item = legendary(h, 'pit', x - 7, y, 22)
    local t0 = h.now
    ok(h.run_until(function() return (enemy.health or 0) <= 0 end, 30), 'the enemy dies\n' .. h.tail(10))
    local took = h.now - t0
    print(string.format('  A2 enemy dead after %.1f s', took))
    ok(took < 12, string.format('Arkham fought: enemy dead after %.1f s', took))
    eq(h.logged('pit task (pickup yield) proceeds'), 0, 'no bounded pickup yield ran out during the fight')
    ok(h.run_until(function() return item.picked == true end, 30), 'the drop is taken after the fight\n' .. h.tail(10))
end)

case('A3 Pit exit_pit waits while the fight holds a drop; exits once it is taken', function()
    local h = new({'Batmobile', 'ArkhamAsylum'})
    local exit = h.mod('ArkhamAsylum', 'tasks.exit_pit')
    local tracker = h.mod('ArkhamAsylum', 'core.tracker')
    h.actor('pit', 'Gizmo_Paragon_Glyph_Upgrade', 3, 3, {})
    local should = function(hh) return hh.as('ArkhamAsylum', function()
        tracker.pit_start_time = hh.now -- the run timer is not what ends this wait
        return exit.shouldExecute()
    end) end
    local item = legendary(h, 'pit', -12, 0, 23)
    immortal(h, 'pit', 8, 0)
    h.run(1)
    local early, taken = go_before_pickup(h, item, 90, should)
    ok(taken, 'the drop is taken\n' .. h.tail(10))
    eq(early, nil, 'exit_pit before the pickup at ' .. tostring(early))
    ok(h.run_until(should, 5), 'exit_pit runs once the drop is taken')
end)

case('A4 Hordes chest phase: loot_guard.ready waits for a drop the fight holds; ready after it', function()
    local h = new({'HordeDev'})
    local guard = h.mod('HordeDev', 'core.loot_guard')
    local ready = function(hh) return hh.as('HordeDev', function() return guard.ready() end) end
    local item = legendary(h, 'pit', -12, 0, 24)
    immortal(h, 'pit', 8, 0)
    h.run(1)
    local early, taken = go_before_pickup(h, item, 90, ready)
    ok(taken, 'the drop is taken\n' .. h.tail(10))
    eq(early, nil, 'chest/exit handoff before the pickup at ' .. tostring(early))
    ok(h.run_until(ready, 10), 'ready once the drop is taken')
end)

case('A5 Undercity reward phase: can_exit waits for a drop the fight holds; true after it', function()
    local h = new({'WonderCity'})
    local reward = h.mod('WonderCity', 'core.reward_phase')
    local tracker = h.mod('WonderCity', 'core.tracker')
    tracker.done = true
    local can = function(hh) return hh.as('WonderCity', function() return reward.can_exit() end) end
    local item = legendary(h, 'pit', -12, 0, 25)
    immortal(h, 'pit', 8, 0)
    h.run(1)
    local early, taken = go_before_pickup(h, item, 90, can)
    ok(taken, 'the drop is taken\n' .. h.tail(10))
    eq(early, nil, 'Undercity exit before the pickup at ' .. tostring(early))
    ok(h.run_until(can, 10), 'can_exit once the drop is taken')
end)

print(string.format('activities fight hold 3.3.2: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(#failures .. ' activities fight-hold regression(s) failed') end
