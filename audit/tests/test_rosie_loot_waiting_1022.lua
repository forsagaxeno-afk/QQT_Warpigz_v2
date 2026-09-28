-- QQT_Warpigz_v3 Rosie 1.0.22 (Auditor MED, cross-plugin): a drop waiting for
-- the fight set looting=true without moving (pickup/main.lua main_pulse), so
-- every farm plugin that yields to a busy Looter stood still for the whole
-- fight (HR loot_hold 15 s, Arkham pickup_yield 15 s, Batmobile freeroam
-- 10 s), against the pickup.lua design note ("reports not busy, so the farm
-- plugin fights"). Now is_actively_looting() stays false (is_idle() true)
-- during a fight wait, and the wait is published apart for exit checks:
-- LooteerPlugin.has_pending_loot() and status().loot_waiting, bounded by the
-- fight hold's 45 s cap and stale 1 s after the last pulse that saw it.
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
    if passed then print('PASS loot waiting 1.0.22: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL loot waiting 1.0.22: ' .. name .. ': ' .. tostring(err)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function new()
    local h = J.new({rosie = true, dirs = {}, place = 'pit'})
    h.assert_clean('load')
    h.pos = h.v(0, 0)
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(30)
    return h
end
local function looter(h, name, arg)
    return h.as(CONSUMER, function()
        local fn = h.G.LooteerPlugin[name]
        if type(fn) ~= 'function' then return nil end
        return fn(arg)
    end)
end
local function busy(h) return looter(h, 'is_actively_looting') end
local function pending(h) return looter(h, 'has_pending_loot') end
local function status(h) return looter(h, 'status') or {} end
local function rosie_moves(h, since)
    return h.count(h.moves, function(m) return m.owner == 'Rosie' and m.t >= since end)
end
-- An elite fight_radius-close one way and a wanted drop 7 m (> FIGHT.feet) the other.
-- L1-L4 test the target contract (Pickup.fight_wait_busy=false); L0 the
-- transitional default (busy as before, plus has_pending_loot).
local function target(h) h.mod('Rosie', 'rosie.private.pickup.src.pickup').fight_wait_busy = false end
local function fight_wait(h)
    local enemy = h.actor('pit', 'Dark_Conjurer', 6, 0, {enemy = true, elite = true, health = 1e9})
    local item = h.drop('pit', -7, 0, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_030'})
    return enemy, item
end

case('L0 transitional default: a fight wait still reports busy (exit guards keep waiting) and is also published as has_pending_loot()', function()
    local h = new()
    eq(h.mod('Rosie', 'rosie.private.pickup.src.pickup').fight_wait_busy, true, 'default until the exit guards read has_pending_loot')
    local enemy, item = fight_wait(h)
    local t0 = h.now
    h.run(3)
    eq(busy(h), true, 'busy during the fight wait (as in 1.0.21)')
    eq(pending(h), true, 'has_pending_loot()')
    eq(status(h).loot_waiting, true, 'status().loot_waiting')
    eq(rosie_moves(h, t0), 0, 'no Rosie move during the fight')
    enemy.health = 0; h.remove_actor(enemy)
    ok(h.run_until(function() return item.picked == true end, 15), 'taken after the fight\n' .. h.tail(8))
    h.run(0.3)
    eq(pending(h), false, 'nothing pending afterwards')
    eq(busy(h), false, 'not busy afterwards')
    h.assert_clean('L0')
end)

case('L1 a drop that waits for the fight: not busy, idle, has_pending_loot and status().loot_waiting; taken after the fight, then no longer pending', function()
    local h = new()
    target(h)
    local enemy, item = fight_wait(h)
    local t0 = h.now
    local busy_pulses, idle_false, pending_pulses, pulses = 0, 0, 0, 0
    h.run(3, function(hh)
        pulses = pulses + 1
        if busy(hh) ~= false then busy_pulses = busy_pulses + 1 end
        if looter(hh, 'is_idle') ~= true then idle_false = idle_false + 1 end
        if pending(hh) == true then pending_pulses = pending_pulses + 1 end
    end)
    eq(busy_pulses, 0, 'is_actively_looting() stays false while the drop waits for the fight (pulses busy of ' .. pulses .. ')')
    eq(idle_false, 0, 'is_idle() stays true while the drop waits for the fight')
    eq(type(h.G.LooteerPlugin.has_pending_loot), 'function', 'LooteerPlugin.has_pending_loot is published')
    ok(pending_pulses >= pulses - 1, 'has_pending_loot() true all along the wait (' .. pending_pulses .. ' of ' .. pulses .. ')')
    eq(pending(h), true, 'has_pending_loot()')
    local st = status(h)
    eq(st.loot_waiting, true, 'status().loot_waiting')
    eq(st.running, false, 'status().running (not picking up)')
    eq(st.reason, 'ready', 'status().reason')
    eq(st.detail, 'Ready; a drop waits for the fight to end.', 'status().detail')
    eq(rosie_moves(h, t0), 0, 'no Rosie move during the fight')
    ok(item.picked ~= true, 'the drop waits')
    -- The fight ends: the drop is taken, the wait is over.
    enemy.health = 0; h.remove_actor(enemy)
    local busy_after = false
    ok(h.run_until(function() return item.picked == true end, 15, function(hh) if busy(hh) then busy_after = true end end),
        'taken after the fight\n' .. h.tail(8))
    eq(busy_after, true, 'busy while it walks to the drop after the fight')
    h.run(0.3)
    eq(pending(h), false, 'has_pending_loot() false once the drop is taken')
    eq(status(h).loot_waiting, false, 'status().loot_waiting false once the drop is taken')
    eq(busy(h), false, 'not busy afterwards')
    h.assert_clean('L1')
end)

case('L2 a farm plugin that yields to a busy Looter keeps fighting; an exit guard that also reads has_pending_loot() waits for the drop', function()
    local h = new()
    target(h)
    local enemy, item = fight_wait(h)
    -- Farm model: stands still (yields) while the Looter is busy, else walks
    -- to the enemy. Exit model (Reaper / HordeDev shape): leaves after 3 s
    -- quiet of is_actively_looting() or has_pending_loot().
    local farm = {yielded = 0, pulses = 0}
    local exit = {quiet = nil, left_at = nil}
    local function farm_pulse(hh)
        local looting, waiting = busy(hh), pending(hh)
        if not item.picked then
            farm.pulses = farm.pulses + 1
            if looting then farm.yielded = farm.yielded + 1
            else hh.as(CONSUMER, function() return hh.G.pathfinder.request_move(enemy.pos) end) end
        end
        if looting or waiting then exit.quiet = nil
        else
            exit.quiet = exit.quiet or hh.now
            if not exit.left_at and hh.now - exit.quiet >= 3 then exit.left_at = hh.now end
        end
    end
    h.run(10, farm_pulse)
    eq(farm.yielded, 0, 'the farm plugin never stood still for the waiting drop (' .. farm.yielded .. ' of ' .. farm.pulses .. ' pulses)')
    eq(exit.left_at, nil, 'the exit guard waits for the drop during the fight')
    ok(item.picked ~= true, 'the drop waits for the fight')
    enemy.health = 0; h.remove_actor(enemy)
    local picked_at
    ok(h.run_until(function() return exit.left_at ~= nil end, 25, function(hh)
        farm_pulse(hh)
        if item.picked and not picked_at then picked_at = hh.now end
    end), 'the exit guard leaves after the drop\n' .. h.tail(8))
    ok(picked_at ~= nil and exit.left_at >= picked_at, 'left only after the drop was taken')
end)

case('L3 the wait is not published while Rosie is off or pickup is paused (stale after 1 s), and is again when pickup resumes', function()
    local h = new()
    target(h)
    fight_wait(h)
    h.run(3)
    eq(pending(h), true, 'waiting before the pause')
    eq(looter(h, 'acquire_pause', 'Consumer'), true, 'acquire_pause')
    h.run(1.2)
    eq(pending(h), false, 'paused: not pending')
    eq(status(h).loot_waiting, false, 'paused: status().loot_waiting')
    looter(h, 'release_pause', 'Consumer')
    h.run(1)
    eq(pending(h), true, 'resumed: pending again')
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.disable() end) ~= false, true, 'RosiePlugin.disable()')
    h.run(1.2)
    eq(pending(h), false, 'Rosie off: not pending')
    eq(busy(h), false, 'Rosie off: not busy')
end)

case('L4 (C6) an enemy that never dies: pending until the fight hold\'s 45 s cap, then the drop is taken and nothing is pending', function()
    local h = new()
    target(h)
    local _, item = fight_wait(h)
    local t0 = h.now
    local busy_seen = false
    h.run(40, function(hh) if busy(hh) then busy_seen = true end end)
    eq(busy_seen, false, 'not busy for 40 s of fight wait')
    eq(pending(h), true, 'still pending at 40 s')
    ok(h.run_until(function() return item.picked == true end, 20), 'taken once the hold is capped\n' .. h.tail(8))
    ok(h.now - t0 >= 44, string.format('picked after the 45 s cap (%.1f s)', h.now - t0))
    h.run(0.3)
    eq(pending(h), false, 'nothing pending after the cap and the pickup')
end)

print(string.format('rosie loot waiting 1.0.22: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(#failures .. ' loot-waiting regression(s) failed') end
