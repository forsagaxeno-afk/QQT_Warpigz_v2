-- QQT_Warpigz_v3 (rc.2, Q2 + Q3) joint host: standalone Helltide farming (HR in
-- Farm mode + real Rosie + real Batmobile, WarPigs off). The player stands in
-- a golden tear until it closes; Rosie's pickup is paused by
-- 'HelltideRevamped' meanwhile and collects the drop once the tear is closed.
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
        print('PASS Helltide tears (joint): ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Helltide tears (joint): ' .. name .. ': ' .. tostring(err))
    end
end

local WP, HR = 'WarPigs', 'HelltideRevamped'
local function el(h, dir) return assert(h.mod(dir, 'gui'), 'gui of ' .. dir).elements end
local function rosie_status(h) return h.as(WP, function() return h.G.LooteerPlugin.status() end) end

case('Q2 standalone HR + Rosie: stands in the tear until it closes, pickup paused by HR, drop taken after', function()
    local h = J.new({place = 'helltide', rosie = true, persisted = {helltide_revamped_main_toggle = true}})
    h.assert_clean('load')
    el(h, WP).main_toggle:set(false) -- plain farming: no WarPigs
    el(h, HR).mode:set(1)            -- Farm (tears)
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(12)
    eq(h.as('Rosie', function() return h.G.RosiePlugin.enable() end), true, 'Rosie enabled')
    h.pos = h.v(-600, 300)
    h.actor('helltide', 'S14_Rupture_SMP_SwitchGizmo', -585, 300)
    h.actor('helltide', 'S14_PandemoniumCrack_gizmo_holdArea', -585, 300)
    local tear = h.actor('helltide', 'S14_Rupture_SMP_Chargeable', -583, 301)
    local task = h.mod(HR, 'tasks.helltide')
    ok(h.run_until(function()
        return task.current_state == 'RIFT_CLOSE_TEARS' and h.pos:dist_to(tear.pos) <= 1.05
    end, 30), 'HR walked onto the golden tear\n' .. h.tail(30))
    -- A drop lands 8 m away while the tear is open.
    h.drop('helltide', tear.pos:x() + 6, tear.pos:y() + 5)
    local max_d = 0
    h.run(20, function()
        local d = h.pos:dist_to(tear.pos)
        if d > max_d then max_d = d end
    end)
    ok(max_d <= 2.0, string.format('stayed inside the circle (max %.2f m from the glint)', max_d))
    eq(task.current_state, 'RIFT_CLOSE_TEARS', 'still closing the tear')
    local st = rosie_status(h)
    eq(st.reason, 'paused', 'Rosie pickup paused')
    ok(tostring(st.detail):find('HelltideRevamped', 1, true), 'paused by HelltideRevamped: ' .. tostring(st.detail))
    eq(h.pickups or 0, 0, 'no pickup while the tear is open')
    eq(h.logged('Skipping tear'), 0, 'the tear was not skipped')
    -- The tear closes.
    h.remove_actor(tear)
    ok(h.run_until(function() return (h.pickups or 0) >= 1 end, 40), 'drop collected after the tear\n' .. h.tail(30))
    ok(rosie_status(h).reason ~= 'paused', 'pause released')
    eq(h.logged('Tear closed after'), 1, 'one close line')
    -- QQT_Warpigz_v3 (Q3): the pause covers the whole tear event.
    eq(h.logged('Pausing Looter pickup until the tear event is over'), 1, 'one pause line')
end)

