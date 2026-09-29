-- 3.2.4 (Rosie 1.0.16), live report: town Keep settings (ANCESTRAL) with
-- Always keep mythics ON, Mythic items Keep, Unique items Salvage, GA sliders
-- 0, "Use Mythic Unique filter" ON with "unchecked Mythic Uniques" Salvage and
-- nothing checked, "Use unique/mythic filter" ON with Leoric's Crown checked.
-- A dropped Leoric's Crown in its S15 Mythic form (same SNO 2647147, rarity 6,
-- affix S14_Mythic_UniquePotency 2628989) was salvaged.
-- Rules pinned here: a Unique checked in "Unique items" or in "Mythic Uniques
-- to keep" is kept in both forms; Always keep mythics beats the unchecked
-- Mythic Unique action; one "[Rosie] Kept <name>: <reason>" line per item.
-- Both paths: the town decision and the every-Unique "Plain Uniques: Drop" sorter.
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
    if passed then print('PASS keep324: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL keep324: ' .. name .. ': ' .. tostring(err)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function affix(hash, name, roll)
    return {affix_name_hash = hash, get_name = function() return name end, get_roll = function() return roll or 1 end}
end
local MARK = affix(2628989, 'S14_Mythic_UniquePotency')
local function item(fields)
    local out = {name = 'Helm_Unique_Generic_005', sno = 2647147, rarity = 6, display = "Leoric's Crown"}
    for k, v in pairs(fields) do out[k] = v end
    return out
end
local function mythic_leoric(ga)
    return item({ancestral = true, ga = ga or 0,
        affixes = {affix(2662414, 'Helm_Unique_Generic_005'), MARK, affix(1829592, 'S04_Life', 900)}})
end
local function plain_leoric(ancestral, roll)
    return item({ancestral = ancestral ~= false, ga = 0,
        affixes = {affix(2662414, 'Helm_Unique_Generic_005'), affix(583206, 'AttackSpeed', roll or 7.25), affix(1829592, 'S04_Life', 812)}})
end
local function locran_mythic()
    return {name = 'S05_BSK_Amulet_Unique_Generic_001', sno = 1944508, rarity = 6, display = "Locran's Talisman",
        ancestral = true, ga = 0, affixes = {affix(1924261, 'S05_BSK_Generic_009'), MARK}}
end

local function setup(opts)
    opts = opts or {}
    opts.rosie, opts.dirs, opts.place = true, {}, opts.place or 'pit'
    if opts.shipped_defaults == nil then opts.shipped_defaults = true end
    local h = J.new(opts)
    h.assert_clean('load')
    h.pos = h.v(0, 0)
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    local pgui = h.mod('Rosie', 'rosie.private.pickup.gui')
    pgui.elements.general.distance_slider:set(30)
    local e = h.G.RosiePlugin._elements
    if opts.mode == 'drop' then e.all_uniques_mode:set(1) end
    local tg = h.mod('Rosie', 'rosie.private.town.gui').elements
    -- The live settings (screenshot).
    tg.mythic_always_keep:set(true)
    tg.ancestral_item_mythic:set(0)
    tg.ancestral_item_unique:set(1)
    tg.ancestral_ga_count_slider:set(0)
    tg.ancestral_unique_ga_count_slider:set(0)
    tg.ancestral_mythic_ga_count_slider:set(0)
    tg.mythic_form_filter_toggle:set(true)
    tg.mythic_form_other:set(1)
    tg.ancestral_unique_filter_toggle:set(true)
    ok(tg['unique_2647147'] ~= nil, "Leoric's Crown is in the Unique items list")
    ok(tg['mythic_form_2647147'] ~= nil, "Leoric's Crown is in the Mythic Uniques to keep list")
    tg['unique_2647147']:set(true)
    h.run(1)
    local utils = h.mod('Rosie', 'rosie.private.town.core.utils')
    local t = {h = h, tg = tg, utils = utils}
    function t.acts(it)
        return h.as('Rosie', function()
            return utils.is_salvage_or_sell(it, utils.item_enum.SALVAGE) or utils.is_salvage_or_sell(it, utils.item_enum.SELL)
        end)
    end
    function t.lines(text)
        local n, last = 0, nil
        for _, line in ipairs(h.log) do if tostring(line):find(text, 1, true) then n = n + 1; last = tostring(line) end end
        return n, last
    end
    function t.bag_item(fields) local it = h.gear(fields); h.inventory = h.inventory or {}; h.inventory[#h.inventory + 1] = it; return it end
    function t.in_bag(it) for _, x in ipairs(h.inventory or {}) do if x == it then return true end end return false end
    return t
end

case('town: live settings keep the checked Leoric\'s Crown in its Mythic form and its plain form', function()
    local t = setup({place = 'temis'})
    eq(t.acts(t.h.gear(mythic_leoric())), false, 'Mythic-form Leoric (checked in Unique items) must be kept')
    eq(t.acts(t.h.gear(plain_leoric())), false, 'plain Leoric (checked in Unique items) is kept')
    eq(t.acts(t.h.gear(plain_leoric(false))), false, 'non-ancestral plain Leoric (checked) is kept')
    local n, line = t.lines("[Rosie] Kept Leoric's Crown: ")
    ok(n >= 1, 'a Kept line\n' .. t.h.tail())
    ok(line:find('Always keep mythics', 1, true) or line:find('Uniques I keep', 1, true), line) -- Rosie 1.0.28: the list's new name
    -- Once per item: the same Mythic read again logs nothing new.
    local before = t.lines('[Rosie] Kept ')
    t.acts(t.h.gear(mythic_leoric())); t.acts(t.h.gear(plain_leoric()))
    eq((t.lines('[Rosie] Kept ')), before, 'one Kept line per item')
    t.h.assert_clean('town live')
end)

case('town: Always keep mythics beats "unchecked Mythic Uniques = Salvage/Sell"', function()
    local t = setup({place = 'temis'})
    t.tg['unique_2647147']:set(false); t.h.run(0.5)
    for _, action in ipairs({1, 2}) do
        t.tg.mythic_form_other:set(action); t.h.run(0.5)
        eq(t.acts(t.h.gear(locran_mythic())), false, 'unchecked Mythic Locran kept (action ' .. action .. ')')
        eq(t.acts(t.h.gear(mythic_leoric())), false, 'unchecked Mythic Leoric kept (action ' .. action .. ')')
    end
    local _, line = t.lines("[Rosie] Kept Locran's Talisman: ")
    ok(line and line:find('Always keep mythics', 1, true), tostring(line))
    -- Guard: switched off, the unchecked action applies again.
    t.tg.mythic_always_keep:set(false); t.tg.mythic_form_other:set(1); t.h.run(0.5)
    eq(t.acts(t.h.gear(locran_mythic())), true, 'Always keep mythics off: unchecked Mythic Unique is salvaged')
    -- ... but a checked one (either list) is kept in both forms.
    t.tg['mythic_form_1944508']:set(true); t.h.run(0.5)
    eq(t.acts(t.h.gear(locran_mythic())), false, 'checked in Mythic Uniques to keep: Mythic form kept')
    t.tg['unique_2647147']:set(true); t.h.run(0.5)
    eq(t.acts(t.h.gear(mythic_leoric())), false, 'checked in Unique items, Always keep off: Mythic form kept')
    t.h.assert_clean('always keep')
end)

case('town: a Unique checked only in "Mythic Uniques to keep" keeps its plain form too', function()
    local t = setup({place = 'temis'})
    t.tg['unique_2647147']:set(false); t.tg['mythic_form_2647147']:set(true); t.h.run(0.5)
    eq(t.acts(t.h.gear(plain_leoric())), false, 'plain Leoric checked in Mythic Uniques to keep is kept')
    local _, line = t.lines("[Rosie] Kept Leoric's Crown: ")
    ok(line and line:find('Mythic uniques to keep', 1, true), tostring(line))
    -- Guard: unchecked everywhere, the plain one follows Unique items = Salvage.
    t.tg['mythic_form_2647147']:set(false); t.h.run(0.5)
    eq(t.acts(t.h.gear(plain_leoric(true, 3.5))), true, 'unchecked plain Leoric is salvaged')
    t.h.assert_clean('mythic list')
end)

case('sorter "Plain Uniques: Drop": checked Uniques are never dropped, in either list', function()
    local t = setup({mode = 'drop'})
    t.tg['unique_2647147']:set(false); t.tg['mythic_form_2647147']:set(true)
    t.tg['unique_1944508']:set(true)
    t.h.run(1)
    local by_mythic_list = t.bag_item(plain_leoric())
    local non_ancestral = t.bag_item({name = 'S05_BSK_Amulet_Unique_Generic_001', sno = 1944508, rarity = 6,
        display = "Locran's Talisman", ancestral = false, ga = 0,
        affixes = {affix(1924261, 'S05_BSK_Generic_009'), affix(2602164, 'X2_CritDamage_Greater', 31.5)}})
    local mythic = t.bag_item(mythic_leoric())
    t.h.run(10)
    eq(t.h.drop_calls, nil, 'nothing dropped\n' .. t.h.tail())
    ok(t.in_bag(by_mythic_list), 'plain Leoric checked in Mythic Uniques to keep stays')
    ok(t.in_bag(non_ancestral), 'non-ancestral Locran checked in Unique items stays')
    ok(t.in_bag(mythic), 'Mythic Leoric stays')
    -- Guard: unchecked, the plain Leoric is dropped.
    t.tg['mythic_form_2647147']:set(false)
    ok(t.h.run_until(function() return not t.in_bag(by_mythic_list) end, 15), 'unchecked plain Leoric is dropped\n' .. t.h.tail())
    ok(t.in_bag(mythic) and t.in_bag(non_ancestral), 'the others stay')
    t.h.assert_clean('sorter')
end)

case('town: S14 iconic re-issues are Mythics; a checked name matches the re-issue SNO', function()
    local t = setup({place = 'temis'})
    local function harlequin() return t.h.gear({name = 'S14_Helm_Unique_Generic_002', sno = 2646291, rarity = 6,
        display = 'Harlequin Crest', ancestral = true, junk = false, ga = 0,
        affixes = {affix(2646292, 'S14_Helm_Unique_Generic_002'), affix(1829592, 'S04_Life', 800)}}) end
    t.tg.ancestral_item_mythic:set(1); t.h.run(0.5)
    eq(t.acts(harlequin()), false, 'S14 Harlequin kept by Always keep mythics')
    -- The Mythic items list ships all checked; uncheck the iconic Harlequin.
    ok(t.tg['mythic_609820'] ~= nil, 'Harlequin Crest (iconic) is in the Mythic items list')
    t.tg.mythic_always_keep:set(false); t.tg['mythic_609820']:set(false); t.h.run(0.5)
    eq(t.acts(harlequin()), true, 'guard: Always keep off, unchecked, Mythic action Salvage')
    t.tg['mythic_609820']:set(true); t.h.run(0.5)
    eq(t.acts(harlequin()), false, 'Harlequin checked by its iconic SNO keeps the S14 re-issue')
    local _, line = t.lines('[Rosie] Kept Harlequin Crest: ')
    ok(line and line:find('Mythic items', 1, true), tostring(line))
    t.h.assert_clean('s14')
end)

case('town: Keep Uniques with Item Power >= wins over GA, Salvage and Sell; unreadable = no effect', function()
    local t = setup({place = 'temis'})
    t.tg['unique_2647147']:set(false); t.tg.ancestral_unique_ga_count_slider:set(2); t.h.run(0.5)
    local function plain(ip, extra)
        local f = plain_leoric(true, 3 + (ip or 0) / 1000)
        f.ga = 1; f.attrs = ip and {Item_Power_Total = ip} or nil
        for k, v in pairs(extra or {}) do f[k] = v end
        return t.h.gear(f)
    end
    eq(t.acts(plain(900)), true, 'slider off (default 0): a 900 plain Unique follows Salvage')
    t.tg.unique_ip_keep_slider:set(900); t.h.run(0.5)
    for _, action in ipairs({1, 2}) do
        t.tg.ancestral_item_unique:set(action); t.h.run(0.5)
        eq(t.acts(plain(900)), false, 'IP 900 >= 900 kept (action ' .. action .. ')')
        eq(t.acts(plain(925)), false, 'IP 925 kept (action ' .. action .. ')')
        eq(t.acts(plain(875)), true, 'IP 875 < 900 follows the action ' .. action)
    end
    eq(t.acts(plain(nil)), true, 'item power unreadable: no effect')
    eq(t.acts(plain(900, {ancestral = false})), false, 'non-ancestral IP 900 kept')
    local _, line = t.lines("[Rosie] Kept Leoric's Crown: item power 925 >= 900")
    ok(line ~= nil, 'Kept line with item power\n' .. t.h.tail())
    -- A host get_item_power() method is read first.
    local m = plain(nil); function m:get_item_power() return 910 end
    eq(t.acts(m), false, 'get_item_power() 910 kept')
    local bad = plain(nil); function bad:get_item_power() error('host: no item power') end
    eq(t.acts(bad), true, 'a failing read has no effect')
    -- Plain Uniques only: a Mythic follows the Mythic rules (Always keep mythics off).
    t.tg.mythic_always_keep:set(false); t.tg.ancestral_item_mythic:set(1); t.h.run(0.5)
    local f = locran_mythic(); f.junk = false; f.attrs = {Item_Power_Total = 925}
    eq(t.acts(t.h.gear(f)), true, 'the item power option does not apply to Mythics')
    t.h.assert_clean('item power')
end)

case('sorter "Plain Uniques: Drop": a plain Unique at or above the item power is never dropped', function()
    local t = setup({mode = 'drop'})
    t.tg['unique_2647147']:set(false); t.tg.unique_ip_keep_slider:set(900); t.h.run(1)
    local f = plain_leoric(); f.attrs = {Item_Power_Total = 900}
    local high = t.bag_item(f)
    local g = plain_leoric(true, 4.5); g.attrs = {Item_Power_Total = 850}
    local low = t.bag_item(g)
    ok(t.h.run_until(function() return not t.in_bag(low) end, 20), 'the 850 plain Leoric is dropped\n' .. t.h.tail())
    t.h.run(10)
    ok(t.in_bag(high), 'the 900 plain Leoric stays')
    eq(#t.h.dropped, 1, 'only the low one dropped')
    t.h.assert_clean('sorter ip')
end)

-- 3.2.5 live crash: after a Lua reload onto the new Rosie, the town GUI reuses the
-- previous generation's cached element table, which has no unique_ip_keep_slider.
case('3.2.5 reload with a pre-3.2.4 cached GUI does not crash settings', function()
    local t = setup()
    local prev = t.h.G.AlfredTheButlerPlugin
    ok(type(prev) == 'table' and type(prev._gui) == 'table', 'cached town GUI published')
    prev._gui.elements.unique_ip_keep_slider = nil
    local dir
    for d, rec in pairs(t.h.by_dir) do if rec.name == 'Rosie' then dir = d end end
    ok(dir ~= nil, 'Rosie loaded')
    t.h.reload(dir)
    t.h.run(3)
    t.h.assert_clean('reload with old cached GUI')
    local tg = t.h.mod('Rosie', 'rosie.private.town.gui').elements
    ok(tg.unique_ip_keep_slider ~= nil, 'missing widget recreated after reload')
end)

print('Rosie keep 3.2.4: ' .. checks .. ' checks')
if #failures > 0 then error(#failures .. ' failure(s):\n' .. table.concat(failures, '\n')) end
