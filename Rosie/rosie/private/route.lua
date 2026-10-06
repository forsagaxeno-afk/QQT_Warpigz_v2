-- QQT_Warpigz_v2 local patch (Rosie 1.0.7, LooteerV3 core/pathfinder.lua
-- a_star, bounded): waypoints around an obstacle for the pickup owner only.
-- nil means "walk straight" (the caller requests the goal itself, as Rosie
-- 1.0.5/1.0.6 did). Bounds:
--  * A* runs only when pcall(utility.is_ray_cast_walkeable, here, goal, ...)
--    returns false (the straight line is blocked); an error, a missing
--    function or any other value walks straight;
--  * at most MAX_NODES expanded nodes per plan; each cell's walkability is
--    asked of the host once per plan; a diagonal step never cuts a wall corner;
--  * "no path" is cached per goal (drop position, 0.6 m cell, world): such a
--    goal is planned at most once. A found path is reused from near the start
--    it was planned from; from elsewhere (after a pause, a rest, a recovery)
--    the goal is planned afresh, at most PLAN_CAP times, then the cached path
--    resumes at the nearest waypoint the ray cast can reach. The cache is
--    dropped on a world change (QQT_Warpigz_v2 local patch, review rc.10).
-- Never calls the engine path and never sets a map pin. LuaJIT/Lua 5.1 safe.
local M={}
local GRID=0.8
local MAX_NODES=1500
local ARRIVE=1.5
local ANGLE=math.rad(20)
local OFF,SPAN=4096,8192
local CACHE_MAX=64
local PLAN_CAP=4
local REUSE=1.5
local DIRS={{1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1}}
M.MAX_NODES=MAX_NODES
M.PLAN_CAP=PLAN_CAP
M.stats={plans=0,straight=0,cached=0,found=0,failed=0,nodes=0,max_nodes=0,cells=0,resumed=0}
local cache,cache_count,cache_world={},0,nil
function M.reset() cache,cache_count,cache_world={},0,nil end
local function host_point(x,y,z)
    local u=rawget(_G,'utility')
    if type(u)~='table' or type(u.is_point_walkeable)~='function' then return nil,true end
    local ok,p=pcall(function() return vec3:new(x,y,z) end)
    if not ok or p==nil then return nil,true end
    if type(u.set_height_of_valid_position)=='function' then
        -- Documented both as in-place and as returning the vector (SEASON_15.md).
        local ok2,q=pcall(u.set_height_of_valid_position,p)
        if ok2 and type(q)=='userdata' or ok2 and type(q)=='table' then p=q end
    end
    local ok3,walk=pcall(u.is_point_walkeable,p)
    if not ok3 then return nil,true end
    if walk~=true then return nil,false end
    local ok4,pz=pcall(function() return p:z() end)
    return {x=x,y=y,z=ok4 and type(pz)=='number' and pz or z},false
end
-- One host call: true only when the host says the straight line is blocked.
local function line_blocked(here,goal)
    local u=rawget(_G,'utility')
    if type(u)~='table' or type(u.is_ray_cast_walkeable)~='function' then return false end
    local ok,walkable=pcall(function()
        return u.is_ray_cast_walkeable(vec3:new(here.x,here.y,here.z),vec3:new(goal.x,goal.y,goal.z),0.5,GRID)
    end)
    return ok and walkable==false
end
local function world_of()
    local ok,key=pcall(function()
        local w=get_current_world()
        return tostring(w:get_world_id())..'|'..tostring(w:get_current_zone_name())
    end)
    return ok and key or ''
end
local function goal_key(goal)
    return math.floor(goal.x/0.6+0.5)..':'..math.floor(goal.y/0.6+0.5)
end
local function dist2(a,b) local dx,dy=a.x-b.x,a.y-b.y;return math.sqrt(dx*dx+dy*dy) end
-- Binary min-heap of node ids ordered by f (lazy deletion of stale entries).
local function push(heap,f,id)
    local n=#heap+1;heap[n]=id
    while n>1 do
        local parent=math.floor(n/2)
        if f[heap[parent]]<=f[heap[n]] then break end
        heap[parent],heap[n]=heap[n],heap[parent];n=parent
    end
