-- QQT_Warpigz_v3 (rc.2, live: "the bot barely stands in the tears").
-- Standing in Helltide tears (Pandemonium rupture tears, core/hr_tear_event.lua).
--
-- A tear closes while the player stands inside its golden circle and enemies
-- die there. The rc.1 machine left a tear long before that:
--   * every tear it saw started a 12 s "static" clock (position and charge
--     unchanged), so the tears it was NOT standing in were skipped for 45 s
--     while it worked on the first one, and the one it stood in was skipped
--     too when the charge read nil or did not change;
--   * the focused tear was dropped 18 s after it was first chosen (walk
--     included), "not closing — trying next glint";
--   * with every tear skipped the rupture counted as complete after the 5 s
--     linger and its area was blacklisted for 120 s;
--   * a charge of 0.99 or more read as "closed", so on a 0-100 charge scale
--     every tear counted as closed at 1 % (see charge_full);
--   * a tear 25-30 m from the ritual anchor bounced RIFT_CLOSE_TEARS /
--     RIFT_STAY_ACTIVE every tick without being approached;
--   * a chest in reach (Pandemonium or cinder chest) and Rosie's pickup pulled
--     the player out of the circle mid-tear.
-- Now the engaged tear is kept until it closes, and only inside-the-circle
-- time counts toward its bounds (C6): INSIDE_MAX_S inside, STATIC_INSIDE_S
-- without charge/health progress once that reading has been seen to change,
-- APPROACH_NO_PROGRESS_S without getting closer, ENGAGED_MAX_S in all. The
-- rupture itself keeps its own cap (hr_tear_event C.RUPTURE_MAX_S).
--
-- While a tear is engaged (QQT_Warpigz_v3 rc.2 review: and the player is at
-- it, M.at_tear), Rosie's pickup is paused (LooteerPlugin
-- acquire_pause/release_pause, caller 'HelltideRevamped'), refreshed every
-- PAUSE_REFRESH_S (Rosie drops a foreign pause after 60 s without a refresh)
-- and released on reset, disable and death. QQT_Warpigz_v3 (Q3): the same
-- pause now lasts until the whole tear event is over (core/hr_tear_loot.lua).
local M = {}

local C = {
    STAND_IN = 1.05,          -- chargeable glint: stop within this (upstream TEAR_STAND_MAX + 0.35)
    STAND_OUT = 2.0,          -- ... and walk back only beyond this (still inside the circle)
    INSIDE_MAX_S = 90,        -- inside one tear's circle before it is skipped
    STATIC_INSIDE_S = 30,     -- inside with a proven reading that stopped changing
    APPROACH_NO_PROGRESS_S = 15,
    APPROACH_PROGRESS_M = 1.5,
    ENGAGED_MAX_S = 150,      -- wall time on one tear (walk + stand)
    TICK_MAX_S = 0.5,         -- a longer gap (yield) never counts as inside time
    FULL_HOLD_S = 1.0,        -- a 0.99-1.0 charge must hold this long to mean "closed"
    PAUSE_REFRESH_S = 5,
}
M.C = C
M.PAUSE_CALLER = 'HelltideRevamped'

local function round(x) return math.floor(x * 1000 + 0.5) / 1000 end

-- Charge progress (0-1 or 0-100, unverified live) and health, whatever the
-- tear reports (a change in either is progress). nil: nothing readable, only
-- the time bounds apply.
function M.signal(progress, hp)
    local p = type(progress) == 'number' and round(progress) or nil
    local h = type(hp) == 'number' and round(hp) or nil
    if p == nil and h == nil then return nil end
    return tostring(p) .. '|' .. tostring(h)
end

-- Charge scale (Chargeable_Gizmo_Progress, unverified live: 0-1 or 0-100).
-- rc.1 read ">= 0.99" as closed, so on a 0-100 scale every tear counted as
-- closed at 1 % and was left after well under a second inside. A reading
-- above 1 proves the 0-100 scale (kept for the session of the game client:
-- module level); a reading of 0.99-1.0 is 1 % there, so on an unknown scale
-- it means "closed" only once it held FULL_HOLD_S (a charging tear passes
-- 1 % in a moment). 99+ is closed on either scale.
local scale100 = false
local full_since = {}
function M.charge_full(progress, t, key)
    if type(progress) ~= 'number' then return false end
    if progress >= 99 then return true end
    if progress > 1.001 then
        if not scale100 then console.print('[RIFT] Tear charge reads 0-100 (full at 99+)') end
        scale100 = true
        if key then full_since[key] = nil end
        return false
    end
    if progress < 0.99 or scale100 or not key then
        if key then full_since[key] = nil end
        return progress >= 0.99 and not scale100 -- no key: rc.1 reading
    end
    local since = full_since[key]
    if not since or t < since then
        full_since[key] = t
        return false
    end
    return t - since >= C.FULL_HOLD_S
end

function M.reset_scale_probe()
    full_since = {}
end

