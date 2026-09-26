-- Rosie 1.0.7 (2.3.0-rc.10): Mythic Uniques are never skipped or destroyed.
-- Live facts this file pins (see CHANGELOG 2.3.0-rc.10):
--  * rc.8 Uber Mephisto: fresh Unique drops were skipped as
--    "Helm | sno=2647147 rarity=6 ancestral=true GA=0 ... unique_general:2".
--    QQT docs: a ground item's affix table is empty until it was picked up once.
--  * rc.10 session dump of a Leoric's Crown dropped from the bag: GA 1,
--    display "Leoric's Crown {icon:AttributeBullet_GreaterAffix, 1.5}",
--    affixes incl. S14_Mythic_UniquePotency#2628989; Rosie then logged
--    "Wanted Leoric's Crown ... threshold=mythic_general:0".
--  * d4data: Locran's Talisman / Endurant Faith carry a Unique power that is
--    NOT named after the item (S05_BSK_Generic_009 / _001); the 14 S14
--    re-issued iconic Mythics are rarity 6 with catalog quality "unique".
-- Rows S1..S10 are the decision matrix (scratchpad test_mythic_matrix.lua).
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
    if passed then print('PASS mythic: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL mythic: ' .. name .. ': ' .. tostring(err)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function affix(hash, name) return {affix_name_hash = hash, get_name = function() return name end} end
local MARK = affix(2628989, 'S14_Mythic_UniquePotency')

-- Pickup: distance 30, Unique GA 2, Mythic GA 0 (the live rc.8 settings).
local function setup(opts)
    opts = opts or {}
    opts.rosie, opts.dirs, opts.place = true, {}, opts.place or 'pit'
    local h = J.new(opts)
    h.assert_clean('load')
    h.pos = h.v(0, 0)
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    local pgui = h.mod('Rosie', 'rosie.private.pickup.gui')
    pgui.elements.general.distance_slider:set(30)
    pgui.elements.affix_settings.unique_greater_affix_slider:set(2)
    h.run(1)
    local im = h.mod('Rosie', 'rosie.private.pickup.src.item_manager')
    local utils = h.mod('Rosie', 'rosie.private.town.core.utils')
    local t = {h = h, im = im, utils = utils, pgui = pgui}
    function t.want(item) return h.as('Rosie', function() return im.check_want_item(item, true) end) end
    function t.acts(item)
        return h.as('Rosie', function()
            return utils.is_salvage_or_sell(item, utils.item_enum.SALVAGE) or utils.is_salvage_or_sell(item, utils.item_enum.SELL)
        end)
    end
    function t.lines(prefix)
        local n, last = 0, nil
        for _, line in ipairs(h.log) do if tostring(line):find(prefix, 1, true) then n = n + 1; last = tostring(line) end end
        return n, last
    end
    return t
end

local LEORIC = {name = 'Helm_Unique_Generic_005', sno = 2647147, rarity = 6}
local LOCRAN = {name = 'S05_BSK_Amulet_Unique_Generic_001', sno = 1944508, rarity = 6}
local HARLEQUIN = {name = 'S14_Helm_Unique_Generic_002', sno = 2646291, rarity = 6}
local function item(base, fields)
    local out = {}
    for k, v in pairs(base) do out[k] = v end
    for k, v in pairs(fields) do out[k] = v end
    return out
end
local LEORIC_LISTED = function() return {affix(2662414, 'Helm_Unique_Generic_005'), affix(583206, 'AttackSpeed')} end
local LOCRAN_LISTED = function() return {affix(1924261, 'S05_BSK_Generic_009'), affix(2602164, 'X2_CritDamage_Greater')} end
local HARLEQUIN_LISTED = function() return {affix(2646292, 'S14_Helm_Unique_Generic_002'), affix(1829592, 'S04_Life')} end

case('matrix S1-S10: ground and town decisions for rarity-6 readings', function()
    local t = setup()
    local rows = {
        -- id, fields, pickup expected, town must not destroy (nil: not asserted)
        {'S1 live rc.8: Leoric ancestral GA0 affixes={}', item(LEORIC, {display = 'Helm', ancestral = true, ga = 0, affixes = {}}), true, true},
        {'S2 Leoric ancestral GA0 power listed, no mark', item(LEORIC, {ancestral = true, ga = 0, affixes = LEORIC_LISTED()}), true, nil},
        {'S3 Locran ancestral GA0 listed, no mark', item(LOCRAN, {ancestral = true, ga = 0, affixes = LOCRAN_LISTED()}), true, nil},
        {'S4 Locran ancestral GA1 listed, no mark (plain)', item(LOCRAN, {ancestral = true, ga = 1, affixes = LOCRAN_LISTED()}), false, nil},
        {'S5 Leoric ancestral GA1 with the mark', item(LEORIC, {ancestral = true, ga = 1, affixes = {affix(2662414, 'Helm_Unique_Generic_005'), MARK}}), true, true},
        {'S6 Leoric non-ancestral GA0 listed (plain)', item(LEORIC, {ancestral = false, ga = 0, affixes = LEORIC_LISTED()}), false, nil},
        {'S7 S14 Harlequin Crest ancestral GA1 no mark', item(HARLEQUIN, {ancestral = true, ga = 1, affixes = HARLEQUIN_LISTED()}), true, true},
        {'S8 Leoric ancestral GA1 power listed, no mark (plain)', item(LEORIC, {ancestral = true, ga = 1, affixes = LEORIC_LISTED()}), false, nil},
        {'S9 S14 Harlequin Crest ancestral GA0 listed no mark', item(HARLEQUIN, {ancestral = true, ga = 0, affixes = HARLEQUIN_LISTED()}), true, true},
        {'S10 Leoric non-ancestral GA0 affixes={}', item(LEORIC, {ancestral = false, ga = 0, affixes = {}}), true, true},
    }
    for _, r in ipairs(rows) do
        local wanted, why = t.want(t.h.gear(r[2]))
        eq(wanted, r[3], r[1] .. ' pickup (' .. tostring(why) .. ')')
        if r[4] then eq(t.acts(t.h.gear(r[2])), false, r[1] .. ': never sold or salvaged in town') end
    end
    -- The S14 re-issue uses the Mythic GA rule, not "may be a Mythic".
    local _, why = t.want(t.h.gear(item(HARLEQUIN, {ancestral = true, ga = 1, affixes = HARLEQUIN_LISTED()})))
    ok(tostring(why):find('threshold=mythic_general', 1, true), tostring(why))
    t.h.assert_clean('matrix')
end)

case('undecided reasons and the describe() fields', function()
    local t = setup()
    local fresh = t.h.gear(item(LEORIC, {display = 'Helm', ancestral = true, ga = 0, affixes = {}}))
    local _, why = t.want(fresh)
    ok(tostring(why):find('may be a Mythic Unique (no affixes listed; decided in town)', 1, true), tostring(why))
    local line = t.im.describe(fresh, why)
    ok(line:find('mythic_mark=false undecided=no affixes listed affixes=0', 1, true), line)
    local listed = t.h.gear(item(LEORIC, {ancestral = true, ga = 0, affixes = LEORIC_LISTED()}))
    _, why = t.want(listed)
    ok(tostring(why):find('(Ancestral, 0 Greater Affixes read; decided in town)', 1, true), tostring(why))
    ok(t.im.describe(listed, why):find('affixes=2', 1, true), t.im.describe(listed, why))
    local broken = t.h.gear(item(LEORIC, {ancestral = true, ga = 0}))
    function broken:get_affixes() error('host: affixes unreadable') end
    _, why = t.want(broken)
    ok(tostring(why):find('(affixes unreadable;', 1, true), tostring(why))
    ok(t.im.describe(broken, why):find('affixes=unreadable', 1, true), t.im.describe(broken, why))
    -- The matching mark affix is named in the line (keep direction).
    local marked = t.h.gear(item(LEORIC, {ancestral = true, ga = 1, affixes = {affix(2662414, 'Helm_Unique_Generic_005'), MARK}}))
    ok(t.im.describe(marked, 'x'):find('mythic_mark=S14_Mythic_UniquePotency', 1, true), t.im.describe(marked, 'x'))
    t.h.assert_clean('describe')
end)

case('mark: hash 2628989 or any affix name containing "Mythic"; "...Potency" is not a mark', function()
    local t = setup()
    local by_hash = t.h.gear(item(LEORIC, {ancestral = true, ga = 1, affixes = {affix(2662414, 'Helm_Unique_Generic_005'), {affix_name_hash = 2628989}}}))
    local w, why = t.want(by_hash)
    eq(w, true, 'hash-only mark: ' .. tostring(why))
    local other_word = t.h.gear(item(LEORIC, {ancestral = true, ga = 1,
        affixes = {affix(2662414, 'Helm_Unique_Generic_005'), affix(7777777, 'S15_Mythic_Upgrade_Other')}}))
    w, why = t.want(other_word)
    eq(w, true, 'an affix named ...Mythic... marks it (keep direction): ' .. tostring(why))
    ok(tostring(why):find('mythic_general', 1, true), tostring(why))
    ok(t.im.describe(other_word, why):find('mythic_mark=S15_Mythic_Upgrade_Other', 1, true), t.im.describe(other_word, why))
    eq(t.acts(t.h.gear(item(LEORIC, {ancestral = true, ga = 0,
        affixes = {affix(2662414, 'Helm_Unique_Generic_005'), affix(7777777, 'S15_Mythic_Upgrade_Other')}}))), false,
        'town keeps a Unique with a ...Mythic... affix')
    eq(t.want(t.h.gear(item(LEORIC, {ancestral = true, ga = 1,
        affixes = {affix(2662414, 'Helm_Unique_Generic_005'), affix(1111111, 'UNIQUE_Double_Damage_Tag_Generic_Potency')}}))),
        false, 'an ordinary ...Potency affix is not a mark')
    -- Item_Quality_Modifier_Bits is logged only, never a decision input.
    eq(t.want(t.h.gear(item(LEORIC, {ancestral = true, ga = 1, attrs = {Item_Quality_Modifier_Bits = 4 + 32},
        affixes = LEORIC_LISTED()}))), false, 'quality bits never promote')
    t.h.assert_clean('mark')
end)

case('real live dump (rc.10 session): tempered Leoric\'s Crown with the potency affix is wanted and kept', function()
    local t = setup()
    local dump = {
        affix(583206, 'AttackSpeed'), affix(2662414, 'Helm_Unique_Generic_005'),
        affix(1829574, 'S04_CoreStat_Willpower'), affix(2628989, 'S14_Mythic_UniquePotency'),
        affix(1829592, 'S04_Life'), affix(1862295, 'Tempered_Generic_LifeMax_Tier3'),
        affix(2532220, 'S04_Resource_Per_Second_Wrath'),
    }
    local crown = item(LEORIC, {display = "Leoric's Crown {icon:AttributeBullet_GreaterAffix, 1.5}", ancestral = true,
        ga = 1, affixes = dump})
    local w, why = t.want(t.h.gear(crown))
    eq(w, true, tostring(why))
    ok(tostring(why):find('threshold=mythic_general', 1, true), tostring(why))
    eq(t.acts(t.h.gear(crown)), false, 'never sold or salvaged')
    t.h.assert_clean('live dump')
end)

case('Locran\'s Talisman (power affix not named after the item)', function()
    local t = setup()
    local w, why = t.want(t.h.gear(item(LOCRAN, {ancestral = true, ga = 1, affixes = {affix(1924261, 'S05_BSK_Generic_009'), MARK}})))
    eq(w, true, tostring(why))
    ok(tostring(why):find('mythic_general', 1, true), 'Mythic rule: ' .. tostring(why))
    local plain = t.h.gear(item(LOCRAN, {ancestral = true, ga = 1, affixes = LOCRAN_LISTED()}))
    w, why = t.want(plain)
    eq(w, false, 'a known plain Locran\'s (GA 1 < 2) follows the Unique GA rule: ' .. tostring(why))
    ok(t.im.describe(plain, why):find('undecided=no affixes=2', 1, true), t.im.describe(plain, why))
    t.h.assert_clean('locran')
end)

case('town: a bag Unique whose affixes are unreadable or empty is never sold or salvaged', function()
    local t = setup({place = 'temis'})
    local unreadable = t.h.gear(item(LEORIC, {ancestral = true, ga = 0, affixes = {}}))
    function unreadable:get_affixes() error('host: affixes unreadable') end
    eq(t.acts(unreadable), false, 'unreadable bag Unique kept')
    eq(t.acts(t.h.gear(item(LEORIC, {ancestral = true, ga = 0, affixes = {}}))), false, 'empty-affix bag Unique kept')
    eq(t.acts(t.h.gear(item(LEORIC, {ancestral = false, ga = 0, affixes = {}}))), false, 'non-ancestral empty-affix Unique kept')
    -- Guard: a plain loaded 0-GA ancestral Unique still follows the Unique rule.
    eq(t.acts(t.h.gear(item(LEORIC, {ancestral = true, ga = 0, affixes = LEORIC_LISTED()}))), true,
        'a readable plain 0-GA Unique is still sold or salvaged')
    t.h.assert_clean('town guard')
end)

case('ground probe lines are bounded: at most 3 per drop, one reading per second', function()
    local t = setup()
    local drop = t.h.drop('pit', 12, 0, item(LEORIC, {ancestral = true, ga = 1, affixes = LEORIC_LISTED()}))
    t.h.run(2)
    local n, line = t.lines('[Rosie mythic-probe] skipped')
    eq(n, 1, 'one probe line\n' .. t.h.tail())
    ok(line:find('qbits=nil', 1, true) and line:find('mark=nil', 1, true) and line:find('affixes=2 [', 1, true), line)
    local function change(i) drop.affixes[#drop.affixes + 1] = affix(3000000 + i, 'S04_Filler_' .. i) end
    change(1); t.h.run(0.3)
    eq((t.lines('[Rosie mythic-probe] skipped')), 2, 'a changed reading is logged again\n' .. t.h.tail())
    change(2); t.h.run(0.3)
    eq((t.lines('[Rosie mythic-probe] skipped')), 2, 'one reading per second per drop')
    t.h.run(1.5)
    eq((t.lines('[Rosie mythic-probe] skipped')), 3, 'the held reading is logged after the second')
    change(3); t.h.run(3)
    eq((t.lines('[Rosie mythic-probe] skipped')), 3, 'at most 3 probe lines per drop')
    t.h.assert_clean('probe bound')
end)

-- Review rc.10 (major): a fresh drop lists no affixes and reads GA 0 whatever
-- it carries, so no GA rule can be judged; the Mythic GA slider must never
-- turn a fresh Mythic (S14 iconic, rarity 8, Leoric's that may be a form) into a skip.
case('fresh drops (affixes={}) are taken whichever Mythic GA slider is stricter', function()
    local t = setup()
    local a = t.pgui.elements.affix_settings
    local function fresh(base, fields)
        local out = item(base, {display = 'Helm', ancestral = true, ga = 0, affixes = {}})
        for k, v in pairs(fields or {}) do out[k] = v end
        return t.h.gear(out)
    end
    local function set(unique, mythic, custom)
        a.unique_greater_affix_slider:set(unique); a.uber_unique_greater_affix_slider:set(mythic)
        a.custom_toggle:set(custom == true); t.h.run(0.5)
    end
    local rows = {
        {'S14 Harlequin, Unique 2 / Mythic 1', HARLEQUIN, 2, 1},
        {'S14 Harlequin, Unique 0 / Mythic 1', HARLEQUIN, 0, 1},
        {'S14 Starless Skies, Unique 0 / Mythic 2', {name = 'S14_Ring_Unique_Generic_001', sno = 2629581, rarity = 6}, 0, 2},
        {'Leoric, Unique 2 / Mythic 2', LEORIC, 2, 2},
        {'Leoric, slot override (helm 2) / Mythic 2', LEORIC, 2, 2, true},
        {'Leoric, Unique 2 / Mythic 3', LEORIC, 2, 3},
        {'Leoric, Unique 2 / Mythic 1', LEORIC, 2, 1},
        {'rarity 8, Mythic 1', {name = 'Helm_Mythic_Joint', sno = 1306338, rarity = 8}, 0, 1},
        {'rarity 8, Mythic 2', {name = 'Helm_Mythic_Joint', sno = 1306338, rarity = 8}, 0, 2},
    }
    for _, r in ipairs(rows) do
        set(r[3], r[4], r[5])
        local w, why = t.want(fresh(r[2]))
        eq(w, true, r[1] .. ': ' .. tostring(why))
        ok(tostring(why):find('decided in town', 1, true), r[1] .. ': ' .. tostring(why))
    end
    -- An unreadable affix list is as blind as an empty one.
    set(2, 3)
    local broken = fresh(LEORIC)
    function broken:get_affixes() error('host: affixes unreadable') end
    eq((t.want(broken)), true, 'unreadable affixes with a stricter Mythic rule are taken')
    -- Listed affixes are a reading: the stricter Mythic rule still applies to
    -- an Ancestral 0-GA Unique, and a listed S14 iconic below Mythic GA is skipped.
    eq((t.want(t.h.gear(item(LEORIC, {ancestral = true, ga = 0, affixes = LEORIC_LISTED()})))), false,
        'Mythic GA 3 > Unique GA 2: a listed 0-GA Unique follows the Unique rule')
    set(2, 2)
    eq((t.want(t.h.gear(item(HARLEQUIN, {ancestral = true, ga = 1, affixes = HARLEQUIN_LISTED()})))), false,
        'a listed S14 iconic with GA 1 < Mythic GA 2 is skipped')
    t.h.assert_clean('fresh sliders')
end)

-- Review rc.10 (minor): the in-game loot filter never refuses a mythic
-- (the town rules exempt mythics the same way).
case('respect in-game loot filter never skips a mythic', function()
    local t = setup()
    t.pgui.elements.affix_settings.unique_greater_affix_slider:set(0)
    t.h.run(0.5)
    local rows = {
        {'rarity 8', {name = 'Helm_Mythic_Joint', sno = 1306338, rarity = 8, ancestral = true, ga = 0, affixes = {}}},
        {'S14 Harlequin', item(HARLEQUIN, {ancestral = true, ga = 0, affixes = {}})},
        {'marked Leoric', item(LEORIC, {ancestral = true, ga = 1, affixes = {affix(2662414, 'Helm_Unique_Generic_005'), MARK}})},
    }
    for _, r in ipairs(rows) do
        local fields = item(r[2], {filtered = true})
        local w, why = t.want(t.h.gear(fields))
        eq(w, true, r[1] .. ' filtered by the in-game loot filter: ' .. tostring(why))
    end
    local w, why = t.want(t.h.gear(item(LEORIC, {ancestral = true, ga = 1, affixes = LEORIC_LISTED(), filtered = true})))
    eq(w, false, 'a plain Unique still respects the loot filter')
    eq(why, 'ingame loot filter', tostring(why))
    t.h.assert_clean('loot filter')
end)

print('Rosie mythic rc.10: ' .. checks .. ' checks')
if #failures > 0 then error(#failures .. ' failure(s):\n' .. table.concat(failures, '\n')) end
