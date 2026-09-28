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
    local h = J.new({rosie = o.rosie ~= false, dirs = o.dirs or {'Batmobile', SR}, place = o.place or 'helltide'})
    h.assert_clean('load')
    h.instrument_exports()
    local g = h.mod(SR, 'silent_raven.gui').elements
    g.main_toggle:set(true)
    g.claim_trip_slider:set(o.claim_trip or 1)
    if o.rosie ~= false then
        eq(h.as('Rosie', function() return h.G.RosiePlugin.enable() end), true, 'Rosie enabled')
        h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(2)
    end
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

-- Each gate: {name, wait-line reason, setup(h) -> lift(h) or nil, host options}.
local GATES = {
    {'dead player', 'the player is dead or loading', function(h)
        h.dead = true
        return function() h.dead = false end
    end},
    {'another town', 'the player is in a town other than Temis', function() return nil end, {place = 'kurast'}},
    {'Rosie disabled', 'the town service is disabled', function(h)
        h.as('Rosie', function() return h.G.RosiePlugin.disable() end)
        return function() h.as('Rosie', function() return h.G.RosiePlugin.enable() end) end
    end},
    {'Rosie refuses external requests', 'the town service refuses external requests', function(h)
        local f = {on = true, set = {allow_external = false}}
        town_status(h, f)
        return function() f.on = false end
    end},
    {'Rosie stuck', 'the town service is stuck (probe_failure)', function(h)
        local f = {on = true, set = {stuck = true, stuck_reason = 'probe_failure'}}
        town_status(h, f)
        return function() f.on = false end
    end},
    {'Rosie paused', 'the town service is paused by Probe', function(h)
        eq(h.G.AlfredTheButlerPlugin.pause('Probe'), true, 'Rosie paused by a companion')
        return function() h.G.AlfredTheButlerPlugin.resume('Probe') end
    end},
    {'Rosie live work', 'the town service is on a trip', function(h)
        local f = {on = true, set = {trigger_tasks = true}}
        town_status(h, f)
        return function() f.on = false end
    end},
    {'WarPug busy', 'a companion is busy (war_pug_busy)', function(h)
        local st = {enabled = true, state = 'APPROACH_TABLE'}
        h.G.WarPugPlugin = {status = function() return st end}
        return function() st.state = 'IDLE' end
    end},
    {'Looter busy', 'a companion is busy (looter_busy:is_actively_looting)', function(h)
        local busy = true
        local looter = h.G.LooteerPlugin
        local real = looter.is_actively_looting
        looter.is_actively_looting = function(...) if busy then return true end return real(...) end
        return function() busy = false end
    end},
    {'HelltideRevamped at the maiden', 'HelltideRevamped is busy (AT_MAIDEN)', function(h)
        local state = 'AT_MAIDEN'
        h.G.HelltideRevampedPlugin = {getState = function() return state end}
        return function() state = 'EXPLORE_HELLTIDE' end
    end},
    -- QQT_Warpigz_v3 3.3.3: a third-party loop owning the run (Rosie defers
    -- its own trip for it too) is never teleported away for a claim.
    {'TristramLoop owns the run', 'another activity owns the run (TristramLoop, loop)', function(h)
        local st = {running = true, owns_activity = true, phase = 'loop'}
        h.G.TRISTRAM_LOOP_STATE = {status = function() return st end}
        return function() st.owns_activity = false end
    end},
    {'enemy close', 'enemies are close', function(h)
        local mob = h.actor('helltide', 'Probe_Enemy', h.pos:x() + 3, h.pos:y(), {enemy = true, health = 1e9})
        return function() h.remove_actor(mob) end
    end},
}

case('G each claim-trip gate holds the trip with one line; lifting it starts the trip', function()
    for _, gate in ipairs(GATES) do
        local name, reason, setup, o = gate[1], gate[2], gate[3], gate[4] or {}
        local h = host(o)
        local lift = setup(h)
        h.bounty_ready = true
        h.run(80)
        h.assert_clean(name)
        eq(trips(h), 0, name .. ': no claim trip\n' .. h.tail(20))
        eq(h.logged('[SilentRaven] reward ready: claim trip waits because ' .. reason), 1,
            name .. ': one wait line\n' .. h.tail(20))
        eq(h.logged('claim trip waits because'), 1, name .. ': no other wait reason')
        if lift then
            lift(h)
            ok(h.run_until(function() return trips(h) == 1 end, 5), name .. ': the trip starts once the gate lifts\n' .. h.tail(20))
        end
    end
end)

