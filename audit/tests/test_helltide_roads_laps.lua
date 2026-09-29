-- QQT_Warpigz_v3 2.6.4 (sweep 2026-09-28 H1, High): the road planner took
-- the ONE loop point nearest the player and the ONE nearest the chest. The
-- recorded patrol loops pass the same places several times, so those two
-- points were often on different laps and the arc between them ran a long
-- way round the loop: a chest 270 m away cost 2,179 m, a few metres of
-- movement moved the start to another lap, and the chest order flipped
-- between two chests (cinders unspent at :55). The plan now takes the
-- cheapest pair of one start point per lap near the player and one exit per
-- lap near the chest. Real jirandai loop, the spots and chests of sweep seed
-- 1; a synthetic figure-eight. Runs under Lua 5.4 and LuaJIT.
local root = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local H = dofile(root .. '/audit/tests/hr_smart_harness.lua')
local R = H.runner('Helltide roads (laps)')
local ok = R.ok
local v = H.v

local function session(wps)
    local s = H.new()
    local atlas = s.require('core.hr_atlas')
    local roads = s.require('core.hr_roads')
    atlas.set_zone('Step_South')
    s.tracker.waypoints = wps
    s.tracker.waypoints_zone = 'Step_South'
    return s, roads
end

-- The recorded jirandai loop (waypoints/jirandai.lua returns vec3 points).
local function jirandai()
    local env = setmetatable({vec3 = {new = function(_, x, y, z) return v(x, y, z) end}}, {__index = _G})
    return assert(loadfile(root .. '/HelltideRevamped/waypoints/jirandai.lua', 't', env))()
end

-- The shortest road route over every loop point within the road reach of
-- the player and the off-road reach of the chest (brute force).
local function best_road(roads, target, p)
    local L = roads.loop()
    local near_p, near_t = {}, {}
    for i = 1, L.n do
        local dp = math.sqrt((L.xs[i] - p:x()) ^ 2 + (L.ys[i] - p:y()) ^ 2)
        local dt = math.sqrt((L.xs[i] - target:x()) ^ 2 + (L.ys[i] - target:y()) ^ 2)
        if dp <= roads.ROAD_MAX then near_p[#near_p + 1] = {i, dp} end
        if dt <= roads.OFFROAD_MAX then near_t[#near_t + 1] = {i, dt} end
    end
    local best = math.huge
    for _, a in ipairs(near_p) do
        for _, b in ipairs(near_t) do
            local f = roads.arc(a[1], b[1], 1)
            best = math.min(best, a[2] + math.min(f, L.total - f) + b[2])
        end
    end
    return best
end

R.case('jirandai: the road cost is close to the shortest road route and steady over 15 m steps (seed 1)', function()
    local s, roads = session(jirandai())
    local A, B = v(-523.0, -609.3, 0), v(-740.3, -594.0, 0)
    local P = {v(-310.6, -601.5, 0), v(-304.5, -615.2, 0), v(-298.7, -602.0, 0), v(-304.1, -615.3, 0)}
    local rows, ratio, jump, prev = {}, 0, 0, nil
    for i, p in ipairs(P) do
        s.pos = p
        local ca = roads.cost(A, p)
        local cb = roads.cost(B, p)
        local ba, bb = best_road(roads, A, p), best_road(roads, B, p)
        rows[#rows + 1] = string.format('P%d: A %.0f m (best %.0f), B %.0f m (best %.0f)', i, ca, ba, cb, bb)
        ratio = math.max(ratio, ca / ba, cb / bb)
        ok(ca < cb, string.format('P%d: chest A (%.0f m) is cheaper than B (%.0f m)', i, ca, cb))
        if prev then
            local moved = p:dist_to(P[i - 1])
            jump = math.max(jump, math.abs(ca - prev.a) - moved, math.abs(cb - prev.b) - moved)
        end
        prev = {a = ca, b = cb}
    end
    local detail = '\n    ' .. table.concat(rows, '\n    ')
    ok(ratio <= 1.5, string.format('road cost up to %.1fx the shortest road route%s', ratio, detail))
    ok(jump <= 100, string.format('a 15 m step changed a road cost by %.0f m more than the step%s', jump, detail))
end)

R.case('jirandai: the planned route really walks the chosen arc (start and exit near player and chest)', function()
    local s, roads = session(jirandai())
    local A, p = v(-523.0, -609.3, 0), v(-304.5, -615.2, 0)
    local route = roads.plan(A, p)
    ok(route ~= nil, 'a route')
    local L = roads.loop()
    local ds = math.sqrt((L.xs[route.i0] - p:x()) ^ 2 + (L.ys[route.i0] - p:y()) ^ 2)
    ok(ds <= roads.ROAD_MAX, 'the start is within the road reach: ' .. ds)
    ok(route.offroad <= roads.OFFROAD_MAX, 'the exit is within the off-road reach')
    ok(math.abs(route.cost - (ds + route.road + route.offroad)) < 1, 'cost = to the road + arc + off-road')
    ok(math.abs(route.road - roads.arc(route.i0, route.i1, route.dir)) < 1, 'the arc in the planned direction')
end)

-- A figure-eight: two 200 m circles touching at the origin, walked as one
-- loop. At the crossing the nearest point is on either lobe; a chest just
-- inside the far lobe is reached across the crossing, not round the lobe.
local function figure_eight()
    local wps, n = {}, 314
    for i = 1, n do -- right lobe, starting at the crossing
        local a = math.pi + 2 * math.pi * (i - 1) / n
        wps[#wps + 1] = v(200 + 200 * math.cos(a), 200 * math.sin(a), 0)
    end
    for i = 1, n do -- left lobe, starting at the crossing, the other way round
        local a = -2 * math.pi * (i - 1) / n
        wps[#wps + 1] = v(-200 + 200 * math.cos(a), 200 * math.sin(a), 0)
    end
    return wps
end

R.case('figure-eight: at the crossing a chest on the other lobe is reached across it', function()
    local s, roads = session(figure_eight())
    -- The player just after the start of the right lobe (nearest: its first
    -- points), the chest just after the start of the left lobe (nearest: its
    -- first points): a whole lobe apart along the loop, but the end of the
    -- right lobe runs into the start of the left one right there.
    local p = v(3, -8, 0)
    local chest = v(-12, -30, 0)
    s.pos = p
    local cost = roads.cost(chest, p)
    local best = best_road(roads, chest, p)
    ok(cost <= best * 1.5, string.format('road cost %.0f m vs the shortest road route %.0f m', cost, best))
    ok(cost < 200, string.format('across the crossing (%.0f m), not round a lobe', cost))
end)

R.finish()
