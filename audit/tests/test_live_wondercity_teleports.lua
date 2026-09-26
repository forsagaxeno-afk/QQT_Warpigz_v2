-- Live report (v2.1.0): "when wondercity starts he TPs to the entrance 5 times
-- in a row, then starts the run". Loads the real teleport_kurast and
-- walk_kurast tasks with QQT-shaped doubles.
local root = assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/WonderCity-main/'
local failures, checks = {}, 0
local function check(label, fn)
    checks = checks + 1
    local ok, err = pcall(fn)
    if not ok then failures[#failures + 1] = label .. ': ' .. tostring(err) end
end
local function eq(a, b, m) assert(a == b, (m or 'mismatch') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end

local function vec(x, y) return {x = function() return x end, y = function() return y end, z = function() return 0 end} end

local function fixture()
    local f = {now = 100, teleports = 0, spell = 0, world = 'Sanctuary', zone = 'Kehj_Kurast', pos = vec(10, 10), logs = {}}
    local settings = {town_zone = 'Kehj_Kurast', town_waypoint = 0x1234, town_long_path_target = nil}
    local utils = {
        player_in_zone = function(z) return f.zone == z end,
        player_in_undercity = function() return false end,
        stop_movement = function() end,
        distance = function(a, b) return math.max(math.abs(a:x() - b:x()), math.abs(a:y() - b:y())) end,
        get_spirit_brazier = function() return nil end,
        get_entrance_portal = function() return nil end,
    }
    local path = {vec(10, 10), vec(40, 10), vec(80, 10), vec(120, 10)}
    local modules = {['core.utils'] = utils, ['core.settings'] = settings, ['data.path'] = path}
    local env = setmetatable({
        require = function(n) return assert(modules[n], 'unexpected require ' .. n) end,
        get_time_since_inject = function() return f.now end,
        get_local_player = function()
            return {get_position = function() return f.pos end, get_active_spell_id = function() return f.spell end}
        end,
        get_current_world = function()
            return {get_name = function() return f.world end, get_current_zone_name = function() return f.zone end}
        end,
        teleport_to_waypoint = function() f.teleports = f.teleports + 1 end,
        console = {print = function(l) f.logs[#f.logs + 1] = l end},
        BatmobilePlugin = setmetatable({is_long_path_navigating = function() return false end},
            {__index = function() return function() return true end end}),
    }, {__index = _G})
    env._G = env
    f.tp = assert(loadfile(root .. 'tasks/teleport_kurast.lua', 't', env))()
    f.walk = assert(loadfile(root .. 'tasks/walk_kurast.lua', 't', env))()
    return f
end

check('teleport_kurast: no retry while the channel/loading of the first trip is still arriving', function()
    local f = fixture()
    f.zone = 'Hawe_Zarbinzet'
    f.tp.Execute(); eq(f.teleports, 1, 'first teleport')
    f.spell = 186139
    for _ = 1, 40 do f.now = f.now + 0.1; f.tp.Execute() end   -- 4 s channel
    f.spell = 0
    f.world = 'Limbo'
    for _ = 1, 30 do f.now = f.now + 0.1; f.tp.Execute() end   -- 3 s loading
    eq(f.teleports, 1, 'a retry cancelled the arriving trip (was 3 s debounce)')
end)

check('walk_kurast: standing still at the entrance re-teleports at most twice, then walks on (logged once)', function()
    local f = fixture()
    for _ = 1, 1200 do f.now = f.now + 0.1; f.walk.Execute() end  -- 120 s, never moving
    eq(f.teleports, 2, 'bounded watchdog re-teleports (was one every 15 s)')
    local n = 0
    for _, l in ipairs(f.logs) do if l:find('no further teleports', 1, true) then n = n + 1 end end
    eq(n, 1, 'cap logged once')
end)

check('walk_kurast: real progress re-arms the watchdog for a genuine later stall', function()
    local f = fixture()
    for _ = 1, 400 do f.now = f.now + 0.1; f.walk.Execute() end
    eq(f.teleports, 2)
    f.pos = vec(40, 10); f.now = f.now + 0.1; f.walk.Execute()
    for _ = 1, 300 do f.now = f.now + 0.1; f.walk.Execute() end
    eq(f.teleports, 4, 'a new stall after real movement may recover again, bounded to 2 per stall')
end)

if #failures > 0 then error('WonderCity live teleport regressions failed:\n' .. table.concat(failures, '\n')) end
print(string.format('PASS: WonderCity live teleport regressions (%d checks)', checks))
