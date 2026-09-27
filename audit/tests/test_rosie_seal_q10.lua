-- QQT_Warpigz_v3 (Q10, live v3.0.0): Rosie seal filter. The user's setup:
-- Seal default action Salvage, seal affix filter on with only
-- Talisman_SealAffix_AdditionalCharmSlot ("+1 Charm Slot") checked. A seal
-- WITHOUT that affix was stashed, and the host crashed with the Rosie menu
-- open on the 312-row seal affix list while a seal was hovered in the bag.
-- The REAL Rosie runs standalone in the joint host (as a farming user runs
-- it), with its real affix lists loaded.
--   Q10-1 the seal affix filter decides seals, also with the in-game loot
--         filter on (Universal or Seals only);
--   Q10-2 a town trip salvages the seal without the checked affix;
--   Q10-3 a seal listed in the equipment bag follows the seal rules;
--   Q10-4 why a seal is kept against a Salvage action is logged once;
--   Q10-5 menu open on the seal affix list: bounded work per frame;
--   Q10-6 the prepared filter rows keep search / scope / class semantics;
--   Q10-7 charms keep the in-game filter first; unique seals need the
--         unique/mythic seal filter (review);
--   Q10-8 town service off, menu closed: the Keep box follows a moved item.
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
    if passed then print('PASS rosie-seal: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL rosie-seal: ' .. name .. ': ' .. tostring(err)) end
end

local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local CHARM_SLOT, ANCESTRAL_01, LIFE = 2609197, 2443302, 2545574
local SALVAGE, SELL, KEEP = 1, 2, 0
-- The joint host cannot resolve Rosie's Windows data path (package.path +
-- 'data\\affix\\...'): seed the real affix JSON where Rosie looks, reload.
local AFFIX_SLOTS = {'helm', 'chest', 'gloves', 'pants', 'boots', 'amulet', 'ring', 'offhand',
    'weapon_1h', 'weapon_2h', 'talisman_seal', 'talisman_charm'}
