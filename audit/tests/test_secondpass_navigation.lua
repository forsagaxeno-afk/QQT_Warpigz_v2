-- Independent second-pass reproductions against executable navigation modules.
local checks=0
local function eq(a,b,message)
    assert(a==b,(message or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b));checks=checks+1
end
REAPER_TEST_HARNESS_ONLY=true
local reaper_harness=assert(loadfile(SUITE_ROOT..'/audit/tests/test_reaper.lua'))()
REAPER_TEST_HARNESS_ONLY=nil

-- Reaper release must not erase an already-running Alfred's Batmobile goal,
-- including status implementations that omit the legacy trigger booleans.
for _,state in ipairs({'running','teleport','pending','paused','unreadable','missing_method','missing_enabled'}) do
    local e,c=reaper_harness();local calls=0
    e.BatmobilePlugin={stop_long_path=function()calls=calls+1 end,clear_target=function()calls=calls+1 end}
    e.AlfredTheButlerPlugin={get_status=function()if state=='unreadable' then error('stale') end return {[state]=true,enabled=true} end}
    if state=='missing_method' then e.AlfredTheButlerPlugin.get_status=nil end
    if state=='missing_enabled' then e.AlfredTheButlerPlugin.get_status=function()return {}end end
    local owner=e.require('core.navigation_owner');owner.claim();owner.release()
    eq(calls,0,state..' prevents foreign navigation reset');eq(owner.active,false)
    owner.release();eq(calls,0,'idempotent cleanup')
end
do
    local e,c=reaper_harness();local calls=0
    e.BatmobilePlugin={stop_long_path=function()calls=calls+1 end,clear_target=function()calls=calls+1 end}
    local owner=e.require('core.navigation_owner');owner.claim();owner.release()
    eq(calls,2,'normal owned route is stopped')
end
-- Passive handoff must not overwrite a companion reporting modern busy fields.
for _,state in ipairs({'running','teleport','pending','paused','unreadable','missing_method','missing_enabled'}) do
    local e,c,settings=reaper_harness();settings.use_alfred=true;local triggers=0
    e.AlfredTheButlerPlugin={get_status=function()if state=='unreadable' then error('stale') end return {[state]=true,enabled=true} end,
        trigger_tasks_with_teleport=function()triggers=triggers+1 end}
    if state=='missing_method' then e.AlfredTheButlerPlugin.get_status=nil end
    if state=='missing_enabled' then e.AlfredTheButlerPlugin.get_status=function()return {}end end
    local task=e.require('tasks.alfred');eq(task.shouldExecute(),true,state..' yields')
    task.Execute();eq(triggers,0,'busy/unknown companion is not overwritten')
end

