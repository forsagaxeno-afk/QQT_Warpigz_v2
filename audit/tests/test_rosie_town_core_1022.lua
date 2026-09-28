-- QQT_Warpigz_v3 Rosie 1.0.22 (Auditor findings on 1.0.21, town core):
-- 1. The Navigator pause condition ("Rosie") was `trip in progress`, so every
--    busy state tick() does not bound (a dead player, a TristramLoop revive
--    phase that sticks, a load screen that never ends) froze the third-party
--    Navigator and Worldstone. It now needs a tick that drives the trip within
--    NAV_PULSE s and lets go NAV_HOLD_MAX s after the request (logged once).
-- 2. get_status().returned stayed true after the trip, also while idle.
-- 3. A trip waited without a bound while TristramLoop reported phase 'revive';
--    after REVIVE_LIMIT s of it the trip continues (logged once).
-- 4. While the third-party Butler runs a town trip Rosie refuses requests, but
--    the status did not show it: farm plugins asked again every 5 s. It now
--    reads paused / paused_by = 'Butler' outside a Rosie trip.
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
    if passed then print('PASS town core 1.0.22: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL town core 1.0.22: ' .. name .. ': ' .. tostring(err)) end
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
local function tracker(h) return h.mod('Rosie', 'rosie.private.town.core.tracker') end
local function start_trip(h)
    local result = {}
    local accepted, why = as_consumer(h, function()
        return h.G.AlfredTheButlerPlugin.trigger_tasks_with_teleport('Consumer', function(err, res)
            result.err, result.res, result.done = err, res, true
        end)
    end)
    eq(accepted, true, 'trip accepted (' .. tostring(why) .. ')')
    return result
end
-- The third-party Navigator's seen API; only the pause condition matters here.
local function fake_navigator(h)
    local nav = {conditions = {}}
    function nav.held()
        local fn = nav.conditions.Rosie
        if not fn then return false end
        local fine, on = pcall(fn)
        return fine and on == true
    end
    h.G.Navigator = {
        set_pause_condition = function(name, fn) nav.conditions[name] = fn end,
        get_status = function() return {state = 'idle', is_busy = false, is_paused = nav.held(), priority = 0} end,
        navigate = function() return 1 end,
        stop = function() end,
    }
    return nav
end
local function tristram(h, phase)
    h.G.TRISTRAM_LOOP_STATE = {status = function() return {running = true, owns_activity = true, phase = phase} end}
end
-- Seconds until pred() holds (nil when it never does within `limit`).
local function time_until(h, pred, limit)
    local t0 = h.now
    if h.run_until(pred, limit) then return h.now - t0 end
    return nil
end

-- ── 1 + 3: the Navigator hold and the revive bound ─────────────────────────
case('a dead player: Navigator is released within NAV_PULSE s, held again once alive, the trip completes', function()
    local h = new({place = 'pit'})
    enable(h)
    fill_bag(h, 3)
    local nav = fake_navigator(h)
    local lc = lifecycle(h)
    local result = start_trip(h)
    h.run(0.5)
    eq(nav.held(), true, 'held at the trip start')
    h.dead = true
    local took = time_until(h, function() return not nav.held() end, 30)
    ok(took ~= nil and took <= 5.5, 'released while dead: ' .. tostring(took))
    eq(lc.NAV_PULSE, 5, 'NAV_PULSE'); eq(lc.NAV_HOLD_MAX, 300, 'NAV_HOLD_MAX')
    h.run(20)
    eq(nav.held(), false, 'stays released while dead')
    eq(st(h).running, true, 'the trip itself still waits for the player')
    h.dead = false
    ok(time_until(h, function() return nav.held() end, 2) ~= nil, 'held again once the player is alive')
    ok(h.run_until(function() return result.done end, 200), 'trip ends\n' .. h.tail())
    eq(st(h).outcome, 'completed', 'completed\n' .. h.tail())
    eq(nav.held(), false, 'released after the trip')
    eq(h.logged('Navigator released'), 0, 'the cap never fired')
    h.assert_clean('dead')
end)

