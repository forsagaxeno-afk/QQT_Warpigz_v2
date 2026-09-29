-- QQT_Warpigz_v3 Reaper 1.10.7: sweep 2026-09-28 #9 (S5 F1, P1). Open Chest's
-- MAIN walk to the reward chest had no Looter guard: after the boss kill it
-- walked to the chest while Rosie was picking up the boss drops and dragged
-- her off a Mythic outside her pickup range. The walk now waits for
-- utils.loot_ready() (the same bounded 75 s hold as every lair exit).
--   W1 Looter busy: no walk to the chest, no stuck recovery; walks and opens
--      the chest once the Looter is idle
--   W2 the hold is bounded (Looter busy forever: the walk starts at ~75 s)
--   W3 control: no Looter, the walk starts at once
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
        print('PASS Reaper chest walk loot: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Reaper chest walk loot: ' .. name .. ': ' .. tostring(err))
    end
end

local GREATER = 2558255
local function boot(looter)
    local e, c, s, p = harness()
    local logs = {}
    e.console = {print = function(m) logs[#logs + 1] = tostring(m) end}
    c.chest_moves, c.raw_moves = 0, 0
    local chest_pos = e.vec3:new(10, 0, 0)
    e.pathfinder.request_move = function(t)
        local pos = t.get_position and t:get_position() or t
        if pos:dist_to(chest_pos) < 0.5 then c.chest_moves = c.chest_moves + 1 end
        c.position(e.vec3:new(pos:x() - 1, pos:y(), pos:z()))  -- arrive next to it
    end
    e.pathfinder.force_move_raw = function() c.raw_moves = c.raw_moves + 1 end
    if looter then e.LooteerPlugin = looter end
    p.get_dungeon_key_items = function()
        return {{get_acd = function() return 1 end, get_sno_id = function() return GREATER end,
            get_stack_count = function() return 1 end}}
    end
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
    -- The boss is dead: the altar is spent and the reward chest is 10 m away.
    local altar = c.actor('Boss_WT4_Duriel', e.vec3:new(0, 0, 0)); altar.interactive = false
    local chest = c.actor('EGB_Chest_Duriel', chest_pos)
    c.chest = chest
    c.actors({altar, chest})
    e.ReaperPlugin.enable()
    c.run(1, 0.2)
    return e, c
end

local function looter_api(state)
    return {get_enabled = function() return true end,
        is_actively_looting = function() return state.busy end}
end

case('W1 a busy Looter holds the chest walk; the walk and the open follow once it is idle', function()
    local state = {busy = true}
    local e, c = boot(looter_api(state))
    c.run(40, 0.2)
    eq(c.chest_moves, 0, 'no walk to the chest while the Looter is picking up the boss drops')
    eq(c.interactions, 0, 'chest not opened from 10 m')
    eq(c.raw_moves, 0, 'standing still during the hold is not stuck recovery')
    eq(e.ReaperPlugin.status().task.name, 'Open Chest')
    ok((e.ReaperPlugin.status().hold_reason or ''):find('waiting for Looter', 1, true) ~= nil,
        'hold shown in status: ' .. tostring(e.ReaperPlugin.status().hold_reason))
    state.busy = false
    c.run(6, 0.2)
    ok(c.chest_moves >= 1, 'walks to the chest after the Looter is idle')
    ok(c.interactions >= 1, 'chest opened')
end)

case('W2 the hold is bounded: a Looter that never idles releases the walk at ~75 s', function()
    local state = {busy = true}
    local e, c = boot(looter_api(state))
    c.run(70, 0.5)
    eq(c.chest_moves, 0, 'held inside the bound')
    c.run(10, 0.5)
    ok(c.chest_moves >= 1, 'walk released after the 75 s bound')
    ok(c.interactions >= 1, 'chest opened')
    eq(c.count('leaving the lair without waiting any longer'), 1, 'bound logged once')
end)

-- QQT_Warpigz_v3 Reaper 1.10.8 (3.3.13 review #2): the chest walk and the
-- post-chest wait shared one 75 s Looter bound; a walk that spent it left
-- the lair at once, before the Looter picked up the chest drops.
case('W4 a bound spent on the chest walk does not release the post-chest loot wait', function()
    local state = {busy = true}
    local e, c = boot(looter_api(state))
    c.run(80, 0.5)
    ok(c.interactions >= 1, 'chest opened after the walk bound')
    c.actors({})  -- the chest is spent: it drops its loot and goes away
    c.run(40, 0.5)
    eq(c.count('Run complete'), 0, 'the run waits for the Looter picking up the chest drops')
    state.busy = false
    c.run(10, 0.5)
    ok(c.count('Run complete') >= 1, 'the run completes once the Looter is idle')
end)

case('W3 control: without a Looter the chest walk starts at once', function()
    local e, c = boot(nil)
    c.run(2, 0.2)
    ok(c.chest_moves >= 1, 'walks to the chest')
    ok(c.interactions >= 1, 'chest opened')
end)

print(string.format('Reaper chest walk loot: %d cases, %d checks, %d failures', cases, checks, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
