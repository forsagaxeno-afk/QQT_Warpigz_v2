-- HelltideRevamped integration regressions: CRT-4/L11 (a Looter/Alfred yield
-- never counts toward the chest and chest-recall stuck windows), HLT-1..HLT-9
-- and the suite contract items C1 (canonical Alfred reading), C3 (Batmobile
-- release), C4 (orbwalker release), C5 (yield accounting), A5-2 (advisory
-- flags under WarPigs, guard) and C6 (bounded,
-- published holds). Loads the real HelltideRevamped main.lua, task_manager,
-- tasks and core modules with QQT-shaped host mocks; Alfred, Batmobile,
-- Looteer and the orbwalker are the synthetic boundaries. Runs under Lua 5.4
-- and LuaJIT.
local root = assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/HelltideRevamped/'
local checks, cases, failures = 0, 0, {}
local function ok(cond, message)
    checks = checks + 1
    if not cond then error(message or 'assertion failed', 2) end
end
local function eq(actual, expected, message)
    checks = checks + 1
    if actual ~= expected then
        error((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
end
local function case(name, fn)
    cases = cases + 1
    local passed, err = pcall(fn)
    if passed then
        print('PASS Helltide integration: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Helltide integration: ' .. name .. ': ' .. tostring(err))
    end
end

local Vec = {}; Vec.__index = Vec
function Vec:new(x, y, z) return setmetatable({xx = x or 0, yy = y or 0, zz = z or 0}, self) end
function Vec:x() return self.xx end
function Vec:y() return self.yy end
function Vec:z() return self.zz end
function Vec:dist_to(o) return math.sqrt((self.xx - o:x())^2 + (self.yy - o:y())^2 + (self.zz - o:z())^2) end
function Vec:dist_to_ignore_z(o) return math.sqrt((self.xx - o:x())^2 + (self.yy - o:y())^2) end
local function v(x, y, z) return Vec:new(x, y, z) end

-- Actor handles; navigate_to() treats non-userdata targets as positions, so
-- the mock also answers the vector accessors.
local function actor(skin, x, y, opts)
    opts = opts or {}
    local a = {skin = skin, pos = v(x, y, opts.z or 0), interactable = opts.interactable ~= false}
    function a:get_skin_name() return self.skin end
    function a:get_position() return self.pos end
    function a:is_interactable() return self.interactable end
    function a:x() return self.pos:x() end
    function a:y() return self.pos:y() end
    function a:z() return self.pos:z() end
    function a:dist_to(o) return self.pos:dist_to(o) end
    return a
end

local HELLTIDE_BUFF, TELEPORT_BUFF = 1066539, 44010
local TOWN_ZONE = 'Skov_Temis'

local function session(opts)
    opts = opts or {}
    local s = {now = 100, minute = opts.minute or 10, pos = v(0, 0, 0),
        world = opts.world or 'Sanctuary_Eastern_Continent', zone = opts.zone or 'Test_Zone',
        in_helltide = opts.in_helltide ~= false, teleporting = false, cinders = opts.cinders or 311,
        items = 0, actors = {}, loot = {}, logs = {}, teleports = {}, interactions = {}, triggers = {},
        looting = false, orb = {clear = true, block = false}, task_ticks = {}, name_ticks = {}}
    local bm = {target = nil, paused = false, resets = 0, releases = {}, clears = 0, sets = {},
        long_paths = {}, long_active = false, giving_up = false, moves = 0}
    s.bm = bm
    local batmobile = {
        pause = function() bm.paused = true end,
        resume = function() bm.paused = false end,
        set_target = function(_, t) bm.target = t; bm.sets[#bm.sets + 1] = {at = s.now, target = t}; return true end,
        clear_target = function() bm.target = nil; bm.clears = bm.clears + 1 end,
        stop_long_path = function() bm.long_active = false end,
        update = function() end,
        move = function() bm.moves = bm.moves + 1 end,
        is_paused = function() return bm.paused end,
        is_done = function() return false end,
        reset = function() bm.resets = bm.resets + 1; bm.target = nil end,
        reset_movement = function() bm.target = nil end,
        get_target = function() return bm.target end,
        clear_giving_up = function() bm.giving_up = false end,
        is_giving_up = function() return bm.giving_up end,
        navigate_long_path = function() bm.long_paths[#bm.long_paths + 1] = s.now; bm.long_active = true; return true end,
        is_long_path_navigating = function() return bm.long_active end,
        get_closeby_node = function(_, p) return p end,
        clear_traversal_blacklist = function() end,
    }
    if opts.release then
        batmobile.release = function(caller)
            bm.releases[#bm.releases + 1] = caller
            bm.target, bm.paused, bm.long_active = nil, true, false
        end
    end
    local player = {
        get_position = function() return s.pos end,
        get_current_speed = function() return 0 end,
        is_dead = function() return false end,
        get_item_count = function() return s.items end,
        get_consumable_items = function() return {} end,
        get_attribute = function() return 0 end,
        get_buffs = function()
            local buffs = {}
            if s.in_helltide then buffs[#buffs + 1] = {name_hash = HELLTIDE_BUFF} end
            if s.teleporting then buffs[#buffs + 1] = {name_hash = TELEPORT_BUFF} end
            return buffs
        end,
    }
    local world = {get_name = function() return s.world end,
        get_current_zone_name = function() return s.zone end,
        get_world_id = function() return 1 end}
    local env = setmetatable({}, {__index = _G})
    env._G = env
    env.vec3 = Vec
    env.get_time_since_inject = function() return s.now end
    env.get_helltide_coin_cinders = function() return s.cinders end
    env.get_player_position = function() return s.pos end
    env.get_local_player = function() return player end
    env.get_current_world = function() return world end
    env.on_render = function() end
    env.on_render_menu = function() end
    env.on_update = function(fn) s.update = fn end
    env.console = {print = function(line) s.logs[#s.logs + 1] = tostring(line) end}
    env.target_selector = {get_near_target_list = function() return {} end}
    env.actors_manager = {get_all_actors = function() return s.actors end, get_enemy_actors = function() return {} end}
    env.loot_manager = {get_all_items_chest_sort_by_distance = function() return s.loot end,
        any_item_around = function() return false end}
    env.utility = {set_height_of_valid_position = function(p) return p end, is_point_walkeable = function() return true end}
    env.pathfinder = {request_move = function() end, clear_stored_path = function() end}
    env.teleport_to_waypoint = function(id) s.teleports[#s.teleports + 1] = {at = s.now, id = id} end
    env.interact_object = function(a) s.interactions[#s.interactions + 1] = a end
    env.revive_at_checkpoint = function() end
    env.attributes = {PLAYER_IN_TOWN_LEVEL_AREA = 1}
    env.orbwalker = {set_clear_toggle = function(on) s.orb.clear = on end,
        set_block_movement = function(on) s.orb.block = on end}
    -- utils.helltide_active()/do_events() read the minute; QQT_Warpigz_v3:
    -- in UTC (core/hr_clock.lua), so the scripted clock answers both forms.
    env.os = setmetatable({date = function(fmt, ...)
        if fmt == '%M' or fmt == '!%M' then return string.format('%02d', s.minute) end
        if fmt == '!%S' then return '00' end
        return os.date(fmt, ...)
    end}, {__index = os})
    env.BatmobilePlugin = batmobile
    env.LooteerPlugin = {get_enabled = function() return true end,
        is_actively_looting = function() return s.looting end}

    local function control(value)
        return {value = value, get = function(self) return self.value end, set = function(self, n) self.value = n end}
    end
    local controls = setmetatable({}, {__index = function(t, k) local c = control(false); rawset(t, k, c); return c end})
    local defaults = {main_toggle = opts.enabled == true, town = 0, salvage_toggle = opts.salvage == true,
        helltide_chest_toggle = true, kill_monsters_toggle = false, kill_monsters_rarity = 0,
        farm_cinder_threshold = 0, maiden_disable_cinders = 0, manage_orbwalker = opts.manage_orbwalker == true,
        prioritize_traversals_toggle = opts.prioritize_traversals == true}
    for k, value in pairs(defaults) do controls[k] = control(value) end
    s.controls = controls
    local noop = setmetatable({}, {__index = function() return function() end end})
    local modules = {
        gui = {elements = controls, render = function() end,
            town_data = {[0] = {zone_name = TOWN_ZONE, waypoint_sno = 0x1CE51E},
                [1] = {zone_name = 'Scos_Cerrigar', waypoint_sno = 0x76D58}}},
        ['core.perf'] = noop,
        ['core.helltide_explorer'] = noop,
    }
    env.require = function(name)
        if modules[name] == nil then
            modules[name] = assert(loadfile(root .. name:gsub('%.', '/') .. '.lua', 't', env))()
        end
        return modules[name]
    end
    s.env = env
    s.settings = env.require('core.settings')
    s.settings:update_settings()
    s.tracker = env.require('core.tracker')
    s.utils = env.require('core.utils')
    s.tm = env.require('core.task_manager')
    s.helltide = env.require('tasks.helltide')
    s.search = env.require('tasks.search_helltide')
    s.loot_guard = env.require('core.loot_guard')

    function s.tick(seconds, dt)
        dt = dt or 0.1
        for _ = 1, math.floor(seconds / dt + 0.5) do
            s.now = s.now + dt
            if s.before_tick then s.before_tick() end
            if s.main_loaded then s.update() else s.tm.execute_tasks() end
            local name = s.tm.get_current_task().name or '?'
            local key = name:match('^Explore Helltide') and 'helltide' or name
            s.task_ticks[key] = (s.task_ticks[key] or 0) + 1
            s.name_ticks[name] = (s.name_ticks[name] or 0) + 1
        end
    end
    function s.load_main()
        assert(loadfile(root .. 'main.lua', 't', env))()
        s.main_loaded = true
        s.plugin = env.HelltideRevampedPlugin
    end
    function s.logged(pattern)
        local n = 0
        for _, line in ipairs(s.logs) do if line:find(pattern, 1, true) then n = n + 1 end end
        return n
    end
    function s.sets_after(t)
        local out = {}
        for _, set in ipairs(s.bm.sets) do if set.at > t then out[#out + 1] = set end end
        return out
    end
    return s
end

-- Alfred boundary: a with-teleport trip completes (callback) 10 s after the
-- trigger; status() builds each read from the session state.
local function alfred(s, status_fn, global_name)
    local a = {}
    a.get_status = function() return status_fn(s) end
    a.trigger_tasks_with_teleport = function(_, cb)
        s.triggers[#s.triggers + 1] = s.now
        s.alfred_busy, s.alfred_cb, s.alfred_cb_at = true, cb, s.now + 10
    end
    s.before_tick = function()
        if s.alfred_cb_at and s.now >= s.alfred_cb_at then
            local cb = s.alfred_cb
            s.alfred_busy, s.alfred_cb, s.alfred_cb_at, s.latched = false, nil, nil, true
            cb()
        end
    end
    s.env[global_name or 'AlfredTheButlerPlugin'] = a
    return a
end

local function chest_session(opts)
    local s = session(opts)
    s.chest = actor('usz_rewardGizmo_1H', opts and opts.chest_x or 22.7, 0)
    s.actors = {s.chest}
    return s
end

-- QQT_Warpigz_v3: the in-Helltide Looter hold is bounded (15 s without a new
-- bag item). Cases that model a long but productive Looter pickup add one
-- item every `every` seconds while it is busy.
local function loot_progress(s, every)
    local prev, next_at = s.before_tick, s.now + every
    s.before_tick = function()
        if prev then prev() end
        if not s.looting then next_at = s.now + every
        elseif s.now >= next_at then s.items, next_at = s.items + 1, s.now + every end
    end
end

-- ── CRT-4 / L11: Looter yield vs. chest stuck windows ─────────────────────
case('ZZ minute 55 after a scan found the Helltide: search goes to town, not back to the scan waypoint', function()
    local s = session({zone = 'Skov_Temis', in_helltide = false})
    s.tick(1)
    local first = s.teleports[1]
    ok(first ~= nil, 'scan teleport fired')
    print(string.format('scan teleport 0x%X', first.id))
    s.zone, s.in_helltide = 'Frac_Tundra_S', true      -- arrived; buff on: helltide task takes over
    s.tick(30)
    s.zone = 'Frac_Tundra_N'                             -- farmed into the next sub-zone of the region
    s.tick(5)
    local before = #s.teleports
    s.minute, s.in_helltide = 55, false                  -- the Helltide ends
    s.tick(10)
    for i = before + 1, #s.teleports do print(string.format('after :55 teleport at %.1f -> 0x%X', s.teleports[i].at, s.teleports[i].id)) end
    eq(s.teleports[before + 1] and s.teleports[before + 1].id, 0x1CE51E, 'first teleport after :55 is not the idle town')
end)
print(string.format('cases %d failures %d', cases, #failures))
if #failures > 0 then error('failures:\n' .. table.concat(failures, '\n')) end
