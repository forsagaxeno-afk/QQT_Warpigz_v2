-- QQT_Warpigz_v3 (night orchestration): standalone activity lease in the
-- joint host (all real plugins, WarPigs / WarPug / SilentRaven off: plain
-- farming with persisted toggles).
--   A  two leftover activity toggles (Arkham + WonderCity, HordeDev + Arkham)
--      no longer teleport back and forth between their home towns forever:
--      the first one runs, the other holds and says why once; turning the
--      runner off lets the other one start.
--   B  HordeDev's own 'Run pit' hand-off (no compass: HordeDev disables
--      itself, then enables Arkham) is not held by the lease.
--   C  with WarPigs on the lease is not consulted.
-- Before the fix, A logged nothing about the other plugin and both plugins
-- alternated waypoint teleports about every 3 s. Runs under Lua 5.4 and LuaJIT.
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
    if passed then print('PASS activity lease: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err) end
end

local SR_GUI = {SilentRaven = 'silent_raven.gui'}
local function el(h, dir) return assert(h.mod(dir, SR_GUI[dir] or 'gui'), 'gui of ' .. dir).elements end
local function setup(warpigs)
    local h = J.new()
    h.assert_clean('load')
    el(h, 'WarPigs').main_toggle:set(warpigs == true)
    el(h, 'WarPug').main_toggle:set(false)
    el(h, 'SilentRaven').main_toggle:set(false)
    return h
end
local function waypoints_by(h)
    local by = {}
    for _, w in ipairs(h.waypoints) do by[w.context] = (by[w.context] or 0) + 1 end
    return by
end
local function enabled(h, export)
    local api = h.G[export]
    local fn = api.status or api.get_status
    return h.as('WarPigs', function() return fn().enabled end) == true
end

case('A Arkham + WonderCity leftover toggles: one runs, the other holds and says why', function()
    local h = setup(false)
    el(h, 'ArkhamAsylum').main_toggle:set(true)
    el(h, 'WonderCity').main_toggle:set(true)
    h.run(180)
    h.assert_clean('two activities')
    local by = waypoints_by(h)
    local ark, wc = by.ArkhamAsylum or 0, by.WonderCity or 0
    ok(ark == 0 or wc == 0, string.format('only one plugin teleports (Arkham %d, WonderCity %d)', ark, wc))
    eq(h.logged('another activity plugin ('), 1, 'the hold is logged once')
    ok(h.place.zone ~= 'Skov_Temis', 'the running activity left town: ' .. tostring(h.place.zone))
    -- The user turns the runner off: the other one starts.
    local lease = rawget(h.G, 'QQT_Warpigz_activity_lease')
    local runner = ({ArkhamAsylumPlugin = 'ArkhamAsylum', WonderCityPlugin = 'WonderCity'})[lease and lease.owner]
    ok(runner ~= nil, 'the lease names the runner')
    eq(h.logged('another activity plugin (' .. runner .. ')'), 1, 'the hold names the runner')
    local other = runner == 'ArkhamAsylum' and 'WonderCity' or 'ArkhamAsylum'
    el(h, runner).main_toggle:set(false)
    local before = (waypoints_by(h)[other] or 0) + h.count(h.moves, function(m) return m.context == other end)
    ok(h.run_until(function()
        return (waypoints_by(h)[other] or 0) + h.count(h.moves, function(m) return m.context == other end) > before
    end, 60), other .. ' starts once ' .. runner .. ' is off\n' .. h.tail(20))
    eq(h.logged('resuming'), 1, 'resume logged once')
end)

case('A HordeDev + Arkham leftover toggles do not alternate Temis and Caldeum', function()
    local h = setup(false)
    el(h, 'HordeDev').main_toggle:set(true)
    el(h, 'ArkhamAsylum').main_toggle:set(true)
    h.run(180)
    h.assert_clean('horde + pit')
    local by = waypoints_by(h)
    local hd, ark = by.HordeDev or 0, by.ArkhamAsylum or 0
    ok(hd == 0 or ark == 0, string.format('only one plugin teleports (HordeDev %d, Arkham %d)', hd, ark))
    eq(h.logged('another activity plugin ('), 1, 'the hold is logged once')
end)

case('B HordeDev without a compass hands over to the Pit (Run pit) unheld', function()
    local h = setup(false)
    local hd = el(h, 'HordeDev')
    hd.run_pit_toggle:set(true)
    hd.use_alfred:set(false)
    hd.main_toggle:set(true)
    ok(h.run_until(function() return enabled(h, 'ArkhamAsylumPlugin') end, 120),
        'HordeDev enabled Arkham\n' .. h.tail(30))
    eq(enabled(h, 'InfernalHordesPlugin'), false, 'HordeDev disabled itself first')
    ok(h.run_until(function() return h.place.zone == 'PIT_Subzone' end, 120), 'Arkham runs the Pit\n' .. h.tail(30))
    eq(h.logged('another activity plugin ('), 0, 'no lease hold in the hand-off')
    h.assert_clean('run pit')
end)

case('C with WarPigs on the lease is not consulted', function()
    local h = setup(true)
    el(h, 'ArkhamAsylum').main_toggle:set(true)
    el(h, 'WonderCity').main_toggle:set(true)
    h.run(20)
    eq(h.logged('another activity plugin ('), 0, 'WarPigs owns activity hand-offs')
    eq(rawget(h.G, 'QQT_Warpigz_activity_lease'), nil, 'no lease taken under WarPigs')
end)

if #failures > 0 then error(#failures .. ' activity lease regressions failed:\n' .. table.concat(failures, '\n')) end
print('PASS activity lease (joint host): ' .. checks .. ' checks')
