-- QQT_Warpigz_v3 (rc.2, Q3, live: "when farming tears, running after the
-- loot is dumb - loot once the whole event is over: the Realmwalker killed,
-- or no Realmwalker within 10 seconds after the rift completes").
--
-- Before this, Rosie's pickup was paused only while a tear was engaged
-- (core/hr_tear_stand.lua, Q2). Between two tears, while the cultists died,
-- in the linger after the last tear and during the whole Realmwalker wait and
-- fight, every accepted drop in range made Rosie walk off and HR yield to it
-- (tasks/helltide.lua loot_hold). rc.1 did not pause pickup at all.
--
-- Two parts, both per rupture. Their state lives in the hr_tear_event
-- session, so every way out of a rupture (resume_patrol, reset, a fresh
-- engage) ends them.
--
-- 1. Event gate. Rosie's pickup stays paused (caller 'HelltideRevamped',
--    through hr_tear_stand.sync_pause, refreshed every 5 s; Rosie drops a
--    foreign pause after 60 s without a refresh) from the player's arrival
--    at the rupture until the event is over, and only while the player is
--    at the event (QQT_Warpigz_v3 rc.2 review: the walk there, a revive
--    walk-back and the town are never paused, so nothing Rosie would take
--    outside the event area is lost):
--      * the Realmwalker was defeated (RIFT_KILL_REALMWALKER);
--      * or no Realmwalker showed up within RW_ABSENT_S after the rupture
--        completed (RIFT_WAIT_REALMWALKER; the 'Realmwalker wait' slider
--        caps it when it is shorter);
--      * or the rupture completed without a Realmwalker chain (a Normal or
--        unconfirmed rupture, or 'Realmwalker' off).
--    A Realmwalker that shows up later while HR still waits for it gates
--    the fight again. C6: at most PAUSE_MAX_S for the tears and
--    RW_CHAIN_MAX_S for the Realmwalker chain (wall time, never credited).
--    hr_tear_event.sync_holds releases it on every exit (rupture
--    left or abandoned, reset/zone change, Helltide end, Warplan) and
--    release_holds on disable/suspend/task switch and death; a reloaded HR
--    drops a pause left by the previous load (hr_tear_stand). The Deathtoll
--    Chamber is not gated (only the Q2 per-tear pause applies there).
-- 2. Loot window. The drops stayed where they fell (tears, ring, chest,
--    Realmwalker). Before HR leaves, it walks to each drop that Rosie wants
--    (LooteerPlugin.evaluate_item, distance ignored) inside the event area.
--    Rosie takes it as soon as it is within her pickup distance (HR's
--    loot_hold yields while she is busy). Bounded: ITEM_MAX_S per drop,
--    APPROACH_NO_PROGRESS_S without getting closer, WINDOW_MAX_S in all
--    (handler time, like the other rupture timers) and WINDOW_WALL_MAX_S
--    wall time. No window when the pause was never held (no Rosie-shaped
--    Looter, or its pickup is off).
local utils = require "core.utils"

local M = {}

local C = {
    RW_ABSENT_S = 10,          -- no Realmwalker this long after completion: the event is over
    PAUSE_MAX_S = 300,         -- C6: pause per rupture (tears), wall time
    -- QQT_Warpigz_v3 (rc.2 review): the Realmwalker chain (wait + fight +
    -- portal) has its own bound: hr_tear_event C.RW_CHAIN_MAX_S (handler
    -- time) and the gate's second phase (wall time) both use this.
    RW_CHAIN_MAX_S = 180,
    -- QQT_Warpigz_v3 (rc.2 review): the pause holds only while the player is
    -- at the event. A ring with open tears is engaged from up to
    -- tear_search_dist (110 m) and a revive walks back from the checkpoint:
    -- Rosie keeps taking what she passes there (the loot window below only
    -- covers the event area).
    ARRIVE_PAD = 10,           -- the gate opens within tear_event_radius + this of the ring
    HOLD_PAD = 32,             -- held within tear_event_radius + this (tears are engaged up to r + 30) ...
    HOLD_HYST = 4,             -- ... left only beyond + this (inside AREA_PAD: every held drop is walked to)
    RW_HOLD_M = 16,            -- ... or this close to the Realmwalker (the fight stops at 14 m)
    SETTLE_S = 1.5,            -- drops land a moment after the kill; Rosie starts within a frame
    SCAN_TTL = 0.5,
    AREA_PAD = 40,             -- event area: tear_event_radius + this around the ring ...
    AROUND_M = 20,             -- ... and this around the Realmwalker and where the window started
    ITEM_REACH = 1.5,          -- standing this close and Rosie still idle: she does not take it now
    ITEM_DWELL_S = 1.5,
    ITEM_MAX_S = 10,
    APPROACH_NO_PROGRESS_S = 5,
    APPROACH_PROGRESS_M = 1,
    WINDOW_MAX_S = 45,         -- handler time
    WINDOW_WALL_MAX_S = 90,    -- C6 hard bound
}
M.C = C

