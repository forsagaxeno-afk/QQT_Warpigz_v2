-- Live report (v2.1.2): WarPug picked Grigoire; the path to the boss worked,
-- but Reaper then looped "kill boss -> chest -> altar" and never counted the
-- run (log: altar interacted three times, "In zone — using Batmobile to
-- navigate to altar area" right after, then after the chest "Interacting
-- with altar" again; "Total runs completed this session: 0"). Loads the real
-- Reaper scheduler and tasks with the QQT-shaped harness of test_reaper.lua.
local harness_env = setmetatable({REAPER_TEST_HARNESS_ONLY = true}, {__index = _G})
local harness = assert(loadfile(SUITE_ROOT .. '/audit/tests/test_reaper.lua', 't', harness_env))()
local failures, checks = {}, 0
local function check(label, fn)
    checks = checks + 1
    local ok, err = pcall(fn)
    if not ok then failures[#failures + 1] = label .. ': ' .. tostring(err) end
end
local function eq(a, b, m) assert(a == b, (m or 'mismatch') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end

local function lair()
    local e, c = harness()
    c.zone('Boss_WT3_PenitentKnight')
    local logs = {}
    e.console = {print = function(l) logs[#logs + 1] = tostring(l) end}
    local rot = e.require('core.boss_rotation')
    eq(rot.set_external('grigoire', nil), true, 'external Grigoire')
    local w = {e = e, c = c, rot = rot, logs = logs, now = 100,
        tracker = e.require('core.tracker'), manager = e.require('core.task_manager'),
        altar = c.actor('Boss_WT3_PenitentKnight')}
    function w.step(dt, n)
        for _ = 1, n or 1 do
            w.now = w.now + (dt or 0.25); c.time(w.now); w.manager.execute_tasks()
        end
    end
    function w.count(needle)
        local k = 0
        for _, l in ipairs(logs) do if l:find(needle, 1, true) then k = k + 1 end end
        return k
    end
    return w
end

check('the altar vanishing when the boss spawns counts as the summon (was: navigation took over)', function()
    local w = lair()
    w.c.actors({w.altar})
    w.step()
    eq(w.c.interactions, 1, 'altar interacted')
    w.c.actors({})                          -- Grigoire spawns, the altar actor is gone
    w.step(0.25, 4)
    eq(w.tracker.altar_activated, true, 'summon registered')
    eq(w.count('navigate to altar area'), 0, 'no re-navigation to the altar')
end)

check('an altar that stays listed but is no longer interactable counts as the summon', function()
    local w = lair()
    w.c.actors({w.altar})
    w.step()
    w.altar.interactive = false
    w.step(0.25, 8)
    eq(w.tracker.altar_activated, true, 'summon registered')
    eq(w.c.interactions, 1, 'no second altar click')
end)

check('reward chest completes the run even if the altar is back (was: altar re-summoned)', function()
    local w = lair()
    -- Live state: the summon was never registered, the boss is dead.
    local chest = w.c.actor('EGB_Chest_PenitentKnight')
    w.c.actors({chest})
    w.step()
    eq(w.c.interactions, 1, 'chest opened')
    chest.interactive = false
    w.altar.interactive = true
    w.c.actors({w.altar})                    -- chest gone, altar listed and clickable again
    local looting = true                     -- Looter collects the boss drops for ~8 s (live)
    w.e.LooteerPlugin = {get_enabled = function() return true end,
        is_actively_looting = function() return looting end}
    w.step(0.5, 16)
    looting = false
    w.step(0.5, 24)
    eq(w.c.interactions, 1, 'altar not clicked after the chest')
    eq(w.tracker.total_kills, 1, 'run counted')
    eq(w.rot.external_consumed, true, 'one-shot consumed')
end)

if #failures > 0 then error('Reaper Grigoire live regressions failed:\n' .. table.concat(failures, '\n')) end
print(string.format('PASS: Reaper Grigoire live regressions (%d checks)', checks))
