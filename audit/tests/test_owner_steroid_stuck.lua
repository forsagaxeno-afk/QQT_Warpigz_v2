-- QQT_Warpigz_v3 owner-build (no Rosie; SteroidAlfredV2 "BetterAlfred" +
-- LooteerV3). Regressions against the joint host's Steroid-shaped Alfred mock
-- (opts.alfred_shape = 'steroid': Steroid's status fields only, one callback
-- slot, cb() without arguments, Batmobile paused during the trip, STUCK mode).
--   b1  SteroidAlfred goes STUCK for good (stash full / skip_cache with a full
--       bag): trigger_tasks stays true and no callback ever comes. Every
--       activity held on that "live work" forever. Now continuous live work
--       longer than 300 s is logged once, the activity's request is retired
--       and it farms on; no new trip is asked for while the town service
--       stays stuck (and for at least 600 s).
--         A1 ArkhamAsylum, W1 WonderCity, D1 HordeDev, R1 Reaper,
--         H1 HelltideRevamped, P1 WarPug, S1 SilentRaven auto-fire.
--   b2  A1b / W2: any loaded town service is Temis-only (Steroid's town list
--       is {'Temis'}): with a Cerrigar home town Arkham's own hop and
--       WonderCity's exit go to Temis, not to Cerrigar.
--   H2  a failed Steroid cycle calls cb() with no arguments and leaves the bag
--       full: HelltideRevamped does not ask again and again (two trips that
--       end with a full bag latch "town service unavailable").
-- Each case fails on the 3.3.21 tree. Runs under Lua 5.4 and LuaJIT.
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
local ONLY = os.getenv('JOINT_ONLY')
local function case(name, fn)
    if ONLY and ONLY ~= '' and not name:find(ONLY, 1, true) then return end
    local started = os.clock()
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print(string.format('PASS owner-steroid: %s (%.1fs)', name, os.clock() - started))
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL owner-steroid: ' .. name .. ': ' .. tostring(err)) end
end

local STUCK_LINE = 'town service busy for 300s without finishing (stash full?)'
local CERRIGAR_WP, TEMIS_WP = 0x76D58, 0x1CE51E
local function triggers(h, context, since)
    return h.count(h.alfred.triggers, function(t) return t.context == context and t.t >= (since or 0) end)
end
local function moves(h, context, since)
    return h.count(h.moves, function(m) return m.context == context and m.t >= since end)
end
local function log_time(h, text)
    for _, line in ipairs(h.log) do
        if line:find(text, 1, true) then return tonumber(line:match('^(%-?[%d%.]+)')) end
    end
    return nil
end
local function steroid(dirs, place, o)
    o = o or {}
    local h = J.new({alfred_shape = 'steroid', dirs = dirs, place = place, minute = o.minute, persisted = o.persisted})
    h.assert_clean('load')
    h.render = false -- long runs: update callbacks only
    h.instrument_exports()
    return h
end

-- ── ArkhamAsylum ──────────────────────────────────────────────────────────
local ARK = 'ArkhamAsylum'
local function arkham(o)
    local h = steroid({ARK, 'Batmobile'}, 'pit')
    for i = 1, 4 do h.actor('pit', 'Pit_Monster_' .. i, 20 + i * 15, (i % 2) * 6, {enemy = true}) end
    if o and o.town then h.mod(ARK, 'gui').elements.town:set(o.town) end
    h.mod(ARK, 'gui').elements.main_toggle:set(true)
    h.run(5)
    return h
end

