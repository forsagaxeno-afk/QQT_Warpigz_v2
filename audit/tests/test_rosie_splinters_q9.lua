-- QQT_Warpigz_v3 (Q9, live 2026-09-27): Season 15 Splinters of Evil
-- ("Splinters of the Prime Evils": Terror / Destruction / Hatred,
-- S15_SoulSplinter_TriadA/B/C_01, sno 2656952 / 2656956 / 2656962) are
-- one-per-character consumables (d4data: nMaxStackSize 1,
-- fMustKeepInInventory, dwFlags bit 0x20000). With one already carried the
-- game refuses a second copy of the same kind; Rosie accepted it anyway
-- ("accepted splinter") and stood on it (c6433d8: 3 rounds x 30 interactions,
-- busy, again on every stream-in; with Q1 alone still 12 interactions per
-- identifier). Now the carried kind is read from the consumable bag by SNO
-- and the drop is never approached; a refused drop is also remembered by SNO
-- and spot, so a new host identifier does not restart the attempts.
-- Real Rosie in the joint host, standalone and under WarPigs.
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
    if passed then print('PASS splinters: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL splinters: ' .. name .. ': ' .. tostring(err)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local TERROR, DESTRUCTION = 2656952, 2656956
local function new(opts)
    opts = opts or {}
    opts.rosie, opts.dirs = true, opts.dirs or {}
    local h = J.new(opts)
    h.assert_clean('load')
    h.pos = h.pos or h.v(0, 0)
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(30)
    return h
end
local function busy(h) return h.as(CONSUMER, function() return h.G.LooteerPlugin.is_actively_looting() end) end
local function carried(h, sno, skin) return h.gear({sno = sno, name = skin or 'S15_SoulSplinter_TriadA_01', rarity = 1}) end
-- The game refuses a second copy of the same SNO while one is carried.
local function refuse_same(h, item)
    for _, it in ipairs(h.consumables or {}) do if it:get_sno_id() == item.sno then return true end end
    return false
end
local function splinter(h, place, x, y, sno, skin, display, refuse)
    return h.drop(place, x, y, {sno = sno, name = skin or 'S15_SoulSplinter_TriadA_01', display = display or 'Splinter of Terror',
        rarity = 1, bag = 'consumables', refuse = refuse or refuse_same})
end
local function watch(h, seconds)
    local b, i0 = 0, #h.interactions
    h.run(seconds, function() if busy(h) then b = b + 0.1 end end)
    return b, #h.interactions - i0
end
-- The drop leaves the actor list for `gap` s and comes back; `new_uid` gives
-- it a new host identifier (live unknown: does the host keep it?).
local function stream_out_and_back(h, item, gap, new_uid)
    local items = h.place.items
    for i = #items, 1, -1 do if items[i] == item then table.remove(items, i) end end
    h.run(gap or 2)
    if new_uid then item.uid = item.uid + 100000 end
    items[#items + 1] = item
end

case('Q9-1 a second Splinter of Terror is never approached nor interacted with; one log line', function()
    local h = new({place = 'pit'})
    h.consumables = {carried(h, TERROR)}
    local g = splinter(h, 'pit', 1, 0, TERROR)
    local im = h.mod('Rosie', 'rosie.private.pickup.src.item_manager')
    local wanted, why = h.as('Rosie', function() return im.check_want_item(g, true) end)
    eq(wanted, false, 'refused up front (c6433d8: accepted splinter): ' .. tostring(why))
    ok(tostring(why):find('already carrying Splinter of Terror', 1, true), tostring(why))
    local b, n = watch(h, 60)
    eq(n, 0, 'no interaction with the refused drop')
    eq(b, 0, 'never busy (activities do not wait for it)')
    eq(h.refusals or 0, 0, 'the game was never asked')
    eq(h.logged('Not picking up Splinter of Terror (sno=2656952): already carrying one'), 1, 'logged once\n' .. h.tail())
    eq(h.logged('[Rosie pickup] Retrying'), 0, 'no pickup rounds')
    eq(h.logged('[Rosie pickup] Leaving Splinter of Terror'), 0, 'no settle attempt either')
end)

case('Q9-2 the refused drop streaming out and back in 3 times (also with a new identifier): still nothing, one line', function()
    local h = new({place = 'pit'})
    h.consumables = {carried(h, TERROR)}
    local g = splinter(h, 'pit', 1, 0, TERROR)
    local total = 0
    for i = 1, 3 do
        local _, n = watch(h, 20)
        total = total + n
        stream_out_and_back(h, g, 2, i == 2)
    end
    local _, n = watch(h, 20)
    eq(total + n, 0, 'no interaction on any visit')
    eq(h.logged('already carrying one'), 1, 'one line in the same zone\n' .. h.tail())
end)

case('Q9-3 carrying Destruction, a Splinter of Terror (other kind) is picked up into the consumable bag', function()
    local h = new({place = 'pit'})
    h.consumables = {carried(h, DESTRUCTION, 'S15_SoulSplinter_TriadB_01')}
    splinter(h, 'pit', 1, 0, TERROR)
    ok(h.run_until(function() return (h.pickups or 0) > 0 end, 10), 'picked up\n' .. h.tail())
    eq(#h.consumables, 2, 'now carrying both kinds')
end)

case('Q9-4 once the carried Splinter is used, the ground copy is picked up', function()
    local h = new({place = 'pit'})
    h.consumables = {carried(h, TERROR)}
    splinter(h, 'pit', 1, 0, TERROR)
    h.run(30)
    eq(h.pickups or 0, 0, 'refused while carried')
    table.remove(h.consumables, 1) -- right-click: the Splinter replaces the active one
    ok(h.run_until(function() return (h.pickups or 0) > 0 end, 10), 'picked up after use\n' .. h.tail())
    eq(h.refusals or 0, 0, 'the game never refused an attempt')
end)

case('Q9-5 consumable bag unreadable: the Splinter is deferred, never interacted with', function()
    local h = new({place = 'pit'})
    h.consumables_error = true
    local g = splinter(h, 'pit', 1, 0, TERROR)
    local im = h.mod('Rosie', 'rosie.private.pickup.src.item_manager')
    local wanted, why, decision = h.as('Rosie', function() return im.check_want_item(g, true) end)
    eq(wanted, false, tostring(why))
    eq(decision, 'deferred', 'an unreadable bag is not a refusal: ' .. tostring(why))
    local _, n = watch(h, 10)
    eq(n, 0, 'no interaction')
end)

case('Q9-6 a later build\'s Splinter of Evil (SNO not in the data) is recognized by its skin', function()
    local h = new({place = 'pit'})
    local skin = 'S15_SoulSplinter_TriadD_01'
    h.consumables = {carried(h, 2699999, skin)}
    local g = splinter(h, 'pit', 1, 0, 2699999, skin, 'Splinter of Something')
    local im = h.mod('Rosie', 'rosie.private.pickup.src.item_manager')
    local wanted, why = h.as('Rosie', function() return im.check_want_item(g, true) end)
    eq(wanted, false, tostring(why))
    ok(tostring(why):find('already carrying', 1, true), tostring(why))
    local _, n = watch(h, 20)
    eq(n, 0, 'no interaction')
end)

case('Q9-7 ordinary Soul Splinters (stack 1000, socketable bag) are still taken while one is carried', function()
    local h = new({place = 'pit'})
    h.socketables = {h.gear({sno = 2651971, name = 'S15_SoulSplinter_Andariel_01', rarity = 1})}
    h.drop('pit', 1, 0, {sno = 2651971, name = 'S15_SoulSplinter_Andariel_01', display = 'Lesser Splinter of Anguish',
        rarity = 1, bag = 'socketables'})
    ok(h.run_until(function() return (h.pickups or 0) > 0 end, 10), 'picked up\n' .. h.tail())
    eq(#h.socketables, 2, 'in the socketable bag')
end)

case('Q9-8 "Stash consumables = Always": a carried Splinter (the game refuses its deposit) no longer fails the trip', function()
    local h = new({})
    h.mod('Rosie', 'rosie.private.town.gui').elements.stash_consumables:set(2) -- ALWAYS
    local keep = carried(h, TERROR); keep.must_keep = true -- the game refuses the deposit
    local mat = h.gear({sno = 1502569, name = 'Item_BossMaterial_Joint', rarity = 1})
    h.consumables = {keep, mat}
    h.inventory = {h.gear({rarity = 8, ancestral = true})}
    local done
    eq(h.as(CONSUMER, function() return h.G.AlfredTheButlerPlugin.trigger_tasks('WarPigs', function(r, d) done = {r, d} end) end), true)
    ok(h.run_until(function() return done ~= nil end, 200), 'the trip finished\n' .. h.tail())
    eq(done[1], nil, 'serviced (c6433d8: No transfer observed ... after 3 attempts): '
        .. tostring(done[2] and done[2].reason) .. '\n' .. h.tail(12))
    eq(h.logged('No transfer observed for S15_SoulSplinter_TriadA_01'), 0, 'the trip did not fail on the Splinter')
    eq(h.consumables[1], keep, 'still carried')
    local stashed_mat = false
    for _, it in ipairs(h.stashed) do if it == mat then stashed_mat = true end end
    ok(stashed_mat, 'the other consumable was stashed')
end)

case('Q9-9 an item the game always refuses and Rosie has no carry data for: one short try, then never again here', function()
    local h = new({place = 'pit'})
    local g = h.drop('pit', 1, 0, {sno = 2605399, name = 'S15_Khalims_Eye', display = "Khalim's Eye", rarity = 1,
        refuse = function() return true end})
    local _, n1 = watch(h, 40)
    ok(n1 >= 1 and n1 <= 30, 'at most one short try (c6433d8: 90): ' .. n1) -- QQT_Warpigz_v3 (Q1 review): one round
    eq(h.logged("Khalim's Eye"), 1, 'the verdict is logged once\n' .. h.tail())
    local total = 0
    for _ = 1, 3 do
        stream_out_and_back(h, g)
        local b, n = watch(h, 20)
        total = total + n
        eq(b, 0, 'not busy on a later visit')
    end
    eq(total, 0, 'not retried after it streamed back in')
    eq(h.logged("Khalim's Eye"), 1, 'still one line')
end)

case('Q9-10 a refused Splinter re-listed under a NEW identifier keeps its verdict (carried copy not visible)', function()
    -- Live unknown: the carried copy may not show in get_consumable_items;
    -- the game still refuses the ground copy. Q1 leaves it after one round (30)
    -- interactions; the verdict now survives a new host identifier.
    local h = new({place = 'pit'})
    local g = splinter(h, 'pit', 1, 0, TERROR, nil, nil, function() return true end)
    local _, n1 = watch(h, 30)
    ok(n1 >= 1 and n1 <= 30, 'one bounded try: ' .. n1) -- QQT_Warpigz_v3 (Q1 review): one round
    eq(h.logged('[Rosie pickup] Leaving Splinter of Terror'), 1, 'logged once\n' .. h.tail())
    local total = 0
    for _ = 1, 3 do
        stream_out_and_back(h, g, 2, true)
        local b, n = watch(h, 20)
        total = total + n
        eq(b, 0, 'not busy on a later visit')
    end
    eq(total, 0, 'no attempt under a new identifier (Q1 alone: 30 per visit)')
    eq(h.logged('[Rosie pickup] Leaving Splinter of Terror'), 1, 'still one line')
    -- A second Terror 1 m away is a different drop: it gets its own try.
    local g2 = splinter(h, 'pit', 1.8, 0.6, TERROR, nil, nil, function() return true end)
    h.run(20)
    ok((h.refusals or 0) > n1, 'the drop at another spot was tried')
    eq(g2.picked, nil, 'still refused')
end)

case('Q9-11 standalone Helltide (HR + Batmobile + Rosie): a refused Splinter never makes HR yield', function()
    local h = new({dirs = {'Batmobile', 'HelltideRevamped'}, place = 'helltide'})
    h.P.helltide.helltide = true
    h.mod('HelltideRevamped', 'gui').elements.main_toggle:set(true)
    h.consumables = {carried(h, TERROR)}
    h.run(8)
    splinter(h, 'helltide', h.pos:x() + 1, h.pos:y() + 1, TERROR)
    local b = watch(h, 60)
    eq(b, 0, 'Rosie never busy')
    eq(h.refusals or 0, 0, 'no pickup attempt')
    eq(h.logged('Looter busy 15s without progress'), 0, 'HR never hit its Looter cap\n' .. h.tail(20))
    h.assert_clean('Q9-11')
end)

case('Q9-12 under WarPigs (all plugins, Temis, Whisper reward ready): a refused Splinter does not delay the claim', function()
    local h = J.new({rosie = true})
    h.assert_clean('load')
    h.instrument_exports()
    h.mod('WarPigs', 'gui').elements.main_toggle:set(true)
    h.mod('WarPug', 'gui').elements.main_toggle:set(true)
    h.mod('SilentRaven', 'silent_raven.gui').elements.main_toggle:set(true)
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(12)
    eq(h.as('Rosie', function() return h.G.RosiePlugin.enable() end), true, 'Rosie enabled')
    h.consumables = {carried(h, TERROR)}
    h.bounty_ready = true
    local t0, g = h.now, nil
    local b = 0
    ok(h.run_until(function()
        if not g and h.now - t0 >= 1 then g = splinter(h, 'temis', h.pos:x() + 1, h.pos:y() + 1, TERROR) end
        return h.logged('visit 1: success') > 0
    end, 120, function() if busy(h) then b = b + 0.1 end end), 'the Whisper claim completes\n' .. h.tail(30))
    ok(h.now - t0 <= 20, string.format('claim done after %.1fs', h.now - t0))
    eq(b, 0, 'Rosie never busy')
    eq(h.refusals or 0, 0, 'no pickup attempt')
    h.assert_clean('Q9-12')
end)

-- QQT_Warpigz_v3 (Q1/Q9 review): paths the mutation run found unpinned.
case('Q9-13 one carried consumable with an unreadable SNO defers the Splinter (never taken blind), then it is taken', function()
    local h = new({place = 'pit'})
    local odd = h.gear({name = 'Elixir_Joint', rarity = 1})
    local readable = false
    odd.get_sno_id = function() if readable then return 1066486 end return nil end
    h.consumables = {odd}
    local g = splinter(h, 'pit', 1, 0, TERROR)
    local im = h.mod('Rosie', 'rosie.private.pickup.src.item_manager')
    local wanted, why, decision = h.as('Rosie', function() return im.check_want_item(g, true) end)
    eq(wanted, false, tostring(why))
    ok(tostring(why):find('carried items unreadable', 1, true), tostring(why))
    eq(decision, 'deferred', 'deferred, not refused')
    local _, n = watch(h, 10)
    eq(n, 0, 'no interaction while the carried list is unreadable')
    readable = true
    ok(h.run_until(function() return g.picked == true end, 10), 'taken once the list reads\n' .. h.tail())
end)

case('Q9-14 the carried Splinter used and a new one picked up: the next ground copy logs "Not picking up" again', function()
    local h = new({place = 'pit'})
    h.consumables = {carried(h, TERROR)}
    local g1 = splinter(h, 'pit', 1, 0, TERROR)
    watch(h, 5)
    eq(h.logged('already carrying one'), 1, 'first line')
    table.remove(h.consumables, 1) -- used
    ok(h.run_until(function() return g1.picked == true end, 10), 'the ground copy is taken\n' .. h.tail())
    splinter(h, 'pit', -1, 0, TERROR)
    local _, n = watch(h, 5)
    eq(n, 0, 'the second ground copy is not tried')
    eq(h.logged('already carrying one'), 2, 'the decision is logged again for the new carry\n' .. h.tail())
end)

case('Q9-15 a refused carry-once drop that would reach the rejection report prints no second "Skipped" line', function()
    local h = new({place = 'pit'})
    h.consumables = {carried(h, TERROR)}
    local g = splinter(h, 'pit', 1, 0, TERROR)
    g.rarity = 6 -- past the report's rarity gate
    watch(h, 10)
    eq(h.logged('already carrying one'), 1, 'one decision line\n' .. h.tail())
    eq(h.logged('[Rosie pickup] Skipped'), 0, 'no duplicate Skipped line\n' .. h.tail())
end)

-- QQT_Warpigz_v3 (Q9 stash follow-up): the stash never spends deposit
-- requests on a carried Splinter (the game does not stash it); two trips, one
-- "Kept ... in the bag" line for the session.
case('Q9-16 "Stash consumables = Always": no deposit request for a carried Splinter on any trip; kept line once per session', function()
    local h = new({})
    h.mod('Rosie', 'rosie.private.town.gui').elements.stash_consumables:set(2) -- ALWAYS
    local keep = carried(h, TERROR); keep.must_keep = true -- the game refuses the deposit
    local mat = h.gear({sno = 1502569, name = 'Item_BossMaterial_Joint', rarity = 1})
    h.consumables = {keep, mat}
    for trip = 1, 2 do
        h.inventory = {h.gear({rarity = 8, ancestral = true})}
        local done, t0 = nil, h.now
        eq(h.as(CONSUMER, function() return h.G.AlfredTheButlerPlugin.trigger_tasks('WarPigs', function(r, d) done = {r, d} end) end), true)
        ok(h.run_until(function() return done ~= nil end, 200), 'trip ' .. trip .. ' finished\n' .. h.tail())
        eq(done[1], nil, 'trip ' .. trip .. ' serviced: ' .. tostring(done[2] and done[2].reason))
        ok(h.now - t0 < 60, string.format('trip %d took %.1fs', trip, h.now - t0))
    end
    eq(h.logged('Deposit requested: S15_SoulSplinter_TriadA_01'), 0,
        'no deposit request for the carried Splinter (rc.2 lanes: 3 per trip)\n' .. h.tail(20))
    eq(h.logged('Skipped S15_SoulSplinter_TriadA_01'), 0, 'never a per-trip skip for it')
    eq(h.logged('[Rosie:stash] Kept Splinter of Terror in the bag: the game does not stash it.'), 1,
        'logged once for the session over two trips\n' .. h.tail(20))
    eq(h.consumables[1], keep, 'still carried')
    local stashed_mat = false
    for _, it in ipairs(h.stashed) do if it == mat then stashed_mat = true end end
    ok(stashed_mat, 'the other consumable was stashed')
end)

case('Q9-17 a later build\'s Splinter SNO (not in the carry data) is kept by its item skin; no deposit request', function()
    local h = new({})
    h.mod('Rosie', 'rosie.private.town.gui').elements.stash_consumables:set(2) -- ALWAYS
    local keep = carried(h, 2799001, 'S15_SoulSplinter_TriadB_02'); keep.must_keep = true
    local mat = h.gear({sno = 1502569, name = 'Item_BossMaterial_Joint', rarity = 1})
    h.consumables = {keep, mat}
    h.inventory = {h.gear({rarity = 8, ancestral = true})}
    local done
    eq(h.as(CONSUMER, function() return h.G.AlfredTheButlerPlugin.trigger_tasks('WarPigs', function(r, d) done = {r, d} end) end), true)
    ok(h.run_until(function() return done ~= nil end, 200), 'the trip finished\n' .. h.tail())
    eq(done[1], nil, 'serviced: ' .. tostring(done[2] and done[2].reason))
    eq(h.logged('Deposit requested: S15_SoulSplinter_TriadB_02'), 0, 'no deposit request\n' .. h.tail(20))
    eq(h.logged('[Rosie:stash] Kept S15_SoulSplinter_TriadB_02 in the bag'), 1, 'logged once\n' .. h.tail(20))
    eq(h.consumables[1], keep, 'still carried')
end)

print(string.format('rosie splinters q9: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(#failures .. ' splinter regression(s) failed') end
