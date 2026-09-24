-- Independent review: load each real main -> GUI/settings -> external ->
-- scheduler -> tasks. Only QQT/companion boundaries are synthetic.
local checks = 0
local function check(name, fn)
    fn(); checks=checks+1; print('PASS second-pass dungeons: '..name)
end
local V={};V.__index=V
function V:new(x,y,z)return setmetatable({xx=x,yy=y,zz=z or 0},self)end
function V:x()return self.xx end
function V:y()return self.yy end
function V:z()return self.zz end
function V:dist_to(p)return math.sqrt((self.xx-p:x())^2+(self.yy-p:y())^2+(self.zz-p:z())^2)end
function V:squared_dist_to_ignore_z(p)return (self.xx-p:x())^2+(self.yy-p:y())^2 end
local next_id=0
local function actor(name,x,y)
    next_id=next_id+1
    local a={id=next_id,name=name,pos=V:new(x or 0,y or 0),health=100,interactable=true}
    function a:get_id()return self.id end
    function a:get_skin_name()return self.name end
    function a:get_position()return self.pos end
    function a:get_current_health()return self.health end
    function a:is_dead()return self.health<=0 end
    function a:is_boss()return self.boss==true end
    function a:is_elite()return false end
    function a:is_champion()return false end
    function a:is_untargetable()return false end
    function a:is_interactable()return self.interactable end
    function a:get_active_spell_id()return 0 end
    function a:get_obols()return 0 end
    function a:get_dungeon_key_items()return {} end
    return a
end
local function control(value,key)
    return {value=value,key=key,get=function(self)return self.value end,set=function(self,v)self.value=v end,
        get_key=function(self)return self.key end,get_state=function(self)return self.value and 1 or 0 end,
        render=function()end,push=function()return false end,pop=function()end}