-- Legacy callbacks may be synchronous, nil-accepted, lost, late, or repeated.
-- Recovery retires only our wait, never resumes/pauses Alfred or invents success.
do
    local e,c,s=reaper_harness();s.use_alfred=true
    local status={enabled=true,need_trigger=true};local callbacks={};local resumes,pauses=0,0
    e.AlfredTheButlerPlugin={get_status=function()if status=='unknown' then error('loading')end return status end,
        resume=function()resumes=resumes+1 end,pause=function()pauses=pauses+1 end,
        trigger_tasks_with_teleport=function(_,cb)callbacks[#callbacks+1]=cb end}
    local task=e.require('tasks.alfred');task.Execute()
    eq(#callbacks,1);eq(resumes,0,'Reaper cannot resume an unowned legacy pause')
    c.time(108);eq(task.shouldExecute(),true);eq(task.status,'waiting for alfred to complete')
    c.time(109);status='unknown';eq(task.shouldExecute(),true)
    c.time(120);status={enabled=true,need_trigger=true};task.shouldExecute()
    eq(task.status,'waiting for alfred to complete','unknown sample resets stable idle interval')
    c.time(121);task.shouldExecute();eq(task.status,'waiting for alfred to complete')
    c.time(122);task.shouldExecute();eq(task.status,'idle','lost callback has bounded healthy-idle recovery')
    task.Execute();eq(#callbacks,1,'recovery backoff prevents immediate overwrite')
    c.time(127);eq(task.shouldExecute(),true,'retirement does not invent successful maintenance grace')
    task.Execute();eq(#callbacks,2);callbacks[1]()
    eq(task.status,'waiting for alfred to complete','late retired callback cannot release next request')
    callbacks[2]();eq(task.status,'idle');eq(task.shouldExecute(),false,'real callback gets completion grace')
    c.time(140);callbacks[2]();c.time(158)
    eq(task.shouldExecute(),true,'duplicate callback cannot extend completion grace');eq(pauses,0)
end

-- Pending work and unreadable status hold ownership even after a trigger throws.
do
    local e,c,s=reaper_harness();s.use_alfred=true
    local status={enabled=true,need_trigger=true};local calls=0
    e.AlfredTheButlerPlugin={get_status=function()return status end,
        trigger_tasks_with_teleport=function()calls=calls+1;status.pending=true;error('enqueued before error')end}
    local task=e.require('tasks.alfred');eq(pcall(task.Execute),true)
    eq(task.status,'waiting for alfred to complete','exception is an uncertain request, not rejection')
    c.time(200);eq(task.shouldExecute(),true);task.Execute();eq(calls,1,'pending request not overwritten')
    status.pending=false;c.time(201);task.shouldExecute();eq(task.status,'waiting for alfred to complete')
    c.time(203);task.shouldExecute();eq(task.status,'idle','healthy idle reconciles uncertain request')
end

-- Replacement/disabled companions cannot complete an obsolete local request.
do
    local e,c,s=reaper_harness();s.use_alfred=true;local callback
    e.AlfredTheButlerPlugin={get_status=function()return {enabled=true,need_trigger=true}end,
        trigger_tasks_with_teleport=function(_,cb)callback=cb end}
    local task=e.require('tasks.alfred');task.Execute()
    e.AlfredTheButlerPlugin={get_status=function()return {enabled=true,running=true}end}
    callback();eq(task.status,'waiting for alfred to complete','callback from replaced plugin ignored')
    eq(task.shouldExecute(),true);eq(task.status,'idle','replacement retires our obsolete reservation')
    s.use_alfred=false;eq(task.shouldExecute(),true,'disabled integration still yields to active companion')
    e.AlfredTheButlerPlugin.get_status=function()return {enabled=false}end
    eq(task.shouldExecute(),false,'confirmed disabled companion releases priority')
end

-- The supplied status keeps teleport true after terminal done/failed flags.
for _,terminal in ipairs({'teleport_done','teleport_failed'})do
    local e,c,s=reaper_harness();s.use_alfred=true;local stopped=0
    e.BatmobilePlugin={stop_long_path=function()stopped=stopped+1 end,clear_target=function()stopped=stopped+1 end}
    e.AlfredTheButlerPlugin={get_status=function()return {enabled=true,teleport=true,[terminal]=true}end}
    eq(e.require('tasks.alfred').shouldExecute(),false,terminal..' latch is no active trip')
    local owner=e.require('core.navigation_owner');owner.claim();owner.release();eq(stopped,2,'own cleanup after terminal teleport')
end

-- Unavailable actor samples cannot finish a chest sequence or activate an altar.
do
    local e,c,settings=reaper_harness();local rotation=e.require('core.boss_rotation');rotation.set_external('duriel')
    local tracker=e.require('core.tracker');local chest=e.require('tasks.open_chest')
    c.actors({c.actor('EGB_Chest_Duriel')});eq(chest.shouldExecute(),true);chest.Execute()
    c.actors(nil);c.time(120);chest.Execute();c.time(130);chest.Execute()
    eq(tracker.total_kills,0,'nil actor list is not a redeemed chest');eq(rotation.external_consumed,false)
    c.actors({});chest.Execute();c.time(132);chest.Execute();eq(tracker.total_kills,0,'fresh absence must settle')
    c.time(134);chest.Execute();eq(tracker.total_kills,1,'valid stable disappearance completes normally')
end
do
    local e,c,settings=reaper_harness();local rotation=e.require('core.boss_rotation');rotation.set_external('duriel')
    local tracker=e.require('core.tracker');local altar=e.require('tasks.interact_altar')
    c.actors({c.actor('Boss_WT4_Duriel')});altar.Execute();eq(c.interactions,1)
    c.actors(nil);c.time(103);altar.Execute();eq(tracker.altar_activated,false,'nil stream is not altar disappearance')
    c.actors({});altar.Execute();eq(tracker.altar_activated,true,'known altar disappearance keeps prior behavior')
end

local V={};V.__index=V
function V:new(x,y,z)return setmetatable({x,y,z or 0},self)end
function V:x()return self[1]end;function V:y()return self[2]end;function V:z()return self[3]end
local function bm_fixture()
    local c={now=10,moves=0,unpaused=0};local e=setmetatable({}, {__index=_G});e._G=e
    local root=SUITE_ROOT..'/Batmobile-1.0.12/'
    local player={get_position=function()return V:new(0,0,0)end,get_buffs=function()return {}end,is_dead=function()return false end,
        get_attribute=function()return 0 end,get_active_spell_id=function()return -1 end,get_current_speed=function()return 0 end}
    e.vec3=V;e.vec2=V;e.get_hash=function()return 1 end;e.get_time_since_inject=function()return c.now end
    e.get_local_player=function()return player end;e.get_player_position=player.get_position
    e.get_current_world=function()return {get_current_zone_name=function()return 'Dungeon'end}end
    e.actors_manager={get_all_actors=function()return {}end};e.attributes={PLAYER_IN_TOWN_LEVEL_AREA=1}
    e.console={print=function()end};e.utility={set_height_of_valid_position=function(p)return p end,is_point_walkeable=function()return true end,can_cast_spell=function()return false end}
    e.pathfinder={request_move=function()c.moves=c.moves+1 end};e.cast_spell={position=function()return false end}
    local function widget(v)return {get_state=function()return v and 1 or 0 end,set=function(_,n)v=n end}end
    local gui={elements={reset_keybind=widget(false),long_path_set_target=widget(false),long_path_set_target_cursor=widget(false),
        long_path_test=widget(false),freeroam_keybind_toggle=widget(false)},render=function()end}
    local settings={normalizer=2,step=.5,path_smooth_step=0,log_level=0,plugin_label='test',use_movement=false,
        spell_interval=.15,min_spell_dist=3,explore_path_budget_ms=80,update_settings=function()end,nav_viz=true}
    local tracker={bench_enabled=false,bench_start=function()end,bench_stop=function()end,bench_count=function()end,bench_report=function()end,
        evaluated={},timer_update=0,timer_move=0}
    local explorer={frontier_count=0,visited_count=0,retry_count=0,backtrack={},frontier_node={},visited={},
        update=function()end,reset=function()end,select_node=function()return nil end,clear_frontiers_in_box=function()return 0 end}
    local modules={gui=gui,['core.settings']=settings,['core.tracker']=tracker,['core.explorer']=explorer,
        ['core.pathfinder']={find_path=function(a,b)return {a,b},false end,
            find_path_debug=function(a,b)return {a,b},1,.001,'found'end,clear_wall_penalty_cache=function()end}}
    e.require=function(name)if modules[name]~=nil then return modules[name]end
        local value=assert(loadfile(root..name:gsub('%.','/')..'.lua','t',e))();modules[name]=value;return value end
    e.checkbox={new=function()return {}end};e.on_update=function(fn)c.update=fn end;e.on_render_menu=function()end;e.on_render=function()end
    e.graphics={circle_3d=function()end,line=function()end,text_2d=function()end}
    for _,color in ipairs({'white','green','red','blue','yellow'})do e['color_'..color]=function()return 0 end end
    e.get_screen_width=function()return 1920 end;e.get_screen_height=function()return 1080 end
    assert(loadfile(root..'main.lua','t',e))()
    c.update();c.api=e.BatmobilePlugin;c.nav=e.require('core.navigator');c.gui=gui;c.player=player
    function c.tick()c.now=c.now+.2;c.update()end
    return c,e
end
-- Main's automatic driver honors pause; explicit movement while paused remains
-- available to combat tasks, which rely on pause meaning no exploration.
do
    local c=bm_fixture();eq(c.api.navigate_long_path('reaper',V:new(20,0,0)),true)
    c.api.pause('reaper');local moves=c.moves;c.tick();c.tick()
    eq(c.nav.paused,true,'native callback does not resume an external pause');eq(c.moves,moves,'paused autonomous route is idle')
    c.api.move('reaper');eq(c.moves>moves,true,'explicit caller movement remains supported')
    moves=c.moves;c.api.resume('reaper');c.tick();eq(c.moves>moves,true,'resume restarts autonomous route')
    c.api.stop_long_path('reaper');c.api.pause('reaper');c.gui.elements.freeroam_keybind_toggle:set(true);c.tick()
    eq(c.nav.paused,false,'new manual freeroam toggle is an explicit resume')
    c.api.pause('reaper');c.tick();eq(c.nav.paused,true,'persistent freeroam toggle cannot override later pause')
end
-- The traversal overlay receives an actor, not a vec3; stale handles are ignored.
do
    local c,e=bm_fixture();c.nav.last_trav={get_position=function()return V:new(1,1,0)end}
    local draw=e.require('core.drawing');eq(pcall(draw.draw_nodes,c.player),true,'actor-only traversal overlay')
    c.nav.last_trav={get_position=function()error('stale')end}
    eq(pcall(draw.draw_nodes,c.player),true,'stale traversal overlay')
end
print('Second-pass navigation audit: '..checks..' checks')
