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
local function joint(block, seconds)
    local h = J.new({dirs = {'Batmobile', 'WonderCity'}, place = 'pit'})
    local path = assert(loadfile(WC .. 'data/path.lua', 't',
        setmetatable({vec3 = {new = function(_, x, y) return h.v(x, y) end}}, {__index = _G})))()
    local K = h.P.kurast
    K.box = {1000, 1080, 120, 260}
    K.spawn = h.v(path[1]:x(), path[1]:y())
    for i = #K.actors, 1, -1 do if K.actors[i] == h.brazier then table.remove(K.actors, i) end end
    h.brazier.pos = h.v(path[#path]:x(), path[#path]:y())
    K.walls = {{1000, 1080, 187.4, 188.4}}
    h.travel_to('kurast', 0.1, 'test')
    h.run(3)
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
        caps = h.logged('no further teleports')}
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

print(string.format('wondercity walk review v3: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(#failures .. ' WonderCity review regression(s) failed') end
