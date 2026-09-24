-- Batmobile integration regressions (C3 release, BAT-1..11, HLT-5, ARK-8,
-- WCY-8, live L10).  Loads the real Batmobile navigator / external /
-- long_path (and main.lua or the real explorer where a case needs them)
-- with QQT-shaped host mocks.  Runs under Lua 5.4 and LuaJIT.
local root = assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/Batmobile-1.0.12/'
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
        print('PASS Batmobile integration: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Batmobile integration: ' .. name .. ': ' .. tostring(err))
    end
end

local Vec = {}; Vec.__index = Vec
function Vec:new(x, y, z) return setmetatable({_x = x, _y = y, _z = z or 0}, self) end
function Vec:x() return self._x end
function Vec:y() return self._y end
function Vec:z() return self._z end
function Vec:dist_to(o) local dx, dy = self._x - o:x(), self._y - o:y(); return math.sqrt(dx*dx + dy*dy) end
local function v(x, y, z) return Vec:new(x, y, z) end
local function gizmo(name, x, y, z)
    return {get_position = function() return v(x, y, z) end, get_skin_name = function() return name end}
end

-- opts: real_explorer, main (load main.lua), actors, walkable(p), find_path(a,b,custom),
--       find_path_debug(a,b,caps)
local function harness(opts)
    opts = opts or {}
    local h = {now = 100, logs = {}, counts = {moves = 0, native_clears = 0, casts = 0, interacts = 0,
        selects = 0, visited_writes = 0, explorer_updates = 0, find_path = 0}, pf_goals = {},
        select_failed = {}}
    h.world = {name = 'Sanctuary_Eastern_Continent', zone = 'Scos_Coast', id = 1}
    h.actors = opts.actors or {}
    h.walkable = opts.walkable or function() return true end
    local player = {pos = v(0, 0), buffs = {}}
    function player:get_position() return self.pos end
    function player:get_buffs() return self.buffs end
    function player:get_attribute() return 0 end
    function player:get_character_class_id() return 0 end
    function player:is_dead() return false end
    function player:get_active_spell_id() return -1 end
    h.player = player
    local world = {}
    function world:get_name() return h.world.name end
    function world:get_current_zone_name() return h.world.zone end
    function world:get_world_id() return h.world.id end
    local settings = {step = 0.5, normalizer = 2, path_smooth_step = 0, log_level = 0, plugin_label = 't',
        use_movement = false, spell_interval = 0.15, min_spell_dist = 3, explore_path_budget_ms = 80,
        prefer_long_paths = false, update_settings = function() end}
    local tracker = {bench_enabled = false, bench_start = function() end, bench_stop = function() end,
        bench_count = function() end, bench_report = function() end, bench_set_meta = function() end,
        evaluated = {}, timer_update = 0, timer_move = 0}
    local env = setmetatable({vec3 = Vec, vec2 = Vec,
        get_time_since_inject = function() return h.now end,
        get_local_player = function() return player end,
        get_player_position = function() return player.pos end,
        get_current_world = function() if h.world == false then return nil end return world end,
        attributes = {PLAYER_IN_TOWN_LEVEL_AREA = 1},
        console = {print = function(s) h.logs[#h.logs + 1] = tostring(s) end},
        utility = {set_height_of_valid_position = function(p) return p end,
            is_point_walkeable = function(p) return h.walkable(p) end,
            can_cast_spell = function() return false end, is_ray_cast_walkeable = function() return true end},
        actors_manager = {get_all_actors = function() return h.actors end},
        cast_spell = {position = function() h.counts.casts = h.counts.casts + 1; return true end},
        pathfinder = {request_move = function() h.counts.moves = h.counts.moves + 1 end,
            clear_stored_path = function() h.counts.native_clears = h.counts.native_clears + 1 end,
            force_move_raw = function() h.counts.native_clears = h.counts.native_clears + 1 end},
        interact_object = function() h.counts.interacts = h.counts.interacts + 1 end,
        get_hash = function() return 1 end}, {__index = _G})
    env._G = env
    local modules = {['core.settings'] = settings, ['core.tracker'] = tracker,
        ['core.movement_engine'] = {pick = function() return nil end}}
    local find_path = opts.find_path or function(a, b) return {a, b}, false end
    modules['core.pathfinder'] = {
        find_path = function(a, b, custom, ...)
            h.counts.find_path = h.counts.find_path + 1
            h.pf_goals[#h.pf_goals + 1] = b
            return find_path(a, b, custom, ...)
        end,
        find_path_debug = opts.find_path_debug or function(a, b) return {a, b}, 2, 0.001, 'found' end,
        clear_wall_penalty_cache = function() end, last_pathfind = {}}
    if not opts.real_explorer then
        local visited = setmetatable({}, {__newindex = function(t, k, val)
            h.counts.visited_writes = h.counts.visited_writes + 1; rawset(t, k, val) end})
        modules['core.explorer'] = {backtracking = false, frontier_count = 5, backtrack = {}, visited = visited,
            priority = 'direction', default_priority = 'direction',
            update = function() h.counts.explorer_updates = h.counts.explorer_updates + 1 end,
            select_node = function(_, failed)
                h.counts.selects = h.counts.selects + 1
                h.select_failed[#h.select_failed + 1] = failed
                return opts.explorer_target or v(-40, 0)
            end,
            set_priority = function(p) if p == 'direction' or p == 'distance' then
                modules['core.explorer'].priority = p end end,
            reset = function() end, clear_frontiers_in_box = function() return 0 end}
    end
    env.require = function(name)
        if modules[name] ~= nil then return modules[name] end
        local chunk = assert(loadfile(root .. name:gsub('%.', '/') .. '.lua', 't', env))
        modules[name] = chunk()
        return modules[name]
    end
    if opts.main then
        local function widget(value)
            return {get_state = function() return value and 1 or 0 end, set = function(_, n) value = n end}
        end
        modules.gui = {elements = {reset_keybind = widget(false), long_path_set_target = widget(false),
            long_path_set_target_cursor = widget(false), long_path_test = widget(false),
            freeroam_keybind_toggle = widget(false), draw_keybind_toggle = widget(false),
            move_keybind_toggle = widget(false)}, render = function() end}
        modules['core.drawing'] = {draw_nodes = function() end}
        modules['core.movement_helpers'] = {observe_buffs = function() end}
        env.checkbox = {new = function() return {get = function() return false end, set = function() end} end}
        env.on_update = function(fn) h.update = fn end
        env.on_render_menu = function() end
        env.on_render = function() end
        assert(loadfile(root .. 'main.lua', 't', env))()
        h.ext = env.BatmobilePlugin
    else
        h.ext = env.require('core.external')
    end
    h.nav = env.require('core.navigator')
    h.lp = env.require('core.long_path')
    h.explorer = env.require('core.explorer')
    h.env = env
    function h.adv(dt) h.now = h.now + dt end
    function h.logged(pattern)
        local n = 0
        for _, line in ipairs(h.logs) do if line:find(pattern, 1, true) then n = n + 1 end end
        return n
    end
    return h
end

-- C3 + BAT-3 + BAT-6 + BAT-11: release is a deterministic, owner-scoped hand-off.
case('release clears goal, long route and traversal routing, pauses, restores priority', function()
    local trav = gizmo('Traversal_Gizmo_FreeClimb_Up', 10, 0)
    local h = harness({actors = {trav}})
    local ext, nav = h.ext, h.nav
    ext.set_priority('arkham_asylum', 'distance')
    ext.pause('arkham_asylum'); ext.set_target('arkham_asylum', v(40, 0))
    ok(ext.try_traversal_route('arkham_asylum'), 'traversal route engaged')
    nav.trav_escape_pos = v(9, 0); nav.post_trav_target = {pos = v(40, 0), is_custom = true}
    nav.all_trav_blocked_until = h.now + 60
    local moves = h.counts.moves
    eq(ext.release('arkham_asylum'), true)
    eq(nav.target, nil, 'goal dropped'); eq(nav.is_custom_target, false)
    eq(nav.last_trav, nil, 'last_trav'); eq(nav.trav_final_target, nil, 'trav_final_target')
    eq(nav.trav_escape_pos, nil, 'escape'); eq(nav.post_trav_target, nil, 'post-traversal goal')
    eq(nav.trav_delay, nil, 'trav_delay')
    ok(nav.all_trav_blocked_until > h.now, 'own portal-ledge safeguard survives a plain release')
    eq(ext.is_traversal_routing(), false); eq(ext.is_paused(), true, 'released navigator is paused')
    eq(h.explorer.priority, 'direction', 'default explorer priority restored')
    eq(h.counts.moves, moves, 'release issues no movement'); eq(h.counts.native_clears, 0, 'native path untouched')
    -- BAT-3: the next task/plugin's target is applied, not swallowed.
    local accepted = ext.set_target('arkham_asylum', v(25, 5))
    eq(accepted, true); ok(nav.target ~= nil and nav.target:x() == 25, 'next set_target is applied')
    -- long route owned by the caller is stopped
    eq(ext.navigate_long_path('reaper', v(30, 0)), true); eq(ext.get_owner(), 'reaper')
    ext.release('Reaper')
    eq(ext.is_long_path_navigating(), false, 'own long route stopped (case-insensitive owner)')
    eq(ext.get_owner(), nil)
end)

case('release by another plugin leaves the current owner alone', function()
    local h = harness()
    local ext, nav = h.ext, h.nav
    eq(ext.navigate_long_path('wonder_city', v(30, 0)), true)
    ext.release('helltide_revamped')
    eq(ext.is_long_path_navigating(), true, 'foreign route survives')
    ok(nav.target ~= nil, 'foreign goal survives'); eq(ext.get_owner(), 'wonder_city')
    ok(h.logged('left untouched') == 1, 'one diagnostic line')
    ext.set_priority('wonder_city', 'distance'); ext.release('helltide_revamped')
    eq(h.explorer.priority, 'distance', 'priority owned by another plugin is kept')
    ext.release('wonder_city')
    eq(ext.is_long_path_navigating(), false); eq(h.explorer.priority, 'direction')
end)

-- BAT-11 / ARK-8 / WCY-8
case('reset() restores the default explorer priority', function()
    local h = harness()
    h.ext.set_priority('wonder_city', 'distance'); eq(h.explorer.priority, 'distance')
    h.ext.reset('helltide_revamped')
    eq(h.explorer.priority, 'direction', 'priority does not leak into the next consumer')
end)

-- BAT-3 detail: deferred acceptances are distinguishable but stay truthy.
case('set_target reports deferred acceptance as (true, "deferred")', function()
    local h = harness()
    h.ext.pause('arkham_asylum'); h.ext.set_target('arkham_asylum', v(5, 0))
    h.nav.trav_escape_pos = v(1, 0)
    local accepted, detail = h.ext.set_target('arkham_asylum', v(8, 0))
    eq(accepted, true); eq(detail, 'deferred')
    ok(h.nav.post_trav_target ~= nil and h.nav.post_trav_target.pos:x() == 8, 'goal queued for after the escape')
end)

-- BAT-1 (critic: guard on paused only).
case('paused stationary fight never trips trap/giving_up or interacts a nearby gizmo', function()
    local climb = gizmo('Traversal_Gizmo_FreeClimb_Up', 8, 0)
    local h = harness({actors = {climb}, explorer_target = v(30, 0)})
    local ext, nav = h.ext, h.nav
    local trapped, gave_up, hijacked = false, false, false
    for i = 1, 1500 do          -- 150 s at 10 Hz inside HR's 12 u Maiden lock
        h.adv(0.1)
        local a = i * 0.05
        h.player.pos = v(6 * math.cos(a), 6 * math.sin(a))
        ext.pause('helltide_revamped')
        ext.set_target('helltide_revamped', v(6 * math.cos(a + 0.3), 6 * math.sin(a + 0.3)))
        ext.update('helltide_revamped'); ext.move('helltide_revamped')
        trapped = trapped or ext.is_trapped()
        gave_up = gave_up or ext.is_giving_up()
        hijacked = hijacked or nav.last_trav == climb
    end
    eq(trapped, false, 'no trap while paused'); eq(gave_up, false, 'no giving_up while paused')
    eq(hijacked, false, 'caller target never replaced by a gizmo'); eq(h.counts.interacts, 0, 'no unintended climb')
end)

case('a trap raised before a pause ages out instead of freezing while paused', function()
    local h = harness()
    local ext, nav = h.ext, h.nav
    ext.resume('arkham_asylum'); ext.navigate_long_path('arkham_asylum', v(200, 0))
    for i = 1, 250 do
        h.adv(0.1); h.player.pos = v(5 * math.cos(i * 0.05), 5 * math.sin(i * 0.05))
        ext.update('arkham_asylum'); ext.move('arkham_asylum')
    end
    eq(ext.is_trapped(), true, 'trapped while exploring unpaused')
    ext.stop_long_path('arkham_asylum')
    for _ = 1, 600 do                      -- 60 s paused boss fight
        h.adv(0.1); ext.pause('arkham_asylum'); ext.set_target('arkham_asylum', v(3, 0)); ext.move('arkham_asylum')
    end
    eq(ext.is_trapped(), false, 'stale trap cleared while paused'); eq(ext.is_giving_up(), false)
end)

case('unpaused navigation still detects a real trap', function()
    local h = harness()
    local ext = h.ext
    ext.resume('reaper'); ext.navigate_long_path('reaper', v(200, 0))
    local trapped = false
    for i = 1, 300 do            -- 30 s oscillating inside a 10 u pocket
        h.adv(0.1)
        h.player.pos = v(5 * math.cos(i * 0.05), 5 * math.sin(i * 0.05))
        ext.update('reaper'); ext.move('reaper')
        trapped = trapped or ext.is_trapped()
    end
    eq(trapped, true, 'trap detection is kept for unpaused custom goals (long paths)')
end)

-- BAT-2
case('an inert non-Jump traversal is abandoned after 3 interacts', function()
    local ladder = gizmo('Traversal_Gizmo_FreeClimb_Up', 2, 0)
    local h = harness({actors = {ladder}, explorer_target = v(30, 0)})
    local nav, ext = h.nav, h.ext
    nav.last_trav = ladder; nav.target = v(1, 0); nav.pre_trav_z = 0
    for _ = 1, 100 do h.adv(0.1); nav.move() end          -- 10 s
    ok(h.counts.interacts <= 3, 'bounded interacts within 10 s (got ' .. h.counts.interacts .. ')')
    eq(nav.last_trav, nil, 'last_trav released'); ok(h.counts.selects >= 1, 'explorer picks a new target')
    eq(ext.is_traversal_routing(), false, 'cross_traversal is not pinned')
    ok(h.logged('produced no traversal buff') == 1, 'one diagnostic line')
    for _ = 1, 1100 do h.adv(0.1); nav.move() end         -- up to 120 s total
    ok(h.counts.interacts <= 9, 'retries stay bounded over 120 s (got ' .. h.counts.interacts .. ', was 65)')
end)

case('a paused caller does not interact a stale gizmo after release', function()
    local ladder = gizmo('Traversal_Gizmo_FreeClimb_Up', 2, 0)
    local h = harness({actors = {ladder}})
    h.nav.last_trav = ladder                     -- left by exploration
    h.ext.release('arkham_asylum'); h.ext.pause('arkham_asylum')
    local wiped = 0
    for _ = 1, 100 do
        h.adv(0.1)
        h.ext.set_target('arkham_asylum', v(3, 0), false)
        h.ext.update('arkham_asylum'); h.ext.move('arkham_asylum')
        if h.nav.target == nil then wiped = wiped + 1 end
    end
    eq(h.counts.interacts, 0, 'no stale-gizmo interact'); eq(wiped, 0, 'caller target never wiped')
end)

-- BAT-4
case('paused unstuck keeps the caller waypoint and never writes explorer.visited', function()
    local h = harness({find_path = function(a, b) return {a, v(a:x() + 4, a:y()), b}, false end,
        explorer_target = v(-35, 10)})
    local ext, nav = h.ext, h.nav
    nav.update_trap_state = function() end
    ext.pause('infernal_horde'); ext.set_target('infernal_horde', v(10, 0), false)
    for _ = 1, 40 do h.adv(0.1); ext.update('infernal_horde'); ext.move('infernal_horde') end  -- blocked 4 s
    eq(h.counts.selects, 0, 'no explorer frontier replaces the waypoint')
    ok(nav.target ~= nil and nav.target:x() == 10 and nav.target:y() == 0, 'waypoint kept')
    eq(nav.is_custom_target, true); eq(h.counts.visited_writes, 0, 'no explorer.visited writes')
    ok(h.logged('replanning, target kept') >= 1, 'exhaustion was reached and logged')
end)

-- BAT-5
case('pause()+navigate_long_path keeps the pause; paused arrival ends the route', function()
    local h = harness({explorer_target = v(-30, 0)})
    local ext, nav = h.ext, h.nav
    ext.pause('helltide_revamped')
    eq(ext.navigate_long_path('helltide_revamped', v(20, 0)), true)
    eq(ext.is_paused(), true, 'caller pause survives navigate_long_path')
    for i = 1, 30 do
        h.adv(0.1); ext.pause('helltide_revamped'); h.player.pos = v(math.min(20, i), 0)
        ext.update('helltide_revamped'); ext.move('helltide_revamped')
    end
    eq(ext.is_long_path_navigating(), false, 'paused caller sees completion at the goal')
    eq(h.counts.selects, 0)
end)

case('unpaused self-driven route at the goal does not turn into exploration', function()
    local h = harness({explorer_target = v(-30, 0)})
    local ext = h.ext
    eq(ext.navigate_long_path('reaper', v(20, 0)), true)
    eq(ext.is_paused(), false, 'callers without their own pause keep the autonomous drive')
    for i = 1, 30 do
        h.adv(0.1); h.player.pos = v(math.min(20, i), 0)
        ext.update('reaper'); ext.move('reaper')
    end
    eq(h.counts.selects, 0, 'no explorer frontier while the route owns the goal')
    eq(ext.is_long_path_navigating(), false, 'route ends at the goal')
end)

case('a release pause from another plugin does not stall a Reaper-style route', function()
    local h = harness({main = true})
    local ext = h.ext
    ext.pause('arkham_asylum'); ext.release('arkham_asylum'); h.adv(1)
    eq(ext.navigate_long_path('reaper', v(40, 0)), true)
    eq(ext.is_paused(), false, 'legacy unpause for callers that did not just pause')
    local moves = h.counts.moves
    for _ = 1, 5 do h.adv(0.2); h.update() end
    ok(h.counts.moves > moves, 'main.lua drives the route autonomously')
end)

case('a kept-pause route nobody drives falls back to autonomous drive after 1 s', function()
    local h = harness({main = true})
    local ext = h.ext
    ext.pause('reaper'); eq(ext.navigate_long_path('reaper', v(40, 0)), true)
    eq(ext.is_paused(), true)
    local moves = h.counts.moves
    for _ = 1, 8 do h.adv(0.2); h.update() end
    eq(ext.is_paused(), false, 'undriven kept pause is released'); ok(h.counts.moves > moves, 'route driven')
    eq(h.logged('resuming autonomous drive'), 1)
end)

-- BAT-6
case('clear_traversal_blacklist lifts the 60 s global traversal block', function()
    local partial = true
    local h = harness({actors = {gizmo('Traversal_Gizmo_FreeClimb_Up', 6, 0)},
        find_path = function(a, b, custom)
            if custom and partial then return {a, v(a:x() + 0.5, a:y())}, true end
            return {a, b}, false
        end})
    local ext, nav = h.ext, h.nav
    ext.resume('helltide_revamped'); ext.set_target('helltide_revamped', v(20, 0))
    h.adv(0.1); ext.move('helltide_revamped')
    partial = false; h.adv(0.2); nav.pathfind_replan_cooldown = -1; nav.path = {}
    ext.move('helltide_revamped')
    ok(nav.all_trav_blocked_until > h.now, 'block armed by the partial->full transition')
    ext.clear_traversal_blacklist('helltide_revamped')
    eq(nav.all_trav_blocked_until, 0)
    eq(ext.try_traversal_route('helltide_revamped'), true, 'traversal recovery engages')
end)

-- BAT-7 / HLT-5
case('explorer, trap and route state are reset on a world change or teleport', function()
    local h = harness({real_explorer = true})
    local ext, nav, ex = h.ext, h.nav, h.explorer
    ext.resume('helltide_revamped')
    h.player.pos = v(1000, 1000)
    for x = 1000, 1100, 5 do h.adv(0.1); h.player.pos = v(x, 1000); ext.update('helltide_revamped') end
    ok(ex.frontier_count > 0, 'world A frontiers')
    nav.trav_history = {{t = h.now - 10, direction = -1}, {t = h.now - 5, direction = 1}}
    ext.set_priority('arkham_asylum', 'distance')
    eq(ext.navigate_long_path('arkham_asylum', v(1200, 1000)), true)
    -- WarPigs drops the player into another world; nobody calls reset()
    h.world = {name = 'PIT_Test_Floor', zone = 'Pit_Zone', id = 7}
    h.player.pos = v(0, 0); h.adv(0.1)
    ext.update('helltide_revamped')
    local stale = 0
    for _, node in pairs(ex.frontier_node) do if node:x() > 500 then stale = stale + 1 end end
    eq(stale, 0, 'no frontier from the previous world'); ok(ex.frontier_count > 0, 'new world scanned')
    eq(#nav.trav_history, 0, 'ping-pong history cleared'); eq(ex.priority, 'direction', 'priority default')
    eq(ext.is_long_path_navigating(), false, 'old-world route dropped')
    ok(h.logged('world changed') == 1, 'one diagnostic line')
    -- walking across a zone border keeps the map
    local visited = ex.visited_count
    h.world.zone = 'Pit_Zone_B'; h.adv(0.1); h.player.pos = v(1, 0); ext.update('helltide_revamped')
    ok(ex.visited_count >= visited, 'zone border walk keeps exploration')
    eq(h.logged('zone teleport'), 0, 'walking across a zone border is not a teleport')
    -- waypoint teleport inside the same world (zone change + jump) resets
    h.world.zone = 'Kehj_Other'; h.player.pos = v(3000, 3000); h.adv(0.1); ext.update('helltide_revamped')
    stale = 0
    for _, node in pairs(ex.frontier_node) do if node:x() < 2500 then stale = stale + 1 end end
    eq(stale, 0, 'teleport destination starts with a fresh frontier set')
end)

case('a goal set during the loading screen survives the world-change reset', function()
    local h = harness()
    local ext, nav = h.ext, h.nav
    ext.pause('infernal_horde'); ext.set_target('infernal_horde', v(10, 0))   -- old world
    h.adv(0.1); ext.move('infernal_horde')
    h.world = {name = 'Limbo', zone = '[sno none]', id = 0}; h.adv(1)
    ext.set_target('infernal_horde', v(55, 5))       -- set-once waypoint issued while loading
    h.world = {name = 'BSK_Horde', zone = 'BSK_Zone', id = 9}; h.player.pos = v(50, 0); h.adv(1)
    ext.move('infernal_horde')
    eq(h.logged('world changed'), 1, 'world change detected')
    ok(nav.target ~= nil and nav.target:x() == 55, 'new-world waypoint kept')
    local h2 = harness()
    h2.ext.pause('infernal_horde'); h2.ext.set_target('infernal_horde', v(10, 0)); h2.adv(0.1); h2.ext.move('infernal_horde')
    h2.world = {name = 'BSK_Horde', zone = 'BSK_Zone', id = 9}; h2.player.pos = v(50, 0); h2.adv(1)
    h2.ext.move('infernal_horde')
    eq(h2.nav.target, nil, 'old-world waypoint dropped')
end)

case('clear_giving_up drops traversal ping-pong history', function()
    local h = harness()
    local cleared = 0
    h.explorer.clear_frontiers_in_box = function() cleared = cleared + 1; return 42 end
    h.player.pos = v(500, 500)
    h.nav.trav_history = {{t = h.now - 20, direction = -1}, {t = h.now - 10, direction = 1}}
    h.ext.clear_giving_up('helltide_revamped')
    h.adv(1); h.ext.resume('next_plugin'); h.ext.move('next_plugin')
    eq(h.ext.is_trapped(), false, 'not re-trapped in the next zone'); eq(cleared, 0, 'no frontier wipe')
    eq(#h.nav.trav_history, 0)
end)

-- BAT-8
case('resumed custom waypoint that cannot be reached is reported by set_target', function()
    local h = harness({walkable = function() return false end,
        find_path = function() return {}, true end})
    local ext, nav = h.ext, h.nav
    ext.resume('helltide_revamped')
    ext.set_target('helltide_revamped', v(30, 0))
    for _ = 1, 40 do
        h.adv(0.5); ext.move('helltide_revamped')
        if nav.failed_target ~= nil then break end
    end
    ok(nav.failed_target ~= nil, 'failed_target armed in resumed mode')
    eq(ext.set_target('helltide_revamped', v(31, 0)), false, 'waypoint rejected like in paused mode')
    eq(h.counts.visited_writes, 0, 'explorer.visited untouched')
    for _, failed in ipairs(h.select_failed) do
        ok(not (failed and failed:x() == 30), 'custom waypoint never fed to the explorer as failed')
    end
end)

-- BAT-9 / live L10
case('a stale custom goal or route of a disabled plugin never steers the next caller', function()
    local h = harness()
    local ext, nav = h.ext, h.nav
    -- Arkham, still enabled in Temis, drives a paused custom target
    ext.pause('arkham_asylum'); ext.set_target('arkham_asylum', v(2571.5, -499.5))
    h.player.pos = v(2560, -490); h.adv(0.1); ext.move('arkham_asylum')
    ok(h.counts.find_path > 0, 'arkham pathfinds to its target')
    -- disabled without release; another consumer drives Batmobile
    local before = h.counts.find_path
    for _ = 1, 10 do h.adv(0.1); ext.move('wonder_city') end
    local stale = 0
    for i = before + 1, #h.pf_goals do
        local g = h.pf_goals[i]
        if g:x() == 2571.5 and g:y() == -499.5 then stale = stale + 1 end
    end
    eq(stale, 0, 'no pathfinding to the stale Temis target'); eq(nav.target, nil)
    ok(h.logged('dropping movement left by arkham_asylum') == 1, 'one diagnostic line')
    -- a paused route left by another plugin is not revived by resume()
    ext.pause('arkham_asylum'); eq(ext.navigate_long_path('arkham_asylum', v(2600, -500)), true)
    ext.resume('wonder_city')
    eq(ext.is_long_path_navigating(), false, 'foreign route dropped on resume')
    -- a foreign traversal route cannot swallow the next plugin's target
    ext.pause('arkham_asylum'); ext.set_target('arkham_asylum', v(2600, -480))
    nav.last_trav = gizmo('Traversal_Gizmo_FreeClimb_Up', 2562, -490); nav.trav_final_target = v(2600, -480)
    nav.failed_target = v(2590, -485); nav.failed_target_time = h.now; nav.all_trav_blocked_until = h.now + 60
    local accepted, detail = ext.set_target('helltide_revamped', v(2590, -485))
    eq(accepted, true, 'previous owner failed zone does not reject the new owner'); eq(detail, nil, 'applied, not deferred')
    ok(nav.target ~= nil and nav.target:x() == 2590, 'target applied'); eq(nav.last_trav, nil)
    eq(nav.all_trav_blocked_until, 0, 'previous owner traversal block lifted on takeover')
end)

case('L10 end-to-end: after Arkham releases in Temis nothing keeps steering', function()
    local h = harness({main = true})
    local ext = h.ext
    h.world = {name = 'PIT_Floor_1', zone = 'Pit', id = 3}
    ext.set_priority('arkham_asylum', 'distance'); ext.resume('arkham_asylum')
    for _ = 1, 3 do h.adv(0.2); h.update(); ext.update('arkham_asylum'); ext.move('arkham_asylum') end
    -- pit finished: teleport to Temis, Arkham (still enabled) walks a route there
    h.world = {name = 'Temis_Town', zone = 'Temis', id = 4}; h.player.pos = v(2550, -480); h.adv(1); h.update()
    ext.pause('arkham_asylum'); eq(ext.navigate_long_path('arkham_asylum', v(2571.5, -499.5)), true)
    ext.move('arkham_asylum')
    -- WarPigs disables Arkham (C3 release path); SilentRaven walks natively
    ext.release('arkham_asylum')
    local moves, finds = h.counts.moves, h.counts.find_path
    for _ = 1, 50 do h.adv(0.2); h.update() end
    eq(h.counts.moves, moves, 'Batmobile issues no movement after the release')
    eq(h.counts.find_path, finds, 'no pathfinding toward the stale target')
    eq(ext.is_paused(), true); eq(h.nav.target, nil); eq(ext.is_long_path_navigating(), false)
    eq(h.explorer.priority, 'direction'); eq(ext.get_owner(), nil)
end)

-- BAT-10 (NEEDS_LIVE_CHECK: defensive only)
case('external update/move respect the loading guard; load-time scans do not poison the explorer', function()
    local function run(poison)
        local walk = true
        local h = harness({real_explorer = true, walkable = function() return walk end})
        local ext = h.ext
        ext.resume('helltide_revamped')
        if poison then
            h.world.zone = '[sno none]'
            for _ = 1, 3 do h.adv(0.1); ext.update('helltide_revamped'); ext.move('helltide_revamped') end
            eq(h.counts.moves, 0, 'no movement while loading')
            eq(h.logged('skipped while the world is loading'), 1, 'one log line per loading episode')
            eq(h.explorer.frontier_count, 0, 'no scan while loading')
            h.world.zone = 'Scos_Coast'; walk = false   -- zone set, navmesh still streaming
        end
        h.adv(0.1); ext.update('helltide_revamped')
        walk = true; h.player.pos = v(1, 0); h.adv(0.1); ext.update('helltide_revamped')
        return h.explorer.frontier_count
    end
    local clean, poisoned = run(false), run(true)
    eq(poisoned, clean, 'frontiers recover after the load (clean=' .. clean .. ')')
end)

-- C5: yield time is not "no progress"
case('a caller yield does not count toward the partial-path no-progress window', function()
    local function run(yield)
        local h = harness({find_path = function(a) return {a, v(a:x() + 0.5, a:y())}, true end})
        local ext, nav = h.ext, h.nav
        nav.update_trap_state = function() end
        -- HR chest approach: paused custom goal, partial paths, no progress yet
        ext.pause('helltide_revamped'); ext.set_target('helltide_revamped', v(40, 0))
        h.adv(0.1); ext.move('helltide_revamped')
        if yield then h.adv(20) end               -- Looter owns the player
        h.tick = function()
            -- side-steps (no STUCK) without getting closer to the goal
            h.adv(0.1); h.player.pos = v(0, h.player.pos:y() == 0 and 0.6 or 0)
            ext.pause('helltide_revamped'); ext.set_target('helltide_revamped', v(40, 0))
            ext.move('helltide_revamped')
        end
        local stuck_before = h.logged('[nav] STUCK')
        h.tick()
        local stuck_after_yield = h.logged('[nav] STUCK') - stuck_before
        for _ = 1, 4 do h.tick() end
        return nav.failed_target ~= nil, h, stuck_after_yield
    end
    local failed, _, stuck = run(true)
    eq(stuck, 0, 'no STUCK/unstuck (evade, side-step) right after the yield')
    eq(failed, false, 'goal not abandoned right after the yield')
    local _, h = run(false)
    for _ = 1, 40 do h.tick() end
    ok(h.nav.failed_target ~= nil, 'the no-progress window still works for an active caller')
end)

if #failures > 0 then
    error('Batmobile integration: ' .. #failures .. ' of ' .. cases .. ' cases failed:\n  ' .. table.concat(failures, '\n  '))
end
print(string.format('PASS Batmobile integration suite: %d cases, %d checks', cases, checks))
