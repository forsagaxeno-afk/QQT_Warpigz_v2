-- QQT_Warpigz_v3 Reaper 1.10.7: sweep 2026-09-28 #17 (S5 F5, P2). Reaper
-- reloaded or enabled in the middle of a boss fight whose summon spent the
-- last key found no keys at startup, stopped in the lair and left the live
-- boss (and its reward chest). It now joins the fight with a one-run
-- committed rotation for the boss of this lair.
--   L1 last key spent, boss quest active: no refusal, the kill, one chest,
--      home in town, 'success', the rotation ends after that run
--   L2 last key spent, reward chest already up (boss dead): the chest is
--      opened before the town return
--   L3 control: a key left in the bags is not spent (no second summon)
--   L4 no fight in progress (spent altar, no boss, no chest): still refused
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
        print('PASS Reaper reload last key: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Reaper reload last key: ' .. name .. ': ' .. tostring(err))
    end
end

local GREATER = 2558255

-- keys: Greater Lair Keys left in the bags after the summon.
-- fight: 'quest' (boss up, boss quest active), 'chest' (boss dead, chest up), nil.
local function boot(keys, fight)
    local e, c, s, p = harness()
    local logs = {}
    e.console = {print = function(m) logs[#logs + 1] = tostring(m) end}
    p.get_dungeon_key_items = function()
        if keys == 0 then return {} end
        return {{get_acd = function() return 7 end, get_sno_id = function() return GREATER end,
            get_stack_count = function() return keys end}}
    end
    local altar = c.actor('Boss_WT4_Duriel', e.vec3:new(0, 0, 0)); altar.interactive = false
    local chest = c.actor('EGB_Chest_Duriel', e.vec3:new(1, 0, 0))
    c.altar_clicks, c.chest_opens = 0, 0
    e.interact_object = function(a)
        if a == altar then c.altar_clicks = c.altar_clicks + 1 end
        if a == chest then c.chest_opens = c.chest_opens + 1; c.actors({altar}) end
    end
    local quest = fight == 'quest'
    e.get_quests = function()
        if quest then return {{get_name = function() return 'Boss_WT4_Duriel_Primary' end}} end
        return {}
    end
    function c.kill()
        quest = false
        c.actors({altar, chest})
    end
    c.actors(fight == 'chest' and {altar, chest} or {altar})
    c.result = nil
    assert(loadfile(root .. 'main.lua', 't', e))()
    c.now = 100
    function c.step(dt) c.now = c.now + (dt or 0.2); c.time(c.now); c.update() end
    function c.run(seconds, dt)
        local stop_at = c.now + seconds
        while c.now < stop_at - 1e-9 do c.step(dt) end
    end
    function c.count(pattern)
        local n = 0
        for _, m in ipairs(logs) do if m:find(pattern, 1, true) then n = n + 1 end end
        return n
    end
    -- The reload: the fresh Reaper is enabled inside the lair.
    e.ReaperPlugin.enable()
    return e, c
end

local function go_home(e, c)
    local tp = c.teleports
    for _ = 1, 200 do
        c.step(0.2)
        if c.teleports > tp then break end
    end
    eq(c.teleports, tp + 1, 'one town teleport after the chest')
    c.zone('Town'); c.run(1)
end

case('L1 reload mid-fight on the last key joins the fight and finishes the run', function()
    local e, c = boot(0, 'quest')
    c.run(10)
    local st = e.ReaperPlugin.status()
    eq(st.enabled, true, 'no refusal at startup (last_error=' .. tostring(st.last_error) .. ')')
    eq(c.count('No keys / husks available'), 0, 'not refused')
    eq(c.count('Joining the fight already in progress'), 1, 'logged once')
    eq(st.task and st.task.name, 'Kill Monsters', 'fighting the live boss')
    eq(c.teleports, 0, 'no teleport away from the fight')
    c.kill()
    go_home(e, c)
    st = e.ReaperPlugin.status()
    eq(c.chest_opens, 1, 'one reward chest')
    eq(c.altar_clicks, 0, 'the spent altar is never clicked')
    eq(st.total_runs, 1, 'the kill is counted')
    eq(st.enabled, false, 'stopped in town')
    eq(st.last_result, 'success', 'run result')
end)

case('L2 reload after the kill on the last key: the chest is opened before going home', function()
    local e, c = boot(0, 'chest')
    c.run(3)
    eq(e.ReaperPlugin.status().enabled, true, 'no refusal at startup')
    go_home(e, c)
    eq(c.chest_opens, 1, 'reward chest opened')
    eq(e.ReaperPlugin.status().last_result, 'success')
end)

case('L3 control: with a key left the reload joins the fight and does not spend the key', function()
    local e, c = boot(1, 'quest')
    c.run(10)
    eq(e.ReaperPlugin.status().task.name, 'Kill Monsters')
    c.kill()
    go_home(e, c)
    eq(c.chest_opens, 1, 'one chest')
    eq(c.altar_clicks, 0, 'no second summon')
    eq(e.ReaperPlugin.status().last_result, 'success')
end)

case('L4 no fight in progress (spent altar, no boss, no chest) on no keys: still refused', function()
    local e, c = boot(0, nil)
    c.run(3)
    local st = e.ReaperPlugin.status()
    eq(st.enabled, false, 'refused')
    eq(st.last_result, 'failed')
    eq(c.count('Joining the fight already in progress'), 0)
end)

print(string.format('Reaper reload last key: %d cases, %d checks, %d failures', cases, checks, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
