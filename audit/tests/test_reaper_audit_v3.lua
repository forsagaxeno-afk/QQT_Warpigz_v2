-- QQT_Warpigz_v3 Reaper 1.10.4: auditor findings (area reaper). Each case
-- failed on the pre-fix tree and passes after the fix:
--   A1-A4 an interactable altar that is never reached is bounded (approach
--         deadline: no progress for 60 s -> skip/fail, one log line); an Alfred
--         yield neither resets nor advances it, a new run resets it
--   B1-B2 enable/reload mid-fight (altar spent, boss quest active or a boss
--         nearby) joins the fight instead of skipping the boss after 30 s
--   C1-C3 the finishing town teleport never fires or re-fires into a live
--         Alfred/Rosie trip; the hold is bounded (180 s, logged once)
-- Real Reaper main.lua and tasks in the QQT-shaped harness of test_reaper.lua.
local SUITE = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local root = SUITE .. '/Reaper/'
local harness_env = setmetatable({REAPER_TEST_HARNESS_ONLY = true}, {__index = _G})
local harness = assert(loadfile(SUITE .. '/audit/tests/test_reaper.lua', 't', harness_env))()

local checks, cases, failures = 0, 0, {}
local function ok(cond, message)
    checks = checks + 1
    if not cond then error(message or 'assertion failed', 2) end
