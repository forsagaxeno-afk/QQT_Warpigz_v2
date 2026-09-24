local root = assert(SUITE_ROOT) .. '/WarPigs-1.0.0/'
package.path = root .. '?.lua;' .. package.path
local Bridge = require 'wp_silent_raven'
local checks = 0
local function eq(a,b,message)
    assert(a == b, (message or 'mismatch') .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b))
    checks = checks + 1
end
local function fixture()
    local f = {now=100, zone='Skov_Temis', world='Town', town=true, quests={},
        triggers=0, cancels=0, waypoint=0, teleport=0, task_calls=0}
    local s = {api_version=2, enabled=true, running=false, pending=false}
    f.status = s
    f.sr = {
        get_status=function() if f.status_error then error('unreadable') end; return s end,
        set_managed=function(caller,value)
            if value then
                if s.managed_by and s.managed_by ~= caller then return false end
                if (s.running or s.pending) and s.owner ~= caller then return false end
                s.managed_by=caller
            else
                if s.owner == caller and (s.running or s.pending) then return false end
                s.managed_by=nil
            end
            return true
        end,
        trigger_tasks=function(caller,callback,guard)
            if s.running or s.pending then return false end
            f.triggers=f.triggers+1; f.callback=callback; f.guard=guard
            s.pending=true; s.owner=caller
            return true
        end,
        cancel=function(caller,preserve)
            f.cancels=f.cancels+1; f.preserve=preserve
            if f.cancel_error then error('cancel unavailable') end
            if s.owner ~= caller then return false end
            s.running=false; s.pending=false; s.owner=nil
            if f.callback then f.callback('cancelled') end
            return true
        end,
    }
    f.settings={manage_whispers=true, use_teleport_transition=false}
    package.loaded['core.settings']=f.settings
    package.loaded['core.tasks.turn_in_rewards']={
        tick=function(active) if active then f.task_calls=f.task_calls+1 end end,
        get_state=function() return f.task_state or 'IDLE' end,
    }
    console={print=function() end}
    attributes={PLAYER_IN_TOWN_LEVEL_AREA=1}
    get_time_since_inject=function() return f.now end
    get_local_player=function() return {
        is_dead=function() return false end,
        get_attribute=function() return f.town and 1 or 0 end,
        get_buffs=function() return {} end,
    } end
    get_current_world=function() return {
        get_name=function() return f.world end, get_current_zone_name=function() return f.zone end,
    } end
    get_quests=function()
        if f.quest_error then error('quests unavailable') end
        local out={}
        for _,name in ipairs(f.quests) do out[#out+1]={get_name=function() return name end} end
        return out
    end
    actors_manager={get_all_actors=function() return {} end}
    get_aether_count=function() return 0 end
    teleport_to_waypoint=function() f.waypoint=f.waypoint+1 end
    warplan={teleport_to_activity=function() f.teleport=f.teleport+1 end}
    SilentRavenPlugin=f.sr; PLUGIN_silent_raven=nil
    LooteerPlugin, AlfredTheButlerPlugin, PLUGIN_alfred_the_butler, WarPugPlugin=nil,nil,nil,nil
    ArkhamAsylumPlugin, InfernalHordesPlugin, ReaperPlugin, WonderCityPlugin, HelltideRevampedPlugin=nil,nil,nil,nil,nil
    target_selector=nil
    f.o=dofile(root .. 'core/orchestrator.lua')
    function f:tick(seconds) self.now=self.now+(seconds or 0.5); self.o.tick() end
    function f:steps(n) for _=1,n do self:tick() end end
    function f:finish(result)
        s.pending=false; s.running=false; s.owner=nil; s.last_result=result or 'done'
        if f.callback then f.callback(s.last_result) end
    end
    return f
end

-- No activity quest is required; the optional visit task still runs once.
do
    local f=fixture(); f:steps(4); eq(f.triggers,1); eq(f.status.managed_by,'WarPigs')
    eq(f.o.is_busy(),true); eq(f.guard(),true)
    local old_callback=f.callback
    f:finish(); f:steps(10); eq(f.triggers,1); eq(f.o.is_busy(),false)
    f.zone='AnotherTown'; f:steps(4); eq(f.triggers,1)
    f.zone='Skov_Temis'; f:steps(4); eq(f.triggers,2)
    old_callback('done'); eq(f.o.is_busy(),true,'stale callback cannot finish new request')
    f:finish(); f:tick(); eq(f.o.release_all(),true); eq(f.status.managed_by,nil)
end
-- Loading and empty zone snapshots cannot manufacture a visit.
do
    local f=fixture(); f:steps(4); f:finish(); f:tick()
    f.zone=''; f.world='Limbo'; f:steps(5)
    f.zone='Skov_Temis'; f.world='Town'; f:steps(5); eq(f.triggers,1)
end
-- Other towns are ignored, including the old Tree of Whispers zone.
do
    local f=fixture(); f.zone='Hawe_TreeOfWhispers'; f:steps(10); eq(f.triggers,0)
    f.zone='Skov_Temis'; f:steps(4); eq(f.triggers,1)
end
-- Town Looter owns pickup before Tyrael navigation or Alfred triggers.
do
    local f=fixture(); f.status.enabled=false
    f.quests={'WarPlans_QST_TurnIn_Rewards'}
    local busy=true; local alfred_triggers=0
    LooteerPlugin={is_actively_looting=function() return busy end}
    AlfredTheButlerPlugin={get_status=function() return {enabled=true,need_trigger=true} end,
        trigger_tasks=function() alfred_triggers=alfred_triggers+1 end}
    f:steps(10); eq(f.task_calls,0); eq(alfred_triggers,0); eq(f.triggers,0)
    AlfredTheButlerPlugin=nil; busy=false; f:steps(4); assert(f.task_calls>0)
end
-- Town Looter also blocks the original teleport preamble, even without Raven.
do
    local f=fixture(); f.status.enabled=false; f.settings.use_teleport_transition=true
    f.quests={'WarPlans_QST_ThePit'}
    LooteerPlugin={is_actively_looting=function() return true end}
    f:steps(20); eq(f.teleport,0); eq(f.waypoint,0); eq(f.triggers,0)
end
-- Newly competing navigation cancels only our Raven request, preserving path.
do
    local f=fixture(); f:steps(4)
    LooteerPlugin={is_actively_looting=function() return true end}
    eq(f.guard(),false); f:tick(); eq(f.cancels,1); eq(f.preserve,true)
    eq(f.triggers,1)
end
-- Unknown companion data never authorizes the new NPC task.
do
    local f=fixture(); AlfredTheButlerPlugin={get_status=function() error('unknown') end}
    f:steps(50); eq(f.triggers,0)
end
-- Legacy false-as-nil getters and modern active override are both supported.
do
    fixture()
    LooteerPlugin={getSettings=function(key) if key=='looting' then return true end end}
    eq(Bridge.looter_state(),false,'disabled legacy Looter stale flag')
    LooteerPlugin={getSettings=function(key) if key=='enabled' then return true end end}
    eq(Bridge.looter_state(),false,'enabled legacy Looter idle nil')
    LooteerPlugin={is_actively_looting=function() return false end,
        getSettings=function() return true end}
    eq(Bridge.looter_state(),false,'modern explicit idle wins sticky legacy')
    LooteerPlugin={getSettings=function() error('missing') end}
    eq(Bridge.looter_state(),nil,'failed read is unknown')
end
-- Master stop revokes the live guard even when public cancel throws.
do
    local f=fixture(); f:steps(4); f.cancel_error=true
    eq(f.o.release_all(),false); eq(f.guard(),false); eq(f.status.managed_by,'WarPigs')
    f.cancel_error=false; eq(f.o.release_all(),true); eq(f.status.managed_by,nil)
end
-- A lost status response cannot abandon a held management lease.
do
    local f=fixture(); f:steps(4); f:finish(); f:tick(); f.status_error=true
    eq(f.o.release_all(),false); eq(f.status.managed_by,'WarPigs')
    f.status_error=false; eq(f.o.release_all(),true); eq(f.status.managed_by,nil)
end
-- Do not hijack a caller already using Raven, or overwrite its callback.
do
    local f=fixture(); f.status.pending=true; f.status.owner='AnotherCaller'
    f.quests={'WarPlans_QST_TurnIn_Rewards'}; f:steps(8)
    eq(f.triggers,0); eq(f.cancels,0); eq(f.task_calls,0); eq(f.status.owner,'AnotherCaller')
end
-- An active WarPug confirmation retains priority; an idle planner waits for us.
do
    local f=fixture(); local planner='CONFIRMING'
    WarPugPlugin={status=function() return {enabled=true,state=planner} end}
    f:steps(5); eq(f.triggers,0); eq(f.o.is_busy(),false,'do not interrupt current planner transaction')
    planner='IDLE'; eq(f.o.is_busy(),true,'reserve Whisper slot before starting a new plan')
    f:steps(3); eq(f.triggers,1); f:finish(); f:tick(); eq(f.o.is_busy(),false)
end
-- Preamble holds actual activity teleport until the reward request completes.
do
    local f=fixture(); f.settings.use_teleport_transition=true
    f.quests={'WarPlans_QST_ThePit'}; f:steps(12)
    eq(f.triggers,1); eq(f.teleport,0)
    f:finish(); f:steps(2); eq(f.teleport,1)
end
-- Internal Tyrael work already in progress finishes before a new Raven task.
do
    local f=fixture(); f.task_state='APPROACH_NPC'; f.quests={'WarPlans_QST_TurnIn_Rewards'}
    f:steps(8); eq(f.triggers,0); assert(f.task_calls>0)
    f.task_state='IDLE'; f.quests={}; f:steps(4); eq(f.triggers,1)
end
-- External WarPigs status and stop keep their own controller after load.
do
    local calls=0
    local controller={is_busy=function() return true end, alfred_idle=function() return true end,
        release_all=function() calls=calls+1; return true end}
    local gui={elements={main_toggle={get=function() return true end,set=function() end}}}
    local settings={get_keybind_state=function() return true end,update_settings=function() end}
    local imports={gui=gui,['core.settings']=settings,['core.orchestrator']=controller}
    local env=setmetatable({require=function(name) return assert(imports[name]) end},{__index=_G})
    local external=assert(loadfile(root..'core/external.lua','t',env))()
    env.require=function() error('foreign require context') end
    eq(external.status().busy,true); eq(external.disable(),true); eq(calls,1)
end
print('PASS WarPigs/SilentRaven: ' .. checks .. ' assertions across visit, ownership and town handoff scenarios')
