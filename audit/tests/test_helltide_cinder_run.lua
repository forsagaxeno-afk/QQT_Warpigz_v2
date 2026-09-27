-- QQT_Warpigz_v3 (Q4): "Spend cinders on chests at" (core/hr_cinder_run.lua).
-- User: at 3000 cinders go open chests by priority: the War Plan node chest
-- (Hell's Prize, 666 cinders) first if the node is taken, then Mystery (250),
-- then the rest. Before: HR did not know the 666 chest at all
-- (Warplan_Helltide_HellsPrize: "[CHEST UNKNOWN] ... no known cost, ignored")
-- and had no such option; Warplan took the nearest affordable chest.
--   * data: Hell's Prize = 666 (d4data lock cost), _PreTorment included;
--   * option off (default): nothing changes, Hell's Prize is never taken;
--   * option on: Farm and Warplan / WarPigs (external enable) go Hell's
--     Prize > Mystery > nearest; the run ends below the cheapest known chest
--     and starts again only at the threshold; resumes after a task reset in
--     the same Helltide hour only;
--   * a chest on the way does not take the Hell's Prize cinders;
--   * no new tear hunt while the run walks to a chest;
--   * learned Hell's Prize spots are their own kind; the War Plan node read.
-- Review repair (QQT_Warpigz_v3, Q4 lane):
--   * save phase: below the threshold nothing is opened (chests remembered);
--     the last minutes of the Helltide spend the savings in the run order;
--   * a tear in range no longer starves the run (tears wait from the moment
--     the run is due until a run pick finds nothing);
--   * the same-hour resume and the switch-off work in Warplan / WarPigs too;
--   * no start/Done flip-flop when the threshold is below the cheapest chest;
--   * a learned Hell's Prize spot is skipped while the node is not taken;
--   * option-off gates of the legacy recall / Farm Cinder Threshold, the atlas
--     reload, the overlay and the menu entry are asserted.
-- Runs under Lua 5.4 and LuaJIT.
local H = dofile(assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/audit/tests/hr_smart_harness.lua')
local R = H.runner('Helltide cinder run')
local ok, eq = R.ok, R.eq
local v, actor = H.v, H.actor

local PRIZE, MYSTERY, GLOVES, RING = 'Warplan_Helltide_HellsPrize', 'usz_rewardGizmo_Uber',
    'usz_rewardGizmo_Gloves', 'usz_rewardGizmo_Rings'

local function session(opts)
    local s = H.new(opts)
    s.set('mode', (opts and opts.mode) or 1)
    -- QQT_Warpigz_v3: the run is "Spend cinders on chests at" (cinder_run) in
    -- Warplan / WarPigs and the Smart farm goal (farm_goal, on by default) in
    -- Farm mode. These cases start with the option off at 3000 (the amount
    -- they were written for; the default is now 2000, asserted below).
    s.set('farm_goal', false)
    s.set('cinder_run_at', 3000)
    function s.run_toggle(on)
        s.set('cinder_run', on)
        s.set('farm_goal', on)
    end
    s.order = s.require('core.hr_chest_order')
    s.atlas = s.require('core.hr_atlas')
    s.fence = s.require('core.hr_fence')
    s.targets = s.require('core.chest_targets')
    s.hr_mode = s.require('core.hr_mode')
    s.tracker.hr_fence = s.fence
    s.atlas.set_zone('Step_South')
    s.remembered = {}
    s.blacklist = {}
    function s.pick(actors, current)
        return s.order.pick({actors = actors or {}, remembered = s.remembered, key_of = s.targets.key,
            blacklisted = function(key) return s.blacklist[key] == true end,
            player = s.pos, cinders = s.cinders, current = current, now = s.now})
    end
    function s.run_on(at)
        s.run_toggle(true)
        if at then s.set('cinder_run_at', at) end
    end
    return s
end

local function task_session(mode, cinders, external)
    local bm = {sets = {}}
    local s = session({mode = mode, cinders = cinders or 3000, zone = 'Test_Zone', batmobile = {
        pause = function() end, resume = function() end, update = function() end, move = function() end,
        set_target = function(_, t) bm.sets[#bm.sets + 1] = t; return true end,
        clear_target = function() end, stop_long_path = function() end, is_paused = function() return false end,
        is_done = function() return false end, reset = function() end, reset_movement = function() end,
        get_target = function() return nil end, navigate_long_path = function() return true end,
        is_long_path_navigating = function() return false end}})
    s.bm = bm
    s.tracker.hr_chest_order, s.tracker.hr_atlas = s.order, s.atlas
    s.tracker.hr_stats = s.require('core.hr_stats')
    s.task = s.require('tasks.helltide')
    s.run = s.tracker.hr_cinder_run
    s.atlas.set_zone('Test_Zone')
    if external then s.hr_mode.set_external(true) end -- WarPigs: always Warplan
    return s
end

local function explore(s, from_explore)
    s.advance(1.1)
    s.task._last_check_events_time = nil
    if from_explore then s.task.current_state = 'EXPLORE_HELLTIDE' end
    if #s.tracker.waypoints == 0 then s.task:initiate_waypoints() end
    s.task:explore_helltide()
end

-- The first chest the task went for since the logs were cleared.
local function first_target(s)
    for _, l in ipairs(s.logs) do
        local n = l:match('Detected (%S+)') or l:match('Going to (%S+)') or l:match('On the way: (%S+)')
        if n then return n end
    end
    return nil
end

R.case('data: Hell\'s Prize is a known 666 chest (the _PreTorment variant too); menu defaults', function()
    local s = session({cinders = 0})
    local enums = s.require('data.enums')
    eq(enums.chest_types[PRIZE], 666, 'd4data lock cost of Warplan_Helltide_HellsPrize')
    local name, cost = s.targets.classify('Warplan_Helltide_HellsPrize_PreTorment', enums.chest_types)
    eq(name, PRIZE); eq(cost, 666)
    -- QQT_Warpigz_v3: shipped defaults: Warplan option off, Farm goal on, 2000.
    local d = H.new({})
    eq(d.gui.elements.cinder_run:get(), false, 'Warplan toggle off by default')
    eq(d.gui.elements.farm_goal:get(), true, 'Farm goal on by default')
    eq(d.gui.elements.cinder_run_at:get(), 2000, 'slider default 2000 (was 3000)')
    eq(d.settings.cinder_run, false); eq(d.settings.farm_goal, true); eq(d.settings.cinder_run_at, 2000)
    ok(s.settings.set_setting('cinder_run_at', 2500), 'set_setting accepts the slider value')
    eq(s.gui.elements.cinder_run_at:get(), 2500, 'and writes it to the menu')
end)

R.case('option off: nothing changes, a Hell\'s Prize is never taken (Farm and Warplan)', function()
    local farm = task_session(1)
    farm.actors = {actor(GLOVES, 20, 0), actor(MYSTERY, 40, 0), actor(PRIZE, 30, 0)}
    explore(farm)
    eq(farm.task.current_state, 'MOVING_TO_HELLTIDE_CHEST')
    eq(farm.logged('Detected usz_rewardGizmo_Uber'), 1, 'Farm: the Mystery, as before')
    local wp = task_session(0)
    wp.actors = {actor(GLOVES, 20, 0), actor(MYSTERY, 40, 0), actor(PRIZE, 30, 0)}
    explore(wp)
    eq(wp.logged('Detected usz_rewardGizmo_Gloves'), 1, 'Warplan: the nearest affordable, as before')
    for _, mode in ipairs({1, 0}) do
        local s = task_session(mode)
        s.actors = {actor(PRIZE, 20, 0)}
        explore(s)
        eq(s.task.current_state, 'EXPLORE_HELLTIDE', 'mode ' .. mode .. ': the Hell\'s Prize in sight is not opened')
        s.actors = {}
        explore(s)
        eq(s.task.current_state, 'EXPLORE_HELLTIDE', 'mode ' .. mode .. ': nor recalled')
        eq(s.logged('[CINDER RUN]'), 0)
        eq(#s.interactions, 0)
    end
    -- The legacy gates (Warplan / WarPigs): a Hell's Prize beyond 50 m is
    -- remembered, and must not be recalled; one 66 cinders short must not
    -- start a Farm Cinder Threshold stay (review: both gates were unreached).
    local a = task_session(0, 3000)
    a.actors = {actor(PRIZE, 110, 0)}
    explore(a); explore(a)
    eq(a.task.current_state, 'EXPLORE_HELLTIDE', 'Warplan, off: the remembered Hell\'s Prize is not recalled')
    eq(a.logged('[CHEST RECALL]'), 0)
    ok(a.logged('[CHEST REMEMBER] Warplan_Helltide_HellsPrize') >= 1, 'the recall gate was reached (remembered)')
    local b = task_session(0, 600)
    b.set('farm_cinder_threshold', 100)
    b.actors = {actor(PRIZE, 30, 0)}
    explore(b); explore(b)
    eq(b.task.current_state, 'EXPLORE_HELLTIDE', 'Warplan, off: no cinder farming for a Hell\'s Prize')
    eq(b.logged('[FARM CHEST] Warplan_Helltide_HellsPrize'), 0)
end)

R.case('option on, Farm: 3000 cinders -> Hell\'s Prize, then Mystery, then the nearest', function()
    local s = session({cinders = 3000})
    s.run_on()
    local prize, mystery = actor(PRIZE, 90, 0), actor(MYSTERY, 60, 0)
    local far_glove, near_ring = actor(GLOVES, 70, 5), actor(RING, 40, 0)
    local function all() return {near_ring, mystery, far_glove, prize} end -- a fresh actor snapshot
    local p = s.pick(all())
    eq(p.name, PRIZE, 'Hell\'s Prize first'); eq(p.class, -2)
    eq(s.logged('[CINDER RUN] 3000 cinders >= 3000'), 1, 'the start is logged once')
    s.cinders = 3000 - 666                         -- opened: the actor is spent
    prize.interactable = false
    s.order.release(p.key)
    p = s.pick(all())
    eq(p.name, MYSTERY, 'then the Mystery'); eq(p.class, 0)
    s.cinders = s.cinders - 250
    mystery.interactable = false
    s.order.release(p.key)
    p = s.pick(all())
    eq(p.name, RING, 'then the nearest'); eq(p.class, 2)
    eq(s.order.last_plan.cinder_run, true)
    eq(s.logged('[CINDER RUN]'), 1, 'no per-pick log')
end)

R.case('option on, Warplan under WarPigs (external enable): the run order replaces nearest-first', function()
    local s = task_session(1, 3000)
    s.hr_mode.set_external(true)                  -- WarPigs: always Warplan
    ok(not s.hr_mode.is_farm(), 'effective mode Warplan')
    s.run_on()
    s.actors = {actor(GLOVES, 20, 0), actor(MYSTERY, 40, 0), actor(PRIZE, 30, 0)}
    explore(s)
    eq(s.task.current_state, 'MOVING_TO_HELLTIDE_CHEST')
    eq(s.logged('Detected Warplan_Helltide_HellsPrize'), 1, 'the Hell\'s Prize first')
    -- Below the threshold under WarPigs: no save phase (the War Plan step is
    -- "spend 250 / 750 cinders on Tortured Gifts" and WarPigs leaves once it
    -- is done): the Warplan plain order, the Hell's Prize ignored.
    local w = task_session(0, 900, true)
    w.run_on()
    w.actors = {actor(GLOVES, 20, 0), actor(MYSTERY, 40, 0), actor(PRIZE, 30, 0)}
    explore(w)
    eq(w.logged('Detected usz_rewardGizmo_Gloves'), 1, 'WarPigs, no run at 900: nearest affordable')
    eq(w.logged('[CINDER RUN]'), 0, 'WarPigs: nothing saved')
    -- HR on its own (Warplan mode) below the threshold: the run saves
    -- (review: nothing saved toward it, the run never started): nothing is
    -- opened, the chests are remembered.
    local t = task_session(0, 900)
    t.run_on()
    t.actors = {actor(GLOVES, 20, 0), actor(MYSTERY, 40, 0), actor(PRIZE, 30, 0)}
    for _ = 1, 3 do explore(t) end
    eq(t.task.current_state, 'EXPLORE_HELLTIDE', 'saving at 900: no chest trip')
    eq(first_target(t), nil)
    eq(t.logged('[CHEST REMEMBER] usz_rewardGizmo_Gloves'), 1, 'the Gloves in reach are remembered for the run')
    eq(t.logged('[CHEST REMEMBER] usz_rewardGizmo_Uber'), 1)
    eq(t.logged('[CINDER RUN] Saving cinders for the run at 3000 (have 900)'), 1, 'the save phase is logged once')
    eq(t.logged('[CINDER RUN]'), 1)
    eq(#t.interactions, 0)
end)

R.case('Warplan task: a remembered Hell\'s Prize beyond 50 m is walked to and opened by the run', function()
    local s = task_session(0, 3000)
    s.run_on()
    local prize = actor(PRIZE, 110, 0)
    s.actors = {prize}
    explore(s)
    eq(s.task.current_state, 'MOVING_TO_REMEMBERED_CHEST', 'a trip to the Hell\'s Prize')
    s.pos = v(109.5, 0)
    for _ = 1, 6 do
        s.advance(0.5); s.task:move_to_remembered_chest()
        if #s.interactions > 0 then break end
    end
    ok(#s.interactions >= 1 and s.interactions[1] == prize, 'the Hell\'s Prize is opened')
end)

R.case('the run ends below the cheapest known chest and starts again only at the threshold', function()
    local s = session({cinders = 3000})
    s.run_on()
    local mystery, glove = actor(MYSTERY, 60, 0), actor(GLOVES, 30, 0)
    eq(s.pick({mystery, glove}).name, MYSTERY)
    mystery.interactable = false                   -- opened
    s.cinders = 200                                -- the Gloves (75) still affordable
    local p = s.pick({mystery, glove})
    eq(p and p.name, GLOVES, 'still spending')
    eq(s.logged('Done:'), 0)
    s.cinders = 60                                 -- below the cheapest known chest (75)
    eq(s.pick({mystery, glove}), nil)
    mystery.interactable = true                    -- a chest reset later
    eq(s.logged('[CINDER RUN] Done: below the cheapest known chest (75)'), 1, 'the end is logged once')
    s.pick({mystery, glove})
    eq(s.logged('Done:'), 1, 'once')
    s.cinders = 900                                -- income again, below the threshold
    local prize = actor(PRIZE, 20, 0)
    p = s.pick({prize, mystery, glove})
    eq(p, nil, 'no run below 3000: saving, nothing is picked (the Hell\'s Prize neither)')
    eq(s.order.last_plan.cinder_run, nil)
    s.cinders = 3100
    p = s.pick({prize, mystery, glove})
    eq(p.name, PRIZE, 'at the threshold again: a new run')
    eq(s.logged('[CINDER RUN] 3100 cinders'), 1)
    s.run_toggle(false)                     -- switched off mid-run
    p = s.pick({prize, mystery, glove})
    ok(p and p.name ~= PRIZE, 'off: back to the normal order')
    eq(s.logged('the option was switched off'), 1)
end)

R.case('a chest on the way does not take the cinders of the Hell\'s Prize', function()
    local s = session({cinders = 3000})
    s.run_on()
    local prize, here = actor(PRIZE, 90, 0), actor(GLOVES, 8, 0)
    eq(s.pick({prize}).name, PRIZE, 'run started')
    s.order.on_reset()
    s.cinders = 700                               -- 700 - 75 < 666
    local p = s.pick({prize, here})
    eq(p.name, PRIZE, 'the Hell\'s Prize, not the Gloves next to the player')
    ok(not p.opportunistic)
    s.order.on_reset()
    s.cinders = 800                               -- 800 - 75 >= 666
    p = s.pick({prize, here})
    eq(p.actor, here, 'enough for both: the chest on the way first'); eq(p.opportunistic, true)
end)

R.case('no new tear hunt from the moment the run is due; hunts again once it finds nothing', function()
    local s = session({cinders = 3000})
    s.tracker.hr_cinder_run = s.require('core.hr_cinder_run')
    s.set('hunt_rift_toggle', true)
    eq((s.hr_mode.hunt_ruptures()), true, 'option off: hunting')
    s.run_on()
    local hunt, why = s.hr_mode.hunt_ruptures()
    eq(hunt, false, 'at the threshold before the first run pick: the run goes first (review: tears starved it)')
    ok(tostring(why):find('cinder run', 1, true) ~= nil, tostring(why))
    ok(s.pick({actor(MYSTERY, 60, 0)}) ~= nil)
    eq((s.hr_mode.hunt_ruptures()), false, 'walking to a chest')
    s.advance(11)
    eq((s.hr_mode.hunt_ruptures()), false, 'still engaged with a chest to go to: no tear')
    s.remembered = {}                              -- the Mystery was opened
    ok(s.pick({}) == nil)
    eq((s.hr_mode.hunt_ruptures()), true, 'nothing to spend on: tears are hunted (they bring cinders)')
    s.advance(5)
    eq((s.hr_mode.hunt_ruptures()), true, 'within 10 s of the empty pick')
    s.advance(6)
    eq((s.hr_mode.hunt_ruptures()), false, 'later the run looks again first')
    ok(s.pick({}) == nil)
    eq((s.hr_mode.hunt_ruptures()), true)
    s.cinders = 50; ok(s.pick({}) == nil)          -- the run ends (below 75)
    eq(s.logged('Done:'), 1)
    s.cinders = 2000                               -- below the threshold, no run: tears as before
    eq((s.hr_mode.hunt_ruptures()), true, 'saving: tears are hunted')
end)

R.case('task (Farm, Hunt tears on): a ritual ring in range no longer keeps the run from starting', function()
    local RING_SKIN = 'S14_PandemoniumCrack_gizmo_holdArea'
    local function farm(cinders)
        local s = task_session(1, cinders)
        s.set('hunt_rift_toggle', true)
        s.run_on()
        s.at_minute(20)
        return s
    end
    local s = farm(3200)
    local prize, mystery = actor(PRIZE, 30, 0), actor(MYSTERY, 40, 0)
    for round = 1, 3 do
        s.actors = {prize, mystery, actor(RING_SKIN, 50 + round * 8, 10 * round)}
        explore(s, true)
        eq(s.task.current_state, 'MOVING_TO_HELLTIDE_CHEST', 'round ' .. round .. ': a chest trip, not the tear')
        s.advance(60); s.cinders = s.cinders + 150
    end
    eq(s.logged('[RIFT] Found'), 0, 'no tear engaged while the run has chests')
    eq(s.logged('[CINDER RUN] 3200 cinders >= 3000'), 1)
    eq(s.logged('Detected ' .. PRIZE), 3, 'the Hell\'s Prize first')
    -- Control: the same ring below the threshold (saving) is engaged.
    local c = farm(1000)
    c.actors = {actor(RING_SKIN, 58, 10)}
    explore(c, true)
    ok(c.logged('[RIFT] Found') >= 1, 'the ring is a tear the hunt engages: ' .. table.concat(c.logs, ' / '))
    -- Nothing to spend on at the threshold: the run finds nothing, tears go on.
    local e = farm(3200)
    e.actors = {actor(RING_SKIN, 58, 10)}
    explore(e, true)
    eq(e.logged('[RIFT] Found'), 0, 'the run looks first')
    explore(e, true)
    ok(e.logged('[RIFT] Found') >= 1, 'no chest known: the tear is hunted next tick')
end)

R.case('a task reset resumes the run in the same Helltide hour only', function()
    local s = session({cinders = 3000})
    s.run_on()
    s.at_minute(20)
    local mystery = actor(MYSTERY, 60, 0)
    ok(s.pick({mystery}) ~= nil)
    s.cinders = 1500
    s.order.on_reset()                            -- town trip / death: task reset
    local run = s.require('core.hr_cinder_run')
    eq(run.active(), false, 'reset clears the run')
    ok(s.pick({mystery}) ~= nil)
    eq(run.active(), true, 'same hour, a known chest affordable: resumed')
    eq(s.logged('run resumed'), 1)
    s.order.on_reset()
    s.epoch = s.epoch + 3600
    s.pick({mystery})
    eq(run.active(), false, 'the next Helltide: 1500 < 3000, no run')
    -- A run that ended normally is not resumed by a reset.
    local t = session({cinders = 3000})
    t.run_on()
    t.at_minute(20)
    t.pick({actor(GLOVES, 30, 0)})
    t.cinders = 50; t.pick({actor(GLOVES, 30, 0)})
    t.order.on_reset()
    t.cinders = 400; t.pick({actor(GLOVES, 30, 0)})
    eq(t.require('core.hr_cinder_run').active(), false, 'ended run: not resumed')
    -- Right after the reset nothing is known yet: no resume, still pending.
    local u = session({cinders = 3000})
    u.run_on(); u.at_minute(20)
    ok(u.pick({actor(MYSTERY, 60, 0)}) ~= nil)
    u.cinders = 1500; u.remembered = {}; u.order.on_reset()
    eq(u.pick({}), nil)
    local urun = u.require('core.hr_cinder_run')
    eq(urun.active(), false, 'no known chest: not resumed')
    eq(u.logged('run resumed'), 0)
    eq(u.pick({actor(GLOVES, 30, 0)}).name, GLOVES, 'a chest comes into sight: resumed')
    eq(u.logged('run resumed'), 1)
end)

R.case('task reset resume in Warplan and under WarPigs (external enable) as in Farm', function()
    for _, m in ipairs({{1, false, 'Farm'}, {0, false, 'Warplan'}, {1, true, 'WarPigs'}}) do
        local s = task_session(m[1], 3000, m[2])
        s.run_on(); s.at_minute(20)
        s.actors = {actor(GLOVES, 20, 0), actor(MYSTERY, 40, 0), actor(PRIZE, 30, 0)}
        explore(s)
        eq(s.logged('Detected ' .. PRIZE), 1, m[3] .. ': the Hell\'s Prize first')
        s.cinders = 1500
        s.task:reset()                              -- town trip: HR's search task resets the helltide task
        s.logs = {}
        s.actors = {actor(GLOVES, 20, 5), actor(MYSTERY, 40, 5), actor(PRIZE, 30, 5)}
        explore(s)
        eq(s.run.active(), true, m[3] .. ': resumed in the same Helltide hour (review: only Farm did)')
        eq(s.logged('run resumed'), 1, m[3])
        eq(first_target(s), PRIZE, m[3] .. ': the run order, not the nearest Gloves')
    end
end)

R.case('switching the option off ends the run in every mode; on again below the threshold saves', function()
    for _, m in ipairs({{1, false, true, 'Farm'}, {0, false, true, 'Warplan'}, {1, true, true, 'WarPigs'},
            {1, false, false, 'Farm, smart order off'}}) do
        local s = task_session(m[1], 3000, m[2])
        s.set('smart_order', m[3])
        s.run_on(); s.at_minute(20)
        s.actors = {actor(GLOVES, 20, 0), actor(MYSTERY, 40, 0), actor(PRIZE, 30, 0)}
        explore(s, true)
        eq(s.logged('[CINDER RUN] 3000 cinders >= 3000'), 1, m[4])
        s.cinders = 2000
        s.run_toggle(false)
        for _ = 1, 3 do explore(s, true) end
        eq(s.logged('the option was switched off'), 1, m[4] .. ': Done logged once (review: never outside Farm)')
        eq(s.run._state().active, false, m[4] .. ': released')
        s.advance(300); s.cinders = 800; s.logs = {}
        s.run_toggle(true)
        s.actors = {actor(GLOVES, 20, 9), actor(MYSTERY, 40, 9), actor(PRIZE, 30, 9)}
        explore(s, true)
        eq(s.run.active(), false, m[4] .. ': no stale run at 800')
        eq(s.run.busy(), false, m[4] .. ': no tear block')
        if m[2] then                               -- WarPigs: no save phase, the plain order
            eq(first_target(s), GLOVES, m[4] .. ': the nearest, no Hell\'s Prize at 800')
        else
            eq(first_target(s), nil, m[4] .. ': saving toward 3000, no Hell\'s Prize at 800')
        end
        eq(s.logged('spending on chests'), 0, m[4])
    end
    -- Switched off and a task reset before any poll: no resume is kept.
    local s = session({cinders = 3000})
    s.run_on(); s.at_minute(20)
    ok(s.pick({actor(MYSTERY, 60, 0)}) ~= nil)
    s.run_toggle(false)
    s.order.on_reset()
    s.run_toggle(true); s.cinders = 1500
    eq(s.pick({actor(GLOVES, 30, 0)}), nil, 'no resume after an off + reset: saving')
    eq(s.logged('run resumed'), 0)
end)

R.case('save phase: nothing opened below the threshold; the last minutes spend the savings by priority', function()
    local s = session({cinders = 400})
    s.run_on()
    s.at_minute(30)
    local mystery, glove = actor(MYSTERY, 40, 0), actor(GLOVES, 20, 0)
    eq(s.pick({mystery, glove}), nil, 'Farm, 400 < 3000: saving')
    eq(s.pick({mystery, glove}), nil)
    eq(s.logged('[CINDER RUN] Saving cinders for the run at 3000'), 1, 'logged once')
    ok(s.remembered[s.targets.key(GLOVES, glove.pos)] ~= nil, 'the Gloves are remembered')
    local run = s.require('core.hr_cinder_run')
    eq(run.saving(), true)
    eq(run.allows(GLOVES), false, 'legacy gates hold too')
    eq(run.engaged(), false, 'not engaged: tears are hunted while saving')
    s.at_minute(51)                                 -- 4 min left <= 'Spend everything in the last' 5
    eq(run.saving(), false)
    eq(run.engaged(), true, 'the savings are due')
    local p = s.pick({mystery, glove})
    eq(p and p.name, MYSTERY, 'the run order spends them: Mystery before the nearer Gloves')
    eq(s.logged('[CINDER RUN] 400 cinders saved, the Helltide ends in 5 min or less'), 1)
    -- 'Spend everything in the last (min)' 0: the save phase still leaves 2 min.
    local t = session({cinders = 400})
    t.run_on(); t.set('dump_min', 0)
    t.at_minute(52)
    eq(t.pick({actor(GLOVES, 20, 0)}), nil, '3 min left: saving')
    t.at_minute(53, 30)
    eq(t.pick({actor(GLOVES, 20, 0)}).name, GLOVES, '1.5 min left: spent')
end)

R.case('save phase in the task: Warplan remembers, then spends at the threshold (and in the last minutes)', function()
    local s = task_session(0, 500)
    s.run_on(); s.at_minute(20)
    s.actors = {actor(GLOVES, 20, 0), actor(MYSTERY, 40, 0)}
    for _ = 1, 2 do explore(s, true) end
    eq(first_target(s), nil, 'saving: no chest trip at 500')
    eq(#s.interactions, 0)
    s.set('farm_cinder_threshold', 100)
    s.cinders = 200                                 -- the Mystery 50 short: no Farm Cinder Threshold stay
    s.actors = {actor(MYSTERY, 40, 0)}
    explore(s, true)
    eq(s.task.current_state, 'EXPLORE_HELLTIDE', 'no cinder farming for a chest while saving')
    s.cinders = 3000; s.logs = {}
    s.actors = {}                                   -- out of sight: the remembered chests
    explore(s, true)
    eq(s.logged('[CINDER RUN] 3000 cinders >= 3000'), 1)
    eq(first_target(s), MYSTERY, 'the remembered Mystery first')
    local d = task_session(0, 400)
    d.run_on(); d.at_minute(52)
    d.actors = {actor(GLOVES, 20, 0), actor(MYSTERY, 40, 0)}
    explore(d, true)
    eq(first_target(d), MYSTERY, 'Warplan, last minutes: the savings by the run order')
    eq(d.logged('saved, the Helltide ends'), 1)
end)

R.case('a threshold below the only known chest: no start/Done flip-flop', function()
    local s = session({cinders = 550})
    s.run_on(500)
    local prize = actor(PRIZE, 60, 0)
    for _ = 1, 10 do s.pick({prize}); s.advance(0.5) end
    ok(s.logged('[CINDER RUN]') <= 1, 'at most one line, got ' .. s.logged('[CINDER RUN]'))
    eq(s.logged('spending on chests'), 0, 'no run: nothing affordable')
    eq(s.logged('Done:'), 0)
    local t = task_session(0, 550, true)
    t.run_on(500)
    t.actors = {actor(PRIZE, 60, 0)}
    for _ = 1, 10 do explore(t) end
    eq(t.logged('spending on chests') + t.logged('Done:'), 0, 'task (WarPigs): no start/Done lines')
    t.cinders = 700
    explore(t)
    eq(t.logged('[CINDER RUN] 700 cinders >= 500'), 1, 'affordable: the run starts once')
end)

R.case('War Plan node not taken: a learned Hell\'s Prize spot is skipped (unknown keeps it)', function()
    local s = session({cinders = 3000})
    s.at_minute(1); s.atlas.observe(PRIZE, 666, v(120, 0), true)
    s.at_minute(16); s.atlas.observe(PRIZE, 666, v(120, 0), true)
    s.at_minute(21)
    s.env.warplan = {selected_path = function() return {7, 8} end,
        node_name = function(id) return id == 7 and 'Wretched Vermin' or 'Tainted Shrines' end,
        node_reward_name = function() return '' end}
    s.run_on()
    local p = s.pick({actor(MYSTERY, 40, 0)})
    eq(s.logged("Hell's Prize node not in the War Plan"), 1)
    eq(p.name, MYSTERY, 'the Mystery in sight, not a sure miss 120 m away')
    s.order.on_reset()
    p = s.pick({actor(MYSTERY, 40, 0), actor(PRIZE, 90, 0)})
    eq(p.name, PRIZE, 'a Hell\'s Prize in sight is the ground truth'); eq(p.class, -2)
end)

R.case('the run ends below the cheapest chest that is not blacklisted; Helltide chests off: no run', function()
    local s = session({cinders = 3000})
    s.run_on()
    local glove, amulet = actor(GLOVES, 30, 0), actor('usz_rewardGizmo_Amulet', 50, 0)
    ok(s.pick({glove, amulet}) ~= nil)
    s.blacklist[s.targets.key(GLOVES, glove.pos)] = true
    s.cinders = 100
    eq(s.pick({glove, amulet}), nil)
    eq(s.logged('Done: below the cheapest known chest (125)'), 1, 'the blacklisted 75 chest does not keep it going')
    local run = s.require('core.hr_cinder_run')
    s.set('helltide_chest_toggle', false)
    eq(run.on(), false, 'requires Open Helltide Chest')
    s.cinders = 3000
    eq(run.engaged(), false)
    eq(run.allows(PRIZE), false)
    s.set('helltide_chest_toggle', true)
    s.set('cinder_run_at', 100); eq(run.threshold(), 250, 'clamped to 250')
    s.set('cinder_run_at', 20000); eq(run.threshold(), 10000, 'clamped to 10000')
end)

R.case('overlay and menu: "Cinder run | Plan", Hell\'s Prize, "Saving"; the menu entry is rendered', function()
    local s = session({cinders = 3000})
    s.tracker.hr_chest_order = s.order
    s.tracker.hr_cinder_run = s.require('core.hr_cinder_run')
    local overlay = s.require('core.hr_overlay')
    local function line(prefix)
        for _, l in ipairs(overlay.build(s.now, s.pos)) do
            if l:find(prefix, 1, true) then return l end
        end
        return nil
    end
    s.run_on()
    s.pick({actor(PRIZE, 40, 0)})
    -- QQT_Warpigz_v3: sectioned overlay (NOW: Plan row, TARGET: Chest row).
    local l = line('Plan  Cinder run: ')
    ok(l ~= nil, tostring(l))
    l = line('Chest  ')
    ok(l ~= nil and l:find("Hell's Prize  666", 1, true) ~= nil, tostring(l))
    s.cinders = 400; s.order.on_reset()
    s.remembered = {}
    s.pick({})
    ok(line('Saving cinders for the run at 3000') ~= nil, 'saving shown')
    eq(line('Cinder run:'), nil)
    s.hr_mode.set_external(true)                  -- WarPigs: no save phase
    ok(line('Plan  ') ~= nil and line('Saving') == nil, 'WarPigs: not saving')
    eq(s.require('core.hr_cinder_run').saving(), false)
    s.hr_mode.set_external(false)
    s.run_toggle(false)
    ok(line('Plan  ') ~= nil and line('Saving') == nil and line('Cinder run') == nil, 'off: the plain plan line')
    -- The menu: the entry under Settings, the slider only with the toggle on.
    -- QQT_Warpigz_v3: Warplan mode (Farm shows the Smart farm goal instead).
    s.set('mode', 0)
    local e = s.gui.elements
    local seen = {}
    for _, k in ipairs({'cinder_run', 'cinder_run_at'}) do
        e[k].render = function() seen[k] = (seen[k] or 0) + 1 end
    end
    s.gui.render()
    eq(seen.cinder_run, 1, '"Spend cinders on chests at" is in the menu'); eq(seen.cinder_run_at, nil)
    e.cinder_run:set(true)
    s.gui.render()
    eq(seen.cinder_run_at, 1, '"Cinders" with the toggle on')
end)

R.case('learned Hell\'s Prize spots are their own kind and come first during the run', function()
    local s = session({cinders = 3000})
    s.at_minute(1); s.atlas.observe(PRIZE, 666, v(120, 0), true)
    s.at_minute(16); s.atlas.observe(PRIZE, 666, v(120, 0), true)
    s.at_minute(1); s.atlas.observe(RING, 75, v(121, 1), true)
    eq(s.atlas.spot_at(v(120, 0), PRIZE).type, 'prize')
    eq(s.atlas.spot_at(v(121, 1), RING).name, RING, 'a regular chest 1.4 m away is another spot')
    s.at_minute(21)
    local p = s.pick({})
    ok(p == nil or p.name ~= PRIZE, 'option off: the learned Hell\'s Prize spot is not a target')
    s.run_on()
    p = s.pick({actor(MYSTERY, 60, 0)})
    eq(p.name, PRIZE, 'run: the learned Hell\'s Prize spot first'); eq(p.class, -1); eq(p.predicted, true)
    -- Saved and loaded with its kind.
    s.atlas.save_zone('Step_South')
    local text = s.file('learned/Step_South.txt') or ''
    ok(text:find('|prize|' .. PRIZE, 1, true) ~= nil, 'persisted as a prize spot')
    local t = H.new({cinders = 3000, files = s.files})  -- a game restart
    local atlas2 = t.require('core.hr_atlas')
    atlas2.set_zone('Step_South')
    local spot = atlas2.spot_at(v(120, 0), PRIZE)
    eq(spot and spot.type, 'prize', 'loaded back as a prize spot')
end)

R.case('task: a learned Hell\'s Prize spot takes only a Hell\'s Prize (not a regular chest there)', function()
    local s = task_session(1, 3000)
    s.run_on()
    s.at_minute(1); s.atlas.observe(PRIZE, 666, v(120, 0), true)
    s.at_minute(16); s.atlas.observe(PRIZE, 666, v(120, 0), true)
    s.at_minute(21)
    s.actors = {}
    explore(s)
    eq(s.task.current_state, 'MOVING_TO_REMEMBERED_CHEST', 'the learned Hell\'s Prize spot')
    s.actors = {actor(GLOVES, 121, 1)}             -- only a regular chest at the spot now
    s.pos = v(120.5, 0.5)
    for _ = 1, 8 do s.advance(0.5); s.task:move_to_remembered_chest() end
    eq(#s.interactions == 0 or s.interactions[1].skin ~= GLOVES, true, 'the Gloves are not opened as the Hell\'s Prize')
    ok(s.logged('No Warplan_Helltide_HellsPrize at the learned spot') >= 1, 'a miss of the prize spot')
end)

R.case('War Plan node read: taken / not taken / unknown (log only)', function()
    local s = session({cinders = 3000})
    local run = s.require('core.hr_cinder_run')
    eq(run.node_taken(1), nil, 'no War Plan API: unknown')
    local names = {[7] = 'Wretched Vermin', [9] = 'Hell\226\128\153s Prize'}
    s.env.warplan = {selected_path = function() return {7, 9} end,
        node_name = function(id) return names[id] end, node_reward_name = function() return '' end}
    eq(run.node_taken(100), true, 'Hell\'s Prize selected (curly apostrophe)')
    names[9] = 'Tainted Shrines'
    eq(run.node_taken(130), true, 'cached for 60 s')
    eq(run.node_taken(200), false, 'not selected')
    s.env.warplan.selected_path = function() error('not ready') end
    eq(run.node_taken(300), nil, 'API error: unknown')
    s.run_on()
    s.pick({actor(MYSTERY, 60, 0)})
    eq(s.logged('Hell\'s Prize node unknown'), 1, 'the start log says what the War Plan read gave')
end)

R.finish()
