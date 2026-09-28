-- QQT_Warpigz_v3 Rosie 1.0.23 (Auditor findings on 1.0.19, town/main.lua):
-- 1. "Bag needs a town trip for Ns (...): starting it now" printed every pulse
--    while the start was then blocked (last trip failed / cancelled) or
--    refused, and a foreign town pause was cleared for a trip that never ran.
-- 2. With the keybind off, a bag that needed nothing logged "but it waits:
--    automatic service is off" and latched it, so the real need later logged
--    nothing.
-- 3. The automatic start waited on another activity's revive phase without a
--    bound (C6): it now waits REVIVE_LIMIT s of continuous revive at most.
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
    if passed then print('PASS town main 1.0.23: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL town main 1.0.23: ' .. name .. ': ' .. tostring(err)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function new(opts)
    opts = opts or {}
    opts.rosie, opts.dirs = true, {}
    local h = J.new(opts)
    h.assert_clean('load')
    return h
end
local function as_consumer(h, fn) return h.as(CONSUMER, fn) end
local function st(h) return as_consumer(h, function() return h.G.AlfredTheButlerPlugin.get_status() end) end
local function enable(h)
    eq(as_consumer(h, function() return h.G.RosiePlugin.enable() end), true)
    h.frame()
end
local function fill_bag(h, n)
    h.inventory = {}
    for i = 1, n or 25 do h.inventory[i] = h.gear() end
end
local function owner(h, phase)
    h.G.TRISTRAM_LOOP_STATE = {status = function() return {running = true, owns_activity = true, phase = phase} end}
end
local function tracker(h) return h.mod('Rosie', 'rosie.private.town.core.tracker') end
local function lifecycle(h) return h.mod('Rosie', 'rosie.private.town.core.lifecycle') end
-- The last automatic trip failed (the live teleport_failed): 120 s retry cooldown.
local function last_trip_failed(h)
    local t = tracker(h)
    t.outcome, t.failure_reason, t.fail_streak, t.failed_at = 'failed', 'teleport_failed', 1, h.now
end
local function started(h) return h.logged('[Rosie] Bag needs a town trip for') end
local function completes(h, seconds)
    ok(h.run_until(function() return st(h).outcome == 'completed' end, seconds or 200), 'trip completes\n' .. h.tail())
end

case('a failed last trip under an activity owner: the start line is not printed every pulse', function()
    local h = new({place = 'temis'})
    enable(h)
    fill_bag(h, 25)
    last_trip_failed(h)
    owner(h, 'travel')
    h.run(110)
    eq(st(h).running, false, 'no trip inside the 120 s cooldown')
    eq(started(h), 0, 'the override is not logged while the start is blocked\n' .. h.tail(6))
    eq(h.logged('but it waits: last trip failed: teleport_failed'), 1, 'the block is logged once')
    ok(h.run_until(function() return st(h).running == true end, 20), 'trip once the cooldown ends\n' .. h.tail())
    eq(started(h), 1, 'the override is logged once, for the trip that starts')
    completes(h)
    eq(started(h), 1)
    h.assert_clean('failed under owner')
end)

case('a cancelled last trip under an activity owner: waits, logged once, no start line', function()
    local h = new({place = 'temis'})
    enable(h)
    fill_bag(h, 25)
    local t = tracker(h)
    t.outcome, t.failure_reason = 'cancelled', 'Cancelled by user'
    owner(h, 'travel')
    h.run(200)
    eq(st(h).running, false, 'a cancel never restarts on its own')
    eq(started(h), 0, 'no start line for a trip that never starts\n' .. h.tail(6))
    eq(h.logged('but it waits: last trip cancelled: Cancelled by user'), 1, 'the wait is logged once')
    h.assert_clean('cancelled under owner')
end)

case("a foreign pause is kept while the start is blocked, and cleared for the trip that starts", function()
    local h = new({place = 'temis'})
    enable(h)
    eq(as_consumer(h, function() return h.G.AlfredTheButlerPlugin.pause('Worldstone') end), true)
    fill_bag(h, 25)
    last_trip_failed(h)
    h.run(90)
    local s = st(h)
    eq(s.running, false)
    eq(s.paused, true, 'the pause is not cleared for a blocked start')
    eq(s.paused_by, 'Worldstone', 'the pause keeps its caller')
    eq(started(h), 0, 'no start line while blocked\n' .. h.tail(6))
    eq(h.logged('but it waits: last trip failed: teleport_failed'), 1, 'the block is logged once')
    ok(h.run_until(function() return st(h).running == true end, 40), 'trip once the cooldown ends\n' .. h.tail())
    eq(st(h).paused, false, 'the stale pause is released for the trip')
    eq(started(h), 1)
    completes(h)
    h.assert_clean('pause while blocked')
end)

case('a refused start restores the foreign pause with its caller and logs the refusal once', function()
    local h = new({place = 'temis'})
    enable(h)
    local butler = {busy = true}
    h.G.Butler = {is_busy = function() return butler.busy end}
    eq(as_consumer(h, function() return h.G.AlfredTheButlerPlugin.pause('Worldstone') end), true)
    fill_bag(h, 25)
    h.run(90)
    local s = st(h)
    eq(s.running, false, 'Butler runs a town trip')
    eq(s.paused, true, 'the pause survives a refused start')
    eq(s.paused_by, 'Worldstone', 'with the same caller')
    eq(started(h), 0, 'no start line for a refused start\n' .. h.tail(6))
    eq(h.logged('but it waits: Butler is running a town trip.'), 1, 'the refusal is logged once')
    butler.busy = false
    ok(h.run_until(function() return st(h).running == true end, 5), 'trip once Butler is done\n' .. h.tail())
    eq(st(h).paused, false)
    eq(started(h), 1)
    completes(h)
    h.assert_clean('refused start')
end)

case('keybind off: a bag that needs nothing logs no wait; each real need logs once', function()
    local h = new()
    enable(h)
    h.mod('Rosie', 'rosie.private.town.gui').elements.use_keybind:set(true)
    fill_bag(h, 3)
    h.run(10)
    eq(tracker(h).need_trigger, false, 'a bag of 3 needs nothing')
    eq(h.logged('but it waits: automatic service is off (keybind toggle)'), 0, 'no wait line for a bag that needs nothing\n' .. h.tail(6))
    fill_bag(h, 25)
    h.run(10)
    eq(st(h).running, false)
    eq(h.logged('but it waits: automatic service is off (keybind toggle)'), 1, 'the real need is logged once')
    eq(h.logged('(bag 25/25, talismans 0) but it waits: automatic service is off'), 1, 'with the full bag\n' .. h.tail(6))
    fill_bag(h, 3)
    h.run(5)
    fill_bag(h, 25)
    h.run(5)
    eq(h.logged('but it waits: automatic service is off (keybind toggle)'), 2, 'a new need logs again')
    h.assert_clean('keybind')
end)

case('a revive phase that sticks holds the automatic start for REVIVE_LIMIT s at most', function()
    local h = new({place = 'pit'})
    enable(h)
    owner(h, 'fight')
    fill_bag(h, 25)
    h.run(590)
    eq(st(h).running, false, 'no trip inside 600 s outside town')
    owner(h, 'revive')
    h.run(55)
    eq(st(h).running, false, 'a revive under the bound still holds past the 600 s deferral')
    ok(h.run_until(function() return st(h).running == true end, 10), 'trip once the revive passed its bound\n' .. h.tail())
    eq(h.logged('in its revive phase for 60s: the town trip no longer waits on it'), 1, 'the bound is logged once\n' .. h.tail(6))
    eq(started(h), 1)
    owner(h, 'fight')
    completes(h)
    h.run(5)
    eq(h.logged('the town trip no longer waits on it'), 1, 'logged once')
    h.assert_clean('revive bound')
end)

case('the revive bound counts continuous revive only, and follows lifecycle.REVIVE_LIMIT', function()
    local h = new({place = 'pit'})
    enable(h)
    owner(h, 'fight')
    fill_bag(h, 25)
    h.run(530)
    owner(h, 'revive')
    h.run(40)
    owner(h, 'fight')
    h.run(1)
    owner(h, 'revive') -- a new revive at ~571 s
    h.run(49)
    eq(st(h).running, false, 'a revive that restarted at ~571 s still holds at ~620 s\n' .. h.tail(6))
    ok(h.run_until(function() return st(h).running == true end, 15), 'trip ~60 s into the new revive\n' .. h.tail())
    owner(h, 'fight')
    completes(h)
    local h2 = new({place = 'pit'})
    enable(h2)
    lifecycle(h2).REVIVE_LIMIT = 30
    owner(h2, 'fight')
    fill_bag(h2, 25)
    h2.run(590)
    owner(h2, 'revive')
    h2.run(25)
    eq(st(h2).running, false, 'held under a 30 s bound')
    ok(h2.run_until(function() return st(h2).running == true end, 10), 'trip after 30 s of revive\n' .. h2.tail())
    eq(h2.logged('in its revive phase for 30s: the town trip no longer waits on it'), 1)
    owner(h2, 'fight')
    completes(h2)
    h.assert_clean('revive continuous')
    h2.assert_clean('revive limit')
end)

print(string.format('Rosie town main 1.0.23: %d checks', checks))
if #failures > 0 then error(#failures .. ' failing case(s):\n' .. table.concat(failures, '\n')) end
