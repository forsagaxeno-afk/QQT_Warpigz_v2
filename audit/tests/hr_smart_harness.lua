-- Shared offline harness for the HelltideRevamped smart-farm modules
-- (QQT_Warpigz_v3): the REAL gui.lua, core/settings.lua, core/hr_*.lua (and,
-- on request, tasks/*.lua) in a sandbox with QQT-shaped host stubs:
--   * a scripted UTC clock: s.epoch (seconds) drives core/hr_clock.lua and
--     the os.date('!%M' / '!%S') answers; s.now is get_time_since_inject();
--     s.advance(dt) moves both;
--   * an in-memory file system behind io.open (s.files[path] = text;
--     s.fail_write(path) -> true refuses a write, s.fail_read(path) -> true
--     a read ('Permission denied'); s.writes lists writes);
--   * menu widgets holding the real defaults of gui.lua;
--   * an optional curl stub whose callbacks run on s.pump().
-- Loaded with dofile by the test_helltide_* smart-farm tests (it is not a
-- test itself: run_tests.py only picks up test_*.lua).
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/HelltideRevamped/'
local H = {}

local Vec = {}; Vec.__index = Vec
function Vec.new(_, x, y, z) return setmetatable({xx = x or 0, yy = y or 0, zz = z or 0}, Vec) end
function Vec:x() return self.xx end
function Vec:y() return self.yy end
function Vec:z() return self.zz end
function Vec:dist_to(o) return math.sqrt((self.xx - o:x()) ^ 2 + (self.yy - o:y()) ^ 2 + (self.zz - o:z()) ^ 2) end
function Vec:dist_to_ignore_z(o) return math.sqrt((self.xx - o:x()) ^ 2 + (self.yy - o:y()) ^ 2) end
H.Vec = Vec
function H.v(x, y, z) return Vec:new(x, y, z) end

-- A chest-like actor (also answers the vector accessors: navigate_to()
-- treats table targets as positions).
function H.actor(skin, x, y, fields)
    local a = {skin = skin, pos = Vec:new(x, y, 0), interactable = true}
    for k, v in pairs(fields or {}) do a[k] = v end
    function a:get_skin_name() return self.skin end
    function a:get_position() return self.pos end
    function a:is_interactable() return self.interactable ~= false end
    function a:x() return self.pos:x() end
    function a:y() return self.pos:y() end
    function a:z() return self.pos:z() end
    function a:dist_to(o) return self.pos:dist_to(o) end
    return a
end

-- Epoch of 2026-09-27 04:00:00 UTC (helltides.com hour id 1790481600).
H.HOUR = 1790481600
H.MEM_ROOT = '/mem/HelltideRevamped/'

local function mem_reader(text)
    local pos, f = 1, {}
    local function next_line()
        if pos > #text then return nil end
        local e = text:find('\n', pos, true)
        local line
        if e then line, pos = text:sub(pos, e - 1), e + 1 else line, pos = text:sub(pos), #text + 1 end
        return line
    end
    function f:lines() return next_line end
    function f:read() return next_line() end
    function f:seek(whence, offset)
        if whence == 'end' then pos = #text + 1; return #text end
        if whence == 'set' then pos = (offset or 0) + 1 end
        return pos - 1
    end
    function f:close() return true end
    return f
end

function H.new(opts)
    opts = opts or {}
    local s = {now = 100, epoch = opts.epoch or (H.HOUR + 10 * 60), cinders = opts.cinders or 0,
        pos = Vec:new(0, 0, 0), zone = opts.zone or 'Step_South', world = 'Sanctuary_Eastern_Continent',
        in_helltide = opts.in_helltide ~= false, dead = false, logs = {}, files = opts.files or {}, writes = {},
        actors = {}, loot = {}, draws = {}, pins = {}, teleports = {}, interactions = {}, curl_calls = {},
        curl_queue = {}, items = 0}
    local player = {
        get_position = function() return s.pos end,
        get_current_speed = function() return 0 end,
        is_dead = function() return s.dead end,
        get_item_count = function() return s.items end,
        get_consumable_items = function() return {} end,
        get_attribute = function() return 0 end,
        get_buffs = function() return s.in_helltide and {{name_hash = 1066539}} or {} end,
    }
    local world = {get_name = function() return s.world end, get_current_zone_name = function() return s.zone end,
        get_world_id = function() return 1 end}
    local env = setmetatable({}, {__index = _G})
    env._G = env
    env.vec3 = Vec
    env.vec2 = {new = function(_, x, y) return {x = x, y = y} end}
    env.get_time_since_inject = function() return s.now end
    env.get_helltide_coin_cinders = function()
        if s.cinder_error then error('host: cinders unavailable') end
        return s.cinders
    end
    env.get_player_position = function() return s.pos end
    env.get_local_player = function() return player end
    env.get_current_world = function() return world end
    env.console = {print = function(line) s.logs[#s.logs + 1] = tostring(line) end}
    env.on_render, env.on_render_menu, env.on_update = function() end, function() end, function(fn) s.update = fn end
    env.graphics = setmetatable({}, {__index = function(_, k)
        return function() s.draws[k] = (s.draws[k] or 0) + 1 end
    end})
    for _, c in ipairs({'white', 'red', 'green', 'yellow', 'orange', 'black', 'blue', 'purple', 'gray', 'grey'}) do
        env['color_' .. c] = function(a) return {c, a} end
    end
    env.get_screen_width = function() return 1920 end
    env.get_screen_height = function() return 1080 end
    env.render_menu_header = function() end
    env.target_selector = {get_near_target_list = function() return {} end}
    env.actors_manager = {get_all_actors = function() return s.actors end, get_enemy_actors = function() return {} end}
    env.loot_manager = {get_all_items_chest_sort_by_distance = function() return s.loot end,
        any_item_around = function() return false end}
    env.utility = {set_height_of_valid_position = function(p) return p end, is_point_walkeable = function() return true end,
        set_map_pin = function(p) s.pins[#s.pins + 1] = p end}
    env.pathfinder = {request_move = function() end, clear_stored_path = function() end}
    env.teleport_to_waypoint = function(id) s.teleports[#s.teleports + 1] = {at = s.now, id = id}; return true end
    env.interact_object = function(a) s.interactions[#s.interactions + 1] = a end
    env.revive_at_checkpoint = function() s.revives = (s.revives or 0) + 1 end
    env.attributes = {PLAYER_IN_TOWN_LEVEL_AREA = 1}
    env.orbwalker = {set_clear_toggle = function() end, set_block_movement = function() end}
    -- Scripted UTC clock (hr_clock also reads it through its _now hook).
    env.os = setmetatable({
        date = function(fmt, t)
            if fmt == '!%M' then return string.format('%02d', math.floor(s.epoch / 60) % 60) end
            if fmt == '!%S' then return string.format('%02d', math.floor(s.epoch) % 60) end
            if fmt == '%M' then return string.format('%02d', (math.floor(s.epoch / 60) + (s.tz_minutes or 0)) % 60) end
            return os.date(fmt, t or s.epoch)
        end,
        time = function(t) if t then return os.time(t) end return math.floor(s.epoch) end,
    }, {__index = os})
    -- In-memory files.
    env.io = {open = function(path, mode)
        mode = mode or 'r'
        if mode:find('[wa]') then
            s.writes[#s.writes + 1] = {path = path, t = s.now}
            if s.fail_write and s.fail_write(path) then return nil, 'write refused by the test' end
            local buf = {}
            local f = {}
            function f:write(...)
                for i = 1, select('#', ...) do buf[#buf + 1] = tostring((select(i, ...))) end
                s.files[path] = table.concat(buf)
                return self
            end
            function f:close() s.files[path] = table.concat(buf); return true end
            s.files[path] = ''
            return f
        end
        if s.fail_read and s.fail_read(path) then return nil, path .. ': Permission denied' end
        local text = s.files[path]
        if text == nil then return nil, path .. ': No such file or directory' end
        return mem_reader(text)
    end}
    if opts.curl ~= false then
        env.curl = {http_get = function(url, cb, headers, timeout)
            s.curl_calls[#s.curl_calls + 1] = {url = url, headers = headers, timeout = timeout, at = s.now}
            if s.curl_refuse then return false end
            s.curl_queue[#s.curl_queue + 1] = cb
            return true
        end}
    end
    function s.pump(body, status, err)
        local queue = s.curl_queue
        s.curl_queue = {}
        for _, cb in ipairs(queue) do cb(body or s.curl_body or '', status or s.curl_status or 200, err or s.curl_err or '') end
        return #queue
    end

    -- Menu widgets with the real gui.lua defaults.
    local function widget(value)
        local w = {v = value}
        function w:get() return self.v end
        function w:set(n) self.v = n end
        function w:render() s.rendered = (s.rendered or 0) + 1 end
        function w:push() return true end
        function w:pop() end
        return w
    end
    env.checkbox = {new = function(_, d) return widget(d == true) end}
    env.slider_int = {new = function(_, _, _, d) return widget(d) end}
    env.slider_float = {new = function(_, _, _, d) return widget(d) end}
    env.combo_box = {new = function(_, d) return widget(d or 0) end}
    env.tree_node = {new = function() return widget(false) end}
    env.button = {new = function() local w = widget(false); return w end}
    env.keybind = {new = function() return widget(false) end}
    env.get_hash = function(x) return x end
    env.BatmobilePlugin = opts.batmobile
    local modules = opts.modules or {}
    local noop = setmetatable({}, {__index = function() return function() end end})
    if opts.noop_perf ~= false then modules['core.perf'] = modules['core.perf'] or noop end
    modules['core.helltide_explorer'] = modules['core.helltide_explorer'] or noop
    env.require = function(name)
        if modules[name] == nil then
            modules[name] = assert(loadfile(ROOT .. name:gsub('%.', '/') .. '.lua', 't', env))()
        end
        return modules[name]
    end
    s.env, s.modules, s.player = env, modules, player
    s.require = env.require
    s.gui = env.require('gui')
    s.settings = env.require('core.settings')
    s.tracker = env.require('core.tracker')
    s.clock = env.require('core.hr_clock')
    s.clock._now = function() return s.epoch end
    s.store = env.require('core.hr_store')
    s.store.set_root(opts.root == nil and H.MEM_ROOT or opts.root or nil)
    function s.advance(dt)
        s.now = s.now + dt
        s.epoch = s.epoch + dt
    end
    -- UTC minute:second of the current hour.
    function s.at_minute(minute, second)
        s.epoch = math.floor(s.epoch / 3600) * 3600 + minute * 60 + (second or 0)
    end
    function s.set(name, value)
        local el = s.gui.elements[name]
        assert(el, 'no menu element ' .. tostring(name))
        el:set(value)
        s.settings:update_settings()
    end
    function s.logged(text)
        local n = 0
        for _, line in ipairs(s.logs) do if line:find(text, 1, true) then n = n + 1 end end
        return n
    end
    function s.file(rel) return s.files[H.MEM_ROOT .. rel] end
    s.settings:update_settings()
    return s
end

-- A test runner in the style of the other suites.
function H.runner(label)
    local R = {checks = 0, cases = 0, failures = {}}
    function R.ok(cond, message)
        R.checks = R.checks + 1
        if not cond then error(message or 'assertion failed', 2) end
    end
    function R.eq(actual, expected, message)
        R.checks = R.checks + 1
        if actual ~= expected then
            error((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
        end
    end
    function R.near(actual, expected, tol, message)
        R.checks = R.checks + 1
        if type(actual) ~= 'number' or math.abs(actual - expected) > (tol or 1e-6) then
            error((message or 'values differ') .. ': expected ' .. tostring(expected) .. ' +- ' .. tostring(tol)
                .. ', got ' .. tostring(actual), 2)
        end
    end
    function R.case(name, fn)
        R.cases = R.cases + 1
        local passed, err = xpcall(fn, debug.traceback)
        if passed then
            print('PASS ' .. label .. ': ' .. name)
        else
            R.failures[#R.failures + 1] = name .. ': ' .. tostring(err)
            print('FAIL ' .. label .. ': ' .. name .. ': ' .. tostring(err))
        end
    end
    function R.finish()
        print(string.format('%s: %d cases, %d checks, %d failures', label, R.cases, R.checks, #R.failures))
        if #R.failures > 0 then error(label .. ' failures:\n' .. table.concat(R.failures, '\n')) end
    end
    return R
end

return H
