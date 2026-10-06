-- QQT_Warpigz_v3 WonderCity 2.2.7: W3 of audit/reviews/sweep_2026-09-28.md
-- (S3 F9). exit_undercity cast the exit teleport with an elite pack next
-- to the player; the rotation's evade broke the channel and the exit
-- re-cast every 5 s with no cap. Now a non-forced exit holds while a live
-- enemy is within 8 m (at most 20 s from the exit trigger), and after 4
-- casts without a world change it backs off 30 s (logged). A forced exit
-- (run timeout) casts at once.
-- Joint host: real Batmobile + WonderCity. A cut channel is modelled by
-- clearing the host's travel (the rotation's evade). Runs under Lua 5.4 and
-- LuaJIT.
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
    if passed then print('PASS WonderCity exit enemies: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL WonderCity exit enemies: ' .. name .. ': ' .. tostring(err)) end
end

local J = dofile(SUITE .. '/audit/tests/joint_host.lua')

-- The reward chest opens; 3 enemies stand 6 m from the player (out of the
-- rotation's reach); the exit delay is 0 so the exit follows the 3 s quiet.
local function reward_done(o)
    o = o or {}
    local h = J.new({dirs = {'Batmobile', 'WonderCity'}, place = 'undercity'})
    h.assert_clean('load')
    local wc = h.mod('WonderCity', 'gui').elements
    wc.skip_tribute:set(true); wc.exit_mode:set(1); wc.exit_undercity_delay:set(o.delay or 0)
    local chest = h.actor('undercity', 'X1_Undercity_Chest_Attunement', 5, 0)
    chest.on_interact = function() chest.interactable = false end
    wc.main_toggle:set(true)
    h.tracker = h.mod('WonderCity', 'core.tracker')
    ok(h.run_until(function() return h.tracker.done end, 30), 'the reward chest opened\n' .. h.tail(20))
    h.enemies = {}
    for i = 1, 3 do
        h.enemies[i] = h.actor('undercity', 'X1_Undercity_Elite_Joint', h.pos:x() + 6, h.pos:y() + (i - 2),
            {enemy = true, elite = true, health = o.immortal and 1e9 or 100, reach = 0})
    end
    return h
end
local function casts(h, since)
    return h.count(h.waypoints, function(w) return w.t >= (since or 0) end)
end
-- Cut every channel (the rotation's evade), for `seconds`.
local function cut_channels(h, seconds)
    h.run(seconds, function() if h.travel and h.travel.phase == 'channel' then h.travel, h.casting = nil, false end end)
end

case('W3-A/B no exit cast while an enemy lives within 8 m; exactly one cast after they die', function()
    local h = reward_done()
    h.run(8)
    eq(casts(h), 0, 'no exit cast into the fight')
    ok(h.tracker.exit_trigger_time ~= nil, 'the exit is due')
    for _, e in ipairs(h.enemies) do e.health = 0 end
    local mark = h.now
    ok(h.run_until(function() return casts(h) > 0 end, 5), 'the exit is cast once the enemies are dead\n' .. h.tail(20))
    ok(h.run_until(function() return h.place ~= h.P.undercity end, 10), 'the player left')
    eq(casts(h, mark), 1, 'exactly one cast')
    eq(#h.errors, 0, 'no host errors')
end)

case('W3-C immortal enemies: the exit is cast within 20 s, at most 4 casts, then a logged 30 s back-off', function()
    local h = reward_done({immortal = true})
    local due
    ok(h.run_until(function() due = due or h.tracker.exit_trigger_time; return casts(h) > 0 end, 30),
        'the exit is cast anyway\n' .. h.tail(20))
    ok(h.waypoints[1].t - due <= 20.5, string.format('cast within 20 s of the exit trigger (%.1f)', h.waypoints[1].t - due))
    cut_channels(h, 40)
    ok(casts(h) <= 4, 'at most 4 casts before the back-off, got ' .. casts(h))
    eq(h.logged('backing off 30s'), 1, 'the back-off is logged once')
    local before = casts(h)
    cut_channels(h, 20)
    ok(casts(h) > before, 'the exit is cast again after the back-off (never parked)')
    eq(#h.errors, 0, 'no host errors')
end)

case('W3-D a forced exit (run timeout) casts at once with enemies next to the player', function()
    local h = reward_done({immortal = true})
    h.tracker.undercity_start_time = h.now - 10000
    h.tracker.reward_grace_until = h.now - 1 -- the 45 s reward grace is over
    local mark = h.now
    ok(h.run_until(function() return casts(h) > 0 end, 2), 'the forced exit is cast\n' .. h.tail(20))
    ok(h.waypoints[1].t - mark <= 1, 'at once')
end)

-- QQT_Warpigz_v3 WonderCity 2.2.8 (3.3.13 review #3).
case('W3-E with an exit delay of 25 s the enemy hold still applies after the delay', function()
    local h = reward_done({immortal = true, delay = 25})
    local due
    ok(h.run_until(function() due = due or h.tracker.exit_trigger_time; return due ~= nil end, 10), 'the exit is due')
    h.run(25 + 8 - (h.now - due))
    eq(casts(h), 0, 'no exit cast into the fight 8 s after the delay')
    ok(h.run_until(function() return casts(h) > 0 end, 20), 'cast within the 20 s hold after the delay\n' .. h.tail(20))
end)

case('W3-F a forced exit during the re-cast back-off is cast at once', function()
    local h = reward_done({immortal = true})
    ok(h.run_until(function() return casts(h) > 0 end, 30), 'first cast')
    cut_channels(h, 25)
    ok(h.logged('backing off 30s') == 1, 'in the back-off\n' .. h.tail(20))
    local before = casts(h)
    h.tracker.undercity_start_time = h.now - 10000
    h.tracker.reward_grace_until = h.now - 1
    ok(h.run_until(function() return casts(h) > before end, 6),
        'the forced exit is not held by the back-off\n' .. h.tail(20))
end)

if #failures > 0 then error(#failures .. ' WonderCity exit enemies case(s) failed:\n' .. table.concat(failures, '\n')) end
print('WonderCity exit enemies: ' .. checks .. ' checks')
