-- QQT_Warpigz_v3 3.1.0-rc.2 (Q1, live 2026-09-27): Rosie "ghost" pickups.
-- Live: "[Rosie pickup] Retrying {icon:Cube_TooltipIcon, 2} Protector's
-- Tuning Prism: round 1/3 failed (no progress toward it, distance 9.6)" ...
-- round 3/3 at 14.7, then "[HELLTIDE] Resumed after 33.6s yield". The prism
-- (X2_HoradricCube_TuningStone_2, Horadric Cube material) was taken on the
-- first interaction (it goes to Materials, never to a bag) but the host kept
-- listing the ground actor. Rosie had no receipt: only the actor leaving
-- actors_manager.get_all_items ended a drop, so a ghost got 3 rounds (90
-- interactions or 3 x 6 s stall windows) of busy, again after every time it
-- streamed out of the list and back, and HR / activity loot holds waited.
-- Each case runs with the REAL Rosie in the joint host, standalone.
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
    if passed then print('PASS ghost-pickup: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL ghost-pickup: ' .. name .. ': ' .. tostring(err)) end
end
local last_busy -- Q1-11 episode view
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function new(opts)
    opts = opts or {}
    opts.rosie = true
    opts.dirs = opts.dirs or {}
    opts.place = opts.place or 'pit'
    local h = J.new(opts)
    h.assert_clean('load')
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(15)
    return h
end
local function busy(h) return h.as(CONSUMER, function() return h.G.LooteerPlugin.is_actively_looting() end) end
-- Busy seconds (total, longest continuous) and interactions with `g` over `seconds`.
local function measure(h, g, seconds, dt)
    local total, longest, since = 0, 0, nil
    local tries0 = g.tries or 0
    h.run(seconds, function()
        if busy(h) then
            total = total + 0.1; since = since or h.now
            if h.now - since > longest then longest = h.now - since end
        else since = nil end
    end)
    return total, longest, (g.tries or 0) - tries0
end
local PRISM = {sno = 2533715, name = 'X2_HoradricCube_TuningStone_2', rarity = 0,
    display = "{icon:Cube_TooltipIcon, 2} Protector's Tuning Prism"}
