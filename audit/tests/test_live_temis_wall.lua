-- Live report (v2.1.1): "when the whisper cache triggers and right after he
-- wants to hand in the finished war plan, he gets stuck on the wall between
-- the whisper tree and the war plan table". Loads the real WarPigs turn-in
-- task and the real WarPug route module with a straight-line host double
-- in which the wall blocks any move whose goal lies across it.
local suite = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local failures, checks = {}, 0
local function check(label, fn)
    checks = checks + 1
    local ok, err = pcall(fn)
    if not ok then failures[#failures + 1] = label .. ': ' .. tostring(err) end
end
local function eq(a, b, m) assert(a == b, (m or 'mismatch') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end

local Vec = {}
Vec.__index = Vec
function Vec:new(x, y, z) return setmetatable({px = x, py = y, pz = z or 0}, Vec) end
function Vec:x() return self.px end
function Vec:y() return self.py end
function Vec:z() return self.pz end
function Vec:dist_to(o) local dx, dy = self.px - o:x(), self.py - o:y(); return math.sqrt(dx * dx + dy * dy) end

local RAVEN = Vec:new(2596.38, -495.79, 30.52)
local TYRAEL = Vec:new(2570.0, -500.0, 31.0)    -- War Plan table side (west of the wall)

-- Wall: a segment between the Raven area and the table side. Moving toward a
-- goal on the other side of x = 2588 while south of y = -490 is blocked.
local function blocked(from, goal)
    return from:y() < -490 and goal:y() < -490 and (from:x() - 2588) * (goal:x() - 2588) < 0
end

local function world(start)
    local w = {now = 100, pos = start, moves = 0, logs = {}}
    w.pathfinder = {request_move = function(goal)
        w.moves = w.moves + 1
        if blocked(w.pos, goal) then return end            -- runs into the wall
        local d = w.pos:dist_to(goal)
        local step = math.min(d, 0.6)                        -- 6 yd/s at 0.1 s ticks
        if d > 0 then
            w.pos = Vec:new(w.pos:x() + (goal:x() - w.pos:x()) / d * step,
                w.pos:y() + (goal:y() - w.pos:y()) / d * step, goal:z())
        end
    end}
    return w
end

local function turn_in(w)
    local npc = {get_position = function() return TYRAEL end,
        get_skin_name = function() return 'NPC_QST_X2_Tyrael_NonCombat' end}
    local env = setmetatable({
        vec3 = Vec, pathfinder = w.pathfinder,
        console = {print = function(l) w.logs[#w.logs + 1] = l end},
        get_time_since_inject = function() return w.now end,
        get_player_position = function() return w.pos end,
        get_local_player = function() return {get_position = function() return w.pos end} end,
        get_current_world = function() return {get_current_zone_name = function() return 'Skov_Temis' end,
            get_name = function() return 'Sanctuary' end} end,
        actors_manager = {get_all_actors = function() return {npc} end},
        loot_manager = {interact_with_object = function() w.interacted = true end},
        teleport_to_waypoint = function() end,
        attributes = {PLAYER_IN_TOWN_LEVEL_AREA = 1},
    }, {__index = _G})
    env._G = env
    env.require = function(name)
        assert(name == 'wp_temis_route', 'unexpected dependency ' .. name)
        return assert(loadfile(suite .. '/WarPigs-1.0.0/wp_temis_route.lua', 't', env))()
    end
    return assert(loadfile(suite .. '/WarPigs-1.0.0/core/tasks/turn_in_rewards.lua', 't', env))()
end

local function logged(w, needle)
    local n = 0
    for _, l in ipairs(w.logs) do if l:find(needle, 1, true) then n = n + 1 end end
    return n
end

check('turn-in from the Whisper tree walks around the wall and reaches Tyrael', function()
    local w = world(Vec:new(2595.5, -494.0, 30.5))      -- right after the Whisper claim
    local task = turn_in(w)
    for _ = 1, 600 do
        w.now = w.now + 0.1
        task.tick(true, {activity_quiet = true})
        if w.interacted then break end
    end
    eq(w.interacted, true, 'reached Tyrael (was: stuck on the wall)')
    eq(logged(w, 'Whisper side of the wall'), 1, 'route chosen once')
end)

check('a direct walk that stalls on the wall takes a bounded detour', function()
    local w = world(Vec:new(2593.0, -498.0, 30.5))      -- beside the wall, farther than 10 yd? no: stall path
    local route = assert(loadfile(suite .. '/WarPug-1.0.0/warpug_temis_route.lua', 't',
        setmetatable({vec3 = Vec, pathfinder = w.pathfinder}, {__index = _G})))()
    local r = route.new(function(l) w.logs[#w.logs + 1] = l end)
    r.started = true                                       -- skip the Raven-side shortcut: test the stall detour
    for _ = 1, 600 do
        w.now = w.now + 0.1
        r.move(w.pos, TYRAEL, w.now)
        if w.pos:dist_to(TYRAEL) < 3 then break end
    end
    local ok = w.pos:dist_to(TYRAEL) < 3
    assert(ok, 'reached the table after a detour, at ' .. w.pos:x() .. ',' .. w.pos:y())
    eq(logged(w, 'detour around the Whisper wall'), 1, 'one detour logged')
end)

if #failures > 0 then error('Temis wall regressions failed:\n' .. table.concat(failures, '\n')) end
print(string.format('PASS: Temis wall live regressions (%d checks)', checks))
