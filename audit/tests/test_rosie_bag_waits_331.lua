-- QQT_Warpigz_v3 3.3.1 (live report: a Worldstone loop farmed for hours with
-- a full bag, the stash half empty, no Rosie town trip and no log line).
-- A full bag never waits forever: another activity owning the run or a
-- foreign town pause is served after 60 s in a town (between runs) or 600 s
-- anywhere; a latch that waits for Run town service is retried by Rosie's own
-- automatic service every 600 s; every wait names its reason once.
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
    if passed then print('PASS bag waits: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL bag waits: ' .. name .. ': ' .. tostring(err)) end
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
local function fill_bag(h, n, fields)
    h.inventory = {}
    for i = 1, n or 25 do h.inventory[i] = h.gear(fields) end
end
local function owner(h, phase)
    h.G.TRISTRAM_LOOP_STATE = {status = function() return {running = true, owns_activity = true, phase = phase} end}
end
local function started(h) return h.logged('[Rosie] Bag needs a town trip for') end

case('an activity owning the run: served after 60 s while the player stands in town', function()
    local h = new({place = 'temis'})
    enable(h)
    owner(h, 'travel')
    fill_bag(h, 25)
    h.run(30)
    eq(st(h).running, false, 'no trip inside 60 s')
    eq(h.logged('but it waits: another activity owns the run'), 1, 'the reason is logged once')
    ok(h.run_until(function() return st(h).running == true end, 40), 'trip after ~60 s in town\n' .. h.tail())
    eq(started(h), 1, 'the override is logged')
    ok(h.run_until(function() return st(h).outcome == 'completed' end, 120), 'trip completes\n' .. h.tail())
    eq(#h.inventory, 0, 'bag emptied')
    h.assert_clean('owner in town')
end)

-- QQT_Warpigz_v3 1.0.22: a revive phase is honoured for REVIVE_LIMIT s at
-- most (it was waited on without a bound, C6; test_rosie_town_main_1022.lua).
case('an activity owning the run outside town: served after 600 s, not during a revive under its bound', function()
    local h = new({place = 'pit'})
    enable(h)
    owner(h, 'fight')
    fill_bag(h, 25)
    h.run(590)
    owner(h, 'revive')
    h.run(55)
    eq(st(h).running, false, 'a revive under REVIVE_LIMIT holds the start past the 600 s deferral')
    owner(h, 'fight')
    h.run(1)
    ok(h.run_until(function() return st(h).running == true end, 5), 'trip once the revive ended (waited > 600 s)')
    eq(started(h), 1)
    local h2 = new({place = 'pit'})
    enable(h2)
    owner(h2, 'fight')
    fill_bag(h2, 25)
    h2.run(590)
    eq(st(h2).running, false, 'no trip inside 600 s outside town')
    ok(h2.run_until(function() return st(h2).running == true end, 20), 'trip after 600 s\n' .. h2.tail())
    ok(h2.run_until(function() return st(h2).outcome == 'completed' end, 200), 'trip completes\n' .. h2.tail())
    h2.assert_clean('owner outside town')
end)

case("a foreign town pause left on while idle: released after 600 s with a full bag", function()
    local h = new({place = 'pit'})
    enable(h)
    eq(as_consumer(h, function() return h.G.AlfredTheButlerPlugin.pause('Worldstone') end), true)
    fill_bag(h, 25)
    h.run(300)
    eq(st(h).running, false, 'the pause is respected at first')
    eq(h.logged('but it waits: paused by Worldstone'), 1, 'reason logged once')
    ok(h.run_until(function() return st(h).running == true end, 320), 'trip after 600 s\n' .. h.tail())
    eq(st(h).paused, false, 'the stale pause was released')
    ok(h.run_until(function() return st(h).outcome == 'completed' end, 200), 'trip completes\n' .. h.tail())
    h.assert_clean('stale pause')
end)

case('a latch waiting for Run town service is retried by the automatic service every 600 s', function()
    local h = new()
    enable(h)
    h.mod('Rosie', 'rosie.private.town.gui').elements.skip_favorite:set(true)
    fill_bag(h, 25, {locked = true})
    ok(h.run_until(function() return h.logged('[Rosie] failed') == 1 end, 200), 'first trip fails\n' .. h.tail())
    ok(h.logged('equipment bag 25') >= 1, 'the failure names the need left')
    h.run(1)
    eq(st(h).stuck_retry_in, nil, 'latched for API callers')
    h.run(500)
    eq(h.logged('[Rosie] failed'), 1, 'no retry inside 600 s')
    for _, item in ipairs(h.inventory) do item.locked = false end
    ok(h.run_until(function() return st(h).outcome == 'completed' end, 200), 'automatic retry after 600 s\n' .. h.tail())
    eq(#h.inventory, 0)
    h.assert_clean('latch retry')
end)

case('automatic service switched off by the keybind: the wait is logged once', function()
    local h = new()
    enable(h)
    h.mod('Rosie', 'rosie.private.town.gui').elements.use_keybind:set(true)
    fill_bag(h, 25)
    h.run(20)
    eq(st(h).running, false)
    eq(h.logged('but it waits: automatic service is off (keybind toggle)'), 1)
    h.assert_clean('keybind')
end)

print(string.format('Rosie bag waits 3.3.1: %d checks', checks))
if #failures > 0 then error(#failures .. ' failing case(s):\n' .. table.concat(failures, '\n')) end
