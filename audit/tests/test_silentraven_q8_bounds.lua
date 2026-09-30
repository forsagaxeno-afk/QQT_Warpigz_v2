-- QQT_Warpigz_v3 Q8 review: the claim trip's safety gates and C6 bounds, the
-- quest-state line dedup and Rosie's hand-off refusal lines. The claim trip
-- ports the player to Temis through Rosie unattended; each gate in
-- claims.lua blocker() and each bound is pinned here (the Q8 review deleted
-- them one by one with the suite green). Real plugins in the joint host.
--   G  each gate holds the trip with exactly one 'claim trip waits because'
--      line, and the trip starts once that one gate lifts.
--   B  bounds: inferred readiness costs one trip; a trip in flight is watched
--      (5 s idle grace, TRIP_BOUND 400 s) and no second trip is asked for.
--   D  the '[SilentRaven] Whisper quest ... -> <state>' line: one per change.
--   H  Rosie names each refused hand-off once and queues nothing.
-- QQT_Warpigz_v3 owner-build: no Rosie in this build. SteroidAlfred publishes
-- no raven_handoff, so SilentRaven never asks it for a claim trip and there is
-- no return-leg hand-off: G, B1, H, Z and S (claim-trip gates through Rosie,
-- Rosie's refusal lines) are dropped; D runs with the joint host's mocks.
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
    if passed then print(string.format('PASS sr-q8b: %s (%.1fs)', name, os.clock() - started))
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL sr-q8b: ' .. name .. ': ' .. tostring(err)) end
end

local SR = 'SilentRaven'
local function trips(h)
    return h.count(h.api_calls, function(c) return c.name == 'trigger_tasks_with_teleport' and c.context == SR end)
end
local function log_time(h, text)
    for _, line in ipairs(h.log) do
        if line:find(text, 1, true) then return tonumber(line:match('^(%-?[%d%.]+)')) end
    end
    return nil
end
-- Standalone Rosie + SilentRaven (claim trip after 1 min) in the helltide.
local function host(o)
    o = o or {}
    local h = J.new({rosie = false, dirs = o.dirs or {'Batmobile', SR}, place = o.place or 'helltide'})
    h.assert_clean('load')
    h.instrument_exports()
    local g = h.mod(SR, 'silent_raven.gui').elements
    g.main_toggle:set(true)
    g.claim_trip_slider:set(o.claim_trip or 1)
    h.P.helltide.helltide = true
    h.run(1)
    return h
end
-- The town service's status with fields overridden (read-only for SilentRaven).
local function town_status(h, fields)
    local api = h.G.AlfredTheButlerPlugin or h.G.PLUGIN_alfred_the_butler
    local real = api.get_status
    api.get_status = function(...)
        local s = real(...)
        if type(s) == 'table' and fields.on then for k, v in pairs(fields.set) do s[k] = v end end
        return s
    end
end

-- A town service that accepts the trip, reports live work from 2 s after the
-- request (until `idle_at` seconds, if given) and never calls back.
local function stub_town(h, idle_at)
    local stub = {live = false, calls = {}}
    local api = {
        get_status = function()
            return {enabled = true, name = 'StubTown', raven_handoff = 'stub_town', allow_external = true,
                trigger_tasks = stub.live}
        end,
        trigger_tasks_with_teleport = function(caller)
            stub.calls[#stub.calls + 1] = {t = h.now, caller = caller}
            h.at(2, function() stub.live = true end)
            if idle_at then h.at(idle_at, function() stub.live = false end) end
            return true
        end,
    }
    h.G.AlfredTheButlerPlugin, h.G.PLUGIN_alfred_the_butler = api, api
    return stub
end
-- B2: the 5 s idle grace keeps the trip, TRIP_BOUND (400 s) ends it, and no
-- second trip or wait line is produced while it is in flight. B3: a town
-- service that goes idle without a callback ends the trip then, not at 400 s.
case('B2 a trip in flight: idle grace, no second request, ended at the 400 s bound or when the service goes idle', function()
    for _, idle_at in ipairs({false, 20}) do
        local label = idle_at and 'idle at 20 s' or 'live, no callback'
        local h = host({rosie = false, dirs = {SR}})
        local stub = stub_town(h, idle_at)
        h.bounty_ready = true
        ok(h.run_until(function() return #stub.calls > 0 end, 80), label .. ': trip requested\n' .. h.tail(20))
        local t = stub.calls[1].t
        eq(stub.calls[1].caller, 'silent_raven')
        ok(h.run_until(function() return h.logged('claim trip ended without a claim') > 0 end, 420), label .. ': the trip ends\n' .. h.tail(20))
        h.assert_clean('B2 ' .. label)
        local ended = log_time(h, 'claim trip ended without a claim')
        local want = idle_at or 400
        ok(ended - t >= want and ended - t < want + 2, string.format('%s: ended at %.1f s (want %d s)', label, ended - t, want))
        eq(h.logged('claim trip ended without a claim (town service: no callback'), 1)
        eq(#stub.calls, 1, label .. ': no second request while the trip is in flight')
        eq(h.logged('claim trip waits because'), 0, label .. ': no wait line while the trip is in flight')
    end
end)

case('D the Whisper quest state line: one per change, never per check', function()
    local h = host({dirs = {SR}})
    h.set_quests({{name = 'Bounty_Meta_Quest', objectives = {{text = 'Collect Grim Favor (3/10)'}}}})
    h.run(120)
    eq(h.logged('[SilentRaven] Whisper quest Bounty_Meta_Quest: Collect Grim Favor (3/10) -> collecting'), 1, 'one line in 120 s')
    h.set_quests({{name = 'Bounty_Meta_Quest', objectives = {{text = 'Return to the Tree of Whispers'}}}})
    h.run(30)
    eq(h.logged('[SilentRaven] Whisper quest Bounty_Meta_Quest: Return to the Tree of Whispers -> ready'), 1, 'one line on the change')
    eq(h.logged('[SilentRaven] Whisper quest'), 2, 'two quest-state lines in 150 s')
    -- A flapping objective: at most one line per 10 s.
    local mark = h.now
    for i = 1, 30 do
        h.set_quests({{name = 'Bounty_Meta_Quest', objectives = {{text = 'Collect Grim Favor (' .. (i % 2 + 3) .. '/10)'}}}})
        h.run(1)
    end
    local flaps = h.logged('[SilentRaven] Whisper quest', mark)
    ok(flaps >= 2 and flaps <= 4, string.format('flapping objective: %d lines in 30 s (at most one per 10 s)', flaps))
    -- A localized objective is cut on a character boundary (valid UTF-8).
    local whispers = h.mod(SR, 'silent_raven.whispers')
    local text = 'Вернитесь к Древу Шепотов или найдите Ворона Древа в городе'
    h.set_quests({{name = 'Bounty_Meta_Quest', objectives = {{text = text}}}})
    local s = h.as(SR, function() return whispers.quest_snapshot() end)
    -- Byte 90 is the lead byte of a 2-byte letter: the cut keeps 89 bytes.
    eq(text:byte(90) >= 0xC0, true, 'the fixture cuts inside a letter')
    eq(s.detail, 'Bounty_Meta_Quest: ' .. text:sub(1, 89), 'cut before the split letter')
    local function valid_utf8(str)
        local i = 1
        while i <= #str do
            local b = str:byte(i)
            local n = b < 0x80 and 0 or (b >= 0xF0 and 3) or (b >= 0xE0 and 2) or (b >= 0xC0 and 1) or -1
            if n < 0 or i + n > #str then return false end
            for k = 1, n do
                local c = str:byte(i + k)
                if c < 0x80 or c >= 0xC0 then return false end
            end
            i = i + n + 1
        end
        return true
    end
    ok(valid_utf8(s.detail), 'the quest-state detail is valid UTF-8')
    eq(whispers.utf8_head(text, 91), text:sub(1, 91), 'a boundary cut keeps every byte')
    eq(whispers.utf8_head('abc', 90), 'abc')
end)

case('T auto-fire in Temis waits for a loop owning the run at most 60 s of readiness', function()
    local h = J.new({dirs = {'Batmobile', SR}, place = 'temis'})
    h.assert_clean('load')
    h.mod(SR, 'silent_raven.gui').elements.main_toggle:set(true)
    local st = {running = true, owns_activity = true, phase = 'town'}
    h.G.TRISTRAM_LOOP_STATE = {status = function() return st end}
    h.bounty_ready = true
    h.run(59)
    h.assert_clean('held')
    eq(h.logged('[SilentRaven] claiming the Whisper reward'), 0, 'no claim before 60 s of readiness\n' .. h.tail(20))
    eq(h.logged('[SilentRaven] reward ready in Temis but auto-fire waits: activity_owner:TristramLoop'), 1,
        'one visible hold line (RC6)\n' .. h.tail(20))
    ok(h.run_until(function() return h.logged('[SilentRaven] run finished') > 0 end, 30),
        'the claim runs at this Temis stop\n' .. h.tail(20))
    eq(h.logged('[SilentRaven] claiming the Whisper reward (auto)'), 1, 'exactly one auto claim')
    eq(h.logged('[SilentRaven] run finished: success'), 1, 'claimed\n' .. h.tail(20))
    eq(h.logged('claiming at this Temis stop'), 1, 'the bound is logged once')
end)

case('N auto-fire in Temis waits for Butler / Scavenger / a moving Navigator; our claim pauses Navigator', function()
    local movers = {
        {'butler_busy', function(h, f) h.G.Butler = {is_busy = function() return f.on end} end},
        {'scavenger_busy', function(h, f) h.G.Scavenger = {is_busy = function() return f.on end} end},
        {'navigator_busy:Butler', function(h, f) h.G.Navigator = {get_status = function()
            return {is_busy = f.on, owner = 'Butler', priority = 10} end} end},
    }
    for _, m in ipairs(movers) do
        local h = J.new({dirs = {'Batmobile', SR}, place = 'temis'})
        h.mod(SR, 'silent_raven.gui').elements.main_toggle:set(true)
        local f = {on = true}
        m[2](h, f)
        h.bounty_ready = true
        h.run(20)
        h.assert_clean(m[1])
        eq(h.logged('[SilentRaven] claiming the Whisper reward'), 0, m[1] .. ': no claim while busy\n' .. h.tail(20))
        f.on = false
        ok(h.run_until(function() return h.logged('[SilentRaven] claiming the Whisper reward') == 1 end, 5),
            m[1] .. ': the claim starts once it is idle\n' .. h.tail(20))
    end
    -- A paused Navigator (Worldstone's looting pause) does not hold the claim;
    -- the claim registers its pause condition and it holds while the claim runs.
    local h = J.new({dirs = {'Batmobile', SR}, place = 'temis'})
    h.mod(SR, 'silent_raven.gui').elements.main_toggle:set(true)
    local cond = {}
    h.G.Navigator = {get_status = function() return {is_busy = true, is_paused = true, owner = 'Worldstone'} end,
        set_pause_condition = function(name, fn) cond[name] = fn end}
    h.bounty_ready = true
    local held_while_running = false
    ok(h.run_until(function()
        local s = h.as(SR, function() return h.G.SilentRavenPlugin.get_status() end)
        if s.running and cond.SilentRaven and cond.SilentRaven() == true then held_while_running = true end
        return h.logged('[SilentRaven] run finished') > 0
    end, 60), 'the claim ran next to a paused Navigator\n' .. h.tail(20))
    ok(type(cond.SilentRaven) == 'function', 'pause condition SilentRaven registered')
    ok(held_while_running, 'Navigator is held while the claim runs')
    eq(cond.SilentRaven(), false, 'and released after it')
end)

-- QQT_Warpigz_v3 3.3.3 (auditor LOW): with a companion holding the auto-fire
-- in Temis, the checks (WarPigs status, ally-actor scan) run at the
-- ready-check rate, not on every frame.
case('P held auto-fire in Temis is checked at the ready-check rate, not per frame', function()
    local h = J.new({dirs = {'Batmobile', SR}, place = 'temis'})
    h.mod(SR, 'silent_raven.gui').elements.main_toggle:set(true)
    h.G.LooteerPlugin = {is_actively_looting = function() return true end}
    local calls = 0
    h.G.WarPigsPlugin = {status = function() calls = calls + 1; return {enabled = false} end}
    h.bounty_ready = true
    h.run(2)
    calls = 0
    h.run(10)
    -- 2 Hz each: the delegation cache, can_start and the WarPigs companion check.
    ok(calls <= 65, 'WarPigs status calls in 10 s while held: ' .. calls)
end)

-- QQT_Warpigz_v3 3.3.3 (auditor LOW): a queued request paused by its owner's
-- 'yield:' guard answer is published (get_status().yielding), so the activity
-- plugins' raven_claim_active() need not hold their Temis steps for it.
case('Y a queued request paused by a yield: guard is published as yielding', function()
    local h = J.new({dirs = {SR}, place = 'temis'})
    h.mod(SR, 'silent_raven.gui').elements.main_toggle:set(true)
    h.mod(SR, 'silent_raven.gui').elements.auto_fire_toggle:set(false)
    h.bounty_ready = true
    h.run(1)
    local answer = 'yield:looter_busy'
    local accepted = h.as(SR, function()
        return h.G.SilentRavenPlugin.trigger_tasks('Probe', function() end, function() return false, answer end)
    end)
    eq(accepted, true, 'queued')
    h.run(3)
    local s = h.as(SR, function() return h.G.SilentRavenPlugin.get_status() end)
    eq(s.pending, true, 'still queued'); eq(s.running, false, 'not started')
    eq(s.yielding, true, 'published as yielding')
    answer = nil
    h.run(1)
    s = h.as(SR, function() return h.G.SilentRavenPlugin.get_status() end)
    ok(s.yielding ~= true, 'not yielding once the request ended or resumed')
end)

-- QQT_Warpigz_v3 3.3.3 (auditor LOW): an owner's cancel (Rosie after its
-- hand-off wait) and the Enable toggle end a run through the FSM: one
-- whisper_claim event, and the visit latched once an accept was sent.
case('C cancel and disable after an accept emit the event and latch the visit', function()
    for _, how in ipairs({'cancel', 'disable'}) do
        local h = J.new({dirs = {SR}, place = 'temis'})
        local g = h.mod(SR, 'silent_raven.gui').elements
        g.main_toggle:set(true)
        g.auto_fire_toggle:set(false)
        local bus = {seq = 0, ring = {}, max = 512}
        h.G.QQT_Warpigz_events = bus
        h.bounty_ready = true
        h.deliver_reward = function() end -- the accept is sent, the cache never arrives
        h.run(1)
        eq(h.as(SR, function() return h.G.SilentRavenPlugin.trigger_tasks('Probe', function() end) end), true)
        ok(h.run_until(function()
            local s = h.as(SR, function() return h.G.SilentRavenPlugin.get_status() end)
            return s.state == 'API_CLAIMING'
        end, 60), how .. ': accept sent\n' .. h.tail(20))
        if how == 'cancel' then
            eq(h.as(SR, function() return h.G.SilentRavenPlugin.cancel('Probe') end), true)
        else
            g.main_toggle:set(false)
        end
        h.run(1)
        local claims = 0
        for i = 1, bus.seq do
            local e = bus.ring[i]
            if e and e.source == 'silentraven' and e.kind == 'whisper_claim' then claims = claims + 1 end
        end
        eq(claims, 1, how .. ': one whisper_claim event')
        local s = h.as(SR, function() return h.G.SilentRavenPlugin.get_status() end)
        eq(s.last_zone_handled, 'Skov_Temis', how .. ': the visit is latched after an accept')
    end
end)

-- QQT_Warpigz_v3 3.3.3 (auditor MED): a claim trip the town service ends
-- before any teleport is not counted against the trip limit.
case('K a claim trip ended before any teleport is not counted', function()
    local h = host({rosie = false, dirs = {SR}})
    local calls = 0
    local api = {
        get_status = function() return {enabled = true, name = 'StubTown', raven_handoff = 'stub_town', allow_external = true} end,
        trigger_tasks_with_teleport = function(caller, cb) calls = calls + 1; cb('cancelled'); return true end,
    }
    h.G.AlfredTheButlerPlugin, h.G.PLUGIN_alfred_the_butler = api, api
    h.set_quests({{name = 'Bounty_Meta_Quest', objectives = {{text = 'Соберите Мрачную Благосклонность (10/10)'}}}})
    h.run(200)
    h.assert_clean('K')
    ok(calls >= 2, 'a trip that never teleported does not use up the inferred limit (trips: ' .. calls .. ')\n' .. h.tail(20))
    ok(h.logged('no teleport, not counted') >= 1, 'logged as not counted')
end)

-- A Navigator mock that honours pause conditions (is_paused while any is true)
-- with a permanent request of `owner` / `priority`.
local function navigator(h, owner, priority)
    local nav = {cond = {}, owner = owner, priority = priority}
    local function paused()
        for _, fn in pairs(nav.cond) do if fn() == true then return true end end
        return false
    end
    nav.api = {
        get_status = function()
            return {is_busy = nav.owner ~= nil, is_paused = paused(), owner = nav.owner, priority = nav.priority}
        end,
        set_pause_condition = function(name, fn) nav.cond[name] = fn end,
    }
    h.G.Navigator = nav.api
    return nav
end

-- QQT_Warpigz_v3 0.2.8 (RC2a): Worldstone's walk (a Navigator request with no
-- priority) never holds auto-fire; once the claim runs our pause condition
-- stops it. 0.2.6/0.2.7: never claimed while the request was pending.
case('W a priority-0 Navigator request (Worldstone) does not hold; the claim pauses it', function()
    local h = J.new({dirs = {'Batmobile', SR}, place = 'temis'})
    h.mod(SR, 'silent_raven.gui').elements.main_toggle:set(true)
    local nav = navigator(h, 'Worldstone', 0)
    local t0 = h.now
    h.bounty_ready = true
    local held = false
    ok(h.run_until(function()
        local s = h.as(SR, function() return h.G.SilentRavenPlugin.get_status() end)
        if s.running and nav.cond.SilentRaven and nav.cond.SilentRaven() == true then held = true end
        return h.logged('[SilentRaven] run finished') > 0
    end, 30), 'the claim ran\n' .. h.tail(20))
    local t = log_time(h, '[SilentRaven] claiming the Whisper reward (auto)')
    ok(t ~= nil and t - t0 <= 2.5, 'claimed within 2 s (' .. tostring(t and t - t0) .. ')\n' .. h.tail(20))
    ok(held, 'Navigator is paused while the claim runs')
    eq(h.logged('[SilentRaven] run finished: success'), 1, 'success\n' .. h.tail(20))
end)

-- QQT_Warpigz_v3 0.2.8 (RC2b): a Butler that reports busy forever holds for at
-- most 180 s of this ready episode (one line), then the claim runs.
case('U a Butler stuck busy holds auto-fire at most 180 s', function()
    local h = J.new({dirs = {'Batmobile', SR}, place = 'temis'})
    h.mod(SR, 'silent_raven.gui').elements.main_toggle:set(true)
    h.G.Butler = {is_busy = function() return true end}
    h.bounty_ready = true
    h.run(170)
    eq(h.logged('[SilentRaven] claiming the Whisper reward'), 0, 'held while Butler is busy\n' .. h.tail(20))
    ok(h.run_until(function() return h.logged('[SilentRaven] run finished: success') == 1 end, 40),
        'claimed after the bound\n' .. h.tail(20))
    eq(h.logged('waited 180s for butler_busy this ready episode'), 1, 'one bound line')
    eq(h.logged('[SilentRaven] reward ready in Temis but auto-fire waits: butler_busy'), 1, 'one hold line')
end)

-- 0.2.8 review [MED]: the 180 s limit counts time actually held, not time
-- since the first sighting. A 5 s Butler sighting early in a long ready
-- episode must not switch the Butler hold off for a later, real Butler trip.
case('V a short early Butler sighting does not use up the 180 s limit', function()
    local h = J.new({dirs = {'Batmobile', SR}, place = 'temis'})
    h.mod(SR, 'silent_raven.gui').elements.main_toggle:set(true)
    local butler, looting = true, false
    h.G.Butler = {is_busy = function() return butler end}
    h.G.LooteerPlugin = {is_actively_looting = function() return looting end}
    h.bounty_ready = true
    h.run(5)
    butler, looting = false, true -- another hold for a long while
    h.run(200)
    butler, looting = true, false -- a real Butler trip
    h.run(15)
    h.assert_clean('V')
    eq(h.logged('[SilentRaven] claiming the Whisper reward'), 0, 'Butler still holds (held ~5 s of 180)\n' .. h.tail(20))
    eq(h.logged('waited 180s for butler_busy'), 0, 'the limit is not used up')
    butler = false
    ok(h.run_until(function() return h.logged('[SilentRaven] claiming the Whisper reward (auto)') == 1 end, 3),
        'the claim starts once Butler is done\n' .. h.tail(20))
end)

-- 0.2.8 review [LOW]: the reason that held longest, not the last one (a
-- teleport channel at departure), is what the outside-Temis line names.
case('L the held reason reported is the one that held longest', function()
    local h = J.new({dirs = {'Batmobile', SR}, place = 'temis'})
    h.mod(SR, 'silent_raven.gui').elements.main_toggle:set(true)
    local butler = true
    h.G.Butler = {is_busy = function() return butler end}
    h.bounty_ready = true
    h.run(20)
    butler = false
    h.casting = true
    h.run(2)
    local tracker = h.mod(SR, 'silent_raven.tracker')
    eq(tracker.visit_hold, 'butler_busy', 'the long Butler hold, not the last teleport channel')
end)

-- 0.2.8 review [MED]: a blank quest list on a loading screen does not end the
-- ready episode (the 60 s TristramLoop bound would restart at every Temis
-- arrival: 'manual now' again for Worldstone + TristramLoop).
case('F a blank quest list in Limbo keeps the ready episode', function()
    local h = J.new({dirs = {'Batmobile', SR}, place = 'helltide'})
    h.mod(SR, 'silent_raven.gui').elements.main_toggle:set(true)
    h.mod(SR, 'silent_raven.gui').elements.claim_trip_slider:set(0)
    h.G.TRISTRAM_LOOP_STATE = {status = function() return {running = true, owns_activity = true, phase = 'town'} end}
    h.bounty_ready = true
    h.run(120)
    h.place, h.pos = h.P.limbo, h.P.limbo.spawn
    h.bounty_ready = false -- the quest list reads empty while loading
    h.run(2)
    h.place, h.pos = h.P.temis, h.P.temis.spawn
    h.bounty_ready = true
    ok(h.run_until(function() return h.logged('[SilentRaven] claiming the Whisper reward (auto)') == 1 end, 40),
        'claimed during a 40 s Temis stop (ready for 120 s)\n' .. h.tail(20))
end)

-- 0.2.8 review [MED]: the 15 s channel bound is per cast. A second cast right
-- after a loading screen (the host may keep reporting the spell through Limbo)
-- gets its own 15 s.
case('K2 the channel bound restarts for a new cast after a loading screen', function()
    local h = J.new({dirs = {'Batmobile', SR}, place = 'temis'})
    h.mod(SR, 'silent_raven.gui').elements.main_toggle:set(true)
    h.bounty_ready = true
    h.casting = true
    h.run(12)
    h.place, h.pos = h.P.limbo, h.P.limbo.spawn
    h.run(2)
    h.place, h.pos = h.P.temis, h.P.temis.spawn
    h.run(10)
    h.assert_clean('K2')
    eq(h.logged('[SilentRaven] claiming the Whisper reward'), 0, 'the second cast holds too\n' .. h.tail(20))
    h.casting = false
    ok(h.run_until(function() return h.logged('[SilentRaven] claiming the Whisper reward (auto)') == 1 end, 3),
        'the claim starts once the cast ends\n' .. h.tail(20))
end)

-- 0.2.8 re-review [MED]: after a loading screen the quest is re-read before
-- auto-fire. The list reads blank in Limbo and for the first 0.6 s in Temis;
-- dd60352 auto-fired on the stale pre-teleport ready, START saw no quest and
-- latched the visit (skipped_not_ready): no claim.
local function arrive_blank(h, limbo_s)
    h.place, h.pos = h.P.limbo, h.P.limbo.spawn
    h.bounty_ready = false
    h.run(limbo_s or 2)
    h.place, h.pos = h.P.temis, h.P.temis.spawn
    h.run(0.6)
    h.bounty_ready = true
end
-- The stale window depends on where the 0.5 s ready-check clock stands at the
-- arrival, so several loading-screen lengths are tried.
local LIMBO_LENGTHS = {2.0, 2.1, 2.2, 2.3, 2.4}
case('F2 a quest list blank just after arriving in Temis: the claim still runs', function()
    for _, limbo_s in ipairs(LIMBO_LENGTHS) do
        local h = J.new({dirs = {'Batmobile', SR}, place = 'helltide'})
        h.mod(SR, 'silent_raven.gui').elements.main_toggle:set(true)
        h.mod(SR, 'silent_raven.gui').elements.claim_trip_slider:set(0)
        h.bounty_ready = true
        h.run(5)
        arrive_blank(h, limbo_s)
        ok(h.run_until(function() return h.logged('[SilentRaven] run finished: success') == 1 end, 40),
            'Limbo ' .. limbo_s .. ' s: claimed at this Temis stop\n' .. h.tail(20))
        eq(h.logged('skipped_not_ready'), 0, 'Limbo ' .. limbo_s .. ' s: no stale start\n' .. h.tail(20))
    end
end)
case('F3 the same under TristramLoop: the ready episode survives the blank arrival', function()
    for _, limbo_s in ipairs(LIMBO_LENGTHS) do
        local h = J.new({dirs = {'Batmobile', SR}, place = 'helltide'})
        h.mod(SR, 'silent_raven.gui').elements.main_toggle:set(true)
        h.mod(SR, 'silent_raven.gui').elements.claim_trip_slider:set(0)
        h.G.TRISTRAM_LOOP_STATE = {status = function() return {running = true, owns_activity = true, phase = 'town'} end}
        h.bounty_ready = true
        h.run(120)
        arrive_blank(h, limbo_s)
        ok(h.run_until(function() return h.logged('[SilentRaven] run finished: success') == 1 end, 40),
            'Limbo ' .. limbo_s .. ' s: claimed during a 40 s Temis stop (ready for 120 s)\n' .. h.tail(20))
        eq(h.logged('skipped_not_ready'), 0, 'Limbo ' .. limbo_s .. ' s: no stale start\n' .. h.tail(20))
    end
end)

-- 0.2.8 re-review [LOW]: a new ready episode clears the held reason; the next
-- outside-Temis line promises the next visit again.
case('M a new ready episode forgets the last held reason', function()
    local h = J.new({dirs = {'Batmobile', SR}, place = 'temis'})
    h.mod(SR, 'silent_raven.gui').elements.main_toggle:set(true)
    h.mod(SR, 'silent_raven.gui').elements.claim_trip_slider:set(1)
    local butler = true
    h.G.Butler = {is_busy = function() return butler end}
    h.bounty_ready = true
    h.run(5)
    butler = false
    h.place, h.pos = h.P.helltide, h.P.helltide.spawn
    h.run(3)
    eq(h.logged('the last one waited: butler_busy'), 1, 'this episode names the held visit\n' .. h.tail(20))
    h.bounty_ready = false -- the reward was claimed elsewhere
    h.run(5)
    h.bounty_ready = true -- the next reward
    h.run(3)
    h.assert_clean('M')
    eq(h.logged('the last one waited'), 1, 'not repeated for the new reward\n' .. h.tail(20))
    eq(h.logged('reward ready: claimed on the next Temis visit, or by a claim trip'), 1, 'the plain line\n' .. h.tail(20))
end)

-- 0.2.8 re-review [LOW]: a yield on a real Scavenger releases the Navigator
-- pause like Butler's (it may walk through Navigator).
case('R2 a Scavenger yield mid-claim releases the Navigator pause', function()
    local h = J.new({dirs = {'Batmobile', SR}, place = 'temis'})
    h.mod(SR, 'silent_raven.gui').elements.main_toggle:set(true)
    local nav = navigator(h, nil, 0)
    local busy = false
    h.G.Scavenger = {is_busy = function() return busy end}
    h.bounty_ready = true
    ok(h.run_until(function() return h.logged('[SilentRaven] claiming the Whisper reward (auto)') == 1 end, 5), 'started')
    h.at(0.5, function() busy = true end)
    h.at(3.0, function() busy = false end)
    local released = false
    ok(h.run_until(function()
        local s = h.as(SR, function() return h.G.SilentRavenPlugin.get_status() end)
        if busy and s.running and s.hold_reason == 'scavenger_busy' and nav.cond.SilentRaven
            and nav.cond.SilentRaven() == false then released = true end
        return h.logged('[SilentRaven] run finished') > 0
    end, 30), 'the claim finished\n' .. h.tail(20))
    ok(released, 'Navigator was released during the Scavenger yield')
end)

-- QQT_Warpigz_v3 0.2.9: Rosie's Butler stand-in (`_rosie=true`) mirrors
-- Rosie's own trip: it holds neither auto-fire nor the claim trip; a real
-- Butler still holds both.
case('B3 Rosie\'s Butler stand-in never holds; a real Butler does', function()
    local h = J.new({dirs = {'Batmobile', SR}, place = 'temis'})
    h.mod(SR, 'silent_raven.gui').elements.main_toggle:set(true)
    h.G.Butler = {_rosie = true, is_busy = function() return true end}
    h.bounty_ready = true
    ok(h.run_until(function() return h.logged('[SilentRaven] run finished: success') == 1 end, 20),
        'the claim ran next to a busy stand-in\n' .. h.tail(20))
    eq(h.logged('butler_busy'), 0, 'never held for the stand-in')
    local h2 = host({rosie = false, dirs = {SR}})
    local stub = stub_town(h2)
    h2.G.Butler = {_rosie = true, is_busy = function() return true end}
    h2.bounty_ready = true
    ok(h2.run_until(function() return #stub.calls == 1 end, 80), 'the claim trip is not held by the stand-in\n' .. h2.tail(20))
    local h3 = J.new({dirs = {'Batmobile', SR}, place = 'temis'})
    h3.mod(SR, 'silent_raven.gui').elements.main_toggle:set(true)
    h3.G.Butler = {is_busy = function() return true end}
    h3.bounty_ready = true
    h3.run(10)
    eq(h3.logged('[SilentRaven] claiming the Whisper reward'), 0, 'a real Butler still holds')
end)

-- QQT_Warpigz_v3 0.2.8 (RC3): a Looter blip during the claim keeps Navigator
-- paused (only a Butler / town-priority Navigator yield releases it), so the
-- loop's walk never resumes and holds the yield until its 120 s timeout.
case('R a Looter blip mid-claim keeps Navigator paused; the claim finishes', function()
    local h = J.new({dirs = {'Batmobile', SR}, place = 'temis'})
    h.mod(SR, 'silent_raven.gui').elements.main_toggle:set(true)
    local nav = navigator(h, nil, 0)
    local looting = false
    h.G.LooteerPlugin = {is_actively_looting = function() return looting end}
    h.bounty_ready = true
    ok(h.run_until(function() return h.logged('[SilentRaven] claiming the Whisper reward (auto)') == 1 end, 5), 'started')
    local t0 = h.now
    h.at(0.5, function() nav.owner = 'Worldstone' end)
    h.at(1.0, function() looting = true end)
    h.at(2.0, function() looting = false end)
    local held_in_blip, blip_seen = true, false
    ok(h.run_until(function()
        if looting then
            blip_seen = true
            if not (nav.cond.SilentRaven and nav.cond.SilentRaven() == true) then held_in_blip = false end
        end
        return h.logged('[SilentRaven] run finished') > 0
    end, 30), 'the claim finished\n' .. h.tail(20))
    ok(blip_seen, 'the blip happened during the claim')
    ok(held_in_blip, 'Navigator stayed paused during the Looter yield')
    eq(h.logged('[SilentRaven] run finished: success'), 1, 'success\n' .. h.tail(20))
    eq(h.logged('yield_timeout'), 0, 'no yield timeout')
    ok(h.now - t0 < 12, 'within 12 s')
end)

-- QQT_Warpigz_v3 0.2.8 (Undercity storm): never start a claim walk while the
-- player channels a teleport (WonderCity's cast to Kurast); bounded to 15 s.
case('X a teleport channel holds a new claim; a channel stuck past 15 s does not', function()
    local h = J.new({dirs = {'Batmobile', SR}, place = 'temis'})
    h.mod(SR, 'silent_raven.gui').elements.main_toggle:set(true)
    h.casting = true
    h.bounty_ready = true
    h.run(5)
    eq(h.logged('[SilentRaven] claiming the Whisper reward'), 0, 'no claim during the channel\n' .. h.tail(20))
    eq(h.logged('[SilentRaven] reward ready in Temis but auto-fire waits: teleport_channel'), 1, 'one hold line')
    h.casting = false
    ok(h.run_until(function() return h.logged('[SilentRaven] claiming the Whisper reward (auto)') == 1 end, 3),
        'the claim starts once the channel ends\n' .. h.tail(20))
    local h2 = J.new({dirs = {'Batmobile', SR}, place = 'temis'})
    h2.mod(SR, 'silent_raven.gui').elements.main_toggle:set(true)
    h2.casting = true
    h2.bounty_ready = true
    h2.run(14)
    eq(h2.logged('[SilentRaven] claiming the Whisper reward'), 0, 'held up to 15 s')
    ok(h2.run_until(function() return h2.logged('[SilentRaven] claiming the Whisper reward (auto)') == 1 end, 4),
        'a channel stuck past 15 s no longer holds\n' .. h2.tail(20))
end)

-- QQT_Warpigz_v3 0.2.8 (RC5): a claim trip whose callback arrives after the
-- quest left does not count against the next ready episode (on an inferred
-- client the next reward got no claim trip at all).
case('E a late trip callback does not starve the next ready episode', function()
    local h = host({rosie = false, dirs = {SR}})
    local ST = {live = false, done = false}
    local calls = {}
    local api = {
        get_status = function()
            return {enabled = true, name = 'StubTown', raven_handoff = 'stub_town', allow_external = true,
                trigger_tasks = ST.live, teleport_done = ST.done}
        end,
        trigger_tasks_with_teleport = function(caller, cb)
            calls[#calls + 1] = h.now
            ST.live, ST.done = true, true
            h.at(3, function() h.set_quests({}) end) -- the claim turned the quest in
            h.at(8, function() ST.live = false; cb('failed') end)
            return true
        end,
    }
    h.G.AlfredTheButlerPlugin, h.G.PLUGIN_alfred_the_butler = api, api
    local RU = {{name = 'Bounty_Meta_Quest', objectives = {{text = 'Соберите Мрачную Благосклонность (10/10)'}}}}
    h.set_quests(RU)
    ok(h.run_until(function() return #calls == 1 end, 90), 'first trip\n' .. h.tail(20))
    ok(h.run_until(function() return h.logged('claim trip ended without a claim') == 1 end, 20), 'first trip ended')
    h.run(5)
    h.set_quests(RU) -- the next reward
    ok(h.run_until(function() return #calls == 2 end, 90), 'a trip for the next reward\n' .. h.tail(20))
    eq(h.logged('no more claim trips'), 0, 'the next episode is not starved')
end)

if #failures > 0 then error(table.concat(failures, '\n')) end
print('SilentRaven Q8 bounds checks: ' .. checks)
