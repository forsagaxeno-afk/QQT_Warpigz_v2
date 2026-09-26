local root = assert(SUITE_ROOT) .. '/HelltideRevamped-0.4/'
local checks = 0
local function check(name, fn)
    fn()
    checks = checks + 1
    print('PASS Helltide: ' .. name)
end
local vector = {}
vector.__index = vector
function vector:new(x,y,z) return setmetatable({_x=x,_y=y,_z=z or 0}, self) end
function vector:x() return self._x end
function vector:y() return self._y end
function vector:z() return self._z end
function vector:dist_to(other)
    return math.sqrt((self:x()-other:x())^2+(self:y()-other:y())^2+(self:z()-other:z())^2)
end
local function actor(skin, x, interactable, z)
    local a = {skin=skin, pos=vector:new(x,0,z), interactable=interactable ~= false}
    function a:get_skin_name() return self.skin end
    function a:get_position() return self.pos end
    function a:is_interactable() return self.interactable end
    return a
end
local targets = assert(loadfile(root .. 'core/chest_targets.lua'))()
local types = {usz_rewardGizmo_ChestArmor=75, usz_rewardGizmo_Uber=250}
check('documented loot source contributes chests and actor references deduplicate', function()
    local a,b = actor('usz_rewardGizmo_ChestArmor',2), actor('usz_rewardGizmo_Uber',3)
    local result = targets.collect({get_all_actors=function() return {a} end},
        {get_all_items_chest_sort_by_distance=function() return {a,b} end})
    assert(#result == 2)
    assert(targets.select(result,types,vector:new(0,0),250,50).actor == a)
    assert(#targets.collect({get_all_actors=function() error('loading') end}, nil) == 0)
end)
check('spent nearest chest does not hide a valid chest of the same type', function()
    local spent = actor('usz_rewardGizmo_ChestArmor',1,false)
    local valid = actor('USZ_REWARDGIZMO_CHESTARMOR_Dyn',4)
    assert(targets.select({spent,valid},types,vector:new(0,0),75,50).actor == valid)
end)
check('blacklisted nearest chest does not hide another same-type chest', function()
    local blocked, valid = actor('usz_rewardGizmo_ChestArmor',1),actor('usz_rewardGizmo_ChestArmor',8)
    local result = targets.select({blocked,valid},types,vector:new(0,0),75,50,
        function(e) return e.actor == blocked end)
    assert(result.actor == valid)
end)
check('range, cinders, unknown skins and invalid handles are filtered safely', function()
    local invalid = {get_skin_name=function() error('stale actor') end}
    assert(not targets.select({actor('usz_rewardGizmo_ChestArmor',51)},types,vector:new(0,0),75,50))
    assert(not targets.select({actor('usz_rewardGizmo_Uber',1)},types,vector:new(0,0),249,50))
    assert(not targets.select({invalid,actor('Helltide_Unknown_SeasonalChest',1)},types,vector:new(0,0),9999,50))
    assert(not targets.classify(nil,types))
    assert(targets.key('chest',vector:new(1,1,2)) ~= targets.key('chest',vector:new(1,1,8)))
end)
check('reacquisition stays at the selected chest position', function()
    local other, selected = actor('usz_rewardGizmo_ChestArmor',1),actor('usz_rewardGizmo_ChestArmor',20,false)
    assert(targets.at_position({other,selected},'usz_rewardGizmo_ChestArmor',vector:new(20,0)) == selected)
    assert(not targets.at_position({other},'usz_rewardGizmo_ChestArmor',vector:new(20,0)))
end)

local function harness()
    local state = {now=100,cinders=100,actors={},loot={},pos=vector:new(0,0),zone='Test_Zone',world='Test_World',
        in_helltide=true,active=true,teleports={},interactions={},logs={},moves=0,stops=0,pauses=0,resets=0}
    local settings = {enabled=true,helltide_chest=true,kill_monsters=false,kill_monsters_rarity=0,farm_cinder_threshold=0,salvage=false,
        town_zone='HOME',town_waypoint=999,apply_cinder_orb_gate=function() end,orb_set_clear=function() end,
        orb_set_block=function() end,force_orb_clear_for=function() end,orb_release=function() end}
    local modules = {['core.settings']=settings,['core.perf']=setmetatable({}, {__index=function() return function() end end}),
        ['core.helltide_explorer']=setmetatable({}, {__index=function() return function() end end})}
    local player = {get_position=function() return state.pos end,get_current_speed=function() return 0 end,
        is_dead=function() return false end,get_item_count=function() return 0 end,get_buffs=function() return {} end}
    local world = {get_name=function() return state.world end,get_current_zone_name=function() return state.zone end}
    local env = setmetatable({vec3=vector,get_time_since_inject=function() return state.now end,
        get_helltide_coin_cinders=function() return state.cinders end,
        get_player_position=function() return state.pos end,get_local_player=function() return player end,
        get_current_world=function() return world end,on_render=function() end,on_update=function() end,
        console={print=function(s) state.logs[#state.logs+1]=s end},
        target_selector={get_near_target_list=function() return {} end},
        actors_manager={get_all_actors=function() return state.actors end,get_enemy_actors=function() return {} end},
        loot_manager={get_all_items_chest_sort_by_distance=function() return state.loot end},
        utility={set_height_of_valid_position=function(p) return p end,is_point_walkeable=function() return true end},
        pathfinder={request_move=function() state.moves=state.moves+1 end},
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
        modules[name] = assert(loadfile(root .. name:gsub('%.','/') .. '.lua','t',env))()
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
check('real Helltide task discovers loot-only chests and opens the selected instance', function()
    local env,s = harness()
    local spent,valid = actor('usz_rewardGizmo_ChestArmor',1,false),actor('usz_rewardGizmo_ChestArmor',2)
    s.actors={spent}; s.loot={valid}
    local task = env.require('tasks.helltide')
    task:initiate_waypoints(); task:explore_helltide()
    assert(task.current_state == 'MOVING_TO_HELLTIDE_CHEST')
    task:move_to_helltide_chest()
    assert(s.interactions[1] == valid)
    s.cinders=25; s.loot={}; s.actors={}; s.now=s.now+4
    task:move_to_helltide_chest()
    assert(task.current_state == 'EXPLORE_HELLTIDE','cinder payment must confirm an unloaded chest')
end)
check('affordable distant chest uses recall instead of direct selection and abandonment', function()
    local env,s=harness(); s.actors={actor('usz_rewardGizmo_ChestArmor',80)}
    local task=env.require('tasks.helltide'); task:initiate_waypoints(); task:explore_helltide()
    assert(task.current_state=='MOVING_TO_REMEMBERED_CHEST')
end)
check('rejected chest interactions stop after six attempts and respect temporary blacklist', function()
    local env,s=harness(); s.actors={actor('usz_rewardGizmo_ChestArmor',2)}
    local task=env.require('tasks.helltide'); task:initiate_waypoints(); task:explore_helltide()
    for _=1,7 do task:move_to_helltide_chest(); s.now=s.now+4 end
    assert(#s.interactions==6 and task.current_state=='EXPLORE_HELLTIDE')
    task:explore_helltide(); assert(task.current_state=='EXPLORE_HELLTIDE')
end)
check('real task remembers a chest when cinders are lost en route', function()
    local env,s = harness(); s.actors={actor('usz_rewardGizmo_ChestArmor',10)}
    local task=env.require('tasks.helltide')
    task:initiate_waypoints(); task:explore_helltide(); s.cinders=20
    task:move_to_helltide_chest()
    assert(task.current_state == 'EXPLORE_HELLTIDE' and #s.interactions==0)
    s.actors={}; s.cinders=100; s.now=s.now+2
    task:explore_helltide()
    assert(task.current_state == 'MOVING_TO_REMEMBERED_CHEST')
end)
check('reset immediately invalidates source cache, selected target and old route', function()
    local env,s = harness(); s.actors={actor('usz_rewardGizmo_ChestArmor',2)}
    local task=env.require('tasks.helltide'); task:initiate_waypoints(); task:explore_helltide()
    env.require('core.tracker').waypoints={vector:new(100,0)}
    task:reset(); s.actors={}
    assert(#env.require('core.tracker').waypoints==0)
    task:initiate_waypoints(); task:explore_helltide()
    assert(task.current_state=='EXPLORE_HELLTIDE')
end)
check('cancelled session drops pending chest state without resetting another movement owner', function()
    local env,s=harness(); s.actors={actor('usz_rewardGizmo_ChestArmor',2)}
    local task=env.require('tasks.helltide'); task:initiate_waypoints(); task:explore_helltide()
    local resets=s.resets
    task:cancel_pending()
    assert(task.current_state=='INIT' and s.resets==resets)
    s.actors={}; task:initiate_waypoints(); task:explore_helltide()
    assert(task.current_state=='EXPLORE_HELLTIDE')
end)
check('opt-in unknown skin diagnostics are rate limited and never select unknowns', function()
    local env,s,settings = harness(); settings.draw_chest_status=true
    s.loot={actor('Helltide_UnrecognizedChest',1)}
    local task=env.require('tasks.helltide'); task:initiate_waypoints(); task:explore_helltide()
    s.now=s.now+2; task:explore_helltide(); s.now=s.now+5; task:explore_helltide()
    local unknown,scans=0,0
    for _,line in ipairs(s.logs) do
        if line:find('[CHEST UNKNOWN]',1,true) then unknown=unknown+1 end
        if line:find('[CHEST SCAN]',1,true) then scans=scans+1 end
    end
    assert(unknown==1 and scans==2 and #s.interactions==0)
end)
check('search can leave an inactive override zone', function()
    local env,s=harness(); s.world='Sanctuary_Eastern_Continent'; s.zone='Skov_Celestia'; s.in_helltide=false
    local search=env.require('tasks.search_helltide')
    assert(not search.shouldExecute(),'active entry must remain owned by Helltide')
    s.active=false
    assert(search.shouldExecute(),'expired override must release search')
end)
check('search visits all five destinations, debounces channel and preserves cooldown', function()
    local env,s=harness(); s.in_helltide=false
    local search=env.require('tasks.search_helltide'); local enums=env.require('data.enums')
    for i,tp in ipairs(enums.helltide_tps) do
        search:searching_helltide(); search:teleporting_to_helltide(); search:waiting_for_teleport()
        assert(s.teleports[i]==tp.id,'skipped destination '..i)
        search:waiting_for_teleport(); assert(#s.teleports==i,'restarted teleport before channel')
        s.zone=tp.name; search:waiting_for_teleport(); s.now=s.now+4; search:waiting_for_teleport()
    end
    search:searching_helltide(); search:teleporting_to_helltide()
    assert(search.current_state=='SEARCHING_HELLTIDE')
    search:searching_helltide(); assert(search.current_state=='SEARCHING_HELLTIDE')
    s.now=s.now+46; search:searching_helltide(); assert(search.current_state=='TELEPORTING')
end)
check('yield cancels owned autonomous movement; disabled stale Looteer does not hold', function()
    local env,s=harness(); local task=env.require('tasks.helltide'); task:initiate_waypoints(); task:explore_helltide()
    local before=s.moves
    env.LooteerPlugin={getSettings=function(k) return k=='enabled' or k=='looting' end}
    task:Execute(); assert(s.moves==before and s.stops>0)
    env.LooteerPlugin.getSettings=function(k) return k=='looting' end
    for _=1,3 do s.now=s.now+1; task:Execute() end
    assert(s.moves>before)
end)
check('disabling via public API cancels task ownership and false settings remain editable', function()
    local env,s,_,modules=harness()
    local function control(v) return {value=v,get=function(self) return self.value end,set=function(self,n) self.value=n end} end
    local controls=setmetatable({}, {__index=function(t,k) local v=control(false); rawset(t,k,v); return v end})
    controls.main_toggle=control(true); controls.town=control(0)
    local gui={elements=controls,town_data={[0]={zone_name='HOME',waypoint_sno=999}},render=function() end}
    modules.gui=gui; modules['core.settings']=nil
    local settings=env.require('core.settings')
    local stops=0
    modules['core.task_manager']={stop=function() stops=stops+1 end,get_current_task=function() return nil end,execute_tasks=function() end}
    env.on_render_menu=function() end
    assert(loadfile(root..'main.lua','t',env))()
    assert(env.HelltideRevampedPlugin.getSettings('do_maiden')==false)
    assert(env.HelltideRevampedPlugin.setSettings('do_maiden',true))
    settings:update_settings(); assert(settings.do_maiden==true)
    assert(not env.HelltideRevampedPlugin.setSettings('do_maiden','yes'))
    env.HelltideRevampedPlugin.disable(); assert(stops==1 and not settings.enabled)
end)
print(string.format('Helltide: %d behavior regressions passed',checks))
