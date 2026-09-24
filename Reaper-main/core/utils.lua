-- ============================================================
--  Reaper - core/utils.lua
-- ============================================================

local enums = require "data.enums"
local utils = {}

function utils.distance_to(target)
    local player_pos = get_player_position()
    if not player_pos or not target then return math.huge end
    local target_pos
    if target.get_position then
        target_pos = target:get_position()
    elseif target.x then
        target_pos = target
    end
    return target_pos and player_pos:dist_to(target_pos) or math.huge
end

function utils.get_zone()
    local world = get_current_world()
    return world and world:get_current_zone_name() or ""
end

function utils.player_in_zone(zname)
    return utils.get_zone() == zname
end

function utils.match_player_zone(pattern)
    return utils.get_zone():match(pattern)
end

function utils.in_boss_zone(boss)
    return enums.zone_matches(boss, utils.get_zone())
end

function utils.get_altar()
    local ok, actors = pcall(function() return actors_manager:get_all_actors() end)
    if not ok or type(actors) ~= "table" then return nil, false end
    local readable = true
    for _, actor in pairs(actors) do
        local valid, name = pcall(function() return actor:get_skin_name() end)
        if not valid or type(name) ~= "string" then readable = false
        else
            for _, aname in ipairs(enums.altar_names) do
                if name == aname then return actor, true end
            end
        end
    end
    return nil, readable
end

function utils.get_dungeon_entrance()
    local actors = actors_manager:get_all_actors() or {}
    local world = get_current_world()
    local world_name = world and world:get_name() or ""
    for _, actor in pairs(actors) do
        local name = actor:get_skin_name()
        if name == enums.misc.dungeon_entrance and utils.distance_to(actor) < 60 then
            if world_name == "Sanctuary_Eastern_Continent" or world_name == "Frac_Underworld" then
                return actor
            end
        end
    end
    return nil
end

function utils.get_suppressor()
    local actors = actors_manager:get_all_actors() or {}
    for _, actor in pairs(actors) do
        if actor:get_skin_name() == enums.misc.suppressor then return actor end
    end
end

function utils.get_town_portal()
    local actors = actors_manager:get_all_actors() or {}
    for _, actor in pairs(actors) do
        if actor:get_skin_name() == enums.misc.portal then return actor end
    end
end

function utils.get_closest_enemy()
    local player_pos = get_player_position()
    if not player_pos then return nil end
    local enemies    = target_selector.get_near_target_list(player_pos, 20) or {}
    local best, best_dist = nil, math.huge
    for _, enemy in pairs(enemies) do
        local dist = player_pos:dist_to(enemy:get_position())
        if dist < best_dist then
            best = enemy
            best_dist = dist
        end
    end
    return best
end

-- Boss quest presence tracking.
-- The Boss_*_Primary quest appears when the boss spawns and disappears when it dies.
-- We track "seen" so we don't fire before the boss ever appears.
local boss_quest_seen = false

local function boss_quest_present()
    local ok, quests = pcall(get_quests)
    if not ok or type(quests) ~= "table" then return false end
    for _, quest in ipairs(quests) do
        local ok_n, name = pcall(function() return quest:get_name() end)
        if ok_n and type(name) == "string"
            and name:find("^Boss_") and name:find("_Primary$") then
            return true
        end
    end
    return false
end

-- Returns true once the boss quest was seen this run and has since disappeared.
function utils.is_boss_quest_complete()
    local present = boss_quest_present()
    if present then
        if not boss_quest_seen then
            console.print("[Reaper] Boss quest detected — tracking active.")
        end
        boss_quest_seen = true
        return false
    end
    if boss_quest_seen then
        console.print("[Reaper] Boss quest gone (was seen) — boss is dead.")
        return true
    end
    return false
end

-- Returns true while the boss quest is currently active (boss is alive/spawning).
function utils.boss_quest_active()
    local ok, quests = pcall(get_quests)
    if not ok or type(quests) ~= "table" then return false end
    for _, quest in ipairs(quests) do
        local ok_n, name = pcall(function() return quest:get_name() end)
        if ok_n and type(name) == "string"
            and name:find("^Boss_") and name:find("_Primary$") then
            return true
        end
    end
    return false
end

-- Reset at the start of each new run.
function utils.reset_boss_quest_tracking()
    if boss_quest_seen then
        console.print("[Reaper] Boss quest tracking reset for new run.")
    end
    boss_quest_seen = false
end

local MOVEMENT_SPELL_IDS = { 288106, 358761, 355606, 1663206, 1871821, 337031 }

function utils.try_movement_spell(target_pos)
    local player = get_local_player()
    if not player then return false end
    for _, sid in ipairs(MOVEMENT_SPELL_IDS) do
        if player:is_spell_ready(sid) then
            if cast_spell.position(sid, target_pos, 3.0) then return true end
        end
    end
    return false
end

return utils
