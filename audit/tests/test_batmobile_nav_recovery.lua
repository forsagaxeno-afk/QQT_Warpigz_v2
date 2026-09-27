-- QQT_Warpigz_v3: Batmobile navigation-recovery regressions (night audit,
-- area batmobile).  Loads the real navigator / external / long_path /
-- movement_engine with the QQT-shaped host mocks of
-- test_integration_batmobile.lua.  Every case failed on the pre-fix tree.
--   N1 ping-pong window + escape crossing + giving_up only on a bbox trap,
--      clear_traversal_blacklist lifts the trap blacklist
--   N2 giving_up is not terminal (escape keeps retrying)
--   N3 an injected long partial route is not hijacked while it progresses;
--      try_traversal_route direction/floor filters and approach blacklist
--   N4 post-traversal escape is bounded (clear_target, failed pathfinds,
--      no walkable escape point)
--   N5 unstuck honours the Evade checkbox
--   N6 movement revamp skips a rule whose skill is not castable
--   N7 hot-path navigator lines honour the logging combo
-- Runs under Lua 5.4 and LuaJIT.
local root = assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/Batmobile/'
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
        print('PASS Batmobile recovery: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Batmobile recovery: ' .. name .. ': ' .. tostring(err))
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

local function pocket(i, radius, step) return v(radius * math.cos(i * step), radius * math.sin(i * step)) end
local function walker(h, speed, keep_z)
    h.env.pathfinder.request_move = function(node)
        h.counts.moves = h.counts.moves + 1
        local p = h.player.pos
        local dx, dy = node:x() - p:x(), node:y() - p:y()
        local d = math.sqrt(dx * dx + dy * dy); local s = math.min(speed or 0.6, d)
        if d > 0 then
            local np = v(p:x() + dx / d * s, p:y() + dy / d * s, keep_z and p:z() or node:z())
            if h.walkable(np) then h.player.pos = np end
        end
    end
end
local function climb_buff() return {{name = function() return 'Player_Traversal_Climb' end}} end
-- navigator blacklist key: skin name .. utils.vec_to_string(pos) ('x,y')
local function key_of(g) local p = g:get_position(); return g:get_skin_name() .. tostring(p:x()) .. ',' .. tostring(p:y()) end

-- ── N1 ──────────────────────────────────────────────────────────────────
case('N1 an Up minutes ago plus a Down now is not a ping-pong trap', function()
    local h = harness()
    local nav = h.nav
    nav.trav_history = {{t = h.now - 600, direction = 1}, {t = h.now, direction = -1}}
    nav.update_trap_state(h.player)
    eq(nav.trapped, false, 'Up 600 s ago + Down now (was trapped=true)')
    nav.trav_history = {{t = h.now - 300, direction = 1}, {t = h.now - 1, direction = -1}}
    nav.update_trap_state(h.player)
    eq(nav.trapped, false, '5-minute gap')
    nav.trav_history = {{t = h.now - 20, direction = 1}, {t = h.now, direction = -1}}
    nav.update_trap_state(h.player)
    eq(nav.trapped, true, 'a genuine Up/Down inside 60 s still reads as ping-pong')
end)

