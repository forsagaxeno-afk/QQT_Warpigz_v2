-- Round-5 advisory-flag policy in the joint host (audit/tests/joint_host.lua:
-- all nine real plugins, one shared _G, per-plugin require caches).
--   Policy: while WarPigsPlugin is loaded and status().enabled == true,
--   activity plugins never start an Alfred trip for advisory-only flags
--   (need_trigger / restock without inventory_full or need_repair); WarPigs
--   services them once per Temis visit. Hard needs and standalone behaviour
--   are unchanged.
--   A5-1 WonderCity (probe_wc_sticky_joint.lua): 9e01f67 made two WonderCity
--        advisory trips in Kurast with 'Use teleport' on (1026.4, 1063.0) and
--        off (1036.5, 1073.1) once WarPigs' 20 s alfred_idle grace lapsed.
--   A5-1 Arkham: a Pit plan started from Kurast with 'Use teleport' off made
--        an Arkham advisory trip in Temis (1003.2) on 9e01f67.
--   A5-2 Reaper: a boss plan with 'Use teleport' on made a Reaper advisory
--        trip in Temis right after its enable (1054.9) on 9e01f67; the
--        boss-zone rule covered only the lair.
--   A5-2 HelltideRevamped: guard (no gap; passes on 9e01f67 too).
-- Runs under Lua 5.4 and LuaJIT.
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local checks, failures, cases = 0, {}, 0
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
    cases = cases + 1
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS r5 advisory joint: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL r5 advisory joint: ' .. name .. ': ' .. tostring(err))
    end
end

local WP, PUG, SR = 'WarPigs-1.0.0', 'WarPug-1.0.0', 'SilentRaven-0.1.3'
local ARK, WC, HR, RP = 'ArkhamAsylum-1.0.6', 'WonderCity-main', 'HelltideRevamped-0.4', 'Reaper-main'
local function el(h, dir) return assert(h.mod(dir, dir == SR and 'silent_raven.gui' or 'gui'), dir).elements end
local function setup(opts)
    local h = J.new(opts)
    h.assert_clean('load')
    h.instrument_exports()
    el(h, WP).main_toggle:set(opts.warpigs ~= false)
    el(h, PUG).main_toggle:set(opts.warpigs ~= false)
    el(h, SR).main_toggle:set(opts.warpigs ~= false)
    if opts.teleport then el(h, WP).use_teleport_transition:set(true) end
    if opts.quests then h.set_quests(opts.quests) end
    -- Steroid's sticky restock flag: need_trigger stays true after every cycle.
    h.alfred.need_trigger, h.alfred.sticky_need, h.alfred.restock_count = true, true, 2
    return h
end
local function enabled(h, export)
    local api = h.G[export]
    local fn = api.status or api.get_status
    return h.as(WP, function() return fn() end).enabled == true
end
local function trips(h, dir)
    return h.count(h.alfred.triggers, function(t) return t.context == dir end)
