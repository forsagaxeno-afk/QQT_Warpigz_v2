-- Batmobile integration regressions (C3 release, BAT-1..11, HLT-5, ARK-8,
-- WCY-8, live L10; round 3: R9 paused-route trap sampling, R10 world map
-- cache for ARK-3, R11 companion-safe ownership).  Loads the real Batmobile navigator / external /
-- long_path (and main.lua or the real explorer where a case needs them)
-- with QQT-shaped host mocks.  Runs under Lua 5.4 and LuaJIT.
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

-- R1: stale explorer.cur_pos (player moved >50u while Batmobile's update was not called)
-- => respawn detector in navigator.update wipes a set-once paused goal (HordeDev walking_to_horde)
case('R1 set-once paused waypoint survives first update after a same-zone jump', function()
    local h = harness({real_explorer = true})
    local ext, nav = h.ext, h.nav
    ext.pause('infernal_horde'); ext.set_target('infernal_horde', v(5, 0))
    h.adv(0.1); ext.update('infernal_horde'); ext.move('infernal_horde')
    -- same world+zone teleport (Library re-teleport) / native walk of 60u with no Batmobile update
    h.player.pos = v(60, 0); h.adv(3)
    ext.pause('infernal_horde'); ext.set_target('infernal_horde', v(80, 0))
    h.adv(0.2); ext.update('infernal_horde'); ext.move('infernal_horde')
    print('R1 target after update = ' .. tostring(nav.target and nav.target:x()))
    print('R1 respawn log = ' .. h.logged('respawn detected'))
    local m0 = h.counts.moves
    for _ = 1, 20 do h.adv(0.1); ext.update('infernal_horde'); ext.move('infernal_horde') end
    print('R1 moves in 2s after = ' .. (h.counts.moves - m0))
    ok(nav.target ~= nil, 'set-once waypoint lost: paused navigator has no goal, player stands still')
end)

-- R2: stop_long_path / clear_target leave get_owner() stale
case('R2 get_owner after stop_long_path/clear_target', function()
    local h = harness()
    local ext = h.ext
    eq(ext.navigate_long_path('reaper', v(40, 0)), true)
    ext.stop_long_path('reaper')
    print('R2 owner after stop_long_path=' .. tostring(ext.get_owner()) .. ' paused=' .. tostring(ext.is_paused()))
    ext.resume('helltide_revamped'); ext.set_target('helltide_revamped', v(10, 0)); ext.clear_target('helltide_revamped')
    print('R2 owner after clear_target=' .. tostring(ext.get_owner()) .. ' paused=' .. tostring(ext.is_paused()))
    ok(ext.get_owner() == nil, 'stale owner after clear_target')
end)

-- R3: loading push (last_update=now+5) + move-gap compensation double count
case('R3 stuck detection after a same-world loading screen', function()
    local h = harness({main = true})
    local ext, nav = h.ext, h.nav
    ext.pause('helltide_revamped'); ext.set_target('helltide_revamped', v(40, 0))
    for _ = 1, 5 do h.adv(0.1); ext.pause('helltide_revamped'); ext.move('helltide_revamped'); h.update() end
    -- same zone loading screen of 8s (no world change), player lands at 200,0 same zone
    h.world.zone = '[sno none]'
    for _ = 1, 80 do h.adv(0.1); h.update() end
    h.world.zone = 'Scos_Coast'; h.player.pos = v(20, 0)
    ext.pause('helltide_revamped'); ext.set_target('helltide_revamped', v(40, 0))
    local first_stuck = nil
    local t0 = h.now
    for i = 1, 400 do
        h.adv(0.1); h.update(); ext.pause('helltide_revamped'); ext.set_target('helltide_revamped', v(40, 0)); ext.move('helltide_revamped')
        if not first_stuck and h.logged('[nav] STUCK') > 0 then first_stuck = h.now - t0 end
    end
    print('R3 first STUCK after load at +' .. tostring(first_stuck) .. 's; last_update-now=' .. tostring(nav.last_update and (nav.last_update - h.now)))
    ok(first_stuck ~= nil and first_stuck < 3, 'stuck detection off too long after load: ' .. tostring(first_stuck))
end)

-- R4: navigate_long_path / resume from a farm plugin lift Rosie's hold pause
case('R4 Rosie hold pause lifted by another caller', function()
    local h = harness({main = true})
    local ext = h.ext
    ext.pause('rosie')
    ext.navigate_long_path('reaper', v(40, 0))
    print('R4 paused after foreign navigate_long_path=' .. tostring(ext.is_paused()))
    ext.pause('rosie'); ext.resume('helltide_revamped')
    print('R4 paused after foreign resume=' .. tostring(ext.is_paused()))
end)

-- R5: paused caller pressed against a large target (boss collision > 1u) keeps calling move()
case('R5 paused melee hold at a boss: STUCK/evade spam', function()
    local h = harness()
    local ext, nav = h.ext, h.nav
    h.env.utility.can_cast_spell = function() return true end
    local st = h.env.require('core.settings'); st.use_evade = true
    h.player.pos = v(0, 0)
    for _ = 1, 100 do  -- 10 s
        h.adv(0.1); ext.pause('arkham_asylum'); ext.update('arkham_asylum')
        ext.set_target('arkham_asylum', v(2.5, 0)); ext.move('arkham_asylum')
    end
    print(string.format('R5 10s at boss: STUCK lines=%d casts=%d EXHAUSTED=%d', h.logged('[nav] STUCK'), h.counts.casts, h.logged('EXHAUSTED')))
end)

-- R6: non-jump traversal interacted, player displaced to 3<d<=5 of the gizmo: nothing drives
case('R6 3-5u limbo after a non-jump interact', function()
    local trav = gizmo('Traversal_Gizmo_FreeClimb_Up', 10, 0)
    local h = harness({actors = {trav}})
    local ext, nav = h.ext, h.nav
    h.player.pos = v(0, 0)
    ext.pause('arkham_asylum'); ext.set_target('arkham_asylum', v(40, 0))
    ok(ext.try_traversal_route('arkham_asylum'), 'routed')
    h.player.pos = v(8, 0)  -- walked to approach node, within 3u of gizmo
    h.adv(0.1); ext.move('arkham_asylum')
    print('R6 interacts=' .. h.counts.interacts .. ' target=' .. tostring(nav.target) .. ' last_trav=' .. tostring(nav.last_trav ~= nil))
    h.player.pos = v(6, 0)   -- combat knockback / orbwalker: 4u from gizmo
    local m0, i0 = h.counts.moves, h.counts.interacts
    for _ = 1, 600 do  -- 60 s
        h.adv(0.1); ext.pause('arkham_asylum'); ext.update('arkham_asylum')
        local acc, det = ext.set_target('arkham_asylum', v(40, 1)); ext.move('arkham_asylum')
    end
    print(string.format('R6 60s later: moves=%d interacts=%d target=%s routing=%s', h.counts.moves - m0,
        h.counts.interacts - i0, tostring(nav.target and nav.target:x()), tostring(ext.is_traversal_routing())))
    ok(h.counts.moves - m0 > 0, 'player frozen 60 s in the 3-5u band while routing')
end)

if #failures > 0 then
    error('BM repro: ' .. #failures .. ' of ' .. cases .. ' cases failed:\n  ' .. table.concat(failures, '\n  '))
end
print(string.format('PASS BM repro: %d cases, %d checks', cases, checks))
