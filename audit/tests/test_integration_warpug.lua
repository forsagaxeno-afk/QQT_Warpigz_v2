-- Integration regressions for WarPug (review items WPT-3/WPG-4, WPG-5, WPG-6,
-- WPG-9, CRT-5, SRV-4 WarPug side, WPG-1). Real WarPug modules run against
-- QQT-shaped mocks; one case also runs the real WarPigs dispatcher.
local root = assert(SUITE_ROOT) .. '/WarPug-1.0.0/'
local pigs_root = SUITE_ROOT .. '/WarPigs-1.0.0/'
local real_io, real_package_path = io, package.path

local failures, checks = {}, 0
local function equal(actual, expected, message)
    checks = checks + 1
    if actual ~= expected then
        error((message or 'mismatch') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
end
local function truthy(value, message) equal(not not value, true, message) end
local function case(name, fn)
    local ok, err = pcall(fn)
    io, package.path = real_io, real_package_path
    if not ok then failures[#failures + 1] = name .. ': ' .. tostring(err) end
end
local function copy(list)
    local out = {}
    for i = 1, #list do out[i] = list[i] end
    return out
end
local function any_log(f, needle)
    for _, line in ipairs(f.logs) do if line:find(needle, 1, true) then return true end end
    return false
end
local function count_log(f, needle)
    local n = 0
    for _, line in ipairs(f.logs) do if line:find(needle, 1, true) then n = n + 1 end end
    return n
end

local function load_planner(settings)
    local env = setmetatable({ require = function(name)
        assert(name == 'core.settings', 'unexpected planner dependency: ' .. tostring(name))
        return settings
    end }, { __index = _G })
    return assert(loadfile(root .. 'core/planner.lua', 't', env))()
end

local VALID = { root = { 3 }, [3] = { 4 } }
local BLOCKED_TREE = { root = { 1 } }
local function fixture(opts)
    opts = opts or {}
    local f = { now = 100, dead = false, player = true, zone = 'Skov_Temis', world = 7,
        ready = opts.ready ~= false, quests = {}, path = {}, required = 2, confirms = 0, selections = 0,
        deselections = 0, clicks = {}, interacts = 0, moves = 0, width = 1000, height = 800, dist = 0,
        logs = {} }
    f.settings = { enabled = true, table_actor_name = 'Warplans_Vendor', verbose_logs = false,
        reroll_set = true, confirm_set = true, reroll_click_x = 150, reroll_click_y = 700,
        reroll_confirm_x = 700, reroll_confirm_y = 550 }
    f.names = { [1] = 'Warplans_NightmareDungeons', [2] = 'Warplans_ThePit', [3] = 'Warplans_Helltide',
        [4] = 'Warplans_InfernalHordes' }
    f.edges = opts.blocked and BLOCKED_TREE or VALID
    WarPigsPlugin, WarPugPlugin, AlfredTheButlerPlugin, PLUGIN_alfred_the_butler = nil, nil, nil, nil
    SilentRavenPlugin, PLUGIN_silent_raven, LooteerPlugin = nil, nil, nil
    console = { print = function(m) f.logs[#f.logs + 1] = string.format('%.1f %s', f.now, m) end }
    get_time_since_inject = function() return f.now end
    get_local_player = function() if f.player then return { is_dead = function() return f.dead end } end end
    get_current_world = function()
        if f.world then return { get_current_zone_name = function() return f.zone end,
            get_world_id = function() return f.world end, get_name = function() return 'Sanctuary' end } end
    end
    get_quests = function()
        local out = {}
        for i, name in pairs(f.quests) do out[i] = { get_name = function() return name end } end
        return out
    end
    get_screen_width = function() return f.width end
    get_screen_height = function() return f.height end
    warplan = {
        is_ready = function() return f.ready end,
        required_picks = function() return f.required end,
        selected_count = function() return #f.path end,
        selected_path = function() return copy(f.path) end,
        is_complete = function() return #f.path == f.required end,
        get_selectable_now = function() return f.edges[f.path[#f.path] or 'root'] or {} end,
        node_name = function(id) return f.names[id] end,
        select_node = function(id)
            for _, legal in ipairs(warplan.get_selectable_now()) do
                if legal == id then f.path[#f.path + 1] = id; f.selections = f.selections + 1; return true end
            end
            return false
        end,
        deselect_last = function() f.deselections = f.deselections + 1; return table.remove(f.path) ~= nil end,
        confirm = function() f.confirms = f.confirms + 1 end,
    }
    utility = {
        send_mouse_move = function() end,
        send_mouse_click = function(x, y)
            f.clicks[#f.clicks + 1] = { x, y }
            -- A confirmed reroll deals a board with a valid path.
            if x == f.settings.reroll_confirm_x and y == f.settings.reroll_confirm_y then f.edges = VALID end
        end,
    }
    actors_manager = { get_all_actors = function()
        return { { get_skin_name = function() return 'Warplans_Vendor' end,
            get_position = function() return {} end } }
    end }
    get_player_position = function() return { dist_to = function() return f.dist end } end
    pathfinder = { request_move = function() f.moves = f.moves + 1 end }
    interact_vendor = function() f.interacts = f.interacts + 1; f.ready = true end
    f.p = load_planner(f.settings)
    f.halted_at = nil
    function f.tick(dt)
        f.now = f.now + (dt or 0.5); f.p.tick()
        if not f.halted_at and f.p.get_current_state() == 'HALTED' then f.halted_at = f.now end
    end
    function f.state() return f.p.get_current_state() end
    function f.run(seconds, stop_at)
        local deadline = f.now + seconds
        while f.now < deadline do
            f.tick()
            if stop_at and f.state() == stop_at then return true end
        end
        return stop_at == nil
    end
    function f.until_state(wanted, limit)
        for _ = 1, limit or 120 do if f.state() == wanted then return end; f.tick() end
        error('never reached ' .. wanted .. '; got ' .. f.state() .. ' (' .. tostring(f.p.get_status_line()) .. ')', 2)
    end
    return f
end

-- WPT-3 / WPG-4: a session admitted under WarPigs' short completed-cycle grace
-- latches Alfred admission. The sticky advisory need_trigger that outlives the
-- grace must not stop a reroll that is already under way.
case('WPT-3 latched Alfred admission survives the expiring grace', function()
    local f = fixture({ blocked = true })
    AlfredTheButlerPlugin = { get_status = function() return { enabled = true, need_trigger = true } end }
    local grace_end = f.now + 3
    WarPigsPlugin = { status = function()
        return { enabled = true, busy = false, alfred_idle = f.now < grace_end }
    end }
    f.tick(); equal(f.state(), 'FIND_PATH', 'admitted under the grace')
    truthy(f.run(60, 'DONE_WAIT'), 'session completes after the grace expired: ' .. tostring(f.p.get_status_line()))
    equal(f.halted_at, nil, 'never halted')
    equal(f.confirms, 1); equal(#f.clicks, 2, 'one reroll + one reroll confirmation')
    truthy(f.now > grace_end + 3, 'the session outlived the grace')
    -- Live work and hard needs still stop an admitted session.
    for _, hard in ipairs({ { running = true }, { pending = true }, { inventory_full = true }, { need_repair = true } }) do
        local g = fixture({ ready = false }); g.dist = 10
        local s = { enabled = true, need_trigger = true }
        AlfredTheButlerPlugin = { get_status = function() return s end }
        WarPigsPlugin = { status = function() return { enabled = true, busy = false, alfred_idle = true } end }
        g.tick(); equal(g.state(), 'APPROACH_TABLE')
        for k, v in pairs(hard) do s[k] = v end
        local moves = g.moves
        g.run(20); equal(g.state(), 'IDLE', 'paused for Alfred work'); equal(g.moves, moves, 'no movement while Alfred owns town')
    end
end)

-- The same latch with the actual WarPigs dispatcher and a Steroid-like Alfred
-- whose restock need_trigger never clears.
case('WPT-3 real WarPigs dispatcher with sticky restock need_trigger', function()
    -- A long walk to the table plus a reroll outlasts WarPigs' 20 s grace.
    local f = fixture({ blocked = true, ready = false }); f.dist = 12
    pathfinder.request_move = function() f.moves = f.moves + 1; f.dist = math.max(0, f.dist - 0.25) end
    local pigs_settings = { use_teleport_transition = true, manage_whispers = false, run_pit_after_turnin = false,
        get_keybind_state = function() return true end }
    package.path = pigs_root .. '?.lua;' .. real_package_path
    for _, name in ipairs({ 'core.settings', 'gui', 'wp_silent_raven', 'core.tasks.turn_in_rewards', 'core.orchestrator' }) do
        package.loaded[name] = nil
    end
    package.loaded['core.settings'] = pigs_settings
    package.loaded.gui = { elements = { main_toggle = { get = function() return true end, set = function() end } } }
    package.loaded['core.tasks.turn_in_rewards'] = dofile(pigs_root .. 'core/tasks/turn_in_rewards.lua')
    local o = dofile(pigs_root .. 'core/orchestrator.lua'); package.loaded['core.orchestrator'] = o
    WarPigsPlugin = dofile(pigs_root .. 'core/external.lua')
    WarPugPlugin = assert(loadfile(root .. 'core/external.lua', 't', setmetatable({
        require = function(name) return name == 'core.settings' and f.settings or f.p end,
    }, { __index = _G })))()
    attributes = { PLAYER_IN_TOWN_LEVEL_AREA = 1 }
    get_local_player = function() return { is_dead = function() return false end,
        get_attribute = function() return 1 end, get_buffs = function() return {} end,
        get_position = function() return {} end } end
    local status = { enabled = true, need_trigger = true, trigger_tasks = false }
    local cb, busy_until
    AlfredTheButlerPlugin = { get_status = function() return status end,
        trigger_tasks = function(_, callback) cb = callback; status.trigger_tasks = true; busy_until = f.now + 6; return true end }
    local done_at, started_at
    for _ = 1, 600 do
        f.now = f.now + 0.5
        if busy_until and f.now >= busy_until then busy_until = nil; status.trigger_tasks = false; if cb then cb(true) end end
        o.tick(); f.p.tick()
        if not started_at and f.state() ~= 'IDLE' then started_at = f.now end
        if f.state() == 'HALTED' then break end
        if f.state() == 'DONE_WAIT' then done_at = f.now; break end
    end
    equal(f.state(), 'DONE_WAIT', 'WarPug completes: ' .. tostring(f.p.get_status_line()))
    equal(f.confirms, 1)
    truthy(done_at and started_at and done_at - started_at > 20, 'the session outlived the 20 s grace')
    WarPigsPlugin, WarPugPlugin = nil, nil
    for _, name in ipairs({ 'core.settings', 'gui', 'wp_silent_raven', 'core.tasks.turn_in_rewards', 'core.orchestrator' }) do
        package.loaded[name] = nil
    end
end)

-- WPG-5: the suite-wide Alfred predicate (C1).
case('WPG-5 canonical Alfred predicate', function()
    local function start_state(status, seconds)
        local f = fixture()
        AlfredTheButlerPlugin = { get_status = function()
            if status == 'throws' then error('stale') end
            return status
        end }
        f.run(seconds or 2)
        return f.state(), f
    end
    equal(start_state({ enabled = true, pending = true }), 'IDLE', 'queued Alfred work (pending) holds')
    equal(start_state({ enabled = true, teleport = true }), 'IDLE', 'teleport in flight holds')
    equal(start_state({ enabled = true, teleport = true, teleport_done = true }), 'DONE_WAIT',
        'finished teleport latch is not live work')
    equal(start_state({ enabled = true, teleport = true, teleport_failed = true }), 'DONE_WAIT',
        'failed teleport latch is not live work')
    equal(start_state({ enabled = false, trigger_tasks = true, inventory_full = true }), 'DONE_WAIT',
        'disabled Alfred is not busy')
    equal(start_state({ enabled = true, paused = true, need_trigger = true }), 'DONE_WAIT',
        'foreign pause without hard need is idle')
    equal(start_state({ enabled = true, paused = true, inventory_full = true }, 120), 'IDLE',
        'hard need holds even while paused')
    equal(start_state({ enabled = true, need_repair = true }, 120), 'IDLE', 'repair need holds')
    -- Unreadable status holds for at most ~10 s, then Alfred counts as unavailable.
    for _, bad in ipairs({ 'throws', { enabled = 'yes' } }) do
        local state, f = start_state(bad, 9)
        equal(state, 'IDLE', 'unreadable Alfred briefly holds')
        truthy(f.run(10, 'DONE_WAIT'), 'unreadable Alfred stops holding after ~10s')
        equal(count_log(f, 'treating Alfred as unavailable'), 1, 'one diagnostic line')
    end
    -- A sticky advisory flag with no WarPigs grace holds a new session only briefly.
    for _, pigs in ipairs({ false, { enabled = false, busy = false, alfred_idle = true },
        { enabled = true, busy = false, alfred_idle = false } }) do
        local f = fixture()
        if pigs then WarPigsPlugin = { status = function() return pigs end } end
        AlfredTheButlerPlugin = { get_status = function() return { enabled = true, need_trigger = true } end }
        f.run(29); equal(f.state(), 'IDLE', 'advisory need_trigger holds a new session briefly')
        truthy(f.run(5, 'FIND_PATH') or f.state() == 'DONE_WAIT', 'advisory hold is bounded')
        equal(count_log(f, 'stayed advisory'), 1)
    end
end)

-- WPG-4 / SRV-4 / C5: companion work mid-session pauses instead of a permanent
-- HALT; paused time does not count toward the session timeout.
case('WPG-4 companion work pauses and resumes the session', function()
    local f = fixture({ ready = false }); f.dist = 10
    local looting = false
    LooteerPlugin = { get_enabled = function() return true end, is_actively_looting = function() return looting end }
    WarPugPlugin = assert(loadfile(root .. 'core/external.lua', 't', setmetatable({
        require = function(name) return name == 'core.settings' and f.settings or f.p end,
    }, { __index = _G })))()
    f.tick(); f.tick(); equal(f.state(), 'APPROACH_TABLE'); truthy(f.moves > 0)
    looting = true; f.tick()
    equal(f.state(), 'IDLE', 'paused, not halted'); equal(f.halted_at, nil)
    equal(WarPugPlugin.status().state, 'IDLE', 'companions see an idle planner while it yields')
    local moves = f.moves
    f.run(200)
    equal(f.moves, moves, 'no movement while the Looter owns town')
    truthy(tostring(f.p.get_status_line()):find('paused for Looter busy', 1, true), 'status line names the hold')
    truthy(count_log(f, 'still waiting for town work') >= 3, 'long hold is logged every 60s')
    looting = false; f.dist = 0
    f.tick(); f.tick(); equal(f.state(), 'IDLE', 'short quiet window before resuming')
    truthy(f.run(30, 'DONE_WAIT'), 'resumed session completes: ' .. tostring(f.p.get_status_line()))
    equal(f.halted_at, nil, 'paused time did not trip the 180s session timeout'); equal(f.confirms, 1)
    truthy(any_log(f, 'Resuming after'), 'resume logged')

    -- SilentRaven auto-fire mid-search (unmanaged mode) is waited out, too.
    local g = fixture({ blocked = true })
    local raven = { enabled = true, running = false }
    SilentRavenPlugin = { get_status = function() return raven end }
    g.until_state('REROLL_WAIT1'); equal(#g.clicks, 1)
    raven.running = true; g.run(20)
    equal(#g.clicks, 1, 'no delayed confirmation while another plugin owns town'); equal(g.state(), 'IDLE')
    raven.running = false
    truthy(g.run(60, 'DONE_WAIT'), 'resumes with a fresh reroll: ' .. tostring(g.p.get_status_line()))
    equal(g.halted_at, nil); equal(g.confirms, 1)
    equal(#g.clicks, 3, 'interrupted reroll redone after a fresh interaction'); equal(g.clicks[2][1], 150)
    equal(g.clicks[3][1], 700)
    truthy(g.p.get_status_line():find('reroll 2/10', 1, true), 'reroll budget carried across the pause')
end)

case('WPG-4 paused complete selection is confirmed only after revalidation', function()
    local f = fixture()
    local s = { enabled = true }
    AlfredTheButlerPlugin = { get_status = function() return s end }
    f.until_state('CONFIRMING'); equal(table.concat(f.path, ','), '3,4')
    s.running = true; f.tick(); equal(f.state(), 'IDLE'); equal(f.confirms, 0)
    f.run(10); s.running = false
    truthy(f.run(10, 'DONE_WAIT'), 'owned path resumes to confirmation')
    equal(f.confirms, 1); equal(f.deselections, 0, 'own selection kept'); equal(table.concat(f.path, ','), '3,4')
    -- A user edit while paused is never auto-confirmed.
    local g = fixture(); local gs = { enabled = true }
    AlfredTheButlerPlugin = { get_status = function() return gs end }
    g.until_state('CONFIRMING'); gs.running = true; g.tick(); g.path = { 3 }; gs.running = false
    g.run(10); equal(g.confirms, 0); equal(g.state(), 'HALTED')
    -- A world change while paused with a selection on the board still stops.
    local h = fixture(); local hs = { enabled = true }
    AlfredTheButlerPlugin = { get_status = function() return hs end }
    h.until_state('CONFIRMING'); hs.running = true; h.tick(); h.world = 8; hs.running = false
    h.run(10); equal(h.confirms, 0); equal(h.state(), 'HALTED')
    truthy(tostring(h.p.get_status_line()):find('World changed', 1, true))
end)

-- C6: a pre-session hold is visible and rate-limited.
case('C6 long companion holds are logged and shown', function()
    local f = fixture()
    LooteerPlugin = { get_enabled = function() return true end, is_actively_looting = function() return true end }
    f.run(130)
    equal(f.state(), 'IDLE'); equal(count_log(f, 'still waiting for town work'), 2, 'one line per 60s')
    truthy(tostring(f.p.get_status_line()):find('waiting for Looter busy', 1, true), f.p.get_status_line())
end)

-- CRT-5: every submitted node is named at info level.
case('CRT-5 submitted path is logged by node name', function()
    local f = fixture(); f.until_state('DONE_WAIT')
    truthy(any_log(f, 'Submitting war plan path: Warplans_Helltide -> Warplans_InfernalHordes'),
        'submitted node names logged')
end)

-- WPG-1: the planner must not depend on Lua 5.2's table.unpack.
case('WPG-1 planner works without table.unpack', function()
    local saved_unpack, saved_global = table.unpack, rawget(_G, 'unpack')
    unpack = saved_global or saved_unpack
    table.unpack = nil
    local ok, err = pcall(function()
        local f = fixture({ blocked = true })
        truthy(f.run(60, 'DONE_WAIT'), 'plans with rerolls on a 5.1 library: ' .. tostring(f.p.get_status_line()))
        equal(f.confirms, 1)
        f.settings.enabled = false; f.tick()
    end)
    table.unpack, unpack = saved_unpack, saved_global
    assert(ok, err)
end)

-- Real GUI with a virtual positions.txt and toggle-mode keybinds.
local function gui_env(contents, keybinds)
    local f = { writes = 0, saved = '', now = 100, x = 200, y = 300, logs = {} }
    local function element(value)
        return { value = value, get = function(self) return self.value end, set = function(self, v) self.value = v end }
    end
    local function toggle_key(state)
        -- QQT toggle keybind: each press flips the latch; set(false) clears it.
        return { state = state or 0, key = 65, get_state = function(self) return self.state end,
            get_key = function(self) return self.key end,
            set = function(self, v) self.state = v and 1 or 0 end,
            press = function(self) self.state = 1 - self.state end }
    end
    local env = setmetatable({
        checkbox = { new = function(_, value) return element(value) end },
        keybind = { new = function(_, _, _, hash)
            local k = toggle_key(keybinds and keybinds[hash] or 0); f.keys = f.keys or {}; f.keys[hash] = k; return k
        end },
        tree_node = { new = function() return {} end },
        get_hash = function(s) return s end,
        console = { print = function(m) f.logs[#f.logs + 1] = m end },
        get_screen_width = function() return 1000 end,
        get_screen_height = function() return 800 end,
        get_time_since_inject = function() return f.now end,
        utility = { get_cursor_screen_position = function() return f.x, f.y end },
        io = { open = function(path, mode)
            if path ~= root .. 'positions.txt' then return nil, 'unexpected path ' .. tostring(path) end
            if mode == 'r' then
                if not contents then return nil end
                return { lines = function() return contents:gmatch('[^\n]+') end, close = function() return true end }
            end
            f.saved, f.writes = '', f.writes + 1
            return { write = function(_, chunk) f.saved = f.saved .. chunk; return true end,
                close = function() return true end }
        end },
    }, { __index = _G })
    package.path = root .. '?.lua;' .. real_package_path
    f.gui = assert(loadfile(root .. 'gui.lua', 't', env))()
    package.path = real_package_path
    f.env = env
    return f
end
local function read_file(path)
    local file = assert(real_io.open(path, 'r'))
    local text = file:read('*a'); file:close(); return text
end

-- WPG-6: a fresh install (shipped file) and the calibration shipped by older
-- releases are "not captured"; the planner then never fires a native click.
case('WPG-6 shipped calibration never fires blind clicks', function()
    local shipped = gui_env(read_file(root .. 'positions.txt'))
    equal(shipped.gui.positions.reroll_set, false, 'shipped reroll position is uncalibrated')
    equal(shipped.gui.positions.confirm_set, false, 'shipped confirm position is uncalibrated')
    local legacy = gui_env('reroll_rx=0.179541\nreroll_ry=0.971173\nconfirm_rx=0.713987\nconfirm_ry=0.728628\n' ..
        'reroll_set=true\nconfirm_set=true\n')
    equal(legacy.gui.positions.reroll_set, false, 'old shipped reroll capture rejected')
    equal(legacy.gui.positions.confirm_set, false, 'old shipped confirm capture rejected')
    truthy(legacy.logs[#legacy.logs]:find('shipped with older releases', 1, true), 'user told to capture')
    local user = gui_env('reroll_rx=0.250000000\nreroll_ry=0.960000000\nconfirm_rx=0.700000000\n' ..
        'confirm_ry=0.720000000\nreroll_set=true\nconfirm_set=true\n')
    equal(user.gui.positions.reroll_set, true, 'user capture still loads')
    equal(user.gui.positions.confirm_set, true, 'user capture still loads')
    -- Real settings + real planner on the shipped file: a reroll-only board stops
    -- with the capture hint and zero native clicks.
    local f = fixture({ blocked = true })
    local settings_env = setmetatable({ require = function(name)
        assert(name == 'gui'); return shipped.gui
    end }, { __index = shipped.env })
    local settings = assert(loadfile(root .. 'core/settings.lua', 't', settings_env))()
    settings:update_settings(); settings.enabled = true
    equal(settings.reroll_set, false); equal(settings.confirm_set, false)
    f.p = load_planner(settings)
    f.until_state('HALTED')
    equal(#f.clicks, 0, 'no blind native clicks')
    truthy(f.p.get_status_line():find('Capture valid Reroll and Confirm positions', 1, true), f.p.get_status_line())
end)

-- WPG-9: toggle-mode capture/test keybinds register every press.
case('WPG-9 every capture press registers', function()
    local f = gui_env(nil)
    local kb = f.keys['war_pug_kb_set_confirm']
    f.gui.poll_keybinds()
    for i = 1, 3 do
        f.x = 100 * i; kb:press(); f.gui.poll_keybinds(); f.now = f.now + 1; f.gui.poll_keybinds()
        equal(f.writes, i, 'press ' .. i .. ' captured')
    end
    equal(f.gui.positions.confirm_rx, 0.3)
    f.gui.poll_keybinds(); f.gui.poll_keybinds(); equal(f.writes, 3, 'no repeat without a press')
    -- A latch restored by the host at load is cleared without capturing.
    local r = gui_env(nil, { war_pug_kb_set_reroll = 1 })
    r.gui.poll_keybinds(); r.now = r.now + 1; r.gui.poll_keybinds()
    equal(r.writes, 0, 'restored latch does not capture'); equal(r.keys['war_pug_kb_set_reroll'].state, 0)
    r.keys['war_pug_kb_set_reroll']:press(); r.gui.poll_keybinds(); equal(r.writes, 1, 'next real press captures')
end)

case('WPG-9 every test-sequence press registers', function()
    local g = gui_env(nil)
    local f = fixture(); f.settings.enabled = false
    local kb = g.keys['war_pug_kb_test_clicks']
    local stub = { positions = {}, elements = { main_toggle = { value = false, get = function(self) return self.value end },
        keybind_test_clicks = kb, show_click_points = { get = function() return false end } },
        poll_keybinds = function() end, consume_press = g.gui.consume_press }
    f.settings.update_settings = function() f.settings.enabled = stub.elements.main_toggle:get() end
    package.loaded.gui, package.loaded['core.settings'], package.loaded['core.planner'] = stub, f.settings, f.p
    package.loaded['core.external'] = {}
    local update
    on_update = function(fn) update = fn end
    on_render_menu, on_render = function() end, function() end
    color_green = function() return {} end
    g.env.get_time_since_inject = function() return f.now end
    dofile(root .. 'main.lua')
    for _, name in ipairs({ 'gui', 'core.settings', 'core.planner', 'core.external' }) do package.loaded[name] = nil end
    local function pulse(dt) f.now = f.now + (dt or 0.5); update() end
    pulse()
    kb:press(); pulse(); pulse(2); equal(#f.clicks, 2, 'first test sequence')
    kb:press(); pulse(); pulse(2); equal(#f.clicks, 4, 'second press runs a second sequence')
    pulse(); pulse(3); equal(#f.clicks, 4, 'no repeat without a press')
end)

if #failures > 0 then error('WarPug integration failures:\n' .. table.concat(failures, '\n')) end
print('PASS WarPug integration: latched Alfred admission, canonical Alfred predicate, pause/resume for companion work, ' ..
    'bounded visible holds, logged plan nodes, no blind shipped calibration, one-shot keybinds, 5.1 library (' ..
    checks .. ' checks)')
