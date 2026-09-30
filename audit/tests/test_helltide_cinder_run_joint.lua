-- QQT_Warpigz_v3 (Q4): the cinder run ("Spend cinders on chests at") in the
-- joint host with the REAL HelltideRevamped, Batmobile and Rosie on the Dry
-- Steppes patrol loop (waypoints/jirandai.lua):
--   * standalone Farm (no WarPigs): 1200 cinders, run at 1000: Hell's Prize
--     (666) first, then the Mystery (250), then the regular chests;
--   * Warplan through an external enable (what WarPigs calls): the same
--     order instead of nearest-affordable;
--   * option off: the Hell's Prize is left alone;
--   * review repair: from 0 cinders with farming income the bot saves up to
--     the threshold (no chest opened below it, the chests are remembered),
--     then opens the Hell's Prize first (before: it spent as it went, never
--     got near the threshold, and never opened the Hell's Prize).
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
        print('PASS Helltide cinder run (joint): ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Helltide cinder run (joint): ' .. name .. ': ' .. tostring(err))
    end
end

local HR = 'HelltideRevamped'
local PRIZE, MYSTERY = 'Warplan_Helltide_HellsPrize', 'usz_rewardGizmo_Uber'
local GLOVES, RINGS = 'usz_rewardGizmo_Gloves', 'usz_rewardGizmo_Rings'

