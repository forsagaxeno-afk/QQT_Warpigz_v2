-- Chest discovery uses only the existing, source-backed name/cost table.
-- Unknown seasonal skins are observable in diagnostics, never assigned a cost.
local M = {}

function M.read(actor)
    if not actor then return nil end
    local ok, skin, position, interactable = pcall(function()
        return actor:get_skin_name(), actor:get_position(), actor:is_interactable()
    end)
    if not ok or type(skin) ~= "string" or not position then return nil end
    return {actor = actor, skin = skin, position = position, interactable = interactable == true}
end

function M.collect(actor_source, loot_source)
    local result, seen = {}, {}
    local function append(source)
        if type(source) ~= "table" then return end
        for _, actor in pairs(source) do
            if actor and not seen[actor] and M.read(actor) then
                seen[actor] = true
                result[#result + 1] = actor
            end
        end
    end
    if actor_source and actor_source.get_all_actors then
        local ok, actors = pcall(function() return actor_source:get_all_actors() end)
        if ok then append(actors) end
    end
    -- This documented host API can include chests absent from the actor list.
    if loot_source and loot_source.get_all_items_chest_sort_by_distance then
        local ok, actors = pcall(loot_source.get_all_items_chest_sort_by_distance)
        if ok then append(actors) end
    end
    return result
end

function M.classify(skin, chest_types)
    if type(skin) ~= "string" then return nil end
    local lower = string.lower(skin)
    local best_name, best_cost
    for name, cost in pairs(chest_types) do
        if lower:find(string.lower(name), 1, true)
            and (not best_name or #name > #best_name) then
            best_name, best_cost = name, cost
        end
    end
    return best_name, best_cost
end

function M.key(name, position)
    return string.format("%s_%d_%d_%d", name,
        math.floor(position:x()), math.floor(position:y()), math.floor(position:z()))
end

-- Apply eligibility before distance ranking: an opened or blacklisted chest
-- must not hide another chest with the same skin.
function M.select(actors, chest_types, player_position, cinders, max_distance, excluded)
    local best, best_distance
    for _, actor in pairs(actors) do
        local entry = M.read(actor)
        if entry and entry.interactable then
            entry.name, entry.cost = M.classify(entry.skin, chest_types)
            if entry.name and cinders >= entry.cost then
                local distance = player_position:dist_to(entry.position)
                if distance <= max_distance and (not excluded or not excluded(entry))
                    and (not best_distance or distance < best_distance
                        or (distance == best_distance and entry.name < best.name)) then
                    best, best_distance = entry, distance
                end
            end
        end
    end
    return best
end

-- Reacquire at the selected location, including spent actors for completion
-- checks. A different same-type chest elsewhere is not the selected chest.
function M.at_position(actors, name, position)
    local best, best_distance = nil, 4
    for _, actor in pairs(actors) do
        local entry = M.read(actor)
        if entry and entry.skin:lower():find(name:lower(), 1, true) then
            local distance = position:dist_to(entry.position)
            if distance <= best_distance then
                best, best_distance = actor, distance
            end
        end
    end
    return best
end

return M