case('a TristramLoop revive phase that sticks: Navigator released, the trip continues after REVIVE_LIMIT', function()
    local h = new({place = 'pit'})
    enable(h)
    fill_bag(h, 3)
    local nav = fake_navigator(h)
    local lc = lifecycle(h)
    -- The player stands alive in the Pit while TristramLoop stays in 'revive'.
    local result = start_trip(h)
    tristram(h, 'revive')
    eq(nav.held(), true, 'held at the trip start')
    local took = time_until(h, function() return not nav.held() end, 30)
    ok(took ~= nil and took <= 5.5, 'released during the revive phase: ' .. tostring(took))
    eq(lc.REVIVE_LIMIT, 60, 'REVIVE_LIMIT')
    h.run(40)
    eq(result.done, nil, 'the revive phase is honoured at first')
    eq(nav.held(), false, 'Navigator stays free during the honoured revive wait')
    ok(h.run_until(function() return result.done end, 200), 'the trip ends although the revive phase never does\n' .. h.tail())
    eq(st(h).outcome, 'completed', 'completed\n' .. h.tail())
    eq(h.logged('in its revive phase for 60s: Rosie no longer waits on it'), 1, 'logged once\n' .. h.tail())
    eq(nav.held(), false, 'released after the trip')
    -- The same revive, still stuck: a second trip does not wait on it again
    -- (one clock per revive); a new revive gets its own bound.
    fill_bag(h, 3)
    local t2 = h.now
    local r2 = start_trip(h)
    ok(h.run_until(function() return r2.done end, 200), 'second trip ends\n' .. h.tail())
    ok(h.now - t2 < 45, 'no second REVIVE_LIMIT wait for the same revive: ' .. (h.now - t2))
    eq(h.logged('in its revive phase for 60s: Rosie no longer waits on it'), 1, 'logged once per revive')
    tristram(h, 'fight'); h.run(1)
    fill_bag(h, 3)
    local r3 = start_trip(h)
    h.run(0.3)
    tristram(h, 'revive')
    h.run(30)
    eq(r3.done, nil, 'a new revive is honoured again')
    ok(h.run_until(function() return r3.done end, 200), 'third trip ends\n' .. h.tail())
    eq(h.logged('in its revive phase for 60s: Rosie no longer waits on it'), 2, 'logged once per revive')
    h.assert_clean('revive')
end)

case('a revive phase that sticks (no Navigator): the trip is bounded and completes', function()
    local h = new({place = 'pit'})
    enable(h)
    fill_bag(h, 3)
    local t0 = h.now
    local result = start_trip(h)
    h.run(0.3)
    tristram(h, 'revive')
    ok(h.run_until(function() return result.done end, 300), 'the trip ends although the revive phase never does\n' .. h.tail())
    eq(st(h).outcome, 'completed', 'completed\n' .. h.tail())
    ok(h.now - t0 >= 60, 'the revive phase was honoured for a while: ' .. (h.now - t0))
    ok(h.now - t0 < 60 + 120, 'bounded: ' .. (h.now - t0))
    eq(h.logged('in its revive phase for 60s: Rosie no longer waits on it'), 1, 'logged once')
    h.assert_clean('revive bound')
end)

case('a load screen where the host returns no world or no player keeps Navigator held', function()
    for _, which in ipairs({'world', 'player'}) do
        local h = new({place = 'pit'})
        enable(h)
        fill_bag(h, 3)
        local nav = fake_navigator(h)
        local result = start_trip(h)
        h.run(0.3)
        eq(nav.held(), true, 'held at the trip start')
        local name = which == 'world' and 'get_current_world' or 'get_local_player'
        local real = h.G[name]
        h.G[name] = function() return nil end
        local freed = 0
        h.run(8, function() if not nav.held() then freed = freed + 1 end end)
        h.G[name] = real
        eq(freed, 0, 'held through an 8 s load with no ' .. which)
        ok(h.run_until(function() return result.done end, 200), 'trip ends\n' .. h.tail())
        h.assert_clean('no ' .. which)
    end
end)

