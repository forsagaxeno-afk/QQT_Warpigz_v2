-- Behavioral regressions using actual Reaper modules and QQT-shaped mocks.
local root = SUITE_ROOT .. '/Reaper-main/'
local count = 0
local function eq(actual, expected, message)
    assert(actual == expected, (message or 'unexpected result') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
    count = count + 1
end
local function harness()
    local e = setmetatable({}, {__index = _G})
    e._G = e
    local t, zone, actors = 100, 'Boss_WT4_Duriel', {}
    local controls = {enabled=false, blocked=false, clear=false, teleports=0, resets=0, interactions=0}
    local V = {}; V.__index = V
    function V:x() return self[1] end
    function V:y() return self[2] end
    function V:z() return self[3] end
    function V:dist_to(p) return math.sqrt((self:x()-p:x())^2+(self:y()-p:y())^2+(self:z()-p:z())^2) end
    function V:dist_to_ignore_z(p) return math.sqrt((self:x()-p:x())^2+(self:y()-p:y())^2) end
    function V:is_zero() return self[1]==0 and self[2]==0 and self[3]==0 end
    e.vec3 = {new=function(_, x,y,z) return setmetatable({x,y,z},V) end}
    local position = e.vec3:new(0,0,0)
    local player = {get_position=function() return position end, is_dead=function() return false end,
        get_dungeon_key_items=function() return {} end, get_consumable_items=function() return {} end,
        is_spell_ready=function() return false end}
    e.get_local_player=function() return player end
    e.get_player_position=function() return position end
    e.get_time_since_inject=function() return t end
    e.get_gametime=function() return t end
    e.os=setmetatable({time=function() return t end},{__index=os})
    e.get_current_world=function() if zone==nil then return nil end return {get_current_zone_name=function() return zone end, get_name=function() return zone end} end
    e.actors_manager={get_all_actors=function() return actors end}
    e.console={print=function() end}
    e.target_selector={get_near_target_list=function() return {} end}
    e.pathfinder={request_move=function() end,force_move_raw=function() end}
    e.teleport_to_waypoint=function() controls.teleports=controls.teleports+1 end
    e.teleport_to_boss_dungeon=function() controls.teleports=controls.teleports+1 end
    e.reset_all_dungeons=function() controls.resets=controls.resets+1 end
    e.interact_object=function() controls.interactions=controls.interactions+1 end
    e.loot_manager={interact_with_object=e.interact_object}
    e.cast_spell={position=function() return false end}
    e.utility={send_mouse_click=function() end,set_height_of_valid_position=function(p) return p end,is_point_walkeable=function() return true end}
    e.get_screen_width=function() return 1920 end
    e.get_screen_height=function() return 1080 end
    e.get_quests=function() return {} end
    e.on_render=function() end
    e.on_render_menu=function() end
    e.on_update=function(callback) controls.update=callback end
    local settings={enabled=false,use_alfred=false,use_batmobile=false,town_zone='Town',town_waypoint=1,
        boss_enabled={duriel=true},boss_rotation_mode='manual',boss_target='duriel',
        dungeon_reset_enabled=false,dungeon_reset_interval=2,belial_chest_enabled=false,
        belial_chest={selection_mode='manual',target_boss='duriel',pool={},party_delay=0}}
    function settings:update_settings() self.enabled=controls.enabled end
    settings.orb_set_block=function(value) controls.blocked=value end
    settings.orb_set_clear=function(value) controls.clear=value end
    local toggle={get=function() return controls.enabled end,set=function(_,value) controls.enabled=value end}
    local modules={['core.settings']=settings,['gui']={elements={main_toggle=toggle},render=function() end},
        ['core.explorerlite']={set_custom_target=function() end,move_to_target=function() end,clear_path_and_target=function() end,find_unstuck_target=function() return nil end}}
    e.package={loaded=modules}
    e.require=function(name)
        if modules[name]~=nil then return modules[name] end
        local value=assert(loadfile(root .. name:gsub('%.','/') .. '.lua','t',e))()
        modules[name]=value
        return value
    end
    controls.time=function(value) t=value end
    controls.zone=function(value) zone=value end
    controls.actors=function(value) actors=value end
    controls.position=function(value) position=value end
    controls.actor=function(name, p)
        local a={interactive=true}
        function a:get_skin_name() return name end
        function a:get_position() return p or position end
        function a:is_interactable() return self.interactive end
        return a
    end
    return e, controls, settings, player
end

-- Reuse the exact QQT-shaped harness for focused loader-context regressions.
if REAPER_TEST_HARNESS_ONLY then return harness end

-- Inventory aliases do not double-count the same item, and empty stacks remain empty.
do
    local e,c,s,p=harness()
    local function item(id,sno,n) return {get_acd=function() return id end,get_sno_id=function() return sno end,get_stack_count=function() return n end} end
    local shared=item(1,2556388,3)
    p.get_dungeon_key_items=function() return {shared,item(2,2558255,0)} end
    p.get_consumable_items=function() return {item(1,2556388,3),item(3,2194099,4)} end
    local m=e.require('core.materials')
    local stock=m.scan_keys()
    eq(stock.lair_keys,3,'same item in two inventories')
    eq(stock.greater_lair_keys,0,'zero stack')
    eq(stock.husks,4)
    s.boss_target='varshan'; s.boss_enabled={}
    eq(m.has_inventory_stock(s),true,'manual mode ignores checkboxes')
    local rot=e.require('core.boss_rotation')
    s.boss_rotation_mode='roundrobin'; s.boss_enabled={varshan=true,zir=true}
    rot.build(s); eq(rot.current().id,'varshan')
    rot.consume_run(); eq(rot.current().id,'zir'); eq(rot.pools.lair,2)
    rot.advance('unreachable'); eq(rot.current().id,'varshan','failed boss skipped without consuming shared keys')
    rot.consume_run(); rot.consume_run(); eq(rot.is_done(),true)
    eq(rot.set_external('duriel','sigil'),false,'unsupported sigil must not spend material')
    eq(rot.set_external('duriel','bogus'),false)
    eq(rot.set_external('duriel',nil),true)
    rot.pools.greater=99
    local total=e.require('core.tracker').total_kills
    rot.consume_run(); rot.consume_run()
    eq(rot.is_done(),true,'external stop does not depend on pool')
    eq(e.require('core.tracker').total_kills,total+1,'one-shot counted once')
end

-- Actual scheduler reaches reward handling even with altar_activated set.
do
    local e,c=harness()
    local rot=e.require('core.boss_rotation'); rot.set_external('duriel')
    local tracker=e.require('core.tracker'); tracker.altar_activated=true; tracker.altar_activate_time=1
    local chest=c.actor('EGB_Chest_Reward'); c.actors({chest})
    local manager=e.require('core.task_manager')
    manager.execute_tasks(); eq(c.interactions,1,'chest outranks persistent combat')
    chest.interactive=false; c.time(101); manager.execute_tasks()
    -- A transient gap must not count completion if the chest becomes visible again.
    chest.interactive=true; c.time(105); manager.execute_tasks(); eq(tracker.total_kills,0)
    chest.interactive=false; c.time(106); manager.execute_tasks()
    c.time(110); manager.execute_tasks(); eq(tracker.total_kills,1,'confirmed chest completion')
    manager.reset_all(); eq(tracker.altar_activated,false); eq(c.blocked,false)
end

-- Clock alone cannot count an external boss kill.
do
    local e,c=harness(); local rot=e.require('core.boss_rotation'); rot.set_external('duriel')
    local tracker=e.require('core.tracker'); tracker.altar_activated=true; tracker.altar_activate_time=1
    c.time(999); eq(e.require('tasks.interact_altar').shouldExecute(),false)
    eq(tracker.total_kills,0); eq(rot.is_done(),false)
end

-- Completion callback waits for actual town and cleans up before reentrant run_once.
do
    local e,c=harness(); assert(loadfile(root .. 'main.lua','t',e))()
    local callbacks=0
    eq(e.ReaperPlugin.run_once('duriel',nil,function()
        callbacks=callbacks+1
        eq(e.ReaperPlugin.status().enabled,false,'cleanup before callback')
        eq(e.ReaperPlugin.run_once('varshan'),true,'callback may queue a fresh run')
    end),true)
    eq(e.ReaperPlugin.run_once('zir'),false,'busy request cannot replace callback')
    c.update(); c.time(100.3); c.update(); c.time(100.6); c.update()
    e.require('core.boss_rotation').consume_run()
    c.time(101); c.update(); c.time(150); c.update()
    eq(callbacks,0,'teleport timeout is not success'); eq(c.enabled,true); eq(c.teleports,2,'town teleport retries')
    c.zone('Town'); c.time(151); c.update(); eq(callbacks,1)
    eq(e.require('core.boss_rotation').current().id,'varshan')
    e.ReaperPlugin.disable(); eq(e.ReaperPlugin.status().enabled,false); eq(e.require('core.tracker').altar_activated,false)
    -- A failed run never invokes the success callback.
    e.ReaperPlugin.run_once('duriel',nil,function() callbacks=callbacks+10 end)
    c.time(152); c.update(); c.time(153); c.update()
    e.require('core.boss_rotation').advance('unreachable')
    c.time(154); c.update(); c.time(155); c.update(); eq(callbacks,1)
end

-- QQT exposes coordinate methods; retry math and the DONE phase must work.
do
    local e,c,s=harness(); s.belial_chest_enabled=true; c.zone('Boss_Kehj_Belial')
    local task=e.require('tasks.belial_chest'); local tracker=e.require('core.tracker')
    tracker.belial_chest_interacted=true
    local chest=c.actor('Boss_WT_Belial_Reward',e.vec3:new(1,0,0)); c.actors({chest})
    task.Execute(); c.time(102); task.Execute(); task.Execute(); c.time(103); task.Execute()
    c.time(104); task.Execute(); c.time(105); task.Execute(); c.time(107); task.Execute()
    -- CHECK computed away_pos without attempting arithmetic on coordinate methods.
    eq(task.shouldExecute(),true)
    c.time(111); task.Execute(); chest.interactive=false; task.Execute()
    eq(task.shouldExecute(),true,'DONE must be serviced')
    task.Execute(); eq(task.shouldExecute(),false,'DONE releases priority')
    tracker.belial_chest_interacted=true; eq(task.shouldExecute(),true,'second chest can start')
    task.reset(); tracker.belial_chest_interacted=false; eq(task.shouldExecute(),false)
end

-- Synchronous/stale Alfred callbacks and unlabelled busy ownership.
do
    local e,c,s=harness(); s.use_alfred=true
    local status={enabled=true,need_trigger=true}; local callbacks={}; local triggers=0
    e.AlfredTheButlerPlugin={create_task=function() end,get_status=function() return status end,
        trigger_tasks_with_teleport=function(_,cb) triggers=triggers+1; callbacks[#callbacks+1]=cb; cb() end}
    local task=e.require('tasks.alfred'); task.Execute(); eq(task.status,'idle','synchronous callback')
    eq(task.shouldExecute(),false,'completion grace')
    task.reset(); status.external_trigger=true; status.paused=true; task.Execute(); eq(triggers,1,'busy paused/unlabeled Alfred is not overwritten')
    status.external_trigger=false; status.paused=false
    e.AlfredTheButlerPlugin.trigger_tasks_with_teleport=function(_,cb) callbacks[#callbacks+1]=cb end
    task.Execute(); local old=callbacks[#callbacks]; task.reset(); task.Execute()
    old(); eq(task.status,'waiting for alfred to complete','stale callback cannot release new run')
    callbacks[#callbacks](); eq(task.status,'idle')
end

-- Recorded paths preserve completion and never skip a nearby interaction.
do
    local e,c=harness(); local walker=e.require('core.pathwalker')
    eq(walker.start_walking_path_with_points({e.vec3:new(0,0,0)},'end'),true)
    walker.update_path_walking(); eq(walker.is_path_completed(),true)
    walker.stop_walking(); eq(walker.is_path_completed(),false)
    local portal=c.actor('Traversal_Gizmo',e.vec3:new(0,0,0)); c.actors({portal})
    walker.start_walking_path_with_points({{e.vec3:new(0,0,0),action='interact'},e.vec3:new(8,0,0)},'traversal')
    walker.update_path_walking(); eq(c.interactions,1,'interaction waypoint at current position')
    c.time(103); walker.update_path_walking(); eq(walker.current_waypoint_index,2)
end

-- Known boss aliases and loading screens are handled without guessed identifiers.
do
    local e,c=harness(); local enums=e.require('data.enums'); local utils=e.require('core.utils')
    eq(enums.zone_matches({id='grigoire'},'Boss_WT4_PenitentKnight'),true)
    eq(enums.zone_matches({id='varshan'},'Boss_WT3_Varshan'),true)
    eq(enums.zone_matches({id='varshan'},'Unrelated_Varshan_Town'),false)
    c.zone(nil); eq(utils.get_zone(),''); eq(utils.player_in_zone('Town'),false)
end

-- Periodic reset exits a consecutive same-boss run before resetting dungeons.
do
    local e,c,s=harness(); s.dungeon_reset_enabled=true
    local tracker=e.require('core.tracker'); tracker.total_kills=2
    local task=e.require('tasks.dungeon_reset')
    eq(task.shouldExecute(),true); task.Execute(); eq(c.teleports,1); eq(c.resets,0)
    c.zone('Town'); task.Execute(); task.Execute(); eq(c.resets,1)
    task.reset(); eq(task.shouldExecute(),false)
end
-- Navigation cleanup is issued once for Reaper and cannot erase Alfred's trip.
do
    local e,c,s=harness(); local stops, clears=0,0
    e.BatmobilePlugin={stop_long_path=function() stops=stops+1 end,clear_target=function() clears=clears+1 end}
    local owner=e.require('core.navigation_owner')
    e.require('tasks.navigate_to_boss').reset(); eq(stops,0,'idle nav reset has no foreign side effects')
    owner.claim(); owner.release(); eq(stops,1); eq(clears,1)
    owner.release(); eq(stops,1,'cleanup is once per ownership')
    owner.claim(); e.AlfredTheButlerPlugin={get_status=function() return {enabled=true,external_trigger=true} end}
    owner.release(); eq(stops,1,'Alfred already owns movement')
    eq(owner.active,false)
    -- A new Alfred cycle receives an already-stopped Reaper route.
    s.use_alfred=true; owner.claim()
    e.AlfredTheButlerPlugin={create_task=function() end,get_status=function() return {enabled=true,need_trigger=true} end,
        trigger_tasks_with_teleport=function(_,cb) eq(stops,2,'stop before Alfred starts'); cb() end}
    e.require('tasks.alfred').Execute()
end

print('Reaper behavioral assertions: ' .. count)
