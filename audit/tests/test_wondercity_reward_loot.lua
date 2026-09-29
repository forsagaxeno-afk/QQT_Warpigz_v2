-- QQT_Warpigz_v3 WonderCity 2.2.7: W4 of audit/reviews/sweep_2026-09-28.md
-- (S3 F4/F5). The exit after the reward chest only needed 3 s of loot quiet:
-- reward loot beyond Rosie's pickup distance (2 m shipped) was left behind,
-- and after a death next to the opened chest the run exited from the
-- checkpoint. Now wanted reward loot within 12 m of the chest / boss holds
-- the exit and tasks/loot_reward walks to it (bounded: 25 s from the
-- opening, 5 s without progress skips an item).
-- Joint host: real Batmobile + WonderCity + real Rosie (pickup 2 m).
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
    if passed then print('PASS WonderCity reward loot: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL WonderCity reward loot: ' .. name .. ': ' .. tostring(err)) end
end

local J = dofile(SUITE .. '/audit/tests/joint_host.lua')

local MYTHIC = {name = 'Helm_Unique_Generic_005', sno = 2647147, rarity = 6, ancestral = true, ga = 1,
    affixes = {{affix_name_hash = 2662414, get_name = function() return 'Helm_Unique_Generic_005' end},
        {affix_name_hash = 2628989, get_name = function() return 'S14_Mythic_UniquePotency' end}}}
local GA2 = {name = 'Helm_Legendary_Chaos', rarity = 5, ancestral = true, ga = 2}

-- The boss floor after the kill: the reward chest 12 m from the spawn; the
-- click opens it and drops `loot` ({dx, dy, fields}) around it.
local function boss_floor(loot)
    local h = J.new({rosie = true, dirs = {'Batmobile', 'WonderCity'}, place = 'undercity'})
    h.assert_clean('load')
    local wc = h.mod('WonderCity', 'gui').elements
    wc.skip_tribute:set(true); wc.exit_mode:set(1); wc.exit_undercity_delay:set(0)
    h.mod('Rosie', 'rosie.private.town.gui').elements.use_keybind:set(true) -- no automatic trips
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(2)
    ok(h.as('Rosie', function() return h.G.RosiePlugin.enable() end))
    local chest = h.actor('undercity', 'X1_Undercity_Chest_Attunement', 12, 0)
    h.items_dropped = {}
    chest.on_interact = function()
        if chest.interactable == false then return end
        chest.interactable = false
        h.opened_at = h.now
        for _, l in ipairs(loot) do
            local fields = {}
            for k, val in pairs(l[3]) do fields[k] = val end
            h.items_dropped[#h.items_dropped + 1] = h.drop('undercity', 12 + l[1], l[2], fields)
        end
        if h.on_open then h.on_open() end
    end
    h.chest = chest
    wc.main_toggle:set(true)
    h.tracker = h.mod('WonderCity', 'core.tracker')
    return h
end
local function exit_cast(h) return #h.waypoints > 0 end

-- QQT_Warpigz_v3 WonderCity 2.2.8 (3.3.13 review #5): reward_loot_target
-- scanned the ground items and called evaluate_item up to 3 times per tick
-- (loot_reward.shouldExecute, Execute, can_exit). One scan per tick now.
case('W4-D the reward-loot scan asks the Looter at most once per item per tick', function()
    local h = boss_floor({{0, 3.5, MYTHIC}})
    ok(h.run_until(function() return h.opened_at ~= nil end, 30), 'the chest opened\n' .. h.tail(20))
    local looter = h.G.LooteerPlugin
    local real, calls = looter.evaluate_item, 0
    looter.evaluate_item = function(...) calls = calls + 1; return real(...) end
    local worst = 0
    h.run(10, function()
        if calls > worst then worst = calls end
        calls = 0
    end)
    looter.evaluate_item = real
    print('  evaluate_item calls in the worst tick (1 item): ' .. worst)
    ok(worst >= 1, 'the item is evaluated')
    ok(worst <= 1, 'evaluate_item calls per tick for one item: ' .. worst)
end)

case('W4-A a Mythic 3.5 m and a GA2 4 m from the chest (pickup 2 m) are picked up before the exit cast', function()
    local h = boss_floor({{0, 3.5, MYTHIC}, {0, -4, GA2}})
    ok(h.run_until(function() return h.opened_at ~= nil end, 30), 'the chest opened\n' .. h.tail(20))
    ok(h.run_until(exit_cast, 60), 'the exit was cast\n' .. h.tail(30))
    for i, item in ipairs(h.items_dropped) do
        ok(item.picked == true, 'reward item ' .. i .. ' (' .. item.name .. ') picked before the exit cast\n' .. h.tail(30))
    end
    ok(h.waypoints[1].t - h.opened_at <= 30, 'the exit follows within 30 s')
    eq(#h.errors, 0, 'no host errors')
end)

case('W4-B a death 0.2 s after the chest opens, revive 100 m away: the bot walks back and picks the Mythic', function()
    local h = boss_floor({{0, 3.5, MYTHIC}})
    h.P.undercity.box = {-100, 260, -60, 60}
    h.P.undercity.spawn = h.v(-88, 0) -- the checkpoint, 100 m from the chest
    h.on_open = function() h.at(0.2, function() h.dead = true end) end
    ok(h.run_until(function() return h.opened_at ~= nil end, 30), 'the chest opened\n' .. h.tail(20))
    ok(h.run_until(exit_cast, 90), 'the exit was cast\n' .. h.tail(30))
    ok(h.revives >= 1, 'the player revived')
    ok(h.items_dropped[1].picked == true, 'the Mythic was picked up before the exit\n' .. h.tail(30))
    eq(#h.errors, 0, 'no host errors')
end)

case('W4-C an item out of reach (behind a ledge, 2.6 m at best): the exit still fires, bounded', function()
    local h = boss_floor({{0, 5, MYTHIC}})
    -- a walled pocket: 2.6 m at best; the Looter (2 m) never gets it, the walk stalls
    h.P.undercity.walls = {{9, 15, 2.4, 4.6}, {9, 15, 5.4, 9}, {9, 11.2, 2.4, 9}, {12.8, 15, 2.4, 9}}
    ok(h.run_until(function() return h.opened_at ~= nil end, 30), 'the chest opened\n' .. h.tail(20))
    ok(h.run_until(exit_cast, 60), 'the exit was cast\n' .. h.tail(30))
    ok(h.logged('reward loot item:') + h.logged('reward loot not picked up within') >= 1, 'the give-up is logged\n' .. h.tail(30))
    print(string.format('  W4-C exit %.1f s after the opening', h.waypoints[1].t - h.opened_at))
    ok(h.waypoints[1].t - h.opened_at <= 25 + 5 + 3 + 1, 'bounded by the 25 s cap + 5 s no-progress + 3 s quiet ('
        .. string.format('%.1f', h.waypoints[1].t - h.opened_at) .. ' s)')
    eq(#h.errors, 0, 'no host errors')
end)

if #failures > 0 then error(#failures .. ' WonderCity reward loot case(s) failed:\n' .. table.concat(failures, '\n')) end
print('WonderCity reward loot: ' .. checks .. ' checks')
