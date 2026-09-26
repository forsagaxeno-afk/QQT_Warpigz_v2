local root = assert(SUITE_ROOT) .. '/ArkhamAsylum-1.0.6/'
local checks = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    assert(ok, name .. ': ' .. tostring(err))
    checks = checks + 1
end

local function vector(x, y, z)
    local v = {xx = x, yy = y or 0, zz = z or 0}
    function v:x() return self.xx end
    function v:y() return self.yy end
    function v:z() return self.zz end
    function v:dist_to(other)
        return math.sqrt((self:x()-other:x())^2+(self:y()-other:y())^2+(self:z()-other:z())^2)
    end
    return v
end
local function actor(name, x, options)
    options = options or {}
    local a = {name = name, position = vector(x or 0), health = options.health or 100,
        interactable = options.interactable ~= false, boss = options.boss or false}
    function a:get_skin_name() return self.name end
    function a:get_position() return self.position end
    function a:is_interactable() return self.interactable end
    function a:get_current_health() return self.health end
    function a:is_boss() return self.boss end
    function a:is_elite() return false end
    function a:is_champion() return false end
    function a:is_untargetable() return false end
    function a:is_dead() return self.health <= 0 end
    function a:get_active_spell_id() return 0 end
    return a
end
local function glyph(hash, level)
    local g = {glyph_name_hash=hash, level=level, allowed=true}
    function g:get_level() return self.level end
    function g:get_upgrade_chance() return 1 end
    function g:can_upgrade() return self.allowed end
    function g:get_max_level() return 100 end
    return g
