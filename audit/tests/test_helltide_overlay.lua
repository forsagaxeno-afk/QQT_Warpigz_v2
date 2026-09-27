-- QQT_Warpigz_v3: the sectioned stats overlay (core/hr_overlay.lua over
-- core/hr_view.lua): header, Helltide timer, reset wave, cinders and goal,
-- NOW, TARGET, the STATS table (This HT / Session / All time) and OPENED
-- THIS WAVE; the Rows option; rebuilt at most 4x a second, a frame replays a
-- cached draw list (no vec2 made while nothing changed); a failing host call
-- turns it off with one log line; missing data never breaks it. Runs under
-- Lua 5.4 and LuaJIT.
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
    local want = {'HELLTIDE  Kehjistan  RUNNING', 'Helltide ends in  26m 00s', 'Wave 3 of 6  |  next reset :30 in 1m 00s',
        'CINDERS', '660  +', 'Ready: 75 for Random chest', 'This HT  +60 earned | -0 spent | -0 lost',
        'NOW', 'Activity  Walking to chest', 'Movement  Direct path', 'In Helltide  Yes', 'Plan  ',
        'TARGET', 'Chest  Random chest  75', 'Distance  108 m  |  seen', 'Position  33, -780',
        'STATS', 'This HT  Session  All time', 'Chests  1  1  1', 'Mystery  1  1  1', 'Earned  60  60  60',
        'Spent  0  0  0', 'Lost  0  0  0', 'Deaths  0  0  0', 'Time  ', 'Cinders/min  ',
        'OPENED THIS WAVE', 'Mystery 250  7m 20s ago  at 377, -622', 'Still to open: 1 mystery | 1 regular | 0 learned',
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
    ok(h > 500 and h < 900, 'panel height ' .. h)
    -- every text op fits the panel width (approximate glyph width)
    for _, op in ipairs(s.overlay.ops()) do
        if op.k == 't' then
            ok(op.x + #op.s * s.overlay.CHAR_W <= w - s.overlay.PAD * 2 + 1, 'fits: ' .. op.s)
        end
    end
end)

R.case('Rows: Helltide only shows the This HT column; Compact stops after the cinders', function()
    local s = session()
    walking(s)
    s.set('overlay_rows', 1)
    local lines = s.overlay.build(s.now, s.pos)
    ok(has(lines, 'This HT') and not has(lines, 'Session'), 'This HT only')
    ok(has(lines, 'TARGET') and has(lines, 'OPENED THIS WAVE'))
    s.set('overlay_rows', 2)
    lines = s.overlay.build(s.now, s.pos)
    ok(has(lines, 'CINDERS') and has(lines, 'Helltide ends in'), 'compact keeps the timer and cinders')
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
    ok(has(lines, 'Next Helltide in  3m 00s') and not has(lines, 'Wave '), 'between Helltides')
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
    local texts = 0
    for _, op in ipairs(s.overlay.ops()) do if op.k == 't' then texts = texts + 1 end end
    eq(s.draws.text_2d, 120 * texts, 'one text_2d per text op per frame')
    ok((s.draws.rect_filled or 0) >= 120 and (s.draws.line or 0) >= 120, 'background, bars and dividers')
    local per_build = 2 * #s.overlay.ops() + 2
    ok(vec2s <= builds * per_build, 'vec2 only on rebuilds: ' .. vec2s .. ' <= ' .. builds * per_build)
    -- moving the panel rebuilds the absolute list once
    vec2s = 0
    s.set('overlay_x', 40)
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

R.finish()
