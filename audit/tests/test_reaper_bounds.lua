-- QQT_Warpigz_v3: Reaper night-review regressions (area reaper). Each case
-- failed on the pre-fix tree and passes after the fix:
--   N1 Rosie stuck: no trip loop, farm on, 'Alfred stuck (...)' shown (C6)
--   N2 an explicit refusal is not retried every 5 s from alfred_running
--   N3 one navigation reset per Alfred yield; explorerlite logs only real clears
--   N4 altar clicks that never summon are bounded (manual resync, external fails)
--   N5 a reward chest that never despawns is bounded; manual Belial with the
--      Belial Chest sequence off is skipped at startup
--   N6 a death after the summon returns to the fight (no skip, no ping-pong)
--   N7 a listed, non-interactable altar is never clicked (no phantom summon),
--      and Kill Monsters without any fight evidence is bounded
--   N8 Kill Monsters' tether anchor is the last altar position / the recorded
--      endpoint, never the world origin; Andariel/Harbinger seeds corrected
-- Real Reaper main.lua and tasks in the QQT-shaped harness of test_reaper.lua.
local SUITE = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local root = SUITE .. '/Reaper/'
local harness_env = setmetatable({REAPER_TEST_HARNESS_ONLY = true}, {__index = _G})
local harness = assert(loadfile(SUITE .. '/audit/tests/test_reaper.lua', 't', harness_env))()

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
    local passed, err = pcall(fn)
    if passed then
        print('PASS Reaper bounds: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Reaper bounds: ' .. name .. ': ' .. tostring(err))
    end
end

local next_acd = 100
local function key_item(sno, n)
    next_acd = next_acd + 1
    local acd = next_acd
    return {get_acd = function() return acd end, get_sno_id = function() return sno end,
        get_stack_count = function() return n end}
end
local GREATER, HUSK = 2558255, 2194099