-- QQT_Warpigz_v3 (rc.2, Q3): "loot once the whole event is over". A Normal
-- rupture has no Realmwalker chain: the event is over when the rupture
-- completes (after the linger). No pickup before that; after it, HR walks
-- Rosie (pickup distance 6 m) to the drops that fell 5 m and 20+ m from
-- where it stood, then resumes the patrol.
case('Q3 standalone HR + Rosie: no pickup until the tear event is over, then every event drop is collected', function()
    local h = J.new({place = 'helltide', rosie = true, persisted = {helltide_revamped_main_toggle = true}})
    h.assert_clean('load')
    el(h, WP).main_toggle:set(false) -- plain farming: no WarPigs
    el(h, HR).mode:set(1)            -- Farm (tears)
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(6)
    eq(h.as('Rosie', function() return h.G.RosiePlugin.enable() end), true, 'Rosie enabled')
    h.pos = h.v(-600, 300)
    h.actor('helltide', 'S14_Rupture_SMP_SwitchGizmo', -585, 300)
    h.actor('helltide', 'S14_PandemoniumCrack_gizmo_holdArea', -585, 300)
    local tear = h.actor('helltide', 'S14_Rupture_SMP_Chargeable', -583, 301)
    local task = h.mod(HR, 'tasks.helltide')
    local tear_event = h.mod(HR, 'core.hr_tear_event')
    ok(h.run_until(function()
        return task.current_state == 'RIFT_CLOSE_TEARS' and h.pos:dist_to(tear.pos) <= 1.05
    end, 30), 'HR walked onto the golden tear\n' .. h.tail(30))
    h.drop('helltide', tear.pos:x() + 4, tear.pos:y() + 3)   -- 5 m: within Rosie's 6 m
    h.drop('helltide', tear.pos:x() - 12, tear.pos:y() - 18) -- 21.6 m: far outside it
    h.run(8)
    eq(h.pickups or 0, 0, 'no pickup while the tear is open')
    h.remove_actor(tear) -- the tear closes; the rupture lingers before it completes
    local early = 0
    ok(h.run_until(function()
        if not tear_event.session().loot_window then early = h.pickups or 0 end
        return h.logged('Tear event over (rupture complete)') > 0
    end, 30), 'the event ended\n' .. h.tail(30))
    eq(early, 0, 'no pickup between the last tear and the end of the event')
    ok(h.run_until(function() return (h.pickups or 0) >= 2 end, 45), 'both drops collected\n' .. h.tail(30))
    ok(h.run_until(function() return not tear_event.is_rift_state(task.current_state) end, 30),
        'HR resumed its patrol after the loot\n' .. h.tail(30))
    ok(rosie_status(h).reason ~= 'paused', 'pause released')
    eq(h.logged('Looter pickup resumed (tear event over: rupture complete)'), 1, 'one resume line')
    eq(h.logged('Tear event loot:'), 1, 'one loot summary line')
end)

-- QQT_Warpigz_v3 (3.1.1): drops Rosie already settled (a Tuning Prism taken
-- into Materials on the first interaction that the host still lists) are no
-- target of the post-event loot window: LooteerPlugin.evaluate_item(item,
-- true) refuses them ('pickup settled/exhausted'), so HR moves on and its
-- summary counts them as taken. Pre-fix: each ghost was walked to again until
-- its per-drop bound, '0 drop(s) walked to, 4 given up'.
case('3.1.1 the loot window skips drops Rosie already settled and counts them as taken', function()
    local h = J.new({place = 'helltide', rosie = true, persisted = {helltide_revamped_main_toggle = true}})
    h.assert_clean('load')
    el(h, WP).main_toggle:set(false)
    el(h, HR).mode:set(1)
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(6)
    eq(h.as('Rosie', function() return h.G.RosiePlugin.enable() end), true, 'Rosie enabled')
    h.P.helltide.helltide = true
    h.pos = h.v(-600, 300)
    h.actor('helltide', 'S14_Rupture_SMP_SwitchGizmo', -585, 300)
    h.actor('helltide', 'S14_PandemoniumCrack_gizmo_holdArea', -585, 300)
    local tear = h.actor('helltide', 'S14_Rupture_SMP_Chargeable', -583, 301)
    local task = h.mod(HR, 'tasks.helltide')
    local tear_event = h.mod(HR, 'core.hr_tear_event')
    ok(h.run_until(function()
        return task.current_state == 'RIFT_CLOSE_TEARS' and h.pos:dist_to(tear.pos) <= 1.05
    end, 30), 'HR walked onto the golden tear\n' .. h.tail(30))
    local prisms, spots = {}, {{12, 1}, {-12, 4}, {3, -16}, {-6, 15}}
    for i, spot in ipairs(spots) do
        local p = h.drop('helltide', tear.pos:x() + spot[1], tear.pos:y() + spot[2],
            {sno = 2533715, name = 'X2_HoradricCube_TuningStone_2', rarity = 0, display = "Protector's Tuning Prism"})
        p.on_interact = function()
            p.tries = (p.tries or 0) + 1
            p.taken = true -- into Materials; the host keeps listing it (a ghost)
        end
        prisms[i] = p
    end
    h.run(20)
    h.remove_actor(tear)
    ok(h.run_until(function()
        return h.logged('Tear event over') > 0 and not tear_event.is_rift_state(task.current_state)
    end, 180), 'HR left the rupture after its loot window\n' .. h.tail(30))
    h.assert_clean('3.1.1 settled')
    for i, p in ipairs(prisms) do
        ok(p.taken, 'prism ' .. i .. ' taken')
        local want, why = h.as(HR, function() return h.G.LooteerPlugin.evaluate_item(p, true) end)
        eq(want, false, 'prism ' .. i .. ': a settled drop is not wanted from afar')
        eq(why, 'pickup settled/exhausted', 'prism ' .. i .. ' reason')
    end
    eq(h.logged('Tear event loot: 4 drop(s) walked to, 0 given up'), 1, 'summary counts the settled drops as taken\n' .. h.tail(30))
    eq(h.logged('Event loot: leaving a drop'), 0, 'no drop given up')
end)

