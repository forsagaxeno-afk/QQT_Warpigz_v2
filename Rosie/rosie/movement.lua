-- One route owner; numeric snapshots prevent mutable host vectors faking progress.
local M={}
local native=pathfinder
local state={owner=nil,detail='Idle',requests=0,repaths=0}
local allowed=function() return false end
local pace=function() return 0.20 end
local planner=nil -- QQT_Warpigz_v2 local patch: optional waypoint planner
local inherited_cleanup={}
local cleanup_next=0
local cleanup_transferred=false
local function call(object,name,...)
    if not object then return nil end
    local ok,result=pcall(function(...) return object[name](object,...) end,...)
    if ok then return result end
end
local function point(v)
    local x,y,z=call(v,'x'),call(v,'y'),call(v,'z')
    for _,n in ipairs({x,y,z}) do if type(n)~='number' or n~=n or math.abs(n)==math.huge then return nil end end
    if x==nil or y==nil or z==nil then return nil end
    return {x=x,y=y,z=z}
end
local function vector(p) return vec3:new(p.x,p.y,p.z) end
local function distance(a,b) return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2+(a.z-b.z)^2) end
local function world_key(world)
    local id,zone,name=call(world,'get_world_id'),call(world,'get_current_zone_name'),call(world,'get_name')
    if id==nil or not zone or zone=='[sno none]' or not name then return nil end
    return tostring(id)..'|'..name..'|'..zone
end
function M.configure(admission,interval,plan) allowed=admission;pace=interval or pace;planner=plan end
function M.suspend_if_unavailable()
    local player,world=get_local_player(),get_current_world()
    if not point(call(player,'get_position')) or not world_key(world) or call(player,'is_dead')~=false or is_chat_open() then
        M.release('pickup');M.release('town');return true
    end
    return false
end
function M.release(owner,preserve_failure)
    if not preserve_failure and state.blocked and state.blocked.owner==owner then state.blocked=nil end
    if state.owner~=owner then return true end
    local ok,result=pcall(native.clear_stored_path)
    if not ok or result==false then state.releasing=true;state.detail='Waiting for movement release';return false end
    state.owner=nil;state.goal=nil;state.route=nil;state.releasing=false
    state.detail=preserve_failure and state.blocked and state.blocked.detail or 'Idle'
    return true
end
function M.status()
    return {owner=state.owner,detail=state.detail,requests=state.requests,repaths=state.repaths,
        cleanup_pending=state.releasing==true or #inherited_cleanup>0,
        target=state.goal and {x=state.goal.x,y=state.goal.y,z=state.goal.z} or nil}
