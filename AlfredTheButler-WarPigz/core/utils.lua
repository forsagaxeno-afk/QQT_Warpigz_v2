local json = require 'core.json'
local tracker = require 'core.tracker'
local town = require 'core.town'
local classify = require 'core.classify'

local utils    = {
    settings = {},
    last_dump_time = 0,
    classify = classify,
}
utils.TALISMAN_BAG_SIZE = 33

function utils.get_town()
    return town.get(utils.settings.town_choice)
end
function utils.is_in_town()
    local world = get_current_world()
    if not world then return false end
    return world:get_current_zone_name() == utils.get_town().zone_name
end
local affix_slot_names = {
    'helm', 'chest', 'gloves', 'pants', 'boots',
    'amulet', 'ring', 'offhand',
    'weapon_1h', 'weapon_2h',
    'talisman_seal', 'talisman_charm',
}
local aspect_slot_names = {
    'weapon', 'helm', 'chest', 'gloves', 'pants', 'boots',
    'amulet', 'ring', 'offhand',
    'talisman_seal', 'talisman_charm',
}
local item_affix = {}
local item_aspect = {}
local item_unique = {}
local json_classes = {}   -- [sno] = {class = {...}, set = '...'} from the charm JSON files
-- npc_enum / npc_loc_enum / npc_via_loc_enum / walls are sourced from the
-- active town config (see core/town.lua).
utils.npc_enum = setmetatable({}, {
    __index = function(_, key) return utils.get_town().npc_enum[key] end,
})
utils.npc_loc_enum = setmetatable({}, {
    __index = function(_, key) return utils.get_town().npc_loc_enum[key] end,
})
utils.npc_via_loc_enum = setmetatable({}, {
    __index = function(_, key) return utils.get_town().npc_via_loc_enum[key] end,
})
function utils.get_walls()
    return utils.get_town().walls or {}
end
utils.item_enum = {
    KEEP = 0,
    SALVAGE = 1,
    SELL = 2
}
utils.stash_extra_enum = {
    NEVER = 0,
    FULL = 1,
    ALWAYS = 2
}
utils.failed_action_enum = {
    LOG = 0,
    RETRY = 1
}

function utils.log(msg)
    if utils.settings.debug then console.print('[Alfred] ' .. tostring(msg)) end
end
utils.debug = utils.log

-- Compatibility tables (read by older integrations): now built from the
-- item database instead of a hardcoded 13-id list.
utils.mythics = {}
utils.mythic_seals = {}
for sno, entry in pairs(classify.db.mythic) do
    if entry.g == 'seal' then utils.mythic_seals[sno] = entry.n
    elseif entry.g ~= 'charm' then utils.mythics[sno] = entry.n end
end

-- ---------------------------------------------------------------------------
-- Data files (plugin folder only; every failure is logged, never fatal)
-- ---------------------------------------------------------------------------
local function get_plugin_root_path()
    local path = type(package) == 'table' and type(package.path) == 'string' and package.path or ''
    local first = path:match('^([^;]*)') or ''
    local root = first:gsub('%?.*$', '')
    return root
end
utils.get_plugin_root_path = get_plugin_root_path
local function path_join(...)
    local root = get_plugin_root_path()
    local sep = (root:find('/', 1, true) and not root:find('\\', 1, true)) and '/' or '\\'
    return root .. table.concat({...}, sep)
end
utils.path_join = path_join

-- Decoded JSON table or nil (missing, 0-byte, BOM-only or malformed file).
local function read_json(filename)
    local file = io.open(filename, 'r')
    if not file then utils.log('cannot open ' .. filename); return nil end
    local raw = file:read('*a')
    file:close()
    if type(raw) ~= 'string' then return nil end
    raw = raw:match('[%[%{].*')
    if not raw then utils.log('empty data file ' .. filename); return nil end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' then utils.log('bad data file ' .. filename); return nil end
    return data
end
utils.read_json = read_json

