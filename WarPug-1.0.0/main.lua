local gui      = require 'gui'
local settings = require 'core.settings'
local planner  = require 'core.planner'
local external = require 'core.external'

local last_tick     = 0
local TICK_INTERVAL = 0.5

-- Manual calibration remains available while disabled. The press edge and
-- context snapshot prevent repeats or a delayed confirmation after interruption.
local test_down, test_pending = false, nil
local function tick_test()
    local now = get_time_since_inject()
    local kb = gui.elements.keybind_test_clicks
    local down = kb:get_state() == 1 and kb:get_key() ~= 0x0A
    local pressed = down and not test_down
    test_down = down
    if test_pending then
        local p = test_pending
        if gui.elements.main_toggle:get() or planner.click_context() ~= p.world or
            now - p.t > 4 or get_screen_width() ~= p.width or get_screen_height() ~= p.height or
            not settings.confirm_set or settings.reroll_confirm_x ~= p.x or settings.reroll_confirm_y ~= p.y then
            test_pending = nil
            if gui.elements.main_toggle:get() then
                planner.stop('Calibration test interrupted; inspect the panel before retrying')
            end
            console.print('[WarPug] test cancelled: context, calibration or deadline changed')
        elseif now - p.t >= 1.5 then
            test_pending = nil
            if planner.fire_click(p.x, p.y, 'RerollConfirm') then
                console.print('[WarPug] test: sequence complete')
            end
        end
        return
    end
    if not pressed then return end
    local key = planner.click_context()
    if gui.elements.main_toggle:get() or not key or not settings.reroll_set or not settings.confirm_set then
        console.print('[WarPug] test: disable WarPug, capture both positions, and open an empty war plan panel in Temis')
        return
    end
    if planner.fire_click(settings.reroll_click_x, settings.reroll_click_y, 'Reroll') then
        test_pending = { t = now, world = key, x = settings.reroll_confirm_x, y = settings.reroll_confirm_y,
            width = get_screen_width(), height = get_screen_height() }
    end
end

local main_pulse = function()
    gui.poll_keybinds()
    settings:update_settings()
    tick_test()
    -- Always process a stop, including during loading or with no player.
    if settings.enabled and get_time_since_inject() - last_tick < TICK_INTERVAL then return end
    last_tick = get_time_since_inject()
    planner.tick()
end

-- ── Rendering ────────────────────────────────────────────────────────────────

local COL_CROSSHAIR = color_green(220)

local function draw_crosshair(cx, cy, label, col)
    local arm = 12
    graphics.line(vec2:new(cx - arm, cy), vec2:new(cx + arm, cy), col, 2)
    graphics.line(vec2:new(cx, cy - arm), vec2:new(cx, cy + arm), col, 2)
    graphics.circle_2d(vec2:new(cx, cy), 5, col, 1)
    graphics.text_2d(label, vec2:new(cx + 14, cy - 8), 14, col)
end

local render_pulse = function()
    -- Click-position overlays are shown regardless of enable state so the
    -- user can calibrate coordinates with the plugin paused.
    if gui.elements.show_click_points:get() then
        local sw, sh = get_screen_width(), get_screen_height()
        local p = gui.positions
        if p.reroll_set then
            draw_crosshair(math.floor(p.reroll_rx * sw),
                           math.floor(p.reroll_ry * sh),
                           'Reroll', COL_CROSSHAIR)
        end
        if p.confirm_set then
            draw_crosshair(math.floor(p.confirm_rx * sw),
                           math.floor(p.confirm_ry * sh),
                           'RerollConfirm', COL_CROSSHAIR)
        end
    end

    -- Fading yellow circle for each recent scripted click (~6s TTL)
    local clicks, fade = planner.get_recent_clicks()
    if clicks and #clicks > 0 then
        local t = get_time_since_inject()
        for _, c in ipairs(clicks) do
            local age   = t - c.t
            local alpha = math.max(0, math.min(255, math.floor(255 * (1 - age / fade))))
            local col   = color_yellow(alpha)
            graphics.circle_2d(vec2:new(c.x, c.y), 14, col, 2)
            graphics.circle_2d(vec2:new(c.x, c.y),  3, col, 2)
            graphics.text_2d(
                string.format('%s (%.1fs)', c.label, age),
                vec2:new(c.x + 18, c.y + 10), 13, col)
        end
    end

    if not settings.enabled then return end
    local msg = planner.get_status_line()
    if not msg then return end
    local x_pos = get_screen_width() / 2 - (#msg * 5.5)
    graphics.text_2d(msg, vec2:new(x_pos, 120), 20, color_white(255))
end

on_update(main_pulse)
on_render_menu(function() gui.render() end)
on_render(render_pulse)

WarPugPlugin = external
