local plugin_label   = 'war_pug'
local plugin_version = '1.0.11'
console.print('Lua Plugin - WarPug - War Plan Creator - v' .. plugin_version)

local gui = {}

local function ck(value, key)
    return checkbox:new(value, get_hash(plugin_label .. '_' .. key))
end

gui.plugin_label   = plugin_label
gui.plugin_version = plugin_version

-- ── Captured click positions ─────────────────────────────────────────────────
-- Stored as RELATIVE coords (0..1 of screen w/h) so values stay correct if
-- the user changes resolution. Persisted to positions.txt in the plugin root.
-- The file format is plain `key=value` lines so we don't need a JSON parser
-- for four numbers.
--
-- We keep this in a side-table because pushing values back into a slider via
-- `:set()` is unreliable on this user's QQT host (past investigations showed
-- it can crash mid-frame / corrupt UI state).
gui.positions = {
    reroll_rx   = 0.0,
    reroll_ry   = 0.0,
    confirm_rx  = 0.0,
    confirm_ry  = 0.0,
    reroll_set  = false,
    confirm_set = false,
}

local function get_plugin_root_path()
    -- Match the actual module path on either Windows or Unix.
    local path = package.searchpath and package.searchpath('gui', package.path)
    if path then return path:match('^(.*[/\\])') or '' end
    return package.path:match('^([^;]-)%?') or ''
end

local POS_FILE = get_plugin_root_path() .. 'positions.txt'
local coordinate_fields = { reroll_rx = true, reroll_ry = true, confirm_rx = true, confirm_ry = true }
local function valid_fraction(value)
    return type(value) == 'number' and value == value and value >= 0 and value < 1
end
function gui.valid_position(rx, ry)
    return valid_fraction(rx) and valid_fraction(ry)
end
-- Earlier releases shipped the author's own capture with *_set=true, so a
-- fresh install fired native clicks at another layout's buttons. Those exact
-- values count as "not captured"; the user must capture their own positions.
local SHIPPED_CAPTURE = { reroll_rx = 0.179541, reroll_ry = 0.971173, confirm_rx = 0.713987, confirm_ry = 0.728628 }
local function shipped_capture(loaded, field_x, field_y)
    local x, y = loaded[field_x], loaded[field_y]
    return type(x) == 'number' and type(y) == 'number' and
        math.abs(x - SHIPPED_CAPTURE[field_x]) < 5e-7 and math.abs(y - SHIPPED_CAPTURE[field_y]) < 5e-7
end

local function save_positions()
    local file, err = io.open(POS_FILE, 'w')
    if not file then
        console.print('[WarPug] failed to open ' .. POS_FILE .. ' for write: ' .. tostring(err))
        return false
    end
    local ok, failure = pcall(function()
        for _, key in ipairs({ 'reroll_rx', 'reroll_ry', 'confirm_rx', 'confirm_ry' }) do
            assert(file:write(string.format('%s=%.9f\n', key, gui.positions[key])))
        end
        assert(file:write('reroll_set=' .. tostring(gui.positions.reroll_set) .. '\n'))
        assert(file:write('confirm_set=' .. tostring(gui.positions.confirm_set) .. '\n'))
    end)
    local closed, close_error = file:close()
    if not ok or not closed then
        console.print('[WarPug] positions could not be saved: ' .. tostring(failure or close_error))
        return false
    end
    return true
end

local function load_positions()
    local file = io.open(POS_FILE, 'r')
    if not file then return end
    local loaded = {}
    local ok = pcall(function()
        for line in file:lines() do
            local k, v = line:match('^([%w_]+)=(.-)%s*$')
            if k == 'reroll_set' or k == 'confirm_set' then
                loaded[k] = (v == 'true')
            elseif coordinate_fields[k] then
                local n = tonumber(v)
                if valid_fraction(n) then loaded[k] = n end
            end
        end
    end)
    file:close()
    if not ok then return end
    for key in pairs(coordinate_fields) do
        if loaded[key] ~= nil then gui.positions[key] = loaded[key] end
    end
    local shipped_reroll = shipped_capture(loaded, 'reroll_rx', 'reroll_ry')
    local shipped_confirm = shipped_capture(loaded, 'confirm_rx', 'confirm_ry')
    gui.positions.reroll_set = loaded.reroll_set == true and not shipped_reroll and
        gui.valid_position(loaded.reroll_rx, loaded.reroll_ry)
    gui.positions.confirm_set = loaded.confirm_set == true and not shipped_confirm and
        gui.valid_position(loaded.confirm_rx, loaded.confirm_ry)
    if (shipped_reroll and loaded.reroll_set == true) or (shipped_confirm and loaded.confirm_set == true) then
        console.print('[WarPug] positions.txt holds the calibration shipped with older releases; ' ..
            'capture your own Reroll and Confirm positions before WarPug can reroll')
    end
end

load_positions()

-- ── GUI elements ─────────────────────────────────────────────────────────────
gui.elements = {
    main_tree   = tree_node:new(0),
    main_toggle = ck(false, 'main_toggle'),

    -- 0x0A = harness convention for "no key bound yet" (matches WarPigs/HordeDev).
    -- Second arg `true` matches the predominant working pattern across this
    -- codebase (Alfred / HordeDev / Batmobile / MapRevealPathTest). With
    -- `false`, presses weren't registering as state==1 on this host.
    keybind_set_reroll  = keybind:new(0x0A, true, get_hash(plugin_label .. '_kb_set_reroll')),
    keybind_set_confirm = keybind:new(0x0A, true, get_hash(plugin_label .. '_kb_set_confirm')),
    keybind_test_clicks = keybind:new(0x0A, true, get_hash(plugin_label .. '_kb_test_clicks')),

    show_click_points = ck(false, 'show_click_points'),
    verbose_logs      = ck(false, 'verbose_logs'),
}

