-- Live report (v2.1.0): "when wondercity starts he TPs to the entrance 5 times
-- in a row, then starts the run". Loads the real teleport_kurast and
-- walk_kurast tasks with QQT-shaped doubles.
local root = assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/WonderCity/'
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
    f.set_bat = function(b) env.BatmobilePlugin = b end
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

check('walk_kurast: passing the stall point re-arms the watchdog for a genuine later stall', function()
    local f = fixture()
    for _ = 1, 600 do f.now = f.now + 0.1; f.walk.Execute() end -- 2.2.6: 20 s window
    eq(f.teleports, 2)
    -- QQT_Warpigz_v3 WonderCity 2.2.6: a jump to the next node is what a
    -- landing looks like and no longer counts; walking 3 nodes past does.
    f.pos = vec(120, 10); f.now = f.now + 0.1; f.walk.Execute()
    for _ = 1, 500 do f.now = f.now + 0.1; f.walk.Execute() end
    eq(f.teleports, 4, 'a new stall past the old one may recover again, bounded to 2 per stall')
end)

-- QQT_Warpigz_v3 WonderCity 2.2.6 (audit/reviews/undercity_teleports_2026-09-28.md):
-- a live-shaped recovery: the cast channels 3 s, 2 s of loading (the task
-- manager runs no task), the player lands at path[1] and walks back to the
-- stall. Each case failed on 3.3.6 (WonderCity 2.2.5).
local function live_fixture(stall_x)
    local f = fixture()
    f.stall_x = stall_x
    return f
end
local function drive(f, seconds, opts)
    opts = opts or {}
    local stop = f.now + seconds
    local cast_end, limbo_end
    while f.now < stop do
        f.now = f.now + 0.1
        if cast_end and f.now >= cast_end then
            cast_end = nil; f.spell = 0; limbo_end = f.now + 2
        end
        if limbo_end then
            if f.now >= limbo_end then
                limbo_end = nil
                f.landings = (f.landings or 0) + 1
                -- deterministic landing jitter (review: no math.random in tests)
                local j = opts.jitter and ({0.8, -1.9, 1.4, -0.6, 2.0, -1.2})[(f.landings - 1) % 6 + 1] or 0
                f.pos = vec(10 + j, 10)
                if opts.on_land then opts.on_land(f) end
            end
        else
            local before = f.teleports
            f.walk.Execute()
            if f.teleports > before then cast_end = f.now + 3; f.spell = 186139 end
            if f.spell == 0 and opts.walk ~= false then
                local x = f.pos:x()
                if x < f.stall_x then f.pos = vec(math.min(f.stall_x, x + 0.7), 10) end
            end
        end
    end
end
local function cap_lines(f)
    local n = 0
    for _, l in ipairs(f.logs) do if l:find('no further teleports', 1, true) then n = n + 1 end end
    return n
end

check('walk_kurast 2.2.6: a stall 30 m past the landing re-teleports at most twice in 180 s, cap logged once (3.3.6: 8, 0)', function()
    local f = live_fixture(40)
    drive(f, 180)
    assert(f.teleports <= 2, 'teleports ' .. f.teleports)
    eq(cap_lines(f), 1, 'cap line')
end)

check('walk_kurast 2.2.6: a stall at the landing with 2 m landing jitter stays bounded', function()
    local f = live_fixture(10)
    drive(f, 180, {jitter = 2})
    assert(f.teleports <= 2, 'teleports ' .. f.teleports)
end)

check('walk_kurast 2.2.6: a world-key change (task.reset) after each landing does not re-arm the cap', function()
    local f = live_fixture(40)
    drive(f, 180, {on_land = function(ff) ff.walk.reset('outside') end})
    assert(f.teleports <= 2, 'teleports ' .. f.teleports .. ' (3.3.6: task.reset zeroed the count)')
end)

check('walk_kurast 2.2.6: a single Batmobile give-up (goal refused 15 s) is not a re-teleport (3.3.6: 1)', function()
    local f = fixture()
    local refused_until = f.now + 15
    local set_calls = 0
    -- Batmobile double: refuses every goal for 15 s after its give-up, then accepts
    local env_bat = setmetatable({is_long_path_navigating = function() return false end,
        set_target = function() set_calls = set_calls + 1; return f.now >= refused_until end},
        {__index = function() return function() return true end end})
    f.set_bat(env_bat)
    for _ = 1, 170 do f.now = f.now + 0.1; f.walk.Execute() end   -- 17 s still: refused, then accepted
    for _ = 1, 100 do f.now = f.now + 0.1; f.pos = vec(math.min(120, f.pos:x() + 0.7), 10); f.walk.Execute() end
    eq(f.teleports, 0, 'teleports')
    assert(set_calls > 0, 'drove Batmobile')
end)

check('walk_kurast 2.2.6: no Batmobile drive during its own recovery channel (3.3.6: every tick)', function()
    local f = fixture()
    local calls, in_channel = 0, 0
    local env_bat = setmetatable({is_long_path_navigating = function() return false end},
        {__index = function(_, k) return function() calls = calls + 1; if f.spell == 186139 then in_channel = in_channel + 1 end; return true end end})
    f.set_bat(env_bat)
    for _ = 1, 250 do f.now = f.now + 0.1; f.walk.Execute() end  -- stall -> recovery at 20 s
    eq(f.teleports, 1, 'one recovery')
    f.spell = 186139
    local before = in_channel
    for _ = 1, 40 do f.now = f.now + 0.1; f.walk.Execute() end  -- 4 s channel
    eq(in_channel - before, 0, 'Batmobile calls inside the channel')
    f.spell = 0
end)

if #failures > 0 then error('WonderCity live teleport regressions failed:\n' .. table.concat(failures, '\n')) end
print(string.format('PASS: WonderCity live teleport regressions (%d checks)', checks))