end
local function pop(heap,f)
    local top=heap[1];local last=heap[#heap];heap[#heap]=nil
    if #heap>0 then
        heap[1]=last
        local n,size=1,#heap
        while true do
            local l,r,m=2*n,2*n+1,n
            if l<=size and f[heap[l]]<f[heap[m]] then m=l end
            if r<=size and f[heap[r]]<f[heap[m]] then m=r end
            if m==n then break end
            heap[m],heap[n]=heap[n],heap[m];n=m
        end
    end
    return top
end
-- LooteerV3 reconstruct_path: keep only turning points (angle > 20 degrees).
local function simplify(path)
    if #path<=2 then return path end
    local out={path[1]}
    for i=2,#path-1 do
        local a,b,c=path[i-1],path[i],path[i+1]
        local x1,y1,x2,y2=b.x-a.x,b.y-a.y,c.x-b.x,c.y-b.y
        local m=math.sqrt(x1*x1+y1*y1)*math.sqrt(x2*x2+y2*y2)
        if m>0 then
            local cos=math.max(-1,math.min(1,(x1*x2+y1*y2)/m))
            if math.acos(cos)>ANGLE then out[#out+1]=b end
        end
    end
    out[#out+1]=path[#path]
    return out
end
-- A copy of a cached path (the mover advances past waypoints it reaches).
local function copy(path)
    local out={}
    for i=1,#path do out[i]={x=path[i].x,y=path[i].y,z=path[i].z} end
    return out
end
local function search(here,goal)
    local px,py,pz,g,f,parent,closed={},{},{},{},{},{},{}
    local heap,walk={},{}
    local function id_of(gx,gy) return (gx+OFF)*SPAN+(gy+OFF) end
    -- One host question per cell per plan (false: not walkable).
    local function cell(gx,gy,z)
        local id=id_of(gx,gy)
        local known=walk[id]
        if known==nil then
            known=host_point(here.x+gx*GRID,here.y+gy*GRID,z) or false
            walk[id]=known;M.stats.cells=M.stats.cells+1
        end
        return known or nil
    end
    local start=id_of(0,0)
    px[start],py[start],pz[start],g[start]=here.x,here.y,here.z,0
    f[start]=dist2(here,goal)
    push(heap,f,start)
    local expanded,found=0,nil
    while #heap>0 do
        local cur=pop(heap,f)
        if not closed[cur] then
            closed[cur]=true
            expanded=expanded+1
            local cp={x=px[cur],y=py[cur],z=pz[cur]}
            if dist2(cp,goal)<ARRIVE then found=cur;break end
            if expanded>=MAX_NODES then break end
            local gx=math.floor(cur/SPAN)-OFF
            local gy=cur-(gx+OFF)*SPAN-OFF
            for _,dir in ipairs(DIRS) do
                local nx,ny=gx+dir[1],gy+dir[2]
                local nid=id_of(nx,ny)
                if not closed[nid] then
                    local p=cell(nx,ny,pz[cur])
                    -- A diagonal step needs both orthogonal neighbours (no
                    -- cutting a wall corner the straight mover cannot pass).
                    if p and dir[1]~=0 and dir[2]~=0 and not (cell(nx,gy,pz[cur]) and cell(gx,ny,pz[cur])) then
                        p=nil
                    end
                    if p then
                        local step=(dir[1]~=0 and dir[2]~=0) and GRID*1.41421356 or GRID
                        local tentative=g[cur]+step
                        if g[nid]==nil or tentative<g[nid] then
                            g[nid],parent[nid]=tentative,cur
                            px[nid],py[nid],pz[nid]=p.x,p.y,p.z
                            f[nid]=tentative+dist2(p,goal)
                            push(heap,f,nid)
                        end
                    elseif not walk[nid] then closed[nid]=true end
                end
            end
        end
    end
    M.stats.nodes=M.stats.nodes+expanded
    if expanded>M.stats.max_nodes then M.stats.max_nodes=expanded end
    if not found then return nil end
    local path={}
    local n=found
    while n do table.insert(path,1,{x=px[n],y=py[n],z=pz[n]});n=parent[n] end
    path=simplify(path)
    table.remove(path,1) -- the start cell is where the player stands
    path[#path+1]={x=goal.x,y=goal.y,z=goal.z}
    return path
end
-- The cached path from the waypoint nearest `here` that the ray cast shows
-- reachable (at most one ray cast per waypoint); nil walks straight.
local function resume(path,here)
    local best,best_d=nil,math.huge
    for i=1,#path do
        local d=dist2(here,path[i])
        if d<best_d and not line_blocked(here,path[i]) then best,best_d=i,d end
    end
    if not best then return nil end
    local out={}
    for i=best,#path do out[#out+1]={x=path[i].x,y=path[i].y,z=path[i].z} end
    return out
end
function M.plan(here,goal)
    M.stats.plans=M.stats.plans+1
    local world=world_of()
    if world~=cache_world then cache,cache_count,cache_world={},0,world end
    if not line_blocked(here,goal) then M.stats.straight=M.stats.straight+1;return nil end
    local key=goal_key(goal)
    local known=cache[key]
    if known==false then M.stats.cached=M.stats.cached+1;return nil end
    if known and dist2(here,known.start)<=REUSE then M.stats.cached=M.stats.cached+1;return copy(known.path) end
    if known and known.plans>=PLAN_CAP then M.stats.resumed=M.stats.resumed+1;return resume(known.path,here) end
    local ok,path=pcall(search,here,goal)
    if not ok or type(path)~='table' then path=nil end
    if known==nil then
        if cache_count>=CACHE_MAX then cache,cache_count={},0 end
        cache_count=cache_count+1
    end
    if not path then
        M.stats.failed=M.stats.failed+1
        -- A goal that once had a path keeps it (resumed from here on).
        if known then known.plans=PLAN_CAP;return resume(known.path,here) end
        cache[key]=false
        return nil
    end
    cache[key]={start={x=here.x,y=here.y},path=path,plans=(known and known.plans or 0)+1}
    M.stats.found=M.stats.found+1
    return copy(path)
end
return M
