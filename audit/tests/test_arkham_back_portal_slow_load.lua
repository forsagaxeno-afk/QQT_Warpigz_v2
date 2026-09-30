-- QQT_Warpigz_v3 Arkham 2.1.5 (sweep 2026-09-28 A2 / S2 F2): the back-portal
-- blacklist accepted a world change as portal-induced only within 5 s of the
-- click, and the loading screen counts toward it. A 5.2 s floor load read
-- "not via portal": no blacklist, the bot took the portal next to its spawn
-- (the one back up) and ping-ponged between the floors.
--   L1 5.2 s loads: "via portal — back-portal blacklisted", never back up
--      within 60 s, the next floor is reached (failed pre-fix).
--   L2 control: 2 s loads.
-- Real tasks/portal.lua + core/tracker.lua, driven like core/task_manager
-- (observe_world, then reset(transition), then shouldExecute/Execute).
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local checks, failures = 0, {}
local function ok(value, message)
    if not value then error(message or 'expected a true value', 2) end
    checks = checks + 1
end
local function case(name, fn)
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS arkham-back-portal-slow-load: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL arkham-back-portal-slow-load: ' .. name .. ': ' .. tostring(err)) end
end

local function vec(x, y, z)
    local v = {}
    v.x = function() return x end; v.y = function() return y end; v.z = function() return z or 0 end
    return v
end
local function pos_of(a) if a.get_position then return a:get_position() end return a end
local function dist(a, b)
    a, b = pos_of(a), pos_of(b)
    return math.sqrt((a:x() - b:x()) ^ 2 + (a:y() - b:y()) ^ 2)
end

