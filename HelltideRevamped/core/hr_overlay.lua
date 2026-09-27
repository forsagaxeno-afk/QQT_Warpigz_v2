-- QQT_Warpigz_v3: on-screen Helltide panel (text and rectangles only; the
-- host documents no image drawing). The text is rebuilt every 0.5 s, never
-- per frame; drawing is protected and a failing host call turns the panel
-- off for the session with one log line (no console spam).
--
--   HT 12:34 left | reset in 3:10 | zone Step_South [live]
--   Cinders 180 | 14.2/min 852/hr
--   Helltide  E 640 S 575 L 0 | chests 6 (M 1) | deaths 0
--   Session   E ... ;  All time  E ...
--   Plan: reserve 250 (Mystery known) | target <name> <dist>m
local clock = require "core.hr_clock"
local stats = require "core.hr_stats"
local settings = require "core.settings"
local tracker = require "core.tracker"

local M = {
    REBUILD_EVERY = 0.5,
    ROWS = {'All', 'Helltide only', 'Compact'},
    FONT = 15,
    LINE_H = 18,
    PAD = 6,
    CHAR_W = 7.6,
}

local cache = {lines = {}, built_at = nil, width = 0}
local broken = false

local function num(v)
    v = tonumber(v) or 0
    if v ~= v then return 0 end
    return v
end

local function scope_line(label, t)
    t = t or {}
    return string.format('%-9s E %d S %d L %d | chests %d (M %d) | deaths %d', label,
        math.floor(num(t.earned)), math.floor(num(t.spent)), math.floor(num(t.lost)),
        num(t.chests), num(t.mystery), num(t.deaths))
end

local function short_name(name)
    name = tostring(name or '?'):gsub('^usz_rewardGizmo_', '')
    if name == 'Uber' then return 'Mystery' end
    return name
end

local function timer_line(zone, live_tag)
    local head
    if clock.active() then
        head = string.format('HT %s left | reset in %s', clock.mmss(clock.minutes_left() * 60),
            clock.mmss(clock.next_reset_in()))
    else
        head = string.format('HT starts in %s', clock.mmss(clock.starts_in()))
    end
    if zone then head = head .. ' | zone ' .. zone .. (live_tag and ' [live]' or '') end
    return head
end

local function plan_line(player_pos)
    local order = tracker.hr_chest_order
    local info = order and order.last_plan
    if type(info) ~= 'table' then return nil end
    local text = 'Plan: '
    if (info.reserve or 0) > 0 then
        text = text .. string.format('reserve %d (Mystery known)', info.reserve)
    else
        text = text .. 'no reserve'
    end
    if info.target_name and info.target_pos and player_pos then
        local p = info.target_pos
        local ok, d = pcall(function()
            local dx, dy = p:x() - player_pos:x(), p:y() - player_pos:y()
            return math.sqrt(dx * dx + dy * dy)
        end)
        text = text .. string.format(' | target %s %dm', short_name(info.target_name), ok and math.floor(d) or 0)
    end
    return text
end

function M.build(now, player_pos)
    local rows = tonumber(settings.overlay_rows) or 0
    local okc, cinders = pcall(get_helltide_coin_cinders)
    if not okc then cinders = 0 end
    local atlas, live = tracker.hr_atlas, tracker.hr_live
    local zone = atlas and atlas.current_zone and atlas.current_zone() or nil
    local live_tag = false
    if live and live.matches_zone then
        local ok, match = pcall(live.matches_zone, zone)
        live_tag = ok and match == true
    end
    local lines = {}
    lines[#lines + 1] = timer_line(zone, live_tag)
    lines[#lines + 1] = string.format('Cinders %d | %.1f/min %d/hr', math.floor(num(cinders)),
        stats.rate_min(), math.floor(stats.rate_hr() + 0.5))
    if rows ~= 2 then
        lines[#lines + 1] = scope_line('Helltide', stats.helltide)
        if rows == 0 then
            lines[#lines + 1] = scope_line('Session', stats.session)
            lines[#lines + 1] = scope_line('All time', stats.alltime)
        end
        local plan = plan_line(player_pos)
        if plan then lines[#lines + 1] = plan end
    end
    local width = 0
    for _, line in ipairs(lines) do if #line > width then width = #line end end
    cache.lines, cache.width, cache.built_at = lines, width, now
    return lines
end

local function draw()
    local sw, sh = 1920, 1080
    local okw, w = pcall(get_screen_width)
    local okh, hh = pcall(get_screen_height)
    if okw and type(w) == 'number' and w > 0 then sw = w end
    if okh and type(hh) == 'number' and hh > 0 then sh = hh end
    local x = math.floor(sw * math.max(0, math.min(100, num(settings.overlay_x))) / 100)
    local y = math.floor(sh * math.max(0, math.min(100, num(settings.overlay_y))) / 100)
    local lines = cache.lines
    local width = cache.width * M.CHAR_W + M.PAD * 2
    local height = #lines * M.LINE_H + M.PAD * 2
    graphics.rect_filled(vec2:new(x, y), vec2:new(x + width, y + height), color_black(150))
    local white, yellow = color_white(230), color_yellow(230)
    for i, line in ipairs(lines) do
        graphics.text_2d(line, vec2:new(x + M.PAD, y + M.PAD + (i - 1) * M.LINE_H), M.FONT,
            i == 1 and yellow or white)
    end
end

-- render_pulse (main.lua): cheap unless a rebuild is due.
function M.render(now, player_pos)
    if broken or settings.overlay ~= true then return false end
    if not cache.built_at or now - cache.built_at >= M.REBUILD_EVERY or now < cache.built_at then
        local ok, err = pcall(M.build, now, player_pos)
        if not ok then
            broken = true
            pcall(function() console.print('[HelltideRevamped] overlay off for this session: ' .. tostring(err)) end)
            return false
        end
    end
    local ok, err = pcall(draw)
    if not ok then
        broken = true
        pcall(function() console.print('[HelltideRevamped] overlay off for this session: ' .. tostring(err)) end)
        return false
    end
    return true
end

function M.lines() return cache.lines end
function M.is_broken() return broken end
function M._reset() cache = {lines = {}, built_at = nil, width = 0}; broken = false end

return M
