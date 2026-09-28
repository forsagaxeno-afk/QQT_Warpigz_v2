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

-- True inside any boss lair (not only the current rotation's boss).
function utils.in_any_boss_zone()
    return enums.is_boss_zone(utils.get_zone())
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

-- True unless the actor positively reports it cannot be interacted with
-- (an unreadable state is never evidence).
function utils.is_interactable(actor)
    local ok, v = pcall(function() return actor:is_interactable() end)
    return not ok or v ~= false
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

-- QQT_Warpigz_v3 1.10.4: the third-party Navigator looter (docs/THIRD_PARTY_APIS.md):
-- a busy Scavenger holds the same loot waits as a busy Looter.
local function scavenger_busy()
    local s = Scavenger
    -- QQT_Warpigz_v3 1.10.6: Rosie's Scavenger stand-in (`_rosie=true`, published
    -- while Worldstone runs) is Rosie's pickup, already read through the Looter.
    if type(s) ~= 'table' or rawget(s, '_rosie') == true or type(s.is_busy) ~= 'function' then return false end
    local ok, busy = pcall(s.is_busy)
    return ok and busy == true
end
-- QQT_Warpigz_v3 1.10.4 (audit MED, Rosie yield rest <-> exit guards): a drop
-- Rosie stepped back from (yield, 4-30 s) or rests between rounds reads as
-- "not busy", yet Rosie still means to take it. A drop Rosie wants within
-- its own pickup range and has not given up on (evaluate_item: wanted by
-- distance, and not settled/exhausted) keeps the exit waiting, inside the
-- same bound. Sampled at most every PENDING_EVERY s.
local PENDING_EVERY = 0.5
local pending = {at = nil, value = false}
local function loot_pending()
    local looter = LooteerPlugin
    if type(looter) ~= 'table' or type(looter.evaluate_item) ~= 'function' then return false end
    local now = get_time_since_inject()
    if pending.at and now >= pending.at and now - pending.at < PENDING_EVERY then return pending.value end
    pending.at = now
    local ok, found = pcall(function()
        if type(looter.get_enabled) == 'function' and looter.get_enabled() ~= true then return false end
        -- QQT_Warpigz_v3 1.10.4 (Coordinator review): only a pickup that can act now
        -- (Rosie status().ready: enabled, not paused, not activity-owned, world
        -- loaded, no menu open) holds the exit for a pending drop.
        if type(looter.status) ~= 'function' then return false end
        local st = looter.status()
        if type(st) ~= 'table' or st.ready ~= true then return false end
        for _, item in pairs(actors_manager.get_all_items() or {}) do
            if looter.evaluate_item(item, false) and looter.evaluate_item(item, true) then return true end
        end
        return false
    end)
    pending.value = ok and found == true
    return pending.value
end

-- RPR-6: read-only Looter coordination (same contract reading as HordeDev's
-- loot_guard; the Looter's settings are never changed). A failed/invalid
-- read is not idle.
function utils.looter_busy()
    if scavenger_busy() then return true end -- QQT_Warpigz_v3 1.10.4
    local looter = LooteerPlugin
    if not looter then return false end
    local function read(fn, ...)
        if type(fn) ~= "function" then return false, nil end
        return pcall(fn, ...)
    end
    if type(looter.get_enabled) == "function" then
        local ok, enabled = read(looter.get_enabled)
        if not ok or type(enabled) ~= "boolean" then return true end
        if not enabled then return false end
    elseif type(looter.getSettings) == "function" then
        local ok, enabled = read(looter.getSettings, "enabled")
        if not ok then return true end
        if enabled == false or enabled == nil then return false end
        if enabled ~= true then return true end
    end
    local modern_unknown = false
    if type(looter.is_actively_looting) == "function" then
        local ok, active = read(looter.is_actively_looting)
        if ok and type(active) == "boolean" then return active end
        modern_unknown = true
    end
    if type(looter.is_idle) == "function" then
        local ok, idle = read(looter.is_idle)
        if ok and type(idle) == "boolean" then return not idle end
        modern_unknown = true
    end
    if modern_unknown then return true end
    if type(looter.getSettings) == "function" then
        local ok, active = read(looter.getSettings, "looting")
        if not ok then return true end
        return not (active == false or active == nil)
    end
    return true -- no readable ownership contract
end

-- Hold a lair exit (town teleport / next-run teleport) while the Looter picks
-- up the boss drops, then require LOOT_QUIET seconds of quiet. Bounded (C6):
-- after LOOT_HOLD_MAX of continuous busy the exit proceeds with one log line.
-- QQT_Warpigz_v3 1.10.4: Rosie (3.3.2) stays busy without moving while a
-- drop waits out a fight near the player, for up to 45 s (its fight hold
-- cap), and only then walks to it (20 s pickup episode). The old 30 s bound
-- left the lair first and lost the drop; 75 s covers the cap plus a pickup.
local LOOT_QUIET, LOOT_HOLD_MAX = 3, 75
local loot = { quiet_since = nil, busy_since = nil, logged = false }

function utils.loot_ready()
    if not LooteerPlugin and not scavenger_busy() then return true end -- QQT_Warpigz_v3 1.10.4
    local now = get_time_since_inject()
    if utils.looter_busy() or loot_pending() then -- QQT_Warpigz_v3 1.10.4: a yielded/resting drop
        loot.quiet_since = nil
        loot.busy_since = loot.busy_since or now
        if now - loot.busy_since < LOOT_HOLD_MAX then return false end
        if not loot.logged then
            loot.logged = true
            console.print(string.format("[Reaper] Looter busy for %ds; leaving the lair without waiting any longer", LOOT_HOLD_MAX))
        end
        return true
    end
    -- QQT_Warpigz_v3 1.10.4: a quiet gap shorter than LOOT_QUIET does not end
    -- the busy episode (a flapping Looter re-armed LOOT_HOLD_MAX forever).
    loot.quiet_since = loot.quiet_since or now
    if now - loot.quiet_since < LOOT_QUIET then return loot.logged end -- a spent bound stays released
    loot.busy_since, loot.logged = nil, false
    return true
end

-- Reason text while the Looter holds a lair exit (nil when not holding).
function utils.loot_hold_reason()
    if not loot.busy_since or loot.logged then return nil end
    return string.format("waiting for Looter (%ds)", math.floor(get_time_since_inject() - loot.busy_since))
end

function utils.reset_loot_guard()
    loot.quiet_since, loot.busy_since, loot.logged = nil, nil, false
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

-- QQT_Warpigz_v3: a SilentRaven Whisper claim (its own auto-fire or keybind,
-- or a queued request) owns Temis movement and clicks until it finishes,
-- bounded by SilentRaven (100 s run, 120 s pause). Town steps (walks,
-- interactions, the teleport out of Temis) wait; a paused queued request
-- does not hold them.
utils.raven_claim_active = function ()
    local raven = SilentRavenPlugin or PLUGIN_silent_raven
    if type(raven) ~= 'table' or type(raven.get_status) ~= 'function' then return false end
    local ok, s = pcall(raven.get_status)
    return ok and type(s) == 'table' and s.enabled == true
        and (s.running == true or (s.pending == true and s.paused ~= true))
end

return utils
