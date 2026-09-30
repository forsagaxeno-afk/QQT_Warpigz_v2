-- QQT_Warpigz_v3 Batmobile 2.2.2: movement oscillation / stuck-loop regressions
-- (self-review "the bot goes back and forth").  Loads the real navigator,
-- external, long_path (and main.lua where noted) with QQT-shaped host mocks.
-- Every case failed on the 2.2.1 tree.
--   B1 a path node skipped for being closer than movement_step is not walked
--      back to (node behind the player after a detour; hairpin)
--   B2 the unstuck side-step node is walked to until reached (it jittered
--      on the 4 u ring forever and never read as STUCK)
--   B3 STUCK next to a traversal gizmo is suppressed at most 5 s; a gizmo
--      that cannot be reached for interact is dropped (was waited on forever)
-- Auditor findings on 2.2.1 (audit/reviews/repro_batmobile_full.lua R1-R6):
--   B4 displaced 3-5 u after a non-Jump interact: walk back, bounded (R6)
--   B5 a goal set after a jump survives the respawn detector (R1)
--   B6 get_owner() is nil once the goal is gone (R2)
--   B7 STUCK detection returns ~6 s after a loading screen, not load + 6 s (R3)
--   B8 a paused caller pressed against a big target: no STUCK/Evade spam (R5)
--   B9 freeroam also yields to a busy Scavenger (Navigator's looter)
-- Scenario sweep 2026-09-28 (audit/reviews/sweep_2026-09-28.md §2.5):
--   B10 STUCK / PARTIAL PATH REJECTED / SKIPPED (2.2.4) and the [unstuck]
--       replan / EXHAUSTED lines (2.2.5) honour the logging combo
-- Runs under Lua 5.4 and LuaJIT.
local root = assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/Batmobile/'
local checks, cases, failures = 0, 0, {}
local function ok(cond, message)
    checks = checks + 1
    if not cond then error(message or 'assertion failed', 2) end
end
local function case(name, fn)
    cases = cases + 1
    local passed, err = pcall(fn)
    if passed then
        print('PASS Batmobile oscillation: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Batmobile oscillation: ' .. name .. ': ' .. tostring(err))
    end
end

local Vec = {}; Vec.__index = Vec
function Vec:new(x, y, z) return setmetatable({_x = x, _y = y, _z = z or 0}, self) end
function Vec:x() return self._x end
function Vec:y() return self._y end
function Vec:z() return self._z end
local function v(x, y, z) return Vec:new(x, y, z) end
local function dist(a, b) local dx, dy = a:x() - b:x(), a:y() - b:y(); return math.sqrt(dx * dx + dy * dy) end

-- opts: walkable(x, y), blocked(x, y), find_path(a, b, custom), speed, seed, actors,
--       real_explorer, explorer_target, main (load main.lua), freeroam
local function harness(opts)
    opts = opts or {}
    local h = {now = 100, logs = {}, moves = {}, rng = opts.seed or 1}
    h.walkable = opts.walkable or function() return true end
    local player = {pos = opts.start or v(0, 0), buffs = {}}
    function player:get_position() return self.pos end
    function player:get_buffs() return self.buffs end
    function player:get_attribute() return 0 end
    function player:get_character_class_id() return 0 end
    function player:is_dead() return false end
    function player:get_active_spell_id() return -1 end
    h.player = player
    local world = {}
    function world:get_name() return 'Sanctuary_Eastern_Continent' end
    h.zone = 'Scos_Coast'
    function world:get_current_zone_name() return h.zone end
    function world:get_world_id() return 1 end
    local settings = {step = 0.5, normalizer = 2, path_smooth_step = 0, log_level = 1, plugin_label = 't',
        use_movement = false, use_evade = false, spell_interval = 0.15, min_spell_dist = 3,
        explore_path_budget_ms = 80, prefer_long_paths = false, update_settings = function() end}
    local tracker = {bench_enabled = false, bench_start = function() end, bench_stop = function() end,
        bench_count = function() end, bench_report = function() end, bench_set_meta = function() end,
        evaluated = {}, timer_update = 0, timer_move = 0}
    -- The game slides along walls; a fully blocked step keeps the player in place.
    -- opts.blocked(x, y): a blocker the walkability grid does not know (a
    -- dynamic obstacle); only the player's movement honours it.
    local function free(x, y) return h.walkable(x, y) and not (opts.blocked and opts.blocked(x, y)) end
    local function request_move(node)
        h.moves[#h.moves + 1] = {from = player.pos, to = node}
        local p = player.pos
        local dx, dy = node:x() - p:x(), node:y() - p:y()
        local d = math.sqrt(dx * dx + dy * dy); local s = math.min(opts.speed or 0.35, d)
        if d > 0 then
            local np = v(p:x() + dx / d * s, p:y() + dy / d * s, p:z())
            if free(np:x(), np:y()) then player.pos = np; return end
            -- slide along the blocking wall on the dominant axis, then the other
            local ax = v(p:x() + (dx > 0 and 1 or -1) * math.min(s, math.abs(dx)), p:y(), p:z())
            local ay = v(p:x(), p:y() + (dy > 0 and 1 or -1) * math.min(s, math.abs(dy)), p:z())
            local first, second = ax, ay
            if math.abs(dy) > math.abs(dx) then first, second = ay, ax end
            if free(first:x(), first:y()) then player.pos = first
            elseif free(second:x(), second:y()) then player.pos = second end
        end
    end
    local env = setmetatable({vec3 = Vec, vec2 = Vec,
        get_time_since_inject = function() return h.now end,
        get_local_player = function() return player end,
        get_player_position = function() return player.pos end,
        get_current_world = function() return world end,
        attributes = {PLAYER_IN_TOWN_LEVEL_AREA = 1},
        console = {print = function(s) h.logs[#h.logs + 1] = tostring(s) end},
        utility = {set_height_of_valid_position = function(p) return p end,
            is_point_walkeable = function(p) return h.walkable(p:x(), p:y()) end,
            can_cast_spell = function() return false end, is_ray_cast_walkeable = function() return true end},
        actors_manager = {get_all_actors = function() return opts.actors or {} end},
        cast_spell = {position = function() return true end},
        pathfinder = {request_move = request_move, clear_stored_path = function() end,
            force_move_raw = function() end},
        interact_object = function() end,
        get_hash = function() return 1 end}, {__index = _G})
    -- Deterministic shuffle order for unstuck's side-step directions.
    env.math = setmetatable({random = function(a, b)
        h.rng = (h.rng * 1103515245 + 12345) % 2147483648
        local r = h.rng / 2147483648
        if a == nil then return r end
        if b == nil then return math.floor(r * a) + 1 end
        return a + math.floor(r * (b - a + 1))
    end}, {__index = math})
    env._G = env
    local modules = {['core.settings'] = settings, ['core.tracker'] = tracker,
        ['core.movement_engine'] = {pick = function() return nil end}}
    local find_path = opts.find_path or function(a, b) return {a, b}, false end
    modules['core.pathfinder'] = {find_path = function(a, b, custom) return find_path(a, b, custom) end,
        find_path_debug = opts.find_path_debug or function(a, b) return {a, b}, 2, 0.001, 'found' end,
        clear_wall_penalty_cache = function() end, last_pathfind = {}}
    if not opts.real_explorer then
        modules['core.explorer'] = {backtracking = false, frontier_count = 5, backtrack = {}, visited = {},
            priority = 'direction', default_priority = 'direction', update = function() end,
            select_node = function() return opts.explorer_target end, set_priority = function() end,
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
        h.freeroam = widget(opts.freeroam == true)
        modules.gui = {elements = {reset_keybind = widget(false), long_path_set_target = widget(false),
            long_path_set_target_cursor = widget(false), long_path_test = widget(false),
            freeroam_keybind_toggle = h.freeroam, draw_keybind_toggle = widget(false),
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
    h.env = env
    -- One caller tick: 20 Hz update + move.
    function h.tick(caller)
        h.now = h.now + 0.05
        h.ext.update(caller); h.ext.move(caller)
    end
    -- Move requests whose direction turned by more than ~135 degrees.
    function h.reversals(from)
        local n, prev = 0, nil
        for i = from or 1, #h.moves do
            local m = h.moves[i]
            local dx, dy = m.to:x() - m.from:x(), m.to:y() - m.from:y()
            local len = math.sqrt(dx * dx + dy * dy)
            if len > 0.01 then
                dx, dy = dx / len, dy / len
                if prev ~= nil and dx * prev[1] + dy * prev[2] < -0.7 then n = n + 1 end
                prev = {dx, dy}
            end
        end
        return n
    end
    function h.logged(pattern)
        local n = 0
        for _, line in ipairs(h.logs) do if line:find(pattern, 1, true) then n = n + 1 end end
        return n
    end
    return h
end

-- ── B1 ──────────────────────────────────────────────────────────────────
case('B1 a close path node behind the player is not walked back to', function()
    -- A detour (Looter pickup, a fight) left the player 3 u past the first
    -- node of its route: the node is behind and closer than movement_step.
    local goal = v(12, 0)
    -- The route was planned before the detour; a replan starts at the player.
    local stale = true
    local h = harness({find_path = function(a, b)
        if stale then stale = false; return {v(-3, 0), goal}, false end
        return {a, b}, false
    end})
    h.ext.resume('reaper')
    ok(h.ext.set_target('reaper', goal) ~= false, 'goal accepted')
    for _ = 1, 100 do h.tick('reaper') end                    -- 5 s at 7 u/s
    ok(dist(h.player.pos, goal) <= 1.5, string.format('player reached the goal (at %.1f,%.1f; was stuck '
        .. 'jittering around x=1)', h.player.pos:x(), h.player.pos:y()))
    ok(h.reversals() <= 1, 'direction reversals: ' .. h.reversals() .. ' (was one every tick)')
end)

case('B1 a hairpin corner node closer than movement_step is not re-approached', function()
    -- Route bends back around a wall end: n1 is 3.5 u away, n2 lies behind
    -- the player on the other side of the thin wall y=1.
    local wall = function(x, y) return not (y > 0.8 and y < 1.2 and x < 2.5) end
    local goal = v(-8, 2)
    local h = harness({walkable = wall, find_path = function(a)
        if a:y() > 1 then return {a, goal}, false end
        return {a, v(3.5, 0), v(3.5, 2), goal}, false
    end})
    h.ext.pause('arkham_asylum')
    ok(h.ext.set_target('arkham_asylum', goal) ~= false, 'goal accepted')
    for _ = 1, 160 do h.tick('arkham_asylum') end              -- 8 s
    ok(dist(h.player.pos, goal) <= 1.5, string.format('player reached the goal around the wall (at %.1f,%.1f)',
        h.player.pos:x(), h.player.pos:y()))
    ok(h.reversals() <= 3, 'direction reversals: ' .. h.reversals())
end)

-- ── B2 ──────────────────────────────────────────────────────────────────
case('B2 the unstuck side-step is reached, then the goal around the pillar', function()
    -- A pillar the straight route runs into: STUCK -> unstuck injects a
    -- side-step node 4 u away.  2.2.1 left it after one step (closer than
    -- movement_step) and walked back to it from the goal leg forever.
    local pillar = function(x, y) return not (x > 0.6 and x < 2.5 and math.abs(y) < 1.5) end
    local goal = v(12, 0)
    for seed = 1, 12 do
        local h = harness({walkable = pillar, seed = seed,
            find_path = function(a, b) return {a, b}, false end})
        h.ext.resume('helltide_revamped')
        ok(h.ext.set_target('helltide_revamped', goal) ~= false, 'goal accepted')
        local reached_at = nil
        for i = 1, 600 do                                      -- 30 s
            h.tick('helltide_revamped')
            if dist(h.player.pos, goal) <= 1.5 then reached_at = i / 20; break end
        end
        ok(h.logged('unstuck by injecting path') >= 1, 'seed ' .. seed .. ': the side-step was injected')
        ok(reached_at ~= nil, string.format('seed %d: goal reached around the pillar (stuck at %.1f,%.1f '
            .. 'after %d side-steps)', seed, h.player.pos:x(), h.player.pos:y(),
            h.logged('unstuck by injecting path')))
    end
end)

case('B2 control: no side-step is pending once the path is replaced', function()
    local pillar = function(x, y) return not (x > 0.6 and x < 2.5 and math.abs(y) < 1.5) end
    local h = harness({walkable = pillar, find_path = function(a, b) return {a, b}, false end})
    h.ext.resume('helltide_revamped')
    h.ext.set_target('helltide_revamped', v(12, 0))
    for _ = 1, 40 do
        h.tick('helltide_revamped')
        if h.nav.side_step_node ~= nil then break end
    end
    ok(h.nav.side_step_node ~= nil, 'side-step pending after STUCK')
    h.ext.release('helltide_revamped')
    h.ext.resume('reaper')
    h.ext.set_target('reaper', v(-10, 0))
    h.tick('reaper')
    ok(h.nav.side_step_node == nil, 'a new goal drops the old side-step')
end)

-- ── B3 ──────────────────────────────────────────────────────────────────
case('B3 a gizmo the player cannot get within interact range of is dropped, not waited on forever', function()
    local climb = {get_position = function() return v(10, 0, 0) end,
        get_skin_name = function() return 'Traversal_Gizmo_FreeClimb_Up' end}
    local goal = v(20, 0)
    -- Something the walk grid does not know holds the player 4 u short.
    local h = harness({actors = {climb}, start = v(3, 0), blocked = function(x) return x > 6.3 end})
    local interacts = 0
    h.env.interact_object = function() interacts = interacts + 1 end
    h.ext.pause('arkham_asylum')
    ok(h.ext.set_target('arkham_asylum', goal) ~= false, 'goal accepted')
    ok(h.ext.try_traversal_route('arkham_asylum') == true, 'routed via the climb')
    local dropped_at = nil
    for i = 1, 20 * 60 do
        h.tick('arkham_asylum')
        if not h.ext.is_traversal_routing() then dropped_at = i / 20; break end
    end
    ok(dropped_at ~= nil and dropped_at <= 10, 'traversal routing dropped within 10 s (still routing after '
        .. tostring(dropped_at or 60) .. ' s; STUCK suppressed ' .. h.logged('STUCK suppressed') .. 'x)')
    ok(interacts == 0, 'never in interact range')
    ok(h.logged('not reachable for interact') == 1, 'the drop is logged once')
    local t = h.ext.get_target()
    ok(t ~= nil and dist(t, goal) < 1, 'the caller goal is given back')
    ok(h.nav.trap_blacklisted_trav['Traversal_Gizmo_FreeClimb_Up10,0'] ~= nil, 'the gizmo is blacklisted for a while')
    -- control: a reachable gizmo is still interacted with
    local h2 = harness({actors = {climb}, start = v(3, 0)})
    local n2 = 0
    h2.env.interact_object = function() n2 = n2 + 1 end
    h2.ext.pause('arkham_asylum')
    h2.ext.set_target('arkham_asylum', goal)
    h2.ext.try_traversal_route('arkham_asylum')
    for _ = 1, 60 do h2.tick('arkham_asylum') end
    ok(n2 >= 1, 'a reachable gizmo is interacted with')
end)

-- ── B4 (R6) ─────────────────────────────────────────────────────────────
local function freeclimb() return {get_position = function() return v(10, 0, 0) end,
    get_skin_name = function() return 'Traversal_Gizmo_FreeClimb_Up' end} end

case('B4 displaced 3-5 u after a non-Jump interact: the player walks back and interacts again', function()
    local h = harness({actors = {freeclimb()}, start = v(3, 0)})
    local interacts = 0
    h.env.interact_object = function() interacts = interacts + 1 end
    h.ext.pause('arkham_asylum')
    h.ext.set_target('arkham_asylum', v(40, 0))
    ok(h.ext.try_traversal_route('arkham_asylum') == true, 'routed via the climb')
    for _ = 1, 60 do
        h.tick('arkham_asylum'); h.ext.set_target('arkham_asylum', v(40, 1))
        if interacts > 0 then break end
    end
    ok(interacts == 1, 'first interact')
    h.player.pos = v(6, 0)                                    -- knockback: 4 u from the gizmo
    for _ = 1, 100 do                                          -- 5 s
        h.tick('arkham_asylum'); h.ext.set_target('arkham_asylum', v(40, 1))
        if interacts > 1 then break end
    end
    ok(interacts == 2, 'walked back into range and interacted again (was frozen, interacts=' .. interacts .. ')')
end)

case('B4 a player kept out of interact range drops the gizmo instead of waiting forever', function()
    local h = harness({actors = {freeclimb()}, start = v(3, 0)})
    local interacts = 0
    h.env.interact_object = function() interacts = interacts + 1 end
    h.ext.pause('arkham_asylum')
    h.ext.set_target('arkham_asylum', v(40, 0))
    h.ext.try_traversal_route('arkham_asylum')
    for _ = 1, 60 do
        h.tick('arkham_asylum'); h.ext.set_target('arkham_asylum', v(40, 1))
        if interacts > 0 then break end
    end
    h.player.pos = v(6, 0)
    local blocked = true                                      -- a mob pack holds the player there
    h.env.pathfinder.request_move = function() end
    local dropped_at = nil
    for i = 1, 20 * 60 do
        h.tick('arkham_asylum'); h.ext.set_target('arkham_asylum', v(40, 1))
        if not h.ext.is_traversal_routing() then dropped_at = i / 20; break end
    end
    ok(blocked and dropped_at ~= nil and dropped_at <= 20, 'routing dropped within 20 s (was still routing after 60 s)')
    local t = h.ext.get_target()
    ok(t ~= nil and dist(t, v(40, 1)) < 2, 'the caller goal is accepted again')
end)

-- ── B5 (R1) ─────────────────────────────────────────────────────────────
case('B5 a goal set after a same-zone jump survives the respawn detector; a real respawn still resets', function()
    local h = harness({real_explorer = true})
    h.ext.pause('infernal_horde'); h.ext.set_target('infernal_horde', v(5, 0))
    h.tick('infernal_horde')
    -- same-zone re-teleport with no Batmobile update meanwhile
    h.now = h.now + 3; h.player.pos = v(60, 0)
    h.ext.pause('infernal_horde'); h.ext.set_target('infernal_horde', v(80, 0))
    h.tick('infernal_horde')
    local t = h.ext.get_target()
    ok(t ~= nil and dist(t, v(80, 0)) < 1, 'the new waypoint is kept (was wiped: player stood still)')
    ok(h.logged('respawn detected') == 1, 'the jump is still noticed')
    -- control: death + checkpoint revive, the goal is from before the jump
    h.now = h.now + 5; h.player.pos = v(200, 0)
    h.tick('infernal_horde')
    ok(h.ext.get_target() == nil, 'a goal from before a respawn is dropped as before')
end)

-- ── B6 (R2) ─────────────────────────────────────────────────────────────
case('B6 get_owner() is nil after stop_long_path and after clear_target', function()
    local h = harness()
    ok(h.ext.navigate_long_path('reaper', v(40, 0)) == true, 'route started')
    ok(h.ext.get_owner() == 'reaper', 'route owner')
    h.ext.stop_long_path('reaper')
    ok(h.ext.get_owner() == nil, 'owner after stop_long_path: ' .. tostring(h.ext.get_owner()))
    h.ext.resume('helltide_revamped'); h.ext.set_target('helltide_revamped', v(10, 0))
    ok(h.ext.get_owner() == 'helltide_revamped', 'goal owner')
    h.ext.clear_target('helltide_revamped')
    ok(h.ext.get_owner() == nil, 'owner after clear_target: ' .. tostring(h.ext.get_owner()))
end)

-- ── B7 (R3) ─────────────────────────────────────────────────────────────
case('B7 STUCK detection is back ~6 s after a loading screen, not load time + 6 s', function()
    local h = harness({main = true, blocked = function() return true end})
    local function drive()
        h.now = h.now + 0.1; h.update()
        h.ext.pause('helltide_revamped'); h.ext.set_target('helltide_revamped', v(40, 0))
        h.ext.move('helltide_revamped')
    end
    for _ = 1, 5 do drive() end
    h.zone = '[sno none]'                                      -- 8 s same-world loading screen
    for _ = 1, 80 do drive() end
    h.zone = 'Scos_Coast'
    local t0, first = h.now, nil
    for _ = 1, 200 do
        drive()
        if not first and h.logged('[nav] STUCK') > 0 then first = h.now - t0 end
    end
    ok(first ~= nil and first <= 7, 'first STUCK ' .. tostring(first) .. ' s after the load (was 14 s)')
end)

-- ── B8 (R5) ─────────────────────────────────────────────────────────────
case('B8 a paused caller pressed against a big target: no STUCK, no Evade', function()
    local function run(goal_x)
        local h = harness({blocked = function() return true end})
        h.env.utility.can_cast_spell = function() return true end
        local casts = 0
        h.env.cast_spell.position = function() casts = casts + 1; return true end
        h.env.require('core.settings').use_evade = true
        for _ = 1, 100 do                                      -- 10 s
            h.now = h.now + 0.1
            h.ext.pause('arkham_asylum'); h.ext.update('arkham_asylum')
            h.ext.set_target('arkham_asylum', v(goal_x, 0)); h.ext.move('arkham_asylum')
        end
        return h.logged('[nav] STUCK'), casts
    end
    local stuck, casts = run(2.5)
    ok(stuck == 0 and casts == 0, string.format('boss hitbox at 2.5 u: STUCK=%d casts=%d (was 36/25)', stuck, casts))
    stuck, casts = run(8)
    ok(stuck >= 1 and casts >= 1, 'control: a goal 8 u away still gets STUCK handling')
end)

-- ── B9 ──────────────────────────────────────────────────────────────────
case('B9 freeroam holds for a busy Scavenger like for a busy Looter', function()
    local function moves_with(busy)
        local h = harness({main = true, freeroam = true, explorer_target = v(30, 0)})
        h.env.Scavenger = {is_busy = function() return busy end}
        local n0 = #h.moves
        for _ = 1, 100 do h.now = h.now + 0.05; h.update() end  -- 5 s
        return #h.moves - n0
    end
    ok(moves_with(false) > 0, 'freeroam drives')
    ok(moves_with(true) == 0, 'freeroam waits while Scavenger is busy')
end)

-- ── B10 (sweep B1; 2.2.5 Auditor LOWs) ──────────────────────────────────
case('B10 per-attempt navigator lines honour the logging combo', function()
    -- mode: stuck (paused caller wedged), explore_stuck (explorer target
    -- wedged), rejected / skipped_full / skipped_wall (explorer frontier behind
    -- a cliff re-picked every 0.5 s).
    local function run(level, mode, pattern)
        local long_partial = mode == 'skipped_full' or mode == 'skipped_wall'
        local h = harness({blocked = function() return true end, explorer_target = v(30, 0),
            walkable = function(_, y) return mode ~= 'skipped_wall' or math.abs(y) < 2 end,
            find_path = function(a, b, custom)
                if custom then return {a, b}, false end
                if long_partial then                           -- 5 nodes: not "too short"
                    return {a, v(a:x() + 1, a:y()), v(a:x() + 2, a:y()), v(a:x() + 3, a:y()),
                        v(a:x() + 4, a:y())}, true
                end
                return {a, v(a:x() + 1, a:y())}, true            -- a 2-node partial toward a far goal
            end})
        local settings = h.env.require('core.settings')
        settings.log_level = level
        settings.require_full_path_explore = mode == 'skipped_full'
        settings.wall_path, settings.wall_path_dist = mode == 'skipped_wall', 4
        h.nav.update_trap_state = function() end
        if mode == 'stuck' then
            for _ = 1, 600 do                                  -- 60 s wedged, paused caller
                h.now = h.now + 0.1
                h.ext.pause('helltide_revamped'); h.ext.set_target('helltide_revamped', v(40, 0))
                h.ext.move('helltide_revamped')
            end
        elseif mode == 'explore_stuck' then
            h.ext.resume('helltide_revamped')
            for _ = 1, 600 do
                h.now = h.now + 0.1
                if h.nav.target == nil then h.nav.target = v(30, 0) end
                h.nav.path = #h.nav.path > 0 and h.nav.path or {v(30, 0)}
                h.nav.pathfind_replan_cooldown = h.now + 10       -- keep walking the stale path
                h.ext.move('helltide_revamped')
            end
        else
            h.ext.resume('helltide_revamped')
            for _ = 1, 120 do
                h.now = h.now + 0.5
                h.nav.target, h.nav.path, h.nav.is_custom_target = v(30, 0), {}, false
                h.nav.pathfind_area_cooldown, h.nav.pathfind_replan_cooldown = -1, -1
                h.nav.pathfind_fail_count = 0
                h.ext.move('helltide_revamped')
            end
        end
        return h.logged(pattern), h.logged('similar)')
    end
    local cases_ = {
        {'stuck', '[nav] STUCK'},
        {'stuck', 'replanning, target kept'},
        {'explore_stuck', '[unstuck] EXHAUSTED'},
        {'rejected', '[nav] PARTIAL PATH REJECTED'},
        {'skipped_full', 'PARTIAL PATH SKIPPED (require_full_path_explore'},
        {'skipped_wall', 'PARTIAL PATH SKIPPED (wall_path'},
    }
    for _, c in ipairs(cases_) do
        local mode, pattern = c[1], c[2]
        local debug = run(2, mode, pattern)
        local info, similar = run(1, mode, pattern)
        local off = run(0, mode, pattern)
        ok(debug > 12, pattern .. ': the scenario repeats (Debug lines=' .. debug .. ')')
        ok(info >= 1 and info <= 12, pattern .. ': Info lines in 60 s=' .. info .. ' (Debug ' .. debug .. ')')
        ok(similar >= 1, pattern .. ': Info appends (+N similar)')
        ok(off == 0, pattern .. ': Disabled prints nothing (got ' .. off .. ')')
    end
end)

if #failures > 0 then
    error('Batmobile oscillation: ' .. #failures .. ' of ' .. cases .. ' cases failed:\n  ' .. table.concat(failures, '\n  '))
end
print(string.format('PASS Batmobile oscillation suite: %d cases, %d checks', cases, checks))
