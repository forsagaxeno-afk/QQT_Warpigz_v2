-- External callers must not resolve Reaper's dependencies in their own context.
local root = SUITE_ROOT .. '/Reaper-main/'
local harness_env = setmetatable({REAPER_TEST_HARNESS_ONLY=true}, {__index=_G})
local harness = assert(loadfile(SUITE_ROOT .. '/audit/tests/test_reaper.lua', 't', harness_env))()
local count = 0
local function eq(actual, expected, message)
    assert(actual == expected, (message or 'unexpected result') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
    count = count + 1
end

local function boot()
    local e,c,s,p = harness()
    assert(loadfile(root .. 'main.lua', 't', e))()
    local own = {}
    for name,value in pairs(e.package.loaded) do own[name]=value end
    return e,c,s,p,own
end

-- Model QQT entering WarPigs' caller context after Reaper has bootstrapped.
-- Its generic module cache intentionally has a tracker without reset_run.
do
    local e,c,s,p,own = boot()
    local foreign_tracker = {marker='WarPigs tracker', altar_activated=true}
    local foreign = {['core.tracker']=foreign_tracker}
    local late_requires = 0
    for name in pairs(e.package.loaded) do
        e.package.loaded[name] = foreign[name] or {marker='foreign ' .. name}
    end
    e.require = function(name)
        late_requires=late_requires+1
        return e.package.loaded[name] or error('unexpected late require: ' .. name)
    end
    own['core.tracker'].altar_activated=true
    eq(e.ReaperPlugin.run_once('duriel'),true,'WarPigs one-shot enable')
    eq(own['core.tracker'].altar_activated,false,'reset uses Reaper tracker')
    eq(foreign_tracker.altar_activated,true,'foreign tracker untouched')
    eq(e.ReaperPlugin.status().enabled,true,'external start enables Reaper')
    c.update(); c.time(100.6); c.update(); c.time(101); c.update()
    c.time(101.2); c.update()
    eq(own['core.pathwalker'].is_walking,true,'recorded path starts after caller switch')
    eq(#own['core.pathwalker'].original_path > 0,true,'own recorded path retained')
    e.ReaperPlugin.disable()
    eq(e.ReaperPlugin.status().enabled,false,'external disable works')
    eq(own['core.pathwalker'].is_walking,false,'own path stops')
    eq(e.ReaperPlugin.run_boss('varshan'),true,'external run_boss works')
    e.ReaperPlugin.clear_external()
    eq(own['core.boss_rotation'].external,false,'external rotation cleanup works')
    e.ReaperPlugin.disable()
    e.ReaperPlugin.enable()
    eq(e.ReaperPlugin.status().enabled,true,'plain enable works')
    e.ReaperPlugin.disable()
    eq(late_requires,0,'no runtime dependency resolution under external caller')
end

-- Inventory eligibility and Alfred handoff use the same modules captured at
-- startup, including task resets that used to require modules on every pulse.
do
    local e,c,s,p,own = boot()
    s.boss_target='duriel'; s.use_alfred=true
    p.get_dungeon_key_items=function()
        return {{get_acd=function() return 1 end, get_sno_id=function() return 2558255 end, get_stack_count=function() return 1 end}}
    end
    local triggers=0
    e.AlfredTheButlerPlugin={create_task=function() end,
        get_status=function() return {enabled=true,need_trigger=true} end,
        trigger_tasks_with_teleport=function(_,callback) triggers=triggers+1; callback() end}
    e.require=function(name) error('foreign caller must not resolve ' .. name) end
    eq(own['core.materials'].has_inventory_stock(s),true,'eligibility uses own enums')
    eq(own['tasks.alfred'].shouldExecute(),true,'Alfred maintenance needed')
    own['tasks.alfred'].Execute()
    eq(triggers,1,'maintenance handed off once')
    eq(own['tasks.alfred'].status,'idle','synchronous maintenance completion')
    eq(own['tasks.alfred'].shouldExecute(),false,'handoff preserves completion grace')
end

-- Resetting under foreign module keys also clears Reaper's boss-quest latch;
-- swallowing the missing reset_run error would leave this state stale.
do
    local e,c,s,p,own = boot()
    e.get_quests=function() return {{get_name=function() return 'Boss_Duriel_Primary' end}} end
    eq(own['core.utils'].is_boss_quest_complete(),false,'observe active boss quest')
    e.get_quests=function() return {} end
    eq(own['core.utils'].is_boss_quest_complete(),true,'quest latch was armed')
    e.package.loaded['core.tracker']={}
    e.package.loaded['core.utils']={}
    own['core.task_manager'].reset_all()
    eq(own['core.utils'].is_boss_quest_complete(),false,'actual Reaper quest latch reset')
end

print('Reaper feedback assertions: ' .. count)
