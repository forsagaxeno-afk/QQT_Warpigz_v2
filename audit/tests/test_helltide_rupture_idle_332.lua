-- QQT_Warpigz_v3 3.3.2 (live, Farm / smart farm with tears on): "Seeing
-- quite a bit of just standing around waiting. Says activity is
-- Pandemonium Rupture with local movement but there is no rupture."
-- A rupture state must end within a few seconds when no live rupture actor
-- (open tear, cultist, Realmwalker) is there; every wait is bounded and a
-- spent rupture is never re-armed; the activity line never claims a
-- rupture that is not there. Drives the real HelltideRevamped main.lua /
-- tasks/helltide.lua / core/hr_tear_event.lua (Farm mode, standalone) with
-- the test_helltide_tears_stand harness. Runs under Lua 5.4 and LuaJIT.
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
local last_session
local function case(name, fn)
    cases = cases + 1
    last_session = nil
    local passed, err = pcall(fn)
    if passed then
        print('PASS Helltide rupture idle: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Helltide rupture idle: ' .. name .. ': ' .. tostring(err))
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

local PROGRESS = 2
local next_id = 7000
-- opts.readable=false: the charge attribute cannot be read (nil);
-- opts.no_id: no get_id (position key fallback).
local function actor(skin, x, y, opts)
    opts = opts or {}
    next_id = next_id + 1
    local a = {skin = skin, pos = v(x, y, 0), interactable = opts.interactable ~= false, hp = opts.hp,
        id = next_id, progress = opts.progress}
    function a:get_skin_name() return self.skin end
    function a:get_position() return self.pos end
    function a:is_interactable() return self.interactable end
    if not opts.no_id then function a:get_id() return self.id end end
    if opts.hp then function a:get_current_health() return self.hp end end
    if opts.readable ~= false then
        function a:get_attribute(k) if k == PROGRESS then return (self.progress or 0) * (self.scale or 1) end return 0 end
    end
    return a
end

local SKIN = {
    normal_starter = 'S14_Rupture_SMP_SwitchGizmo',
    surging_starter = 'S14_Rupture_LE_SwitchGizmo',
    boundary = 'PandemoniumRift_gizmo_Boundry',
    hold = 'S14_PandemoniumCrack_gizmo_holdArea',
    glint = 'S14_Rupture_SMP_Chargeable',
    chest = 'S14_Rupture_SMP_PandemoniumChest',
}
local HELLTIDE_BUFF = 1066539
local SPEED, CIRCLE = 7, 2.5 -- m/s; the golden circle a tear charges in

