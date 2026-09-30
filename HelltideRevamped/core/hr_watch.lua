-- QQT_Warpigz_v3 3.3.3 (live: "just standing around waiting", "slow").
-- Bounds for the tasks/helltide.lua waits that had none:
--   * the walk-to-a-target states (ore, herb, shrine, goblin, silent chest,
--     chaos rift): given up after STALL_S without progress, or their cap;
--   * KILL_MONSTERS: a target that neither loses health nor gets closer
--     for KM_NO_EFFECT_S is ignored for KM_IGNORE_S;
--   * a pyre / pillar event: over once no monster was near it for
--     EVENT_QUIET_S (a spent one stays listed, non-interactable).
-- Reached through tracker.hr_watch (helltide.lua is at the local limit).
local M = {}

M.C = {
    MOVE_M = 4,           -- the player moved this far: progress
    STALL_S = 12,         -- no progress for this long: give the target up
    SKIP_S = 120,         -- a given-up target is not picked again for this long
    KM_NO_EFFECT_S = 15,  -- a kill target that takes no damage and gets no closer
    KM_PROGRESS_M = 2,
    KM_IGNORE_S = 60,
    EVENT_QUIET_S = 20,   -- no monster within EVENT_QUIET_R of the event
    EVENT_QUIET_R = 25,
}
-- Whole-state caps (seconds), progress or not.
M.LIMITS = {
    MOVING_TO_ORE = 30, MOVING_TO_HERB = 30, MOVING_TO_SHRINE = 30,
    CHASE_GOBLIN = 60, MOVING_TO_SILENT_CHEST = 45,
    MOVING_TO_CHAOS_RIFT = 45, INTERACT_CHAOS_RIFT = 45,
    STAY_NEAR_CHAOS_RIFT = 180,
}
-- States watched as one (review: INTERACT <-> STAY_NEAR bounced and reset
-- the record each time), and states that stand still by design (no stall).
M.GROUP = {MOVING_TO_CHAOS_RIFT = 'CHAOS_RIFT', INTERACT_CHAOS_RIFT = 'CHAOS_RIFT', STAY_NEAR_CHAOS_RIFT = 'CHAOS_RIFT'}
M.NO_STALL = {STAY_NEAR_CHAOS_RIFT = true}

local rec = nil      -- the watched target {state, key, t0, moved_t, anchor, hp}
local skips = {}     -- key -> until
local km = {}        -- key -> {hp, d, t}
local km_count = 0
local quiet_since = nil

local function call(obj, name)
    local fn = obj and obj[name]
    if type(fn) ~= 'function' then return nil end
    local ok, v = pcall(fn, obj)
    if ok then return v end
    return nil
end

-- A stable key: the actor id, else skin + 1 m cell.
function M.key(actor, fallback)
    if not actor then return fallback end
    local id = call(actor, 'get_id')
    local skin = call(actor, 'get_skin_name') or '?'
    if type(id) == 'number' then return skin .. '#' .. id end
    local pos = call(actor, 'get_position')
    if not pos then return fallback or skin end
    return string.format('%s_%d_%d', skin, math.floor(pos:x()), math.floor(pos:y()))
end

function M.skip(key, now, secs)
    if key then skips[key] = now + (secs or M.C.SKIP_S) end
end

function M.skipped(key, now)
    local u = key and skips[key]
    if not u then return false end
    if now < u then return true end
    skips[key] = nil
    return false
end

-- One tick of `state` working on target `key` (hp: its health, or nil).
-- nil to go on, else the reason to give it up.
function M.watch(state, key, now, pos, hp)
    local limit = M.LIMITS[state]
    if not limit then
        rec = nil
        return nil
    end
    local group = M.GROUP[state] or state
    if not rec or rec.group ~= group or rec.key ~= key then
        rec = {group = group, key = key, t0 = now, moved_t = now, anchor = pos, hp = hp}
        return nil
    end
    -- a group's cap is its longest member's
    if M.GROUP[state] then limit = M.LIMITS.STAY_NEAR_CHAOS_RIFT end
    if pos and (not rec.anchor or pos:dist_to(rec.anchor) >= M.C.MOVE_M) then
        rec.anchor, rec.moved_t = pos, now
    end
    if type(hp) == 'number' then
        if type(rec.hp) == 'number' and hp < rec.hp - 0.5 then rec.moved_t = now end
        if type(rec.hp) ~= 'number' or hp < rec.hp then rec.hp = hp end
    end
    if M.NO_STALL[state] then rec.moved_t = now end
    if now - rec.moved_t >= M.C.STALL_S then
        return string.format('no progress for %ds', M.C.STALL_S)
    end
    if now - rec.t0 >= limit then
        return string.format('not done in %ds', limit)
    end
    return nil
end

function M.clear()
    rec = nil
end

-- KILL_MONSTERS: true once `actor` took no damage and got no closer for
-- KM_NO_EFFECT_S; it is then ignored (km_ignored) for KM_IGNORE_S.
function M.km_no_effect(actor, now, d)
    local key = M.key(actor)
    if not key then return false end
    if M.skipped('km:' .. key, now) then return true end
    local hp = call(actor, 'get_current_health')
    local e = km[key]
    if not e then
        if km_count > 200 then km, km_count = {}, 0 end
        km[key], km_count = {hp = hp, d = d, t = now}, km_count + 1
        return false
    end
    if (type(hp) == 'number' and type(e.hp) == 'number' and hp < e.hp - 0.5)
        or (type(d) == 'number' and type(e.d) == 'number' and d < e.d - M.C.KM_PROGRESS_M)
        or now < e.t then
        e.hp, e.d, e.t = hp, d, now
        return false
    end
    if now - e.t < M.C.KM_NO_EFFECT_S then return false end
    km[key], km_count = nil, km_count - 1
    M.skip('km:' .. key, now, M.C.KM_IGNORE_S)
    return true, key
end

function M.km_ignored(actor, now)
    if not next(skips) then return false end
    return M.skipped('km:' .. (M.key(actor) or '?'), now)
end

-- Pyre / pillar event: true once no living monster was within
-- EVENT_QUIET_R of pos for EVENT_QUIET_S.
function M.event_quiet(pos, now)
    local busy = false
    local ok, list = pcall(function() return target_selector.get_near_target_list(pos, M.C.EVENT_QUIET_R) end)
    if ok and type(list) == 'table' then
        for _, enemy in pairs(list) do
            local hp = call(enemy, 'get_current_health')
            if hp == nil or hp > 1 then busy = true break end
        end
    else
        busy = true -- unreadable: the old 240 s cap still applies
    end
    if busy or (quiet_since and now < quiet_since) then
        quiet_since = nil
        return false
    end
    quiet_since = quiet_since or now
    return now - quiet_since >= M.C.EVENT_QUIET_S
end

function M.event_reset()
    quiet_since = nil
end

-- C5: a yield never counts toward these bounds.
function M.credit(gap)
    if rec then rec.t0, rec.moved_t = rec.t0 + gap, rec.moved_t + gap end
    for _, e in pairs(km) do e.t = e.t + gap end
    if quiet_since then quiet_since = quiet_since + gap end
end

function M.reset()
    rec, skips, km, km_count, quiet_since = nil, {}, {}, 0, nil
end

return M