local RUNE = {sno = 2155997, name = 'Rune_Condition_Summons', rarity = 0, display = 'Rune of Summons'}
local function fields(t) local f = {}; for k, v in pairs(t) do f[k] = v end; return f end
-- A ground actor the host keeps listing. mode 'materials': the first
-- interaction takes it into Materials (no bag gains it); 'bag': the first
-- interaction puts a copy into `bag` (a list); 'refused': nothing happens.
local function ghost(h, place, x, y, template, mode, bag)
    local g = h.drop(place, x, y, fields(template))
    g.on_interact = function()
        g.tries = (g.tries or 0) + 1
        if g.taken or mode == 'refused' then return end
        g.taken = true
        h.materials = (h.materials or 0) + (mode == 'materials' and 1 or 0)
        if mode == 'bag' then bag[#bag + 1] = h.gear(fields(template)) end
    end
    return g
end
local function no_round_logs(h, why)
    eq(h.logged('[Rosie pickup] Retrying'), 0, why .. ': no retry rounds\n' .. h.tail(20))
    eq(h.logged('[Rosie pickup] Gave up on'), 0, why .. ': no 3-round give-up')
end

case('Q1-1 a Tuning Prism taken on the first interaction but still listed is settled after 3.5 s of clear reach, logged once', function()
    local h = new()
    local g = ghost(h, 'pit', h.pos:x() + 1, h.pos:y(), PRISM, 'materials')
    local total, longest, tries = measure(h, g, 30)
    ok(g.taken, 'the first interaction took it')
    -- QQT_Warpigz_v3 (Q1 review): 3.5 s of clear time in reach (a 3 s cast the host does not report is survived).
    ok(tries >= 1 and tries <= 25, 'interactions with the ghost: ' .. tries .. ' (HEAD: 90)')
    ok(longest <= 4.5, string.format('longest continuous busy %.1fs (HEAD: 17.8 s)', longest))
    eq(h.logged("[Rosie pickup] Took {icon:Cube_TooltipIcon, 2} Protector's Tuning Prism"), 1, 'one line\n' .. h.tail(20))
    no_round_logs(h, 'Q1-1')
    -- Pickup keeps working: a real drop next to it is taken.
    local before = h.pickups or 0
    h.drop('pit', h.pos:x() - 1, h.pos:y(), {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_009'})
    ok(h.run_until(function() return (h.pickups or 0) > before end, 10), 'a takeable drop is still picked up')
    h.assert_clean('Q1-1')
end)

case('Q1-2 a settled ghost that streams out of the actor list and back in is not tried again', function()
    local h = new()
    local g = ghost(h, 'pit', h.pos:x() + 1, h.pos:y(), PRISM, 'materials')
    measure(h, g, 10)
    for i = #h.place.items, 1, -1 do if h.place.items[i] == g then table.remove(h.place.items, i) end end
    h.run(5) -- the player farmed elsewhere; the actor left the list
    h.place.items[#h.place.items + 1] = g -- same identifier, same spot
    local total, _, tries = measure(h, g, 30)
    eq(tries, 0, 'no interaction on the second visit (HEAD: 90)')
    ok(total <= 0.3, string.format('busy %.1fs on the second visit (HEAD: 17.9 s)', total))
    eq(h.logged('[Rosie pickup] Took'), 1, 'still one line')
end)

case('Q1-3 a ghost the player cannot approach is left after one stall window, logged once (live: 9.6 m)', function()
    local h = new()
    local b = h.place.box
    h.pos = h.v(b[2] - 4.6, 0)
    local g = ghost(h, 'pit', b[2] + 5, 0, PRISM, 'materials') -- listed 9.6 m away, off the walkable area
    g.taken = true
    local total, longest = measure(h, g, 40)
    ok(total <= 7.0, string.format('busy %.1fs (one 6 s stall window; HEAD: 18.8 s)', total))
    eq(h.logged("[Rosie pickup] Leaving {icon:Cube_TooltipIcon, 2} Protector's Tuning Prism: cannot reach it"), 1,
        'one line\n' .. h.tail(20))
    no_round_logs(h, 'Q1-3')
    eq(busy(h), false, 'not busy afterwards')
    local s = h.as(CONSUMER, function() return h.G.RosiePlugin.status() end)
    eq(s.movement.owner, nil, 'pickup released movement')
end)

case('Q1-4 a gear ghost is settled by the bag receipt (the bag gained its SNO)', function()
    local h = new()
    h.inventory = {}
    local g = ghost(h, 'pit', h.pos:x() + 1, h.pos:y(), {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_001',
        sno = 990001234}, 'bag', h.inventory)
    local _, longest, tries = measure(h, g, 30)
    ok(tries >= 1 and tries <= 3, 'interactions with the gear ghost: ' .. tries .. ' (HEAD: 90)')
    ok(longest <= 2.0, string.format('longest continuous busy %.1fs', longest))
    eq(h.logged('[Rosie pickup] Took Helm_Legendary_Generic_001 (now in the equipment bag'), 1, 'one line\n' .. h.tail(20))
    no_round_logs(h, 'Q1-4')
end)

case('Q1-5 a small stackable the game refuses (no receipt, same spot) is left after one full round of clear interactions', function()
    local h = new()
    local g = ghost(h, 'pit', h.pos:x() + 1, h.pos:y(), RUNE, 'refused')
    local total, longest, tries = measure(h, g, 40)
    ok(tries >= 28 and tries <= 31, 'interactions: ' .. tries .. ' (HEAD: 90)') -- QQT_Warpigz_v3 (Q1 review): one round
    ok(longest <= 7.0, string.format('longest continuous busy %.1fs (HEAD: 17.8 s)', longest))
    eq(h.logged('[Rosie pickup] Leaving Rune of Summons: still on the ground after 30 interactions'), 1,
        'one line\n' .. h.tail(20))
    no_round_logs(h, 'Q1-5')
end)

case('Q1-6 a small stackable whose bag gains it is settled by the receipt', function()
    local h = new()
    local sockets = {}
    local player = h.G.get_local_player()
    player.get_socketable_items = function() return sockets end
    local g = ghost(h, 'pit', h.pos:x() + 1, h.pos:y(), RUNE, 'bag', sockets)
    local _, longest, tries = measure(h, g, 20)
    ok(tries >= 1 and tries <= 3, 'interactions: ' .. tries)
    ok(longest <= 2.0, string.format('longest continuous busy %.1fs', longest))
    eq(h.logged('[Rosie pickup] Took Rune of Summons (now in the socketable bag'), 1, 'one line\n' .. h.tail(20))
end)

case('Q1-7 standalone Helltide (HR + Batmobile + Rosie): a ghost prism never makes HR yield', function()
    local h = new({dirs = {'Batmobile', 'HelltideRevamped'}, place = 'helltide'})
    h.P.helltide.helltide = true
    h.mod('HelltideRevamped', 'gui').elements.main_toggle:set(true)
    h.run(8)
    local g = ghost(h, 'helltide', h.pos:x() + 1, h.pos:y() + 1, PRISM, 'materials')
    local _, longest = measure(h, g, 60)
    ok(longest <= 4.5, string.format('Rosie busy %.1fs (HEAD: 20.0 s)', longest)) -- QQT_Warpigz_v3 (Q1 review)
    eq(h.logged('Looter busy 15s without progress'), 0, 'HR never hit its Looter cap (HEAD: 1)\n' .. h.tail(20))
    eq(h.logged('[HELLTIDE] Resumed after'), 0, 'no yield of 5 s or more (HEAD: 15.1 s)')
    h.assert_clean('Q1-7')
end)

case('Q1-8 (C6) the 20 s episode budget still bounds untakeable gear drops', function()
    local h = new()
    for i = 1, 4 do
        ghost(h, 'pit', h.pos:x() + i * 1.5, h.pos:y() + 1, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_00' .. i}, 'refused')
    end
    local longest, since = 0, nil
    h.run(120, function()
        if busy(h) then since = since or h.now; if h.now - since > longest then longest = h.now - since end
        else since = nil end
    end)
    ok(longest <= 21, string.format('longest continuous busy %.1fs', longest))
end)

case('Q1-9 under WarPigs (all plugins, Temis, Whisper reward ready): a ghost prism does not hold the claim', function()
    local h = J.new({rosie = true})
    h.assert_clean('load')
    h.instrument_exports()
    h.mod('WarPigs', 'gui').elements.main_toggle:set(true)
    h.mod('WarPug', 'gui').elements.main_toggle:set(true)
    h.mod('SilentRaven', 'silent_raven.gui').elements.main_toggle:set(true)
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(12)
    eq(h.as('Rosie', function() return h.G.RosiePlugin.enable() end), true, 'Rosie enabled')
    h.bounty_ready = true
    local t0, g = h.now, nil
    local longest, since = 0, nil
    ok(h.run_until(function()
        if not g and h.now - t0 >= 1 then g = ghost(h, 'temis', h.pos:x() + 1, h.pos:y() + 1, PRISM, 'materials') end
        return h.logged('visit 1: success') > 0
    end, 120, function()
        if busy(h) then since = since or h.now; if h.now - since > longest then longest = h.now - since end
        else since = nil end
    end), 'the Whisper claim completes\n' .. h.tail(30))
    ok(h.now - t0 <= 20, string.format('claim done after %.1fs (HEAD: 31.3 s)', h.now - t0))
    ok(longest <= 4.5, string.format('Rosie busy %.1fs (HEAD: 17.8 s)', longest)) -- QQT_Warpigz_v3 (Q1 review)
    ok((g.tries or 0) <= 25, 'ghost interactions: ' .. tostring(g.tries))
    eq(h.logged("[Rosie pickup] Took {icon:Cube_TooltipIcon, 2} Protector's Tuning Prism"), 1, 'one line')
    h.assert_clean('Q1-9')
end)

-- QQT_Warpigz_v3 (Q1 review, rc.10 R6): the first version settled a rune
-- as unreachable after ONE 6 s window of a fight and lost it; a fight now
-- keeps the bounded rounds and the drop is collected after it. Only a CLEAR
-- stall (no fight: the host executed Rosie's moves) settles a non-gear drop.
case('Q1-10 a non-gear drop during a fight keeps its rounds and is picked up after it; a clear unreachable ghost gets one more attempt when the player passes by', function()
    local h = new()
    h.pos = h.v(0, 0)
    h.drop('pit', 12, 0, fields(RUNE))
    local real = h.G.pathfinder.request_move
    local fight_until = h.now + 15
    h.G.pathfinder.request_move = function(p) if h.now < fight_until then return false end return real(p) end
    ok(h.run_until(function() return (h.pickups or 0) > 0 end, 30), 'picked up after the 15 s fight\n' .. h.tail(20))
    eq(h.logged('[Rosie pickup] Leaving Rune of Summons'), 0, 'never settled during the fight\n' .. h.tail(20))
    -- A ghost the player cannot approach with no fight is left after one window ...
    local b = h.place.box
    local g = ghost(h, 'pit', b[2] + 5, 0, PRISM, 'materials')
    g.taken = true
    h.pos = h.v(b[2] - 4, 0)
    h.run(10)
    eq(h.logged("[Rosie pickup] Leaving {icon:Cube_TooltipIcon, 2} Protector's Tuning Prism: cannot reach it"), 1, 'left\n' .. h.tail(20))
    -- ... and gets exactly one in-reach attempt when the player's own route passes it.
    h.pos = h.v(b[2] + 4.5, 0)
    local _, _, tries = measure(h, g, 10)
    ok(tries >= 1 and tries <= 25, 'one in-reach attempt: ' .. tries)
    eq(h.logged("[Rosie pickup] Took {icon:Cube_TooltipIcon, 2} Protector's Tuning Prism"), 1, 'then taken\n' .. h.tail(20))
    h.pos = h.v(b[2] - 4, 0)
    h.run(3)
    h.pos = h.v(b[2] + 4.5, 0)
    local _, _, again = measure(h, g, 10)
    eq(again, 0, 'no second attempt')
end)

case('Q1-11 (C6) four unreachable ghosts: one stall window each, the 20 s budget still bounds the chain', function()
    local h = new()
    local b = h.place.box
    h.pos = h.v(b[2] - 4, 0)
    for i = 1, 4 do local g = ghost(h, 'pit', b[2] + 3 + i, i, PRISM, 'materials'); g.taken = true end
    local total, longest, since = 0, 0, nil
    h.run(120, function()
        if busy(h) then
            total = total + 0.1
            -- one episode: busy gaps shorter than 2 s do not end it (HR's loot hold view)
            since = since or h.now; last_busy = h.now
            if h.now - since > longest then longest = h.now - since end
        elseif since and h.now - (last_busy or h.now) >= 2 then since = nil end
    end)
    ok(total <= 27, string.format('busy %.1fs in 120 s (HEAD: 3 rounds each)', total))
    ok(longest <= 21, string.format('longest episode %.1fs', longest))
    eq(h.logged('[Rosie pickup] Leaving'), 4, 'each ghost left once\n' .. h.tail(20))
    eq(h.logged('[Rosie pickup] Retrying'), 0, 'no retry rounds')
end)

case('Q1-12 a settled no-bag ghost gets ONE more short attempt only after the player left and came back', function()
    local h = new()
    local g = ghost(h, 'pit', h.pos:x() + 1, h.pos:y(), PRISM, 'materials')
    local home = h.v(h.pos:x(), h.pos:y())
    local _, _, first = measure(h, g, 5)
    ok(first >= 1 and first <= 25, 'first visit: ' .. first) -- QQT_Warpigz_v3 (Q1 review): 3.5 s clear
    local _, _, idle = measure(h, g, 25)
    eq(idle, 0, 'standing next to it: no second attempt')
    h.pos = h.v(home:x() - 8, home:y()) -- the player's own route leaves ...
    h.run(3)
    h.pos = home -- ... and brings it back (Rosie never walks back for it)
    local total, _, second = measure(h, g, 10)
    ok(second >= 1 and second <= 25, 'one short attempt on the way back: ' .. second)
    ok(total <= 4.5, string.format('busy %.1fs on the way back', total))
    h.pos = h.v(home:x() - 8, home:y()); h.run(3); h.pos = home
    local _, _, third = measure(h, g, 10)
    eq(third, 0, 'never a third attempt')
    eq(h.logged("[Rosie pickup] Took {icon:Cube_TooltipIcon, 2} Protector's Tuning Prism"), 1, 'still one line\n' .. h.tail(20))
    no_round_logs(h, 'Q1-12')
end)

case('Q1-13 a Tuning Prism goes to Materials: a full consumable bag does not refuse it', function()
    local h = new()
    local full = {}
    for i = 1, 33 do full[i] = h.gear({name = 'Elixir_Assault_1', sno = 1066486}) end
    h.G.get_local_player().get_consumable_items = function() return full end
    local g = h.drop('pit', h.pos:x() + 1, h.pos:y(), fields(PRISM))
    local wanted, reason = h.as(CONSUMER, function() return h.G.LooteerPlugin.evaluate_item(g, false) end)
    eq(wanted, true, 'prism accepted with 33 consumables (HEAD: bag full or unreadable: consumable); reason ' .. tostring(reason))
    ok(h.run_until(function() return (h.pickups or 0) > 0 end, 5), 'and taken\n' .. h.tail(10))
end)

case('Q1-14 gear-class drops (a charm) keep the bounded rounds: swallowed interactions in a fight do not settle it', function()
    local h = new()
    local charm = h.drop('pit', h.pos:x() + 1, h.pos:y(), {name = 'Talisman_Charm_Joint_01', rarity = 6, sno = 990004242})
    local real = charm.on_interact
    local swallowed = 0
    charm.on_interact = function(...)
        if swallowed < 20 then swallowed = swallowed + 1; return end -- a boss fight: the cast wins
        return real(...)
    end
    ok(h.run_until(function() return (h.pickups or 0) > 0 end, 15), 'the charm is taken after 20 swallowed interactions\n' .. h.tail(20))
    eq(h.logged('[Rosie pickup] Leaving'), 0, 'never settled as refused')
end)

case('Q1-15 a receipt counts only this drop: another drop of the same SNO taken meanwhile does not settle it', function()
    local h = new()
    h.inventory = {}
    local SAME = 990007777
    local a = h.drop('pit', h.pos:x() + 1, h.pos:y(), {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_009', sno = SAME})
    local b = h.drop('pit', h.pos:x() - 1, h.pos:y(), {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_009', sno = SAME})
    local real = a.on_interact
    local swallowed = 0
    a.on_interact = function(...)
        if swallowed < 30 then swallowed = swallowed + 1; return end -- one whole round swallowed (a fight)
        return real(...)
    end
    ok(h.run_until(function() return (h.pickups or 0) >= 2 end, 40), 'both helms taken\n' .. h.tail(20))
    ok(b.picked and a.picked, 'A and B picked')
    eq(h.logged('[Rosie pickup] Took'), 0, 'no receipt settle: A really left the ground\n' .. h.tail(20))
end)

if #failures > 0 then error(#failures .. ' failure(s):\n' .. table.concat(failures, '\n')) end
print('Rosie ghost pickup checks: ' .. checks)
