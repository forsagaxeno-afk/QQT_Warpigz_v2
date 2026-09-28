-- RouteRecorder (QQT_Warpigz_v3 diagnostics, not part of the release package).
-- Read-only: it never moves the character, clicks or changes a setting.
-- It records a dungeon run so our own activity plugin can replay the route:
--   W  world / zone changes (with the world id)
--   P  the player position (every 0.5 s when it moved 0.5 m, else every 5 s)
--   A  objects near the player (portals, altars, doors, chests, bosses,
--      elites): first sighting, and when "interactable" or a boss's health
--      changes state
--   I  ground items (first sighting, and when they leave the ground)
--   S  the active spell changes (casts, e.g. 186139 = Town Portal)
--   D  death / revive
--   N  Navigator.get_status() changes (state, owner, request, target)
-- Everything goes to RouteRecorder\route_log.txt (and a short line to the
-- console on world changes). Actor lists are never read while the game loads
-- (Limbo / Loading / no zone) or for 3 s after a world change: reading them in
-- those windows can crash the client (see WonderCity enter_undercity.lua).
-- Remove the folder when done.
local SCAN_RADIUS = 45        -- m, objects and items logged around the player
local SCAN_EVERY = 1.0        -- s between actor scans
local POS_EVERY, POS_IDLE = 0.5, 5.0
local SETTLE_AFTER_WORLD = 3.0
local MAX_LINES = 200000

local file_path, lines = nil, 0
do
    local ok, dir = pcall(function()
        local found = package.searchpath and package.searchpath('main', package.path)
        return found and found:match('^(.*[/\\])')
    end)
    if ok and type(dir) == 'string' and dir:sub(1, 1) ~= '.' then file_path = dir .. 'route_log.txt' end
end

local function out(kind, text, echo)
    if echo then console.print('[RouteRecorder] ' .. text) end
    if not file_path or lines >= MAX_LINES then return end
    local f = io.open(file_path, 'a')
    if f then
        f:write(string.format('%.2f %s %s\n', get_time_since_inject(), kind, text))
        f:close()
        lines = lines + 1
    end
end

local function xyz(p)
    local ok, x, y, z = pcall(function() return p:x(), p:y(), p:z() end)
    if ok then return x, y, z end
    return 0, 0, 0
end

local function call(obj, name, ...)
    if obj == nil then return nil end
    local ok, fn = pcall(function() return obj[name] end)
    if not ok or type(fn) ~= 'function' then return nil end
    local ok2, v = pcall(fn, obj, ...)
    if ok2 then return v end
    return nil
end

local state = {
    world = nil, zone = nil, world_id = nil, world_at = -math.huge,
    pos_at = -math.huge, px = nil, py = nil, scan_at = -math.huge,
    spell = nil, dead = nil, nav = nil,
    actors = {}, items = {},
}

local function loading(world_name, zone)
    return type(world_name) ~= 'string' or world_name == '' or world_name:find('Limbo', 1, true) ~= nil
        or world_name:find('Loading', 1, true) ~= nil or type(zone) ~= 'string' or zone == '' or zone == '[sno none]'
end

-- Objects worth recording: anything interactable, plus portals/doors/altars/
-- chests/entrances by name, plus bosses and elites.
local KEYWORDS = {'portal', 'door', 'altar', 'gizmo', 'chest', 'entrance', 'exit', 'switch', 'stone', 'chamber',
    'waypoint', 'shrine', 'lever', 'gate', 'stairs', 'cache', 'reward'}
local function interesting(skin, interactable, boss, elite)
    if interactable or boss or elite then return true end
    local low = string.lower(skin or '')
    for _, k in ipairs(KEYWORDS) do if low:find(k, 1, true) then return true end end
    return false
end

