-- AlfredTheButler-WarPigz item classification: Mythic Uniques (runtime rarity
-- 8, not in any SNO list), old listed mythics, mythic charms and seals, charm
-- and seal detection (item database, skin name, display name) and the
-- per-rarity charm/seal rules. Loads the real plugin files (main.lua and every
-- module it requires) into a QQT-shaped environment.
--
-- Also the harness for test_alfred_contract.lua (ALFRED_TEST_HARNESS_ONLY).
local ROOT = assert(SUITE_ROOT) .. '/AlfredTheButler-WarPigz/'
local unpack = table.unpack or unpack

local function vector(x, y, z)
    local v = {xx = x or 0, yy = y or 0, zz = z or 0}
    function v:x() return self.xx end
    function v:y() return self.yy end
    function v:z() return self.zz end
    function v:dist_to(o) return math.sqrt((self.xx - o:x())^2 + (self.yy - o:y())^2 + (self.zz - o:z())^2) end
    function v:dist_to_ignore_z(o) return math.sqrt((self.xx - o:x())^2 + (self.yy - o:y())^2) end
    function v:squared_dist_to_ignore_z(o) return (self.xx - o:x())^2 + (self.yy - o:y())^2 end
    return v
end

-- QQT item_data mock. o = {sno, rarity, skin, display, ancestral, locked,
-- junk, filtered, affixes, rarity_error, durability}
local function item(o)
    local it = {o = o}
    function it:get_sno_id() return o.sno end
    function it:get_rarity()
        if o.rarity_error then error('get_rarity unavailable') end
        return o.rarity
    end
    function it:get_name() return o.skin or '' end
    function it:get_display_name() return o.display or o.skin or '' end
    function it:is_ancestral() return o.ancestral == true end
    function it:is_locked() return o.locked == true end
    function it:is_junk() return o.junk == true end
    function it:get_affixes() return o.affixes or {} end
    function it:is_filtered_by_loot_filter()
        if o.filtered == nil then error('no loot filter') end
        return o.filtered
    end
    function it:get_durability() return o.durability or 100 end
    function it:get_inventory_row() return 0 end
    function it:get_inventory_column() return 0 end
    return it
end

local function widget(value)
    local w = {value = value}
    function w:get() return self.value end
    function w:set(v) self.value = v end
    function w:render() return self.value end
    return w
end

