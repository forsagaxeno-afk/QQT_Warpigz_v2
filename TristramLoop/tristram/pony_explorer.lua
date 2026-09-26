-- Local terrain exploration using a validated parent graph.
-- This module selects points only. The activity owns movement, world checks,
-- combat, interactions and loot; graph exhaustion is not encounter completion.
local host = require("tristram.host")
local M = {
    STEP = 12, MIN_STEP = 1.5, ARRIVAL = 0.65, MAX_NODES = 8192,
    MAX_RADIUS = 640, MAX_ACTIVE_SECONDS = 1800, LEG_TIMEOUT = 12,
    PROBE_INTERVAL = 0.1, PROBES_PER_STEP = 8, STREAM_GRACE = 3, UNKNOWN_TIMEOUT = 15,
    MAX_APPROACH_DISTANCE = 100, MAX_PATH_POINTS = 128, MAX_PATH_SAMPLES = 256,
    MAX_LOCAL_POINTS = 512, LOCAL_PROBES_PER_STEP = 32,
    REVEAL_MIN_DISTANCE = 1.5,
}
local DIRECTIONS = { {1,0}, {0,1}, {-1,0}, {0,-1}, {1,1}, {-1,1}, {-1,-1}, {1,-1},
    {0.5,1}, {1,0.5}, {-0.5,1}, {-1,0.5}, {-0.5,-1}, {-1,-0.5}, {0.5,-1}, {1,-0.5} }
local function finite(n) return type(n) == "number" and n == n and math.abs(n) < 1e9 end
-- Identifiers are finite numbers, not bounded map coordinates.
local function finite_id(n) return type(n) == "number" and n == n and math.abs(n) < math.huge end
local function position(p)
    local x, y, z = host.method(p, "x"), host.method(p, "y"), host.method(p, "z")
    if not finite(x) or not finite(y) or not finite(z) then return nil end
    return vec3:new(x, y, z)
end
local function distance(a, b)
    local x, y, z = a:x()-b:x(), a:y()-b:y(), a:z()-b:z()
    return math.sqrt(x*x+y*y+z*z)
end
local function on_segment(point, from, destination)
    local dx,dy,dz=destination:x()-from:x(),destination:y()-from:y(),destination:z()-from:z()
    local length=dx*dx+dy*dy+dz*dz
    if length==0 then return distance(point,from)<=M.ARRIVAL end
    local t=((point:x()-from:x())*dx+(point:y()-from:y())*dy+(point:z()-from:z())*dz)/length
    t=math.max(0,math.min(1,t))
    return distance(point,vec3:new(from:x()+dx*t,from:y()+dy*t,from:z()+dz*t))<=M.ARRIVAL
end
local function clock(time)
    local c = { last = time, active = 0, paused = false }
    function c.tick(now)
        if not finite(now) or not finite(c.last) or now < c.last then return false end
        local delta = now - c.last
        -- No calls means no driven work. Large callback gaps are implicit pauses.
        if not c.paused and delta <= 1 then c.active = c.active + delta end
        c.last = now
        return true
    end
    function c.suspend(now)
        if not c.tick(now) then return false end
        c.paused = true
        return true
    end
    function c.resume(now)
        if not finite(now) or not finite(c.last) or now < c.last then return false end
        if c.paused then c.last, c.paused = now, false end
        return true
    end
    return c
end
local function terrain(point)
    local adjusted = position(host.try(utility.set_height_of_valid_position, point))
    if not adjusted or math.abs(adjusted:x()-point:x()) > 0.05 or math.abs(adjusted:y()-point:y()) > 0.05 then
        return nil, "terrain height unreadable"
    end
    return adjusted
end
local function standable(point)
    local walkable = host.try(utility.is_point_walkeable, point)
    if type(walkable) ~= "boolean" then return nil, "walkability unreadable" end
    if not walkable then return false, "terrain is not walkable" end
    local world = host.try(get_current_world)
    local scene = host.method(world, "get_scene_for_position", point)
    local world_id = host.method(world, "get_world_id")
    local scene_world = host.method(scene, "get_world_id")
    if not scene or not finite_id(world_id) or not finite_id(scene_world) then return nil, "scene membership unreadable" end
    if scene_world ~= world_id then return false, "scene belongs to another world" end
    return true
