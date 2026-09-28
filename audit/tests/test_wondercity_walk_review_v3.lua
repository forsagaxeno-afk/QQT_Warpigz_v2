-- QQT_Warpigz_v3 WonderCity 2.2.6, Coordinator review round 2026-09-28 16:30
-- (audit/reviews/review_round_2026-09-28_1630.md). Each case failed on the
-- 2.2.6 first cut (a2a5c57):
--   F1 [MED] the goal flipped every pulse between two path points tied in
--      octile distance (the J1 post-cap freeze): the walk index is monotonic.
--   E1 [LOW] an advisory-only need inside the alfred task's 30 s post-cycle
--      grace sent the exit to Temis for a trip that never starts.
--   J1-J3 joint (real Batmobile + WonderCity, Kurast route of data/path.lua,
--      a full-width block on the bridge): cast count AND time to the brazier;
--      a persistent block: bounded casts, one cap line, and Batmobile's
--      give-ups stay rare (a2a5c57's refused-node skip re-drove the
--      blacklisted node: 247 give-ups in 400 s).
-- Re-review 2026-09-28 18:20 (audit/reviews/rereview_2026-09-28_1820.md):
--   J5 [MED] the cap was a latch: a block only a fresh landing clears froze
--      the walk for good (715d160: no entry); it now expires after 300 s.
--   J6 the investigation's J1 (partial wall, start in Temis).
--   C1-C8 cap expiry, on_release / 'run' / arrival end the walk, furthest
--      stall key, long-path retry back-off, Temis slow walk and detour stall,
--      release_control resets teleport_kurast (C1, C2, C5 fail on 715d160).
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local WC = ROOT .. '/WonderCity/'
local checks, failures = 0, {}
local function ok(value, message)
    if not value then error(message or 'expected a true value', 2) end
    checks = checks + 1
