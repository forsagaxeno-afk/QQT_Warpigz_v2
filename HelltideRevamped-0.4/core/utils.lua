local utils    = {}
local enums = require "data.enums"
local tracker = require "core.tracker"

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

-- C1 canonical Alfred reading (suite contract, copied into each plugin and
-- never shared across plugins). A `teleport` flag latched after a finished
-- or failed trip is not live work.
local ALFRED_UNKNOWN_GRACE = 10   -- unreadable status counts as busy this long
-- The unknown-since stamp lives in tracker so tasks/alfred.lua and this
-- reader share ONE grace (two sequential 10 s holds would be 20 s).

function utils.get_alfred()
    return AlfredTheButlerPlugin or PLUGIN_alfred_the_butler
end

function utils.alfred_live_work(s)
    return s.trigger_tasks == true or s.external_trigger == true or s.pending == true or s.running == true
        or (s.teleport == true and s.teleport_done ~= true and s.teleport_failed ~= true)
end

-- Only these send HR to town. need_trigger alone, restock_count and
-- need_stash_* are advisory; tasks/alfred.lua handles them with the sticky
-- grace after a completed cycle (HLT-1/HLT-2).
function utils.alfred_hard_need(s)
    return s.inventory_full == true or s.need_repair == true
end

-- Readable status table; {enabled=false} when Alfred is absent; nil while an
-- unreadable status (missing get_status, throw, non-table, non-boolean
-- `enabled`) is inside ALFRED_UNKNOWN_GRACE (callers hold); after the grace
-- {enabled=false, unavailable=true}, logged once, so no hold is unbounded.
function utils.read_alfred_status()
    local a = utils.get_alfred()
    if not a then
        tracker.alfred_unknown_since, tracker.alfred_unknown_logged = nil, nil
        return {enabled = false}
    end
    local ok, status = false, nil
    if type(a.get_status) == 'function' then ok, status = pcall(a.get_status) end
    if ok and type(status) == 'table' and type(status.enabled) == 'boolean' then
        tracker.alfred_unknown_since, tracker.alfred_unknown_logged = nil, nil
        return status
    end
    local now = get_time_since_inject()
    tracker.alfred_unknown_since = tracker.alfred_unknown_since or now
    if now - tracker.alfred_unknown_since < ALFRED_UNKNOWN_GRACE then return nil end
    if not tracker.alfred_unknown_logged then
        tracker.alfred_unknown_logged = true
        console.print(string.format("[HelltideRevamped] Alfred status unreadable for %ds; treating Alfred as unavailable",
            ALFRED_UNKNOWN_GRACE))
    end
    return {enabled = false, unavailable = true}
end

function utils.alfred_available()
    if not utils.get_alfred() then return false end
    local status = utils.read_alfred_status()
    if not status then return nil end
    return status.enabled
end

-- True only for a hard Alfred need. The local item count is a fallback for a
-- provider that does not publish inventory_full; when it does, its view wins
-- (a trip for items its rules keep would bounce town<->portal forever).
function utils.is_inventory_full()
    if utils.get_alfred() then
        local status = utils.read_alfred_status()
        if not status then return nil end
        if status.enabled then
            if utils.alfred_hard_need(status) then return true end
            if type(status.inventory_full) == 'boolean' then return false end
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