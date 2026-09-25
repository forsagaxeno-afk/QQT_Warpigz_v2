-- Round-5 HordeDev regressions in the joint host (audit/tests/joint_host.lua:
-- all nine real plugins, one shared _G, per-plugin require caches), turning
-- the round-4 critic/auditor probes into regressions:
--   H5-1 (critic probe_static_stash_loop.lua / probe_door_timing.lua, auditor
--        probe_completion_edges.lua case A): a Stash visible from arrival,
--        the normal door approach (longer than CHEST_WAIT) and a Council fight
--        longer than CHEST_WAIT: the Council is killed, the chests are opened
--        (or, without a chest room, the bounded exit comes only after the
--        boss room is idle), one horde, the turn-in completes.
--   H5-2 (auditor probe_fh2_loading.lua): HordeDev and WarPigs toggles
--        persisted on, 6 s of loading screen (Limbo) at startup, then Temis:
--        HordeDev makes no teleport before WarPigs' first loaded decision.
--   H5-4 (joint J6 NOTE, suite policy): under an enabled WarPigs a sticky
--        advisory restock flag no longer sends HordeDev on its own Alfred trip
--        from the War Plan chest room; the chests are opened and the run
--        completes.
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
    if passed then print('PASS HordeDev round 5 (joint): ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err) end
end

local WP, PUG, SR, HD = 'WarPigs-1.0.0', 'WarPug-1.0.0', 'SilentRaven-0.1.3', 'HordeDev-1.3.9'
local HORDE_Q, LIBRARY_WP, CHEST_WAIT = 'WarPlans_QST_InfernalHordes_BSK', 0x10D63D, 20
local function el(h, dir) return assert(h.mod(dir, dir == SR and 'silent_raven.gui' or 'gui'), dir).elements end
local function setup(opts)
    local h = J.new(opts)
    h.assert_clean('load')
    h.instrument_exports()
    el(h, WP).main_toggle:set(true); el(h, PUG).main_toggle:set(true); el(h, SR).main_toggle:set(true)
    if opts.quests then h.set_quests(opts.quests) end
    return h
end
local function enabled(h, export)
    local api = h.G[export]
    local fn = api.status or api.get_status
    return h.as(WP, function() return fn() end).enabled == true
end
local function log_time(h, text)
    for _, line in ipairs(h.log) do
        if line:find(text, 1, true) then return tonumber(line:match('^(%-?[%d%.]+)')) end
    end
    return nil
end
local function event_time(A, what, run)
    for _, e in ipairs(A.events) do
        if e.what == what and (run == nil or e.run == run) then return e.t end
    end
    return nil
end
local function no_compass(h, label)
    eq(#h.items, 0, label .. ': use_item (Infernal Compass) calls')
    eq(#h.sigil_confirms, 0, label .. ': sigil confirmations')
    eq(h.count(h.waypoints, function(w) return w.sno == LIBRARY_WP end), 0, label .. ': Library teleports')
    eq(h.count(h.waypoints, function(w) return w.context == HD end), 0, label .. ': HordeDev teleports')
end

-- ── H5-1 ─────────────────────────────────────────────────────────────────────
case('H5-1 static Stash from arrival, door approach and Council fight > CHEST_WAIT: one horde, Council killed first', function()
    for _, v in ipairs({
        {'chest room, 75 s Council fight', true, 3000},
        {'chest room, 10 s Council fight', true, 400},
        {'no chest room, 75 s Council fight', false, 3000},
    }) do
        local label, chest_room = 'H5-1 ' .. v[1], v[2]
        local h = setup({place = 'temis', quests = {HORDE_Q}})
        local A = h.setup_horde({boss_health = v[3], chest_room = chest_room, stash = false})
        -- the Stash is part of the arena: visible from each arrival on
        local arrive = h.P.bsk.on_arrive
        h.P.bsk.on_arrive = function(a, trip)
            arrive(a, trip)
            if not (trip and trip.why == 'alfred_return') then h.actor('bsk', 'Stash', -40, -38) end
        end
        h.warplan_dest = 'bsk'
        local left_at
        ok(h.run_until(function()
            if not left_at and h.leaves >= 1 then left_at = h.now end
            return #h.quests == 0 or A.runs >= 3
        end, 900), label .. ': the War Plan quest was turned in\n' .. h.tail())
        h.assert_clean(label)
        eq(A.runs, 1, label .. ': one horde (no loop into new hordes)')
        eq(h.leaves, 1, label .. ': one Leave Dungeon')
        local dead = event_time(A, 'council dead', 1)
        ok(dead, label .. ': the Council was killed\n' .. h.tail())
        ok(left_at > dead, label .. ': left only after the Council died')
        local door, opened = event_time(A, 'locked door', 1), event_time(A, 'door opened', 1)
        ok(door and opened and opened - door > CHEST_WAIT, string.format(
            '%s: the door approach (%.1fs) is longer than CHEST_WAIT', label, (opened or 0) - (door or 0)))
        local fight = dead - event_time(A, 'council pylon', 1)
        if v[3] >= 3000 then ok(fight > CHEST_WAIT, string.format('%s: Council fight %.1fs', label, fight)) end
        if chest_room then
            eq(#A.opened, 3, label .. ': the chests were opened')
            eq(h.logged('no chest room'), 0, label .. ': no chest skip')
        else
            local skipped = log_time(h, 'stash visible for 20s and no chest room; leaving without chests')
            ok(skipped and skipped >= dead + CHEST_WAIT - 0.5, string.format(
                '%s: bounded skip only after the boss room is idle (skip %s, Council dead %.1f)', label,
                tostring(skipped), dead))
            ok(left_at - dead <= 60, string.format('%s: bounded exit %.1fs after the Council', label, left_at - dead))
        end
        eq(h.logged('War Plan horde complete; no new cycle'), 1, label .. ': completed once')
        no_compass(h, label)
    end
end)

-- ── H5-2 ─────────────────────────────────────────────────────────────────────
case('H5-2 persisted HordeDev + 6 s loading screen at startup: nothing before WarPigs decides in the loaded world', function()
    local PERSISTED = {infernal_horde_main_toggle = true, war_pigs_main_toggle = true, war_pug_main_toggle = true,
        silent_raven_main_toggle = true}
    for _, v in ipairs({{'no Horde plan', nil}, {'Horde plan', HORDE_Q}}) do
        local label = 'H5-2 ' .. v[1]
        local h = J.new({place = 'limbo', persisted = J.copy(PERSISTED)})
        h.assert_clean('load')
        h.instrument_exports()
        eq(el(h, HD).main_toggle:get(), true, label .. ': HordeDev toggle persisted on')
        if v[2] then h.set_quests({v[2]}) end
        h.setup_horde({})
        h.warplan_dest = 'bsk'
        h.travel = {at = h.now + 6, to = h.P.temis, phase = 'loading', why = 'startup load'}
        h.run(5.9)
        eq(h.place, h.P.limbo, label .. ': still loading')
        eq(#h.waypoints, 0, label .. ': nothing during the loading screen')
        h.run(60)
        h.assert_clean(label)
        local loaded = h.arrivals[1] and h.arrivals[1].t
        ok(loaded, label .. ': the world loaded')
        local decided = log_time(h, '[WarPigs] disabled InfernalHordesPlugin')
            or log_time(h, 'adopted active InfernalHordesPlugin')
        ok(decided and decided >= loaded, label .. ': WarPigs decided in the loaded world')
        local early = nil
        for kind, list in pairs({teleport = h.waypoints, compass = h.items, movement = h.moves}) do
            for _, c in ipairs(list) do
                if c.context == HD and c.t <= decided + 1e-6 and not early then
                    early = string.format('%s at %.1f (world loaded at %.1f, WarPigs decided at %.1f)', kind, c.t, loaded,
                        decided)
                end
            end
        end
        eq(early, nil, label .. ': no HordeDev teleport, compass or movement before WarPigs decided')
        eq(h.count(h.waypoints, function(w) return w.context == HD end), 0, label .. ': no HordeDev teleport at all')
        eq(h.logged('waiting up to 5s for WarPigs before acting'), 1, label .. ': the visible wait was logged')
        eq(h.logged('No enable/disable from WarPigs within 5s'), 0, label .. ': WarPigs decided within the bound')
    end
end)

-- ── H5-4 ─────────────────────────────────────────────────────────────────────
case('H5-4 sticky advisory restock flag under WarPigs: no HordeDev Alfred trip from the War Plan chest room', function()
    local h = setup({place = 'temis', quests = {HORDE_Q}})
    h.alfred.need_trigger, h.alfred.sticky_need, h.alfred.restock_count = true, true, 2
    local A = h.setup_horde({})
    h.warplan_dest = 'bsk'
    ok(h.run_until(function() return #h.quests == 0 end, 600), 'H5-4: the War Plan quest was turned in\n' .. h.tail())
    h.assert_clean('H5-4')
    eq(A.runs, 1, 'H5-4: one horde')
    eq(#A.opened, 3, 'H5-4: the chests were opened')
    eq(h.count(h.alfred.triggers, function(t) return t.context == HD end), 0,
        'H5-4: HordeDev started no Alfred trip for the advisory flag')
    eq(h.logged('Advisory Alfred flag left to WarPigs'), 1, 'H5-4: the skip was logged once')
    eq(h.logged('War Plan horde complete; no new cycle'), 1, 'H5-4: completed')
    no_compass(h, 'H5-4')
    -- a hard need in the chest room still sends HordeDev's own Alfred trip
    local f = setup({place = 'temis', quests = {HORDE_Q}})
    local B = f.setup_horde({})
    f.warplan_dest = 'bsk'
    ok(f.run_until(function() return B.council_dead_at ~= nil end, 400), 'H5-4 hard need: the Council died')
    f.alfred.inventory_full = true
    ok(f.run_until(function() return f.count(f.alfred.triggers, function(t) return t.context == HD end) >= 1 end, 90),
        'H5-4 hard need: inventory_full still starts HordeDev\'s own Alfred trip\n' .. f.tail())
    f.assert_clean('H5-4 hard need')
end)

for _, failure in ipairs(failures) do print('FAIL ' .. failure) end
print(string.format('HordeDev round 5 (joint): %d checks, %d failures', checks, #failures))
assert(#failures == 0, 'HordeDev round-5 joint regressions failed')
print(string.format('PASS: HordeDev round-5 joint regressions (%d checks)', checks))