end
local function trip_list(h)
    local out = {}
    for _, t in ipairs(h.alfred.triggers) do
        out[#out + 1] = string.format('%.1f %s %s', t.t, t.context, t.place)
    end
    return table.concat(out, '; ')
end

case('A5-1 WonderCity: sticky restock flag, Undercity plan from Temis: no WonderCity advisory trip (Use teleport on/off)', function()
    for _, tp in ipairs({true, false}) do
        local label = tp and 'Use teleport on' or 'Use teleport off'
        local h = setup({quests = {'WarPlans_QST_Undercity'}, teleport = tp})
        h.warplan_dest = 'kurast'
        ok(h.run_until(function() return enabled(h, 'WonderCityPlugin') end, 60), label .. ': WonderCity enabled\n' .. h.tail())
        ok(h.run_until(function() return h.place == h.P.kurast end, 30), label .. ': reached Kurast\n' .. h.tail())
        h.run(90)   -- past WarPigs' 20 s alfred_idle grace and WonderCity's own 30 s grace, twice
        h.assert_clean(label)
        eq(trips(h, WC), 0, label .. ': WonderCity advisory trips (9e01f67: 2) [' .. trip_list(h) .. ']')
        eq(trips(h, WP), 1, label .. ': WarPigs serviced the flag once in Temis')
        eq(h.count(h.alfred.triggers), 1, label .. ': one Alfred cycle in total')
        ok(h.logged('[WonderCity:alfred] advisory Alfred restock skipped: WarPigs is enabled') >= 1,
            label .. ': the skip is logged')
        ok(h.logged('[WonderCity:alfred] advisory Alfred restock skipped') <= 3, label .. ': rate-limited to once a minute')
        ok(enabled(h, 'WonderCityPlugin'), label .. ': WonderCity still running')
    end
end)

case('A5-1 Arkham: sticky restock flag, Pit plan from Kurast: no Arkham advisory trip in Temis; a full bag still triggers', function()
    for _, tp in ipairs({false, true}) do
        local label = tp and 'Use teleport on' or 'Use teleport off'
        local h = setup({place = 'kurast', quests = {'WarPlans_QST_ThePit'}, teleport = tp})
        ok(h.run_until(function() return enabled(h, 'ArkhamAsylumPlugin') end, 60), label .. ': Arkham enabled\n' .. h.tail())
        ok(h.run_until(function() return h.place == h.P.pit end, 60), label .. ': Arkham entered the pit\n' .. h.tail())
        h.run(20)
        h.assert_clean(label)
        eq(trips(h, ARK), 0, label .. ': Arkham advisory trips (9e01f67: 1 in Temis with Use teleport off) ['
            .. trip_list(h) .. ']')
        ok(trips(h, WP) <= 1, label .. ': at most one WarPigs cycle')
        -- Hard need: the pit filled the bags.
        local before = h.count(h.alfred.triggers)
        h.alfred.inventory_full = true
        ok(h.run_until(function() return trips(h, ARK) == 1 end, 10), label .. ': inventory_full starts the Arkham trip\n' .. h.tail())
        eq(h.count(h.alfred.triggers), before + 1, label .. ': exactly one hard-need trip')
    end
end)

case('A5-2 Reaper: sticky restock flag, boss plan from Temis: no Reaper advisory trip (Use teleport on/off)', function()
    for _, tp in ipairs({true, false}) do
        local label = tp and 'Use teleport on' or 'Use teleport off'
        local h = setup({quests = {'WarPlans_QST_BossLair_Andariel'}, teleport = tp})
        h.setup_lair()
        ok(h.run_until(function() return enabled(h, 'ReaperPlugin') end, 90), label .. ': Reaper enabled\n' .. h.tail())
        ok(h.run_until(function() return h.place == h.P.lair end, 20), label .. ': Reaper reached the lair\n' .. h.tail())
        h.run(10)
        h.assert_clean(label)
        eq(trips(h, RP), 0, label .. ': Reaper advisory trips (9e01f67: 1 in Temis with Use teleport on) ['
            .. trip_list(h) .. ']')
        eq(trips(h, WP), 1, label .. ': WarPigs serviced the flag once in Temis')
    end
end)

case('A5-2 HelltideRevamped guard: sticky restock flag, Helltide plan from Temis: no HR advisory trip', function()
    for _, tp in ipairs({true, false}) do
        local label = tp and 'Use teleport on' or 'Use teleport off'
        local h = setup({quests = {'WarPlans_QST_Helltide_TorturedGifts'}, teleport = tp})
        h.P.helltide.helltide = true
        ok(h.run_until(function() return enabled(h, 'HelltideRevampedPlugin') end, 90), label .. ': HR enabled\n' .. h.tail())
        ok(h.run_until(function() return h.place == h.P.helltide end, 90), label .. ': HR reached the helltide\n' .. h.tail())
        h.run(30)
        h.assert_clean(label)
        eq(trips(h, HR), 0, label .. ': HR advisory trips [' .. trip_list(h) .. ']')
    end
end)

case('A5-1 standalone unchanged: WarPigs off, WonderCity on by hand in Kurast: its advisory trip at the start', function()
    local h = setup({place = 'kurast', warpigs = false})
    el(h, WC).main_toggle:set(true)
    ok(h.run_until(function() return trips(h, WC) >= 1 end, 10), 'standalone WonderCity services the advisory flag\n' .. h.tail())
    h.assert_clean('standalone')
    eq(h.logged('advisory Alfred restock skipped'), 0, 'no skip line without an enabled WarPigs')
end)

print(string.format('r5 advisory joint: %d cases, %d checks, %d failures', cases, checks, #failures))
if #failures > 0 then error(#failures .. ' round-5 advisory joint regressions failed:\n' .. table.concat(failures, '\n\n')) end
print('PASS r5 advisory joint regressions: ' .. checks .. ' checks')
