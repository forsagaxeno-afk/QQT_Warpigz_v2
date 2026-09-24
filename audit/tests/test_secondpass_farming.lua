local root=assert(SUITE_ROOT)..'/HordeDev-1.3.9/'
local count=0
local function test(name,fn)
    local ok,err=pcall(fn);assert(ok,name..': '..tostring(err));count=count+1
end
local v={};v.__index=v
function v:new(x,y,z)return setmetatable({xx=x,yy=y,zz=z or 0},v)end
function v:x()return self.xx end;function v:y()return self.yy end;function v:z()return self.zz end
function v:dist_to(p)return math.sqrt((self.xx-p:x())^2+(self.yy-p:y())^2+(self.zz-p:z())^2)end
v.dist_to_ignore_z=v.dist_to
local function session()
 local s={now=100,pos=v:new(0,0),zone='S05_BSK_Prototype02',world='BSK',dead=false,teleports=0,revives=0,walk_checks=0,pulses=0,updates={}}
 local settings={enabled=true,exit_mode=1,wait_loot_delay=2,aggresive_movement=true,manage_orbwalker=false,reset_time=600,update_settings=function()end}
 local player={is_dead=function()return s.dead end,get_position=function()return s.pos end}
 local world={get_name=function()return s.world end,get_current_zone_name=function()return s.zone end,get_world_id=function()return 1 end}
 local explorer={is_task_running=false,clear_path_and_target=function()end}
 local control={set=function()end,get=function()return true end}
 local modules={['core.settings']=settings,['core.explorer']=explorer,['gui']={elements={main_toggle=control,keybind_toggle=control},render=function()end},
  ['data.enums']={waypoints={LIBRARY=9},chest_types={GOLD='Gold'}},['Meteor']={initialize=function()end},['tasks.town_salvage']={reset=function()end}}
 local env=setmetatable({vec3=v,get_local_player=function()return player end,get_player_position=function()return s.pos end,
  get_current_world=function()return world end,get_time_since_inject=function()return s.now end,get_aether_count=function()return 0 end,
  console={print=function()end},on_update=function(fn)s.updates[#s.updates+1]=fn end,on_render=function()end,on_render_menu=function()end,
  pathfinder={clear_stored_path=function()end,request_move=function()end},teleport_to_waypoint=function()s.teleports=s.teleports+1 end,
  revive_at_checkpoint=function()s.revives=s.revives+1 end,utility={set_height_of_valid_position=function(p)return p end,
   is_point_walkeable=function()s.walk_checks=s.walk_checks+1;return true end}}, {__index=_G})
 env._G=env
 modules['core.utils']={player_in_zone=function(z)return s.zone==z end,get_stash=function()return {}end,get_chest=function()return {}end,
  get_keybind_state=function()return true end}
 function s.load(name)
  if not modules[name] then modules[name]=assert(loadfile(root..name:gsub('%.','/')..'.lua','t',env))() end
  return modules[name]
 end
 env.require=s.load
 s.env,s.modules,s.settings=env,modules,settings
 return s
end

test('Horde chest cleanup waits through live Looter work and fresh quiet period',function()
 local s=session();local task=s.load('tasks.open_chests');local tr=s.load('core.tracker')
 local busy=true;s.env.LooteerPlugin={get_enabled=function()return true end,is_actively_looting=function()return busy end}
 task.current_state='WAITING_FOR_LOOT';task.last_opened_type='MATERIALS'
 task:wait_for_loot();s.now=110;task:wait_for_loot();task:finish_chest_opening()
 assert(task.current_state=='WAITING_FOR_LOOT' and not tr.finished_chest_looting)
 busy=false;s.now=111;task:wait_for_loot();s.now=113.9;task:wait_for_loot();assert(task.current_state=='WAITING_FOR_LOOT')
 s.now=114;task:wait_for_loot();task:finish_chest_opening();assert(tr.finished_chest_looting)
end)

test('late pickup retains chest ownership and blocks first exit request',function()
 local s=session();local tr=s.load('core.tracker');local task=s.load('tasks.open_chests');local exit=s.load('tasks.exit_horde')
 local busy=false;s.env.LooteerPlugin={get_enabled=function()return true end,is_actively_looting=function()return busy end}
 task.current_state='FINISHED';task:finish_chest_opening();s.now=104;task:finish_chest_opening();assert(tr.finished_chest_looting)
 busy=true;assert(task.shouldExecute() and not exit.shouldExecute());exit:Execute();assert(s.teleports==0)
 busy=false;s.now=105;assert(task.shouldExecute());s.now=108;assert(not task.shouldExecute() and exit.shouldExecute())
 exit:Execute();assert(s.teleports==1)
 -- Once a native teleport channel is committed, other tasks cannot reclaim it.
 busy=true;s.now=108.1;assert(not task.shouldExecute());assert(exit.shouldExecute());exit:Execute();assert(s.teleports==1)
end)

test('Horde Looter compatibility handles actual V2 nil getter and unknown failures',function()
 local s=session();local guard=s.load('core.loot_guard');local values={enabled=false,looting=true}
 s.env.LooteerPlugin={getSettings=function(k)return values[k] or nil end}
 assert(not guard.busy());values.enabled=true;values.looting=false;assert(not guard.busy())
 values.looting=true;assert(guard.busy())
 s.env.LooteerPlugin={is_actively_looting=function()error('bad')end,is_idle=function()return true end};assert(not guard.busy())
 s.env.LooteerPlugin.is_idle=function()return 'unknown'end;assert(guard.busy())
end)

test('Horde explorer callback avoids unused volume scans and duplicate revival',function()
 local s=session();s.modules['core.explorer']=nil;s.load('core.explorer')
 assert(#s.updates==1);s.updates[1]();assert(s.walk_checks==0)
 s.now=101;s.updates[1]();assert(s.walk_checks==0)
 s.dead=true;s.now=130;s.updates[1]();assert(s.revives==0 and s.walk_checks==0)
 s.dead=false;s.world=nil;s.updates[1]();s.world='Loading_World';s.updates[1]();s.world='BSK';s.pos=nil;s.updates[1]()
end)

test('actual Horde main callback debounces revival and rejects loading snapshots',function()
 local s=session();s.modules['core.task_manager']={execute_tasks=function()s.pulses=s.pulses+1 end,stop=function()end,get_current_task=function()return {}end}
 for _,name in ipairs({'tasks.exit_horde','tasks.start_dungeon','tasks.enter_horde','tasks.open_chests'})do s.modules[name]={reset=function()end}end
 assert(loadfile(root..'main.lua','t',s.env))();assert(#s.updates==1)
 s.dead=true
 for i=0,9 do s.now=100+i/10;s.updates[1]()end
 assert(s.revives==1 and s.pulses==0)
 s.now=101;s.updates[1]();assert(s.revives==2)
 s.dead=false;s.now=101.1;s.updates[1]();assert(s.pulses==1)
 s.dead=true;s.now=101.2;s.updates[1]();assert(s.revives==3)
 s.world='Loading_World';s.now=110;s.updates[1]();assert(s.revives==3)
 s.world=nil;s.updates[1]();assert(s.revives==3)
end)

local helltide_root=assert(SUITE_ROOT)..'/HelltideRevamped-0.4/'
local function helltide_session()
    local state = {now=100,cinders=100,actors={},loot={},pos=v:new(0,0),zone='Test_Zone',world='Test_World',
        in_helltide=true,active=true,teleports={},interactions={},logs={},moves=0,stops=0,pauses=0,resets=0,revives=0,clears=0,dead=false}
    local settings = {enabled=true,helltide_chest=true,kill_monsters=false,kill_monsters_rarity=0,farm_cinder_threshold=0,salvage=false,
        town_zone='HOME',town_waypoint=999,apply_cinder_orb_gate=function() end,orb_set_clear=function() end,
        orb_set_block=function() end,force_orb_clear_for=function() end,orb_release=function() end}
    local modules = {['core.settings']=settings,['core.perf']=setmetatable({}, {__index=function() return function() end end}),
        ['core.helltide_explorer']=setmetatable({}, {__index=function() return function() end end})}
    local player = {get_position=function() return state.pos end,get_current_speed=function() return 0 end,
        is_dead=function() return state.dead end,get_item_count=function() return 0 end,get_buffs=function() return {} end}
    local world = {get_name=function() return state.world end,get_current_zone_name=function() return state.zone end}
    local env = setmetatable({vec3=v,get_time_since_inject=function() return state.now end,
        get_helltide_coin_cinders=function() return state.cinders end,
        get_player_position=function() return state.pos end,get_local_player=function() return player end,
        get_current_world=function() return world end,on_render=function() end,on_update=function() end,
        console={print=function(s) state.logs[#state.logs+1]=s end},
        target_selector={get_near_target_list=function() return {} end},
        actors_manager={get_all_actors=function() return state.actors end,get_enemy_actors=function() return {} end},
        loot_manager={get_all_items_chest_sort_by_distance=function() return state.loot end},
        utility={set_height_of_valid_position=function(p) return p end,is_point_walkeable=function() return true end},
        pathfinder={request_move=function(pos) state.moves=state.moves+1;state.current_target=pos end,
            clear_stored_path=function()state.clears=state.clears+1;state.current_target=nil end},
        revive_at_checkpoint=function()state.revives=state.revives+1 end,
        teleport_to_waypoint=function(id) state.teleports[#state.teleports+1]=id end,
        interact_object=function(a) state.interactions[#state.interactions+1]=a end,
        BatmobilePlugin={pause=function() state.pauses=state.pauses+1 end,resume=function() end,
            clear_target=function() end,stop_long_path=function() state.stops=state.stops+1 end,
            set_target=function() return true end,update=function() end,move=function() state.moves=state.moves+1 end,
            is_paused=function() return false end,is_done=function() return false end,
            reset=function() state.resets=state.resets+1 end,reset_movement=function() end,
            get_target=function() return nil end}}, {__index=_G})
    env._G = env
    env.require = function(name)
        if modules[name] then return modules[name] end
        modules[name] = assert(loadfile(helltide_root .. name:gsub('%.','/') .. '.lua','t',env))()
        return modules[name]
    end
    modules['core.utils'] = {
        distance_to=function(a) return state.pos:dist_to(a.get_position and a:get_position() or a) end,
        is_in_helltide=function() return state.in_helltide end,helltide_active=function() return state.active end,
        player_in_region=function(prefix) return state.zone:sub(1,#prefix) == prefix end,
        player_in_zone=function(zone) return state.zone == zone end,
        do_events=function() return false end,is_inventory_full=function() return false end,
        alfred_available=function() return false end,check_cinders=function(name) return state.cinders >= env.require('data.enums').chest_types[name] end,
        is_teleporting=function() return false end,have_whispering_key=function() return false end}
    return env,state,settings,modules
end

local function actor(skin,x,z)
 local a={pos=v:new(x,0,z),skin=skin,interactable=true}
 function a:get_position()return self.pos end
 function a:get_skin_name()return self.skin end
 function a:is_interactable()return self.interactable end
 return a
end

test('Helltide Maiden preserves the full charge window before retry',function()
 local env,s,settings=helltide_session();settings.do_maiden=true
 local altar=actor('S04_SMP_Succuboss_Altar_A_Dyn',0);s.actors={altar}
 env.get_helltide_coin_hearts=function()return 3 end
 local task=env.require('tasks.helltide');task:at_maiden();assert(#s.interactions==1)
 for _,t in ipairs({101.5,102.9,103,104.4})do s.now=t;task:at_maiden();assert(#s.interactions==1)end
 s.now=104.5;task:at_maiden();assert(#s.interactions==2)
end)

test('Helltide farming/search share a bounded revival owner',function()
 local env,s=helltide_session();local farm=env.require('tasks.helltide');local search=env.require('tasks.search_helltide')
 s.dead=true
 for i=0,9 do s.now=100+i/10;if i%2==0 then farm:Execute()else search:Execute()end end
 assert(s.revives==1);s.now=101;search:Execute();farm:Execute();assert(s.revives==2)
 s.dead=false;env.LooteerPlugin={get_enabled=function()return true end,is_actively_looting=function()return true end}
 farm:Execute();s.dead=true;s.now=101.1;farm:Execute();assert(s.revives==3)
end)

test('Helltide native fallback releases only its own path on Looter and suspend',function()
 local env,s=helltide_session();env.BatmobilePlugin=nil
 s.actors={actor('usz_rewardGizmo_ChestArmor',20)}
 local task=env.require('tasks.helltide');task:initiate_waypoints();task:explore_helltide();task:move_to_helltide_chest()
 assert(s.moves>0 and s.clears==0)
 env.LooteerPlugin={get_enabled=function()return true end,is_actively_looting=function()return true end}
 local loot_target=v:new(99,0);env.pathfinder.request_move(loot_target) -- Looteer update runs first
 task:Execute();assert(s.clears==0 and s.current_target==loot_target)
 task:Execute();task:suspend();assert(s.clears==0 and s.current_target==loot_target)
 env.LooteerPlugin=nil;task:move_to_helltide_chest();task:suspend();assert(s.clears==1 and s.current_target==nil)
 for _,flag in ipairs({'trigger_tasks','external_trigger','running','pending'})do
  task:move_to_helltide_chest()
  env.AlfredTheButlerPlugin={get_status=function()return {enabled=true,[flag]=true}end}
  local town_target=v:new(500,500);env.pathfinder.request_move(town_target) -- companion owns the replacement
  task:suspend();task:suspend();assert(s.clears==1 and s.current_target==town_target,flag)
 end
end)

test('Horde chest release preserves a companion replacement path before its next tick',function()
 local s=session();local target,clears=nil,0
 s.env.pathfinder.request_move=function(p)target=p end
 s.env.pathfinder.clear_stored_path=function()clears=clears+1;target=nil end
 local movement=s.load('core.movement');local chest=s.load('tasks.open_chests')
 movement.claim(false);s.env.pathfinder.request_move(v:new(20,0))
 s.env.LooteerPlugin={get_enabled=function()return true end,is_actively_looting=function()return true end}
 local loot_target=v:new(21,1);s.env.pathfinder.request_move(loot_target)
 chest:try_next_chest(true);assert(target==loot_target and clears==0)
 movement.stop();assert(target==loot_target and clears==0)
 s.env.LooteerPlugin=nil;movement.claim(false);s.env.pathfinder.request_move(v:new(30,0));movement.stop()
 assert(target==nil and clears==1)
end)

test('Helltide and Horde hold unreadable modern Looter status without losing legacy nil-idle',function()
 for _,make in ipairs({function()local s=session();return s.env,s.load('core.loot_guard')end,
  function()local env=helltide_session();return env,env.require('core.loot_guard')end})do
  local env,guard=make()
  env.LooteerPlugin={get_enabled=function()return true end,is_actively_looting=function()error('loading')end,
   getSettings=function()return nil end}
  assert(guard.busy())
  env.LooteerPlugin.is_idle=function()return true end;assert(not guard.busy())
  env.LooteerPlugin={get_enabled=function()error('loading')end,getSettings=function()return nil end};assert(guard.busy())
  env.LooteerPlugin={getSettings=function(k)if k=='enabled'then return true end end};assert(not guard.busy())
 end
end)

local function grid_session()
 local env,s,settings,modules=helltide_session();modules['core.helltide_explorer']=nil
 env.require('core.tracker').waypoints={v:new(0,0)}
 local grid=env.require('core.helltide_explorer');grid.init()
 return grid,s
end

test('experimental Helltide grid never reselects a fully blacklisted node set',function()
 local grid,s=grid_session();local pos=v:new(1000,1000)
 local total=grid.get_stats().total;assert(total>0)
 for _=1,total do assert(grid.get_target(pos));grid.mark_active_unreachable()end
 assert(grid.get_stats().unreachable==total);assert(grid.get_target(pos)==nil)
end)

test('experimental Helltide grid returns finite coordinates for another floor directly below',function()
 local grid,s=grid_session();local target=assert(grid.get_target(v:new(0,0,100)))
 assert(target:x()==0 and target:y()==0 and target:z()==0)
end)

local function find_upvalue(fn,wanted,seen)
 seen=seen or {};if seen[fn]then return end;seen[fn]=true
 for i=1,100 do
  local name,value=debug.getupvalue(fn,i);if not name then break end
  if name==wanted then return value end
  if type(value)=='function'then local got=find_upvalue(value,wanted,seen);if got then return got end end
 end
end

test('Helltide traversal recovery clears the actual selection blacklist without a global write',function()
 local env,s,settings=helltide_session();settings.prioritize_traversals=true;settings.helltide_chest=false
 s.actors={actor('Traversal_Gizmo_Test',20)}
 local task=env.require('tasks.helltide');task:initiate_waypoints();task:explore_helltide()
 assert(task.current_state=='MOVING_TO_TRAVERSAL')
 s.now=200;task:move_to_traversal();assert(task.current_state=='EXPLORE_HELLTIDE')
 s.now=201;task:explore_helltide();assert(task.current_state=='EXPLORE_HELLTIDE')
 local recover=assert(find_upvalue(task.explore_helltide,'try_traversal_recovery'));assert(recover(s.now))
 assert(rawget(env,'trav_blacklist')==nil)
 s.now=202;task:explore_helltide();assert(task.current_state=='MOVING_TO_TRAVERSAL')
end)

test('actual Helltide callbacks hold loading snapshots and render without a player position',function()
 local env,s,settings,modules=helltide_session();local updates,renders={},{};local pulses,suspends=0,0
 env.on_update=function(fn)updates[#updates+1]=fn end;env.on_render=function(fn)renders[#renders+1]=fn end
 env.on_render_menu=function()end;settings.update_settings=function()end
 modules.gui={elements={},render=function()end}
 modules['core.task_manager']={execute_tasks=function()pulses=pulses+1 end,stop=function()end,
  get_current_task=function()return {name='test',suspend=function()suspends=suspends+1 end}end}
 assert(loadfile(helltide_root..'main.lua','t',env))();assert(#updates==1)
 updates[1]();assert(pulses==1)
 s.world=nil;updates[1]();s.world='LOADING_World';updates[1]();assert(pulses==1 and suspends==2)
 s.pos=nil;updates[1]();renders[1]();assert(pulses==1)
end)

test('Horde outer Alfred reads defer unknown state without salvage or Pit handoff',function()
 local getters={function()error('loading')end,function()return nil end,function()return {}end,
  function()return {enabled=true}end}
 for _,getter in ipairs(getters)do
  local s=session();s.world='Sanctuary';s.zone='Kehj_Caldeum';s.settings.use_alfred=true
  s.settings.salvage=true;s.settings.run_pit=true;s.settings.open_chest_delay=0
  local player=s.env.get_local_player();player.get_dungeon_key_items=function()return {}end
  player.get_item_count=function()return 40 end
  s.env.AlfredTheButlerPlugin={get_status=getter}
  local handoffs=0;s.env.PitPlugin={enable=function()handoffs=handoffs+1 end}
  s.env.InfernalHordesPlugin={disable=function()handoffs=handoffs+1 end}
  s.modules['core.utils']=nil;local utils=s.load('core.utils');assert(utils.is_inventory_full()==nil)
  local chest_reads=0;utils.get_chest=function()chest_reads=chest_reads+1 end
  local chest=s.load('tasks.open_chests');chest.current_state='OPENING_CHEST';chest.current_chest_type='GOLD'
  chest:open_chest();assert(chest_reads==0 and chest.current_state=='OPENING_CHEST')
  local tr=s.load('core.tracker');tr.start_dungeon_time=95
  local start=s.load('tasks.start_dungeon');start:Execute();assert(handoffs==0 and not tr.needs_salvage)
  s.env.AlfredTheButlerPlugin.get_status=function()return {enabled=true,need_trigger=true}end
  assert(utils.is_inventory_full()==true);s.now=105;start:Execute();assert(tr.needs_salvage and handoffs==0)
 end
end)

test('Helltide outer companion readers and farming defer unreadable ownership',function()
 local env,s,settings,modules=helltide_session();modules['core.utils']=nil
 local utils=env.require('core.utils');settings.salvage=true
 env.AlfredTheButlerPlugin={get_status=function()error('loading')end}
 assert(utils.alfred_available()==nil and utils.is_inventory_full()==nil)
 -- Keep actual protected companion reads while replacing unrelated host buff/time APIs.
 utils.is_in_helltide=function()return true end;utils.helltide_active=function()return true end
 local task=env.require('tasks.helltide');task:Execute()
 assert(task.current_state=='INIT' and #s.teleports==0)
 -- HLT-1: need_trigger alone is advisory (tasks/alfred.lua applies the sticky
 -- grace); only a hard need sends the farm task to town.
 env.AlfredTheButlerPlugin.get_status=function()return {enabled=true,need_trigger=true,inventory_full=false}end
 assert(utils.alfred_available()==true and utils.is_inventory_full()==false)
 task:Execute();assert(not env.require('core.tracker').needs_salvage)
 env.AlfredTheButlerPlugin.get_status=function()return {enabled=true,need_trigger=true,inventory_full=true}end
 assert(utils.is_inventory_full()==true)
 task:Execute();assert(env.require('core.tracker').needs_salvage)
 -- C1: an unreadable status holds the farm task for at most ~10 s.
 env.require('core.tracker').needs_salvage=false
 env.AlfredTheButlerPlugin.get_status=function()error('loading')end
 assert(utils.is_inventory_full()==nil);s.now=s.now+11
 assert(utils.alfred_available()==false and utils.is_inventory_full()==false)
end)

test('Helltide search resumes after a confirmed zone loses its buff',function()
 local env,s=helltide_session();local task=env.require('tasks.search_helltide')
 task:searching_helltide();assert(task.current_state=='FOUND_HELLTIDE')
 s.in_helltide=false;assert(task.shouldExecute());task:Execute()
 assert(task.current_state=='TELEPORTING')
end)

test('all supplied farming coordinates and filter rows satisfy their runtime schemas',function()
 local env={vec3=v};local rows,affixes=0,0
 local routes={'ironwolfs','jirandai','marowen','menestad','wejinhani'}
 local files={root..'data/library.lua'}
 for _,name in ipairs(routes)do
  files[#files+1]=helltide_root..'waypoints/'..name..'.lua'
  files[#files+1]=helltide_root..'waypoints/'..name..'_to_maiden.lua'
 end
 for _,file in ipairs(files)do
  local points=assert(loadfile(file,'t',env))();assert(type(points)=='table' and #points>0,file)
  for key,point in pairs(points)do
   assert(type(key)=='number' and key>=1 and key<=#points and key%1==0,file)
   for _,coord in ipairs({point:x(),point:y(),point:z()})do
    assert(type(coord)=='number' and coord==coord and math.abs(coord)<math.huge,file)
   end
   rows=rows+1
  end
 end
 local filters={helltide_root..'data/filter.lua'}
 for _,name in ipairs({'barbarian','default','druid','necromancer','rogue','sorcerer','spiritborn'})do
  filters[#filters+1]=root..'data/filters/'..name..'.lua'
 end
 for _,file in ipairs(filters)do
  local filter=assert(loadfile(file,'t',env))()
  for key,entries in pairs(filter)do
   assert(type(key)=='string' and key:match('_affix_filter$') and type(entries)=='table',file)
   for _,entry in ipairs(entries)do
    assert(type(entry.sno_id)=='number' and entry.sno_id>0 and entry.sno_id%1==0,file)
    assert(type(entry.affix_name)=='string' and #entry.affix_name>0,file)
    assert(entry.max_roll==nil or type(entry.max_roll)=='boolean',file)
    affixes=affixes+1
   end
  end
 end
 print('Farming data: '..rows..' coordinate rows, '..affixes..' affix rows validated')
end)

print('Second-pass farming: '..count..' behavior regressions passed')
