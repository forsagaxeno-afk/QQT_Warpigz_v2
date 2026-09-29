-- QQT_Warpigz_v3 WonderCity 2.2.7: W2 of audit/reviews/sweep_2026-09-28.md
-- (S3 F1/F2, harness B7 pad thrash). On a Grand Beacon floor the floor exit
-- (X1_Undercity_WarpPad + X1_Undercity_PortalSwitch) stays locked until the
-- beacon is lit.
--   A the warp pad no longer pulls the portal task while its switch is
--     locked (it walked to the pad, the explorer walked away, again and
--     again: 26-47 task switches in 15 s);
--   B the exit seen on this floor is remembered: once the beacon is lit the
--     player walks back to it (it used to wander until the exit came within
--     check_distance again: 68-87 s lost per beacon floor).
-- Joint host: real Batmobile + WonderCity. Runs under Lua 5.4 and LuaJIT.
local SUITE = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local checks, failures = 0, {}
local function ok(cond, message)
    checks = checks + 1
    if not cond then error(message or 'assertion failed', 2) end
end
local function eq(actual, expected, message)
    checks = checks + 1
    if actual ~= expected then
        error((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
end
local function case(name, fn)
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS WonderCity beacon exit: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL WonderCity beacon exit: ' .. name .. ': ' .. tostring(err)) end
end

local J = dofile(SUITE .. '/audit/tests/joint_host.lua')

-- Floor 1: pad + locked switch 6-7 m from the spawn, the Grand Beacon at
-- beacon_x (beyond check_distance); lighting it opens the switch.
local function beacon_floor(beacon_x)
    local h = J.new({dirs = {'Batmobile', 'WonderCity'}, place = 'undercity'})
    h.assert_clean('load')
    local uc = h.P.undercity
    -- The floor goes on past the beacon (unexplored ground to the west).
    uc.zone, uc.slide, uc.box = 'X1_Undercity_Ziggurat_01', true, {-250, 40, -30, 30}
    h.P.uc2 = {name = 'X1_Undercity_Joint2', zone = 'X1_Undercity_Ziggurat_02', id = 78, town = false,
        spawn = h.v(0, 0), box = {-60, 60, -60, 60}, key = 'uc2', actors = {}}
    h.pad = h.actor('undercity', 'X1_Undercity_WarpPad', 6, 0)
    local sw = h.actor('undercity', 'X1_Undercity_PortalSwitch', 7, 0, {interactable = false})
    sw.on_interact = function() if sw.interactable ~= false then h.travel_to(h.P.uc2, 0.5, 'floor portal') end end
    h.switch = sw
    local beacon = h.actor('undercity', 'X1_Undercity_Enticements_SpiritBeaconSwitch', beacon_x, 0)
    beacon.on_interact = function() beacon.interactable = false; sw.interactable = true; h.lit_at = h.lit_at or h.now end
    h.beacon = beacon
    h.mod('WonderCity', 'gui').elements.main_toggle:set(true)
    h.portal_task = h.mod('WonderCity', 'tasks.portal')
    h.manager = h.mod('WonderCity', 'core.task_manager')
    return h
end
local function count_switches(h, seconds)
    local last, switches = nil, 0
    h.run(seconds, function()
        local name = h.manager.get_current_task().name
        if last ~= nil and name ~= last and (name == 'portal' or last == 'portal') then switches = switches + 1 end
        last = name
    end)
    return switches
end

case('W2-A a warp pad 6 m away whose PortalSwitch is locked does not drive the portal task (no thrash)', function()
    local h = beacon_floor(-55)
    h.run(0.5)
    eq(h.as('WonderCity', function() return h.portal_task.shouldExecute() end), false,
        'portal.shouldExecute with the switch locked')
    local switches = count_switches(h, 15)
    print('  portal task switches in 15 s: ' .. switches)
    ok(switches < 3, 'portal <-> other task switches in 15 s: ' .. switches .. '\n' .. h.tail(20))
    eq(#h.errors, 0, 'no host errors')
end)

case('W2-B the exit seen before the beacon is remembered: once the beacon is lit the player walks back and leaves', function()
    local h = beacon_floor(-55)
    h.run(1) -- the exit (locked) is seen within check_distance
    -- The player is 60 m away at the beacon (the explorer took it there);
    -- WonderCity lights it; the exit opens far out of check_distance.
    h.pos, h.goal = h.v(-52, 3), nil
    ok(h.run_until(function() return h.lit_at ~= nil end, 20), 'the beacon was lit\n' .. h.tail(20))
    ok(h.run_until(function() return h.place == h.P.uc2 end, 40), 'floor 2 within 40 s of the beacon\n' .. h.tail(30))
    ok(h.count(h.interactions, function(r) return r.skin == 'X1_Undercity_PortalSwitch' end) >= 1,
        'the PortalSwitch was interacted with')
    eq(#h.errors, 0, 'no host errors')
end)

case('W2-C an open PortalSwitch set aside (no progress while a fight held the player) is set aside with its pad: no thrash', function()
    -- test_wondercity_bounds B7 "fight" floor: pad 16 m, open switch 17 m.
    local h = J.new({dirs = {'Batmobile', 'WonderCity'}, place = 'undercity'})
    local uc = h.P.undercity
    uc.zone, uc.slide, uc.box = 'X1_Undercity_Ziggurat_01', true, {-60, 60, -40, 40}
    h.P.uc2 = {name = 'X1_Undercity_Joint2', zone = 'X1_Undercity_Ziggurat_02', id = 78, town = false,
        spawn = h.v(0, 0), box = {-60, 60, -60, 60}, key = 'uc2', actors = {}}
    h.actor('undercity', 'X1_Undercity_WarpPad', 16, 0)
    local sw = h.actor('undercity', 'X1_Undercity_PortalSwitch', 17, 0)
    sw.on_interact = function() h.travel_to(h.P.uc2, 0.5, 'floor portal') end
    h.speed = 0 -- a fight holds the player in place for 15 s
    h.at(15, function() h.speed = 7 end)
    h.mod('WonderCity', 'gui').elements.main_toggle:set(true)
    local manager = h.mod('WonderCity', 'core.task_manager')
    local last, times = nil, {}
    ok(h.run_until(function() return h.place == h.P.uc2 end, 120, function()
        local name = manager.get_current_task().name
        if last ~= nil and name ~= last and (name == 'portal' or last == 'portal') then times[#times + 1] = h.now end
        last = name
    end), 'floor 2 reached\n' .. h.tail(30))
    local worst = 0
    for i = 1, #times do
        local n = 0
        for j = i, #times do if times[j] - times[i] <= 15 then n = n + 1 end end
        if n > worst then worst = n end
    end
    ok(worst < 5, 'portal <-> other task switches in any 15 s: ' .. worst .. ' (was 104)')
    eq(#h.errors, 0, 'no host errors')
end)

case('W2 a floor exit without a switch in view keeps the pad as the way down (open-exit floors unchanged)', function()
    local h = J.new({dirs = {'Batmobile', 'WonderCity'}, place = 'undercity'})
    h.actor('undercity', 'X1_Undercity_WarpPad', 12, 0)
    h.mod('WonderCity', 'gui').elements.main_toggle:set(true)
    local portal_task = h.mod('WonderCity', 'tasks.portal')
    h.run(0.5)
    eq(h.as('WonderCity', function() return portal_task.shouldExecute() end), true, 'the pad drives the portal task')
end)

if #failures > 0 then error(#failures .. ' WonderCity beacon exit case(s) failed:\n' .. table.concat(failures, '\n')) end
print('WonderCity beacon exit: ' .. checks .. ' checks')