local function session(opts)
    opts = opts or {}
    local s = {now = 100, minute = 10, pos = v(0, 0, 0), zone = 'Test_Zone', in_helltide = true,
        cinders = 311, actors = {}, loot = {}, logs = {}, interactions = {}, states = {}, dead = false,
        orb = {clear = true, block = false}, pauses = {}, acquires = 0, releases = 0, tears = {}, closed = 0,
        inside = 0, left_circle = 0, frozen = false}
    local bm = {target = nil}
    s.bm = bm
    local player = {
        get_position = function() return s.pos end, get_current_speed = function() return 0 end,
        is_dead = function() return s.dead end, get_item_count = function() return s.items or 0 end,
        get_consumable_items = function() return {} end, get_attribute = function() return 0 end,
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
    env.console = {print = function(line) s.logs[#s.logs + 1] = string.format('%.1f %s', s.now, tostring(line)) end}
    env.target_selector = {get_near_target_list = function() return {} end}
    env.actors_manager = {get_all_actors = function() return s.actors end, get_enemy_actors = function() return {} end}
    env.loot_manager = {get_all_items_chest_sort_by_distance = function() return s.loot end,
        any_item_around = function() return false end}
    env.utility = {set_height_of_valid_position = function(p) return p end, is_point_walkeable = function() return true end}
    env.pathfinder = {request_move = function() end, clear_stored_path = function() end}
    env.teleport_to_waypoint = function() end
    env.interact_object = function(a) s.interactions[#s.interactions + 1] = a end
    env.revive_at_checkpoint = function() s.revives = (s.revives or 0) + 1 end
    env.attributes = {PLAYER_IN_TOWN_LEVEL_AREA = 1, CHARGEABLE_GIZMO_PROGRESS = PROGRESS, GIZMO_HAS_BEEN_OPERATED = 3}
    env.orbwalker = {set_clear_toggle = function(on) s.orb.clear = on end,
        set_block_movement = function(on) s.orb.block = on end}
    -- QQT_Warpigz_v3 3.3.4: the whole clock is scripted (a fixed UTC hour at
    -- s.minute): core/hr_clock.lua also reads os.time() and os.date('!*t'),
    -- and the real wall clock made results depend on when the suite ran (:00).
    local function pinned_epoch() return 1790002800 + s.minute * 60 end
    env.os = setmetatable({date = function(fmt, t)
        if fmt == '%M' or fmt == '!%M' then return string.format('%02d', s.minute) end
        if fmt == '!%S' then return '00' end
        return os.date(fmt, t or pinned_epoch())
    end, time = function(t) if t then return os.time(t) end return pinned_epoch() end}, {__index = os})
    env.BatmobilePlugin = {
        pause = function() end, resume = function() end,
        set_target = function(_, t) bm.target = t; s.moves = (s.moves or 0) + 1; return true end,
        clear_target = function() bm.target = nil end, stop_long_path = function() end,
        update = function() end, move = function() end, is_paused = function() return false end,
        is_done = function() return false end, reset = function() bm.target = nil end,
        reset_movement = function() bm.target = nil end, get_target = function() return bm.target end,
        clear_giving_up = function() end, is_giving_up = function() return false end,
        navigate_long_path = function() return true end, is_long_path_navigating = function() return false end,
        get_closeby_node = function(_, p) return p end, clear_traversal_blacklist = function() end,
        release = function() bm.target = nil end,
    }
    -- Rosie-shaped Looter (acquire_pause/release_pause by caller): busy while
    -- its item lies on the ground and no one paused it; it steers the player.
    env.LooteerPlugin = {get_enabled = function() return true end,
        is_actively_looting = function() return s.loot_item ~= nil and next(s.pauses) == nil end,
        acquire_pause = function(c) s.pauses[c] = s.now; s.acquires = s.acquires + 1; return true end,
        release_pause = function(c) s.pauses[c] = nil; s.releases = s.releases + 1; return true end}
    local function control(value)
        return {value = value, get = function(self) return self.value end, set = function(self, n) self.value = n end}
    end
    local controls = setmetatable({}, {__index = function(t, k) local c = control(false); rawset(t, k, c); return c end})
    local defaults = {main_toggle = true, town = 0, helltide_chest_toggle = true,
        kill_monsters_toggle = false, kill_monsters_rarity = 0, farm_cinder_threshold = 0,
        maiden_disable_cinders = 0, mode = opts.mode or 1, hunt_rift_toggle = true,
        rupture_hunt_normal = true, rupture_hunt_surging = true, rupture_hunt_colossal = true,
        rupture_open_chests = true, tear_use_charge_ring = true, rupture_max_cinders = 0,
        tear_search_dist = 110, tear_passby_dist = 50, tear_event_radius = 12, tear_circle_radius = 2,
        rupture_linger_sec = 5, rupture_do_realmwalker = opts.rw == true, rupture_rw_wait_sec = 25}
    for k, value in pairs(defaults) do controls[k] = control(value) end
    s.controls = controls
    local noop = setmetatable({}, {__index = function() return function() end end})
    local modules = {
        gui = {elements = controls, render = function() end, mode = {'Warplan', 'Farm'},
            town_data = {[0] = {zone_name = 'Skov_Temis', waypoint_sno = 0x1CE51E}}},
        ['core.perf'] = noop, ['core.helltide_explorer'] = noop,
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
    s.tear = env.require('core.hr_tear_event')
    s.helltide = env.require('tasks.helltide')
    assert(loadfile(root .. 'main.lua', 't', env))()
    s.plugin = env.HelltideRevampedPlugin
    last_session = s

    local function step_to(target, dt)
        local d = s.pos:dist_to(target)
        if d <= 0.3 then return end
        local k = math.min(d, SPEED * dt) / d
        s.pos = v(s.pos:x() + (target:x() - s.pos:x()) * k, s.pos:y() + (target:y() - s.pos:y()) * k, 0)
    end
    -- One simulated host frame: Batmobile walks to its goal, a busy Looter
    -- steers the player to its item, tears in whose circle the player stands
    -- charge (1 / close_s per second) and close at 100 %.
    function s.tick(seconds, dt)
        dt = dt or 0.1
        for _ = 1, math.floor(seconds / dt + 0.5) do
            s.now = s.now + dt
            if bm.target and not s.frozen then
                step_to(bm.target.get_position and bm.target:get_position() or bm.target, dt)
            end
            if s.loot_item and next(s.pauses) == nil then
                if s.pos:dist_to(s.loot_item) > 0.5 then step_to(s.loot_item, dt) else s.loot_item = nil end
            end
            if s.push then s.pos = s.push; s.push = nil end
            local in_any, in_tear = false, nil
            for i = #s.tears, 1, -1 do
                local t = s.tears[i]
                if s.pos:dist_to(t.pos) <= CIRCLE then
                    in_any, in_tear = true, t
                    if t.close_s then
                        t.progress = (t.progress or 0) + dt / t.close_s
                        if t.progress >= 1 then
                            s.closed = s.closed + 1
                            table.remove(s.tears, i)
                            if t.stay_listed then
                                t.progress, t.close_s = 1, nil -- closed, the gizmo stays listed at 100 %
                            else
                                for j, a in ipairs(s.actors) do if a == t then table.remove(s.actors, j) break end end
                            end
                        end
                    end
                end
            end
            if in_any then s.inside = s.inside + dt end
            -- left the circle of a tear that is still open
            if s.was_in and s.was_in ~= in_tear then
                for _, t in ipairs(s.tears) do
                    if t == s.was_in then s.left_circle = s.left_circle + 1 end
                end
            end
            s.was_in = in_tear
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
    return s
end


local function rift(s) return s.tear.is_rift_state(s.helltide.current_state) end
-- Seconds spent in rupture states and the number of fresh engagements.
local function watch(s)
    s.rift_s, s.engages = 0, 0
    local was = false
    s.before_tick = function()
        local now_rift = rift(s)
        if now_rift then s.rift_s = s.rift_s + 0.1 end
        if now_rift and not was then s.engages = s.engages + 1 end
        was = now_rift
    end
end
-- A finished rupture's leftovers 20 m east: ring, boundary gizmos and a
-- spent starter (no tear, no cultist, no Realmwalker).
local function leftovers(s, starter)
    s.actors = {actor(SKIN.hold, 20, 0), actor(SKIN.boundary, 32, 0), actor(SKIN.boundary, 8, 0),
        actor(starter or SKIN.normal_starter, 20, 2, {interactable = false})}
end

case('a leftover ring (holdArea + boundary + spent starter) is left within seconds, not completed', function()
    local s = session()
    leftovers(s)
    watch(s)
    s.tick(30)
    ok(s.engages >= 1, 'the ring was looked at')
    ok(not rift(s), 'not in a rupture state 30 s later: ' .. tostring(s.helltide.current_state))
    ok(s.rift_s <= 12, string.format('at most a walk + a few seconds there (%.1fs)', s.rift_s))
    eq(s.logged('rupture complete'), 0, 'a dead site is not a completed rupture')
    eq(s.logged('No live rupture here'), 1, 'the exit names why')
end)

case('a spent site is not re-armed when its blacklist runs out', function()
    local s = session()
    leftovers(s)
    watch(s)
    s.tick(400)
    eq(s.engages, 1, 'engaged once in 400 s (the 120 s blacklist used to re-arm it)')
    ok(s.rift_s <= 12, string.format('%.1fs in rupture states in all', s.rift_s))
    -- a new rupture at the same spot (an open tear) is engaged again
    local t = actor(SKIN.glint, 22, 0, {progress = 0})
    t.close_s = 5
    s.tears[#s.tears + 1] = t
    s.actors[#s.actors + 1] = t
    s.tick(30)
    eq(s.closed, 1, 'a live tear at the spent site is still closed')
end)

case('a leftover Surging site with the Realmwalker on: no Realmwalker wait', function()
    local s = session({rw = true})
    leftovers(s, SKIN.surging_starter)
    watch(s)
    s.tick(45)
    eq(s.states.RIFT_WAIT_REALMWALKER, nil, 'never waited for a Realmwalker at a dead site')
    ok(not rift(s), 'left the site')
    ok(s.rift_s <= 12, string.format('%.1fs in rupture states', s.rift_s))
end)

case('a leftover tear gizmo that never closes is stood in once, never re-engaged', function()
    local s = session()
    leftovers(s)
    -- closed, still listed, charge unreadable (reads as open): a stale glint
    local g = actor(SKIN.glint, 24, 0, {readable = false})
    s.actors[#s.actors + 1] = g
    watch(s)
    s.tick(500)
    eq(s.logged('Engaging tear'), 1, 'engaged once (a new session re-engaged it for another 90 s)')
    ok(s.rift_s <= 120, string.format('%.1fs in rupture states in 500 s', s.rift_s))
end)

case('after the last tear an unreachable ring centre does not park the bot until the 300 s cap', function()
    local s = session()
    s.actors = {actor(SKIN.normal_starter, 30, 0), actor(SKIN.hold, 30, 0)}
    local t = actor(SKIN.glint, 30, 20, {progress = 0}) -- 20 m from the ring centre
    t.close_s = 5
    s.tears = {t}
    s.actors[#s.actors + 1] = t
    local closed_at, left_at
    s.before_tick = function()
        if s.closed == 1 and not closed_at then
            closed_at = s.now
            s.frozen = true -- Batmobile cannot reach the ring centre from the tear
        end
        if closed_at and not left_at and not rift(s) then left_at = s.now end
    end
    s.tick(90)
    eq(s.closed, 1, 'the tear was closed')
    ok(left_at, 'left the rupture')
    ok(left_at and left_at - closed_at <= 20, string.format('within 20 s of the last tear (%.1fs)', (left_at or s.now) - closed_at))
    ok(s.logged('Normal rupture complete') >= 1, 'a live rupture still completes')
end)

case('a starter that despawns on the way: no 20 s wait at an empty spot', function()
    local s = session()
    s.actors = {actor(SKIN.normal_starter, 60, 0)}
    s.tick(1.5)
    eq(s.helltide.current_state, 'MOVING_TO_RIFT')
    s.actors = {} -- despawned (its handle still reports the old position)
    watch(s)
    s.tick(40)
    ok(not rift(s), 'left')
    eq(s.logged('Timed out waiting for the rupture to open'), 0, 'no 20 s wait for an opening')
    ok(s.rift_s <= 15, string.format('%.1fs more in rupture states', s.rift_s))
end)

case('the activity line claims a Pandemonium rupture only while one is live', function()
    local s = session()
    local view = s.env.require('core.hr_view')
    leftovers(s)
    s.tick(3)
    ok(rift(s), 'looking at the leftover site')
    local label = view.activity(s.helltide.current_state)
    ok(label ~= 'Pandemonium rupture', 'no rupture claimed at a dead site: ' .. tostring(label))
    local w = session()
    local wview = w.env.require('core.hr_view')
    w.actors = {actor(SKIN.normal_starter, 30, 0), actor(SKIN.hold, 30, 0)}
    local t = actor(SKIN.glint, 32, 0, {progress = 0})
    t.close_s = 60
    w.tears = {t}
    w.actors[#w.actors + 1] = t
    w.tick(8)
    eq(w.helltide.current_state, 'RIFT_CLOSE_TEARS')
    eq(wview.activity(w.helltide.current_state), 'Pandemonium rupture', 'a live rupture is named')
end)

print(string.format('Helltide rupture idle: %d cases, %d checks, %d failures', cases, checks, #failures))
if #failures > 0 then error('Helltide rupture idle failures:\n' .. table.concat(failures, '\n')) end
print('PASS: test_helltide_rupture_idle_332 (' .. cases .. ' cases)')
