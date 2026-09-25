local data = require("tristram.data")
local M = {}
function M.try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end
function M.method(obj, name, ...)
    if obj == nil then return nil end
    local ok, fn = pcall(function() return obj[name] end)
    if not ok then return nil end
    return M.try(fn, obj, ...)
end
function M.sample()
    local player = get_local_player()
    local current_world = get_current_world()
    if not player or not current_world then return nil end
    local position = player:get_position()
    if not position then return nil end
    local dead = player:is_dead()
    local name, zone, id = current_world:get_name(), current_world:get_current_zone_name(), current_world:get_world_id()
    -- The host can retain objects while their world/life data is still loading.
    if type(dead) ~= "boolean" or type(id) ~= "number" or id ~= id
        or type(name) ~= "string" or name == "" or type(zone) ~= "string" or zone == ""
        or name == "[sno none]" or zone == "[sno none]" then return nil end
    return { player = player, position = position, dead = dead, name = name, zone = zone, id = id }
end
function M.in_arena(sample, arena)
    return sample ~= nil and arena ~= nil and sample.name == arena.name and sample.zone == arena.zone
end
function M.distance(a, b)
    if not a or not b then return math.huge end
    local d = M.method(a, "squared_dist_to_ignore_z", b)
    if type(d) ~= "number" or d < 0 or d ~= d then return math.huge end
    return math.sqrt(d)
end
function M.peer(name, method, ...)
    local peer = rawget(_G, name)
    if type(peer) ~= "table" then return nil end
    return M.try(rawget(peer, method), ...)
end
function M.standalone_rotation()
    local peer = rawget(_G, "WarlockBlazingScreamPlugin")
    if peer == nil then return false end
    local enabled = M.peer("WarlockBlazingScreamPlugin", "is_enabled")
    if type(enabled) ~= "boolean" then
        return true, "Rotation state is unreadable; fallback casting is paused."
    end
    return enabled
end
function M.actors()
    local actors = M.try(actors_manager.get_all_actors)
    if type(actors) ~= "table" then return nil end
    -- Native actor collections can have holes or actor-ID keys. Keep every
    -- supplied row, including unreadable ones, for downstream completeness checks.
    local dense = {}
    for _, actor in pairs(actors) do dense[#dense + 1] = actor end
    return dense
end
function M.entry_portal(position)
    local actors = M.actors()
    if not actors then return nil, "Waiting for a readable party portal list." end
    local selected, count = nil, 0
    local seen = {}
    for _, actor in ipairs(actors) do
        -- Exact interactable skin from the user's screenshot. A personal TownPortal,
        -- waypoint or portal particle is not the party member's entry portal.
        if M.method(actor, "get_skin_name") == data.ENTRY_PORTAL_SKIN
            and M.method(actor, "is_interactable") == true
            and M.method(actor, "is_enemy") ~= true
            and M.distance(position, M.method(actor, "get_position")) <= 60 then
            local id = M.method(actor, "get_id") or actor
            if not seen[id] then selected = actor; count = count + 1; seen[id] = true end
        end
    end
    if count > 1 then return nil, "Multiple usable party portals; waiting for one identifiable portal." end
    if not selected then return nil, "Waiting for " .. data.ENTRY_PORTAL_SKIN .. " near the character." end
    return selected
end
function M.diagnose()
    local s = M.sample()
    if not s then console.print("[TristramLoop] no loaded world/player"); return end
    console.print(string.format("[TristramLoop] world=%s zone=%s world_id=%s position=%.3f,%.3f,%.3f",
        s.name, s.zone, tostring(s.id), s.position:x(), s.position:y(), s.position:z()))
    local shown = 0
    for _, actor in ipairs(M.actors() or {}) do
        local skin = M.method(actor, "get_skin_name") or "?"
        local enemy = M.method(actor, "is_enemy") == true
        local boss = M.method(actor, "is_boss") == true
        local interactable = M.method(actor, "is_interactable") == true
        if shown < 30 and (enemy or boss or interactable or skin:lower():find("portal", 1, true)) then
            console.print(string.format("[TristramLoop] actor skin=%s actor_id=%s enemy=%s boss=%s dead=%s interactable=%s",
                skin, tostring(M.method(actor, "get_id")), tostring(enemy), tostring(boss),
                tostring(M.method(actor, "is_dead")), tostring(interactable)))
            shown = shown + 1
        end
    end
end
return M
