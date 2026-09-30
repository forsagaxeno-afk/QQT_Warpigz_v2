local json = require 'core.json'
local tracker = require 'core.tracker'
local town = require 'core.town'

local utils    = {
    settings = {},
    last_dump_time = 0,
}

function utils.get_town()
    return town.get(utils.settings.town_choice)
end
function utils.is_in_town()
    return get_current_world():get_current_zone_name() == utils.get_town().zone_name
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
local item_unique_charm = {}
local item_set_charm = {}
-- npc_enum / npc_loc_enum / npc_via_loc_enum / walls are sourced from the
-- active town config (see core/town.lua). __index delegates per-key reads to
-- whichever town is selected so existing call sites like
-- `utils.npc_enum['GAMBLER']` keep working without changes.
utils.npc_enum = setmetatable({}, {
    __index = function(_, key) return utils.get_town().npc_enum[key] end,
})
utils.npc_loc_enum = setmetatable({}, {
    __index = function(_, key) return utils.get_town().npc_loc_enum[key] end,
})
utils.npc_via_loc_enum = setmetatable({}, {
    __index = function(_, key) return utils.get_town().npc_via_loc_enum[key] end,
})
-- Subzones where a wall forces routing through a middleman waypoinhow to checkt.
-- Player must pass through `via` to enter or leave the area within `radius` of `inside_anchor`.
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
local function talisman_should_act(item, requested_action)
    if not item then return false end
    local s = utils.settings

    if s.loot_filter_mode then
        local ok, filtered = pcall(function() return item:is_filtered_by_loot_filter() end)
        if ok then
            if not filtered then return false end
            local item_type = utils.get_item_type(item)
            if item_type == 'talisman_seal' then
                return s.talisman_seal_action == requested_action
            elseif item_type == 'talisman_charm' then
                return s.talisman_charm_action == requested_action
            end
            return false
        end
    end

    local item_type_early = utils.get_item_type(item)
    local lf_active = (item_type_early == 'talisman_seal' and s.loot_filter_seal)
                   or (item_type_early == 'talisman_charm' and s.loot_filter_charm)
    if lf_active then
        local ok, filtered = pcall(function() return item:is_filtered_by_loot_filter() end)
        if ok then
            if not filtered then return false end
            if item_type_early == 'talisman_seal' then
                return s.talisman_seal_action == requested_action
            elseif item_type_early == 'talisman_charm' then
                return s.talisman_charm_action == requested_action
            end
            return false
        end
    end

    local item_type = utils.get_item_type(item)
    local ok, r = pcall(function() return item:get_rarity() end)
    local rarity = ok and r or 0

    local action, affix_filter, affix_count, affix_selected
    if item_type == 'talisman_seal' then
        -- Mythic seal protection (filter optional)
        if utils.is_mythic_seal(item) then
            if s.talisman_seal_mythic_filter then
                if utils.is_correct_mythic_seal(item) then return false end
            else
                return false
            end
        end
        action         = s.talisman_seal_action
        affix_filter   = s.talisman_seal_affix_filter
        affix_count    = s.talisman_seal_affix_count
        affix_selected = s.talisman_seal_affix
    elseif item_type == 'talisman_charm' then
        -- Unique charm (rarity 6): keep always, or keep if in filter list
        if rarity == 6 then
            if s.talisman_charm_unique_filter then
                if utils.is_correct_unique_charm(item) then return false end
            else
                return false
            end
        end
        -- Set charm (rarity 7): set filter gates which ones to keep; filter off = default action
        if rarity == 7 then
            if s.talisman_charm_set_filter then
                if not utils.is_correct_set_charm(item) then
                    return s.talisman_charm_action == requested_action
                end
                -- in set list: affix filter applies below (AND logic — fall through)
            end
            -- set filter off: fall through to default action
        end
        action         = s.talisman_charm_action
        affix_filter   = s.talisman_charm_affix_filter
        affix_count    = s.talisman_charm_affix_count
        affix_selected = s.talisman_charm_affix
    else
        return false
    end
    -- Affix filter: keep if matched >= count
    if affix_filter and affix_selected then
        local matched = 0
        for _, affix in pairs(item:get_affixes()) do
            if affix_selected[affix.affix_name_hash] then matched = matched + 1 end
        end
        if matched >= (affix_count or 1) then return false end
    end
    return action == requested_action
