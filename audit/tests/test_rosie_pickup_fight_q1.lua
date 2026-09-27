-- QQT_Warpigz_v3 3.1.0-rc.2 (Q1 review, rc.10 R6 / LIVE_CHECKLIST): drops
-- that fall during a fight must be collected after the fight, for EVERY
-- drop class, not only gear. The first Q1 fix settled non-gear drops fast
-- (no-bag "Took" after 3 interactions in 0.5 s, small "refused" after 12
-- interactions, "cannot reach it" after one 6 s window) and read a fight as
-- proof of a ghost: runes, boss items, crafting materials and real Tuning
-- Prisms were lost, and a Mythic on a small prop was left as "not walkable".
-- Settle evidence now counts only CLEAR time (not casting, no live enemy
-- within 10 m, the host executed Rosie's move); a fight keeps the bounded
-- rounds. Also pins the settled-drop lifecycle and the receipt paths the
-- mutation run found unpinned. Real Rosie in the joint host throughout.
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
    if passed then print('PASS pickup-fight: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL pickup-fight: ' .. name .. ': ' .. tostring(err)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function new(dirs, place, slider)
    local h = J.new({rosie = true, dirs = dirs or {}, place = place or 'pit'})
    h.assert_clean('load')
    if (place or 'pit') == 'pit' then h.pos = h.v(0, 0) end
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(slider or 30)
    return h
end
local function busy(h) return h.as(CONSUMER, function() return h.G.LooteerPlugin.is_actively_looting() end) end
local function fields(t) local f = {}; for k, v in pairs(t) do f[k] = v end; return f end
local RUNE = {sno = 2155997, name = 'Rune_Condition_Summons', rarity = 0, display = 'Rune of Summons'}
local PRISM = {sno = 2533715, name = 'X2_HoradricCube_TuningStone_2', rarity = 0,
    display = "{icon:Cube_TooltipIcon, 2} Protector's Tuning Prism"}
local CRAFT = {sno = 311552, name = 'Crafting_311552', rarity = 0}
local HELM = {rarity = 6, ancestral = true, ga = 1, name = 'Helm_Unique_Generic_005', sno = 2647147,
    affixes = {{affix_name_hash = 2628989, get_name = function() return 'S14_Mythic_UniquePotency' end}}}
local KINDS = {{'rune', RUNE}, {'tuning prism', PRISM}, {'crafting', CRAFT}}
local function fight_moves(h, seconds)
    local real = h.G.pathfinder.request_move
    local until_t = h.now + seconds
    h.G.pathfinder.request_move = function(p) if h.now < until_t then return false end return real(p) end
end
-- A ground actor the host keeps listing; the first interaction takes it
-- into Materials (no bag gains it). tries counts interactions.
local function ghost(h, x, y, template)
    local g = h.drop('pit', x, y, fields(template))
    g.on_interact = function() g.tries = (g.tries or 0) + 1 end
    return g
end
local function unlist(h, item)
    for i = #h.place.items, 1, -1 do if h.place.items[i] == item then table.remove(h.place.items, i) end end
end

case('F1 (E1) in reach, 3 s of swallowed interactions the host does not report: rune, prism, crafting picked up', function()
    for _, k in ipairs(KINDS) do
        local h = new()
        h.drop('pit', 1, 0, fields(k[2]))
        local real = h.G.interact_object
        local busy_until = h.now + 3
        rawset(h.G, 'interact_object', function(a) if h.now < busy_until then return true end return real(a) end)
        ok(h.run_until(function() return (h.pickups or 0) > 0 end, 20), k[1] .. ': picked up after the cast (pre-fix: settled early)\n' .. h.tail(10))
        eq(h.logged('[Rosie pickup] Took'), 0, k[1] .. ': no false Took line')
        eq(h.logged('[Rosie pickup] Leaving'), 0, k[1] .. ': never left')
    end
end)

case('F2 (E2) 12 m away during a 10 s fight (request_move ignored): rune, prism, crafting picked up after it', function()
    for _, k in ipairs(KINDS) do
        local h = new()
        h.drop('pit', 12, 0, fields(k[2]))
        fight_moves(h, 10)
        ok(h.run_until(function() return (h.pickups or 0) > 0 end, 40), k[1] .. ': picked up after the fight (pre-fix: Leaving ... no progress at 6 s)\n' .. h.tail(10))
        eq(h.logged('[Rosie pickup] Leaving'), 0, k[1] .. ': never left')
    end
end)

case('F3 (R-E10) Reaper waits: rune, prism, crafting 12 m away during a 10 s fight; loot_ready never true before the pickup', function()
    for _, k in ipairs(KINDS) do
        local h = new({'Reaper'})
        h.drop('pit', 12, 0, fields(k[2]))
        fight_moves(h, 10)
        local utils = h.mod('Reaper', 'core.utils')
        local ready_early = false
        h.run_until(function() return (h.pickups or 0) > 0 end, 40, function(hh)
            if (hh.pickups or 0) > 0 then return end
            if hh.as('Reaper', function() return utils.loot_ready() end) then ready_early = true end
        end)
        ok((h.pickups or 0) > 0, k[1] .. ': picked up\n' .. h.tail(10))
        eq(ready_early, false, k[1] .. ': Reaper loot_ready before the pickup (pre-fix: at 9.2 s)')
    end
end)

case('F4 standalone Helltide (HR + Batmobile + Rosie): a rune / crafting material 10 m away during an 8 s fight is picked up', function()
    for _, k in ipairs({{'rune', RUNE}, {'crafting', CRAFT}}) do
        local h = new({'Batmobile', 'HelltideRevamped'}, 'helltide', 15)
        h.P.helltide.helltide = true
        h.mod('HelltideRevamped', 'gui').elements.main_toggle:set(true)
        h.run(8)
        local item = h.drop('helltide', h.pos:x() + 10, h.pos:y(), fields(k[2]))
        fight_moves(h, 8)
        ok(h.run_until(function() return item.picked == true end, 60), k[1] .. ': picked up (pre-fix: HR walked on, 252 m)\n' .. h.tail(12))
        h.assert_clean('F4 ' .. k[1])
    end
end)

case('F5 casting (get_active_spell_id) pauses the settle evidence: a prism under a 6 s cast and a rune under an 8 s cast are taken', function()
    for _, c in ipairs({{'tuning prism', PRISM, 6}, {'rune', RUNE, 8}}) do
        local h = new()
        h.drop('pit', 1, 0, fields(c[2]))
        local real = h.G.interact_object
        h.casting = true
        local cast_until = h.now + c[3]
        rawset(h.G, 'interact_object', function(a) if h.casting then return true end return real(a) end)
        ok(h.run_until(function()
            if h.now >= cast_until then h.casting = false end
            return (h.pickups or 0) > 0
        end, 30), c[1] .. ': picked up after the cast (longer than the clear floor)\n' .. h.tail(10))
        eq(h.logged('[Rosie pickup] Took'), 0, c[1] .. ': no false Took line')
        eq(h.logged('[Rosie pickup] Leaving'), 0, c[1] .. ': never left')
    end
end)

case('F6 a live enemy within 10 m pauses the settle evidence: a rune next to the player is taken once the enemy dies', function()
    local h = new()
    h.drop('pit', 1, 0, fields(RUNE))
    local enemy = h.actor('pit', 'Joint_Monster', 7, 0, {enemy = true, health = 100}) -- outside the rotation's 4 m
    local real = h.G.interact_object
    rawset(h.G, 'interact_object', function(a) if (enemy.health or 0) > 0 then return true end return real(a) end)
    local dies = h.now + 9
    ok(h.run_until(function()
        if h.now >= dies then enemy.health = 0 end
        return (h.pickups or 0) > 0
    end, 30), 'picked up after the fight\n' .. h.tail(10))
    eq(h.logged('[Rosie pickup] Leaving'), 0, 'never left as refused')
end)

case('F7 a Mythic on a small prop (its spot not walkable, the spot in front is): a clear stall keeps its rounds', function()
    local h = new()
    h.place.walls = {{11.6, 12.4, -0.4, 0.4}}
    h.drop('pit', 12, 0, fields(HELM))
    local speed = h.speed
    h.speed = 0 -- body-blocked for 7 s: Rosie's moves are executed but the player does not move
    local free_at = h.now + 7
    ok(h.run_until(function()
        if h.now >= free_at then h.speed = speed end
        return (h.pickups or 0) > 0
    end, 40), 'picked up from in front of the prop (pre-fix: Leaving ... not walkable)\n' .. h.tail(10))
    eq(h.logged('[Rosie pickup] Leaving'), 0, 'never left')
    ok(h.logged('[Rosie pickup] Retrying Helm_Unique_Generic_005') >= 1, 'the stall ended a round, not the drop')
end)

case('F8 a gear drop with no walkable point within reach is left after one clear window, one line, no rounds', function()
    local h = new()
    local b = h.place.box
    h.pos = h.v(b[2] - 6, 0)
    h.drop('pit', b[2] + 5, 0, fields(HELM))
    h.run(30)
    eq(h.logged('[Rosie pickup] Leaving Helm_Unique_Generic_005: cannot reach it (not walkable'), 1, 'one line\n' .. h.tail(10))
    eq(h.logged('[Rosie pickup] Retrying'), 0, 'no retry rounds')
    eq(busy(h), false, 'not busy afterwards')
end)

case('F9 settled drops are forgotten on a world change, 180 s after they were last listed, and on reset', function()
    local function setup()
        local h = new(nil, nil, 15)
        local g = ghost(h, h.pos:x() + 1, h.pos:y(), PRISM)
        h.run(10)
        eq(h.logged('[Rosie pickup] Took'), 1, 'settled once')
        return h, g
    end
    local h, g = setup()
    local t0, pos = g.tries, h.pos
    h.place = h.P.undercity; h.run(3); h.place = h.P.pit; h.pos = pos
    h.run(10)
    ok(g.tries > t0, 'world change: tried again')
    eq(h.logged('[Rosie pickup] Took'), 2, 'world change: settled again')
    h, g = setup()
    t0 = g.tries
    unlist(h, g); h.run(100); h.place.items[#h.place.items + 1] = g; h.run(3)
    eq(g.tries, t0, 'unlisted 100 s: still settled')
    unlist(h, g); h.run(185); h.place.items[#h.place.items + 1] = g; h.run(10)
    ok(g.tries > t0, 'unlisted 185 s: forgotten, tried again')
    eq(h.logged('[Rosie pickup] Took'), 2, 'ttl: settled again')
    h, g = setup()
    t0 = g.tries
    h.as(CONSUMER, function() return h.G.LooteerPlugin.disable() end); h.run(1)
    h.as(CONSUMER, function() return h.G.LooteerPlugin.enable() end); h.run(10)
    ok(g.tries > t0, 'disable/enable: tried again')
    eq(h.logged('[Rosie pickup] Took'), 2, 'reset: settled again')
end)

case('F10 a drop that moves more than 1 m under the same identifier restarts its in-reach count', function()
    local h = new(nil, nil, 15)
    local r = h.drop('pit', 1, 0, fields(RUNE))
    r.on_interact = function() r.tries = (r.tries or 0) + 1 end -- the game refuses it
    ok(h.run_until(function() return (r.tries or 0) >= 20 end, 10), 'twenty interactions')
    r.pos = h.v(-0.5, 0) -- 1.5 m away, same identifier
    local at
    h.run_until(function()
        if h.logged('[Rosie pickup] Leaving Rune of Summons') > 0 then at = r.tries; return true end
    end, 40)
    ok(at ~= nil, 'left in the end\n' .. h.tail(10))
    ok(at >= 45, 'the count restarted at the new spot: left after ' .. tostring(at) .. ' interactions (without the reset: 30)')
end)

case('F11 a recycled identifier (another SNO at another spot) is a new drop and is taken', function()
    local h = new(nil, nil, 15)
    local g = ghost(h, h.pos:x() + 1, h.pos:y(), PRISM)
    h.run(10)
    eq(h.logged('[Rosie pickup] Took'), 1, 'the ghost settled')
    unlist(h, g); h.run(1)
    local helm = h.drop('pit', h.pos:x() - 1.5, h.pos:y() + 0.5, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_009'})
    helm.uid = g.uid
    ok(h.run_until(function() return helm.picked == true end, 10), 'the new drop under the recycled identifier is taken\n' .. h.tail(10))
end)

case('F12 a rune that merges into a carried stack (only get_stack_count rises) is settled by the receipt', function()
    local h = new(nil, nil, 15)
    local stack = h.gear(fields(RUNE))
    local n = 5
    stack.get_stack_count = function() return n end
    local sockets = {stack}
    h.G.get_local_player().get_socketable_items = function() return sockets end
    local g = h.drop('pit', h.pos:x() + 1, h.pos:y(), fields(RUNE))
    g.on_interact = function() g.tries = (g.tries or 0) + 1; if g.tries == 1 then n = n + 1 end end -- still listed
    h.run(10)
    eq(h.logged('[Rosie pickup] Took Rune of Summons (now in the socketable bag'), 1, 'receipt from the stack count\n' .. h.tail(10))
    ok((g.tries or 0) <= 3, 'interactions: ' .. tostring(g.tries))
end)

case('F13 a no-bag ghost re-listed under a NEW identifier keeps its "taken" verdict: one line, no new attempts', function()
    local h = new(nil, nil, 15)
    local g = ghost(h, h.pos:x() + 1, h.pos:y(), PRISM)
    h.run(10)
    local t0 = g.tries
    for _ = 1, 3 do
        unlist(h, g); h.run(2); g.uid = g.uid + 100000
        h.place.items[#h.place.items + 1] = g
        h.run(10)
    end
    eq(g.tries, t0, 'no attempt under a new identifier (pre-fix: 3 per visit)')
    eq(h.logged('[Rosie pickup] Took'), 1, 'one Took line (pre-fix: one per visit)')
end)

case('F14 a gear ghost settled by its receipt logs one line (no second "Skipped ... pickup settled")', function()
    local h = new(nil, nil, 15)
    h.inventory = {}
    local g = h.drop('pit', h.pos:x() + 1, h.pos:y(), {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_001', sno = 990001234})
    g.on_interact = function()
        g.tries = (g.tries or 0) + 1
        if g.tries == 1 then h.inventory[#h.inventory + 1] = h.gear({rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_001', sno = 990001234}) end
    end
    h.run(30)
    eq(h.logged('[Rosie pickup] Took Helm_Legendary_Generic_001'), 1, 'settled\n' .. h.tail(10))
    eq(h.logged('[Rosie pickup] Skipped Helm_Legendary_Generic_001'), 0, 'no duplicate Skipped line\n' .. h.tail(10))
end)

case('F15 (C6) a no-bag "taken" settle is progress: eight ghosts in a row never trip the 20 s budget', function()
    local h = new(nil, nil, 15)
    for i = 1, 8 do ghost(h, i * 1.5, 0, PRISM) end
    h.run(60)
    eq(h.logged('[Rosie pickup] Took'), 8, 'every ghost settled\n' .. h.tail(10))
    eq(h.logged('without picking anything up'), 0, 'the budget did not cap real progress')
end)

print(string.format('rosie pickup fight q1: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(#failures .. ' pickup fight regression(s) failed') end