local GATED_OFF = { -- the Deathtoll Chamber is its own run (Q2 per-tear pause only)
    RIFT_ENTER_CHAMBER = true, CHAMBER_START_RITUAL = true, CHAMBER_CLOSE_TEARS = true,
    CHAMBER_STAY_ACTIVE = true, CHAMBER_EXIT = true,
}

local function log(msg) console.print(msg) end

-- ── event gate ─────────────────────────────────────────────────────────────
local RW_STATES = { RIFT_WAIT_REALMWALKER = true, RIFT_KILL_REALMWALKER = true } -- QQT_Warpigz_v3

local function player_dist(pos) -- QQT_Warpigz_v3 (rc.2 review)
    if not pos then return math.huge end
    local ok, d = pcall(utils.distance_to, pos)
    return (ok and type(d) == 'number') and d or math.huge
end

-- True while Rosie's pickup should stay paused for the rupture in `s`
-- (the caller checks that the state is a rupture state in Farm mode).
-- QQT_Warpigz_v3 (rc.2 review): r (tear_event_radius) turns on the "at the
-- event" checks: the gate opens on arrival (within r + ARRIVE_PAD of the
-- ring, or at_tear: standing at an engaged tear) and holds only inside
-- r + HOLD_PAD of the ring (or next to the Realmwalker); a walk there, a
-- revive walk-back or a chase further out leaves Rosie looting (g.away).
function M.gate_wants(s, state, t, r, at_tear)
    if GATED_OFF[state] or s.chamber_anchor then return false end
    local g = s.loot_gate
    local d = r and player_dist(s.anchor) or 0
    if not g then
        if state == 'MOVING_TO_RIFT' then return false end -- the Looter keeps looting on the way
        if r and not at_tear and d > r + C.ARRIVE_PAD then return false end -- QQT_Warpigz_v3: not there yet
        g = { opened_at = t }
        s.loot_gate = g
    end
    if g.expired then return false end
    if t < g.opened_at then g.opened_at = t end
    -- QQT_Warpigz_v3 (rc.2 review): the Realmwalker chain is its own phase.
    if g.rw_at and t < g.rw_at then g.rw_at = t end
    local since, cap = g.opened_at, C.PAUSE_MAX_S
    if g.rw_at then since, cap = g.rw_at, C.RW_CHAIN_MAX_S end
    if t - since >= cap then
        g.expired = true
        log(string.format('[RIFT] %s still running after %ds — Looter pickup resumes (pause cap)',
            g.rw_at and 'Realmwalker chain' or 'Tear event', cap)) -- QQT_Warpigz_v3
        return false
    end
    local want
    if state == 'RIFT_KILL_REALMWALKER' then want = s.rw_kill_done_at == nil else want = s.loot_window == nil end
    if not want or not r or at_tear then
        if want then g.away = nil end
        return want
    end
    -- QQT_Warpigz_v3 (rc.2 review): only while the player is at the event.
    local near = d <= r + C.HOLD_PAD + (g.away and 0 or C.HOLD_HYST)
    if not near and RW_STATES[state] and s.rw_anchor then
        near = player_dist(s.rw_anchor) <= C.RW_HOLD_M + (g.away and 0 or C.HOLD_HYST)
    end
    g.away = not near or nil
    return near
