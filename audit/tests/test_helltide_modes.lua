-- HelltideRevamped Warplan / Farm mode and the Farm-mode Pandemonium rupture
-- port (core/hr_mode.lua, core/hr_tear_event.lua, core/hr_rupture_leash.lua,
-- data/hr_tear_skins.lua). Loads the real main.lua, settings, task_manager,
-- tasks and core modules with QQT-shaped host mocks (same boundaries as
-- test_integration_helltide.lua). Runs under Lua 5.4 and LuaJIT.
local root = assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/HelltideRevamped-0.4/'
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
local last_session -- the most recent session(): its log tail is printed on failure
local function case(name, fn)
    cases = cases + 1
    last_session = nil
    local passed, err = pcall(fn)
    if passed then
        print('PASS Helltide modes: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Helltide modes: ' .. name .. ': ' .. tostring(err))
        local logs = last_session and last_session.logs or {}
        for i = math.max(1, #logs - 25), #logs do print('    | ' .. logs[i]) end
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

local function actor(skin, x, y, opts)
    opts = opts or {}
    local a = {skin = skin, pos = v(x, y, opts.z or 0), interactable = opts.interactable ~= false, hp = opts.hp}
    function a:get_skin_name() return self.skin end
    function a:get_position() return self.pos end
    function a:is_interactable() return self.interactable end
    if opts.hp then function a:get_current_health() return self.hp end end
    function a:x() return self.pos:x() end
    function a:y() return self.pos:y() end
    function a:z() return self.pos:z() end
    function a:dist_to(o) return self.pos:dist_to(o) end
    return a
end

-- Skins the ported rupture code relies on (data/hr_tear_skins.lua).
local SKIN = {
    surging_starter = 'S14_Rupture_LE_SwitchGizmo',
    normal_starter = 'S14_Rupture_SMP_SwitchGizmo',
    hold = 'S14_PandemoniumCrack_gizmo_holdArea',
    tear = 'S14_Rupture_Major_ZE_MicroRupture',
    chest = 'S14_Rupture_SMP_PandemoniumChest',
}
local CHEST = 'usz_rewardGizmo_1H'
local HELLTIDE_BUFF = 1066539

local function session(opts)
    opts = opts or {}
    local s = {now = 100, minute = 10, pos = v(0, 0, 0), zone = 'Test_Zone', in_helltide = true,
        cinders = opts.cinders or 311, actors = {}, loot = {}, logs = {}, interactions = {}, states = {},
        orb = {clear = true, block = false}}
    local bm = {target = nil, sets = {}}
    s.bm = bm
    local player = {
        get_position = function() return s.pos end,
        get_current_speed = function() return 0 end,
        is_dead = function() return false end,
        get_item_count = function() return 0 end,
        get_consumable_items = function() return {} end,
        get_attribute = function() return 0 end,
        get_buffs = function() return s.in_helltide and {{name_hash = HELLTIDE_BUFF}} or {} end,
    }
    local world = {get_name = function() return 'Sanctuary_Eastern_Continent' end,
        get_current_zone_name = function() return s.zone end, get_world_id = function() return 1 end}
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
    env.teleport_to_waypoint = function() end
    env.interact_object = function(a) s.interactions[#s.interactions + 1] = a end
    env.revive_at_checkpoint = function() end
    env.attributes = {PLAYER_IN_TOWN_LEVEL_AREA = 1, CHARGEABLE_GIZMO_PROGRESS = 2, GIZMO_HAS_BEEN_OPERATED = 3}
    env.orbwalker = {set_clear_toggle = function(on) s.orb.clear = on end,
        set_block_movement = function(on) s.orb.block = on end}
    env.os = setmetatable({date = function(fmt, ...)
        if fmt == '%M' then return string.format('%02d', s.minute) end
        return os.date(fmt, ...)
    end}, {__index = os})
    env.BatmobilePlugin = {
        pause = function() end, resume = function() end,
        set_target = function(_, t) bm.target = t; bm.sets[#bm.sets + 1] = {at = s.now, target = t}; return true end,
        clear_target = function() bm.target = nil end, stop_long_path = function() end,
        update = function() end, move = function() end, is_paused = function() return false end,
        is_done = function() return false end, reset = function() bm.target = nil end,
        reset_movement = function() bm.target = nil end, get_target = function() return bm.target end,
        clear_giving_up = function() end, is_giving_up = function() return false end,
        navigate_long_path = function() return true end, is_long_path_navigating = function() return false end,
        get_closeby_node = function(_, p) return p end, clear_traversal_blacklist = function() end,
    }
    env.LooteerPlugin = {get_enabled = function() return true end, is_actively_looting = function() return false end}
    if opts.strip_apis then
        env.target_selector, env.attributes, env.interact_object = nil, nil, nil
    end

    local function control(value)
        return {value = value, get = function(self) return self.value end, set = function(self, n) self.value = n end}
    end
    local controls = setmetatable({}, {__index = function(t, k) local c = control(false); rawset(t, k, c); return c end})
    local defaults = {main_toggle = opts.enabled == true, town = 0, helltide_chest_toggle = true,
        kill_monsters_toggle = false, kill_monsters_rarity = 0, farm_cinder_threshold = 0,
        maiden_disable_cinders = 0, mode = opts.mode or 0, hunt_rift_toggle = true,
        rupture_hunt_normal = true, rupture_hunt_surging = true, rupture_hunt_colossal = true,
        rupture_open_chests = true, tear_use_charge_ring = true, rupture_max_cinders = opts.max_cinders or 0,
        chaos_rift_toggle = true}
    for k, value in pairs(defaults) do controls[k] = control(value) end
    s.controls = controls
    local noop = setmetatable({}, {__index = function() return function() end end})
    local modules = {
        gui = {elements = controls, render = function() end, mode = {'Warplan', 'Farm'},
            town_data = {[0] = {zone_name = 'Skov_Temis', waypoint_sno = 0x1CE51E},
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
    s.mode = env.require('core.hr_mode')
    s.tear = env.require('core.hr_tear_event')
    s.tm = env.require('core.task_manager')
    s.helltide = env.require('tasks.helltide')
    assert(loadfile(root .. 'main.lua', 't', env))()
    s.plugin = env.HelltideRevampedPlugin
    last_session = s

    function s.tick(seconds, dt)
        dt = dt or 0.1
        for _ = 1, math.floor(seconds / dt + 0.5) do
            s.now = s.now + dt
            if s.before_tick then s.before_tick() end
            s.update()
            s.states[s.helltide.current_state] = true
        end
    end
    function s.logged(pattern)
        local n = 0
        for _, line in ipairs(s.logs) do if line:find(pattern, 1, true) then n = n + 1 end end
        return n
    end
    function s.any_rift_state()
        for state in pairs(s.states) do
            if s.tear.is_rift_state(state) then return state end
        end
        return nil
    end
    return s
end

-- Rupture scene: a Surging starter at 30 m, an affordable chest 20 m the
-- other way (50 m from the rupture: outside its in-ring chest scan).
local function rupture_scene(s)
    s.starter = actor(SKIN.surging_starter, 30, 0)
    s.chest = actor(CHEST, -20, 0)
    s.actors = {s.starter, s.chest}
end

-- ── mode selection ─────────────────────────────────────────────────────────
case('GUI mode picks warplan/farm; setSettings writes the persisted combo', function()
    local s = session({enabled = true})
    s.tick(0.2)
    eq(s.mode.effective(), 'warplan', 'default mode is warplan')
    eq(s.plugin.status().mode, 'warplan')
    s.controls.mode.value = 1
    s.tick(0.2)
    eq(s.settings.mode, 1, 'settings follow the combo')
    eq(s.mode.effective(), 'farm', 'manual farm mode')
    eq(s.plugin.status().mode, 'farm')
    eq(s.plugin.setSettings('mode', 0), true, 'mode is a writable setting')
    eq(s.controls.mode.value, 0, 'setSettings persists through the combo')
    s.tick(0.2)
    eq(s.mode.effective(), 'warplan')
    eq(s.plugin.setSettings('mode', 'farm'), false, 'wrong type rejected')
    eq(s.plugin.getSettings('hunt_rift'), true, 'rupture settings readable')
    ok(s.logged('[MODE] Helltide mode: farm') >= 1, 'mode change logged')
end)

case('external enable forces warplan regardless of the GUI; disable/untick restores the GUI mode', function()
    local s = session({mode = 1})
    s.tick(0.2)
    s.plugin.enable()
    s.tick(0.2)
    eq(s.mode.effective(), 'warplan', 'WarPigs enable runs warplan')
    eq(s.mode.selected(), 'farm', 'GUI value itself untouched')
    eq(s.plugin.status().mode, 'warplan')
    ok(s.logged('external enable forces warplan') >= 1)
    s.plugin.enable() -- repeat enables stay external
    s.tick(0.2)
    eq(s.mode.effective(), 'warplan')
    s.plugin.disable()
    s.tick(0.2)
    eq(s.mode.effective(), 'farm', 'after disable the GUI mode applies again')
    s.plugin.enable()
    s.tick(0.2)
    eq(s.mode.effective(), 'warplan')
    s.controls.main_toggle.value = false -- user unticks Enable
    s.tick(0.2)
    s.controls.main_toggle.value = true  -- and ticks it again by hand
    s.tick(0.2)
    eq(s.mode.effective(), 'farm', 'a manual re-enable is not external')
end)

-- ── warplan never enters a rupture ─────────────────────────────────────────
case('warplan (GUI) opens the chest and never enters a visible rupture', function()
    local s = session({enabled = true, mode = 0})
    rupture_scene(s)
    s.actors[#s.actors + 1] = actor(SKIN.hold, 31, 0)
    s.actors[#s.actors + 1] = actor(SKIN.tear, 32, 0, {hp = 50})
    s.tick(1)
    eq(s.helltide.current_state, 'MOVING_TO_HELLTIDE_CHEST', 'chest first in warplan')
    s.tick(10)
    eq(s.any_rift_state(), nil, 'no rupture state in warplan')
    eq(s.logged('[RIFT]'), 0, 'rupture code stayed silent')
end)

case('external enable with Farm selected still never enters a rupture', function()
    local s = session({mode = 1})
    rupture_scene(s)
    s.chest.pos = v(40, 0, 0) -- chest out of the direct range: only ruptures would be picked up
    s.tick(0.2)
    s.plugin.enable()
    s.tick(12)
    eq(s.any_rift_state(), nil, 'WarPigs-driven HR never hunts ruptures')
end)

case('switching to warplan mid-rupture abandons the rupture on the next tick', function()
    local s = session({enabled = true, mode = 1})
    rupture_scene(s)
    s.tick(1)
    ok(s.tear.is_rift_state(s.helltide.current_state), 'farm entered the rupture')
    s.plugin.enable()
    s.tick(0.2)
    eq(s.tear.is_rift_state(s.helltide.current_state), false, 'left the rupture')
    ok(s.logged('Mode is warplan') >= 1)
    s.states = {}
    s.tick(5)
    eq(s.any_rift_state(), nil, 'and never re-entered')
end)

-- ── farm prioritises ruptures ──────────────────────────────────────────────
case('farm prioritises a visible rupture over an affordable chest and runs it to completion', function()
    local s = session({enabled = true, mode = 1})
    rupture_scene(s)
    s.tick(1)
    eq(s.helltide.current_state, 'MOVING_TO_RIFT', 'rupture beats the 20 m chest')
    ok(s.bm.target and s.bm.target:dist_to(s.starter.pos) < 1, 'walking to the rupture gizmo')
    ok(s.logged('Found Surging rupture ' .. SKIN.surging_starter) >= 1)
    -- arrive: no cultists, no hold area yet -> wait for it to open
    s.pos = v(29, 0, 0)
    s.tick(0.5)
    eq(s.helltide.current_state, 'RIFT_WAIT_OPEN')
    -- rupture opens: a tear appears at the ring
    local tear = actor(SKIN.tear, 31, 0, {hp = 40})
    s.actors[#s.actors + 1] = tear
    s.tick(5.5)
    eq(s.helltide.current_state, 'RIFT_CLOSE_TEARS', 'closing the tear')
    -- a free Pandemonium chest drops in the ring: interrupt and open it
    local pchest = actor(SKIN.chest, 33, 0)
    s.actors[#s.actors + 1] = pchest
    s.tick(1.5)
    eq(s.helltide.current_state, 'RIFT_OPEN_CHEST')
    s.pos = v(33, 0, 0)
    s.tick(1.5)
    ok(s.interactions[1] == pchest, 'Pandemonium chest opened')
    pchest.interactable = false
    s.tick(4)
    ok(s.helltide.current_state ~= 'RIFT_OPEN_CHEST', 'resumed the rupture')
    -- tear closed
    tear.hp = 1
    s.pos = v(30, 0, 0)
    s.tick(7)
    ok(s.logged('Surging rupture complete') >= 1, 'rupture completed after the linger')
    ok(not s.tear.is_rift_state(s.helltide.current_state), 'back to patrol')
    s.pos = v(0, 0, 0)
    s.tick(2)
    eq(s.helltide.current_state, 'MOVING_TO_HELLTIDE_CHEST', 'then the chest; finished rupture not re-entered')
end)

case('farm without ruptures still opens chests; cinder cap pauses the hunt', function()
    local s = session({enabled = true, mode = 1, max_cinders = 300})
    rupture_scene(s)
    s.tick(1.5)
    eq(s.helltide.current_state, 'MOVING_TO_HELLTIDE_CHEST', 'cinders 311 >= cap 300: chests first')
    local t = session({enabled = true, mode = 1})
    t.chest = actor(CHEST, 10, 0); t.actors = {t.chest}
    t.tick(1.5)
    eq(t.helltide.current_state, 'MOVING_TO_HELLTIDE_CHEST', 'no rupture visible: chest')
end)

case('farm poll: kill-monsters and chest recall are pre-empted by a rupture', function()
    local s = session({enabled = true, mode = 1})
    s.actors = {actor(SKIN.normal_starter, 90, 0)}
    s.tick(0.2)
    local states = {KILL_MONSTERS = 'KILL_MONSTERS', MOVING_TO_REMEMBERED_CHEST = 'MOVING_TO_REMEMBERED_CHEST',
        MOVING_TO_RIFT = 'MOVING_TO_RIFT', RIFT_CLOSE_TEARS = 'RIFT_CLOSE_TEARS', RIFT_KILL_GUARDS = 'RIFT_KILL_GUARDS',
        RIFT_STAY_ACTIVE = 'RIFT_STAY_ACTIVE', EXPLORE_HELLTIDE = 'EXPLORE_HELLTIDE'}
    local km = {current_state = 'KILL_MONSTERS'}
    eq(s.tear.poll(km, states), true, 'proactive range from kill monsters')
    eq(km.current_state, 'MOVING_TO_RIFT')
    s.tear.on_reset()
    local recall = {current_state = 'MOVING_TO_REMEMBERED_CHEST'}
    eq(s.tear.poll(recall, states), false, '90 m is beyond the pass-by range')
    s.actors = {actor(SKIN.normal_starter, 40, 0)}
    s.now = s.now + 1
    eq(s.tear.poll(recall, states), true, 'pass-by range')
    s.mode.set_external(true)
    s.tear.on_reset()
    local w = {current_state = 'KILL_MONSTERS'}
    eq(s.tear.poll(w, states), false, 'warplan never polls')
end)

-- ── robustness ─────────────────────────────────────────────────────────────
case('rupture code survives missing host APIs and broken actor handles', function()
    local s = session({enabled = true, mode = 1, strip_apis = true})
    rupture_scene(s)
    local broken = {get_skin_name = function() error('stale actor') end, get_position = function() error('stale') end}
    local noskin = {get_position = function() return v(5, 0, 0) end}
    local tear_no_hp = actor(SKIN.tear, 31, 0)
    s.actors[#s.actors + 1] = broken
    s.actors[#s.actors + 1] = noskin
    s.actors[#s.actors + 1] = tear_no_hp
    s.actors[#s.actors + 1] = actor(SKIN.hold, 30, 1)
    s.actors[#s.actors + 1] = actor('S14_Golem_Stone_Realmwalker', 35, 0, {hp = 100})
    s.actors[#s.actors + 1] = actor('S14_cultist_Melee', 32, 0)
    s.tick(1)
    ok(s.tear.is_rift_state(s.helltide.current_state), 'rupture engaged without target_selector/attributes')
    s.pos = v(30, 0, 0)
    s.tick(20)
    s.env.get_current_world = function() error('loading') end
    s.env.actors_manager = nil
    local tear = s.tear
    local states = setmetatable({}, {__index = function(_, k) return k end})
    for state in pairs(tear.RIFT_STATES) do
        local self = {current_state = state}
        local passed, err = pcall(tear.execute, self, states)
        ok(passed, 'execute ' .. state .. ': ' .. tostring(err))
    end
    ok(tear.is_rupture_marker_skin(SKIN.hold) and not tear.is_rupture_marker_skin('TWN_Rupture_Board'))
    eq(tear.rupture_type_label(SKIN.surging_starter), 'Surging')
    eq(tear.rupture_type_label('S14_Rupture_Major_Proxy'), 'Colossal')
    eq(tear.rupture_type_label(SKIN.normal_starter), 'Normal')
    eq(tear.in_deathtoll_chamber(), false, 'broken world read is not a chamber')
end)

-- ── round-2 audit regressions ──────────────────────────────────────────────
-- Arrive at a Normal rupture from 30 m away (MOVING_TO_RIFT -> KILL_GUARDS).
local function normal_rupture(s, x)
    s.starter = actor(SKIN.normal_starter, x, 0)
    s.actors = {s.starter}
    s.tick(1)
    eq(s.helltide.current_state, 'MOVING_TO_RIFT', 'routing to the Normal rupture')
end

case('salvage trip mid-rupture: the next rupture gets a fresh session (not abandoned on its first tick)', function()
    local s = session({enabled = true, mode = 1})
    normal_rupture(s, 30)
    local first_started = s.tear.session().started_at
    -- Inventory full mid-rupture: Alfred's trip ends with return_from_salvage
    -- (state EXPLORE_HELLTIDE, no on_reset, no resume_patrol).
    s.tracker.has_salvaged = true
    s.actors = {} -- (the old rupture is out of sight when HR comes back)
    s.tick(4)
    eq(s.helltide.current_state, 'EXPLORE_HELLTIDE', 'return_from_salvage left the rupture state')
    s.actors = {}
    s.tick(400, 0.25) -- patrol well past RUPTURE_MAX_S (ticks < 0.5 s: no yield credit)
    s.pos = v(0, 0, 0)
    s.logs = {}
    s.actors = {actor(SKIN.normal_starter, 20, 0)}
    s.tick(1)
    ok(s.tear.is_rift_state(s.helltide.current_state), 'the new rupture is engaged: ' .. s.helltide.current_state)
    ok(s.tear.session().started_at > first_started + 300, "fresh start time")
    eq(s.logged('abandoned'), 0, 'new rupture not abandoned/blacklisted')
    eq(s.logged('took longer than'), 0, 'no stale time cap')
end)

case('Looter hold during RIFT_WAIT_OPEN does not use up the open window (C5/L11)', function()
    local s = session({enabled = true, mode = 1})
    normal_rupture(s, 30)
    s.pos = v(29, 0, 0)
    s.tick(0.5)
    eq(s.helltide.current_state, 'RIFT_WAIT_OPEN')
    local looting = true
    s.env.LooteerPlugin.is_actively_looting = function() return looting end
    s.tick(30) -- Looter holds HR for 30 s (> SPAWN_WAIT_S + 15)
    looting = false
    s.tick(1)
    eq(s.logged('Timed out waiting for the rupture to open'), 0, 'held time not counted')
    eq(s.helltide.current_state, 'RIFT_WAIT_OPEN', 'still waiting for the rupture')
    s.actors[#s.actors + 1] = actor(SKIN.tear, 31, 0, {hp = 40})
    s.tick(5)
    eq(s.helltide.current_state, 'RIFT_CLOSE_TEARS', 'rupture opened and is being closed')
end)

case('Deathtoll Chamber: buff drops before the zone name changes; the chamber run is kept', function()
    local s = session({enabled = true, mode = 1})
    s.controls.rupture_do_deathtoll_chamber.value = true
    s.tick(0.2)
    local portal = actor('S14_Realmwalker_eventEnd_RuptureEntrance_Portal', 2, 0)
    s.actors = {portal}
    s.tick(1.2) -- past the task's 1 s actor cache
    local sess = s.tear.session()
    sess.anchor, sess.rupture_type, sess.started_at = v(5, 0, 0), 'Surging', s.now
    s.helltide.current_state = 'RIFT_ENTER_CHAMBER'
    s.tick(0.5)
    ok(s.logged('Clicking Deathtoll Chamber portal') >= 1, 'portal clicked')
    -- Loading: the portal and the helltide buff are gone, the zone name still
    -- reports the overworld for over a second.
    s.actors, s.in_helltide = {}, false
    s.tick(1.5)
    eq(s.logged('Left helltide zone'), 0, 'no walk-back during the loading gap')
    eq(s.helltide.current_state, 'RIFT_ENTER_CHAMBER')
    s.zone = 'S14_RuptureChamber_01'
    s.tick(2)
    ok(s.helltide.current_state:find('^CHAMBER_') ~= nil, 'chamber run started: ' .. s.helltide.current_state)
    ok(s.tear.session().chamber_anchor ~= nil, 'chamber anchored')
end)

case('ring gizmo without a tear: KILL_GUARDS stay is bounded, the rupture completes', function()
    local s = session({enabled = true, mode = 1})
    normal_rupture(s, 30)
    s.actors[#s.actors + 1] = actor(SKIN.hold, 31, 0)
    s.tick(1.2) -- past the task's 1 s actor cache
    s.pos = v(29, 0, 0)
    s.tick(0.5)
    eq(s.helltide.current_state, 'RIFT_KILL_GUARDS')
    s.tick(29)
    eq(s.helltide.current_state, 'RIFT_KILL_GUARDS', 'waits at the ring for a while')
    s.tick(20)
    ok(s.logged('No tear at the ritual ring') >= 1, 'bounded wait logged')
    ok(s.logged('Normal rupture complete') >= 1, 'linger/completion ran\n' .. table.concat(s.logs, '\n'))
    eq(s.tear.is_rift_state(s.helltide.current_state), false, 'back to patrol long before RUPTURE_MAX_S')
end)

case('ring-only rupture is Unknown (no Realmwalker wait) until a starter confirms its type', function()
    local s = session({enabled = true, mode = 1})
    s.actors = {actor(SKIN.hold, 10, 0)}
    s.tick(1)
    ok(s.tear.is_rift_state(s.helltide.current_state), 'ring engaged')
    eq(s.tear.session().rupture_type, 'Unknown', 'not assumed Surging')
    s.pos = v(10, 0, 0)
    s.tick(45)
    eq(s.states.RIFT_WAIT_REALMWALKER, nil, 'no Realmwalker wait for an unconfirmed type')
    ok(s.logged('Unknown rupture complete') >= 1, 'completed as Unknown')
    -- Surging toggle off: a ring next to a Surging starter is not engaged.
    local t = session({enabled = true, mode = 1})
    t.controls.rupture_hunt_surging.value = false
    t.actors = {actor(SKIN.hold, 10, 0), actor(SKIN.surging_starter, 12, 0)}
    t.tick(3)
    eq(t.any_rift_state(), nil, 'Hunt Surging off is honoured for a ring')
    -- A ring engaged as Unknown picks its type up from the starter.
    local u = session({enabled = true, mode = 1})
    u.actors = {actor(SKIN.hold, 10, 0)}
    u.tick(1)
    u.actors[#u.actors + 1] = actor(SKIN.surging_starter, 40, 0)
    u.pos = v(10, 0, 0)
    u.tick(3)
    eq(u.tear.session().rupture_type, 'Surging', 'type confirmed from the starter skin')
end)

case('unreachable rupture chest is skipped after the approach watchdog; chest tries are per chest', function()
    local s = session({enabled = true, mode = 1})
    normal_rupture(s, 30)
    s.pos = v(29, 0, 0)
    local tear = actor(SKIN.tear, 31, 0, {hp = 40})
    s.actors[#s.actors + 1] = tear
    -- A live tear keeps moving (else it is skipped as static after 12 s).
    s.before_tick = function() tear.pos = v(31, 0, math.floor(s.now) % 2) end
    s.tick(6)
    eq(s.helltide.current_state, 'RIFT_CLOSE_TEARS')
    local far = actor(SKIN.chest, 60, 0) -- 31 m out, player never gets closer
    s.actors[#s.actors + 1] = far
    s.tick(1.5)
    eq(s.helltide.current_state, 'RIFT_OPEN_CHEST')
    s.tick(14)
    ok(s.logged('No progress towards chest') >= 1, 'approach watchdog fired')
    ok(s.helltide.current_state ~= 'RIFT_OPEN_CHEST', 'rupture resumed')
    s.tick(3)
    ok(s.helltide.current_state ~= 'RIFT_OPEN_CHEST', 'skipped chest not re-picked')
    -- A chest that opens resets the per-chest try counter.
    local near = actor(SKIN.chest, 30, 0)
    s.actors[#s.actors + 1] = near
    s.tick(1.5)
    eq(s.helltide.current_state, 'RIFT_OPEN_CHEST')
    s.pos = v(30, 0, 0)
    s.tick(0.3)
    eq(s.tear.session().chest_tries, 1, 'one interact')
    near.interactable = false
    s.tick(4)
    ok(s.helltide.current_state ~= 'RIFT_OPEN_CHEST', 'resumed after the chest')
    eq(s.tear.session().chest_tries, nil, 'tries reset for the next chest')
end)

case('GUI mode defaults to Farm for manual use; maiden/chaos toggles say Farm only', function()
    local f = assert(io.open(root .. 'gui.lua', 'r'))
    local src = f:read('*a'); f:close()
    ok(src:find('mode = combo_box:new(1, get_hash(plugin_label .. "_mode"))', 1, true), 'combo default is Farm (1)')
    ok(src:find('"Do Maiden (Farm mode only)"', 1, true), 'maiden toggle labelled')
    ok(src:find('"Do chaos rift (Farm mode only)"', 1, true), 'chaos rift toggle labelled')
    local s = session({mode = 0, enabled = true})
    s.tick(0.2)
    ok(s.logged('Maiden / chaos rift toggles are Farm-mode only') >= 1, 'warplan notes the ignored toggles')
end)

case('new HR modules load under this runtime (LuaJIT limits: run_tests.py scan) and helltide.lua keeps a local margin', function()
    for _, f in ipairs({'core/hr_mode.lua', 'core/hr_tear_event.lua', 'core/hr_rupture_leash.lua',
        'data/hr_tear_skins.lua', 'tasks/helltide.lua', 'gui.lua', 'core/settings.lua', 'main.lua'}) do
        local chunk, err = loadfile(root .. f)
        ok(chunk ~= nil, f .. ': ' .. tostring(err))
    end
    -- Rough guard (the exact count is run_tests.py's): file-level `local`
    -- statements in tasks/helltide.lua stay well below LuaJIT's 200.
    local n = 0
    for line in io.lines(root .. 'tasks/helltide.lua') do
        if line:match('^local[%s]') then n = n + 1 end
    end
    ok(n <= 190, 'tasks/helltide.lua has ' .. n .. ' file-level locals (keep <= 190)')
end)

print(string.format('Helltide modes: %d cases, %d checks, %d failures', cases, checks, #failures))
if #failures > 0 then error('Helltide modes failures:\n' .. table.concat(failures, '\n')) end
print('PASS: test_helltide_modes (' .. cases .. ' cases)')
