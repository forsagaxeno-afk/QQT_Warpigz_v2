-- Pandemonium rupture leash: keep the player inside the ritual bubble while
-- lingering on a finished/idle rupture. Ported from upstream HelltideRevamped
-- 2.5.0 core/rupture_leash.lua: the bubble centre follows the hold-area gizmo,
-- the radius follows PandemoniumRift_gizmo_Boundry actors and can shrink but
-- never grow mid-event. Every actor read is pcall-protected.
local utils = require "core.utils"
local settings = require "core.settings"
local skins = require "data.hr_tear_skins"

local M = {}

local function read(actor, method)
    if actor == nil then return nil end
    local ok, v = pcall(function() return actor[method](actor) end)
    if ok then return v end
    return nil
end

local function matches(skin, patterns)
    if type(skin) ~= "string" then return false end
    for _, pat in ipairs(patterns) do
        if skin:match(pat) then return true end
    end
    return false
end

function M.reset(session)
    if not session then return end
    session.leash_center = nil
    session.leash_radius = nil
    session.leash_last_log = nil
    session.leash_armed = nil
end

function M.update(session, anchor, actors)
    if not session or not anchor then return end
    local event_radius = settings.tear_event_radius or 12
    local scan = event_radius + 55
    local center = session.leash_center or anchor
    local hold_best, hold_d = nil, math.huge
    for _, actor in pairs(actors or {}) do
        local skin = read(actor, "get_skin_name")
        if matches(skin, skins.hold_area) then
            local pos = read(actor, "get_position")
            local d = pos and anchor:dist_to(pos)
            if d and d <= scan and d < hold_d then hold_best, hold_d = pos, d end
        end
    end
    if hold_best then center = hold_best end
    session.leash_center = center

    local max_r = event_radius + 10
    for _, actor in pairs(actors or {}) do
        if matches(read(actor, "get_skin_name"), skins.boundary) then
            local pos = read(actor, "get_position")
            if pos and center:dist_to(pos) <= scan + 20 then
                local d = center:dist_to(pos) + 2
                if d > max_r then max_r = d end
            end
        end
    end
    if not session.leash_radius or max_r < session.leash_radius then
        session.leash_radius = max_r
    end
end

function M.is_outside(session)
    if not session or not session.leash_center or not session.leash_radius then
        return false
    end
    local event_radius = settings.tear_event_radius or 12
    local margin = settings.tear_circle_radius or 2
    local limit = math.max(event_radius, session.leash_radius - margin)
    return utils.distance_to(session.leash_center) > limit + 1.0
end

-- Returns true when it issued a walk-back this tick.
-- opts.busy: skip (tear focus or live combat target).
function M.enforce(session, anchor, actors, move_to, opts)
    if not session or not anchor or (opts and opts.busy) then return false end
    local event_radius = settings.tear_event_radius or 12
    if not session.leash_armed then
        if utils.distance_to(anchor) > event_radius + 3 then return false end
        session.leash_armed = true
    end
    M.update(session, anchor, actors)
    if not M.is_outside(session) then return false end
    local now = get_time_since_inject()
    if not session.leash_last_log or now - session.leash_last_log > 3 then
        session.leash_last_log = now
        console.print(string.format("[RIFT] Outside rupture bubble (%.1fm / %.1fm) — walking back",
            utils.distance_to(session.leash_center), session.leash_radius or 0))
    end
    if move_to then move_to(session.leash_center or anchor, true) end
    return true
end

return M
