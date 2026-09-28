-- QQT_Warpigz_v3 Rosie 1.0.21 (live log 2026-09-28): the third-party Navigator
-- (driven by Worldstone) kept moving the player while Rosie cast the Town
-- Portal. Every cast was interrupted, Rosie spent its 8 casts in 24 s and the
-- trip ended `teleport_failed` at 60 s; Worldstone then went to town itself.
-- Rosie now re-casts only once the player has stood still, an interrupted cast
-- is not an attempt, and time spent being moved by someone else is not
-- outbound service time (bounded on its own). A generic, pcall-guarded hook
-- holds foreign navigators for the trip; it does nothing when the API is absent.
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
    if passed then print('PASS foreign mover: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL foreign mover: ' .. name .. ': ' .. tostring(err)) end
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
local function lifecycle(h) return h.mod('Rosie', 'rosie.private.town.core.lifecycle') end

-- A fake Navigator: while active and not paused it issues a new move goal
-- every `every` s (back and forth in the Pit), and any move while the Town
-- Portal channels interrupts the cast, as in the game.
local function navigator(h, every)
    local nav = {active = true, paused = false, moves = 0, interrupts = 0, pauses = 0, resumes = 0, last = -math.huge, flip = false}
    function nav.step()
        if not nav.active or nav.paused or h.place ~= h.P.pit then return end
        if h.now - nav.last < (every or 0.5) then return end
        nav.last, nav.flip = h.now, not nav.flip
        nav.moves = nav.moves + 1
        h.goal = h.v(nav.flip and 60 or 20, 0)
        if h.travel and h.travel.phase == 'channel' then
            h.travel, h.casting = nil, false
            nav.interrupts = nav.interrupts + 1
        end
    end
    return nav
end
-- The move loop freezes the player while a travel channels; a foreign move
-- cancelled it, so the player walks on.
local function start_trip(h)
    local result = {}
    local accepted = as_consumer(h, function()
        return h.G.AlfredTheButlerPlugin.trigger_tasks_with_teleport('Consumer', function(err, res)
            result.err, result.res, result.done = err, res, true
        end)
    end)
    eq(accepted, true, 'trip accepted')
    return result
end
local function casts(h) return #h.waypoints end

case('a Navigator that moves the player for 50 s: Rosie waits and casts once it stands still', function()
    local h = new({place = 'pit', pos = nil})
    enable(h)
    fill_bag(h, 3)
    local nav = navigator(h, 0.5)
    local t0 = h.now
    local result = start_trip(h)
    h.run(50, nav.step)
    local wasted = casts(h)
    ok(wasted <= 1, 'no casts burned while the player is being moved (got ' .. wasted .. ')\n' .. h.tail())
    nav.active = false
    ok(h.run_until(function() return result.done end, 200), 'trip ends\n' .. h.tail())
    eq(st(h).outcome, 'completed', 'trip completes after the Navigator stops\n' .. h.tail())
    eq(h.logged('teleport_failed'), 0, 'no teleport_failed')
    eq(h.place, h.P.pit, 'back in the Pit')
    ok(h.now - t0 < 150, 'finished promptly')
    eq(h.logged('Town Portal waits: another addon moves the player'), 1, 'the wait is logged once')
    h.assert_clean('50 s navigator')
end)

case('a Navigator that stops every 7 s for 2 s: interrupted casts are not attempts', function()
    local h = new({place = 'pit'})
    enable(h)
    fill_bag(h, 3)
    -- Moves for 5 s (every 0.5 s), then idles for 2 s; a cast started late in
    -- the idle window is interrupted by the next burst.
    local nav = navigator(h, 0.5)
    local base = h.now
    local function step()
        local phase = (h.now - base) % 7
        nav.active = phase < 5 and h.now - base < 80
        nav.step()
    end
    local result = start_trip(h)
    ok(h.run_until(function() return result.done end, 300, step), 'trip ends\n' .. h.tail())
    eq(st(h).outcome, 'completed', 'the trip completes\n' .. h.tail())
    h.assert_clean('bursty navigator')
end)

