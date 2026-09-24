-- Preserved prior regression suite; only runner paths adapted.
ROOT = assert(SUITE_ROOT) .. '/HordeDev-1.3.9'
package.path = ROOT .. '/?.lua;' .. ROOT .. '/?/init.lua;' .. package.path
local n=0
local function eq(a,b,msg) n=n+1;assert(a==b,(msg or 'mismatch')..': expected '..tostring(b)..', got '..tostring(a)) end
local function ok(v,msg) eq(not not v,true,msg) end
local function fresh()
    for name in pairs(package.loaded) do
        if name:match('^core%.') or name:match('^tasks%.') or name=='gui' or name=='Meteor' or name=='data.enums' then package.loaded[name]=nil end
    end
    local s={t=100,zone='Kehj_Caldeum',world='Sanctuary',id=1,uses=0,confirms=0,interacts=0,chest_resets=0,
        moves=0,portal_reads=0,other_checks=0,other_runs=0,confirms_needed=2,logs={},distance=1,leave_calls=0,reset_calls=0}
    console={print=function(line) s.logs[#s.logs+1]=line end}
    vec3={new=function(_,x,y,z) return {x=function()return x end,y=function()return y end,z=function()return z end} end}
    local position=vec3:new(1,2,3)
    local item={}
    local player={is_dead=function() return s.dead==true end,get_position=function() return position end,
        get_dungeon_key_items=function() s.inventory_reads=(s.inventory_reads or 0)+1;return {item} end}
    local w={get_name=function()return s.world end,get_current_zone_name=function()return s.zone end,get_world_id=function()return s.id end}
    get_time_since_inject=function() return s.t end
    get_local_player=function() if not s.no_player then return player end end
    get_current_world=function() if not s.no_world then return w end end
    get_aether_count=function() return 0 end
    local function native() s.last_native=s.t end
    use_item=function(got) eq(got,item);s.uses=s.uses+1;native();if s.use_error then error('use failed') end;return s.use_result end
    utility={confirm_sigil_notification=function()
        eq(s.zone,'Kehj_Caldeum','confirm only in originating outside zone')
        eq(s.dead==true,false,'never confirm while dead')
        s.confirms=s.confirms+1;native()
        if s.confirm_error then error('confirmation failure') end
        if s.confirms>=s.confirms_needed then s.portal=true end
        return s.confirm_result
    end}
    interact_object=function(portal) eq(portal,s.portal_actor);s.interacts=s.interacts+1;native();if s.interact_error then error('interact failed') end;return s.interact_result end
    leave_dungeon=function()s.leave_calls=s.leave_calls+1 end
    reset_all_dungeons=function()eq(s.zone,'Kehj_Caldeum');s.reset_calls=s.reset_calls+1 end
    teleport_to_waypoint=function()error('no waypoint teleport during activation/entry')end
    pathfinder={clear_stored_path=function() end,request_move=function()s.moves=s.moves+1 end}
    BatmobilePlugin={is_long_path_navigating=function()return false end,pause=function()end,clear_target=function()end}
    local settings={enabled=true,exit_mode=0,use_6_wave=true,aggresive_movement=true,update_settings=function()end}
    local explorer={is_task_running=false}
    package.loaded['core.settings']=settings;package.loaded['core.explorer']=explorer
    s.portal_actor={get_position=function()return position end}
    package.loaded['core.utils']={player_in_zone=function(zone)return s.zone==zone end,
        get_keybind_state=function()return true end,get_stash=function()if s.stash then return {} end end,
        get_consumable_info=function()return {name='S05_DungeonSigil_BSK_Wave6'}end,
        get_horde_portal=function()
            eq(s.last_native==nil or s.t-s.last_native>=3,true,'no actor scan during post-call quiet period')
            s.portal_reads=s.portal_reads+1
            if s.portal_read_error then error('actor unavailable') end
            if s.portal then return s.portal_actor end
        end,distance_to=function()return s.distance end}
    package.loaded['data.enums']={waypoints={LIBRARY=99}}
    local tracker=require('core.tracker');tracker.start_dungeon_time=95
    package.loaded['tasks.open_chests']={name='Open Chests',shouldExecute=function()return false end,
        reset=function()s.chest_resets=s.chest_resets+1;tracker.finished_chest_looting=false end}
    for _,name in ipairs({'alfred','town_salvage','walking_to_horde','horde'}) do
        package.loaded['tasks.'..name]={name=name,shouldExecute=function()s.other_checks=s.other_checks+1;return s.other_ready==name end,
            Execute=function()s.other_runs=s.other_runs+1 end}
    end
    local start=require('tasks.start_dungeon');local entry=require('tasks.enter_horde');local exit=require('tasks.exit_horde')
    local manager=require('core.task_manager')
    s.start,s.entry,s.exit,s.tracker,s.manager,s.explorer=start,entry,exit,tracker,manager,explorer
    function s:tick(t)self.t=t;self.manager.execute_tasks()end
    function s:inside()self.zone='S05_BSK_Prototype02';self.world='S05_BSK_Prototype02';self.id=2 end
    function s:outside()self.zone='Kehj_Caldeum';self.world='Sanctuary';self.id=1 end
    function s:activate()
        self:tick(100);self:tick(103);self:tick(108);self:tick(111);self:tick(112)
        eq(self.tracker.horde_entry_pending,true)
    end
    return s
end

-- Reproduce screenshot: the first void confirmation does nothing. Remain in
-- activation, retry natively, and only move to entry after portal observation.
do
    local s=fresh();s:tick(100);eq(s.uses,1);eq(s.chest_resets,1);eq(s.tracker.horde_opened,false)
    eq(s.tracker.sigil_activation_pending,true);eq(s.explorer.is_task_running,true)
    s.other_ready='walking_to_horde';local before=s.other_checks
    s:tick(102);eq(s.confirms,0);eq(s.portal_reads,0)
    s:tick(103);eq(s.confirms,1);eq(s.tracker.horde_opened,false);eq(s.interacts,0)
    for i=1,20 do s:tick(103+i*0.1) end
    eq(s.confirms,1);eq(s.portal_reads,0);eq(s.other_checks,before)
    s:tick(106);eq(s.tracker.horde_opened,false)
    s:tick(108);eq(s.confirms,2);eq(s.tracker.horde_opened,false)
    s:tick(109);eq(s.interacts,0)
    s:tick(111);eq(s.tracker.horde_opened,false)
    s:tick(112);eq(s.tracker.horde_opened,true);eq(s.tracker.sigil_activation_pending,false)
    eq(s.tracker.horde_entry_pending,true);eq(s.other_checks,before)
    s:tick(112.2);eq(s.interacts,1)
    s:inside();s:tick(114);eq(s.tracker.has_entered,false)
    s:tick(117.3);s:tick(118.4);eq(s.tracker.has_entered,true)
    eq(s.tracker.horde_entry_pending,false);eq(s.explorer.is_task_running,false)
    eq(s.chest_resets,1);eq(s.uses,1);eq(s.interacts,1)
end

-- False native confirmation is not success; repeated failures are bounded.
do
    local s=fresh();s.confirms_needed=999;s.confirm_result=false;s:tick(100)
    for _,t in ipairs({103,108,113,118,123,128,133,140}) do s:tick(t) end
    eq(s.confirms,5);eq(s.uses,1);eq(s.interacts,0);eq(s.tracker.horde_opened,false)
    ok(s.start.activation_error);eq(s.tracker.sigil_activation_pending,true)
    local logs=#s.logs;s:tick(200);eq(#s.logs,logs,'latched error does not flood console')
end

-- Missing API and exceptions stop; a failed use cannot mark a sigil accepted.
for _,kind in ipairs({'use_false','use_error','confirm_error','missing_api'}) do
    local s=fresh()
    if kind=='use_false' then s.use_result=false elseif kind=='use_error' then s.use_error=true
    elseif kind=='confirm_error' then s.confirm_error=true else utility.confirm_sigil_notification=nil end
    s:tick(100);s:tick(103);s:tick(200)
    ok(s.start.activation_error);eq(s.uses,1);eq(s.tracker.horde_opened,false);eq(s.chest_resets,kind:match('^use') and 0 or 1)
    eq(s.interacts,0)
end

-- Loading/death/wrong-zone snapshots cannot click a dialog or validate a portal.
do
    local s=fresh();s:tick(100);s.no_world=true;s:tick(103);eq(s.confirms,0)
    s.no_world=false;s.world='Loading';s:tick(108);eq(s.confirms,0)
    s.world='Sanctuary';s.dead=true;s:tick(110);eq(s.confirms,0)
    s.dead=false;s.zone='AnotherActivity';s:tick(112);eq(s.confirms,0)
    s:outside();s.id=999;s:tick(114);eq(s.confirms,0,'different source world cannot confirm')
    s:outside();s:tick(116);eq(s.confirms,1)
    s.no_player=true;s:tick(121);eq(s.confirms,1)
    s.no_player=false;s:tick(122);eq(s.confirms,2)
    s:tick(125);s.no_world=true;s:tick(125.5);s.no_world=false;s:tick(126)
    eq(s.tracker.horde_opened,false);s:tick(127);eq(s.tracker.horde_opened,true)
end

-- Direct Horde arrival is sufficient; no phantom portal or extra confirm needed.
do
    local s=fresh();s:tick(100);s:inside();s:tick(103);eq(s.tracker.has_entered,false)
    s:tick(104);eq(s.tracker.has_entered,true);eq(s.tracker.horde_opened,true)
    eq(s.tracker.sigil_activation_pending,false);eq(s.confirms,0);eq(s.uses,1)
end

-- Portal visibility must remain stable; API result alone never hands off.
do
    local s=fresh();s.confirms_needed=1;s:tick(100);s:tick(103);s:tick(106)
    eq(s.tracker.horde_opened,false);s.portal=false;s:tick(106.5);s.portal=true;s:tick(107)
    eq(s.tracker.horde_opened,false);s:tick(108);eq(s.tracker.horde_opened,true)
    eq(s.confirms,1)
end

-- Approach, stop, interact once, wait; no repeated chest flag reset or click spam.
do
    local s=fresh();s:activate();s.distance=5;s:tick(112.2);eq(s.interacts,0)
    s.distance=1;s:tick(112.4);eq(s.interacts,0)
    s:tick(113);eq(s.interacts,1);local reads=s.portal_reads;local moves=s.moves
    for i=1,20 do s:tick(113+i*0.1) end
    eq(s.portal_reads,reads);eq(s.interacts,1);eq(s.moves,moves);eq(s.chest_resets,1)
    s.portal=false;s:tick(118);local count=#s.logs
    s:tick(119);s:tick(120);eq(#s.logs,count,'missing portal wait logs once')
    s:tick(158);ok(s.entry.entry_error);eq(s.tracker.horde_entry_pending,true);eq(s.uses,1)
end

-- Interactions returning false are spaced and capped; thrown errors are latched.
do
    local s=fresh();s:activate();s.interact_result=false
    for _,t in ipairs({112.2,117.3,122.4,127.5,132.6,137.7}) do s:tick(t) end
    eq(s.interacts,5);ok(s.entry.entry_error);eq(s.chest_resets,1)
    s=fresh();s:activate();s.interact_error=true;s:tick(112.2);ok(s.entry.entry_error)
    s:tick(130);eq(s.interacts,1)
end

-- Real reset -> activation -> entry chain with no manual accept or extra compass.
do
    local s=fresh();s:inside();s.stash=true;s.tracker.finished_chest_looting=true
    s.tracker.horde_opened,s.tracker.sigil_used=true,true
    s:tick(100);s:tick(100.5);eq(s.leave_calls,1)
    s:outside();s:tick(101);s:tick(103);eq(s.reset_calls,1)
    s:tick(105);eq(s.tracker.reset_exit_pending,false)
    s:tick(106);s:tick(111);eq(s.uses,1)
    s:tick(114);s:tick(119);s:tick(122);s:tick(123);s:tick(123.2)
    eq(s.interacts,1);eq(s.reset_calls,1);eq(s.chest_resets,1)
    s:inside();s:tick(128.3);s:tick(129.4);eq(s.tracker.has_entered,true)
    eq(s.tracker.horde_entry_pending,false);eq(s.uses,1)
    -- Explicit new cycle resets entry timers and permits exactly one new use.
    s.start:reset();s.entry:reset();s.tracker.fresh_run_reset();s:outside();s.stash=false
    s:tick(140);s:tick(145);eq(s.uses,2);eq(s.tracker.sigil_activation_pending,true)
end

-- Main plugin lifecycle and handoff include both activation and entry ownership.
-- The toggles are stateful (off until an external enable) so that enable() is
-- a fresh activation here; R8: an enable() while already on and inside a
-- healthy run keeps it, and disable()+enable() is the restart.
do
    local s=fresh();local function toggle()local t={v=false};function t:set(v)self.v=v end;function t:get()return self.v end;return t end
    package.loaded.gui={elements={main_toggle=toggle(),keybind_toggle=toggle()},render=function()end}
    package.loaded.Meteor={initialize=function()end}
    on_update=function()end;on_render=function()end;on_render_menu=function()end
    dofile(ROOT..'/main.lua')
    s:tick(100);eq(InfernalHordesPlugin.chests_done(),false)
    s:tick(103);s:tick(108);s:tick(111);s:tick(112);eq(InfernalHordesPlugin.chests_done(),false)
    InfernalHordesPlugin.enable();eq(s.tracker.sigil_activation_pending,false);eq(s.tracker.horde_entry_pending,false)
    eq(s.explorer.is_task_running,false);eq(s.start.activation_phase,nil);eq(s.entry.entry_phase,nil)
    s.tracker.horde_entry_pending=true -- a healthy entry of the next run
    InfernalHordesPlugin.enable();eq(s.tracker.horde_entry_pending,true,'R8: re-enable while on keeps the pending entry')
    InfernalHordesPlugin.disable();InfernalHordesPlugin.enable()
    eq(s.tracker.horde_entry_pending,false,'disable()+enable() restarts');eq(s.entry.entry_phase,nil)
end
print('PASS: '..n..' assertions (sigil confirmation, portal entry, loading and complete reset/start cycle)')
