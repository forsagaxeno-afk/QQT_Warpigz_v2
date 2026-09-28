-- QQT_Warpigz_v3 3.3.2 (live Discord report, current and previous release:
-- "this back and forth happens (not only in pit also in helltides, etc) I
-- think it's Rosie"; video: Pit, elite "Dark Conjurer", ground labels such as
-- "Murmuring Obols"). Two movers took turns on the one native path: Rosie
-- walked to a drop the game would not give it while the farm plugin walked
-- the player back to the fight (Arkham kill_monster once its 15 s pickup
-- yield ran out; HR / Batmobile freeroam after their own bounded holds), each
-- overriding the other every pulse, and a failed round was woken at once so
-- Rosie reclaimed the drop at once. Real Rosie (+ Arkham + Batmobile) in the
-- joint host. Counts direction reversals of the player and alternations of
-- the move issuer (Rosie <-> another plugin) over time.
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
    if passed then print('PASS back-forth: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL back-forth: ' .. name .. ': ' .. tostring(err)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function new(dirs)
    local h = J.new({rosie = true, dirs = dirs or {}, place = 'pit'})
    h.assert_clean('load')
    h.pos = h.v(0, 0)
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(30)
    return h
end
local function busy(h) return h.as(CONSUMER, function() return h.G.LooteerPlugin.is_actively_looting() end) end
-- A Legendary the game never gives the player (bag refuses / ghost).
local function refused(h, x, y)
    return h.drop('pit', x, y, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_009', refuse = function() return true end})
end
-- Watches the player: direction reversals along x (steps > 5 cm) and
-- alternations of the plugin issuing moves (Rosie vs anyone else).
local function watcher(h)
    local w = {rev = 0, alt = 0, last = h.pos:x(), dir = 0, moves = #h.moves, who = nil}
    function w.each(hh)
        local x = hh.pos:x()
        local dx = x - w.last
        if math.abs(dx) > 0.05 then
            local d = dx > 0 and 1 or -1
            if w.dir ~= 0 and d ~= w.dir then w.rev = w.rev + 1 end
            w.dir = d
        end
        w.last = x
        for i = w.moves + 1, #hh.moves do
            local who = hh.moves[i].owner == 'Rosie' and 'Rosie' or 'other'
            if w.who and who ~= w.who then w.alt = w.alt + 1 end
            w.who = who
        end
        w.moves = #hh.moves
    end
    return w
end
local function arkham_pit()
    local h = new({'Batmobile', 'ArkhamAsylum'})
    h.mod('ArkhamAsylum', 'gui').elements.main_toggle:set(true)
    h.run(3) -- Arkham starts exploring
    return h
end

case('B1 Pit, an elite 6 m one way and a drop the game refuses 5 m the other: no tug of war', function()
    local h = arkham_pit()
    local ex = h.pos:x()
    h.actor('pit', 'Dark_Conjurer', ex + 6, h.pos:y(), {enemy = true, elite = true, health = 1e9})
    refused(h, ex - 5, h.pos:y())
    local w = watcher(h)
    h.run(40, w.each)
    print(string.format('  B1 reversals=%d alternations=%d', w.rev, w.alt))
    ok(w.rev <= 4, 'direction reversals in 40 s: ' .. w.rev .. ' (pre-fix: 131)\n' .. h.tail(12))
    ok(w.alt <= 6, 'Rosie/other move alternations in 40 s: ' .. w.alt .. ' (pre-fix: 26)\n' .. h.tail(12))
    h.assert_clean('B1')
end)

case('B2 Pit, a drop that falls 7 m off during an elite fight waits for the fight; taken after it, one trip', function()
    local h = arkham_pit()
    local ex, ey = h.pos:x(), h.pos:y()
    local elite = h.actor('pit', 'Dark_Conjurer', ex + 6, ey, {enemy = true, elite = true, health = 1e9})
    h.run(4) -- Arkham walks to the elite
    elite.t0 = h.now + 0.5
    local item = h.drop('pit', h.pos:x() - 7, ey, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_010'})
    local w = watcher(h)
    local busy_in_fight, pending_in_fight, closest = false, false, math.huge
    h.run(15, function(hh)
        w.each(hh)
        if busy(hh) then busy_in_fight = true end
        if hh.as(CONSUMER, function() return hh.G.LooteerPlugin.has_pending_loot() end) then pending_in_fight = true end
        closest = math.min(closest, hh.pos:dist_to_ignore_z(item.pos))
    end)
    -- QQT_Warpigz_v3 1.0.22: the wait is published as has_pending_loot(); it
    -- still reports busy until the exit guards read it (Pickup.fight_wait_busy).
    eq(busy_in_fight, true, 'pickup stays busy while the drop waits for the fight (transitional)')
    eq(pending_in_fight, true, 'the wait is published (has_pending_loot)')
    eq(h.count(h.moves, function(m) return m.owner == 'Rosie' and m.t > elite.t0 end), 0, 'no Rosie move during the fight')
    ok(closest > 5, 'the player stayed at the fight: closest ' .. string.format('%.1f', closest))
    elite.health = 0
    ok(h.run_until(function() return item.picked == true end, 20, w.each), 'taken after the fight\n' .. h.tail(10))
    ok(w.rev <= 3, 'direction reversals: ' .. w.rev)
end)

case('B3 no enemy: a farm mover that takes the path back after its own 3 s hold is not fought; the drop rests', function()
    local h = new()
    local item = refused(h, 8, 0)
    -- A farm plugin: yields to a busy Looter for at most 3 s per episode,
    -- then walks to its own goal every pulse (HR / Arkham / Batmobile freeroam
    -- shape, shorter hold); its hold re-arms after 2 s without busy.
    local farm = {since = nil, quiet = nil}
    local function farm_pulse(hh)
        local now = hh.now
        if busy(hh) then
            farm.quiet = nil
            farm.since = farm.since or now
            if now - farm.since < 3 then return end
        else
            farm.quiet = farm.quiet or now
            if now - farm.quiet >= 2 then farm.since = nil end
        end
        hh.as(CONSUMER, function() return hh.G.pathfinder.request_move(hh.v(-12, 0)) end)
    end
    local w = watcher(h)
    h.run(40, function(hh) farm_pulse(hh); w.each(hh) end)
    print(string.format('  B3 reversals=%d alternations=%d', w.rev, w.alt))
    ok(w.alt <= 12, 'Rosie/farm move alternations in 40 s: ' .. w.alt .. ' (pre-fix: 87)\n' .. h.tail(12))
    ok(w.rev <= 8, 'direction reversals in 40 s: ' .. w.rev .. ' (pre-fix: 83)\n' .. h.tail(12))
    ok(h.logged('[Rosie pickup] Another move took the player off Helm_Legendary_Generic_009') >= 1, 'the yield is logged')
    ok(item.picked ~= true, 'refused drop stays')
end)

case('B4 a yielded drop is not woken while its yield lasts, is taken once the other mover stops, and yields are bounded', function()
    local h = new()
    local item = h.drop('pit', 8, 0, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_011'})
    local stop_at = h.now + 6
    local rosie_moves_while_foreign, foreign = 0, false
    h.run_until(function() return item.picked == true end, 40, function(hh)
        if hh.now < stop_at then
            foreign = true
            hh.as(CONSUMER, function() return hh.G.pathfinder.request_move(hh.v(-12, 0)) end)
        else foreign = false end
    end)
    ok(item.picked == true, 'taken once the other mover stopped\n' .. h.tail(10))
    local yields = h.logged('[Rosie pickup] Another move took the player off Helm_Legendary_Generic_011')
    ok(yields >= 1 and yields <= 3, 'yield lines: ' .. yields)
    local P = h.mod('Rosie', 'rosie.private.pickup.src.pickup')
    eq(P.limits.yield_rest, 4, 'first yield rest'); eq(P.limits.yield_max, 30, 'yield cap')
end)

case('B5 Murmuring Obols (loot_manager.is_obols) are never a pickup target, even when the host lists them as lootable and the classification accepts them', function()
    -- QQT_Warpigz_v3 1.0.23 (Auditor, test quality): the old B5 drop was an
    -- unrecognized type, refused without the host flag too. This drop is
    -- lootable and classified as an accepted crafting material, so only the
    -- is_obols check keeps Rosie off it; the control twin without the flag is
    -- taken, which proves the classification alone would target it.
    local function obols_drop(h, flagged)
        h.G.loot_manager.is_obols = function(item) return item and item.obols == true end
        h.frame() -- the pickup distance slider (30 m) is read on a pulse
        local obols = h.drop('pit', 6, 0, {rarity = 0, name = 'CraftingMaterial_Obols', display = 'Murmuring Obols'})
        obols.obols = flagged
        local wanted, why = h.as(CONSUMER, function() return h.G.LooteerPlugin.evaluate_item(obols, false) end)
        return obols, wanted, why
    end
    local c = new()
    local twin, twin_wanted, twin_why = obols_drop(c, false)
    eq(twin_wanted, true, 'control: without the obols flag the classification accepts the drop (' .. tostring(twin_why) .. ')')
    ok(c.run_until(function() return twin.picked == true end, 10), 'control: the unflagged twin is taken\n' .. c.tail(6))
    local h = new()
    local obols, wanted, why = obols_drop(h, true)
    eq(wanted, false, 'the obols flag refuses it (' .. tostring(why) .. ')')
    local busy_seen = false
    h.run(10, function(hh) if busy(hh) then busy_seen = true end end)
    eq(busy_seen, false, 'Rosie never busy for obols')
    eq(h.count(h.moves, function(m) return m.owner == 'Rosie' end), 0, 'no Rosie move toward obols')
    eq(h.count(h.interactions, function(i) return i.actor == obols end), 0, 'never interacted with')
end)

case('B6 a drop at the feet during a fight is still interacted with (F6 contract)', function()
    local h = new()
    local item = h.drop('pit', 1, 0, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_012'})
    h.actor('pit', 'Joint_Monster', 7, 0, {enemy = true, health = 1e9})
    ok(h.run_until(function() return item.picked == true end, 5), 'picked at the feet mid-fight\n' .. h.tail(8))
end)

case('B7 a stale far move destination while the player stands at a drop is nobody\'s move: no yield', function()
    local h = new()
    local item = refused(h, 1, 0)
    h.speed = 0
    h.run(1)
    h.goal = h.v(20, 0) -- the host still reports an old destination; the player does not move
    h.run(6)
    eq(h.logged('[Rosie pickup] Another move took the player off'), 0, 'no yield\n' .. h.tail(8))
    ok(#h.interactions > 10, 'kept interacting: ' .. #h.interactions)
    ok(item.picked ~= true)
end)

print(string.format('rosie back-forth 3.3.2: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(#failures .. ' back-and-forth regression(s) failed') end
