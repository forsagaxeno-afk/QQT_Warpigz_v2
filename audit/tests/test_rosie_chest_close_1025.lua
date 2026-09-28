-- QQT_Warpigz_v3 Rosie 1.0.25 (Discord, Rosie 1.0.23 / 3.3.5): chest loot
-- next to the player is not picked up and nothing is logged; after the player
-- walks 2-3 m Rosie goes and loots it; older versions worked
-- (audit/reviews/rosie_close_pickup_2026-09-28.md, seed K1-K8), plus the
-- live Worldstone 'no progress, distance 2.1-2.8' lines
-- (audit/reviews/rosie_navigator_pickup_2026-09-28.md, band S1-S6).
--   K1-K3, C2-C5: the fight hold counts only a real, engaged enemy
--     (HP > 1, targetable, same floor; within 6 m or a player cast in the
--     last 3 s once the host has reported a cast) and says so once.
--   K4, T1-T3: a standing player steps onto a drop in-reach interactions do
--     not take (once per round).
--   K5, K5b, K5c: no false 'Took' for a no-bag drop interacted with from
--     afar; a retry that ends like the first attempt is logged.
--   K6, B2-B6: a drop 2-3 m away the walk brings no closer is interacted with
--     from where the player stands.
--   K7, K8: silent gates are logged once (a busy Scavenger addon, Behavior =
--     Orbwalk outside Clear mode).
--   C6-C12, K5b, K5d (review of the first 1.0.25 build, fd70b6d, where each
--     fails): live the host reports casts, so the engaged rule is the live
--     path; a passive monster no longer blocks the step-in, the Town Portal
--     channel is no cast evidence, an unproven cast reading is named, a mover
--     walking the player to an enemy or an elite within 10 m still holds far
--     drops, a no-bag drop the player cannot get closer to is left after the
--     step-in instead of 3 rounds of busy, and a fight hold does not scan the
--     target list every pulse.
-- Every case except the ones named "control" fails on Rosie 1.0.24, except
-- C11 and C12 (they guard the first 1.0.25 build's regressions; 1.0.24
-- passes them).
-- Review round 3 (second 1.0.25 build, de12a7d): C13 (a stale destination
-- of a player who stopped short of a chest counted as walking toward a
-- passive monster) fails there and on 1.0.24. C11 now asserts the order
-- (no Rosie move before the elite dies), so it fails on fd70b6d whatever ran
-- before it (at a 0.033 s frame C11 can fail on every build, 1.0.24 too:
-- Arkham/Batmobile in the joint host may never reach the elite). The
-- helpers no longer assume the joint
-- host's 0.1 s frame: cast_once holds the cast 0.2 s, busy time is counted
-- with each frame's real step, K6 matches its distance by pattern.
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local checks, failures = 0, {}
local function ok(value, message) if not value then error(message or 'expected a true value', 2) end checks = checks + 1 end
local function eq(a, e, m) if a ~= e then error((m or 'mismatch') .. ': expected ' .. tostring(e) .. ', got ' .. tostring(a), 2) end checks = checks + 1 end
local only = os.getenv('ONLY')
local function case(name, fn)
    if only and not name:find(only, 1, true) then return end
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS chest close 1.0.25: ' .. name)
    else failures[#failures + 1] = name; print('FAIL chest close 1.0.25: ' .. name .. ': ' .. tostring(err):gsub('\nstack traceback:.*', '')) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function new(o)
    o = o or {}
    local h = J.new({rosie = true, dirs = o.dirs or {}, place = 'pit', speed = o.speed})
    h.assert_clean('load')
    h.pos = o.start and h.v(o.start[1], o.start[2]) or h.v(0, 0)
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(15)
    h.run(0.5)
    return h
end
local function helm(i) return {rarity = 5, ga = 3, name = string.format('Helm_Legendary_Generic_%03d', 60 + i)} end
local function prism() return {sno = 2533715, name = 'X2_HoradricCube_TuningStone_2', rarity = 0, display = 'Pragmatic Tuning Prism'} end
local function flat(h, it) return h.pos:dist_to_ignore_z(it.pos) end
-- The game takes a ground drop only within `r` m of the standing player.
local function take_within(r) return function(h, it) return flat(h, it) > r end end
local function picked(list) local n = 0 for _, it in ipairs(list) do if it.picked then n = n + 1 end end return n end
local function rosie_moves(h, t0) return h.count(h.moves, function(m) return m.owner == 'Rosie' and m.t >= t0 end) end
local function status(h) return h.as(CONSUMER, function() return h.G.LooteerPlugin.status() end) end
local function busy(h) return h.as(CONSUMER, function() return h.G.LooteerPlugin.is_actively_looting() end) end
local function lines(h, pred)
    local n = 0
    for _, l in ipairs(h.log) do if pred(l) then n = n + 1 end end
    return n
end
local function fight_lines(h)
    return lines(h, function(l) return l:find('[Rosie pickup]', 1, true) and l:lower():find('fight', 1, true) end)
end
local function spill(h)
    return {h.drop('pit', 0.8, 0, helm(1)), h.drop('pit', -1.6, 0, helm(2)),
        h.drop('pit', 3.4, 1.2, helm(3)), h.drop('pit', 4.1, -1.5, helm(4))} -- 0.8 / 1.6 / 3.6 / 4.4 m
end
-- A rotation cast as the host reports it. The joint host's h.casting is the
-- Town Portal channel (186139), which is no fight evidence (review).
local function rotation(h)
    local player = h.G.get_local_player()
    player.get_active_spell_id = function() if h.casting then return 186139 end return h.spell or -1 end
end
-- The host has reported a player cast once (the engaged rule's evidence),
-- then the player stops casting.
-- Review round 3: held 0.2 s (at least 0.15 s), so Rosie's pulse (at most
-- every 0.05 s) sees it whatever the frame step.
local function cast_once(h) rotation(h); h.spell = 111; h.run(0.2); h.spell = nil; h.frame() end
-- Seconds `pred` held, counted with each frame's real step (review round 3:
-- the counters added 0.1 per frame whatever the frame step).
local function meter(h, pred)
    local m = {s = 0, last = h.now}
    function m.each(hh)
        if pred(hh) then m.s = m.s + (hh.now - m.last) end
        m.last = hh.now
    end
    return m
