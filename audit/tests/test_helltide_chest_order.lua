-- QQT_Warpigz_v3: Farm-mode smart chest order (core/hr_chest_order.lua):
-- class order (Mystery seen > Mystery predicted > regular seen > regular
-- predicted), road cost, hysteresis and the 3-per-minute switch limit, the
-- chest reset (stale regular chests dropped, Mystery first again), fence and
-- bad-cell rejection, and the task integration: Farm picks through the
-- smart order, Warplan keeps the legacy nearest-affordable selection.
-- Runs under Lua 5.4 and LuaJIT.
local H = dofile(assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/audit/tests/hr_smart_harness.lua')
local R = H.runner('Helltide chest order')
local ok, eq = R.ok, R.eq
local v, actor = H.v, H.actor

local MYSTERY, GLOVES, RING = 'usz_rewardGizmo_Uber', 'usz_rewardGizmo_Gloves', 'usz_rewardGizmo_Rings'

local function session(opts)
    local s = H.new(opts)
    s.set('mode', 1) -- Farm
    s.order = s.require('core.hr_chest_order')
    s.atlas = s.require('core.hr_atlas')
    s.fence = s.require('core.hr_fence')
    s.roads = s.require('core.hr_roads')
    s.targets = s.require('core.chest_targets')
    s.tracker.hr_fence = s.fence
    s.atlas.set_zone('Step_South')
    s.remembered = {}
    s.blacklist = {}
    function s.pick(actors, current)
        return s.order.pick({actors = actors or {}, remembered = s.remembered, key_of = s.targets.key,
            blacklisted = function(key) return s.blacklist[key] == true end,
            player = s.pos, cinders = s.cinders, current = current, now = s.now})
    end
    return s
end

-- A learned spot seen in two earlier slots (predicted in a later slot).
local function learn(s, name, pos)
    s.at_minute(1); s.atlas.observe(name, s.require('data.enums').chest_types[name], pos, true)
    s.at_minute(16); s.atlas.observe(name, s.require('data.enums').chest_types[name], pos, true)
    s.at_minute(21)
end

R.case('Mystery before regular, seen before predicted, nearest first', function()
    local s = session({cinders = 600})
    local near_glove = actor(GLOVES, 20, 0)
    local mystery = actor(MYSTERY, 45, 0)
    local pick = s.pick({near_glove, mystery})
    eq(pick.name, MYSTERY, 'Mystery first'); eq(pick.class, 0); eq(pick.kind, 'visible')
    learn(s, MYSTERY, v(30, 30))
    s.order.on_reset()
    pick = s.pick({near_glove, mystery})
    eq(pick.kind, 'visible', 'a seen Mystery before a learned (predicted) one')
    pick = s.pick({near_glove})
    eq(pick.kind, 'remembered', 'out of sight: the Mystery seen before is remembered (known before predicted)')
    eq(pick.class, 0)
    s.remembered = {}
    pick = s.pick({near_glove})
    eq(pick.kind, 'predicted', 'no Mystery known: the learned Mystery spot')
    eq(pick.class, 1); eq(pick.predicted, true)
    s.order.on_reset()
    local g2 = actor(RING, 35, 0)
    pick = s.pick({g2, near_glove}, nil)
    s.atlas.forget()
    s.order.on_reset()
    pick = s.pick({g2, near_glove})
    eq(pick.actor, near_glove, 'nearest regular')
end)

R.case('an allowed chest right next to the player is taken on the way', function()
    local s = session({cinders = 600})
    local here = actor(GLOVES, 8, 0)
    local mystery = actor(MYSTERY, 45, 0)
    local pick = s.pick({here, mystery})
    eq(pick.actor, here); eq(pick.opportunistic, true)
    s.cinders = 300                                   -- 300 - 75 < 250: the reserve decides
    s.order.on_reset()
    pick = s.pick({here, mystery})
    eq(pick.name, MYSTERY, 'not when it would break the Mystery reserve')
end)

-- Hairpin loop: leg y=0 from x=-600 to 600, leg y=60 back; 4 m steps.
local function hairpin()
    local wps = {}
    for x = -600, 600, 4 do wps[#wps + 1] = v(x, 0) end
    for y = 4, 56, 4 do wps[#wps + 1] = v(600, y) end
    for x = 600, -600, -4 do wps[#wps + 1] = v(x, 60) end
    for y = 56, 4, -4 do wps[#wps + 1] = v(-600, y) end
    return wps
end

-- QQT_Warpigz_v3 (night review): with an income rate the plan let a regular
-- chest on the way take the cinders of a Mystery the bot could already afford.
R.case('250 in hand and a Mystery target: a regular chest on the way is not taken', function()
    local s = session({cinders = 260})
    s.require('core.hr_stats').rate_min = function() return 10 end
    s.at_minute(20)
    local mystery = actor(MYSTERY, 45, 0)
    local glove = actor(GLOVES, 10, 0)
    local first = s.pick({mystery})
    eq(first.name, MYSTERY)
    local p = s.pick({mystery, glove}, first.key)
    eq(p.name, MYSTERY, 'the Mystery stays the target')
    ok(not p.opportunistic, 'no opportunistic detour')
    s.cinders = 240                                   -- the Mystery is not affordable yet
    s.order.on_reset()
    p = s.pick({mystery, glove})
    eq(p and p.name, GLOVES, 'below 250 the income rule still allows it')
end)

R.case('nearest by road, not by the straight line', function()
    local s = session({cinders = 600})
    s.tracker.waypoints = hairpin()
    s.tracker.waypoints_zone = 'Step_South'
    s.pos = v(0, 0)
    local across = actor(GLOVES, -150, 75)            -- 168 m straight, ~1100 m by road
    local along = actor(RING, 250, -10)               -- 250 m straight, ~260 m by road
    local pick = s.pick({across, along})
    eq(pick.actor, along, 'the road decides')
    ok(pick.route ~= nil and pick.route.dir == 1, 'with a road route east')
    ok(pick.cost_est < 300, 'road cost ' .. pick.cost_est)
end)

R.case('equal road cost: the forward loop direction wins the tie', function()
    local s = session({cinders = 600})
    local n, radius = 314, 200
    local wps = {}
    for i = 1, n do
        local a = 2 * math.pi * (i - 1) / n
        wps[i] = v(radius * math.cos(a), radius * math.sin(a))
    end
    s.tracker.waypoints, s.tracker.waypoints_zone = wps, 'Step_South'
    local function out(i, d)
        local a = 2 * math.pi * (i - 1) / n
        return (radius + d) * math.cos(a), (radius + d) * math.sin(a)
    end
    s.pos = wps[1]
    local ax, ay = out(60, 20)                        -- ahead: ~236 m road
    local bx, by = out(n - 57, 20)                    -- behind: ~232 m road (4 m shorter)
    local ahead, behind = actor(GLOVES, ax, ay), actor(RING, bx, by)
    local pick = s.pick({ahead, behind})
    eq(pick.actor, ahead, 'within 5 m: the forward direction')
    eq(pick.route.dir, 1)
    s.order.on_reset()
    local cx, cy = out(n - 40, 20)                    -- behind, clearly shorter
    local near_behind = actor(RING, cx, cy)
    pick = s.pick({ahead, near_behind})
    eq(pick.actor, near_behind, 'a clearly shorter way still wins')
end)

R.case('hysteresis: similar candidates never switch; at most 3 switches a minute', function()
    local s = session({cinders = 600})
    local a = actor(GLOVES, 60, 0)
    local b = actor(RING, -58, 0)
    local first = s.pick({a, b})
    eq(first.actor, b, 'nearest first')
    s.pos = v(3, 0)                                   -- now a is 57 m, b 61 m: similar
    local again = s.pick({a, b}, first.key)
    eq(again.key, first.key, 'kept: not less than half the remaining cost')
    -- The player runs back and forth: each time the other chest is 20 m
    -- away and the current one 100 m (a big gain, but more than 15 m: not
    -- an "on the way" pick). Switches 1..3 happen, the 4th inside a minute not.
    local current, switches = first.key, 0
    for i, spot in ipairs({40, -40, 40, -40}) do
        s.advance(5)
        s.pos = v(spot, 0)
        local p = s.pick({a, b}, current)
        if p.key ~= current then switches = switches + 1; current = p.key end
        if i <= 3 then eq(p.actor, spot > 0 and a or b, 'switch ' .. i) end
    end
    eq(switches, 3, 'the 4th switch within 60 s is refused')
    s.advance(61)
    local p = s.pick({a, b}, current)
    ok(p.key ~= current, 'allowed again after a minute')
end)

R.case('chest reset: stale regular chests dropped, Mystery first again (one log line)', function()
    local s = session({cinders = 400})
    learn(s, MYSTERY, v(80, 0))
    learn(s, MYSTERY, v(-90, 20))
    s.at_minute(21)
    s.atlas.observe(MYSTERY, 250, v(80, 0), false)      -- seen spent this slot
    s.atlas.mark_opened(v(-90, 20), MYSTERY)            -- opened by us this hour
    local stale = actor(GLOVES, 60, 30)
    local key = s.targets.key(GLOVES, stale.pos)
    s.remembered[key] = {name = GLOVES, cost = 75, position = stale.pos, discovered_at = s.now, seen_at = s.now}
    local pick = s.pick({})
    eq(pick.key, key, 'the remembered regular chest (no Mystery spot open this slot)')
    s.at_minute(30, 1); s.advance(1)                  -- the :30 reset
    pick = s.pick({})
    s.advance(3)
    pick = s.pick({})
    eq(s.remembered[key], nil, 'not seen since the reset: dropped')
    eq(pick.name, MYSTERY, 'a Mystery spot is a candidate again')
    eq(pick.class, 1)
    ok(math.abs(pick.position:x() - 80) < 1, 'the spot seen spent before the reset')
    eq(s.logged('[CHEST ORDER] Chest reset at :30'), 1)
    -- The spot we opened ourselves stays gone this hour (a respawn within the
    -- hour is unconfirmed) until it was once seen closed again.
    local count = 0
    for _, spot in ipairs(s.atlas.predicted()) do if spot.x < 0 then count = count + 1 end end
    eq(count, 0, 'opened this hour: not predicted after the reset')
    s.at_minute(40, 30); s.atlas.mark_opened(v(80, 0), MYSTERY)
    s.advance(40); s.atlas.observe(MYSTERY, 250, v(80, 0), true)   -- closed again
    s.at_minute(46)
    count = 0
    for _, spot in ipairs(s.atlas.predicted()) do if spot.x > 0 then count = count + 1 end end
    eq(count, 1, 'a spot seen respawning is predicted after the next reset')
    s.epoch = s.epoch + 3600
    count = 0
    for _, spot in ipairs(s.atlas.predicted()) do if spot.x < 0 then count = count + 1 end end
    eq(count, 1, 'the next hour: every Mystery spot again')
end)

R.case('a task reset reports no chest reset; unaffordable regular chests are not planned', function()
    local s = session({cinders = 100})
    s.atlas.reset_seen_at = s.now - 50                -- a spot reset seen earlier
    s.pick({actor(GLOVES, 20, 0)})
    eq(s.logged('Chest reset'), 0, 'not a crossing')
    s.advance(3); s.pick({actor(GLOVES, 20, 0)})
    local notes = s.logged('Chest reset')
    s.order.on_reset()
    s.advance(3); s.pick({actor(GLOVES, 20, 0)}); s.advance(3); s.pick({actor(GLOVES, 20, 0)})
    eq(s.logged('Chest reset'), notes, 'no false note after the task reset')
    local planned = 0
    local cost = s.roads.cost
    s.roads.cost = function(...) planned = planned + 1; return cost(...) end
    s.cinders = 50
    eq(s.pick({actor('usz_rewardGizmo_1H', 400, 0), actor(GLOVES, 300, 0)}), nil)
    eq(planned, 0, 'no road planning for chests that cannot be afforded')
    s.pick({actor(MYSTERY, 300, 0)})
    eq(planned, 1, 'a Mystery is still costed (reserve rule)')
    s.roads.cost = cost
end)

R.case('fenced-out and bad-cell targets are skipped; blacklisted ones too', function()
    local s = session({cinders = 600})
    local out = actor(GLOVES, 40, 0)
    local fine = actor(RING, -45, 0)
    for _ = 1, 3 do s.fence.tick(s.now, true, v(0, 0)); s.advance(2.1) end
    s.fence.on_left(v(40, 0)); s.fence.on_left(v(41, 1))
    local pick = s.pick({out, fine})
    eq(pick.actor, fine, 'the fenced-out chest is skipped')
    local bad = actor(GLOVES, -10, 5)
    for _ = 1, 3 do s.roads.record_bad(bad.pos) end
    s.order.on_reset()
    pick = s.pick({bad, fine})
    eq(pick.actor, fine, 'a target where the bot got stuck 3 times is skipped')
    s.blacklist[s.targets.key(RING, fine.pos)] = true
    s.order.on_reset()
    eq(s.pick({bad, fine}), nil, 'blacklisted')
end)

R.case('3D distance: a chest on a ledge is not "on the way"; beyond 150 m in 3D needs a road', function()
    local s = session({cinders = 600})
    local ledge = actor(GLOVES, 10, 0); ledge.pos = v(10, 0, 20)   -- 10 m flat, 22 m in 3D
    local ground = actor(RING, 14, 0)
    local pick = s.pick({ledge, ground})
    eq(pick.actor, ground, 'the chest on the ground is the one on the way')
    eq(pick.opportunistic, true)
    s.order.on_reset(); s.remembered = {}
    ok(math.abs(s.pick({ledge}).distance - math.sqrt(500)) < 1e-6, 'measured in 3D')
    s.order.on_reset(); s.remembered = {}
    local far = actor(GLOVES, 140, 0); far.pos = v(140, 0, 60)     -- 152 m in 3D, no patrol loop
    eq(s.pick({far}), nil, 'out of recall reach without a road')
    s.order.on_reset(); s.remembered = {}
    local flat = actor(GLOVES, 140, 0)
    ok(s.pick({flat}) ~= nil, '140 m on flat ground: in reach')
end)

R.case('Warplan and "Smart chest order" off: disabled (the legacy selection runs)', function()
    local s = session()
    eq(s.order.enabled(), true)
    s.set('mode', 0); eq(s.order.enabled(), false, 'Warplan')
    s.set('mode', 1); s.require('core.hr_mode').set_external(true)
    eq(s.order.enabled(), false, 'WarPigs (external enable)')
    s.require('core.hr_mode').set_external(false)
    s.set('smart_order', false); eq(s.order.enabled(), false, 'option off')
end)

-- The real Helltide task with the smart order.
local function task_session(mode)
    local bm = {sets = {}}
    local s = session({cinders = 400, zone = 'Test_Zone', batmobile = {
        pause = function() end, resume = function() end, update = function() end, move = function() end,
        set_target = function(_, t) bm.sets[#bm.sets + 1] = t; return true end,
        clear_target = function() end, stop_long_path = function() end, is_paused = function() return false end,
        is_done = function() return false end, reset = function() end, reset_movement = function() end,
        get_target = function() return nil end, navigate_long_path = function() return true end,
        is_long_path_navigating = function() return false end}})
    s.set('mode', mode)
    s.bm = bm
    s.tracker.hr_chest_order, s.tracker.hr_atlas = s.order, s.atlas
    s.tracker.hr_stats = s.require('core.hr_stats')
    s.task = s.require('tasks.helltide')
    s.atlas.set_zone('Test_Zone')
    return s
end

R.case('task: Farm commits the smart pick, Warplan keeps nearest-affordable', function()
    local farm = task_session(1)
    local glove, mystery = actor(GLOVES, 20, 0), actor(MYSTERY, 40, 0)
    farm.actors = {glove, mystery}
    farm.task:initiate_waypoints(); farm.task:explore_helltide()
    eq(farm.task.current_state, 'MOVING_TO_HELLTIDE_CHEST')
    eq(farm.task:move_to_helltide_chest(), nil)
    ok(farm.logged('Detected usz_rewardGizmo_Uber') == 1, 'the Mystery was chosen')
    local warplan = task_session(0)
    warplan.actors = {actor(GLOVES, 20, 0), actor(MYSTERY, 40, 0)}
    warplan.task:initiate_waypoints(); warplan.task:explore_helltide()
    eq(warplan.task.current_state, 'MOVING_TO_HELLTIDE_CHEST')
    eq(warplan.logged('Detected usz_rewardGizmo_Gloves'), 1, 'Warplan: the nearest affordable chest')
    eq(warplan.logged('smart order'), 0)
end)

R.case('task: saving for a Mystery skips the plain selection; a learned spot is routed to', function()
    local s = task_session(1)
    s.cinders = 260
    learn(s, MYSTERY, v(120, 0))
    s.set('dump_min', 0)
    s.actors = {actor(GLOVES, 20, 0)}
    s.cinders = 260
    s.task:initiate_waypoints(); s.task:explore_helltide()
    eq(s.task.current_state, 'MOVING_TO_REMEMBERED_CHEST', 'the learned Mystery spot')
    eq(s.logged('(learned spot)'), 1)
    s.cinders = 200 -- the Mystery is out of reach now: the plan keeps the reserve
    s.task:reset()
    s.task:initiate_waypoints(); s.advance(1.1); s.task:explore_helltide()
    eq(s.task.current_state, 'EXPLORE_HELLTIDE', 'no chest: saving 250 for the Mystery')
    eq(#s.interactions, 0)
end)

R.case('task: Farm event reach, the engaged event actor and a bounded stay; Warplan keeps 12 m', function()
    local s = task_session(1)
    s.set('hunt_rift_toggle', false)                  -- tears would replace legacy events
    s.at_minute(20)
    local pillar = actor('S04_Helltide_FlamePillar_Switch_Dyn', 30, 0)
    local spent_pyre = actor('S04_Helltide_Prop_SoulSyphon_01_Dyn', 5, 0, {interactable = false})
    s.actors = {pillar, spent_pyre}
    s.task:initiate_waypoints(); s.task:explore_helltide()
    eq(s.task.current_state, 'MOVING_TO_PYRE', 'the pillar 30 m away (Farm reach 40 m)')
    s.advance(1.1); s.task:move_to_pyre()
    eq(s.bm.sets[#s.bm.sets], pillar, 'walks to the engaged pillar, not the spent pyre next to it')
    s.pos = v(29.5, 0)
    s.advance(1.1); s.task:move_to_pyre()
    eq(s.task.current_state, 'INTERACT_PYRE')
    pillar.interactable = false                      -- the event runs
    s.task:interact_pyre()
    eq(s.task.current_state, 'STAY_NEAR_PYRE')
    s.advance(100); s.task:stay_near_pyre()
    eq(s.task.current_state, 'STAY_NEAR_PYRE', 'standing by the event')
    s.advance(150); s.task:stay_near_pyre()
    eq(s.task.current_state, 'EXPLORE_HELLTIDE', 'a pillar that never ends is left after 240 s')
    eq(s.logged('Event still running after 240s'), 1)
    local w = task_session(0)
    w.set('hunt_rift_toggle', false)
    w.at_minute(20)
    w.actors = {actor('S04_Helltide_FlamePillar_Switch_Dyn', 30, 0)}
    w.task:initiate_waypoints(); w.task:explore_helltide()
    eq(w.task.current_state, 'EXPLORE_HELLTIDE', 'Warplan: 12 m as before')
    w.actors = {actor('S04_Helltide_FlamePillar_Switch_Dyn', 10, 0)}
    w.advance(1.1); w.task:explore_helltide()
    eq(w.task.current_state, 'MOVING_TO_PYRE')
end)

-- QQT_Warpigz_v3 (night review): with default menu values (Hunt tears on,
-- "Prefer tears" on) the Farm events never ran.
R.case('task: Farm defaults walk to a flame pillar in the event radius; the skip option turns it off', function()
    local s = task_session(1)
    s.at_minute(20)
    s.actors = {actor('S04_Helltide_FlamePillar_Switch_Dyn', 30, 0)}
    s.task:initiate_waypoints(); s.task:explore_helltide()
    eq(s.task.current_state, 'MOVING_TO_PYRE', 'Farm defaults: the pillar 30 m away')
    local x = task_session(1)
    x.set('rupture_replace_local_events', true)
    x.at_minute(20)
    x.actors = {actor('S04_Helltide_FlamePillar_Switch_Dyn', 10, 0)}
    x.task:initiate_waypoints(); x.task:explore_helltide()
    eq(x.task.current_state, 'EXPLORE_HELLTIDE', '"Skip legacy Helltide events" ticked')
end)

R.case('task: an event not reached in 45 s is skipped for 180 s; a stuck interaction is bounded', function()
    local s = task_session(1)
    s.set('hunt_rift_toggle', false)
    s.at_minute(20)
    local pillar = actor('S04_Helltide_FlamePillar_Switch_Dyn', 30, 0)
    s.actors = {pillar}
    s.task:initiate_waypoints(); s.task:explore_helltide()
    eq(s.task.current_state, 'MOVING_TO_PYRE')
    s.advance(20); s.task:move_to_pyre()
    eq(s.task.current_state, 'MOVING_TO_PYRE', 'still walking after 20 s')
    s.advance(26); s.task:move_to_pyre()                -- never got closer (a wall)
    eq(s.task.current_state, 'EXPLORE_HELLTIDE', 'given up after 45 s')
    eq(s.logged('Event not reached in 45s'), 1)
    s.advance(1.1); s.task:explore_helltide()
    eq(s.task.current_state, 'EXPLORE_HELLTIDE', 'not engaged again at once')
    s.advance(100); s.task:explore_helltide()
    eq(s.task.current_state, 'EXPLORE_HELLTIDE', 'still skipped after 100 s')
    local other = actor('S04_Helltide_Prop_SoulSyphon_01_Dyn', -25, 0)
    s.actors = {pillar, other}
    s.advance(1.1); s.task:explore_helltide()
    eq(s.task.current_state, 'MOVING_TO_PYRE', 'another event is taken')
    s.advance(1.1); s.task:move_to_pyre()
    eq(s.bm.sets[#s.bm.sets], other, 'walking to the other one')
    s.task:hr_event_done(); s.task.current_state = 'EXPLORE_HELLTIDE'
    s.actors = {pillar}
    s.advance(80); s.task:explore_helltide()
    eq(s.task.current_state, 'MOVING_TO_PYRE', 'the skipped one again after 180 s')
    -- Reached, but the interaction never takes: bounded by the event limit.
    s.pos = v(29.5, 0)
    s.advance(1.1); s.task:move_to_pyre()
    eq(s.task.current_state, 'INTERACT_PYRE')
    local interactions = #s.interactions
    s.advance(100); s.task:interact_pyre()
    eq(s.task.current_state, 'INTERACT_PYRE', 'still trying after 100 s')
    ok(#s.interactions > interactions, 'interacting')
    s.advance(150); s.task:interact_pyre()
    eq(s.task.current_state, 'EXPLORE_HELLTIDE', 'given up after 240 s')
    eq(s.logged('Event still running after 240s'), 1)
end)

R.case('task: a stuck smart trip is blacklisted 60 s; after 3 its spot counts as bad', function()
    local s = task_session(1)
    s.tracker.hr_roads = s.roads
    s.cinders = 600
    local chest = actor(GLOVES, 55, 0)                  -- beyond the direct 50 m: a recall trip
    s.actors = {chest}
    s.task:initiate_waypoints()
    for trip = 1, 3 do
        s.advance(1.1); s.task:explore_helltide()
        eq(s.task.current_state, 'MOVING_TO_REMEMBERED_CHEST', 'trip ' .. trip)
        for _ = 1, 40 do
            s.advance(0.5); s.task:move_to_remembered_chest()
            if s.task.current_state ~= 'MOVING_TO_REMEMBERED_CHEST' then break end
        end
        eq(s.task.current_state, 'EXPLORE_HELLTIDE', 'no progress: trip ' .. trip .. ' given up')
        s.advance(1.1); s.task:explore_helltide()
        eq(s.task.current_state, 'EXPLORE_HELLTIDE', 'blacklisted: not picked again at once')
        ok(s.roads.is_bad(chest.pos) == (trip == 3), 'bad cell after trip ' .. trip)
        s.advance(60)
    end
    s.advance(1.1); s.task:explore_helltide()
    eq(s.task.current_state, 'EXPLORE_HELLTIDE', 'the blacklist is over, the bad cell keeps it out')
    eq(s.order.last_plan.allowed, 0)
end)

R.case('task: a learned regular spot takes the chest of another gear type found there', function()
    local s = task_session(1)
    learn(s, RING, v(120, 0))
    s.cinders = 300
    s.actors = {}
    s.task:initiate_waypoints(); s.task:explore_helltide()
    eq(s.task.current_state, 'MOVING_TO_REMEMBERED_CHEST', 'the learned Rings spot')
    local gloves = actor(GLOVES, 121, 1)             -- this rotation: Gloves at the spot
    s.actors = {gloves}
    s.pos = v(118, 0)
    for _ = 1, 4 do s.advance(0.5); s.task:move_to_remembered_chest() end
    eq(s.logged('No usz_rewardGizmo_Rings at the learned spot'), 0, 'not a miss')
    s.pos = v(120.5, 0.5)
    s.advance(0.5); s.task:move_to_remembered_chest()
    ok(#s.interactions == 1 and s.interactions[1] == gloves, 'the Gloves chest is opened')
    -- An empty learned spot: one miss after 2 s there.
    local t = task_session(1)
    learn(t, RING, v(120, 0))
    t.cinders = 300
    t.task:initiate_waypoints(); t.task:explore_helltide()
    t.pos = v(118, 0)
    t.advance(1.1); t.task:move_to_remembered_chest()
    eq(t.logged('at the learned spot'), 0, 'not at once')
    for _ = 1, 5 do t.advance(0.5); t.task:move_to_remembered_chest() end
    eq(t.logged('No usz_rewardGizmo_Rings at the learned spot'), 1, 'a miss')
    eq(t.task.current_state, 'EXPLORE_HELLTIDE')
    eq(t.atlas.spot_at(v(120, 0), RING).miss, 1)
end)

R.case('task: walking to a regular chest, a Mystery coming into sight takes over', function()
    local s = task_session(1)
    s.cinders = 600
    local far = actor(GLOVES, 90, 0)
    s.actors = {far}
    s.task:initiate_waypoints(); s.task:explore_helltide()
    eq(s.task.current_state, 'MOVING_TO_REMEMBERED_CHEST')
    s.advance(0.5); s.task:move_to_remembered_chest()
    s.actors = {far, actor(MYSTERY, -70, 0)}
    s.advance(2.5); s.task:move_to_remembered_chest()
    eq(s.logged('[CHEST ORDER] Switching to usz_rewardGizmo_Uber'), 1, 'switched to the Mystery')
    eq(s.task.current_state, 'MOVING_TO_REMEMBERED_CHEST')
    s.advance(2.5); s.task:move_to_remembered_chest()
    eq(s.logged('[CHEST ORDER] Switching'), 1, 'and stays with it')
end)

-- QQT_Warpigz_v3 (night review): one missed buff read cancelled a Mystery
-- trip, blacklisted it for 180 s and taught the fence an "out" spot inside
-- the Helltide; a real exit was never escalated (picked again every 181 s).
local function walk_mystery(s)
    s.at_minute(20)
    -- the learned Helltide area around the trip (buff samples)
    for i = 0, 5 do for _ = 1, 3 do s.fence.tick(s.now, true, v(i * 20, 0)); s.advance(2.1) end end
    local mystery = actor(MYSTERY, 90, 0)
    s.actors = {mystery}
    s.task:initiate_waypoints(); s.task:explore_helltide()
    eq(s.task.current_state, 'MOVING_TO_REMEMBERED_CHEST')
    for _ = 1, 4 do s.advance(0.5); s.pos = v(s.pos:x() + 3, 0); s.task:Execute() end
    return mystery
end

local function explore_again(s, dt)
    s.advance(dt)
    s.task._last_check_events_time = nil
    if #s.tracker.waypoints == 0 then s.task:initiate_waypoints() end
    s.task:explore_helltide()
end

R.case('task: a one-read Helltide buff flicker only interrupts the chest trip', function()
    local s = task_session(1)
    walk_mystery(s)
    s.in_helltide = false; s.advance(0.5); s.task:Execute()
    eq(s.task.current_state, 'RETURN_TO_HELLTIDE')
    s.in_helltide = true
    for _ = 1, 6 do s.advance(0.5); s.task:Execute() end
    eq(s.task.current_state, 'MOVING_TO_REMEMBERED_CHEST', 'the Mystery trip goes on')
    eq(s.logged('left the Helltide'), 0, 'no blacklist')
    eq(s.logged('buff flicker'), 1)
    eq(s.fence.stats().out, 0, 'no out count inside the Helltide')
end)

R.case('task: a trip that really leaves the Helltide is skipped 180 s, after 2 exits for the Helltide', function()
    local s = task_session(1)
    walk_mystery(s)
    for round = 1, 2 do
        s.in_helltide = false
        for _ = 1, 10 do s.advance(0.5); s.task:Execute() end       -- 5 s without the buff
        eq(s.task.current_state, 'RETURN_TO_HELLTIDE', 'round ' .. round)
        s.in_helltide = true; s.advance(0.5); s.task:Execute()
        eq(s.task.current_state, 'EXPLORE_HELLTIDE', 'back inside, round ' .. round)
        if round == 1 then
            eq(s.logged('skipping it for 180s'), 1)
            explore_again(s, 30)
            eq(s.task.current_state, 'EXPLORE_HELLTIDE', 'blacklisted for 180 s')
            explore_again(s, 151)
            eq(s.task.current_state, 'MOVING_TO_REMEMBERED_CHEST', 'tried again after 180 s')
        end
    end
    eq(s.logged('skipping it for the rest of this Helltide'), 1)
    eq(s.fence.stats().out, 1, 'confirmed exits are learned by the fence')
    explore_again(s, 181)
    eq(s.task.current_state, 'EXPLORE_HELLTIDE', 'not picked again this Helltide')
    s.task:reset(); explore_again(s, 1.1)
    eq(s.task.current_state, 'EXPLORE_HELLTIDE', 'a task reset does not bring it back')
    s.epoch = s.epoch + 3600; s.at_minute(5)
    explore_again(s, 1.1)
    eq(s.task.current_state, 'MOVING_TO_REMEMBERED_CHEST', 'the next Helltide may try it again')
end)

R.finish()