-- Pit floors 1..n. Floor k: spawn (0,0); its portal back up (k > 1) 5 m from
-- the spawn at (5,0), listed first (without a blacklist it is taken); the
-- descend portal at (-20,0). Going down lands at the spawn of k+1; going up
-- lands at (-15,0) on k-1, 5 m from that floor's descend portal.
local function world_fixture(opts)
    local w = {now = 1000, logs = {}, floor = opts.floor or 1, loading = nil, load_s = opts.load_s or 2,
        pos = opts.pos or vec(0, 0), goal = nil, visits = {}, ups = 0, floors = opts.floors or 4, town = opts.town}
    local function portal(kind, x)
        local a = {kind = kind, p = vec(x, 0)}
        function a:get_skin_name() return 'Prefab_Portal_Dungeon_Generic' end
        function a:get_position() return self.p end
        function a:is_interactable() return true end
        return a
    end
    function w.actors()
        if w.town or w.loading then return {} end
        local list = {}
        if w.floor > 1 then list[#list + 1] = portal('up', 5) end
        if w.floor < w.floors then list[#list + 1] = portal('down', -20) end
        return list
    end
    function w.travel(kind, secs)
        w.loading = {until_t = w.now + (secs or w.load_s), kind = kind}
        w.goal = nil
    end
    local world = {
        get_name = function()
            if w.loading then return 'Loading' end
            if w.town then return 'Skov_Temis' end
            return 'PIT_Floor' .. w.floor
        end,
        get_current_zone_name = function() return w.loading and '[sno none]' or (w.town and 'Skov_Temis' or 'PIT_Subzone') end,
        get_world_id = function() return w.town and 7 or (100 + w.floor) end,
    }
    -- The plugin folder (package.path) and an in-memory file system for the
    -- back-portal store (back_portals.txt); other reads go to the real files.
    w.files = {}
    local mem_io = {open = function(path, mode)
        mode = mode or 'r'
        if mode:find('[wa]') then
            local buf = {}
            return {write = function(self, ...) for i = 1, select('#', ...) do buf[#buf + 1] = tostring((select(i, ...))) end; return self end,
                close = function() w.files[path] = table.concat(buf); w.writes = (w.writes or 0) + 1; return true end}
        end
        if w.files[path] then
            local text = w.files[path]
            return {read = function() local t = text; text = ''; return t end, close = function() return true end}
        end
        return io.open(path, mode)
    end}
    w.env_base = {
        io = mem_io,
        package = {path = ROOT .. '/ArkhamAsylum/?.lua;' .. ROOT .. '/ArkhamAsylum/?/init.lua',
            searchpath = package.searchpath},
        get_time_since_inject = function() return w.now end,
        get_current_world = function() return world end,
        get_local_player = function() return {get_position = function() return w.pos end} end,
        get_player_position = function() return w.pos end,
        vec3 = {new = function(_, x, y, z) return vec(x, y, z) end},
        actors_manager = {get_all_actors = function() return w.actors() end,
            get_ally_actors = function() return {} end},
        console = {print = function(l) w.logs[#w.logs + 1] = tostring(l) end},
        interact_object = function(a)
            if a.kind and dist(w.pos, a) <= 3.5 then
                if a.kind == 'up' then w.ups = w.ups + 1 end
                w.travel(a.kind)
            end
        end,
        pathfinder = {force_move_raw = function(p) w.goal = p end},
        BatmobilePlugin = setmetatable({
            navigate_long_path = function(_, p) w.goal = p; return true end,
            get_closeby_node = function(_, p) return p end,
            is_long_path_navigating = function() return w.goal ~= nil end,
            stop_long_path = function() w.goal = nil end,
            clear_target = function() end,
        }, {__index = function() return function() return true end end}),
    }
    -- Loads a fresh copy of the plugin's modules (a QQT reload does the same).
    function w.load()
        local settings = {reset_timeout = 600, death_recovery = false, orb_set_clear = function() end,
            pit_level = 1}
        local env = setmetatable({}, {__index = function(_, k)
            local v = w.env_base[k]
            if v ~= nil then return v end
            return _G[k]
        end})
        local modules = {['core.settings'] = settings, ['core.qqt_events'] = {emit = function() end}}
        env.require = function(n) return assert(modules[n], n) end
        modules['core.tracker'] = assert(loadfile(ROOT .. '/ArkhamAsylum/core/tracker.lua', 't', env))()
        modules['core.utils'] = {
            distance = dist,
            player_in_pit = function() return world.get_name():match('^PIT_') ~= nil end,
            get_glyph_upgrade_gizmo = function() return nil end,
            exit_pit_forced = function() return false end,
        }
        w.tracker = modules['core.tracker']
        w.task = assert(loadfile(ROOT .. '/ArkhamAsylum/tasks/portal.lua', 't', env))()
    end
    function w.pulse(dt)
        dt = dt or 0.05
        if w.loading and w.now >= w.loading.until_t then
            local kind = w.loading.kind
            w.loading = nil
            if kind == 'down' then w.floor = w.floor + 1; w.pos = vec(0, 0)
            elseif kind == 'up' then w.floor = w.floor - 1; w.pos = vec(-15, 0)
            elseif kind == 'pit' then w.town = false; w.floor = 1; w.pos = vec(0, 0) end
            w.visits[#w.visits + 1] = {t = w.now, floor = w.floor, kind = kind}
        end
        if not w.loading then
            local transition = w.tracker.observe_world(false)
            if transition then w.task.reset(transition) end
            if w.task.shouldExecute() then w.task.Execute() end
        end
        if w.goal and not w.loading then
            local d = dist(w.pos, w.goal)
            local step = 7 * dt
            if d <= step then w.pos = w.goal; w.goal = nil
            else
                local k = step / d
                w.pos = vec(w.pos:x() + (w.goal:x() - w.pos:x()) * k, w.pos:y() + (w.goal:y() - w.pos:y()) * k)
            end
        end
        w.now = w.now + dt
    end
    function w.run_until(pred, seconds)
        local stop = w.now + seconds
        while w.now < stop do
            w.pulse()
            if pred() then return true end
        end
        return false
    end
    function w.logged(needle)
        local n = 0
        for _, l in ipairs(w.logs) do if l:find(needle, 1, true) then n = n + 1 end end
        return n
    end
    w.load()
    return w
end

local function slow_load_case(load_s)
    -- From town into floor 1, then floor-to-floor loads of load_s seconds.
    local w = world_fixture({town = true, load_s = load_s})
    w.pulse()
    w.travel('pit', 1)
    ok(w.run_until(function() return w.floor == 2 and not w.loading end, 60), 'floor 2 reached')
    ok(w.logged("arrived in 'PIT_Floor2' via portal — back-portal blacklisted") == 1,
        'floor 2: via portal, back portal blacklisted\n' .. table.concat(w.logs, '\n'))
    local reached = w.run_until(function() return w.floor == 3 and not w.loading end, 60)
    ok(w.ups == 0, string.format('the bot took the portal back up %d time(s) (%.1f s loads)', w.ups, load_s))
    ok(reached, 'floor 3 reached within 60 s')
    ok(w.run_until(function() return w.floor == 4 end, 60) and w.ups == 0, 'floor 4 reached, never back up')
end

case('L1 5.2 s floor loads: via portal, blacklisted, never back up, the next floor is reached', function()
    slow_load_case(5.2)
end)
case('L2 control: 2 s floor loads', function()
    slow_load_case(2)
end)

ok(rawget(_G, 'QQT_ArkhamBackPortals') == nil, 'no new global')
if #failures > 0 then error(#failures .. ' arkham back-portal slow-load case(s) failed:\n' .. table.concat(failures, '\n')) end
print(string.format('PASS: arkham back-portal slow load, %d checks', checks))
