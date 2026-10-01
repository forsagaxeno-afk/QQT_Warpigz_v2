-- Bounded live actor snapshot for diagnosing rupture targeting. Read-only
-- actor access; one small file overwritten at most once every five seconds.
local store = require 'core.hr_store'
local settings = require 'core.settings'
local unpack_ = table.unpack or unpack -- QQT_Warpigz_v3 2.6.7: Lua 5.1/5.4
local M = {}
local last_at

local function read(actor, method, ...)
    if actor == nil then return nil end
    local args = {...}
    local ok, value = pcall(function() return actor[method](actor, unpack_(args)) end)
    if ok then return value end
    return nil
end

local function coord(pos)
    if not pos then return '?' end
    return table.concat({tostring(read(pos, 'x')), tostring(read(pos, 'y')), tostring(read(pos, 'z'))}, ',')
end

local function capture(state, session, actors, t)
    -- QQT_Warpigz_v3 2.6.7: a diagnostic file, written only with 'Debug log' on.
    if settings.debug_log ~= true then return end
    if last_at and t >= last_at and t - last_at < 5 then return end
    last_at = t
    local player = get_player_position()
    local rows = {
        'time=' .. tostring(t) .. ' state=' .. tostring(state) .. '\n',
        'player=' .. coord(player) .. ' anchor=' .. coord(session.anchor) .. '\n',
        'focus=' .. tostring(session.tear_focus_key) .. ' standing=' .. tostring(session.tear_standing) .. '\n',
    }
    local count = 0
    for _, actor in pairs(actors or {}) do
        local skin = read(actor, 'get_skin_name')
        local lower = type(skin) == 'string' and skin:lower() or ''
        if lower:find('rupture', 1, true) or lower:find('pandemonium', 1, true) or lower:find('tear', 1, true) then
            local pos = read(actor, 'get_position')
            local distance = read(player, 'dist_to', pos)
            if type(distance) == 'number' and distance <= 150 then
                local attrs = rawget(_G, 'attributes') or {}
                rows[#rows + 1] = string.format(
                    'id=%s skin=%s distance=%.2f pos=%s hp=%s charge=%s operated=%s interactable=%s untargetable=%s\n',
                    tostring(read(actor, 'get_id')), skin, distance, coord(pos),
                    tostring(read(actor, 'get_current_health')),
                    tostring(read(actor, 'get_attribute', attrs.CHARGEABLE_GIZMO_PROGRESS)),
                    tostring(read(actor, 'get_attribute', attrs.GIZMO_HAS_BEEN_OPERATED)),
                    tostring(read(actor, 'is_interactable')), tostring(read(actor, 'is_untargetable')))
                count = count + 1
                if count >= 64 then break end
            end
        end
    end
    rows[#rows + 1] = 'rupture_actors=' .. count .. '\n'
    store.write('learned/tear_probe.txt', rows)
end

function M.capture(...)
    -- Diagnostics must never interrupt combat or navigation on a host with
    -- unavailable actor methods, attributes or file access.
    pcall(capture, ...)
end

return M