local function seed_affix_data(h)
    local dir = ROOT .. '/Rosie/'
    local root = string.gmatch(dir .. '?.lua;' .. dir .. '?/init.lua', '.*?\\?')():gsub('?', '')
    for _, slot in ipairs(AFFIX_SLOTS) do
        local f = assert(io.open(ROOT .. '/Rosie/data/affix/affix_' .. slot .. '.json', 'r'))
        h.mem_files[root .. 'data\\affix\\affix_' .. slot .. '.json'] = f:read('*a')
        f:close()
    end
    h.G.io.close = h.G.io.close or function(f) return f:close() end
    h.reload('Rosie')
    eq(#h.errors, 0, 'Rosie reload: ' .. tostring(h.errors[1] and h.errors[1].err))
end
local function new(opts)
    opts = opts or {}
    opts.rosie, opts.dirs = true, {}
    local h = J.new(opts)
    seed_affix_data(h)
    h.assert_clean('load')
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.run(1)
    return h
end
local function affix(hash, name)
    return {affix_name_hash = hash, get_name = function() return name end}
end
local function seal(h, affixes, fields)
    local f = {sno = 2418245, name = 'Talisman_Seal_Legendary', rarity = 5, affixes = affixes}
    for k, v in pairs(fields or {}) do f[k] = v end
    return h.gear(f)
end
local function no_slot(h, fields) return seal(h, {affix(ANCESTRAL_01, 'Talisman_SealAffix_Ancestral_01'), affix(LIFE, 'x')}, fields) end
local function with_slot(h, fields) return seal(h, {affix(LIFE, 'x'), affix(CHARM_SLOT, 'Talisman_SealAffix_AdditionalCharmSlot')}, fields) end
-- The user's screenshot: Seal default action Salvage > Use affix filter >
-- +1 Charm Slot checked (Min matching affixes 1).
local function user_setup(h, extra)
    local tgui = h.mod('Rosie', 'rosie.private.town.gui')
    ok(tgui.elements['talisman_seal_affix_' .. CHARM_SLOT], 'the seal affix list is loaded')
    tgui.elements.talisman_seal_action:set(SALVAGE)
    tgui.elements.talisman_seal_affix_filter_toggle:set(true)
    tgui.elements['talisman_seal_affix_' .. CHARM_SLOT]:set(true)
    if extra then extra(tgui.elements) end
    local settings = h.mod('Rosie', 'rosie.private.town.core.settings')
    h.as('Rosie', function() settings:update_settings(true) end)
    return h.mod('Rosie', 'rosie.private.town.core.utils'), tgui
end
local function salvages(h, utils, item) return h.as('Rosie', function() return utils.should_salvage_talisman(item) end) end
local function sells(h, utils, item) return h.as('Rosie', function() return utils.should_sell_talisman(item) end) end

case('Q10-1 the seal affix filter decides seals, also with the in-game loot filter on', function()
    local modes = {
        {'loot filter off', function() end},
        {'Universal loot filter', function(e) e.loot_filter_toggle:set(true) end},
        {'Seals-only loot filter', function(e) e.loot_filter_seal:set(true) end},
    }
    for _, mode in ipairs(modes) do
        local h = new()
        local utils = user_setup(h, mode[2])
        -- In-game filter: shown (filtered=false) or hidden (filtered=true).
        eq(salvages(h, utils, no_slot(h, {filtered = false})), true, mode[1] .. ': a shown seal without +1 Charm Slot is salvaged')
        eq(salvages(h, utils, no_slot(h, {filtered = true})), true, mode[1] .. ': a hidden seal without +1 Charm Slot is salvaged')
        eq(salvages(h, utils, with_slot(h, {filtered = false})), false, mode[1] .. ': a shown seal WITH +1 Charm Slot is kept')
        eq(salvages(h, utils, with_slot(h, {filtered = true})), false, mode[1] .. ': a hidden seal WITH +1 Charm Slot is kept')
        eq(sells(h, utils, no_slot(h)), false, mode[1] .. ': never sold under a Salvage action')
        -- Unique / mythic seals stay protected in every mode.
        eq(salvages(h, utils, no_slot(h, {rarity = 8, filtered = true})), false, mode[1] .. ': mythic seal kept')
        eq(salvages(h, utils, no_slot(h, {rarity = 6, filtered = true})), false, mode[1] .. ': unique seal kept (its filter is off)')
        eq(#h.errors, 0, 'host errors')
    end
    -- Affix filter off: the in-game filter still decides seals (unchanged).
    local h = new()
    local utils = user_setup(h, function(e) e.loot_filter_toggle:set(true); e.talisman_seal_affix_filter_toggle:set(false) end)
    eq(salvages(h, utils, no_slot(h, {filtered = false})), false, 'affix filter off: a seal the in-game filter shows is kept')
    eq(salvages(h, utils, with_slot(h, {filtered = true})), true, 'affix filter off: a seal the in-game filter hides is salvaged')
    -- "Min matching affixes" restored below its range counts as 1, never 0
    -- (0 would keep every seal).
    local h2 = new()
    local utils2 = user_setup(h2, function(e) e.talisman_seal_affix_count_slider:set(0) end)
    eq(salvages(h2, utils2, no_slot(h2)), true, 'count 0 counts as 1: a seal without the affix is salvaged')
    -- A hash the host cannot read is matched by the affix's internal name.
    local by_name = seal(h2, {{get_name = function() return 'Talisman_SealAffix_AdditionalCharmSlot' end}})
    eq(salvages(h2, utils2, by_name), false, 'matched by name when the hash is unreadable')
    -- QQT_Warpigz_v3 (review): the keep-safety branches, each pinned.
    -- A seal listing no affixes (not readable yet) is kept, never salvaged.
    eq(salvages(h2, utils2, seal(h2, {})), false, 'a seal listing no affixes is kept')
    -- An affix whose hash AND name cannot be read keeps the seal (not skipped).
    local blind = seal(h2, {affix(LIFE, 'x'), {get_name = function() error('host: name unreadable') end}})
    local action, why = h2.as('Rosie', function() return utils2.talisman_decision(blind) end)
    eq(action, KEEP, 'an unreadable affix keeps the seal')
    eq(why, 'an affix is unreadable', 'the keep reason names the unreadable affix')
    -- One checked affix listed twice counts once (Min matching affixes 2).
    local h3 = new()
    local utils3 = user_setup(h3, function(e) e.talisman_seal_affix_count_slider:set(2) end)
    eq(salvages(h3, utils3, seal(h3, {affix(CHARM_SLOT, 'c'), affix(CHARM_SLOT, 'c')})), true,
        'one checked affix listed twice counts once')
    -- Affix filter on with NOTHING checked: the in-game filter still decides.
    local h4 = new()
    local utils4 = user_setup(h4, function(e)
        e['talisman_seal_affix_' .. CHARM_SLOT]:set(false)
        e.loot_filter_toggle:set(true)
    end)
    eq(salvages(h4, utils4, no_slot(h4, {filtered = false})), false, 'nothing checked: a seal the in-game filter shows is kept')
    eq(salvages(h4, utils4, no_slot(h4, {filtered = true})), true, 'nothing checked: a seal the in-game filter hides is salvaged')
end)

-- QQT_Warpigz_v3 (review): the new precedence is for seals only. Charms keep
-- the pre-v3 order (the in-game loot filter first), so updating never
-- salvages a charm the in-game filter shows. Unique seals (Annihilus: fixed
-- affixes, never "+1 Charm Slot") stay kept unless the user opts in with the
-- unique/mythic seal filter.
case('Q10-7 charms keep the in-game filter first; unique seals need the unique/mythic seal filter', function()
    local CHARM_AFFIX, ANNIHILUS = 2586362, 2684354
    local function charm(h, has, shown, fields)
        local f = {sno = 2257839, name = 'Talisman_Charm_Rare', rarity = 3, filtered = not shown,
            affixes = {has and affix(CHARM_AFFIX, 'c') or affix(1, 'z')}}
        for k, v in pairs(fields or {}) do f[k] = v end
        return h.gear(f)
    end
    for _, mode in ipairs({{'Universal', 'loot_filter_toggle'}, {'Charms only', 'loot_filter_charm'}}) do
        local h = new()
        local utils = user_setup(h, function(e)
            e[mode[2]]:set(true)
            e.talisman_charm_action:set(SALVAGE)
            e.talisman_charm_affix_filter_toggle:set(true)
            e['talisman_charm_affix_' .. CHARM_AFFIX]:set(true)
        end)
        eq(salvages(h, utils, charm(h, false, true)), false, mode[1] .. ': a rare charm the in-game filter shows is kept')
        eq(salvages(h, utils, charm(h, false, false)), true, mode[1] .. ': a rare charm the in-game filter hides is salvaged')
        eq(salvages(h, utils, charm(h, true, false)), true, mode[1] .. ': the in-game filter decides charms first (pre-v3 order)')
        eq(salvages(h, utils, charm(h, false, true, {sno = 2304176, name = 'Phoba', rarity = 7})), false,
            mode[1] .. ': a set charm the in-game filter shows is kept')
        -- Seals in the same setup: the seal affix filter decides.
        eq(salvages(h, utils, no_slot(h, {filtered = false})), true, mode[1] .. ': a shown seal without the affix is salvaged')
        eq(#h.errors, 0, 'host errors')
    end
    -- In-game filter off: the charm affix filter decides charms (unchanged).
    local h = new()
    local utils = user_setup(h, function(e)
        e.talisman_charm_action:set(SALVAGE)
        e.talisman_charm_affix_filter_toggle:set(true)
        e['talisman_charm_affix_' .. CHARM_AFFIX]:set(true)
    end)
    eq(salvages(h, utils, charm(h, false, true)), true, 'loot filter off: a charm without the affix is salvaged')
    eq(salvages(h, utils, charm(h, true, false)), false, 'loot filter off: a charm with the affix is kept')
    -- Unique seal (Annihilus) under the shipped defaults: kept, with the reason.
    local annihilus = no_slot(h, {sno = ANNIHILUS, name = 'Talisman_Seal_Unique_Annihilus', rarity = 6})
    local action, why = h.as('Rosie', function() return utils.talisman_decision(annihilus) end)
    eq(action, KEEP, 'Annihilus kept while the unique/mythic seal filter is off')
    ok(tostring(why):find('Use unique/mythic seal filter', 1, true), 'the keep reason names the filter: ' .. tostring(why))
    -- Opted in and unchecked: it follows the seal action and affix filter.
    local h2 = new()
    local utils2 = user_setup(h2, function(e) e.talisman_seal_mythic_filter_toggle:set(true) end)
    eq(salvages(h2, utils2, no_slot(h2, {sno = ANNIHILUS, rarity = 6})), true, 'unique filter on, unchecked: affix rule applies')
    -- Opted in and checked: kept.
    local tgui2 = h2.mod('Rosie', 'rosie.private.town.gui')
    ok(tgui2.elements['seal_mythic_' .. ANNIHILUS], 'Annihilus is in the unique/mythic seal list')
    tgui2.elements['seal_mythic_' .. ANNIHILUS]:set(true)
    h2.as('Rosie', function() h2.mod('Rosie', 'rosie.private.town.core.settings'):update_settings(true) end)
    eq(salvages(h2, utils2, no_slot(h2, {sno = ANNIHILUS, rarity = 6})), false, 'unique filter on, checked: kept')
    eq(#h2.errors, 0, 'host errors')
end)

case('Q10-2 a town trip salvages the seal without the checked affix (Universal loot filter on)', function()
    local h = new({place = 'temis'})
    user_setup(h, function(e) e.loot_filter_toggle:set(true) end)
    h.actor('temis', 'TWN_Skov_Temis_Crafter_Occultist', 2583.64, -478.22, {vendor = true})
    local plain = no_slot(h, {filtered = false})
    h.talismans = {plain}
    h.inventory = {}
    local r
    eq(h.as(CONSUMER, function()
        return h.G.AlfredTheButlerPlugin.trigger_tasks('Consumer', function(a) r = a or 'ok' end)
    end), true, 'trip accepted')
    ok(h.run_until(function() return r ~= nil end, 180), 'trip finished\n' .. h.tail())
    local salvaged = false
    for _, item in ipairs(h.salvaged) do if item == plain then salvaged = true end end
    ok(salvaged, 'the seal without +1 Charm Slot was salvaged\n' .. h.tail())
    for _, item in ipairs(h.stashed) do ok(item ~= plain, 'never stashed') end
    eq(#h.talismans, 0, 'talisman bag empty')
    eq(#h.errors, 0, 'host errors')
end)

case('Q10-3 a seal the host lists in the equipment bag follows the seal rules', function()
    local h = new()
    -- Legendary equipment action Keep: before, a bag-listed seal took it.
    local utils = user_setup(h, function(e) e.item_legendary_or_lower:set(KEEP); e.ancestral_item_legendary:set(KEEP) end)
    local function act(item, what) return h.as('Rosie', function() return utils.is_salvage_or_sell(item, what) end) end
    eq(act(no_slot(h), SALVAGE), true, 'bag-listed seal without the affix: seal action Salvage')
    eq(act(with_slot(h), SALVAGE), false, 'bag-listed seal with the affix: kept')
    eq(act(no_slot(h), SELL), false, 'not sold')
    -- The census counts it as salvage, not as keep.
    h.inventory = {no_slot(h)}
    h.run(2)
    local tracker = h.mod('Rosie', 'rosie.private.town.core.tracker')
    eq(tracker.salvage_count, 1, 'census: salvage')
    eq(tracker.stash_count, 0, 'census: not kept')
end)

case('Q10-4 why a seal is kept against a Salvage action is logged once', function()
    local h = new()
    user_setup(h)
    local unreadable = seal(h, nil)
    function unreadable:get_affixes() error('host: affixes unreadable') end
    h.talismans = {unreadable, with_slot(h), with_slot(h), no_slot(h, {rarity = 6}), no_slot(h)}
    local mark = #h.log
    h.run(8)
    local lines = {}
    for i = mark + 1, #h.log do if h.log[i]:find('[Rosie] Seal kept', 1, true) then lines[#lines + 1] = h.log[i] end end
    local text = table.concat(lines, '\n')
    eq(#lines, 3, 'one line per reason and SNO:\n' .. text)
    ok(text:find('affixes unreadable', 1, true), 'unreadable affixes named\n' .. text)
    ok(text:find('affix filter: 1 of the checked affixes (need 1)', 1, true), 'affix match named\n' .. text)
    ok(text:find('Unique/Mythic seal', 1, true), 'unique seal named\n' .. text)
    ok(text:find('sno=2418245', 1, true), 'SNO named\n' .. text)
    -- Seal action Keep: keeping surprises nobody, nothing is logged.
    local h2 = new()
    user_setup(h2, function(e) e.talisman_seal_action:set(KEEP) end)
    h2.talismans = {with_slot(h2), no_slot(h2)}
    local mark2 = #h2.log
    h2.run(4)
    for i = mark2 + 1, #h2.log do ok(not h2.log[i]:find('Seal kept', 1, true), 'no keep line for action Keep: ' .. h2.log[i]) end
end)

case('Q10-5 menu open on the seal affix list, a seal hovered: bounded work per frame', function()
    local h = new({place = 'temis'})
    local utils, tgui = user_setup(h, function(e)
        e.draw_stash:set(true)
        e.item_legendary_or_lower:set(KEEP)
        e.talisman_seal_affix_search:set('charmslot')
    end)
    local settings = h.mod('Rosie', 'rosie.private.town.core.settings')
    local rebuilds = 0
    local rebuild = settings.update_selections
    settings.update_selections = function(...) rebuilds = rebuilds + 1; return rebuild(...) end
    local widget_reads, slider_reads = 0, 0
    for key, w in pairs(tgui.elements) do
        if type(w) == 'table' and type(w.get) == 'function' then
            local g = w.get
            w.get = function(self, ...)
                widget_reads = widget_reads + 1
                if key == 'draw_offset_x' then slider_reads = slider_reads + 1 end -- QQT_Warpigz_v3 (review)
                return g(self, ...)
            end
        end
    end
    local affix_reads, slot_reads = 0, 0
    h.talismans = {}
    for i = 1, 20 do
        local s = seal(h, {affix(ANCESTRAL_01, 'a'), affix(LIFE + i, 'b')})
        local read = s.get_affixes
        s.get_affixes = function(self) affix_reads = affix_reads + 1; return read(self) end
        h.talismans[i] = s
    end
    h.inventory = {}
    for i = 1, 20 do
        local g = h.gear({rarity = 5})
        g.get_inventory_row = function() slot_reads = slot_reads + 1; return math.floor((i - 1) / 11) end
        g.get_inventory_column = function() return (i - 1) % 11 end
        h.inventory[i] = g
    end
    h.G.is_inventory_open = function() return true end -- the bag is open (a seal hovered)
    h.run(1)
    h.menu_labels = {}
    widget_reads, affix_reads, slot_reads, rebuilds, slider_reads = 0, 0, 0, 0, 0
    local mark, f0, t0 = #h.log, h.frames, h.now
    h.run(10)
    local frames, secs = h.frames - f0, h.now - t0
    local rows = 0
    for _, label in ipairs(h.menu_labels) do if label == 'Talisman_SealAffix_AdditionalCharmSlot' then rows = rows + 1 end end
    eq(rows, frames, 'the checked seal affix row renders every frame')
    ok(rebuilds / secs <= 3, 'selection rebuilds per second: ' .. rebuilds / secs .. ' (was every menu frame)')
    ok(widget_reads / secs < 20000, 'town widget reads per second: ' .. widget_reads / secs)
    ok(affix_reads / secs / 20 <= 1.5, 'affix reads per seal per second: ' .. affix_reads / secs / 20)
    ok(slot_reads / secs / 20 <= 3, 'bag slot reads per drawn item per second: ' .. slot_reads / secs / 20
        .. ' (was every frame)')
    ok(slot_reads > 0 and (h.graphics_used.rect or 0) > 0, 'the Keep boxes are still drawn')
    ok(slider_reads <= frames, 'a layout slider is read once per frame, not per drawn item: '
        .. slider_reads .. ' reads in ' .. frames .. ' frames') -- QQT_Warpigz_v3 (review)
    eq(#h.log - mark, 0, 'no console line while the menu is open:\n' .. h.tail())
    -- Counts on screen stay current (display-only talisman census).
    local tracker = h.mod('Rosie', 'rosie.private.town.core.tracker')
    eq(tracker.salvage_talisman_count, 20, 'talisman salvage count')
    h.talismans[#h.talismans + 1] = with_slot(h)
    h.run(1)
    eq(tracker.stash_talisman_count, 1, 'a new talisman is counted within a second')
    -- QQT_Warpigz_v3 (review): the tally is not display-only (its sell part
    -- feeds tracker.sell_count, read by the sell step's is_done), so its two
    -- instant recount triggers are pinned apart from the 1 s timer.
    local player = h.G.get_local_player()
    h.as('Rosie', function() utils.update_tracker_count(player, 'now') end)
    local before = tracker.stash_talisman_count
    h.talismans[#h.talismans + 1] = with_slot(h)
    h.now = h.now + 0.3
    h.as('Rosie', function() utils.update_tracker_count(player, true) end)
    eq(tracker.stash_talisman_count, before + 1, 'count change: the new talisman is counted 0.3 s later')
    h.talismans[1].affixes = {affix(CHARM_SLOT, 'c')} -- same count, the decision changes
    h.now = h.now + 0.3
    h.as('Rosie', function() utils.update_tracker_count(player, 'now') end)
    eq(tracker.stash_talisman_count, before + 2, "a request census ('now') counts a changed decision at once")
    eq(tracker.salvage_talisman_count, 19, "a request census ('now') drops the stale salvage count")
    eq(#h.errors, 0, 'host errors')
end)

case('Q10-6 the prepared filter rows keep search, scope and class semantics', function()
    local h = new()
    local _, tgui = user_setup(h)
    local e = tgui.elements
    local function rendered()
        h.menu_labels = {}
        h.frame()
        local n = 0
        for _, label in ipairs(h.menu_labels) do if label:find('^Talisman_SealAffix_') then n = n + 1 end end
        return n
    end
    e.talisman_seal_affix_search:set('') -- (the joint host seeds input_text with its key)
    e.talisman_seal_affix_scope:set(1) -- All classes
    eq(rendered(), 312, 'All classes, no search: every seal affix')
    e.talisman_seal_affix_scope:set(0) -- Current class (sorcerer) + selected
    eq(rendered(), 98, 'Sorcerer: 67 all-class + 30 Sorcerer + 1 Sorcerer/Necromancer affixes')
    e.talisman_seal_affix_scope:set(2) -- Selected only
    eq(rendered(), 1, 'Selected only')
    e.talisman_seal_affix_scope:set(1)
    e.talisman_seal_affix_search:set('ANCESTRAL_0')
    eq(rendered(), 4, 'search (any case) plus the selected row stays visible')
    e.talisman_seal_affix_search:set('2609197')
    eq(rendered(), 1, 'search by Item ID')
    eq(#h.errors, 0, 'host errors')
end)

-- QQT_Warpigz_v3 (review): with the town service off (pickup only) and the
-- Rosie menu closed no census runs; the Keep box must still follow a bag item
-- the user moves (the cached slot ages out after 0.5 s).
case('Q10-8 town service off, menu closed: the Keep box follows a moved bag item', function()
    local h = new()
    local tgui = h.mod('Rosie', 'rosie.private.town.gui')
    tgui.elements.draw_stash:set(true)
    tgui.elements.item_legendary_or_lower:set(KEEP) -- the gear is drawn with the Keep box
    local item = h.gear({rarity = 5})
    item.row, item.slot_reads = 0, 0
    item.get_inventory_row = function() item.slot_reads = item.slot_reads + 1; return item.row end
    item.get_inventory_column = function() return 0 end
    h.inventory = {item}
    h.inventory_open = true
    local ys = {}
    local rect = h.G.graphics.rect
    h.G.graphics.rect = function(a, ...) ys[#ys + 1] = a._y; return rect(a, ...) end
    h.run(2) -- menu open: the preview census builds the entry
    tgui.elements.main_toggle:set(false) -- town service off; Rosie stays on for pickup
    h.run(2)
    local rosie
    for _, rec in ipairs(h.plugins) do if rec.name == 'Rosie' then rosie = rec end end
    rosie.menu = {} -- the Rosie menu is closed
    h.run(1)
    local y0 = ys[#ys]
    ok(y0 ~= nil, 'the Keep box is drawn')
    item.row = 2 -- the user drags the item two rows down
    local mark, reads0, t0 = #ys, item.slot_reads, h.now
    h.run(1)
    ok(#ys > mark, 'still drawn after the move')
    ok(ys[#ys] ~= y0, 'the Keep box follows the item within a second (y ' .. tostring(y0) .. ' -> ' .. tostring(ys[#ys]) .. ')')
    h.run(4)
    ok((item.slot_reads - reads0) / (h.now - t0) <= 3, 'slot reads per second stay bounded: '
        .. (item.slot_reads - reads0) / (h.now - t0))
    eq(#h.errors, 0, 'host errors')
end)

print(string.format('rosie-seal: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(#failures .. ' rosie-seal case(s) failed') end
