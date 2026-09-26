-- Rosie 1.0.8 (2.3.0-rc.11): "Pick up every Unique (sort in the bag)".
-- Facts this file pins (CHANGELOG 2.3.0-rc.11, "How Rosie sorts Mythics"):
--  * a fresh ground drop exposes no affixes until its first pickup (QQT
--    docs); once picked up, the bag copy AND a re-dropped ground copy list
--    their affixes (live dumps of Leoric's Crown and Condemnation);
--  * an S15 Mythic form keeps the Unique's SNO and rarity 6 and carries
--    S14_Mythic_UniquePotency (hash 2628989);
--  * the joint host models loot_manager.drop_item: the item leaves the bag
--    and a NEW ground actor appears at the player's position with the same
--    SNO and affixes and a new identifier (get_item_identifier = uid).
-- Every case loads the REAL Rosie (joint_host opts.rosie) with the shipped
-- defaults (opts.shipped_defaults: the option is ON, mode "Handle in town").
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
    if passed then print('PASS sort: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL sort: ' .. name .. ': ' .. tostring(err)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function affix(hash, name, roll)
    return {affix_name_hash = hash, get_name = function() return name end, get_roll = function() return roll end}
end
local MARK = affix(2628989, 'S14_Mythic_UniquePotency', 1)
local REASON = 'accepted: every Unique is taken (sorted in the bag)'
local BLACKLISTED = 'dropped by Rosie (plain Unique)'
local function copy(t) local out = {}; for k, v in pairs(t) do out[k] = v end; return out end
local function item(base, fields) local out = copy(base); for k, v in pairs(fields or {}) do out[k] = v end; return out end
local LEORIC = {name = 'Helm_Unique_Generic_005', sno = 2647147, rarity = 6}
local LOCRAN = {name = 'S05_BSK_Amulet_Unique_Generic_001', sno = 1944508, rarity = 6}
local HARLEQUIN = {name = 'S14_Helm_Unique_Generic_002', sno = 2646291, rarity = 6}
-- Plain Uniques read GA 0: the town's default Unique GA override (1) keeps
-- an Ancestral Unique with 1+ GA, so only a 0-GA one is salvaged by default.
local function leoric_plain(roll)
    return item(LEORIC, {ancestral = true, ga = 0, display = "Leoric's Crown",
        affixes = {affix(2662414, 'Helm_Unique_Generic_005', 1), affix(583206, 'AttackSpeed', roll or 7.25),
            affix(1829592, 'S04_Life', 812)}})
end
local function leoric_mythic()
    return item(LEORIC, {ancestral = true, ga = 1, display = "Leoric's Crown",
        affixes = {affix(2662414, 'Helm_Unique_Generic_005', 1), MARK, affix(1829592, 'S04_Life', 900)}})
end
local function locran_plain()
    return item(LOCRAN, {ancestral = true, ga = 0, display = "Locran's Talisman",
        affixes = {affix(1924261, 'S05_BSK_Generic_009', 1), affix(2602164, 'X2_CritDamage_Greater', 31.5)}})
end

-- mode: nil (shipped default: town), 'town' or 'drop'.
local function setup(opts)
    opts = opts or {}
    opts.rosie, opts.dirs, opts.place = true, {}, opts.place or 'pit'
    if opts.shipped_defaults == nil then opts.shipped_defaults = true end
    local h = J.new(opts)
    -- Clean also means no caught Rosie error (sorter, pickup, host) was logged.
    local base_clean = h.assert_clean
    function h.assert_clean(label)
        base_clean(label)
        for _, line in ipairs(h.log) do
            local text = tostring(line)
            for _, bad in ipairs({'[Rosie] Sorter error', '[Rosie] Pickup error', '[Rosie] Host error', 'Menu error'}) do
                if text:find(bad, 1, true) then error((label or 'sort') .. ': ' .. text, 2) end
            end
        end
    end
    h.assert_clean('load')
    h.pos = h.v(0, 0)
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    local pgui = h.mod('Rosie', 'rosie.private.pickup.gui')
    pgui.elements.general.distance_slider:set(30)
    pgui.elements.affix_settings.unique_greater_affix_slider:set(2)
    local e = h.G.RosiePlugin._elements
    if opts.mode == 'drop' then e.all_uniques_mode:set(1) elseif opts.mode == 'town' then e.all_uniques_mode:set(0) end
    h.run(1)
    local t = {h = h, e = e, pgui = pgui, tgui = h.mod('Rosie', 'rosie.private.town.gui'),
        im = h.mod('Rosie', 'rosie.private.pickup.src.item_manager'),
        utils = h.mod('Rosie', 'rosie.private.town.core.utils'),
        blacklist = h.mod('Rosie', 'rosie.private.blacklist'),
        sorter = h.mod('Rosie', 'rosie.private.unique_sorter')}
    function t.want(it) return h.as('Rosie', function() return t.im.check_want_item(it, true) end) end
    function t.evaluate(it) return h.as(CONSUMER, function() return h.G.LooteerPlugin.evaluate_item(it, true) end) end
    function t.lines(prefix)
        local n, last = 0, nil
        for _, line in ipairs(h.log) do if tostring(line):find(prefix, 1, true) then n = n + 1; last = tostring(line) end end
        return n, last
    end
    function t.in_bag(it) for _, x in ipairs(h.inventory or {}) do if x == it then return true end end return false end
    function t.bag_item(fields) local it = h.gear(fields); h.inventory = h.inventory or {}; h.inventory[#h.inventory + 1] = it; return it end
    function t.busy() return h.as(CONSUMER, function() return h.G.LooteerPlugin.is_actively_looting() end) end
    function t.alfred() return h.as(CONSUMER, function() return h.G.AlfredTheButlerPlugin.get_status() end) end
    return t
end

case('menu: the new controls render right after the enable toggle; defaults and persisted values', function()
    local t = setup()
    eq(t.e.all_uniques:get(), true, 'shipped default: Pick up every Unique ON')
    eq(t.e.all_uniques_mode:get(), 0, 'shipped default: Handle in town')
    t.h.menu_labels = {}
    t.h.frame()
    local labels = t.h.menu_labels
    eq(labels[1], 'Enable Rosie', 'first widget\n' .. table.concat(labels, ' | '))
    eq(labels[2], 'Pick up every Unique (sort in the bag)', 'second widget')
    eq(labels[3], 'Plain Uniques', 'third widget (the mode, shown while the option is on)')
    t.e.all_uniques:set(false)
    t.h.menu_labels = {}
    t.h.frame()
    eq(t.h.menu_labels[2], 'Pick up every Unique (sort in the bag)', 'off: still right after the toggle')
    ok(t.h.menu_labels[3] ~= 'Plain Uniques', 'off: the mode combo is hidden')
    t.h.menu_labels = nil
    -- QQT restores both widgets by their own hashes.
    local p = setup({persisted = {Rosie_pickup_all_uniques = false, Rosie_plain_unique_mode = 1}})
    eq(p.e.all_uniques:get(), false, 'persisted OFF loads OFF')
    eq(p.e.all_uniques_mode:get(), 1, 'persisted Drop loads Drop')
    eq(p.sorter.pick_all(), false, 'the sorter reads the widget')
    -- The rc.10 scenarios load with the option saved OFF (joint host default).
    local old = setup({shipped_defaults = false})
    eq(old.e.all_uniques:get(), false, 'rc.10 scenarios: option OFF')
    -- Lua refresh keeps the widget objects; a reload from 1.0.7 (cached
    -- widgets without the new ones) gains them with their defaults.
    p.h.reload('Rosie'); p.h.run(0.5)
    eq(p.h.G.RosiePlugin._elements.all_uniques_mode:get(), 1, 'reload keeps the mode widget')
    eq(p.h.mod('Rosie', 'rosie.private.unique_sorter').mode(), 1, 'the reloaded sorter reads it')
    p.h.G.RosiePlugin._elements.all_uniques, p.h.G.RosiePlugin._elements.all_uniques_mode = nil, nil
    p.h.reload('Rosie'); p.h.run(0.5)
    eq(p.h.G.RosiePlugin._elements.all_uniques:get(), false, 'reload from 1.0.7: the widget loads its persisted value')
    eq(p.h.mod('Rosie', 'rosie.private.unique_sorter').mode(), 1, 'reload from 1.0.7: mode restored by hash')
    t.h.assert_clean('menu'); p.h.assert_clean('menu persisted')
end)

case('toggle on + Unique GA 2: fresh undecided drops, plain loaded Uniques and Mythics are all taken', function()
    local t = setup()
    local a = t.pgui.elements.affix_settings
    a.uber_unique_greater_affix_slider:set(3)
    a.custom_toggle:set(true); a.unique_helm_slider:set(4); a.unique_amulet_slider:set(4)
    t.h.run(0.5)
    local rows = {
        {'fresh Leoric (no affixes listed)', item(LEORIC, {display = 'Helm', ancestral = true, ga = 0, affixes = {}})},
        {'plain Leoric GA1 listed (rc.10: skipped)', item(leoric_plain(), {ga = 1})},
        {'plain Locran GA1 listed (rc.10: skipped)', item(locran_plain(), {ga = 1})},
        {'plain non-ancestral Leoric GA0 listed', item(LEORIC, {ancestral = false, ga = 0, affixes = leoric_plain().affixes})},
        {'marked Leoric GA1 (Mythic GA 3)', leoric_mythic()},
        {'S14 Harlequin listed GA1 (Mythic GA 3)', item(HARLEQUIN, {ancestral = true, ga = 1,
            affixes = {affix(2646292, 'S14_Helm_Unique_Generic_002', 1)}})},
        {'rarity 8 GA0', {name = 'Helm_Mythic_Joint', sno = 1306338, rarity = 8, ancestral = true, ga = 0, affixes = {}}},
    }
    for _, r in ipairs(rows) do
        local w, why = t.want(t.h.gear(r[2]))
        eq(w, true, r[1] .. ': ' .. tostring(why))
        eq(why, REASON, r[1])
    end
    -- Loot filter: a plain Unique still respects it, a Mythic never does.
    local w, why = t.want(t.h.gear(item(leoric_plain(), {filtered = true})))
    eq(w, false, 'plain Unique filtered by the in-game loot filter'); eq(why, 'ingame loot filter')
    eq((t.want(t.h.gear(item(leoric_mythic(), {filtered = true})))), true, 'Mythic ignores the loot filter')
    -- Legendaries and rares keep their own rules.
    a.custom_toggle:set(false); t.h.run(0.5)
    eq((t.want(t.h.gear({name = 'Helm_Legendary_Joint', rarity = 5, ancestral = true, ga = 0, affixes = {}}))), true,
        'Legendary GA 0 (default slider 0)')
    a.greater_affix_slider:set(2); t.h.run(0.5)
    eq((t.want(t.h.gear({name = 'Helm_Legendary_Joint', rarity = 5, ancestral = true, ga = 1, affixes = {}}))), false,
        'Legendary below its GA minimum is still skipped')
    -- Off: rc.10 behaviour.
    t.e.all_uniques:set(false); t.h.run(0.5)
    w, why = t.want(t.h.gear(item(leoric_plain(), {ga = 1})))
    eq(w, false, 'toggle off: a plain Leoric GA1 is skipped again: ' .. tostring(why))
    -- Real pickup: every Unique on the floor ends up in the bag.
    t.e.all_uniques:set(true); t.h.run(0.5)
    t.h.drop('pit', 6, 0, leoric_plain()); t.h.drop('pit', -6, 0, locran_plain())
    t.h.drop('pit', 0, 6, leoric_mythic()); t.h.drop('pit', 0, -6, item(LEORIC, {display = 'Helm', ancestral = true, ga = 0, affixes = {}}))
    ok(t.h.run_until(function() return (t.h.pickups or 0) >= 4 end, 60), 'all four picked up\n' .. t.h.tail())
    eq(#(t.h.dropped or {}), 0, 'mode town: nothing dropped')
    t.h.assert_clean('pick all')
end)

case('mode Drop: the Mythic stays in the bag, the plain Unique is dropped once and never picked up again', function()
    local t = setup({mode = 'drop'})
    local plain = t.h.drop('pit', 6, 0, leoric_plain())
    local mythic = t.h.drop('pit', -6, 0, leoric_mythic())
    ok(t.h.run_until(function() return #(t.h.dropped or {}) >= 1 end, 60), 'the plain Unique is dropped\n' .. t.h.tail())
    t.h.run(20)
    eq(#t.h.dropped, 1, 'dropped exactly once')
    eq(t.h.dropped[1].bag, plain, 'the plain Leoric was dropped')
    ok(t.in_bag(mythic), 'the Mythic Leoric stays in the bag')
    ok(not t.in_bag(plain), 'the plain Leoric left the bag')
    eq(t.h.pickups, 2, 'the ground copy was never picked up again\n' .. t.h.tail())
    local ground = t.h.dropped[1].ground
    ok(ground.uid ~= plain.uid, 'the ground copy is a new actor (new identifier)')
    local w, why = t.want(ground)
    eq(w, false, 'ground copy refused'); eq(why, BLACKLISTED)
    w, why = t.evaluate(ground)
    eq(w, false, 'evaluate_item refuses it too'); eq(why, BLACKLISTED)
    local n, line = t.lines('[Rosie sort] Dropped plain Unique')
    eq(n, 1, 'one Dropped line'); ok(line:find('sno=2647147 fp=2647147#', 1, true), line)
    n, line = t.lines('[Rosie sort] Kept Mythic')
    eq(n, 1, 'one Kept line'); ok(line:find('mark=S14_Mythic_UniquePotency', 1, true), line)
    n, line = t.lines('[Rosie sort] Ground copy of')
    eq(n, 1, 'identifier diagnostic logged once'); ok(line:find('by fingerprint', 1, true) and line:find('matched=false', 1, true), line)
    -- A different plain Leoric (other roll) is a different item: taken.
    eq((t.want(t.h.gear(leoric_plain(9.5)))), true, 'another roll of the same Unique is not blacklisted')
    -- A Mythic reading is never refused, whatever the list holds.
    local m = t.h.gear(leoric_mythic()); m.pos = ground.pos; function m:get_position() return self.pos end
    eq((t.want(m)), true, 'a Mythic at the same spot is taken')
    eq(t.busy(), false, 'the Looter adapter is not busy because of the sorter')
    t.h.assert_clean('drop')
end)

case('mode Drop: the position fallback refuses a ground copy that lists no affixes', function()
    local t = setup({mode = 'drop'})
    t.h.drop_hides_affixes = true
    local plain = t.h.drop('pit', 6, 0, leoric_plain())
    ok(t.h.run_until(function() return #(t.h.dropped or {}) >= 1 end, 60), 'dropped\n' .. t.h.tail())
    t.h.run(20)
    eq(t.h.pickups, 1, 'the affix-less ground copy is not picked up\n' .. t.h.tail())
    local ground = t.h.dropped[1].ground
    eq(#ground.affixes, 0, 'host model: the copy lists no affixes')
    local w, why = t.want(ground)
    eq(w, false, 'refused by position'); eq(why, BLACKLISTED)
    local n, line = t.lines('[Rosie sort] Ground copy of')
    eq(n, 1); ok(line:find('by position', 1, true), line)
    -- Same SNO farther than 4 m from the drop spot: a new drop, taken.
    local far = t.h.gear(item(LEORIC, {display = 'Helm', ancestral = true, ga = 0, affixes = {}}))
    far.pos = t.h.v(ground.pos:x() + 5, ground.pos:y()); function far:get_position() return self.pos end
    eq((t.want(far)), true, 'same SNO 5 m away is taken')
    ok(not t.in_bag(plain), 'plain left the bag')
    -- The fallback lasts 15 min, the fingerprint 30 min; then entries expire.
    t.h.now = t.h.now + 15 * 60 + 1
    eq((t.want(ground)), true, 'after 15 min the position fallback no longer applies')
    eq(t.blacklist.count(), 1, 'the entry itself lives 30 min')
    t.h.now = t.h.now + 15 * 60
    local fp_copy = t.h.gear(plain); fp_copy.affixes = plain.affixes
    eq((t.want(fp_copy)), true, 'after 30 min the fingerprint entry expired')
    eq(t.blacklist.count(), 0, 'expired entries are pruned')
    t.h.assert_clean('fallback')
end)

case('blacklist: cap 200, cleared when a different world is entered (not by town or Limbo), never records a Mythic', function()
    local t = setup({mode = 'drop'})
    local bl = t.blacklist
    t.h.as('Rosie', function()
        for i = 1, 205 do
            bl.record(t.h.gear(item(LEORIC, {affixes = {affix(583206, 'AttackSpeed', i)}})), t.h.pos, 'x')
        end
    end)
    eq(bl.count(), 200, 'capped at 200')
    eq(t.h.as('Rosie', function() return bl.record(t.h.gear(leoric_mythic()), t.h.pos, 'm') end), nil, 'a Mythic is never recorded')
    eq(t.h.as('Rosie', function() return bl.record(t.h.gear(item(HARLEQUIN, {affixes = {affix(1, 'A', 1)}})), t.h.pos, 's14') end), nil,
        'an S14 iconic is never recorded')
    eq(t.h.as('Rosie', function() return bl.record(t.h.gear(item(LEORIC, {rarity = 8, affixes = {affix(1, 'A', 1)}})), t.h.pos, 'r8') end), nil,
        'a rarity-8 item is never recorded')
    -- Review rc.11 R2: a town, Limbo (loading) or a town trip is not a
    -- world change; entering a different world clears the list.
    t.h.place = t.h.P.kurast
    t.h.run(0.5)
    eq(bl.count(), 200, 'a town does not clear the list')
    t.h.place = t.h.P.limbo
    t.h.run(0.5)
    eq(bl.count(), 200, 'Limbo (loading) does not clear the list')
    t.h.place = t.h.P.pit
    t.h.run(0.5)
    eq(bl.count(), 200, 'back in the same world: the list is kept')
    t.h.place = t.h.P.undercity
    t.h.run(0.5)
    eq(bl.count(), 0, 'a different world clears the list')
    t.h.assert_clean('cap')
end)

case('keep rules: locked, name-filtered and GA-override Uniques are never dropped', function()
    local t = setup({mode = 'drop'})
    local tg = t.tgui.elements
    tg.ancestral_unique_filter_toggle:set(true)
    ok(tg['unique_2647147'] ~= nil, 'Leoric\'s Crown is in the Unique filter list')
    tg['unique_2647147']:set(true)
    t.h.run(1)
    local locked = t.bag_item(item(locran_plain(), {locked = true}))
    local named = t.bag_item(leoric_plain())
    -- The town's Unique GA override (default 1) keeps an Ancestral 1-GA Unique.
    local ga_kept = t.bag_item(item(locran_plain(), {ga = 1}))
    -- "Always keep mythics" off and the Mythic action Salvage: a Mythic the
    -- town rules would salvage is still never dropped.
    tg.mythic_always_keep:set(false); tg.ancestral_item_mythic:set(1)
    local mythic = t.bag_item(item(LOCRAN, {ancestral = true, ga = 0, display = "Locran's Talisman",
        affixes = {affix(1924261, 'S05_BSK_Generic_009', 1), MARK}}))
    t.h.run(10)
    eq(t.h.drop_calls, nil, 'nothing dropped\n' .. t.h.tail())
    ok(t.in_bag(locked) and t.in_bag(named) and t.in_bag(ga_kept) and t.in_bag(mythic), 'all four stay')
    eq(t.h.as('Rosie', function() return t.utils.is_salvage_or_sell(mythic, t.utils.item_enum.SALVAGE) end), true,
        'guard: the town rules would salvage that Mythic')
    -- Unique filter off: the named Leoric is no longer protected.
    tg['unique_2647147']:set(false); tg.ancestral_unique_filter_toggle:set(false)
    ok(t.h.run_until(function() return not t.in_bag(named) end, 15), 'the plain Leoric is dropped once no rule keeps it\n' .. t.h.tail())
    t.h.run(10)
    ok(t.in_bag(mythic), 'the Mythic stays')
    ok(t.in_bag(locked), 'the locked one stays')
    ok(t.in_bag(ga_kept), 'the GA-override one stays')
    eq(#t.h.dropped, 1, 'only the plain Leoric')
    t.h.assert_clean('keep rules')
end)

case('the sorter is idle during a town trip, a pause, in town, with chat open or a vendor screen', function()
    local t = setup({mode = 'drop'})
    local plain = t.bag_item(leoric_plain())
    local function idle_while(label, set, clear)
        set()
        t.h.run(6)
        eq(t.h.drop_calls, nil, label .. ': nothing dropped\n' .. t.h.tail())
        ok(t.in_bag(plain), label .. ': still in the bag')
        if clear then clear() end
    end
    idle_while('chat', function() t.h.chat_open = true end, function() t.h.chat_open = false end)
    idle_while('vendor screen', function() t.h.vendor_screen = true end, function() t.h.vendor_screen = false end)
    idle_while('pickup pause', function()
        eq(t.h.as(CONSUMER, function() return t.h.G.LooteerPlugin.acquire_pause('Consumer') end), true)
    end, function() t.h.as(CONSUMER, function() return t.h.G.LooteerPlugin.release_pause('Consumer') end) end)
    idle_while('town pause', function()
        eq(t.h.as(CONSUMER, function() return t.h.G.AlfredTheButlerPlugin.pause('Consumer') end), true)
    end, function() t.h.as(CONSUMER, function() return t.h.G.AlfredTheButlerPlugin.resume('Consumer') end) end)
    idle_while('pickup off', function() t.pgui.elements.main_toggle:set(false) end,
        function() t.pgui.elements.main_toggle:set(true) end)
    local town = setup({mode = 'drop', place = 'temis'})
    local in_town = town.bag_item(leoric_plain())
    town.h.pos = town.h.v(2560, -470)
    town.h.run(6)
    eq(town.h.drop_calls, nil, 'in town: nothing dropped')
    ok(town.in_bag(in_town), 'in town: kept for the trip')
    -- Review rc.11 P5: every town the game flags counts, not only Rosie's
    -- home town (Caldeum: HordeDev's gate, Kurast: WonderCity, Cerrigar).
    for _, where in ipairs({'caldeum', 'kurast', 'cerrigar'}) do
        local o = setup({mode = 'drop', place = where})
        local it = o.bag_item(leoric_plain())
        o.h.pos = o.h.P[where].spawn
        o.h.run(6)
        eq(o.h.drop_calls, nil, where .. ': nothing dropped')
        ok(o.in_bag(it), where .. ': kept for the trip')
        eq(o.h.as('Rosie', function() return o.sorter.update(true) end), 'in town', where .. ': sorter state')
        o.h.assert_clean('gates ' .. where)
    end
    -- A town trip: nothing is dropped from its request until it returns.
    local done
    eq(t.h.as(CONSUMER, function() return t.h.G.AlfredTheButlerPlugin.trigger_tasks_with_teleport('Consumer',
        function(a) done = a or 'ok' end) end), true, 'trip accepted')
    local dropped_during = 0
    ok(t.h.run_until(function() return done ~= nil end, 240, function()
        local s = t.alfred()
        if (s.running or s.teleport) and t.h.drop_calls then dropped_during = dropped_during + 1 end
    end), 'trip finished\n' .. t.h.tail())
    eq(dropped_during, 0, 'no drop during the trip')
    ok(not t.in_bag(plain), 'the trip sold or salvaged the plain Unique (it was in the bag at the request)')
    eq(t.h.drop_calls, nil, 'it was never dropped')
    -- After the conditions clear, the sorter works.
    local later = t.bag_item(locran_plain())
    ok(t.h.run_until(function() return t.h.drop_calls ~= nil end, 30), 'dropped once idle\n' .. t.h.tail())
    ok(t.h.run_until(function() return not t.in_bag(later) end, 10), 'left the bag')
    t.h.assert_clean('gates'); town.h.assert_clean('gates town')
end)

case('drop failure is bounded: 3 attempts, then the item is left to the town trip', function()
    for _, mode in ipairs({'error', 'false', 'stay'}) do
        local t = setup({mode = 'drop'})
        t.h.drop_fails = mode
        local plain = t.bag_item(leoric_plain())
        t.h.run(30)
        eq(t.h.drop_calls, 3, mode .. ': one attempt plus 2 retries\n' .. t.h.tail())
        ok(t.in_bag(plain), mode .. ': still in the bag')
        eq((t.lines('[Rosie sort] Could not drop')), 1, mode .. ': one give-up line')
        eq(t.blacklist.count(), 0, mode .. ': its blacklist entry is forgotten')
        t.h.run(30)
        eq(t.h.drop_calls, 3, mode .. ': never touched again')
        eq(t.sorter.stats.given_up, 1)
        eq(t.busy(), false, mode .. ': Looter adapter not busy')
        t.h.assert_clean('failure ' .. mode)
    end
end)

case('dropped Uniques cause no town trip; mode Town sends them to town instead', function()
    local function run(mode)
        local t = setup({mode = mode})
        t.tgui.elements.max_inventory:set(20)
        t.h.run(1)
        for i = 1, 17 do t.bag_item({name = 'Helm_Rare_Joint', rarity = 3, locked = true}) end
        -- Four plain Uniques 20 m apart: the bag would reach 20 in Mode Town.
        for i = 1, 4 do
            local it = leoric_plain(i)
            t.h.drop('pit', 20 * i, 0, it)
        end
        t.h.run(60)
        return t
    end
    local d = run('drop')
    eq(d.h.pickups, 4, 'drop: all four picked up\n' .. d.h.tail())
    eq(#d.h.dropped, 4, 'drop: all four dropped')
    eq(#d.h.arrivals, 0, 'drop: no town trip (no travel)')
    eq(d.alfred().outcome, nil, 'drop: no trip requested')
    eq(d.h.pickups, 4, 'drop: none picked up again')
    local tw = run('town')
    ok(#tw.h.arrivals > 0, 'town mode: the full bag triggered a trip\n' .. tw.h.tail())
    eq(#(tw.h.dropped or {}), 0, 'town mode: nothing dropped')
    d.h.assert_clean('no trip'); tw.h.assert_clean('town trip')
end)

case('mode Town: nothing is dropped; the town trip sells the plain Unique and keeps the Mythic', function()
    local t = setup({mode = 'town'})
    local plain = t.h.drop('pit', 6, 0, leoric_plain())
    local mythic = t.h.drop('pit', -6, 0, leoric_mythic())
    ok(t.h.run_until(function() return (t.h.pickups or 0) >= 2 end, 60), 'both picked up\n' .. t.h.tail())
    t.h.run(10)
    eq(t.h.drop_calls, nil, 'mode town: drop_item never called')
    eq(t.h.as(CONSUMER, function() return t.h.G.RosiePlugin.service() end), true, 'Run town service')
    ok(t.h.run_until(function() return t.alfred().outcome == 'completed' end, 240), 'trip completed\n' .. t.h.tail())
    local gone = false
    for _, list in ipairs({t.h.sold, t.h.salvaged}) do for _, x in ipairs(list) do if x == plain then gone = true end
        ok(x ~= mythic, 'the Mythic was never sold or salvaged') end end
    ok(gone, 'the plain Unique was sold or salvaged in town')
    ok(t.in_bag(mythic) or (function() for _, x in ipairs(t.h.stashed) do if x == mythic then return true end end end)(),
        'the Mythic was kept (bag or stash)')
    t.h.assert_clean('town mode')
end)

-- ── Review rc.11 regressions ─────────────────────────────────────────────
-- A fresh drop lists no affixes until its first pickup (QQT docs); its bag
-- copy (and a copy dropped again) lists them.
local function drop_fresh(h, x, y, fields, place)
    local it = h.drop(place or 'pit', x, y, fields)
    local real = it.affixes
    function it:get_affixes() if self.picked then return real end return {} end
    return it
end
local function at(h, it, x, y) it.pos = h.v(x, y); function it:get_position() return self.pos end; return it end
local function fresh_leoric(h) return h.gear(item(LEORIC, {display = 'Helm', ancestral = true, ga = 0, affixes = {}})) end

case('review R1: a boss pile of fresh drops: the Mythic form next to a dropped plain copy is picked up', function()
    for _, hides in ipairs({false, true}) do
        local label = hides and 'copy lists no affixes' or 'copy lists its affixes'
        local t = setup({mode = 'drop'})
        t.h.drop_hides_affixes = hides
        local plain = drop_fresh(t.h, 5, 0, leoric_plain())
        local myth = drop_fresh(t.h, 5, 3, leoric_mythic())
        ok(t.h.run_until(function() return t.in_bag(myth) and #(t.h.dropped or {}) >= 1 end, 60),
            label .. ': the Mythic form ends up in the bag and the plain one is dropped\n' .. t.h.tail())
        t.h.run(20)
        eq(t.h.pickups, 2, label .. ': both picked once, the dropped copy never again')
        eq(t.h.dropped[1].bag, plain, label .. ': the plain one was dropped')
        ok(t.in_bag(myth), label .. ': the Mythic stays')
        local n, line = t.lines('[Rosie sort] Ground copy of')
        eq(n, 1, label .. ': one identifier line')
        local copy_uid = t.h.dropped[1].ground.uid
        ok(line:find('ground=' .. tostring(copy_uid), 1, true), label .. ': the line names the dropped copy: ' .. line)
        ok(line:find(hides and 'by position' or 'by fingerprint', 1, true), label .. ': ' .. line)
        t.h.assert_clean('R1 ' .. label)
    end
end)

case('review R1b: a fresh same-SNO drop near the spot later is taken; only the dropped copy is refused', function()
    for _, hides in ipairs({false, true}) do
        local label = hides and 'copy lists no affixes' or 'copy lists its affixes'
        local t = setup({mode = 'drop'})
        t.h.drop_hides_affixes = hides
        -- Already on the ground before the drop, 1 m from where Rosie stands.
        local before = drop_fresh(t.h, 6, 1, item(leoric_plain(3.5), {filtered = true}))
        local plain = t.h.drop('pit', 6, 0, leoric_plain())
        ok(t.h.run_until(function() return #(t.h.dropped or {}) >= 1 end, 60), label .. ': dropped\n' .. t.h.tail())
        t.h.run(3)
        local ground = t.h.dropped[1].ground
        local w, why = t.want(ground)
        eq(w, false, label .. ': the dropped copy is refused'); eq(why, BLACKLISTED)
        w, why = t.want(item(before, {filtered = false}))
        eq(why ~= BLACKLISTED, true, label .. ': an item already on the ground before the drop is never refused')
        t.h.now = t.h.now + 300
        local fresh = at(t.h, fresh_leoric(t.h), ground.pos:x() + 2, ground.pos:y())
        w, why = t.want(fresh)
        eq(w, true, label .. ': a fresh Leoric 2 m from the spot 5 min later is taken: ' .. tostring(why))
        eq((t.want(ground)), false, label .. ': the dropped copy is still refused')
        t.h.assert_clean('R1b ' .. label)
    end
end)

case('review R2: a town trip out of a Pit and back keeps the list; the dropped copy is never picked up again', function()
    local t = setup({mode = 'drop'})
    local plain = t.h.drop('pit', 6, 0, leoric_plain())
    ok(t.h.run_until(function() return #(t.h.dropped or {}) >= 1 end, 60), 'dropped\n' .. t.h.tail())
    t.h.run(3)
    local ground = t.h.dropped[1].ground
    eq((t.want(ground)), false, 'refused before the trip')
    local p0, g0 = t.h.pickups, t.blacklist.generation()
    local done
    eq(t.h.as(CONSUMER, function() return t.h.G.AlfredTheButlerPlugin.trigger_tasks_with_teleport('Consumer',
        function(a) done = a or 'ok' end) end), true, 'trip accepted')
    ok(t.h.run_until(function() return done ~= nil end, 300), 'trip finished\n' .. t.h.tail())
    eq(t.h.place, t.h.P.pit, 'back in the Pit')
    ok(#t.h.arrivals > 0, 'the trip went to town')
    eq(t.blacklist.generation(), g0, 'the list was not cleared')
    eq(t.blacklist.count(), 1, 'the entry survives the trip')
    t.h.run(40)
    eq(t.h.pickups, p0, 'the dropped copy is never picked up again\n' .. t.h.tail())
    eq(#t.h.dropped, 1, 'dropped once')
    eq((t.lines('[Rosie sort] Dropped plain Unique')), 1, 'one Dropped line')
    ok(not t.in_bag(plain), 'plain gone')
    t.h.assert_clean('R2')
end)

case('review R3: a given-up item stays given up across a world change; a hold keeps the try count', function()
    local t = setup({mode = 'drop'})
    local a = t.bag_item(leoric_plain())
    ok(t.h.run_until(function() return not t.in_bag(a) end, 10), 'A dropped')
    t.h.drop_fails = 'error'
    local b = t.bag_item(locran_plain())
    t.h.run(30)
    eq(t.h.drop_calls, 4, 'A once, B three times')
    t.h.place, t.h.pos = t.h.P.undercity, t.h.v(0, 0)
    t.h.run(30)
    eq(t.h.drop_calls, 4, 'B is never touched again in the next world\n' .. t.h.tail())
    eq((t.lines('[Rosie sort] Could not drop')), 1, 'one give-up line')
    ok(t.in_bag(b), 'B left to the town trip')
    -- A town hold between two attempts keeps the count (3 in all).
    local u = setup({mode = 'drop'})
    u.h.drop_fails = 'stay'
    local c = u.bag_item(leoric_plain())
    ok(u.h.run_until(function() return u.h.drop_calls == 1 end, 10), 'first attempt')
    u.h.place, u.h.pos = u.h.P.caldeum, u.h.P.caldeum.spawn
    u.h.run(5)
    eq(u.h.drop_calls, 1, 'nothing in Caldeum')
    u.h.place, u.h.pos = u.h.P.pit, u.h.v(0, 0)
    u.h.run(30)
    eq(u.h.drop_calls, 3, 'the hold kept the try count\n' .. u.h.tail())
    ok(u.in_bag(c), 'still in the bag')
    eq(u.blacklist.count(), 0, 'its entry is forgotten')
    -- Mode switched to Town with a drop pending: the entry is forgotten.
    local v = setup({mode = 'drop'})
    v.h.drop_fails = 'stay'
    v.bag_item(leoric_plain())
    ok(v.h.run_until(function() return v.h.drop_calls == 1 end, 10), 'attempt')
    eq(v.blacklist.count(), 1, 'recorded before the drop')
    v.e.all_uniques_mode:set(0); v.h.run(1)
    eq(v.blacklist.count(), 0, 'mode Town: the pending entry is forgotten')
    t.h.assert_clean('R3'); u.h.assert_clean('R3 hold'); v.h.assert_clean('R3 off')
end)

case('review P3: a pile of plain Uniques near the bag limit causes no town trip in mode Drop', function()
    local t = setup({mode = 'drop'})
    t.tgui.elements.max_inventory:set(20)
    t.h.run(1)
    for i = 1, 17 do t.bag_item({name = 'Helm_Rare_Joint', rarity = 3, locked = true}) end
    local pile = {}
    for i = 1, 4 do pile[i] = t.h.drop('pit', 6 + i * 0.3, 0, leoric_plain(i)) end
    t.h.run(40)
    eq(t.h.pickups, 4, 'all four picked up\n' .. t.h.tail())
    eq(#t.h.dropped, 4, 'all four dropped')
    eq(#t.h.arrivals, 0, 'no town trip\n' .. t.h.tail())
    eq(t.alfred().outcome, nil, 'no trip requested')
    -- The census still counts them when the sorter cannot act (mode Town).
    local tw = setup({mode = 'town'})
    tw.tgui.elements.max_inventory:set(20)
    tw.h.run(1)
    for i = 1, 17 do tw.bag_item({name = 'Helm_Rare_Joint', rarity = 3, locked = true}) end
    for i = 1, 4 do tw.h.drop('pit', 6 + i * 0.3, 0, leoric_plain(i)) end
    tw.h.run(40)
    ok(#tw.h.arrivals > 0, 'mode Town: the full bag still triggers a trip\n' .. tw.h.tail())
    t.h.assert_clean('pile'); tw.h.assert_clean('pile town')
end)

case('review P7: with the option on, a Unique taken from the ground still logs its ground probe', function()
    local t = setup({mode = 'town'})
    t.h.drop('pit', 6, 0, item(LEORIC, {display = 'Helm', ancestral = true, ga = 0, affixes = {}}))
    t.h.drop('pit', -6, 0, item(LEORIC, {ancestral = true, ga = 1, affixes = leoric_plain().affixes}))
    ok(t.h.run_until(function() return (t.h.pickups or 0) >= 2 end, 40), 'both taken\n' .. t.h.tail())
    eq((t.lines('[Rosie mythic-probe] taken')), 2, 'one ground probe per taken Unique')
    t.h.assert_clean('probe')
end)

case('review P4: mode Drop does not read the bag every tick while nothing is pending', function()
    local function reads(mode)
        local t = setup({mode = mode})
        for i = 1, 20 do t.bag_item({name = 'Helm_Rare_Joint', rarity = 3}) end
        local player = t.h.G.get_local_player()
        local n, base = 0, player.get_inventory_items
        player.get_inventory_items = function(self) n = n + 1; return base(self) end
        t.h.run(10)
        player.get_inventory_items = base
        eq(t.h.drop_calls, nil, mode .. ': nothing to drop')
        return n / 10
    end
    local town, drop = reads('town'), reads('drop')
    ok(drop - town <= 2.5, string.format('drop mode adds at most one bag read per scan (0.5 s): town %.1f/s, drop %.1f/s', town, drop))
end)

print('Rosie unique sorter: ' .. checks .. ' checks')
if #failures > 0 then error(#failures .. ' failure(s):\n' .. table.concat(failures, '\n')) end
