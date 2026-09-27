-- QQT_Warpigz_v3: on-screen Helltide panel (text, rectangles and lines only;
-- the host documents no image drawing). The panel is rebuilt at most four
-- times a second (REBUILD_EVERY), never per frame: build() turns the run
-- into a list of draw operations (relative to the panel's corner) and the
-- plain text lines (tests, lines()); the absolute positions are cached until
-- the panel moves or is rebuilt, so a frame only replays the cached list.
-- Drawing is protected and a failing host call turns the panel off for the
-- session with one log line (no console spam).
--
--   HELLTIDE  Kehjistan                          RUNNING
--   Helltide ends in 6m 29s          [bar]
--   Wave 2 of 6 | next reset :20 in 3m 12s   [bar]
--   CINDERS   660   +18.0 / min   ~1087 / hr   [bar to the goal]
--             Ready: 75 for Random chest
--             This HT +16 earned | -0 spent | -0 lost
--   NOW       Activity / Movement / In Helltide / Plan
--   TARGET    Chest / Distance + source / Position
--   STATS     This HT / Session / All time (Chests .. Cinders/min)
--   OPENED THIS WAVE (last 3) and still to open
-- Rows: All; Helltide only (the STATS table shows This HT only); Compact
-- (header, timers and cinders).
local clock = require "core.hr_clock"
local stats = require "core.hr_stats"
local settings = require "core.settings"
local tracker = require "core.tracker"
local view = require "core.hr_view"

local M = {
    REBUILD_EVERY = 0.25,
    ROWS = {'All', 'Helltide only', 'Compact'},
    FONT = 14,
    LINE_H = 17,
    PAD = 9,
    CHAR_W = 8.2,           -- conservative glyph width (layout and cuts)
    WIDTH = 440,
    VALUE_X = 108,          -- value column (NOW / TARGET)
    STAT_X = {118, 206, 294}, -- STATS columns
    OPENED_ROWS = 3,
}

-- ops: {k = 't'|'r'|'l', ...} relative to the panel corner; lines: text.
local cache = {lines = {}, ops = {}, built_at = nil, width = 0, height = 0, abs = nil, ox = nil, oy = nil}
local broken = false
local pal = nil

local num = view.num
local floor = math.floor

-- ── palette (color.new when the host has it, else the named colours) ─────
local function rgba(r, g, b, a, fallback)
    local ok, c = pcall(function() return color.new(r, g, b, a) end)
    if ok and c ~= nil then return c end
    return fallback(a)
end

local function palette()
    if pal then return pal end
    pal = {
        bg = rgba(8, 11, 16, 205, color_black),
        head = rgba(94, 200, 230, 255, color_blue),
        label = rgba(150, 160, 175, 255, color_white),
        text = rgba(232, 236, 242, 255, color_white),
        amber = rgba(245, 180, 70, 255, color_orange),
        green = rgba(80, 215, 150, 255, color_green),
        red = rgba(240, 90, 80, 255, color_red),
        dim = rgba(110, 120, 135, 255, color_white),
        track = rgba(55, 62, 74, 220, color_black),
        cyan = rgba(110, 215, 240, 240, color_blue),
        divider = rgba(80, 92, 108, 170, color_white),
    }
    return pal
end

-- ── builder ──────────────────────────────────────────────────────────────
local function new_builder()
    return {y = 0, ops = {}, lines = {}, row = nil}
end

-- Text at column x (px) of the current row, cut to `max` characters.
local function put(b, x, s, c, max)
    s = tostring(s or '')
    if max and #s > max then s = s:sub(1, math.max(1, max - 2)) .. '..' end
    b.ops[#b.ops + 1] = {k = 't', x = x, y = b.y, s = s, c = c or 'text'}
    b.row = b.row and (b.row .. '  ' .. s) or s
end

local function newline(b, h)
    if b.row then b.lines[#b.lines + 1] = b.row end
    b.row = nil
    b.y = b.y + (h or M.LINE_H)
end

local function bar(b, frac, c, w)
    frac = num(frac)
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    w = w or (M.WIDTH - M.PAD * 2)
    local y = b.y + 2
    b.ops[#b.ops + 1] = {k = 'r', x1 = 0, y1 = y, x2 = w, y2 = y + 4, c = 'track'}
    if frac > 0 then b.ops[#b.ops + 1] = {k = 'r', x1 = 0, y1 = y, x2 = floor(w * frac + 0.5), y2 = y + 4, c = c or 'cyan'} end
    b.y = b.y + 10
end

local function divider(b)
    b.y = b.y + 3
    b.ops[#b.ops + 1] = {k = 'l', x1 = 0, y = b.y, x2 = M.WIDTH - M.PAD * 2, c = 'divider'}
    b.y = b.y + 5
end

local function head(b, title)
    put(b, 0, title, 'head')
    newline(b)
end

local function kv(b, label, value, c)
    put(b, 0, label, 'label')
    put(b, M.VALUE_X, value, c or 'text', floor((M.WIDTH - M.PAD * 2 - M.VALUE_X) / M.CHAR_W))
    newline(b)
end

local function int(v) return floor(num(v) + 0.5) end

-- ── sections ─────────────────────────────────────────────────────────────
local function header(b, zone)
    local in_ht = tracker.hr_in_ht == true
    local state = tracker.hr_task_state
    local status, sc = 'IDLE', 'dim'
    if in_ht and state then status, sc = 'RUNNING', 'green'
    elseif clock.active() then status, sc = 'SEARCHING', 'amber' end
    put(b, 0, 'HELLTIDE', 'head')
    put(b, 78, view.region(zone) or 'no zone', 'text', 30)
    put(b, M.WIDTH - M.PAD * 2 - #status * M.CHAR_W, status, sc)
    newline(b)
    divider(b)
end

local function timers(b)
    if clock.active() then
        put(b, 0, 'Helltide ends in', 'label')
        put(b, 150, view.dur(clock.minutes_left() * 60), 'text')
        newline(b)
        bar(b, 1 - clock.minutes_left() / clock.END_MINUTE, 'cyan')
        local w = view.wave()
        put(b, 0, string.format('Wave %d of %d  |  next reset :%02d in %s', w.i, w.n, w.next_min, view.dur(w.next_in)), 'label')
        newline(b)
        bar(b, w.frac, 'amber')
    else
        put(b, 0, 'Next Helltide in', 'label')
        put(b, 150, view.dur(clock.starts_in()), 'text')
        newline(b)
    end
end

local function cinders_section(b, cinders, target)
    divider(b)
    head(b, 'CINDERS')
    put(b, 0, tostring(int(cinders)), 'amber')
    put(b, 80, string.format('+%.1f / min', num(stats.rate_min())), 'text')
    put(b, 210, string.format('~%d / hr', int(stats.rate_hr())), 'label')
    newline(b)
    local g = view.goal(cinders, target)
    bar(b, g.frac, g.ready and 'green' or 'amber')
    if g.ready then
        put(b, 0, string.format('Ready: %d for %s', int(g.cost), g.label), 'green', 51)
    else
        put(b, 0, string.format('Need %d more for %s (%d)', int(g.cost - num(cinders)), g.label, int(g.cost)), 'label', 51)
    end
    newline(b)
    local h = stats.helltide or {}
    put(b, 0, string.format('This HT  +%d earned | -%d spent | -%d lost', int(h.earned), int(h.spent), int(h.lost)), 'text', 51)
    newline(b)
end

local function now_section(b, target)
    local state = tracker.hr_task_state
    divider(b)
    head(b, 'NOW')
    kv(b, 'Activity', view.activity(state))
    kv(b, 'Movement', view.movement(state, target))
    local in_ht = tracker.hr_in_ht
    if in_ht == nil then kv(b, 'In Helltide', '?', 'dim')
    else kv(b, 'In Helltide', in_ht and 'Yes' or 'No', in_ht and 'green' or 'red') end
    kv(b, 'Plan', view.plan())
end

local function target_section(b, target)
    divider(b)
    head(b, 'TARGET')
    if not target then
        kv(b, 'Chest', 'none', 'dim')
        return
    end
    kv(b, 'Chest', string.format('%s  %d', target.short, int(target.cost)), target.mystery and 'amber' or 'text')
    local src = target.source == 'learned' and 'learned spot' or 'seen'
    if target.road then src = src .. ' | road' end
    kv(b, 'Distance', target.dist and string.format('%d m  |  %s', int(target.dist), src) or src)
    kv(b, 'Position', target.x and string.format('%d, %d', int(target.x), int(target.y)) or '?')
end

local STAT_ROWS = {
    {'Chests', 'chests'}, {'Mystery', 'mystery', 'amber'}, {'Earned', 'earned', 'amber'}, {'Spent', 'spent'},
    {'Lost', 'lost'}, {'Deaths', 'deaths'}, {'Time', 'secs'}, {'Cinders/min', 'rate'},
}

local function stat_value(t, key)
    if key == 'secs' then return (view.dur(num(t.secs)):gsub(' %d+s$', '')) end
    if key == 'rate' then return string.format('%.1f', view.scope_rate(t)) end
    return tostring(int(t[key]))
end

local function stats_section(b, only_ht)
    divider(b)
    head(b, 'STATS')
    local scopes = {stats.helltide or {}, stats.session or {}, stats.alltime or {}}
    local titles = {'This HT', 'Session', 'All time'}
    local n = only_ht and 1 or 3
    for i = 1, n do put(b, M.STAT_X[i], titles[i], 'label') end
    newline(b)
    for _, row in ipairs(STAT_ROWS) do
        put(b, 0, row[1], 'label')
        for i = 1, n do put(b, M.STAT_X[i], stat_value(scopes[i], row[2]), row[3] or 'text') end
        newline(b)
    end
    local a, h = stats.alltime or {}, stats.helltide or {}
    local hts = int(a.helltides)
    local each = hts > 0 and num(a.chests) / hts or 0
    local hrs = num(h.secs) / 3600
    put(b, 0, string.format('%d Helltides | %.1f chests each | %.1f/hr now', hts, each,
        hrs > 0 and num(h.chests) / hrs or 0), 'dim', 51)
    newline(b)
end

local function opened_section(b)
    divider(b)
    head(b, 'OPENED THIS WAVE')
    local list = view.opened_wave(M.OPENED_ROWS)
    local now = clock.epoch()
    if #list == 0 then
        put(b, 0, 'nothing yet', 'dim')
        newline(b)
    end
    for _, o in ipairs(list) do
        put(b, 0, string.format('%s %d', view.short_name(o.name), int(o.cost)), o.name == view.MYSTERY and 'amber' or 'text', 18)
        put(b, 158, view.dur(now - num(o.t)) .. ' ago', 'label')
        if o.x then put(b, 288, string.format('at %d, %d', int(o.x), int(o.y)), 'label') end
        newline(b)
    end
    local t = view.to_open()
    put(b, 0, string.format('Still to open: %d mystery | %d regular | %d learned', t.mystery, t.regular, t.learned), 'text', 51)
    newline(b)
    put(b, 0, string.format('Opened this Helltide: %d', view.opened_hour_count()), 'dim')
    newline(b)
end

function M.build(now, player_pos)
    local rows = tonumber(settings.overlay_rows) or 0
    local okc, cinders = pcall(get_helltide_coin_cinders)
    if not okc or type(cinders) ~= 'number' then cinders = 0 end
    local atlas = tracker.hr_atlas
    local zone = atlas and atlas.current_zone and atlas.current_zone() or nil
    local target = view.target(player_pos)
    local b = new_builder()
    header(b, zone)
    timers(b)
    cinders_section(b, cinders, target)
    if rows ~= 2 then
        now_section(b, target)
        target_section(b, target)
        stats_section(b, rows == 1)
        opened_section(b)
    end
    cache.lines, cache.ops, cache.built_at = b.lines, b.ops, now
    cache.width, cache.height = M.WIDTH, b.y + M.PAD * 2
    cache.abs = nil
    return b.lines
end

-- Absolute draw list for the panel corner (x, y): vec2 objects made once
-- per rebuild or move.
local function absolute(x, y)
    local p = palette()
    local out = {}
    local ox, oy = x + M.PAD, y + M.PAD
    for i, op in ipairs(cache.ops) do
        if op.k == 't' then
            out[i] = {k = 't', a = vec2:new(ox + op.x, oy + op.y), s = op.s, c = p[op.c] or p.text}
        elseif op.k == 'r' then
            out[i] = {k = 'r', a = vec2:new(ox + op.x1, oy + op.y1), b = vec2:new(ox + op.x2, oy + op.y2), c = p[op.c] or p.track}
        else
            out[i] = {k = 'l', a = vec2:new(ox + op.x1, oy + op.y), b = vec2:new(ox + op.x2, oy + op.y), c = p[op.c] or p.divider}
        end
    end
    cache.bg_a, cache.bg_b = vec2:new(x, y), vec2:new(x + cache.width, y + cache.height)
    cache.abs, cache.ox, cache.oy = out, x, y
    return out
end

local function draw()
    local sw, sh = 1920, 1080
    local okw, w = pcall(get_screen_width)
    local okh, hh = pcall(get_screen_height)
    if okw and type(w) == 'number' and w > 0 then sw = w end
    if okh and type(hh) == 'number' and hh > 0 then sh = hh end
    local x = floor(sw * math.max(0, math.min(100, num(settings.overlay_x))) / 100)
    local y = floor(sh * math.max(0, math.min(100, num(settings.overlay_y))) / 100)
    local list = cache.abs
    if not list or cache.ox ~= x or cache.oy ~= y then list = absolute(x, y) end
    local p = palette()
    graphics.rect_filled(cache.bg_a, cache.bg_b, p.bg)
    local font = M.FONT
    for i = 1, #list do
        local op = list[i]
        if op.k == 't' then graphics.text_2d(op.s, op.a, font, op.c)
        elseif op.k == 'r' then graphics.rect_filled(op.a, op.b, op.c)
        else graphics.line(op.a, op.b, op.c, 1) end
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
function M.ops() return cache.ops end
function M.size() return cache.width, cache.height end
function M.is_broken() return broken end
function M._reset()
    cache = {lines = {}, ops = {}, built_at = nil, width = 0, height = 0, abs = nil, ox = nil, oy = nil}
    broken = false
    pal = nil
end

return M