case('A1 Arkham: a STUCK town service holds the Pit at most 300 s, then Arkham farms on without asking again', function()
    local h = arkham()
    h.alfred.stuck = true
    h.alfred.need_trigger, h.alfred.inventory_full = true, true
    local t0 = h.now
    ok(h.run_until(function() return h.logged(STUCK_LINE) > 0 end, 400, nil, 0.25), 'the stuck service is noticed\n' .. h.tail(20))
    local at = log_time(h, STUCK_LINE)
    ok(at - t0 >= 300 and at - t0 <= 330, string.format('noticed after %.0f s', at - t0))
    eq(triggers(h, ARK), 1, 'one request before')
    local task = h.mod(ARK, 'tasks.alfred')
    h.run(5)
    eq(h.as(ARK, function() return task.is_busy() end), false, 'the Alfred task no longer holds the Pit')
    local mark = h.now
    h.run(620, nil, 0.5)
    h.assert_clean('A1')
    eq(h.logged(STUCK_LINE), 1, 'logged once')
    eq(triggers(h, ARK, at), 0, 'no new request while the service stays stuck')
    ok(moves(h, ARK, mark) + h.count(h.bm_calls, function(c) return c.context == ARK and c.t >= mark end) > 0,
        'Arkham farms on (movement after the latch)')
    ok(h.alfred.job and h.alfred.job.phase == 'stuck', 'the mock stayed stuck')
end)

case('A1b Arkham, Cerrigar home town: the plain-trigger hop goes to Temis (the only town Steroid services)', function()
    local h = arkham({town = 1})
    local mark = h.now
    h.alfred.need_trigger, h.alfred.inventory_full = true, true
    ok(h.run_until(function() return triggers(h, ARK, mark) > 0 end, 30), 'Arkham asks for the trip\n' .. h.tail(20))
    ok(h.run_until(function() return h.alfred.job == nil and h.alfred.inventory_full == false end, 120),
        'the trip completes\n' .. h.tail(20))
    h.assert_clean('A1b')
    eq(h.count(h.waypoints, function(w) return w.context == ARK and w.t >= mark and w.sno == CERRIGAR_WP end), 0,
        'no Cerrigar cast against the Temis trip')
end)

-- ── WonderCity ────────────────────────────────────────────────────────────
local WC = 'WonderCity'
case('W1 WonderCity: a STUCK town service holds at most 300 s, then WonderCity goes on without asking again', function()
    local h = steroid({'Batmobile', WC}, 'kurast')
    local wc = h.mod(WC, 'gui').elements
    wc.main_toggle:set(true); wc.skip_tribute:set(true); wc.exit_mode:set(1)
    h.alfred.stuck = true
    h.alfred.need_trigger, h.alfred.inventory_full = true, true
    local t0 = h.now
    ok(h.run_until(function() return triggers(h, WC) > 0 end, 30), 'WonderCity asks for the trip\n' .. h.tail(20))
    ok(h.run_until(function() return h.logged(STUCK_LINE) > 0 end, 400, nil, 0.25), 'the stuck service is noticed\n' .. h.tail(20))
    local at = log_time(h, STUCK_LINE)
    ok(at - t0 >= 300 and at - t0 <= 330, string.format('noticed after %.0f s', at - t0))
    local task = h.mod(WC, 'tasks.alfred')
    h.run(2)
    eq(h.as(WC, function() return task.is_busy() end), false, 'the Alfred task no longer holds WonderCity')
    h.run(620, nil, 0.5)
    h.assert_clean('W1')
    eq(h.logged(STUCK_LINE), 1, 'logged once')
    eq(triggers(h, WC, at), 0, 'no new request while the service stays stuck')
    ok(h.alfred.job and h.alfred.job.phase == 'stuck', 'the mock stayed stuck')
end)

case('W2 WonderCity: a town-service need at run end exits to Temis (Steroid services Temis only), not Kurast', function()
    local h = steroid({'Batmobile', WC}, 'undercity')
    local wc = h.mod(WC, 'gui').elements
    wc.skip_tribute:set(true); wc.exit_mode:set(1); wc.exit_undercity_delay:set(0)
    local chest = h.actor('undercity', 'X1_Undercity_Chest_Attunement', 5, 0)
    chest.on_interact = function() chest.interactable = false end
    wc.main_toggle:set(true)
    local tracker = h.mod(WC, 'core.tracker')
    ok(h.run_until(function() return tracker.done end, 30), 'the reward chest opened\n' .. h.tail(20))
    h.alfred.need_trigger, h.alfred.need_repair = true, true -- a need that does not start a trip inside
    ok(h.run_until(function() return h.count(h.waypoints, function(w) return w.context == WC end) > 0 end, 40),
        'the exit was cast\n' .. h.tail(20))
    h.assert_clean('W2')
    local first
    for _, w in ipairs(h.waypoints) do if w.context == WC then first = first or w end end
    eq(first.sno, TEMIS_WP, 'the exit goes to Temis')
end)