case('a Navigator that never stops: the trip fails with a clear reason, bounded', function()
    local h = new({place = 'pit'})
    enable(h)
    fill_bag(h, 3)
    local nav = navigator(h, 0.5)
    local t0 = h.now
    local result = start_trip(h)
    ok(h.run_until(function() return result.done end, 400, nav.step), 'trip ends\n' .. h.tail())
    eq(result.err, 'failed', 'failed')
    ok(h.now - t0 <= 60 + (lifecycle(h).MOVER_WAIT or 120) + 2, 'bounded: ' .. (h.now - t0))
    ok(h.logged('another addon kept moving the player') >= 1, 'the reason names the foreign mover\n' .. h.tail())
    ok(casts(h) <= 1, 'no casts burned while moving: ' .. casts(h))
    h.assert_clean('endless navigator')
end)

case('no foreign mover: the cast is immediate and one cast serves the trip', function()
    local h = new({place = 'pit'})
    enable(h)
    fill_bag(h, 3)
    local result = start_trip(h)
    ok(h.run_until(function() return result.done end, 200), 'trip ends\n' .. h.tail())
    eq(st(h).outcome, 'completed')
    eq(casts(h), 1, 'one cast')
    eq(h.logged('Town Portal waits'), 0, 'nothing to wait for')
    h.assert_clean('plain')
end)

case('the foreign hold hook: holds a registered navigator for the trip and releases it after', function()
    local h = new({place = 'pit'})
    enable(h)
    fill_bag(h, 3)
    local nav = navigator(h, 0.5)
    h.G.FakeNavigatorPlugin = {
        pause = function(who) nav.paused = true; nav.pauses = nav.pauses + 1; nav.by = who end,
        resume = function(who) nav.paused = false; nav.resumes = nav.resumes + 1 end,
    }
    local lc = lifecycle(h)
    lc.add_foreign_hold({name = 'FakeNavigator', global = 'FakeNavigatorPlugin',
        hold = function(api, label) api.pause(label) end,
        release = function(api, label) api.resume(label) end})
    local t0 = h.now
    local result = start_trip(h)
    h.run(1, nav.step)
    eq(nav.paused, true, 'held at the trip start')
    ok(h.run_until(function() return result.done end, 200, nav.step), 'trip ends\n' .. h.tail())
    eq(st(h).outcome, 'completed', 'completed\n' .. h.tail())
    eq(casts(h), 1, 'one cast: the held navigator never interrupted it')
    eq(nav.pauses, 1, 'held once per trip')
    eq(nav.resumes, 1, 'released once')
    eq(nav.paused, false, 'released after the trip')
    ok(h.now - t0 < 120)
    h.assert_clean('hold hook')
end)

case('the foreign hold hook is pcall-guarded and a no-op when the API is absent', function()
    local h = new({place = 'pit'})
    enable(h)
    fill_bag(h, 3)
    local lc = lifecycle(h)
    local calls = 0
    lc.add_foreign_hold({name = 'Absent', global = 'NoSuchNavigatorPlugin',
        hold = function() calls = calls + 1 end, release = function() calls = calls + 1 end})
    h.G.ThrowingNavigatorPlugin = {}
    lc.add_foreign_hold({name = 'Throwing', global = 'ThrowingNavigatorPlugin',
        hold = function() error('boom hold') end, release = function() error('boom release') end})
    local result = start_trip(h)
    ok(h.run_until(function() return result.done end, 200), 'trip ends\n' .. h.tail())
    eq(st(h).outcome, 'completed', 'a throwing peer never fails the trip\n' .. h.tail())
    eq(calls, 0, 'an absent API is never called')
    eq(h.logged('Could not hold Throwing'), 1, 'the hold error is logged once')
    eq(lc.cleanup_pending(), 0, 'a throwing release leaves no pending cleanup')
    h.assert_clean('guarded')
end)

print(string.format('foreign mover: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