local function loop_points()
    local f = assert(io.open(SUITE_ROOT .. '/HelltideRevamped/waypoints/jirandai.lua', 'r'))
    local text = f:read('*a'); f:close()
    local pts = {}
    for x, y in text:gmatch('vec3:new%(%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*,%s*[%-%d%.]+%s*%)') do
        pts[#pts + 1] = {tonumber(x), tonumber(y)}
    end
    return pts
end

-- A chest `side` metres to the left of loop point i; opening pays its cost.
local function chest(h, pts, skin, i, side, cost)
    local a, b = pts[i], pts[i + 1]
    local dx, dy = b[1] - a[1], b[2] - a[2]
    local len = math.sqrt(dx * dx + dy * dy)
    local c = h.actor('step', skin, a[1] - dy / len * side, a[2] + dx / len * side)
    function c:x() return self.pos:x() end
    function c:y() return self.pos:y() end
    function c:z() return self.pos:z() end
    function c:dist_to(o) return self.pos:dist_to(o) end
    c.cost = cost or h.mod(HR, 'data.enums').chest_types[skin]
    c.on_interact = function()
        if c.interactable == false or h.cinders < c.cost then return end
        h.cinders = h.cinders - c.cost
        c.interactable = false
        h.opened = h.opened or {}
        h.opened[#h.opened + 1] = {skin = skin, t = h.now}
    end
    return c
end

local function helltide(opts)
    local h = J.new({rosie = false, dirs = {'Batmobile', HR}, place = 'step', minute = 5})
    h.mod(HR, 'core.hr_clock')._now = function() return 1790481600 + h.minute * 60 + math.floor(h.now) % 60 end
    local pts = loop_points()
    h.P.step.box = {-1300, -150, -900, -150}
    h.P.step.spawn = h.v(pts[1][1], pts[1][2])
    h.P.step.helltide = true
    h.pos = h.P.step.spawn
    h.cinders = opts.cinders
    h.assert_clean('load')
    local e = h.mod(HR, 'gui').elements
    e.mode:set(opts.mode or 1)
    -- QQT_Warpigz_v3: Farm: the Smart farm goal (on by default) is the run's
    -- option; Warplan / WarPigs: "Spend cinders on chests at".
    e.farm_goal:set(opts.run ~= nil)
    if opts.run then
        e.cinder_run:set(true)
        e.cinder_run_at:set(opts.run)
    end
    h.chests = {
        prize = chest(h, pts, PRIZE, 30, 12),           -- ~110 m along the loop
        mystery = chest(h, pts, MYSTERY, 70, 12),       -- farther: Farm without the run takes it first
        glove = chest(h, pts, GLOVES, #pts - 30, 25),   -- behind the start
        ring = chest(h, pts, RINGS, 110, -25),
    }
    return h, e
end

local function order_of(h)
    local out = {}
    for _, o in ipairs(h.opened or {}) do out[#out + 1] = o.skin end
    return table.concat(out, ' > ')
end

case('standalone Farm: Hell\'s Prize first, then the Mystery, then the regular chests', function()
    local h, e = helltide({cinders = 1200, run = 1000})
    e.main_toggle:set(true)
    local done = h.run_until(function() return #(h.opened or {}) >= 4 end, 600)
    h.run(8)
    h.assert_clean('run')
    ok(done, 'four chests opened: ' .. order_of(h) .. '\n' .. h.tail(40))
    eq(h.opened[1].skin, PRIZE, 'the Hell\'s Prize first: ' .. order_of(h))
    eq(h.opened[2].skin, MYSTERY, 'then the Mystery: ' .. order_of(h))
    eq(h.cinders, 1200 - 666 - 250 - 75 - 75)
    eq(h.logged('[CINDER RUN] 1200 cinders >= 1000'), 1, 'run start logged once\n' .. h.tail(30))
end)

case('Warplan (external enable, as WarPigs does): the run order, not nearest-first', function()
    local h = helltide({cinders = 1200, run = 1000, mode = 1})
    h.as(HR, function() h.G.HelltideRevampedPlugin.enable() end)
    eq(h.mod(HR, 'core.hr_mode').effective(), 'warplan')
    local done = h.run_until(function() return #(h.opened or {}) >= 2 end, 600)
    h.assert_clean('warplan run')
    ok(done, 'two chests opened: ' .. order_of(h) .. '\n' .. h.tail(40))
    eq(h.opened[1].skin, PRIZE, 'the Hell\'s Prize first: ' .. order_of(h))
    eq(h.opened[2].skin, MYSTERY, 'then the Mystery: ' .. order_of(h))
end)

case('option off: the Hell\'s Prize is left alone (Farm)', function()
    local h, e = helltide({cinders = 1200})
    e.main_toggle:set(true)
    h.run_until(function() return #(h.opened or {}) >= 3 end, 600)
    h.run(30)
    h.assert_clean('off')
    for _, o in ipairs(h.opened or {}) do ok(o.skin ~= PRIZE, 'Hell\'s Prize opened without the run: ' .. order_of(h)) end
    eq(h.chests.prize.interactable ~= false, true)
    eq(h.logged('[CINDER RUN]'), 0)
end)

case('standalone Farm from 0 cinders: saves up to the threshold, then the Hell\'s Prize first', function()
    local h, e = helltide({cinders = 0, run = 1000})
    e.main_toggle:set(true)
    local acc, peak_before = 0, 0
    local function index_of(skin)
        for i, o in ipairs(h.opened or {}) do if o.skin == skin then return i end end
        return nil
    end
    local done = h.run_until(function() return index_of(PRIZE) ~= nil and index_of(MYSTERY) ~= nil end, 900,
        function(hh)
            acc = acc + 0.1 * 4                     -- farming income: 4 cinders / s
            if acc >= 1 then hh.cinders = hh.cinders + math.floor(acc); acc = acc - math.floor(acc) end
            if not hh.opened and hh.cinders > peak_before then peak_before = hh.cinders end
        end)
    h.assert_clean('saving')
    ok(done, 'Hell\'s Prize and Mystery opened: ' .. order_of(h) .. '\n' .. h.tail(40))
    ok(peak_before >= 1000, 'saved up to the threshold before the first chest (peak ' .. peak_before .. ')')
    local pi = index_of(PRIZE)
    -- QQT_Warpigz_v3: only chests on the way may come first (the run's target
    -- stays affordable after each). The walk to the Hell's Prize can pass
    -- both the Rings and the Mystery (a slower Batmobile path under CPU load:
    -- the old "at most one before it" check failed there, at 3.1.1 too).
    for i = 1, pi - 1 do
        ok(h.logged('On the way: ' .. h.opened[i].skin) >= 1,
            'only chests on the way before the Hell\'s Prize: ' .. order_of(h) .. '\n' .. h.tail(40))
    end
    ok(pi < index_of(MYSTERY) or h.logged('On the way: ' .. MYSTERY) >= 1,
        'the Hell\'s Prize first, then the Mystery: ' .. order_of(h))
    eq(h.logged('[CINDER RUN] Saving cinders for the run at 1000'), 1, 'the save phase logged once\n' .. h.tail(30))
    eq(h.logged('>= 1000'), 1, 'the run start logged once')
end)

print(string.format('Helltide cinder run (joint): %d cases, %d checks, %d failures', cases, checks, #failures))
if #failures > 0 then error('Helltide cinder run (joint) failures:\n' .. table.concat(failures, '\n')) end
print('PASS: test_helltide_cinder_run_joint (' .. cases .. ' cases)')
