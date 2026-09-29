local tracker = require 'core.tracker'
local utils = require 'core.utils'
local events = require 'core.qqt_events' -- QQT_Warpigz_v3
local reward_phase = {}
local LOOT_QUIET_SECONDS = 3
local REWARD_GRACE_SECONDS = 45
local CHEST_GONE_SECONDS, CHEST_GONE_RANGE = 20, 20
-- R14: a burst of at least LOOT_BURST new (non-obol) ground items within
-- LOOT_NEAR_RANGE of the reward chest, first seen within LOOT_BURST_WINDOW,
-- after the chest was first seen: it (or the boss beside it) dropped the
-- reward. A single drop from a mob killed next to the chest is not a burst.
local LOOT_NEAR_RANGE, LOOT_BURST, LOOT_BURST_WINDOW, LOOT_CHECK_INTERVAL = 5, 2, 3, 0.5
-- R14: a dead boss counts as an observed kill only if a live boss was seen
-- at most KILL_LINK_SECONDS earlier (a corpse entering the stream is not).
local KILL_LINK_SECONDS = 5
-- Live 2.1.2: WonderCity stood still on floor 1 "waiting for reward chest".
-- A boss/miniboss corpse on a floor without the reward chest must not park
-- the run until its timeout: with no reward chest seen for this long after
-- the death, the reward phase is dropped (logged) and the run continues. The
-- same corpse never re-arms it; a new live -> dead kill does.
local NO_CHEST_AFTER_KILL = 30

-- Match only actors already known to this runner. Other bosses can still be
-- recognized by the documented is_boss() API. Never retain actor handles.
local boss_names = {
    S11_Andariel_Boss_KUC = true,
    X1_Undercity_Ghost_Caster_Miniboss = true,
    X1_Undercity_Lacuni_Boss = true,
    X1_Undercity_Snake_Brute_Miniboss = true,
}

local function is_obols(item)
    local ok, obols = pcall(function()
        if loot_manager.is_obols then return loot_manager.is_obols(item) end
        local info = item:get_item_info()
        local name = info and info:get_display_name()
        return type(name) == 'string' and name:match('[Oo]bol') ~= nil
    end)
    return not ok or (obols and true or false) -- unreadable: never evidence
end