end
-- An interaction counter on a drop.
local function counted(it)
    local take = it.on_interact
    it.tries, it.try_d = 0, {}
    it.on_interact = function(hh, a) it.tries = it.tries + 1; it.try_d[#it.try_d + 1] = hh.pos:dist_to_ignore_z(it.pos); take(hh, a) end
    return it
end

-- ── 1. The fight hold ──────────────────────────────────────────────────────
case('K1 1-HP listed actor 8 m away: a chest spill at 0.8-4.4 m is all taken within 6 s', function()
    local h = new()
    h.actor('pit', 'S11_BabyBelial_Apparition', -8, 0, {enemy = true, health = 1})
    local t0, items = h.now, spill(h)
    h.run(6)
    eq(picked(items), 4, 'drops taken (1.0.24: the two beyond 3 m wait silently up to 45 s)\n' .. h.tail(6))
    eq(h.logged('A fight kept pickup waiting', t0), 0, 'no fight cap')
    eq(fight_lines(h), 0, 'no fight hold line')
end)
case('K2 untargetable listed actor 8 m away: same', function()
    local h = new()
    local a = h.actor('pit', 'Untargetable_Totem', -8, 0, {enemy = true, health = 100})
    a.is_untargetable = function() return true end
    local items = spill(h)
    h.run(6)
    eq(picked(items), 4, 'drops taken\n' .. h.tail(6))
end)
case('K3 a real fight still holds a far drop (3.3.2 contract) but says so once, and status is honest', function()
    local h = new()
    h.actor('pit', 'Dark_Conjurer', 6, 0, {enemy = true, elite = true, health = 1e9})
    local t0 = h.now
    local d = h.drop('pit', -7, 0, helm(5))
    h.run(3)
    eq(rosie_moves(h, t0), 0, 'no walk out of the fight')
    ok(d.picked ~= true, 'the far drop waits')
    eq(fight_lines(h), 1, 'one line names the fight hold (1.0.24: silent until the 45 s cap)\n' .. h.tail(6))
    eq(h.logged('[Rosie pickup] 1 drop(s) wait for the fight (Dark_Conjurer at 6.0 m)'), 1, 'names the enemy and its distance')
    local s = status(h)
    ok(s.detail ~= 'Picking up accepted items.', 'status is not "Picking up" while nothing moves: ' .. tostring(s.detail))
    ok(tostring(s.detail):find('Waiting for the fight to end (1 drop(s))', 1, true), 'status: ' .. tostring(s.detail))
    h.run(3)
    eq(fight_lines(h), 1, 'still one line in the same episode')
end)
case('C2 a passive monster 9 m away (HP 100, never fought, no cast in 3 s): the spill is all taken', function()
    local h = new()
    cast_once(h)
    h.run(3.5) -- the last cast is more than 3 s old
    h.actor('pit', 'Passive_Ghoul', -9, 0, {enemy = true, health = 100, reach = 0})
    local items = spill(h)
    h.run(6)
    eq(picked(items), 4, 'drops taken (1.0.24: the two beyond 3 m wait up to 45 s)\n' .. h.tail(6))
    eq(fight_lines(h), 0, 'no fight hold line')
end)
case('C3 the same monster while the player casts at it: the hold starts, one line; taken after the fight', function()
    local h = new()
    local m = h.actor('pit', 'Passive_Ghoul', -9, 0, {enemy = true, health = 100, reach = 0})
    rotation(h)
    h.spell = 111
    local items = spill(h)
    h.run(3)
    eq(picked(items), 2, 'the two near drops are taken, the far two wait\n' .. h.tail(6))
    eq(fight_lines(h), 1, 'one fight hold line (1.0.24: silent)\n' .. h.tail(6))
    eq(h.logged('not reported a cast'), 0, 'a proven cast: no fallback note')
    h.spell = nil
    m.health = 0
    ok(h.run_until(function() return picked(items) == 4 end, 5), 'the far drops are taken after the fight\n' .. h.tail(6))
end)
case('C4 an enemy on another floor (2 m across, 8 m up) does not hold the spill', function()
    local h = new()
    local a = h.actor('pit', 'Ledge_Brute', 2, 0, {enemy = true, health = 1e9, reach = 0})
    a.pos = h.v(2, 0, 8)
    local items = spill(h)
    h.run(6)
    eq(picked(items), 4, 'drops taken (1.0.24: held up to 45 s, z ignored)\n' .. h.tail(6))
end)
case('C5 Diagnose names the fight hold for a held drop', function()
    local h = new()
    h.actor('pit', 'Dark_Conjurer', 6, 0, {enemy = true, elite = true, health = 1e9})
    h.drop('pit', -7, 0, helm(5))
    h.run(2)
    local n0 = #h.log
    h.as(CONSUMER, function() return h.G.LooteerPlugin.diagnose() end)
    local held = 0
    for i = n0 + 1, #h.log do
        if h.log[i]:find('[Rosie pickup] Waiting Helm_Legendary_Generic_065', 1, true) and h.log[i]:find('held by the fight hold', 1, true) then held = held + 1 end
    end
    eq(held, 1, 'diagnose prints the held drop as held by the fight hold (1.0.24: "Wanted")\n' .. h.tail(8))
end)

-- ── 1b. The engaged rule on the live path (review of the first 1.0.25 build:
-- live, the host reports casts, so G.cast_seen is true within seconds) ──────
case('C6 K4 beside a passive monster 8 m away (a cast seen, none in 3 s): the step-in still happens', function()
    local h = new()
    cast_once(h)
    h.run(3.5)
    h.actor('pit', 'Passive_Ghoul', -8, 0, {enemy = true, health = 100, reach = 0})
    local f = helm(6); f.refuse = take_within(1.2)
    local t0 = h.now
    local it = h.drop('pit', 1.7, 0, f)
    h.run(4)
    ok(it.picked == true, 'taken (first 1.0.25 build: no step while a passive monster is listed, then "Retrying")\n' .. h.tail(6))
    ok(rosie_moves(h, t0) >= 1, 'stepped closer')
    eq(h.logged('[Rosie pickup] Retrying', t0), 0, 'no failed round')
    eq(fight_lines(h), 0, 'no fight hold')
end)
case('C7 the Town Portal channel is no fight evidence: a channel next to a passive monster starts no hold', function()
    local h = new()
    cast_once(h)
    h.run(3.5)
    h.actor('pit', 'Passive_Ghoul', -8, 0, {enemy = true, health = 100, reach = 0})
    h.casting = true; h.frame(); h.casting = false -- a Town Portal channel (spell 186139)
    local items = spill(h)
    h.run(6)
    eq(picked(items), 4, 'drops taken (first 1.0.25 build: the channel counted as a cast, the far two waited)\n' .. h.tail(6))
    eq(fight_lines(h), 0, 'no fight hold line')
end)
case('C8 no cast reading yet: the 1.0.24 rule holds any enemy within 10 m, and the line says so', function()
    local h = new()
    h.actor('pit', 'Passive_Ghoul', -8, 0, {enemy = true, health = 100, reach = 0})
    local items = spill(h)
    h.run(3)
    eq(picked(items), 2, 'the far two wait\n' .. h.tail(6))
    eq(h.logged('[Rosie pickup] 2 drop(s) wait for the fight (Passive_Ghoul at 8.0 m); the host has not reported a cast yet'), 1,
        'the unproven reading is named (first 1.0.25 build: silent about it)\n' .. h.tail(6))
end)
case('C9 another mover walks the player to a monster 9 m away, no cast yet: the far drop waits, Rosie does not walk off', function()
    local h = new({speed = 1})
    cast_once(h)
    h.run(3.5)
    local m = h.actor('pit', 'Joint_Monster', 9, 0, {enemy = true, health = 1e9, reach = 0})
    local function mover(hh) hh.as(CONSUMER, function() return hh.G.pathfinder.request_move(m.pos) end) end
    -- a farm plugin already walks the player to it. Review round 3: 0.6 s
    -- (0.5 m at speed 1): a destination counts only once the player moves
    -- (0.25 m within 0.8 s), since the host keeps stale destinations (C13)
    h.run(0.6, mover)
    local t0 = h.now
    local d = h.drop('pit', -6, 0, helm(5))
    h.run(1.5, mover)
    eq(rosie_moves(h, t0), 0, 'no walk away from the fight (first 1.0.25 build: Rosie walked 6 m the other way)\n' .. h.tail(6))
    eq(h.logged('drop(s) wait for the fight (Joint_Monster at 8.'), 1, 'the hold names the monster\n' .. h.tail(6))
    ok(d.picked ~= true)
    m.health = 0
    ok(h.run_until(function() return d.picked == true end, 12), 'taken after the fight\n' .. h.tail(6))
end)
case('C10 an elite 9 m away holds a far drop (3.3.2 contract) with no cast in 3 s', function()
    local h = new()
    cast_once(h)
    h.run(3.5)
    h.actor('pit', 'Dark_Conjurer', 9, 0, {enemy = true, elite = true, health = 1e9, reach = 0})
    local t0 = h.now
    local d = h.drop('pit', -7, 0, helm(5))
    h.run(3)
    eq(rosie_moves(h, t0), 0, 'no walk out of an elite fight (first 1.0.25 build: walked to it)\n' .. h.tail(6))
    eq(h.logged('[Rosie pickup] 1 drop(s) wait for the fight (Dark_Conjurer at 9.0 m)'), 1, 'named\n' .. h.tail(6))
    ok(d.picked ~= true)
end)
case('C11 Pit (Arkham + Batmobile), a killable elite 8 m ahead and a drop 5 m behind, no cast in 3 s: the elite dies first, then the drop is taken', function()
    local h = new({dirs = {'Batmobile', 'ArkhamAsylum'}})
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(30)
    cast_once(h)
    h.mod('ArkhamAsylum', 'gui').elements.main_toggle:set(true)
    h.run(3.5)
    local x0, y0 = h.pos:x(), h.pos:y()
    local elite = h.actor('pit', 'Dark_Conjurer', x0 + 8, y0, {enemy = true, elite = true, health = 300})
    local t0 = h.now
    local item = h.drop('pit', x0 - 5, y0, helm(11))
    ok(h.run_until(function() return (elite.health or 0) <= 0 end, 20), 'the elite dies (first 1.0.25 build: never within 30 s)\n' .. h.tail(8))
    -- review round 3: the order itself (first 1.0.25 build: Rosie walked to
    -- the drop and took it at 0.9 s, whatever ran before this case). Counted
    -- as Rosie's moves: Arkham may still carry the player over the drop
    -- (taken at the feet, allowed during a fight)
    eq(rosie_moves(h, t0), 0, 'no Rosie move before the elite died\n' .. h.tail(8))
    ok(h.run_until(function() return item.picked == true end, 20), 'the drop is taken after the fight\n' .. h.tail(8))
end)

case('C12 a fight hold costs no enemy scan per pulse (the calm tail reads the hold\'s last evaluation)', function()
    local h = new()
    h.actor('pit', 'Dark_Conjurer', 6, 0, {enemy = true, elite = true, health = 1e9})
    h.drop('pit', -7, 0, helm(5))
    h.run(1)
    local ts = h.G.target_selector
    local real, n = ts.get_near_target_list, 0
    ts.get_near_target_list = function(...) n = n + 1; return real(...) end
    h.run(5)
    ts.get_near_target_list = real
    ok(n <= 30, string.format('%d target-list scans in 5 s of a fight hold (first 1.0.25 build: 66, one per pulse)', n))
end)
case('C13 a stale destination: the player stopped 2.5 m short of a chest, the host still reports the chest; a passive monster 6.5-7 m away (4 m past it): the spill is all taken, no hold', function()
    -- review round 3 (probe_stale_toward): the 'toward' rule trusted the
    -- destination of a player who no longer moves (test_rosie_back_forth_332 B7)
    for _, mx in ipairs({6.5, 7}) do
        local h = new()
        cast_once(h)
        h.run(3.5) -- the last cast is more than 3 s old
        local player = h.G.get_local_player()
        local chest = h.v(2.5, 0)
        player.get_move_destination = function() return h.goal or chest end -- the host keeps the chest as destination
        h.actor('pit', 'Passive_Ghoul', mx, 0, {enemy = true, health = 100, reach = 0})
        local items = {h.drop('pit', 0.8, 0, helm(1)), h.drop('pit', -1.6, 0, helm(2)),
            h.drop('pit', -3.4, 1.2, helm(3)), h.drop('pit', -4.1, -1.5, helm(4))}
        h.run(6)
        eq(picked(items), 4, string.format('monster at %.1f m: drops taken (second 1.0.25 build: 2/4, "wait for the fight")\n%s', mx, h.tail(6)))
        eq(fight_lines(h), 0, 'no fight hold line')
    end
end)

-- ── 2. Standing next to a drop the game does not take from there ───────────
case('K4 a helm 1.7 m from a standing player (game take radius 1.2 m) is taken within 4 s', function()
    local h = new()
    local f = helm(6); f.refuse = take_within(1.2)
    local t0 = h.now
    local it = h.drop('pit', 1.7, 0, f)
    h.run(4)
    ok(it.picked == true, 'taken (1.0.24: interacts from 1.7 m until the round fails, 0 moves)\n' .. h.tail(6))
    ok(rosie_moves(h, t0) >= 1, 'Rosie stepped closer')
    eq(h.logged('[Rosie pickup] Retrying', t0), 0, 'no failed round')
    eq(h.logged('interactions are not taking it; stepping closer', t0), 1, 'logged once')
end)
case('T1 control: a helm 0.8 m away is taken with no move', function()
    local h = new()
    local t0 = h.now
    local it = h.drop('pit', 0.8, 0, helm(7))
    h.run(2)
    ok(it.picked == true, 'taken\n' .. h.tail(6))
    eq(rosie_moves(h, t0), 0, 'no move')
end)
case('T2 the step-in is bounded: a helm the game never takes gets at most one step per round and the rounds still end it', function()
    local h = new()
    local f = helm(8); f.refuse = function() return true end
    local t0 = h.now
    local it = h.drop('pit', 1.7, 0, f)
    ok(h.run_until(function() return h.logged('[Rosie pickup] Gave up on Helm_Legendary_Generic_068', t0) > 0 end, 40),
        'three rounds, then given up (C6)\n' .. h.tail(8))
    local steps = rosie_moves(h, t0)
    ok(steps >= 1 and steps <= 3, 'Rosie moves (one step per round at most; 1.0.24: none): ' .. steps)
    eq(h.logged('stepping closer', t0), 1, 'one line per drop')
    ok(it.picked ~= true)
end)
case('T3 no step-in during a fight; after it the step is taken', function()
    local h = new()
    local e = h.actor('pit', 'Joint_Monster', -7, 0, {enemy = true, health = 1e9, reach = 0})
    local f = helm(9); f.refuse = take_within(1.2)
    local t0 = h.now
    local it = h.drop('pit', 1.7, 0, f)
    h.run(3)
    eq(rosie_moves(h, t0), 0, 'no step while an enemy is near (interactions are not CLEAR)')
    e.health = 0
    ok(h.run_until(function() return it.picked == true end, 4), 'taken after the fight (1.0.24: never)\n' .. h.tail(6))
end)
case('K5 a no-bag material 1.7 m away that the game has not taken is not logged "Took"', function()
    local h = new()
    local f = prism(); f.refuse = take_within(1.2)
    local it = h.drop('pit', 1.7, 0, f)
    local t0 = h.now
    h.run(6)
    eq(h.logged('[Rosie pickup] Took Pragmatic Tuning Prism', t0), 0, 'no false Took (1.0.24: after 3.5 s)\n' .. h.tail(6))
    ok(it.picked == true, 'taken\n' .. h.tail(6))
end)
case('K5b a no-bag material the player cannot get closer to (body-blocked): no "Took"; left once after the step-in, busy bounded', function()
    local h = new()
    h.speed = 0 -- Rosie's step is executed but the player does not move
    local f = prism(); f.refuse = take_within(1.2)
    local it = h.drop('pit', 1.7, 0, f)
    local t0 = h.now
    local bm = meter(h, busy)
    h.run(10, bm.each)
    local busy_s = bm.s
    eq(h.logged('[Rosie pickup] Took Pragmatic Tuning Prism', t0), 0, 'no false Took (1.0.24: after 3.5 s)\n' .. h.tail(6))
    eq(h.logged('[Rosie pickup] Leaving Pragmatic Tuning Prism: still listed after', t0), 1,
        'left with the no-bag wording once the step-in did not bring the player closer\n' .. h.tail(6))
    ok(h.logged('(no bag to confirm it was taken)', t0) == 1, 'says why')
    eq(h.logged('[Rosie pickup] Retrying', t0), 0, 'no rounds of busy (first 1.0.25 build: 3 rounds)')
    ok(busy_s <= 5, string.format('busy %.1f s', busy_s))
    ok(it.picked ~= true)
end)
case('K5d a no-bag ghost (taken into Materials, still listed) 1.7 m from a body-blocked player: busy about as short as 1.0.24, one line', function()
    local h = new()
    h.speed = 0
    local g = h.drop('pit', 1.7, 0, prism())
    g.on_interact = function() g.tries = (g.tries or 0) + 1 end -- the game took it; the host still lists it
    local t0 = h.now
    local bm = meter(h, busy)
    h.run(30, bm.each)
    local busy_s = bm.s
    ok(busy_s <= 5, string.format('busy %.1f s in 30 s (first 1.0.25 build: about 26 s over 3 rounds and the episode cap)', busy_s))
    eq(lines(h, function(l) return l:find('[Rosie pickup]', 1, true) and l:find('Pragmatic Tuning Prism', 1, true)
        and (l:find('Took', 1, true) or l:find('Leaving', 1, true)) end), 1, 'one line\n' .. h.tail(6))
    eq(h.logged('[Rosie pickup] Took Pragmatic Tuning Prism', t0), 0, 'no Took without the proof')
    ok((g.tries or 0) <= 40, 'interactions ' .. tostring(g.tries))
end)
case('K5c a no-bag ghost whose one retry ends like the first attempt: one line for the retry', function()
    local h = new()
    local g = h.drop('pit', 1, 0, prism())
    g.on_interact = function() g.tries = (g.tries or 0) + 1 end -- taken into Materials, still listed
    h.run(6)
    eq(h.logged('[Rosie pickup] Took Pragmatic Tuning Prism'), 1, 'the ghost settles once\n' .. h.tail(6))
    local home = h.pos
    h.pos = h.v(home:x() - 8, home:y()); h.run(3); h.pos = home -- the player's route leaves and comes back
    h.run(8)
    eq(h.logged('[Rosie pickup] Took Pragmatic Tuning Prism'), 1, 'still one Took line')
    eq(h.logged('[Rosie pickup] Second attempt at Pragmatic Tuning Prism ended like the first (taken)'), 1,
        'the retry is logged (1.0.24: silent)\n' .. h.tail(6))
end)

-- ── 3. The walk-only band: 2-3 m, the player gets no closer ─────────────────
case('K6 a drop on a prop 2.6 m from its edge, game takes within 3.0 m: interacted with and taken', function()
    local h = new()
    h.place.walls = {{0.5, 4.5, -2.0, 2.0}}
    local f = helm(7); f.refuse = take_within(3.0)
    local t0 = h.now
    local it = h.drop('pit', 2.6, 0, f)
    h.run(10)
    ok(it.picked == true, 'taken (1.0.24: 0 interactions beyond 2 m, then a failed round / Leaving)\n' .. h.tail(6))
    eq(h.logged('no progress toward it', t0), 0, 'no stall line')
    -- review round 3: matched by pattern (at a 0.033 s frame the player stops at 2.1 m, not 2.6 m)
    eq(lines(h, function(l) return l:find('%[Rosie pickup%] Interacting with Helm_Legendary_Generic_067 from %d%.%d m %(the player gets no closer%)') end),
        1, 'logged once\n' .. h.tail(6))
end)
-- A drop at (8,0) inside a box the player cannot enter: at speed 4 the
-- player stops at x=5.2, 2.8 m from it.
local function boxed(h, item, reach)
    h.place.walls = {{5.5, 10.5, -2.5, 2.5}}
    item.refuse = take_within(reach or 3.0)
    return counted(h.drop('pit', 8, 0, item))
end
case('B2 a prism on a prop (the player stops 2.8 m away): taken, never "Leaving"', function()
    local h = new({speed = 4})
    local it = boxed(h, prism())
    local t0 = h.now
    local bm = meter(h, busy)
    h.run(10, bm.each)
    local busy_s = bm.s
    ok(it.picked == true, 'taken (1.0.24: "Leaving ... cannot reach it (no progress, distance 2.8)")\n' .. h.tail(6))
    eq(h.logged('[Rosie pickup] Leaving', t0), 0, 'never left')
    ok(busy_s <= 2.5 + 1e-6, string.format('busy %.1f s (review S1: <= 2.5 s)', busy_s))
end)
case('B3 control: a prism on a prop the game takes only within 2 m: exactly one "Leaving" line, busy and interactions bounded', function()
    local h = new({speed = 4})
    local it = boxed(h, prism(), 2.0)
    local t0 = h.now
    local bm = meter(h, busy)
    h.run(20, bm.each)
    local busy_s = bm.s
    eq(h.logged('[Rosie pickup] Leaving Pragmatic Tuning Prism: cannot reach it', t0), 1, 'one Leaving line\n' .. h.tail(6))
    ok(busy_s <= 8.5, string.format('busy %.1f s', busy_s))
    ok(it.tries <= 15, 'interactions ' .. it.tries)
    ok(it.picked ~= true)
end)
case('B4 control: on open ground every interaction happens within 2 m', function()
    local h = new({speed = 4})
    local it = counted(h.drop('pit', 8, 0, helm(10)))
    h.run(6)
    ok(it.picked == true, 'taken\n' .. h.tail(6))
    for i, d in ipairs(it.try_d) do ok(d <= 2.0 + 1e-6, string.format('interaction %d from %.2f m', i, d)) end
end)
case('B5 Worldstone stand-in: a band drop holds Navigator at most 2.5 s (1.0.24: the whole 6 s stall)', function()
    local h = new({speed = 4, start = {4, 0}})
    local conds = {}
    h.G.Navigator = {set_pause_condition = function(name, fn) conds[name] = fn end,
        get_status = function() return {state = 'idle', is_busy = false, is_paused = false} end}
    h.G.Navigator.set_pause_condition('Worldstone Looting', function()
        local sc = rawget(h.G, 'Scavenger'); return type(sc) == 'table' and sc.is_busy() == true
    end)
    h.G.Worldstone = {get_status = function() return {} end}
    h.run(4)
    ok(h.G.Scavenger and h.G.Scavenger._rosie == true, 'stand-in published')
    local it = boxed(h, prism())
    local pm = meter(h, function()
        local p = false
        for _, fn in pairs(conds) do local okc, on = pcall(fn); if okc and on == true then p = true end end
        return p
    end)
    h.run(12, pm.each)
    local paused = pm.s
    ok(it.picked == true, 'taken\n' .. h.tail(6))
    -- review round 3: + 0.15 s, the phase of Rosie's 0.05 s pulses against a
    -- finer frame (2.6 s at 0.05 / 0.033 s frames, counted with the real step)
    ok(paused <= 2.5 + 0.15, string.format('Navigator paused %.2f s (review S5: <= 2.5 s + 0.15 s pulse phase)', paused))
end)
case('B6 an enemy that never dies 6 m away: a band drop is taken, no "Retrying" rounds', function()
    local h = new({speed = 4, start = {5.2, 0}})
    h.actor('pit', 'Joint_Monster', 5.2, 6, {enemy = true, health = 1e9, reach = 0})
    local it = boxed(h, prism())
    local t0 = h.now
    h.run(10)
    ok(it.picked == true, 'taken (1.0.24: no progress rounds while the fight lasts)\n' .. h.tail(6))
    eq(h.logged('[Rosie pickup] Retrying', t0), 0, 'no failed round')
end)

-- ── 4. Silent gates ────────────────────────────────────────────────────────
case('K7 a busy third-party Scavenger holding a drop at the feet is logged once and named in status', function()
    local h = new()
    h.G.Scavenger = {is_busy = function() return true end, pause = function() return true end, resume = function() return true end}
    h.drop('pit', 1.0, 0.5, helm(8))
    h.run(3)
    eq(lines(h, function(l) return l:find('[Rosie', 1, true) and l:find('Scavenger', 1, true) end), 1, 'one hand-over line (1.0.24: silent)\n' .. h.tail(6))
    local s = status(h)
    ok(not tostring(s.detail):find('Tristram', 1, true), 'status names Scavenger, not Tristram: ' .. tostring(s.detail))
    ok(tostring(s.detail):find('Scavenger', 1, true), 'status: ' .. tostring(s.detail))
end)
case('K8 Behavior=Orbwalk outside Clear mode with a wanted drop in range: one line; in Clear mode it is taken', function()
    local h = new()
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.behavior_combo:set(1)
    h.orb.mode = 0
    local it = h.drop('pit', 1.0, 0, helm(9))
    h.run(3)
    eq(lines(h, function(l) return l:find('[Rosie pickup]', 1, true) and l:find('Clear', 1, true) end), 1,
        'one "Waiting for orbwalker Clear mode" line (1.0.24: silent)\n' .. h.tail(6))
    ok(it.picked ~= true, 'not taken outside Clear mode')
    h.orb.mode = h.G.orb_mode and h.G.orb_mode.clear or 3
    ok(h.run_until(function() return it.picked == true end, 3), 'taken in Clear mode\n' .. h.tail(6))
end)

print(string.format('rosie chest close 1.0.25: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(#failures .. ' chest-close case(s) failed: ' .. table.concat(failures, ' | ')) end
