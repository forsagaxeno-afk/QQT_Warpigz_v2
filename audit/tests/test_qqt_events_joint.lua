-- QQT_Warpigz_v3 (3.3.0): the suite event bus in the joint host. A test
-- collector creates _G.QQT_Warpigz_events (as the archived WarRoom did at
-- load; since 3.3.6 no shipped plugin creates it, so the test does) and
-- records every event through on_emit; the real plugins emit at their own
-- code points:
--   E1 Temis: Whisper claim -> WarPug plan -> WarPigs step/enable -> Arkham
--      opens the Pit (pit_start) -> leaves it (pit_end, level from settings)
--   E2 a whole War Plan: Pit -> Undercity (start/end, floors) -> Infernal
--      Horde in War Plan mode (start, pylons, Council, chests, done) ->
--      Reaper boss lair (summoned, chest, boss_killed with the boss label,
--      run_end) -> Helltide -> turn-in (step edges, turn_in_done,
--      plugin enable/disable/finished)
--   E3 Rosie: drops picked up (pickup with rarity / mythic / ancestral / GA),
--      a with-teleport town trip (trip_start census, trip_end sold/salvaged)
--   E4 HelltideRevamped farm: chest_opened with the cost, helltide_done when
--      the Helltide hour ends
--   E5 without a collector (the 3.3.6 package: WarRoom archived) nothing is
--      emitted and no global appears.
-- QQT_Warpigz_v3 owner-build: no Rosie in this build; E3 and E7 (Rosie's
-- pickup/trip events) are dropped and E4 runs with the Alfred/Looter mocks.
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
local ONLY = os.getenv('JOINT_ONLY')
local function case(name, fn)
    if ONLY and ONLY ~= '' and not name:find(ONLY, 1, true) then return end
    local started = os.clock()
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print(string.format('PASS qqt-events joint: %s (%.1fs)', name, os.clock() - started))
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL qqt-events joint: ' .. name .. ': ' .. tostring(err)) end
end

local WP, PUG, SR, ARK, HR = 'WarPigs', 'WarPug', 'SilentRaven', 'ArkhamAsylum', 'HelltideRevamped'
local HORDE_Q = 'WarPlans_QST_InfernalHordes_BSK'
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

