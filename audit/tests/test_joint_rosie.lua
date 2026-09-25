-- Joint scenarios with the REAL Rosie as the Alfred and Looter provider:
-- all nine bundle plugins plus Rosie in one emulated QQT host
-- (joint_host.lua with opts.rosie: no Alfred/Looter mocks). Rosie publishes
-- RosiePlugin, AlfredTheButlerPlugin, PLUGIN_alfred_the_butler and
-- LooteerPlugin; the bundle reaches it only through those adapters.
--   R1 War Plan Pit run, bags full: a town trip through Rosie (Arkham's own
--      request, and Rosie's own automatic service), back into the same pit,
--      Arkham resumes, the War Plan hand-off waits for the trip.
--   R2 C5: Rosie picking up drops holds the WarPigs outgoing teleport and the
--      Whisper walk; the yield is visible, bounded, and never counted as stuck.
--   R3 failed trips: Rosie's bounded retry cooldown, WarPigs' bounded stuck
--      hold, a latched stop after three failures that WarPigs stops waiting on.
--   R4 H1: a Batmobile long route is stopped and Batmobile paused for a trip.
--   R5 Helltide, R6 WonderCity Undercity (success / legacy 'failed'), R7 Reaper
--      boss lair: a Rosie trip mid-activity returns into it, activity kept.
--   R8 reloads mid-trip: Rosie (package.loaded kept) and Arkham.
-- Runs under Lua 5.4 and LuaJIT (run_tests.py runs both).
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
    if passed then print(string.format('PASS joint-rosie: %s (%.1fs)', name, os.clock() - started))
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL joint-rosie: ' .. name .. ': ' .. tostring(err)) end
end

local WP, PUG, SR, ARK, WC = 'WarPigs-1.0.0', 'WarPug-1.0.0', 'SilentRaven-0.1.3', 'ArkhamAsylum-1.0.6', 'WonderCity-main'
local function el(h, dir)
    local mod = dir == SR and 'silent_raven.gui' or 'gui'
    return assert(h.mod(dir, mod), 'gui of ' .. dir).elements
end
local function status(h, export)
    local api = h.G[export]
    local fn = api.status or api.get_status
    return h.as(WP, function() return fn() end)
end
local function enabled(h, export) return status(h, export).enabled == true end
local function first(list, pred)
    for _, rec in ipairs(list) do if pred(rec) then return rec end end
    return nil
end
local function live(s)
    return s.trigger_tasks == true or s.external_trigger == true or s.pending == true or s.running == true
        or (s.teleport == true and s.teleport_done ~= true and s.teleport_failed ~= true)
end
local function alfred(h) return status(h, 'AlfredTheButlerPlugin') end
-- The README configuration with Rosie enabled (it starts off).
local function setup(opts)
    opts = opts or {}
    opts.rosie = true
    local h = J.new(opts)
    h.assert_clean('load')
    h.instrument_exports()
    el(h, WP).main_toggle:set(opts.warpigs ~= false)
    el(h, PUG).main_toggle:set(opts.warpug ~= false)
    el(h, SR).main_toggle:set(opts.raven ~= false)
    if opts.teleport then el(h, WP).use_teleport_transition:set(true) end
    if opts.quests then h.set_quests(opts.quests) end
    -- Rosie's automatic service off (its keybind gate closed): trips only on request.
    if opts.rosie_auto == false then h.mod('Rosie', 'rosie.private.town.gui').elements.use_keybind:set(true) end
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(opts.pickup_distance or 2)
    eq(h.as('Rosie', function() return h.G.RosiePlugin.enable() end), true, 'Rosie enabled')
    return h
end
local function fill_bag(h, n)
    h.inventory = h.inventory or {}
    for _ = 1, n or 25 do h.inventory[#h.inventory + 1] = h.gear() end
end

case('R0 load: nine plugins + Rosie, documented exports only, consumer reads resolve', function()
    local h = J.new({rosie = true})
    h.assert_clean('load')
    eq(#h.plugins, 10, 'plugin folders')
    local expected = {}
    for export in pairs(h.exports) do expected[#expected + 1] = export end
    table.sort(expected)
    eq(table.concat(h.new_globals(), ','), table.concat(expected, ','), 'new globals after load')
    for export, dir in pairs(J.ROSIE_EXPORTS) do
        local writer = first(h.global_writes, function(w) return w.name == export end)
        eq(writer and writer.owner, dir, export .. ' written by Rosie')
    end
    h.run(20)
    h.assert_clean('idle')
    local s = alfred(h)
    eq(s.enabled, false, 'Rosie starts off'); eq(live(s), false)
end)

case("R1 War Plan Pit, bags full: Arkham's with-teleport trip through Rosie, back into the pit, the hand-off waits", function()
    local h = setup({place = 'pit', quests = {'WarPlans_QST_ThePit'}, rosie_auto = false})
    h.run(10)
    ok(enabled(h, 'ArkhamAsylumPlugin'), 'WarPigs runs Arkham in the pit\n' .. h.tail())
    -- The plan moves on mid-run: the hand-off must wait for the trip.
    h.set_quests({'WarPlans_QST_Undercity'})
    h.run(1)
    h.floor_loot = true
    fill_bag(h, 25)
    local in_town, statuses, live_town = false, {}, true
    ok(h.run_until(function()
        if h.place == h.P.temis then
            in_town = true
            statuses[#statuses + 1] = status(h, 'ArkhamAsylumPlugin')
            live_town = live_town and live(alfred(h))
        end
        return in_town and h.place == h.P.pit and not live(alfred(h))
    end, 90), 'Rosie trip went to town and back\n' .. h.tail())
    ok(#statuses > 10, 'town leg observed')
    ok(live_town, 'C1: Rosie reported live work during the whole town leg')
    eq(#h.inventory, 0, 'Rosie emptied the bag'); eq(#h.salvaged, 25, 'salvaged at the Temis Blacksmith')
    local back = h.arrivals[#h.arrivals]
    eq(back.why, 'town_portal', 'returned through the town portal'); eq(back.place, 'pit', 'into the same pit')
    eq(#h.waypoints, 1, 'one waypoint teleport')
    eq(h.waypoints[1].context, 'Rosie', 'the teleport is Rosie\'s')
    local requests = {}
    for _, c in ipairs(h.api_calls) do
        if c.name == 'trigger_tasks_with_teleport' or c.name == 'trigger_tasks' then requests[#requests + 1] = c end
    end
    eq(#requests, 1, 'one town request'); eq(requests[1].context, ARK, 'requested by Arkham')
    eq(requests[1].caller, 'arkham_asylum')
    for _, st in ipairs(statuses) do
        eq(st.enabled, true, 'Arkham kept during its town leg')
        eq(st.alfred_trip, true, 'C2 alfred_trip published during the town leg')
    end
    ok(h.logged('Alfred round trip in progress') >= 1, 'WarPigs defers the hand-off over the trip')
    eq(enabled(h, 'WonderCityPlugin'), false, 'WonderCity not started over the trip')
    h.floor_loot = false
    h.run(8)
    ok(h.logged('resuming the run') >= 1, 'Arkham resumes the same pit run')
    eq(live(alfred(h)), false, 'Rosie idle again')
    -- The run ends: back in town, released, WonderCity next.
    h.travel_to('temis', 1.0, 'pit_exit')
    ok(h.run_until(function() return enabled(h, 'WonderCityPlugin') end, 30), 'WonderCity after the real exit\n' .. h.tail())
    eq(h.count(h.api_calls, function(c) return c.name == 'trigger_tasks_with_teleport' or c.name == 'trigger_tasks' end), 1,
        'no second town request')
    h.assert_clean('R1')
end)

local HORDE_Q = 'WarPlans_QST_InfernalHordes_BSK'
case("R1 War Plan Horde, bags full at wave 3: Rosie's own trip out of the Horde and back, HordeDev kept, run completes",
    function()
    local h = setup({quests = {HORDE_Q}})
    local A = h.setup_horde({chest_room = true})
    h.warplan_dest = 'bsk'
    ok(h.run_until(function() return A.wave >= 3 end, 400), 'wave 3 reached\n' .. h.tail())
    local mark = h.now
    fill_bag(h, 25)
    local town_frames, dropped, live_town = 0, false, true
    ok(h.run_until(function()
        if h.place == h.P.temis and h.now > mark and first(h.arrivals, function(a) return a.t >= mark end) then
            local left = first(h.arrivals, function(a) return a.t >= mark and a.place == 'temis' end)
            local back = first(h.arrivals, function(a) return a.t >= mark and a.place == 'bsk' end)
            if left and not back then
                town_frames = town_frames + 1
                if not enabled(h, 'InfernalHordesPlugin') then dropped = true end
                live_town = live_town and live(alfred(h))
            end
        end
        return #h.quests == 0
    end, 500), 'the horde and the turn-in\n' .. h.tail())
    h.run(3)
    h.assert_clean('R1 horde')
    local to_town = first(h.arrivals, function(a) return a.t >= mark and a.place == 'temis' end)
    local back = first(h.arrivals, function(a) return a.t >= mark and a.place == 'bsk' end)
    ok(to_town and back and back.why == 'town_portal', 'Rosie took the player to Temis and back into the same horde')
    local tp = first(h.waypoints, function(x) return x.from == 'bsk' end)
    eq(tp and tp.context, 'Rosie', 'the only teleport out of BSK is Rosie\'s')
    eq(h.count(h.waypoints, function(x) return x.from == 'bsk' end), 1, 'one teleport out of BSK')
    eq(h.count(h.api_calls, function(c) return c.name == 'trigger_tasks_with_teleport' end), 0,
        'nobody requested it: Rosie\'s own automatic service')
    ok(town_frames > 50 and not dropped, 'HordeDev kept over the town leg')
    ok(live_town, 'C1: live work during the town leg')
    eq(#h.salvaged, 25, 'the bag was serviced')
    eq(A.runs, 1, 'one horde'); eq(A.wave, 6, 'six waves'); ok(A.council_dead_at ~= nil, 'Council dead')
    eq(#A.opened, 3, 'the chests were opened')
    eq(h.leaves, 1, 'Leave Dungeon')
    eq(h.count(h.warplans, function(x) return x.kind == 'teleport' and x.from == 'bsk' end), 0, 'no War Plan teleport from BSK')
    eq(h.logged('turn-in cycle completed'), 1, 'turn-in')
    eq(live(alfred(h)), false, 'Rosie idle at the end')
end)

-- C5: Rosie's pickup holds WarPigs' companion gates. In Temis the Whisper walk
-- (SilentRaven, managed by WarPigs) waits while Rosie collects drops next to
-- the player; the wait is a yield, not a failure, and nothing re-requests.
case('R2 C5: Rosie picking up drops in Temis holds the Whisper walk; the claim completes once, no stuck time', function()
    local h = setup({pickup_distance = 12})
    h.bounty_ready = true
    local t0 = h.now
    -- Drops land beside the player at 1 s and again at 9 s (a second burst).
    local spawn = {{1, 3}, {9, 2}}
    local busy_frames, raven_moves_busy = 0, 0
    ok(h.run_until(function()
        local rel = h.now - t0
        for _, sp in ipairs(spawn) do
            if not sp.done and rel >= sp[1] then
                sp.done = true
                for i = 1, sp[2] do h.drop('temis', h.pos:x() + 6 + i, h.pos:y() + 2) end
            end
        end
        return h.logged('[WarPug] state IDLE -> APPROACH_TABLE') > 0
    end, 120, function()
        local busy = h.as(WP, function() return h.G.LooteerPlugin.is_actively_looting() end)
        if busy then
            busy_frames = busy_frames + 1
            raven_moves_busy = raven_moves_busy + h.count(h.moves, function(m) return m.context == SR and m.t == h.now end)
        end
    end), 'WarPug started planning\n' .. h.tail())
    h.assert_clean('R2')
    ok(busy_frames > 5, 'Rosie reported active pickup (' .. busy_frames .. ' frames)')
    eq(h.pickups, 5, 'every drop collected')
    eq(raven_moves_busy, 0, 'SilentRaven never moved while Rosie was picking up')
    eq(h.reward_accepts, 1, 'one reward accepted')
    eq(h.logged('checking completed Whispers in Temis'), 1, 'one managed request in the visit')
    eq(h.logged('retrying when companions are clear'), 0, 'no re-request')
    eq(h.logged('run finished: success'), 1, 'SilentRaven verified the claim')
    eq(h.logged('visit 1: success'), 1, 'WarPigs reports the claim')
    eq(h.logged('proceeding with the teleport anyway'), 0, 'no bounded Looter hold expired')
    eq(h.logged('stuck'), 0, 'no stuck report')
    ok(h.logged('town movement held — Looter collecting town loot (is_actively_looting)') >= 1,
        'WarPigs holds its town movement for Rosie\'s pickup (visible, C6)')
    ok(h.logged('waiting: looter_settling') >= 1, 'the Whisper check waits for the pickup to settle')
    eq(h.logged('Looter busy before accept — pausing the Whisper request'), 1,
        'the second burst pauses (not cancels) the running request')
    local paused_at, done_at
    for _, line in ipairs(h.log) do
        local t = tonumber(line:match('^(%-?[%d%.]+)'))
        if line:find('pausing the Whisper request', 1, true) then paused_at = t end
        if line:find('visit 1: success', 1, true) then done_at = t end
    end
    ok(paused_at and done_at and done_at > paused_at, 'the claim completed after the pickup yield')
end)

-- A failed Rosie trip whose need remains (the Blacksmith cannot be reached):
-- Rosie reports 'failed'; WarPigs does not count it as a completed cycle.
-- Rosie refuses API requests for its retry cooldown (stuck_retry_in); WarPigs
-- holds for it (bounded, logged once with the reason), kicks again once the
-- cooldown ends, and after Rosie's third consecutive failure (latched until
-- Run town service) stops holding: the War Plan loop is never stopped
-- indefinitely and nothing loops trips.
case('R3 failed Rosie trips in Temis: bounded cooldown retries, then a latched stop WarPigs no longer waits on', function()
    local h = setup({rosie_auto = false})
    h.remove_actor(h.blacksmith)
    fill_bag(h, 25)
    ok(h.run_until(function() return h.logged('[Rosie] failed') > 0 end, 200), 'the trip failed\n' .. h.tail())
    local failed_at = h.now
    local function kicks()
        return h.count(h.api_calls, function(c) return c.context == WP and c.name == 'trigger_tasks' end)
    end
    ok(kicks() >= 1, 'WarPigs kicked Rosie in Temis')
    h.run(60)
    h.assert_clean('R3 cooldown')
    eq(h.logged('[Rosie] failed'), 1, 'no retry inside the cooldown')
    eq(h.count(h.vendors, function(v) return v.t > failed_at end), 0, 'no vendor walk inside the cooldown')
    local s = alfred(h)
    eq(live(s), false, 'C1: nothing live'); eq(s.stuck, true); eq(s.need_trigger, false); eq(s.inventory_full, true)
    ok(type(s.stuck_retry_in) == 'number', 'Rosie publishes when it allows a retry')
    eq(h.logged('Alfred is stuck ('), 1, 'WarPigs logs the stuck hold once, with the reason')
    ok(h.logged('allows a retry in') == 1, 'and that it is bounded')
    eq(h.logged('task requested in town', failed_at + 1), 0, 'no false "task requested" while Rosie refuses')
    eq(h.as(WP, function() return h.mod(WP, 'core.orchestrator').alfred_idle() end), false, 'held inside the cooldown')
    -- Cooldown over: WarPigs kicks again, twice more; the third failure latches.
    ok(h.run_until(function() return h.logged('[Rosie] failed') == 3 end, 900), 'three attempts\n' .. h.tail())
    h.run(2)
    s = alfred(h)
    eq(s.stuck, true); eq(s.stuck_retry_in, nil, 'latched until Run town service'); eq(s.fail_streak, 3)
    eq(h.logged('waits for an explicit Run town service'), 1, 'WarPigs stops holding, logged once')
    eq(h.as(WP, function() return h.mod(WP, 'core.orchestrator').alfred_idle() end), true, 'the gate is open again')
    local k = kicks()
    ok(k >= 3 and k <= 4, 'one kick per attempt: ' .. k)
    h.run(300)
    h.assert_clean('R3')
    eq(h.logged('[Rosie] failed'), 3, 'no fourth attempt'); eq(kicks(), k, 'no further kicks while latched')
    eq(#h.waypoints, 0, 'nobody teleported')
end)

local BAT, HR, RP = 'Batmobile-1.0.12', 'HelltideRevamped-0.4', 'Reaper-main'
local function bat_moves(h, from, to)
    return h.count(h.moves, function(m) return m.owner == BAT and m.t > from and (not to or m.t <= to) end)
end
-- The trip window: the first and last frame Rosie reported live work.
local function trip_window(h, pred_done, seconds)
    local from, to
    local done = h.run_until(function()
        if live(alfred(h)) then from = from or h.now; to = h.now end
        return from ~= nil and pred_done()
    end, seconds or 120)
    return done, from, to
end

-- H1: an activity's Batmobile long route keeps driving from Batmobile's own
-- update. Rosie's automatic trip stops the route and pauses a running
-- Batmobile for the trip, and resumes it afterwards (the old fork did too).
case("R4 H1 Batmobile long path active when Rosie's automatic trip starts: no Batmobile move during the trip", function()
    local h = setup({place = 'pit', warpigs = false, warpug = false, raven = false})
    local lp, nav = h.mod(BAT, 'core.long_path'), h.mod(BAT, 'core.navigator')
    h.run(1)
    eq(h.as(ARK, function() return h.G.BatmobilePlugin.navigate_long_path('arkham_asylum', h.v(200, 0)) end), true,
        'an activity route')
    local t0 = h.now
    h.run(1)
    ok(bat_moves(h, t0) > 0 and lp.navigating, 'Batmobile drives the route on its own')
    fill_bag(h, 25)
    local done, from, to = trip_window(h, function() return h.place == h.P.pit and not live(alfred(h)) end, 120)
    ok(done, 'Rosie trip to town and back\n' .. h.tail())
    eq(h.count(h.api_calls, function(c) return c.name == 'trigger_tasks_with_teleport' end), 0, "Rosie's own trip")
    eq(bat_moves(h, from, to), 0, 'no Batmobile move while Rosie is live')
    eq(h.count(h.bm_calls, function(c) return c.name == 'stop_long_path' and c.caller == 'alfred_the_butler' end), 1,
        'the route is stopped once')
    eq(h.count(h.bm_calls, function(c) return c.name == 'pause' and c.caller == 'alfred_the_butler' end), 1, 'paused once')
    eq(lp.navigating, false)
    eq(nav.paused, false, 'Batmobile resumed after the trip')
    eq(h.count(h.bm_calls, function(c) return c.name == 'resume' and c.caller == 'alfred_the_butler' end), 1, 'resumed once')
    eq(#h.salvaged, 25)
    h.assert_clean('R4')
end)

-- Helltide War Plan: bags full inside the helltide, a Rosie trip, back into
-- the same helltide, HelltideRevamped kept and running.
case('R5 War Plan Helltide, bags full in the helltide: a Rosie trip returns into the helltide, Helltide kept', function()
    local h = setup({place = 'helltide', quests = {'WarPlans_QST_Helltide_TorturedGifts'}})
    h.P.helltide.helltide = true
    ok(h.run_until(function() return enabled(h, 'HelltideRevampedPlugin') end, 20), 'Helltide enabled\n' .. h.tail())
    h.run(5)
    local mark = h.now
    fill_bag(h, 25)
    local dropped = false
    local done = h.run_until(function()
        if h.now > mark and not enabled(h, 'HelltideRevampedPlugin') then dropped = true end
        local back = first(h.arrivals, function(a) return a.t > mark and a.place == 'helltide' end)
        return back ~= nil and not live(alfred(h))
    end, 150)
    ok(done, 'back in the helltide\n' .. h.tail())
    h.assert_clean('R5')
    local to_town = first(h.arrivals, function(a) return a.t > mark and a.place == 'temis' end)
    local back = first(h.arrivals, function(a) return a.t > mark and a.place == 'helltide' end)
    ok(to_town and back and back.why == 'town_portal', 'Temis and back through the town portal')
    eq(h.count(h.waypoints, function(w) return w.t > mark and w.context == 'Rosie' end), 1, 'one Rosie teleport')
    eq(#h.salvaged, 25, 'serviced')
    eq(dropped, false, 'HelltideRevamped kept over the trip')
    eq(h.logged('[Rosie] completed'), 1)
    h.run(10)
    ok(first(h.bm_calls, function(c) return c.context == HR and c.t > back.t end) ~= nil, 'Helltide drives again')
    eq(h.count(h.waypoints, function(w) return w.t > back.t end), 0, 'nobody teleports out of the helltide after')
    h.assert_clean('R5 after')
end)

-- WonderCity's own with-teleport request from the Undercity: success resets
-- its task; a failed Rosie trip (legacy 'failed') counts as a failed cycle.
case("R6 WonderCity Undercity: its Rosie trip succeeds (reset), a failed one counts as a failed cycle", function()
    local h = setup({place = 'undercity', quests = {'WarPlans_QST_Undercity'}, rosie_auto = false})
    for i = 1, 3 do h.actor('undercity', 'Undercity_Monster_' .. i, 25 + i * 20, 0, {enemy = true}) end
    ok(h.run_until(function() return enabled(h, 'WonderCityPlugin') end, 20), 'WonderCity enabled\n' .. h.tail())
    h.run(3)
    local mark = h.now
    fill_bag(h, 25)
    ok(h.run_until(function()
        return first(h.arrivals, function(a) return a.t > mark and a.place == 'undercity' end) ~= nil
            and not live(alfred(h))
    end, 120), 'WonderCity trip there and back\n' .. h.tail())
    local req = first(h.api_calls, function(c) return c.t > mark and c.name == 'trigger_tasks_with_teleport' end)
    eq(req and req.context, WC, 'requested by WonderCity')
    eq(h.logged('Alfred reported'), 0, 'success is not a failed cycle')
    eq(#h.salvaged, 25)
    ok(enabled(h, 'WonderCityPlugin'), 'WonderCity kept')
    -- Second trip: the Blacksmith cannot be reached.
    h.run(3)
    h.remove_actor(h.blacksmith)
    local mark2 = h.now
    fill_bag(h, 25)
    ok(h.run_until(function() return h.logged('[Rosie] failed') > 0 end, 200), 'failed trip\n' .. h.tail())
    h.run(3)
    ok(h.logged('[WonderCity:alfred] Alfred reported failed for our cycle') == 1,
        'WonderCity counts the failed cycle\n' .. h.tail())
    eq(h.count(h.api_calls, function(c) return c.t > mark2 and c.name == 'trigger_tasks_with_teleport' and c.context == WC end), 1,
        'one request')
    h.assert_clean('R6')
end)

-- Reaper boss lair (War Plan): bags full in the lair, a Rosie trip back into
-- the lair, Reaper kept.
case('R7 War Plan boss lair: bags full in the lair, a Rosie trip back into the lair, Reaper kept', function()
    local h = setup({quests = {'WarPlans_QST_BossLair_Andariel'}})
    h.setup_lair()
    ok(h.run_until(function() return h.place == h.P.lair end, 20), 'Reaper travelled to the lair\n' .. h.tail())
    h.run(3)
    local mark = h.now
    fill_bag(h, 25)
    local dropped = false
    ok(h.run_until(function()
        if not enabled(h, 'ReaperPlugin') then dropped = true end
        return first(h.arrivals, function(a) return a.t > mark and a.place == 'lair' end) ~= nil and not live(alfred(h))
    end, 150), 'back in the lair\n' .. h.tail())
    h.assert_clean('R7')
    eq(#h.salvaged, 25); eq(dropped, false, 'Reaper kept over the trip')
    eq(h.count(h.waypoints, function(w) return w.t > mark and w.context == 'Rosie' end), 1, 'one Rosie teleport')
    local st = status(h, 'ReaperPlugin')
    eq(st.enabled, true); eq(st.in_run, true, 'the same run continues')
end)

-- Reloads: Rosie mid-trip (Arkham's request) and Arkham mid-trip (Rosie
-- holding its callback).
case('R8 reloads mid-trip in the War Plan Pit: Rosie (next request served), then Arkham (Rosie keeps its trip)', function()
    local h = setup({place = 'pit', quests = {'WarPlans_QST_ThePit'}, rosie_auto = false})
    h.run(10)
    ok(enabled(h, 'ArkhamAsylumPlugin'), 'Arkham runs')
    h.floor_loot = true
    fill_bag(h, 25)
    ok(h.run_until(function() return h.place == h.P.temis end, 30), 'trip in town\n' .. h.tail())
    h.reload('Rosie', {keep_loaded = true})
    h.instrument_exports()
    h.assert_clean('Rosie reload')
    eq(h.logged('[Rosie] cancelled: Rosie reloaded during service'), 1, 'the old trip is cancelled')
    -- The new Rosie is enabled (cached master switch) and serves the next request.
    ok(h.run_until(function() return h.logged('[Rosie] completed') > 0 end, 150), 'a trip completes after the reload\n' .. h.tail())
    eq(#h.inventory, 0, 'serviced by the new instance')
    eq(h.logged('This Rosie instance has reloaded'), 0)
    ok(h.run_until(function() return h.place == h.P.pit or enabled(h, 'ArkhamAsylumPlugin') end, 60), 'the run continues')
    -- Arkham reloads while Rosie holds its callback.
    ok(h.run_until(function() return h.place == h.P.pit and not live(alfred(h)) end, 60), 'back in the pit\n' .. h.tail())
    h.run(3)
    local mark = h.now
    fill_bag(h, 25)
    ok(h.run_until(function() return h.place == h.P.temis end, 30), 'second trip in town\n' .. h.tail())
    h.reload(ARK, {keep_loaded = false})
    ok(h.run_until(function() return h.logged('[Rosie] completed', mark) > 0 end, 150), 'Rosie finishes the trip\n' .. h.tail())
    h.run(5)
    h.assert_clean('R8')
    eq(h.logged('Completion callback raised'), 0, "the stale Arkham callback is harmless")
    eq(#h.inventory, 0)
end)

if #failures > 0 then error(table.concat(failures, '\n')) end
print('Joint Rosie checks: ' .. checks)
