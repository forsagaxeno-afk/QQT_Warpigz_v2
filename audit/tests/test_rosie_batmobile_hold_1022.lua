-- QQT_Warpigz_v3 Rosie 1.0.22 (Auditor finding, Rosie 1.0.20 <-> Batmobile 2.2.1):
-- lifecycle.hold_peers paused Batmobile once per trip. Batmobile keeps one
-- shared pause flag, so HR's patrol_move resume, an activity, or Batmobile's
-- own 1 s kept-pause fallback lifted that pause mid-trip and Batmobile drove
-- against Rosie's walks in town for the rest of the trip; at the trip end
-- release_peers resumed a pause another caller had taken since.
-- Rosie now pauses a Batmobile that is not paused whenever the trip holds its
-- peers (at most every REPAUSE_EVERY s, the lift logged once per trip), and
-- resumes at the trip end only a pause that is still its own.
-- Real Batmobile + real Rosie in the joint host. Runs under Lua 5.4 and LuaJIT.
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
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
    if passed then print('PASS batmobile hold: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL batmobile hold: ' .. name .. ': ' .. tostring(err)) end
end
local BAT, ROSIE = 'Batmobile', 'alfred_the_butler'
local LIFT_LOG = 'Another addon resumed Batmobile during the town trip'
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function new()
    local h = J.new({rosie = true, dirs = {BAT}, place = 'pit'})
    h.assert_clean('load')
    h.instrument_exports()
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(2)
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'Rosie enabled')
    h.run(1)
    return h, h.mod(BAT, 'core.navigator')
end
local function st(h) return h.as(CONSUMER, function() return h.G.AlfredTheButlerPlugin.get_status() end) end
local function lifecycle(h) return h.mod('Rosie', 'rosie.private.town.core.lifecycle') end
-- The re-pause bound (0.5 s; a constant here so the old code fails on behaviour).
local function every(h) return lifecycle(h).REPAUSE_EVERY or 0.5 end
local function fill_bag(h, n)
    h.inventory = {}
    for i = 1, n or 25 do h.inventory[i] = h.gear() end
end
local function start_trip(h)
    local result = {}
    local accepted, why = h.as(CONSUMER, function()
        return h.G.AlfredTheButlerPlugin.trigger_tasks_with_teleport('Consumer', function(err, res)
            result.err, result.res, result.done = err, res, true
        end)
    end)
    eq(accepted, true, 'trip accepted (' .. tostring(why) .. ')')
    return result
end
-- Another plugin's call on the shared Batmobile (from Batmobile's context,
-- as the Auditor's repro does).
local function bat(h, name, caller, ...)
    local args = {...}
    return h.as(BAT, function() return h.G.BatmobilePlugin[name](caller, (table.unpack or unpack)(args)) end)
end
local function calls(h, name, caller, from)
    return h.count(h.bm_calls, function(c) return c.name == name and c.caller == caller and c.t >= (from or -math.huge) end)
end
-- The trip is in Temis and Rosie drives it.
local function to_town(h, result)
    ok(h.run_until(function() return h.place == h.P.temis end, 60), 'the trip reaches Temis\n' .. h.tail())
    h.run(0.5)
    ok(not result.done and st(h).running == true, 'the trip still runs in town')
end
local function finish(h, result)
    ok(h.run_until(function() return result.done end, 200), 'the trip ends\n' .. h.tail())
    eq(st(h).outcome, 'completed', 'trip completed\n' .. h.tail())
end

case('another addon resumes Batmobile in town: Rosie pauses it again, logs once per trip, resumes its own pause after', function()
    local h, nav = new()
    eq(nav.paused, false, 'Batmobile runs before the trip')
    fill_bag(h, 25)
    local r = start_trip(h)
    eq(nav.paused, true, 'paused at the request')
    eq(calls(h, 'pause', ROSIE), 1)
    to_town(h, r)
    -- HR's patrol_move: resume + a waypoint.
    bat(h, 'resume', 'helltide_revamped')
    eq(nav.paused, false, 'the foreign resume lifts the shared flag')
    local t1 = h.now
    ok(h.run_until(function() return nav.paused == true end, every(h) + 0.3),
        'Rosie pauses Batmobile again within REPAUSE_EVERY s\n' .. h.tail())
    ok(h.now - t1 <= every(h) + 0.2, 're-paused after ' .. (h.now - t1) .. ' s')
    eq(h.logged(LIFT_LOG), 1, 'the lift is logged')
    -- A second lift later in the same trip: paused again, not logged again.
    h.run(1)
    ok(st(h).running == true and h.place == h.P.temis, 'still in town')
    bat(h, 'resume', 'reaper')
    ok(h.run_until(function() return nav.paused == true end, every(h) + 0.3), 'paused again')
    finish(h, r)
    eq(h.logged(LIFT_LOG), 1, 'logged once per trip')
    eq(calls(h, 'pause', ROSIE), 3, 'the request pause plus one re-pause per lift')
    eq(nav.paused, false, "Rosie's own pause is resumed after the trip")
    eq(calls(h, 'resume', ROSIE), 1, 'resumed once')
    -- The next trip logs its own lift.
    fill_bag(h, 3)
    local r2 = start_trip(h)
    to_town(h, r2)
    bat(h, 'resume', 'helltide_revamped')
    ok(h.run_until(function() return nav.paused == true end, every(h) + 0.3), 'paused on trip 2')
    finish(h, r2)
    eq(h.logged(LIFT_LOG), 2, 'one line for each trip')
    eq(nav.paused, false)
    h.assert_clean('lift')
end)

