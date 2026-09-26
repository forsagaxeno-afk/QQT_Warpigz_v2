-- Preserved prior regression suite; only runner paths adapted.
ROOT = assert(SUITE_ROOT) .. '/HordeDev-1.3.9'
package.path = ROOT .. '/?.lua;' .. ROOT .. '/?/init.lua;' .. package.path
local n = 0
local function eq(actual, expected, why)
    n = n + 1
    assert(actual == expected, (why or "mismatch") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function ok(value, why) eq(not not value, true, why) end
local function fresh()
    for name in pairs(package.loaded) do
        if name:match("^core%.") or name:match("^tasks%.") or name=="gui" or name=="Meteor" or name=="data.enums" then package.loaded[name]=nil end
    end
    local s={time=10,zone="S05_BSK_Prototype02",name="S05_BSK_Prototype02",id=42,leaves=0,resets=0,teleports=0,stops=0,clears=0,bm_clears=0,long_stops=0,logs={},aether=0,stash=true}
    console={print=function(line) s.logs[#s.logs+1]=line end}
    vec3={new=function(_,x,y,z) return {x=function() return x end,y=function() return y end,z=function() return z end} end}
    local player={is_dead=function() return s.dead==true end,get_position=function() return vec3:new(1,2,3) end,
        get_active_spell_id=function() return s.casting and 186139 or 0 end}
    local world={get_name=function() return s.name end,get_current_zone_name=function() return s.zone end,get_world_id=function() return s.id end}
    get_local_player=function() if not s.no_player then return player end end
    get_current_world=function() if s.world_error then error("unavailable") end; if not s.no_world then return world end end
    get_time_since_inject=function() return s.time end
    get_aether_count=function() return s.aether end
    leave_dungeon=function() s.leaves=s.leaves+1; eq(s.zone,"S05_BSK_Prototype02","leave only original activity"); if s.leave_error then error("leave refused") end; return s.leave_result end
    reset_all_dungeons=function() s.resets=s.resets+1; eq(s.zone,"Kehj_Caldeum","never reset inside Horde"); if s.reset_error then error("reset refused") end; return s.reset_result end
    teleport_to_waypoint=function(id) eq(id,99); s.teleports=s.teleports+1 end
    pathfinder={clear_stored_path=function() s.clears=s.clears+1;return s.clear_result end,request_move=function() s.stops=s.stops+1 end}
    BatmobilePlugin={is_long_path_navigating=function() return true end,stop_long_path=function() s.long_stops=s.long_stops+1 end,pause=function() end,clear_target=function() s.bm_clears=s.bm_clears+1 end}
    local settings={exit_mode=0,aggresive_movement=true,enabled=true,update_settings=function() end}
    local explorer={is_task_running=false}
    package.loaded['core.settings']=settings
    package.loaded['core.explorer']=explorer
    package.loaded['core.utils']={get_stash=function() if s.stash then return {} end end,player_in_zone=function(zone) return s.zone==zone end,get_keybind_state=function() return true end}
    package.loaded['data.enums']={waypoints={LIBRARY=99}}
    local tracker=require('core.tracker')
    tracker.finished_chest_looting=true;tracker.horde_opened=true;tracker.sigil_used=true;tracker.boss_killed=true
    local task=require('tasks.exit_horde')
    s.settings,s.tracker,s.task,s.explorer=settings,tracker,task,explorer
    function s:tick(t) self.time=t; if self.task.shouldExecute() then self.task:Execute() end end
    function s:outside() self.zone="Kehj_Caldeum";self.name="Sanctuary";self.id=43 end
    return s
end

-- Completion flags alone still need stash visibility and fully spent aether.
do
    local s=fresh(); s.aether=1; eq(s.task.shouldExecute(),false)
    s.aether=0;s.stash=false;eq(s.task.shouldExecute(),false)
    s.stash=true;s.tracker.finished_chest_looting=false;eq(s.task.shouldExecute(),false)
    s.tracker.finished_chest_looting=true;s:tick(10)
    eq(s.tracker.reset_exit_pending,true);eq(s.explorer.is_task_running,true)
    eq(s.stops,1);eq(s.long_stops,1);eq(s.leaves,0)
    s:tick(10.5);eq(s.leaves,1);eq(s.resets,0)
    for i=1,40 do s:tick(10.5+i*0.1) end
    eq(s.leaves,1,"no per-frame leave spam");eq(s.stops,1,"no movement interrupts the channel");eq(s.resets,0)
    s:outside();s.stash=false;s:tick(15);eq(s.task.shouldExecute(),true,"exit survives zone/stash change")
    s:tick(16.9);eq(s.resets,0);eq(s.tracker.horde_opened,true)
    s:tick(17);eq(s.resets,1);eq(s.tracker.reset_exit_pending,true)
    s:tick(18.9);eq(s.tracker.sigil_used,true)
    s:tick(19);eq(s.tracker.reset_exit_pending,false);eq(s.tracker.horde_opened,false);eq(s.tracker.sigil_used,false)
    eq(s.task.reset_complete,true);eq(s.explorer.is_task_running,false);eq(s.teleports,0)
    s:tick(25);eq(s.resets,1,"reset sent once")
end

-- Loading, missing world/player and a stale BSK world name never prove departure.
do
    local s=fresh();s:tick(10);s:tick(10.5);s:outside()
    s.no_world=true;s:tick(11);s:tick(13);eq(s.resets,0)
    s.no_world=false;s.name="Loading";s:tick(14);s:tick(17);eq(s.resets,0)
    s.name="S05_BSK_Prototype02";s:tick(18);s:tick(21);eq(s.resets,0)
    s.name="Sanctuary";s.no_player=true;s:tick(22);eq(s.resets,0)
    s.no_player=false;s:tick(23);s.world_error=true;s:tick(24);s.world_error=false;s:tick(25)
    s:tick(26.9);eq(s.resets,0);s:tick(27);eq(s.resets,1)
    s.no_world=true;s:tick(27.5);s.no_world=false;s.id=44;s:tick(28)
    s:tick(29.9);eq(s.tracker.reset_exit_pending,true)
    s:tick(30);eq(s.tracker.reset_exit_pending,false);eq(s.resets,1,"loading after reset cannot duplicate it")
end

-- Outside flicker/world changes must restart the two-second observation.
do
    local s=fresh();s:tick(10);s:tick(10.5);s:outside();s:tick(11)
    s.zone="S05_BSK_Prototype02";s.name="BSK";s:tick(12)
    s:outside();s:tick(13);s.id=44;s:tick(14);s:tick(15.9);eq(s.resets,0)
    s:tick(16);eq(s.resets,1)
end

-- No reset/next cycle when leaving repeatedly fails; fault logs are latched.
do
    local s=fresh();s.leave_result=false;s:tick(10);s:tick(10.5);s:tick(20.5);s:tick(30.5)
    eq(s.leaves,3);eq(s.resets,0);s:tick(40.5);ok(s.task.reset_error)
    local log_count=#s.logs;s:tick(41);s:tick(80);eq(#s.logs,log_count)
    eq(s.tracker.reset_exit_pending,true);eq(s.tracker.horde_opened,true)
    s.task:reset();eq(s.tracker.reset_exit_pending,false);eq(s.explorer.is_task_running,false)
end

-- Missing API, dead/loading time, unexpected destinations and movement refusal.
do
    local s=fresh();leave_dungeon=nil;s:tick(10);s:tick(10.5);eq(s.resets,0);s:tick(70);ok(s.task.reset_error)
    s=fresh();s:tick(10);s.dead=true;s:tick(11);s:outside();s:tick(20);eq(s.resets,0)
    s.dead=false;s:tick(21);s:tick(23);eq(s.resets,1)
    s=fresh();s:tick(10);s:tick(10.5);s.zone="AnotherDungeon";s.name="Pit";s:tick(20);s:tick(70)
    eq(s.resets,0);ok(s.task.reset_error);eq(s.tracker.horde_opened,true)
    s=fresh();s.clear_result=false;s:tick(10);ok(s.task.reset_error);s:tick(20);eq(s.leaves,0);eq(s.resets,0)
end

-- Reset refusal/exception must not consume a new compass or issue repeat resets.
for _, kind in ipairs({'false','throw'}) do
    local s=fresh();s:tick(10);s:tick(10.5);s:outside();s:tick(11)
    if kind=='false' then s.reset_result=false else s.reset_error=true end
    s:tick(13);eq(s.resets,1);ok(s.task.reset_error)
    s:tick(20);eq(s.resets,1);eq(s.tracker.sigil_used,true);eq(s.tracker.reset_exit_pending,true)
end

-- Changing the menu mid-flight cannot convert a committed RESET to a teleport.
do
    local s=fresh();s:tick(10);s.settings.exit_mode=1;s:tick(10.5)
    eq(s.leaves,1);eq(s.teleports,0);s:outside();s:tick(11);s:tick(13);s:tick(15)
    eq(s.resets,1);eq(s.tracker.reset_exit_pending,false)
end

-- TELEPORT keeps a six-second debounce (HRD-10: the suite's waypoint
-- debounce), never re-fires while the channel casts, and does not call Leave/Reset.
do
    local s=fresh();s.settings.exit_mode=1;s:tick(10);eq(s.teleports,1)
    s:tick(11);s:tick(15.9);eq(s.teleports,1);s:tick(16);eq(s.teleports,2)
    eq(s.leaves,0);eq(s.resets,0);eq(s.tracker.reset_exit_pending,false)
    s.casting=true;s:tick(22);s:tick(30.9);eq(s.teleports,2,"no re-fire while the teleport channel casts")
    s:tick(31);eq(s.teleports,3,"a stuck cast id is not trusted forever")
    s.casting=false;s:tick(36.9);eq(s.teleports,3);s:tick(37);eq(s.teleports,4)
end

-- Two consecutive RESET runs; previous state never skips the second leave.
do
    local s=fresh()
    for run=1,2 do
        local t=run*20;s.time=t;s.zone="S05_BSK_Prototype02";s.name="BSK";s.id=42+run
        s.tracker.horde_opened=true;s.tracker.sigil_used=true;s.tracker.finished_chest_looting=true
        s:tick(t);s:tick(t+0.5);s:outside();s:tick(t+2);s:tick(t+4);s:tick(t+6)
        eq(s.leaves,run);eq(s.resets,run);eq(s.task.reset_complete,true)
    end
end

-- Actual scheduler and main plugin contract: prevent higher-priority tasks and
-- an orchestrator's chests_done handoff from overtaking the pending RESET.
do
    local s=fresh();local checks,runs=0,0
    for _,name in ipairs({'alfred','town_salvage','walking_to_horde','open_chests','start_dungeon','enter_horde','horde'}) do
        package.loaded['tasks.'..name]={name=name,shouldExecute=function() checks=checks+1;return s.zone~='S05_BSK_Prototype02' end,
            Execute=function() runs=runs+1 end,reset=function() s.tracker.finished_chest_looting=false end}
    end
    local manager=require('core.task_manager')
    local function toggle() return {set=function() end,get=function() return true end} end
    package.loaded.gui={elements={main_toggle=toggle(),keybind_toggle=toggle()},render=function() end}
    package.loaded.Meteor={initialize=function() end}
    on_update=function() end;on_render=function() end;on_render_menu=function() end
    dofile(ROOT..'/main.lua')
    manager.execute_tasks();eq(s.tracker.reset_exit_pending,true)
    s.time=10.5;manager.execute_tasks();eq(s.leaves,1)
    local before=checks;s:outside();s.time=11;manager.execute_tasks();eq(checks,before);eq(runs,0)
    eq(InfernalHordesPlugin.chests_done(),false,"handoff waits for actual reset")
    s.time=13;manager.execute_tasks();eq(s.resets,1);eq(InfernalHordesPlugin.chests_done(),false)
    s.time=15;manager.execute_tasks();eq(InfernalHordesPlugin.chests_done(),true)
    s.time=15.2;manager.execute_tasks();eq(runs,1,"next task released after reset")
    eq(InfernalHordesPlugin.chests_done(),true,"handoff survives next task selection")
    InfernalHordesPlugin.enable();eq(s.task.reset_complete,false);eq(s.tracker.reset_exit_pending,false)
    eq(s.tracker.finished_chest_looting,false);eq(InfernalHordesPlugin.chests_done(),false)
end
print('PASS: '..n..' assertions (Horde RESET exit flow + scheduler + external handoff)')
