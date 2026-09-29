-- QQT_Warpigz_v3 WonderCity 2.2.7: contract C-boss
-- (audit/reviews/sweep_2026-09-28.md §2.4). WonderCityPlugin.get_status()
-- publishes boss_fight = inside the Undercity and (a live boss in the reward
-- scan, or kill_monster's 10 s boss gate). Rosie reads it to defer her
-- automatic trip during a live boss fight. The gate's tail ends at once when
-- the kill is observed (the trip may start right after the kill).
-- Joint host: real Batmobile + WonderCity. Runs under Lua 5.4 and LuaJIT.
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
    if passed then print('PASS WonderCity boss_fight: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL WonderCity boss_fight: ' .. name .. ': ' .. tostring(err)) end
end

local J = dofile(SUITE .. '/audit/tests/joint_host.lua')

local function boss_floor()
    local h = J.new({dirs = {'Batmobile', 'WonderCity'}, place = 'undercity'})
    h.assert_clean('load')
    local wc = h.mod('WonderCity', 'gui').elements
    wc.skip_tribute:set(true); wc.boss_delay:set(0)
    wc.main_toggle:set(true)
    h.boss = h.actor('undercity', 'X1_Undercity_Lacuni_Boss', 20, 0, {enemy = true, boss = true, health = 300})
    return h
end
local function status(h)
    return h.as('WonderCity', function() return h.G.WonderCityPlugin.get_status() end)
end

case('C-boss boss_fight is true while the district boss lives and false right after the kill', function()
    local h = boss_floor()
    h.run(1)
    eq(status(h).boss_fight, true, 'a live boss on the floor is a boss fight')
    local fight_seen, killed = 0, nil
    ok(h.run_until(function()
        if status(h).boss_fight then fight_seen = fight_seen + 1 end
        if (h.boss.health or 0) <= 0 then killed = killed or h.now end
        return killed ~= nil and h.now - killed >= 1.5
    end, 60), 'the boss died\n' .. h.tail(20))
    ok(fight_seen > 10, 'boss_fight held during the fight')
    eq(status(h).boss_fight, false, 'boss_fight clears within 1.5 s of the kill (the 10 s gate tail is not a fight)')
    eq(#h.errors, 0, 'no host errors')
end)

case('C-boss a boss that leaves the actor stream keeps boss_fight for the 10 s gate only', function()
    local h = boss_floor()
    h.boss.pos = h.v(40, 0) -- out of the rotation's reach
    h.run(1)
    eq(status(h).boss_fight, true)
    h.remove_actor(h.boss)
    h.run(2)
    eq(status(h).boss_fight, true, 'kill_monster saw it 2 s ago: still a fight')
    h.run(10)
    eq(status(h).boss_fight, false, 'bounded by the gate')
end)

case('C-boss outside the Undercity boss_fight is false; the field is always a boolean', function()
    local h = J.new({dirs = {'Batmobile', 'WonderCity'}, place = 'kurast'})
    h.mod('WonderCity', 'gui').elements.main_toggle:set(true)
    h.run(1)
    eq(status(h).boss_fight, false)
end)

-- QQT_Warpigz_v3 WonderCity 2.2.9 (audit LOW c): a disabled WonderCity does
-- not hold Rosie's trip (Arkham and Reaper gate the field the same way).
case('C-boss a disabled WonderCity reports no boss fight', function()
    local h = boss_floor()
    h.run(1)
    eq(status(h).boss_fight, true, 'enabled: a live boss is a boss fight')
    h.mod('WonderCity', 'gui').elements.main_toggle:set(false)
    h.run(0.5)
    eq(status(h).boss_fight, false, 'disabled: no boss fight')
end)

if #failures > 0 then error(#failures .. ' WonderCity boss_fight case(s) failed:\n' .. table.concat(failures, '\n')) end
print('WonderCity boss_fight: ' .. checks .. ' checks')
