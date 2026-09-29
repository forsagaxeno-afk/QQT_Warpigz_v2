-- QQT_Warpigz_v3 WonderCity 2.2.7: W5 of audit/reviews/sweep_2026-09-28.md
-- (ranked #16). WonderCity clicked the reward chest; an Alfred trip took the
-- player out before the opening was confirmed. On return (a resume) the
-- chest reads non-interactable before goto_chest's (new) first click, and
-- it waited LOCKED_WAIT (10 s) "unless it unlocks" although our own click
-- is on record for this floor. Now that click confirms it like a fresh
-- click (CONFIRM_SECONDS).
-- Joint host: real Batmobile + WonderCity, the C1 Alfred stand-in (its
-- with-teleport trip returns to the same Undercity spot).
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
    if passed then print('PASS WonderCity chest resume: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL WonderCity chest resume: ' .. name .. ': ' .. tostring(err)) end
end

local J = dofile(SUITE .. '/audit/tests/joint_host.lua')
local CONSUMER = {name = 'Consumer', dir = SUITE .. '/audit/tests/', loaded = {}}

case('W5 a chest clicked 0.5 s before an Alfred trip is confirmed within 3 s of the resume (was 10 s)', function()
    local h = J.new({dirs = {'Batmobile', 'WonderCity'}, place = 'undercity'})
    h.assert_clean('load')
    local wc = h.mod('WonderCity', 'gui').elements
    wc.skip_tribute:set(true); wc.exit_mode:set(1)
    local chest = h.actor('undercity', 'X1_Undercity_Chest_Attunement', 5, 0)
    local clicked
    chest.on_interact = function()
        chest.interactable = false
        clicked = clicked or h.now
    end
    wc.main_toggle:set(true)
    local tracker = h.mod('WonderCity', 'core.tracker')
    ok(h.run_until(function() return clicked ~= nil end, 20), 'the chest was clicked\n' .. h.tail(20))
    h.run(0.5)
    ok(not tracker.done, 'not confirmed yet')
    -- The bag fills: another caller's with-teleport Alfred trip.
    h.alfred.need_trigger, h.alfred.inventory_full = true, true
    ok(h.as(CONSUMER, function()
        return h.G.AlfredTheButlerPlugin.trigger_tasks_with_teleport('Consumer', function() end)
    end), 'trip queued')
    ok(h.run_until(function() return h.place.key == 'temis' end, 10), 'to town\n' .. h.tail(20))
    ok(h.run_until(function() return h.place.key == 'undercity' end, 30), 'back\n' .. h.tail(20))
    local back = h.now
    ok(h.logged('resuming the run', back - 1) >= 1, 'a resume\n' .. h.tail(20))
    ok(h.run_until(function() return tracker.done end, 15), 'confirmed\n' .. h.tail(20))
    ok(h.now - back <= 3, string.format('confirmed within 3 s of the return (%.1f s)', h.now - back))
    eq(h.logged('treating it as already opened in 10s'), 0, 'no 10 s re-check')
    eq(h.count(h.interactions, function(r) return r.skin == 'X1_Undercity_Chest_Attunement' end), 1, 'one click')
    eq(#h.errors, 0, 'no host errors')
end)

if #failures > 0 then error(#failures .. ' WonderCity chest resume case(s) failed:\n' .. table.concat(failures, '\n')) end
print('WonderCity chest resume: ' .. checks .. ' checks')
