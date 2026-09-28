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
        print('PASS Reaper bounds: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Reaper bounds: ' .. name .. ': ' .. tostring(err))
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
case('X1 an interactable altar the player never reaches is never bounded', function()
    local e, c = boot()
    c.actors({c.actor('Boss_WT4_Duriel', e.vec3:new(8, 0, 0))})
    e.ReaperPlugin.enable()
    c.run(900, 0.5)
    local st = e.ReaperPlugin.status()
    print(string.format('  after 900 s: task=%s interactions=%d moves=%d done=%s hold=%s failed=%s',
        tostring(st.task and st.task.name), c.interactions, #c.moves,
        tostring(e.require('core.boss_rotation').is_done()), tostring(st.hold_reason), tostring(st.failed)))
    ok(e.require('core.boss_rotation').is_done() or st.failed, 'unreachable altar approach bounded')
end)
case('X2 enable/reload mid-fight: boss alive (quest active), altar spent -> boss skipped after 30 s', function()
    local e, c = boot()
    e.get_quests = function() return {{get_name = function() return 'Boss_WT4_Duriel_Primary' end}} end
    local a = c.actor('Boss_WT4_Duriel', e.vec3:new(0, 0, 0)); a.interactive = false
    local boss = c.actor('Duriel_Boss', e.vec3:new(3, 0, 0))
    c.actors({a, boss})
    e.ReaperPlugin.enable()
    c.run(40, 0.5)
    local done = e.require('core.boss_rotation').is_done()
    print('  boss alive, rotation done (skipped) = ' .. tostring(done) .. ', teleports=' .. tostring(c.teleports))
    ok(not done, 'a live boss fight is not skipped')
end)
case('X3 rotation done while a Rosie town trip is live: finishing teleport fires into it', function()
    local e, c = boot()
    local st = {enabled = true, trigger_tasks = true, running = true, need_trigger = true, inventory_full = true}
    rosie_like(e, st)
    c.actors({c.actor('Boss_WT4_Duriel', e.vec3:new(0, 0, 0))})
    local rot = e.require('core.boss_rotation')
    local res
    eq(e.ReaperPlugin.run_once('duriel', nil, function(r) res = r end), true)
    c.run(2, 0.5)
    local tp0 = c.teleports
    rot.external_consumed = true     -- chest done, the run is consumed; Rosie's trip is live
    c.run(3, 0.5)
    print(string.format('  teleports during a live Alfred trip: %d (task=%s)', c.teleports - tp0, tostring(e.ReaperPlugin.status().task.name)))
    ok(c.teleports == tp0, 'no town teleport while Alfred is live')
end)
print(string.format('%d checks, %d failures', checks, #failures))
if #failures > 0 then error('fail') end