-- The collector side: the bus the test creates (the archived WarRoom created
-- it at load), plus a full log via on_emit.
local function collect(h)
    local log = {}
    local bus = {seq = 0, ring = {}, max = 512, on_emit = function(e) log[#log + 1] = e end}
    rawset(h.G, 'QQT_Warpigz_events', bus)
    h.bus, h.events_log = bus, log
    return log
end
local function events(h, source, kind)
    local out = {}
    for _, e in ipairs(h.events_log) do
        if e.source == source and (kind == nil or e.kind == kind) then out[#out + 1] = e end
    end
    return out
end
local function one(h, source, kind, label)
    local list = events(h, source, kind)
    ok(#list >= 1, (label or '') .. ': no ' .. source .. '.' .. kind .. ' event\n' .. h.tail(20))
    return list[1], list
end
local function listing(h)
    local out = {}
    for _, e in ipairs(h.events_log) do out[#out + 1] = e.source .. '.' .. e.kind end
    return table.concat(out, ' ')
end
local function scalar_only(h)
    for _, e in ipairs(h.events_log) do
        ok(type(e.seq) == 'number' and type(e.epoch) == 'number' and type(e.t) == 'number', 'event header')
        for k, v in pairs(e) do
            local tv = type(v)
            ok(type(k) == 'string' and (tv == 'string' or tv == 'number' or tv == 'boolean'),
                e.source .. '.' .. e.kind .. ': non-scalar field ' .. tostring(k))
        end
    end
end

local function setup(opts)
    opts = opts or {}
    local h = J.new(opts)
    h.assert_clean('load')
    h.instrument_exports()
    collect(h)
    el(h, WP).main_toggle:set(opts.warpigs ~= false)
    el(h, PUG).main_toggle:set(opts.warpug ~= false)
    el(h, SR).main_toggle:set(opts.raven ~= false)
    if opts.quests then h.set_quests(opts.quests) end
    return h
end

case('E1 Temis: Whisper claim, WarPug plan, WarPigs step and enable, Arkham pit_start and pit_end', function()
    local h = setup({})
    h.bounty_ready = true
    h.on_confirm = function() h.at(1.0, function() h.set_quests({'WarPlans_QST_ThePit'}) end) end
    el(h, ARK).pit_level:set(37)
    ok(h.run_until(function() return h.place == h.P.pit end, 120), 'Arkham entered the pit\n' .. h.tail())
    h.run(8)
    local claim = one(h, 'silentraven', 'whisper_claim', 'E1')
    eq(claim.result, 'success', 'the Whisper claim'); ok(type(claim.name) == 'string', 'claimed reward named')
    eq(type(claim.legendary), 'boolean')
    local plan = one(h, 'warpug', 'plan_created', 'E1')
    ok(type(plan.path) == 'string' and plan.path:find(' -> ', 1, true) ~= nil, 'plan path: ' .. tostring(plan.path))
    eq(plan.rerolls, 0)
    ok(plan.seq > claim.seq, 'the plan after the claim')
    local step = one(h, 'warpigs', 'step_start', 'E1')
    eq(step.quest ~= nil, true)
    local found = false
    for _, e in ipairs(events(h, 'warpigs', 'step_start')) do
        if tostring(e.quest):find('ThePit', 1, true) then found = true end
    end
    ok(found, 'step_start for the Pit quest: ' .. listing(h))
    local en = one(h, 'warpigs', 'plugin_enabled', 'E1')
    eq(en.plugin, 'ArkhamAsylumPlugin'); ok(type(en.reason) == 'string', 'enable reason')
    local start = one(h, 'arkham', 'pit_start', 'E1')
    eq(start.level, 37, 'pit_start level from settings')
    ok(start.seq > en.seq, 'the pit opened after WarPigs enabled Arkham')
    eq(#events(h, 'arkham', 'pit_end'), 0, 'no pit_end inside the pit')
    local entered = h.now
    h.run(10)
    h.travel_to('temis', 1.0, 'pit_exit')
    ok(h.run_until(function() return #events(h, 'arkham', 'pit_end') > 0 end, 10), 'pit_end on leaving\n' .. listing(h))
    local fin = events(h, 'arkham', 'pit_end')
    eq(#fin, 1, 'one pit_end')
    eq(fin[1].level, 37); eq(fin[1].boss, false); eq(fin[1].glyph, false); eq(fin[1].timeout, false)
    ok(fin[1].secs >= h.now - entered - 2 and fin[1].secs < 200, 'pit_end secs: ' .. tostring(fin[1].secs))
    h.run(3)
    eq(#events(h, 'arkham', 'pit_end'), 1, 'not repeated in town')
    h.assert_clean('E1')
    scalar_only(h)
    ok(h.bus.seq == #h.events_log, 'every event went through the ring')
end)

case('E2 one War Plan: Pit, Undercity, War Plan Horde, Reaper lair, Helltide, turn-in', function()
    local Q = {pit = 'WarPlans_QST_ThePit', uc = 'WarPlans_QST_Undercity', boss = 'WarPlans_QST_BossLair_Andariel',
        ht = 'WarPlans_QST_Helltide_TorturedGifts', turn = 'WarPlans_QST_TurnIn_Rewards'}
    local DEST = {[Q.uc] = 'kurast', [HORDE_Q] = 'bsk', [Q.boss] = 'lair', [Q.ht] = 'helltide'}
    local h = setup({quests = {Q.pit}, virtual_os_time = true})
    h.setup_undercity()
    local A = h.setup_horde({next_quest = Q.boss})
    h.setup_lair(function(hh) hh.at(3, function() hh.set_quests({Q.ht}) end) end, {altar_stays = true})
    for i = 1, 4 do h.actor('pit', 'Pit_Monster_' .. i, 20 + i * 15, (i % 2) * 6, {enemy = true}) end
    for i = 1, 3 do h.actor('undercity', 'Undercity_Monster_' .. i, 25 + i * 20, 0, {enemy = true}) end
    h.warplan_dest = function(hh) return DEST[hh.quests[1]] end
    h.P.helltide.helltide = true
    local phase, since = 'pit', nil
    ok(h.run_until(function()
        if phase == 'pit' and h.place == h.P.pit then
            since = since or h.now
            if h.now - since > 25 and not h.travel then
                h.set_quests({Q.uc}); h.travel_to('temis', 1.0, 'pit_exit'); phase, since = 'uc', nil
            end
        elseif phase == 'uc' and h.place == h.P.undercity then
            since = since or h.now
            if h.now - since > 30 and not h.travel and not h.alfred.job then
                h.set_quests({HORDE_Q}); h.travel_to('kurast', 1.0, 'undercity_exit'); phase, since = 'rest', nil
            end
        elseif phase == 'rest' and h.quests[1] == Q.ht and h.place == h.P.helltide then
            since = since or h.now
            if h.now - since > 30 then h.set_quests({Q.turn}); phase = 'turn' end
        elseif phase == 'turn' and #h.quests == 0 then
            return true
        end
        return false
    end, 1500), 'the whole plan and the turn-in (phase ' .. phase .. ')\n' .. h.tail())
    h.run(2)
    h.assert_clean('E2')
    local all = listing(h)
    -- Arkham
    local ps = one(h, 'arkham', 'pit_start', 'E2')
    ok(type(ps.level) == 'number', 'pit level')
    local pe = one(h, 'arkham', 'pit_end', 'E2')
    ok(pe.seq > ps.seq and pe.secs > 20, 'pit_end after the run: ' .. tostring(pe.secs))
    -- WonderCity
    local us = one(h, 'wondercity', 'undercity_start', 'E2')
    local ue = one(h, 'wondercity', 'undercity_end', 'E2')
    ok(ue.seq > us.seq, 'undercity_end after its start')
    eq(ue.floors, 1, 'one floor'); eq(type(ue.success), 'boolean'); ok(type(ue.reason) == 'string', 'reason')
    ok(ue.secs >= 25, 'undercity secs ' .. tostring(ue.secs))
    -- HordeDev (War Plan mode)
    local hs, starts = one(h, 'hordedev', 'horde_start', 'E2')
    eq(#starts, 1, 'one horde_start: ' .. all); eq(hs.mode, 'warplan')
    local pylons = events(h, 'hordedev', 'horde_pylon')
    eq(#pylons, 6, 'one horde_pylon per offering: ' .. all)
    ok(pylons[1].name == 'BSK_Pyl_ChaoticOffering', 'pylon name ' .. tostring(pylons[1].name))
    ok(pylons[1].seq > hs.seq, 'start before the first pylon')
    local council, councils = one(h, 'hordedev', 'horde_council', 'E2')
    eq(#councils, 1, 'one Council event'); eq(type(council.bartuc), 'boolean')
    local chests = events(h, 'hordedev', 'horde_chest')
    eq(#chests, #A.opened, 'one horde_chest per opened chest: ' .. all)
    ok(#chests >= 1 and type(chests[1].type) == 'string', 'chest type')
    local done, dones = one(h, 'hordedev', 'horde_done', 'E2')
    eq(#dones, 1, 'one horde_done'); eq(done.mode, 'warplan')
    ok(done.exit == 'reset' or done.exit == 'teleport', 'exit ' .. tostring(done.exit))
    eq(#events(h, 'hordedev', 'horde_fail'), 0, 'no horde_fail')
    -- Reaper
    local sum = one(h, 'reaper', 'boss_summoned', 'E2')
    eq(sum.boss, 'andariel'); eq(sum.label, 'Andariel')
    local kill, kills = one(h, 'reaper', 'boss_killed', 'E2')
    eq(#kills, 1, 'one kill counted'); eq(kill.label, 'Andariel', 'the right boss label'); eq(kill.boss, 'andariel')
    eq(kill.tier, 'greater'); ok(type(kill.secs) == 'number' and kill.secs >= 0, 'kill secs')
    local chest = one(h, 'reaper', 'chest_opened', 'E2')
    eq(chest.name, 'EGB_Chest_Andariel')
    ok(sum.seq < chest.seq, 'summoned before the chest')
    local run_end = one(h, 'reaper', 'run_end', 'E2')
    eq(run_end.result, 'success'); eq(run_end.mode, 'run_once', 'the run kind (field mode)')
    -- WarPigs
    eq(#events(h, 'warpigs', 'turn_in_done'), 1, 'turn_in_done once: ' .. all)
    local quests = {}
    for _, e in ipairs(events(h, 'warpigs', 'step_start')) do quests[e.quest] = (quests[e.quest] or 0) + 1 end
    local done_q = {}
    for _, e in ipairs(events(h, 'warpigs', 'step_done')) do done_q[e.quest] = true end
    local n = 0
    for q in pairs(quests) do n = n + 1; ok(done_q[q], 'step_done for ' .. q .. ': ' .. all) end
    ok(n >= 5, 'a step per War Plan quest pattern: ' .. n)
    local enabled_plugins = {}
    for _, e in ipairs(events(h, 'warpigs', 'plugin_enabled')) do enabled_plugins[e.plugin] = true end
    for _, p in ipairs({'ArkhamAsylumPlugin', 'WonderCityPlugin', 'InfernalHordesPlugin', 'ReaperPlugin',
        'HelltideRevampedPlugin'}) do
        ok(enabled_plugins[p], 'plugin_enabled ' .. p .. ': ' .. all)
    end
    ok(#events(h, 'warpigs', 'plugin_disabled') + #events(h, 'warpigs', 'plugin_finished') >= 4,
        'hand-offs reported: ' .. all)
    scalar_only(h)
end)

-- ── HelltideRevamped ─────────────────────────────────────────────────────
local MYSTERY, GLOVES = 'usz_rewardGizmo_Uber', 'usz_rewardGizmo_Gloves'
local function loop_points()
    local f = assert(io.open(ROOT .. '/HelltideRevamped/waypoints/jirandai.lua', 'r'))
    local text = f:read('*a'); f:close()
    local pts = {}
    for x, y in text:gmatch('vec3:new%(%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*,%s*[%-%d%.]+%s*%)') do
        pts[#pts + 1] = {tonumber(x), tonumber(y)}
    end
    return pts
end
local function hr_chest(h, pts, skin, i, side)
    local a, b = pts[i], pts[i + 1]
    local dx, dy = b[1] - a[1], b[2] - a[2]
    local len = math.sqrt(dx * dx + dy * dy)
    local c = h.actor('step', skin, a[1] - dy / len * side, a[2] + dx / len * side)
    function c:x() return self.pos:x() end
    function c:y() return self.pos:y() end
    function c:z() return self.pos:z() end
    function c:dist_to(o) return self.pos:dist_to(o) end
    c.cost = h.mod(HR, 'data.enums').chest_types[skin]
    c.on_interact = function()
        if c.interactable == false or h.cinders < c.cost then return end
        h.cinders = h.cinders - c.cost
        c.interactable = false
        h.opened = h.opened or {}
        h.opened[#h.opened + 1] = {skin = skin, t = h.now}
    end
    return c
end

case('E4 HelltideRevamped farm: chest_opened with the cost, helltide_done when the hour ends', function()
    local h = J.new({rosie = false, dirs = {'Batmobile', HR}, place = 'step', minute = 5})
    local hour = 1790481600
    h.mod(HR, 'core.hr_clock')._now = function() return hour + h.minute * 60 + math.floor(h.now) % 60 end
    local pts = loop_points()
    h.P.step.box = {-1300, -150, -900, -150}
    h.P.step.spawn = h.v(pts[1][1], pts[1][2])
    h.P.step.helltide = true
    h.pos = h.P.step.spawn
    h.cinders = 325
    h.assert_clean('load')
    collect(h)
    hr_chest(h, pts, MYSTERY, 44, 12)
    hr_chest(h, pts, GLOVES, 110, -25)
    h.mod(HR, 'gui').elements.cinder_run_at:set(325)
    h.mod(HR, 'gui').elements.main_toggle:set(true)
    ok(h.run_until(function() return #(h.opened or {}) >= 2 end, 420), 'both chests opened\n' .. h.tail(30))
    h.run(8)
    local opened = events(h, 'helltide', 'chest_opened')
    local paid = {}
    for _, e in ipairs(opened) do if type(e.cost) == 'number' and e.cost > 0 then paid[e.name] = e.cost end end
    eq(paid[MYSTERY], 250, 'the Mystery chest with its cost: ' .. listing(h))
    eq(paid[GLOVES], 75, 'the Gloves chest with its cost')
    eq(#events(h, 'helltide', 'helltide_done'), 0, 'the Helltide is still on')
    -- The Helltide hour ends: the record closes once.
    hour = hour + 3600
    h.minute = 5
    ok(h.run_until(function() return #events(h, 'helltide', 'helltide_done') > 0 end, 30),
        'helltide_done at the hour change\n' .. listing(h))
    h.run(5)
    local done = events(h, 'helltide', 'helltide_done')
    eq(#done, 1, 'one helltide_done')
    eq(done[1].chests, 2); eq(done[1].mystery, 1); eq(done[1].spent, 325)
    eq(done[1].zone, 'Step_South'); ok(type(done[1].hour) == 'number' and done[1].secs > 0, 'hour / secs')
    -- death / tear_done from the stats hooks HR calls.
    local stats = h.mod(HR, 'core.hr_stats')
    h.as(HR, function() stats.on_death(); stats.on_tear_done() end)
    eq(#events(h, 'helltide', 'death'), 1); eq(#events(h, 'helltide', 'tear_done'), 1)
    h.assert_clean('E4')
    scalar_only(h)
end)

case('E5 no collector: the plugins run a Pit and emit nothing, no bus global appears', function()
    local h = J.new({place = 'pit'})
    h.assert_clean('load')
    h.set_quests({'WarPlans_QST_ThePit'})
    el(h, WP).main_toggle:set(true)
    h.run(12)
    ok(enabled(h, 'ArkhamAsylumPlugin'), 'Arkham runs')
    h.travel_to('temis', 1.0, 'pit_exit')
    h.run(5)
    eq(rawget(h.G, 'QQT_Warpigz_events'), nil, 'no bus without a collector')
    for _, name in ipairs(h.new_globals()) do
        ok(name ~= 'QQT_Warpigz_events', 'no emitter created the bus')
    end
    h.assert_clean('E5')
end)

-- 3.3.0 review B1: WarPigs' step_start / step_done are edges. While tick()
-- returns early (a SilentRaven claim held by raven_bridge, a teleport in
-- flight) last_matches is not updated; the events diff their own record, so
-- a quest change during a hold is sent once, not on every tick.
case('E6 step edges once across a raven_bridge hold', function()
    local h = setup({quests = {'WarPlans_QST_ThePit'}})
    ok(h.run_until(function() return h.place == h.P.pit end, 120), 'in the pit')
    local orch = h.mod(WP, 'core.orchestrator')
    local rb
    for i = 1, 200 do
        local n, v = debug.getupvalue(orch.tick, i)
        if not n then break end
        if n == 'raven_bridge' then rb = v end
    end
    ok(rb ~= nil, 'raven_bridge upvalue')
    local real = rb.tick
    rb.tick = function() return true end -- a Whisper claim in flight
    h.set_quests({'WarPlans_QST_Undercity'})
    h.run(5)
    rb.tick = real
    h.run(3)
    local function n_of(kind, quest)
        local n = 0
        for _, e in ipairs(events(h, 'warpigs', kind)) do if e.quest == quest then n = n + 1 end end
        return n
    end
    eq(n_of('step_start', 'WarPlans_QST_Undercity'), 1, 'step_start(Undercity) once across the hold')
    eq(n_of('step_done', 'WarPlans_QST_ThePit'), 1, 'step_done(ThePit) once across the hold')
    eq(n_of('step_start', 'WarPlans_QST_ThePit'), 1, 'step_start(ThePit) once')
end)

-- 3.3.0 review B3: without a bus (no collector; the 3.3.6 package has none)
-- Rosie's pickup does not build the event description (host getters, mythic
-- scan, GA count) per drop.
case('E8 HordeDev: fresh_run_reset clears the horde_start guard', function()
    local h = setup({})
    local tracker = h.mod('HordeDev', 'core.tracker')
    h.as('HordeDev', function() tracker.emit_start() end)
    eq(#events(h, 'hordedev', 'horde_start'), 1, 'first run started')
    -- no emit_done: the run was abandoned
    tracker.qqt_pylon_announced = true
    h.as('HordeDev', function() tracker.fresh_run_reset() end)
    eq(tracker.qqt_run_started, false, 'run flag cleared')
    ok(not tracker.qqt_pylon_announced, 'pylon announce flag cleared')
    h.as('HordeDev', function() tracker.emit_start() end)
    eq(#events(h, 'hordedev', 'horde_start'), 2, 'the next run sends horde_start')
end)

print(string.format('QQT events joint: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
