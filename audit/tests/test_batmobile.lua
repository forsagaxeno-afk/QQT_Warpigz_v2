local root = SUITE_ROOT .. '/Batmobile-1.0.12/'
local tests, checks = 0, 0
local function eq(actual, expected, message)
    checks = checks + 1
    assert(actual == expected, (message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end
local Vec = {}; Vec.__index = Vec
function Vec:new(x,y,z) return setmetatable({_x=x,_y=y,_z=z or 0}, self) end
function Vec:x() return self._x end
function Vec:y() return self._y end
function Vec:z() return self._z end
local function v(x,y,z) return Vec:new(x,y,z) end
local function fixture()
    local counts = {casts=0, moves=0, prints=0, walk_checks=0}
    local now = 10
    local player = {pos=v(0,0), buffs={}}
    function player:get_position() return self.pos end
    function player:get_buffs() return self.buffs end
    function player:get_attribute() return 0 end
    function player:get_character_class_id() return 0 end
    function player:is_dead() return false end
    local settings = {step=0.5,normalizer=2,path_smooth_step=0,log_level=0,
        plugin_label='test',use_movement=false,spell_interval=0.15,
        min_spell_dist=3,explore_path_budget_ms=80,update_settings=function() end}
    local tracker = {bench_enabled=false,bench_start=function() end,bench_stop=function() end,
        bench_count=function() end,bench_report=function() end}
    local env = setmetatable({vec3=Vec, get_time_since_inject=function() return now end,
        get_local_player=function() return player end, get_current_world=function() return {get_current_zone_name=function() return 'test' end} end,
        attributes={PLAYER_IN_TOWN_LEVEL_AREA=1},
        console={print=function() counts.prints=counts.prints+1 end},
        utility={set_height_of_valid_position=function(p) return p end,
            is_point_walkeable=function() counts.walk_checks=counts.walk_checks+1; return true end,
            can_cast_spell=function() return true end, is_ray_cast_walkeable=function() return true end},
        actors_manager={get_all_actors=function() return {} end},
        cast_spell={position=function() counts.casts=counts.casts+1; return true end},
        pathfinder={request_move=function() counts.moves=counts.moves+1 end},
        interact_object=function() end}, {__index=_G})
    local loaded = {['core.settings']=settings,['core.tracker']=tracker}
    env.require = function(name)
        if loaded[name] ~= nil then return loaded[name] end
        local chunk = assert(loadfile(root .. name:gsub('%.','/') .. '.lua', 't', env))
        local module = chunk(); loaded[name]=module; return module
    end
    return {env=env,loaded=loaded,settings=settings,tracker=tracker,counts=counts,player=player,
        time=function(t) now=t end,require=env.require}
end
local function test(name, fn)
    fn(); tests=tests+1; print('PASS Batmobile: ' .. name)
end
local function nav_fixture()
    local f=fixture()
    local explorer={backtracking=false,frontier_count=0,backtrack={},visited={keep=true},
        update=function() end,select_node=function() return nil end,
        reset=function() end,clear_frontiers_in_box=function() return 0 end}
    f.loaded['core.explorer']=explorer
    f.loaded['core.movement_engine']={pick=function() return nil end}
    f.loaded['core.pathfinder']={find_path=function(a,b) return {a,b},false end,
        clear_wall_penalty_cache=function() end}
    f.nav=f.require('core.navigator'); f.explorer=explorer
    return f
end

test('numeric and serialized crowd-control hashes are recognized', function()
    local f=fixture(); local u=f.require('core.utils')
    for _,h in ipairs({39809,290961,290962,'39809'}) do
        f.player.buffs={{name_hash=h}}; eq(u.is_cced(f.player),true,'CC hash '..h)
    end
    f.player.buffs={{name_hash=7}}; eq(u.is_cced(f.player),false)
end)

test('custom targets honor disable_spell, drift reuse, pause, and movement reset',function()
    local f=nav_fixture();local n=f.nav
    eq(n.set_target(nil),false)
    n.pause();eq(n.paused,true);eq(n.set_target(v(10,0),true),true)
    local path={v(0,0),v(10,0)};n.path=path
    eq(n.set_target(v(11,0),true),true);eq(n.path,path,'small drift keeps path')
    eq(n.disable_spell,true)
    f.settings.use_movement=true;f.settings.use_teleport=true
    n.move();eq(f.counts.casts,0,'normal move cannot cast disabled spells')
    eq(f.counts.moves>0,true,'pause still allows explicit movement')
    -- keep the caller active (a >0.75 s move gap is a yield and would
    -- discount the stuck window)
    f.time(12.9);n.move()
    f.time(13);n.last_update=10;n.last_pos=v(0,0);n.move()
    eq(n.unstuck_count,1,'stuck detection ran for the active caller')
    eq(f.counts.casts,0,'unstuck evade must honor disable_spell')
    local history=f.explorer.visited;n.reset_movement()
    eq(f.explorer.visited,history,'movement reset preserves explorer history')
    eq(n.disable_spell,nil);eq(n.target,nil)
end)

test('traversal approach returns the validated height and accepts exploration routing',function()
    local f=nav_fixture(); local n=f.nav
    f.env.utility.set_height_of_valid_position=function(p) return v(p:x(),p:y(),8) end
    eq(n.get_closeby_node(v(5,0,8),0.5):z(),8)
    local trav={get_position=function() return v(5,0,8) end,get_skin_name=function() return 'Traversal_Gizmo_Up' end}
    f.env.actors_manager.get_all_actors=function() return {trav} end
    eq(n.try_traversal_route(f.player,f.player.pos),true,'nil destination is valid for explorer traversal')
end)

test('chain crossing uses a local timestamp and clears actual escape state',function()
    local f=nav_fixture();local n=f.nav;f.player.pos=v(10,0)
    f.player.buffs={{name=function() return 'Player_Traversal_Climb' end}}
    local function trav(x) return {get_position=function() return v(x,0) end,get_skin_name=function() return 'Traversal_Gizmo_Up' end} end
    local a,b=trav(0),trav(12)
    f.env.actors_manager.get_all_actors=function() return {a,b} end
    n.last_trav=a;n.target=v(50,0);n.trav_escape_pos=v(99,0)
    n.update_trap_state=function() end
    n.move()
    eq(n.last_trav,b);eq(n.trap_post_escape_grace_until,25)
    eq(n.trav_escape_pos,nil,'chain must clear the real field, not trap_escape_pos')
    eq(#n.trav_history,1);eq(f.counts.moves,0,'do not interrupt traversal animation')
    f.time(10.1);n.move()
    eq(n.last_trav,b,'same buff must not consume the chained traversal')
    eq(#n.trav_history,1,'one traversal buff produces one history entry')
end)

test('A* preserves endpoints, detours, partial status and snapshot IDs',function()
    local f=fixture();local pf=f.require('core.pathfinder')
    f.env.utility.is_point_walkeable=function(p)
        return not (p:x()==2 and p:y()>=-1 and p:y()<=1)
    end
    local path,partial=pf.find_path(v(0,0),v(4,0),true)
    eq(partial,false);eq(path[1]:x(),0);eq(path[#path]:x(),4)
    local detoured=false
    for _,node in ipairs(path) do if math.abs(node:y())>1 then detoured=true end end
    eq(detoured,true,'path must go around wall')
    eq(pf.last_pathfind.status,'found');eq(pf.last_pathfind.call_id,1)
    local partial_path,_,_,status=pf.find_path_debug(v(0,0),v(100,0),{iter_cap=4,time_cap=1})
    eq(status,'iter_limit_partial');eq(#partial_path>1,true)
    pf.find_path(v(0,0),v(0,0),true);eq(pf.last_pathfind.call_id,2)
end)

test('long route reconstruction avoids quadratic front inserts',function()
    local f=fixture();local inserts=0
    f.env.table=setmetatable({insert=function(t,p,value)
        if value~=nil and p==1 then inserts=inserts+#t end
        return table.insert(t,p,value)
    end},{__index=table})
    local pf=f.require('core.pathfinder')
    local path,_,_,status=pf.find_path_debug(v(0,0),v(100,0),{iter_cap=10000,time_cap=1})
    eq(status,'found');eq(#path,201);eq(path[1]:x(),0);eq(path[201]:x(),100)
    eq(inserts,0,'no shifted entries during reconstruction (baseline 20,100)')
end)

test('density result is preserved with one position read per enemy',function()
    local f=fixture();local reads=0;local enemies={}
    for i=1,10 do enemies[i]={get_position=function() reads=reads+1;return v(4,0) end} end
    f.env.actors_manager.get_enemy_npcs=function() return enemies end
    local path={};for i=1,24 do path[i]=v(i,0) end
    local h=f.require('core.movement_helpers');local count,node=h.largest_pack_on_path(path,1)
    eq(count,10);eq(node,path[3],'same earliest densest node')
    eq(reads,10,'position calls reduced from 240 to 10')
end)

test('backtrack restoration scales with active frontiers, not historical holes',function()
    local f=fixture();local e=f.require('core.explorer');local reads=0
    e.frontier_index=100000
    e.frontier_order=setmetatable({}, {__index=function() reads=reads+1;return nil end})
    e.backtrack_secondary={v(100,0)}
    e.set_current_pos(f.player)
    eq(reads,0,'no historical index reads (baseline 100,001)')
    eq(#e.backtrack_secondary,0);eq(e.backtrack[1]:x(),0)
end)

test('normal log level avoids per-rule formatting and console writes',function()
    local f=fixture();local formats=0
    f.env.string=setmetatable({format=function(...) formats=formats+1;return string.format(...) end},{__index=string})
    local engine=f.require('core.movement_engine')
    local sid=engine.pick({{enabled=true,skill_id=337031,conditions={{type='skill_ready'}}}},
        {local_player=f.player,player_pos=v(0,0),path={v(5,0)},min_spell_dist=3})
    eq(sid,337031);eq(formats,0);eq(f.counts.prints,0)
end)

test('long path launch clears stale state, preserves drawing path and runtime budgets',function()
    local f=nav_fixture();local n=f.nav;local seen_opts
    f.loaded['core.pathfinder'].find_path_debug=function(a,b,opts) seen_opts=opts;return {a,b},2,0.001,'found' end
    local lp=f.require('core.long_path');n.is_partial_path=true;n.pathfind_replan_cooldown=99;n.pathfind_area_cooldown=99
    n.trav_escape_pos=v(0,0);n.disable_spell=true;n.pause()
    eq(lp.navigate_to(v(20,0)),true);eq(n.is_partial_path,false);eq(n.pathfind_area_cooldown,-1)
    eq(n.pathfind_replan_cooldown,-1);eq(n.trav_escape_pos,nil);eq(n.disable_spell,nil)
    eq(n.paused,false);eq(f.tracker.paused,false);eq(seen_opts.time_cap,0.300);eq(seen_opts.iter_cap,10000)
    eq(lp.active_path~=n.path,true,'drawing path must not alias mutable nav path')
    n.path[1]=nil;eq(#lp.active_path,2)
    eq(lp.navigate_to(nil),false);eq(lp.find_long_path(v(0,0),nil),nil)
end)

test('long-path query survives traversal nil target; explicit reset cancels autonomous work',function()
    local f=nav_fixture();local n=f.nav
    local lp=f.require('core.long_path');local external=f.require('core.external')
    lp.navigating=true;n.target=nil;n.last_trav={}
    eq(external.is_long_path_navigating(),true)
    n.last_trav=nil;n.trav_escape_pos=v(0,0);eq(external.is_long_path_navigating(),true)
    n.trav_escape_pos=nil;eq(external.is_long_path_navigating(),false)
    for _,reset in ipairs({'reset','reset_movement'}) do
        lp.navigating=true;n.target=v(8,0);n.last_trav={};external[reset]('test')
        eq(lp.navigating,false);eq(n.target,nil);eq(n.last_trav,nil)
    end
end)

test('main tolerates absent player, avoids duplicate drive, and preserves crossing',function()
    local f=fixture();local callback;local stopped,moves,updates=0,0,0
    local player=nil;f.env.get_local_player=function() return player end
    local function widget(value) return {get_state=function() return value end,set=function(_,new) value=new and 1 or 0 end} end
    local elements={reset_keybind=widget(0),long_path_set_target=widget(0),long_path_set_target_cursor=widget(0),long_path_test=widget(0),freeroam_keybind_toggle=widget(1)}
    f.loaded.gui={elements=elements,render=function() end}
    f.loaded['core.drawing']={};f.loaded['core.movement_helpers']={observe_buffs=function() end}
    f.loaded['core.external']={}
    local n={target=v(10,0),path={v(10,0)},unpause=function() end,update=function() updates=updates+1 end,move=function() moves=moves+1 end,clear_target=function() end,reset=function() end,note_loading=function() end}
    f.loaded['core.navigator']=n
    local pending=false
    local lp={navigating=false,is_traversal_pending=function() return pending end,observe_world=function() return false end}
    -- Bind after declaration so the function captures the local table.
    lp.stop_navigation=function() stopped=stopped+1;lp.navigating=false end
    f.loaded['core.long_path']=lp
    f.env.checkbox={new=function() return {} end};f.env.get_hash=function() return 1 end
    f.env.on_update=function(cb) callback=cb end;f.env.on_render_menu=function() end;f.env.on_render=function() end
    assert(loadfile(root..'main.lua','t',f.env))();callback();eq(moves,0)
    player=f.player;lp.navigating=true;callback();eq(moves,1);eq(updates,1)
    n.target=player.pos;pending=true;callback();eq(lp.navigating,true);eq(moves,2)
    elements.reset_keybind=widget(1);callback();eq(stopped,1);eq(lp.navigating,false)
    local before_moves=moves;local revives=0
    f.env.revive_at_checkpoint=function() revives=revives+1 end
    player.is_dead=function() return true end
    callback();callback();eq(revives,1,'async revive requests are throttled')
    eq(moves,before_moves,'dead actor must not receive movement after revive')
    f.time(11);callback();eq(revives,2,'failed async revive can retry')
    player.is_dead=function() return false end
    f.env.get_current_world=function() return nil end
    callback();eq(moves,before_moves,'loading blocks freeroam and pathfinding')
    eq(n.last_update,16,'loading retains the existing unstuck grace')
end)

print(string.format('Batmobile regression suite: %d tests, %d assertions', tests, checks))
