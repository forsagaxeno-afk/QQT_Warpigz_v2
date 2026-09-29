-- QQT_Warpigz_v3 Rosie 1.0.27 (contract C-boss, scenario sweep 2026-09-28
-- §2.4; BOARD MED post-3.3.3): Rosie's automatic trip started 0.5 s after the
-- bag filled next to a live Pit / Undercity boss (a Town Portal cast in melee,
-- glyph chances lost). The activity boss defers only gated the activity's own
-- request. 1.0.27: before an automatic trip Rosie reads `boss_fight` from
-- WonderCityPlugin / ArkhamAsylumPlugin get_status() and ReaperPlugin status()
-- and waits while one reports a live boss fight, at most 90 s (logged once
-- each). Manual and keybind trips and farm-plugin requests are unaffected.
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
    if passed then print('PASS boss fight defer: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL boss fight defer: ' .. name .. ': ' .. tostring(err)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function st(h) return h.as(CONSUMER, function() return h.G.AlfredTheButlerPlugin.get_status() end) end
local function new(global, fn)
    local h = J.new({rosie = true, dirs = {}, place = 'undercity'})
    h.assert_clean('load')
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true)
    h.frame()
    local boss = {live = true}
    local api = {}
    api[fn] = function() return {enabled = true, boss_fight = boss.live} end
    h.G[global] = api
    h.inventory = {}
    for i = 1, 25 do h.inventory[i] = h.gear() end
    return h, boss
end
local function tp_casts(h) return h.logged('[Rosie] Town Portal cast') end

for _, p in ipairs({{'WonderCityPlugin', 'get_status', 'WonderCity'}, {'ArkhamAsylumPlugin', 'get_status', 'ArkhamAsylum'},
    {'ReaperPlugin', 'status', 'Reaper'}}) do
    case('B1 ' .. p[1] .. ': no automatic trip while the boss lives; the trip within 3 s of the kill', function()
        local h, boss = new(p[1], p[2])
        h.run(20)
        eq(st(h).running, false, 'no trip during the boss fight (1.0.26: 0.5 s after the bag filled)\n' .. h.tail(8))
        eq(tp_casts(h), 0, 'no Town Portal cast')
        eq(h.logged('but it waits: ' .. p[3] .. ' is in a live boss fight'), 1, 'the wait is logged once\n' .. h.tail(8))
        boss.live = false
        local t0 = h.now
        ok(h.run_until(function() return st(h).running == true end, 3), 'the trip within 3 s of the kill\n' .. h.tail(8))
        ok(h.now - t0 <= 3)
        h.assert_clean('B1')
    end)
end

case('B2 a boss fight that never ends holds the trip 90 s, then the trip starts with one line', function()
    local h = new('WonderCityPlugin', 'get_status')
    h.run(85)
    eq(st(h).running, false, 'held under 90 s')
    ok(h.run_until(function() return st(h).running == true end, 10), 'the trip after 90 s\n' .. h.tail(8))
    eq(h.logged('reported a live boss fight for 90s'), 1, 'the cap is logged once')
    ok(h.run_until(function() return st(h).outcome == 'completed' end, 200), 'the trip completes\n' .. h.tail(8))
    h.assert_clean('B2')
end)

case('B3 a farm plugin request is not held by the boss field', function()
    local h = new('WonderCityPlugin', 'get_status')
    local done
    eq(h.as(CONSUMER, function()
        return h.G.AlfredTheButlerPlugin.trigger_tasks_with_teleport('Consumer', function(err) done = err or 'ok' end)
    end), true, 'the request is accepted during the boss fight')
    ok(h.run_until(function() return done ~= nil end, 200), 'the requested trip ends')
    eq(done, 'ok')
    h.assert_clean('B3')
end)

case('B4 control: a status without boss_fight (or one that raises) does not hold the automatic trip', function()
    local h = J.new({rosie = true, dirs = {}, place = 'undercity'})
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true)
    h.frame()
    h.G.WonderCityPlugin = {get_status = function() return {enabled = true} end}
    h.G.ReaperPlugin = {status = function() error('status raised') end}
    h.inventory = {}
    for i = 1, 25 do h.inventory[i] = h.gear() end
    ok(h.run_until(function() return st(h).running == true end, 5), 'the trip starts\n' .. h.tail(8))
end)

print(string.format('rosie boss fight defer: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