-- h = new_alfred{widgets = {[hash] = value}, zone = 'Skov_Temis', files = {[name] = content}}
local function new_alfred(opts)
    opts = opts or {}
    local h = {now = 100, zone = opts.zone or 'Skov_Temis', logs = {}, inventory = {}, talismans = {},
        equipped = {}, stash = {}, sold = {}, salvaged = {}, stashed = {}, callbacks = {update = {}, render = {}, menu = {}},
        widgets = {}, tree_open = opts.tree_open or false, pos = vector(2578.11, -482.26, 31.5), batmobile = {}}
    local preset = opts.widgets or {}
    local env = setmetatable({}, {__index = _G})
    h.env = env
    local function remember(hash, w) h.widgets[hash] = w; return w end
    local function value_for(hash, default)
        if preset[hash] ~= nil then return preset[hash] end
        return default
    end
    env.get_hash = function(text) return text end
    env.checkbox = {new = function(_, default, hash) return remember(hash, widget(value_for(hash, default))) end}
    env.combo_box = {new = function(_, default, hash) return remember(hash, widget(value_for(hash, default))) end}
    env.slider_int = {new = function(_, _, _, default, hash) return remember(hash, widget(value_for(hash, default))) end}
    env.slider_float = {new = function(_, _, _, default, hash) return remember(hash, widget(value_for(hash, default))) end}
    env.input_text = {new = function(_, hash) return remember(hash, widget(value_for(hash, ''))) end}
    env.button = {new = function(_, hash) return remember(hash, widget(value_for(hash, false))) end}
    env.keybind = {new = function(_, key, _, hash)
        local w = remember(hash, widget(value_for(hash, false)))
        w.key = key
        function w:get_state() return self.value and 1 or 0 end
        function w:get_key() return self.key end
        return w
    end}
    env.tree_node = {new = function()
        local t = {}
        function t:push() return h.tree_open end
        function t:pop() end
        return t
    end}
    env.render_menu_header = function() end
    env.console = {print = function(line) h.logs[#h.logs + 1] = tostring(line) end}
    env.get_time_since_inject = function() return h.now end
    env.PERSISTENT_MODE = nil
    env.package = {path = ROOT .. '?.lua'}
    -- Writes never touch the repo: they land in h.written[path]. The learned
    -- catalog (data/seen_items.lua) is served back from h.written / opts.seen.
    h.written = {}
    env.io = setmetatable({open = function(name, mode)
        if mode and mode:find('w', 1, true) then
            local buf = {}
            return {write = function(_, text) buf[#buf + 1] = text end,
                close = function() h.written[name] = table.concat(buf) end}
        end
        return io.open(name, mode)
    end}, {__index = io})
    env.loadfile = function(path, ...)
        if type(path) == 'string' and path:find('seen_items', 1, true) then
            local text = h.written[path] or opts.seen
            if not text then return nil, 'no seen file' end
            return load(text, '=seen_items', 't', {})
        end
        return loadfile(path, ...)
    end
    env.vec3 = {new = function(_, x, y, z) return vector(x, y, z) end}
    env.vec2 = {new = function(_, x, y) return vector(x, y, 0) end}
    env.color = {new = function() return {} end}
    for _, name in ipairs({'color_white', 'color_red', 'color_green', 'color_orange', 'color_yellow', 'color_blue',
        'color_pink', 'color_orange_red'}) do env[name] = function() return {} end end
    env.graphics = setmetatable({}, {__index = function() return function() end end})
    env.attributes = {CURRENT_MOUNT = 1}
    env.on_update = function(fn) h.callbacks.update[#h.callbacks.update + 1] = fn end
    env.on_render = function(fn) h.callbacks.render[#h.callbacks.render + 1] = fn end
    env.on_render_menu = function(fn) h.callbacks.menu[#h.callbacks.menu + 1] = fn end
    env.get_current_world = function()
        return {get_current_zone_name = function() return h.zone end, get_name = function() return h.zone end}
    end
    env.get_player_position = function() return h.pos end
    local player = {}
    function player:get_inventory_items() return h.inventory end
    function player:get_talisman_items() return h.talismans end
    function player:get_item_count() return #h.inventory end
    function player:get_equipped_items() return h.equipped end
    function player:get_socketable_items() return {} end
    function player:get_consumable_items() return {} end
    function player:get_dungeon_key_items() return {} end
    function player:get_stash_items() return h.stash end
    function player:get_character_class_id() return 1 end
    function player:get_active_spell_id() return 0 end
    function player:get_attribute() return 0 end
    function player:get_position() return h.pos end
    function player:is_dead() return false end
    h.player = player
    env.get_local_player = function() return h.player end
    -- Temis NPCs (and the stash) right next to the player unless a test sets h.actors
    local npcs = {}
    for _, skin in ipairs({'TWN_Skov_Temis_Crafter_Blacksmith', 'TWN_Skov_Temis_Crafter_Occultist', 'Stash',
        'TWN_Skov_Temis_Vendor_Gambler'}) do
        npcs[#npcs + 1] = {get_skin_name = function() return skin end, get_position = function() return h.pos end}
    end
    env.actors_manager = {get_all_actors = function() return h.actors or npcs end}
    env.get_actors_list = function() return {} end
    local function take(it)   -- the game removes a sold/salvaged/stashed item from its bag
        for _, bag in ipairs({h.inventory, h.talismans}) do
            for i = #bag, 1, -1 do if bag[i] == it then table.remove(bag, i) end end
        end
    end
    env.loot_manager = {
        is_in_vendor_screen = function() return h.vendor == true end,
        sell_specific_item = function(it) h.sold[#h.sold + 1] = it; take(it); return true end,
        salvage_specific_item = function(it) h.salvaged[#h.salvaged + 1] = it; take(it); return true end,
        move_item_to_stash = function(it) h.stashed[#h.stashed + 1] = it; take(it); h.stash[#h.stash + 1] = it; return true end,
        repair_all_items = function() return true end,
        move_item_from_stash = function() return true end,
    }
    env.interact_vendor = function() h.interactions = (h.interactions or 0) + 1 end
    env.interact_object = env.interact_vendor
    env.teleport_to_waypoint = function(sno) h.teleported = sno; return true end
    env.pathfinder = setmetatable({}, {__index = function() return function() end end})
    env.utility = setmetatable({}, {__index = function() return function() return true end end})
    if opts.files then
        -- io.open override for selected plugin files (0-byte / BOM-only data)
        local base_io = env.io
        env.io = setmetatable({open = function(name, mode)
            for suffix, content in pairs(opts.files) do
                if name:sub(-#suffix) == suffix then
                    if content == false then return nil end
                    return {read = function() return content end, close = function() end, write = function() end}
                end
            end
            return base_io.open(name, mode)
        end}, {__index = io})
    end
    local loaded = {}
    local function load_module(name)
        if loaded[name] ~= nil then return loaded[name] end
        if opts.require_fail and opts.require_fail[name] then error('module ' .. name .. ' not found') end
        local path = ROOT .. name:gsub('%.', '/') .. '.lua'
        local chunk = assert(loadfile(path, 't', env))
        local result = chunk(name)
        if result == nil then result = true end
        loaded[name] = result
        return result
    end
    env.require = load_module
    h.mod = load_module
    for k, v in pairs(opts.globals or {}) do env[k] = v end   -- e.g. an old Alfred already loaded
    local main = assert(loadfile(ROOT .. 'main.lua', 't', env))
    main()
    h.api = env.AlfredTheButlerPlugin
    function h.set(hash, value)
        assert(h.widgets[hash], 'no widget ' .. hash)
        h.widgets[hash].value = value
    end
    function h.pulse(n, dt)
        for _ = 1, n or 1 do
            h.now = h.now + (dt or 0.25)
            for _, fn in ipairs(h.callbacks.update) do fn() end
        end
    end
    function h.render_menu()
        for _, fn in ipairs(h.callbacks.menu) do fn() end
        for _, fn in ipairs(h.callbacks.render) do fn() end
    end
    function h.refresh()
        h.mod('core.settings'):update_settings()
    end
    function h.decide(it, bag)
        h.refresh()
        return h.api.get_item_decision(it, bag)
    end
    function h.errors()
        local out = {}
        for _, line in ipairs(h.logs) do if line:find('error', 1, true) then out[#out + 1] = line end end
        return out
    end
    h.item, h.vector = item, vector
    return h
end

if ALFRED_TEST_HARNESS_ONLY then return {new = new_alfred, item = item, vector = vector} end

local failures, checks = {}, 0
local function check(label, fn)
    checks = checks + 1
    local ok, err = pcall(fn)
    if not ok then failures[#failures + 1] = label .. ': ' .. tostring(err) end
end
local function eq(a, b, m) assert(a == b, (m or 'mismatch') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end

local L = 'alfred_the_butler_'
-- A user who salvages everything that is not protected.
local SALVAGE_ALL = {[L .. 'main_toggle'] = true, ['alfred_the_butler_ancestral_item_legendary'] = 1,
    ['alfred_the_butler_ancestral_item_unique'] = 1, ['alfred_the_butler_item_unique'] = 1,
    ['alfred_the_butler_item_legendary_or_lower'] = 1}

check('the item database loads (mythics, charms, seals)', function()
    local h = new_alfred({widgets = SALVAGE_ALL})
    local classify = h.mod('core.classify')
    eq(classify.db_loaded, true, 'db loaded')
    eq(classify.db.source, 'DiabloTools/d4data', 'catalog source')
    assert(tostring(classify.db.version):match('^%d%d%d%d%-%d%d%-%d%d'), 'd4data version: ' .. tostring(classify.db.version))
    local charms, seals, mythics = 0, 0, 0
    for _, e in pairs(classify.db.talisman) do if e.g == 'charm' then charms = charms + 1 else seals = seals + 1 end end
    for _ in pairs(classify.db.mythic) do mythics = mythics + 1 end
    assert(charms > 300, 'charms: ' .. charms)
    assert(seals >= 10, 'seals: ' .. seals)
    assert(mythics > 13, 'mythic list is more than the old 13 ids: ' .. mythics)
    eq(#h.mod('core.utils').get_mythic_items() > 13, true, 'GUI mythic list from the db')
end)

check('a new Mythic Unique (rarity 8, unlisted sno) is kept although legendary/unique action is salvage', function()
    local h = new_alfred({widgets = SALVAGE_ALL})
    local mythic = item({sno = 2799001, rarity = 8, skin = 'Sword_Unique_Generic_104', ancestral = true,
        display = 'Mythic Blade GreaterAffix'})
    local action, reason, info = h.decide(mythic)
    eq(action, 'keep', 'decision')
    eq(info.mythic, true, 'mythic')
    assert(reason:find('mythic', 1, true), reason)
    -- non-ancestral copy and a "junk" flag do not change it
    eq((h.decide(item({sno = 2799002, rarity = 8, skin = 'Helm_Unique_Generic_01'}))), 'keep', 'non-ancestral')
    eq((h.decide(item({sno = 2799003, rarity = 8, skin = 'Boots_Unique_x', ancestral = true, junk = true}))), 'keep', 'junk flag')
    -- a mythic the game reports as rarity 6 is still caught by its name
    local _, _, byname = h.decide(item({sno = 2799008, rarity = 6, skin = 'Sword_Unique_Generic_7',
        display = 'Mythic Unique Sword', ancestral = true}))
    eq(byname.mythic_source, 'display name', 'display-name fallback')
    eq((h.decide(item({sno = 2799009, rarity = 6, skin = 'Ring_Unique_Mythic_01', ancestral = true}))), 'keep', 'skin fallback')
    -- a plain legendary of the same kind is salvaged (the rules still apply)
    eq((h.decide(item({sno = 2799004, rarity = 5, skin = 'Sword_Legendary_Generic_01', ancestral = true}))), 'salvage', 'legendary')
    eq((h.decide(item({sno = 2799005, rarity = 6, skin = 'Sword_Unique_Generic_01', ancestral = true}))), 'salvage', 'unique')
end)

check('old listed mythics are kept even when the game reports rarity 6', function()
    local h = new_alfred({widgets = SALVAGE_ALL})
    for _, sno in ipairs({223271, 1901484, 2603733}) do
        local action, _, info = h.decide(item({sno = sno, rarity = 6, skin = 'Axe2H_Unique_x', ancestral = true}))
        eq(action, 'keep', 'sno ' .. sno)
        eq(info.mythic_source, 'item db', 'source')
    end
end)

check('mythic charms and seals are kept whatever the charm/seal tier actions', function()
    local w = {}
    for k, v in pairs(SALVAGE_ALL) do w[k] = v end
    for _, kind in ipairs({'charm', 'seal'}) do
        for _, tier in ipairs({'magic', 'rare', 'legendary', 'unique', 'set', 'mythic'}) do
            w[L .. 'talisman_' .. kind .. '_tier_' .. tier] = 1
        end
    end
    local h = new_alfred({widgets = w})
    local cases = {
        {sno = 2611624, rarity = 8, skin = 'Generic_Charm_Unique_Doombringer'},   -- mythic charm (db)
        {sno = 2611677, rarity = 6, skin = 'Generic_Charm_Unique_Grandfather'},    -- listed, game says 6
        {sno = 2799100, rarity = 8, skin = 'Generic_Charm_Unique_New_01'},         -- unlisted rarity 8 charm
        {sno = 2622265, rarity = 8, skin = 'Talisman_Seal_Mythic_01'},             -- mythic seal
        {sno = 2609259, rarity_error = true, skin = 'Talisman_Seal_Mythic_02'},    -- rarity unreadable: db r=8
    }
    for _, o in ipairs(cases) do
        local action, reason, info = h.decide(item(o), true)
        eq(action, 'keep', 'sno ' .. o.sno .. ' (' .. tostring(reason) .. ')')
        eq(info.mythic, true, 'mythic ' .. o.sno)
    end
    -- the same rules do salvage a non-mythic unique charm
    eq((h.decide(item({sno = 2393546, rarity = 6, skin = 'Generic_Charm_Unique_Temerity'}), true)), 'salvage', 'unique charm')
end)

check('mythics follow the rules only when "Always keep mythics" is turned off', function()
    local w = {[L .. 'mythic_always_keep'] = false, [L .. 'talisman_charm_tier_mythic'] = 1,
        [L .. 'ancestral_item_mythic'] = 1}
    for k, v in pairs(SALVAGE_ALL) do w[k] = v end
    local h = new_alfred({widgets = w})
    eq((h.decide(item({sno = 2611624, rarity = 8, skin = 'Generic_Charm_x'}), true)), 'salvage', 'mythic charm tier action')
    eq((h.decide(item({sno = 2799001, rarity = 8, skin = 'Sword_Unique_x', ancestral = true}))), 'salvage', 'mythic action')
    -- the mythic keep list (default: every listed mythic checked) still keeps listed ones
    h.set(L .. 'use_unique_filter', true)
    eq((h.decide(item({sno = 223271, rarity = 8, skin = 'Sword2H_Unique_x', ancestral = true}))), 'keep', 'listed mythic kept')
end)

check('the loot filter never discards a mythic (Always keep on)', function()
    local w = {[L .. 'loot_filter_mode'] = true}
    for k, v in pairs(SALVAGE_ALL) do w[k] = v end
    local h = new_alfred({widgets = w})
    eq((h.decide(item({sno = 2799001, rarity = 8, skin = 'Sword_Unique_x', filtered = true}))), 'keep', 'mythic')
    eq((h.decide(item({sno = 2799006, rarity = 5, skin = 'Sword_Legendary_x', filtered = true}))), 'salvage', 'legendary')
    eq((h.decide(item({sno = 2799007, rarity = 5, skin = 'Sword_Legendary_x', filtered = false}))), 'keep', 'kept by filter')
    eq((h.decide(item({sno = 2611848, rarity = 8, skin = 'Generic_Charm_x', filtered = true}), true)), 'keep', 'mythic charm')
end)

check('charms and seals are classified by database, skin name and display name', function()
    local h = new_alfred({widgets = SALVAGE_ALL})
    local utils = h.mod('core.utils')
    local _, _, info = h.decide(item({sno = 2304176, rarity = 7, skin = 'Weird_Skin_Name'}), false)
    eq(info.kind, 'charm', 'db charm'); eq(info.kind_source, 'db', 'db source')
    _, _, info = h.decide(item({sno = 2418245, rarity = 5, skin = 'Unknown'}), false)
    eq(info.kind, 'seal', 'db seal')
    -- skin names: a charm skin containing "Ring"/"Sword" is a charm, not a ring/weapon
    local charm = item({sno = 2799200, rarity = 5, skin = 'Generic_Charm_Ring_Sword_001'})
    _, _, info = h.decide(charm, false)
    eq(info.kind, 'charm', 'skin charm'); eq(info.kind_source, 'skin', 'skin source')
    eq(utils.get_item_type(charm), 'talisman_charm', 'item type')
    eq(utils.get_item_type(item({sno = 2799201, skin = 'Talisman_Seal_Legendary_07'})), 'talisman_seal', 'skin seal')
    eq(utils.get_item_type(item({sno = 2799202, skin = 'Talisman_Charm_Rare_01'})), 'talisman_charm', 'talisman charm skin')
    -- display name fallback, talisman bag only
    _, _, info = h.decide(item({sno = 2799203, rarity = 4, skin = 'X_Unknown', display = 'Rare Horadric Seal'}), true)
    eq(info.kind, 'seal', 'display seal'); eq(info.kind_source, 'display', 'display source')
    _, _, info = h.decide(item({sno = 2799204, rarity = 4, skin = 'X_Unknown', display = 'Bone Charm'}), false)
    eq(info.kind, nil, 'an amulet named "Bone Charm" in the main bag is no charm')
    -- equipment slots still work
    eq(utils.get_item_type(item({sno = 1, skin = 'Ring_Legendary_Generic_01'})), 'ring', 'ring')
    eq(utils.get_item_type(item({sno = 2, skin = 'Quarterstaff_Legendary_01'})), 'weapon_2h', '2h')
    eq(utils.get_item_type(item({sno = 3, skin = 'Treasure_Reward_Cache_1'})), 'cache', 'cache')
end)

check('charm and seal rules: rarity tiers, keep list, greater affixes, sell', function()
    local h = new_alfred({widgets = SALVAGE_ALL})
    local function charm(sno, rarity, extra)
        local o = {sno = sno, rarity = rarity, skin = 'Generic_Charm_' .. sno}
        for k, v in pairs(extra or {}) do o[k] = v end
        return item(o)
    end
    -- defaults: magic/rare salvaged, legendary and above kept
    eq((h.decide(charm(2799300, 2), true)), 'salvage', 'magic')
    eq((h.decide(charm(2799301, 4), true)), 'salvage', 'rare')
    eq((h.decide(charm(2799302, 5), true)), 'keep', 'legendary')
    eq((h.decide(charm(2393546, 6), true)), 'keep', 'unique')
    eq((h.decide(charm(2304176, 7), true)), 'keep', 'set')
    eq((h.decide(item({sno = 2444850, rarity = 2, skin = 'Talisman_Seal_Magic'}), true)), 'salvage', 'magic seal')
    eq((h.decide(item({sno = 2418245, rarity = 5, skin = 'Talisman_Seal_Leg'}), true)), 'keep', 'legendary seal')
    -- set tier -> salvage, but a checked set charm stays (keep list)
    h.set(L .. 'talisman_charm_tier_set', 1)
    eq((h.decide(charm(2304176, 7), true)), 'salvage', 'set tier salvage')
    h.set(L .. 'talisman_charm_set_filter', true)
    h.set(L .. 'charm_set_2304176', true)
    eq((h.decide(charm(2304176, 7), true)), 'keep', 'keep list')
    eq((h.decide(charm(2308710, 7), true)), 'salvage', 'unchecked set charm')
    -- unique keep list toggle
    h.set(L .. 'talisman_charm_tier_unique', 2)
    eq((h.decide(charm(2393546, 6), true)), 'sell', 'unique tier sell')
    h.set(L .. 'talisman_charm_unique_filter', true)
    h.set(L .. 'charm_unique_2393546', true)
    eq((h.decide(charm(2393546, 6), true)), 'keep', 'unique keep list')
    -- greater affixes
    h.set(L .. 'talisman_charm_min_ga', 2)
    eq((h.decide(charm(2799303, 4, {display = 'x GreaterAffix y'}), true)), 'salvage', '1 GA')
    eq((h.decide(charm(2799304, 4, {display = 'GreaterAffix GreaterAffix'}), true)), 'keep', '2 GA')
    -- favorited charms are never touched
    eq((h.decide(charm(2799305, 2, {locked = true}), true)), 'keep', 'locked')
    -- seal keep list
    h.set(L .. 'talisman_seal_tier_legendary', 1)
    eq((h.decide(item({sno = 2418245, rarity = 5, skin = 'Talisman_Seal_Leg'}), true)), 'salvage', 'legendary seal salvage')
    h.set(L .. 'talisman_seal_mythic_filter', true)
    h.set(L .. 'seal_keep_2418245', true)
    eq((h.decide(item({sno = 2418245, rarity = 5, skin = 'Talisman_Seal_Leg'}), true)), 'keep', 'seal keep list')
end)

check('inventory scan: counts, talisman bag full triggers, sell/salvage tasks never touch a mythic', function()
    local w = {[L .. 'max_inventory'] = 20}
    for k, v in pairs(SALVAGE_ALL) do w[k] = v end
    local h = new_alfred({widgets = w})
    local mythic = item({sno = 2799001, rarity = 8, skin = 'Sword_Unique_x', ancestral = true})
    h.inventory = {mythic, item({sno = 5, rarity = 5, skin = 'Helm_Legendary_1', ancestral = true}),
        item({sno = 6, rarity = 6, skin = 'Boots_Unique_1'})}
    for i = 1, 20 do h.talismans[i] = item({sno = 2799400 + i, rarity = i % 2 == 0 and 2 or 5, skin = 'Generic_Charm_' .. i}) end
    h.talismans[21] = item({sno = 2611624, rarity = 8, skin = 'Generic_Charm_Doombringer'})
    h.pulse(2)
    local tracker = h.mod('core.tracker')
    eq(tracker.salvage_count, 2, 'salvage count')
    eq(tracker.stash_count, 1, 'stash count (mythic)')
    eq(tracker.salvage_talisman_count, 10, 'magic charms to salvage')
    eq(tracker.stash_talisman_count, 11, 'legendary + mythic charms kept')
    eq(tracker.talisman_inventory_full, true, 'talisman bag full')
    eq(tracker.need_trigger, true, 'need_trigger')
    eq(h.api.get_status().need_trigger, true, 'status need_trigger')
    -- run the task chain in town and check nothing mythic was sold/salvaged
    h.vendor = true
    h.api.trigger_tasks('test', function() h.done = true end)
    h.pulse(60, 0.6)
    for _, list in ipairs({h.sold, h.salvaged}) do
        for _, it in ipairs(list) do
            assert(it ~= mythic and it ~= h.talismans[21], 'a mythic was sold or salvaged')
        end
    end
    assert(#h.salvaged > 0, 'something was salvaged')
    eq(#h.errors(), 0, 'no update errors: ' .. table.concat(h.errors(), ' | '))
end)

check('dump inventory item info prints rarity, skin, type, group and decision', function()
    local h = new_alfred({widgets = SALVAGE_ALL})
    h.inventory = {item({sno = 2799001, rarity = 8, skin = 'Sword_Unique_x', display = 'New Mythic', ancestral = true})}
    h.talismans = {item({sno = 2622265, rarity = 8, skin = 'Talisman_Seal_Mythic_01'})}
    h.refresh()
    eq(h.api.dump_items(), 2, 'items dumped')
    local text = table.concat(h.logs, '\n')
    for _, needle in ipairs({'sno=2799001', 'rarity=8', 'mythic=true', 'skin=Sword_Unique_x', 'display=New Mythic',
        'type=weapon_1h', 'group=seal(db)', '-> keep', 'item db ' .. h.mod('core.classify').db.version}) do
        assert(text:find(needle, 1, true), 'missing ' .. needle .. ' in\n' .. text)
    end
    -- the GUI button does the same
    h.logs = {}
    h.set(L .. 'dump_items_button', true)
    h.render_menu()
    assert(table.concat(h.logs, '\n'):find('item dump done: 2 items', 1, true), 'button dump')
end)

check('missing item database: rarity 8 and skin names still protect mythics and find charms', function()
    local h = new_alfred({widgets = SALVAGE_ALL, require_fail = {['data.item_db'] = true}})
    local classify = h.mod('core.classify')
    eq(classify.db_loaded, false, 'db missing')
    eq((h.decide(item({sno = 2799001, rarity = 8, skin = 'Sword_Unique_x', ancestral = true}))), 'keep', 'rarity 8 kept')
    local _, _, info = h.decide(item({sno = 2799500, rarity = 2, skin = 'Talisman_Seal_Magic_1'}), true)
    eq(info.kind, 'seal', 'seal by skin without db')
end)

check('0-byte / BOM-only / missing data files load without crashing', function()
    local h = new_alfred({widgets = SALVAGE_ALL, files = {['unique-item.json'] = '', ['affix_helm.json'] = '\239\187\191',
        ['aspect_ring.json'] = '[{"broken"', ['set-charm.json'] = false}})
    h.pulse(3)
    eq(#h.errors(), 0, 'no update errors')
    eq(#h.mod('core.utils').get_unique_items(), 0, 'empty unique list')
end)

check('unreadable rarity with an SNO the database does not know is kept, not treated as magic', function()
    local h = new_alfred({widgets = SALVAGE_ALL})
    local cases = {
        {o = {sno = 2799999, rarity_error = true, skin = 'Generic_Charm_Legendary_9'}, bag = true},   -- unknown charm
        {o = {sno = 2799998, rarity_error = true, skin = 'Talisman_Seal_Legendary_9'}, bag = true},   -- unknown seal
        {o = {sno = 2799997, rarity_error = true, skin = 'Helm_Unique_x', ancestral = true}},        -- unique helm
        {o = {sno = 2799996, rarity_error = true, skin = 'Boots_Unique_New'}},                       -- non-ancestral
    }
    for _, c in ipairs(cases) do
        local action, reason, info = h.decide(item(c.o), c.bag)
        eq(action, 'keep', 'sno ' .. c.o.sno .. ' (' .. tostring(reason) .. ')')
        eq(reason, 'rarity unknown', 'reason ' .. c.o.sno)
        eq(info.rarity_source, 'unknown', 'source ' .. c.o.sno)
    end
    -- a db-known charm with an unreadable rarity still follows its db rarity
    local _, _, info = h.decide(item({sno = 2609259, rarity_error = true, skin = 'Talisman_Seal_Mythic_02'}), true)
    eq(info.rarity_source, 'item db', 'db rarity used')
    -- favorited and mythic reasons still win
    local _, reason = h.decide(item({sno = 2799995, rarity_error = true, skin = 'Sword_Mythic_x', ancestral = true}))
    eq(reason, 'mythic (always kept)', 'mythic first')
end)

check('talisman bag trigger never exceeds the 33-slot bag', function()
    local w = {[L .. 'max_inventory'] = 33, [L .. 'max_talisman'] = 60}
    for k, v in pairs(SALVAGE_ALL) do w[k] = v end
    local h = new_alfred({widgets = w})
    for i = 1, 33 do h.talismans[i] = item({sno = 2799600 + i, rarity = 5, skin = 'Generic_Charm_' .. i}) end
    h.pulse(2)
    eq(h.mod('core.tracker').talisman_inventory_full, true, '33 charms = full although the slider says 60')
    h.talismans[33] = nil
    h.pulse(2)
    eq(h.mod('core.tracker').talisman_inventory_full, false, '32 charms not full')
end)

check('mythic list search box filters the mythic checkboxes (empty search shows all)', function()
    local h = new_alfred({widgets = SALVAGE_ALL, tree_open = true})
    h.set(L .. 'use_unique_filter', true)
    local rendered = {}
    for hash, w in pairs(h.widgets) do
        if hash:find('^alfred_the_butler_mythic_%d') then
            local w2 = w
            function w2:render() rendered[hash] = true; return self.value end
        end
    end
    local function count() local n = 0; for _ in pairs(rendered) do n = n + 1 end; return n end
    h.render_menu()
    local all = count()
    assert(all > 13, 'every mythic rendered with an empty search: ' .. all)
    rendered = {}
    h.set('alfred_the_butlermythic_search_input', 'grandfather')
    h.render_menu()
    assert(rendered['alfred_the_butler_mythic_223271'], 'The Grandfather shown')
    assert(count() < all, 'search filters: ' .. count() .. ' of ' .. all)
    rendered = {}
    h.set('alfred_the_butlermythic_search_input', '(%')
    h.render_menu()
    eq(count(), 0, 'pattern characters match nothing, no error')
    eq(#h.errors(), 0, 'no errors')
end)

check('GUI renders with every tree open and a pattern character in a search box', function()
    local h = new_alfred({widgets = SALVAGE_ALL, tree_open = true})
    h.set(L .. 'use_unique_filter', true)
    h.set('alfred_the_butlerunique_search_input', '(')
    h.set('alfred_the_butlercharm_unique_search_input', '%')
    h.set(L .. 'talisman_charm_unique_filter', true)
    h.set(L .. 'talisman_seal_mythic_filter', true)
    h.set(L .. 'talisman_charm_set_filter', true)
    h.render_menu()
    h.pulse(2)
    eq(#h.errors(), 0, 'no errors')
end)

check('self-learning catalog remembers an unknown mythic charm and reloads it into the lists', function()
    local h = new_alfred({widgets = SALVAGE_ALL})
    local classify = h.mod('core.classify')
    local charm = item({sno = 2899999, rarity = 8, skin = 'Talisman_Charm_Unique_New_001',
        display = 'Brand New Mythic Charm'})
    local action = h.decide(charm, true)
    eq(action, 'keep', 'unknown mythic charm kept')
    eq(classify.learned[2899999] ~= nil, true, 'learned')
    eq(classify.db.talisman[2899999].g, 'charm', 'merged as charm')
    h.now = h.now + 60
    h.mod('core.utils').update_tracker_count(h.env.get_local_player(), true)
    local path, text = next(h.written)
    assert(text and text:find('2899999', 1, true), 'seen file written')
    assert(path:find('seen_items.lua', 1, true), 'written to data/seen_items.lua: ' .. tostring(path))
    local h2 = new_alfred({widgets = SALVAGE_ALL, seen = text})
    local found = false
    for _, e in ipairs(h2.mod('core.utils').get_unique_charm_items()) do
        if e.sno_id == 2899999 then found = true end
    end
    eq(found, true, 'learned charm appears in the GUI list after reload')
    -- rolled-rarity (legendary) charms are not learned
    h.decide(item({sno = 2899998, rarity = 5, skin = 'Talisman_Charm_Rare_New', display = 'Some Charm'}), true)
    eq(classify.learned[2899998], nil, 'legendary charm not learned')
end)

if #failures > 0 then error('Alfred item regressions failed:\n' .. table.concat(failures, '\n')) end
print(string.format('PASS: Alfred item classification (%d checks)', checks))
