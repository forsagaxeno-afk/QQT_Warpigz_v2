-- QQT_Warpigz_v3: the Farm-mode Smart farm flow in the joint host (REAL
-- HelltideRevamped + Batmobile + Rosie, WarPigs off) on the Dry Steppes
-- patrol loop (waypoints/jirandai.lua).
-- User report: "the bot ran around near a chest for a couple of minutes
-- killing ordinary mobs — first search tears, then looting". Two causes:
--   * 'Farm Cinder Threshold' (Settings) also ran in Farm mode: within that
--     many cinders of a remembered chest the bot entered FARM_CHEST_CINDERS
--     and roamed a 22 m ring round the chest killing monsters with no time
--     bound, polling tears only within the pass-by distance (50 m): a tear
--     86 m away that showed up meanwhile waited ~90 s. Now Warplan only;
--   * the monster fight (KILL_MONSTERS) had no bound: a stream of plain
--     monsters within 50 m (Helltide spawns keep coming, here round a chest)
--     parked the bot in one spot for the whole run, so a tear beyond the
--     search distance was never found. Farm now moves on along the road after
--     25 s in one spot (plain monsters skipped until 50 m away, <= 45 s).
-- Plus the whole flow with the new default goal ("Farm cinders until" 2000):
-- tears while below the goal, no chest opened below it, the chest run at
-- the goal (Mystery first), tears again after it, the last minutes
-- spend the rest; and the menu layout (one "Smart farm" section).
-- Runs under Lua 5.4 and LuaJIT.
SUITE_ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(SUITE_ROOT .. '/audit/tests/joint_host.lua')
local H = dofile(SUITE_ROOT .. '/audit/tests/hr_smart_harness.lua')
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
        print('PASS Helltide smart farm flow: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Helltide smart farm flow: ' .. name .. ': ' .. tostring(err))
    end
end

local HR = 'HelltideRevamped'
local MYSTERY, GLOVES = 'usz_rewardGizmo_Uber', 'usz_rewardGizmo_Gloves'
local RIFT = {MOVING_TO_RIFT = true, RIFT_KILL_GUARDS = true, RIFT_WAIT_OPEN = true, RIFT_CLOSE_TEARS = true,
    RIFT_STAY_ACTIVE = true, RIFT_OPEN_CHEST = true, RIFT_WAIT_REALMWALKER = true, RIFT_KILL_REALMWALKER = true}

