-- QQT_Warpigz_v3 Rosie 1.0.22 (Auditor MED, confirmed by two skeptics): a
-- drop Rosie yielded to another mover (3.3.2 yield_until) stayed blocked
-- even when that mover walked the player right over it: Pickup.blocked() was
-- true for the whole yield, item_manager treated the drop as not wanted and
-- the in-reach interaction never happened. Worldstone/Navigator walking a
-- route with a drop on it: yield 1, the player passes the drop, yield 2 when
-- Rosie tried to walk back, drop lost. Now the yield holds walks only; a
-- yielded drop within reach is interacted with (no move, no tug of war).
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
    if passed then print('PASS yield reach: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL yield reach: ' .. name .. ': ' .. tostring(err)) end
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
-- Another mover (Navigator for Worldstone, a farm route) re-issues its move
-- toward a far goal every pulse; the drop lies on its route.
local function route(h, item, seconds)
    local r = {first_yield = nil, rosie_moves_after_yield = 0, reversals = 0, picked_at = nil, picked_x = nil}
    local last_x, moves = h.pos:x(), #h.moves
    h.run(seconds, function(hh)
        hh.as(CONSUMER, function() return hh.G.pathfinder.request_move(hh.v(200, 0)) end)
        if not r.first_yield and hh.logged('[Rosie pickup] Another move took the player off') > 0 then r.first_yield = hh.now end
        for i = moves + 1, #hh.moves do
            if r.first_yield and hh.moves[i].owner == 'Rosie' then r.rosie_moves_after_yield = r.rosie_moves_after_yield + 1 end
        end
        moves = #hh.moves
        if hh.pos:x() < last_x - 0.05 then r.reversals = r.reversals + 1 end
        last_x = hh.pos:x()
        if item.picked and not r.picked_at then r.picked_at, r.picked_x = hh.now, hh.pos:x() end
    end)
    return r
end

case('Y1 a mover walks the player over a yielded drop on its route (pickup distance 30): taken in reach, no walk back', function()
    local h = new()
    local item = h.drop('pit', 15, 0, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_013'})
    local r = route(h, item, 30)
    print(string.format('  Y1: picked=%s at x=%s, yields=%d, Rosie moves after the yield=%d, reversals=%d',
        tostring(item.picked), r.picked_x and string.format('%.1f', r.picked_x) or '-',
        h.logged('[Rosie pickup] Another move took the player off'), r.rosie_moves_after_yield, r.reversals))
    ok(r.first_yield, 'Rosie first yielded to the other mover (3.3.2)\n' .. h.tail(10))
    eq(item.picked, true, 'the drop was taken as the player passed over it (1.0.21: yield 1, yield 2, lost)\n' .. h.tail(10))
    ok(math.abs(r.picked_x - 15) <= 2.5, 'taken in reach of the drop: x=' .. string.format('%.1f', r.picked_x))
    eq(r.rosie_moves_after_yield, 0, 'the yield still holds walks: no Rosie move after it')
    eq(r.reversals, 0, 'the player never walked back')
    eq(h.logged('[Rosie pickup] Another move took the player off'), 1, 'one yield')
    ok(h.pos:x() > 150, 'the other mover kept its route: x=' .. string.format('%.1f', h.pos:x()))
    h.assert_clean('Y1')
end)

-- QQT_Warpigz_v3 1.0.22 (review): Y1 took its drop on the 1st interaction.
-- A drop the game takes only on its Nth interaction needs the whole pass:
-- foreign_move kept counting the mover while Rosie stood on the drop and
-- interacted, a second yield came 0.3 s in (HEAD: 'yield 2'; with
-- YIELD.per_round=2: a failed round, the drop rests 8 s mid-pass and is lost).
for _, n in ipairs({2, 3}) do
    case('Y1.' .. n .. ' the same pass with a drop taken on its interaction ' .. n .. ': one yield, no failed round, taken', function()
        local h = new()
        local tries = 0
        local item = h.drop('pit', 15, 0, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_015', bag = 'sink',
            refuse = function() tries = tries + 1; return tries < n end})
        local r = route(h, item, 30)
        print(string.format('  Y1.%d: picked=%s at x=%s, interactions=%d, yields=%d, failed rounds=%d', n, tostring(item.picked),
            r.picked_x and string.format('%.1f', r.picked_x) or '-', tries,
            h.logged('[Rosie pickup] Another move took the player off'), h.logged('failed (')))
        ok(r.first_yield, 'yielded first\n' .. h.tail(10))
        eq(h.logged('[Rosie pickup] Another move took the player off'), 1, 'one yield: none while Rosie stands on the drop\n' .. h.tail(10))
        eq(h.logged('failed ('), 0, 'no round failed mid-pass\n' .. h.tail(10))
        eq(item.picked, true, 'taken on its interaction ' .. n .. ' as the player passed over it\n' .. h.tail(10))
        ok(math.abs(r.picked_x - 15) <= 2.5, 'taken in reach: x=' .. string.format('%.1f', r.picked_x))
        eq(r.rosie_moves_after_yield, 0, 'no Rosie move after the yield')
        eq(r.reversals, 0, 'the player never walked back')
        h.assert_clean('Y1.' .. n)
    end)
end

case('Y2 a yielded drop off the route is not walked to while the yield lasts (the 3.3.2 walk hold stays)', function()
    local h = new()
    local item = h.drop('pit', 12, 6, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_014'})
    local r = route(h, item, 3.8) -- the first yield rests 4 s
    ok(r.first_yield, 'yielded\n' .. h.tail(10))
    eq(r.rosie_moves_after_yield, 0, 'no Rosie move while yielded and out of reach')
    ok(item.picked ~= true, 'never in reach: not taken')
    eq(r.reversals, 0, 'no back and forth')
    local Pickup = h.mod('Rosie', 'rosie.private.pickup.src.pickup')
    eq((Pickup.blocked(item)), true, 'blocked out of reach while yielded')
    h.assert_clean('Y2')
end)

print(string.format('rosie yield reach 1.0.22: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