end
local function session(plugin)
    local root=assert(SUITE_ROOT)..'/'..plugin..'/'
    local uc=plugin=='WonderCity-main'
    local s={now=100,actors={},enemies={},items={},world=uc and 'Undercity_First' or 'PIT_First',
        zone=uc and 'X1_Undercity_First' or 'EGD_MSWK_World_01',world_id=1,
        updates={},teleports=0,interactions={},paths=0,nav_accept=true,stops=0,moves=0,scans=0,revives=0}
    s.player=actor('player',0,0)
    local function scan()s.scans=s.scans+1;return s.actors end
    local env=setmetatable({vec3=V,vec2=V,get_hash=function(v)return v end,
        console={print=function()end},get_time_since_inject=function()return s.now end,
        get_local_player=function()return s.player end,get_player_position=function()return s.player.pos end,
        get_current_world=function()return {get_name=function()return s.world end,
            get_current_zone_name=function()return s.zone end,get_world_id=function()return s.world_id end}end,
        checkbox={new=function(_,v)return control(v)end},combo_box={new=function(_,v)return control(v)end},
        slider_int={new=function(_,_,_,v)return control(v)end},tree_node={new=function()return control(false)end},
        keybind={new=function(_,key,v)return control(v,key)end},
        actors_manager={get_all_actors=scan,get_ally_actors=scan,get_all_items=function()return s.items end},
        target_selector={get_near_target_list=function()return s.enemies end},
        loot_manager={any_item_around=function()return false end,is_in_vendor_screen=function()return false end,
            is_obols=function()return false end},
        utility={send_mouse_move=function()end,send_mouse_click=function()end,send_mouse_right_click=function()end},
        pathfinder={force_move_raw=function(p)s.moves=s.moves+1;s.target=p end},
        get_glyphs=function()return {} end,upgrade_glyph=function()end,
        interact_object=function(a)s.interactions[#s.interactions+1]={actor=a,time=s.now}end,
        teleport_to_waypoint=function()s.teleports=s.teleports+1 end,
        reset_all_dungeons=function()s.resets=(s.resets or 0)+1 end,
        revive_at_checkpoint=function()s.revives=s.revives+1 end,
        orbwalker={set_clear_toggle=function()end,set_block_movement=function()end},
        on_update=function(fn)s.updates[#s.updates+1]=fn end,on_render=function()end,on_render_menu=function()end,
        get_screen_width=function()return 1920 end,render_menu_header=function()end}, {__index=_G})
    env._G=env
    for _,color in ipairs({'green','red','white','cyan','yellow','blue','purple','orange'})do env['color_'..color]=function()return {}end end
    env.BatmobilePlugin=setmetatable({
        reset=function()s.nav_resets=(s.nav_resets or 0)+1;s.navigating=false end,stop_long_path=function()s.stops=s.stops+1;s.navigating=false end,
        clear_target=function()s.target=nil end,set_target=function(_,p)s.target=p;return s.nav_accept end,
        move=function()s.moves=s.moves+1 end,is_long_path_navigating=function()return s.navigating or false end,
        navigate_long_path=function(_,p)s.paths=s.paths+1;s.target=p;s.navigating=s.nav_accept;return s.nav_accept end,
        get_closeby_node=function(_,p)return p end}, {__index=function()return function()return false end end})
    local modules={}
    env.require=function(name)
        if modules[name]==nil then modules[name]=assert(loadfile(root..name:gsub('%.','/')..'.lua','t',env))() end
        return modules[name]
    end
    assert(loadfile(root..'main.lua','t',env))()
    s.env,s.modules=env,modules
    s.external=uc and env.WonderCityPlugin or env.ArkhamAsylumPlugin
    s.gui=env.require('gui');s.tracker=env.require('core.tracker');s.manager=env.require('core.task_manager')
    s.gui.elements.exit_mode:set(1)
    s.gui.elements[uc and 'exit_undercity_delay' or 'exit_pit_delay']:set(0)
    if not uc then s.gui.elements.upgrade_toggle:set(false) end
    function s:tick(dt)self.now=self.now+(dt or 0.1);for _,fn in ipairs(self.updates)do fn()end end
    function s:enable()self.external.enable();self:tick()end
    return s
end
local plugins={'WonderCity-main','ArkhamAsylum-1.0.6'}
check('real GUI/external enable and disable control each actual main scheduler',function()
    for _,plugin in ipairs(plugins)do
        local s=session(plugin);s:tick();assert(s.scans==0 and not s.external.get_status().enabled)
        s:enable();assert(s.scans>0 and s.external.get_status().enabled)
        s.external.disable();local scans,moves=s.scans,s.moves;s:tick()
        assert(not s.external.get_status().enabled and s.scans==scans and s.moves==moves)
    end
end)
check('legacy getter returning nil for false is idle, disabled is idle, busy is busy',function()
    for _,plugin in ipairs(plugins)do
        local s=session(plugin);local cfg={enabled=true,looting=false}
        s.env.LooteerPlugin={getSettings=function(k)if cfg[k]then return cfg[k]end end}
        local utils=s.env.require('core.utils')
        assert(utils.is_looting()==false);cfg.looting=true;assert(utils.is_looting()==true)
        cfg.enabled=false;assert(utils.is_looting()==false)
    end
end)
check('modern unreadable status stays busy and is not replaced by a legacy nil',function()
    for _,plugin in ipairs(plugins)do
        local s=session(plugin);local utils=s.env.require('core.utils')
        s.env.LooteerPlugin={get_enabled=function()return true end,is_actively_looting=function()error('unavailable')end,
            getSettings=function()return nil end}
        assert(utils.is_looting())
        s.env.LooteerPlugin.is_actively_looting=function()return nil end;assert(utils.is_looting())
        s.env.LooteerPlugin.is_actively_looting=function()return false end;assert(not utils.is_looting())
        s.env.LooteerPlugin={getSettings=function()error('unavailable')end};assert(utils.is_looting())
        s.env.LooteerPlugin={get_enabled=function()error('unavailable')end,getSettings=function()return nil end}
        assert(utils.is_looting(),'failed modern enabled read cannot become legacy disabled')
        s.env.LooteerPlugin={is_actively_looting=function()error('unavailable')end,getSettings=function()return nil end}
        assert(utils.is_looting(),'legacy enabled=nil cannot precede and hide a failed modern activity read')
        s.env.LooteerPlugin.is_actively_looting=function()return true end
        assert(utils.is_looting(),'explicit modern collection outranks legacy enabled=nil')
        s.env.LooteerPlugin.is_actively_looting=function()error('unavailable')end
        s.env.LooteerPlugin.is_idle=function()return true end
        assert(not utils.is_looting(),'secondary modern idle can resolve failed activity read')
    end
end)
check('WonderCity reward exits after real legacy Looter goes idle and quiet period elapses',function()
    local s=session('WonderCity-main');local busy=true
    s.env.LooteerPlugin={getSettings=function(k)if k=='enabled' or (k=='looting' and busy)then return true end end}
    s:enable();s.tracker.done=true;s:tick();s:tick(4);assert(s.teleports==0)
    busy=false;s:tick();s:tick(2.9);assert(s.teleports==0)
    s:tick(0.2);s:tick();assert(s.teleports==1)
end)
check('Arkham glyphstone cannot cause normal exit while modern Looter is active',function()
    local s=session('ArkhamAsylum-1.0.6');local busy=true
    s.env.LooteerPlugin={get_enabled=function()return true end,is_actively_looting=function()return busy end}
    s.actors={actor('Gizmo_Paragon_Glyph_Upgrade',1,0)};s:enable();s:tick(5);assert(s.teleports==0)
    busy=false;s:tick();s:tick();assert(s.teleports==1)
end)
check('Arkham foreign Alfred trip owns scheduler even outside selected town',function()
    local s=session('ArkhamAsylum-1.0.6');s.world='Sanctuary';s.zone='Foreign_Service_Town'
    s.env.AlfredTheButlerPlugin={get_status=function()return {enabled=true,trigger_tasks=true}end}
    s:enable();s:tick(10)
    assert(s.manager.get_current_task().name=='alfred_running' and s.teleports==0)
end)
check('newly acquired Alfred route survives scheduler handoff and immediate disable',function()
    for _,plugin in ipairs(plugins)do
        for _,stop_immediately in ipairs({false,true})do
            local s=session(plugin);s:enable()
            local stops=s.stops
            s.env.AlfredTheButlerPlugin={get_status=function()return {enabled=true,trigger_tasks=true}end}
            if stop_immediately then s.external.disable() else s:tick() end
            assert(s.stops==stops,'dungeon cleanup must preserve an already active Alfred route')
        end
    end
end)
check('floor navigation reset waits for Alfred release then executes once',function()
    for _,plugin in ipairs(plugins)do
        local s=session(plugin);s:enable();local resets=s.nav_resets;local busy=true
        s.env.AlfredTheButlerPlugin={get_status=function()return {enabled=true,trigger_tasks=busy}end}
        s.world=s.world..'_Next';s.world_id=s.world_id+1;s:tick()
        assert(s.nav_resets==resets,'floor observation cannot reset a service route')
        busy=false;s:tick();assert(s.nav_resets==resets+1,'deferred floor reset must run before dungeon navigation resumes')
        s:tick();assert(s.nav_resets==resets+1,'deferred floor reset is not repeated')
    end
end)
check('altar, Heart of Stone and shrine interactions stay spaced throughout the timeout',function()
    local names={altar='Warplans_Pit_ChoronsBurden_Receptacle',heart='Warplans_Pit_ChoronsBurden_Carryable',shrine='Shrine_DRLG_Protection'}
    for _,kind in ipairs({'altar','heart','shrine'})do
        local s=session('ArkhamAsylum-1.0.6')
        s.actors={actor(names[kind],1,0)}
        s:enable();for _=1,80 do s:tick(0.1)end
        assert(#s.interactions>=2 and #s.interactions<=6)
        for i=2,#s.interactions do assert(s.interactions[i].time-s.interactions[i-1].time>=0.999)end
    end
end)
check('loading world names preserve lifecycle and prevent actor scans and native actions',function()
    for _,plugin in ipairs(plugins)do
        local s=session(plugin);s:enable()
        local world,key,scans=s.world,s.tracker.world_key,s.scans
        s.tracker.boss_seen=true;s.tracker.reward_seen=true
        for _,name in ipairs({'Limbo','Loading',''})do
            s.world=name;s:tick()
            assert(s.scans==scans and s.teleports==0)
            assert(s.tracker.observe_world()==nil and s.tracker.world_key==key)
            assert(s.tracker.boss_seen and s.tracker.reward_seen)
        end
        s.world=world;s:tick()
        assert(s.tracker.world_key==key)
    end
end)
check('main death handling debounces revival without running task actor scans',function()
    for _,plugin in ipairs(plugins)do
        local s=session(plugin);s:enable();local scans=s.scans;s.player.health=0
        s:tick();for _=1,5 do s:tick()end
        assert(s.revives==1 and s.scans==scans)
    end
end)
check('rejected progress-orb navigation observes retry interval',function()
    local s=session('ArkhamAsylum-1.0.6');s.actors={actor('TWR_ProgressOrb',30,0)};s.nav_accept=false
    s:enable();assert(s.paths==1)
    for _=1,15 do s:tick()end;assert(s.paths==1)
    s:tick(0.6);assert(s.paths==2)
end)
check('walking toward a traversal is not itself a completed crossing',function()
    local s=session('ArkhamAsylum-1.0.6');s.actors={actor('Traversal_Gizmo_Up',25,0)};s:enable()
    local portal=s.env.require('tasks.portal');portal.long_path_failed_time=s.now
    s:tick();assert(s.manager.get_current_task().name=='cross_traversal')
    s.player.pos=V:new(12,0);s:tick()
    assert(s.manager.get_current_task().name=='cross_traversal' and #s.interactions==0)
    s.player.pos=V:new(23,0);s:tick()
    assert(#s.interactions==1,'interaction occurs after the long approach')
    s:tick()
    assert(s.manager.get_current_task().name=='cross_traversal','approach distance cannot become post-interaction crossing evidence')
    s.player.pos=V:new(40,0);s:tick()
    assert(s.manager.get_current_task().name~='cross_traversal','actual post-interaction displacement releases traversal')
end)
check('real GUI accepts the same alternate Alfred export as the runtime',function()
    for _,plugin in ipairs(plugins)do
        local s=session(plugin);local rendered=0
        s.env.PLUGIN_alfred_the_butler={get_status=function()return {enabled=false}end}
        s.env.LooteerPlugin={getSettings=function()return nil end}
        s.gui.elements.main_tree.push=function()return true end
        s.gui.elements.main_toggle.render=function()rendered=rendered+1 end
        s.gui.render();assert(rendered==1)
    end
end)
print(string.format('Second-pass dungeons: %d behavior regressions passed',checks))