case('B1 inferred readiness (localized complete counter), the panel never opens: exactly one claim trip', function()
    local h = host()
    h.set_quests({{name = 'Bounty_Meta_Quest', objectives = {{text = 'Соберите Мрачную Благосклонность (10/10)'}}}})
    h.raven.on_interact = function() end
    ok(h.run_until(function() return h.logged('no more claim trips') > 0 end, 400), 'the trips stop\n' .. h.tail(30))
    h.run(120)
    h.assert_clean('B1')
    eq(h.reward_accepts, nil)
    eq(trips(h), 1, 'one trip for an inferred readiness\n' .. h.tail(30))
    eq(h.logged('claim trip ended without a claim'), 1)
    eq(h.logged('reward ready: no more claim trips after 1 without a claim'), 1, 'one line')
    eq(h.logged('[SilentRaven] reward ready (inferred: one probe per Temis visit)'), 1)
end)

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

-- Rosie's return-leg hand-off refused by SilentRaven's state: one line per
-- trip naming why, and no trigger_tasks queued.
local REFUSALS = {
    {'paused', 'SilentRaven is paused', function(h)
        eq(h.G.SilentRavenPlugin.pause('Probe'), true, 'SilentRaven paused by a companion')
    end},
    {'latched', 'this Temis visit is already handled', nil, function(h)
        h.mod(SR, 'silent_raven.tracker').last_zone_handled = 'Skov_Temis'
    end},
    {'pending', 'SilentRaven already has a request', nil, function(h)
        local accepted = h.G.SilentRavenPlugin.trigger_tasks('Probe', nil, function() return false, 'yield:probe' end)
        eq(accepted, true, 'a companion request queued (and held by its guard)')
    end},
}
case('H Rosie names a refused hand-off (paused, visit handled, request pending) once and queues nothing', function()
    for _, r in ipairs(REFUSALS) do
        local name, why, before, in_temis = r[1], r[2], r[3], r[4]
        local h = host({claim_trip = 0})
        h.bounty_ready = true
        if before then before(h) end
        h.inventory = h.inventory or {}
        for _ = 1, 25 do h.inventory[#h.inventory + 1] = h.gear() end
        local seen_temis, done = false, false
        done = h.run_until(function()
            if h.place == h.P.temis and not seen_temis then
                seen_temis = true
                if in_temis then in_temis(h) end
            end
            return seen_temis and h.place == h.P.helltide
        end, 200)
        ok(done, name .. ': Rosie trip to Temis and back\n' .. h.tail(30))
        h.assert_clean(name)
        eq(h.logged('[Rosie] no SilentRaven hand-off: ' .. why), 1, name .. ': one line\n' .. h.tail(30))
        eq(h.logged('[Rosie] no SilentRaven hand-off'), 1, name .. ': no other reason')
        eq(h.count(h.api_calls, function(c)
            return c.export == 'SilentRavenPlugin' and c.name == 'trigger_tasks' and c.caller == 'alfred_the_butler'
        end), 0, name .. ': no hand-off queued')
        eq(h.logged('[Rosie] waiting for SilentRaven'), 0)
    end
end)

-- QQT_Warpigz_v3 3.3.3: a third-party loop (TristramLoop, driven by
-- Worldstone) that owns the run keeps SilentRaven's own auto-fire in Temis
-- held (it would take movement away from it); the claim starts once it lets go.
case('T auto-fire in Temis holds while TristramLoop owns the run', function()
    local h = J.new({dirs = {'Batmobile', SR}, place = 'temis'})
    h.assert_clean('load')
    h.mod(SR, 'silent_raven.gui').elements.main_toggle:set(true)
    local st = {running = true, owns_activity = true, phase = 'loop'}
    h.G.TRISTRAM_LOOP_STATE = {status = function() return st end}
    h.bounty_ready = true
    h.run(70)
    h.assert_clean('held')
    eq(h.logged('[SilentRaven] claiming the Whisper reward'), 0, 'no claim while the loop owns the run\n' .. h.tail(20))
    eq(h.logged('[SilentRaven] auto-fire waiting'), 1, 'one hold line after 60 s\n' .. h.tail(20))
    ok(h.logged('activity_owner:TristramLoop') >= 1, 'the hold names the owner\n' .. h.tail(20))
    st.owns_activity = false
    ok(h.run_until(function() return h.logged('[SilentRaven] claiming the Whisper reward') == 1 end, 5),
        'the claim starts once the loop lets go\n' .. h.tail(20))
end)

if #failures > 0 then error(table.concat(failures, '\n')) end
print('SilentRaven Q8 bounds checks: ' .. checks)
