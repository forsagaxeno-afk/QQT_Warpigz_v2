-- QQT_Warpigz_v3: routes along the patrol loop (core/hr_roads.lua): the
-- shorter way round, wrap-around, the off-road hand-off, backtracking to
-- the road with alternative exits (at most 3, then the caller blacklists),
-- learned exits, bad cells with decay, the no-progress watchdog, and no loop.
-- Runs under Lua 5.4 and LuaJIT.
local H = dofile(assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/audit/tests/hr_smart_harness.lua')
local R = H.runner('Helltide roads')
local ok, eq = R.ok, R.eq
local v = H.v

-- A circular patrol loop: radius 200 m around (0, 0), 314 points ~4 m apart.
local N, RADIUS = 314, 200
local function circle()
    local wps = {}
    for i = 1, N do
        local a = 2 * math.pi * (i - 1) / N
        wps[i] = v(RADIUS * math.cos(a), RADIUS * math.sin(a), 0)
    end
    return wps
end
-- A point `out` metres outside the loop at the angle of loop index i.
local function outside(i, out)
    local a = 2 * math.pi * (i - 1) / N
    return v((RADIUS + out) * math.cos(a), (RADIUS + out) * math.sin(a), 0)
end

local function session()
    local s = H.new()
    local atlas = s.require('core.hr_atlas')
    local fence = s.require('core.hr_fence')
    local roads = s.require('core.hr_roads')
    s.tracker.hr_fence = fence
    atlas.set_zone('Step_South')
    s.tracker.waypoints = circle()
    s.tracker.waypoints_zone = 'Step_South'
    return s, roads, atlas
end

-- Walk the route: jump to every goal until the hand-off; returns cursors seen.
local function walk(s, roads, route, limit)
    local seen = {}
    for _ = 1, limit or 500 do
        s.advance(1)
        local goal = roads.next_goal(route, s.pos, s.now)
        if goal == nil then return seen end
        seen[#seen + 1] = route.cursor
        s.pos = v(goal:x(), goal:y(), 0)
    end
    error('route never handed off')
end

R.case('the shorter way round the loop', function()
    local s, roads = session()
    s.pos = s.tracker.waypoints[1]
    local fwd = roads.plan(outside(60, 20), s.pos)
    eq(fwd.i0, 1); eq(fwd.dir, 1, 'forward is shorter')
    ok(math.abs(fwd.road - 59 * 2 * math.pi * RADIUS / N) < 5, 'road metres ' .. fwd.road)
    ok(math.abs(fwd.offroad - 20) < 1)
    local back = roads.plan(outside(260, 20), s.pos)
    eq(back.dir, -1, 'backward is shorter')
    ok(back.road < 250, 'the short way: ' .. back.road)
    local cost, route = roads.cost(outside(60, 20), s.pos)
    ok(route ~= nil and math.abs(cost - (fwd.road + fwd.offroad)) < 1, 'cost = road + off-road')
end)

R.case('wrap-around from the end of the loop to its start, then the off-road hand-off', function()
    local s, roads = session()
    s.pos = s.tracker.waypoints[300]
    local target = outside(20, 25)
    local route = roads.plan(target, s.pos)
    eq(route.dir, 1, 'through the end of the list')
    local seen = walk(s, roads, route)
    local high, low = false, false
    for _, c in ipairs(seen) do
        if c > 300 then high = true end
        if c < 20 then low = true end
    end
    ok(high and low, 'the cursor wrapped from index 314 to 1')
    eq(route.mode, 'offroad', 'handed off near the exit')
    ok(s.pos:dist_to(s.tracker.waypoints[route.i1]) <= roads.HANDOFF + 1, 'at the exit')
    eq(roads.next_goal(route, s.pos, s.now), nil, 'off-road: the caller walks to the target')
end)

R.case('stuck off the road: back to the road, another exit >= 30 m along, at most 3 exits', function()
    local s, roads = session()
    s.pos = s.tracker.waypoints[1]
    local target = outside(80, 30)
    local route = roads.plan(target, s.pos)
    walk(s, roads, route)
    local first_exit = route.i1
    s.pos = v(target:x() - 5, target:y() - 5, 0)               -- stuck close to the chest
    eq(roads.stuck_offroad(route, s.pos), true, 'backtrack')
    eq(route.mode, 'backtrack')
    eq(route.back_idx, first_exit, 'back to the road point it left from')
    local alt = route.next_exit
    local spacing = math.min(roads.arc(first_exit, alt, 1), roads.arc(first_exit, alt, -1))
    ok(spacing >= roads.EXIT_SPACING, 'the new exit is ' .. spacing .. ' m along the loop')
    local goal = roads.next_goal(route, s.pos, s.now)
    eq(goal, s.tracker.waypoints[first_exit], 'first walks back to the road')
    s.pos = s.tracker.waypoints[first_exit]
    walk(s, roads, route)
    eq(route.mode, 'offroad'); eq(route.i1, alt, 'then leaves the road at the new exit')
    s.pos = v(target:x() + 3, target:y(), 0)
    eq(roads.stuck_offroad(route, s.pos), true, 'a third exit')
    local third = route.next_exit
    for _, used in ipairs({first_exit, alt}) do
        ok(math.min(roads.arc(used, third, 1), roads.arc(used, third, -1)) >= roads.EXIT_SPACING, 'spaced from every tried exit')
    end
    s.pos = s.tracker.waypoints[route.back_idx]
    walk(s, roads, route)
    eq(roads.stuck_offroad(route, s.pos), false, 'three exits tried: the caller blacklists')
    eq(roads.is_bad(s.pos), false, 'one bad sample is not a bad cell yet')
end)

R.case('the exit of a successful trip is learned and used next time', function()
    local s, roads, atlas = session()
    local target = outside(120, 20)
    atlas.observe('usz_rewardGizmo_Gloves', 75, target, true)
    s.pos = s.tracker.waypoints[1]
    local route = roads.plan(target, s.pos)
    walk(s, roads, route)
    route.i1 = route.i1 + 3                                     -- say the 2nd exit worked
    ok(roads.on_success(route, target, 'usz_rewardGizmo_Gloves'), 'stored')
    local spot = atlas.spot_at(target, 'usz_rewardGizmo_Gloves')
    eq(spot.exit_idx, route.i1)
    s.pos = s.tracker.waypoints[1]
    local again = roads.plan(target, s.pos, spot.exit_idx)
    eq(again.i1, spot.exit_idx, 'the learned exit')
    local bogus = roads.plan(target, s.pos, 1)                  -- 1 is far from the target
    ok(bogus.i1 ~= 1, 'an exit far from the target is ignored')
end)

R.case('no loop (Nahantu / Skovos), another zone\'s loop, option off: no road route', function()
    local s, roads = session()
    s.tracker.waypoints_zone = 'Scos_Coast'
    s.pos = s.tracker.waypoints[1]
    eq(roads.plan(outside(60, 20), s.pos), nil, 'the loop of another zone')
    s.tracker.waypoints_zone = 'Step_South'
    s.set('road_routing', false)
    eq(roads.plan(outside(60, 20), s.pos), nil, 'option off')
    s.set('road_routing', true)
    s.tracker.waypoints = {}
    eq(roads.plan(outside(60, 20), s.pos), nil, 'no loop')
    local cost, route = roads.cost(v(100, 0), v(0, 0))
    eq(route, nil); eq(cost, 100, 'straight distance')
    s.tracker.waypoints = circle()
    s.pos = v(0, 0)                                             -- 200 m from the loop
    eq(roads.plan(outside(60, 20), s.pos), nil, 'the player is too far from the road')
    s.pos = s.tracker.waypoints[1]
    eq(roads.plan(v(0, 0), s.pos), nil, 'the target is too far from the road (200 m)')
end)

R.case('no progress on the road for 20 s drops the route', function()
    local s, roads = session()
    s.pos = s.tracker.waypoints[1]
    local route = roads.plan(outside(150, 20), s.pos)
    ok(roads.next_goal(route, s.pos, s.now) ~= nil)
    s.advance(15); roads.credit(route, 10)                      -- 10 s of it was a Looter yield
    ok(roads.next_goal(route, s.pos, s.now) ~= nil, 'credited yield')
    s.advance(16)
    eq(roads.next_goal(route, s.pos, s.now), nil)
    ok(route.failed ~= nil, 'failed: ' .. tostring(route.failed))
end)

R.case('the loop going away mid-trip fails the route (not a hand-off)', function()
    local s, roads = session()
    s.pos = s.tracker.waypoints[1]
    local route = roads.plan(outside(120, 20), s.pos)
    ok(roads.next_goal(route, s.pos, s.now) ~= nil)
    s.tracker.waypoints = {}
    eq(roads.next_goal(route, s.pos, s.now), nil)
    eq(route.failed, 'patrol loop unavailable')
    eq(route.mode, 'road', 'never reported as the off-road hand-off')
end)

R.case('bad cells: 3 hits mark a target cell bad; one count less per Helltide without a hit', function()
    local s, roads = session()
    for _ = 1, 3 do roads.record_bad(v(41, 41)) end
    eq(roads.is_bad(v(42, 42)), true, 'same 4 m cell')
    eq(roads.is_bad(v(50, 50)), false)
    roads.tick(nil)
    s.epoch = s.epoch + 3600
    roads.tick(nil)                                                -- the Helltide of the hits ended
    eq(roads.is_bad(v(42, 42)), true, 'hit in the Helltide that ended: kept')
    s.epoch = s.epoch + 3600
    roads.tick(nil)                                                -- a Helltide without a hit
    eq(roads.is_bad(v(42, 42)), false, 'decayed to 2')
    roads.record_bad(v(41, 41))
    eq(roads.is_bad(v(42, 42)), true, 'hit again')
    s.set('learn', false)
    roads.record_bad(v(100, 100)); roads.record_bad(v(100, 100)); roads.record_bad(v(100, 100))
    eq(roads.is_bad(v(100, 100)), false, 'learning off')
end)

R.case('a loop point whose way to the target crosses a learned out cell is not an exit', function()
    local s, roads = session()
    local fence = s.require('core.hr_fence')
    local target = outside(40, 40)
    s.pos = s.tracker.waypoints[1]
    local plain = roads.plan(target, s.pos)
    local mid = v((plain.tx + s.tracker.waypoints[plain.i1]:x()) / 2, (plain.ty + s.tracker.waypoints[plain.i1]:y()) / 2)
    for _ = 1, 3 do fence.tick(s.now, true, s.tracker.waypoints[1]); s.advance(2.1) end
    fence.on_left(mid); fence.on_left(mid)
    local route = roads.plan(target, s.pos)
    ok(route == nil or route.i1 ~= plain.i1, 'the fenced exit is avoided')
end)

-- QQT_Warpigz_v3 (night review): the decay only touched the zone the player
-- was in at the hour change (the town at :55 in standalone farming) and never
-- ran across reloads, so a bad cell stayed bad for good.
R.case('bad cells decay per elapsed Helltide in any zone and across a reload', function()
    local s, roads, atlas = session()
    for _ = 1, 3 do roads.record_bad(v(41, 41)) end
    eq(roads.is_bad(v(42, 42)), true)
    atlas.set_zone('Skov_Temis')                                   -- :55: teleported home
    for _ = 1, 4 do s.epoch = s.epoch + 3600; roads.tick(nil) end  -- boundaries pass in town
    atlas.set_zone('Step_South')
    eq(roads.is_bad(v(42, 42)), false, 'decayed although the hours passed in another zone')
    -- A new session reads the file: the next Helltide still skips the cell,
    -- a day later it is gone.
    for _ = 1, 3 do roads.record_bad(v(81, 81)) end
    ok(atlas.save_zone('Step_South'), 'saved')
    ok(s.file('learned/Step_South.txt'):find('\nbad|20|20|3|', 1, true), 'bad line written')
    -- The next Helltide after the hits still skips the cell.
    local s3 = H.new({files = s.files, epoch = s.epoch + 3600})
    local atlas3 = s3.require('core.hr_atlas')
    s3.tracker.hr_fence = s3.require('core.hr_fence')
    local roads3 = s3.require('core.hr_roads')
    atlas3.set_zone('Step_South')
    eq(roads3.is_bad(v(81, 81)), true, 'reloaded in the next Helltide: still bad')
    local s2 = H.new({files = s.files, epoch = s.epoch + 24 * 3600})
    local atlas2 = s2.require('core.hr_atlas')
    s2.tracker.hr_fence = s2.require('core.hr_fence')
    local roads2 = s2.require('core.hr_roads')
    atlas2.set_zone('Step_South')
    eq(roads2.is_bad(v(81, 81)), false, 'next day, new session: no longer bad')
    atlas2.save_zone('Step_South')
    eq(s2.file('learned/Step_South.txt'):find('\nbad|', 1, true), nil, 'the decayed cell is not written back')
end)

R.finish()
