-- QQT_Warpigz_v3 (Activities, audit 2026-09-28). Each case failed on the
-- pre-fix tree and passes after the fix:
--   Y1 [MED, Rosie yield rest <-> exit guards] real Rosie: the activity walks
--      off (another mover) so Rosie yields a boss drop 10 m away; the
--      yielded drop reads "not busy", and Reaper loot_ready / HordeDev
--      loot_guard.ready let the exit go with the drop on the ground.
--   Y2 the pending-drop hold stays bounded (a drop Rosie keeps wanting but
--      never takes): Reaper 75 s, HordeDev 120 s.
--   S1 [Coordinator request] a busy third-party Scavenger (Navigator's
--      looter) holds every loot wait like a busy Looter: Reaper loot_ready,
--      HordeDev loot_guard.ready, Pit exit_pit, Undercity can_exit; and the
--      Reaper/HordeDev hold stays bounded.
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
    if passed then print('PASS loot-waits: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL loot-waits: ' .. name .. ': ' .. tostring(err)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function with_rosie(dirs)
    local h = J.new({rosie = true, dirs = dirs, place = 'pit'})
    h.assert_clean('load')
    h.pos = h.v(0, 0)
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(30)
    return h
end
local GUARDS = {
    {'Reaper', 'core.utils', 'loot_ready', 75},
    {'HordeDev', 'core.loot_guard', 'ready', 120},
}
local function ready_fn(h, g)
    local m = h.mod(g[1], g[2])
    return function(hh) return hh.as(g[1], function() return m[g[3]]() end) end
end

case('Y1 a drop Rosie yielded to the activity\'s own walk keeps the Reaper / HordeDev exit waiting until it is taken', function()
    for _, g in ipairs(GUARDS) do
        local h = with_rosie({g[1]})
        local ready = ready_fn(h, g)
        local item = h.drop('pit', 10, 0, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_031'})
        h.run(0.5)
        -- The activity walks to its chest for 1.5 s (Rosie yields the drop),
        -- then once more briefly; afterwards it stands and asks to exit.
        local stop_at = h.now + 1.5
        local early
        h.run_until(function() return item.picked == true end, 60, function(hh)
            if hh.now < stop_at or (hh.now >= stop_at + 5 and hh.now < stop_at + 6.5) then
                hh.as(CONSUMER, function() return hh.G.pathfinder.request_move(hh.v(-12, 0)) end)
            elseif hh.now >= stop_at + 6.5 and not item.picked and not early and ready(hh) then
                early = hh.now
            end
        end)
        ok(h.logged('[Rosie pickup] Another move took the player off') >= 1, g[1] .. ': Rosie yielded the drop')
        ok(item.picked == true, g[1] .. ': the drop is taken\n' .. h.tail(10))
        eq(early, nil, g[1] .. ': exit allowed with the yielded drop on the ground (pre-fix: at t=11 s)')
        ok(h.run_until(ready, 10), g[1] .. ': ready once the drop is taken')
    end
end)

case('Y2 a drop the Looter keeps wanting but never takes holds the exit only up to the bound', function()
    for _, g in ipairs(GUARDS) do
        local h = with_rosie({g[1]})
        -- a drop the game never gives (stays listed); the fake Looter below
        -- keeps wanting it and never reports busy
        h.drop('pit', 6, 0, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_032', refuse = function() return true end})
        h.G.LooteerPlugin = {get_enabled = function() return true end,
            is_actively_looting = function() return false end, is_idle = function() return true end,
            evaluate_item = function() return true, 'wanted' end}
        local ready = ready_fn(h, g)
        local t0 = h.now
        eq(ready(h), false, g[1] .. ': a pending drop holds the exit')
        ok(h.run_until(ready, g[4] + 20), g[1] .. ': bounded')
        local after = h.now - t0
        ok(after >= g[4] - 1 and after <= g[4] + 6, string.format('%s: released after %.1f s (bound %d s)', g[1], after, g[4]))
    end
end)

local function scavenger(h, busy)
    h.G.Scavenger = {is_busy = function() return busy.value end, pause = function() end, resume = function() end}
end

case('S1 a busy Scavenger holds the Reaper / HordeDev exit (bounded) and the Pit / Undercity exits', function()
    for _, g in ipairs(GUARDS) do
        local h = J.new({dirs = {g[1]}, place = 'pit'})
        local busy = {value = true}
        scavenger(h, busy) -- no LooteerPlugin at all: the owner runs Scavenger instead
        local ready = ready_fn(h, g)
        h.run(1)
        eq(ready(h), false, g[1] .. ': busy Scavenger holds the exit (pre-fix: no Looter = ready)')
        ok(h.run_until(ready, g[4] + 20), g[1] .. ': still bounded')
        busy.value = false
        local h2 = J.new({dirs = {g[1]}, place = 'pit'})
        local busy2 = {value = true}
        scavenger(h2, busy2)
        local ready2 = ready_fn(h2, g)
        h2.run(5)
        eq(ready2(h2), false, g[1] .. ': held')
        busy2.value = false
        ok(h2.run_until(ready2, 5), g[1] .. ': ready after 3 s of an idle Scavenger')
    end
    -- Pit: exit_pit waits for the Scavenger at the glyph.
    local h = J.new({dirs = {'ArkhamAsylum', 'Batmobile'}, place = 'pit'})
    local busy = {value = true}
    scavenger(h, busy)
    h.actor('pit', 'Gizmo_Paragon_Glyph_Upgrade', 3, 3, {})
    local exit = h.mod('ArkhamAsylum', 'tasks.exit_pit')
    local tracker = h.mod('ArkhamAsylum', 'core.tracker')
    local should = function() return h.as('ArkhamAsylum', function()
        tracker.pit_start_time = h.now
        return exit.shouldExecute()
    end) end
    h.run(1)
    eq(should(), false, 'Pit: exit_pit waits for a busy Scavenger')
    busy.value = false
    eq(should(), true, 'Pit: exit_pit once it is idle')
    -- Undercity: can_exit waits for the Scavenger.
    h = J.new({dirs = {'WonderCity'}, place = 'pit'})
    busy = {value = true}
    scavenger(h, busy)
    local reward = h.mod('WonderCity', 'core.reward_phase')
    h.mod('WonderCity', 'core.tracker').done = true
    local can = function(hh) return hh.as('WonderCity', function() return reward.can_exit() end) end
    h.run(5, function(hh) eq(can(hh), false, 'Undercity: can_exit waits for a busy Scavenger') end)
    busy.value = false
    ok(h.run_until(can, 5), 'Undercity: can_exit once it is idle')
end)

print(string.format('activities loot waits v3: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(#failures .. ' activities loot-wait regression(s) failed') end
