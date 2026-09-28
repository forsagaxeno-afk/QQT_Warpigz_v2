-- SEED for the Rosie session (proposed audit/tests/test_rosie_chest_close_1024.lua).
-- Discord report on Rosie 1.0.23 / 3.3.5: chest loot next to the player is
-- not picked up; after the player walks 2-3 m Rosie goes and loots it;
-- nothing in the log; older versions worked. Every case must FAIL on
-- 8bb81bd and pass once its fix lands.
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local checks, failures = 0, {}
local function ok(value, message) if not value then error(message or 'expected a true value', 2) end checks = checks + 1 end
local function eq(a, e, m) if a ~= e then error((m or 'mismatch') .. ': expected ' .. tostring(e) .. ', got ' .. tostring(a), 2) end checks = checks + 1 end
local only = os.getenv('ONLY')
local function case(name, fn)
    if only and not name:find(only, 1, true) then return end
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS chest close: ' .. name)
    else failures[#failures + 1] = name; print('FAIL chest close: ' .. name .. ': ' .. tostring(err):gsub('\nstack traceback:.*', '')) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function new()
    local h = J.new({rosie = true, dirs = {}, place = 'pit'})
    h.assert_clean('load')
    h.pos = h.v(0, 0)
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(15)
    h.run(0.5)
    return h
end
local function helm(i) return {rarity = 5, ga = 3, name = string.format('Helm_Legendary_Generic_%03d', 60 + i)} end
local function flat(h, it) return h.pos:dist_to_ignore_z(it.pos) end
-- The game takes a ground drop only within `r` m of the standing player.
local function take_within(r) return function(h, it) return flat(h, it) > r end end
local function picked(list) local n = 0 for _, it in ipairs(list) do if it.picked then n = n + 1 end end return n end
local function rosie_moves(h, t0) return h.count(h.moves, function(m) return m.owner == 'Rosie' and m.t >= t0 end) end
local function status(h) return h.as(CONSUMER, function() return h.G.LooteerPlugin.status() end) end
local function spill(h)
    return {h.drop('pit', 0.8, 0, helm(1)), h.drop('pit', -1.6, 0, helm(2)),
        h.drop('pit', 3.4, 1.2, helm(3)), h.drop('pit', 4.1, -1.5, helm(4))} -- 0.8 / 1.6 / 3.6 / 4.4 m
end

-- 1. FIGHT hold (3.3.2): a listed actor the rotation never fights.
case('K1 1-HP listed actor 8 m away: a chest spill at 0.8-4.4 m is all taken within 6 s', function()
    local h = new()
    h.actor('pit', 'S11_BabyBelial_Apparition', -8, 0, {enemy = true, health = 1})
    local t0, items = h.now, spill(h)
    h.run(6)
    eq(picked(items), 4, 'drops taken (8bb81bd: the two beyond 3 m wait silently up to 45 s)\n' .. h.tail(6))
    eq(h.logged('A fight kept pickup waiting', t0), 0, 'no fight cap')
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
    local lines = 0
    for _, l in ipairs(h.log) do if l:find('[Rosie pickup]', 1, true) and l:lower():find('fight', 1, true) then lines = lines + 1 end end
    eq(lines, 1, 'one line names the fight hold (8bb81bd: silent until the 45 s cap)\n' .. h.tail(6))
    ok(status(h).detail ~= 'Picking up accepted items.', 'status is not "Picking up" while nothing moves: ' .. tostring(status(h).detail))
end)

-- 2. In-reach standstill: the game takes only within 1.2 m of a standing player.
case('K4 a helm 1.7 m from a standing player (game take radius 1.2 m) is taken within 4 s', function()
    local h = new()
    local f = helm(6); f.refuse = take_within(1.2)
    local t0 = h.now
    local it = h.drop('pit', 1.7, 0, f)
    h.run(4)
    ok(it.picked == true, 'taken (8bb81bd: interacts from 1.7 m forever, 0 moves)\n' .. h.tail(6))
    ok(rosie_moves(h, t0) >= 1, 'Rosie stepped closer')
    eq(h.logged('[Rosie pickup] Retrying', t0), 0, 'no failed round')
end)
case('K5 a no-bag material 1.7 m away that the game has not taken is not logged "Took"', function()
    local h = new()
    local it = h.drop('pit', 1.7, 0, {sno = 2533715, name = 'X2_HoradricCube_TuningStone_2', rarity = 0,
        display = 'Pragmatic Tuning Prism', refuse = take_within(1.2)})
    local t0 = h.now
    h.run(6)
    eq(h.logged('[Rosie pickup] Took Pragmatic Tuning Prism', t0), 0, 'no false Took (8bb81bd: after 3.5 s)\n' .. h.tail(6))
    ok(it.picked == true, 'taken\n' .. h.tail(6))
end)

-- 3. Walk-only band: a drop on a prop, the player stops 2.1-2.8 m away.
case('K6 a drop on a prop 2.6 m from its edge, game takes within 3.0 m: interacted with and taken', function()
    local h = new()
    h.place.walls = {{0.5, 4.5, -2.0, 2.0}}
    local f = helm(7); f.refuse = take_within(3.0)
    local t0 = h.now
    local it = h.drop('pit', 2.6, 0, f)
    h.run(10)
    ok(it.picked == true, 'taken (8bb81bd: 0 interactions beyond 2 m, then a failed round / Leaving)\n' .. h.tail(6))
    eq(h.logged('no progress toward it', t0), 0, 'no stall line')
end)

-- 4. Silent gates.
case('K7 a busy third-party Scavenger holding a drop at the feet is logged once and named in status', function()
    local h = new()
    h.G.Scavenger = {is_busy = function() return true end, pause = function() return true end, resume = function() return true end}
    local t0 = h.now
    h.drop('pit', 1.0, 0.5, helm(8))
    h.run(3)
    local n = 0
    for _, l in ipairs(h.log) do if l:find('[Rosie', 1, true) and l:find('Scavenger', 1, true) then n = n + 1 end end
    eq(n, 1, 'one hand-over line (8bb81bd: silent)\n' .. h.tail(6))
    ok(not tostring(status(h).detail):find('Tristram', 1, true), 'status names Scavenger, not Tristram: ' .. tostring(status(h).detail))
end)
case('K8 Behavior=Orbwalk outside Clear mode with a wanted drop in range: one line', function()
    local h = new()
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.behavior_combo:set(1)
    h.orb.mode = 0
    local t0 = h.now
    h.drop('pit', 1.0, 0, helm(9))
    h.run(3)
    local n = 0
    for _, l in ipairs(h.log) do if l:find('[Rosie pickup]', 1, true) and l:find('Clear', 1, true) then n = n + 1 end end
    eq(n, 1, 'one "waiting for orbwalker Clear mode" line (8bb81bd: silent)\n' .. h.tail(6))
end)

print(string.format('rosie chest close: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(#failures .. ' chest-close case(s) failed: ' .. table.concat(failures, ' | ')) end