-- One tick of work on the engaged tear `key` at distance d (inside when
-- d <= inside_r). Returns nil to keep standing, else the reason to skip it.
function M.work(sess, key, d, signal, t, inside_r)
    sess.tear_work = sess.tear_work or {}
    local rec = sess.tear_work[key]
    if not rec then
        rec = {engaged_at = t, last_t = t, best_d = d, best_t = t, inside_s = 0}
        sess.tear_work[key] = rec
    end
    local step = t - rec.last_t
    if step < 0 then step = 0 elseif step > C.TICK_MAX_S then step = 0 end
    rec.last_t = t
    if d <= inside_r then
        rec.inside_s = rec.inside_s + step
        rec.inside = true
        if signal ~= nil then
            if rec.signal == nil then
                rec.signal, rec.signal_at = signal, rec.inside_s
            elseif rec.signal ~= signal then
                rec.signal, rec.signal_at, rec.signal_live = signal, rec.inside_s, true
            elseif rec.signal_live and rec.inside_s - rec.signal_at >= C.STATIC_INSIDE_S then
                return string.format('no progress for %ds inside its circle', C.STATIC_INSIDE_S)
            end
        end
        if rec.inside_s >= C.INSIDE_MAX_S then
            return string.format('still open after %ds inside its circle', C.INSIDE_MAX_S)
        end
    elseif rec.inside or d < rec.best_d - C.APPROACH_PROGRESS_M then
        -- Getting closer, or just pushed out of the circle (knock-back,
        -- revive): the approach window starts again from here.
        rec.inside, rec.best_d, rec.best_t = nil, d, t
    elseif t - rec.best_t >= C.APPROACH_NO_PROGRESS_S then
        return string.format('no progress towards it for %ds (dist=%.1f)', C.APPROACH_NO_PROGRESS_S, d)
    end
    if t - rec.engaged_at >= C.ENGAGED_MAX_S then
        return string.format('engaged %ds without closing', C.ENGAGED_MAX_S)
    end
    return nil
end

-- QQT_Warpigz_v3 (rc.2 review): the per-tear pause counts only once the
-- player is at the engaged tear (a tear is engaged from up to
-- tear_search_dist, and a revive walks back from the checkpoint): within
-- NEAR_IN of it, kept up to NEAR_OUT (a knock-back does not flip it).
C.NEAR_IN = C.STAND_OUT + 3
C.NEAR_OUT = C.STAND_OUT + 8
function M.at_tear(sess, key, d)
    if not key or type(d) ~= 'number' then
        sess.tear_near_key = nil
        return false
    end
    local near = d <= C.NEAR_IN or (sess.tear_near_key == key and d <= C.NEAR_OUT)
    sess.tear_near_key = near and key or nil
    return near
end

function M.inside_seconds(sess, key)
    local rec = sess and sess.tear_work and sess.tear_work[key]
    return rec and rec.inside_s or 0
end

-- C5: a yield (Looter/Alfred hold, revive) never counts toward the bounds.
function M.credit(sess, gap)
    for _, rec in pairs(sess and sess.tear_work or {}) do
        rec.engaged_at, rec.best_t, rec.last_t = rec.engaged_at + gap, rec.best_t + gap, rec.last_t + gap
    end
end

-- ── Rosie pickup pause ─────────────────────────────────────────────────────
local pause = {held = false, at = nil}

local function looter_call(name)
    local looter = rawget(_G, 'LooteerPlugin')
    if type(looter) ~= 'table' or type(looter[name]) ~= 'function' then return nil end
    local ok, result = pcall(looter[name], M.PAUSE_CALLER)
    if not ok then return false end
    return result
end

-- QQT_Warpigz_v3 (Q3): a reloaded HR starts with pause.held = false and
-- would never give back a pause its previous load held (Rosie keeps it up
-- to 60 s). Nothing can be held by this load yet, so drop ours once now.
looter_call('release_pause')

-- want: a tear is engaged (Q2) or the tear event is still running (Q3,
-- core/hr_tear_loot.lua) this tick. hold_msg: the pause line (logged once
-- per pause). Returns whether the pause is held.
function M.sync_pause(want, t, why, hold_msg)
    if want then
        -- Refreshed (or refused / no Looter) at most every PAUSE_REFRESH_S.
        if pause.at and t >= pause.at and t - pause.at < C.PAUSE_REFRESH_S then
            return pause.held
        end
        local got = looter_call('acquire_pause')
        pause.at = t
        if got == nil or got == false then -- no Rosie-shaped Looter, or refused
            pause.held = false
            return false
        end
        if not pause.held then
            console.print(hold_msg or '[RIFT] Pausing Looter pickup while standing in the tear') -- QQT_Warpigz_v3 (Q3)
        end
        pause.held = true
        return true
    end
    if pause.held then
        looter_call('release_pause')
        console.print('[RIFT] Looter pickup resumed (' .. tostring(why or 'no tear engaged') .. ')')
    end
    pause.held, pause.at = false, nil
    return false
end

function M.pause_held() return pause.held end

return M