end
local function edge(from, destination, budget)
    local length = distance(from, destination)
    if length > M.MAX_APPROACH_DISTANCE then return false, "path segment exceeds validation limit" end
    local ray = host.try(utility.is_ray_cast_walkeable, from, destination, 0.5, 0.5)
    if type(ray) ~= "boolean" then return nil, "ray walkability unreadable" end
    if not ray then return false, "path crosses blocked terrain" end
    local samples = math.max(1, math.ceil(length / 0.5))
    if budget.used + samples > M.MAX_PATH_SAMPLES then return false, "path sample limit reached" end
    budget.used = budget.used + samples
    for i = 1, samples do
        local t = i / samples
        local p = vec3:new(from:x()+(destination:x()-from:x())*t,
            from:y()+(destination:y()-from:y())*t, from:z()+(destination:z()-from:z())*t)
        local floor, why = terrain(p)
        if not floor then return nil, why end
        if math.abs(floor:z()-p:z()) > 1.5 then return false, "path changes elevation without a ramp" end
        local ok, reason = standable(floor)
        if ok ~= true then return ok, reason end
    end
    return true
end
local function route(from, destination, stats)
    local direct, why = edge(from, destination, { used = 0 })
    if direct == true then return { destination } end
    if direct == nil then return nil, why, true end
    stats.path_queries = stats.path_queries + 1
    local raw = host.try(pathfinder.calculate_and_get_path_points, from, destination)
    if type(raw) ~= "table" then return nil, "path result unreadable", true end
    if #raw == 0 then return nil, "no path to approach point", false end
    if #raw > M.MAX_PATH_POINTS then return nil, "path point limit reached", true end
    local points, previous, budget = {}, from, { used = 0 }
    for _, value in ipairs(raw) do
        local p = position(value)
        if not p then return nil, "path contains unreadable position", true end
        if distance(previous, p) > 0.05 then
            local valid, reason = edge(previous, p, budget)
            if valid ~= true then return nil, reason, valid == nil or reason:find("limit",1,true) ~= nil end
            points[#points+1], previous = p, p
        end
    end
    if #points == 0 or distance(previous, destination) > M.ARRIVAL then return nil, "partial path does not reach the approach point", false end
    return points
end

-- A paced, cached route to standable terrain within reach of a possibly solid
-- actor. Arrival means positioning only; the caller verifies interaction/loot.
function M.approach(start, target, time, reach, opts)
    start, target = position(start), position(target)
    if not start or not target or not finite(time) or not finite(reach) or reach <= 0 then return nil, "approach input unreadable" end
    local grounded = type(opts)=="table" and opts.horizontal_reach==true
    local initial_distance = grounded and math.sqrt((start:x()-target:x())^2+(start:y()-target:y())^2) or distance(start,target)
    if initial_distance > M.MAX_APPROACH_DISTANCE then return nil, "approach exceeds loaded-route distance limit" end
    local reach_target = not grounded and target or nil
    local c = clock(time)
    local a = { reason = "planning approach", path_queries = 0, probes = 0 }
    local points, index, candidate, next_probe = nil, 1, 1, 0
    local best, progressed, planned_at, unknown = math.huge, 0, 0, false
    local pass, pass_started = 1, 0
    local candidates = { target }
    local dx, dy = start:x()-target:x(), start:y()-target:y()
    local d = math.sqrt(dx*dx+dy*dy)
    if d == 0 then dx, dy, d = 1, 0, 1 end
    for _, scale in ipairs({ 0.8, 0.4 }) do
        for i = 1, 8 do
            local direction = DIRECTIONS[i]
            local norm = math.sqrt(direction[1]^2+direction[2]^2)
            local x, y = direction[1]/norm, direction[2]/norm
            candidates[#candidates+1] = vec3:new(target:x()+reach*scale*(dx*x-dy*y)/d,
                target:y()+reach*scale*(dy*x+dx*y)/d, target:z())
        end
    end
    local function blocked(why) a.reason, a.terminal = why, "blocked"; return "blocked", why end
    function a.suspend(now) return c.suspend(now) end
    function a.resume(now)
        local paused = c.paused
        if not c.resume(now) then return false end
        if paused then
            points, candidate, next_probe, planned_at, unknown = nil, 1, c.active, c.active, false
            pass, pass_started = 1, c.active
            if grounded then reach_target=nil end
        end
        return true
    end
    function a.status()
        return { reason = a.reason, waypoint = points and index or 0, waypoints = points and #points or 0,
            probes = a.probes, path_queries = a.path_queries, active_seconds = c.active, suspended = c.paused }
    end
    function a.step(current, now)
        if a.terminal then return a.terminal, a.reason end
        if not c.tick(now) then return blocked("approach clock is invalid") end
        if c.paused then return "waiting", "approach suspended" end
        current = position(current)
        if not current then return blocked("approach player position unreadable") end
        if c.active >= 180 then return blocked("approach active-time limit reached") end
        if not reach_target then
            if c.active<next_probe then return "waiting","waiting for target ground height" end
            next_probe=c.active+M.PROBE_INTERVAL
            reach_target=terrain(target)
            if not reach_target then
                if c.active-planned_at>=M.UNKNOWN_TIMEOUT then return blocked("approach target ground remained unreadable") end
                return "waiting","waiting for target ground height"
            end
            if distance(current,reach_target)>M.MAX_APPROACH_DISTANCE then return blocked("grounded approach exceeds loaded-route distance limit") end
            next_probe=c.active
        end
        if not points then
            if c.active < next_probe then return "waiting", a.reason end
            next_probe = c.active + M.PROBE_INTERVAL
            if distance(current, reach_target) <= reach then
                local valid, why = standable(current)
                if valid == true then a.reason, a.terminal = "approach reached", "done"; return "done", a.reason end
                if valid == nil then unknown = true; a.reason = why end
            end
            if candidate > #candidates then
                if c.active-pass_started < M.STREAM_GRACE then return "waiting", "waiting for approach geometry to stream" end
                if c.active-planned_at >= M.UNKNOWN_TIMEOUT or (pass >= 2 and not unknown) then
                    return blocked(unknown and "approach geometry remained unreadable" or "no validated approach route")
                end
                candidate, pass, pass_started, unknown = 1, pass+1, c.active, false
                return "waiting", "rechecking approach after terrain streaming"
            end
            a.probes = a.probes + 1
            local goal, why = terrain(candidates[candidate]); candidate = candidate + 1
            if goal and distance(goal,reach_target) <= reach then
                local valid, reason = standable(goal)
                if valid == true then
                    local pending, problem, uncertain = route(current, goal, a)
                    if pending then points, index, best, progressed = pending, 1, math.huge, c.active
                    else a.reason, unknown = problem, unknown or uncertain end
                else a.reason, unknown = reason, unknown or valid == nil end
            elseif not goal then a.reason, unknown = why, true end
            if not points then return "waiting", a.reason end
        end
        local waypoint = points[index]
        local remaining = distance(current, waypoint)
        if remaining <= M.ARRIVAL then
            index, best, progressed = index + 1, math.huge, c.active
            if index > #points then
                if distance(current,reach_target) > reach then return blocked("approach ended outside interaction reach") end
                a.reason, a.terminal = "approach reached", "done"
                return "done", a.reason
            end
            waypoint, remaining = points[index], distance(current, points[index])
        end
        if remaining < best-0.1 then best, progressed = remaining, c.active end
        if c.active-progressed >= M.LEG_TIMEOUT then return blocked("approach made no observed progress") end
        a.reason = "following validated approach"
        return "move", waypoint
    end
    return a
end

local function follow_known(points, time)
    local c=clock(time)
    local a={reason="validating known return edge",path_queries=0}
    local index,validated,best,progressed,unknown_at,next_probe=1,false,math.huge,0,nil,0
    local function blocked(why) a.terminal,a.reason="blocked",why;return "blocked",why end
    function a.suspend(now) return c.suspend(now) end
    function a.resume(now)
        local paused=c.paused
        if not c.resume(now) then return false end
        if paused then validated=false;unknown_at=nil;next_probe=c.active end
        return true
    end
    function a.status() return {path_queries=0,active_seconds=c.active,suspended=c.paused,reason=a.reason} end
    function a.step(current,now)
        if a.terminal then return a.terminal,a.reason end
        if not c.tick(now) then return blocked("known edge clock is invalid") end
        if c.paused then return "waiting","known return edge suspended" end
        current=position(current);if not current then return blocked("known return position unreadable") end
        local target=points[index]
        if distance(current,target)<=M.ARRIVAL then
            index,validated,best,progressed=index+1,false,math.huge,c.active
            if index>#points then a.terminal,a.reason="done","known return edge reached";return "done",a.reason end
            target=points[index]
        end
        if not validated then
            if c.active<next_probe then return "waiting",a.reason end
            next_probe=c.active+M.PROBE_INTERVAL
            local valid,why=edge(current,target,{used=0})
            if valid~=true then
                unknown_at=unknown_at or c.active;a.reason=why
                if c.active-unknown_at >= (valid==nil and M.UNKNOWN_TIMEOUT or M.STREAM_GRACE) then return blocked(why) end
                return "waiting","waiting for known return geometry to stream"
            end
            validated,unknown_at,progressed=true,nil,c.active
        end
        local remaining=distance(current,target)
        if remaining<best-0.1 then best,progressed=remaining,c.active end
        if c.active-progressed>=M.LEG_TIMEOUT then return blocked("known return edge made no observed progress") end
        a.reason="following validated known return edge"
        return "move",target
    end
    return a
end

function M.new(start, time)
    start = position(start)
    local c = clock(time)
    local e = { nodes = {}, visited = {}, current = 1, probes = 0, path_queries = 0,
        reveal_arrivals = 0, farthest = 0, reason = "starting exploration" }
    local leg, scan_after = nil, 0
    local scales = M.STEP > 3 and { M.STEP, M.STEP } or { M.STEP, M.MIN_STEP }
    local direction_count = M.STEP > 3 and #DIRECTIONS or 8
    local regions, coverage = {}, {}
    local function key(gx, gy, p) return gx .. ":" .. gy .. ":" .. math.floor(p:z()/M.MIN_STEP+0.5) end
    local function terminal(kind, reason) e.terminal, e.reason, leg = kind, reason, nil; return kind, reason end
    local function region(gx, gy) return math.floor(gx*M.MIN_STEP/M.STEP), math.floor(gy*M.MIN_STEP/M.STEP) end
    local function node_at(point, gx, gy, parent)
        local rx, ry = region(gx,gy)
        local tile = rx .. ":" .. ry .. ":" .. math.floor(point:z()/M.STEP+0.5)
        regions[tile] = regions[tile] or c.active
        local bucket = rx .. ":" .. ry
        coverage[bucket] = coverage[bucket] or {}
        coverage[bucket][#coverage[bucket]+1] = point
        return { position = point, gx = gx, gy = gy, parent = parent, index = 1, scale = 1,
            observed_at = regions[tile], round = 1, failed = {}, unknown = false, reveal = {}, reveal_keys = {} }
    end
    local function advance(node)
        node.index, node.scale, node.direction_unknown = node.index + 1, 1, false
    end
    local function coarse_axis(value, direction)
        local grid = M.STEP / M.MIN_STEP
        if direction > 0 then return (math.floor(value/grid)+1)*grid end
        if direction < 0 then return (math.ceil(value/grid)-1)*grid end
        return math.floor(value/grid+0.5)*grid
    end
    local function reveal_prefix(node, current, target)
        -- A failed full ray may be an unloaded cell beyond reachable ground.
        -- Walking that known prefix changes the observation position; a nearby
        -- point being geometrically sampled is not evidence it revealed terrain.
        local span=math.max(math.abs(target:x()-current:x()),math.abs(target:y()-current:y()))
        local steps=math.ceil(span/M.MIN_STEP)
        if steps<2 or steps>32 then return end
        local previous,points=current,{}
        for i=1,steps do
            local t=i/steps
            local candidate=terrain(vec3:new(current:x()+(target:x()-current:x())*t,
                current:y()+(target:y()-current:y())*t,previous:z()))
            if not candidate or edge(previous,candidate,{used=0})~=true then break end
            points[#points+1],previous=candidate,candidate
        end
        if #points==0 or distance(current,previous)<M.REVEAL_MIN_DISTANCE then return end
        local gx,gy=(previous:x()-start:x())/M.MIN_STEP,(previous:y()-start:y())/M.MIN_STEP
        local cell=key(gx,gy,previous)
        if e.visited[cell] or node.reveal_keys[cell] then return end
        node.reveal_keys[cell]=true
        node.reveal[#node.reveal+1]={position=previous,gx=gx,gy=gy,points=points}
    end
    local function already_sampled(point, gx, gy, ignored, radius)
        if M.STEP <= 3 then return false end
        local rx, ry = region(gx,gy)
        local examined = 0
        for x = rx-1, rx+1 do
            for y = ry-1, ry+1 do
                for _, observed in ipairs(coverage[x .. ":" .. y] or {}) do
                    if observed~=ignored and distance(point,observed) <= (radius or M.STEP*0.8) then
                        examined = examined + 1
                        if edge(observed,point,{used=0}) == true then return true end
                        if examined >= 4 then return false end
                    end
                end
            end
        end
        return false
    end
    local function local_frontier(node)
        local search = node.local_search
        if not search then
            search = { head = 1, queue = { {position=node.position,gx=node.gx,gy=node.gy,index=1} },
                seen = { [key(node.gx,node.gy,node.position)] = true } }
            node.local_search = search
        end
        for _ = 1, M.LOCAL_PROBES_PER_STEP do
            local row = search.queue[search.head]
            if not row then return "done" end
            if row.index > 4 then search.head = search.head + 1
            else
                local dir = DIRECTIONS[row.index]
                local gx,gy = row.gx+dir[1],row.gy+dir[2]
                local raw = vec3:new(start:x()+gx*M.MIN_STEP,start:y()+gy*M.MIN_STEP,row.position:z())
                if distance(raw,node.position) > M.STEP then row.index = row.index + 1
                else
                    local candidate,why = terrain(raw)
                    e.probes = e.probes + 1
                    local valid,cell
                    if candidate then
                        cell = key(gx,gy,candidate)
                        if search.seen[cell] then valid = false
                        else valid,why = edge(row.position,candidate,{used=0}) end
                    end
                    if valid == nil then
                        search.unknown_at = search.unknown_at or c.active
                        if c.active-search.unknown_at >= M.UNKNOWN_TIMEOUT then return "blocked", "local frontier geometry remained unreadable" end
                        return "waiting", why
                    end
                    search.unknown_at = nil
                    row.index = row.index + 1
                    if cell and valid then search.seen[cell] = true end
                    if valid then
                        if #search.queue >= M.MAX_LOCAL_POINTS then return "blocked", "local frontier search limit reached" end
                        if distance(start,candidate) > M.MAX_RADIUS then return "blocked", "exploration radius limit reached" end
                        local pending = {position=candidate,gx=gx,gy=gy,index=1,parent=search.head}
                        search.queue[#search.queue+1] = pending
                        if not already_sampled(candidate,gx,gy) then
                            local reverse, cursor = {}, pending
                            while cursor.parent do reverse[#reverse+1]=cursor.position;cursor=search.queue[cursor.parent] end
                            local points={};for i=#reverse,1,-1 do points[#points+1]=reverse[i] end
                            return "frontier", pending, points
                        end
                    end
                end
            end
        end
        return "waiting", "checking narrow passages near explored terrain"
    end
    if not start or not finite(time) then terminal("blocked", "exploration start is unreadable")
    else
        e.nodes[1] = node_at(start, 0, 0)
        e.visited[key(0,0,start)] = 1
    end
    function e.suspend(now)
        if leg and leg.driver then leg.driver.suspend(now) end
        return c.suspend(now)
    end
    function e.resume(now)
        local paused = c.paused
        if not c.resume(now) then return false end
        -- A pending frontier is neither visited nor consumed by a detour. Keep
        -- each arrived node's scan cursor; do not re-scan its completed children.
        if paused then
            if leg then leg.resumed = true end
            scan_after = c.active
        end
        return true
    end
    function e.status()
        local node=e.nodes[e.current]
        return { nodes = #e.nodes, edges = math.max(0,#e.nodes-1), probes = e.probes,
            path_queries = e.path_queries, current = e.current, leg = leg and leg.kind or "none",
            reveal_arrivals = e.reveal_arrivals, farthest = e.farthest,
            pending_frontiers = node and #node.reveal or 0,
            active_seconds = c.active, suspended = c.paused, reason = e.reason, terminal = e.terminal }
    end
    local function begin(point, kind, destination, gx, gy, current, points, revealing)
        leg = { point = point, kind = kind, destination = destination, gx = gx, gy = gy,
            best = math.huge, progressed = c.active, last_position = current, points = points, index = 1,
            expected = points and points[1] or point, revealing = revealing }
        e.reason = revealing and "approaching reachable edge to reveal more terrain"
            or kind == "frontier" and "exploring reachable terrain" or "backtracking explored terrain"
        return "move", points and points[1] or point
    end
    function e.step(current, now)
        if e.terminal then return e.terminal, e.reason end
        if not c.tick(now) then return terminal("blocked", "exploration clock is invalid") end
        if c.paused then return "waiting", "exploration suspended" end
        current = position(current)
        if not current then return terminal("blocked", "exploration player position unreadable") end
        e.farthest=math.max(e.farthest,distance(start,current))
        if c.active >= M.MAX_ACTIVE_SECONDS then return terminal("blocked", "exploration active-time limit reached") end
        if leg and leg.resumed then
            if leg.driver then leg.driver.resume(now);leg.resumed=nil
            elseif not on_segment(current,leg.last_position,leg.expected) and distance(current,leg.point) > M.ARRIVAL then
                leg = nil -- a displaced detour must rejoin; a stationary loot pause preserves its leg
            else
                if c.active<(leg.revalidate_after or 0) then return "waiting",e.reason end
                leg.revalidate_after=c.active+M.PROBE_INTERVAL
                local previous,budget,available,why=current,{used=0},true,nil
                local pending=leg.points or {leg.point}
                for i=leg.index,#pending do
                    available,why=edge(previous,pending[i],budget)
                    if available~=true then break end
                    previous=pending[i]
                end
                if available~=true then
                    leg.revalidate_at=leg.revalidate_at or c.active
                    if c.active-leg.revalidate_at>=M.UNKNOWN_TIMEOUT then
                        return terminal("blocked","resumed exploration route remained unavailable: "..tostring(why))
                    end
                    e.reason="waiting to revalidate resumed exploration route"
                    return "waiting",e.reason
                end
                leg.resumed,leg.revalidate_at,leg.revalidate_after=nil,nil,nil
                leg.best,leg.progressed=math.huge,c.active
            end
        end
        if leg then
            if leg.driver then
                local action, value = leg.driver.step(current, now)
                if action == "blocked" then return terminal("blocked", "cannot rejoin explored terrain: " .. value) end
                if action ~= "done" then e.reason = "rejoining explored terrain"; return action, value end
                if distance(current,e.nodes[e.current].position) > M.ARRIVAL then return terminal("blocked", "rejoin did not reach the explored node") end
                e.path_queries = e.path_queries + leg.driver.status().path_queries
                leg, scan_after = nil, c.active
                return "waiting", "explored route rejoined"
            end
            leg.last_position = current
            local waypoint = leg.points and leg.points[leg.index] or leg.point
            local remaining = distance(current,waypoint)
            if remaining <= M.ARRIVAL and leg.points and leg.index < #leg.points then
                leg.index, leg.best, leg.progressed = leg.index + 1, math.huge, c.active
                waypoint, remaining = leg.points[leg.index], distance(current,leg.points[leg.index])
            end
            if remaining <= M.ARRIVAL and distance(current,leg.point) <= M.ARRIVAL then
                if leg.kind == "frontier" then
                    local node = node_at(leg.point, leg.gx, leg.gy, e.current)
                    if leg.points then
                        node.return_path = {}
                        for i = #leg.points-1, 1, -1 do node.return_path[#node.return_path+1] = leg.points[i] end
                        node.return_path[#node.return_path+1] = e.nodes[e.current].position
                    end
                    advance(e.nodes[e.current])
                    e.nodes[#e.nodes+1] = node
                    e.current = #e.nodes
                    e.visited[key(node.gx,node.gy,node.position)] = e.current
                    if leg.revealing then
                        e.reveal_arrivals=e.reveal_arrivals+1
                        for _, prior in ipairs(e.nodes) do
                            if prior~=node and distance(prior.position,node.position)<=M.STEP*2 then prior.refresh=c.active end
                        end
                    end
                else e.current = leg.destination end
                leg, scan_after = nil, c.active; e.reason = "exploration waypoint reached"
                return "waiting", e.reason
            end
            if remaining < leg.best-0.1 then leg.best, leg.progressed = remaining, c.active end
            if c.active-leg.progressed >= M.LEG_TIMEOUT then return terminal("blocked", "exploration made no observed progress") end
            leg.expected = waypoint
            return "move", waypoint
        end
        local node = e.nodes[e.current]
        if distance(current,node.position) > M.ARRIVAL then
            local driver, why = e.return_to(current,node.position,now)
            if not driver then return terminal("blocked", "cannot rejoin explored terrain: " .. why) end
            leg = { kind = "rejoin", driver = driver }
            e.reason = "rejoining explored terrain"
            return "waiting", e.reason
        end
        if node.refresh then
            local observed_at=node.refresh
            node.refresh,node.index,node.scale,node.round=nil,1,1,1
            node.failed,node.reveal,node.reveal_keys,node.local_search={},{},{},nil
            node.unknown,node.unknown_at,node.observed_at=false,nil,observed_at
        end
        if c.active < scan_after then return "waiting", e.reason end
        scan_after = c.active + M.PROBE_INTERVAL
        local queries_before = e.path_queries
        for _ = 1, M.PROBES_PER_STEP do
            if node.index > direction_count then break end
            if node.round > 1 and (not node.failed[node.index]
                or node.failed[node.index] >= node.observed_at + M.STREAM_GRACE) then advance(node)
            else
                local direction = DIRECTIONS[node.index]
                local stride = scales[node.scale] / M.MIN_STEP
                -- Coarse points share one lattice even after a narrow detour.
                -- Fine offsets must not seed another complete grid in open space.
                local gx, gy = node.gx+direction[1]*stride, node.gy+direction[2]*stride
                if node.scale == 1 and node.index <= 8 then
                    gx, gy = coarse_axis(node.gx,direction[1]), coarse_axis(node.gy,direction[2])
                end
                local raw=vec3:new(start:x()+gx*M.MIN_STEP,start:y()+gy*M.MIN_STEP,node.position:z())
                local candidate, why = terrain(raw)
                e.probes = e.probes + 1
                local valid, known = false, true
                if candidate then
                    if distance(start,candidate) > M.MAX_RADIUS then return terminal("blocked", "exploration radius limit reached") end
                    if e.visited[key(gx,gy,candidate)] or stride > 2 and already_sampled(candidate,gx,gy,node.position) then valid = true
                    else
                        valid, why = edge(current,candidate,{used=0})
                        local points
                        if valid == false and node.scale <= 2 and stride > 2 and standable(candidate) == true then
                            local uncertain
                            points, why, uncertain = route(current,candidate,e)
                            if points then valid = true elseif uncertain then valid = nil end
                        end
                        if valid == true then
                            if #e.nodes >= M.MAX_NODES then return terminal("blocked", "exploration node limit reached") end
                            return begin(candidate,"frontier",nil,gx,gy,current,points)
                        end
                        known = valid ~= nil
                    end
                else known = false end
                if valid~=true and node.scale==1 then reveal_prefix(node,current,candidate or raw) end
                if not known then
                    node.unknown, node.direction_unknown, node.failed[node.index] = true, true, -math.huge
                    e.reason = why
                end
                if valid == true then
                    if not node.direction_unknown then node.failed[node.index] = nil end
                    advance(node)
                elseif node.scale < #scales and node.index <= 8 then node.scale = node.scale + 1
                else
                    node.failed[node.index] = node.direction_unknown and -math.huge or c.active
                    advance(node)
                end
            end
            if e.path_queries > queries_before then break end -- at most one heavy path search per planning tick
        end
        if node.index <= direction_count then return "waiting", e.reason end
        while #node.reveal>0 do
            local frontier=node.reveal[1]
            if e.visited[key(frontier.gx,frontier.gy,frontier.position)]
                or already_sampled(frontier.position,frontier.gx,frontier.gy,node.position,M.STEP+M.ARRIVAL) then table.remove(node.reveal,1)
            else
                if #e.nodes>=M.MAX_NODES then return terminal("blocked","exploration node limit reached") end
                local previous,budget,available=current,{used=0},true
                for _,point in ipairs(frontier.points) do
                    if edge(previous,point,budget)~=true then available=false;break end
                    previous=point
                end
                if not available then
                    frontier.unavailable_at=frontier.unavailable_at or c.active
                    if c.active-frontier.unavailable_at>=M.UNKNOWN_TIMEOUT then
                        return terminal("blocked","reachable frontier path remained unavailable")
                    end
                    e.reason="waiting to revalidate reachable frontier geometry"
                    return "waiting",e.reason
                end
                frontier.unavailable_at=nil
                return begin(frontier.position,"frontier",nil,frontier.gx,frontier.gy,current,frontier.points,true)
            end
        end
        if node.unknown then
            if not node.unknown_at then node.unknown_at = c.active end
            if c.active-node.unknown_at >= M.UNKNOWN_TIMEOUT then return terminal("blocked", "exploration geometry remained unreadable") end
            node.index, node.scale, node.round, node.unknown = 1, 1, node.round+1, false
            e.reason = "waiting for readable exploration geometry"
            return "waiting", e.reason
        end
        node.unknown_at = nil
        if node.round == 1 then
            if c.active-node.observed_at < M.STREAM_GRACE then e.reason = "waiting for terrain streaming"; return "waiting", e.reason end
            -- Retry only blocked directions after the streaming grace, once.
            -- Scans and children already completed stay cached on every return.
            node.index, node.scale, node.round = 1, 1, 2
            return "waiting", "rechecking blocked exploration directions"
        end
        if M.STEP > 3 and next(node.failed) ~= nil then
            local action, value, points = local_frontier(node)
            if action == "blocked" then return terminal("blocked",value) end
            if action == "waiting" then e.reason = value;return action,value end
            if action == "frontier" then
                if #e.nodes >= M.MAX_NODES then return terminal("blocked", "exploration node limit reached") end
                return begin(value.position,"frontier",nil,value.gx,value.gy,current,points)
            end
        end
        if not node.parent then
            if #e.nodes < 2 then return terminal("blocked", "no reachable frontier was observed from the starting point") end
            return terminal("done", "reachable sampled terrain exhausted")
        end
        local parent = e.nodes[node.parent]
        local previous, budget = current, {used=0}
        for _, point in ipairs(node.return_path or {parent.position}) do
            local valid, why = edge(previous,point,budget)
            if valid ~= true then return terminal("blocked", "known return edge unavailable: " .. tostring(why)) end
            previous = point
        end
        return begin(parent.position,"backtrack",node.parent,nil,nil,current,node.return_path)
    end
    -- Reconnect to actual arrived nodes, then validate short graph hops as their
    -- terrain streams. No route query targets an unloaded far-away destination.
    function e.return_to(current, goal, now, reach, opts)
        current, goal = position(current), position(goal)
        reach=reach or M.ARRIVAL
        if not current or not goal or not finite(now) or not finite(reach) or reach<=0 or #e.nodes == 0 then return nil,"return input unreadable" end
        local horizontal=type(opts)=="table" and opts.horizontal_reach==true
        local entries, goal_node, goal_distance = {}, nil, math.huge
        for i, node in ipairs(e.nodes) do
            local from=distance(current,node.position)
            local to=horizontal and math.sqrt((goal:x()-node.position:x())^2+(goal:y()-node.position:y())^2)
                or distance(goal,node.position)
            if from <= M.MAX_APPROACH_DISTANCE then entries[#entries+1] = {id=i,distance=from} end
            if to < goal_distance then goal_node, goal_distance = i, to end
        end
        if #entries == 0 or goal_distance > M.MAX_APPROACH_DISTANCE then return nil,"no observed graph node is within loaded-route reach" end
        table.sort(entries,function(a,b) return a.distance < b.distance end)
        local r, timer = {reason="connecting to explored terrain",path_queries=0}, clock(now)
        local entry, driver, sequence, cursor, stage = 1, nil, nil, 1, "connect"
        local function fail(why) r.reason,r.terminal=why,"blocked";return "blocked",why end
        local function graph_path(first, last)
            local ancestors, chain, seen = {}, {}, {}
            local node = first
            while node do
                if seen[node] or not e.nodes[node] then return nil end
                seen[node],ancestors[node] = true,true;chain[#chain+1]=node;node=e.nodes[node].parent
            end
            local tail={};node=last;seen={}
            while not ancestors[node] do
                if not node or seen[node] or not e.nodes[node] then return nil end
                seen[node]=true;tail[#tail+1]=node;node=e.nodes[node].parent
            end
            local path={}
            for i=2,#chain do path[#path+1]=chain[i];if chain[i]==node then break end end
            if first==node then path={} end
            for i=#tail,1,-1 do path[#path+1]=tail[i] end
            return path
        end
        function r.suspend(t)
            if driver then driver.suspend(t) end
            return timer.suspend(t)
        end
        function r.resume(t)
            local paused=timer.paused
            if not timer.resume(t) then return false end
            if paused and driver then driver.resume(t) end
            return true
        end
        function r.status()
            return {reason=r.reason,path_queries=r.path_queries+(driver and driver.status().path_queries or 0),
                active_seconds=timer.active,suspended=timer.paused,stage=stage,remaining=sequence and #sequence-cursor+1 or 0}
        end
        function r.step(at,t)
            if r.terminal then return r.terminal,r.reason end
            if not timer.tick(t) then return fail("return clock is invalid") end
            if timer.paused then return "waiting","return suspended" end
            if timer.active>=M.MAX_ACTIVE_SECONDS then return fail("graph return active-time limit reached") end
            at=position(at);if not at then return fail("return position unreadable") end
            if not driver then
                local destination
                if stage=="connect" then destination=e.nodes[entries[entry].id].position
                elseif stage=="graph" then
                    if cursor>#sequence then stage="goal";destination=goal
                    else
                        local previous=cursor==1 and entries[entry].id or sequence[cursor-1]
                        local next_id=sequence[cursor]
                        local prior,after=e.nodes[previous],e.nodes[next_id]
                        local points
                        if prior.parent==next_id then points=prior.return_path or {after.position}
                        elseif after.parent==previous then
                            points={}
                            if after.return_path then
                                for i=#after.return_path-1,1,-1 do points[#points+1]=after.return_path[i] end
                            end
                            points[#points+1]=after.position
                        else return fail("return nodes are not connected by an observed parent edge") end
                        driver=follow_known(points,t)
                    end
                else destination=goal end
                if not driver then
                    local final=stage=="goal"
                    local why;driver,why=M.approach(at,destination,t,final and reach or M.ARRIVAL,final and opts or nil)
                    if not driver then return fail("cannot validate graph return: "..why) end
                end
            end
            local action,value=driver.step(at,t)
            if action=="blocked" then
                r.path_queries=r.path_queries+driver.status().path_queries;driver=nil
                if stage=="connect" and entry<math.min(8,#entries) then entry=entry+1;return "waiting","trying another observed return node" end
                return fail("graph return blocked: "..value)
            end
            if action~="done" then r.reason="returning through validated explored terrain";return action,value end
            r.path_queries=r.path_queries+driver.status().path_queries;driver=nil
            if stage=="connect" then
                sequence=graph_path(entries[entry].id,goal_node)
                if not sequence then return fail("observed return graph is invalid") end
                stage,cursor="graph",1
            elseif stage=="graph" then cursor=cursor+1
            else r.reason,r.terminal="saved position reached","done";return "done",r.reason end
            return "waiting","observed return waypoint reached"
        end
        return r
    end
    return e
end
return M
