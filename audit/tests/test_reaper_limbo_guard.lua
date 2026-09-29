-- QQT_Warpigz_v3 Reaper 1.10.7: sweep 2026-09-28 P3 (S5 F2, hardening).
-- A Limbo/Loading world is not "out of the lair": Reaper runs no task there
-- (no boss teleport mid-fight), like ArkhamAsylum/main.lua.
--   G1 Limbo / Loading / '[sno none]' mid-fight: no teleport, no task;
--      back in the lair the fight goes on
-- Real Reaper main.lua and tasks in the QQT-shaped harness of test_reaper.lua.
local SUITE = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local root = SUITE .. '/Reaper/'
local harness_env = setmetatable({REAPER_TEST_HARNESS_ONLY = true}, {__index = _G})
local harness = assert(loadfile(SUITE .. '/audit/tests/test_reaper.lua', 't', harness_env))()

local checks, failures = 0, {}
local function eq(actual, expected, message)
    checks = checks + 1
    if actual ~= expected then
        error((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
end

local GREATER = 2558255
for _, limbo in ipairs({'Limbo', 'S04_Loading_Screen', '[sno none]'}) do
    local passed, err = pcall(function()
        local e, c, _, p = harness()
        e.console = {print = function() end}
        p.get_dungeon_key_items = function()
            return {{get_acd = function() return 7 end, get_sno_id = function() return GREATER end,
                get_stack_count = function() return 3 end}}
        end
        local altar = c.actor('Boss_WT4_Duriel', e.vec3:new(0, 0, 0))
        local quest = false
        e.interact_object = function(a) if a == altar then altar.interactive = false; quest = true end end
        e.get_quests = function()
            if quest then return {{get_name = function() return 'Boss_WT4_Duriel_Primary' end}} end
            return {}
        end
        c.actors({altar})
        assert(loadfile(root .. 'main.lua', 't', e))()
        local now = 100
        local function run(seconds)
            local stop_at = now + seconds
            while now < stop_at - 1e-9 do now = now + 0.2; c.time(now); c.update() end
        end
        e.ReaperPlugin.enable()
        run(6)
        eq(e.ReaperPlugin.status().task.name, 'Kill Monsters', 'in the fight')
        local tp = c.teleports
        c.zone(limbo); c.actors({})
        run(4)
        eq(c.teleports, tp, limbo .. ': no teleport from a Limbo/Loading world')
        c.zone('Boss_WT4_Duriel'); c.actors({altar})
        run(2)
        eq(e.ReaperPlugin.status().task.name, 'Kill Monsters', 'back in the fight')
        eq(c.teleports, tp, 'no teleport at all')
    end)
    print((passed and 'PASS' or 'FAIL') .. ' Reaper limbo guard: G1 ' .. limbo .. (passed and '' or (': ' .. tostring(err))))
    if not passed then failures[#failures + 1] = limbo .. ': ' .. tostring(err) end
end
print(string.format('Reaper limbo guard: 3 cases, %d checks, %d failures', checks, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
