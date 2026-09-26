local plugin_label = 'wonder_city'
local settings = require 'core.settings'
local utils = require 'core.utils'
local task = {name = 'loot_obols', status = 'idle'}
local skipped, active_key, best_dist, progress_time = {}, nil, nil, nil
local function key_for(item)
    local p = item:get_position()
    return tostring(p:x()) .. ':' .. tostring(p:y())
end
local function is_obols(item)
    if loot_manager.is_obols then return loot_manager.is_obols(item) end
    local info = item:get_item_info()
    local name = info and info:get_display_name()
    return name and name:match('[Oo]bol') ~= nil
end
local function get_obols()
    local player = get_local_player()
    if not player then return nil end
    local enticement = utils.get_closest_enticement(true)
    local beacon = enticement and not enticement:get_skin_name():match('SpiritHearth_Switch')
    local closest, closest_dist
    for _, item in pairs(actors_manager:get_all_items()) do
        local key = key_for(item)
        if not skipped[key] and is_obols(item)
            and not (beacon and utils.distance(item, enticement) <= 3)
        then
            local dist = utils.distance(player, item)
            if not closest_dist or dist < closest_dist then closest, closest_dist = item, dist end
        end
    end
    return closest, closest_dist
end

task.shouldExecute = function ()
    local player = get_local_player()
    if not player or not settings.loot_obols or not utils.player_in_undercity() then return false end
    if (tonumber(player:get_obols()) or 0) >= 2500 then return false end
    return get_obols() ~= nil
end

task.Execute = function ()
    local obols, dist = get_obols()
    if not obols then return end
    local key, now = key_for(obols), get_time_since_inject()
    if key ~= active_key then
        active_key, best_dist, progress_time = key, dist, now
    elseif dist < best_dist - 1 then
        best_dist, progress_time = dist, now
    elseif now - progress_time > 12 then
        skipped[key] = true
        utils.stop_movement()
        task.status = 'unreachable obols — continuing'
        active_key = nil
        return
    end
    BatmobilePlugin.pause(plugin_label)
    BatmobilePlugin.update(plugin_label)
    if BatmobilePlugin.set_target(plugin_label, obols) == false then
        skipped[key] = true
        utils.stop_movement()
        active_key = nil
        return
    end
    BatmobilePlugin.move(plugin_label)
    task.status = 'walking to obols'
end

-- C5: time spent yielding (e.g. to Alfred) is not 'no progress' time.
task.on_yield = function (seconds)
    if progress_time then progress_time = progress_time + seconds end
end

task.reset = function ()
    skipped, active_key, best_dist, progress_time = {}, nil, nil, nil
end
return task
