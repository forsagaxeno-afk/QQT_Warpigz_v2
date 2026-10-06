-- QQT_Warpigz_v3 (Activities self-review: unbounded waits). Each case failed
-- on the pre-fix tree and passes after the fix:
--   L1 HordeDev loot_guard.ready: a Looter busy 2 s / idle 1 s over and over
--      (never the 3 s of quiet) re-armed the 120 s bound on every quiet
--      sample, so the chest phase / exit waited forever.
--   L2 Reaper loot_ready: the same flapping Looter held the lair exit forever
--      (75 s bound re-armed).
--   L3 Pit forced exit (reset timer ran out): a live Alfred status that never
--      clears held the exit forever (WonderCity already capped it at 120 s).
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local checks, failures = 0, {}
local function ok(value, message)
    if not value then error(message or 'expected a true value', 2) end
    checks = checks + 1
end
local function case(name, fn)
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS activities-bounds: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL activities-bounds: ' .. name .. ': ' .. tostring(err)) end
end
-- busy 2 s, idle 1 s, forever.
local function flapping(h)
    local t0 = h.now
    local function busy() return (h.now - t0) % 3 < 2 end
    return {get_enabled = function() return true end,
        is_actively_looting = function() return busy() end,
        is_idle = function() return not busy() end}
end
local function released_within(h, seconds, fn)
    local t0 = h.now
    if h.run_until(fn, seconds) then return h.now - t0 end
    return nil
end

case('L1 HordeDev: a flapping Looter holds the chest/exit handoff at most ~120 s', function()
    local h = J.new({dirs = {'HordeDev'}, place = 'pit'})
    h.G.LooteerPlugin = flapping(h)
    local guard = h.mod('HordeDev', 'core.loot_guard')
    local after = released_within(h, 200, function(hh) return hh.as('HordeDev', function() return guard.ready() end) end)
    ok(after ~= nil, 'loot_guard.ready never true in 200 s (pre-fix: bound re-armed by each quiet sample)')
    ok(after >= 119 and after <= 125, string.format('released after %.1f s', after))
    ok(h.logged('[HordeDev] Looter busy for 120s') == 1, 'one log line')
end)

case('L2 Reaper: a flapping Looter holds the lair exit at most ~75 s', function()
    local h = J.new({dirs = {'Reaper'}, place = 'pit'})
    h.G.LooteerPlugin = flapping(h)
    local utils = h.mod('Reaper', 'core.utils')
    local after = released_within(h, 200, function(hh) return hh.as('Reaper', function() return utils.loot_ready() end) end)
    ok(after ~= nil, 'loot_ready never true in 200 s (pre-fix: bound re-armed by each quiet sample)')
    ok(after >= 74 and after <= 80, string.format('released after %.1f s', after))
end)

case('L3 Pit: past the reset timer a never-clearing Alfred holds the forced exit at most ~120 s', function()
    local h = J.new({dirs = {'ArkhamAsylum', 'Batmobile'}, place = 'pit'})
    h.mod('ArkhamAsylum', 'gui').elements.main_toggle:set(true)
    h.run(2)
    local alfred = h.mod('ArkhamAsylum', 'tasks.alfred')
    alfred.is_busy = function() return true end -- positive, never-clearing Alfred evidence
    alfred.Execute = function() alfred.status = 'waiting for Alfred' end
    local tracker = h.mod('ArkhamAsylum', 'core.tracker')
    tracker.pit_start_time = h.now - 10000
    local waypoints, resets = #h.waypoints, h.resets
    local after = released_within(h, 200, function(hh) return #hh.waypoints > waypoints or hh.resets > resets end)
    ok(after ~= nil, 'forced exit never ran in 200 s (pre-fix: Alfred held it forever)\n' .. h.tail(8))
    ok(after >= 119 and after <= 135, string.format('forced exit after %.1f s', after))
    ok(h.logged('[arkham] run timeout: Alfred busy for') == 1, 'one log line\n' .. h.tail(8))
end)

print(string.format('activities bounds v3: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(#failures .. ' activities bound regression(s) failed') end
