local utils    = {}
local enums = require "data.enums"

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

function utils.check_z_distance(target, distance)
    local player_pos = get_player_position()
    local target_pos

    if target.get_position then
        target_pos = target:get_position()
    elseif target.x then
        target_pos = target
    end

    return math.abs(player_pos:z() - target_pos:z()) <= distance
end

---Returns wether the player is in the zone name specified
---@param zname string
function utils.player_in_zone(zname)
    local world = get_current_world()
    return world ~= nil and world:get_current_zone_name() == zname
end

function utils.player_in_region(rname)
    local world = get_current_world()
    local zone = world and world:get_current_zone_name()
    return type(zone) == "string" and zone:sub(1, #rname) == rname
end

function utils.loot_on_floor()
    return loot_manager.any_item_around(get_player_position(), 30, true, true)
end

function utils.get_consumable_info(item)
    if not item then
        console.print("Error: Item is nil")
        return nil
    end
    local info = {}
    -- Helper function to safely get item properties
    local function safe_get(func, default)
        local success, result = pcall(func)
        return success and result or default
    end
    -- Get the item properties
    info.name = safe_get(function() return item:get_name() end, "Unknown")
    return info
end

function utils.alfred_available()
    local alfred = AlfredTheButlerPlugin or PLUGIN_alfred_the_butler
    if not alfred then return false end
    if type(alfred.get_status) ~= 'function' then return nil end
    local ok, status = pcall(alfred.get_status)
    if not ok or type(status) ~= 'table' or type(status.enabled) ~= 'boolean' then return nil end
    return status.enabled
end

function utils.is_inventory_full()
    if AlfredTheButlerPlugin then
        if type(AlfredTheButlerPlugin.get_status) ~= 'function' then return nil end
        local ok, status = pcall(AlfredTheButlerPlugin.get_status)
        if not ok or type(status) ~= 'table' or type(status.enabled) ~= 'boolean' then return nil end
        if status.enabled and type(status.need_trigger) ~= 'boolean' then return nil end
        if (status.enabled and status.need_trigger) then
            return true
        end
    elseif PLUGIN_alfred_the_butler then
        if type(PLUGIN_alfred_the_butler.get_status) ~= 'function' then return nil end
        local ok, status = pcall(PLUGIN_alfred_the_butler.get_status)
        if not ok or type(status) ~= 'table' or type(status.enabled) ~= 'boolean' then return nil end
        if status.restock_count ~= nil and type(status.restock_count) ~= 'number' then return nil end
        if status.enabled and (
            status.inventory_full or
            (status.restock_count or 0) > 0 or
            status.need_repair or
            status.teleport
        ) then
            return true
        end
    end
    local player = get_local_player()
    return player ~= nil and player:get_item_count() >= 33
end

local _iih_result = false
local _iih_time   = -math.huge
local _iih_player = nil
local IIH_TTL     = 0.25  -- re-check buffs at most 4x per second
function utils.is_in_helltide()
    local now = get_time_since_inject()
    local player = get_local_player()
    if not player then
        _iih_player, _iih_result, _iih_time = nil, false, -math.huge
        return false
    end
    if player == _iih_player and now - _iih_time < IIH_TTL then return _iih_result end
    _iih_player = player
    _iih_time = now
    local buffs = player:get_buffs() or {}
    for _, buff in ipairs(buffs) do
        if buff.name_hash == 1066539 then
            _iih_result = true
            return true
        end
    end
    _iih_result = false
    return false
end

function utils.is_teleporting()
    local buffs = get_local_player():get_buffs()
    for _, buff in ipairs(buffs) do
        if buff.name_hash == 44010 then -- teleport buff
        return true
        end
    end
    return false
end

function utils.have_whispering_key()
    local inventory = get_local_player():get_consumable_items()
    for _, item in pairs(inventory) do
        local item_info = utils.get_consumable_info(item)
        if item_info then
            if item_info.name == "GamblingCurrency_Key" then
                return true
            end
        end
    end

    return false
end

function utils.check_cinders(chest_name)
    local current_cinders = get_helltide_coin_cinders()
    local cost = enums.chest_types[chest_name]
    if cost and current_cinders >= cost then
        return true
    else
        return false
    end
end

function utils.player_in_town()
    if get_local_player():get_attribute(attributes.PLAYER_IN_TOWN_LEVEL_AREA) == 1 then
        return true
    else
        return false
    end
end

function utils.helltide_active()
    local minute = tonumber(os.date("%M"))
    -- No helltide at this time.
    if minute >= 55 and minute <=59 then
        return false
    else
        return true
    end
end

function utils.do_events()
    local minute = tonumber(os.date("%M"))
    -- Don't do events at this time. Events are bugged and do not end
    if minute >= 45 then
        return false
    else
        return true
    end
end

return utils