-- ── HordeDev ──────────────────────────────────────────────────────────────
local HD = 'HordeDev'
case('D1 HordeDev: a STUCK town service (its own trip from the Horde) holds at most 300 s; the Horde and the next run go on', function()
    local h = steroid({'Batmobile', HD}, 'caldeum')
    h.give_compasses(2)
    local A = h.setup_horde({})
    h.mod(HD, 'gui').elements.main_toggle:set(true)
    ok(h.run_until(function() return A.wave >= 2 end, 300), 'wave 2\n' .. h.tail(20))
    h.alfred.stuck = true
    h.alfred.need_trigger, h.alfred.inventory_full = true, true
    h.as(h.alfred_ctx, function() return h.G.AlfredTheButlerPlugin.trigger_tasks_with_teleport('alfred_the_butler') end)
    local t0, wave = h.now, A.wave
    ok(h.run_until(function() return h.logged(STUCK_LINE) > 0 end, 400, nil, 0.25), 'the stuck service is noticed\n' .. h.tail(20))
    local at = log_time(h, STUCK_LINE)
    ok(at - t0 >= 300 and at - t0 <= 330, string.format('noticed after %.0f s', at - t0))
    eq(A.wave, wave, 'the Horde waited for the trip until then')
    ok(h.run_until(function() return A.runs >= 2 end, 600, nil, 0.25), 'the Horde finished and the next run started\n' .. h.tail(30))
    h.assert_clean('D1')
    eq(h.logged(STUCK_LINE), 1, 'logged once')
    eq(triggers(h, HD, at), 0, 'no HordeDev request while the service stays stuck')
    ok(h.alfred.job and h.alfred.job.phase == 'stuck', 'the mock stayed stuck')
end)

-- ── Reaper ────────────────────────────────────────────────────────────────
local RP = 'Reaper'
case('R1 Reaper: a STUCK town service in Temis holds the boss run at most 300 s, then Reaper goes to the boss', function()
    local h = steroid({'Batmobile', RP}, 'temis')
    h.setup_lair()
    h.keys_items = {{get_sno_id = function() return 2558255 end, get_acd = function() return 777 end,
        get_stack_count = function() return 5 end}}
    h.alfred.stuck = true
    h.alfred.need_trigger, h.alfred.inventory_full = true, true
    h.as(h.alfred_ctx, function() return h.G.AlfredTheButlerPlugin.trigger_tasks('alfred_the_butler') end)
    h.run(10)
    local g = h.mod(RP, 'gui').elements
    g.boss_enabled.andariel:set(true)
    g.main_toggle:set(true)
    local t0 = h.now
    ok(h.run_until(function() return h.logged(STUCK_LINE) > 0 end, 400, nil, 0.25), 'the stuck service is noticed\n' .. h.tail(20))
    local at = log_time(h, STUCK_LINE)
    ok(at - t0 >= 290 and at - t0 <= 330, string.format('noticed after %.0f s', at - t0))
    eq(h.count(h.boss_tps, function(b) return b.context == RP and b.t < at end), 0, 'Reaper waited for the trip until then')
    ok(h.run_until(function() return h.count(h.boss_tps, function(b) return b.context == RP end) > 0 end, 60),
        'Reaper teleports to the boss\n' .. h.tail(20))
    h.run(120, nil, 0.25)
    h.assert_clean('R1')
    eq(h.logged(STUCK_LINE), 1, 'logged once')
    eq(triggers(h, RP), 0, 'no Reaper request while the service stays stuck')
end)

-- ── HelltideRevamped ──────────────────────────────────────────────────────
local HR = 'HelltideRevamped'
local function helltide()
    local h = steroid({'Batmobile', HR}, 'helltide', {minute = 5})
    h.mod(HR, 'core.hr_clock')._now = function() return 1790481600 + h.minute * 60 + math.floor(h.now) % 60 end
    h.P.helltide.helltide = true
    h.mod(HR, 'gui').elements.main_toggle:set(true)
    h.run(10)
    return h
