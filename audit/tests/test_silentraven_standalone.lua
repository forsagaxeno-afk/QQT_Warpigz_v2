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
    assert(h.as('Rosie', function() return h.G.RosiePlugin.enable() end))
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
local function fill_bag(h, n)
    h.inventory = h.inventory or {}
    for _ = 1, n do h.inventory[#h.inventory + 1] = h.gear() end
end

-- S1: Rosie's automatic trip from the pit.
local function trip(o)
    local h = host({rosie = true, dirs = {'SilentRaven'}, place = 'pit'})
    if o.auto_fire == false then h.mod('SilentRaven', 'silent_raven.gui').elements.auto_fire_toggle:set(false) end
    h.bounty_ready = o.ready ~= false
    h.run(2)
    fill_bag(h, 25)
    local rosie = h.mod('Rosie', 'rosie.private.town.core.tracker')
    local w = watch(h)
    local in_temis, elapsed = false, {}
    w.on_frame = function()
        if h.place == h.P.temis then in_temis = true end
        if rosie.raven_wait then elapsed[#elapsed + 1] = rosie.service_elapsed end
    end
    ok(w.run(200, function() return in_temis and h.place == h.P.pit end), 'trip back into the pit\n' .. h.tail())
    h.run(2)
    h.assert_clean('S1')
    return h, w, elapsed
end
case('S1 a Rosie trip to Temis hands off once to SilentRaven before the return portal', function()
    local h, w, elapsed = trip({})
    eq(h.reward_accepts, 1, 'the Whisper reward is claimed during the trip')
    eq(w.result, 'success'); eq(w.reason, 'external:alfred_the_butler', 'claimed through the hand-off')
    eq(h.bounty_ready, false, 'no reward left ready')
    eq(h.logged('[Rosie] waiting for SilentRaven'), 1, 'one hand-off per trip')
    eq(h.logged('[Rosie] completed'), 1, 'the trip completes')
    local back = nil
    for _, a in ipairs(h.arrivals) do if a.place == 'pit' and a.why == 'town_portal' then back = a.t end end
    ok(back and w.done and w.done < back, 'claimed before the portal back to the pit')
    ok(#elapsed > 10, 'Rosie waited for the claim')
    eq(elapsed[#elapsed], elapsed[1], 'the hand-off wait is not Rosie service time')
end)
case('S1 no hand-off when auto-fire is off or no reward is ready', function()
    for _, o in ipairs({{auto_fire = false}, {ready = false}}) do
        local h, w = trip(o)
        eq(h.logged('[Rosie] waiting for SilentRaven'), 0, 'no hand-off')
        eq(h.reward_accepts, nil, 'nothing claimed')
        eq(w.first, nil, 'SilentRaven never ran')
        eq(h.logged('[Rosie] completed'), 1, 'the trip completes')
    end
end)

-- S2: Arkham at the Temis obelisk when SilentRaven auto-fires.
case('S2 Arkham defers its obelisk walk and interactions while SilentRaven claims', function()
    local h = host({rosie = true, dirs = {'ArkhamAsylum', 'Batmobile', 'SilentRaven'}, place = 'temis'})
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
    local h = host({rosie = true, dirs = {'Batmobile', 'Reaper', 'SilentRaven'}, place = 'temis'})
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
    local h = host({rosie = true, dirs = {'Batmobile', 'WonderCity', 'SilentRaven'}, place = 'temis'})
    h.mod('WonderCity', 'gui').elements.main_toggle:set(true)
    local w = watch(h)
    w.run(20)
    h.assert_clean('S4')
    eq(w.result, 'success'); eq(h.reward_accepts, 1)
    local tp = first_after(h.waypoints, 'WonderCity')
    ok(tp and tp >= w.done, 'Kurast teleport after the claim (' .. tostring(tp) .. ' vs ' .. tostring(w.done) .. ')')
end)
case('S5 Helltide waits with its teleport out of Temis until SilentRaven finished', function()
    local h = host({rosie = true, dirs = {'Batmobile', 'HelltideRevamped', 'SilentRaven'}, place = 'temis', minute = 30})
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
