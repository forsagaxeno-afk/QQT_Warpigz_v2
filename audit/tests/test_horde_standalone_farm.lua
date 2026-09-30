-- QQT_Warpigz_v3: standalone HordeDev farming regressions in the joint host
-- (real HordeDev + Batmobile + Rosie, no WarPigs; the user's plain farming
-- setup). Each case is a night-audit reproduction that failed before the fix:
--   A  a Horde run left outside HordeDev's own exit (the player ends up in
--      Temis mid-run) is reset once and the next compass is used; before,
--      HordeDev idled at the Caldeum gate for good (no fault, hold or log).
--   B  'Use alfred' off: HordeDev yields to Rosie's own automatic town trip
--      instead of teleporting to the Library in the middle of it (the bag
--      stayed full and the two teleports fought every ~125 s).
--   C  HordeDev's pylon pause of Rosie pickup is released by a toggle off,
--      disable() and a HordeDev reload ('Paused by HordeDev.' forever).
--   D  console volume of one horde (was ~2900 lines / 300 s, 60 in 1 s).
--   E  Rosie's automatic trip during the RESET exit or the sigil activation
--      no longer latches 'Leave Dungeon/reset timed out' / 'Activation timed
--      out'; the next run starts.
--   F  'Pick Pylon delay' applies to every pylon, not only the first.
-- QQT_Warpigz_v3 owner-build: no Rosie in this build (SteroidAlfred +
-- LooteerV3). B and C exercised Rosie's own automatic trip and pickup pause
-- and are dropped; E runs with the joint host's Alfred mock (a bag-full
-- need that HordeDev's Alfred task services); A, D, F are unchanged.
-- Runs under Lua 5.4 and LuaJIT.
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
    if passed then print('PASS HordeDev standalone farm: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err) end
end

local HD = 'HordeDev'
local function farm(compasses, place)
    local h = J.new({rosie = false, dirs = {'Batmobile', HD}, place = place or 'caldeum'})
    h.assert_clean('load')
    h.instrument_exports()
    h.give_compasses(compasses or 2)
    local A = h.setup_horde({})
    return h, A, h.mod(HD, 'gui').elements
end
local function hd_status(h) return h.as(HD, function() return h.G.InfernalHordesPlugin.status() end) end
local function hd_waypoints(h)
    return h.count(h.waypoints, function(w) return w.context == HD end)
end

case('A abandoned run (player moved to Temis at wave 3) is reset and the next compass is used', function()
    local h, A, hd = farm(2)
    hd.main_toggle:set(true)
    ok(h.run_until(function() return A.wave >= 3 end, 300), 'reached wave 3')
    h.travel_to('temis', 1.0, 'waypoint')
    ok(h.run_until(function() return A.runs >= 2 end, 400), 'a second horde was started\n' .. h.tail(30))
    eq(#h.items, 2, 'the second compass was used')
    eq(h.logged("resetting it for a new run"), 1, 'one recovery line')
    eq(hd_status(h).fault, nil, 'no fault')
    h.assert_clean('A')
end)

case('D one horde logs on change, not on every pulse', function()
    local h, A, hd = farm(1)
    hd.main_toggle:set(true)
    h.run(300)
    ok(A.runs >= 1 and #A.opened >= 1, 'the horde and its chests were run')
    local per = {}
    for _, line in ipairs(h.log) do
        local t = tonumber(line:match('^([%d%.]+)'))
        if t then per[math.floor(t)] = (per[math.floor(t)] or 0) + 1 end
    end
    local peak = 0
    for _, n in pairs(per) do if n > peak then peak = n end end
    ok(#h.log < 700, 'total console lines in 300 s: ' .. #h.log)
    ok(peak <= 25, 'peak console lines in one second: ' .. peak)
    eq(h.logged('Setting custom target.'), 0, 'explorer per-pulse line')
    ok(h.logged('Current state: WAITING_FOR_LOOT') <= 6, 'chest state logged on change')
    ok(h.logged('Starting move_in_pattern function') == 0, 'move_in_pattern per-call trace')
    ok(h.logged('Executing Walking to Horde task') <= 4, 'walking logged once per episode')
    h.assert_clean('D')
end)

case("E a bag-full Alfred trip during the RESET exit: no fault, next run starts", function()
    local h, A, hd = farm(2)
    hd.main_toggle:set(true)
    ok(h.run_until(function() return h.leaves >= 1 and h.place.key == 'caldeum' end, 300), 'left the Horde')
    -- bag full: the town service starts its own with-teleport trip (as
    -- SteroidAlfred does on need_trigger), not HordeDev's request.
    h.alfred.need_trigger, h.alfred.inventory_full = true, true
    h.as(h.alfred_ctx, function() return h.G.AlfredTheButlerPlugin.trigger_tasks_with_teleport('alfred_the_butler') end)
    ok(h.run_until(function() return A.runs >= 2 end, 300), 'the next run started\n' .. h.tail(30))
    eq(h.alfred.job == nil and h.alfred.inventory_full, false, 'the Alfred trip completed')
    eq(hd_status(h).fault, nil, 'no latched exit fault')
    ok(h.resets >= 1, 'the old instance was reset')
    h.assert_clean('E exit')
end)

case("E a bag-full Alfred trip during the sigil activation: no fault, a new run starts", function()
    local h, A, hd = farm(2)
    hd.main_toggle:set(true)
    ok(h.run_until(function() return h.logged('Sigil requested') > 0 end, 300), 'sigil requested')
    -- bag full: the town service starts its own with-teleport trip (as
    -- SteroidAlfred does on need_trigger), not HordeDev's request.
    h.alfred.need_trigger, h.alfred.inventory_full = true, true
    h.as(h.alfred_ctx, function() return h.G.AlfredTheButlerPlugin.trigger_tasks_with_teleport('alfred_the_butler') end)
    ok(h.run_until(function() return A.runs >= 1 end, 300), 'a horde was started after the trip\n' .. h.tail(30))
    eq(h.alfred.job == nil and h.alfred.inventory_full, false, 'the Alfred trip completed')
    eq(hd_status(h).fault, nil, 'no latched activation fault')
    h.assert_clean('E sigil')
end)

case("F 'Pick Pylon delay' applies to every pylon of a run", function()
    local h, A, hd = farm(1)
    hd.main_toggle:set(true)
    h.run(90)
    local pylons = h.count(A.events, function(e) return e.what:find('^pylon %d') ~= nil end)
    ok(pylons >= 5, 'pylons taken: ' .. pylons)
    local waits, interacts = {}, {}
    for _, line in ipairs(h.log) do
        local t = tonumber(line:match('^([%d%.]+)'))
        if line:find('Waiting for pylon to be interactable.', 1, true) then waits[#waits + 1] = t end
        if line:find('Interacting with pylon.', 1, true) then interacts[#interacts + 1] = t end
    end
    ok(#waits >= pylons, string.format('a delay before each pylon: %d waits for %d pylons', #waits, pylons))
    local delay = h.mod(HD, 'core.settings').pick_pylon_delay
    for i, t in ipairs(interacts) do
        local waited = nil
        -- the first wait line of this pylon's episode (within 5 s before it)
        for _, w in ipairs(waits) do if not waited and w <= t and t - w < 5 then waited = t - w end end
        ok(waited and waited >= delay - 0.25, string.format('pylon interaction %d at %.1f waited %s s', i, t, tostring(waited)))
    end
    h.assert_clean('F')
end)

for _, failure in ipairs(failures) do print('FAIL ' .. failure) end
print(string.format('HordeDev standalone farm (joint): %d checks, %d failures', checks, #failures))
assert(#failures == 0, 'HordeDev standalone farm regressions failed')
print(string.format('PASS: HordeDev standalone farm regressions (%d checks)', checks))