case('N1 the escape crossing is no reversal and a ping-pong never escalates to giving_up', function()
    local UP = gizmo('Traversal_Gizmo_FreeClimb_Up', 10, 0, 0)
    local h = harness({actors = {UP}, explorer_target = v(200, 0, 5)})
    local nav = h.nav
    h.player.pos = v(8, 0, 0)
    nav.trav_history = {{t = h.now - 20, direction = 1}, {t = h.now - 1, direction = -1}}
    nav.update_trap_state(h.player)
    eq(nav.trapped, true, 'ping-pong trap raised')
    nav.attempt_escape(h.player)
    eq(nav.last_trav, UP, 'escape routes back up')
    -- the climb: buff tick at the gizmo
    h.player.pos = v(10, 0, 0); h.player.buffs = climb_buff()
    h.adv(0.1); nav.move()
    h.player.buffs = {}
    local last = nav.trav_history[#nav.trav_history]
    eq(last.direction, 1)
    -- the bot walks away on the upper floor for 120 s (2 u/s, no bbox trap)
    local gave_up, trapped_at = false, nil
    for i = 1, 1200 do
        h.adv(0.1)
        h.player.pos = v(12 + i * 0.2, 0, 5)
        nav.move()
        gave_up = gave_up or nav.giving_up
        if nav.trapped then trapped_at = i / 10 end
    end
    eq(gave_up, false, 'giving_up never set by a ping-pong (was true at ~60 s -> HR left the zone)')
    ok(trapped_at == nil or trapped_at <= 20, 'trap released within the post-escape grace (last trapped at '
        .. tostring(trapped_at) .. ' s)')
    eq(nav.trapped, false)
    eq(last.escape, true, 'escape crossing tagged')
end)

case('N1 clear_traversal_blacklist also lifts the long-term trap blacklist', function()
    local h = harness()
    local nav, ext = h.nav, h.ext
    nav.trap_blacklisted_trav['Traversal_Gizmo_FreeClimb_Down1,2,0'] = h.now + 300
    ext.clear_traversal_blacklist('helltide_revamped')
    eq(next(nav.trap_blacklisted_trav), nil, 'trap blacklist wiped by HR/Arkham recoveries')
end)

-- ── N2 ──────────────────────────────────────────────────────────────────
case('N2 giving_up keeps escaping: the exit is taken once its blacklist expires', function()
    local EXIT = gizmo('Traversal_Gizmo_FreeClimb_Up', 3, 0, 0)
    local h = harness({actors = {EXIT}})
    local nav = h.nav
    local t0 = h.now
    nav.trap_blacklisted_trav[key_of(EXIT)] = t0 + 100      -- briefly unusable exit
    local gave_up_at, routed_at = nil, nil
    for i = 1, 1600 do                                        -- 160 s in a 8 u pocket
        h.adv(0.1)
        if routed_at == nil then h.player.pos = pocket(i, 4, 0.05) end
        nav.move()
        if gave_up_at == nil and nav.giving_up then gave_up_at = h.now - t0 end
        if routed_at == nil and nav.last_trav == EXIT then routed_at = h.now - t0 end
    end
    ok(gave_up_at ~= nil, 'a confined pocket still gives up (HR contract)')
    ok(routed_at ~= nil, 'escape routed to the exit after giving up (was never: terminal giving_up)')
    ok(routed_at >= 100 and routed_at <= 125, 'exit taken within one slow retry of becoming usable (at '
        .. tostring(routed_at) .. ' s)')
end)

-- ── N3 ──────────────────────────────────────────────────────────────────
local function long_partial(opts)
    local side = gizmo('Traversal_Gizmo_FreeClimb_Up', 20, 20, 0)
    local capped = 0
    local h = harness({actors = {side},
        find_path = function(a, b, custom, shared, cap)
            if cap == 0.040 then
                capped = capped + 1
                if opts.cliff then return {a, v(a:x() + 0.5, a:y())}, true end
            end
            return {a, b}, false
        end,
        find_path_debug = function()
            local p = {}
            for i = 0, 60 do p[#p + 1] = v(i, 0, 0) end        -- 60 u of a 90 u chest recall
            return p, 10000, 0.3, 'time_limit_partial'
        end})
    walker(h, 0.6)
    return h, side, function() return capped end
end

case('N3 a progressing injected long partial route is not hijacked by a side ladder', function()
    local h, side, capped = long_partial({})
    local ext, nav = h.ext, h.nav
    ext.pause('helltide_revamped')
    ok(ext.navigate_long_path('helltide_revamped', v(90, 0, 0)), 'route started')
    local rerouted_at = nil
    for i = 1, 80 do
        h.adv(0.1); ext.pause('helltide_revamped'); ext.update('helltide_revamped'); ext.move('helltide_revamped')
        if rerouted_at == nil and nav.last_trav == side then rerouted_at = i / 10 end
    end
    eq(rerouted_at, nil, 'no traversal reroute while progressing (was 1.6 s)')
    eq(h.logged('routing via traversal'), 0)
    ok(h.player.pos:x() > 40, 'the route kept going (x=' .. string.format('%.1f', h.player.pos:x()) .. ')')
    eq(capped(), 0, 'no feasibility A* bursts while progressing')
end)

case('N3 control: the stall escape still fires once the route stops progressing', function()
    local h, side = long_partial({})
    local ext, nav = h.ext, h.nav
    h.env.pathfinder.request_move = function() end              -- blocked: no movement at all
    ext.pause('helltide_revamped')
    ok(ext.navigate_long_path('helltide_revamped', v(90, 0, 0)), 'route started')
    local rerouted_at = nil
    for i = 1, 60 do
        h.adv(0.1); ext.pause('helltide_revamped'); ext.update('helltide_revamped'); ext.move('helltide_revamped')
        if rerouted_at == nil and nav.last_trav == side then rerouted_at = i / 10 end
    end
    ok(rerouted_at ~= nil and rerouted_at <= 3, 'stalled route engages the traversal (at ' .. tostring(rerouted_at) .. ' s)')
end)

case('N3 try_traversal_route: floor and direction filters, failed approach is blacklisted', function()
    local BEHIND = gizmo('Traversal_Gizmo_FreeClimb_Up', -10, 0, 0)
    local OTHER_Z = gizmo('Traversal_Gizmo_FreeClimb_Up', 10, 2, 8)
    local h = harness({actors = {BEHIND, OTHER_Z}})
    local ext, nav = h.ext, h.nav
    ext.pause('arkham_asylum'); ext.set_target('arkham_asylum', v(40, 0, 0))
    eq(ext.try_traversal_route('arkham_asylum'), false, 'gizmo behind the player / on another floor is not taken')
    eq(nav.last_trav, nil)
    -- a gizmo ahead whose approach is unreachable: one feasibility burst, then blacklisted
    local AHEAD = gizmo('Traversal_Gizmo_FreeClimb_Up', 10, 0, 0)
    local capped = 0
    local h2 = harness({actors = {AHEAD}, find_path = function(a, b, custom, shared, cap)
        if cap == 0.040 then capped = capped + 1; return {a, v(a:x() + 0.5, a:y())}, true end
        return {a, b}, false
    end})
    h2.ext.pause('arkham_asylum'); h2.ext.set_target('arkham_asylum', v(40, 0, 0))
    eq(h2.ext.try_traversal_route('arkham_asylum'), false)
    local first = capped
    ok(first > 0, 'feasibility checked once')
    h2.adv(2.1)
    eq(h2.ext.try_traversal_route('arkham_asylum'), false)
    eq(capped, first, 'no repeated feasibility burst 2 s later (blacklisted)')
end)

-- ── N4 ──────────────────────────────────────────────────────────────────
local function crossed(h, UP, G)
    local ext, nav = h.ext, h.nav
    nav.update_trap_state = function() end
    ext.pause('arkham_asylum'); ext.set_target('arkham_asylum', G)
    nav.last_trav = UP; nav.pre_trav_z = 0
    h.player.pos = v(0.5, 0, 0); h.player.buffs = climb_buff()
    h.adv(0.1); ext.pause('arkham_asylum'); ext.move('arkham_asylum')
    h.player.buffs = {}
end

case('N4 a paused caller that clears its target right after a crossing is not frozen', function()
    local UP = gizmo('Traversal_Gizmo_FreeClimb_Up', 0, 0, 0)
    local h = harness({actors = {UP}})
    local ext, nav = h.ext, h.nav
    walker(h, 0.6, true)
    local G = v(0, -30, 5)
    crossed(h, UP, G)
    ok(nav.trav_escape_pos ~= nil, 'escape phase started')
    h.player.pos = v(1.5, 0, 5)
    h.adv(0.1); ext.pause('arkham_asylum'); ext.clear_target('arkham_asylum')
    local deferred = 0
    for _ = 1, 100 do
        h.adv(0.1); ext.pause('arkham_asylum')
        local _, d = ext.set_target('arkham_asylum', G)
        if d == 'deferred' then deferred = deferred + 1 end
        ext.update('arkham_asylum'); ext.move('arkham_asylum')
    end
    eq(deferred, 0, 'set_target applied after clear_target (was 600/600 deferred)')
    eq(nav.trav_escape_pos, nil)
    ok(h.player.pos:y() < -20, 'player walks to the goal (y=' .. string.format('%.1f', h.player.pos:y()) .. ')')
end)

case('N4 an escape whose pathfinds fail is dropped and the goal restored', function()
    local UP = gizmo('Traversal_Gizmo_FreeClimb_Up', 0, 0, 0)
    local G = v(0, -30, 5)
    local h = harness({actors = {UP}, find_path = function(a, b)
        if math.abs(b:y() - G:y()) < 0.1 then return {a, b}, false end
        return {}, false                                          -- the escape point is unreachable
    end})
    local ext, nav = h.ext, h.nav
    h.env.pathfinder.request_move = function() h.counts.moves = h.counts.moves + 1 end  -- wedged
    crossed(h, UP, G)
    ok(nav.trav_escape_pos ~= nil, 'escape phase started')
    local deferred, released_at = 0, nil
    for i = 1, 100 do
        h.adv(0.1); ext.pause('arkham_asylum')
        local _, d = ext.set_target('arkham_asylum', G)
        if d == 'deferred' then deferred = deferred + 1 end
        ext.move('arkham_asylum')
        if released_at == nil and nav.trav_escape_pos == nil then released_at = i / 10 end
    end
    ok(released_at ~= nil and released_at <= 3.5, 'escape bounded (released at ' .. tostring(released_at) .. ' s, was never)')
    ok(nav.target ~= nil and nav.target:y() == G:y(), 'goal restored')
    ok(deferred < 40, 'set_target no longer deferred for the whole run (' .. deferred .. '/100)')
end)

case('N4 no walkable escape point: the escape is skipped and the goal restored at once', function()
    local UP = gizmo('Traversal_Gizmo_FreeClimb_Up', 0, 0, 0)
    local h = harness({actors = {UP}})
    local nav = h.nav
    h.walkable = function(p) return math.abs(p:x()) <= 1 end      -- 2 u wide walkway along y
    local G = v(0, -30, 5)
    crossed(h, UP, G)
    eq(nav.trav_escape_pos, nil, 'no escape toward an unwalkable point (was the 3 u fallback)')
    ok(nav.target ~= nil and nav.target:y() == G:y(), 'goal kept for the paused caller')
end)

-- ── N5 ──────────────────────────────────────────────────────────────────
local function stuck_evades(use_evade)
    local h = harness()
    local ext, nav = h.ext, h.nav
    local evades = 0
    h.env.utility.can_cast_spell = function(id) return id == 337031 end
    h.env.cast_spell.position = function(id) if id == 337031 then evades = evades + 1 end return true end
    local settings = h.env.require('core.settings')
    settings.use_movement = false; settings.use_evade = use_evade
    nav.update_trap_state = function() end
    for _ = 1, 40 do                                               -- wedged for 4 s
        h.adv(0.1); ext.pause('helltide_revamped'); ext.set_target('helltide_revamped', v(40, 0))
        ext.move('helltide_revamped')
    end
    return evades, h.logged('[nav] STUCK')
end

case('N5 unstuck honours the "use evade for movement" checkbox', function()
    local evades, stuck = stuck_evades(false)
    ok(stuck > 0, 'STUCK reached')
    eq(evades, 0, 'no Evade with the checkbox off')
    local evades_on = stuck_evades(true)
    ok(evades_on > 0, 'default (checkbox on) still evades')
end)

-- ── N6 ──────────────────────────────────────────────────────────────────
case('N6 movement revamp skips a rule whose skill is not castable', function()
    local env = setmetatable({vec3 = Vec, get_time_since_inject = function() return 100 end,
        console = {print = function() end},
        utility = {can_cast_spell = function(id) return id == 337031 end}}, {__index = _G})
    local mods = {['core.settings'] = {normalizer = 2, log_level = 0}}
    env.require = function(name)
        if mods[name] ~= nil then return mods[name] end
        mods[name] = assert(loadfile(root .. name:gsub('%.', '/') .. '.lua', 't', env))()
        return mods[name]
    end
    local engine = env.require('core.movement_engine')
    local rules = {
        {enabled = true, skill_id = 288106, cast_position = 'next_node', throttle_ms = 0, conditions = {}},
        {enabled = true, skill_id = 337031, cast_position = 'next_node', throttle_ms = 0, conditions = {}},
    }
    local ctx = {local_player = {get_buffs = function() return {} end}, path = {v(1, 0), v(4, 0), v(8, 0), v(12, 0)},
        player_pos = v(0, 0), default_range = 12, min_spell_dist = 3, blacklist = {}}
    eq(engine.pick(rules, ctx), 337031, 'Teleport on cooldown -> Evade (was 288106)')
end)

-- ── N7 ──────────────────────────────────────────────────────────────────
case('N7 hot-path navigator lines honour the logging combo', function()
    local function parked(level)
        local h = harness()
        h.env.require('core.settings').log_level = level
        h.nav.update_trap_state = function() end
        h.ext.pause('helltide_revamped')
        for _ = 1, 100 do                                          -- 10 s at 10 Hz, parked on the goal
            h.adv(0.1); h.ext.pause('helltide_revamped'); h.ext.set_target('helltide_revamped', v(0, 0))
            h.ext.update('helltide_revamped'); h.ext.move('helltide_revamped')
        end
        return h.logged('no target or reached')
    end
    eq(parked(0), 0, 'Disabled prints nothing (was 100 lines)')
    local info = parked(1)
    ok(info >= 1 and info <= 3, 'Info prints one line per state/5 s (got ' .. info .. ')')
    eq(parked(2), 100, 'Debug keeps every line')
    -- unpaused caller with an exhausted explorer, 20 Hz
    local h = harness()
    h.env.require('core.settings').log_level = 1
    h.explorer.select_node = function() return nil end
    h.explorer.frontier_count = 0
    h.nav.update_trap_state = function() end
    h.ext.resume('arkham_asylum')
    local n0 = #h.logs
    for _ = 1, 200 do h.adv(0.05); h.ext.update('arkham_asylum'); h.ext.move('arkham_asylum') end
    ok(#h.logs - n0 <= 40, 'exhausted explorer at Info: ' .. (#h.logs - n0) .. ' lines in 10 s (was 611)')
end)

if #failures > 0 then
    error('Batmobile recovery: ' .. #failures .. ' of ' .. cases .. ' cases failed:\n  ' .. table.concat(failures, '\n  '))
end
print(string.format('PASS Batmobile recovery suite: %d cases, %d checks', cases, checks))
