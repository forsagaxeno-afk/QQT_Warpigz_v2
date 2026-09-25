-- Drive the recorded corridor one observed waypoint at a time, in either direction.
local records = require("tristram.routes")
local host = require("tristram.host")
local M = {}
local ARRIVAL = 0.8
local STUCK_SECONDS = 12
local function point(p) return vec3:new(p.x, p.y, p.z) end
local function nearest(position)
    local best, distance = nil, math.huge
    for index, p in ipairs(records.record3) do
        local d = host.distance(position, point(p))
        if d < distance then best, distance = index, d end
    end
    return best, distance
end
function M.new(position, destination, time, join_range)
    if host.distance(position, destination) <= ARRIVAL then
        return { index = 1, points = {}, done = true, tick = function() return "done" end }
    end
    local first, from_distance = nearest(position)
    local last, to_distance = nearest(destination)
    -- A start/restart inside the encounter may be displaced by combat or evade.
    -- Connect to the nearest recorded waypoint, then retain the recorded order.
    local can_join = type(join_range) == "number" and host.distance(position, destination) <= join_range
    if not first or (from_distance > 6 and not can_join) or to_distance > 12 then
        return nil, "Outside the recorded corridor; move onto the recorded path before restarting."
    end
    local points = {}
    local direction = first <= last and 1 or -1
    for index = first, last, direction do points[#points + 1] = point(records.record3[index]) end
    if host.distance(points[#points], destination) > ARRIVAL then points[#points + 1] = destination end
    local n = { index = 1, points = points, done = false, best = math.huge, progress_at = time, started_at = time }
    function n.tick(current, now)
        if n.done then return "done" end
        local target = n.points[n.index]
        local distance = host.distance(current, target)
        if distance <= ARRIVAL then
            n.index = n.index + 1
            n.best, n.progress_at, n.started_at = math.huge, now, now
            if n.index > #n.points then n.done = true; return "done" end
            target = n.points[n.index]
            distance = host.distance(current, target)
        end
        if distance < n.best - 0.15 then n.best, n.progress_at = distance, now end
        if now - n.progress_at >= STUCK_SECONDS or now - n.started_at >= 45 then
            return "blocked", "Recorded path blocked at waypoint " .. n.index .. "; stopped without skipping it."
        end
        return "move", target
    end
    return n
end
return M
