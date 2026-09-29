-- QQT_Warpigz_v3 Rosie 1.0.28 (owner, via the Coordinator): "there is no option
-- to keep a selected Unique only when ANCESTRAL; if you move the slider it
-- keeps ALL Uniques; and the Unique settings are scattered over 3-4 places".
--  C  (owner amendment: "the slider isn't needed; just keep the selected
--     Ancestral Uniques, the others get salvaged") one toggle "Keep checked
--     Uniques only when Ancestral" (default off = the old behaviour). On: a
--     checked plain Unique is kept only as an Ancestral copy; a non-Ancestral
--     copy falls through to the GA rule and the Otherwise actions. Its Mythic
--     form follows 1. Always keep.
--  I  the item power slider is gone from the menu; a saved value > 0 is still
--     honoured and shown read-only with a Reset button.
--  M  one section "2. Uniques" right after 1. Always keep holds Pick up every
--     Unique (same widget), the list, the toggle, the GA slider, the two
--     Otherwise actions and the sorter mode; saved values keep their hashes.
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
    if passed then print('PASS uniques 1.0.28: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL uniques 1.0.28: ' .. name .. ': ' .. tostring(err)) end
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
local PLAIN = {affix(2662414, 'Helm_Unique_Generic_005'), affix(583206, 'AttackSpeed')}
local MYTHIC = {affix(2662414, 'Helm_Unique_Generic_005'), affix(583206, 'AttackSpeed'), MARK}
-- Leoric's Crown checked; other Ancestral Uniques salvaged, non-Ancestral sold.
local SAVED = {[P .. 'unique_2647147'] = true, [P .. 'ancestral_item_unique'] = SALVAGE, [P .. 'item_unique'] = SELL}

local function setup(opts)
    opts = opts or {}
    local persisted = {}
    for k, v in pairs(SAVED) do persisted[k] = v end
    for k, v in pairs(opts.persisted or {}) do persisted[k] = v end
    local h = J.new({rosie = true, dirs = {}, place = 'pit', persisted = persisted})
    h.assert_clean('load')
    h.pos = h.v(0, 0)
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    local tg = h.mod('Rosie', 'rosie.private.town.gui').elements
    tg.ancestral_unique_ga_count_slider:set(0); tg.ancestral_mythic_ga_count_slider:set(0); tg.ancestral_ga_count_slider:set(0)
    h.run(1.5)
    local utils = h.mod('Rosie', 'rosie.private.town.core.utils')
    local t = {h = h, tg = tg, gui = h.mod('Rosie', 'rosie.private.town.gui'), utils = utils,
        im = h.mod('Rosie', 'rosie.private.pickup.src.item_manager')}
    function t.verdict(fields)
        local it = h.gear(fields)
        return h.as('Rosie', function()
            if utils.is_salvage_or_sell(it, SALVAGE) then return 'salvage' end
            if utils.is_salvage_or_sell(it, SELL) then return 'sell' end
            return 'keep'
        end)
    end
    function t.anc(v) tg.unique_ancestral_only:set(v); h.run(1.5) end
    function t.lines(text)
        local n = 0
        for _, line in ipairs(h.log) do if tostring(line):find(text, 1, true) then n = n + 1 end end
        return n
    end
    return t
end
local function leoric(anc, ga, affixes) return item(LEORIC, {ancestral = anc, ga = ga, affixes = affixes or PLAIN}) end

case('C1 toggle off (default): the checked plain Unique is kept, Ancestral or not (unchanged)', function()
    local t = setup()
    eq(t.tg.unique_ancestral_only:get(), false, 'default off')
    eq(t.verdict(leoric(true, 0)), 'keep', 'Ancestral')
    eq(t.verdict(leoric(false, 0)), 'keep', 'non-Ancestral')
    t.h.assert_clean('C1')
end)

case('C2 toggle on: a non-Ancestral copy falls through to the Non-Ancestral action (1.0.27: kept)', function()
    local t = setup()
    t.anc(true)
    eq(t.verdict(leoric(true, 0)), 'keep', 'Ancestral kept')
    eq(t.verdict(leoric(false, 0)), 'sell', 'non-Ancestral sold (Otherwise: Non-Ancestral Uniques)')
    eq(t.lines('checked in "Uniques I keep" (Ancestral)'), 1, 'keep reason\n' .. t.h.tail(6))
    eq(t.lines('checked in "Uniques I keep" but not Ancestral'), 1, 'the fall-through reason\n' .. t.h.tail(6))
    t.h.assert_clean('C2')
end)

case('C3 the owner\'s recipe: toggle on, both Otherwise = Salvage, GA 0: only checked Ancestral Uniques are kept', function()
    local t = setup()
    t.anc(true)
    t.tg.item_unique:set(SALVAGE); t.tg.ancestral_item_unique:set(SALVAGE); t.tg.ancestral_unique_ga_count_slider:set(0); t.h.run(1.5)
    eq(t.verdict(leoric(true, 3)), 'keep', 'checked Ancestral')
    eq(t.verdict(leoric(false, 3)), 'salvage', 'checked non-Ancestral')
    local other = {name = 'Dagger_Unique_Generic_001', sno = 451091, rarity = 6,
        affixes = {affix(3, 'Dagger_Unique_Generic_001')}}
    eq(t.verdict(item(other, {ancestral = true, ga = 3})), 'salvage', 'unchecked Ancestral')
    -- A failed copy still meets "Keep with Greater Affixes at least" when set.
    t.tg.ancestral_unique_ga_count_slider:set(2); t.h.run(1.5)
    eq(t.verdict(leoric(false, 2)), 'keep', 'kept by the section\'s GA rule after falling through')
    t.h.assert_clean('C3')
end)

case('C4 the Mythic form of a checked Unique follows 1. Always keep (the toggle never drops it)', function()
    local t = setup()
    t.anc(true)
    eq(t.verdict(leoric(false, 0, MYTHIC)), 'keep', 'Always keep Mythics on')
    t.tg.mythic_always_keep:set(false); t.tg.ancestral_item_mythic:set(SALVAGE); t.h.run(1.5)
    eq(t.verdict(leoric(false, 0, MYTHIC)), 'keep', 'Always keep Mythics off: the list keeps the Mythic form as before')
    t.h.assert_clean('C4')
end)

case('C5 pickup still takes a checked Unique with the toggle on (ancestry is unknown on the ground)', function()
    local t = setup()
    t.anc(true)
    local want, why = t.h.as('Rosie', function() return t.im.check_want_item(t.h.gear(leoric(false, 0)), true) end)
    eq(want, true, 'wanted')
    eq(why, "accepted: selected in 'Uniques I keep'", 'reason')
end)

case('I1 the item power slider is not shown; a saved value > 0 is honoured, shown with Reset, and Reset turns it off', function()
    local t = setup()
    t.tg['unique_2647147']:set(false); t.h.run(1.5)
    -- the joint host's buttons record no label: spy on the reset button's render
    local reset_shown = false
    local real = t.tg.unique_ip_reset.render
    t.tg.unique_ip_reset.render = function(self, ...) reset_shown = true; return real(self, ...) end
    local function has(label)
        t.h.menu_labels = {}; reset_shown = false; t.h.frame()
        local found = false
        for _, l in ipairs(t.h.menu_labels) do if l == label then found = true end end
        t.h.menu_labels = nil
        if label == 'Reset (turn the item power rule off)' then return reset_shown end
        return found
    end
    ok(not has('Keep Uniques with Item Power at least'), 'no slider (1.0.27: shown)')
    ok(not has('Reset (turn the item power rule off)'), 'no reset row at 0')
    t.tg.unique_ip_keep_slider:set(900); t.h.run(1.5)
    local f = leoric(true, 0); f.attrs = {Item_Power_Total = 910}
    eq(t.verdict(f), 'keep', 'a saved 900 is still honoured')
    ok(has('Reset (turn the item power rule off)'), 'the reset row shows while it is on')
    ok(not has('Keep Uniques with Item Power at least'), 'still no slider')
    t.tg.unique_ip_reset:set(true); has('x'); t.tg.unique_ip_reset:set(false)
    eq(t.tg.unique_ip_keep_slider:get(), 0, 'Reset sets it to 0')
    t.h.run(1.5)
    eq(t.verdict(f), 'salvage', 'off: the Ancestral action')
end)

case('M1 one "2. Uniques" section right after 1. Always keep: toggle, list, Ancestral toggle, GA slider, actions', function()
    local t = setup()
    t.anc(true)
    t.h.menu_labels = {}; t.h.frame()
    local labels = t.h.menu_labels
    t.h.menu_labels = nil
    local function at(label) for i, l in ipairs(labels) do if l == label then return i end end return nil end
    local order = {'Always keep Mythics', 'Pick up every Unique (sort in the bag)',
        "Leoric's Crown - helm  [keeps Ancestral plain + Mythic form]", 'Keep checked Uniques only when Ancestral',
        'Keep with Greater Affixes at least', 'Otherwise: Ancestral Uniques', 'Otherwise: Non-Ancestral Uniques', 'Ancestral junk'}
    local last = 0
    for _, label in ipairs(order) do
        local i = at(label)
        ok(i and i > last, 'in order: ' .. label .. '\n' .. table.concat(labels, ' | '))
        last = i
    end
    eq(labels[2] == 'Pick up every Unique (sort in the bag)', false, 'no longer in the root menu')
end)

case('M2 saved settings survive: the toggle, the list and the Ancestral toggle load by their hashes', function()
    local t = setup({persisted = {Rosie_pickup_all_uniques = false, [P .. 'unique_ancestral_only'] = true}})
    eq(t.tg['unique_2647147']:get(), true, 'the checked row')
    eq(t.tg.unique_ancestral_only:get(), true, 'the saved Ancestral toggle')
    eq(t.verdict(leoric(false, 0)), 'sell', 'it decides')
    local sorter = t.h.mod('Rosie', 'rosie.private.unique_sorter')
    eq(sorter.pick_all(), false, 'Pick up every Unique keeps its saved OFF')
end)

print(string.format('rosie uniques 1.0.28: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