end
local function eq(actual, expected, message)
    checks = checks + 1
    if actual ~= expected then
        error((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
end
local function case(name, fn)
    cases = cases + 1
    local passed, err = pcall(fn)
    if passed then
        print('PASS Reaper audit v3: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Reaper audit v3: ' .. name .. ': ' .. tostring(err))
    end
end

local next_acd = 100
local function key_item(sno, n)
    next_acd = next_acd + 1
    local acd = next_acd
    return {get_acd = function() return acd end, get_sno_id = function() return sno end,
        get_stack_count = function() return n end}
end
local GREATER, HUSK = 2558255, 2194099

local function boot(before)
    local e, c, s, p = harness()
    local logs = {}
    c.logs = logs
    e.console = {print = function(m) logs[#logs + 1] = tostring(m) end}
    c.moves = {}
    e.pathfinder.request_move = function(t)
        local pos = t.get_position and t:get_position() or t
        c.moves[#c.moves + 1] = pos
        if c.walk then c.position(pos) end
    end
    local target
    local ex = e.package.loaded['core.explorerlite']
    ex.set_custom_target = function(_, t) target = t end
    ex.move_to_target = function() if target and c.walk then c.position(target) end end
    c.clears = 0
    ex.clear_path_and_target = function() c.clears = c.clears + 1 end
    c.task_frames = {}
    if before then before(e, c, s, p) end
    assert(loadfile(root .. 'main.lua', 't', e))()
    c.now = 100
    function c.step(dt)
        c.now = c.now + (dt or 0.2); c.time(c.now); c.update()
        local st = e.ReaperPlugin.status()
        local n = st.task and st.task.name or '?'
        c.task_frames[n] = (c.task_frames[n] or 0) + 1
    end
    function c.run(seconds, dt)
        local stop_at = c.now + seconds
        while c.now < stop_at - 1e-9 do c.step(dt) end
    end
    function c.count(pattern)
        local n = 0
        for _, m in ipairs(logs) do if m:find(pattern, 1, true) then n = n + 1 end end
        return n
    end
    function c.frames(name) return c.task_frames[name] or 0 end
    p.get_dungeon_key_items = function() return {key_item(GREATER, 3)} end
    return e, c, s, p
end

-- A Rosie-shaped provider: the same table under both globals (Rosie
-- town/main.lua publishes AlfredTheButlerPlugin and PLUGIN_alfred_the_butler).
local function rosie_like(e, status, refuse)
    local api = {calls = 0}
    api.get_status = function() return status end
    api.trigger_tasks_with_teleport = function()
        api.calls = api.calls + 1
        if refuse then return false, 'stuck' end
        return true
    end
    e.AlfredTheButlerPlugin = api
    e.PLUGIN_alfred_the_butler = api
    return api
end


local function rotation_of(e) return e.require('core.boss_rotation') end
local function finished(e)
    local st = e.ReaperPlugin.status()
    return rotation_of(e).is_done() or st.failed == true or st.enabled == false
end

-- ── A: approach deadline ────────────────────────────────────────────────────
case('A1 an interactable altar the player never reaches is skipped after the approach bound', function()
    local e, c = boot()
    c.actors({c.actor('Boss_WT4_Duriel', e.vec3:new(8, 0, 0))})
    e.ReaperPlugin.enable()
    c.run(50, 0.5)
    ok(not finished(e), 'no give-up before the 60 s approach bound')
    c.run(40, 0.5)
    eq(c.interactions, 0, 'never clicked')
    ok(finished(e), 'unreachable altar approach bounded (skip/fail within 90 s)')
    eq(c.count('Altar not reached'), 1, 'one log line for the give-up')
end)

case('A2 an external run fails (C2) when the altar is never reached', function()
    local e, c = boot()
    c.actors({c.actor('Boss_WT4_Duriel', e.vec3:new(8, 0, 0))})
    local res
    eq(e.ReaperPlugin.run_once('duriel', nil, function(r) res = r end), true)
    c.run(120, 0.5)
    ok(e.require('core.boss_rotation').failed, 'external rotation failed')
    c.zone('Town'); c.run(1, 0.5)
    eq(res, 'failed', 'run_once reports failed')
    eq(c.count('no progress for 60s) — skipping'), 1, 'one give-up log line')
end)

case('A3 Alfred yields during the approach do not reset the deadline', function()
    local e, c = boot()
    local st = {enabled = true}
    rosie_like(e, st)
    c.actors({c.actor('Boss_WT4_Duriel', e.vec3:new(8, 0, 0))})
    e.ReaperPlugin.enable()
    local elapsed = 0
    while elapsed < 240 and not finished(e) do
        c.run(20, 0.5); elapsed = elapsed + 20
        st.running = true          -- a short Rosie trip: Reaper yields
        c.run(2, 0.5); elapsed = elapsed + 2
        st.running = nil
    end
    ok(finished(e), 'deadline survives Alfred yields (gave up within 240 s)')
    ok(elapsed <= 110, 'yield time is not counted but approach time accumulates: ' .. elapsed)
    eq(c.count('no progress for 60s) — skipping'), 1, 'one give-up log line')
end)

case('A4 a new run resets the approach deadline; steady progress is never bounded', function()
    local e, c = boot()
    c.actors({c.actor('Boss_WT4_Duriel', e.vec3:new(8, 0, 0))})
    e.ReaperPlugin.enable()
    c.run(45, 0.5)
    e.require('core.task_manager').reset_all()   -- what a new run does
    c.run(45, 0.5)
    ok(not finished(e), 'deadline restarted by the new run')
    c.run(30, 0.5)
    ok(finished(e), 'then bounded again')
    -- Steady progress (1 m every 10 s) keeps the approach alive.
    local e2, c2 = boot()
    c2.actors({c2.actor('Boss_WT4_Duriel', e2.vec3:new(100, 0, 0))})
    e2.ReaperPlugin.enable()
    for i = 1, 30 do
        c2.run(10, 0.5)
        c2.position(e2.vec3:new(i * 1.5, 0, 0))
    end
    ok(not finished(e2), 'progress toward the altar is not "never reached"')
    eq(c2.count('Altar not reached'), 0)
end)

-- ── B: enable/reload mid-fight ──────────────────────────────────────────────
case('B1 boss quest active, altar spent: joins the fight, keeps the key', function()
    local e, c = boot()
    e.get_quests = function() return {{get_name = function() return 'Boss_WT4_Duriel_Primary' end}} end
    local a = c.actor('Boss_WT4_Duriel', e.vec3:new(0, 0, 0)); a.interactive = false
    c.actors({a, c.actor('Duriel_Boss', e.vec3:new(3, 0, 0))})
    e.ReaperPlugin.enable()
    c.run(40, 0.5)
    ok(not rotation_of(e).is_done(), 'a live boss fight is not skipped')
    eq(c.teleports, 0, 'no teleport away from the fight')
    eq(c.interactions, 0, 'the spent altar is never clicked')
    eq(e.require('core.tracker').altar_activated, true, 'summon marked')
    eq(e.ReaperPlugin.status().task.name, 'Kill Monsters')
    eq(c.count('Boss fight already in progress'), 1)
end)

case('B2 a boss-flagged target nearby (quest not readable) also joins the fight', function()
    local e, c = boot()
    local a = c.actor('Boss_WT4_Duriel', e.vec3:new(0, 0, 0)); a.interactive = false
    c.actors({a})
    local boss = {get_position = function() return e.vec3:new(4, 0, 0) end, is_boss = function() return true end}
    e.target_selector.get_near_target_list = function() return {boss} end
    e.ReaperPlugin.enable()
    c.run(40, 0.5)
    ok(not rotation_of(e).is_done(), 'a live boss fight is not skipped')
    eq(e.require('core.tracker').altar_activated, true, 'summon marked')
end)

-- ── C: finishing path vs a live Alfred trip ─────────────────────────────────
local function finishing_boot(status)
    local e, c = boot()
    rosie_like(e, status)
    c.actors({c.actor('Boss_WT4_Duriel', e.vec3:new(0, 0, 0))})
    local res
    eq(e.ReaperPlugin.run_once('duriel', nil, function(r) res = r end), true)
    c.run(2, 0.5)
    return e, c, function() return res end
end

case('C1 rotation done while a Rosie trip is live: no town teleport into it', function()
    local st = {enabled = true, trigger_tasks = true, running = true, need_trigger = true, inventory_full = true}
    local e, c = finishing_boot(st)
    local tp0 = c.teleports
    rotation_of(e).external_consumed = true
    c.run(60, 0.5)
    eq(c.teleports, tp0, 'no town teleport while Alfred is live')
    st.running, st.trigger_tasks, st.need_trigger, st.inventory_full = nil, nil, nil, nil
    c.run(2, 0.5)
    eq(c.teleports, tp0 + 1, 'town teleport once the trip is over')
end)

case('C2 the finishing hold is bounded (180 s, logged once)', function()
    local st = {enabled = true, running = true}
    local e, c, res = finishing_boot(st)
    local tp0 = c.teleports
    rotation_of(e).external_consumed = true
    c.run(170, 0.5)
    eq(c.teleports, tp0, 'held while Alfred is live')
    c.run(20, 0.5)
    eq(c.teleports, tp0 + 1, 'bounded: teleports after 180 s')
    eq(c.count('returning to town anyway'), 1, 'logged once')
    c.zone('Town'); c.run(1, 0.5)
    eq(res(), 'success')
end)

case('C3 no 30 s re-teleport while a Rosie trip is live after the finishing teleport', function()
    local st = {enabled = true}
    local e, c = finishing_boot(st)
    rotation_of(e).external_consumed = true
    c.run(1, 0.5)
    local tp0 = c.teleports
    ok(tp0 >= 1, 'finishing teleport fired')
    st.running = true             -- Rosie starts a trip (player still in the lair)
    c.run(60, 0.5)
    eq(c.teleports, tp0, 'no re-teleport into the live trip')
    st.running = nil
    c.run(35, 0.5)
    eq(c.teleports, tp0 + 1, 'retry resumes after the trip')
end)

print(string.format('Reaper audit v3: %d cases, %d checks, %d failures', cases, checks, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
