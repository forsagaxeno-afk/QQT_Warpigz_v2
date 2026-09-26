-- Rosie 1.0.7 (2.3.0-rc.10): pickup mechanics like LooteerV3.
-- Rosie 1.0.6 gave a drop 5 interactions or 12 s of selection, then skipped
-- it until it left the ground: a drop that fell during a boss fight (player
-- busy, rotation moving) was lost. rc.10 retries in bounded rounds (REACH 2,
-- interact every 0.15 s, move every 0.35 s, 30 interactions or 6 s without
-- progress per round, 8 s rest, 3 rounds), switches the host Auto Loot off
-- while pickup runs, and walks around a wall with a bounded A* that runs only
-- for the pickup owner, only when the host ray cast says the straight line is
-- blocked, at most 1500 nodes, "no path" once per drop, re-planned from the
-- player's spot at most 4 times (review rc.10).
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local checks, failures = 0, {}
local function ok(value, message)
    if not value then error(message or 'expected a true value', 2) end
    checks = checks + 1
end
local function eq(actual, expected, message)
    if actual ~= expected then
        error((message or 'mismatch') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
    checks = checks + 1
end
local function case(name, fn)
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS pickup: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL pickup: ' .. name .. ': ' .. tostring(err)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function new(opts)
    opts = opts or {}
    opts.rosie, opts.dirs = true, {}
    local h = J.new(opts)
    h.assert_clean('load')
    h.pos = h.v(0, 0)
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(30)
    return h
end
local function busy(h) return h.as(CONSUMER, function() return h.G.LooteerPlugin.is_actively_looting() end) end
local function route_stats(h)
    local okr, route = pcall(function() return h.mod('Rosie', 'rosie.private.route') end)
    return okr and type(route) == 'table' and route.stats or nil
end
local HELM = {rarity = 6, ancestral = true, ga = 1, name = 'Helm_Unique_Generic_005', sno = 2647147,
    affixes = {{affix_name_hash = 2628989, get_name = function() return 'S14_Mythic_UniquePotency' end}}}
local function helm() local t = {}; for k, v in pairs(HELM) do t[k] = v end; return t end

case('E1 a drop in reach while the player is busy for 3 s is still picked up', function()
    local h = new({place = 'pit'})
    h.drop('pit', 1, 0, helm())
    local real = h.G.interact_object
    local busy_until = h.now + 3
    rawset(h.G, 'interact_object', function(a)
        h.tries = (h.tries or 0) + 1
        if h.now < busy_until then return true end
        return real(a)
    end)
    ok(h.run_until(function() return (h.pickups or 0) > 0 end, 20), 'picked up after the busy window\n' .. h.tail())
    local st = route_stats(h)
    ok(st ~= nil, 'the route module is loaded')
    eq(st.found + st.failed, 0, 'open ground: A* never runs (ray cast clear)')
    h.assert_clean('E1')
end)

case('E2 a drop during a 15 s fight (request_move ignored) is picked up after the fight', function()
    local h = new({place = 'pit'})
    h.drop('pit', 12, 0, helm())
    local real = h.G.pathfinder.request_move
    local fight_until = h.now + 15
    h.G.pathfinder.request_move = function(p)
        if h.now < fight_until then return false end
        return real(p)
    end
    ok(h.run_until(function() return (h.pickups or 0) > 0 end, 40), 'picked up after the fight\n' .. h.tail())
    h.assert_clean('E2')
end)

case('E4 (C6) a drop that never picks up is skipped after bounded rounds', function()
    local h = new({place = 'pit'})
    h.drop('pit', 1, 0, helm())
    rawset(h.G, 'interact_object', function() h.tries = (h.tries or 0) + 1; return true end)
    local busy_time = 0
    h.run(60, function() if busy(h) then busy_time = busy_time + 0.1 end end)
    local tries = h.tries
    h.run(20)
    eq(h.tries, tries, 'no interaction after the bound')
    ok(tries <= 3 * 30, 'at most 3 rounds of 30 interactions: ' .. tostring(tries))
    ok(busy_time < 30, 'busy only while a round runs: ' .. busy_time)
    eq(busy(h), false, 'not busy after the bound')
    ok(h.logged('pickup attempts exhausted (3 rounds)') > 0, 'the skip names the rounds\n' .. h.tail())
end)

case('E5 (C6) an unreachable drop (off the walkable area) is skipped after bounded rounds', function()
    local h = new({place = 'pit'})
    local b = h.place.box
    h.drop('pit', b[2] + 5, 0, helm())
    h.pos = h.v(b[2] - 10, 0)
    h.run(60)
    local s = h.as(CONSUMER, function() return h.G.RosiePlugin.status() end)
    eq(busy(h), false, 'not busy after the bound')
    eq(s.movement.owner, nil, 'pickup released movement')
end)

case('E6 a drop behind a wall is picked up by walking around it (bounded A*, planned once)', function()
    local h = new({place = 'pit'})
    h.place.walls = {{4, 5, -10, 10}}
    h.drop('pit', 10, 0, helm())
    local picked = h.run_until(function() return (h.pickups or 0) > 0 end, 40)
    local st = route_stats(h)
    h.place.walls = nil
    ok(picked, 'the drop behind the wall was picked up\n' .. h.tail())
    ok(st ~= nil and st.found == 1, 'one A* plan found a path: ' .. tostring(st and st.found))
    eq(st.failed, 0, 'no failed plan')
    ok(st.max_nodes <= 1500, 'at most 1500 nodes: ' .. tostring(st.max_nodes))
    ok((h.ray_casts or 0) > 0, 'the straight line was checked with the host ray cast')
end)

case('E6b a walled-in drop: A* runs at most once, then walks straight; bounded skip', function()
    local h = new({place = 'pit'})
    -- A closed ring of walls (1.2 m thick, wider than the 0.8 m grid) around
    -- the drop at (10, 0).
    h.place.walls = {{6, 14, -4, -2.8}, {6, 14, 2.8, 4}, {6, 7.2, -4, 4}, {12.8, 14, -4, 4}}
    h.drop('pit', 10, 0, helm())
    h.run(70)
    local st = route_stats(h)
    h.place.walls = nil
    eq(h.pickups or 0, 0, 'nothing picked through the walls')
    ok(st ~= nil, 'route stats')
    eq(st.found + st.failed, 1, 'A* planned once for the drop (plans=' .. st.plans .. ' cached=' .. st.cached .. ')')
    eq(st.failed, 1, 'no path')
    ok(st.cached >= 1, 'later rounds reuse the cached "no path": ' .. st.cached)
    ok(st.max_nodes <= 1500, 'at most 1500 nodes: ' .. st.max_nodes)
    eq(busy(h), false, 'not busy after the bound')
end)

case('E6c the ray cast erroring or missing walks straight (never plans)', function()
    local h = new({place = 'pit'})
    h.place.walls = {{4, 5, -10, 10}}
    h.G.utility.is_ray_cast_walkeable = function() error('host: ray cast unavailable') end
    h.drop('pit', 10, 0, helm())
    h.run(5)
    local st = route_stats(h)
    h.place.walls = nil
    eq(st.found + st.failed, 0, 'no A* without a readable blocked ray cast')
    ok(st.straight >= 1, 'walked straight')
end)

case('E7 a loaded plain Locran\'s Talisman follows Unique GA 2; the 0-GA Ancestral reading is taken', function()
    local h = new({place = 'pit'})
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.affix_settings.unique_greater_affix_slider:set(2)
    local function affix(hash, name) return {affix_name_hash = hash, get_name = function() return name end} end
    local function locran(ga) return h.gear({rarity = 6, ancestral = true, ga = ga, name = 'S05_BSK_Amulet_Unique_Generic_001',
        sno = 1944508, affixes = {affix(11, 'S05_BSK_Generic_009'), affix(12, 'X2_CritDamage_Greater'), affix(13, 'S04_Life')}}) end
    local im = h.mod('Rosie', 'rosie.private.pickup.src.item_manager')
    h.run(1)
    local wanted, why = h.as('Rosie', function() return im.check_want_item(locran(1), true) end)
    eq(wanted, false, 'a loaded plain Unique (GA 1) follows the Unique GA rule: ' .. tostring(why))
    local wanted0, why0 = h.as('Rosie', function() return im.check_want_item(locran(0), true) end)
    eq(wanted0, true, 'Ancestral GA 0 without a mark is taken: ' .. tostring(why0))
    ok(tostring(why0):find('may be a Mythic', 1, true), tostring(why0))
end)

case('E8 pickup keeps the host Auto Loot off', function()
    local h = new({place = 'pit', auto_loot = true})
    h.run(1)
    eq(h.orb.auto_loot, false, 'host auto loot switched off')
end)

case('E9 details loading mid-approach decide the drop (plain abandoned, Mythic picked up)', function()
    local function run(mythic)
        local h = new({place = 'pit'})
        h.mod('Rosie', 'rosie.private.pickup.gui').elements.affix_settings.unique_greater_affix_slider:set(2)
        local function affix(hash, name) return {affix_name_hash = hash, get_name = function() return name end} end
        local item = h.drop('pit', 20, 0, {rarity = 6, ancestral = true, name = 'Helm_Unique_Generic_005', sno = 2647147, affixes = {}})
        h.at(1.0, function()
            item.affixes = {affix(2662414, 'Helm_Unique_Generic_005'), affix(1829592, 'S04_Life')}
            item.ga = 1
            if mythic then item.affixes[3] = affix(2628989, 'S14_Mythic_UniquePotency') end
        end)
        h.run(8)
        return (h.pickups or 0) > 0
    end
    eq(run(false), false, 'plain Unique abandoned once its details load')
    eq(run(true), true, 'Mythic form picked up')
end)

-- ── Review rc.10 regressions ────────────────────────────────────────────
-- (major) The rest between rounds dropped the busy flag: activity loot holds
-- (Reaper loot_ready, 3 s of quiet) left before round 2 could pick the drop.
case('R-E10 a stalled drop keeps the busy flag through its rounds; Reaper waits for it', function()
    for _, fight in ipairs({10, 15}) do
        local h = J.new({rosie = true, dirs = {'Reaper-main'}, place = 'pit'})
        h.pos = h.v(0, 0)
        eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'enable')
        h.frame()
        h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(30)
        h.drop('pit', 12, 0, helm())
        local real = h.G.pathfinder.request_move
        local fight_until = h.now + fight
        h.G.pathfinder.request_move = function(p) if h.now < fight_until then return false end return real(p) end
        local utils = h.mod('Reaper-main', 'core.utils')
        local started, idle_gap, ready_early = false, 0, false
        h.run_until(function() return (h.pickups or 0) > 0 end, 40, function(hh)
            if (hh.pickups or 0) > 0 then return end
            local b = busy(hh)
            if b then started = true elseif started then idle_gap = idle_gap + 1 end
            if hh.as('Reaper-main', function() return utils.loot_ready() end) then ready_early = true end
        end)
        ok((h.pickups or 0) > 0, fight .. ' s fight: picked up\n' .. h.tail())
        eq(idle_gap, 0, fight .. ' s fight: idle frames between rounds')
        eq(ready_early, false, fight .. ' s fight: Reaper loot_ready before the pickup')
    end
end)

