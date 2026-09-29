-- QQT_Warpigz_v3 WonderCity 2.2.7: W1 of audit/reviews/sweep_2026-09-28.md
-- (S3 F8, S4 F5). The resume guard was keyed on tracker.exit_trigger_time,
-- which exit_undercity stamps when its 10 s exit DELAY starts (before any
-- cast). A Rosie trip that started inside that delay was not recorded as
-- resumable: the return into the same Undercity world was a NEW run, the
-- opened reward chest was forgotten, goto_chest waited on it and the
-- finished instance was explored again. Now only an exit CAST
-- (tracker.exit_cast_time) makes the leave final.
-- Joint host: real Batmobile + WonderCity + real Rosie (automatic trips).
-- Runs under Lua 5.4 and LuaJIT.
local SUITE = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local checks, failures = 0, {}
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
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS WonderCity trip in exit delay: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL WonderCity trip in exit delay: ' .. name .. ': ' .. tostring(err)) end
end

local J = dofile(SUITE .. '/audit/tests/joint_host.lua')

-- The boss floor after the kill: the reward chest 5 m from the spawn, one
-- click opens it (non-interactable afterwards, it stays).
local function boss_floor()
    local h = J.new({rosie = true, dirs = {'Batmobile', 'WonderCity'}, place = 'undercity'})
    h.assert_clean('load')
    local wc = h.mod('WonderCity', 'gui').elements
    wc.skip_tribute:set(true); wc.exit_mode:set(1)
    ok(h.as('Rosie', function() return h.G.RosiePlugin.enable() end))
    local chest = h.actor('undercity', 'X1_Undercity_Chest_Attunement', 5, 0)
    chest.on_interact = function() chest.interactable = false end
    h.chest = chest
    wc.main_toggle:set(true)
    h.tracker = h.mod('WonderCity', 'core.tracker')
    h.manager = h.mod('WonderCity', 'core.task_manager')
    return h
end
local function task_name(h) return h.manager.get_current_task().name end

case('W1 a Rosie trip that starts inside the exit delay resumes the finished run on return', function()
    local h = boss_floor()
    ok(h.run_until(function() return h.tracker.done end, 30), 'the reward chest opened\n' .. h.tail(30))
    local start = h.tracker.undercity_start_time
    ok(h.run_until(function() return h.tracker.exit_trigger_time ~= nil end, 10), 'the exit delay started\n' .. h.tail(20))
    h.run(2)
    eq(#h.waypoints, 0, 'no exit cast yet (inside the 10 s exit delay)')
    -- The bag fills: Rosie's automatic trip takes the player to town and
    -- back through her portal into the same Undercity world.
    h.inventory = h.inventory or {}
    for _ = 1, 33 do h.inventory[#h.inventory + 1] = h.gear() end
    ok(h.run_until(function() return h.place.key == 'temis' end, 30), 'Rosie took the player to town\n' .. h.tail(30))
    ok(h.run_until(function() return h.place.key == 'undercity' end, 200), 'back in the Undercity\n' .. h.tail(40))
    local back = h.now
    eq(h.logged('for an Alfred trip — the run resumes on return'), 1, 'leaving for the trip is recorded as resumable')
    ok(h.logged('resuming the run', back - 1) >= 1, 'the return is a resume\n' .. h.tail(20))
    ok(h.tracker.done, 'the opened reward chest is remembered')
    eq(h.tracker.undercity_start_time, start, 'the run deadline is not restarted')
    local exited, explored = nil, false
    h.run_until(function()
        local name = task_name(h)
        if name == 'explore_undercity' or name == 'custom_explorer' then explored = true end
        if name == 'exit_undercity' then exited = exited or h.now end
        return exited ~= nil and #h.waypoints > 0 and h.waypoints[#h.waypoints].t > back
    end, 40)
    ok(exited ~= nil and exited - back <= 20, 'exit_undercity runs within 20 s of the return (' .. tostring(exited and exited - back) .. ')\n' .. h.tail(30))
    ok(not explored, 'the finished instance is not explored again')
    eq(h.logged('not interactable before our click'), 0, 'the opened chest is not waited on again')
    eq(#h.errors, 0, 'no host errors')
end)

case('W1 an exit that was CAST is final: a trip after the cast is not resumed', function()
    local h = boss_floor()
    h.mod('WonderCity', 'gui').elements.exit_undercity_delay:set(0)
    ok(h.run_until(function() return #h.waypoints > 0 end, 40), 'the exit was cast\n' .. h.tail(30))
    ok(h.tracker.exit_cast_time ~= nil, 'the cast is stamped')
    -- The cast is followed by a leave while an Alfred trip is reported: the
    -- run is over, never resumed.
    h.travel, h.casting = nil, false
    h.place = h.P.temis
    h.as('WonderCity', function() return h.tracker.observe_world(true) end)
    eq(h.tracker.resume_key, nil, 'no resume after an exit cast')
    eq(#h.errors, 0, 'no host errors')
end)

-- QQT_Warpigz_v3 WonderCity 2.2.9 (audit LOW a): an exit cast that did not
-- take us out (the channel was cut) is not a final leave: a Rosie trip that
-- then takes over inside the Undercity resumes the finished run on return.
case('W1-C a cut exit cast followed by a Rosie trip: the run resumes on return', function()
    local h = boss_floor()
    h.mod('WonderCity', 'gui').elements.exit_undercity_delay:set(0)
    ok(h.run_until(function() return #h.waypoints > 0 end, 40), 'the exit was cast\n' .. h.tail(30))
    h.travel, h.casting = nil, false -- the channel is cut: still inside
    local start = h.tracker.undercity_start_time
    h.inventory = h.inventory or {}
    for _ = 1, 33 do h.inventory[#h.inventory + 1] = h.gear() end
    ok(h.run_until(function() return h.place.key == 'temis' end, 30), 'a trip left the Undercity\n' .. h.tail(30))
    ok(h.run_until(function() return h.place.key == 'undercity' end, 200), 'back in the Undercity\n' .. h.tail(40))
    eq(h.logged('for an Alfred trip — the run resumes on return'), 1, 'the trip leave after a cut exit cast is resumable')
    ok(h.tracker.done, 'the opened reward chest is remembered')
    eq(h.tracker.undercity_start_time, start, 'the run deadline is not restarted')
    eq(#h.errors, 0, 'no host errors')
end)

if #failures > 0 then error(#failures .. ' WonderCity trip-in-exit-delay case(s) failed:\n' .. table.concat(failures, '\n')) end
print('WonderCity trip in exit delay: ' .. checks .. ' checks')