case('a trip stuck on a load screen: the NAV_HOLD_MAX cap releases Navigator, logged once', function()
    local h = new({place = 'pit'})
    enable(h)
    fill_bag(h, 3)
    local nav = fake_navigator(h)
    local t0 = h.now
    start_trip(h)
    h.run(0.3)
    eq(nav.held(), true, 'held at the trip start')
    -- The player hangs on a load screen that never ends (alive, zone [sno none]).
    h.travel, h.casting, h.goal = nil, false, nil
    h.place, h.pos = h.P.limbo, h.P.limbo.spawn
    h.run(250)
    eq(nav.held(), true, 'a load screen is the trip travelling: still held')
    ok(h.run_until(function() return not nav.held() end, 60), 'released by the cap\n' .. h.tail())
    local at = h.now - t0
    ok(at >= 299 and at <= 301, 'released at the cap: ' .. at)
    eq(h.logged('Navigator released: the town trip has held it for 300s'), 1, 'logged')
    h.run(20)
    eq(nav.held(), false, 'stays released')
    eq(h.logged('Navigator released'), 1, 'logged once')
    eq(st(h).running, true, 'the trip itself is unchanged')
    h.assert_clean('cap')
end)

case('a normal trip holds Navigator throughout, an 8 s load screen included', function()
    local h = new({place = 'pit'})
    enable(h)
    fill_bag(h, 3)
    local nav = fake_navigator(h)
    local result = start_trip(h)
    local gaps, frames, long_load = 0, 0, 0
    ok(h.run_until(function() return result.done end, 200, function()
        -- Loads take 8 s instead of 2 s.
        if h.travel and h.travel.phase == 'loading' and not h.travel.long then
            h.travel.long, h.travel.at = true, h.travel.at + 6
            long_load = long_load + 1
        end
        if st(h).running then
            frames = frames + 1
            if not nav.held() then gaps = gaps + 1 end
        end
    end), 'trip ends\n' .. h.tail())
    eq(st(h).outcome, 'completed', 'completed\n' .. h.tail())
    ok(long_load >= 2, 'both legs loaded slowly: ' .. long_load)
    ok(frames > 100, 'the trip was sampled: ' .. frames)
    eq(gaps, 0, 'Navigator held on every frame of the trip')
    eq(nav.held(), false, 'released after the trip')
    h.assert_clean('normal')
end)

case("the caller's own pause and open chat keep Navigator held (bounded by PAUSE_LIMIT and NAV_HOLD_MAX)", function()
    local h = new({place = 'pit'})
    enable(h)
    fill_bag(h, 3)
    local nav = fake_navigator(h)
    local result = start_trip(h)
    h.run(0.5)
    eq(as_consumer(h, function() return h.G.AlfredTheButlerPlugin.pause('Consumer') end), true)
    local gaps = 0
    h.run(20, function() if not nav.held() then gaps = gaps + 1 end end)
    eq(gaps, 0, 'held during the pause')
    eq(as_consumer(h, function() return h.G.AlfredTheButlerPlugin.resume('Consumer') end), true)
    h.run(0.5)
    h.chat_open = true
    h.run(20, function() if not nav.held() then gaps = gaps + 1 end end)
    eq(gaps, 0, 'held while chat is open')
    h.chat_open = false
    ok(h.run_until(function() return result.done end, 200), 'trip ends\n' .. h.tail())
    eq(st(h).outcome, 'completed', 'completed\n' .. h.tail())
    eq(nav.held(), false, 'released after the trip')
    h.assert_clean('pause and chat')
end)

-- ── 2: returned ─────────────────────────────────────────────────────────────
case('returned is true only while a trip runs', function()
    local h = new({place = 'pit'})
    enable(h)
    fill_bag(h, 3)
    eq(st(h).returned, false, 'idle before any trip')
    local result = start_trip(h)
    local stale, seen = 0, 0
    ok(h.run_until(function() return result.done end, 200, function()
        local s = st(h)
        if s.returned ~= false and s.running ~= true then stale = stale + 1 end
        if s.returned == true and s.running == true then seen = seen + 1 end
    end), 'trip ends\n' .. h.tail())
    ok(seen >= 1, 'returned=true is seen at the end of the trip: ' .. seen)
    eq(st(h).outcome, 'completed', 'completed\n' .. h.tail())
    eq(h.place, h.P.pit, 'back where the trip started')
    local s = st(h)
    eq(s.running, false, 'idle')
    eq(s.returned, false, 'not returned while idle')
    h.run(30)
    eq(st(h).returned, false, 'still false 30 s later')
    eq(stale, 0, 'never returned=true outside a trip')
    h.assert_clean('returned')
end)

