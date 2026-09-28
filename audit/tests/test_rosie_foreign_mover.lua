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
-- QQT_Warpigz_v3 1.0.23: a mover that walks the player on `delay` s into each
-- Town Portal channel (the move interrupts it, as in the game), `dist` m back
-- and forth, for the first `limit` casts (nil: every cast). With `leg` set it
-- also walks a leg every `leg` s between casts (a stop-and-go Navigator).
local function interrupter(h, opts)
    local m = {interrupts = 0, dir = 1, last = h.now}
    function m.step()
        if h.place ~= h.P.pit or (opts.limit and m.interrupts >= opts.limit) then return end
        local rec = h.waypoints[#h.waypoints]
        local channel = h.travel and h.travel.phase == 'channel' and rec ~= nil
        local walk = (channel and h.now - rec.t >= (opts.delay or 0.3))
            or (not channel and opts.leg and h.now - m.last >= opts.leg)
        if not walk then return end
        m.last, m.dir = h.now, -m.dir
        h.goal = h.v(h.pos:x() - m.dir * (opts.dist or 1), h.pos:y())
        if channel then h.travel, h.casting = nil, false; m.interrupts = m.interrupts + 1 end
    end
    return m
end

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

-- QQT_Warpigz_v3 1.0.23: renamed; it passes on 1.0.20 too (one cast of two is
-- interrupted). The refund is proven by the stop-and-go case at the end.
case('a Navigator that stops every 7 s for 2 s: Rosie casts in an idle window, the trip completes', function()
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


-- ── the observed third-party peers (docs/THIRD_PARTY_APIS.md) ──────────────
-- A fake Navigator with the seen API: navigate(opts) -> id, stop(),
-- get_status(), set_pause_condition(name, fn) (optional). An active request
-- that is not paused walks the player back and forth every 0.5 s and a move
-- during the channel interrupts the Town Portal cast.
local function fake_navigator(h, opts)
    opts = opts or {}
    local nav = {req = nil, next_id = 0, conditions = {}, stops = 0, interrupts = 0, flip = false, last = -math.huge,
        paused_frames = 0, api = {}}
    local function paused()
        for _, fn in pairs(nav.conditions) do
            local ok, on = pcall(fn)
            if ok and on then return true end
        end
        return false
    end
    nav.is_paused = paused
    function nav.api.navigate(o)
        nav.next_id = nav.next_id + 1
        nav.req = {id = nav.next_id, owner = o and o.owner}
        return nav.next_id
    end
    function nav.api.stop() nav.stops = nav.stops + 1; nav.req = nil end
    function nav.api.get_status()
        return {state = nav.req and 'exploring' or 'idle', owner = nav.req and nav.req.owner, request_id = nav.req and nav.req.id,
            is_busy = nav.req ~= nil, is_paused = paused(), priority = 0, mode = 'explore'}
    end
    if opts.condition ~= false then
        function nav.api.set_pause_condition(name, fn) nav.conditions[name] = fn end
    end
    function nav.step()
        if not nav.req or h.place ~= h.P.pit then return end
        if paused() then nav.paused_frames = nav.paused_frames + 1; return end
        if h.now - nav.last < 0.5 then return end
        nav.last, nav.flip = h.now, not nav.flip
        h.goal = h.v(nav.flip and 60 or 20, 0)
        if h.travel and h.travel.phase == 'channel' then
            h.travel, h.casting = nil, false
            nav.interrupts = nav.interrupts + 1
        end
    end
    h.G.Navigator = nav.api
    return nav
end
-- Worldstone: polls Alfred's status every 5 s (seen) and re-issues its
-- Navigator request whenever Navigator is idle, never waiting for Rosie.
local function fake_worldstone(h, nav)
    local ws = {polls = {}, last = -math.huge, navigates = 0}
    function ws.step()
        nav.step()
        if h.now - ws.last < 5 then return end
        ws.last = h.now
        local st = h.as(CONSUMER, function() return h.G.AlfredTheButlerPlugin.get_status() end)
        ws.polls[#ws.polls + 1] = {t = h.now, trigger_tasks = st.trigger_tasks, returned = st.returned, running = st.running}
        if h.place == h.P.pit and not nav.req then
            nav.api.navigate({owner = 'Worldstone', explore = true}); ws.navigates = ws.navigates + 1
        end
    end
    h.G.Worldstone = {get_status = function() return {} end}
    return ws
end
local function fake_scavenger(h)
    local sc = {busy = false, pauses = {}, calls = {}}
    h.G.Scavenger = {
        is_busy = function() return sc.busy end,
        pause = function(who) sc.pauses[who] = true; sc.calls[#sc.calls + 1] = 'pause:' .. tostring(who) end,
        resume = function(who) sc.pauses[who] = nil; sc.calls[#sc.calls + 1] = 'resume:' .. tostring(who) end,
        get_status = function() return {} end,
    }
    return sc
end

case('Navigator + Worldstone (pause condition): the trip holds Navigator, Worldstone sees a trip in progress', function()
    local h = new({place = 'pit'})
    enable(h)
    fill_bag(h, 3)
    local nav = fake_navigator(h)
    local ws = fake_worldstone(h, nav)
    nav.api.navigate({owner = 'Worldstone', explore = true})
    h.run(6, ws.step)
    local result = start_trip(h)
    local t_start = h.now
    ok(h.run_until(function() return result.done end, 200, ws.step), 'trip ends\n' .. h.tail())
    local t_end = h.now
    eq(st(h).outcome, 'completed', 'completed\n' .. h.tail())
    eq(h.logged('teleport_failed'), 0, 'no teleport_failed')
    eq(nav.interrupts, 0, 'the held Navigator never interrupted the cast')
    eq(casts(h), 1, 'one cast')
    ok(nav.paused_frames > 0, 'Navigator was paused by the condition')
    eq(nav.is_paused(), false, 'the condition lets go after the trip')
    local during = 0
    for _, p in ipairs(ws.polls) do
        if p.t > t_start + 0.2 and p.t < t_end then
            during = during + 1
            eq(p.trigger_tasks, true, 'Worldstone sees trigger_tasks=true at ' .. p.t)
            eq(p.running, true, 'running at ' .. p.t)
        end
    end
    ok(during >= 2, 'Worldstone polled during the trip: ' .. during)
    eq(h.logged('pause condition "Rosie"'), 1, 'the hold method is logged once')
    -- A second trip does not register again.
    fill_bag(h, 3)
    local r2 = start_trip(h)
    ok(h.run_until(function() return r2.done end, 200, ws.step), 'second trip ends\n' .. h.tail())
    eq(st(h).outcome, 'completed')
    eq(h.logged('pause condition "Rosie"'), 1, 'still logged once')
    h.assert_clean('pause condition')
end)

case('Navigator without a pause condition: Rosie stops its request before the cast, again when Worldstone re-issues it', function()
    local h = new({place = 'pit'})
    enable(h)
    fill_bag(h, 3)
    local nav = fake_navigator(h, {condition = false})
    local ws = fake_worldstone(h, nav)
    nav.api.navigate({owner = 'Worldstone', explore = true})
    h.run(6, ws.step)
    local result = start_trip(h)
    ok(h.run_until(function() return result.done end, 200, ws.step), 'trip ends\n' .. h.tail())
    eq(st(h).outcome, 'completed', 'completed\n' .. h.tail())
    ok(nav.stops >= 1, 'Navigator.stop() was called')
    ok(nav.stops <= 30, 'stops are bounded: ' .. nav.stops)
    eq(h.logged('Navigator request of Worldstone stopped for the Town Portal cast'), 1, 'logged once per trip')
    h.assert_clean('stop')
end)

case('Scavenger: paused as Rosie for the trip and resumed after; pickup yields while it is busy', function()
    local h = new({place = 'pit'})
    enable(h)
    fill_bag(h, 3)
    local sc = fake_scavenger(h)
    local result = start_trip(h)
    h.run(0.5)
    eq(sc.pauses.Rosie, true, 'Scavenger paused under Rosie at the trip start')
    ok(h.run_until(function() return result.done end, 200), 'trip ends\n' .. h.tail())
    eq(sc.pauses.Rosie, nil, 'resumed after the trip')
    eq(sc.calls[1], 'pause:Rosie'); eq(sc.calls[#sc.calls], 'resume:Rosie')
    eq(#sc.calls, 2, 'one pause, one resume')
    h.inventory = {}
    h.run(2)
    -- Pickup yields while Scavenger is busy, and takes the drop once it is not.
    h.pos = h.v(0, 0)
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(30)
    local item = h.drop('pit', 8, 0, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_031'})
    sc.busy = true
    h.run(6)
    ok(item.picked ~= true, 'no pickup while Scavenger is busy')
    ok(h.pos:dist_to_ignore_z(h.v(0, 0)) < 0.5, 'Rosie did not walk to the drop')
    sc.busy = false
    ok(h.run_until(function() return item.picked == true end, 30), 'taken once Scavenger is idle\n' .. h.tail())
    h.assert_clean('scavenger')
end)

case('Butler running a town trip: Rosie does not start one', function()
    local h = new({place = 'pit'})
    enable(h)
    local busy = true
    h.G.Butler = {is_busy = function() return busy end}
    local accepted, why = as_consumer(h, function()
        return h.G.AlfredTheButlerPlugin.trigger_tasks_with_teleport('Consumer', function() end)
    end)
    eq(accepted, false, 'refused while Butler is busy')
    ok(tostring(why):find('Butler', 1, true), 'reason names Butler: ' .. tostring(why))
    busy = false
    fill_bag(h, 3)
    local result = start_trip(h)
    ok(h.run_until(function() return result.done end, 200), 'accepted once Butler is idle\n' .. h.tail())
    h.G.Butler = {is_busy = function() error('boom') end}
    fill_bag(h, 3)
    local r2 = start_trip(h)
    ok(h.run_until(function() return r2.done end, 200), 'a throwing Butler never blocks Rosie')
    h.assert_clean('butler')
end)

-- QQT_Warpigz_v3 1.0.23 (Auditor, Rosie 1.0.21 LOW): the refund had no test that
-- fails without it, and it made the 8-cast cap moot.
case('a stop-and-go Navigator that walks on during each of the first 10 casts: interrupted casts are not attempts', function()
    local h = new({place = 'pit'})
    enable(h)
    fill_bag(h, 3)
    local m = interrupter(h, {delay = 0.3, dist = 3, leg = 2, limit = 10})
    local t0 = h.now
    local result = start_trip(h)
    ok(h.run_until(function() return result.done end, 300, m.step), 'trip ends\n' .. h.tail())
    eq(st(h).outcome, 'completed', 'the trip completes after 10 interrupted casts\n' .. h.tail())
    eq(m.interrupts, 10, 'ten casts were interrupted')
    eq(casts(h), 11, 'ten interrupted casts, then the one that lands')
    eq(h.logged('teleport_failed'), 0, 'no teleport_failed')
    eq(h.place, h.P.pit, 'back in the Pit')
    ok(h.now - t0 < 200, 'finished: ' .. (h.now - t0))
    -- The refunds are per trip: the next trip gets them again.
    m.interrupts = 0
    fill_bag(h, 3)
    local r2 = start_trip(h)
    ok(h.run_until(function() return r2.done end, 300, m.step), 'second trip ends\n' .. h.tail())
    eq(st(h).outcome, 'completed', 'the second trip completes too\n' .. h.tail())
    eq(casts(h), 22, 'again ten interrupted casts, then the one that lands')
    h.assert_clean('stop-and-go navigator')
end)

case('a fight nudge (orbwalker) 0.3 s into every cast: the refunds are capped, at most 12 casts', function()
    local h = new({place = 'pit'})
    enable(h)
    fill_bag(h, 3)
    local m = interrupter(h, {delay = 0.3, dist = 1})
    local t0 = h.now
    local result = start_trip(h)
    ok(h.run_until(function() return result.done end, 400, m.step), 'trip ends\n' .. h.tail())
    eq(result.err, 'failed', 'the trip fails\n' .. h.tail())
    ok(m.interrupts >= casts(h) - 1, 'every cast was interrupted: ' .. m.interrupts .. '/' .. casts(h))
    ok(casts(h) <= 12, 'casts are bounded by the refund cap (1.0.21: 27): ' .. casts(h))
    eq(casts(h), 12, '8 attempts + 4 refunded casts')
    eq(h.logged('4 interrupted casts were not counted'), 1, 'the cap is logged once')
    ok(h.now - t0 <= 60 + (lifecycle(h).MOVER_WAIT or 120) + 2, 'bounded: ' .. (h.now - t0))
    h.assert_clean('nudge')
end)

print(string.format('foreign mover: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
