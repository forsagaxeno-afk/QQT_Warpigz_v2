-- QQT_Warpigz_v3 (rc.2, Q2): "the bot barely stands in the tears".
-- A Helltide tear (Pandemonium rupture tear) closes while the player stands
-- inside its golden circle and enemies die there. These cases drive the real
-- HelltideRevamped main.lua / tasks/helltide.lua / core/hr_tear_event.lua
-- (Farm mode, standalone: WarPigs always runs Warplan, which never enters a
-- tear) with a moving player, charging tears, a Rosie-shaped Looter that
-- steers the player to its item unless paused, and chests.
-- Runs under Lua 5.4 and LuaJIT.
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
        print('PASS Helltide tears: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Helltide tears: ' .. name .. ': ' .. tostring(err))
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
    env.os = setmetatable({date = function(fmt, ...)
        if fmt == '%M' or fmt == '!%M' then return string.format('%02d', s.minute) end
        if fmt == '!%S' then return '00' end
        return os.date(fmt, ...)
    end}, {__index = os})
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
        rupture_linger_sec = 5, rupture_do_realmwalker = false, rupture_rw_wait_sec = 25}
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

-- A Normal rupture 30 m east (ring + starter) with three golden tears.
-- close_s: seconds inside the circle to close one (nil: never closes).
local function rupture(s, close_s, topts)
    s.actors = {actor(SKIN.normal_starter, 30, 0), actor(SKIN.hold, 30, 0)}
    for _, p in ipairs({{34, 0}, {30, 6}, {25, -3}}) do
        local o = {progress = 0}
        for k, val in pairs(topts or {}) do o[k] = val end
        local t = actor(SKIN.glint, p[1], p[2], o)
        t.close_s, t.scale, t.stay_listed = close_s, o.scale, o.stay_listed
        s.tears[#s.tears + 1] = t
        s.actors[#s.actors + 1] = t
    end
end

-- ── the tears are stood in until they close ───────────────────────────────
case('Q2 every tear is stood in until it closes (30 s each, charge readable)', function()
    local s = session()
    rupture(s, 30)
    s.tick(200)
    eq(s.closed, 3, 'all three tears closed')
    ok(s.inside >= 89, string.format('stood %.1fs inside tear circles (3 x 30 s needed)', s.inside))
    eq(s.logged('static'), 0, 'no tear skipped as static')
    eq(s.logged('not closing'), 0, 'no tear dropped after 18 s')
    eq(s.logged('Skipping tear'), 0, 'no tear skipped at all')
    eq(s.left_circle, 0, 'never left a circle while a tear was open')
    eq(s.logged('Tear closed after'), 3, 'one close line per tear')
    ok(s.logged('rupture complete') >= 1, 'rupture completed after the last tear')
end)

case('Q2 tears are closed when the charge cannot be read (nil)', function()
    local s = session()
    rupture(s, 30, {readable = false})
    s.tick(200)
    eq(s.closed, 3, 'all three tears closed')
    eq(s.logged('Skipping tear'), 0, 'no tear skipped')
end)

case('Q2 a charge reported on a 0-100 scale does not read as closed at 1 %', function()
    local s = session()
    rupture(s, 30, {scale = 100})
    s.tick(200)
    eq(s.closed, 3, 'all three tears closed')
    ok(s.inside >= 89, string.format('stood %.1fs inside tear circles', s.inside))
end)

case('Q2 a closed tear that stays listed at 100 % (0-1 scale) is left within ~1 s', function()
    local s = session()
    rupture(s, 10, {stay_listed = true})
    s.tick(60)
    eq(s.closed, 3, 'all three tears closed')
    eq(s.logged('Tear closed after'), 3, 'each counted closed once')
    eq(s.logged('Skipping tear'), 0, 'none skipped')
end)

case('Q2 tears without an actor id (position key) are still stood in until they close', function()
    local s = session()
    rupture(s, 20, {no_id = true})
    s.tick(150)
    eq(s.closed, 3, 'all three tears closed')
    eq(s.logged('Skipping tear'), 0, 'no tear skipped')
end)

case('Q2 standing: small pushes inside the circle are not re-centred, a push out walks back', function()
    local s = session()
    rupture(s, 60)
    s.tick(10)
    eq(s.helltide.current_state, 'RIFT_CLOSE_TEARS')
    local t = s.tear.session().focus_tear
    ok(t and s.pos:dist_to(t.pos) <= 1.05, 'standing on the glint')
    s.moves = 0
    s.push = v(t.pos:x() + 1.5, t.pos:y(), 0)
    s.tick(1)
    eq(s.moves, 0, '1.5 m off the glint (inside the circle): no move issued')
    s.push = v(t.pos:x() + 5, t.pos:y(), 0)
    s.tick(2)
    ok(s.moves > 0, 'pushed out of the circle: walks back')
    ok(s.pos:dist_to(t.pos) <= 1.05, 'back on the glint')
end)

-- ── no chest / loot detour while a tear is engaged ─────────────────────────
case('Q2 a chest in reach waits until the engaged tear closed', function()
    local s = session()
    rupture(s, 20)
    s.tick(10)
    eq(s.helltide.current_state, 'RIFT_CLOSE_TEARS')
    local pchest = actor(SKIN.chest, 40, 8)
    s.actors[#s.actors + 1] = pchest
    local detour_while_open = false
    s.before_tick = function()
        if s.helltide.current_state == 'RIFT_OPEN_CHEST' and #s.tears > 0 then detour_while_open = true end
    end
    s.tick(80)
    eq(detour_while_open, false, 'no chest detour while a tear was open')
    eq(s.closed, 3, 'all three tears closed')
    eq(s.left_circle, 0, 'never left a circle while a tear was open')
    ok(s.interactions[1] == pchest, 'the chest is opened after the tears')
end)

case('Q2/Q3 Rosie pickup is paused while a tear is engaged, refreshed (bounded) and released after the event', function()
    local s = session()
    rupture(s, 20)
    s.tick(8)
    eq(s.helltide.current_state, 'RIFT_CLOSE_TEARS')
    ok(s.pauses.HelltideRevamped ~= nil, 'pickup paused by HelltideRevamped')
    -- a drop lands 11 m away: the paused Looter does not steer the player out
    s.loot_item = v(s.pos:x() + 9, s.pos:y() + 7, 0)
    s.tick(60)
    eq(s.closed, 3, 'all three tears closed')
    eq(s.left_circle, 0, 'never left a circle while a tear was open')
    ok(s.acquires >= 10 and s.acquires <= 16, 'refreshed about every 5 s, not every tick: ' .. s.acquires)
    eq(s.logged('Pausing Looter pickup'), 1, 'one pause line')
    -- QQT_Warpigz_v3 (Q3): held until the whole event is over (this Normal
    -- rupture: until it completes after the linger), not just the last tear.
    ok(s.pauses.HelltideRevamped ~= nil, 'still paused right after the last tear (event not over)')
    local waited = 0
    while s.pauses.HelltideRevamped ~= nil and waited < 15 do s.tick(0.1); waited = waited + 0.1 end
    eq(s.pauses.HelltideRevamped, nil, 'released once the event is over')
    eq(s.logged('Looter pickup resumed (tear event over: rupture complete)'), 1, 'one resume line, at the event end')
    ok(waited >= 4, string.format('not before the rupture completed (%.1fs after the last tear)', waited))
    s.tick(6)
    eq(s.loot_item, nil, 'the Looter picked the drop up after the event')
end)

-- ── C6: every stand is bounded and the pause released on every exit ───────
case('Q2/C6 a tear that never closes is left after 90 s inside; the rupture ends in its cap', function()
    local s = session()
    rupture(s, nil) -- never charges
    s.tick(100)
    eq(s.logged('still open after 90s inside its circle'), 1, 'first tear skipped once, after 90 s inside')
    s.tick(220)
    ok(s.logged('Rupture took longer than 300s') + s.logged('rupture complete') >= 1, 'rupture left within its cap')
    ok(not s.tear.is_rift_state(s.helltide.current_state), 'back to patrol')
    eq(s.pauses.HelltideRevamped, nil, 'pause released')
end)

case('Q2/C6 a charge that moved and then stalls is left after 30 s inside', function()
    local s = session()
    rupture(s, 1000) -- charges very slowly ...
    s.tick(12)
    for _, t in ipairs(s.tears) do t.close_s = nil end -- ... then stops charging
    s.tick(40)
    eq(s.logged('no progress for 30s inside its circle'), 1, 'stalled tear skipped once')
end)

case('Q2/C6 an unreachable tear is skipped after 15 s without getting closer', function()
    local s = session()
    rupture(s, 20)
    s.frozen = true -- Batmobile cannot get anywhere (player 25+ m from every tear)
    s.tick(20)
    ok(s.logged('no progress towards it for 15s') >= 1, 'approach watchdog fired')
end)

case('Q2/C6 the pause is released on disable, death, reset and a switch to Warplan', function()
    local s = session()
    rupture(s, 60)
    s.tick(8)
    ok(s.pauses.HelltideRevamped ~= nil, 'paused')
    s.controls.main_toggle:set(false)
    s.tick(0.5)
    eq(s.pauses.HelltideRevamped, nil, 'disable releases')
    s.controls.main_toggle:set(true)
    s.tick(3)
    ok(s.pauses.HelltideRevamped ~= nil, 'paused again')
    s.dead = true
    s.tick(0.5)
    eq(s.pauses.HelltideRevamped, nil, 'death releases')
    s.dead = false
    s.tick(3)
    ok(s.pauses.HelltideRevamped ~= nil, 'paused again after revive')
    s.helltide:reset()
    eq(s.pauses.HelltideRevamped, nil, 'reset (zone change / new session) releases')
    local w = session()
    rupture(w, 60)
    w.tick(8)
    ok(w.pauses.HelltideRevamped ~= nil, 'paused')
    w.controls.mode:set(0)
    w.tick(0.5)
    eq(w.pauses.HelltideRevamped, nil, 'Warplan releases')
end)

case('Q2 WarPigs (external enable = Warplan) never engages a tear or pauses pickup', function()
    local s = session()
    s.plugin.enable()
    rupture(s, 20)
    s.tick(30)
    for state in pairs(s.states) do ok(not s.tear.is_rift_state(state), 'no rupture state: ' .. state) end
    eq(s.acquires, 0, 'pickup never paused')
end)

-- ── a tear 25-30 m from the anchor is approached ──────────────────────────
case('Q2 a tear at the edge of the reach is walked to (no CLOSE_TEARS / STAY_ACTIVE bounce)', function()
    local s = session()
    s.actors = {actor(SKIN.normal_starter, 30, 0), actor(SKIN.hold, 30, 0)}
    local t = actor(SKIN.glint, 30, 39, {progress = 0}) -- 39 m from the ring
    t.close_s = 10
    s.tears = {t}
    s.actors[#s.actors + 1] = t
    s.pos = v(30, 0, 0)
    s.tick(30)
    eq(s.closed, 1, 'the edge tear was reached and closed')
end)

-- ── QQT_Warpigz_v3 (rc.2 review): regression coverage ─────────────────────
case('review: a tear whose reported position jitters across a metre line keeps one focus (id key)', function()
    local s = session()
    rupture(s, 30)
    local t1 = s.tears[1]
    s.before_tick = function()
        if t1 then t1.pos = v((math.floor(s.now * 2) % 2 == 0) and 33.95 or 34.05, 0, 0) end
    end
    s.tick(200)
    eq(s.closed, 3, 'all three tears closed')
    eq(s.logged('Tear closed after'), 3, 'one close line per tear')
    eq(s.logged('Engaging tear'), 3, 'one engage line per tear')
end)

case('review: ENGAGED_MAX_S ends a tear that keeps pushing the player out (inside time under 90 s)', function()
    local s = session()
    local stand = s.env.require('core.hr_tear_stand')
    local sess, why, t = {}, nil, 0
    while t < 200 and not why do
        -- 10 s inside, then 14 s knocked out of the circle (no approach bound: < 15 s)
        local d = (t % 24) < 10 and 1.0 or 8
        why = stand.work(sess, 'k', d, nil, t, stand.C.STAND_OUT)
        t = t + 0.1
    end
    ok(why and why:find('engaged 150s', 1, true), 'skipped by the engaged bound: ' .. tostring(why))
    ok(t <= 150.6, string.format('at 150 s (%.1f)', t))
    ok(stand.inside_seconds(sess, 'k') < stand.C.INSIDE_MAX_S, 'inside time stayed under INSIDE_MAX_S')
end)

case('review: a Looter/Alfred yield is credited to the stand bounds', function()
    local s = session()
    rupture(s, nil) -- never closes
    s.tick(10)
    local f = s.tear.session().focus_tear
    ok(f and s.pos:dist_to(f.pos) <= 1.05, 'standing in the tear')
    s.now = s.now + 200 -- the task yielded 200 s (its handlers did not run)
    s.tick(1)
    eq(s.logged('Skipping tear'), 0, 'the yield did not count toward the engaged bound')
    eq(s.logged('took longer than'), 0, 'nor toward the rupture cap')
    ok(s.tear.session().focus_tear == f, 'still standing in the same tear')
end)

case('review: the per-tear pause counts only at the engaged tear (hysteresis)', function()
    local s = session()
    local stand = s.env.require('core.hr_tear_stand')
    local sess = {}
    eq(stand.at_tear(sess, 'a', 40), false, 'engaged 40 m away: not yet')
    eq(stand.at_tear(sess, 'a', 4.9), true, 'at the tear')
    eq(stand.at_tear(sess, 'a', 9.5), true, 'knocked back 9.5 m: kept')
    eq(stand.at_tear(sess, 'b', 9.5), false, 'another tear 9.5 m away: not yet')
    eq(stand.at_tear(sess, 'b', 4), true, 'at the other tear')
    eq(stand.at_tear(sess, 'b', 10.5), false, 'beyond 10 m: left')
    eq(stand.at_tear(sess, nil, 1), false, 'no engaged tear')
end)

case('review: a tear engaged from far away pauses pickup only once the player is at it', function()
    local s = session()
    rupture(s, 20)
    for _, a in ipairs(s.actors) do a.pos = v(a.pos:x() + 60, a.pos:y(), 0) end -- the ring 90 m out
    local far_pause = false
    s.before_tick = function()
        if s.pauses.HelltideRevamped and s.pos:dist_to(v(90, 0, 0)) > 12 + 10 + 0.5 then
            local f = s.tear.session().focus_tear
            if not (f and s.pos:dist_to(f.pos) <= 5) then far_pause = true end
        end
    end
    s.tick(90)
    eq(s.closed, 3, 'all three tears closed')
    eq(far_pause, false, 'no pause on the walk to the rupture')
    eq(s.logged('Pausing Looter pickup'), 1, 'one pause line')
end)

print(string.format('Helltide tears: %d cases, %d checks, %d failures', cases, checks, #failures))
if #failures > 0 then error('Helltide tears failures:\n' .. table.concat(failures, '\n')) end
print('PASS: test_helltide_tears_stand (' .. cases .. ' cases)')
