-- Rosie keep menu (QQT_Warpigz_v3). User report (3.2.x, Russian): "My filter is set
-- to keep Leoric's Crown, but Rosie doesn't keep it", and the screenshot of the
-- old Ancestral tree: Always keep mythics ON, "Use Mythic Unique filter" ON with
-- "unchecked Mythic Uniques" = Salvage (nothing checked there), "Use
-- unique/mythic filter" ON with Leoric's Crown checked, all GA sliders 0.
-- Live: Leoric's Crown drops as a Mythic form (S14_Mythic_UniquePotency 2628989).
-- Root cause: the Mythic Unique filter decided before Always keep mythics and
-- before the Unique list, so the checked Mythic Leoric was salvaged. The 3.2.4
-- hotfix rules (test_rosie_keep_checked_324.lua) hold in the restructured menu.
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
    if passed then print('PASS keep-menu: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL keep-menu: ' .. name .. ': ' .. tostring(err)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local P = 'alfred_the_butler_'
local KEEP, SALVAGE, SELL = 0, 1, 2
local function affix(hash, name) return {affix_name_hash = hash, get_name = function() return name end} end
local MARK = affix(2628989, 'S14_Mythic_UniquePotency')
local function item(base, fields)
    local out = {}
    for k, v in pairs(base) do out[k] = v end
    for k, v in pairs(fields or {}) do out[k] = v end
    return out
end
local LEORIC = {name = 'Helm_Unique_Generic_005', sno = 2647147, rarity = 6, display = "Leoric's Crown"}
local LEORIC_PLAIN = {affix(2662414, 'Helm_Unique_Generic_005'), affix(583206, 'AttackSpeed')}
local LEORIC_MYTHIC = {affix(2662414, 'Helm_Unique_Generic_005'), affix(583206, 'AttackSpeed'), MARK}
local CONDEMNATION = {name = 'Dagger_Unique_Generic_001', sno = 451091, rarity = 6}
local HARLEQUIN_S14 = {name = 'S14_Helm_Unique_Generic_002', sno = 2646291, rarity = 6,
    affixes = {affix(2646292, 'S14_Helm_Unique_Generic_002')}}
local HARLEQUIN_OLD = {name = 'Helm_Mythic_Joint', sno = 609820, rarity = 8, affixes = {affix(1, 'x')}}
-- The user's screenshot, as saved widget values of the old menu.
local USER = {[P .. 'use_unique_filter'] = true, [P .. 'unique_2647147'] = true,
    [P .. 'mythic_form_filter'] = true, [P .. 'mythic_always_keep'] = true,
    [P .. 'ancestral_item_mythic'] = KEEP, [P .. 'ancestral_item_unique'] = SALVAGE,
    [P .. 'mythic_form_other'] = SALVAGE}

local function setup(opts)
    opts = opts or {}
    opts.rosie, opts.dirs, opts.place = true, {}, opts.place or 'pit'
    local h = J.new(opts)
    h.assert_clean('load')
    h.pos = h.v(0, 0)
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    local tg = h.mod('Rosie', 'rosie.private.town.gui').elements
    -- The screenshot's sliders (sliders do not persist in the joint host).
    tg.ancestral_unique_ga_count_slider:set(0); tg.ancestral_mythic_ga_count_slider:set(0); tg.ancestral_ga_count_slider:set(0)
    h.run(1.5)
    local utils = h.mod('Rosie', 'rosie.private.town.core.utils')
    local t = {h = h, tg = tg, utils = utils, settings = h.mod('Rosie', 'rosie.private.town.core.settings'),
        pgui = h.mod('Rosie', 'rosie.private.pickup.gui'), im = h.mod('Rosie', 'rosie.private.pickup.src.item_manager')}
    function t.verdict(fields)
        local it = h.gear(fields)
        return h.as('Rosie', function()
            if utils.is_salvage_or_sell(it, SALVAGE) then return 'salvage' end
            if utils.is_salvage_or_sell(it, SELL) then return 'sell' end
            return 'keep'
        end)
    end
    function t.want(fields) return h.as('Rosie', function() return t.im.check_want_item(h.gear(fields), true) end) end
    function t.lines(text)
        local n, last = 0, nil
        for _, line in ipairs(h.log) do if tostring(line):find(text, 1, true) then n = n + 1; last = tostring(line) end end
        return n, last
    end
    return t
end

case("user report: a checked Leoric's Crown is kept as plain Unique AND as Mythic form (screenshot settings)", function()
    local t = setup({persisted = USER})
    eq(t.verdict(item(LEORIC, {ancestral = true, ga = 1, affixes = LEORIC_MYTHIC})), 'keep', 'the Mythic Leoric (live dump)')
    eq(t.verdict(item(LEORIC, {ancestral = true, ga = 0, affixes = LEORIC_MYTHIC})), 'keep', 'Mythic Leoric, 0 GA')
    eq(t.verdict(item(LEORIC, {ancestral = true, ga = 0, affixes = LEORIC_PLAIN})), 'keep', 'plain Ancestral Leoric')
    eq(t.verdict(item(LEORIC, {ancestral = false, ga = 0, affixes = LEORIC_PLAIN})), 'keep',
        'plain non-Ancestral Leoric (the old list only applied to Ancestral items: it was sold)')
    eq(t.verdict(item(LEORIC, {ancestral = true, ga = 0, affixes = LEORIC_PLAIN, junk = true})), 'keep', 'junk mark: Always keep wins')
    -- Guard: an unchecked plain Unique still follows 4. Uniques (Salvage).
    eq(t.verdict(item(CONDEMNATION, {ancestral = true, ga = 0, affixes = {affix(3, 'Dagger_Unique_Generic_001')}})), 'salvage',
        'an unlisted plain Unique is still salvaged')
    -- Always keep Mythics wins over "unchecked Mythic Uniques = Salvage".
    eq(t.verdict(item(CONDEMNATION, {ancestral = true, ga = 0, affixes = {affix(3, 'Dagger_Unique_Generic_001'), MARK}})), 'keep',
        'an unchecked Mythic Unique is kept (Always keep Mythics is on)')
    local n = t.lines("[Rosie] Kept Leoric's Crown: Mythic (Always keep mythics) (Mythic Unique, sno=2647147)")
    eq(n, 1, 'one keep line for the Mythic form\n' .. t.h.tail())
    n = t.lines("[Rosie] Kept Leoric's Crown: checked in \"Unique items I always keep\" (Unique, sno=2647147)")
    eq(n, 1, 'one keep line for the plain Unique')
    t.tg.mythic_always_keep:set(false); t.h.run(1.5)
    eq(t.verdict(item(LEORIC, {ancestral = true, ga = 1, affixes = LEORIC_MYTHIC})), 'keep', 'Always keep off: the list keeps the Mythic form')
    n = t.lines("[Rosie] Kept Leoric's Crown: checked in \"Unique items I always keep\" (Mythic Unique, sno=2647147)")
    eq(n, 1, 'its keep line')
    t.h.assert_clean('user report')
end)

case('old precedence regression: a Unique-list item beats "Mythic Uniques not checked = Salvage"', function()
    local t = setup({persisted = USER})
    t.tg.mythic_always_keep:set(false)
    t.h.run(1.5)
    eq(t.verdict(item(LEORIC, {ancestral = true, ga = 1, affixes = LEORIC_MYTHIC})), 'keep',
        "the Mythic Leoric checked in 'Unique items I always keep' is kept")
    local cond_mythic = item(CONDEMNATION, {ancestral = true, ga = 0, affixes = {affix(3, 'Dagger_Unique_Generic_001'), MARK}})
    local cond_plain = item(CONDEMNATION, {ancestral = true, ga = 0, affixes = {affix(3, 'Dagger_Unique_Generic_001')}})
    eq(t.verdict(cond_mythic), 'salvage', 'an unchecked Mythic Unique takes the rest action')
    local n, line = t.lines("[Rosie] Will salvage ")
    ok(n >= 1 and line:find("'Mythic Uniques not checked' action", 1, true), tostring(line))
    -- 'Mythic Uniques to keep' keeps both forms.
    t.tg.mythic_form_451091:set(true); t.h.run(1.5)
    eq(t.verdict(cond_mythic), 'keep', 'checked Mythic Unique kept')
    eq(t.verdict(cond_plain), 'keep', 'its plain Unique is kept too')
    -- The Mythic GA rule keeps an unchecked one.
    t.tg.mythic_form_451091:set(false); t.tg.ancestral_mythic_ga_count_slider:set(1); t.h.run(1.5)
    eq(t.verdict(item(cond_mythic, {ga = 1})), 'keep', 'Also keep Mythics with Greater Affixes >= 1')
    eq(t.verdict(cond_mythic), 'salvage', 'below it: salvaged')
    t.tg.mythic_form_other:set(SELL); t.h.run(1.5)
    eq(t.verdict(cond_mythic), 'sell', 'Mythic Uniques not checked: Sell')
    t.tg.mythic_form_filter_toggle:set(false); t.tg.ancestral_item_mythic:set(SALVAGE); t.h.run(1.5)
    eq(t.verdict(cond_mythic), 'salvage', 'separate list off: the Iconic Mythic action')
    t.h.assert_clean('precedence')
end)

case('the keep list beats the in-game loot filter and the Unique GA rule; locked items are never touched', function()
    local t = setup({persisted = {[P .. 'unique_2647147'] = true, [P .. 'loot_filter_mode'] = true}})
    eq(t.verdict(item(LEORIC, {ancestral = true, ga = 0, affixes = LEORIC_PLAIN, filtered = true})), 'keep', 'filtered but listed')
    eq(t.verdict(item(CONDEMNATION, {ancestral = true, ga = 0, affixes = {affix(3, 'x')}, filtered = true})), 'salvage',
        'guard: a filtered unlisted Unique is salvaged')
    local locked = item(CONDEMNATION, {ancestral = true, ga = 0, affixes = {affix(3, 'x')}, filtered = true, locked = true})
    eq(t.verdict(locked), 'keep', 'locked: never touched')
    t.h.assert_clean('loot filter')
end)

case('Iconic Mythics: S14 re-issues are in the Iconic list (one row per name); the re-issue matches the older row', function()
    local t = setup()
    local utils = t.utils
    ok(t.tg.mythic_609820 ~= nil, 'Harlequin Crest row (older SNO keeps its saved row)')
    local rows, in_unique = 0, false
    for _, row in ipairs(utils.get_mythic_items()) do if row.name == 'Harlequin Crest' then rows = rows + 1 end end
    for _, row in ipairs(utils.get_unique_items()) do if row.sno_id == 2646291 then in_unique = true end end
    eq(rows, 1, 'one Harlequin Crest row')
    eq(in_unique, false, 'not a plain Unique / Mythic Unique row any more')
    eq(utils.iconic_row_id(2646291), 609820, 'the re-issue maps to the older row')
    eq(t.verdict(item(HARLEQUIN_S14, {ancestral = true, ga = 0})), 'keep', 'Always keep Mythics')
    t.tg.mythic_always_keep:set(false); t.tg.ancestral_item_mythic:set(SALVAGE); t.h.run(1.5)
    eq(t.verdict(item(HARLEQUIN_S14, {ancestral = true, ga = 0})), 'keep', 'checked by default')
    t.tg.mythic_609820:set(false); t.h.run(1.5)
    eq(t.verdict(item(HARLEQUIN_S14, {ancestral = true, ga = 0})), 'salvage', 'unchecked: the Iconic action')
    eq(t.verdict(item(HARLEQUIN_OLD, {ancestral = true, ga = 0})), 'salvage', 'unchecked: the older SNO too')
    t.h.assert_clean('iconic')
end)

case('saved choices keep their widgets; the Unique list no longer needs its old switch', function()
    local t = setup({persisted = {[P .. 'mythic_always_keep'] = false, [P .. 'mythic_form_filter'] = true,
        [P .. 'mythic_form_other'] = SELL, [P .. 'unique_2647147'] = true, [P .. 'use_unique_filter'] = false}})
    eq(t.settings.mythic_always_keep, false, 'Always keep Mythics as saved')
    eq(t.settings.mythic_form_filter, true, 'separate Mythic Unique list as saved')
    eq(t.settings.mythic_form_other, SELL, 'its action as saved')
    eq(t.settings.ancestral_unique[2647147], true, 'the saved Unique selection')
    eq(t.verdict(item(LEORIC, {ancestral = true, ga = 0, affixes = LEORIC_PLAIN})), 'keep',
        'a checked Unique is kept even though the old switch was off (keeps more)')
    t.h.assert_clean('saved')
end)

case('pickup: a listed Unique is taken whatever the GA sliders or the in-game loot filter say', function()
    local t = setup({persisted = {[P .. 'unique_2647147'] = true}})
    t.pgui.elements.general.distance_slider:set(30)
    t.pgui.elements.affix_settings.unique_greater_affix_slider:set(2)
    t.pgui.elements.general.respect_filter_toggle:set(true)
    t.h.run(1)
    local w, why = t.want(item(LEORIC, {ancestral = true, ga = 0, affixes = LEORIC_PLAIN, filtered = true}))
    eq(w, true, tostring(why))
    eq(why, "accepted: selected in 'Unique items I always keep'", 'reason')
    w, why = t.want(item(CONDEMNATION, {ancestral = true, ga = 1, affixes = {affix(3, 'x')}}))
    eq(w, false, 'guard: an unlisted Unique below the GA slider is skipped (' .. tostring(why) .. ')')
    -- Mythic Uniques list (used while not Keep all) and Iconic list.
    t.tg.mythic_always_keep:set(false); t.tg.mythic_form_filter_toggle:set(true); t.tg.mythic_form_451091:set(true); t.h.run(1.5)
    w, why = t.want(item(CONDEMNATION, {ancestral = true, ga = 1, affixes = {affix(3, 'x')}}))
    eq(why, "accepted: selected in 'Mythic Uniques to keep'", tostring(why))
    t.h.assert_clean('pickup')
end)

case('menu: numbered sections in decision order, Mythic choices only while Always keep Mythics is off; rows say which forms are kept', function()
    local t = setup({persisted = USER})
    t.h.menu_labels = {}
    t.h.frame()
    local labels = t.h.menu_labels
    local function at(label)
        for i, l in ipairs(labels) do if l == label then return i end end
        return nil
    end
    for _, label in ipairs({'Always keep Mythics', 'Keep Uniques with Item Power at least', 'Keep with Greater Affixes at least',
            'Otherwise: Ancestral Uniques', 'Otherwise: Non-Ancestral Uniques', 'Ancestral junk',
            'Keep Ancestral with Greater Affixes at least', "Leoric's Crown - helm  [keeps plain + Mythic form]"}) do
        ok(at(label), 'renders ' .. label .. '\n' .. table.concat(labels, ' | '))
    end
    ok(at('Always keep Mythics') < at('Ancestral junk') and at('Ancestral junk') < at('Keep with Greater Affixes at least'),
        'the menu reads in decision order')
    for _, old in ipairs({'Always keep mythics', 'Use Mythic Unique filter', 'Use unique/mythic filter', 'unchecked Mythic Uniques',
            'mythic items', 'Plain Uniques', 'Iconic Mythics not checked', 'Separate list for Mythic Uniques'}) do
        ok(not at(old), 'not shown (Always keep Mythics on): ' .. old)
    end
    t.tg.mythic_always_keep:set(false); t.h.menu_labels = {}; t.h.frame(); labels = t.h.menu_labels
    ok(at('Iconic Mythics not checked') and at('Separate list for Mythic Uniques') and at('Mythic Uniques not checked'),
        'Always keep Mythics off: its choices appear\n' .. table.concat(labels, ' | '))
    t.tg.mythic_always_keep:set(true)
    -- Long lists show only checked rows until a search is typed.
    eq(at('Kleos, Spear of Athulua - 2h_polearm'), nil, 'unchecked rows hidden with an empty search')
    t.tg.unique_search:set('kleos'); t.tg.unique_scope:set(1); t.h.menu_labels = {}; t.h.frame()
    local found = false
    for _, l in ipairs(t.h.menu_labels) do if l:find('Kleos', 1, true) then found = true end end
    ok(found, 'a search shows the matching row')
    t.h.menu_labels = nil
    t.h.assert_clean('menu')
end)

case('reload onto a newer Rosie: every widget missing from the cached GUI is created (generic)', function()
    local t = setup({persisted = USER})
    local prev = t.h.G.AlfredTheButlerPlugin
    ok(type(prev) == 'table' and type(prev._gui) == 'table', 'cached town GUI published')
    local dropped = {'unique_ip_keep_slider', 'mythic_always_keep', 'mythic_form_other', 'item_junk', 'storage_tree',
        'always_keep_tree', 'unique_2647147', 'mythic_609820', 'gamble_category', 'talisman_tab_x'}
    for _, key in ipairs(dropped) do prev._gui.elements[key] = nil end
    local dir
    for d, rec in pairs(t.h.by_dir) do if rec.name == 'Rosie' then dir = d end end
    t.h.reload(dir)
    t.h.run(3)
    t.h.menu_labels = {}; t.h.frame(); t.h.menu_labels = nil
    t.h.assert_clean('reload with an older cached GUI')
    local tg = t.h.mod('Rosie', 'rosie.private.town.gui').elements
    for _, key in ipairs(dropped) do ok(tg[key] ~= nil, 'recreated: ' .. key) end
    eq(tg.unique_2647147:get(), true, 'a recreated list row loads its saved value')
end)

print('Rosie keep menu: ' .. checks .. ' checks')
if #failures > 0 then error(#failures .. ' failure(s):\n' .. table.concat(failures, '\n')) end
