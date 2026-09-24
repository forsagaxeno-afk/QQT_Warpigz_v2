-- core/whispers.lua  --  quest detection + NPC find + click helpers
--
-- Adapted from WarMachine/core/whispers.lua.  Standalone here -- no
-- dependency on a `find` module; we inline the actor-stream scan.
--
-- Live-validated S09 transitions on the Bounty_Meta_Quest:
--   "Collect Grim Favor (N/10)"   -- accumulating; not a turn-in
--   "Return to the Tree of Whispers or find a Crow of the Tree in town"
--                                 -- ready, panel closed
--   "Choose your reward"          -- panel open mid-selection
--   (quest disappears from log)   -- successfully turned in

local M = {}

-- This integration is intentionally restricted to Temis.
local TOWN_ZONES = {
    ['Skov_Temis']          = true,

}

-- Bounty NPC skin patterns.  `temis_bounty_meta_raven_npc` is the live
-- match in Skov_Temis; the rest are defensive against future-season skins
-- and the legacy Hawezar Tree.
local TREE_NPC_PATTERNS = {
    'temis_bounty_meta_raven_npc',
    'bounty_meta_raven',
    'bounty_meta_crow',
    'bounty_meta',
    'treeofwhispers',
    'tree_of_whispers',
    'crow_of_the_tree',
}

local BOUNTY_QUEST_NAMES = {
    'Bounty_Meta_Quest',
    'Bounty_Meta_',
    'Bounty_Tree_',
}

local TURN_IN_OBJECTIVE_HINTS = {
    'tree of whispers',
    'crow of the tree',
    'choose your reward',
    'choose a reward',
    'select your reward',
}

local function safe_method(object, name, ...)
    if not object then return nil end
    local ok, value = pcall(function(...) return object[name](object, ...) end, ...)
    if ok then return value end
    return nil
end
M.safe_method = safe_method
M.current_zone = function ()
    if type(get_current_world) ~= 'function' then return nil end
    local ok, world = pcall(get_current_world)
    if not ok then return nil end
    local zone = safe_method(world, 'get_current_zone_name')
    if type(zone) ~= 'string' or zone == '' or zone == '[sno none]' or zone == 'Limbo' then return nil end
    local name = safe_method(world, 'get_name')
    if type(name) == 'string' then
        local normalized = name:lower()
        if normalized:find('limbo', 1, true) or normalized:find('loading', 1, true) then return nil end
    end
    return zone
end
M.in_whisper_town = function () return M.current_zone() == 'Skov_Temis' end
M.player_ready = function ()
    if type(get_local_player) ~= 'function' then return false end
    local ok, player = pcall(get_local_player)
    return ok and player ~= nil and safe_method(player, 'is_dead') == false
end

