-- QQT_Warpigz_v3 Rosie 1.0.23 (Auditor review of 3.3.2, audit/BOARD.md):
--  F  [HIGH] the fight hold went stale between fights: FIGHT.on / since
--     survived a stretch with no waiting drop, so the next fight hit the 45 s
--     cap on its first frame and Rosie walked out of it to the drop
--     (audit/reviews/repro_rosie_fight_stale_332.lua).
--  Y  [LOW] a yield counted no round: a drop that kept losing the path to
--     another mover came back every 30 s forever (C6).
--  P  [LOW] perf: choose() re-read the equipment bag for every ground
--     candidate, called Pickup.blocked for every ground item and read GA
--     counts of drops beyond 60 m; the answers must not change.
-- Real Rosie in the joint host.
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
    if passed then print('PASS pickup 1.0.23: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL pickup 1.0.23: ' .. name .. ': ' .. tostring(err)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function new()
    local h = J.new({rosie = true, dirs = {}, place = 'pit'})
    h.assert_clean('load')
    h.pos = h.v(0, 0)
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(30)
    return h
end
local function busy(h) return h.as(CONSUMER, function() return h.G.LooteerPlugin.is_actively_looting() end) end
local function rosie_moves(h, since)
    return h.count(h.moves, function(m) return m.owner == 'Rosie' and m.t >= since end)
end
local function remove(h, item)
    local list = h.place.items
    for i = #list, 1, -1 do if list[i] == item then table.remove(list, i) end end
end

case('F1 a fight that starts 60 s after the last fight hold is not capped on its first frame (stale hold)', function()
    local h = new()
    -- Fight A: an elite 5 m away, a drop 7 m the other way: the hold is on.
    local e1 = h.actor('pit', 'Dark_Conjurer', 5, 0, {enemy = true, elite = true, health = 1e9})
    local d1 = h.drop('pit', -7, 0, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_020'})
    h.run(3)
    local IM = h.mod('Rosie', 'rosie.private.pickup.src.item_manager')
    eq(IM.fight_waiting, true, 'fight A: the drop waits for the fight')
    eq(rosie_moves(h, 0), 0, 'fight A: no walk out of the fight')
    -- The drop goes (another player, despawn) while the enemy lives; then fight A ends.
    remove(h, d1)
    h.run(3)
    e1.health = 0; h.remove_actor(e1)
    h.run(60)
    -- Fight B: a new elite and a new drop 7 m off.
    local t0 = h.now
    local px = h.pos:x()
    local e2 = h.actor('pit', 'Dark_Conjurer', px + 5, 0, {enemy = true, elite = true, health = 1e9})
    local d2 = h.drop('pit', px - 7, 0, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_021'})
    local waiting = 0
    h.run(5, function() if IM.fight_waiting == true then waiting = waiting + 1 end end)
    eq(h.logged('A fight kept pickup waiting', t0), 0, 'no 45 s cap in the first 5 s of fight B\n' .. h.tail(8))
    eq(rosie_moves(h, t0), 0, 'fight B: no walk out of the fight\n' .. h.tail(8))
    ok(d2.picked ~= true, 'fight B: the drop waits')
    ok(waiting >= 45, 'fight B: the drop waits for the fight all along (' .. waiting .. ' of 50 pulses)')
    -- After fight B the drop is taken.
    e2.health = 0; h.remove_actor(e2)
    ok(h.run_until(function() return d2.picked == true end, 15), 'taken after fight B\n' .. h.tail(8))
    h.assert_clean('F1')
end)

case('F2 (C6) an enemy that never dies: the hold of one waiting drop is still capped once at 45 s, then the drop is taken', function()
    local h = new()
    h.actor('pit', 'Dark_Conjurer', 6, 0, {enemy = true, elite = true, health = 1e9})
    local t0 = h.now
    local d = h.drop('pit', -7, 0, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_022'})
    h.run(40)
    eq(h.logged('A fight kept pickup waiting', t0), 0, 'no cap before 45 s')
    eq(rosie_moves(h, t0), 0, 'no walk during the hold')
    ok(h.run_until(function() return d.picked == true end, 20), 'taken once the hold is capped\n' .. h.tail(8))
    eq(h.logged('A fight kept pickup waiting', t0), 1, 'the cap is logged once')
    ok(h.now - t0 >= 44, string.format('picked after the 45 s cap (%.1f s)', h.now - t0))
end)

case('F3 two drops of one fight a moment apart share the hold: the second does not restart the 45 s cap', function()
    local h = new()
    h.actor('pit', 'Dark_Conjurer', 6, 0, {enemy = true, elite = true, health = 1e9})
    local t0 = h.now
    local d1 = h.drop('pit', -7, 0, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_023'})
    h.run(30)
    remove(h, d1) -- gone at t0+30 s
    h.run(0.5)    -- well inside FIGHT.calm: still the same wait
    local d2 = h.drop('pit', -7, 1, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_024'})
    ok(h.run_until(function() return d2.picked == true end, 25), 'the second drop is taken at the first drop\'s cap\n' .. h.tail(8))
    ok(h.now - t0 < 50, string.format('capped from the first drop (%.1f s), not restarted', h.now - t0))
    eq(h.logged('A fight kept pickup waiting', t0), 1, 'one cap line')
end)

case('Y1 (C6) a drop that keeps losing the path to another mover is given up within its rounds', function()
    local h = new()
    local item = h.drop('pit', 20, 0, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_025'})
    -- A farm plugin that pulls the player home each time Rosie has walked
    -- toward the drop for 0.6 s (Rosie never reaches it).
    local farm = {since = nil, pull_until = -1}
    local function farm_pulse(hh)
        if busy(hh) then farm.since = farm.since or hh.now else farm.since = nil end
        if farm.since and hh.now - farm.since >= 0.6 then farm.pull_until = hh.now + 1.5 end
        if hh.now < farm.pull_until then
            hh.as(CONSUMER, function() return hh.G.pathfinder.request_move(hh.v(0, 0)) end)
        end
    end
    local t0 = h.now
    h.run(200, farm_pulse)
    local P = h.mod('Rosie', 'rosie.private.pickup.src.pickup')
    local per, max = P.limits.yield_per_round, P.limits.max_rounds
    -- The old code yielded forever (a new try every 30 s): nothing after the budget.
    local late = h.now - 70
    eq(rosie_moves(h, late), 0, 'no Rosie move in the last 70 s\n' .. h.tail(10))
    local lost = h.logged('failed (another move kept taking the player off it', t0)
    eq(lost, max, 'one failed round per ' .. tostring(per) .. ' yields, up to the round budget\n' .. h.tail(10))
    eq(h.logged('[Rosie pickup] Gave up on Helm_Legendary_Generic_025', t0), 1, 'given up once\n' .. h.tail(10))
    ok(per ~= nil and per >= 2 and per <= 3, 'yields per round: ' .. tostring(per))
    ok(item.picked ~= true, 'never reached')
    local busy_late = false
    h.run(35, function(hh) farm_pulse(hh); if busy(hh) then busy_late = true end end)
    eq(busy_late, false, 'pickup no longer busy for the given-up drop')
    h.assert_clean('Y1')
end)

-- P: counters around one pickup pulse (ItemManager.get_item_based_on_priority).
local function instrument(h)
    local IM = h.mod('Rosie', 'rosie.private.pickup.src.item_manager')
    local P = h.mod('Rosie', 'rosie.private.pickup.src.pickup')
    local player = h.G.get_local_player()
    local c = {pulses = 0, bag = 0, blocked = 0, blocked_far = 0, ga_far = 0, inside = false}
    local choose = IM.get_item_based_on_priority
    IM.get_item_based_on_priority = function(...)
        c.pulses = c.pulses + 1; c.inside = true
        local packed = {n = select('#', ...), ...}
        local okc, a, b = pcall(choose, (table.unpack or unpack)(packed, 1, packed.n))
        c.inside = false
        if not okc then error(a, 0) end
        return a, b
    end
    local read = player.get_inventory_items
    player.get_inventory_items = function(self, ...)
        if c.inside then c.bag = c.bag + 1 end
        return read(self, ...)
    end
    local blocked = P.blocked
    P.blocked = function(item, ...)
        if c.inside then
            c.blocked = c.blocked + 1
            if item and item.far then c.blocked_far = c.blocked_far + 1 end
        end
        return blocked(item, ...)
    end
    function c.far(item)
        item.far = true
        local attr = item.get_attribute
        item.get_attribute = function(self, name, ...)
            if c.inside and name == 'Item_Greater_Affix_Count' then c.ga_far = c.ga_far + 1 end
            return attr(self, name, ...)
        end
        return item
    end
    return c
end

case('P1 one pickup pulse reads the bag once, never calls blocked or reads GA for drops out of range; decisions unchanged', function()
    local h = new()
    local c = instrument(h)
    local near = {}
    for i = 1, 20 do
        local a = i * math.pi / 10
        near[i] = h.drop('pit', math.cos(a) * (10 + i * 0.4), math.sin(a) * (10 + i * 0.4),
            {rarity = 5, ga = 3, name = string.format('Helm_Legendary_Generic_%03d', 100 + i)})
    end
    local far = {}
    for i = 1, 40 do
        far[i] = c.far(h.drop('pit', 100 + i, 50, {rarity = 5, ga = 3, name = string.format('Helm_Legendary_Generic_%03d', 200 + i)}))
    end
    h.run(1)
    ok(c.pulses >= 5, 'pickup pulses: ' .. c.pulses)
    print(string.format('  P1 pulses=%d bag_reads=%d blocked=%d blocked_far=%d ga_far=%d', c.pulses, c.bag, c.blocked, c.blocked_far, c.ga_far))
    ok(c.bag <= c.pulses, string.format('equipment bag read at most once per pulse: %d reads in %d pulses (pre-fix: one per wanted drop)', c.bag, c.pulses))
    eq(c.blocked_far, 0, 'Pickup.blocked for drops out of range (none settled)')
    ok(c.blocked <= 20 * c.pulses, 'Pickup.blocked only for wanted drops: ' .. c.blocked)
    eq(c.ga_far, 0, 'GA reads of drops beyond 60 m')
    -- Decisions unchanged: every wanted drop is taken, nothing out of range.
    ok(h.run_until(function() for _, it in ipairs(near) do if not it.picked then return false end end; return true end, 60),
        'all 20 wanted drops taken\n' .. h.tail(8))
    for _, it in ipairs(far) do ok(it.picked ~= true, 'a drop out of range was taken') end
    h.assert_clean('P1')
end)

case('P2 the per-pulse bag reading never outlives its pulse: evaluate_item and the next pulse read the bag live', function()
    local h = new()
    -- The socketable bag, never stashed (a full bag would start a town trip).
    h.mod('Rosie', 'rosie.private.town.gui').elements.stash_socketables:set(0)
    h.socketables = {}
    for i = 1, 32 do h.socketables[i] = h.gear({name = 'Item_Generic_Rune_Filler', rarity = 1}) end
    h.speed = 0 -- the player stays; the rune stays out of reach
    local rune = h.drop('pit', 8, 0, {rarity = 1, ga = 1, name = 'Item_Generic_Rune_Test', bag = 'socketables'})
    h.run(0.5)
    eq(busy(h), true, 'socketable bag 32/33: the rune keeps pickup busy\n' .. h.tail(6))
    -- The bag fills between pulses: another plugin's evaluation and the next pulse see it.
    h.socketables[33] = h.gear({name = 'Item_Generic_Rune_Filler', rarity = 1})
    local wanted, why = h.as(CONSUMER, function() return h.G.LooteerPlugin.evaluate_item(rune, false) end)
    eq(wanted, false, 'evaluate_item right after the pulse reads the full bag')
    ok(type(why) == 'string' and why:find('bag full', 1, true) ~= nil, 'reason: ' .. tostring(why))
    h.run(0.3)
    eq(busy(h), false, 'the next pulse reads the full bag\n' .. h.tail(6))
    eq(h.as(CONSUMER, function() return h.G.LooteerPlugin.status().reason end), 'ready', 'pickup runs (not paused): the bag refused the rune')
    ok(rune.picked ~= true)
end)

case('P3 a settled drop out of pickup range still gets its one retry when the route brings it back (blocked keeps its away mark)', function()
    local h = new()
    -- A small bag item the game refuses (settled 'refused' after a full round in reach).
    local rune = h.drop('pit', 1, 0, {rarity = 1, name = 'Item_Generic_Rune_Test', bag = 'socketables', refuse = function() return true end})
    ok(h.run_until(function() return h.logged('[Rosie pickup] Leaving Item_Generic_Rune_Test') > 0 end, 30),
        'settled after its round\n' .. h.tail(8))
    -- Pickup distance below the away distance: the drop is never wanted
    -- while the player is away, only blocked's away mark remembers it.
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(3)
    h.goal = h.v(-20, 0)
    h.run(4)
    ok(h.pos:dist_to_ignore_z(rune.pos) > 10, 'the route took the player away')
    local tries = h.refusals or 0
    h.goal = h.v(0.5, 0)
    h.run(4)
    ok((h.refusals or 0) > tries, 'one more attempt after coming back\n' .. h.tail(8))
end)

print(string.format('rosie pickup 1.0.23: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(#failures .. ' pickup 1.0.23 regression(s) failed') end
