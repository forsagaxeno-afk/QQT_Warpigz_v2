local settings = require "core.settings"
local enums    = require "data.enums"
local gui      = require "gui"
local utils    = {}

function utils.get_greater_affix_count(display_name)
    local count = 0
    for _ in display_name:gmatch("GreaterAffix") do
       count = count + 1
    end
    return count
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

---Returns wether the player is in the zone name specified
---@param zname string
function utils.player_in_zone(zname)
    local w = get_current_world()
    return w ~= nil and w:get_current_zone_name() == zname
end

---@return game.object|nil
function utils.get_closest_enemy()
    local elite_only = settings.elites_only
    local player_pos = get_player_position()
    local enemies = target_selector.get_near_target_list(player_pos, 90)
    local closest_elite, closest_normal
    local min_elite_dist, min_normal_dist = math.huge, math.huge

    for _, enemy in pairs(enemies) do
        local dist = player_pos:dist_to(enemy:get_position())
        local is_elite = enemy:is_elite() or enemy:is_champion() or enemy:is_boss()

        if is_elite then
            if dist < min_elite_dist then
                closest_elite = enemy
                min_elite_dist = dist
            end
        elseif not elite_only then
            if dist < min_normal_dist then
                closest_normal = enemy
                min_normal_dist = dist
            end
        end
    end

    return closest_elite or (not elite_only and closest_normal) or nil
end

function utils.get_horde_portal()
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        local name = actor:get_skin_name()
        local distance = utils.distance_to(actor)
        if distance < 100 then
            if name == enums.portal_names.horde_portal then
                return actor
            end
        end
    end
end

function utils.get_horde_gate()
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        local name = actor:get_skin_name()
        local distance = utils.distance_to(actor)
        if distance < 100 then
            if name == enums.portal_names.horde_gate then
                return actor
            end
        end
    end
end

function utils.get_bartuc_pylon()
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        local name = actor:get_skin_name()
        local distance = utils.distance_to(actor)
        if distance < 100 then
            if name == enums.boss_pylons.bartuc and actor:is_interactable() then
                return actor
            end
        end
    end
end

function utils.get_boss_pylon()
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        local name = actor:get_skin_name()
        local distance = utils.distance_to(actor)
        if distance < 100 then
            if name == enums.boss_pylons.default and actor:is_interactable() then
                return actor
            end
        end
    end
end

function utils.get_town_portal()
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        local name = actor:get_skin_name()
        if name == enums.misc.portal then
           return actor
        end
    end
end

function utils.get_obelisk()
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        local name = actor:get_skin_name()
        if name == enums.misc.obelisk then
            return actor
        end
    end
end

function utils.loot_on_floor()
    return loot_manager.any_item_around(get_player_position(), 30, true, true)
end


function utils.get_blacksmith()
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        local name = actor:get_skin_name()
        if name == enums.misc.blacksmith then
            console.print("blacksmith location found: " .. name)
            return actor
        end
    end
    --console.print("No blacksmith found")
    return nil
end

function utils.get_jeweler()
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        local name = actor:get_skin_name()
        if name == enums.misc.jeweler then
            local position = actor:get_position()
            console.print(string.format("Jeweler location found: %s at position: (x: %f, y: %f, z: %f)", name, position:x(), position:y(), position:z()))
            return actor
        end
    end
    --console.print("No jeweler found")
    return nil
end


function table.contains(tbl, item)
    for _, value in ipairs(tbl) do
        if value == item then
            return true
        end
    end
    return false
end

---@param identifier string|number string or number of the aura to check for
---@param count? number stacks of the buff to require (optional)
function utils.player_has_aura(identifier, count)
    local buffs = get_local_player():get_buffs()
    local found = 0

    for _, buff in pairs(buffs) do
        if (type(identifier) == "string" and buff:name() == identifier) or
            (type(identifier) == "number" and buff.name_hash == identifier) then
            found = found + 1
            if not count or found >= count then
                return true
            end
        end
    end

    return false
end

---Returns wether the player is on the quest provided or not
---@param quest_id integer
---@return boolean
function utils.player_on_quest(quest_id)
    local quests = get_quests()
    for _, quest in pairs(quests) do
        if quest:get_id() == quest_id then
            return true
        end
    end

    return false
end

---Finds the optimal path from the player's position to the target position
---and moves the player along the path.
---@param target table The target position {x, y, z}
---@return nil
function utils.navigate_to(target)
    local player_pos = get_player_position()

    -- No plugin in the suite defines a `navigation` global; never index nil.
    local host_navigation = rawget(_G, "navigation")
    if type(host_navigation) ~= "table" or type(host_navigation.find_path) ~= "function" then return end
    local path = host_navigation.find_path(player_pos, target)

    if path then
        local current_index = 1

        local function move_to_next_position()
            if current_index > #path then return end

            local next_position = path[current_index]

            if utils.distance_to(next_position) < 1 then
                current_index = current_index + 1

                move_to_next_position()
            else
                pathfinder.request_move(next_position)
            end
        end

        move_to_next_position()
    end
end

function utils.get_material_chest()
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        local name = actor:get_skin_name()
        if name == "BSK_UniqueOpChest_Materials" then
            return actor
        end
    end
    return nil
end