local function quest_name_matches(name)
    if type(name) ~= 'string' then return false end
    for _, want in ipairs(BOUNTY_QUEST_NAMES) do
        if name:sub(1, #want) == want then return true end
    end
    return false
end

-- Tri-state read. A failed quest read is unknown, never evidence of a claim.
M.quest_snapshot = function ()
    if type(get_quests) ~= 'function' then return nil end
    local ok, quests = pcall(get_quests)
    if not ok or type(quests) ~= 'table' then return nil end
    local result = { present = false, ready = false, collecting = false }
    for _, quest in pairs(quests) do
        local name = safe_method(quest, 'get_name')
        if type(name) ~= 'string' then return nil end
        if quest_name_matches(name) then
            result.present = true
            local objectives = safe_method(quest, 'get_objectives')
            if type(objectives) == 'table' then
                for _, objective in pairs(objectives) do
                    local text = type(objective) == 'table' and objective.text or nil
                    if type(text) == 'string' then
                        text = text:lower()
                        if text:find('collect grim favor', 1, true) then result.collecting = true end
                        for _, hint in ipairs(TURN_IN_OBJECTIVE_HINTS) do
                            if text:find(hint, 1, true) then result.ready = true end
                        end
                    end
                end
            end
        end
    end
    return result
end
M.count_ready_bounties = function ()
    local snapshot = M.quest_snapshot()
    return snapshot and snapshot.ready and 1 or 0
end
M.is_bounty_quest_present = function ()
    local snapshot = M.quest_snapshot()
    if not snapshot then return nil end
    return snapshot.present
end

-- Count the selected cache across both bags. Both snapshots must succeed.
-- This is independent receipt evidence even when the quest list is empty.
M.cache_count = function(sno)
    if type(sno) ~= 'number' or type(get_local_player) ~= 'function' then return nil end
    local ok, player = pcall(get_local_player)
    if not ok or not player then return nil end
    local total, seen = 0, {}
    for _, method in ipairs({'get_inventory_items', 'get_consumable_items'}) do
        local items = safe_method(player, method)
        if type(items) ~= 'table' then return nil end
        for _, item in pairs(items) do
            local item_sno = safe_method(item, 'get_sno_id')
            if type(item_sno) ~= 'number' then return nil end
            local id = safe_method(item, 'get_acd')
            local key = id and id ~= 0 and id or item
            if item_sno == sno and not seen[key] then
                seen[key] = true
                local count = safe_method(item, 'get_stack_count')
                total = total + (type(count) == 'number' and count > 0 and count or 1)
            end
        end
    end
    return total
end

-- Closest interactable Tree/Raven/Crow NPC in the live ally stream.
-- Returns (actor, dist_sq) or (nil, math.huge).  Returns nil before the
-- actor stream has populated post-zone-change -- caller should retry.
M.find_tree_npc = function ()
    if not actors_manager or type(get_local_player) ~= 'function' then return nil, math.huge end
    local ok, player = pcall(get_local_player)
    if not ok or not player then return nil, math.huge end
    local pp = safe_method(player, 'get_position')
    local px, py = safe_method(pp, 'x'), safe_method(pp, 'y')
    if not px or not py then return nil, math.huge end
    local actors = safe_method(actors_manager, 'get_ally_actors')
    if type(actors) ~= 'table' then return nil, math.huge end
    local best, best_d2 = nil, math.huge
    for _, actor in pairs(actors) do
        local skin = safe_method(actor, 'get_skin_name')
        if type(skin) == 'string' and safe_method(actor, 'is_interactable') == true then
            for _, pattern in ipairs(TREE_NPC_PATTERNS) do
                if skin:lower():find(pattern, 1, true) then
                    local pos = safe_method(actor, 'get_position')
                    local x, y = safe_method(pos, 'x'), safe_method(pos, 'y')
                    if x and y then
                        local distance = (x - px)^2 + (y - py)^2
                        if distance < best_d2 then best, best_d2 = actor, distance end
                    end
                    break
                end
            end
        end
    end
    return best, best_d2
end
M.player_dist_sq = function(actor)
    if type(get_local_player) ~= 'function' then return math.huge end
    local ok, player = pcall(get_local_player)
    if not ok then return math.huge end
    local pp, ap = safe_method(player, 'get_position'), safe_method(actor, 'get_position')
    local px, py, ax, ay = safe_method(pp, 'x'), safe_method(pp, 'y'), safe_method(ap, 'x'), safe_method(ap, 'y')
    if not px or not py or not ax or not ay then return math.huge end
    return (px - ax)^2 + (py - ay)^2
end

M.send_escape = function ()
    if utility and utility.send_key_press then
        pcall(utility.send_key_press, 0x1B)
    end
end

-- ---------------------------------------------------------------------------
-- Skov_Temis Raven NPC navigation
--
-- Live-validated coordinates from the user (2026-05-09):
--   TP arrival   : ~(2579.58, -482.19, 31.50)
--   Intermediate : ~(2597.24, -488.08, 30.52)  -- avoids a wall on the
--                                                 direct path to the NPC
--   Raven NPC    : ~(2596.38, -495.79, 30.52)
--
-- The intermediate is needed because the NPC actor doesn't appear in
-- the live ally stream until the player is within ~20-25 yards.  After
-- TP arrival we're still 16+ yards away, so find_tree_npc() returns
-- nil and the FSM has nothing to walk toward.  Walking blindly to the
-- intermediate point closes the gap; once the NPC pops into stream the
-- normal "walk to actor + interact" path takes over.
--
-- The intermediate is randomized within INTERMEDIATE_RANDOMIZE_RADIUS
-- yards so repeated runs don't path through the exact same point.
-- ---------------------------------------------------------------------------
M.RAVEN_NPC_POSITION = { x = 2596.38, y = -495.79, z = 30.52 }
M.RAVEN_INTERMEDIATE = { x = 2597.24, y = -488.08, z = 30.52 }

M.INTERMEDIATE_RANDOMIZE_RADIUS = 2.0    -- yards (uniform jitter)
M.INTERMEDIATE_ARRIVAL_RADIUS   = 3.5    -- "close enough" to advance

-- Per-zone hard-coded NPC + intermediate coords.  Used by WALK_NPC's
-- static fallback (when the actor isn't in stream yet) AND by
-- maybe_autofire as the gate for "is it safe to fire here without
-- seeing the actor first?".
--
-- Only Skov_Temis is eligible; other towns never enter the task.
M.ZONE_COORDS = {
    ['Skov_Temis'] = {
        npc_pos      = M.RAVEN_NPC_POSITION,
        intermediate = M.RAVEN_INTERMEDIATE,
    },
}

-- True when we have hard-coded NPC coords for the given zone.
M.has_known_coords = function (zone)
    return M.ZONE_COORDS[zone or ''] ~= nil
end

-- Coords for the zone the player is currently in, or nil.
M.current_zone_coords = function ()
    return M.ZONE_COORDS[M.current_zone() or '']
end

-- Pick a randomized point within INTERMEDIATE_RANDOMIZE_RADIUS yards
-- of the canonical intermediate.  Z stays exact (terrain is flat in
-- this corridor).  Call once per attempt and reuse the result.
M.choose_intermediate = function ()
    local r  = M.INTERMEDIATE_RANDOMIZE_RADIUS
    local dx = (math.random() * 2 - 1) * r
    local dy = (math.random() * 2 - 1) * r
    return {
        x = M.RAVEN_INTERMEDIATE.x + dx,
        y = M.RAVEN_INTERMEDIATE.y + dy,
        z = M.RAVEN_INTERMEDIATE.z,
    }
end

-- Walk toward a static {x, y, z} position via pathfinder.
--
-- Prefer pathfinder.request_move over move_to_cpathfinder: per the
-- API stub, request_move is the per-frame friendly "request to move
-- if not already moving" variant -- the canonical QQT movement
-- pattern (WarMachine nav uses it exclusively).  move_to_cpathfinder
-- recomputes a custom path every call which thrashes on per-frame
-- invocation and produces visibly slow stuttering walks.
--
-- Best-effort -- silent no-op if the host doesn't expose pathfinder
-- + vec3.
M.move_to_pos = function (pos)
    if not pos or not pathfinder then return end
    if not vec3 or not vec3.new then return end
    local p = vec3:new(pos.x, pos.y, pos.z)
    if pathfinder.request_move then
        pcall(pathfinder.request_move, p)
    elseif pathfinder.move_to_cpathfinder then
        pcall(pathfinder.move_to_cpathfinder, p)
    end
end

-- Abort any in-flight pathfinding.  Used when SilentRaven disables /
-- cancels mid-walk so the bot actually STOPS instead of carrying on
-- to its last requested goal.
M.stop_movement = function ()
    if pathfinder and pathfinder.clear_stored_path then
        pcall(pathfinder.clear_stored_path)
    end
end

-- 2D Euclidean distance from local player to a {x, y, z} position.
-- Returns math.huge on any failure (no player, no position).
M.player_dist_to_pos = function (pos)
    if not pos or type(get_local_player) ~= 'function' then return math.huge end
    local ok, player = pcall(get_local_player)
    if not ok then return math.huge end
    local point = safe_method(player, 'get_position')
    local x, y = safe_method(point, 'x'), safe_method(point, 'y')
    if not x or not y then return math.huge end
    return math.sqrt((pos.x - x)^2 + (pos.y - y)^2)
end

-- True when the host exposes the proper quest_reward API.  Checked once
-- per call so a host upgrade mid-run takes effect on the next attempt.
M.has_quest_reward_api = function ()
    return quest_reward ~= nil
        and type(quest_reward.is_open) == 'function'
        and type(quest_reward.enumerate) == 'function'
        and type(quest_reward.select) == 'function'
        and type(quest_reward.selected_index) == 'function'
        and type(quest_reward.accept) == 'function'
end

-- Diagnostic: dump every entry from quest_reward.enumerate() to console.
-- Triggered by the "Dump reward options" GUI keybind when the panel is
-- open -- useful for confirming the right Reward card index when D4
-- ships 3-5 choices that vary by season.
--
-- Output shape (one line per entry):
--   [SilentRaven/dump]  [<index>] sno=<hex>(<dec>) name=<internal_name> valid=<bool> [<-- SELECTED>]
--
-- Always safe to call: gracefully degrades when the host doesn't expose
-- quest_reward / individual sub-functions.  Not on a hot path -- only
-- fires on user keybind, never per-frame.
M.dump_rewards = function ()
    if not console or not console.print then return end
    local PFX = '[SilentRaven/dump] '

    if not quest_reward then
        console.print(PFX .. 'quest_reward API not exposed by this host')
        return
    end

    local open = false
    if type(quest_reward.is_open) == 'function' then
        local ok, ret = pcall(quest_reward.is_open)
        if ok then open = (ret == true) end
    end
    console.print(PFX .. 'panel open: ' .. tostring(open))

    local sel = -1
    if type(quest_reward.selected_index) == 'function' then
        local ok, ret = pcall(quest_reward.selected_index)
        if ok and type(ret) == 'number' then sel = ret end
    end
    console.print(PFX .. 'selected index: ' .. tostring(sel))

    if type(quest_reward.enumerate) ~= 'function' then
        console.print(PFX .. 'enumerate() not exposed; cannot list entries')
        return
    end
    local ok, entries = pcall(quest_reward.enumerate)
    if not ok or not entries then
        console.print(PFX .. 'enumerate() returned nothing')
        return
    end

    -- Sort keys so output is stable across calls.  Numeric keys first,
    -- then strings (defensive -- the API stub says number keys, but real
    -- hosts have surprised us before).
    local keys = {}
    for k, _ in pairs(entries) do keys[#keys + 1] = k end
    table.sort(keys, function (a, b)
        local na, nb = type(a) == 'number', type(b) == 'number'
        if na and nb then return a < b end
        if na ~= nb then return na end
        return tostring(a) < tostring(b)
    end)

    console.print(PFX .. 'enumerate() count: ' .. #keys)

    -- Lazy require so this still works if rewards.lua fails to load
    -- for any reason -- the basic field dump must always be available.
    local rewards_ok, rewards = pcall(require, 'silent_raven.rewards')

    for _, k in ipairs(keys) do
        local e = entries[k] or {}
        local sno_str = '?'
        if type(e.sno) == 'number' then
            sno_str = string.format('0x%X(%d)', e.sno, e.sno)
        elseif e.sno ~= nil then
            sno_str = tostring(e.sno)
        end
        local marker = (k == sel) and ' <-- SELECTED' or ''
        console.print(string.format('%s  [%s] sno=%s name=%s valid=%s%s',
            PFX, tostring(k), sno_str,
            tostring(e.internal_name or '?'),
            tostring(e.valid),
            marker))

        -- Slot + legendary verdict from the rewards classifier.  Gives
        -- the user immediate feedback on whether catalog/heuristic
        -- parsing is finding the right thing.
        if rewards_ok and rewards then
            local slot      = rewards.extract_slot(e)
            local legendary, evidence = rewards.is_legendary(e)
            local display   = rewards.display_name(e)
            console.print(string.format('%s        -> display="%s" slot=%s legendary=%s (%s)',
                PFX, display, slot, tostring(legendary), evidence))
        end

        -- Every field outside {sno, internal_name, valid}.  This is
        -- where we'll see any rarity / legendary / quality field the
        -- host exposes that the API stub didn't document.  If a field
        -- shows up here that we should be using for legendary
        -- detection, add it to rewards.is_legendary.
        local extras = {}
        for fk, fv in pairs(e) do
            if fk ~= 'sno' and fk ~= 'internal_name' and fk ~= 'valid' then
                extras[#extras + 1] = tostring(fk) .. '=' .. tostring(fv)
            end
        end
        if #extras > 0 then
            table.sort(extras)
            console.print(PFX .. '        extras: ' .. table.concat(extras, ', '))
        end
    end
end

-- Tri-state native panel read. Objective text cannot prove a UI is open.
M.reward_panel_open = function ()
    if not quest_reward or type(quest_reward.is_open) ~= 'function' then return nil end
    local ok, open = pcall(quest_reward.is_open)
    if not ok or type(open) ~= 'boolean' then return nil end
    return open
end

return M
