local Utils = {}

-- SNO IDs for crafting materials that have a 999,999 cap.
-- Multiple SNO IDs per material exist across seasons/patches.
local CRAFTING_CAP = 999999
local CRAFTING_CAP_SNOS = {
    [1852185] = true, [1928427] = true,             -- Obducite
    [442701]  = true, [1868786] = true,             -- Baleful Fragment
    [357929]  = true, [1205842] = true, [1868060] = true, -- Forgotten Soul
}

-- Maps SNO ID → settings key for per-material skip toggles.
-- Add Veiled Crystal and Rawhide SNO IDs once identified via the Debug › Dump Currencies tool.
Utils.MAT_SKIP_KEY = {
    [1852185] = "skip_obducite",       [1928427] = "skip_obducite",
    [442701]  = "skip_baleful",        [1868786] = "skip_baleful",
    [357929]  = "skip_forgotten_soul", [1205842] = "skip_forgotten_soul", [1868060] = "skip_forgotten_soul",
    [442481]  = "skip_veiled_crystal",
    [442216]  = "skip_rawhide",
}

local _craft_cache     = {}
local _craft_cache_at  = 0

local function _refresh_craft_cache()
    local now = os.time()
    if now - _craft_cache_at < 2 then return end
    _craft_cache_at = now
    _craft_cache    = {}
    local player = get_local_player()
    if not player then return end
    local function tally(items)
        if type(items) ~= "table" then return end
        for _, item in ipairs(items) do
            local ok_s, sno = pcall(function() return item:get_sno_id() end)
            if ok_s and CRAFTING_CAP_SNOS[sno] then
                local ok_c, cnt = pcall(function() return item:get_stack_count() end)
                local n = (ok_c and cnt and cnt > 0) and cnt or 1
                _craft_cache[sno] = (_craft_cache[sno] or 0) + n
            end
        end
    end
    pcall(function() tally(player:get_inventory_items()) end)
    pcall(function() tally(player:get_consumable_items()) end)
end

-- Returns true when the player already holds >= 999,999 of a capped
-- crafting material (Obducite, Baleful Fragment, Forgotten Soul).
-- Result is cached for 2 s to avoid scanning inventory every frame.
function Utils.is_crafting_mat_capped(sno_id)
    if not CRAFTING_CAP_SNOS[sno_id] then return false end
    _refresh_craft_cache()
    return (_craft_cache[sno_id] or 0) >= CRAFTING_CAP
end

function Utils.distance_to(obj)
    return get_player_position():dist_to_ignore_z(obj:get_position())
end

function Utils.get_greater_affix_count(display_name)
    if not display_name then return 0 end
    local count = 0
    for _ in display_name:gmatch("GreaterAffix") do count = count + 1 end
    return count
end

function Utils.get_ga_count(info)
    local ok, count = pcall(function() return info:get_attribute(attributes.ITEM_GREATER_AFFIX_COUNT) end)
    if ok and count then return math.floor(count) end
    local ok2, dn = pcall(function() return info:get_display_name() end)
    return ok2 and Utils.get_greater_affix_count(dn) or 0
end

function Utils.is_lowest_stack_below(inventory, item_id, max_stack, looted_stack)
    if not inventory then return true end
    local lowest = max_stack
    for _, item in pairs(inventory) do
        if item:get_sno_id() == item_id then
            local s = item:get_stack_count()
            if s < lowest then lowest = s end
        end
    end
    return (lowest + looted_stack) <= max_stack
end

function Utils.is_inventory_full()
    return get_local_player():get_item_count() >= 33
end

function Utils.is_consumable_inventory_full()
    return get_local_player():get_consumable_count() >= 33
end

function Utils.is_sigil_inventory_full()
    return #get_local_player():get_dungeon_key_items() >= 33
end

function Utils.is_socketable_inventory_full()
    return #get_local_player():get_socketable_items() >= 33
end

function Utils.is_talisman_inventory_full()
    return #get_local_player():get_talisman_items() >= 33
end

function Utils.any_inventory_full()
    return Utils.is_inventory_full()
        or Utils.is_consumable_inventory_full()
        or Utils.is_sigil_inventory_full()
        or Utils.is_socketable_inventory_full()
        or Utils.is_talisman_inventory_full()
end

function Utils.player_in_zone(name)
    return get_current_world():get_current_zone_name() == name
end

return Utils