-- ── 4: a Butler town trip ───────────────────────────────────────────────────
case('a Butler trip reads as paused by Butler: an HR-like poller makes no request, then one is accepted', function()
    local h = new({place = 'pit'})
    enable(h)
    fill_bag(h, 3)
    local busy = true
    h.G.Butler = {is_busy = function() return busy end}
    -- HelltideRevamped's pattern: every 5 s, request a trip unless paused.
    local poll = {last = -math.huge, requests = 0, refused = 0, accepted = 0, result = {}}
    local function poller()
        if h.now - poll.last < 5 then return end
        poll.last = h.now
        local s = st(h)
        if s.paused or s.running then return end
        poll.requests = poll.requests + 1
        local accepted = as_consumer(h, function()
            return h.G.AlfredTheButlerPlugin.trigger_tasks_with_teleport('Consumer', function(err)
                poll.result.err, poll.result.done = err, true
            end)
        end)
        if accepted == false then poll.refused = poll.refused + 1 else poll.accepted = poll.accepted + 1 end
    end
    h.run(60, poller)
    eq(poll.refused, 0, 'no refused requests during the 60 s Butler trip')
    eq(poll.requests, 0, 'no requests at all during the Butler trip')
    local s = st(h)
    eq(s.paused, true, 'paused while Butler is busy')
    eq(s.paused_by, 'Butler', 'paused_by names Butler')
    eq(s.state_text, 'Waiting: Butler is running a town trip.', 'the state line agrees')
    eq(s.external_pause, false, 'not an external pause')
    eq(s.pause_caller, nil, 'no pause caller')
    eq(tracker(h).external_pause, false, 'tracker.external_pause untouched')
    busy = false
    s = st(h)
    eq(s.paused, false, 'not paused once Butler is idle')
    eq(s.paused_by, nil, 'no paused_by once Butler is idle')
    ok(h.run_until(function() return poll.accepted == 1 end, 10, poller), 'a request is accepted after Butler\n' .. h.tail())
    eq(poll.refused, 0, 'none refused')
    -- During Rosie's own trip a Butler trip does not read as a pause.
    busy = true
    h.run(1)
    s = st(h)
    eq(s.running, true, 'Rosie trip running')
    eq(s.paused, false, 'a running Rosie trip is not reported paused')
    busy = false
    ok(h.run_until(function() return poll.result.done end, 200), 'the trip ends\n' .. h.tail())
    eq(st(h).outcome, 'completed', 'completed\n' .. h.tail())
    -- A caller's own pause still wins over the Butler reading.
    busy = true
    eq(as_consumer(h, function() return h.G.AlfredTheButlerPlugin.pause('Consumer') end), true)
    eq(st(h).paused_by, 'Consumer', 'an explicit pause keeps its caller')
    eq(as_consumer(h, function() return h.G.AlfredTheButlerPlugin.resume('Consumer') end), true)
    eq(st(h).paused_by, 'Butler', 'Butler again after the resume')
    busy = false
    h.G.Butler = {is_busy = function() error('boom') end}
    eq(st(h).paused, false, 'a throwing Butler is not a pause')
    h.assert_clean('butler poller')
end)

case("a Butler trip: Rosie's own automatic trip still waits for it and starts after", function()
    local h = new({place = 'pit'})
    enable(h)
    local busy = true
    h.G.Butler = {is_busy = function() return busy end}
    fill_bag(h, 25)
    h.run(30)
    eq(st(h).running, false, 'no automatic trip during the Butler trip')
    eq(h.logged('but it waits: Butler is running a town trip.'), 1, 'the wait is logged once\n' .. h.tail())
    local task = as_consumer(h, function() return h.G.AlfredTheButlerPlugin.create_task('Consumer') end)
    eq(st(h).need_trigger, true, 'the bag needs a trip')
    eq(as_consumer(h, function() return task.shouldExecute() end), false, 'create_task does not fire during a Butler trip')
    busy = false
    ok(h.run_until(function() return st(h).running == true end, 5), 'the automatic trip starts after Butler\n' .. h.tail())
    ok(h.run_until(function() return st(h).outcome == 'completed' end, 200), 'and completes\n' .. h.tail())
    h.assert_clean('butler automatic')
end)

print(string.format('town core 1.0.22: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