end

function utils.should_salvage_talisman(item)
    return talisman_should_act(item, utils.item_enum['SALVAGE'])
end

function utils.should_sell_talisman(item)
    return talisman_should_act(item, utils.item_enum['SELL'])
end

utils.mythics = {
    [1901484] = "Tyrael's Might",
    [223271] = 'The Grandfather',
    [241930] = "Andariel's Visage",
    [359165] = 'Ahavarion, Spear of Lycander',
    [221017] = 'Doombringer',
    [609820] = 'Harlequin Crest',
    [1275935] = 'Melted Heart of Selig',
    [1306338] = 'Ring of Starless Skies',
    [2059803] = 'Shroud of False Death',
    [1982241] = 'Nesekem, the Herald',
    [2059799] = 'Heir of Perdition',
    [2059813] = 'Shattered Vow',
    [2603733] = 'El Druin, Sword of Justice',
}

utils.mythic_seals = {
    [2609259] = 'Mythic Unique Horadric Seal',
    [2622265] = 'Seal of the Severed Finger',
    [2622267] = 'Seal of the Golden Epiphany',
    [2622269] = 'Seal of the Diamond Mind',
}

local function get_plugin_root_path()
    local plugin_root = string.gmatch(package.path, '.*?\\?')()
    plugin_root = plugin_root:gsub('?','')
    return plugin_root
end
local function get_export_filename(is_backup)
    local filename = get_plugin_root_path()
    filename = filename .. 'data\\export'
    if is_backup then
        filename = filename .. '\\alfred-backup-'
    else
        filename = filename .. '\\alfred-'
    end
    filename = filename .. os.time(os.date('!*t'))
    filename = filename .. '.json'
    return filename
end
local function get_import_full_filename(name)
    local filename = get_plugin_root_path()
    filename = filename .. 'data\\import\\'
    filename = filename .. name
    return filename
end