local function normalize_class(c)
    return (type(c) ~= 'table' or #c == 0) and {'all'} or c
end

local function load_affix_slot(slot_name)
    local data = read_json(path_join('data', 'affix', 'affix_' .. slot_name .. '.json'))
    if not data then return end
    local group = { name = slot_name, data = {} }
    for _, affix in pairs(data) do
        if type(affix) == 'table' then
            affix.sno_id      = affix.sno_id or affix.id
            affix.class       = normalize_class(affix.class)
            affix.name        = tostring(affix.name or affix.sno_id)
            affix.description = affix.description or affix.name or ''
            if affix.sno_id then group.data[#group.data+1] = affix end
        end
    end
    item_affix[#item_affix+1] = group
end

local function load_aspect_slot(slot_name)
    local data = read_json(path_join('data', 'affix', 'aspect_' .. slot_name .. '.json'))
    if not data then return end
    for _, affix in pairs(data) do
        if type(affix) == 'table' then
            affix.sno_id      = affix.sno_id or affix.id
            affix.class       = normalize_class(affix.class)
            affix.name        = tostring(affix.name or affix.sno_id)
            affix.description = affix.description or affix.name or ''
            if affix.sno_id and not item_aspect[affix.sno_id] then
                item_aspect[affix.sno_id] = affix
            end
        end
    end
end
local function load_unique_items()
    local data = read_json(path_join('data', 'affix', 'unique-item.json'))
    for _, item in pairs(data or {}) do
        if type(item) == 'table' and (item.id or item.sno_id) then
            local entry = {
                sno_id      = item.id or item.sno_id,
                name        = tostring(item.name or item.id or item.sno_id),
                item_type   = item.itemTypeName or item.item_type or '',
                class       = normalize_class(item.playerClassNames or item.class),
            }
            entry.description = entry.name
            if entry.item_type ~= 'Charm' then item_unique[#item_unique+1] = entry end
        end
    end
    -- Charm class / set names only; the charm lists come from the item database.
    for _, file in ipairs({'unique-charm.json', 'set-charm.json'}) do
        for _, item in pairs(read_json(path_join('data', 'affix', file)) or {}) do
            if type(item) == 'table' and item.sno_id then
                json_classes[item.sno_id] = {class = normalize_class(item.class), set = item.set}
            end
        end
    end
end
function utils.get_item_affixes()
    return item_affix
end
function utils.get_item_aspects()
    return item_aspect
end
function utils.get_unique_items()
    return item_unique
end
local function with_classes(list)
    for _, entry in ipairs(list) do
        local extra = json_classes[entry.sno_id]
        if extra then
            entry.class = extra.class
            if extra.set then entry.description = entry.name .. ' (' .. tostring(extra.set) .. ')' end
        end
    end
    return list
end
-- Unique and mythic charms (checkbox prefix charm_unique_).
function utils.get_unique_charm_items()
    return with_classes(classify.talisman_list('charm', {[6] = true, [8] = true}))
end
-- Set charms (checkbox prefix charm_set_).
function utils.get_set_charm_items()
    return with_classes(classify.talisman_list('charm', {[7] = true}))
end
-- Mythic and unique seals (checkbox prefix seal_mythic_).
function utils.get_mythic_seal_items()
    return classify.talisman_list('seal', {[6] = true, [8] = true})
end
-- Legendary seals (checkbox prefix seal_keep_).
function utils.get_legendary_seal_items()
    return classify.talisman_list('seal', {[5] = true})
end
-- Mythic equipment (checkbox prefix mythic_): every uber / mythic unique the
-- database knows. New mythic uniques are recognised by rarity 8 regardless.
function utils.get_mythic_items()
    return classify.mythic_list({uber = true, weapon = true, armor = true, jewelry = true, offhand = true, unique = true})
end

function utils.get_character_class()
    local local_player = get_local_player()
    if not local_player then return 'default' end
    local class_id = classify.call(local_player, 'get_character_class_id')
    local character_classes = {
        [0] = 'sorcerer',
        [1] = 'barbarian',
        [3] = 'rogue',
        [5] = 'druid',
        [6] = 'necromancer',
        [7] = 'spiritborn',
        [9] = 'paladin',
        [10] = 'warlock',
    }
    return character_classes[class_id] or 'default'
end

function utils.player_in_zone(zname)
    local world = get_current_world()
    return world ~= nil and world:get_current_zone_name() == zname
end
function utils.reset_all_task()
    local previous = {}
    for key,data in pairs(tracker) do
        if key ~= 'previous' and key ~= 'cached_inventory' and key ~= 'external_trigger_callbacks' then
            previous[key] = data
        end
    end
    tracker.previous = previous
    tracker.last_reset = 0
    tracker.teleport = false
    tracker.teleport_done = false
    tracker.teleport_failed = false
    tracker.sell_failed = false
    tracker.sell_done = false
    tracker.salvage_failed = false
    tracker.salvage_done = false
    tracker.salvage_talisman_failed = false
    tracker.salvage_talisman_done = false
    tracker.repair_failed = false
    tracker.repair_done = false
    tracker.stash_failed = false
    tracker.stash_done = false
    tracker.stash_full = false
    tracker.stash_pull_done = false
    tracker.stash_pull_failed = false
    tracker.all_task_done = false
    tracker.need_trigger = false
    tracker.inventory_full = false
    tracker.stash_socketables     = false
    tracker.stash_keys            = false
    tracker.stash_sigils          = false
    tracker.salvage_sigils        = false
    tracker.stash_boss_materials  = false
    tracker.stash_talisman_seal    = false
    tracker.stash_talisman_charm   = false
    tracker.salvage_talisman_seal  = false
    tracker.salvage_talisman_charm = false
    tracker.talisman_inventory_full    = false
    tracker.stash_talisman_count       = 0
    tracker.salvage_talisman_count     = 0
    tracker.trigger_tasks = false
end
function utils.get_npc(name)
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        if actor:get_skin_name() == name then return actor end
    end
    -- fallback: interactable objects (stash etc.) may not be in actors_manager
    if type(get_actors_list) == 'function' then
        for _, actor in pairs(get_actors_list() or {}) do
            if actor:get_skin_name() == name then return actor end
        end
    end
    return nil
end
function utils.get_npc_location(name)
    return utils.npc_loc_enum[name]
end
function utils.distance_to(target)
    local player_pos = get_player_position()
    local target_pos

    if target.get_position then
        target_pos = target:get_position()
    elseif target.x then
        target_pos = target
    end

    return player_pos:dist_to(target_pos)
end
function utils.is_same_position(pos1, pos2)
    return pos1:x() == pos2:x() and pos1:y() == pos2:y() and pos1:z() == pos2:z()
end

local move_state = { last_target_key = nil, via_passed = false }
function utils.compute_move_target(target_pos)
    if not target_pos then return target_pos end
    local player_pos = get_player_position()
    if not player_pos then return target_pos end

    local target_key = string.format('%.4f,%.4f,%.4f', target_pos:x(), target_pos:y(), target_pos:z())
    if move_state.last_target_key ~= target_key then
        move_state.last_target_key = target_key
        move_state.via_passed = false
    end

    for _, wall in ipairs(utils.get_walls()) do
        local player_inside = player_pos:dist_to(wall.inside_anchor) < wall.radius
        local target_inside = target_pos:dist_to(wall.inside_anchor) < wall.radius
        if player_inside ~= target_inside then
            if move_state.via_passed then
                return target_pos
            end
            if player_pos:dist_to(wall.via) < 2.5 then
                move_state.via_passed = true
                return target_pos
            end
            return wall.via
        end
    end

    return target_pos
end

function utils.get_greater_affix_count(display_name)
    return classify.greater_affix_count(display_name)
end
function utils.is_max_aspect(affix)
    local affix_id = affix.affix_name_hash
    if item_aspect[affix_id] ~= nil then
        local roll, roll_max, roll_min = affix:get_roll(), affix:get_roll_max(), affix:get_roll_min()
        if roll == roll_max then return true end
        if roll_max > roll_min then
            if roll_max == math.floor(roll_max) then return math.floor(roll + 0.5) >= roll_max end
            return math.floor((roll * 100) + 0.5) >= roll_max * 100
        end
        if roll_max == math.floor(roll_max) then return math.floor(roll + 0.5) <= roll_max end
        return math.floor((roll * 100) + 0.5) <= roll_max * 100
    end
    return false
end
local function sno_of(item) return classify.call(item, 'get_sno_id') end
function utils.is_correct_unique(item)
    return utils.settings.ancestral_unique[sno_of(item)] ~= nil
end
function utils.is_correct_mythic(item)
    return utils.settings.ancestral_mythic[sno_of(item)] ~= nil
end
function utils.is_correct_unique_charm(item)
    return (utils.settings.talisman_charm_unique or {})[sno_of(item)] ~= nil
end
function utils.is_correct_set_charm(item)
    return (utils.settings.talisman_charm_set or {})[sno_of(item)] ~= nil
end
function utils.is_mythic_seal(item)
    local info = classify.read(item, true)
    return info.kind == 'seal' and info.mythic
end
function utils.is_correct_mythic_seal(item)
    return (utils.settings.talisman_seal_mythic or {})[sno_of(item)] ~= nil
end
function utils.is_correct_affix(item_type, affix)
    if not utils.settings.ancestral_affix then return false end
    local affix_id = affix.affix_name_hash
    local t = utils.settings.ancestral_affix[item_type]
    return t and t[affix_id] or false
end
function utils.is_correct_aspect(affix)
    local affix_id = affix.affix_name_hash
    return (utils.settings.ancestral_aspect or {})[affix_id] ~= nil
end

local _armor_slots = { 'helm', 'chest', 'gloves', 'pants', 'boots', 'amulet', 'ring' }
local _offhand_pats = { 'focus', 'book', 'totem', 'shield' }
local _weapon_2h_pats = { '2h', 'quarterstaff', 'glaive', 'polearm', 'bow', 'crossbow', 'staff' }
local _weapon_1h_pats = { '1h', 'wand', 'flail', 'dagger', 'axe', 'sword', 'mace', 'blade', 'scythe', 'weapon' }
-- Equipment slot from the skin name; charms and seals first (database, then
-- skin-name patterns) so a charm skin containing 'ring'/'sword' is a charm.
local function item_type_of(info)
    local name = type(info.skin) == 'string' and info.skin:lower() or ''
    if name:find('cache', 1, true) then return 'cache' end
    if name:find('tempering', 1, true) then return 'tempering' end
    if info.kind == 'seal' then return 'talisman_seal' end
    if info.kind == 'charm' then return 'talisman_charm' end
    if name == '' then return 'unknown' end
    for _, slot in ipairs(_armor_slots) do
        if name:find(slot, 1, true) then return slot end
    end
    for _, pat in ipairs(_offhand_pats) do
        if name:find(pat, 1, true) then return 'offhand' end
    end
    for _, pat in ipairs(_weapon_2h_pats) do
        if name:find(pat, 1, true) then return 'weapon_2h' end
    end
    for _, pat in ipairs(_weapon_1h_pats) do
        if name:find(pat, 1, true) then return 'weapon_1h' end
    end
    return 'unknown'
end
utils.item_type_of = item_type_of
function utils.get_item_type(item, in_talisman_bag)
    return item_type_of(classify.read(item, in_talisman_bag))
end

-- Full decision for one item: action (0 keep / 1 salvage / 2 sell), reason,
-- info snapshot, item type, matched-affix count.
function utils.item_decision(item, in_talisman_bag)
    local info = classify.read(item, in_talisman_bag)
    local item_type = item_type_of(info)
    local action, reason, matched
    if info.kind then
        action, reason = classify.talisman_action(info, utils.settings)
    else
        action, reason, matched = classify.equipment_action(info, item_type, utils.settings)
    end
    if action ~= utils.item_enum.SALVAGE and action ~= utils.item_enum.SELL then action = utils.item_enum.KEEP end
    return action, reason, info, item_type, matched or 0
end

function utils.should_salvage_talisman(item)
    return item ~= nil and (utils.item_decision(item, true)) == utils.item_enum.SALVAGE
end
function utils.should_sell_talisman(item)
    return item ~= nil and (utils.item_decision(item, true)) == utils.item_enum.SELL
end
function utils.is_salvage_or_sell(item,action)
    local is_salvage_or_sell = utils.is_salvage_or_sell_with_data(item, action)
    return is_salvage_or_sell
end
function utils.is_salvage_or_sell_with_data(item,action)
    if not item then return false, 0, false end
    local decided, _, _, _, matched = utils.item_decision(item, false)
    return decided == action, matched, false
end
function utils.is_mounted()
    local local_player = get_local_player()
    return local_player:get_attribute(attributes.CURRENT_MOUNT) < 0
end

-- Read-only Looter check (LooteerV3 is_actively_looting, else the legacy
-- getSettings('looting') status flag). Alfred never writes Looter settings:
-- LooteerV2's setter cannot restore a false value, and V3's 'looting' is a
-- status flag Looter rewrites every pulse.
function utils.looter_busy()
    local looter = LooteerPlugin
    if type(looter) ~= 'table' then return false end
    local fn = looter.is_actively_looting
    if type(fn) == 'function' then
        local ok, busy = pcall(fn)
        return ok and busy == true
    end
    fn = looter.getSettings
    if type(fn) == 'function' then
        local ok, busy = pcall(fn, 'looting')
        return ok and busy == true
    end
    return false
end

local function list_of(player, method)
    local list = classify.call(player, method)
    if type(list) == 'table' then return list end
    return {}
end
utils.list_of = list_of

local update_debounce_time = -math.huge
local update_debounce_timeout = 0.5
local LEARNED_SAVE_INTERVAL = 30
local learned_saved_at = -math.huge
function utils.update_tracker_count(local_player, force)
    local now = get_time_since_inject()
    if not force and update_debounce_time + update_debounce_timeout > now then return end
    update_debounce_time = now
    if classify.learned_dirty and now - learned_saved_at >= LEARNED_SAVE_INTERVAL then
        learned_saved_at = now
        if utils.write_file(classify.seen_path(), classify.learned_source()) then
            classify.learned_dirty = false
        end
    end
    local s = utils.settings

    local cached_inventory = {}
    local salvage_counter, sell_counter, stash_counter = 0, 0, 0
    for _, item in pairs(list_of(local_player, 'get_inventory_items')) do
        local action, _, info, item_type, matched = utils.item_decision(item, false)
        local is_salvage = action == utils.item_enum.SALVAGE
        local is_sell = action == utils.item_enum.SELL
        local is_stash = not is_salvage and not is_sell
        if is_stash and ((s.skip_favorite and info.locked) or (item_type == 'cache' and s.skip_cache)) then
            is_stash = false
        end
        if is_salvage then
            salvage_counter = salvage_counter + 1
        elseif is_sell then
            sell_counter = sell_counter + 1
        elseif is_stash then
            stash_counter = stash_counter + 1
        end
        cached_inventory[#cached_inventory+1] = {
            is_salvage = is_salvage,
            is_sell = is_sell,
            is_stash = is_stash,
            affix_count = matched,
            is_max_aspect = false,
            item = item
        }
    end
    local salvage_talisman_counter, stash_talisman_counter = 0, 0
    local talismans = list_of(local_player, 'get_talisman_items')
    for _, item in pairs(talismans) do
        local action = utils.item_decision(item, true)
        if action == utils.item_enum.SELL then
            sell_counter = sell_counter + 1
        elseif action == utils.item_enum.SALVAGE then
            salvage_talisman_counter = salvage_talisman_counter + 1
        else
            stash_talisman_counter = stash_talisman_counter + 1
        end
    end
    local max_inventory = s.max_inventory or 25
    -- The talisman bag holds 33 (LooteerV3 treats >= 33 as full); a trigger
    -- above that would never fire and the bag would stop taking charms.
    local max_talisman = (s.max_talisman or 0) > 0 and s.max_talisman or max_inventory
    if max_talisman > utils.TALISMAN_BAG_SIZE then max_talisman = utils.TALISMAN_BAG_SIZE end
    tracker.cached_inventory = cached_inventory
    tracker.inventory_count = classify.call(local_player, 'get_item_count') or #list_of(local_player, 'get_inventory_items')
    tracker.salvage_count = salvage_counter
    tracker.salvage_talisman_count = salvage_talisman_counter
    tracker.stash_talisman_count = stash_talisman_counter
    tracker.talisman_count = #talismans
    tracker.sell_count = sell_counter
    tracker.stash_count = stash_counter
    tracker.inventory_full = tracker.inventory_count >= max_inventory

    local need_repair = false
    for _, item in pairs(list_of(local_player, 'get_equipped_items')) do
        local durability = classify.call(item, 'get_durability')
        if type(durability) == 'number' and durability <= 10 then
            need_repair = true
        end
    end
    tracker.need_repair = need_repair
    local enum = utils.stash_extra_enum
    tracker.need_stash_socketables = s.stash_socketables == enum.FULL and #list_of(local_player, 'get_socketable_items') >= max_inventory
    tracker.need_stash_consumables = s.stash_consumables == enum.FULL and #list_of(local_player, 'get_consumable_items') >= max_inventory
    tracker.need_stash_keys        = s.stash_keys        == enum.FULL and #list_of(local_player, 'get_dungeon_key_items') >= max_inventory
    tracker.talisman_inventory_full    = #talismans >= max_talisman

    tracker.need_trigger = tracker.inventory_full or
        tracker.need_repair or
        tracker.need_stash_socketables or
        tracker.need_stash_consumables or
        tracker.need_stash_keys or
        tracker.talisman_inventory_full

    tracker.name = s.plugin_label or tracker.name
    tracker.version = s.plugin_version
end

-- "Dump inventory item info": one console line per bag item with everything
-- the classification used, so a live rarity-8 Mythic Unique can be verified.
function utils.dump_item_info()
    local player = get_local_player()
    if not player then console.print('[Alfred] dump: no local player'); return 0 end
    local names = {[0] = 'keep', [1] = 'salvage', [2] = 'sell'}
    local count = 0
    console.print(string.format('[Alfred] item dump (item db %s, %s)', tostring(classify.db.version),
        classify.db_loaded and 'loaded' or 'MISSING - skin/rarity fallbacks only'))
    for _, bag in ipairs({{'inventory', 'get_inventory_items', false}, {'talisman', 'get_talisman_items', true}}) do
        for _, item in pairs(list_of(player, bag[2])) do
            local ok, action, reason, info, item_type = pcall(utils.item_decision, item, bag[3])
            count = count + 1
            if ok then
                console.print(string.format('[Alfred] %s #%d sno=%s rarity=%s(%s) tier=%s mythic=%s%s skin=%s display=%s type=%s group=%s(%s) ancestral=%s ga=%d locked=%s -> %s (%s)',
                    bag[1], count, tostring(info.sno), tostring(info.rarity), tostring(info.rarity_source),
                    classify.tier(info.rarity), tostring(info.mythic),
                    info.mythic_source and (' [' .. info.mythic_source .. ']') or '',
                    tostring(info.skin), tostring(info.display), tostring(item_type), tostring(info.kind or '-'),
                    tostring(info.kind_source or '-'), tostring(info.ancestral), info.ga, tostring(info.locked),
                    names[action] or tostring(action), tostring(reason)))
            else
                console.print(string.format('[Alfred] %s #%d unreadable item: %s', bag[1], count, tostring(action)))
            end
        end
    end
    console.print(string.format('[Alfred] item dump done: %d items', count))
    return count
end

local function write_file(filename, text)
    local file = io.open(filename, 'w')
    if not file then utils.log('error opening file ' .. filename); return false end
    file:write(text)
    file:close()
    return true
end
utils.write_file = write_file
local function export_name(prefix)
    return path_join('data', 'export', prefix .. tostring(os.time()) .. '.json')
end

local function filter_checkbox_names()
    local names = {}
    for _,affix_type in pairs(item_affix) do
        for _,affix in pairs(affix_type.data) do
            names[#names+1] = tostring(affix_type.name) .. '_affix_' .. tostring(affix.sno_id)
        end
    end
    for _,aspect in pairs(item_aspect) do names[#names+1] = 'aspect_' .. tostring(aspect.sno_id) end
    for _,item in pairs(item_unique) do names[#names+1] = 'unique_' .. tostring(item.sno_id) end
    for _,item in pairs(utils.get_mythic_items()) do names[#names+1] = 'mythic_' .. tostring(item.sno_id) end
    return names
end
function utils.import_filters(elements)
    local filename = path_join('data', 'import', elements.affix_import_name:get())
    local new_affix = read_json(filename)
    if not new_affix then
        console.print('[Alfred] import failed: ' .. filename)
        return false
    end
    local selected = {}
    for _,affix in pairs(new_affix) do selected[affix] = true end
    utils.export_filters(elements, true)   -- backup first
    for _, name in ipairs(filter_checkbox_names()) do
        if elements[name] then elements[name]:set(selected[name] == true) end
    end
    utils.log('import ' .. filename .. ' done')
    return true
end
function utils.export_filters(elements,is_backup)
    local selected = {}
    for _, name in ipairs(filter_checkbox_names()) do
        if elements[name] and elements[name]:get() then selected[#selected+1] = name end
    end
    local filename = export_name(is_backup and 'alfred-backup-' or 'alfred-')
    if write_file(filename, json.encode(selected)) then utils.log('export ' .. filename .. ' done') end
end
function utils.export_actors()
    local current_time = get_time_since_inject()
    if utils.last_dump_time + 1 >= current_time then return end
    local data = {}
    for _, actor in pairs(actors_manager:get_all_actors()) do
        local position = actor:get_position()
        data[#data+1] = {name = actor:get_skin_name(), x = position:x(), y = position:y(), z = position:z()}
    end
    write_file(export_name('actors-'), json.encode(data))
    utils.last_dump_time = current_time
end
function utils.export_inventory_info()
    local current_time = get_time_since_inject()
    if utils.last_dump_time + 10 >= current_time then return end
    utils.last_dump_time = current_time
    local local_player = get_local_player()
    if not local_player then return end
    local items_info = {}
    for _, item in pairs(list_of(local_player, 'get_inventory_items')) do
        local action, reason, info, item_type = utils.item_decision(item, false)
        local item_info = {action = action == 1 and 'salvage' or action == 2 and 'sell' or 'stash',
            reason = reason, name = info.display, skin = info.skin, id = info.sno, rarity = info.rarity,
            mythic = info.mythic, type = item_type, affix = {}, aspect = {}}
        local affixes = classify.call(item, 'get_affixes')
        for _,affix in pairs(type(affixes) == 'table' and affixes or {}) do
            local affix_id = affix.affix_name_hash
            local entry = {id = affix_id, name = classify.call(affix, 'get_name'), roll = classify.call(affix, 'get_roll'),
                max_roll = classify.call(affix, 'get_roll_max'), min_roll = classify.call(affix, 'get_roll_min')}
            if item_aspect[affix_id] ~= nil then
                local ok, is_max = pcall(utils.is_max_aspect, affix)
                entry.is_max = ok and is_max or false
                item_info.aspect = entry
            else
                item_info.affix[#item_info.affix+1] = entry
            end
        end
        items_info[#items_info+1] = item_info
    end
    write_file(export_name('items-'), json.encode(items_info))
end
function utils.dump_tracker_info(tracker_data, depth)
    if (depth or 0) == 0 and tracker_data.previous then
        console.print('[Alfred] ---------- previous:')
        utils.dump_tracker_info(tracker_data.previous, 1)
        console.print('[Alfred] ---------- current:')
    end
    local keys = {}
    for key, data in pairs(tracker_data) do
        if key ~= 'previous' and type(data) ~= 'table' and type(data) ~= 'function' then keys[#keys+1] = key end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        console.print('[Alfred] ' .. key .. ': ' .. tostring(tracker_data[key]))
    end
end

for _, slot in ipairs(affix_slot_names) do load_affix_slot(slot) end
for _, slot in ipairs(aspect_slot_names) do load_aspect_slot(slot) end
load_unique_items()

return utils
