-- QQT_Warpigz_v3 Reaper 1.10.7: contract C-boss (sweep 2026-09-28 §2.4).
-- ReaperPlugin.status().boss_fight is true while a boss fight is live, so
-- Rosie can defer her automatic town trip (one gate for Arkham, WonderCity
-- and Reaper). Bounded: only fresh fight evidence (<= 5 s) counts.
--   S1 false before the summon, true in the fight, false once the reward
--      chest is up, false after disable
--   S2 bounded: no evidence (boss quest gone, no enemy in range) for 5 s
--      turns it off while Kill Monsters still runs
--   S3 boss-flagged enemy in range (quest unreadable) counts as a fight
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
        print('PASS Reaper boss_fight status: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Reaper boss_fight status: ' .. name .. ': ' .. tostring(err))
    end
end

local GREATER = 2558255
local function boot()
    local e, c, s, p = harness()
    e.console = {print = function() end}
    p.get_dungeon_key_items = function()
        return {{get_acd = function() return 7 end, get_sno_id = function() return GREATER end,
            get_stack_count = function() return 3 end}}
    end
    local altar = c.actor('Boss_WT4_Duriel', e.vec3:new(0, 0, 0))
    local chest = c.actor('EGB_Chest_Duriel', e.vec3:new(1, 0, 0))
    c.altar, c.chest = altar, chest
    c.quest = false
    e.interact_object = function(a)
        -- The summon: the altar is spent and the boss quest starts.
        if a == altar then altar.interactive = false; c.quest = true end
    end
    e.get_quests = function()
        if c.quest then return {{get_name = function() return 'Boss_WT4_Duriel_Primary' end}} end
        return {}
    end
    c.actors({altar})
    assert(loadfile(root .. 'main.lua', 't', e))()
    c.now = 100
    function c.step(dt) c.now = c.now + (dt or 0.2); c.time(c.now); c.update() end
    function c.run(seconds, dt)
        local stop_at = c.now + seconds
        while c.now < stop_at - 1e-9 do c.step(dt) end
    end
    function c.fight() return e.ReaperPlugin.status().boss_fight end
    return e, c
end

case('S1 boss_fight follows the live fight: before summon, fight, chest, disable', function()
    local e, c = boot()
    eq(c.fight(), false, 'disabled')
    -- Enabled, the altar not clicked yet: no fight.
    e.ReaperPlugin.enable()
    c.run(0.6)
    eq(c.fight(), false, 'before the summon')
    c.run(5)
    eq(e.ReaperPlugin.status().task.name, 'Kill Monsters', 'summoned')
    eq(c.fight(), true, 'live boss fight published')
    c.run(30)
    eq(c.fight(), true, 'still live while the boss quest runs')
    c.quest = false
    c.actors({c.altar, c.chest})
    c.run(1)
    eq(c.fight(), false, 'boss dead, reward chest up')
    e.ReaperPlugin.disable()
    eq(c.fight(), false, 'disabled')
end)

case('S2 bounded: no fight evidence for 5 s turns boss_fight off', function()
    local e, c = boot()
    e.ReaperPlugin.enable()
    c.run(6)
    eq(c.fight(), true, 'fight')
    c.quest = false               -- no quest, no enemy in range, no chest
    c.run(2)
    eq(e.ReaperPlugin.status().task.name, 'Kill Monsters', 'Kill Monsters still runs (its own 75 s bound)')
    c.run(4)
    eq(c.fight(), false, 'stale evidence is not a live fight')
end)

case('S3 a boss-flagged enemy within range counts; another zone does not', function()
    local e, c = boot()
    e.ReaperPlugin.enable()
    c.run(6)
    c.quest = false
    local boss = {get_position = function() return e.vec3:new(4, 0, 0) end, is_boss = function() return true end}
    e.target_selector.get_near_target_list = function() return {boss} end
    c.run(10)
    eq(c.fight(), true, 'enemy in range keeps the fight live')
    c.zone('Town')
    eq(c.fight(), false, 'out of the lair')
end)

print(string.format('Reaper boss_fight status: %d cases, %d checks, %d failures', cases, checks, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