-- QQT_Warpigz_v3 (rc.2 review): the pause holds only at the event. A ring
-- whose golden tear is open is engaged from 85 m out; the combat rotation
-- kills a monster on the way (its drop lands 60 m from the ring, outside the
-- post-event loot area); later the player dies in the tear and revives at a
-- checkpoint 85 m away, and another monster dies on the walk back. Rosie
-- (8 m) takes both drops as she passes them, as without tears.
local function standalone(range)
    local h = J.new({place = 'helltide', rosie = true, persisted = {helltide_revamped_main_toggle = true}})
    h.assert_clean('load')
    el(h, WP).main_toggle:set(false) -- plain farming: no WarPigs
    el(h, HR).mode:set(1)            -- Farm (tears)
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(range)
    eq(h.as('Rosie', function() return h.G.RosiePlugin.enable() end), true, 'Rosie enabled')
    h.pos = h.v(-600, 300)
    return h
end

case('review standalone HR + Rosie: the walk to a far rupture and the revive walk-back are not paused', function()
    local h = standalone(8)
    local task = h.mod(HR, 'tasks.helltide')
    local ring_x = -515
    h.actor('helltide', 'S14_Rupture_SMP_SwitchGizmo', ring_x, 300)
    h.actor('helltide', 'S14_PandemoniumCrack_gizmo_holdArea', ring_x, 300)
    local tear = h.actor('helltide', 'S14_Rupture_SMP_Chargeable', ring_x + 2, 301)
    local drops = {}
    local function mob(x)
        local m = h.actor('helltide', 'Helltide_Monster_Test', x, 302, {enemy = true, health = 20, max_health = 20})
        m.on_death = function(hh, a) hh.remove_actor(a); drops[#drops + 1] = hh.drop('helltide', a.pos:x(), a.pos:y()) end
    end
    mob(-575) -- on the way, 60 m before the ring
    local paused_far = false
    local function watch()
        if h.pos:dist_to(tear.pos) > 12 + 32 + 4 + 2 and rosie_status(h).reason == 'paused' then paused_far = true end
    end
    ok(h.run_until(function()
        watch()
        return task.current_state == 'RIFT_CLOSE_TEARS' and h.pos:dist_to(tear.pos) <= 1.05
    end, 40), 'HR walked onto the golden tear\n' .. h.tail(30))
    ok(h.logged('Found ritual ring at dist=85.0') == 1, 'the rupture was engaged from 85 m')
    ok(drops[1] and drops[1].picked == true, 'the drop of the monster killed on the way was taken\n' .. h.tail(30))
    h.run(2)
    eq(rosie_status(h).reason, 'paused', 'paused in the tear')
    h.dead = true
    ok(h.run_until(function() return not h.dead end, 10), 'revived')
    eq(h.pos:dist_to(tear.pos) > 60, true, 'at the checkpoint, far from the tear')
    mob(-575) -- on the way back
    local closed = false
    ok(h.run_until(function()
        watch()
        if not closed and h.pos:dist_to(tear.pos) <= 1.5 then
            tear.inside = (tear.inside or 0) + 0.1
            if tear.inside >= 10 then closed = true; h.remove_actor(tear) end
        end
        return h.logged('resuming patrol') > 0
    end, 150), 'the rupture completed\n' .. h.tail(30))
    eq(paused_far, false, 'Rosie was never paused far from the rupture')
    ok(drops[2] and drops[2].picked == true, 'the drop of the monster killed on the way back was taken\n' .. h.tail(30))
    ok(rosie_status(h).reason ~= 'paused', 'pause released')
end)

print(string.format('Helltide tears (joint): %d cases, %d checks, %d failures', cases, checks, #failures))
if #failures > 0 then error('Helltide tears (joint) failures:\n' .. table.concat(failures, '\n')) end
print('PASS: test_helltide_tears_joint (' .. cases .. ' cases)')