end
function M.yield(owner)
    -- A cooperating activity has already taken the path. Drop our claim without
    -- clearing its newer command or carrying a stale release into its next frame.
    if state.owner==owner then state.owner=nil;state.goal=nil;state.route=nil;state.releasing=false;state.detail='Movement owned by activity' end
    if state.blocked and state.blocked.owner==owner then state.blocked=nil end
    local pending={}
    for _,job in ipairs(inherited_cleanup) do
        if type(job)=='table' and job.owner==owner then
            if job.yield then job.yield() end
        else pending[#pending+1]=job end
    end
    inherited_cleanup=pending
end
function M.take_cleanup()
    local pending=inherited_cleanup;inherited_cleanup={}
    cleanup_transferred=true
    if state.owner then
        local owner=state.owner
        pending[#pending+1]={owner=owner,run=function() return M.release(owner,true) end,
            yield=function() M.yield(owner) end}
    end
    return pending
end
function M.adopt_cleanup(pending)
    for _,job in ipairs(pending or {}) do inherited_cleanup[#inherited_cleanup+1]=job end
end
function M.retry_cleanup()
    if cleanup_transferred then return true end
    if not state.releasing and #inherited_cleanup==0 then return true end
    local now=get_time_since_inject();if now<cleanup_next then return false end
    cleanup_next=now+0.5
    local pending={}
    for _,job in ipairs(inherited_cleanup) do
        local ok,result=pcall(type(job)=='table' and job.run or job)
        if not ok or result==false then pending[#pending+1]=job end
    end
    inherited_cleanup=pending
    if state.releasing then M.release(state.owner,true) end
    return not state.releasing and #inherited_cleanup==0
end
function M.move(owner,target)
    if state.releasing or #inherited_cleanup>0 then return false end
    if not allowed(owner) then M.release(owner);return false end
    local player,world=get_local_player(),get_current_world()
    local here,goal=point(call(player,'get_position')),point(target)
    local context=world_key(world)
    if not here or not goal or not context or call(player,'is_dead')~=false or is_chat_open() then M.release(owner);return false end
    if state.owner and state.owner~=owner then return false end
    if state.blocked and state.blocked.owner==owner then
        if state.blocked.context==context and distance(goal,state.blocked.goal)<=0.6 then
            state.detail=state.blocked.detail;return false
        end
        state.blocked=nil
    end
    local now=get_time_since_inject()
    local changed=state.owner~=owner or state.context~=context or not state.goal or distance(goal,state.goal)>0.6
    if changed then
        if state.owner and not M.release(owner) then return false end
        state.owner=owner;state.goal=goal;state.context=context;state.next=0
        state.anchor=here;state.progress_at=now;state.route=nil;state.recovery=0;state.overrides=0
    end
    if distance(here,goal)<=1.5 then M.release(owner);return true end
    if distance(here,state.anchor)>=0.4 then state.anchor=here;state.progress_at=now;state.recovery=0 end
    if now-state.progress_at>=3 then
        if state.recovery>=2 then
            state.blocked={owner=owner,goal=goal,context=context,detail='Stopped: no movement progress'}
            M.release(owner,true)
            return false
        end
        local ok,result=pcall(native.clear_stored_path)
        if not ok or result==false then state.detail='Waiting for repath release';return false end
        state.route=nil;state.recovery=state.recovery+1;state.repaths=state.repaths+1;state.progress_at=now
    end
    if now<(state.next or 0) then return true end
    state.next=now+pace()
    -- QQT_Warpigz_v2 local patch (live 2.3.0-rc.6): walk with the native move
    -- request. The host's create_path_game_engine is asynchronous and routes to
    -- the map pin; Rosie sets none, so no route to the NPC or drop ever came back
    -- and Rosie never moved (Temis Blacksmith/stash, Helltide pickup; its calls
    -- also flooded the host). Never call it and never set a pin (global,
    -- user-visible). The progress bound above (3 s, two re-requests, then
    -- 'Stopped: no movement progress') still limits recovery (C6).
    -- QQT_Warpigz_v2 local patch (Rosie 1.0.7, LooteerV3 pathfinder): an owner
    -- may get waypoints around an obstacle (rosie/private/route.lua: pickup
    -- only, ray-cast gated, bounded, cached per goal); nil or an error walks
    -- straight. The waypoints are still walked with request_move.
    if not state.route then
        local ok,route=false,nil
        if planner then ok,route=pcall(planner,owner,here,goal) end
        state.route=ok and type(route)=='table' and #route>0 and route or {goal};state.index=1
    end
    -- QQT_Warpigz_v2 local patch: a planned waypoint is passed only within 0.6 m (they sit 0.8 m apart
    -- along a wall: a 1.5 m skip aimed the player through it; review rc.10).
    while state.index<#state.route and distance(here,state.route[state.index])<=0.6 do state.index=state.index+1 end
    local ok,result=pcall(native.request_move,vector(state.route[state.index]))
    state.requests=state.requests+1
    if not ok then state.detail='Movement request refused';return false end
    if result==false and (state.overrides or 0)<2 then
        -- The host skipped the command because the player is still walking
        -- someone else's path: clear it (at most twice per goal) and resend.
        local dest=point(call(player,'get_move_destination'))
        if dest and distance(dest,state.route[state.index])>1.5 then
            state.overrides=(state.overrides or 0)+1
            pcall(native.clear_stored_path);state.next=0
        end
    end
    -- QQT documents that request_move sends nothing while the player is
    -- already moving. A false from it (assumed to mean such a skip) is not
    -- treated as a refusal, so pickup's busy flag cannot flap on it; the
    -- override above and the progress bound decide instead (precaution).
    state.detail=result==false and 'Walking to '..owner..' destination (host kept its current move)'
        or 'Walking to '..owner..' destination'
    return true
end
function M.for_owner(owner)
    return {request_move=function(target) return M.move(owner,target) end,
        clear_stored_path=function() return M.release(owner) end}
end
return M
