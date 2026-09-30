-- QQT_Warpigz_v3: a simulated Farm-mode Helltide with the REAL
-- HelltideRevamped, Batmobile and Rosie in the joint host (no WarPigs: plain
-- farming by a user who enabled only these plugins). The Dry Steppes patrol
-- loop (waypoints/jirandai.lua) is the road; a Mystery chest 170 m along it
-- and two regular chests elsewhere; 400 cinders.
--   * the Mystery chest is opened before any regular chest (the Smart farm
--     goal, here 400, reached: the chest run's order; QQT_Warpigz_v3) and
--     every chest is opened once (no recall ping-pong);
--   * the overlay renders with no undefined host global;
--   * at minute 55 the all-time stats and the learned zone file are written
--     by HelltideRevamped (in the host's in-memory files).
-- Runs under Lua 5.4 and LuaJIT.
SUITE_ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(SUITE_ROOT .. '/audit/tests/joint_host.lua')
local checks, cases, failures = 0, 0, {}
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
    cases = cases + 1
    local passed, err = xpcall(fn, debug.traceback)
    if passed then
        print('PASS Helltide standalone smart farm: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Helltide standalone smart farm: ' .. name .. ': ' .. tostring(err))
    end
end

local HR = 'HelltideRevamped'
local MYSTERY, GLOVES, RINGS = 'usz_rewardGizmo_Uber', 'usz_rewardGizmo_Gloves', 'usz_rewardGizmo_Rings'

local function loop_points()
    local f = assert(io.open(SUITE_ROOT .. '/HelltideRevamped/waypoints/jirandai.lua', 'r'))
    local text = f:read('*a'); f:close()
    local pts = {}
    for x, y in text:gmatch('vec3:new%(%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*,%s*[%-%d%.]+%s*%)') do
        pts[#pts + 1] = {tonumber(x), tonumber(y)}
    end
    return pts
end

-- A chest `side` metres to the left of loop point i (a real actor: chests
-- answer the vector accessors because navigate_to treats tables as points).
local function chest(h, pts, skin, i, side)
    local a, b = pts[i], pts[i + 1]
    local dx, dy = b[1] - a[1], b[2] - a[2]
    local len = math.sqrt(dx * dx + dy * dy)
    local x, y = a[1] - dy / len * side, a[2] + dx / len * side
    local c = h.actor('step', skin, x, y)
    function c:x() return self.pos:x() end
    function c:y() return self.pos:y() end
    function c:z() return self.pos:z() end
    function c:dist_to(o) return self.pos:dist_to(o) end
    c.cost = h.mod(HR, 'data.enums').chest_types[skin]
    c.on_interact = function()
        if c.interactable == false or h.cinders < c.cost then return end
        h.cinders = h.cinders - c.cost
        c.interactable = false
        h.opened = h.opened or {}
        h.opened[#h.opened + 1] = {skin = skin, t = h.now}
    end
    return c
end

case('a Farm Helltide: Mystery first, no ping-pong, overlay, stats and learned data saved', function()
    local h = J.new({rosie = true, dirs = {'Batmobile', HR}, place = 'step', minute = 5})
    -- The Helltide hour is pinned (a real hour boundary during the run would
    -- close the Helltide record early); the minute is the host's h.minute.
    h.mod(HR, 'core.hr_clock')._now = function() return 1790481600 + h.minute * 60 + math.floor(h.now) % 60 end
    local pts = loop_points()
    ok(#pts > 1000, 'the Dry Steppes loop')
    -- The Dry Steppes as a walkable area around its patrol loop.
    h.P.step.box = {-1300, -150, -900, -150}
    h.P.step.spawn = h.v(pts[1][1], pts[1][2])
    h.P.step.helltide = true
    h.pos = h.P.step.spawn
    h.cinders = 400
    h.assert_clean('load')
    local mystery = chest(h, pts, MYSTERY, 44, 12)        -- ~170 m along the loop
    local glove = chest(h, pts, GLOVES, 110, -25)
    local ring = chest(h, pts, RINGS, #pts - 30, 25)      -- behind the start
    -- QQT_Warpigz_v3: the Smart farm goal (on by default) is reached: 400.
    h.mod(HR, 'gui').elements.cinder_run_at:set(400)
    h.mod(HR, 'gui').elements.main_toggle:set(true)

    local order = h.mod(HR, 'core.hr_chest_order')
    local targets, last = {}, nil
    local done = h.run_until(function()
        local key = order.last_plan and order.last_plan.target_key
        if key and key ~= last then targets[#targets + 1] = key; last = key end
        return #(h.opened or {}) >= 3
    end, 420)
    h.run(8) -- the last open is confirmed after the loot hold
    h.assert_clean('farm')
    ok(done, 'all three chests opened\n' .. h.tail(40))
    eq(h.opened[1].skin, MYSTERY, 'the Mystery chest first')
    eq(h.cinders, 0, '250 + 75 + 75 spent')
    -- No ping-pong: every target is chosen once and kept until it is opened.
    local seen = {}
    for _, key in ipairs(targets) do
        ok(not seen[key], 'target chosen again after another one: ' .. table.concat(targets, ' > '))
        seen[key] = true
    end
    ok(#targets <= 3, 'three chests, three targets: ' .. #targets)
    eq(h.logged('[CHEST ORDER] Switching'), 0, 'no target switch')
    ok(h.logged('road') >= 1, 'the Mystery was reached along the patrol road\n' .. h.tail(30))

    -- Overlay drawn, nothing undefined read.
    ok((h.graphics_used.text_2d or 0) > 0 and (h.graphics_used.rect_filled or 0) > 0, 'overlay drawn')
    for name in pairs(h.missing) do
        ok(J.EXPORTS[name] ~= nil or J.ROSIE_EXPORTS[name] ~= nil, 'undefined global read: ' .. name)
    end
    local stats = h.mod(HR, 'core.hr_stats')
    eq(stats.helltide.chests, 3); eq(stats.helltide.mystery, 1); eq(stats.helltide.spent, 400)
    eq(h.as(HR, function() return h.G.HelltideRevampedPlugin.status().stats.spent end), 400, 'status().stats')

    -- Minute 55: the Helltide ends; HelltideRevamped saves what it learned.
    h.minute = 55
    h.run(20)
    h.assert_clean('end of the Helltide')
    local wrote = {}
    for _, w in ipairs(h.file_writes) do
        eq(w.owner, HR, 'written by HelltideRevamped: ' .. w.path)
        wrote[w.path:match('[/\\](learned[/\\].+)$') or w.path:match('[^/\\]+$')] = w.path
    end
    local stats_path = wrote['learned/stats.txt'] or wrote['learned\\stats.txt']
    ok(stats_path ~= nil, 'all-time stats written')
    local text = h.mem_files[stats_path]
    ok(text:find('mystery=1', 1, true) and text:find('chests=3', 1, true) and text:find('spent=400', 1, true),
        'all-time totals:\n' .. text)
    ok(text:find('\nh|%d+|Step_South|') ~= nil, 'the Helltide record')
    local zone_path = wrote['learned/Step_South.txt'] or wrote['learned\\Step_South.txt']
    ok(zone_path ~= nil, 'learned zone file written')
    local zone = h.mem_files[zone_path]
    ok(zone:find('v1|spot|mystery|usz_rewardGizmo_Uber|250|', 1, true), 'the Mystery spot is learned:\n' .. zone)
    ok(zone:find('\nin|', 1, true), 'the Helltide area is learned')
    eq(wrote['dashboard/hr_data.js'], nil, 'the web dashboard is off by default')
end)

print(string.format('Helltide standalone smart farm: %d cases, %d checks, %d failures', cases, checks, #failures))
if #failures > 0 then error('Helltide standalone smart farm failures:\n' .. table.concat(failures, '\n')) end
print('PASS: test_helltide_standalone_smart (' .. cases .. ' cases)')
