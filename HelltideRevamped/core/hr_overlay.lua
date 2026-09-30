-- QQT_Warpigz_v3: on-screen Helltide panel (text, rectangles and lines only;
-- the host documents no image drawing). The panel is rebuilt at most four
-- times a second (REBUILD_EVERY), never per frame: build() turns the run
-- into a list of draw operations (relative to the panel's corner) and the
-- plain text lines (tests, lines()); the absolute positions are cached until
-- the panel moves or is rebuilt, so a frame only replays the cached list.
-- Drawing is protected and a failing host call turns the panel off for the
-- session with one log line (no console spam).
--
-- QQT_Warpigz_v3: "Overlay appearance" (menu Live data & stats). The host
-- draws every text_2d BENEATH the rect_filled / line primitives whatever the
-- call order (a live capture showed the text at ~20% of its colour under the
-- old 80% panel), so:
--   * the panel background is light by default (25%) and the text carries a
--     dark shadow / outline, which is what keeps it readable on any scene;
--   * bars and dividers get their own bands and never cross a text row.
-- The layout is a character grid computed from the font size (glyph width
-- CHAR_RATIO * font, line height LINE_RATIO * font): labels at column 0,
-- values at column VCOL, the STATS columns share what is left; every text is
-- cut to its column. Only the enabled sections are laid out, so the panel's
-- height fits them. The anchor (a screen corner) and the offsets place it.
--
--   HELLTIDE  Kehjistan                          RUNNING
--   Ends in      26m 00s                        [bar]
--   Wave         3 of 6  reset :30 in 1m 00s    [bar]
--   CINDERS      660    +18.0/min   ~1087/hr    [bar to the goal]
--   Goal         Ready: 75 for Random chest
--   This HT      +16 earned  -0 spent  -0 lost
--   NOW          Activity / Movement / In Helltide / Plan
--   TARGET       Chest / Distance + source / Position
--   STATS        This HT / Session / All time (Chests .. Cinders/min)
--   OPENED THIS WAVE (last 3) and still to open
-- Rows: All; Helltide only (the STATS table shows This HT only); Timers +
-- cinders (header, timers and cinders).
local clock = require "core.hr_clock"
local stats = require "core.hr_stats"
local settings = require "core.settings"
local tracker = require "core.tracker"
local view = require "core.hr_view"

local M = {
    REBUILD_EVERY = 0.25,
    ROWS = {'All', 'Helltide only', 'Timers + cinders'},
    ANCHORS = {'Top left', 'Top right', 'Bottom left', 'Bottom right'},
    THEMES = {'Bright', 'Classic', 'Minimal'},
    ACCENTS = {'Cyan', 'Gold', 'Green', 'Red', 'Purple', 'White'},
    CHAR_RATIO = 0.57,      -- glyph width / font size (live: ~0.54)
    LINE_RATIO = 1.25,
    COMPACT_LINE_RATIO = 1.1,
    FONT_MIN = 10, FONT_MAX = 28, FONT_DEFAULT = 15,
    COL_GAP = 3,            -- characters between the two columns
    AUTO_COLS = 48, MIN_COLS = 30, MAX_COLS = 100,
    VCOL = 13,              -- value column (characters)
    OPENED_ROWS = 3,
    -- current layout (layout(); kept as fields for tests and callers)
    FONT = 15, LINE_H = 19, PAD = 9, CHAR_W = 8.55, WIDTH = 429,
}

-- ops: {k = 't'|'r'|'l', ...} relative to the panel corner; lines: text.
local cache = {lines = {}, ops = {}, built_at = nil, width = 0, height = 0, abs = nil, ox = nil, oy = nil}
local broken = false
local pal, pal_key = nil, nil
local L = nil               -- current layout (layout())

local num = view.num
local floor = math.floor

local function clampi(v, lo, hi, def)
    v = tonumber(v)
    if not v or v ~= v then return def end
    v = floor(v + 0.5)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

local function on(v) return v ~= false end

-- ── palette (color.new when the host has it, else the named colours) ─────
local function rgba(r, g, b, a, fallback)
    local ok, c = pcall(function() return color.new(r, g, b, a) end)
    if ok and c ~= nil then return c end
    return fallback(a)
end

-- Colour presets: {r, g, b, alpha, named fallback}. 'shadows' is the number
-- of dark copies drawn under every text (1: +1,+1; 2: and -1,-1; 4: an
-- outline); 'bg' false: no panel (Minimal).
M.PRESETS = {
    { -- Bright (default): white text, light labels, a two-way shadow
        label = {218, 224, 234}, text = {255, 255, 255}, dim = {192, 200, 212},
        amber = {255, 196, 84}, green = {96, 236, 150}, red = {255, 148, 132},
        track = {110, 116, 126, 200}, divider = {200, 206, 216, 110},
        shadows = 2, bg = true, dividers = true,
    },
    { -- Classic: the first overlay's colours, one shadow
        label = {175, 185, 200}, text = {235, 239, 245}, dim = {150, 160, 174},
        amber = {245, 180, 70}, green = {80, 215, 150}, red = {250, 125, 112},
        track = {55, 62, 74, 220}, divider = {80, 92, 108, 170},
        shadows = 1, bg = true, dividers = true,
    },
    { -- Minimal: no panel, pure white text in a black outline
        label = {255, 255, 255}, text = {255, 255, 255}, dim = {226, 226, 226},
        amber = {255, 212, 96}, green = {120, 255, 165}, red = {255, 125, 112},
        track = {0, 0, 0, 170}, divider = {0, 0, 0, 0},
        shadows = 4, bg = false, dividers = false,
    },
}
M.ACCENT_RGB = {
    {100, 215, 245}, {255, 200, 70}, {110, 235, 150}, {255, 130, 110}, {200, 160, 255}, {255, 255, 255},
}
local FALLBACK = {
    label = 'white', text = 'white', dim = 'white', amber = 'orange', green = 'green',
    red = 'red', track = 'black', divider = 'white',
}

-- A named host colour (color_white(a) ...), white when missing.
local function named(name)
    local f = _G['color_' .. name]
    if type(f) ~= 'function' then f = _G.color_white end
    return f
end
local SHADOW_OFFSETS = {
    {{1, 1}}, {{1, 1}, {-1, -1}}, nil, {{1, 1}, {-1, -1}, {1, -1}, {-1, 1}},
}

local function palette()
    local theme = L and L.theme or 1
    local accent = L and L.accent or 1
    local bg_a = L and L.bg_alpha or 0
    local key = theme * 10000 + accent * 1000 + bg_a
    if pal and pal_key == key then return pal end
    local P = M.PRESETS[theme]
    local p = {}
    for name, fb in pairs(FALLBACK) do
        local c = P[name]
        p[name] = rgba(c[1], c[2], c[3], c[4] or 255, named(fb))
    end
    local a = M.ACCENT_RGB[accent]
    p.head = rgba(a[1], a[2], a[3], 255, named('blue'))
    p.bar = rgba(a[1], a[2], a[3], 245, named('blue'))
    -- the wave bar: amber, cyan next to a gold accent (two bars side by side)
    local wv = accent == 2 and M.ACCENT_RGB[1] or P.amber
    p.wave = rgba(wv[1], wv[2], wv[3], 245, named('orange'))
    p.shadow = rgba(0, 0, 0, 255, named('black'))
    p.bg = rgba(0, 0, 0, floor(bg_a * 255 / 100 + 0.5), named('black'))
    pal, pal_key = p, key
    return p
end

-- ── layout (from the settings; cheap, done on every rebuild) ─────────────
local SECTION_KEYS = {
    timer = 'overlay_show_timer', wave = 'overlay_show_wave', cinders = 'overlay_show_cinders',
    now = 'overlay_show_now', target = 'overlay_show_target', stats = 'overlay_show_stats',
    opened = 'overlay_show_opened',
}

local function layout()
    local l = L or {show = {}}
    local font = clampi(settings.overlay_font, M.FONT_MIN, M.FONT_MAX, M.FONT_DEFAULT)
    l.two = clampi(settings.overlay_columns, 0, 1, 1) == 1
    local compact = settings.overlay_compact == true
    l.font, l.compact = font, compact
    l.cw = M.CHAR_RATIO * font
    l.lh = math.ceil(font * (compact and M.COMPACT_LINE_RATIO or M.LINE_RATIO))
    l.pad = math.max(4, floor(font * (compact and 0.4 or 0.6) + 0.5))
    l.gap = math.max(2, floor(font * (compact and 0.15 or 0.2) + 0.5))
    l.bar_h = math.max(3, floor(font * 0.28 + 0.5))
    l.theme = clampi(settings.overlay_theme, 0, #M.THEMES - 1, 0) + 1
    l.accent = clampi(settings.overlay_accent, 0, #M.ACCENTS - 1, 0) + 1
    local preset = M.PRESETS[l.theme]
    l.bg_alpha = preset.bg and clampi(settings.overlay_bg, 0, 100, 25) or 0
    l.shadows = SHADOW_OFFSETS[preset.shadows] or {}
    l.dividers = preset.dividers and not compact
    l.bars = on(settings.overlay_bars)
    l.rows = clampi(settings.overlay_rows, 0, 2, 0)
    local width = clampi(settings.overlay_width, 0, 2000, 0)
    local cols = M.AUTO_COLS
    if width > 0 then cols = floor((width - 2 * l.pad) / l.cw) end
    if cols < M.MIN_COLS then cols = M.MIN_COLS elseif cols > M.MAX_COLS then cols = M.MAX_COLS end
    l.cols = cols
    l.iw = math.ceil(cols * l.cw)
    l.vx = M.VCOL * l.cw
    for name, key in pairs(SECTION_KEYS) do l.show[name] = on(settings[key]) end
    if l.rows == 2 then
        l.show.now, l.show.target, l.show.stats, l.show.opened = false, false, false, false
    end
    -- two columns: STATS and OPENED THIS WAVE on the right (when shown)
    if l.two and not (l.show.stats or l.show.opened) then l.two = false end
    l.x2 = l.two and math.ceil((cols + M.COL_GAP) * l.cw) or 0
    l.width = (l.two and (l.x2 + l.iw) or l.iw) + 2 * l.pad
    L = l
    M.FONT, M.LINE_H, M.PAD, M.CHAR_W = font, l.lh, l.pad, l.cw
    M.WIDTH = l.width
    return l
end
M.layout = function() return layout() end

-- ── builder ──────────────────────────────────────────────────────────────
local function new_builder()
    return {y = 0, x0 = 0, ops = {}, lines = {}, row = nil, sections = 0}
end

-- Text at character column `col` of the current row, cut to `max` columns
-- (default: to the panel's right edge). Empty text is not drawn.
local function put(b, col, s, c, max)
    s = tostring(s or '')
    max = max or (L.cols - col)
    if max < 1 then return end
    if #s > max then s = max > 3 and (s:sub(1, max - 2) .. '..') or s:sub(1, max) end
    if s == '' then return end
    b.ops[#b.ops + 1] = {k = 't', x = b.x0 + floor(col * L.cw + 0.5), y = b.y, s = s, c = c or 'text', bold = c == 'head' or nil}
    b.row = b.row and (b.row .. '  ' .. s) or s
end

-- Right-aligned text of the current row.
local function rput(b, s, c)
    put(b, math.max(0, L.cols - #s), s, c)
end

local function newline(b)
    if b.row then b.lines[#b.lines + 1] = b.row end
    b.row = nil
    b.y = b.y + L.lh
end

local function bar(b, frac, c)
    if not L.bars then return end
    frac = num(frac)
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    local y = b.y
    local x = b.x0
    b.ops[#b.ops + 1] = {k = 'r', x1 = x, y1 = y, x2 = x + L.iw, y2 = y + L.bar_h, c = 'track'}
    if frac > 0 then b.ops[#b.ops + 1] = {k = 'r', x1 = x, y1 = y, x2 = x + floor(L.iw * frac + 0.5), y2 = y + L.bar_h, c = c or 'bar'} end
    b.y = y + L.bar_h + L.gap
end

-- Space (and a divider line) between two sections.
local function section(b)
    b.sections = b.sections + 1
    if b.sections == 1 then return end
    if L.dividers then
        b.y = b.y + L.gap
        b.ops[#b.ops + 1] = {k = 'l', x1 = b.x0, y = b.y, x2 = b.x0 + L.iw, c = 'divider'}
        b.y = b.y + L.gap + 1
    else
        b.y = b.y + L.gap
    end
end

local function head(b, title)
    put(b, 0, title, 'head')
    newline(b)
end

local function kv(b, label, value, c)
    put(b, 0, label, 'label', M.VCOL - 1)
    put(b, M.VCOL, value, c or 'text')
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
    section(b)
    put(b, 0, 'HELLTIDE', 'head')
    put(b, 10, view.region(zone) or 'no zone', 'text', L.cols - 10 - #status - 1)
    rput(b, status, sc)
    newline(b)
end

local function timers(b)
    local show = L.show
    if not show.timer and not show.wave then return end
    local active = clock.active()
    if not show.timer and not active then return end
    section(b)
    if not active then
        kv(b, 'Next HT in', view.dur(clock.starts_in()))
        return
    end
    if show.timer then
        kv(b, 'Ends in', view.dur(clock.minutes_left() * 60))
        bar(b, 1 - clock.minutes_left() / clock.END_MINUTE, 'bar')
    end
    if show.wave then
        local w = view.wave()
        kv(b, 'Wave', string.format('%d of %d  reset :%02d in %s', w.i, w.n, w.next_min, view.dur(w.next_in)))
        bar(b, w.frac, 'wave')
    end
end

local function cinders_section(b, cinders, target)
    section(b)
    local c1, c2 = M.VCOL, M.VCOL + 7
    put(b, 0, 'CINDERS', 'head', M.VCOL - 1)
    put(b, c1, tostring(int(cinders)), 'amber', 6)
    put(b, c2, string.format('+%.1f/min', num(stats.rate_min())), 'text', 11)
    if not L.compact and L.cols - (c2 + 12) >= 8 then
        put(b, c2 + 12, string.format('~%d/hr', int(stats.rate_hr())), 'label')
    end
    newline(b)
    local g = view.goal(cinders, target)
    bar(b, g.frac, g.ready and 'green' or 'amber')
    if g.ready then
        kv(b, 'Goal', string.format('Ready: %d for %s', int(g.cost), g.label), 'green')
    else
        kv(b, 'Goal', string.format('Need %d more for %s (%d)', int(g.cost - num(cinders)), g.label, int(g.cost)), 'text')
    end
    if not L.compact then
        local h = stats.helltide or {}
        kv(b, 'This HT', string.format('+%d earned  -%d spent  -%d lost', int(h.earned), int(h.spent), int(h.lost)))
    end
end

local function now_section(b, target)
    local state = tracker.hr_task_state
    section(b)
    if not L.compact then head(b, 'NOW') end
    kv(b, 'Activity', view.activity(state))
    kv(b, 'Movement', view.movement(state, target))
    local in_ht = tracker.hr_in_ht
    if in_ht == nil then kv(b, 'In Helltide', '?', 'dim')
    else kv(b, 'In Helltide', in_ht and 'Yes' or 'No', in_ht and 'green' or 'red') end
    kv(b, 'Plan', view.plan())
end

local function target_section(b, target)
    section(b)
    if not L.compact then head(b, 'TARGET') end
    if not target then
        kv(b, 'Chest', 'none', 'dim')
        return
    end
    kv(b, 'Chest', string.format('%s  %d', target.short, int(target.cost)), target.mystery and 'amber' or 'text')
    local src = target.source == 'learned' and 'learned spot' or 'seen'
    if target.road then src = src .. ', road' end
    kv(b, 'Distance', target.dist and string.format('%d m  |  %s', int(target.dist), src) or src)
    if not L.compact then
        kv(b, 'Position', target.x and string.format('%d, %d', int(target.x), int(target.y)) or '?')
    end
end

local STAT_ROWS = {
    {'Chests', 'chests'}, {'Mystery', 'mystery', 'amber'}, {'Earned', 'earned', 'amber'}, {'Spent', 'spent'},
    {'Lost', 'lost'}, {'Deaths', 'deaths'}, {'Time', 'secs'}, {'Cinders/min', 'rate'},
}
local STAT_TITLES = {'This HT', 'Session', 'All time'}

local function stat_value(t, key)
    if key == 'secs' then return (view.dur(num(t.secs)):gsub(' %d+s$', '')) end
    if key == 'rate' then return string.format('%.1f', view.scope_rate(t)) end
    return tostring(int(t[key]))
end

local function stats_section(b)
    section(b)
    local scopes = {stats.helltide or {}, stats.session or {}, stats.alltime or {}}
    local n = L.rows == 1 and 1 or 3
    local colw = floor((L.cols - M.VCOL) / n)
    if colw > 12 then colw = 12 end
    put(b, 0, 'STATS', 'head', M.VCOL - 1)
    for i = 1, n do put(b, M.VCOL + (i - 1) * colw, STAT_TITLES[i], 'label', colw - 1) end
    newline(b)
    for _, row in ipairs(STAT_ROWS) do
        put(b, 0, row[1], 'label', M.VCOL - 1)
        for i = 1, n do put(b, M.VCOL + (i - 1) * colw, stat_value(scopes[i], row[2]), row[3] or 'text', colw - 1) end
        newline(b)
    end
    if not L.compact then
        local a, h = stats.alltime or {}, stats.helltide or {}
        local hts = int(a.helltides)
        local each = hts > 0 and num(a.chests) / hts or 0
        local hrs = num(h.secs) / 3600
        put(b, 0, string.format('%d Helltides | %.1f chests each | %.1f/hr now', hts, each,
            hrs > 0 and num(h.chests) / hrs or 0), 'dim')
        newline(b)
    end
end

local function opened_section(b)
    section(b)
    head(b, 'OPENED THIS WAVE')
    local list = view.opened_wave(M.OPENED_ROWS)
    local now = clock.epoch()
    if #list == 0 then
        put(b, 0, 'nothing yet', 'dim')
        newline(b)
    end
    local age_col = M.VCOL + 1
    local at_col = age_col + 13
    for _, o in ipairs(list) do
        put(b, 0, string.format('%s %d', view.short_name(o.name), int(o.cost)), o.name == view.MYSTERY and 'amber' or 'text', age_col - 1)
        put(b, age_col, view.dur(now - num(o.t)) .. ' ago', 'label', 12)
        if o.x and L.cols - at_col >= 12 then put(b, at_col, string.format('at %d, %d', int(o.x), int(o.y)), 'label') end
        newline(b)
    end
    local t = view.to_open()
    kv(b, 'To open', string.format('%d mystery  %d regular  %d learned', t.mystery, t.regular, t.learned))
    if not L.compact then
        put(b, 0, string.format('Opened this Helltide: %d', view.opened_hour_count()), 'dim')
        newline(b)
    end
end

function M.build(now, player_pos)
    layout()
    local show = L.show
    local okc, cinders = pcall(get_helltide_coin_cinders)
    if not okc or type(cinders) ~= 'number' then cinders = 0 end
    local atlas = tracker.hr_atlas
    local zone = atlas and atlas.current_zone and atlas.current_zone() or nil
    local target = view.target(player_pos)
    local b = new_builder()
    header(b, zone)
    timers(b)
    if show.cinders then cinders_section(b, cinders, target) end
    if show.now then now_section(b, target) end
    if show.target then target_section(b, target) end
    local left_h = b.y
    if L.two then b.x0, b.y, b.sections = L.x2, 0, 0 end
    if show.stats then stats_section(b) end
    if show.opened then opened_section(b) end
    if b.row then newline(b) end
    cache.lines, cache.ops, cache.built_at = b.lines, b.ops, now
    cache.width = L.width
    cache.height = math.max(left_h, b.y) + 2 * L.pad - floor((L.lh - L.font) / 2)
    cache.abs = nil
    return b.lines
end

-- Absolute draw list for the panel corner (x, y): vec2 objects made once
-- per rebuild or move (a text's shadow copies included).
local function absolute(x, y)
    local p = palette()
    local out = {}
    local ox, oy = x + L.pad, y + L.pad
    local sh = L.shadows
    for i, op in ipairs(cache.ops) do
        if op.k == 't' then
            local tx, ty = ox + op.x, oy + op.y
            local shadows = {}
            for j = 1, #sh do shadows[j] = vec2:new(tx + sh[j][1], ty + sh[j][2]) end
            out[i] = {k = 't', a = vec2:new(tx, ty), s = op.s, c = p[op.c] or p.text, sh = shadows,
                b = op.bold and vec2:new(tx + 1, ty) or nil}
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

-- Panel corner from the anchor and the offsets (percent of the screen),
-- kept on screen.
function M.position(sw, sh)
    local anchor = clampi(settings.overlay_anchor, 0, 3, 0)
    local dx = floor(sw * clampi(settings.overlay_pos_x, 0, 100, 0) / 100)
    local dy = floor(sh * clampi(settings.overlay_pos_y, 0, 100, 0) / 100)
    local w, h = cache.width, cache.height
    local x = (anchor == 1 or anchor == 3) and (sw - w - dx) or dx
    local y = (anchor == 2 or anchor == 3) and (sh - h - dy) or dy
    if x > sw - w then x = sw - w end
    if y > sh - h then y = sh - h end
    if x < 0 then x = 0 end
    if y < 0 then y = 0 end
    return x, y
end

local function draw()
    local sw, sh = 1920, 1080
    local okw, w = pcall(get_screen_width)
    local okh, hh = pcall(get_screen_height)
    if okw and type(w) == 'number' and w > 0 then sw = w end
    if okh and type(hh) == 'number' and hh > 0 then sh = hh end
    local x, y = M.position(sw, sh)
    local list = cache.abs
    if not list or cache.ox ~= x or cache.oy ~= y then list = absolute(x, y) end
    local p = palette()
    if L.bg_alpha > 0 then graphics.rect_filled(cache.bg_a, cache.bg_b, p.bg) end
    local font, shadow = L.font, p.shadow
    for i = 1, #list do
        local op = list[i]
        if op.k == 't' then
            local s = op.sh
            for j = 1, #s do graphics.text_2d(op.s, s[j], font, shadow) end
            graphics.text_2d(op.s, op.a, font, op.c)
            if op.b then graphics.text_2d(op.s, op.b, font, op.c) end -- titles: bold
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
function M.current() return L end
function M.colors() return pal end
function M.is_broken() return broken end
function M._reset()
    cache = {lines = {}, ops = {}, built_at = nil, width = 0, height = 0, abs = nil, ox = nil, oy = nil}
    broken = false
    pal, pal_key, L = nil, nil, nil
end

return M
