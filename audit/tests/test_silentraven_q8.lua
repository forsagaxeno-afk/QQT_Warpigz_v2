-- QQT_Warpigz_v3 Q8: "SilentRaven took zero Whisper rewards all night"
-- (live, v3.0.0: WarPigs + HelltideRevamped + Rosie). Real plugins in the
-- joint host (joint_host.lua with opts.rosie).
--   W1 WarPigs + HR (War Plan Helltide), bags full: the Rosie trip to Temis
--      hands the ready reward over to SilentRaven although WarPigs manages
--      Whispers (it delegates while its own request and teleports are idle).
--      Pre-fix: managed SilentRaven -> Rosie skipped it silently, WarPigs
--      offered its Whisper slot only between activities: nothing claimed.
--   W2 WarPigs + HR, no bag-full trip: a claim trip after the set delay.
--   S1 standalone HR + Rosie, no bag-full trip: a claim trip claims; HR kept.
--   S2 the claim trip is bounded (C6): a reward that cannot be claimed costs
--      at most two trips, then one line; never from a Pit / dungeon world.
--   S3 standalone Reaper + Rosie in the lair, the meta quest showing a
--      complete counter (Grim Favor 10/10): claimed on the lair trip.
--   R  readiness: complete counter / host progress fields, any language.
--   L  one deduplicated line per decision; WarPigs' own Whisper request
--      ends its delegation (review: QQT_Warpigz_v3 Q8).
--   P  War Plan Pit under WarPigs: a Temis stop of the activity (the Pit
--      obelisk, Arkham's own bag trip) claims a ready reward (review).
-- Claim-trip gates and bounds: test_silentraven_q8_bounds.lua.
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
    if passed then print(string.format('PASS sr-q8: %s (%.1fs)', name, os.clock() - started))
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL sr-q8: ' .. name .. ': ' .. tostring(err)) end
end

local WP, SR, HR, RP = 'WarPigs', 'SilentRaven', 'HelltideRevamped', 'Reaper'
local HELLTIDE_Q = 'WarPlans_QST_Helltide_TorturedGifts'
local function sr_gui(h) return h.mod(SR, 'silent_raven.gui').elements end
local function raven(h) return h.as(SR, function() return h.G.SilentRavenPlugin.get_status() end) end
local function first(list, pred)
    for _, rec in ipairs(list) do if pred(rec) then return rec end end
    return nil
end
local function live(s)
    return s.trigger_tasks == true or s.external_trigger == true or s.pending == true or s.running == true
        or (s.teleport == true and s.teleport_done ~= true and s.teleport_failed ~= true)
end
local function alfred(h) return h.as(SR, function() return h.G.AlfredTheButlerPlugin.get_status() end) end
local function hr_on(h) return h.as(WP, function() return h.G.HelltideRevampedPlugin.status().enabled end) == true end
local function fill_bag(h, n)
    h.inventory = h.inventory or {}
    for _ = 1, n or 25 do h.inventory[#h.inventory + 1] = h.gear() end
end
-- Rosie on, SilentRaven on; `claim_trip` minutes (nil keeps the default 5).
local function host(o)
    local h = J.new(o)
    h.assert_clean('load')
    h.instrument_exports()
    sr_gui(h).main_toggle:set(true)
    if o.claim_trip and sr_gui(h).claim_trip_slider then sr_gui(h).claim_trip_slider:set(o.claim_trip) end
    eq(h.as('Rosie', function() return h.G.RosiePlugin.enable() end), true, 'Rosie enabled')
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(2)
    return h
end
-- The night setup: WarPigs + WarPug + all activity plugins, a War Plan
-- Helltide, the player in the active helltide.
local function warpigs_helltide(o)
    o = o or {}
    local h = host({rosie = true, place = 'helltide', claim_trip = o.claim_trip})
    h.P.helltide.helltide = true
    h.mod(WP, 'gui').elements.main_toggle:set(true)
    h.set_quests({HELLTIDE_Q})
    ok(h.run_until(function() return hr_on(h) end, 20), 'WarPigs runs HelltideRevamped\n' .. h.tail())
    h.run(3)
    eq(raven(h).managed_by, 'WarPigs', 'WarPigs manages Whispers (its default)')
    h.bounty_ready = true
    return h
end
-- Runs until the player was in Temis and is back at `place`; records the
-- SilentRaven run window.
local function round_trip(h, place, seconds, each)
    local w, in_temis = {}, false
    local done = h.run_until(function()
        local s = raven(h)
        if s.running then w.first = w.first or h.now; w.last = h.now end
        if h.place == h.P.temis then in_temis = true end
        return in_temis and h.place == h.P[place] and not live(alfred(h))
    end, seconds or 200, each)
    w.done = done
    return w
end

case('W1 WarPigs + HR War Plan Helltide, bags full: the Rosie trip hands the reward over although WarPigs manages Whispers', function()
    local h = warpigs_helltide()
    local mark = h.now
    fill_bag(h, 25)
    local dropped = false
    -- Review (M09): Rosie's live trip that queued the hand-off is SilentRaven's
    -- own (raven_handoff), so the walk's stall recovery (companions 'run')
    -- stays clear while SilentRaven walks to the Raven.
    local coordination, tracker = h.mod(SR, 'silent_raven.coordination'), h.mod(SR, 'silent_raven.tracker')
    local walk_samples, walk_held = 0, {}
    local w = round_trip(h, 'helltide', 200, function()
        if tracker.running and tracker.state == 'WALK_NPC' then
            walk_samples = walk_samples + 1
            local clear, why = h.as(SR, function() return coordination.companions('run', h.now) end)
            if not clear then walk_held[#walk_held + 1] = tostring(why) end
        end
    end)
    ok(w.done, 'Rosie trip to Temis and back into the helltide\n' .. h.tail(40))
    ok(walk_samples > 0, 'SilentRaven walked to the Raven')
    eq(#walk_held, 0, 'companions(run) clear during the hand-off walk: ' .. table.concat(walk_held, ','))
    h.run(3, function() if not hr_on(h) then dropped = true end end)
    h.assert_clean('W1')
    eq(h.reward_accepts, 1, 'the Whisper reward is claimed on the trip\n' .. h.tail(40))
    eq(raven(h).last_result, 'success'); eq(raven(h).last_reason, 'external:alfred_the_butler', 'through the hand-off')
    eq(h.logged('[Rosie] waiting for SilentRaven'), 1, 'one hand-off')
    eq(h.logged('SilentRaven hand-off refused'), 0)
    local back = first(h.arrivals, function(a) return a.t > mark and a.place == 'helltide' end)
    ok(back and w.last and w.last < back.t, 'claimed before the portal back into the helltide')
    eq(dropped, false, 'HelltideRevamped kept'); ok(hr_on(h), 'HR still on')
    eq(h.logged('[WarPigs:Whispers] visit'), 0, "WarPigs' own bridge did not run a request")
    -- One decision line each.
    eq(h.count(h.log, function(l) return l:sub(-26) == '[SilentRaven] reward ready' end), 1, 'reward ready: one line')
    eq(h.logged('reward ready: claimed on the next Temis visit, or by a claim trip in 300s'), 1, 'why it waits: one line')
    eq(h.logged('[SilentRaven] claiming the Whisper reward (external:alfred_the_butler)'), 1)
    eq(h.logged('run finished: success (external:alfred_the_butler)'), 1)
    ok(h.logged('claimed Collection of Helms') == 1, 'the claimed cache is named')
end)

case('W2 WarPigs + HR, no bag-full trip: a claim trip after the delay claims, HR kept', function()
    local h = warpigs_helltide({claim_trip = 1})
    local mark = h.now
    local w = round_trip(h, 'helltide', 150)
    ok(w.done, 'claim trip to Temis and back\n' .. h.tail(40))
    h.run(3)
    h.assert_clean('W2')
    eq(h.reward_accepts, 1, 'claimed\n' .. h.tail(40))
    local req = first(h.api_calls, function(c) return c.t > mark and c.name == 'trigger_tasks_with_teleport' end)
    eq(req and req.context, SR, 'SilentRaven asked the town service for the trip')
    ok(req.t - mark >= 55, string.format('not before the delay (%.0fs)', req.t - mark))
    eq(h.logged('claim trip requested'), 1); eq(h.logged('claim trip finished: the reward was claimed'), 1)
    ok(hr_on(h), 'HR kept'); eq(h.place, h.P.helltide)
    h.run(90)
    eq(h.count(h.api_calls, function(c) return c.name == 'trigger_tasks_with_teleport' and c.context == SR end), 1,
        'no further claim trip once claimed')
end)

local function standalone_hr(o)
    local h = host({rosie = true, dirs = {'Batmobile', HR, SR}, place = 'helltide', claim_trip = o.claim_trip})
    h.P.helltide.helltide = true
    h.mod(HR, 'gui').elements.main_toggle:set(true)
    h.run(3)
    return h
end

case('S1 standalone HR + Rosie, no bag-full trip: a claim trip claims and HR farms on', function()
    local h = standalone_hr({claim_trip = 1})
    h.bounty_ready = true
    local mark = h.now
    local w = round_trip(h, 'helltide', 150)
    ok(w.done, 'claim trip\n' .. h.tail(40))
    h.run(10)
    h.assert_clean('S1')
    eq(h.reward_accepts, 1, 'claimed\n' .. h.tail(40)); eq(raven(h).last_result, 'success')
    local back = first(h.arrivals, function(a) return a.t > mark and a.place == 'helltide' end)
    eq(back and back.why, 'town_portal', 'back through the town portal')
    ok(first(h.bm_calls, function(c) return c.context == HR and c.t > back.t end) ~= nil, 'HelltideRevamped drives again')
    eq(h.logged('[Rosie] completed'), 1, 'the trip completes')
end)

case('S2 claim trips are bounded: an unclaimable reward costs at most two trips, one line; never from a Pit', function()
    local h = standalone_hr({claim_trip = 1})
    h.bounty_ready = true
    h.raven.on_interact = function() end        -- the reward panel never opens
    ok(h.run_until(function() return h.logged('no more claim trips') > 0 end, 500), 'the trips stop\n' .. h.tail(40))
    h.run(150)
    h.assert_clean('S2')
    eq(h.reward_accepts, nil)
    local trips = h.count(h.api_calls, function(c) return c.name == 'trigger_tasks_with_teleport' and c.context == SR end)
    eq(trips, 2, 'two claim trips, then none\n' .. h.tail(40))
    eq(h.logged('claim trip ended without a claim'), 2)
    eq(h.logged('no more claim trips after 2'), 1, 'one line')
    -- Review (C6): the second trip waits a full interval after the first ended.
    local ended, second
    for _, l in ipairs(h.log) do
        if not ended and l:find('claim trip ended without a claim', 1, true) then ended = tonumber(l:match('^(%-?[%d%.]+)')) end
    end
    for _, c in ipairs(h.api_calls) do
        if c.name == 'trigger_tasks_with_teleport' and c.context == SR and ended and c.t > ended then second = second or c.t end
    end
    ok(ended and second and second - ended >= 60, string.format('second trip %.1f s after the first ended (>= 60)',
        (second or 0) - (ended or 0)))
    eq(h.place, h.P.helltide, 'farming in the helltide')
    -- A Pit world is never left for a claim trip.
    local p = host({rosie = true, dirs = {SR}, place = 'pit', claim_trip = 1})
    p.bounty_ready = true
    p.run(150)
    p.assert_clean('S2 pit')
    eq(p.count(p.api_calls, function(c) return c.name == 'trigger_tasks_with_teleport' end), 0, 'no trip from the Pit')
    eq(p.logged('claim trip waits because the player is not in the open world (PIT_Joint_Floor)'), 1, 'one line in 150 s')
end)

-- The meta quest with a complete counter (no English turn-in text).
local function complete_counter(h, text, fields)
    local objective = {text = text}
    for k, v in pairs(fields or {}) do objective[k] = v end
    h.set_quests({{name = 'Bounty_Meta_Quest', objectives = {objective}}})
    h.raven.on_interact = function() h.panel = true end
    local deliver = h.deliver_reward
    h.deliver_reward = function(i) deliver(i); h.set_quests({}) end
end

case('S3 standalone Reaper + Rosie in the lair, Grim Favor 10/10: claimed on the lair trip, back into the lair', function()
    local h = host({rosie = true, dirs = {'Batmobile', RP, SR}, place = 'temis'})
    h.setup_lair()
    h.keys_items = {{get_sno_id = function() return 2558255 end, get_acd = function() return 777 end,
        get_stack_count = function() return 5 end}}
    local g = h.mod(RP, 'gui').elements
    g.boss_enabled.andariel:set(true)
    g.main_toggle:set(true)
    ok(h.run_until(function() return h.place == h.P.lair end, 30), 'Reaper reached the lair\n' .. h.tail())
    h.run(2)
    complete_counter(h, 'Collect Grim Favor (10/10)')
    h.run(2)
    eq(raven(h).ready, true, 'a complete counter is ready')
    local mark = h.now
    fill_bag(h, 25)
    local w = round_trip(h, 'lair', 200)
    ok(w.done, 'lair trip\n' .. h.tail(40))
    h.run(2)
    h.assert_clean('S3')
    eq(h.reward_accepts, 1, 'claimed on the trip\n' .. h.tail(40))
    eq(raven(h).last_reason, 'external:alfred_the_butler')
    local back = first(h.arrivals, function(a) return a.t > mark and a.place == 'lair' end)
    ok(back and w.last < back.t, 'claimed before the portal back into the lair')
    eq(h.count(h.api_calls, function(c) return c.name == 'trigger_tasks_with_teleport' and c.context == SR end), 0,
        'no claim trip from a lair')
end)

case('R readiness: complete counter or host progress fields, any language; incomplete stays collecting', function()
    local h = host({rosie = true, dirs = {SR}, place = 'helltide'})
    local whispers = h.mod(SR, 'silent_raven.whispers')
    local function snap(text, fields)
        complete_counter(h, text, fields)
        return h.as(SR, function() return whispers.quest_snapshot() end)
    end
    local s = snap('Collect Grim Favor (10/10)')
    eq(s.ready, true); eq(s.collecting, false); eq(s.inferred, true, 'one bounded probe per visit')
    s = snap('Соберите Мрачную Благосклонность (10/10)')
    eq(s.ready, true, 'localized complete counter')
    s = snap('Collect Grim Favor (7/10)')
    eq(s.ready, false); eq(s.collecting, true)
    s = snap('Collect Grim Favor', {has_progress = true, progress_ratio = 1})
    eq(s.ready, true, 'progress_ratio 1'); eq(s.collecting, false)
    s = snap('Collect Grim Favor', {has_progress = true, progress_ratio = 0.3})
    eq(s.ready, false, 'progress_ratio 0.3'); eq(s.collecting, true)
    s = snap('Collect Grim Favor')
    eq(s.ready, false, 'the English collect phrase without a counter keeps the old reading')
    -- Review: a ratio of 0 is no evidence (a turn-in 'go to' objective may
    -- report 0/1); a partial ratio is collecting in any language.
    s = snap('Вернитесь к Древу Шепотов или найдите Ворона Древа в городе', {has_progress = true, progress_ratio = 0})
    eq(s.ready, true, 'localized turn-in, ratio 0: ready'); eq(s.inferred, true); eq(s.collecting, false)
    s = snap('Return to the Tree of Whispers', {has_progress = true, progress_ratio = 0})
    eq(s.ready, true, 'English turn-in, ratio 0'); eq(s.inferred, false); eq(s.collecting, false, 'not collecting')
    s = snap('Соберите Мрачную Благосклонность', {has_progress = true, progress_ratio = 0.3})
    eq(s.ready, false, 'localized collect, ratio 0.3'); eq(s.collecting, true)
end)

case('L decisions: WarPigs delegation off -> one reason line; auto-fire off -> one reason line', function()
    -- WarPigs' Whisper option off: SilentRaven is unmanaged; auto-fire off.
    local h = standalone_hr({claim_trip = 1})
    sr_gui(h).auto_fire_toggle:set(false)
    h.bounty_ready = true
    fill_bag(h, 25)
    ok(round_trip(h, 'helltide', 200).done, 'bag trip\n' .. h.tail(30))
    h.run(120)
    h.assert_clean('L')
    eq(h.reward_accepts, nil, 'auto-fire off: nothing claimed')
    eq(h.logged('reward ready but skipped because SilentRaven auto-fire is off'), 1, 'one line')
    eq(h.logged('[Rosie] no SilentRaven hand-off: SilentRaven auto-fire is off'), 1, 'Rosie says why, once per trip')
    eq(h.count(h.api_calls, function(c) return c.context == SR and c.name == 'trigger_tasks_with_teleport' end), 0)
    -- WarPigs status: delegation while idle, none while its own request runs.
    local w = warpigs_helltide()
    local st = w.as(WP, function() return w.G.WarPigsPlugin.status() end)
    eq(st.manages_whispers, true); eq(st.whisper_handoff, true, 'delegates while its bridge and teleports are idle')
    eq(raven(w).handoff, true)
    w.mod(WP, 'gui').elements.manage_whispers:set(false)
    w.run(2)
    st = w.as(WP, function() return w.G.WarPigsPlugin.status() end)
    eq(st.whisper_handoff, false); eq(raven(w).managed_by, nil, 'released'); eq(raven(w).handoff, true, 'auto-fire rule')
    -- Review: WarPigs' own Whisper request (between activities, in Temis)
    -- ends its delegation: no hand-off, no queue from Rosie's caller.
    local t = host({rosie = true, place = 'temis'})
    t.mod(WP, 'gui').elements.main_toggle:set(true)
    t.bounty_ready = true
    local coordination = t.mod(SR, 'silent_raven.coordination')
    local seen = nil
    ok(t.run_until(function()
        local s = raven(t)
        if s.owner == WP and (s.running or s.pending) then
            local wp = t.as(WP, function() return t.G.WarPigsPlugin.status() end)
            seen = {wp = wp, sr = s,
                can = {t.as(SR, function() return coordination.can_start('alfred_the_butler') end)},
                delegated = t.as(SR, function() return coordination.delegated('alfred_the_butler') end)}
            return true
        end
        return false
    end, 60), "WarPigs' own Whisper request runs\n" .. t.tail(30))
    eq(seen.wp.manages_whispers, true)
    eq(seen.wp.whisper_handoff, false, 'no delegation while its own request runs')
    local sr = nil
    t.run_until(function()
        local s = raven(t)
        if s.owner == WP and s.running and s.handoff == false then sr = s end
        return sr ~= nil or t.reward_accepts == 1
    end, 5)
    ok(sr ~= nil, 'SilentRaven reports no hand-off during the WarPigs request')
    eq(sr.handoff_reason, 'WarPigs manages Whispers and does not delegate right now (its own Temis check or teleport is under way)')
    eq(seen.can[1], false, 'can_start refuses the town caller'); eq(seen.can[2], 'reserved_by_war_pigs')
    eq(seen.delegated, false, 'the town caller is not delegated')
    ok(t.run_until(function() return t.reward_accepts == 1 end, 60), "WarPigs' request claims\n" .. t.tail(30))
    t.assert_clean('L WarPigs request')
    eq(raven(t).last_reason, 'external:WarPigs')
    eq(t.logged('claiming the Whisper reward (delegated)'), 0, 'no own claim between activities')
end)

-- Review (Q8): under WarPigs a Temis stop of an activity walked past a ready
-- reward (WarPigs offers its own Whisper slot only between activities, and
-- Rosie hands off only on a with-teleport return leg).
case('P War Plan Pit under WarPigs: the Pit obelisk and Arkham\'s own bag trip claim a ready reward in Temis', function()
    local h = host({rosie = true, place = 'temis'})
    h.pos = h.v(2533, -443)
    h.bounty_ready = true
    h.mod(WP, 'gui').elements.main_toggle:set(true)
    h.mod('WarPug', 'gui').elements.main_toggle:set(true)
    h.set_quests({'WarPlans_QST_ThePit'})
    -- A Looter burst during the delegated walk: SilentRaven yields like auto-fire.
    local tracker, looter = h.mod(SR, 'silent_raven.tracker'), h.G.LooteerPlugin
    local real_active, burst_until, burst_moves = looter.is_actively_looting, nil, 0
    looter.is_actively_looting = function(...)
        if burst_until and h.now < burst_until then return true end
        return real_active(...)
    end
    ok(h.run_until(function() return h.place == h.P.pit end, 90, function()
        if not burst_until and tracker.running and tracker.state == 'WALK_NPC' then burst_until = h.now + 3 end
        if burst_until and h.now < burst_until and h.now > burst_until - 2.5 then
            burst_moves = burst_moves + h.count(h.moves, function(m) return m.context == SR and m.t == h.now end)
        end
    end), 'Pit entered\n' .. h.tail(30))
    h.assert_clean('P obelisk')
    ok(burst_until ~= nil, 'the delegated claim walked to the Raven')
    eq(burst_moves, 0, 'no SilentRaven movement while the Looter is busy')
    eq(h.reward_accepts, 1, 'claimed before the Pit\n' .. h.tail(30))
    eq(raven(h).managed_by, WP)
    eq(raven(h).last_reason, 'delegated')
    eq(h.logged('[SilentRaven] claiming the Whisper reward (delegated)'), 1)
    eq(h.logged('[WarPigs:Whispers] visit'), 0, "WarPigs' own bridge did not run a request")
    -- Arkham's own bag trip (trigger_tasks: no Rosie return leg).
    local b = host({rosie = true, place = 'pit'})
    b.mod(WP, 'gui').elements.main_toggle:set(true)
    b.mod('WarPug', 'gui').elements.main_toggle:set(true)
    b.set_quests({'WarPlans_QST_ThePit'})
    b.mod('Rosie', 'rosie.private.town.gui').elements.use_keybind:set(true)
    b.run(10)
    b.bounty_ready = true
    b.run(2)
    local mark = b.now
    fill_bag(b, 25)
    local w = round_trip(b, 'pit', 120)
    ok(w.done, 'bag trip to Temis and back into the Pit\n' .. b.tail(30))
    b.assert_clean('P bag trip')
    local req = first(b.api_calls, function(c) return c.t >= mark and c.name == 'trigger_tasks' and c.context == 'ArkhamAsylum' end)
    ok(req ~= nil, 'Arkham asked the town service for its trip')
    eq(b.reward_accepts, 1, 'claimed in Temis\n' .. b.tail(30))
    eq(raven(b).last_reason, 'delegated')
    local back = first(b.arrivals, function(a) return a.t > mark and a.place == 'pit' end)
    ok(back and w.last and w.last < back.t, 'claimed before the portal back into the Pit')
end)

if #failures > 0 then error(table.concat(failures, '\n')) end
print('SilentRaven Q8 checks: ' .. checks)