function utils.get_chest(chest_type)
    if type(chest_type) ~= "string" then return nil end
    local closest, closest_distance = nil, math.huge
    local function scan(actors)
        if type(actors) ~= "table" then return end
        for _, actor in pairs(actors) do
            local ok, name, position = pcall(function() return actor:get_skin_name(), actor:get_position() end)
            if ok and name == chest_type and position then
                local distance = utils.distance_to(position)
                if distance < closest_distance then closest, closest_distance = actor, distance end
            end
        end
    end
    if actors_manager and actors_manager.get_all_actors then scan(actors_manager:get_all_actors()) end
    if loot_manager and loot_manager.get_all_items_chest_sort_by_distance then
        local ok, chests = pcall(loot_manager.get_all_items_chest_sort_by_distance)
        if ok then scan(chests) end
    end
    return closest
end

function utils.get_stash()
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        local name = actor:get_skin_name()
        if name == "Stash" then
            return actor
        end
    end
    return nil
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

function utils.get_aether_actor()
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        local name = actor:get_skin_name()
        if name == "BurningAether" then
            return actor
        end
    end
    return nil
end

-- C1 canonical Alfred reading (suite contract, copied into each plugin; never
-- shared across plugins). A `teleport` flag latched after a finished or failed
-- trip is not live work.
local ALFRED_UNKNOWN_GRACE = 10   -- unreadable status counts as busy this long
local ALFRED_STICKY_GRACE = 30    -- advisory flags cannot re-trigger after a cycle
local alfred_unknown = {since = nil, logged = false}

function utils.get_alfred()
    return AlfredTheButlerPlugin or PLUGIN_alfred_the_butler
end

function utils.alfred_live_work(s)
    return s.trigger_tasks == true or s.external_trigger == true or s.pending == true or s.running == true
        or (s.teleport == true and s.teleport_done ~= true and s.teleport_failed ~= true)
end

function utils.alfred_hard_need(s)
    return s.inventory_full == true or s.need_repair == true
end

-- Readable status table; {enabled=false} when Alfred is absent; nil while an
-- unreadable status (missing get_status, throw, non-table, non-boolean
-- `enabled`) is inside ALFRED_UNKNOWN_GRACE (callers treat nil as busy);
-- after the grace {enabled=false, unavailable=true}, logged once.
function utils.read_alfred_status()
    local a = utils.get_alfred()
    if not a then
        alfred_unknown.since, alfred_unknown.logged = nil, false
        return {enabled = false}
    end
    local ok, status = false, nil
    if type(a.get_status) == 'function' then ok, status = pcall(a.get_status) end
    if ok and type(status) == 'table' and type(status.enabled) == 'boolean' then
        alfred_unknown.since, alfred_unknown.logged = nil, false
        return status
    end
    local now = get_time_since_inject()
    alfred_unknown.since = alfred_unknown.since or now
    if now - alfred_unknown.since < ALFRED_UNKNOWN_GRACE then return nil end
    if not alfred_unknown.logged then
        alfred_unknown.logged = true
        console.print(string.format("[HordeDev] Alfred status unreadable for %ds; treating Alfred as unavailable", ALFRED_UNKNOWN_GRACE))
    end
    return {enabled = false, unavailable = true}
end

-- Advisory need_trigger alone cannot re-trigger within the sticky grace after
-- a completed HordeDev Alfred cycle (tracker.alfred_completed_at); a hard need
-- (inventory_full / need_repair) always can.
function utils.alfred_trip_wanted(s, completed_at)
    if s.enabled ~= true then return false end
    if utils.alfred_hard_need(s) then return true end
    if s.need_trigger ~= true then return false end
    return not (completed_at and get_time_since_inject() - completed_at < ALFRED_STICKY_GRACE)
end

function utils.is_inventory_full()
    if AlfredTheButlerPlugin then
        local status = utils.read_alfred_status()
        if not status then return nil end
        if status.enabled and type(status.need_trigger) ~= 'boolean' then return nil end
        if (status.enabled and status.need_trigger) then
            return true
        end
    elseif PLUGIN_alfred_the_butler then
        local status = utils.read_alfred_status()
        if not status then return nil end
        if status.restock_count ~= nil and type(status.restock_count) ~= 'number' then return nil end
        -- WPT-1: only a live teleport is Alfred work; the latch left after a
        -- finished/failed trip is not "needs town".
        if status.enabled and (
            status.inventory_full or
            (status.restock_count or 0) > 0 or
            status.need_repair or
            (status.teleport == true and status.teleport_done ~= true and status.teleport_failed ~= true)
        ) then
            return true
        end
    end
    local player = get_local_player()
    return player ~= nil and player:get_item_count() >= 33
end

-- True while the waypoint teleport (spell 186139, as used by Arkham/WonderCity)
-- is channeling. A second teleport_to_waypoint() would cancel it.
function utils.is_teleport_casting()
    local ok, id = pcall(function()
        local player = get_local_player()
        return player and player:get_active_spell_id()
    end)
    return ok and id == 186139
end

function utils.get_character_class()
    local local_player = get_local_player();
    if not local_player then return nil end
    local class_id = local_player:get_character_class_id()
    local character_classes = {
        [0] = "sorcerer",
        [1] = "barbarian",
        [3] = "rogue",
        [5] = "druid",
        [6] = "necromancer",
        [7] = "spiritborn"
    }
    if character_classes[class_id] then
        return character_classes[class_id]
    else
        return "default"
    end
end

function utils.get_keybind_state()
    local toggle_key = gui.elements.keybind_toggle:get_key();
    local toggle_state = gui.elements.keybind_toggle:get_state();

    -- If not using keybind, skip
    if not settings.use_keybind then
        return true
    end

    if settings.use_keybind and toggle_key ~= 0x0A and toggle_state == 1 then
        return true
    end
    return false
end

return utils