local function boot(before)
    local e, c, s, p = harness()
    local logs = {}
    c.logs = logs
    e.console = {print = function(m) logs[#logs + 1] = tostring(m) end}
    c.moves = {}
    e.pathfinder.request_move = function(t)
        local pos = t.get_position and t:get_position() or t
        c.moves[#c.moves + 1] = pos
        if c.walk then c.position(pos) end
    end
    local target
    local ex = e.package.loaded['core.explorerlite']
    ex.set_custom_target = function(_, t) target = t end
    ex.move_to_target = function() if target and c.walk then c.position(target) end end
    c.clears = 0
    ex.clear_path_and_target = function() c.clears = c.clears + 1 end
    c.task_frames = {}
    if before then before(e, c, s, p) end
    assert(loadfile(root .. 'main.lua', 't', e))()
    c.now = 100
    function c.step(dt)
        c.now = c.now + (dt or 0.2); c.time(c.now); c.update()
        local st = e.ReaperPlugin.status()
        local n = st.task and st.task.name or '?'
        c.task_frames[n] = (c.task_frames[n] or 0) + 1
    end
    function c.run(seconds, dt)
        local stop_at = c.now + seconds
        while c.now < stop_at - 1e-9 do c.step(dt) end
    end
    function c.count(pattern)
        local n = 0
        for _, m in ipairs(logs) do if m:find(pattern, 1, true) then n = n + 1 end end
        return n
    end
    function c.frames(name) return c.task_frames[name] or 0 end
    p.get_dungeon_key_items = function() return {key_item(GREATER, 3)} end
    return e, c, s, p
end

-- A Rosie-shaped provider: the same table under both globals (Rosie
-- town/main.lua publishes AlfredTheButlerPlugin and PLUGIN_alfred_the_butler).
local function rosie_like(e, status, refuse)
    local api = {calls = 0}
    api.get_status = function() return status end
    api.trigger_tasks_with_teleport = function()
        api.calls = api.calls + 1
        if refuse then return false, 'stuck' end
        return true
    end
    e.AlfredTheButlerPlugin = api
    e.PLUGIN_alfred_the_butler = api
    return api
end

-- ── N1/N2: Alfred ───────────────────────────────────────────────────────────
case('N1 a stuck Rosie (need_trigger false, inventory full) never loops Reaper in alfred_running', function()
    local e, c, s = boot()
    s.use_alfred = true
    local api = rosie_like(e, {enabled = true, need_trigger = false, inventory_full = true,
        stuck = true, stuck_reason = 'stash full'}, true)
    c.actors({c.actor('Boss_WT4_Duriel', e.vec3:new(0, 0, 0))})
    e.ReaperPlugin.enable()
    c.run(60)
    eq(api.calls, 0, 'no request to a stuck provider')
    eq(c.frames('alfred_running'), 0, 'Reaper never yields to a stuck Alfred')
    ok(c.interactions > 0, 'Reaper farms on (altar clicked)')
    eq(e.ReaperPlugin.status().hold_reason, nil, 'the summon committed; hold is only for Alfred holds')
    eq(c.count('Alfred stuck (stash full)'), 1, 'logged once')
    -- Before the summon, the stuck note is visible in the status line (C6).
    local e2, c2, s2 = boot()
    s2.use_alfred = true; c2.zone('Town')
    rosie_like(e2, {enabled = true, need_trigger = false, inventory_full = true,
        stuck = true, stuck_reason = 'stash full'}, true)
    e2.ReaperPlugin.enable(); c2.run(2)
    eq(e2.ReaperPlugin.status().hold_reason, 'Alfred stuck (stash full)', 'shown in status')
    ok(c2.frames('alfred_running') == 0, 'no yield in town either')
end)

case('N2 a refusal from a provider without `stuck` is not retried every 5 s', function()
    local e, c, s = boot()
    s.use_alfred = true; c.zone('Town')
    local api = rosie_like(e, {enabled = true, need_trigger = true, inventory_full = true}, true)
    e.ReaperPlugin.enable()
    c.run(60)
    ok(api.calls <= 3, 'refusals are retried at most every 30 s (calls=' .. api.calls .. ')')
    ok(c.frames('alfred_running') <= 10, 'no hold between refusals (frames=' .. c.frames('alfred_running') .. ')')
end)

-- ── N3: console flood ───────────────────────────────────────────────────────
case('N3 one navigation reset per Alfred yield, and explorerlite logs only real clears', function()
    local e, c, s = boot()
    s.use_alfred = true; c.zone('Town')
    local status = {enabled = true, running = true}
    e.AlfredTheButlerPlugin = {get_status = function() return status end,
        trigger_tasks_with_teleport = function() return true end}
    e.ReaperPlugin.enable()
    c.run(1)
    local before = c.clears
    c.run(10)
    ok(c.frames('alfred_running') >= 40, 'yielding to the busy Alfred')
    ok(c.clears - before <= 1, 'reset once per yield, not per tick (clears=' .. (c.clears - before) .. ')')
    -- Real explorerlite: an empty clear prints nothing.
    local lines = {}
    local env = setmetatable({console = {print = function(m) lines[#lines + 1] = m end}}, {__index = e})
    env._G = env
    local ex = assert(loadfile(root .. 'core/explorerlite.lua', 't', env))()
    ex:clear_path_and_target(); ex:clear_path_and_target()
    eq(#lines, 0, 'nothing to clear, nothing logged')
end)

-- ── N4: altar retries ───────────────────────────────────────────────────────
case('N4 manual rotation: an altar that never summons is resynced once, then skipped', function()
    local e, c = boot()
    c.actors({c.actor('Boss_WT4_Duriel', e.vec3:new(0, 0, 0))})
    e.ReaperPlugin.enable()
    c.run(6, 0.5)
    ok((e.ReaperPlugin.status().hold_reason or ''):find('altar not accepting summon', 1, true) ~= nil,
        'retry count visible in status: ' .. tostring(e.ReaperPlugin.status().hold_reason))
    c.run(126, 0.5)
    ok(c.interactions <= 10, 'bounded clicks (' .. c.interactions .. ')')
    eq(c.count('inventory still has'), 1, 'one resync with stock left')
    eq(e.require('core.boss_rotation').is_done(), true, 'boss skipped, rotation over')
    c.zone('Town'); c.run(2)
    eq(e.ReaperPlugin.status().enabled, false, 'returns to town and stops')
end)

case('N4 manual rotation: resync finds no key for the tier, skipped after one bound', function()
    local e, c, _, p = boot()
    c.actors({c.actor('Boss_WT4_Duriel', e.vec3:new(0, 0, 0))})
    e.ReaperPlugin.enable()
    c.run(2, 0.5)
    p.get_dungeon_key_items = function() return {} end   -- e.g. Rosie stashed the keys
    c.run(60, 0.5)
    ok(c.interactions <= 5, 'one bound only (' .. c.interactions .. ')')
    eq(e.require('core.boss_rotation').is_done(), true)
end)

case('N4 run_once: an altar that never summons fails the run (C2)', function()
    local e, c, _, p = boot()
    p.get_dungeon_key_items = function() return {} end
    c.actors({c.actor('Boss_WT4_Duriel', e.vec3:new(0, 0, 0))})
    local result
    eq(e.ReaperPlugin.run_once('duriel', nil, function(r) result = r end), true)
    c.run(60, 0.5)
    ok(c.interactions <= 5, 'bounded clicks (' .. c.interactions .. ')')
    eq(e.ReaperPlugin.status().failed, true)
    c.zone('Town'); c.run(2)
    eq(result, 'failed'); eq(e.ReaperPlugin.status().in_run, false)
    ok((e.ReaperPlugin.status().last_error or ''):find('did not accept the summon', 1, true) ~= nil)
end)

-- ── N5: reward chest ────────────────────────────────────────────────────────
case('N5 a reward chest that never despawns ends a manual run (one reopen cycle)', function()
    local e, c = boot()
    c.actors({c.actor('EGB_Chest_Duriel', e.vec3:new(0, 0, 0))})
    e.ReaperPlugin.enable()
    c.run(600, 0.25)
    ok(c.count('retrying open') <= 1, 'reopen cycles bounded (' .. c.count('retrying open') .. ')')
    eq(c.count('Reward chest remained closed') > 0 or c.count('out of required key') > 0, true, 'run abandoned')
    eq(e.require('core.boss_rotation').is_done(), true)
end)

case('N5 manual Belial with the Belial Chest sequence off is skipped at startup', function()
    local e, c, s, p = boot()
    s.boss_target = 'belial'; s.belial_chest_enabled = false
    p.get_dungeon_key_items = function() return {key_item(HUSK, 6)} end
    c.zone('Boss_Kehj_Belial')
    c.actors({c.actor('Boss_WT_Belial_Reward', e.vec3:new(0, 0, 0))})
    e.ReaperPlugin.enable()
    c.run(120, 0.25)
    eq(e.ReaperPlugin.status().enabled, false, 'not started')
    eq(e.ReaperPlugin.status().last_error, 'belial_chest_disabled')
    eq(c.count('Belial skipped: Belial Chest automation is off'), 1)
    eq(c.interactions, 0)
    -- Roundrobin: Belial is skipped, the other boss farms.
    local e2, c2, s2, p2 = boot()
    s2.boss_rotation_mode = 'roundrobin'; s2.boss_enabled = {belial = true, duriel = true}
    s2.belial_chest_enabled = false
    p2.get_dungeon_key_items = function() return {key_item(HUSK, 6), key_item(GREATER, 1)} end
    e2.ReaperPlugin.enable(); c2.run(2)
    eq(e2.ReaperPlugin.status().boss, 'Duriel')
end)

-- ── N6: death after the summon ──────────────────────────────────────────────
local function death_boot(with_bm)
    local e, c, _, p = boot(function(e0, c0)
        if with_bm then
            local goal
            c0.long_paths = 0
            e0.BatmobilePlugin = {
                reset = function() end, resume = function() end, stop_long_path = function() goal = nil end,
                clear_target = function() end, clear_traversal_blacklist = function() end,
                release = function() goal = nil end,
                navigate_long_path = function(_, t) c0.long_paths = c0.long_paths + 1; goal = t; c0.position(t); return true end,
                is_long_path_navigating = function() return goal ~= nil end,
                update = function() end, move = function() end, set_target = function() end,
            }
        end
    end)
    c.walk = true
    local dead = false
    p.is_dead = function() return dead end
    e.revive_at_checkpoint = function() dead = false; c.position(e.vec3:new(82.78, 39.93, 8.04)) end
    -- The recorded duriel path crosses a ladder (traversal waypoint).
    local trav = c.actor('Traversal_Gizmo_Ladder', e.vec3:new(84.158203, 49.260468, 4.802827))
    local altar = c.actor('Boss_WT4_Duriel', e.vec3:new(-3.7, -4.08, -3.69))
    local boss_alive = true
    local boss = c.actor('Duriel_Boss', e.vec3:new(-5, -5, -3.69))
    e.target_selector.get_near_target_list = function() return boss_alive and {boss} or {} end
    e.interact_object = function(a)
        c.interactions = c.interactions + 1
        if a == altar then c.actors({trav}) end   -- the altar vanishes as the boss spawns
    end
    c.position(e.vec3:new(-3.0, -3.5, -3.69))
    c.actors({trav, altar})
    e.ReaperPlugin.enable()
    c.run(6, 0.25)
    eq(e.require('core.tracker').altar_activated, true, 'summoned')
    return e, c, function(v) dead = v end
end

case('N6 no Batmobile: a death after the summon returns to the fight instead of skipping the boss', function()
    local e, c, die = death_boot(false)
    die(true)
    c.task_frames = {}
    c.run(90, 0.25)
    eq(c.count('Skipping'), 0, 'boss not skipped after one death')
    eq(e.require('core.boss_rotation').is_done(), false)
    eq(e.require('core.tracker').altar_activated, true, 'back in the fight')
    ok(c.frames('Kill Monsters') > c.frames('Navigate to Boss'), 'fighting, not walking')
end)

case('N6 Batmobile: a death after the summon walks to the arena once and fights (no ping-pong)', function()
    local e, c, die = death_boot(true)
    die(true)
    c.task_frames = {}
    c.run(90, 0.25)
    eq(c.count('no altar visible — yielding'), 0, 'no yield/restart cycle')
    ok(c.count('[Pathwalker] Started') <= 1, 'the path is walked at most once')
    eq(c.count('Skipping'), 0)
    eq(e.require('core.tracker').altar_activated, true)
    ok(c.frames('Kill Monsters') > c.frames('Navigate to Boss'), 'fighting, not walking')
end)

-- ── N7: phantom summon / bounded fight ──────────────────────────────────────
case('N7 a listed altar that is not interactable is never clicked (no phantom summon)', function()
    local e, c = boot()
    local altar = c.actor('Boss_WT4_Duriel', e.vec3:new(0, 0, 0))
    altar.interactive = false          -- spent altar still listed after a finished run
    c.actors({altar})
    e.ReaperPlugin.enable()
    c.run(10, 0.5)
    eq(c.interactions, 0, 'no click on a spent altar')
    eq(e.require('core.tracker').altar_activated, false, 'no phantom activation')
    ok((e.ReaperPlugin.status().hold_reason or ''):find('not interactable', 1, true) ~= nil, 'wait visible')
    altar.interactive = true           -- re-armed: summon normally
    c.run(2, 0.5)
    eq(c.interactions, 1, 're-armed altar is clicked')
    -- Never re-arms: bounded wait, then the boss is skipped.
    local e2, c2 = boot()
    local a2 = c2.actor('Boss_WT4_Duriel', e2.vec3:new(0, 0, 0)); a2.interactive = false
    c2.actors({a2})
    e2.ReaperPlugin.enable()
    c2.run(60, 0.5)
    eq(c2.interactions, 0)
    eq(e2.require('core.boss_rotation').is_done(), true, 'skipped after the bounded wait')
end)

case('N7 Kill Monsters without boss, enemies, quest or chest is bounded', function()
    local e, c = boot()
    e.ReaperPlugin.enable()
    c.run(2)
    local tracker = e.require('core.tracker')
    tracker.altar_activated, tracker.altar_activate_time = true, c.now
    c.run(30)
    eq(tracker.altar_activated, true, 'a fight is not dropped early')
    c.run(60)
    eq(tracker.altar_activated, false, 'summon dropped, altar re-evaluated')
    eq(c.count('re-checking the altar'), 1)
end)

-- ── N8: tether anchor ───────────────────────────────────────────────────────
case('N8 the tether anchor is the last altar position, never a stale seed or the origin', function()
    local e, c, s = boot()
    s.boss_target = 'andariel'; c.zone('Boss_WT4_Andariel')
    local altar = c.actor('Boss_WT4_Andariel', e.vec3:new(-12, -11, -6.2))
    local boss = c.actor('Andariel_Boss', e.vec3:new(-15, -14, -6.2))
    e.target_selector.get_near_target_list = function() return {boss} end
    e.interact_object = function(a) c.interactions = c.interactions + 1; if a == altar then c.actors({}) end end
    c.position(e.vec3:new(-12, -10, -6.2))
    c.actors({altar})
    e.ReaperPlugin.enable()
    c.run(4, 0.25)
    eq(e.require('core.tracker').altar_activated, true)
    c.position(e.vec3:new(20, 20, -6.2))       -- knocked far away from the arena
    c.moves = {}
    c.run(1, 0.25)
    local last = c.moves[#c.moves]
    ok(last ~= nil, 'tether pulls back')
    ok(math.abs(last:x() + 12) < 0.01 and math.abs(last:y() + 11) < 0.01,
        'anchor is the last altar position, got ' .. tostring(last and last:x()) .. ',' .. tostring(last and last:y()))
    -- Butcher (no seed): the anchor is the recorded endpoint, never (0,0,0).
    local e2, c2, s2 = boot()
    s2.boss_target = 'butcher'; c2.zone('S12_Boss_Butcher')
    e2.target_selector.get_near_target_list = function() return {c2.actor('x')} end
    e2.ReaperPlugin.enable(); c2.run(1)
    local tr2 = e2.require('core.tracker')
    tr2.altar_activated, tr2.altar_activate_time = true, c2.now
    c2.position(e2.vec3:new(60, 60, 0)); c2.moves = {}
    c2.run(1, 0.25)
    local m = c2.moves[#c2.moves]
    ok(m ~= nil and not (m:x() == 0 and m:y() == 0), 'never tethered to the world origin')
    ok(m:dist_to_ignore_z(e2.vec3:new(-10.01, -41.25, 0)) < 1 or m:dist_to_ignore_z(e2.vec3:new(-41.73, -10.0, 0)) < 1,
        'recorded Butcher endpoint')
    -- Seeds agree with the recorded altar endpoints (within 3 m).
    local enums = e2.require('data.enums')
    local walker = e2.require('core.pathwalker')
    for _, pair in ipairs({{'Boss_WT4_Andariel', {'andariel_a', 'andariel_b', 'andariel_c'}},
                           {'Boss_WT5_Harbinger', {'harbinger_a', 'harbinger_b'}}}) do
        local seed = enums.positions.getBossRoomPosition(pair[1])
        for _, name in ipairs(pair[2]) do
            local pts = assert(loadfile(root .. 'paths/' .. name .. '.lua', 't', e2))()
            local endpoint = walker.point_position(pts[#pts])
            ok(seed:dist_to_ignore_z(endpoint) < 3, pair[1] .. ' seed vs ' .. name .. ': ' .. seed:dist_to_ignore_z(endpoint))
        end
    end
end)

print(string.format('Reaper bounds: %d cases, %d checks, %d failures', cases, checks, #failures))
if #failures > 0 then error('Reaper bounds failures:\n' .. table.concat(failures, '\n')) end
print('PASS: test_reaper_bounds (' .. cases .. ' cases)')
