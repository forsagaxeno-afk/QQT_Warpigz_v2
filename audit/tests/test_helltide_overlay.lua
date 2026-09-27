-- QQT_Warpigz_v3: the sectioned stats overlay (core/hr_overlay.lua over
-- core/hr_view.lua): header, Helltide timer, reset wave, cinders and goal,
-- NOW, TARGET, the STATS table (This HT / Session / All time) and OPENED
-- THIS WAVE; the Rows option; rebuilt at most 4x a second, a frame replays a
-- cached draw list (no vec2 made while nothing changed); a failing host call
-- turns it off with one log line; missing data never breaks it.
-- QQT_Warpigz_v3: Overlay appearance: anchor + offsets, font size, width,
-- one / two columns, colour presets, accent, background, bars, compact and
-- the section toggles; readable default contrast under the host's
-- text-beneath-the-panel compositing; no overlap at several font sizes.
-- Runs under Lua 5.4 and LuaJIT.
local H = dofile(assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/audit/tests/hr_smart_harness.lua')
local R = H.runner('Helltide overlay')
local ok, eq = R.ok, R.eq
local v = H.v

local function session(opts)
    local s = H.new(opts or {cinders = 660, zone = 'Kehj_Oasis'})
    s.stats = s.require('core.hr_stats')
    s.atlas = s.require('core.hr_atlas')
    s.overlay = s.require('core.hr_overlay')
    s.tracker.hr_stats, s.tracker.hr_atlas = s.stats, s.atlas
    s.atlas.set_zone('Kehj_Oasis')
    return s
end

local function has(lines, text)
    for _, l in ipairs(lines) do
        if l:find(text, 1, true) then return l end
    end
    return nil
end

local function walking(s)
    s.tracker.hr_in_ht = true
    s.tracker.hr_task_state = 'MOVING_TO_REMEMBERED_CHEST'
    s.tracker.hr_get_remembered = function()
        return {k1 = {name = 'Helltide_RewardChest_Random', cost = 75, position = v(33, -780)},
            k2 = {name = 'usz_rewardGizmo_Uber', cost = 250, position = v(300, 0)}}, 'k1'
    end
    s.pos = v(33, -672)
end

R.case('all rows: every section in order with the live numbers', function()
    local s = session()
    walking(s)
    s.at_minute(10); s.stats.tick(s.now, 600, true, 'Kehj_Oasis'); s.advance(0.3)
    s.stats.tick(s.now, 660, true, 'Kehj_Oasis')
    s.at_minute(21, 40)
    s.stats.on_chest_opened('usz_rewardGizmo_Uber', 250, v(377, -622))
    s.advance(440)
    s.at_minute(29, 0)
    local lines = s.overlay.build(s.now, s.pos)
    local want = {'HELLTIDE  Kehjistan  RUNNING', 'Ends in  26m 00s', 'Wave  3 of 6  reset :30 in 1m 00s',
        'CINDERS  660  +', 'Goal  Ready: 75 for Random chest', 'This HT  +60 earned  -0 spent  -0 lost',
        'NOW', 'Activity  Walking to chest', 'Movement  Direct path', 'In Helltide  Yes', 'Plan  ',
        'TARGET', 'Chest  Random chest  75', 'Distance  108 m  |  seen', 'Position  33, -780',
        'STATS  This HT  Session  All time', 'Chests  1  1  1', 'Mystery  1  1  1', 'Earned  60  60  60',
        'Spent  0  0  0', 'Lost  0  0  0', 'Deaths  0  0  0', 'Time  ', 'Cinders/min  ',
        'OPENED THIS WAVE', 'Mystery 250  7m 20s ago  at 377, -622', 'To open  1 mystery  1 regular  0 learned',
        'Opened this Helltide: 1'}
    local last = 0
    for _, text in ipairs(want) do
        local found
        for i = last + 1, #lines do
            if lines[i]:find(text, 1, true) then found = i; break end
        end
        ok(found ~= nil, 'line in order: ' .. text .. '\n' .. table.concat(lines, '\n'))
        last = found or last
    end
    local w, h = s.overlay.size()
    eq(w, s.overlay.WIDTH)
    local L = s.overlay.current()
    ok(L.two, 'two columns by default')
    ok(h > 250 and h < 450, 'panel height ' .. h)
    -- every text op fits its column (approximate glyph width)
    for _, op in ipairs(s.overlay.ops()) do
        if op.k == 't' then
            local x = op.x >= L.x2 and L.two and op.x - L.x2 or op.x
            ok(x + #op.s * L.cw <= L.iw + 1, 'fits: ' .. op.s)
        end
    end
end)

R.case('Rows: Helltide only shows the This HT column; Timers + cinders stops after the cinders', function()
    local s = session()
    walking(s)
    s.set('overlay_rows', 1)
    local lines = s.overlay.build(s.now, s.pos)
    ok(has(lines, 'This HT') and not has(lines, 'Session'), 'This HT only')
    ok(has(lines, 'TARGET') and has(lines, 'OPENED THIS WAVE'))
    s.set('overlay_rows', 2)
    lines = s.overlay.build(s.now, s.pos)
    ok(has(lines, 'CINDERS') and has(lines, 'Ends in'), 'timers + cinders keeps the timer and cinders')
    ok(not has(lines, 'STATS') and not has(lines, 'NOW') and not has(lines, 'TARGET'), 'compact')
end)

R.case('missing data: fresh plugin, no task, after the Helltide, a Mystery goal not reached', function()
    local s = session({cinders = 0, zone = 'Kehj_Oasis'})
    local lines = s.overlay.build(s.now, s.pos)
    ok(has(lines, 'HELLTIDE') and has(lines, 'SEARCHING'), 'no task yet')
    ok(has(lines, 'Chest  none'), 'no target')
    ok(has(lines, 'In Helltide  ?'), 'unknown')
    ok(has(lines, 'Activity  Idle'), 'idle')
    ok(has(lines, 'nothing yet'), 'nothing opened')
    ok(has(lines, 'Need 75 more for Chest (75)'), 'the plain goal')
    s.at_minute(57)
    lines = s.overlay.build(s.now, s.pos)
    ok(has(lines, 'Next HT in  3m 00s') and not has(lines, 'Wave '), 'between Helltides')
    ok(has(lines, 'IDLE'))
    s.cinders = 100
    s.at_minute(5)
    s.tracker.hr_in_ht = false
    s.tracker.hr_task_state = 'MOVING_TO_REMEMBERED_CHEST'
    s.tracker.hr_get_remembered = function()
        return {k = {name = 'usz_rewardGizmo_Uber', cost = 250, position = v(10, 0), predicted = true}}, 'k'
    end
    lines = s.overlay.build(s.now, s.pos)
    ok(has(lines, 'Need 150 more for Mystery (250)'), 'Mystery goal')
    ok(has(lines, 'Distance  10 m  |  learned spot'), 'a learned target')
    ok(has(lines, 'In Helltide  No'))
    s.tracker.hr_get_remembered = function() error('task not loaded') end
    lines = s.overlay.build(s.now, s.pos)
    ok(has(lines, 'Chest  none'), 'a failing reader is no target')
end)

R.case('rebuilt at most 4x a second; frames replay the cached list without new vec2', function()
    local s = session()
    walking(s)
    local builds, vec2s = 0, 0
    local build = s.overlay.build
    s.overlay.build = function(...) builds = builds + 1; return build(...) end
    local mk = s.env.vec2.new
    s.env.vec2.new = function(...) vec2s = vec2s + 1; return mk(...) end
    s.draws = {}
    for _ = 1, 120 do                                          -- 2 s at 60 fps
        s.advance(1 / 60)
        ok(s.overlay.render(s.now, s.pos), 'drawn')
    end
    ok(builds >= 8 and builds <= 9, 'rebuilds in 2 s: ' .. builds)
    -- a text op draws its shadow copies, then itself (titles twice: bold)
    local L = s.overlay.current()
    local texts, calls, others = 0, 0, 0
    for _, op in ipairs(s.overlay.ops()) do
        if op.k == 't' then
            texts = texts + 1
            calls = calls + 1 + #L.shadows + (op.bold and 1 or 0)
        else others = others + 1 end
    end
    eq(#L.shadows, 2, 'Bright: two shadow copies')
    eq(s.draws.text_2d, 120 * calls, 'text_2d per text op per frame: shadows + text (+ bold)')
    ok(calls <= texts * 4, 'at most 4 calls per text op')
    ok((s.draws.rect_filled or 0) >= 120 and (s.draws.line or 0) >= 120, 'background, bars and dividers')
    local per_build = calls + 2 * others + 2
    ok(vec2s <= builds * per_build, 'vec2 only on rebuilds: ' .. vec2s .. ' <= ' .. builds * per_build)
    -- moving the panel rebuilds the absolute list once
    vec2s = 0
    s.set('overlay_pos_x', 40)
    s.overlay.render(s.now, s.pos); s.overlay.render(s.now, s.pos)
    ok(vec2s > 0 and vec2s <= per_build, 'one re-layout for the move: ' .. vec2s)
    s.overlay.build = build
    s.env.vec2.new = mk
end)

R.case('colours: color.new when the host has it, the named colours otherwise', function()
    local s = session()
    s.overlay._reset()
    local made = 0
    s.env.color = {new = function(r, g, b, a) made = made + 1; return {r, g, b, a} end}
    ok(s.overlay.render(s.now, s.pos))
    ok(made >= 10, 'palette from color.new')
    local s2 = session()
    s2.overlay._reset()
    ok(s2.overlay.render(s2.now, s2.pos), 'no color global: named colours')
end)

R.case('a failing host call turns the overlay off with one log line; the option gates drawing', function()
    local s = session()
    s.overlay._reset()
    s.env.graphics = setmetatable({text_2d = function() error('host: text_2d broke') end}, {__index = function()
        return function() end
    end})
    eq(s.overlay.render(s.now, s.pos), false)
    for _ = 1, 50 do s.advance(0.1); eq(s.overlay.render(s.now, s.pos), false) end
    eq(s.logged('overlay off for this session'), 1, 'one line')
    ok(s.overlay.is_broken())
    s.overlay._reset()
    s.set('overlay', false)
    eq(s.overlay.render(s.now, s.pos), false, 'option off')
end)

-- r32 review: the chest order's last plan outlived the order. Under WarPigs
-- (and manual Warplan) the order is asked only while a cinder run is
-- engaged; after the run ended the overlay / dashboard kept "Opening chests,
-- Mystery first" (and could keep the old target) for the rest of the
-- Helltide although Warplan opens chests on the way.
R.case('a cinder run that ended (WarPigs): the plan line no longer shows the order\'s old plan', function()
    local s = session({cinders = 3000})
    s.set('mode', 0); s.set('cinder_run', true); s.set('cinder_run_at', 3000)
    local order, targets = s.require('core.hr_chest_order'), s.require('core.chest_targets')
    local mode = s.require('core.hr_mode')
    mode.set_external(true)
    s.tracker.hr_chest_order, s.tracker.hr_mode = order, mode
    s.tracker.hr_cinder_run = s.require('core.hr_cinder_run')
    local view = s.require('core.hr_view')
    local function pick(actors)
        return order.pick({actors = actors, remembered = {}, key_of = targets.key,
            blacklisted = function() return false end, player = s.pos, cinders = s.cinders, now = s.now})
    end
    local p = pick({H.actor('Warplan_Helltide_HellsPrize', 30, 0)})
    eq(p and p.name, 'Warplan_Helltide_HellsPrize', 'the run picks the Hell\'s Prize')
    eq(view.plan(), 'Cinder run: opening chests, best first')
    eq(view.target(s.pos).short, "Hell's Prize", 'the run target')
    s.cinders = 60
    eq(pick({H.actor('usz_rewardGizmo_Gloves', 30, 0)}), nil, 'below the cheapest chest: the run ends')
    eq(order.enabled(), false, 'the order is no longer asked')
    ok(type(order.last_plan) == 'table', 'its last plan is left over')
    eq(view.plan(), 'Warplan: chests on the way', 'the plan line (was "Opening chests, Mystery first")')
    -- a run switched off mid-trip leaves the target in the last plan
    s.cinders = 3000
    pick({H.actor('Warplan_Helltide_HellsPrize', 30, 0)})
    ok(order.last_plan.target_name ~= nil, 'a run target')
    s.set('cinder_run', false)
    eq(view.target(s.pos), nil, 'no stale target once the run is off')
    s.overlay._reset()
    local lines = s.overlay.build(s.now, s.pos)
    ok(has(lines, 'Chest  none'), 'overlay TARGET: none')
    eq(has(lines, 'Opening chests, Mystery first'), nil)
end)

-- ── QQT_Warpigz_v3: Overlay appearance ───────────────────────────────────

-- A walking run with opened chests (every section has data).
local function busy(s)
    walking(s)
    s.at_minute(5); s.stats.tick(s.now, 0, true, 'Kehj_Oasis'); s.advance(0.3)
    for i = 1, 20 do s.advance(15); s.stats.tick(s.now, 12 * i, true, 'Kehj_Oasis') end
    s.at_minute(21, 3); s.stats.on_chest_opened('usz_rewardGizmo_Uber', 250, v(377, -622))
    s.at_minute(23, 30); s.stats.on_chest_opened('usz_rewardGizmo_Amulet', 125, v(489, -765))
    s.at_minute(26, 12)
end

local function built(s)
    s.overlay.build(s.now, s.pos)
    local w, h = s.overlay.size()
    return w, h, s.overlay.current()
end

R.case('appearance defaults: menu defaults match the settings, readable two-column panel off the party frames', function()
    local s = session()
    local e, st = s.gui.elements, s.settings
    local want = {overlay = true, overlay_rows = 0, overlay_anchor = 0, overlay_pos_x = 1, overlay_pos_y = 3,
        overlay_font = 15, overlay_columns = 1, overlay_width = 0, overlay_bg = 25, overlay_theme = 0,
        overlay_accent = 0, overlay_bars = true, overlay_compact = false, overlay_show_timer = true,
        overlay_show_wave = true, overlay_show_cinders = true, overlay_show_now = true,
        overlay_show_target = true, overlay_show_stats = true, overlay_show_opened = true}
    for k, val in pairs(want) do
        eq(st[k], val, 'setting ' .. k)
        eq(e[k]:get(), val, 'menu ' .. k)
    end
    eq(e.overlay_x, nil, 'old Position X id retired')
    eq(st.overlay_x, nil)
    busy(s)
    local w, h, L = built(s)
    eq(L.font, 15); ok(L.two, 'two columns')
    ok(h <= 0.40 * 1080, 'default height at most 40% of 1080p: ' .. h)
    ok(w <= 0.50 * 1920, 'default width at most half of 1920: ' .. w)
    -- the game's party frames: left edge, about 44-56% of the height
    for _, res in ipairs({{1920, 1080}, {2560, 1440}, {3840, 2160}}) do
        local x, y = s.overlay.position(res[1], res[2])
        ok(y + h < 0.44 * res[2] or x > 0.12 * res[1], 'clear of the party frames at ' .. res[1])
    end
    -- the menu renders the appearance subsection
    local seen = {}
    for k in pairs(want) do
        local el = e[k]
        el.render = function() seen[k] = true end
    end
    s.gui.render()
    for k in pairs(want) do ok(seen[k], 'menu shows ' .. k) end
end)

R.case('anchor and offsets place the panel in each corner, clamped on screen', function()
    local s = session()
    busy(s)
    s.set('overlay_pos_x', 2); s.set('overlay_pos_y', 5)
    local w, h = built(s)
    local sw, sh = 1920, 1080
    local expect = {{38, 54}, {sw - w - 38, 54}, {38, sh - h - 54}, {sw - w - 38, sh - h - 54}}
    for a = 0, 3 do
        s.set('overlay_anchor', a)
        local x, y = s.overlay.position(sw, sh)
        eq(x, expect[a + 1][1], 'x anchor ' .. a); eq(y, expect[a + 1][2], 'y anchor ' .. a)
    end
    s.set('overlay_anchor', 0); s.set('overlay_pos_x', 60); s.set('overlay_pos_y', 90)
    local x, y = s.overlay.position(sw, sh)
    eq(x, sw - w, 'kept on screen (x)'); eq(y, sh - h, 'kept on screen (y)')
    -- the drawn background follows (render uses the host's screen size)
    s.set('overlay_anchor', 3); s.set('overlay_pos_x', 0); s.set('overlay_pos_y', 0)
    local rects = {}
    s.env.graphics = setmetatable({rect_filled = function(a, b) rects[#rects + 1] = {a, b} end},
        {__index = function() return function() end end})
    ok(s.overlay.render(s.now, s.pos))
    eq(rects[1][1].x, sw - w); eq(rects[1][2].y, sh, 'bottom right corner')
end)

R.case('font size scales lines, columns, bars and the panel; width sets the column', function()
    local s = session()
    busy(s)
    local sizes = {}
    for _, f in ipairs({10, 15, 22, 28}) do
        s.set('overlay_font', f)
        local w, h, L = built(s)
        sizes[#sizes + 1] = {f = f, w = w, h = h, L = L}
        eq(L.font, f); eq(L.lh, math.ceil(f * 1.25), 'line height from the font')
        ok(math.abs(L.cw - 0.57 * f) < 1e-9, 'glyph width from the font')
    end
    for i = 2, #sizes do
        ok(sizes[i].w > sizes[i - 1].w and sizes[i].h > sizes[i - 1].h, 'bigger font, bigger panel ' .. sizes[i].f)
    end
    s.set('overlay_font', 99)
    local _, _, L = built(s)
    eq(L.font, 28, 'font clamped')
    s.set('overlay_font', 15); s.set('overlay_columns', 0)
    s.set('overlay_width', 520)
    local w1, _, L1 = built(s)
    ok(w1 <= 520 and w1 > 500, 'width in px: ' .. w1)
    eq(L1.cols, math.floor((520 - 2 * L1.pad) / L1.cw))
    s.set('overlay_width', 100)
    local _, _, L2 = built(s)
    eq(L2.cols, 30, 'at least 30 columns')
    for _, op in ipairs(s.overlay.ops()) do
        if op.k == 't' then ok(op.x + #op.s * L2.cw <= L2.iw + 1, 'narrow: cut to fit: ' .. op.s) end
        if op.k == 'r' then ok(op.x2 <= L2.iw, 'bar inside the panel') end
    end
end)

R.case('sections, columns, bars and compact: only what is enabled is laid out', function()
    local s = session()
    busy(s)
    s.set('overlay_columns', 0)
    local _, h_all = built(s)
    local keys = {
        {'overlay_show_timer', 'Ends in'}, {'overlay_show_wave', 'Wave  '}, {'overlay_show_cinders', 'CINDERS'},
        {'overlay_show_now', 'Activity'}, {'overlay_show_target', 'TARGET'}, {'overlay_show_stats', 'STATS'},
        {'overlay_show_opened', 'OPENED THIS WAVE'},
    }
    for _, k in ipairs(keys) do
        s.set(k[1], false)
        local lines = s.overlay.build(s.now, s.pos)
        local _, h = s.overlay.size()
        ok(not has(lines, k[2]), k[1] .. ' off: no ' .. k[2])
        ok(h < h_all, k[1] .. ' off: shorter panel ' .. h .. ' < ' .. h_all)
        ok(has(lines, 'HELLTIDE'), 'the header stays')
        s.set(k[1], true)
    end
    for _, k in ipairs(keys) do s.set(k[1], false) end
    local lines = s.overlay.build(s.now, s.pos)
    local _, h_min, L = built(s)
    eq(#lines, 1, 'every section off: the header only')
    ok(h_min <= L.lh + 2 * L.pad, 'header-only height ' .. h_min)
    for _, k in ipairs(keys) do s.set(k[1], true) end
    -- two columns: about half as tall, STATS / OPENED on the right
    s.set('overlay_columns', 1)
    local w2, h2, L2 = built(s)
    ok(h2 < h_all * 0.65 and w2 > L2.iw * 2, 'two columns: ' .. w2 .. 'x' .. h2)
    for _, op in ipairs(s.overlay.ops()) do
        if op.k == 't' and (op.s == 'STATS' or op.s == 'OPENED THIS WAVE') then eq(op.x, L2.x2, op.s .. ' on the right') end
        if op.k == 't' and (op.s == 'HELLTIDE' or op.s == 'NOW') then eq(op.x, 0, op.s .. ' on the left') end
    end
    s.set('overlay_show_stats', false); s.set('overlay_show_opened', false)
    local _, _, L3 = built(s)
    ok(not L3.two, 'nothing for the right column: one column')
    s.set('overlay_show_stats', true); s.set('overlay_show_opened', true)
    -- bars
    s.set('overlay_bars', false)
    s.overlay.build(s.now, s.pos)
    for _, op in ipairs(s.overlay.ops()) do ok(op.k ~= 'r', 'bars off: no rectangle') end
    s.set('overlay_bars', true)
    -- compact: shorter, same numbers
    s.set('overlay_columns', 0)
    local _, h_full = built(s)
    s.set('overlay_compact', true)
    lines = s.overlay.build(s.now, s.pos)
    local _, h_c, Lc = built(s)
    ok(h_c < h_full * 0.8, 'compact is shorter: ' .. h_c .. ' < ' .. h_full)
    ok(has(lines, 'Activity  Walking to chest') and has(lines, 'Chests  2  2') and has(lines, 'CINDERS  660'), 'compact keeps the data')
    ok(not has(lines, 'NOW') and not has(lines, 'Position') and not has(lines, '/hr'), 'compact drops the extras')
    eq(Lc.dividers, false, 'compact: no divider lines')
    -- Rows = Timers + cinders overrides the lower sections
    s.set('overlay_compact', false); s.set('overlay_rows', 2)
    lines = s.overlay.build(s.now, s.pos)
    ok(has(lines, 'CINDERS') and not has(lines, 'STATS') and not has(lines, 'Activity'), 'timers + cinders')
end)

-- Relative luminance / contrast ratio (WCAG).
local function lum(c)
    local function ch(x) x = x / 255; return x <= 0.03928 and x / 12.92 or ((x + 0.055) / 1.055) ^ 2.4 end
    return 0.2126 * ch(c[1]) + 0.7152 * ch(c[2]) + 0.0722 * ch(c[3])
end
local function contrast(a, b)
    local la, lb = lum(a), lum(b)
    if la < lb then la, lb = lb, la end
    return (la + 0.05) / (lb + 0.05)
end
-- The host composites text BENEATH the panel: a text pixel ends up as
-- text * (1 - a) + bg * a.
local function under(c, bg, a)
    return {c[1] * (1 - a) + bg[1] * a, c[2] * (1 - a) + bg[2] * a, c[3] * (1 - a) + bg[3] * a}
end

R.case('readable contrast: default and every preset, with the host drawing text beneath the panel', function()
    local s = session()
    s.env.color = {new = function(r, g, b, a) return {r, g, b, a} end}
    busy(s)
    local names = {'head', 'label', 'text', 'dim', 'amber', 'green', 'red'}
    local function check(tag, min_shadow, min_dark)
        s.overlay._reset()
        s.overlay.build(s.now, s.pos)
        ok(s.overlay.render(s.now, s.pos), tag .. ' drawn')
        local L, p = s.overlay.current(), s.overlay.colors()
        local a = L.bg_alpha / 100
        for _, n in ipairs(names) do
            local c = under(p[n], p.bg, a)
            local shadow = under(p.shadow, p.bg, a)
            -- body text (label / text / dim) to min_shadow, colours to at least 4.5
            local need = (n == 'label' or n == 'text' or n == 'dim') and min_shadow or math.min(min_shadow, 4.5)
            ok(contrast(c, shadow) >= need, string.format('%s %s vs its shadow %.1f', tag, n, contrast(c, shadow)))
            local scene = under({40, 36, 34}, p.bg, a)   -- a dark Helltide scene under the panel
            ok(contrast(c, scene) >= min_dark, string.format('%s %s on a dark scene %.1f', tag, n, contrast(c, scene)))
            ok(#L.shadows >= 1, tag .. ': text has a shadow')
        end
        return L, p
    end
    local L = check('Bright (default)', 7, 4.5)
    ok(L.bg_alpha <= 40, 'default panel is light: text beneath it keeps its brightness')
    eq(#L.shadows, 2)
    for i = 1, 6 do
        s.set('overlay_accent', i - 1)
        check('accent ' .. s.overlay.ACCENTS[i], 4.5, 3)
    end
    s.set('overlay_accent', 0)
    s.set('overlay_theme', 1); check('Classic', 4.5, 3)
    s.set('overlay_theme', 2)
    local Lm = check('Minimal', 7, 4.5)
    eq(Lm.bg_alpha, 0, 'Minimal: no panel'); eq(#Lm.shadows, 4, 'Minimal: outline')
    -- the 3.2.2 look (80% panel over the text) measured ~20% brightness live
    local old_label = under({150, 160, 175}, {8, 11, 16}, 205 / 255)
    ok(contrast(old_label, under({40, 36, 34}, {8, 11, 16}, 205 / 255)) < 1.5, 'the old default was unreadable')
    -- background opacity only darkens the panel when asked
    s.set('overlay_theme', 0); s.set('overlay_bg', 0)
    s.overlay._reset()
    local rects = 0
    s.env.graphics = setmetatable({rect_filled = function() rects = rects + 1 end}, {__index = function() return function() end end})
    s.set('overlay_bars', false)
    s.overlay.render(s.now, s.pos)
    eq(rects, 0, 'opacity 0: no background rectangle')
end)

R.case('no overlap: rows, columns, bars and dividers at several font sizes and layouts', function()
    local s = session()
    busy(s)
    for _, cols in ipairs({0, 1}) do
        for _, compact in ipairs({false, true}) do
            for _, f in ipairs({10, 12, 15, 18, 22, 28}) do
                s.set('overlay_columns', cols); s.set('overlay_compact', compact); s.set('overlay_font', f)
                s.overlay.build(s.now, s.pos)
                local w, h = s.overlay.size()
                local L = s.overlay.current()
                local tag = string.format('font %d cols %d compact %s', f, cols + 1, tostring(compact))
                local boxes, prims = {}, {}
                for _, op in ipairs(s.overlay.ops()) do
                    if op.k == 't' then
                        ok(op.s ~= '' and op.s:match('^%s') == nil and op.s:match('%s$') == nil, tag .. ': clean token "' .. op.s .. '"')
                        boxes[#boxes + 1] = {x1 = op.x, x2 = op.x + #op.s * L.cw, y1 = op.y, y2 = op.y + L.font, s = op.s}
                    elseif op.k == 'r' then
                        if op.c == 'track' then prims[#prims + 1] = {x1 = op.x1, x2 = op.x2, y1 = op.y1, y2 = op.y2} end
                    else
                        prims[#prims + 1] = {x1 = op.x1, x2 = op.x2, y1 = op.y, y2 = op.y + 1}
                    end
                end
                local function hit(a, b) return a.x1 < b.x2 and b.x1 < a.x2 and a.y1 < b.y2 and b.y1 < a.y2 end
                local bad = 0
                for i = 1, #boxes do
                    local a = boxes[i]
                    if a.x2 > w - 2 * L.pad + 1 or a.y2 > h - 2 * L.pad + L.lh then bad = bad + 1 end
                    for j = i + 1, #boxes do
                        if hit(a, boxes[j]) then bad = bad + 1; ok(false, tag .. ': ' .. a.s .. ' / ' .. boxes[j].s) end
                    end
                    for _, p in ipairs(prims) do
                        if hit(a, p) then bad = bad + 1; ok(false, tag .. ': a bar or line crosses ' .. a.s) end
                    end
                end
                eq(bad, 0, tag .. ': no overlap, inside the panel')
                for _, p in ipairs(prims) do ok(p.x2 <= w - 2 * L.pad and p.y2 <= h - 2 * L.pad + L.lh, tag .. ': bar inside') end
            end
        end
    end
end)

R.finish()