local PTS
local function loop_points()
    if PTS then return PTS end
    local f = assert(io.open(SUITE_ROOT .. '/HelltideRevamped/waypoints/jirandai.lua', 'r'))
    local text = f:read('*a'); f:close()
    PTS = {}
    for x, y in text:gmatch('vec3:new%(%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*,%s*[%-%d%.]+%s*%)') do
        PTS[#PTS + 1] = {tonumber(x), tonumber(y)}
    end
    return PTS
end

local function chest(h, skin, x, y)
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
        h.opened[#h.opened + 1] = {skin = skin, t = h.now, cinders = h.cinders + c.cost}
    end
    return c
end

-- Plain monsters round (x, y): each kill pays `pay` cinders and another one
-- spawns 3 s later (a Helltide keeps spawning).
local function mob_stream(h, x, y, n, pay)
    local function mob(i)
        local ang = i * 2.1
        local m = h.actor('step', 'Trash_' .. i, x + math.cos(ang) * 15, y + math.sin(ang) * 15, {enemy = true, health = 100})
        m.on_death = function(hh)
            hh.cinders = hh.cinders + (pay or 2)
            hh.at(3, function() mob(i + n) end)
        end
    end
    for i = 1, n do mob(i) end
end

local function tear(h, x, y)
    h.actor('step', 'S14_Rupture_SMP_SwitchGizmo', x, y)
    h.actor('step', 'S14_PandemoniumCrack_gizmo_holdArea', x, y)
end

local function helltide(opts)
    local h = J.new({rosie = true, dirs = {'Batmobile', HR}, place = 'step', minute = opts.minute or 5})
    h.mod(HR, 'core.hr_clock')._now = function() return 1790481600 + h.minute * 60 + math.floor(h.now) % 60 end
    local pts = loop_points()
    h.P.step.box = {-1300, -150, -900, -150}
    h.P.step.spawn = h.v(pts[1][1], pts[1][2])
    h.P.step.helltide = true
    h.pos = h.P.step.spawn
    h.cinders = opts.cinders or 0
    h.assert_clean('load')
    local e = h.mod(HR, 'gui').elements
    e.mode:set(1)
    if opts.goal ~= nil then e.farm_goal:set(opts.goal) end
    if opts.goal_at then e.cinder_run_at:set(opts.goal_at) end
    if opts.threshold then e.farm_cinder_threshold:set(opts.threshold) end
    return h, e, h.mod(HR, 'tasks.helltide'), pts
end

case('Farm, Farm Cinder Threshold 100 (goal off): no chest farming, a tear that shows up 86 m away is taken at once', function()
    local h, e, task, pts = helltide({cinders = 180, goal = false, threshold = 100})
    local cx, cy = pts[3][1] + 10, pts[3][2] + 10
    chest(h, MYSTERY, cx, cy)                                  -- 70 short: inside the threshold
    mob_stream(h, cx, cy, 4, 2)
    local tp = pts[25]
    h.at(20, function() tear(h, tp[1], tp[2]) end)
    e.main_toggle:set(true)
    local t0, farmed, rift_at = h.now, 0, nil
    h.run_until(function() return rift_at ~= nil end, 60, function(hh)
        if task.current_state == 'FARM_CHEST_CINDERS' then farmed = farmed + 1 end
        if RIFT[task.current_state] and not rift_at then rift_at = hh.now - t0 end
    end)
    h.assert_clean('threshold')
    eq(farmed, 0, 'never parked at the chest (FARM_CHEST_CINDERS ticks)')
    eq(h.logged('[FARM CHEST]'), 0, 'no "[FARM CHEST] ... staying to farm"')
    ok(rift_at and rift_at <= 26, 'the tear that showed up at 20 s engaged by 26 s (got ' .. tostring(rift_at) .. ')\n' .. h.tail(30))
end)

case('Warplan keeps Farm Cinder Threshold (unchanged)', function()
    local h, e, task, pts = helltide({cinders = 180, threshold = 100})
    e.mode:set(0)
    local cx, cy = pts[3][1] + 10, pts[3][2] + 10
    chest(h, MYSTERY, cx, cy)
    mob_stream(h, cx, cy, 4, 2)
    e.main_toggle:set(true)
    ok(h.run_until(function() return task.current_state == 'FARM_CHEST_CINDERS' end, 20),
        'Warplan farms near the almost affordable chest as before\n' .. h.tail(20))
    h.assert_clean('warplan threshold')
end)

case('Farm (defaults): a stream of plain monsters at a chest does not park the bot; it walks on and finds a far tear', function()
    local h, e, task, pts = helltide({cinders = 180})
    eq(e.farm_goal:get(), true, 'the goal is on by default')
    eq(e.cinder_run_at:get(), 2000, 'goal default 2000')
    local cx, cy = pts[3][1] + 10, pts[3][2] + 10
    chest(h, MYSTERY, cx, cy)
    mob_stream(h, cx, cy, 4, 2)
    -- Tears beyond the search distance (110 m) both ways along the loop.
    tear(h, pts[120][1], pts[120][2])
    tear(h, pts[1578][1], pts[1578][2])
    e.main_toggle:set(true)
    local t0, km_run, km_max, rift_at = h.now, 0, 0, nil
    h.run_until(function() return rift_at ~= nil end, 300, function(hh)
        if task.current_state == 'KILL_MONSTERS' then
            km_run = km_run + 0.1
            if km_run > km_max then km_max = km_run end
        else
            km_run = 0
        end
        if RIFT[task.current_state] and not rift_at then rift_at = hh.now - t0 end
    end)
    h.assert_clean('stream')
    -- Before: one KILL_MONSTERS stretch for the whole run (240 s+).
    ok(km_max <= 45, string.format('never parked in one fight (longest KILL_MONSTERS stretch: %.0f s)', km_max))
    ok(rift_at ~= nil, 'walked on and found a tear beyond the search distance\n' .. h.tail(30))
    ok(h.logged('moving on along the patrol road') >= 1, 'the move-on is logged')
    eq(h.opened, nil, 'no chest opened below the goal')
end)

case('Farm flow: tears below the goal, no chest before it, the run at the goal (Mystery first), then tears again', function()
    local h, e, task, pts = helltide({cinders = 1700, goal_at = 2000})
    local mystery = chest(h, MYSTERY, pts[30][1] + 8, pts[30][2] + 8)
    local glove = chest(h, GLOVES, pts[12][1] + 6, pts[12][2] - 6)
    -- The tear pays 400 cinders once engaged (its event).
    tear(h, pts[60][1], pts[60][2])
    e.main_toggle:set(true)
    local paid, opened_below, rift_seen = false, 0, false
    local done = h.run_until(function() return mystery.interactable == false and glove.interactable == false end, 420,
        function(hh)
            if RIFT[task.current_state] then
                rift_seen = true
                if not paid then paid = true; hh.cinders = hh.cinders + 400 end
            end
            if hh.opened and not paid then opened_below = #hh.opened end
        end)
    h.assert_clean('flow')
    ok(rift_seen, 'the tear was farmed first\n' .. h.tail(30))
    eq(opened_below, 0, 'no chest opened below the goal')
    ok(done, 'both chests opened after the goal: ' .. tostring(h.opened and #h.opened) .. '\n' .. h.tail(40))
    eq(h.opened[1].skin, MYSTERY, 'the Mystery first')
    ok(h.opened[1].cinders >= 2000, 'the run started at the goal (' .. h.opened[1].cinders .. ')')
    ok(h.logged('[CINDER RUN] 2100 cinders >= 2000') >= 1 or h.logged('>= 2000') >= 1, 'run start logged\n' .. h.tail(30))
    -- Nothing left to spend on: the next tear is hunted again (the run holds
    -- the rest for the next chest found; it ends below the cheapest chest).
    local p = h.pos
    tear(h, p:x() + 60, p:y())
    local t1 = h.now
    ok(h.run_until(function() return RIFT[task.current_state] == true end, 40),
        'after the run the next tear is hunted again\n' .. h.tail(30))
    ok(h.now - t1 <= 15, string.format('at once (%.0f s)', h.now - t1))
    h.assert_clean('after the run')
end)

case('Farm flow: the last minutes spend what is held below the goal', function()
    local h, e, task, pts = helltide({cinders = 600, goal_at = 2000, minute = 56})
    local mystery = chest(h, MYSTERY, pts[20][1] + 6, pts[20][2] + 6)
    e.main_toggle:set(true)
    ok(h.run_until(function() return mystery.interactable == false end, 120), 'the Mystery opened in the last minutes\n' .. h.tail(30))
    h.assert_clean('dump')
    eq(h.cinders, 350)
end)

-- The menu (hr_smart_harness: the real gui.lua with recording widgets).
local function menu_labels(mode, external)
    local s = H.new({})
    s.set('mode', mode)
    if external then s.tracker.hr_external = true end
    local labels, headers = {}, {}
    s.env.render_menu_header = function(text) headers[#headers + 1] = text; labels[#labels + 1] = '# ' .. text end
    for _, el in pairs(s.gui.elements) do
        el.render = function(_, label) labels[#labels + 1] = label end
        el.push = function(_, label) labels[#labels + 1] = '> ' .. tostring(label); return true end
    end
    s.gui.render()
    return labels, s
end
local function index_of(list, label)
    for i, l in ipairs(list) do if l == label then return i end end
    return nil
end

case('menu: Farm mode has ONE "Smart farm" section in flow order, tuning under Advanced', function()
    local L = menu_labels(1)
    local want = {'> Smart farm', '# 1. Goal: farm cinders, then open chests', 'Farm cinders until', '  Cinders',
        '  Spend all in the last (min)', '# 2. How to farm: tears first', 'Hunt tears', '  Stand on chargeable tears',
        '  Fight Realmwalker', '  Open tear chests', '  Skip legacy Helltide events', '# 3. Movement and logic',
        'Smart chest order', 'Road routing', 'Learn while farming', 'Stay inside the Helltide',
        'Pin the target on the map', 'Forget learned data (this zone)', '> Advanced', 'Tear search distance',
        'Pass-by distance', 'Ritual stay radius', 'Hold-area tolerance', 'Linger after last tear',
        'Realmwalker wait (sec)', 'Pause tears at cinders', 'Max carry above reserve', 'Event radius (m)',
        'Events until minute (UTC)', '> Settings'}
    local last = 0
    for _, w in ipairs(want) do
        local i = index_of(L, w)
        ok(i ~= nil, 'menu entry ' .. w .. ' missing:\n' .. table.concat(L, '\n'))
        ok(i > last, 'menu entry ' .. w .. ' out of order:\n' .. table.concat(L, '\n'))
        last = i
    end
    for _, gone in ipairs({'> Tears (Farm mode)', '> Smart farm (Farm mode)', 'Spend cinders on chests at',
        'Farm Cinder Threshold (beta)', 'Keep 250 for a Mystery chest', 'Cinder plan'}) do
        eq(index_of(L, gone), nil, gone .. ' is not in the Farm menu')
    end
end)

case('menu: goal off shows the 250 reserve rule; Warplan / WarPigs keep their options', function()
    local s = H.new({})
    s.set('mode', 1); s.set('farm_goal', false)
    local labels = {}
    for _, el in pairs(s.gui.elements) do
        el.render = function(_, label) labels[#labels + 1] = label end
    end
    s.gui.render()
    ok(index_of(labels, 'Keep 250 for a Mystery chest'), 'the reserve rule with the goal off')
    eq(index_of(labels, '  Cinders'), nil, 'no goal amount with the goal off')
    local W = menu_labels(0)
    ok(index_of(W, 'Spend cinders on chests at'), 'Warplan: the cinder run option in Settings')
    ok(index_of(W, 'Farm Cinder Threshold (beta)'), 'Warplan: Farm Cinder Threshold kept')
    ok(index_of(W, 'Learn while farming'), 'Warplan: learning is still reachable')
    eq(index_of(W, '> Smart farm'), nil, 'no Smart farm section in Warplan')
    local X = menu_labels(1, true)
    ok(index_of(X, 'Spend cinders on chests at'), 'WarPigs (external, combo on Farm): the Warplan option shows')
    eq(index_of(X, '> Smart farm'), nil, 'WarPigs: no Smart farm section')
end)

case('settings: the goal and its amount sync; the run follows the effective mode', function()
    local s = H.new({})
    s.set('mode', 1)
    eq(s.settings.farm_goal, true); eq(s.settings.cinder_run_at, 2000); eq(s.settings.cinder_run, false)
    ok(s.settings.set_setting('farm_goal', false), 'set_setting farm_goal')
    eq(s.gui.elements.farm_goal:get(), false)
    local run = s.require('core.hr_cinder_run')
    eq(run.on(), false, 'Farm: the goal decides (off)')
    s.set('farm_goal', true)
    eq(run.on(), true, 'Farm: the goal decides (on)')
    s.set('mode', 0)
    eq(run.on(), false, 'Warplan: "Spend cinders on chests at" decides (off)')
    s.set('cinder_run', true)
    eq(run.on(), true)
    s.set('mode', 1); s.tracker.hr_external = true
    eq(run.on(), true, 'WarPigs: the Warplan option')
    s.set('cinder_run', false)
    eq(run.on(), false, 'WarPigs: the Farm goal is not used')
end)

-- r32 review: "Spend all in the last (min)" (settings.dump_min) ends the
-- save phase of the Warplan cinder run (core/hr_cinder_run.lua
-- dump_minutes). 3.1.1 showed it in the Smart farm tree in every mode; the
-- reorganized menu showed it in Farm only, so Warplan could no longer set it.
case('menu: Warplan keeps "Spend all in the last (min)" under the cinder run option', function()
    local W = menu_labels(0)
    eq(index_of(W, '  Spend all in the last (min)'), nil, 'hidden while the option is off')
    local s = H.new({})
    s.set('mode', 0); s.set('cinder_run', true)
    local labels = {}
    for _, el in pairs(s.gui.elements) do
        el.render = function(_, label) labels[#labels + 1] = label end
    end
    s.gui.render()
    local i, j = index_of(labels, 'Spend cinders on chests at'), index_of(labels, '  Spend all in the last (min)')
    ok(i and j and j > i, 'Warplan: the last-minutes slider under the option:\n' .. table.concat(labels, '\n'))
    ok(index_of(labels, '  Cinders') ~= nil)
    local run = s.require('core.hr_cinder_run')
    s.set('dump_min', 8)
    eq(run.dump_minutes(), 8, 'the slider drives the Warplan run')
end)

print(string.format('Helltide smart farm flow: %d cases, %d checks, %d failures', cases, checks, #failures))
if #failures > 0 then error('Helltide smart farm flow failures:\n' .. table.concat(failures, '\n')) end
print('PASS: test_helltide_smart_farm_flow (' .. cases .. ' cases)')