local function fmt_pos(rx, ry, set)
    if not set then return 'not captured' end
    local sw, sh = get_screen_width(), get_screen_height()
    local px = math.floor(rx * sw)
    local py = math.floor(ry * sh)
    return string.format('rel %.3f, %.3f  (= %dpx, %dpx at %dx%d)',
                         rx, ry, px, py, sw, sh)
end

-- One-shot keybinds follow the suite convention (Batmobile, SilentRaven): act
-- once on get_state()==1, then reset the toggle latch with :set(false) so the
-- next press registers again. A latch that is still set after our reset needs
-- an observed release first, so a host that ignores :set(false) keeps the old
-- edge behaviour instead of repeating. A latch already set at the first poll
-- was restored by the host, not pressed: it is cleared without acting.
local PRESS_DEBOUNCE = 0.5
local press_state = {}
function gui.consume_press(kb, id)
    local ok, down = pcall(function() return kb:get_state() == 1 and kb:get_key() ~= 0x0A end)
    down = ok and down == true
    local rec = press_state[id]
    if not rec then
        press_state[id] = { armed = not down, t = -math.huge }
        if down then
            pcall(function() kb:set(false) end)
            console.print('[WarPug] cleared a restored ' .. id .. ' key state; press it again to use it')
        end
        return false
    end
    if not down then rec.armed = true; return false end
    if not rec.armed then return false end
    rec.armed = false
    pcall(function() kb:set(false) end)
    local t = get_time_since_inject()
    if t - rec.t < PRESS_DEBOUNCE then return false end
    rec.t = t
    return true
end

-- Polls the capture keybinds. Called every on_update tick (not gated by the
-- planner's TICK_INTERVAL) so a key press is never missed.
--
-- One capture per press: holding a key never repeatedly rewrites calibration.
function gui.poll_keybinds()
    local function capture(kb, field_x, field_y, field_set, label)
        if not gui.consume_press(kb, field_set) then return end
        local ok, cx, cy = pcall(function() return utility.get_cursor_screen_position() end)
        local sw, sh = get_screen_width(), get_screen_height()
        if not ok or type(cx) ~= 'number' or type(cy) ~= 'number' or
            sw <= 0 or sh <= 0 or not gui.valid_position(cx / sw, cy / sh) then
            console.print('[WarPug] capture failed: cursor must be inside the game client')
            return
        end
        gui.positions[field_x], gui.positions[field_y] = cx / sw, cy / sh
        gui.positions[field_set] = true
        local saved = save_positions()
        console.print(string.format('[WarPug] %s captured: %dpx, %dpx (%s)',
            label, cx, cy, saved and 'saved' or 'current session only'))
    end
    capture(gui.elements.keybind_set_reroll, 'reroll_rx', 'reroll_ry', 'reroll_set', 'Reroll')
    capture(gui.elements.keybind_set_confirm, 'confirm_rx', 'confirm_ry', 'confirm_set', 'RerollConfirm')
end

-- ── Render ────────────────────────────────────────────────────────────────────
gui.render = function()
    if not gui.elements.main_tree:push('Z | War Pug | War Plan Creator | v' .. plugin_version) then
        return
    end

    gui.elements.main_toggle:render('Enable',
        'When in Temis with no active WarPlans quests, auto-select and confirm\n' ..
        'a new war plan path. Warplans_NightmareDungeons nodes are always excluded.\n' ..
        'Existing selections are preserved. Rerolls use your captured positions.\n' ..
        'On a stopped status, inspect the panel and toggle Enable to retry.')

    render_menu_header('Click position calibration')

    gui.elements.keybind_set_reroll:render('Set Reroll Pos',
        'Hover the war plan reroll/refresh button in-game, then press this key\n' ..
        'to capture its position. Values are saved as relative (0..1) coordinates\n' ..
        'to scale with resolution. Recheck after changing the UI layout.\n\n' ..
        'Currently saved: ' .. fmt_pos(gui.positions.reroll_rx,
                                       gui.positions.reroll_ry,
                                       gui.positions.reroll_set))
    gui.elements.keybind_set_confirm:render('Set Confirm Pos',
        'Hover the confirm button on the reroll dialog, then press this key\n' ..
        'to capture its position.\n\n' ..
        'Currently saved: ' .. fmt_pos(gui.positions.confirm_rx,
                                       gui.positions.confirm_ry,
                                       gui.positions.confirm_set))
    gui.elements.keybind_test_clicks:render('Test Click Sequence',
        'Fires the same Reroll click \xe2\x86\x92 1.5s wait \xe2\x86\x92 Confirm click\n' ..
        'sequence the planner would. Uses the captured positions, the same\n' ..
        'mouse_move + mouse_click path, and the same yellow-fade overlay so\n' ..
        'you can verify both targets land on the right buttons before\n' ..
        'enabling WarPug.\n\n' ..
        'Disable WarPug before testing — the test refuses to run while the\n' ..
        'live state machine is active. Open the war plan panel in Temis first.\n' ..
        'Tests stop on death, loading, quest or cleanup activity, and late ticks.')

    render_menu_header('Diagnostics')
    gui.elements.show_click_points:render('Show click positions',
        'Draw green crosshairs at both captured click targets. Recent scripted\n' ..
        'clicks also appear as a fading yellow circle for ~6s after firing.')
    gui.elements.verbose_logs:render('Verbose logs',
        'Print extra state-transition detail to the console.')

    gui.elements.main_tree:pop()
end

return gui
