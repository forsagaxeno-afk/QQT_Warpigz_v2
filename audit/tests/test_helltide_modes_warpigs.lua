-- HelltideRevamped Warplan contract under WarPigs (joint host, all plugins).
-- When WarPigs drives HR the effective mode must be Warplan, including when
-- WarPigs ADOPTS an HR that is already on (HR's Enable saved on across a QQT
-- reload, or left on by the user) and therefore never calls enable().
-- Runs under Lua 5.4 and LuaJIT.
SUITE_ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(SUITE_ROOT .. '/audit/tests/joint_host.lua')
local checks, cases, failures = 0, 0, {}
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
    cases = cases + 1
    local passed, err = xpcall(fn, debug.traceback)
    if passed then
        print('PASS Helltide modes (WarPigs): ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Helltide modes (WarPigs): ' .. name .. ': ' .. tostring(err))
    end
end

local WP, HR = 'WarPigs-1.0.0', 'HelltideRevamped-0.4'
local HELLTIDE_Q = 'WarPlans_QST_Helltide_TorturedGifts'
local PERSISTED = {helltide_revamped_main_toggle = true, war_pigs_main_toggle = true,
    war_pug_main_toggle = true, silent_raven_main_toggle = true}

local function el(h, dir) return assert(h.mod(dir, 'gui'), 'gui of ' .. dir).elements end
local function hr_status(h) return h.as(WP, function() return h.G.HelltideRevampedPlugin.status() end) end

-- HR saved ON with Farm selected, a QQT reload inside the active helltide with
-- a Helltide War Plan: WarPigs adopts the running HR without enable().
local function reload_in_helltide(with_quest)
    local h = J.new({place = 'helltide', persisted = J.copy(PERSISTED)})
    h.assert_clean('load')
    eq(el(h, HR).main_toggle:get(), true, 'HR Enable persisted on')
    el(h, HR).mode:set(1) -- Farm selected in HR's own menu
    h.pos = h.v(-600, 300)
    -- A Surging rupture right next to the player: Farm would route to it.
    h.starter = h.actor('helltide', 'S14_Rupture_LE_SwitchGizmo', -585, 300)
    h.ring = h.actor('helltide', 'S14_PandemoniumCrack_gizmo_holdArea', -584, 301)
    if with_quest then h.set_quests({HELLTIDE_Q}) end
    return h
end

local function rift_states_seen(h)
    local tear = h.mod(HR, 'core.hr_tear_event')
    local task = h.mod(HR, 'tasks.helltide')
    local seen = {}
    return function()
        local st = task.current_state
        if tear.is_rift_state(st) or st == 'MOVING_TO_MAIDEN' or st == 'AT_MAIDEN' then seen[#seen + 1] = st end
        return seen
    end
end

case('WarPigs cold-start adoption of an HR saved on in Farm: effective mode is warplan, no rupture', function()
    local h = reload_in_helltide(true)
    local watch = rift_states_seen(h)
    local seen
    h.run(20, function() seen = watch() end)
    h.assert_clean('adopt')
    ok(h.logged('adopted active HelltideRevampedPlugin') >= 1, 'WarPigs adopted the running HR\n' .. h.tail(40))
    eq(hr_status(h).enabled, true, 'HR still on')
    eq(hr_status(h).mode, 'warplan', 'WarPigs-driven HR reports warplan')
    eq(h.mod(HR, 'core.hr_mode').selected(), 'farm', 'the GUI value itself is untouched')
    eq(#seen, 0, 'no rupture / maiden state while WarPigs drives HR: ' .. table.concat(seen, ','))
    eq(h.logged('[RIFT] Found'), 0, 'rupture never engaged')
end)

case('control: the same HR without WarPigs ownership (no Helltide plan) runs Farm and takes the rupture', function()
    local h = reload_in_helltide(false)
    el(h, WP).main_toggle:set(false)
    h.run(8)
    eq(hr_status(h).mode, 'farm', 'manual HR runs its GUI mode')
    ok(h.logged('[RIFT] Found') >= 1, 'Farm engaged the visible rupture\n' .. h.tail(30))
end)

case('set_external API: ignored while HR is off, cleared again by disable', function()
    local h = J.new({place = 'helltide'})
    local api = h.G.HelltideRevampedPlugin
    local mode = h.mod(HR, 'core.hr_mode')
    eq(h.as(WP, function() return api.set_external(true) end), false, 'HR off: not marked')
    eq(mode.is_external(), false)
    el(h, HR).main_toggle:set(true)
    eq(h.as(WP, function() return api.set_external(true) end), true)
    eq(mode.effective(), 'warplan')
    h.as(WP, function() api.disable() end)
    eq(mode.is_external(), false, 'disable clears the external mark')
end)

print(string.format('Helltide modes (WarPigs): %d cases, %d checks, %d failures', cases, checks, #failures))
if #failures > 0 then error('Helltide modes (WarPigs) failures:\n' .. table.concat(failures, '\n')) end
print('PASS: test_helltide_modes_warpigs (' .. cases .. ' cases)')