end

-- QQT_Warpigz_v3 (rc.2 review): the rupture completed and the Realmwalker
-- chain starts; the gate's clock restarts with its own bound.
function M.rw_chain(s, t)
    local g = s and s.loot_gate
    if g and not g.expired and not g.rw_at then g.rw_at = t end
end

-- QQT_Warpigz_v3 (rc.2 review): the player left the event area with the
-- gate still open (the release line names it).
function M.away(s)
    local g = s and s.loot_gate
    return g ~= nil and g.away == true and not g.expired
end

-- The pause was really held for this rupture (drops were left on the ground).
function M.note_held(s)
    if s.loot_gate then s.loot_gate.held = true end
end

-- Why the event is over (the window's reason), else nil.
function M.over_reason(s)
    return s.loot_window and s.loot_window.why or nil
end

-- A Realmwalker showed up after the window started: its fight is gated again
-- and a new window runs after it.
function M.interrupt(s)
    s.loot_window = nil
end

-- Rerouted to another rupture in the same session: it gets its own gate.
function M.reset(s)
    s.loot_gate, s.loot_window = nil, nil
end

function M.collecting(s)
    return s.loot_window ~= nil and not s.loot_window.done
end

function M.done(s)
    return s.loot_window ~= nil and s.loot_window.done == true
end

-- C5: a yield never counts toward the window's handler-time bounds.
function M.credit(s, gap)
    local w = s and s.loot_window
    if not w or w.done then return end
    for _, k in ipairs({ 'started', 'item_t', 'best_t', 'near_t' }) do
        if type(w[k]) == 'number' then w[k] = w[k] + gap end
    end
end

-- ── loot window ────────────────────────────────────────────────────────────
local function looter()
    local l = rawget(_G, 'LooteerPlugin')
    return type(l) == 'table' and l or nil
end

local function looter_on()
    local l = looter()
    if not l then return false end
    if type(l.get_enabled) == 'function' then
        local ok, on = pcall(l.get_enabled)
        if ok and on == false then return false end
    end
    return true
end

local function mcall(obj, method)
    if obj == nil then return nil end
    local ok, v = pcall(function() return obj[method](obj) end)
    if ok then return v end
    return nil
end

local function item_key(item, pos)
    local id = mcall(item, 'get_id')
    if type(id) == 'number' then return 'id' .. id end
    return string.format('%d_%d', math.floor(pos:x()), math.floor(pos:y()))
end

local function pdist(a, b)
    if not a or not b then return math.huge end
    local ok, d = pcall(function() return a:dist_to(b) end)
    return (ok and type(d) == 'number') and d or math.huge
end

local function wanted(item)
    local l = looter()
    if not l then return false end
    if type(l.evaluate_item) == 'function' then
        local ok, want = pcall(l.evaluate_item, item, true)
        return ok and want == true
    end
    -- A Looter without evaluate_item: anything but gold and potions.
    local lm = rawget(_G, 'loot_manager')
    if type(lm) == 'table' then
        for _, fn in ipairs({ 'is_gold', 'is_potion' }) do
            if type(lm[fn]) == 'function' then
                local ok, yes = pcall(lm[fn], item)
                if ok and yes == true then return false end
            end
        end
    end
    return true
end

local function in_area(w, pos)
    if w.anchor and pdist(w.anchor, pos) <= w.radius then return true end
    if w.rw_pos and pdist(w.rw_pos, pos) <= C.AROUND_M then return true end
    return w.start_pos ~= nil and pdist(w.start_pos, pos) <= C.AROUND_M
end

-- Nearest wanted drop in the event area that was not given up (scanned at
-- most every SCAN_TTL; the current target is kept while it is listed).
local function pick_target(w, t)
    if w.scan_t and t - w.scan_t < C.SCAN_TTL and w.target then return w.target, w.target_key, w.target_pos end
    w.scan_t = t
    local am = rawget(_G, 'actors_manager')
    local ok, items = pcall(function() return am.get_all_items() end)
    if not ok or type(items) ~= 'table' then return nil end
    local keep, best, best_key, best_pos, best_d = nil, nil, nil, nil, math.huge
    for _, item in pairs(items) do
        local pos = mcall(item, 'get_position')
        if pos and in_area(w, pos) then
            local key = item_key(item, pos)
            if not w.gave_up[key] and wanted(item) then
                if key == w.target_key then keep = item end
                local ok_d, d = pcall(utils.distance_to, pos)
                d = (ok_d and type(d) == 'number') and d or math.huge
                if d < best_d then best, best_key, best_pos, best_d = item, key, pos, d end
            end
        end
    end
    if keep then return keep, w.target_key, mcall(keep, 'get_position') or w.target_pos end
    return best, best_key, best_pos
end

local function finish(w, t, why)
    w.done = true
    log(string.format('[RIFT] Tear event loot: %d drop(s) walked to, %d given up, %.0fs%s — moving on',
        w.walked, w.given_up, t - w.wall, why and (' (' .. why .. ')') or ''))
    return false
end

local function give_up(w, why)
    if w.target_key then
        w.gave_up[w.target_key] = true
        w.given_up = w.given_up + 1
        if why then log('[RIFT] Event loot: leaving a drop — ' .. why) end
    end
    w.target, w.target_key, w.target_pos = nil, nil, nil
    w.item_t, w.best_d, w.best_t, w.near_t = nil, nil, nil, nil
end

-- One tick of the post-event loot window. Starts it on the first call.
-- ctx: anchor, radius (event area), rw_pos, move_to(pos, precise), clear().
-- Returns true while collecting (the caller returns), false once done or
-- when no window is needed.
function M.collect(s, t, why, ctx)
    local w = s.loot_window
    if w and w.done then return false end
    if not w then
        local g = s.loot_gate
        w = { started = t, wall = t, why = why, gave_up = {}, walked = 0, given_up = 0,
            anchor = ctx.anchor, radius = ctx.radius, rw_pos = ctx.rw_pos }
        local ok, p = pcall(get_player_position)
        w.start_pos = ok and p or nil
        s.loot_window = w
        if not (g and g.held) or not looter_on() then
            w.done = true -- nothing was held back
            return false
        end
        log(string.format('[RIFT] Tear event over (%s) — collecting its loot before moving on', tostring(why)))
    end
    if t - w.started >= C.WINDOW_MAX_S or t - w.wall >= C.WINDOW_WALL_MAX_S then
        ctx.clear() -- no walk to a stale drop position after the window
        return finish(w, t, 'time cap')
    end
    if t - w.started < C.SETTLE_S then
        ctx.clear()
        return true
    end
    local item, key, pos = pick_target(w, t)
    if not item or not pos then
        if w.target_key then w.walked = w.walked + 1 end -- the last target was taken
        ctx.clear()
        return finish(w, t, nil)
    end
    if key ~= w.target_key then
        if w.target_key then w.walked = w.walked + 1 end -- the previous one was taken
        w.target, w.target_key, w.target_pos = item, key, pos
        w.item_t, w.best_d, w.best_t, w.near_t = t, nil, nil, nil
    end
    w.target_pos = pos
    local ok_d, d = pcall(utils.distance_to, pos)
    d = (ok_d and type(d) == 'number') and d or math.huge
    if t - w.item_t >= C.ITEM_MAX_S then
        give_up(w, string.format('not taken within %ds', C.ITEM_MAX_S))
        return true
    end
    if d <= C.ITEM_REACH then
        -- On it and Rosie is still idle (her loot_hold would have yielded):
        -- she does not take it now (bag full, filter changed, ...).
        ctx.clear()
        w.near_t = w.near_t or t
        if t - w.near_t >= C.ITEM_DWELL_S then give_up(w, nil) end
        return true
    end
    if not w.best_d or d < w.best_d - C.APPROACH_PROGRESS_M then
        w.best_d, w.best_t = d, t
    elseif t - w.best_t >= C.APPROACH_NO_PROGRESS_S then
        give_up(w, string.format('no progress towards it for %ds (dist=%.1f)', C.APPROACH_NO_PROGRESS_S, d))
        return true
    end
    ctx.move_to(pos, d <= 6)
    return true
end

return M
