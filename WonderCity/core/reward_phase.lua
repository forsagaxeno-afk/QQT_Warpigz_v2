local tracker = require 'core.tracker'
local utils = require 'core.utils'
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
        local read, name, boss, health = pcall(function()
            local skin = actor:get_skin_name()
            local is_boss = boss_names[skin] or (actor.is_boss and actor:is_boss())
            return skin, is_boss, is_boss and actor:get_current_health() or nil
        end)
        if not read then return end -- incomplete enumeration is not kill evidence
        if type(name) == 'string' and name:match('^X1_Undercity_Chest_Attunement') then
            reward_seen = true
            chest_actor = chest_actor or actor
        end
        if boss and type(health) == 'number' then
            if health > 0 then alive_boss = true elseif health == 0 then dead_boss = true end
            if boss_name == nil or health > 0 then boss_name, boss_health = name, health end
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
        console.print(string.format('[WonderCity:finish] boss death observed (%s, zone %s); waiting for reward chest',
            tostring(boss_name), tostring(select(2, pcall(function() return get_current_world():get_current_zone_name() end)))))
    end
    if tracker.boss_kill_time and not reward_seen and not tracker.reward_seen and not tracker.done
        and now - tracker.boss_kill_time >= NO_CHEST_AFTER_KILL then
        console.print(string.format('[WonderCity:finish] no reward chest %ds after the death of %s — not the district boss; continuing the run',
            NO_CHEST_AFTER_KILL, tostring(tracker.last_boss_name)))
        tracker.boss_kill_time, tracker.reward_grace_until = nil, nil
        tracker.kill_dismissed_at = now
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

reward_phase.can_exit = function ()
    if not tracker.done then return false end
    if utils.is_looting() then
        tracker.loot_quiet_since = nil
        return false
    end
    local now = get_time_since_inject()
    tracker.loot_quiet_since = tracker.loot_quiet_since or now
    return now - tracker.loot_quiet_since >= LOOT_QUIET_SECONDS
end

return reward_phase
