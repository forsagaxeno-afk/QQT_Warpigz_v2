local root=assert(SUITE_ROOT)..'/HordeDev-1.3.9/'
local checks=0
local function check(name,fn) fn();checks=checks+1;print('PASS Horde audit: '..name) end
local vector={};vector.__index=vector
function vector:new(x,y,z) return setmetatable({_x=x,_y=y,_z=z or 0},self) end
function vector:x()return self._x end
function vector:y()return self._y end
function vector:z()return self._z end
function vector:dist_to(p)return math.sqrt((self:x()-p:x())^2+(self:y()-p:y())^2+(self:z()-p:z())^2)end
local function actor(name,x,interactable,health,boss)
 local a={name=name,pos=vector:new(x or 1,0),interactable=interactable~=false,health=health or 10,boss=boss==true}
 function a:get_skin_name()return self.name end;function a:get_position()return self.pos end
 function a:is_interactable()return self.interactable end;function a:get_current_health()return self.health end
 function a:is_boss()return self.boss end;function a:is_champion()return false end;function a:is_elite()return false end
 function a:is_enemy()return true end
 return a
end
local function harness()
 local s={now=100,aether=40,actors={},chests={},world='S05_BSK_Prototype02',zone='S05_BSK_Prototype02',pos=vector:new(0,0),
  teleports=0,interactions=0,stops=0,targets={},logs={}}
 local settings={enabled=true,salvage=false,use_alfred=false,aggresive_movement=false,selected_chest_type=0,
  always_open_ga_chest=true,always_open_talisman_chest=true,open_chest_delay=1,wait_loot_delay=2,boss_kill_delay=0,
  chest_move_attempts=40,pick_pylon_delay=0,merry_go_round=false,movement_spell_to_objective=false}
 local explorer={is_task_running=false,clear_path_and_target=function()end,set_custom_target=function()end,move_to_target=function()end}
 local modules={['core.settings']=settings,['core.explorer']=explorer,['tasks.town_salvage']={reset=function()end},['data.pylons']={'BSK_PylTest'},['data.library']={vector:new(0,0)}}
 local player={get_position=function()return s.pos end,is_dead=function()return false end,get_item_count=function()return 0 end}
 local world={get_name=function()return s.world end,get_current_zone_name=function()return s.zone end}
 local env=setmetatable({vec3=vector,get_time_since_inject=function()return s.now end,get_aether_count=function()return s.aether end,
  get_player_position=function()return s.pos end,get_local_player=function()return player end,get_current_world=function()return world end,
  console={print=function(msg)s.logs[#s.logs+1]=msg end},actors_manager={get_all_actors=function()return s.actors end},
  loot_manager={},interact_object=function()s.interactions=s.interactions+1 end,teleport_to_waypoint=function()s.teleports=s.teleports+1 end,
  pathfinder={request_move=function()end,clear_stored_path=function()end,force_move_raw=function()end},
  evade={is_dangerous_position=function()return false end},target_selector={is_valid_enemy=function(a)return a.health>1 and not a.name:find('BSK_Pyl',1,true) end},
  BatmobilePlugin={pause=function()end,resume=function()end,stop_long_path=function()s.stops=s.stops+1 end,
   clear_target=function()end,set_target=function(_,p)s.targets[#s.targets+1]=p;return true end,update=function()end,move=function()end}}, {__index=_G})
 env._G=env
 env.require=function(name)
  if modules[name] then return modules[name] end
  modules[name]=assert(loadfile(root..name:gsub('%.','/')..'.lua','t',env))()
  return modules[name]
 end
 modules['core.utils']={player_in_zone=function(z)return s.zone==z end,distance_to=function(a)return s.pos:dist_to(a.get_position and a:get_position() or a)end,
  get_chest=function(name)return s.chests[name] end,get_horde_gate=function()return nil end,get_bartuc_pylon=function()return nil end,
  get_boss_pylon=function()return nil end,get_aether_actor=function()return nil end,is_inventory_full=function()return false end}
 return env,s,settings,modules
end
local function chest_task(env,s)
 local task=env.require('tasks.open_chests');task.current_chest_type='MATERIALS';task.selected_chest_type='MATERIALS';task.current_chest_index=3
 s.chests.BSK_UniqueOpChest_Materials=actor('BSK_UniqueOpChest_Materials',1)
 return task,env.require('core.tracker')
end
check('unrelated chest VFX and missing actors do not crash or prove payment',function()
 local e,s=harness();local task,tr=chest_task(e,s)
 task.pre_interact_aether=40;s.chests={};s.actors={actor('vfx_resplendentChest_coins',1)}
 task.current_state='WAITING_FOR_VFX';task:wait_for_vfx();s.now=s.now+1;task:wait_for_vfx()
 assert(task.current_state=='OPENING_CHEST' and not tr.selected_chest_opened)
end)
check('actual aether payment confirms an opened actor that unloaded',function()
 local e,s=harness();local task,tr=chest_task(e,s)
 task.pre_interact_aether=40;s.aether=20;s.chests={}
 task:wait_for_vfx();s.now=s.now+1;task:wait_for_vfx()
 assert(task.current_state=='WAITING_FOR_LOOT' and tr.selected_chest_opened)
end)
check('vanished optional chest advances to remaining configured chest',function()
 local e,s=harness();local task=chest_task(e,s)
 task.current_chest_type='TALISMAN';task.current_chest_index=1
 task:open_chest();s.now=s.now+1;task:open_chest()
 assert(task.current_chest_type=='GREATER_AFFIX' and task.current_state=='MOVING_TO_CHEST')
end)
check('selected repeatable chest continues while aether remains',function()
 local e,s=harness();local task,tr=chest_task(e,s)
 task:try_next_chest(true);task:wait_for_loot();s.now=s.now+1;task:wait_for_loot()
 assert(task.current_state=='MOVING_TO_CHEST' and not tr.finished_chest_looting)
 s.aether=0;task:try_next_chest(true);task:wait_for_loot();s.now=s.now+1;task:wait_for_loot();task:finish_chest_opening()
 assert(tr.finished_chest_looting)
end)
check('unavailable materials fall back to existing gold chest and unresolved gold stops safely',function()
 local e,s=harness();local task,tr=chest_task(e,s)
 task:try_next_chest(false)
 assert(task.current_chest_type=='GOLD' and task.current_state=='MOVING_TO_CHEST')
 task:try_next_chest(false)
 -- HRD-1: the fault is terminal and published, never a latch that holds the
 -- chest room; exit_horde may leave with the unspendable aether.
 assert(task.current_state=='FAULT' and task.chest_error and tr.finished_chest_looting and tr.chest_fault==task.chest_error)
 task:reset();assert(tr.chest_fault==nil and not tr.finished_chest_looting)
end)
check('failed chest never fabricates opened flags; reset clears all chest timers',function()
 local e,s=harness();local task,tr=chest_task(e,s)
 s.aether=0;task:try_next_chest(false);task:finish_chest_opening()
 assert(tr.finished_chest_looting and not tr.selected_chest_opened)
 tr.chest_vfx_wait=1;tr.chest_opening_time=1;tr.request_move_to_chest=1;tr.aether_drop_wait=1
 task.chest_not_found_attempts=14;task.move_attempts=40;task:reset()
 assert(not tr.chest_vfx_wait and not tr.chest_opening_time and not tr.request_move_to_chest and not tr.aether_drop_wait)
 assert(task.move_attempts==0 and task.chest_not_found_attempts==0)
end)
check('unavailable aether evidence cannot mark chest sequence finished',function()
 local e,s=harness();local task,tr=chest_task(e,s);s.aether=nil
 task.current_state='FINISHED';task:finish_chest_opening();assert(not tr.finished_chest_looting)
 task.last_opened_type='MATERIALS';task.current_state='WAITING_FOR_LOOT'
 task:wait_for_loot();s.now=s.now+2;task:wait_for_loot()
 assert(task.current_state=='WAITING_FOR_LOOT' and not tr.finished_chest_looting)
end)
check('active chest completion survives disappearance of gold-room actor',function()
 local e,s=harness();local task=chest_task(e,s)
 task.current_state='WAITING_FOR_VFX';s.chests={}
 assert(task.shouldExecute())
end)
check('boss aether collection runs before chest spending',function()
 local e,s,_,modules=harness();local task=chest_task(e,s);local drop=actor('BurningAether',10)
 modules['core.utils'].get_aether_actor=function()return drop end
 task:init_chest_opening();assert(task.current_state=='MOVING_TO_AETHER')
 task:move_to_aether();assert(s.targets[#s.targets]==drop.pos)
end)
check('affix filters load after player class exists and refresh after character changes',function()
 local e,_,_,modules=harness();local class,reads=nil,0
 modules['core.utils'].get_character_class=function()reads=reads+1;return class end
 local function filter(marker)return {focus_weapons_affix_filter={},dagger_weapons_affix_filter={},shield_weapons_affix_filter={},helm_affix_filter={marker}}end
 modules['data.filters.rogue']=filter('rogue');modules['data.filters.sorcerer']=filter('sorcerer')
 local af=e.require('core.affix_filter');assert(reads==0 and af:get_filter('Helm')==nil)
 class='rogue';assert(af:get_filter('Helm')[1]=='rogue')
 class='sorcerer';assert(af:get_filter('Helm')[1]=='sorcerer')
end)
check('Library teleport is debounced while origin world remains loaded',function()
 local e,s=harness();s.zone='OTHER_TOWN';s.world='Sanctuary'
 local task=e.require('tasks.walking_to_horde')
 task:Execute();task:Execute();s.now=s.now+1;task:Execute();assert(s.teleports==1)
 s.now=s.now+10;task:Execute();assert(s.teleports==2)
end)
check('loading blocks both walking predicate branches',function()
 local e,s=harness();s.zone='Kehj_Caldeum';s.world='Limbo'
 assert(not e.require('tasks.walking_to_horde').shouldExecute())
end)
check('Batmobile walking can advance beyond final waypoint and complete',function()
 local e,s=harness();s.zone='Kehj_Caldeum';s.world='Sanctuary'
 local task=e.require('tasks.walking_to_horde');e.require('core.tracker').teleported_from_town=true
 task:Execute();task:Execute()
 assert(task.arrived_destination and not e.require('core.tracker').teleported_from_town)
end)
check('dead boss and spent pylon do not hide living wave targets',function()
 local e,s=harness();local dead=actor('BSK_DeadBoss',1,true,0,true);local living=actor('ordinary_enemy',10,true,10,false)
 s.actors={actor('BSK_PylTest',1,false),dead,living}
 e.require('tasks.horde'):Execute()
 assert(s.interactions==0 and s.targets[#s.targets]==living.pos)
end)
check('War Plan altar (The Black Pact) is taken like a pylon, once, and only when enabled',function()
 local e,s,settings=harness();settings.take_warplan_altar=true
 local a1=actor('Warplans_BSK_ReplicatorGizmo_HellsWrath',1);local a2=actor('Warplans_BSK_ReplicatorGizmo_AetherGoblins',1)
 local idle=actor('Warplans_BSK_ReplicatorGizmo_Inactive',1)
 e.require('data.pylons')[2]='HellsWrath'
 s.actors={idle,a2,a1}
 local horde=e.require('tasks.horde');horde:Execute()
 assert(s.interactions==1,'altar interacted: '..s.interactions)
 local took=false;for _,l in ipairs(s.logs) do if l:find('taking Warplans_BSK_ReplicatorGizmo_HellsWrath',1,true) then took=true end end
 assert(took,'highest-priority offer (HellsWrath) taken')
 -- the chosen offer is gone: the other offer is not accepted as a second one
 s.actors={idle,a2};s.now=s.now+3;horde:Execute()
 assert(s.interactions==1,'second offer ignored')
 -- disabled: nothing
 local e2,s2,settings2=harness();settings2.take_warplan_altar=false
 s2.actors={actor('Warplans_BSK_ReplicatorGizmo_HellsWrath',1)};e2.require('tasks.horde'):Execute()
 assert(s2.interactions==0,'option off')
end)
check('movement ownership is released only once and never before issuance',function()
 local e,s=harness();local m=e.require('core.movement');m.stop();assert(s.stops==0)
 m.claim(true);m.stop();m.stop();assert(s.stops==1)
end)
check('chest discovery includes documented loot list and skips invalid actor handles',function()
 local e,s,_,modules=harness();modules['core.utils']=nil;modules.gui={}
 local chest=actor('BSK_UniqueOpChest_Materials',4)
 s.actors={{get_skin_name=function()error('unloaded')end}}
 e.loot_manager.get_all_items_chest_sort_by_distance=function()return {chest}end
 local utils=e.require('core.utils')
 assert(utils.get_chest('BSK_UniqueOpChest_Materials')==chest and not utils.get_chest(nil))
end)
check('repeated built-in salvage recounts protected items and actually processes the next cycle',function()
 local e,s,settings,modules=harness();modules['tasks.town_salvage']=nil;modules.gui={}
 settings.greater_affix_count=1
 modules['core.affix_filter']={is_uber_item=function()return true end}
 modules['core.utils'].get_greater_affix_count=function()return 0 end
 local reads=0
 local item={is_locked=function()return false end,get_display_name=function()return 'protected' end,
  is_junk=function()return false end,get_sno_id=function()return 99 end,get_rarity=function()return 5 end}
 e.get_local_player=function()return {get_inventory_items=function()reads=reads+1;return {item}end,get_item_count=function()return 1 end}end
 e.loot_manager.salvage_specific_item=function()error('protected item must never be salvaged')end
 local task=e.require('tasks.town_salvage')
 task:salvage_items();s.now=s.now+2;task:salvage_items()
 assert(task.current_state=='FINISHED' and reads==1)
 task:reset();task:salvage_items();s.now=s.now+2;task:salvage_items()
 assert(task.current_state=='FINISHED' and reads==2)
end)
local function salvage_decision(filtered, rarity, filter, rarity_error)
 local e,s,settings,modules=harness();modules['tasks.town_salvage']=nil;modules.gui={}
 settings.greater_affix_count=1;settings.affix_salvage_count=1;settings.use_salvage_filter_toggle=filtered
 modules['core.affix_filter']={is_uber_item=function()return false end,get_filter=function()return filter end}
 modules['core.utils'].get_greater_affix_count=function()return 0 end
 local item={is_locked=function()return false end,get_display_name=function()return 'new item' end,get_name=function()return 'Helm' end,
  is_junk=function()return true end,get_sno_id=function()return 99999999 end,
  get_rarity=function()if rarity_error then error('unreadable rarity')end;return rarity end}
 e.get_local_player=function()return {get_inventory_items=function()return {item}end,get_item_count=function()return 1 end}end
 local destroyed=0;e.loot_manager.salvage_specific_item=function(got)assert(got==item);destroyed=destroyed+1 end
 e.require('tasks.town_salvage'):salvage_items()
 return destroyed,e.require('core.tracker').keep_items
end
check('unknown-SNO Unique and higher-rarity items are retained in both salvage modes even if junk',function()
 for _,filtered in ipairs({false,true})do
  for _,rarity in ipairs({6,7})do
   local destroyed,kept=salvage_decision(filtered,rarity,{{sno_id=1}})
   assert(destroyed==0 and kept==1)
  end
 end
end)
check('missing and unreadable rarity are retained in both salvage modes',function()
 for _,filtered in ipairs({false,true})do
  local destroyed,kept=salvage_decision(filtered,nil,{{sno_id=1}})
  assert(destroyed==0 and kept==1)
  destroyed,kept=salvage_decision(filtered,nil,{{sno_id=1}},true)
  assert(destroyed==0 and kept==1)
 end
end)
check('empty or missing affix filters retain low-rarity items instead of treating missing rules as rejection',function()
 local destroyed,kept=salvage_decision(true,5,{})
 assert(destroyed==0 and kept==1)
 destroyed,kept=salvage_decision(true,5,nil)
 assert(destroyed==0 and kept==1)
end)
check('configured rejection still salvages known low-rarity junk in both modes',function()
 for _,filtered in ipairs({false,true})do
  local destroyed,kept=salvage_decision(filtered,5,{{sno_id=1}})
  assert(destroyed==1 and kept==0)
 end
end)
check('false settings remain externally writable and survive GUI sync',function()
 local e,_,_,modules=harness()
 local function ctrl(v)return {value=v,get=function(self)return self.value end,set=function(self,n)self.value=n end}end
 local controls=setmetatable({}, {__index=function(t,k)local c=ctrl(false);rawset(t,k,c);return c end})
 modules.gui={elements=controls};modules['core.settings']=nil
 local settings=e.require('core.settings');settings:update_settings()
 assert(settings.set_setting('always_open_ga_chest',true));settings:update_settings();assert(settings.always_open_ga_chest)
 assert(not settings.set_setting('always_open_ga_chest','true'))
end)
print(string.format('Horde audit: %d behavior regressions passed',checks))