local function normalize_class(c)
    return (not c or #c == 0) and {'all'} or c
end

local function load_affix_slot(slot_name)
    local filename = get_plugin_root_path() .. 'data\\affix\\affix_' .. slot_name .. '.json'
    local file = io.open(filename, 'r')
    if not file then utils.log('error opening file ' .. filename); return end
    local raw = file:read('*all')
    io.close(file)
    raw = raw:match('[%[%{].*') or raw
    local data = json.decode(raw)
    if not data then return end
    local group = { name = slot_name, data = {} }
    for _, affix in pairs(data) do
        affix.sno_id      = affix.sno_id or affix.id
        affix.class       = normalize_class(affix.class)
        affix.description = affix.description or affix.name or ''
        group.data[#group.data+1] = affix
    end
    item_affix[#item_affix+1] = group
end

local function load_aspect_slot(slot_name)
    local filename = get_plugin_root_path() .. 'data\\affix\\aspect_' .. slot_name .. '.json'
    local file = io.open(filename, 'r')
    if not file then utils.log('error opening file ' .. filename); return end
    local raw = file:read('*all')
    io.close(file)
    raw = raw:match('[%[%{].*') or raw
    local data = json.decode(raw)
    if not data then return end
    for _, affix in pairs(data) do
        affix.sno_id      = affix.sno_id or affix.id
        affix.class       = normalize_class(affix.class)
        affix.description = affix.description or affix.name or ''
        if not item_aspect[affix.sno_id] then
            item_aspect[affix.sno_id] = affix
        end
    end
end
local function load_unique_file(filename)
    local file, err = io.open(filename,'r')
    if not file then
        utils.log('error opening file' .. filename)
        return
    end
    local raw = file:read('*all')
    io.close(file)
    raw = raw:match('[%[%{].*') or raw
    local data = json.decode(raw)
    for _,item in pairs(data) do
        local classes = item.playerClassNames or item.class or {}
        if #classes == 0 then classes = { 'all' } end
        local entry = {
            sno_id      = item.id or item.sno_id,
            name        = item.name,
            description = item.name,
            item_type   = item.itemTypeName or item.item_type or '',
            class       = classes,
        }
        local t = entry.item_type
        if t == 'Charm' then
            item_unique_charm[#item_unique_charm+1] = entry
        else
            item_unique[#item_unique+1] = entry
        end
    end
end
local function load_set_charm_file(filename)
    local file = io.open(filename, 'r')
    if not file then utils.log('error opening file' .. filename); return end
    local raw = file:read('*all')
    io.close(file)
    raw = raw:match('[%[%{].*') or raw
    local data = json.decode(raw)
    for _, item in pairs(data) do
        local classes = item.class or {}
        if #classes == 0 then classes = { 'all' } end
        item_set_charm[#item_set_charm+1] = {
            sno_id      = item.sno_id,
            name        = item.name,
            description = item.name,
            item_type   = 'Charm',
            set         = item.set or '',
            class       = classes,
        }
    end
end
local function get_uniques()
    local root = get_plugin_root_path()
    load_unique_file(root .. 'data\\affix\\unique-item.json')
    load_unique_file(root .. 'data\\affix\\unique-charm.json')
    load_set_charm_file(root .. 'data\\affix\\set-charm.json')
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
function utils.get_unique_charm_items()
    return item_unique_charm
end
function utils.get_set_charm_items()
    return item_set_charm
end
function utils.get_mythic_seal_items()
    local items = {}
    for sno_id, name in pairs(utils.mythic_seals) do
        items[#items+1] = { sno_id = sno_id, name = name, description = name, class = {'all'}, item_type = 'Seal' }
    end
    return items
end
function utils.get_mythic_items()
    local item_mythics = {}
    for sno_id,name in pairs(utils.mythics) do
        item_mythics[#item_mythics+1] = {
            name = name,
            description = name,
            sno_id = sno_id,
            class = {"all"}
        }
    end
    return item_mythics
end
function utils.log(msg)
    -- console.print(utils.settings.plugin_label .. ': ' .. tostring(msg))
end

function utils.get_character_class()
    local local_player = get_local_player();
    if not local_player then return 'default' end
    local class_id = local_player:get_character_class_id()
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
    if character_classes[class_id] then
        return character_classes[class_id]
    else
        return 'default'
    end
end

function utils.player_in_zone(zname)
    return get_current_world():get_current_zone_name() == zname
end
function utils.reset_all_task()
    local previous = {}
    for key,data in pairs(tracker) do
        if key ~= 'previous' then
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
    for _, actor in pairs(get_actors_list()) do
        if actor:get_skin_name() == name then return actor end
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
    local count = 0
    for _ in display_name:gmatch('GreaterAffix') do
       count = count + 1
    end
    return count
end
function utils.is_max_aspect(affix)
    local affix_id = affix.affix_name_hash
    if item_aspect[affix_id] ~= nil then
        -- if ascending
        if affix:get_roll_max() > affix:get_roll_min() then
            -- simple direct comparison
            if affix:get_roll() == affix:get_roll_max() then return true end

            -- dealing with int value of max_roll
            if affix:get_roll_max() == math.floor(affix:get_roll_max()) then
                -- 0.5 for rounding instead of floor
                return math.floor(affix:get_roll() + 0.5) >= affix:get_roll_max()
            end

            -- dealing with decimals up to 2 places
            return math.floor((affix:get_roll() * 100) + 0.5) >= affix:get_roll_max() * 100
        else
            -- simple direct comparison
            if affix:get_roll() == affix:get_roll_max() then return true end

            -- dealing with int value of min_roll
            if affix:get_roll_max() == math.floor(affix:get_roll_max()) then
                -- 0.5 for rounding instead of floor
                return math.floor(affix:get_roll() + 0.5) <= affix:get_roll_max()
            end
            -- dealing with decimals up to 2 places
            return math.floor((affix:get_roll() * 100) + 0.5) <= affix:get_roll_max() * 100
        end

    end
    return false
end
function utils.is_correct_unique(item)
    local item_id = item:get_sno_id()
    return utils.settings.ancestral_unique[item_id] ~= nil
end
function utils.is_correct_mythic(item)
    local item_id = item:get_sno_id()
    return utils.settings.ancestral_mythic[item_id] ~= nil
end
function utils.is_correct_unique_charm(item)
    local item_id = item:get_sno_id()
    return utils.settings.talisman_charm_unique[item_id] ~= nil
end
function utils.is_correct_set_charm(item)
    local item_id = item:get_sno_id()
    return utils.settings.talisman_charm_set[item_id] ~= nil
end
function utils.is_mythic_seal(item)
    return utils.mythic_seals[item:get_sno_id()] ~= nil
end
function utils.is_correct_mythic_seal(item)
    local item_id = item:get_sno_id()
    return utils.settings.talisman_seal_mythic[item_id] ~= nil
end
function utils.is_correct_affix(item_type, affix)
    if not utils.settings.ancestral_affix then return false end
    local affix_id = affix.affix_name_hash
    local t = utils.settings.ancestral_affix[item_type]
    return t and t[affix_id] or false
end
function utils.is_correct_aspect(affix)
    local affix_id = affix.affix_name_hash
    return utils.settings.ancestral_aspect[affix_id] ~= nil
end
local _armor_slots = { 'helm', 'chest', 'gloves', 'pants', 'boots', 'amulet', 'ring' }
local _offhand_pats = { 'focus', 'book', 'totem', 'shield' }
local _weapon_2h_pats = { '2h', 'quarterstaff', 'glaive', 'polearm', 'bow', 'crossbow', 'staff' }
function utils.get_item_type(item)
    local name = string.lower(item:get_name())
    if name:match('cache') then return 'cache' end
    if name:match('tempering') then return 'tempering' end
    if name:match('talisman') then
        if name:match('seal') then return 'talisman_seal' end
        if name:match('charm') then return 'talisman_charm' end
    end
    for _, slot in pairs(_armor_slots) do
        if name:match(slot) then return slot end
    end
    for _, pat in pairs(_offhand_pats) do
        if name:match(pat) then return 'offhand' end
    end
    for _, pat in pairs(_weapon_2h_pats) do
        if name:match(pat) then return 'weapon_2h' end
    end
    if name:match('1h') or name:match('wand') or name:match('flail') or name:match('dagger') or
       name:match('axe') or name:match('sword') or name:match('mace') or name:match('blade') or
       name:match('scythe') or name:match('weapon') then
        return 'weapon_1h'
    end
    return 'unknown'
end
function utils.is_salvage_or_sell(item,action)
    local is_salvage_or_sell, _, _ = utils.is_salvage_or_sell_with_data(item, action)
    return is_salvage_or_sell
end
function utils.is_salvage_or_sell_with_data(item,action)
    if utils.settings.skip_favorite and item:is_locked() then return false, 0, false end

    local item_id = item:get_sno_id()

    local item_type = utils.get_item_type(item)
    if item_type == 'cache' then return false, 0, false end
    if item_type == 'unknown' then return false, 0, false end
    if item_type == 'tempering' then return false, 0, false end

    local is_unique  = item:get_rarity() == 6
    local is_mythic  = utils.mythics[item_id] ~= nil
    local is_ancestral = item:is_ancestral()
    local ga_count     = is_ancestral and utils.get_greater_affix_count(item:get_display_name()) or 0

    -- locked: never act
    if item:is_locked() then return false, 0, false end

    -- loot filter mode: in-game filter is the sole rule
    if utils.settings.loot_filter_mode then
        local ok, filtered = pcall(function() return item:is_filtered_by_loot_filter() end)
        if ok and filtered then return action == utils.item_enum['SALVAGE'], 0, false end
        return false, 0, false
    end

    -- loot filter equipment mode: in-game filter decides equipment, Alfred handles the rest
    if utils.settings.loot_filter_equipment then
        local ok, filtered = pcall(function() return item:is_filtered_by_loot_filter() end)
        if ok then return filtered, 0, false end
    end

    -- non-ancestral path
    if not is_ancestral then
        if item:is_junk() then
            return utils.settings.item_junk == action, 0, false
        elseif is_unique then
            return utils.settings.item_unique == action, 0, false
        else
            return utils.settings.item_legendary_or_lower == action, 0, false
        end
    end

    -- ancestral path
    if item:is_junk() then
        return utils.settings.ancestral_item_junk == action, 0, false
    end

    -- mythic
    if is_mythic then
        if utils.settings.ancestral_mythic_ga_count > 0 and ga_count >= utils.settings.ancestral_mythic_ga_count then
            return false, 0, false  -- GA override: keep
        end
        if utils.settings.ancestral_unique_filter and utils.is_correct_mythic(item) then
            return false, 0, false  -- name filter: keep
        end
        return utils.settings.ancestral_item_mythic == action, 0, false
    end

    -- unique
    if is_unique then
        if utils.settings.ancestral_unique_ga_count > 0 and ga_count >= utils.settings.ancestral_unique_ga_count then
            return false, 0, false  -- GA override: keep
        end
        if utils.settings.ancestral_unique_filter and utils.is_correct_unique(item) then
            return false, 0, false  -- name filter: keep
        end
        return utils.settings.ancestral_item_unique == action, 0, false
    end

    -- non-unique, non-mythic (rare/magic/legendary)
    if utils.settings.ancestral_ga_count > 0 and ga_count >= utils.settings.ancestral_ga_count then
        if utils.settings.ancestral_filter and utils.settings.ancestral_affix then
            local matched = 0
            for _, affix in pairs(item:get_affixes()) do
                if utils.is_correct_affix(item_type, affix) then matched = matched + 1 end
            end
            if matched >= utils.settings.ancestral_affix_count then
                return false, matched, false
            end
        else
            return false, 0, false
        end
    end
    return utils.settings.ancestral_item_legendary == action, 0, false
end
function utils.is_mounted()
    local local_player = get_local_player()
    return local_player:get_attribute(attributes.CURRENT_MOUNT) < 0
end
local update_debounce_time = get_time_since_inject()
local update_debounce_timeout = 0.5
function utils.update_tracker_count(local_player)
    if update_debounce_time + update_debounce_timeout > get_time_since_inject() then return end
    update_debounce_time = get_time_since_inject()


    local items = local_player:get_inventory_items()
    local cached_inventory = {}
    local salvage_counter = 0
    local sell_counter = 0
    local stash_counter = 0
    for _, item in pairs(items) do
        if item then
            if utils.settings.skip_favorite and item:is_locked() then goto continue end
            local is_salvage, affix_count, is_max_aspect = utils.is_salvage_or_sell_with_data(item,utils.item_enum['SALVAGE'])
            local is_sell = utils.is_salvage_or_sell(item,utils.item_enum['SELL'])
            local is_stash = not is_salvage and not is_sell

            if is_stash then
                local item_type = utils.get_item_type(item)
                if (item_type == 'cache' and utils.settings.skip_cache) then
                    is_stash = false
                end
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
                affix_count = affix_count,
                is_max_aspect = is_max_aspect,
                item = item
            }
        else
            utils.log('no item??')
        end
        ::continue::
    end
    local salvage_talisman_counter = 0
    local stash_talisman_counter = 0
    for _, item in pairs(local_player:get_talisman_items()) do
        if utils.should_sell_talisman(item) then
            sell_counter = sell_counter + 1
        elseif utils.should_salvage_talisman(item) then
            salvage_talisman_counter = salvage_talisman_counter + 1
        else
            stash_talisman_counter = stash_talisman_counter + 1
        end
    end
    tracker.cached_inventory = cached_inventory
    tracker.inventory_count = local_player:get_item_count()
    tracker.salvage_count = salvage_counter
    tracker.salvage_talisman_count = salvage_talisman_counter
    tracker.stash_talisman_count = stash_talisman_counter
    tracker.sell_count = sell_counter
    tracker.stash_count = stash_counter
    tracker.inventory_full = tracker.inventory_count >= utils.settings.max_inventory

    local need_repair = false
    local items = local_player:get_equipped_items()
    for _, item in pairs(items) do
        if item:get_durability() <= 10 then
            need_repair = true
        end
    end
    tracker.need_repair = need_repair
    tracker.need_stash_socketables = utils.settings.stash_socketables == utils.stash_extra_enum['FULL'] and #get_local_player():get_socketable_items() >= utils.settings.max_inventory
    tracker.need_stash_consumables = utils.settings.stash_consumables == utils.stash_extra_enum['FULL'] and #get_local_player():get_consumable_items() >= utils.settings.max_inventory
    tracker.need_stash_keys        = utils.settings.stash_keys        == utils.stash_extra_enum['FULL'] and #get_local_player():get_dungeon_key_items() >= utils.settings.max_inventory
    tracker.talisman_inventory_full    = #get_local_player():get_talisman_items() >= utils.settings.max_inventory

    tracker.need_trigger = tracker.inventory_full or
        tracker.need_repair or
        tracker.need_stash_socketables or
        tracker.need_stash_consumables or
        tracker.need_stash_keys or
        tracker.talisman_inventory_full

    tracker.name = utils.settings.plugin_label
    tracker.version = utils.settings.plugin_version
end
function utils.import_filters(elements)
    local filename = get_import_full_filename(elements.affix_import_name:get())
    local file, err = io.open(filename,'r')
    if not file then
        utils.log('error opening file' .. filename)
        return
    end
    io.input(file)
    local data = io.read("*a")  -- <-- Added "*a" parameter
    if pcall(function () return json.decode(data) end) then
        local new_affix = json.decode(data)
        local new_settings = {}
        for _,affix in pairs(new_affix) do
            new_settings[affix] = true
        end
        -- make a backup
        utils.export_filters(elements,true)

        -- clear and set new affix
        for _,affix_type in pairs(item_affix) do
            for _,affix in pairs(affix_type.data) do
                local checkbox_name = tostring(affix_type.name) .. '_affix_' .. tostring(affix.sno_id)
                if new_settings[checkbox_name] then
                    elements[checkbox_name]:set(true)
                else
                    elements[checkbox_name]:set(false)
                end
            end
        end
        for _,aspect in pairs(item_aspect) do
            local checkbox_name = 'aspect_' .. tostring(aspect.sno_id)
            if new_settings[checkbox_name] then
                elements[checkbox_name]:set(true)
            else
                elements[checkbox_name]:set(false)
            end
        end
        for _,item in pairs(item_unique) do
            local checkbox_name = 'unique_' .. tostring(item.sno_id)
            if new_settings[checkbox_name] then
                elements[checkbox_name]:set(true)
            else
                elements[checkbox_name]:set(false)
            end
        end
        for _,item in pairs(utils.get_mythic_items()) do
            local checkbox_name = 'mythic_' .. tostring(item.sno_id)
            if new_settings[checkbox_name] then
                elements[checkbox_name]:set(true)
            else
                elements[checkbox_name]:set(false)
            end
        end
    else
        utils.log('error in import file' .. filename)
    end
    io.close(file)
    utils.log('import ' .. filename .. ' done')
end
function utils.export_filters(elements,is_backup)
    local selected = {}
    for _,affix_type in pairs(item_affix) do
        for _,affix in pairs(affix_type.data) do
            local checkbox_name = tostring(affix_type.name) .. '_affix_' .. tostring(affix.sno_id)
            if elements[checkbox_name]:get() then
                selected[#selected+1] = checkbox_name
            end
        end
    end
    for _,aspect in pairs(item_aspect) do
        local checkbox_name = 'aspect_' .. tostring(aspect.sno_id)
        if elements[checkbox_name]:get() then
            selected[#selected+1] = checkbox_name
        end
    end
    for _,item in pairs(item_unique) do
        local checkbox_name = 'unique_' .. tostring(item.sno_id)
        if elements[checkbox_name]:get() then
            selected[#selected+1] = checkbox_name
        end
    end
    for _,item in pairs(utils.get_mythic_items()) do
        local checkbox_name = 'mythic_' .. tostring(item.sno_id)
        if elements[checkbox_name]:get() then
            selected[#selected+1] = checkbox_name
        end
    end
    local filename = get_export_filename(is_backup)
    local file, err = io.open(filename,'w')
    if not file then
        utils.log('error opening file' .. filename)
    end
    io.output(file)
    io.write(json.encode(selected))
    io.close(file)

    utils.log('export ' .. filename .. ' done')
end
function utils.export_actors()
    -- debounce second
    local current_time = get_time_since_inject()
    if utils.last_dump_time + 1 >= current_time then return end

    local actors = actors_manager:get_all_actors()
    local data = {}
    for _, actor in pairs(actors) do
        local name = actor:get_skin_name()
        local position = actor:get_position()
        data[#data+1] = {
            ['name'] = name,
            ['x'] = position:x(),
            ['y'] = position:y(),
            ['z'] = position:z()
        }
    end
    local filename = get_plugin_root_path()
    filename = filename .. 'data\\export'
    filename = filename .. '\\actors-'
    filename = filename .. os.time(os.date('!*t'))
    filename = filename .. '.json'
    local file, err = io.open(filename,'w')
    if not file then
        utils.log('error opening file' .. filename)
    end
    io.output(file)
    io.write(json.encode(data))
    io.close(file)
    utils.last_dump_time = current_time
end
function utils.export_inventory_info()
    -- debounce 10 seconds
    local current_time = get_time_since_inject()
    if utils.last_dump_time + 10 >= current_time then return end
    utils.last_dump_time = current_time
    local local_player = get_local_player()
    if not local_player then return end
    local items = local_player:get_inventory_items()
    -- local items = local_player:get_equipped_items()
    local items_info = {}
    for _, item in pairs(items) do
        local item_info = {}
        if item then
            local is_salvage = utils.is_salvage_or_sell(item,utils.item_enum['SALVAGE'])
            local is_sell = utils.is_salvage_or_sell(item,utils.item_enum['SELL'])
            item_info['action'] = 'keep'
            if is_salvage then item_info['action'] = 'salvage'
            elseif is_sell then item_info['action'] = 'sell'
            else item_info['action'] = 'stash' end

            item_info['name'] = item:get_display_name()
            item_info['id'] = item:get_sno_id()
            item_info['type'] = utils.get_item_type(item)
            -- item_info['durability'] = item:get_durability()
            item_info['affix'] = {}
            item_info['aspect'] = {}
            for _,affix in pairs(item:get_affixes()) do
                local affix_id = affix.affix_name_hash
                if item_aspect[affix_id] ~= nil then
                    item_info['aspect']['id'] = affix_id
                    item_info['aspect']['name'] = affix:get_name()
                    item_info['aspect']['roll'] = affix:get_roll()
                    item_info['aspect']['max_roll'] = affix:get_roll_max()
                    item_info['aspect']['min_roll'] = affix:get_roll_min()
                    item_info['aspect']['is_max'] = utils.is_max_aspect(affix)
                else
                    item_info['affix'][#item_info['affix']+1] = {
                        ['id'] = affix_id,
                        ['name'] = affix:get_name(),
                        ['roll'] = affix:get_roll(),
                        ['max_roll'] = affix:get_roll_max(),
                        ['min_roll'] = affix:get_roll_min(),
                    }
                end
            end
            -- for key,attr in pairs(attributes) do
            --     item_info['attributes'][key] = item:get_attribute(attr)
            -- end
        end
        items_info[#items_info+1] = item_info
    end
    local filename = get_plugin_root_path()
    filename = filename .. 'data\\export'
    filename = filename .. '\\items-'
    filename = filename .. os.time(os.date('!*t'))
    filename = filename .. '.json'
    local file, err = io.open(filename,'w')
    if not file then
        utils.log('error opening file' .. filename)
    end
    io.output(file)
    io.write(json.encode(items_info))
    io.close(file)
end
function utils.dump_tracker_info(tracker_data)
    if tracker_data.previous then
        utils.log('----------')
        utils.log('previous:')
        utils.dump_tracker_info(tracker_data.previous)
        utils.log('----------')
        utils.log('current:')
    end
    for key,data in pairs(tracker_data) do
        if key ~= 'previous' and key ~= 'cached_inventory' then
            utils.log(key .. ':' .. tostring(data))
        end
    end
end

for _, slot in ipairs(affix_slot_names) do load_affix_slot(slot) end
for _, slot in ipairs(aspect_slot_names) do load_aspect_slot(slot) end
get_uniques()

return utils