end
local function eq(actual, expected, message)
    if actual ~= expected then
        error((message or 'mismatch') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
    checks = checks + 1
end
local function case(name, fn)
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS wondercity-review: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL wondercity-review: ' .. name .. ': ' .. tostring(err)) end
end
local function vec(x, y) return {x = function() return x end, y = function() return y end, z = function() return 0 end} end

case('F1 a stall on the tie between two path points keeps one goal (a2a5c57: flips every pulse)', function()
    local f = {now = 100, pos = vec(5.1, 0), logs = {}, targets = {}}
    local settings = {town_zone = 'Naha_Kurast', town_waypoint = 0x1234}
    local utils = {
        player_in_zone = function(z) return z == 'Naha_Kurast' end,
        distance = function(a, b)
            local dx, dy = math.abs(a:x() - b:x()), math.abs(a:y() - b:y())
            return math.max(dx, dy) + (math.sqrt(2) - 1) * math.min(dx, dy)
        end,
        get_spirit_brazier = function() return nil end,
        get_entrance_portal = function() return nil end,
    }
    local path = {vec(0, 0), vec(10, 0), vec(20, 0), vec(30, 0), vec(40, 0), vec(50, 0)}
    local modules = {['core.utils'] = utils, ['core.settings'] = settings, ['data.path'] = path}
    local env = setmetatable({
        require = function(n) return assert(modules[n], 'unexpected require ' .. n) end,
        get_time_since_inject = function() return f.now end,
        get_local_player = function()
            return {get_position = function() return f.pos end, get_active_spell_id = function() return 0 end}
        end,
        teleport_to_waypoint = function() end,
        console = {print = function(l) f.logs[#f.logs + 1] = l end},
        BatmobilePlugin = setmetatable({
            is_long_path_navigating = function() return false end,
            set_target = function(_, p) f.targets[#f.targets + 1] = p:x(); return true end,
        }, {__index = function() return function() return true end end}),
    }, {__index = _G})
    env._G = env
    local walk = assert(loadfile(WC .. 'tasks/walk_kurast.lua', 't', env))()
    -- The player is pulled back and forth 0.2 m across the tie (x = 5).
    for i = 1, 100 do
        f.now = f.now + 0.1
        f.pos = vec(i % 2 == 0 and 5.1 or 4.9, 0)
        walk.Execute()
    end
    local distinct, seen = 0, {}
    for i = 20, #f.targets do
        local x = f.targets[i]
        if not seen[x] then seen[x] = true; distinct = distinct + 1 end
    end
    eq(distinct, 1, 'distinct goals while standing on the tie')
end)

case('E1 an advisory-only need inside the 30 s post-cycle grace exits to the town, not Temis', function()
    local function run(grace)
        local f = {now = 100, tps = {}}
        local tracker = {exit_trigger_time = 50}
        local settings = {town_waypoint = 0x1EAACC, exit_mode = 1, exit_undercity_delay = 0, confirm_delay = 5,
            party_enabled = false}
        local modules = {
            ['core.utils'] = {exit_forced = function() return true end, player_in_undercity = function() return true end},
            ['core.settings'] = settings, ['core.tracker'] = tracker,
            ['core.reward_phase'] = {can_exit = function() return true end},
            ['tasks.alfred'] = {advisory_grace_active = function() return grace end},
        }
        local env = setmetatable({
            require = function(n) return assert(modules[n], 'unexpected require ' .. n) end,
            get_time_since_inject = function() return f.now end,
            get_local_player = function() return {} end,
            teleport_to_waypoint = function(wp) f.tps[#f.tps + 1] = wp end,
            reset_all_dungeons = function() end,
            console = {print = function() end},
            RosiePlugin = {},
            AlfredTheButlerPlugin = {get_status = function()
                return {enabled = true, paused = false, need_trigger = true, inventory_full = false, need_repair = false}
            end},
            BatmobilePlugin = setmetatable({}, {__index = function() return function() return false end end}),
        }, {__index = _G})
        env._G = env
        local exit = assert(loadfile(WC .. 'tasks/exit_undercity.lua', 't', env))()
        exit.Execute()
        return f.tps[1]
    end
    eq(run(true), 0x1EAACC, 'grace active: the exit goes to the town waypoint')
    eq(run(false), 0x1CE51E, 'no grace: the exit goes to Temis (Rosie serves there)')
end)

-- Joint: Kurast laid over data/path.lua; the brazier streams in near the end
-- of the route; a full-width wall across the bridge (path[10]..path[12]) for
-- `block` s (nil: persistent).
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
-- opts.wall: the wall rectangle; opts.lift_landings: the wall goes away on the
-- Nth walk_kurast recovery landing (an arrival-tied block); opts.temis: start
-- in Temis (teleport_kurast brings the player to Kurast).
local function joint(block, seconds, opts)
    opts = opts or {}
    local h = J.new({dirs = {'Batmobile', 'WonderCity'}, place = opts.temis and 'temis' or 'pit'})
    local path = assert(loadfile(WC .. 'data/path.lua', 't',
        setmetatable({vec3 = {new = function(_, x, y) return h.v(x, y) end}}, {__index = _G})))()
    local K = h.P.kurast
    K.box = {1000, 1080, 120, 260}
    K.spawn = h.v(path[1]:x(), path[1]:y())
    for i = #K.actors, 1, -1 do if K.actors[i] == h.brazier then table.remove(K.actors, i) end end
    h.brazier.pos = h.v(path[#path]:x(), path[#path]:y())
    K.walls = {opts.wall or {1000, 1080, 187.4, 188.4}}
    if not opts.temis then
        h.travel_to('kurast', 0.1, 'test')
        h.run(3)
    end
    local landings = 0
    local travel_to = h.travel_to
    h.travel_to = function(place, channel, why)
        local p = type(place) == 'string' and h.P[place] or place
        if p == K and h.place == K then -- a walk_kurast recovery (Kurast -> Kurast)
            landings = landings + 1
            if opts.lift_landings and landings >= opts.lift_landings then
                h.at((channel or 1) + 2.1, function() K.walls = nil end)
            end
        end
        return travel_to(place, channel, why)
    end
    local wc = h.mod('WonderCity', 'gui').elements
    wc.main_toggle:set(true); wc.skip_tribute:set(true)
    local t0 = h.now
    if block then h.at(block, function() K.walls = nil end) end
    local wp0, listed, entry = #h.waypoints, false, nil
    h.run_until(function() return entry ~= nil end, seconds, function(hh)
        if not listed and hh.place == K and hh.pos:dist_to_ignore_z(h.brazier.pos) < 25 then
            listed = true; K.actors[#K.actors + 1] = h.brazier; entry = hh.now - t0
        end
    end)
    return {h = h, casts = #h.waypoints - wp0, entry = entry, giveups = h.logged('clearing unreachable'),
        caps = h.logged('no further teleports'), landings = landings}
end

case('J1 the bridge blocked for 60 s: at most 2 casts, at the brazier within 15 s of the block lifting', function()
    local r = joint(60, 200)
    ok(r.casts <= 2, 'casts ' .. r.casts .. ' (2.2.5: 3)')
    ok(r.entry ~= nil and r.entry <= 75, 'time to the brazier ' .. tostring(r.entry) .. '\n' .. r.h.tail(10))
end)

case('J2 blocked for 120 s: at most 2 casts, at the brazier within 15 s (2.2.5: 6 casts)', function()
    local r = joint(120, 260)
    ok(r.casts <= 2, 'casts ' .. r.casts)
    ok(r.entry ~= nil and r.entry <= 135, 'time to the brazier ' .. tostring(r.entry) .. '\n' .. r.h.tail(10))
end)

case('J3 blocked for good: 2 casts, one cap line, Batmobile give-ups stay rare (a2a5c57: 247 in 400 s)', function()
    local r = joint(nil, 400)
    eq(r.entry, nil, 'no way through')
    ok(r.casts <= 2, 'casts ' .. r.casts .. ' (2.2.5: 19)')
    eq(r.caps, 1, 'cap line')
    ok(r.giveups <= 30, 'Batmobile give-ups in 400 s: ' .. r.giveups)
end)

-- ── re-review 2026-09-28 18:20 (audit/reviews/rereview_2026-09-28_1820.md) ──
case('J5 a block only a fresh landing clears (lifted on the 3rd recovery landing): entry within 600 s (715d160: never, the cap was a latch)', function()
    local r = joint(nil, 620, {lift_landings = 3})
    ok(r.entry ~= nil and r.entry <= 600, 'time to the brazier ' .. tostring(r.entry) .. ', casts ' .. r.casts .. '\n' .. r.h.tail(8))
    ok(r.casts <= 4, 'casts ' .. r.casts)
end)

-- The investigation's J1 geometry. Batmobile's A* differs between runtimes
-- here (hash order): under LuaJIT it walks around the wall (1 cast, the
-- brazier at +24 s); under Lua 5.4 it gives up twice, then the capped walk's
-- long path gets around (3 casts, +181 s; the same on 715d160). Both are
-- bounded; a2a5c57 never entered (4 casts in 400 s), 2.2.5 took 5 casts.
case('J6 the investigation\'s J1: a partial wall on the bridge, start in Temis: <= 1 + 2 casts, at the brazier within 200 s', function()
    local r = joint(nil, 220, {temis = true, wall = {1020, 1060, 190, 192}, lift_landings = 4})
    ok(r.casts <= 3, 'casts ' .. r.casts .. '\n' .. r.h.tail(8))
    ok(r.entry ~= nil and r.entry <= 200, 'time to the brazier ' .. tostring(r.entry) .. '\n' .. r.h.tail(8))
end)

-- Unit fixture: the real walk_kurast; path along x, the player can be stuck.
local function unit(opts)
    opts = opts or {}
    local f = {now = 100, pos = vec(0, 5), logs = {}, teleports = 0, lp = 0}
    local settings = {town_zone = 'Naha_Kurast', town_waypoint = 0x1234, town_long_path_target = opts.target}
    local utils = {
        player_in_zone = function(z) return z == 'Naha_Kurast' end,
        distance = function(a, b)
            local dx, dy = math.abs(a:x() - b:x()), math.abs(a:y() - b:y())
            return math.max(dx, dy) + (math.sqrt(2) - 1) * math.min(dx, dy)
        end,
        get_spirit_brazier = function() return nil end,
        get_entrance_portal = function() return nil end,
    }
    f.utils = utils
    local path = {}
    for i = 0, 20 do path[#path + 1] = vec(i * 10, 5) end -- y = 5: (x, 0) reads as an unloaded position
    local modules = {['core.utils'] = utils, ['core.settings'] = settings, ['data.path'] = path}
    local env = setmetatable({
        require = function(n) return assert(modules[n], 'unexpected require ' .. n) end,
        get_time_since_inject = function() return f.now end,
        get_local_player = function()
            return {get_position = function() return f.pos end, get_active_spell_id = function() return 0 end}
        end,
        teleport_to_waypoint = function() f.teleports = f.teleports + 1; f.pos = opts.landing or vec(0, 5) end,
        console = {print = function(l) f.logs[#f.logs + 1] = l end},
        BatmobilePlugin = setmetatable({
            is_long_path_navigating = function() return false end,
            navigate_long_path = function() f.lp = f.lp + 1; return false end,
        }, {__index = function() return function() return true end end}),
    }, {__index = _G})
    env._G = env
    f.walk = assert(loadfile(WC .. 'tasks/walk_kurast.lua', 't', env))()
    -- walk toward stall_x at `speed` m/s, then stand
    f.run = function(seconds, stall_x, speed)
        local stop = f.now + seconds
        while f.now < stop do
            f.now = f.now + 0.1
            if f.walk.shouldExecute() then f.walk.Execute() end
            local x = f.pos:x()
            if stall_x and x < stall_x then f.pos = vec(math.min(stall_x, x + (speed or 7) * 0.1), 5) end
        end
    end
    f.caps = function()
        local n = 0
        for _, l in ipairs(f.logs) do if l:find('no further teleports', 1, true) then n = n + 1 end end
        return n
    end
    return f
end

case('C1 the cap expires 300 s after it engaged: a stall that persists re-teleports again (715d160: never)', function()
    local f = unit()
    f.run(120, 45)
    eq(f.teleports, 2, 'capped after 2'); eq(f.caps(), 1, 'cap line')
    f.run(300, 45)
    ok(f.teleports >= 3, 'a re-teleport after the cap expired: ' .. f.teleports)
    ok(f.caps() >= 1, 'cap lines ' .. f.caps())
end)

case('C2 release_control (on_release) ends the walk: a later visit is not capped (715d160: latched)', function()
    local f = unit()
    f.run(120, 45)
    eq(f.teleports, 2, 'capped after 2')
    ok(type(f.walk.on_release) == 'function', 'walk_kurast has no on_release')
    f.walk.on_release()
    f.now = f.now + 1800 -- 30 min later, the same block
    f.pos = vec(0, 5)
    f.run(60, 45)
    ok(f.teleports >= 3, 'the new visit re-teleports: ' .. f.teleports)
end)

case('C3 a \'run\' transition or an arrival from another zone ends the walk (fresh budget)', function()
    local f = unit()
    f.run(120, 45); eq(f.teleports, 2)
    f.walk.reset('run'); f.pos = vec(0, 5)
    f.run(40, 45); eq(f.teleports, 3, 'after run')
    f.run(120, 45) -- capped again
    local n = f.teleports
    f.utils.kurast_arrivals = 1; f.pos = vec(0, 5) -- teleport_kurast delivered an arrival
    f.run(40, 45); eq(f.teleports, n + 1, 'after an arrival from another zone')
end)

case('C4 two alternating stall points keep one budget (the furthest stall key)', function()
    local f = unit()
    -- stall at x=150 (node 16), then at x=45 (node 5), alternating
    for i = 1, 6 do f.run(60, i % 2 == 1 and 150 or 45) end
    ok(f.teleports <= 2, 'teleports in 360 s: ' .. f.teleports)
end)

case('C5 after the cap, failed long paths back off (not every 2 s)', function()
    local f = unit()
    f.run(120, 45) -- capped, long-path fallback
    local before = f.lp
    f.run(100, 45)
    ok(f.lp - before <= 10, 'navigate_long_path calls in 100 s: ' .. (f.lp - before) .. ' (715d160: ~50)')
end)

case('C6 Temis: a steady slow walk (0.3 m/s) never re-teleports', function()
    local f = unit({target = vec(200, 5)})
    f.run(60, 200, 0.3)
    eq(f.teleports, 0, 'teleports')
end)

case('C7 Temis: a detour stall farther from the target than the landing is bounded (<= 2, one cap line)', function()
    -- target at x=0, landing 50 m away, the stall on a detour 65 m away
    local f = unit({target = vec(0, 5), landing = vec(50, 5)})
    f.pos = vec(50, 5)
    f.run(300, 65)
    ok(f.teleports <= 2, 'teleports ' .. f.teleports .. ' (2.2.6 first cut: 8)')
    eq(f.caps(), 1, 'cap line')
end)

case('C8 WonderCity release_control resets teleport_kurast\'s count (joint)', function()
    local h = J.new({dirs = {'Batmobile', 'WonderCity'}, place = 'pit'})
    local wc = h.mod('WonderCity', 'gui').elements
    wc.main_toggle:set(true)
    h.run(2)
    local tp = h.mod('WonderCity', 'tasks.teleport_kurast')
    tp.casts = 3
    wc.main_toggle:set(false)
    h.run(1)
    eq(tp.casts, 0, 'casts after release_control')
end)

print(string.format('wondercity walk review v3: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(#failures .. ' WonderCity review regression(s) failed') end