end
case('H1 HelltideRevamped: a STUCK town service holds the farm at most 300 s, then HR farms on without asking again', function()
    local h = helltide()
    h.alfred.stuck = true
    h.alfred.need_trigger, h.alfred.inventory_full = true, true
    local t0 = h.now
    ok(h.run_until(function() return h.logged(STUCK_LINE) > 0 end, 400, nil, 0.25), 'the stuck service is noticed\n' .. h.tail(20))
    local at = log_time(h, STUCK_LINE)
    ok(at - t0 >= 300 and at - t0 <= 330, string.format('noticed after %.0f s', at - t0))
    eq(triggers(h, HR), 1, 'one request before')
    local task = h.mod(HR, 'tasks.alfred')
    h.run(2)
    eq(h.as(HR, function() return task.shouldExecute() end), false, 'the Alfred task no longer holds the farm')
    local mark = h.now
    h.run(620, nil, 1.0)
    h.assert_clean('H1')
    eq(h.logged(STUCK_LINE), 1, 'logged once')
    eq(triggers(h, HR, at), 0, 'no new request while the service stays stuck')
    ok(h.count(h.bm_calls, function(c) return c.context == HR and c.t >= mark end) > 0
        or moves(h, HR, mark) > 0, 'HR farms on (movement after the latch)')
    ok(h.alfred.job and h.alfred.job.phase == 'stuck', 'the mock stayed stuck')
end)

case('H2 HelltideRevamped: failed Steroid cycles (cb() without arguments, bag still full) latch after two trips', function()
    local h = helltide()
    h.alfred.fail = true
    h.alfred.need_trigger, h.alfred.inventory_full = true, true
    local t0 = h.now
    h.run(400, nil, 0.25)
    h.assert_clean('H2')
    eq(triggers(h, HR, t0), 2, 'two trips, then no more (3.3.21: a trip every ~16 s)')
    eq(h.logged('Town service unavailable (two town trips in a row ended with the bag still full)'), 1, 'one line')
end)

-- ── WarPug / SilentRaven (hold only; they never request a trip) ───────────
local function stuck_in_temis(dirs)
    local h = steroid(dirs, 'temis')
    h.alfred.stuck = true
    h.alfred.need_trigger, h.alfred.inventory_full = true, true
    h.as(h.alfred_ctx, function() return h.G.AlfredTheButlerPlugin.trigger_tasks('alfred_the_butler') end)
    h.run(10)
    ok(h.alfred.job and h.alfred.job.phase == 'stuck', 'the mock is stuck')
    return h
end
case('P1 WarPug: a STUCK town service holds the War Plan at most 300 s, then WarPug plans', function()
    local h = stuck_in_temis({'WarPug'})
    h.mod('WarPug', 'gui').elements.main_toggle:set(true)
    local t0 = h.now
    ok(h.run_until(function() return h.board.confirmed > 0 end, 400, nil, 0.25), 'the plan is confirmed\n' .. h.tail(20))
    local at = log_time(h, STUCK_LINE)
    ok(at and at - t0 >= 295 and at - t0 <= 330, 'noticed after ' .. tostring(at and at - t0))
    eq(h.logged(STUCK_LINE), 1, 'logged once')
    h.assert_clean('P1')
end)
case('S1 SilentRaven: a STUCK town service holds auto-fire in Temis at most 300 s, then the reward is claimed', function()
    local h = stuck_in_temis({'SilentRaven'})
    h.mod('SilentRaven', 'silent_raven.gui').elements.main_toggle:set(true)
    h.bounty_ready = true
    local t0 = h.now
    ok(h.run_until(function() return h.reward_accepts == 1 end, 400, nil, 0.25), 'the reward is claimed\n' .. h.tail(20))
    local at = log_time(h, STUCK_LINE)
    ok(at and at - t0 >= 295 and at - t0 <= 330, 'noticed after ' .. tostring(at and at - t0))
    eq(h.logged(STUCK_LINE), 1, 'logged once')
    h.assert_clean('S1')
end)

if #failures > 0 then error(#failures .. ' owner-build Steroid case(s) failed:\n' .. table.concat(failures, '\n')) end
print(string.format('PASS: owner-build Steroid regressions, %d checks', checks))
