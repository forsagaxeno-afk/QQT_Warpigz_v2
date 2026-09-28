-- QQT_Warpigz_v3: WarRoom's read-only view of the game. Every getter is
-- called under pcall and a value that is not a finite number / string is
-- reported as nil (the dashboard shows "n/a"). The XP and gold getters are
-- not verified on every QQT build: a missing method is simply nil.
local M = {HELLTIDE_BUFF = 1066539}

local function finite(v)
    if type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
end

-- obj:method() protected; nil unless it returns a finite number.
local function num_call(obj, method)
    if obj == nil then return nil end
    local ok, v = pcall(function() return obj[method](obj) end)
    if not ok then return nil end
    return finite(v)
end

local function str_call(obj, method)
    if obj == nil then return nil end
    local ok, v = pcall(function() return obj[method](obj) end)
    if ok and type(v) == 'string' then return v end
    return nil
end

local function global_fn(name)
    local fn = rawget(_G, name)
    if type(fn) ~= 'function' then return nil end
    return fn
end

local function attribute(lp, key, fallback)
    local ok, v = pcall(function()
        local attrs = rawget(_G, 'attributes')
        local id = type(attrs) == 'table' and attrs[key] or nil
        if id == nil then id = fallback end
        if id == nil then return nil end
        return lp:get_attribute(id)
    end)
    if ok then return finite(v) end
    return nil
end

local function in_helltide(lp)
    local ok, found = pcall(function()
        local buffs = lp:get_buffs()
        if type(buffs) ~= 'table' then return false end
        for _, buff in ipairs(buffs) do
            if buff.name_hash == M.HELLTIDE_BUFF then return true end
        end
        return false
    end)
    return ok and found == true
end

-- One snapshot of the player and the world (never raises).
function M.poll()
    local snap = {}
    local get_lp = global_fn('get_local_player')
    local lp
    if get_lp then
        local ok, v = pcall(get_lp)
        if ok and v ~= nil then lp = v end
    end
    snap.player = lp ~= nil
    if lp then
        snap.gold = num_call(lp, 'get_gold')
        snap.level = num_call(lp, 'get_level')
        snap.xp = num_call(lp, 'get_current_experience')
        snap.xp_need = num_call(lp, 'get_experience_total_next_level')
        snap.paragon = attribute(lp, 'PARAGON_LEVEL', nil)
        snap.obols = num_call(lp, 'get_obols')
        local ok, dead = pcall(function() return lp:is_dead() end)
        snap.dead = ok and dead == true
        snap.in_town = attribute(lp, 'PLAYER_IN_TOWN_LEVEL_AREA', 'Player_In_Town_Level_Area') == 1
        snap.in_helltide = in_helltide(lp)
    end
    local cinders_fn = global_fn('get_helltide_coin_cinders')
    if cinders_fn then
        local ok, v = pcall(cinders_fn)
        if ok then snap.cinders = finite(v) end
    end
    local world_fn = global_fn('get_current_world')
    if world_fn then
        local ok, world = pcall(world_fn)
        if ok and world ~= nil then
            snap.world = str_call(world, 'get_name')
            snap.zone = str_call(world, 'get_current_zone_name')
        end
    end
    return snap
end

-- Activity from the place alone ('pit', 'undercity', 'hordes', 'bosses',
-- 'helltide', 'town') or nil.
function M.place_activity(snap)
    local world, zone = snap.world or '', snap.zone or ''
    if world:match('^PIT_') or zone:match('^PIT_') then return 'pit' end
    if zone:match('X1_Undercity_') then return 'undercity' end
    if zone:match('S05_BSK_Prototype02') then return 'hordes' end
    if zone:match('^Boss_WT') or zone:match('^Boss_Kehj') or world:match('^Boss_') then return 'bosses' end
    if snap.in_helltide then return 'helltide' end
    if snap.in_town then return 'town' end
    return nil
end

-- A readable zone label (game data only).
local TITLES = {pit = 'The Pit', undercity = 'Undercity', hordes = 'Infernal Hordes'}
function M.zone_label(snap, activity)
    if TITLES[activity] then return TITLES[activity] end
    local zone = snap.zone
    if type(zone) ~= 'string' or zone == '' or zone == '[sno none]' then return '' end
    local label = zone:gsub('^%a%a%a%a?_', ''):gsub('_', ' ')
    if activity == 'helltide' then return 'Helltide · ' .. label end
    return label
end

M._finite = finite
return M