end
local function session()
    local s = {now=100, world_name='PIT_First', world_id=1, zone='PIT_Subzone',
        actors={}, enemies={}, glyphs={}, interactions={}, upgrades={}, paths=0,
        stops=0, moves=0, reset_calls=0, navigating=false, nav_accept=true,
        teleports=0, dungeon_resets=0, target=nil}
    s.player=actor('Player',0)
    local settings = {enabled=true, reset_timeout=600, check_distance=12,
        town_zone='Town', town_waypoint=1, town_pit_tower_pos=vector(0), pit_level=1,
        upgrade_toggle=true, use_chorons_soul=false, upgrade_mode=0, upgrade_threshold=1,
        minimum_glyph_level=1, maximum_glyph_level=100, upgrade_legendary_toggle=true,
        disable_orbwalker_at_glyphstone=false, death_recovery=false, use_long_path=false,
        exit_pit_delay=0, exit_mode=1, confirm_delay=1, pickup_heart_of_stone=true,
        use_burden_altar=true, interact_shrine=false, chase_goblin=false,
        party_enabled=false, speed_mode=false, speed_mode_2=false, push_mode=false,
        batmobile_priority='distance'}
    settings.orb_set_clear=function(v) s.orb_clear=v end
    settings.orb_set_block=function(v) s.orb_block=v end
    s.settings=settings
    local modules={['core.settings']=settings, ['gui']={upgrade_modes_enum={HIGHEST=0,LOWEST=1}}}
    local env=setmetatable({
        get_time_since_inject=function() return s.now end,
        get_current_world=function()
            if not s.world_name then return nil end
            return {get_name=function() return s.world_name end,
                get_current_zone_name=function() return s.zone end,
                get_world_id=function() return s.world_id end}
        end,
        get_player_position=function() return s.player.position end,
        get_local_player=function() return s.player end,
        vec3={new=function(_,x,y,z) return vector(x,y,z) end},
        console={print=function() end},
        actors_manager={get_ally_actors=function() return s.actors end,
            get_all_actors=function() return s.actors end},
        target_selector={get_near_target_list=function() return s.enemies end},
        get_glyphs=function() return s.glyphs end,
        upgrade_glyph=function(g) s.upgrades[#s.upgrades+1]=g end,
        interact_object=function(a) s.interactions[#s.interactions+1]=a end,
        teleport_to_waypoint=function() s.teleports=s.teleports+1 end,
        reset_all_dungeons=function() s.dungeon_resets=s.dungeon_resets+1 end,
        loot_manager={any_item_around=function() return false end,
            is_in_vendor_screen=function() return false end},
        utility={open_pit_portal=function() end},
        pathfinder={force_move_raw=function(v) s.target=v;s.moves=s.moves+1 end},
        BatmobilePlugin={
            pause=function() end, resume=function() end, update=function() end,
            reset=function() s.reset_calls=s.reset_calls+1;s.navigating=false end,
            set_priority=function() end, reset_movement=function() end,
            clear_traversal_blacklist=function() end,
            is_done=function() return s.nav_done or false end,
            is_traversal_routing=function() return false end,
            is_long_path_navigating=function() return s.navigating end,
            stop_long_path=function() s.stops=s.stops+1;s.navigating=false end,
            clear_target=function() s.target=nil end,
            set_target=function(_,target) s.target=target;return s.nav_accept end,
            move=function() s.moves=s.moves+1 end,
            get_closeby_node=function(_,target) return target end,
            navigate_long_path=function(_,target)
                s.paths=s.paths+1;s.target=target;s.navigating=s.nav_accept;return s.nav_accept
            end,
        },
    },{__index=_G})
    env._G=env
    function s.load(name)
        if modules[name] then return modules[name] end
        local file=assert(loadfile(root..name:gsub('%.','/')..'.lua','t',env))
        modules[name]=file()
        return modules[name]
    end
    env.require=s.load
    s.env=env
    return s
end

local function arm_glyph(s)
    s.actors={actor('Gizmo_Paragon_Glyph_Upgrade',0)}
    local task=s.load('tasks.upgrade_glyph')
    assert(task.shouldExecute())
    task:Execute()
    s.now=s.now+2.1
    task:Execute()
    return task
end

test('nil and loading worlds do not dispatch or crash', function()
    local s=session();s.world_name=nil
    assert(not s.load('core.utils').player_in_zone('Town'))
    local manager=s.load('core.task_manager')
    manager.execute_tasks()
    s.world_name='PIT_First';s.zone='[sno none]';s.now=s.now+1
    manager.execute_tasks()
    assert(s.moves==0 and #s.interactions==0)
end)

test('floor lifecycle preserves run deadline and resets boss state', function()
    local s=session();local tracker=s.load('core.tracker')
    assert(tracker.observe_world()=='run')
    tracker.boss_dead=true;tracker.glyph_done=true
    s.now=130;s.world_name=nil
    assert(tracker.observe_world()==nil and tracker.boss_dead)
    s.world_name='PIT_First';s.world_id=2
    assert(tracker.observe_world()=='floor')
    assert(tracker.pit_start_time==100 and not tracker.boss_dead and not tracker.glyph_done)
    s.world_name='Town';s.zone='Town';assert(tracker.observe_world()=='outside')
    s.now=180;s.world_name='PIT_First';s.zone='PIT_Subzone'
    assert(tracker.observe_world()=='run' and tracker.pit_start_time==180)
end)

test('deadline preempts rewards and ordinary task priority', function()
    local s=session();local manager=s.load('core.task_manager')
    local tracker=s.load('core.tracker');tracker.observe_world()
    local reward=s.load('tasks.use_burden_altar')
    reward.shouldExecute=function() return true end
    reward.Execute=function() error('deadline failed to preempt reward') end
    s.now=800;manager.execute_tasks()
    assert(manager.get_current_task().name=='exit_pit')
    s.now=800.1;manager.execute_tasks()
    assert(s.teleports==1)
end)

test('navigation handoff and disable clear stale long paths', function()
    local s=session();local manager=s.load('core.task_manager')
    local tracker=s.load('core.tracker');tracker.observe_world()
    local tele=s.load('tasks.teleport_cerrigar');local reward=s.load('tasks.use_burden_altar')
    tele.shouldExecute=function() return s.now==100 end
    tele.Execute=function() s.navigating=true end
    reward.shouldExecute=function() return true end
    reward.Execute=function() assert(not s.navigating) end
    manager.execute_tasks();s.now=101;manager.execute_tasks()
    assert(s.stops>0)
    manager.release_control();assert(s.orb_block==false)
end)

test('exploration exhaustion does not complete an unfinished Pit', function()
    local s=session();s.nav_done=true
    assert(not s.load('tasks.exit_pit').shouldExecute())
    s.actors={actor('Gizmo_Paragon_Glyph_Upgrade',0)}
    assert(s.load('tasks.exit_pit').shouldExecute())
end)

test('disabled Looteer cannot retain a stale looting lock', function()
    local s=session();s.env.LooteerPlugin={getSettings=function(k) return k=='looting' end}
    assert(not s.load('core.utils').is_looting())
end)

test('town portal interaction is debounced and does not reset a run early', function()
    local s=session();s.world_name='Town';s.zone='Town'
    s.actors={actor('EGD_MSWK_World_Portal_01',0)}
    local tracker=s.load('core.tracker');tracker.pit_start_time=50
    local task=s.load('tasks.enter_pit');task:Execute();s.now=100.1;task:Execute()
    assert(#s.interactions==1 and tracker.pit_start_time==50)
end)

test('same-name new-world arrival excludes the back portal', function()
    local s=session();s.actors={actor('Prefab_Portal_Dungeon_Generic',0)}
    local task=s.load('tasks.portal');assert(task.shouldExecute());task:Execute()
    assert(#s.interactions==1)
    s.now=101;s.world_id=2;s.player.position=vector(100)
    s.actors={actor('Prefab_Portal_Dungeon_Generic',105),actor('Prefab_Portal_Dungeon_Generic',125)}
    task.reset('floor');assert(task.shouldExecute());task:Execute()
    assert(s.target:x()==125,'back portal was selected instead of descent')
end)

test('temporary boss scan miss never proves death', function()
    local s=session();local boss=actor('Guardian',20,{boss=true});s.enemies={boss}
    local task=s.load('tasks.kill_boss');assert(task.shouldExecute())
    s.enemies={};assert(not task.shouldExecute())
    assert(not s.load('core.tracker').boss_dead)
    local explore=s.load('tasks.explore_pit');explore:Execute();assert(s.moves>0)
    s.enemies={boss};boss.health=0;assert(not task.shouldExecute())
    assert(s.load('core.tracker').boss_dead)
end)

test('visible stationary boss does not rebuild a long path every pulse', function()
    local s=session();s.settings.use_long_path=true;s.enemies={actor('Guardian',20,{boss=true})}
    local task=s.load('tasks.kill_boss');assert(task.shouldExecute());task:Execute()
    for i=1,10 do s.now=s.now+.1;assert(task.shouldExecute());task:Execute() end
    assert(s.paths==1)
    s.navigating=false;s.now=s.now+1;task:Execute();assert(s.paths==2)
end)

test('highest glyph selection uses level rather than container order', function()
    local s=session();s.glyphs={glyph(1,10),glyph(2,70),glyph(3,30)}
    local task=arm_glyph(s)
    assert(#s.upgrades==1 and s.upgrades[1].glyph_name_hash==2)
    for i=1,300 do task.shouldExecute() end
    assert(task.failed_count==0 and next(task.blacklist)==nil)
    -- The same live handle now reports the successful upgraded level.
    s.glyphs[2].level=71;s.now=s.now+2.1;task:Execute()
    assert(task.failed_count==0 and not task.blacklist[2])
end)

test('glyph retry budget counts actual attempts', function()
    local s=session();s.glyphs={glyph(1,10)};local task=arm_glyph(s)
    for i=1,100 do task.shouldExecute() end
    assert(task.failed_count==0)
    for i=1,5 do s.now=s.now+2.1;task:Execute() end
    assert(#s.upgrades==5 and task.blacklist[1] and s.load('core.tracker').glyph_done)
end)

test('legacy vector glyphs and lowest selection remain supported', function()
    local s=session();s.settings.upgrade_mode=1
    local items={glyph(1,70),glyph(2,10)}
    s.glyphs={size=function() return #items end,get=function(_,i) return items[i] end}
    arm_glyph(s);assert(s.upgrades[1].glyph_name_hash==2)
end)

test('empty glyph response yields after bounded wait', function()
    local s=session();local task=arm_glyph(s)
    s.now=109;task:Execute()
    assert(s.load('core.tracker').glyph_done and not task.shouldExecute())
end)

test('legendary toggle prevents the level-45 conversion', function()
    local s=session();s.settings.upgrade_legendary_toggle=false;s.glyphs={glyph(1,45)}
    arm_glyph(s);assert(#s.upgrades==0)
end)

test('finished soul task does not block remaining glyph upgrades', function()
    local s=session();s.settings.use_chorons_soul=true
    s.load('tasks.consume_chorons_soul').shouldExecute=function() return false end
    s.actors={actor('Gizmo_Paragon_Glyph_Upgrade',0),actor('Warplans_Pit_ChoronsSoul',0)}
    assert(s.load('tasks.upgrade_glyph').shouldExecute())
end)

test('despawned soul completes channel and sweeps remembered XP position', function()
    local s=session();s.settings.use_chorons_soul=true
    local soul=actor('Warplans_Pit_ChoronsSoul',0);s.actors={soul}
    local task=s.load('tasks.consume_chorons_soul')
    assert(task.shouldExecute());task:Execute()
    s.now=111;task:Execute();s.now=116;task:Execute();assert(#s.interactions==1)
    s.actors={};s.now=116.1;assert(task.shouldExecute());local moves=s.moves;task:Execute()
    assert(s.moves==moves,'sweep interrupted an unfinished charge')
    s.now=121;task:Execute();assert(s.moves>moves)
    s.now=140;task:Execute();assert(not task.shouldExecute())
    task.reset();s.actors={soul};assert(task.shouldExecute())
end)

test('heart blacklist is scoped to the current floor/run', function()
    local s=session();s.actors={actor('Warplans_Pit_ChoronsBurden_Carryable',20)};s.nav_accept=false
    local task=s.load('tasks.pickup_heart_of_stone');assert(task.shouldExecute());task:Execute()
    assert(not task.shouldExecute());task.reset();assert(task.shouldExecute())
end)

test('altar blacklist is scoped to the current floor/run', function()
    local s=session();s.actors={actor('Warplans_Pit_ChoronsBurden_Receptacle',20)};s.nav_accept=false
    local task=s.load('tasks.use_burden_altar');assert(task.shouldExecute());task:Execute()
    assert(not task.shouldExecute());task.reset();assert(task.shouldExecute())
end)

test('confirmed floor transition resets the explorer exactly once', function()
    local s=session();local manager=s.load('core.task_manager')
    local task=s.load('tasks.use_burden_altar')
    task.shouldExecute=function() return true end
    task.Execute=function() end
    manager.execute_tasks();assert(s.reset_calls==1)
    s.now=101;manager.execute_tasks();assert(s.reset_calls==1)
    s.world_id=2;s.now=102;manager.execute_tasks();assert(s.reset_calls==2)
end)

test('forced reset preserves a busy foreign Alfred cycle', function()
    local s=session();local tracker=s.load('core.tracker');tracker.observe_world()
    s.env.AlfredTheButlerPlugin={get_status=function() return {enabled=true,trigger_tasks=true} end}
    local manager=s.load('core.task_manager');s.now=800;manager.execute_tasks()
    assert(manager.get_current_task().name=='alfred_running' and s.teleports==0)
end)

print('Arkham: '..checks..' focused regressions passed')
