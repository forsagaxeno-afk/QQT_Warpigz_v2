local root = assert(SUITE_ROOT) .. '/WonderCity-main/'
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
    function v:squared_dist_to_ignore_z(other) return (self:x()-other:x())^2+(self:y()-other:y())^2 end
    function v:dist_to(other)
        return math.sqrt((self:x()-other:x())^2+(self:y()-other:y())^2+(self:z()-other:z())^2)
    end
    return v
end
local next_actor_id = 0
local function actor(name, x, options)
    options = options or {}
    local a = {name = name, position = vector(x or 0), health = options.health or 100,
        interactable = options.interactable ~= false, boss = options.boss or false}
    next_actor_id = next_actor_id + 1
    a.id = next_actor_id
    function a:get_id() return self.id end
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
    local s = {now=100, world_name='Undercity_First', world_id=1, zone='X1_Undercity_First',
        actors={}, enemies={}, items={}, keys={}, glyphs={}, mouse={}, vendor=false, key_slot=0, interactions={}, upgrades={}, paths=0,
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
    settings.exit_undercity_delay=0
    settings.max_enticement=3
    settings.enticement_timeout=4
    settings.beacon_timeout=10
    settings.boss_delay=3
    settings.loot_obols=true
    settings.tribute_priorities={}
    settings.skip_tribute=false
    settings.enable_bargains=false
    settings.bargain_timeout=10
    settings.bargain_priorities={}
    settings.bargain_cp={bargain_opener={x=20,y=20},scroll_bar={x=30,y=30},option1={x=40,y=40},option2={x=50,y=50}}
    settings.inventory_slot_0_x=100
    settings.inventory_slot_0_y=100
    settings.inventory_cell_size_x=50
    settings.inventory_cell_size_y=50
    settings.portal_button_x=200
    settings.portal_button_y=200
    settings.accept_button_x=300
    settings.accept_button_y=300
    s.settings=settings
    s.player.get_dungeon_key_items=function() return s.keys end
    s.player.get_item_slot_index=function() return s.key_slot end
    s.player.get_obols=function() return s.obols or 0 end
    local modules={['core.settings']=settings, ['gui']={bargains_data={{name='First',cp_key='option1',needs_scroll=false},{name='Second',cp_key='option2',needs_scroll=false}}}}
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
            get_all_actors=function() return s.all_actors or s.actors end, get_all_items=function() return s.items end},
        target_selector={get_near_target_list=function() return s.enemies end},
        get_glyphs=function() return s.glyphs end,
        upgrade_glyph=function(g) s.upgrades[#s.upgrades+1]=g end,
        interact_object=function(a) s.interactions[#s.interactions+1]=a end,
        teleport_to_waypoint=function() s.teleports=s.teleports+1 end,
        reset_all_dungeons=function() s.dungeon_resets=s.dungeon_resets+1 end,
        loot_manager={any_item_around=function() return false end,
            is_in_vendor_screen=function() return s.vendor end, is_obols=function(item) return item.obols end},
        utility={open_pit_portal=function() end,
            send_mouse_move=function(x,y) s.hover={x=x,y=y} end,
            send_mouse_click=function(x,y) s.mouse[#s.mouse+1]={x=x,y=y,kind='left'} end,
            send_mouse_right_click=function(x,y) s.mouse[#s.mouse+1]={x=x,y=y,kind='right'} end},
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

local function town(s)
    s.world_name='Town';s.zone='Town';s.vendor=true
    s.player.position=vector(10,10)
    local brazier=actor('Aubrie_Test_Undercity_Crafter',10)
    brazier.position=vector(10,10)
    s.actors={brazier}
end
local function key(sno)
    return {get_sno_id=function() return sno end}
end

test('missing/loading world is safe and disabled Looteer yields', function()
    local s=session();s.world_name=nil
    local u=s.load('core.utils');assert(not u.player_in_zone('Town') and not u.player_in_undercity())
    s.load('core.task_manager').execute_tasks()
    s.env.LooteerPlugin={getSettings=function(k) return k=='looting' end}
    assert(not u.is_looting())
end)

test('unavailable selected tribute never falls back to another key', function()
    local s=session();town(s);s.keys={key(10)};s.settings.tribute_priorities={[20]=1}
    local task=s.load('tasks.enter_undercity');task:Execute()
    assert(#s.mouse==0 and not s.hover)
    assert(task.status:find('no item available',1,true))
end)

test('invalid tribute inventory slots never produce screen clicks', function()
    for _,slot in ipairs({-1,33,1.5}) do
        local s=session();town(s);s.keys={key(10)};s.settings.tribute_priorities={[10]=1};s.key_slot=slot
        s.load('tasks.enter_undercity'):Execute()
        assert(not s.hover and #s.mouse==0)
    end
end)

test('tribute hover rechecks slot before consuming an item', function()
    local s=session();town(s);s.keys={key(10)};s.settings.tribute_priorities={[10]=1};s.key_slot=1
    local task=s.load('tasks.enter_undercity');task:Execute();assert(s.hover.x==150)
    s.key_slot=4;s.now=100.3;task:Execute();assert(#s.mouse==0)
    s.now=100.4;task:Execute();assert(s.hover.x==300)
    s.now=100.7;task:Execute();assert(#s.mouse==1 and s.mouse[1].x==300 and s.mouse[1].kind=='right')
end)

local function open_click(s)
    town(s);s.settings.skip_tribute=true
    local task=s.load('tasks.enter_undercity')
    task:Execute();s.now=102.1;task:Execute();s.now=102.2;task:Execute()
    assert(#s.mouse==1 and s.mouse[1].x==200)
    return task
end

test('confirmation proceeds after vendor closes without another tribute', function()
    local s=session();local task=open_click(s)
    s.vendor=false;s.now=105;task:Execute();s.now=105.1;task:Execute()
    assert(#s.mouse==2 and s.mouse[2].x==300,'ACCEPT was not clicked with vendor closed')
end)

test('actor guard blocks all earlier task predicates', function()
    local s=session();local task=open_click(s);local manager=s.load('core.task_manager')
    s.load('tasks.alfred').shouldExecute=function() error('unsafe Alfred scan') end
    s.load('tasks.walk_kurast').shouldExecute=function() error('unsafe town scan') end
    s.env.actors_manager.get_all_actors=function() error('unsafe actor scan') end
    s.now=102.3;manager.execute_tasks()
    assert(manager.get_current_task()==task)
    task.on_cancel();assert(task.transition_guard_active(),'cancel lost the actor-lifetime guard')
end)

test('failed bargain advances to the next configured choice after walking away', function()
    local s=session();town(s);s.settings.skip_tribute=true;s.settings.enable_bargains=true
    s.settings.bargain_priorities={[1]=1,[2]=2}
    local task=s.load('tasks.enter_undercity');task.interacted=true;task.step=12;task.step_time=100;task.bargain_idx=1
    s.now=114;task:Execute();assert(task.bargain_walk_away)
    s.player.position=vector(30,10);s.now=115;task:Execute();assert(not task.bargain_walk_away)
    s.player.position=vector(10,10);s.now=116;task:Execute()
    assert(task.bargain_idx==2,'bargain retry restarted the first choice')
end)

test('visible brazier or entrance portal yields the fixed town route', function()
    local s=session();town(s)
    assert(not s.load('tasks.walk_kurast').shouldExecute())
    s.actors={actor('Portal_Dungeon_Undercity',20)}
    assert(not s.load('tasks.walk_kurast').shouldExecute())
end)

test('floor transition retains deadline and separates enticement coordinates', function()
    local s=session();local tr=s.load('core.tracker');local u=s.load('core.utils')
    assert(tr.observe_world()=='run')
    local first=u.enticement_key('SpiritHearth_Switch',vector(1,2));tr.enticement[first]=true
    tr.done=true;tr.boss_trigger_time=100
    s.now=130;s.world_id=2;assert(tr.observe_world()=='floor')
    assert(tr.undercity_start_time==100 and not tr.done and not tr.boss_trigger_time)
    assert(u.enticement_key('SpiritHearth_Switch',vector(1,2))~=first and u.get_enticement_count()==1)
end)

test('forced timeout preempts objective tasks even while Looteer is busy', function()
    local s=session();local tr=s.load('core.tracker');tr.observe_world()
    s.env.LooteerPlugin={getSettings=function() return true end}
    local task=s.load('tasks.interact_enticement');task.shouldExecute=function() return true end
    task.Execute=function() error('deadline failed to preempt objective') end
    local manager=s.load('core.task_manager');s.now=800;manager.execute_tasks()
    assert(manager.get_current_task().name=='exit_undercity')
    s.now=800.1;manager.execute_tasks();assert(s.teleports==1)
end)

test('forced timeout preserves a busy foreign Alfred cycle', function()
    local s=session();local tr=s.load('core.tracker');tr.observe_world()
    s.env.AlfredTheButlerPlugin={get_status=function() return {enabled=true,trigger_tasks=true} end}
    local manager=s.load('core.task_manager');s.now=800;manager.execute_tasks()
    assert(manager.get_current_task().name=='alfred_running' and s.teleports==0)
end)

test('dead boss and goblin actors yield to reward tasks', function()
    local s=session();local boss=actor('X1_Undercity_Lacuni_Boss',2,{boss=true});boss.health=0
    local goblin=actor('X1_Undercity_Chest_Goblin',2);goblin.health=0;s.enemies={boss,goblin};s.settings.chase_goblin=true
    assert(not s.load('tasks.kill_monster').shouldExecute())
end)

test('exploration exhaustion is not Undercity completion', function()
    local s=session();s.nav_done=true
    assert(not s.load('tasks.exit_undercity').shouldExecute())
    s.load('core.tracker').done=true;assert(not s.load('tasks.exit_undercity').shouldExecute())
    s.now=103;assert(s.load('tasks.exit_undercity').shouldExecute())
end)

test('chest that stays interactable after our interaction completes the reward phase (bounded)', function()
    -- CRT-1: the host can keep an opened chest flagged interactable; waiting
    -- for the 600 s run reset held the WarPigs handoff (upstream: 8 s -> done).
    local s=session();s.actors={actor('X1_Undercity_Chest_Attunement',0)}
    local task=s.load('tasks.goto_chest');task:Execute();s.now=107.9;task:Execute()
    local tr=s.load('core.tracker');assert(not tr.done)
    s.now=109;task:Execute()
    assert(tr.done and not tr.chest_failed and not task.shouldExecute())
    assert(tr.completion_reason:find('stays interactable',1,true))
end)

test('chest disappearance requires stable observation and new loot after our click', function()
    local s=session();s.actors={actor('X1_Undercity_Chest_Attunement',0)}
    local task=s.load('tasks.goto_chest');task:Execute();s.actors={};s.now=101
    assert(task.shouldExecute());task:Execute();assert(not s.load('core.tracker').done)
    s.items={actor('RewardItem',0)};s.now=101.1;task:Execute()
    assert(not s.load('core.tracker').done)
    s.now=102.2;task:Execute();assert(s.load('core.tracker').done)
end)

test('reward chest outside the ally list is found and owns cleanup priority', function()
    local s=session();s.all_actors={actor('X1_Undercity_Chest_Attunement_Tier4',0)}
    local manager=s.load('core.task_manager')
    local portal=s.load('tasks.portal');portal.shouldExecute=function() error('portal stole reward phase') end
    local beacon=s.load('tasks.interact_enticement');beacon.shouldExecute=function() error('beacon stole reward phase') end
    manager.execute_tasks()
    assert(manager.get_current_task().name=='goto_chest' and #s.interactions==1)
    assert(s.load('core.tracker').reward_seen)
end)

test('fresh dead boss establishes reward wait without inventing opened chest', function()
    local s=session();local boss=actor('X1_Undercity_Lacuni_Boss',2,{boss=true});boss.health=0
    s.all_actors={boss};s.enemies={boss}
    local manager=s.load('core.task_manager');manager.execute_tasks()
    local tr=s.load('core.tracker')
    assert(tr.boss_kill_time==100 and not tr.done)
    assert(manager.get_current_task().name=='finish_undercity' and s.teleports==0)
    s.now=120;s.all_actors={};s.enemies={};manager.execute_tasks()
    assert(not tr.done and s.teleports==0,'missing reward was treated as success')
end)

test('boss absence, actor read failure and loading do not prove a kill', function()
    local s=session();local tr=s.load('core.tracker');tr.boss_trigger_time=99
    local phase=s.load('core.reward_phase');phase.observe()
    assert(not tr.boss_kill_time and not phase.active())
    s.env.actors_manager.get_all_actors=function() error('temporary actor failure') end
    phase.observe();assert(not tr.boss_kill_time)
    s.zone='[sno none]';phase.observe();assert(not tr.boss_kill_time)
end)

test('live boss suppresses corpse and chest completion signals', function()
    local s=session();local dead=actor('X1_Undercity_Lacuni_Boss',2,{boss=true});dead.health=0
    local alive=actor('S11_Andariel_Boss_KUC',3,{boss=true})
    s.all_actors={dead,alive,actor('X1_Undercity_Chest_Attunement',0)}
    s.load('core.reward_phase').observe()
    local tr=s.load('core.tracker');assert(tr.boss_alive and not tr.boss_kill_time and not tr.reward_seen)
end)

test('noninteractable chest before our own click waits a bounded unlock window, never clicks', function()
    local s=session();s.actors={actor('X1_Undercity_Chest_Attunement',0,{interactable=false})}
    local task=s.load('tasks.goto_chest');task:Execute();s.now=102;task:Execute()
    assert(not s.load('core.tracker').done and #s.interactions==0)
    -- CRT-1/L9: without an observed kill the wait ends after 30 s (opened).
    s.now=129;task:Execute();assert(not s.load('core.tracker').done)
    s.now=130.1;task:Execute()
    assert(s.load('core.tracker').done and #s.interactions==0)
end)

test('noninteractable confirmation resets when the actor snapshot fails', function()
    local s=session();local chest=actor('X1_Undercity_Chest_Attunement',0);s.actors={chest}
    local task=s.load('tasks.goto_chest');task:Execute();chest.interactable=false
    s.now=101;task:Execute();assert(not s.load('core.tracker').done)
    local enumerate=s.env.actors_manager.get_all_actors
    s.env.actors_manager.get_all_actors=function() return nil end;s.now=101.5;task:Execute()
    s.env.actors_manager.get_all_actors=enumerate;s.now=102;task:Execute()
    assert(not s.load('core.tracker').done)
    s.now=103.1;task:Execute();assert(s.load('core.tracker').done)
end)

test('transient disappearance cannot complete without newly observed loot', function()
    local s=session();local chest=actor('X1_Undercity_Chest_Attunement',0);s.actors={chest}
    s.items={actor('ExistingDrop',0)}
    local task=s.load('tasks.goto_chest');task:Execute();s.actors={}
    s.now=101;task:Execute();s.now=103;task:Execute()
    assert(not s.load('core.tracker').done)
    s.actors={chest};s.now=104;task:Execute();assert(not s.load('core.tracker').done)
end)

test('confirmed opening waits for delayed looting and a new quiet period', function()
    local s=session();local phase=s.load('core.reward_phase');phase.mark_opened('test')
    local exit=s.load('tasks.exit_undercity')
    s.env.LooteerPlugin={getSettings=function(k) return k=='enabled' or s.looting end}
    assert(not exit.shouldExecute())
    s.now=102;s.looting=true;assert(not exit.shouldExecute())
    s.now=110;assert(not exit.shouldExecute())
    s.looting=false;s.now=111;assert(not exit.shouldExecute())
    s.now=113.9;assert(not exit.shouldExecute())
    s.now=114;assert(exit.shouldExecute())
end)

test('LooteerV3 active signal takes precedence over stale legacy state', function()
    local s=session();local utils=s.load('core.utils')
    s.env.LooteerPlugin={get_enabled=function() return true end,
        is_actively_looting=function() return false end,
        getSettings=function() return true end}
    assert(not utils.is_looting())
    s.env.LooteerPlugin.is_actively_looting=function() return true end
    assert(utils.is_looting())
    s.env.LooteerPlugin.get_enabled=function() return false end
    assert(not utils.is_looting(),'disabled Looter retained stale active state')
end)

test('Looter guard falls back across unreadable APIs and holds on unknown', function()
    local s=session();local utils=s.load('core.utils')
    s.env.LooteerPlugin={is_actively_looting=function() error('unavailable') end,
        is_idle=function() return true end}
    assert(not utils.is_looting())
    s.env.LooteerPlugin.is_idle=function() return 'unknown' end
    assert(utils.is_looting())
    s.env.LooteerPlugin.getSettings=function(k) if k=='looting' then return false end end
    assert(utils.is_looting(),'unreadable modern owner cannot be cleared by a legacy false/nil fallback')
end)

test('real legacy nil getter distinguishes disabled, idle and failed reads', function()
    local s=session();local utils=s.load('core.utils')
    local values={enabled=false,looting=true}
    s.env.LooteerPlugin={getSettings=function(k) return values[k] or nil end}
    assert(not utils.is_looting(),'disabled V2 retained stale looting')
    values.enabled=true;values.looting=false
    assert(not utils.is_looting(),'V2 successful nil idle was treated as busy')
    values.looting=true;assert(utils.is_looting())
    s.env.LooteerPlugin.getSettings=function() error('unreadable') end
    assert(utils.is_looting(),'read failure was treated as idle')
end)

test('foreign Alfred keeps ownership during reward cleanup', function()
    local s=session();s.all_actors={actor('X1_Undercity_Chest_Attunement',0)}
    s.env.AlfredTheButlerPlugin={get_status=function() return {enabled=true,trigger_tasks=true} end}
    local manager=s.load('core.task_manager');manager.execute_tasks()
    assert(manager.get_current_task().name=='alfred_running' and #s.interactions==0)
end)

test('scheduler restarts loot quiet time after obols owns intervening pulses', function()
    local s=session();s.load('core.tracker').observe_world()
    s.load('core.reward_phase').mark_opened('test')
    s.looting=false
    s.env.LooteerPlugin={getSettings=function(k) return k=='enabled' or s.looting end}
    local obols=s.load('tasks.loot_obols');local collecting=false
    obols.shouldExecute=function() return collecting end
    obols.Execute=function() end
    local manager=s.load('core.task_manager');manager.execute_tasks()
    assert(s.load('core.tracker').loot_quiet_since==100)
    s.now=101;collecting=true;s.looting=true;manager.execute_tasks()
    assert(manager.get_current_task()==obols and not s.load('core.tracker').loot_quiet_since)
    s.now=110;collecting=false;s.looting=false;manager.execute_tasks()
    assert(manager.get_current_task().name=='finish_undercity' and s.teleports==0)
    s.now=112.9;manager.execute_tasks();assert(s.teleports==0)
    s.now=113;manager.execute_tasks();assert(manager.get_current_task().name=='exit_undercity')
end)

test('replacement chest cannot inherit the previous chest interaction', function()
    local s=session();s.actors={actor('X1_Undercity_Chest_Attunement',0)}
    local task=s.load('tasks.goto_chest');task:Execute()
    s.actors={actor('X1_Undercity_Chest_Attunement',0,{interactable=false})}
    s.now=101;task:Execute();s.now=103;task:Execute()
    assert(not s.load('core.tracker').done and not task.last_interact_call)
end)

test('reward phase near run deadline receives one bounded cleanup grace', function()
    -- The chest stays out of reach (never interacted), so only the grace ends it.
    local s=session();local tr=s.load('core.tracker');tr.observe_world()
    s.now=701;s.all_actors={actor('X1_Undercity_Chest_Attunement',30)}
    local manager=s.load('core.task_manager');manager.execute_tasks()
    assert(manager.get_current_task().name=='goto_chest' and s.teleports==0)
    assert(tr.reward_grace_until==746)
    s.now=745;manager.execute_tasks();assert(tr.reward_grace_until==746 and s.teleports==0)
    s.now=746;manager.execute_tasks();assert(manager.get_current_task().name=='exit_undercity')
    assert(not tr.done,'bounded failure was reported as reward success')
end)

test('chest unlock wait does not consume the interaction confirmation budget', function()
    local s=session();local chest=actor('X1_Undercity_Chest_Attunement',0,{interactable=false});s.actors={chest}
    local task=s.load('tasks.goto_chest');task:Execute();s.now=115;task:Execute()
    assert(not s.load('core.tracker').chest_failed)
    chest.interactable=true;s.now=116;task:Execute()
    assert(task.interact_time==116 and #s.interactions==1)
end)

test('new floor resets reward evidence and stale chest interaction state', function()
    local s=session();local manager=s.load('core.task_manager')
    s.all_actors={actor('X1_Undercity_Chest_Attunement',0)};manager.execute_tasks()
    local task=s.load('tasks.goto_chest');assert(task.last_interact_call)
    s.now=101;s.world_id=2;s.all_actors={};manager.execute_tasks()
    local tr=s.load('core.tracker')
    assert(not tr.reward_seen and not tr.done and not tr.reward_opened_time and not task.last_interact_call)
end)

test('enticement timer belongs to the actor currently being handled', function()
    local s=session();local a=actor('SpiritHearth_Switch_A',0);s.actors={a}
    local task=s.load('tasks.interact_enticement');task:Execute()
    s.now=105;s.actors={actor('SpiritHearth_Switch_B',0)};task:Execute()
    assert(next(s.load('core.tracker').enticement)==nil,'new objective inherited an expired timer')
    assert(#s.interactions==2)
end)

test('standalone floor portal works without a visible warp pad', function()
    local s=session();s.actors={actor('X1_Undercity_PortalSwitch',1)}
    local task=s.load('tasks.portal');assert(task.shouldExecute());task:Execute();s.now=100.1;task:Execute()
    assert(#s.interactions==1)
end)

test('arrived warp pad without a portal does not monopolize task priority', function()
    local s=session();s.actors={actor('X1_Undercity_WarpPad',0)}
    assert(not s.load('tasks.portal').shouldExecute())
end)

test('custom explorer resets sticky boss-room state before predicate gating', function()
    local s=session();s.settings.use_custom_explorer=true;s.actors={actor('Healing_Well_Basic',0)}
    local task=s.load('tasks.custom_explorer');assert(not task.shouldExecute())
    s.actors={};s.load('core.tracker').floor_generation=1
    assert(task.shouldExecute());assert(not task.get_floor_state().in_boss_room)
end)

test('custom explorer skips its own failed objective on the next selection', function()
    local s=session();s.settings.use_custom_explorer=true;s.actors={actor('SpiritHearth_Switch_A',30)}
    local task=s.load('tasks.custom_explorer');assert(task.shouldExecute());task:Execute()
    assert(s.target:x()==30)
    s.now=102;task:Execute();s.now=102.1;task:Execute()
    assert(s.target:x()~=30,'failed objective was selected again')
end)

test('obols use API identity, cap comparison and skip unreachable pickups', function()
    local s=session();local orb=actor('LocalizedObols',10);orb.obols=true;s.items={orb}
    local task=s.load('tasks.loot_obols');assert(task.shouldExecute());task:Execute()
    s.now=113;task:Execute();assert(not task.shouldExecute())
    task.reset();s.obols=2600;assert(not task.shouldExecute())
    s.obols=0;s.zone='Town';assert(not task.shouldExecute())
end)

test('inactive legacy tribute sorting handles empty inventory safely', function()
    local s=session();town(s)
    assert(not s.load('tasks.sort_tribute').shouldExecute())
end)

print('WonderCity: '..checks..' focused regressions passed')
