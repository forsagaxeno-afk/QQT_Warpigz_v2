local root = assert(SUITE_ROOT) .. '/HordeDev-1.3.9/'
local checks = 0
local function check(name, run)
    run(); checks = checks + 1; print('PASS Horde feedback: ' .. name)
end
local vector = {}; vector.__index = vector
function vector:new(x,y,z) return setmetatable({_x=x,_y=y,_z=z or 0},self) end
function vector:x() return self._x end
function vector:y() return self._y end
function vector:z() return self._z end
function vector:dist_to(p) return math.sqrt((self:x()-p:x())^2+(self:y()-p:y())^2+(self:z()-p:z())^2) end
local function actor(name,x,y)
    local a = {name=name,pos=vector:new(x,y),health=100,enemy=true,valid=true}
    function a:get_skin_name() return self.name end
    function a:get_position() return self.pos end
    function a:get_current_health() return self.health end
    function a:is_enemy() return self.enemy end
    function a:is_boss() return self.boss == true end
    function a:is_champion() return false end
    function a:is_elite() return self.elite == true end
    function a:is_untargetable() return self.untargetable == true end
    function a:is_immune() return self.immune == true end
    function a:is_dead() return self.health <= 0 end
    function a:is_interactable() return false end
    return a
end
local function harness(aggressive)
    local s={now=100,pos=vector:new(9.2,8.9),actors={},targets={},raw=0,stops=0,bm_moves=0,interactions=0}
    local settings={aggresive_movement=aggressive==true,movement_spell_to_objective=true,pick_pylon_delay=0,merry_go_round=false}
    local explorer={is_task_running=false,clear_path_and_target=function()s.stops=s.stops+1 end,
        set_custom_target=function(_,pos)s.targets[#s.targets+1]=pos end,move_to_target=function()end,
        movement_spell_to_target=function()end}
    s.explorer=explorer
    local tracker={enable_time=0,check_time=function()return true end,clear_key=function()end}
    local modules={['core.settings']=settings,['core.explorer']=explorer,['core.tracker']=tracker,
        ['core.navigation']={},['data.enums']={},['data.pylons']={'BSK_PylTest'}}
    modules['core.utils']={distance_to=function(a)return s.pos:dist_to(a.get_position and a:get_position() or a)end,
        player_in_zone=function()return true end,get_bartuc_pylon=function()return nil end,
        get_boss_pylon=function()return nil end,get_aether_actor=function()return nil end}
    local env=setmetatable({vec3=vector,console={print=function()end},
        get_time_since_inject=function()return s.now end,get_player_position=function()return s.pos end,
        get_local_player=function()return {is_dead=function()return false end}end,
        get_current_world=function()return {get_name=function()return 'S05_BSK_Prototype02' end}end,
        actors_manager={get_all_actors=function()return s.actors end},
        evade={is_dangerous_position=function(p)return s.danger==p end},
        target_selector={is_valid_enemy=function(a)return a.valid and a.enemy and a.health>1 end},
        interact_object=function()s.interactions=s.interactions+1 end,
        pathfinder={clear_stored_path=function()end,force_move_raw=function()s.raw=s.raw+1 end},
        BatmobilePlugin={pause=function()end,update=function()end,move=function()s.bm_moves=s.bm_moves+1 end,
            stop_long_path=function()end,clear_target=function()end,
            set_target=function(_,pos)s.targets[#s.targets+1]=pos end}}, {__index=_G})
    env._G=env
    env.require=function(name)
        if not modules[name] then modules[name]=assert(loadfile(root..name:gsub('%.','/')..'.lua','t',env))() end
        return modules[name]
    end
    local task=env.require('tasks.horde')
    function s:tick() self.now=self.now+0.2;assert(task.shouldExecute());task:Execute() end
    return s,task,tracker
end
local portal_names={
    'S10_ChaosRift_Portal4','S10_ChaosRift_Portal_BossRush','S10_ChaosRift_Portal_BulletHell',
    'S10_ChaosRift_Portal_Goblin','S10_ChaosRift_Portal_Hellwyrm','S10_ChaosRift_Portal_LunaticSiege',
    'S10_ChaosRift_Portal_MovingAether','S10_ChaosRift_Portal_TeleportHell'}
check('known Chaos Rift variants beat nearby trash, elite adds and aether',function()
    for _,name in ipairs(portal_names)do
        local s=harness();local portal=actor(name,40,20);portal.valid=false
        local elite=actor('ordinary_elite',12,9);elite.elite=true
        s.actors={actor('ordinary_monster',10,9),elite,actor('BurningAether',11,9),portal}
        s:tick();assert(s.targets[#s.targets]==portal.pos and s.interactions==0)
    end
end)
check('edge portal stays engaged after arrival without center retreat in both movement modes',function()
    for _,aggressive in ipairs({false,true})do
        local s=harness(aggressive);local portal=actor(portal_names[1],40,20);s.actors={portal}
        s:tick();s.pos=vector:new(39.5,20);s:tick()
        local moves,bm_moves,stops=#s.targets,s.bm_moves,s.stops
        for _=1,4 do s:tick()end
        assert(#s.targets==moves and s.bm_moves==bm_moves and s.stops==stops and s.raw==0)
        assert(s.explorer.is_task_running, 'autonomous explorer must stay paused while holding the objective')
        portal.health=0;local monster=actor('ordinary_monster',20,10);s.actors={portal,monster}
        s:tick();assert(s.targets[#s.targets]==monster.pos)
        assert(s.explorer.is_task_running==not aggressive)
    end
end)
check('occupied marker also remains engaged instead of recentering',function()
    local s=harness();local marker=actor('MarkerLocation_BSK_Occupied',40,20);marker.enemy=false;marker.health=0
    s.actors={marker};s:tick();s.pos=vector:new(40,20);s:tick();local count=#s.targets;s:tick()
    assert(#s.targets==count and s.raw==0)
end)
check('living Council boss keeps priority over a remaining wave portal',function()
    local s=harness();local boss=actor('BSK_skeleton_boss',-36,-36);boss.boss=true
    s.actors={actor(portal_names[1],12,10),boss};s:tick();assert(s.targets[#s.targets]==boss.pos)
end)
check('dead, friendly, immune and untargetable portals cannot pin the wave',function()
    for _,flag in ipairs({'dead','friendly','immune','untargetable'})do
        local s=harness();local portal=actor(portal_names[1],12,10)
        if flag=='dead' then portal.health=0 elseif flag=='friendly' then portal.enemy=false else portal[flag]=true end
        local monster=actor('ordinary_monster',20,10);s.actors={portal,monster};s:tick()
        assert(s.targets[#s.targets]==monster.pos)
    end
end)
check('hazard rejection remains effective for a recognized portal',function()
    local s=harness();local portal=actor(portal_names[1],40,20);s.danger=portal.pos
    local monster=actor('ordinary_monster',20,10);s.actors={portal,monster};s:tick()
    assert(s.targets[#s.targets]==monster.pos)
end)
check('decorative portals and proximity spawners are not inferred to be attackable',function()
    local s=harness();local vfx=actor('S10_ChaosRift_Controller_LunaticSiege',12,10);vfx.enemy=false
    local spawner=actor('BSK_AmbushPlus_Fallen_LunaticPortal',13,10);spawner.enemy=false
    local monster=actor('ordinary_monster',20,10);s.actors={vfx,spawner,monster};s:tick()
    assert(s.targets[#s.targets]==monster.pos and s.interactions==0)
end)
check('cancellation releases objective hold and the next run can navigate',function()
    local s,task=harness();local portal=actor(portal_names[1],40,20);s.actors={portal};s:tick()
    s.pos=vector:new(40,20);s:tick();task:cancel_pending()
    s.pos=vector:new(9.2,8.9);local before=#s.targets;s:tick()
    assert(#s.targets>before and s.targets[#s.targets]==portal.pos)
end)
check('one remaining hit point is still a living portal objective',function()
    local s=harness();local portal=actor(portal_names[1],40,20);portal.health=1;s.actors={portal}
    s:tick();assert(s.targets[#s.targets]==portal.pos)
end)
print(string.format('Horde feedback: %d behavior regressions passed',checks))
