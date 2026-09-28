-- QQT_Warpigz_v3 sweep tooling self-test (audit/tests/joint_host.lua):
--   V1 invariant monitors are opt-in and read-only: the same seeded run
--      (all plugins, Rosie, rotation, chaos, virtual os.clock) prints the
--      identical log with the monitors on and off, and replays exactly
--   V2 TELEPORT  more than 2 casts before an arrival in a new place
--   V3 LEFT_DROP a wanted drop left behind by a travel (Mythic beyond the
--      pickup distance, legendary within it, the channel tag); nothing for
--      a picked-up drop, an unwanted one, a scenario-set place, Rosie off
--   V4 STALL     a farm plugin on, the player still 90 s outside town; a
--      quiet town is idle; a town where commands keep coming stalls
--   V5 SPAM / LOOP (console lines, "state A -> B", the player's place)
--   V6 assert_invariants overrides (false / count / predicate)
--   V7 Universal Rotation stub: casts and damage within 12 m, seeded dashes
--      stop at walls, a dash breaks a channel, interrupt=false holds
--   V8 chaos: seeded and replayable (`only`), every kind by hand, a drop
--      inside a travel channel, the lazy stash read, J.rng on both runtimes
-- Runs under Lua 5.4 and LuaJIT.
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
    local started = os.clock()
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print(string.format('PASS sweep-harness: %s (%.1fs)', name, os.clock() - started))
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL sweep-harness: ' .. name .. ': ' .. tostring(err)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function kinds(h, kind)
    local n = 0
    for _, hit in ipairs(h.invariants.hits) do if hit.kind == kind then n = n + 1 end end
    return n
end
local function first_hit(h, kind)
    for _, hit in ipairs(h.invariants.hits) do if hit.kind == kind then return hit end end
    return nil
end
local function el(h, dir)
    local mod = dir == 'SilentRaven' and 'silent_raven.gui' or 'gui'
    return assert(h.mod(dir, mod), 'gui of ' .. dir).elements
end
local function rosie_on(h, distance)
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(distance or 2)
    h.frame()
end
local ENV_ON = os.getenv('QQT_INVARIANTS') == '1'

case('V1 monitors are opt-in and read-only; a seeded chaos run replays exactly', function()
    local off = J.new({dirs = {}})
    eq(off._inv ~= nil, ENV_ON, 'default follows QQT_INVARIANTS')
    local forced = J.new({dirs = {}, invariants = false})
    eq(forced._inv, nil, 'invariants = false wins over the environment')
    ok(forced.invariant_report():find('invariants off', 1, true), 'report says off')
    ok(not pcall(forced.assert_invariants, 'x'), 'asserting with the monitors off is an error')
    local function run(inv)
        local h = J.new({rosie = true, place = 'pit', invariants = inv, rotation = true, ordered_pairs = true,
            chaos = {seed = 42, rate = 6}})
        h.assert_clean('load')
        el(h, 'WarPigs').main_toggle:set(true); el(h, 'WarPug').main_toggle:set(true)
        h.set_quests({'WarPlans_QST_ThePit'})
        rosie_on(h, 15)
        for i = 1, 3 do h.actor('pit', 'Pit_Monster', 20 * i, 5, {enemy = true, health = 150}) end
        h.run(90)
        h.assert_clean('run')
        return h
    end
    local a, b = run(true), run(false)
    ok(#a.chaos.log >= 5, 'chaos injected (' .. #a.chaos.log .. ')')
    eq(#a.log, #b.log, 'log length with monitors on / off')
    for i = 1, #a.log do
        if a.log[i] ~= b.log[i] then error('log line ' .. i .. ' differs:\n  on:  ' .. a.log[i] .. '\n  off: ' .. b.log[i]) end
    end
    eq(string.format('%.3f,%.3f,%s', a.pos:x(), a.pos:y(), a.place.key),
        string.format('%.3f,%.3f,%s', b.pos:x(), b.pos:y(), b.place.key), 'final position')
    eq(a.chaos.summary(), b.chaos.summary(), 'same seed, same injections')
    eq(a.rotation.casts, b.rotation.casts, 'same rotation')
    ok(a.chaos.replay():find('seed = 42', 1, true), 'replay string names the seed')
end)

case('V2 TELEPORT: a third cast before arriving somewhere new, with the caller', function()
    local h = J.new({dirs = {}, place = 'pit', invariants = true})
    local function tp() h.as(CONSUMER, function() return h.G.teleport_to_waypoint(0x76D58) end) end
    tp(); h.run(0.3); tp(); h.run(0.3)
    eq(kinds(h, 'TELEPORT'), 0, 'two casts are allowed')
    tp(); h.run(0.3)
    eq(kinds(h, 'TELEPORT'), 1, 'the third cast is a violation')
    local hit = first_hit(h, 'TELEPORT')
    ok(hit.detail:find('3 teleport casts since arriving in pit', 1, true), hit.detail)
    ok(hit.detail:find('ctx Consumer', 1, true), 'caller context recorded: ' .. hit.detail)
    tp(); h.run(0.3)
    eq(kinds(h, 'TELEPORT'), 1, 'one hit per transition (updated)')
    ok(first_hit(h, 'TELEPORT').detail:find('4 teleport casts', 1, true), 'count revised')
    ok(h.run_until(function() return h.place == h.P.cerrigar end, 10), 'arrived')
    h.run(0.5)
    tp(); h.run(4)
    eq(kinds(h, 'TELEPORT'), 1, 'counting restarts after an arrival in a new place')
    -- a War Plan teleport that goes nowhere is retried: counted too
    h.as(CONSUMER, function() h.G.warplan.teleport_to_activity() end)
    h.as(CONSUMER, function() h.G.warplan.teleport_to_activity() end)
    h.as(CONSUMER, function() h.G.warplan.teleport_to_activity() end)
    h.frame()
    eq(kinds(h, 'TELEPORT'), 2, 'War Plan teleports without a destination')
    ok(h.invariants.hits[2].detail:find('warplan->no destination', 1, true), h.invariants.hits[2].detail)
end)

case('V3 LEFT_DROP: wanted drops left by a travel; not for picked, unwanted, scenario moves or Rosie off', function()
    local h = J.new({rosie = true, dirs = {}, place = 'pit', invariants = true})
    h.assert_clean('load')
    rosie_on(h, 2)
    h.pos = h.v(0, 0)
    ok(h.as(CONSUMER, function() return h.G.LooteerPlugin.acquire_pause('Consumer') end) ~= false, 'pickup paused')
    local MARK = {affix_name_hash = 2628989, get_name = function() return 'S14_Mythic_UniquePotency' end}
    local mythic = h.drop('pit', 8, 0, {name = 'Helm_Unique_Generic_005', sno = 2647147, rarity = 6, ancestral = true,
        ga = 1, affixes = {MARK}})
    local rare_far = h.drop('pit', 0, 8, {name = 'Helm_Rare_Joint', rarity = 3, ga = 0})
    local legendary = h.drop('pit', 1.5, 0, {name = 'Helm_Legendary_Chaos', rarity = 5, ga = 3})
    local beyond = h.drop('pit', 20, 0, {name = 'Helm_Unique_Generic_005', sno = 2647147, rarity = 6, ga = 1, affixes = {MARK}})
    h.run(1)
    eq(kinds(h, 'LEFT_DROP'), 0, 'nothing while the player stays')
    h.travel_to('temis', 1.0, 'waypoint')
    h.run(0.5)
    local late = h.drop('pit', 0, 1, {name = 'Helm_Legendary_Chaos', rarity = 5, ga = 3})
    ok(h.run_until(function() return h.place == h.P.limbo end, 3), 'left the pit')
    eq(kinds(h, 'LEFT_DROP'), 3, 'Mythic beyond the distance, legendary within, the drop during the channel\n'
        .. (h.invariant_report()))
    local text = h.invariant_report()
    ok(text:find('MYTHIC', 1, true) and text:find('beyond it', 1, true), 'Mythic tagged: ' .. text)
    ok(text:find('dropped during the waypoint channel', 1, true), 'channel tag: ' .. text)
    ok(not text:find(tostring(rare_far.sno), 1, true) and not text:find('20.0 m', 1, true), 'rare beyond reach / 20 m ignored')
    ok(mythic and legendary and late and beyond, 'drops exist')
    -- back to the spot, pickup resumed: the hit is annotated, not withdrawn
    ok(h.run_until(function() return h.place == h.P.temis end, 5), 'in town')
    h.as(CONSUMER, function() return h.G.LooteerPlugin.release_pause('Consumer') end)
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(15)
    h.travel_to('pit', 0.5, 'town_portal')
    h.travel.pos = h.v(0, 0)
    ok(h.run_until(function() return legendary.picked == true end, 30), 'taken after the return\n' .. h.tail(8))
    h.run(0.2)
    eq(kinds(h, 'LEFT_DROP'), 3, 'no new hit on the return')
    ok(h.invariant_report():find('picked up later, back in pit', 1, true), 'annotated: ' .. h.invariant_report())
    -- picked-up drop, Rosie off, scenario-set place
    local h2 = J.new({rosie = true, dirs = {}, place = 'pit', invariants = true})
    rosie_on(h2, 15)
    h2.pos = h2.v(0, 0)
    local item = h2.drop('pit', 1, 0, {name = 'Helm_Legendary_Chaos', rarity = 5, ga = 3})
    ok(h2.run_until(function() return item.picked == true end, 20), 'Rosie picks it up\n' .. h2.tail(10))
    h2.travel_to('temis', 1.0, 'waypoint')
    h2.run(4)
    eq(kinds(h2, 'LEFT_DROP'), 0, 'a picked-up drop is not left')
    local h3 = J.new({rosie = true, dirs = {}, place = 'pit', invariants = true})
    h3.pos = h3.v(0, 0) -- Rosie never enabled
    h3.drop('pit', 1, 0, {name = 'Helm_Legendary_Chaos', rarity = 5, ga = 3})
    h3.travel_to('temis', 1.0, 'waypoint')
    h3.run(4)
    eq(kinds(h3, 'LEFT_DROP'), 0, 'Rosie off: nothing Rosie would pick up')
    local h4 = J.new({rosie = true, dirs = {}, place = 'pit', invariants = true})
    rosie_on(h4, 15)
    h4.as(CONSUMER, function() return h4.G.LooteerPlugin.acquire_pause('Consumer') end)
    h4.pos = h4.v(0, 0)
    h4.drop('pit', 1, 0, {name = 'Helm_Legendary_Chaos', rarity = 5, ga = 3})
    h4.place, h4.pos = h4.P.temis, h4.P.temis.spawn
    h4.run(2)
    eq(kinds(h4, 'LEFT_DROP'), 0, 'a place the scenario sets is no departure')
end)

case('V4 STALL: a farm plugin on and the player still for 90 s; quiet town is idle; a busy town stalls', function()
    local h = J.new({dirs = {'WarPigs'}, place = 'pit', invariants = true})
    h.pos = h.v(10, 10)
    h.run(100)
    eq(kinds(h, 'STALL'), 0, 'no farm plugin on: no stall')
    el(h, 'WarPigs').main_toggle:set(true)
    h.run(80)
    eq(kinds(h, 'STALL'), 0, 'under 90 s')
    h.run(15)
    eq(kinds(h, 'STALL'), 1, 'over 90 s\n' .. h.tail(10))
    local hit = first_hit(h, 'STALL')
    ok(hit.detail:find('farm on: WarPigs', 1, true), hit.detail)
    ok(hit.detail:find('WarPigs drew', 1, true), 'status line quoted: ' .. hit.detail)
    h.run(20)
    eq(kinds(h, 'STALL'), 1, 'one hit per stall (revised)')
    ok(first_hit(h, 'STALL').detail:find('for 11', 1, true), 'duration revised: ' .. first_hit(h, 'STALL').detail)
    h.pos = h.v(20, 10)
    h.run(95)
    eq(kinds(h, 'STALL'), 2, 'a new stall after moving')
    -- town: quiet is idle
    local t = J.new({dirs = {'WarPigs'}, place = 'temis', invariants = true})
    el(t, 'WarPigs').main_toggle:set(true)
    t.run(120)
    eq(kinds(t, 'STALL'), 0, 'idle in town')
    -- town with commands every 5 s that do not move the player
    t.run(120, function(hh)
        if math.floor(hh.now * 10 + 0.5) % 50 == 0 then
            hh.as(CONSUMER, function() hh.G.interact_object(hh.tyrael) end)
        end
    end)
    eq(kinds(t, 'STALL'), 1, 'stuck in town while commands keep coming')
    -- dead / loading excluded
    local d = J.new({dirs = {'WarPigs'}, place = 'pit', invariants = true})
    el(d, 'WarPigs').main_toggle:set(true)
    rawset(d.G, 'revive_at_checkpoint', function() end) -- nobody revives
    d.dead = true
    d.run(120)
    eq(kinds(d, 'STALL'), 0, 'dead is not a stall')
end)

case('V5 SPAM and LOOP', function()
    local h = J.new({dirs = {}, place = 'pit', invariants = true})
    h.as(CONSUMER, function() for i = 1, 20 do h.G.console.print('[X] waiting ' .. i .. '.5 s') end end)
    eq(kinds(h, 'SPAM'), 0, '20 lines are allowed')
    h.as(CONSUMER, function() h.G.console.print('[X] waiting 99.5 s') end)
    eq(kinds(h, 'SPAM'), 1, 'the 21st masked-equal line within 60 s')
    ok(first_hit(h, 'SPAM').detail:find('[X] waiting #.# s', 1, true), first_hit(h, 'SPAM').detail)
    for i = 1, 30 do h.as(CONSUMER, function() h.G.print('[Y] tick ' .. i) end); h.run(3.5) end
    eq(kinds(h, 'SPAM'), 1, '30 lines over 105 s stay under 21 per 60 s')
    for i = 1, 6 do
        h.as(CONSUMER, function() h.G.console.print('[Z] state IDLE -> RUN_' .. i) end)
        h.as(CONSUMER, function() h.G.console.print('[Z] state RUN_' .. i .. ' -> IDLE') end)
        h.run(1)
    end
    eq(kinds(h, 'LOOP'), 1, 'state lines: 12 switches IDLE <-> RUN_# within 120 s')
    local loop = first_hit(h, 'LOOP').detail
    ok(loop:find('IDLE', 1, true) and loop:find('RUN_#', 1, true), loop)
    local w = J.new({dirs = {}, place = 'temis', invariants = true})
    for i = 1, 12 do w.place = (i % 2 == 1) and w.P.kurast or w.P.temis; w.run(2) end
    eq(kinds(w, 'LOOP'), 1, 'the player bouncing between two places')
    ok(first_hit(w, 'LOOP').detail:find('world.place', 1, true), first_hit(w, 'LOOP').detail)
end)

case('V6 assert_invariants overrides', function()
    local h = J.new({dirs = {}, place = 'pit', invariants = true})
    h.as(CONSUMER, function() for _ = 1, 25 do h.G.console.print('same') end end)
    for _ = 1, 3 do h.as(CONSUMER, function() h.G.teleport_to_waypoint(0x76D58) end); h.run(0.2) end
    ok(not pcall(h.assert_invariants, 'all'), 'two kinds fail')
    ok(pcall(h.assert_invariants, 'skip', {SPAM = false, TELEPORT = false}), 'false ignores a kind')
    ok(pcall(h.assert_invariants, 'count', {SPAM = 1, TELEPORT = 1}), 'a count allows that many')
    ok(not pcall(h.assert_invariants, 'count0', {SPAM = 0, TELEPORT = 1}), 'count 0 allows none')
    ok(pcall(h.assert_invariants, 'pred', {SPAM = function(hit) return hit.detail:find('same', 1, true) end,
        TELEPORT = false}), 'a predicate ignores matching hits')
    local _, err = pcall(h.assert_invariants, 'label', {SPAM = false})
    ok(tostring(err):find('label: 1 invariant violation', 1, true), tostring(err))
    local text, hits = h.invariant_report()
    eq(#hits, 2, 'report lists both'); ok(text:find('SPAM=1', 1, true) and text:find('TELEPORT=1', 1, true), text)
end)

case('V7 Universal Rotation stub', function()
    local function arena(o)
        local h = J.new({dirs = {}, place = 'pit', rotation = o})
        h.pos = h.v(100, 0)
        return h
    end
    local h = arena({seed = 5, move_chance = 1})
    h.run(3)
    eq(h.rotation.casts, 0, 'no enemy in 12 m: no cast')
    local e = h.actor('pit', 'Dummy', 108, 0, {enemy = true, health = 1000})
    h.run(3)
    ok(h.rotation.casts >= 4, 'casts at an enemy in range: ' .. h.rotation.casts)
    ok(e.health < 1000, 'damage dealt')
    ok(h.rotation.dashes >= 1, 'seeded dashes/evades: ' .. h.rotation.dashes)
    local moved = math.abs(h.pos:x() - 100) + math.abs(h.pos:y())
    ok(moved > 0, 'the player was moved')
    local h2 = arena({seed = 5, move_chance = 1})
    h2.run(3)
    h2.actor('pit', 'Dummy', 108, 0, {enemy = true, health = 1000})
    h2.run(3)
    eq(string.format('%.4f,%.4f', h2.pos:x(), h2.pos:y()), string.format('%.4f,%.4f', h.pos:x(), h.pos:y()), 'same seed, same dashes')
    -- walls stop a dash
    local w = arena({seed = 9, move_chance = 1, range = 30})
    w.P.pit.walls = {{95, 105, 3, 4}, {95, 105, -4, -3}, {96, 97, -4, 4}, {103, 104, -4, 4}}
    w.actor('pit', 'Dummy', 120, 0, {enemy = true, health = 1000})
    w.run(5)
    ok(w.pos:x() > 97 and w.pos:x() < 103 and math.abs(w.pos:y()) < 3, 'boxed in by walls: ' .. w.pos:x() .. ',' .. w.pos:y())
    w.P.pit.walls = nil
    -- a dash breaks the channel; interrupt=false holds still while channelling
    local c = arena({seed = 3, move_chance = 1, interrupt = 'dash'})
    c.actor('pit', 'Dummy', 106, 0, {enemy = true, health = 100000})
    c.travel_to('temis', 3.0, 'waypoint')
    c.run(5)
    ok(c.rotation.interrupts >= 1 and c.place == c.P.pit, 'channel broken by an evade')
    local q = arena({seed = 3, move_chance = 1, interrupt = false})
    q.actor('pit', 'Dummy', 106, 0, {enemy = true, health = 100000})
    q.travel_to('temis', 3.0, 'waypoint')
    ok(q.run_until(function() return q.place == q.P.temis end, 8), 'interrupt=false: the channel completes')
    eq(q.rotation.interrupts, 0, 'no interrupt')
end)

case('V8 chaos: seeded, replayable, every kind, channel drops, lazy stash', function()
    local r1, r2 = J.rng(42), J.rng(42)
    eq(string.format('%.9f', r1.next()), '0.735423532', 'J.rng(42) first value (both runtimes)')
    r2.next(); eq(r1.next(), r2.next(), 'same stream')
    local function run(chaos)
        local h = J.new({rosie = true, dirs = {'Batmobile'}, place = 'pit', chaos = chaos})
        h.assert_clean('load')
        rosie_on(h, 2)
        h.run(240)
        return h
    end
    local a = run({seed = 7, rate = 4, kinds = {'drop', 'elite', 'obstacle', 'limbo', 'bag_full'}})
    local b = run({seed = 7, rate = 4, kinds = {'drop', 'elite', 'obstacle', 'limbo', 'bag_full'}})
    ok(#a.chaos.log >= 8, 'injections: ' .. #a.chaos.log)
    eq(a.chaos.summary(), b.chaos.summary(), 'same seed, same injections')
    local n = a.chaos.log[3].n
    local only = run({seed = 7, rate = 4, kinds = {'drop', 'elite', 'obstacle', 'limbo', 'bag_full'}, only = {n}})
    eq(#only.chaos.log, 1, '`only` runs just that injection')
    eq(string.format('%.1f %s', only.chaos.log[1].t, only.chaos.log[1].kind),
        string.format('%.1f %s', a.chaos.log[3].t, a.chaos.log[3].kind), 'same time and kind')
    ok(a.logged('[chaos] seed=7 #') >= 8, 'every injection in h.log with its seed')
    -- every kind by hand
    local h = J.new({rosie = true, dirs = {'Batmobile'}, place = 'pit', chaos = {seed = 1, rate = 1e-9}})
    rosie_on(h, 2)
    h.pos = h.v(50, 0)
    local rec = h.chaos_inject('death')
    ok(not rec.skipped and h.dead, 'death: ' .. rec.detail)
    ok(h.run_until(function() return not h.dead end, 15), 'revived at the checkpoint (ClickRevive stand-in)')
    eq(h.logged('ClickRevive stand-in'), 1, 'revive logged')
    rec = h.chaos_inject('drop', {mythic = true})
    local item = h.P.pit.items[#h.P.pit.items]
    ok(not rec.skipped and item.rarity == 6 and item.affixes[2].affix_name_hash == 2628989, 'Mythic drop: ' .. rec.detail)
    local place, pos = h.place, h.pos
    rec = h.chaos_inject('limbo', {seconds = 3})
    eq(h.place, h.P.limbo, 'limbo')
    h.run(3.2)
    ok(h.place == place and h.pos == pos, 'back at the same spot')
    local batmobile_before = h.mod('Batmobile', 'core.settings')
    rec = h.chaos_inject('reload', {dir = 'Batmobile'})
    ok(not rec.skipped and h.mod('Batmobile', 'core.settings') ~= batmobile_before, 'reload: ' .. rec.detail)
    rec = h.chaos_inject('bag_full')
    eq(#h.inventory, 33, 'bag full: ' .. rec.detail)
    rec = h.chaos_inject('elite', {count = 4})
    local elites = 0
    for _, act in ipairs(h.P.pit.actors) do if act.elite then elites = elites + 1 end end
    eq(elites, 4, 'elite pack: ' .. rec.detail)
    h.pos, h.goal = h.v(50, 0), h.v(80, 0)
    rec = h.chaos_inject('obstacle', {seconds = 4})
    eq(#h.P.pit.walls, 1, 'wall: ' .. rec.detail)
    ok(h.P.pit.walls[1][1] > 50 and h.P.pit.walls[1][1] < 54, 'across the path, 3 m ahead')
    h.run(4.2)
    eq(h.P.pit.walls, nil, 'wall removed')
    rec = h.chaos_inject('stash_lazy')
    eq(#h.stash, 300, 'stash full: ' .. rec.detail)
    h.place, h.pos = h.P.temis, h.v(2574, -485)
    h.as(CONSUMER, function() h.G.interact_vendor(h.temis_stash) end)
    local lp = h.G.get_local_player()
    eq(#lp:get_stash_items(), 32, 'first read small')
    h.now = h.now + 1.2 -- no frames: Rosie (full bag) would walk off and close the panel
    eq(#lp:get_stash_items(), 300, 'later read full')
    rec = h.chaos_inject('drop')
    ok(rec.skipped, 'no drops in town')
    -- a drop inside a travel channel
    local c = J.new({rosie = true, dirs = {}, place = 'pit', chaos = {seed = 3, rate = 1e-9, channel_drop = 1}})
    c.pos = c.v(0, 0)
    c.travel_to('temis', 1.0, 'waypoint')
    c.run(0.9)
    eq(c.logged('during the waypoint channel'), 1, 'drop during the channel\n' .. c.tail(5))
    eq(#c.P.pit.items, 1, 'on the ground in the pit')
end)

print(string.format('sweep harness: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
