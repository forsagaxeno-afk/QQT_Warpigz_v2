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
-- QQT_Warpigz_v3 owner-build: no Rosie in this build (SteroidAlfred has no
-- SilentRaven hand-off and no claim trips). W1, W2, S1, S1b, S2, S3, the
-- standalone-HR half of L and the bag-trip half of P exercised Rosie and are
-- dropped; R, the WarPigs halves of L and the Pit-obelisk half of P run with
-- the joint host's Alfred/Looter mocks.
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
    return h
end
-- The night setup: WarPigs + WarPug + all activity plugins, a War Plan
-- Helltide, the player in the active helltide.
local function warpigs_helltide(o)
    o = o or {}
    local h = host({rosie = false, place = 'helltide', claim_trip = o.claim_trip})
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


-- The meta quest with a complete counter (no English turn-in text).
local function complete_counter(h, text, fields)
    local objective = {text = text}
    for k, v in pairs(fields or {}) do objective[k] = v end
    h.set_quests({{name = 'Bounty_Meta_Quest', objectives = {objective}}})
    h.raven.on_interact = function() h.panel = true end
    local deliver = h.deliver_reward
    h.deliver_reward = function(i) deliver(i); h.set_quests({}) end
end


case('R readiness: complete counter or host progress fields, any language; incomplete stays collecting', function()
    local h = host({rosie = false, dirs = {SR}, place = 'helltide'})
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
    local t = host({rosie = false, place = 'temis'})
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
case('P War Plan Pit under WarPigs: the Pit obelisk claims a ready reward in Temis', function()
    local h = host({rosie = false, place = 'temis'})
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
end)

if #failures > 0 then error(table.concat(failures, '\n')) end
print('SilentRaven Q8 checks: ' .. checks)