-- (major) Diagonal A* steps cut wall corners and the mover skipped planned
-- waypoints within 1.5 m: the path could not be walked (8 of 30 variants).
case('R-E11 E6 geometry over speeds and starts: always picked up; no corner-cutting waypoint', function()
    local fails = {}
    for _, speed in ipairs({4, 5, 6, 7, 8}) do
        for _, st in ipairs({{0, 0}, {-5, -3}, {1, 5}}) do
            local h = new({place = 'pit', speed = speed})
            h.pos = h.v(st[1], st[2])
            h.place.walls = {{4, 5, -10, 10}}
            h.drop('pit', 10, 0, helm())
            if not h.run_until(function() return (h.pickups or 0) > 0 end, 60) then
                fails[#fails + 1] = string.format('speed %d start (%d,%d)', speed, st[1], st[2])
            end
        end
    end
    eq(#fails, 0, 'never picked: ' .. table.concat(fails, ', '))
    -- Every leg of a plan is walkable in a straight line.
    local h = new({place = 'pit'})
    h.place.walls = {{4, 5, -10, 10}}
    local R = h.mod('Rosie', 'rosie.private.route')
    R.reset()
    local path = h.as('Rosie', function() return R.plan({x = 0, y = 0, z = 0}, {x = 10, y = 0, z = 0}) end)
    ok(type(path) == 'table' and #path >= 2, 'a path around the wall')
    local prev = {x = 0, y = 0}
    for i, q in ipairs(path) do
        ok(h.G.utility.is_ray_cast_walkeable(h.v(prev.x, prev.y), h.v(q.x, q.y)),
            string.format('leg %d (%.1f,%.1f)->(%.1f,%.1f) crosses the wall', i, prev.x, prev.y, q.x, q.y))
        prev = q
    end
end)

-- (major) The path cache ignored the start: a path planned elsewhere was
-- replayed from its first waypoint after a pause, a rest or a recovery.
case('R-E12 a path is re-planned from where the player stands (pause, body-block)', function()
    local h = new({place = 'pit'})
    h.place.walls = {{4, 5, -10, 10}}
    h.drop('pit', 10, 0, helm())
    h.run(1.0) -- the northern route is planned and walked
    ok(h.as(CONSUMER, function() return h.G.LooteerPlugin.acquire_pause('HordeDev') end) ~= false, 'paused')
    h.run(0.3)
    h.pos = h.v(2, -14)
    h.run(0.3)
    h.as(CONSUMER, function() return h.G.LooteerPlugin.release_pause('HordeDev') end)
    local walked, last, maxy = 0, h.v(h.pos:x(), h.pos:y()), -1e9
    local picked = h.run_until(function() return (h.pickups or 0) > 0 end, 40, function(hh)
        walked = walked + last:dist_to_ignore_z(hh.pos); last = hh.v(hh.pos:x(), hh.pos:y())
        if hh.pos:y() > maxy then maxy = hh.pos:y() end
    end)
    ok(picked, 'picked after the pause\n' .. h.tail())
    ok(walked < 25, string.format('the southern route from (2,-14): walked %.1f m', walked))
    ok(maxy < 1, string.format('never walked back north: max y %.1f', maxy))
    local R = h.mod('Rosie', 'rosie.private.route')
    ok(R.stats.found <= R.PLAN_CAP, 'plans per drop bounded: ' .. R.stats.found)
    -- A body-block next to the wall end: the recovery plans from here.
    h = new({place = 'pit'})
    h.place.walls = {{4, 5, -10, 10}}
    h.drop('pit', 10, 0, helm())
    h.run_until(function() return h.pos:y() > 9.5 end, 10)
    local speed = h.speed; h.speed = 0
    h.run(4)
    h.speed = speed
    local mark, t0 = #h.moves, h.now
    picked = h.run_until(function() return (h.pickups or 0) > 0 end, 20)
    ok(picked and h.now - t0 < 8, string.format('picked %.1f s after the block\n%s', h.now - t0, h.tail()))
    for i = mark + 1, #h.moves do
        ok(h.moves[i].x > 2, string.format('move back toward the old start (%.1f,%.1f)', h.moves[i].x, h.moves[i].y))
    end
end)

-- (minor) One plan asked the host about the same cells again and again.
case('R-E13 a walled-in drop asks the host about each cell once per plan', function()
    local h = new({place = 'pit'})
    h.place.walls = {{6, 14, -4, -2.8}, {6, 14, 2.8, 4}, {6, 7.2, -4, 4}, {12.8, 14, -4, 4}}
    h.drop('pit', 10, 0, helm())
    local u, per = h.G.utility, {}
    local rw = u.is_point_walkeable
    u.is_point_walkeable = function(p) per[h.frames] = (per[h.frames] or 0) + 1; return rw(p) end
    h.run(70)
    local worst = 0
    for _, n in pairs(per) do if n > worst then worst = n end end
    ok(worst <= 2500, 'host walkability checks in the worst frame: ' .. worst)
    eq(h.pickups or 0, 0, 'nothing picked through the walls')
end)

print('Rosie pickup rc.10: ' .. checks .. ' checks')
if #failures > 0 then error(#failures .. ' failure(s):\n' .. table.concat(failures, '\n')) end
