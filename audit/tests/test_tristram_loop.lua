-- TristramLoop, shipped beside WarPigz as a standalone plugin. Its real main.lua
-- is loaded into a mocked QQT host with a plugin-folder-relative require (as
-- QQT resolves it), then driven through its registered callbacks.
local count, failures = 0, {}
local function eq(a, b, message)
    assert(a == b, (message or 'mismatch') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
    count = count + 1
end
local function ok(v, message) assert(v, message or 'expected truthy'); count = count + 1 end
local function case(name, run)
    local passed, err = pcall(run)
    if not passed then failures[#failures + 1] = name .. ': ' .. tostring(err) end
end

local function read(path)
    local f = assert(io.open(path, 'r')); local s = f:read('*a'); f:close(); return s
end

-- ── mocked host ────────────────────────────────────────────────────────────
local function vec(x, y, z)
    local v = { _x = x or 0, _y = y or 0, _z = z or 0 }
    function v:x() return self._x end
    function v:y() return self._y end
    function v:z() return self._z end
    function v:squared_dist_to_ignore_z(o) local dx, dy = self._x - o:x(), self._y - o:y(); return dx * dx + dy * dy end
    function v:dist_to(o) return math.sqrt(self:squared_dist_to_ignore_z(o)) end
    function v:dist_to_ignore_z(o) return self:dist_to(o) end
    function v:distance_squared(o) return self:squared_dist_to_ignore_z(o) end
    function v:to_vec2() return v end
    function v:is_zero() return self._x == 0 and self._y == 0 end
    return v
end

local function host(opts)
    opts = opts or {}
    local h = { now = 1000, callbacks = { update = {}, render = {}, menu = {}, key = {} }, prints = {},
        clicks = {}, keys = {}, strings = {}, native_revives = 0, saved = opts.saved or {},
        dead = false, world = 'Skov_Temis', zone = 'Skov_Temis', world_id = 7, writes = {},
        widgets = {}, labels = {} }
    local e = setmetatable({}, { __index = _G })
    e._G = e
    h.e = e
    local function widget(kind, default, id)
        local w = { kind = kind, id = id, value = default }
        if id ~= nil and h.saved[id] ~= nil then w.value = h.saved[id] end
        function w:get() return self.value end
        function w:set(v) self.value = v end
        function w:render(label) h.labels[#h.labels + 1] = label end
        function w:get_key() return self.value end
        function w:get_state() return 0 end
        if id ~= nil then h.widgets[id] = w end
        return w
    end
    e.get_hash = function(s) return s end
    e.checkbox = { new = function(_, d, id) return widget('checkbox', d, id) end }
    e.slider_int = { new = function(_, lo, hi, d, id) local w = widget('slider_int', d, id); w.min, w.max, w.default = lo, hi, d; return w end }
    e.slider_float = { new = function(_, lo, hi, d, id) local w = widget('slider_float', d, id); w.min, w.max, w.default = lo, hi, d; return w end }
    e.combo_box = { new = function(_, d, id) return widget('combo_box', d, id) end }
    e.input_text = { new = function(_, id) return widget('input_text', '', id) end }
    e.keybind = { new = function(_, d, _, id) return widget('keybind', d, id) end }
    e.button = { new = function(_, id) local w = widget('button', false, id); return w end }
    e.tree_node = { new = function() return { push = function() return true end, pop = function() end } end }
    e.render_menu_header = function(s) h.labels[#h.labels + 1] = s end
    e.on_update = function(fn) table.insert(h.callbacks.update, fn) end
    e.on_render = function(fn) table.insert(h.callbacks.render, fn) end
    e.on_render_menu = function(fn) table.insert(h.callbacks.menu, fn) end
    e.on_key_press = function(fn) table.insert(h.callbacks.key, fn) end
    e.console = { print = function(s) h.prints[#h.prints + 1] = tostring(s) end, print_full = function() end }
    e.get_time_since_inject = function() return h.now end
    e.vec2 = { new = function(_, x, y) return vec(x, y, 0) end }
    e.vec3 = { new = function(_, x, y, z) return vec(x, y, z) end }
    local function color() return {} end
    e.color_white, e.color_green, e.color_black, e.color_red, e.color_yellow = color, color, color, color, color
    e.color_blue, e.color_orange, e.color_purple, e.color_cyan, e.color_pink = color, color, color, color, color
    e.color_gray, e.color_grey = color, color
    e.graphics = setmetatable({}, { __index = function() return function() end end })
    e.get_screen_width = function() return 1920 end
    e.get_screen_height = function() return 1080 end
    e.is_inventory_open = function() return false end
    e.is_chat_open = function() return false end
    e.utility = {
        send_key_press = function(k) h.keys[#h.keys + 1] = k end,
        send_key_combo = function() end,
        send_string = function(s) h.strings[#h.strings + 1] = s end,
        send_mouse_click = function(x, y) h.clicks[#h.clicks + 1] = { x, y } end,
        send_mouse_right_click = function(x, y) h.clicks[#h.clicks + 1] = { x, y, right = true } end,
        send_mouse_move = function() end,
        can_cast_spell = function() return false end,
        is_spell_ready = function() return false end,
    }
    e.revive_at_checkpoint = function() h.native_revives = h.native_revives + 1 end
    e.auto_play = { is_active = function() return false end }
    e.orb_mode = { none = 0, clear = 1, pvp = 2, flee = 3 }
    h.orb = 0
    e.orbwalker = { get_orb_mode = function() return h.orb end, set_orbwalker_mode = function(m) h.orb = m end,
        set_clear_toggle = function() end }
    e.pathfinder = { request_move = function() return true end, force_move = function() return true end,
        force_move_raw = function() return true end, clear_stored_path = function() return true end }
    e.actors_manager = { get_all_actors = function() return {} end, get_all_items = function() return {} end,
        get_enemy_npcs = function() return {} end, get_all_particles = function() return {} end,
        get_enemy_actors = function() return {} end, get_ally_actors = function() return {} end }
    e.loot_manager = { is_in_vendor_screen = function() return false end, is_lootable_item = function() return false end,
        loot_item = function() return false end }
    e.target_selector = { get_target_closer = function() return nil end }
    e.use_item = function(item) h.used = (h.used or 0) + 1 end
    e.get_equipped_spell_ids = function() return {} end
    e.cast_spell = { target = function() return false end, self = function() return false end, position = function() return false end }
    e.get_player_position = function() return vec(1, 2, 0) end
    e.get_cursor_position = function() return vec(0, 0, 0) end
    e.get_quests = function() return {} end
    local player = {}
    function player:is_dead() return h.dead end
    function player:get_position() return vec(1, 2, 0) end
    function player:get_buffs() return h.buffs end
    function player:get_consumable_items() return h.consumables end
    function player:get_inventory_items() return h.inventory end
    function player:get_item_count() return 0 end
    function player:get_current_health() return 100 end
    function player:get_max_health() return 100 end
    function player:get_health_potion_count() return 0 end
    function player:get_attribute() return 0 end
    function player:get_active_spell_id() return 0 end
    h.player = player
    e.get_local_player = function() return h.no_player and nil or player end
    e.get_current_world = function()
        return { get_name = function() return h.world end, get_current_zone_name = function() return h.zone end,
            get_world_id = function() return h.world_id end }
    end
    -- Plugin-relative require, as the QQT host resolves it per plugin folder.
    e.package = { loaded = {}, path = '' }
    return h
end

local function load_plugin(h, folder, opts)
    opts = opts or {}
    local e = h.e
    local root = SUITE_ROOT .. '/' .. folder .. '/'
    e.require = function(name)
        if e.package.loaded[name] ~= nil then return e.package.loaded[name] end
        local chunk = assert(loadfile(root .. name:gsub('%.', '/') .. '.lua', 't', e))
        local value = chunk(name)
        if value == nil then value = true end
        e.package.loaded[name] = value
        return value
    end
    local before = {}
    for k in pairs(e) do before[k] = true end
    local chunk = assert(loadfile(root .. 'main.lua', 't', e))
    local result = chunk()
    local added = {}
    for k in pairs(e) do if not before[k] then added[#added + 1] = k end end
    table.sort(added)
    h.added = table.concat(added, ',')
    return result
end

local function run_callbacks(h, which)
    for _, fn in ipairs(h.callbacks[which]) do fn() end
end

-- ── the plugin loads and runs its callbacks ───────────────────────────────
local EXTRAS = {
    { folder = 'TristramLoop', globals = 'TRISTRAM_LOOP_STATE,TristramLoopPlugin' },
}
for _, extra in ipairs(EXTRAS) do
    case(extra.folder .. ' loads in a mocked host and runs its callbacks', function()
        local h = host()
        h.e.io = false; h.e.debug = false -- no persistence during tests
        load_plugin(h, extra.folder)
        eq(h.added, extra.globals, extra.folder .. ' introduces only its documented globals')
        ok(#h.callbacks.update + #h.callbacks.render + #h.callbacks.menu > 0, 'registers callbacks')
        for _ = 1, 3 do
            h.now = h.now + 0.5
            run_callbacks(h, 'update'); run_callbacks(h, 'render'); run_callbacks(h, 'menu')
        end
        eq(h.native_revives, 0, 'no revive while alive')
        eq(#h.clicks, 0, 'no clicks while idle')
    end)
end

case('TristramLoop contains no shell, network or 5.2+ library calls', function()
    local files = {
        'TristramLoop/main.lua',
    }
    for _, name in ipairs({ 'activity_lease', 'bridge_alfred', 'bridge_movement', 'bridge_rotation',
        'combat_policy', 'controller', 'data', 'encounter', 'host', 'native_town', 'navigation', 'party',
        'pony', 'pony_data', 'pony_explorer', 'recovery', 'routes', 'settings', 'storage' }) do
        files[#files + 1] = 'TristramLoop/tristram/' .. name .. '.lua'
    end
    for _, file in ipairs(files) do
        local src = read(SUITE_ROOT .. '/' .. file)
        for _, bad in ipairs({ 'os%.execute', 'io%.popen', 'socket', 'http%.', 'os%.remove', 'os%.rename' }) do
            ok(not src:find(bad), file .. ' must not use ' .. bad)
        end
    end
end)

-- ── TristramLoop settings and status ───────────────────────────────────────
local function tristram(saved)
    local h = host({ saved = saved })
    h.e.io = false; h.e.debug = false
    local api = load_plugin(h, 'TristramLoop')
    local settings = h.e.package.loaded['tristram.settings']
    return h, api, settings
end

case('TristramLoop loot wait is 15-120 minutes, default 60', function()
    local h, _, settings = tristram()
    local w = settings.elements.loot_wait
    eq(w.min, 15, 'loot wait minimum'); eq(w.max, 120, 'loot wait maximum'); eq(w.default, 60, 'loot wait default')
    eq(settings.options().cooldown, 3600, 'default cooldown is one hour')
    w:set(90); eq(settings.options().cooldown, 5400)
    w:set(500); eq(settings.options().cooldown, 7200, 'clamped to 120 minutes')
    eq(settings.elements.delay, nil, 'old 15-30 minute widget is gone')
    -- An old saved 17-minute value on the legacy id cannot leak into the new widget.
    local h2, _, s2 = tristram({ tristram_loop_v1_delay = 17 })
    eq(s2.options().cooldown, 3600, 'legacy saved value ignored')
    local _ = h, h2
end)

case('TristramLoop ships no hardcoded friend', function()
    local _, _, settings = tristram()
    eq(settings.options().friend, '', 'friend defaults to empty')
    eq(settings.elements.friend, nil, 'no preset friend list widget')
    local data = read(SUITE_ROOT .. '/TristramLoop/tristram/data.lua')
    ok(not data:find('FRIENDS'), 'no FRIENDS list')
    for _, file in ipairs({ 'data', 'settings', 'controller', 'party' }) do
        local src = read(SUITE_ROOT .. '/TristramLoop/tristram/' .. file .. '.lua')
        ok(not src:find('Azula') and not src:find('Korra'), file .. ' has no personal friend names')
    end
end)

case('TristramLoop holds with a clear reason when the friend is unset, and exposes stop reason', function()
    local h, api, settings = tristram()
    local e = settings.elements
    eq(api.stop_reason, nil, 'no stop reason before any start')
    e.enabled:set(true)
    h.now = h.now + 1; run_callbacks(h, 'update')
    eq(api.running, false, 'does not start without a friend')
    eq(api.stop_reason, settings.FRIEND_MISSING, 'stop reason names the missing friend')
    eq(api.status().stop_reason, settings.FRIEND_MISSING, 'status() exposes stop reason')
    eq(api.friend_set, false)
    eq(#h.clicks + #h.keys + #h.strings, 0, 'no party input without a friend')
    -- Type a friend, switch Run off and on.
    e.custom_friend:set('  Somebody#1234 ')
    eq(settings.options().friend, 'Somebody#1234', 'friend is trimmed')
    e.enabled:set(false); h.now = h.now + 1; run_callbacks(h, 'update')
    e.enabled:set(true); h.now = h.now + 1; run_callbacks(h, 'update')
    eq(api.running, true, 'starts once a friend is set: ' .. tostring(api.detail))
    eq(api.stop_reason, nil, 'stale stop reason cleared from the published API while running')
    eq(api.friend_set, true)
    eq(api.loot_wait_minutes, 60)
    h.now = h.now + 1; run_callbacks(h, 'update')
    eq(api.phase, 'cooldown', 'waits out the loot wait first')
    ok(api.wait_seconds > 3500 and api.wait_seconds <= 3600, 'first wait uses the 60 minute default: ' .. tostring(api.wait_seconds))
    eq(#h.clicks + #h.keys + #h.strings, 0, 'no party inputs during the wait')
    api.disable()
    h.now = h.now + 1; run_callbacks(h, 'update')
    eq(api.running, false)
    eq(api.stop_reason, 'Stopped by external addon/API control.', 'stop reason published after stop')
    eq(h.e.TRISTRAM_LOOP_ACTIVITY_OWNER, nil, 'activity lease released')
    run_callbacks(h, 'menu'); run_callbacks(h, 'render')
end)

case('TristramLoop publish removes status fields that disappear', function()
    local h, api, settings = tristram()
    settings.elements.enabled:set(true)
    h.now = h.now + 1; run_callbacks(h, 'update')
    ok(api.stop_reason ~= nil, 'reason published while held')
    ok(type(api.enable) == 'function' and type(api.status) == 'function', 'API functions survive publishing')
    settings.elements.custom_friend:set('Friend')
    settings.elements.enabled:set(false); h.now = h.now + 1; run_callbacks(h, 'update')
    settings.elements.enabled:set(true); h.now = h.now + 1; run_callbacks(h, 'update')
    eq(rawget(api, 'stop_reason'), nil, 'published key removed, not left stale')
    ok(type(api.enable) == 'function' and type(api.getState) == 'function', 'API functions still present')
    api.shutdown()
end)















-- ── TristramLoop: friend_set and the Alfred bridge contract ───────────────
case('TristramLoop friend_set follows the live setting after a refused start', function()
    local h, api, settings = tristram()
    settings.elements.enabled:set(true)
    h.now = h.now + 1; run_callbacks(h, 'update')
    eq(api.running, false); eq(api.status().friend_set, false)
    settings.elements.custom_friend:set('Somebody')
    eq(api.status().friend_set, true, 'status() sees the newly typed friend without a restart')
    h.now = h.now + 1; run_callbacks(h, 'update')
    eq(api.friend_set, true, 'published friend_set follows too')
end)

local function real_alfred_external(h)
    local tracker = { external_trigger_callbacks = {} }
    local alfred_settings = { plugin_label = 'alfred', plugin_version = 't', allow_external = true,
        is_enabled = function() return true end }
    local mods = { ['core.utils'] = { log = function() end, classify = { db = { version = 't' } } },
        ['core.settings'] = alfred_settings, ['core.tracker'] = tracker }
    local e = setmetatable({ require = function(n) return mods[n] end }, { __index = h.e })
    local external = assert(loadfile(SUITE_ROOT .. '/AlfredTheButler-WarPigz/core/external.lua', 't', e))()
    return external, tracker
end

case('TristramLoop Alfred bridge honours the real Alfred pause fields', function()
    local h = tristram()
    local bridge = h.e.package.loaded['tristram.bridge_alfred']
    local external, tracker = real_alfred_external(h)
    local resumed = {}
    local peer = { get_status = external.get_status, pause = external.pause,
        resume = function(caller) resumed[#resumed + 1] = caller; return external.resume(caller) end,
        trigger_tasks_with_teleport = external.trigger_tasks_with_teleport }
    -- Paused by someone else: refused, and that pause is left alone.
    external.pause('WarPigs')
    local status = external.get_status()
    ok(status.paused == true and status.paused_by == 'WarPigs', 'Alfred publishes paused/paused_by')
    local ticket, why = bridge.begin(peer, status, false)
    eq(ticket, nil, 'foreign pause refuses the request')
    ok(tostring(why):find('WarPigs'), 'reason names the pauser: ' .. tostring(why))
    eq(#resumed, 0, 'never resumes a foreign pause'); eq(tracker.external_pause, true)
    -- Not paused: trigger without calling resume.
    external.resume('WarPigs'); resumed = {}
    ticket = bridge.begin(peer, external.get_status(), false)
    ok(ticket, 'unpaused Alfred accepts the request')
    eq(#resumed, 0, 'no resume when nothing is paused')
    eq(tracker.external_trigger, true); eq(tracker.external_caller, 'TristramLoop')
    -- Our own stale pause is lifted.
    tracker.external_trigger = false; tracker.external_caller = nil
    external.pause('TristramLoop'); resumed = {}
    ticket = bridge.begin(peer, external.get_status(), false)
    ok(ticket, 'own pause does not block')
    eq(resumed[1], 'TristramLoop', 'own stale pause resumed')
    -- Legacy field names still honoured.
    local legacy = { enabled = true, external_pause = true, pause_caller = 'Other' }
    eq((bridge.begin(peer, legacy, false)), nil, 'legacy external_pause/pause_caller still refuse')
end)

if #failures > 0 then error(table.concat(failures, '\n')) end
print('TristramLoop assertions: ' .. count)
