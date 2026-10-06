-- QQT_Warpigz_v3 Rosie 1.0.25 (review of the 1.0.25 pickup branch): the
-- existing pickup contracts re-run, unchanged, under two host states the
-- joint host does not model by default:
--   WS   the Worldstone .pak is installed but idle: _G.Worldstone is
--        published (so Rosie's Scavenger stand-in is in effect) and
--        Navigator is idle (get_status state=idle, is_busy=false). The first
--        1.0.25 Navigator grace applied to every foreign mover there and
--        brought the 3.3.2 back-and-forth back: back_forth_332 B2/B3 and
--        yield_reach_1022 Y1/Y2 failed.
--   LIVE the host reported a rotation cast once, long before (live play; the
--        joint host never reports one). The fight hold's engaged rule is then
--        the live path: a farm plugin walking the player to an enemy 8 m away
--        that the rotation cannot reach yet lost the 3.3.2 fight hold
--        (activities_fight_hold_332 A2 failed: Rosie walked 7 m the other way,
--        the enemy never died).
-- joint_host.lua is wrapped: each listed file's dofile of it returns a J
-- whose new() applies the state right after J.new. ONLY=<text> picks runs.
-- `expected`: Lua patterns of inner FAIL lines that are the live path's
-- intended behaviour (each must appear; any other FAIL fails the run).
-- On the first 1.0.25 build (fd70b6d) WS back_forth_332 (B2, B3) and WS
-- yield_reach_1022 (Y1, Y1.2, Y1.3, Y2) fail; LIVE activities_fight_hold_332
-- A2 fails or passes narrowly there (the enemy dies after 11.8-12.3 s against
-- the 12 s bound, or never), so test_rosie_chest_close_1025 C9-C11 pin that
-- regression deterministically.
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local real_dofile = dofile
local failures, runs = {}, 0
local only = os.getenv('ONLY')

local function ws_idle(h)
    h.G.Navigator = {set_pause_condition = function() end, stop = function() end,
        get_status = function() return {state = 'idle', owner = 'Worldstone', is_busy = false, is_paused = false} end}
    h.G.Worldstone = {get_status = function() return {} end}
    h.run(4)
    assert(type(h.G.Scavenger) == 'table' and h.G.Scavenger._rosie == true, 'WS: the Scavenger stand-in is published')
end
-- The joint host's h.casting is the Town Portal channel (186139, no fight
-- evidence); h.rotation_spell is a rotation cast.
local function live_cast(h)
    local player = h.G.get_local_player()
    player.get_active_spell_id = function() if h.casting then return 186139 end return h.rotation_spell or -1 end
    local P = h.mod('Rosie', 'rosie.private.pickup.src.pickup')
    h.rotation_spell = 111
    P.sample_cast(h.now - 10) -- the host reported a rotation cast once, 10 s ago
    h.rotation_spell = nil
end

local function run(label, file, env, expected)
    local name = label .. ' ' .. file
    if only and not name:find(only, 1, true) then return end
    runs = runs + 1
    local J = real_dofile(ROOT .. '/audit/tests/joint_host.lua') -- a fresh host module per run, as when the file runs alone
    local wrapped = setmetatable({new = function(o) local h = J.new(o); env(h); return h end}, {__index = J})
    dofile = function(path)
        if type(path) == 'string' and path:find('/audit/tests/joint_host.lua', 1, true) then return wrapped end
        return real_dofile(path)
    end
    local real_print, fails = print, {}
    print = function(...)
        local line = table.concat((function(...) local t = {} for i = 1, select('#', ...) do t[i] = tostring((select(i, ...))) end return t end)(...), '\t')
        if line:find('^FAIL ') then fails[#fails + 1] = line end
        return real_print(...)
    end
    real_print('== ' .. name)
    local ok, err = pcall(real_dofile, ROOT .. '/audit/tests/' .. file)
    print, dofile = real_print, real_dofile
    local unexpected, seen = {}, {}
    for _, line in ipairs(fails) do
        local known = false
        for i, pat in ipairs(expected or {}) do if line:find(pat) then known = true; seen[i] = true end end
        if not known then unexpected[#unexpected + 1] = line end
    end
    for i, pat in ipairs(expected or {}) do
        if not seen[i] then unexpected[#unexpected + 1] = 'expected failure did not happen: ' .. pat end
    end
    if not ok and #fails == 0 then unexpected[#unexpected + 1] = tostring(err):gsub('\nstack traceback:.*', ''):sub(1, 400) end
    if #unexpected == 0 then print('PASS live paths 1.0.25: ' .. name .. (#fails > 0 and ' (with its expected live-path difference)' or ''))
    else
        failures[#failures + 1] = name
        print('FAIL live paths 1.0.25: ' .. name .. ': ' .. table.concat(unexpected, ' | '):sub(1, 600))
    end
end

run('WS', 'test_rosie_back_forth_332.lua', ws_idle)
run('WS', 'test_rosie_yield_reach_1022.lua', ws_idle)
run('WS', 'test_rosie_foreign_mover.lua', ws_idle)
-- A1's enemy (8 m, never approached, not an elite, no cast in 3 s) engages
-- nobody on the live path: the drop is taken at once, Reaper still waits for
-- it (the file's contract), but the 45 s cap line A1 also checks never comes.
run('LIVE', 'test_activities_fight_hold_332.lua', live_cast, {'^FAIL activities%-fight: A1 Reaper loot_ready .*:77: Rosie capped its fight hold\n'})
run('LIVE', 'test_rosie_back_forth_332.lua', live_cast)
run('LIVE', 'test_rosie_pickup_1022.lua', live_cast)
run('LIVE', 'test_rosie_pickup_fight_q1.lua', live_cast)
run('LIVE', 'test_rosie_loot_waiting_1022.lua', live_cast)

print(string.format('rosie live paths 1.0.25: %d runs, %d failures', runs, #failures))
if #failures > 0 then error(#failures .. ' live-path run(s) failed: ' .. table.concat(failures, ' | ')) end