local function watch_loot(now)
    if tracker.done or tracker.chest_loot_seen or not tracker.chest_last_pos then return end
    if tracker.chest_loot_checked and now - tracker.chest_loot_checked < LOOT_CHECK_INTERVAL then return end
    tracker.chest_loot_checked = now
    local ok, items = pcall(actors_manager.get_all_items)
    if not ok or type(items) ~= 'table' then return end
    local base, ids, fresh, chest = tracker.chest_items_base, {}, 0, tracker.chest_last_pos
    for _, item in pairs(items) do
        local read, id, near = pcall(function()
            local pos = item:get_position()
            return item:get_id(), (pos:x() - chest:x())^2 + (pos:y() - chest:y())^2 <= LOOT_NEAR_RANGE^2
        end)
        if not read or type(id) ~= 'number' then return end -- incomplete: no baseline, no evidence
        ids[id] = true
        if base and not base[id] and near and not is_obols(item) then fresh = fresh + 1 end
    end
    if not base then tracker.chest_items_base = ids; return end
    for id in pairs(ids) do base[id] = true end
    if fresh == 0 then return end
    local recent, burst = tracker.chest_loot_recent or {}, 0
    tracker.chest_loot_recent = recent
    for _ = 1, fresh do recent[#recent + 1] = now end
    for _, t in ipairs(recent) do if now - t <= LOOT_BURST_WINDOW then burst = burst + 1 end end
    if burst >= LOOT_BURST then
        tracker.chest_loot_seen = now
        console.print(string.format('[WonderCity:finish] %d new items dropped within %dm of the reward chest', burst,
            LOOT_NEAR_RANGE))
    end
end

reward_phase.observe = function ()
    if not utils.player_in_undercity() then return end
    local ok, actors = pcall(actors_manager.get_all_actors)
    if not ok or type(actors) ~= 'table' then return end
    local dead_boss, alive_boss, reward_seen = false, false, false
    local chest_actor, boss_name, boss_health = nil, nil, nil
    for _, actor in pairs(actors) do
        local read, name, boss, health, pos = pcall(function()
            local skin = actor:get_skin_name()
            local is_boss = boss_names[skin] or (actor.is_boss and actor:is_boss())
            local hp = is_boss and actor:get_current_health() or nil
            -- QQT_Warpigz_v3 WonderCity 2.2.7 (W4): where the boss fell.
            return skin, is_boss, hp, is_boss and actor:get_position() or nil
        end)
        if not read then return end -- incomplete enumeration is not kill evidence
        if type(name) == 'string' and name:match('^X1_Undercity_Chest_Attunement') then
            reward_seen = true
            chest_actor = chest_actor or actor
        end
        if boss and type(health) == 'number' then
            if health > 0 then alive_boss = true elseif health == 0 then dead_boss = true end
            if boss_name == nil or health > 0 then boss_name, boss_health = name, health end
            if pos then tracker.boss_last_pos = pos end -- QQT_Warpigz_v3 WonderCity 2.2.7 (W4)
        end
    end
    -- R14 (complete scans only): first sight of the reward chest, the last
    -- boss seen, and a kill we actually observed (a live boss shortly before,
    -- a dead one and no live one now). A corpse alone is not an observed kill.
    local now = get_time_since_inject()
    if chest_actor and not tracker.chest_first_seen then tracker.chest_first_seen = now end
    if boss_name then
        tracker.last_boss_name, tracker.last_boss_health, tracker.last_boss_at = boss_name, boss_health, now
    end
    if alive_boss then
        tracker.boss_alive_at = now
    elseif dead_boss and tracker.boss_alive_at and now - tracker.boss_alive_at <= KILL_LINK_SECONDS
        and not (tracker.boss_kill_seen and tracker.boss_kill_seen >= tracker.boss_alive_at) then
        tracker.boss_kill_seen = now
    end
    tracker.boss_alive = alive_boss
    if alive_boss then return end
    local dismissed = tracker.kill_dismissed_at ~= nil
        and (tracker.boss_alive_at == nil or tracker.boss_alive_at <= tracker.kill_dismissed_at)
    if dead_boss and not tracker.boss_kill_time and not dismissed then
        tracker.boss_kill_time = get_time_since_inject()
        tracker.kill_dismissed_at = nil
        events.emit('wondercity', 'boss_killed', {name = boss_name}) -- QQT_Warpigz_v3
        console.print(string.format('[WonderCity:finish] boss death observed (%s, zone %s); waiting for reward chest',
            tostring(boss_name), tostring(select(2, pcall(function() return get_current_world():get_current_zone_name() end)))))
    end
    if tracker.boss_kill_time and not reward_seen and not tracker.reward_seen and not tracker.done
        and now - tracker.boss_kill_time >= NO_CHEST_AFTER_KILL then
        console.print(string.format('[WonderCity:finish] no reward chest %ds after the death of %s — not the district boss; continuing the run',
            NO_CHEST_AFTER_KILL, tostring(tracker.last_boss_name)))
        tracker.boss_kill_time, tracker.reward_grace_until = nil, nil
        tracker.kill_dismissed_at = now
        -- QQT_Warpigz_v3: the next live boss gets its own first sight and
        -- boss_delay; the dead one no longer holds the explorers.
        tracker.boss_trigger_time, tracker.boss_seen_at = nil, nil
    end
    if reward_seen and not tracker.reward_seen then
        tracker.reward_seen = true
        local read, chest_name = pcall(function() return chest_actor:get_skin_name() end)
        console.print('[WonderCity:finish] reward chest observed in all-actor list (' .. tostring(read and chest_name) .. ')')
    end
    -- Complete, readable scans only (every failure path returned above).
    if chest_actor then
        local read, pos = pcall(function() return chest_actor:get_position() end)
        tracker.chest_last_seen, tracker.chest_gone_since = now, nil
        if read and pos then tracker.chest_last_pos = pos end
    elseif tracker.chest_last_seen then
        tracker.chest_gone_since = tracker.chest_gone_since or now
        tracker.chest_gone_checked = now
    end
    if (dead_boss or reward_seen) and not tracker.reward_grace_until then
        tracker.reward_grace_until = get_time_since_inject() + REWARD_GRACE_SECONDS
    end
    watch_loot(now)
end

reward_phase.active = function ()
    return tracker.boss_kill_time ~= nil or tracker.reward_seen or tracker.done
end

reward_phase.mark_opened = function (reason)
    if not tracker.done then events.emit('wondercity', 'undercity_reward', {reason = reason}) end -- QQT_Warpigz_v3
    tracker.done = true -- reward opened; not permission for an immediate exit
    tracker.reward_opened_time = get_time_since_inject()
    tracker.loot_quiet_since = nil
    tracker.completion_reason = reason
    console.print('[WonderCity:finish] reward opening confirmed: ' .. reason)
end

-- CRT-1: the reward chest we saw is gone from complete, readable actor
-- scans for CHEST_GONE_SECONDS while the player stands near where it was
-- (opened by the player/a companion, or replaced after opening). Only then
-- does its disappearance complete the reward phase without our own click.
reward_phase.chest_vanished = function ()
    if tracker.done or not tracker.reward_seen or not tracker.chest_gone_since or tracker.boss_alive then return false end
    if (tracker.chest_gone_checked or 0) - tracker.chest_gone_since < CHEST_GONE_SECONDS then return false end
    local player = get_local_player()
    local ok, near = pcall(function()
        return tracker.chest_last_pos ~= nil and utils.distance(player, tracker.chest_last_pos) <= CHEST_GONE_RANGE
    end)
    return ok and near == true
end

-- QQT_Warpigz_v3 WonderCity 2.2.7 (W4, sweep S3 F4/F5): reward loot the
-- Looter wants (evaluate_item(item, true)) within REWARD_LOOT_RANGE m of the
-- reward chest or the boss, but beyond its own pickup distance, was left at
-- the exit (only 3 s of loot quiet were needed). Such an item now holds the
-- exit and tasks/loot_reward walks to it (within REWARD_LOOT_REACH m); after
-- a death it walks back to the chest first. Bounded: REWARD_LOOT_CAP s from
-- the reward opening (one log line), and an item (or the walk back) without
-- REWARD_LOOT_STEP m of progress for REWARD_LOOT_STALL s is skipped.
local RL = {RANGE = 12, CAP = 25, STALL = 5, STEP = 0.5, REACH = 1.5}
reward_phase.REWARD_LOOT = RL
local rloot = {key = nil, skipped = {}, capped = false}
local function rloot_state()
    local key = tostring(tracker.floor_generation) .. '|' .. tostring(tracker.reward_opened_time)
    if rloot.key ~= key then
        rloot.key, rloot.skipped, rloot.capped = key, {}, false
        rloot.target, rloot.best, rloot.best_at = nil, nil, nil
    end
    return rloot
end
reward_phase.reward_loot_state = rloot_state
local function near2(pos, anchor)
    return anchor ~= nil and (pos:x() - anchor:x())^2 + (pos:y() - anchor:y())^2 <= RL.RANGE^2
end
-- Returns the wanted reward item (or, after a death, the chest position to
-- walk back to) and its key, or nil.
reward_phase.reward_loot_target = function ()
    if not tracker.done or not tracker.reward_opened_time or not utils.player_in_undercity() then return nil end
    local looter = LooteerPlugin
    if type(looter) ~= 'table' or type(looter.evaluate_item) ~= 'function' then return nil end
    local state, now = rloot_state(), get_time_since_inject()
    if now - tracker.reward_opened_time > RL.CAP then
        if not state.capped then
            state.capped = true
            if state.target ~= nil then
                console.print(string.format('[WonderCity:finish] reward loot not picked up within %ds - exiting anyway', RL.CAP))
            end
        end
        return nil
    end
    local player = get_local_player()
    if not player then return nil end
    local chest, boss = tracker.chest_last_pos, tracker.boss_last_pos
    local ok, best, best_key = pcall(function()
        local pp, found, found_key, found_d = player:get_position(), nil, nil, nil
        for _, item in pairs(actors_manager.get_all_items() or {}) do
            local pos = item:get_position()
            local key = string.format('item:%.1f:%.1f', pos:x(), pos:y()) -- position: ground items may have no id
            if not state.skipped[key] and (near2(pos, chest) or near2(pos, boss)) and not is_obols(item)
                and looter.evaluate_item(item, true) == true then
                local d = (pos:x() - pp:x())^2 + (pos:y() - pp:y())^2
                if found_d == nil or d < found_d then found, found_key, found_d = item, key, d end
            end
        end
        if found == nil and chest ~= nil and not state.skipped.chest and not near2(pp, chest) then
            return chest, 'chest' -- a death: back to the chest, its loot may be out of view
        end
        return found, found_key
    end)
    if not ok then return nil end
    return best, best_key
end
reward_phase.pending_loot = function ()
    return reward_phase.reward_loot_target() ~= nil
end

reward_phase.can_exit = function ()
    if not tracker.done then return false end
    if utils.is_looting() then
        tracker.loot_quiet_since = nil
        return false
    end
    if reward_phase.pending_loot() then -- QQT_Warpigz_v3 WonderCity 2.2.7 (W4)
        tracker.loot_quiet_since = nil
        return false
    end
    local now = get_time_since_inject()
    tracker.loot_quiet_since = tracker.loot_quiet_since or now
    return now - tracker.loot_quiet_since >= LOOT_QUIET_SECONDS
end

return reward_phase