case('a Reaper-style route started in town is not driven by Batmobile while the trip runs', function()
    local h, nav = new()
    local lp = h.mod(BAT, 'core.long_path')
    fill_bag(h, 25)
    local r = start_trip(h)
    to_town(h, r)
    -- Reaper LONG_PATHING: resume + navigate_long_path, Batmobile drives it itself.
    bat(h, 'resume', 'reaper')
    eq(bat(h, 'navigate_long_path', 'reaper', h.v(2600, -520)), true, 'a route in Temis')
    eq(nav.paused, false)
    local t0 = h.now
    local quiet_from = t0 + every(h) + 0.2
    ok(h.run_until(function() return r.done end, 200), 'the trip ends\n' .. h.tail())
    local t_end = h.now
    eq(st(h).outcome, 'completed', 'trip completed\n' .. h.tail())
    local driven = h.count(h.moves, function(m) return m.owner == BAT and m.t > quiet_from and m.t < t_end end)
    eq(driven, 0, 'no Batmobile move in town once Rosie paused it again')
    ok(calls(h, 'pause', ROSIE) >= 2, 're-paused')
    eq(lp.navigating, false, 'the route is dropped with the world change')
    h.assert_clean('route')
end)

case('a plugin that resumes Batmobile every frame: re-pauses are bounded to one per REPAUSE_EVERY', function()
    local h, nav = new()
    fill_bag(h, 25)
    local r = start_trip(h)
    to_town(h, r)
    local t0 = h.now
    h.run(3, function() bat(h, 'resume', 'helltide_revamped') end)
    ok(st(h).running == true, 'still servicing')
    local repauses = calls(h, 'pause', ROSIE, t0)
    ok(repauses >= 4, 'Rosie keeps pausing it: ' .. repauses)
    ok(repauses <= math.floor(3 / every(h)) + 1, 'bounded: ' .. repauses)
    ok(h.run_until(function() return nav.paused == true end, every(h) + 0.3), 'paused once it stops')
    finish(h, r)
    eq(h.logged(LIFT_LOG), 1, 'logged once')
    eq(nav.paused, false, "Rosie's own pause is resumed after the trip")
    h.assert_clean('bounded')
end)

case("a pause another addon takes after lifting Rosie's is left to it at the trip end", function()
    local h, nav = new()
    fill_bag(h, 25)
    local r = start_trip(h)
    to_town(h, r)
    bat(h, 'resume', 'arkham_asylum')
    -- Checked after the trip end, so the old code also reaches the release.
    local repaused = h.run_until(function() return nav.paused == true end, every(h) + 0.3)
    -- Lifted again inside the bound: Rosie sees its pause gone and waits.
    bat(h, 'resume', 'arkham_asylum')
    h.frame()
    eq(nav.paused, false, 'the re-pause waits for REPAUSE_EVERY')
    -- The other addon then pauses Batmobile for itself.
    bat(h, 'pause', 'arkham_asylum')
    local resumes = calls(h, 'resume', ROSIE)
    finish(h, r)
    eq(nav.paused, true, "the other addon's pause is kept after the trip")
    eq(calls(h, 'resume', ROSIE), resumes, 'Rosie does not resume a pause it does not own')
    ok(repaused, "Rosie re-paused after the first lift")
    h.assert_clean('foreign pause')
end)

case('Batmobile paused by the requester before the trip and never lifted: Rosie neither pauses nor resumes it', function()
    local h, nav = new()
    -- WonderCity / Arkham pause Batmobile before they request the trip.
    bat(h, 'pause', 'arkham_asylum')
    fill_bag(h, 25)
    local r = start_trip(h)
    to_town(h, r)
    finish(h, r)
    eq(calls(h, 'pause', ROSIE), 0, 'no Rosie pause')
    eq(calls(h, 'resume', ROSIE), 0, 'no Rosie resume')
    eq(nav.paused, true, "the requester's pause is kept")
    eq(h.logged(LIFT_LOG), 0)
    -- Lifted mid-trip: the pause Rosie then takes is its own and ends with the trip.
    fill_bag(h, 3)
    local r2 = start_trip(h)
    to_town(h, r2)
    bat(h, 'resume', 'helltide_revamped')
    ok(h.run_until(function() return nav.paused == true end, every(h) + 0.3), 'paused by Rosie')
    eq(calls(h, 'pause', ROSIE), 1)
    finish(h, r2)
    eq(nav.paused, false, "Rosie's pause is resumed after the trip")
    eq(calls(h, 'resume', ROSIE), 1)
    eq(h.logged(LIFT_LOG), 0, "not Rosie's pause that was lifted: no line")
    h.assert_clean('requester pause')
end)

case('a Batmobile that refuses a re-pause never raises inside the trip tick', function()
    local h, nav = new()
    fill_bag(h, 25)
    local r = start_trip(h)
    to_town(h, r)
    local api = h.G.BatmobilePlugin
    local real = api.pause
    api.pause = function(caller)
        if caller == ROSIE then error('boom') end
        return real(caller)
    end
    bat(h, 'resume', 'helltide_revamped')
    h.run(2)
    api.pause = real
    eq(h.logged('Batmobile refused the town trip pause'), 1, 'logged once')
    ok(st(h).running == true or r.done, 'Rosie keeps running')
    finish(h, r)
    ok(nav.paused == false, 'Batmobile left unpaused')
    h.assert_clean('refusal')
end)

print(string.format('batmobile hold: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
