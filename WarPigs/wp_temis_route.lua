-- Temis walking route around the wall between the Tree of Whispers (Raven
-- NPC) and the War Plan table / Tyrael.
--
-- Live report (v2.1.1): right after a Whisper claim the turn-in walked
-- straight at Tyrael with pathfinder.request_move, ran into the wall between
-- the Whisper tree and the War Plan table and never got unstuck. The way in
-- that SilentRaven uses (teleport arrival -> intermediate -> Raven) is known
-- to be clear, so the way out walks it backwards. A direct walk that makes
-- no progress also takes that detour (bounded, logged).
--
-- WarPug keeps its own copy (warpug_temis_route.lua): plugins must not share
-- a module name in QQT's module cache.
local M = {}

local RAVEN       = {x = 2596.38, y = -495.79}            -- SilentRaven RAVEN_NPC_POSITION
local WAYPOINTS   = {{2597.24, -488.08, 30.52},           -- SilentRaven RAVEN_INTERMEDIATE
                     {2579.58, -482.19, 31.50}}           -- Temis teleport arrival
local RAVEN_SIDE  = 10.0   -- player this close to the Raven: Whisper side of the wall
local ARRIVE      = 3.5    -- a waypoint counts as reached
local STALL_S     = 3.0    -- no progress for this long = blocked
local STALL_MIN   = 1.0    -- yards of progress that reset the stall window
local MAX_DETOURS = 3

local function flat(pos, x, y)
    local ok, d = pcall(function()
        local dx, dy = pos:x() - x, pos:y() - y
        return math.sqrt(dx * dx + dy * dy)
    end)
    return ok and d or math.huge
end

local function point(i)
    if not vec3 or not vec3.new then return nil end
    local w = WAYPOINTS[i]
    return vec3:new(w[1], w[2], w[3])
end

function M.new(log)
    local r = {leg = nil, best = nil, best_at = nil, detours = 0, capped = false, started = false}

    function r.reset()
        r.leg, r.best, r.best_at, r.detours, r.capped, r.started = nil, nil, nil, 0, false, false
    end

    -- One move toward `target` for this tick (replaces a plain request_move).
    function r.move(pp, target, now)
        if not r.started then
            r.started = true
            if flat(pp, RAVEN.x, RAVEN.y) <= RAVEN_SIDE and flat(target, RAVEN.x, RAVEN.y) > RAVEN_SIDE + 5 then
                r.leg, r.detours = 1, 1
                log('Temis: on the Whisper side of the wall — walking around it')
            end
        end
        -- Advance past reached waypoints.
        while r.leg and flat(pp, WAYPOINTS[r.leg][1], WAYPOINTS[r.leg][2]) <= ARRIVE do
            r.leg = r.leg < #WAYPOINTS and r.leg + 1 or nil
            r.best, r.best_at = nil, nil
        end
        local goal = r.leg and point(r.leg) or target
        local ok, d = pcall(function() return pp:dist_to(goal) end)
        d = ok and d or math.huge
        if r.best == nil or d < r.best - STALL_MIN then
            r.best, r.best_at = d, now
        elseif now - r.best_at >= STALL_S then
            r.best, r.best_at = nil, nil
            if r.leg then
                r.leg = r.leg < #WAYPOINTS and r.leg + 1 or nil
            elseif r.detours < MAX_DETOURS then
                r.detours = r.detours + 1
                local d1 = flat(pp, WAYPOINTS[1][1], WAYPOINTS[1][2])
                local d2 = flat(pp, WAYPOINTS[2][1], WAYPOINTS[2][2])
                r.leg = d1 <= d2 and 1 or 2
                log(string.format('Temis: no progress for %.0fs — detour around the Whisper wall (%d of %d)',
                    STALL_S, r.detours, MAX_DETOURS))
            elseif not r.capped then
                r.capped = true
                log('Temis: still blocked after ' .. MAX_DETOURS .. ' detours — walking directly')
            end
            goal = r.leg and point(r.leg) or target
        end
        pathfinder.request_move(goal)
    end

    return r
end

return M