local function scan(now, px, py)
    local actors = call(actors_manager, 'get_all_actors') or {}
    local seen = {}
    for _, a in ipairs(actors) do
        local id = call(a, 'get_id')
        local pos = call(a, 'get_position')
        if id and pos then
            local x, y, z = xyz(pos)
            if (x - px) ^ 2 + (y - py) ^ 2 <= SCAN_RADIUS ^ 2 then
                local skin = call(a, 'get_skin_name') or '?'
                local inter = call(a, 'is_interactable') == true
                local boss = call(a, 'is_boss') == true
                local elite = call(a, 'is_elite') == true
                if interesting(skin, inter, boss, elite) then
                    seen[id] = true
                    local hp = call(a, 'get_current_health')
                    local alive = hp == nil or hp > 1
                    local key = tostring(inter) .. '/' .. tostring(boss and alive)
                    local old = state.actors[id]
                    if not old then
                        out('A', string.format('new %s id=%s at %.1f,%.1f,%.1f interactable=%s boss=%s elite=%s hp=%s',
                            skin, tostring(id), x, y, z, tostring(inter), tostring(boss), tostring(elite),
                            hp and string.format('%.0f', hp) or '?'))
                    elseif old.key ~= key then
                        out('A', string.format('change %s id=%s at %.1f,%.1f,%.1f interactable=%s alive=%s',
                            skin, tostring(id), x, y, z, tostring(inter), tostring(alive)))
                    end
                    state.actors[id] = {key = key, skin = skin}
                end
            end
        end
    end
    for id, a in pairs(state.actors) do
        if not seen[id] then out('A', string.format('gone %s id=%s', a.skin, tostring(id))); state.actors[id] = nil end
    end
    local items = call(actors_manager, 'get_all_items') or {}
    local iseen = {}
    for _, it in ipairs(items) do
        local id = call(it, 'get_id')
        local pos = call(it, 'get_position')
        if id and pos then
            local x, y, z = xyz(pos)
            if (x - px) ^ 2 + (y - py) ^ 2 <= SCAN_RADIUS ^ 2 then
                iseen[id] = true
                if not state.items[id] then
                    local skin = call(it, 'get_skin_name') or '?'
                    local name = call(it, 'get_display_name') or skin
                    local rarity = call(it, 'get_rarity')
                    state.items[id] = tostring(name)
                    out('I', string.format('drop %s rarity=%s id=%s at %.1f,%.1f,%.1f (%.1f m)', tostring(name),
                        tostring(rarity), tostring(id), x, y, z, math.sqrt((x - px) ^ 2 + (y - py) ^ 2)))
                end
            end
        end
    end
    for id, name in pairs(state.items) do
        if not iseen[id] then out('I', string.format('gone %s id=%s', name, tostring(id))); state.items[id] = nil end
    end
end

local function navigator(now)
    local nav = rawget(_G, 'Navigator')
    if type(nav) ~= 'table' or type(nav.get_status) ~= 'function' then return end
    local ok, st = pcall(nav.get_status)
    if not ok or type(st) ~= 'table' then return end
    local key = string.format('state=%s owner=%s request=%s paused=%s priority=%s mode=%s',
        tostring(st.state), tostring(st.owner), tostring(st.request_id), tostring(st.is_paused),
        tostring(st.priority), tostring(st.mode))
    if key ~= state.nav then state.nav = key; out('N', key) end
end

out('W', 'RouteRecorder loaded', true)

on_update(function()
    local now = get_time_since_inject()
    local player = get_local_player()
    local world = get_current_world()
    local wname = world and call(world, 'get_name')
    local zone = world and call(world, 'get_current_zone_name')
    local wid = world and call(world, 'get_world_id')
    if wname ~= state.world or zone ~= state.zone or wid ~= state.world_id then
        state.world, state.zone, state.world_id = wname, zone, wid
        state.world_at = now
        state.actors, state.items = {}, {}
        out('W', string.format('world=%s zone=%s world_id=%s', tostring(wname), tostring(zone), tostring(wid)), true)
    end
    navigator(now)
    if not player or loading(wname, zone) then return end
    local dead = call(player, 'is_dead') == true
    if dead ~= state.dead then
        state.dead = dead
        out('D', dead and 'dead' or 'alive')
    end
    local spell = call(player, 'get_active_spell_id')
    if spell ~= state.spell then state.spell = spell; out('S', 'active_spell=' .. tostring(spell)) end
    local pos = call(player, 'get_position')
    if not pos then return end
    local px, py, pz = xyz(pos)
    local moved = state.px == nil or (px - state.px) ^ 2 + (py - state.py) ^ 2 >= 0.25
    if (moved and now - state.pos_at >= POS_EVERY) or now - state.pos_at >= POS_IDLE then
        state.pos_at, state.px, state.py = now, px, py
        out('P', string.format('%.1f,%.1f,%.1f', px, py, pz))
    end
    if dead or now - state.world_at < SETTLE_AFTER_WORLD or now - state.scan_at < SCAN_EVERY then return end
    state.scan_at = now
    local ok, err = pcall(scan, now, px, py)
    if not ok then out('E', 'scan failed: ' .. tostring(err)) end
end)
