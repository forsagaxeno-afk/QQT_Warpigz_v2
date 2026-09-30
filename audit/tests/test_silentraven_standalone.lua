-- QQT_Warpigz_v3: SilentRaven in STANDALONE farming (no WarPigs/WarPug): the
-- user enables one activity plugin + Rosie + SilentRaven. Real plugins in the
-- joint host (joint_host.lua with opts.rosie).
--   S1 a Rosie trip to Temis hands off to SilentRaven once, before the return
--      portal (auto-fire alone held on 'alfred_busy' for the whole trip, and
--      Rosie took the portal back with the reward still ready). The wait is
--      not Rosie service time. No hand-off with auto-fire off or no reward.
--   S2 Arkham, S3 Reaper, S4 WonderCity, S5 Helltide defer their Temis steps
--      (walk/obelisk, boss teleport, home-town teleport, Helltide teleport)
--      while a SilentRaven claim runs: one movement owner at a time.
-- QQT_Warpigz_v3 owner-build: no Rosie in this build (SteroidAlfred has no
-- SilentRaven hand-off): S1 is dropped; S2-S5 run with the joint host's
-- Alfred/Looter mocks.
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
    if passed then print(string.format('PASS sr-standalone: %s (%.1fs)', name, os.clock() - started))
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL sr-standalone: ' .. name .. ': ' .. tostring(err)) end
end

local function raven(h) return h.as('SilentRaven', function() return h.G.SilentRavenPlugin.get_status() end) end
local function host(o)
    local h = J.new(o)
    h.instrument_exports()
    h.mod('SilentRaven', 'silent_raven.gui').elements.main_toggle:set(true)
    h.bounty_ready = true
    return h
end
-- Runs `seconds`; returns the first and last frame SilentRaven reported a
-- running claim and the time its result appeared.
local function watch(h, seconds, until_fn)
    local w = {}
    local each = function()
        local s = raven(h)
        if s.running then w.first = w.first or h.now; w.last = h.now end
        if not w.done and s.last_result then w.done, w.result, w.reason = h.now, s.last_result, s.last_reason end
        if w.on_frame then w.on_frame(s) end
    end
    w.run = function(n, pred)
        if pred then return h.run_until(pred, n, each) end
        h.run(n, each)
    end
    return w
end
-- S2: Arkham at the Temis obelisk when SilentRaven auto-fires.
case('S2 Arkham defers its obelisk walk and interactions while SilentRaven claims', function()
    local h = host({rosie = false, dirs = {'ArkhamAsylum', 'Batmobile', 'SilentRaven'}, place = 'temis'})
    h.pos = h.v(2533, -443)
    h.mod('ArkhamAsylum', 'gui').elements.main_toggle:set(true)
    local w = watch(h)
    w.run(45)
    h.assert_clean('S2')
    eq(w.result, 'success'); eq(w.reason, 'auto'); eq(h.reward_accepts, 1)
    local during = h.count(h.moves, function(m) return m.context == 'ArkhamAsylum' and m.t > w.first + 0.15 and m.t <= w.last end)
    eq(during, 0, 'no Arkham movement while SilentRaven claims')
    eq(h.count(h.interactions, function(i) return i.context == 'ArkhamAsylum' and i.t >= w.first and i.t <= w.last end), 0,
        'no Arkham obelisk/portal interaction while SilentRaven claims')
    eq(h.pit_opens, 1, 'the pit opens after the claim')
end)

-- S3-S5: the teleport out of Temis waits for the claim.
local function first_after(list, context)
    for _, rec in ipairs(list) do if rec.context == context then return rec.t end end
    return nil
end
case('S3 Reaper waits with its boss teleport until SilentRaven finished', function()
    local h = host({rosie = false, dirs = {'Batmobile', 'Reaper', 'SilentRaven'}, place = 'temis'})
    h.setup_lair()
    h.keys_items = {{get_sno_id = function() return 2558255 end, get_acd = function() return 777 end,
        get_stack_count = function() return 5 end}}
    local g = h.mod('Reaper', 'gui').elements
    g.boss_enabled.andariel:set(true)
    g.main_toggle:set(true)
    local w = watch(h)
    w.run(20)
    h.assert_clean('S3')
    eq(w.result, 'success'); eq(h.reward_accepts, 1)
    local tp = first_after(h.boss_tps, 'Reaper')
    ok(tp and tp >= w.done, 'boss teleport after the claim (' .. tostring(tp) .. ' vs ' .. tostring(w.done) .. ')')
    eq(h.place, h.P.lair, 'Reaper reached the lair')
end)
case('S4 WonderCity waits with its home-town teleport until SilentRaven finished', function()
    local h = host({rosie = false, dirs = {'Batmobile', 'SilentRaven', 'WonderCity'}, place = 'temis'})
    h.mod('WonderCity', 'gui').elements.main_toggle:set(true)
    local w = watch(h)
    w.run(20)
    h.assert_clean('S4')
    eq(w.result, 'success'); eq(h.reward_accepts, 1)
    local tp = first_after(h.waypoints, 'WonderCity')
    ok(tp and tp >= w.done, 'Kurast teleport after the claim (' .. tostring(tp) .. ' vs ' .. tostring(w.done) .. ')')
end)
case('S5 Helltide waits with its teleport out of Temis until SilentRaven finished', function()
    local h = host({rosie = false, dirs = {'Batmobile', 'HelltideRevamped', 'SilentRaven'}, place = 'temis', minute = 30})
    h.mod('HelltideRevamped', 'gui').elements.main_toggle:set(true)
    local w = watch(h)
    w.run(20)
    h.assert_clean('S5')
    eq(w.result, 'success'); eq(h.reward_accepts, 1)
    local tp = first_after(h.waypoints, 'HelltideRevamped')
    ok(tp and tp >= w.done, 'Helltide teleport after the claim (' .. tostring(tp) .. ' vs ' .. tostring(w.done) .. ')')
    eq(h.logged('SilentRaven is claiming a Whisper reward'), 1, 'one line per wait')
end)

if #failures > 0 then error(table.concat(failures, '\n')) end
print('SilentRaven standalone checks: ' .. checks)
