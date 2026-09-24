-- Reaper integration regressions: C2 provider side (RPR-7/WPD-6 results,
-- RPR-2 run phase), RPR-3/RPR-4 (C1 Alfred reading), RPR-5 (C3 Batmobile
-- release), RPR-6 (Looter before the lair exit), RPR-8 (Belial refusal),
-- RPR-10 (C4 orbwalker), RPR-11 (periodic reset under WarPigs), C5 (yield
-- accounting) and C6 (visible holds). Loads the real Reaper main.lua and
-- tasks with the QQT-shaped harness of test_reaper.lua; the joint cases also
-- load the real WarPigs orchestrator and the real Batmobile. Lua 5.4 + LuaJIT.
local SUITE = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local root = SUITE .. '/Reaper-main/'
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
        print('PASS Reaper integration: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Reaper integration: ' .. name .. ': ' .. tostring(err))
    end
end

-- Real Reaper main.lua in a harness env. `before(e, c, s, p)` runs before
-- main.lua loads (to swap module mocks). c.step/c.run advance host time.
local function boot(before)
    local e, c, s, p = harness()
    local logs = {}
    c.logs = logs
    e.console = {print = function(m) logs[#logs + 1] = tostring(m) end}
    c.town_tps, c.boss_tps = 0, 0
    e.teleport_to_waypoint = function() c.town_tps = c.town_tps + 1; c.teleports = c.teleports + 1 end
    e.teleport_to_boss_dungeon = function() c.boss_tps = c.boss_tps + 1; c.teleports = c.teleports + 1 end
    if before then before(e, c, s, p) end
    assert(loadfile(root .. 'main.lua', 't', e))()
    c.now = 100
    function c.step(dt) c.now = c.now + (dt or 0.2); c.time(c.now); c.update() end
    function c.run(seconds, dt)
        local stop_at = c.now + seconds
        while c.now < stop_at - 1e-9 do c.step(dt) end
    end
    function c.count(pattern)
        local n = 0
        for _, m in ipairs(logs) do if m:find(pattern, 1, true) then n = n + 1 end end
        return n
    end
    return e, c, s, p
end

local function recorder()
    local r = {}
    r.cb = function(result) r[#r + 1] = result == nil and 'nil' or result end
    return r
end

-- ── C2 / WPD-6 / RPR-7: exactly one terminal result per run ────────────────
case('C2 success: on_complete(success) once, status run phase and result', function()
    local e, c = boot()
    local r = recorder()
    local inside
    local accepted = e.ReaperPlugin.run_once('duriel', nil, function(result)
        r.cb(result); inside = e.ReaperPlugin.status()
    end)
    eq(accepted, true)
    local st = e.ReaperPlugin.status()
    eq(st.external_run, true, 'external_run while queued'); eq(st.in_run, true, 'in_run while queued')
    eq(st.last_result, nil)
    c.run(1)
    e.require('core.boss_rotation').consume_run()   -- kill + chest done
    c.run(1)
    eq(c.town_tps, 1, 'town teleport'); eq(e.ReaperPlugin.status().in_run, true, 'returning to town is in_run')
    c.zone('Town'); c.run(1)
    eq(#r, 1, 'one report'); eq(r[1], 'success')
    eq(inside.enabled, false, 'Reaper is off when the callback runs'); eq(inside.last_result, 'success')
    st = e.ReaperPlugin.status()
    eq(st.enabled, false); eq(st.in_run, false); eq(st.external_run, false)
    eq(st.last_result, 'success'); eq(st.last_error, nil)
    c.run(5); e.ReaperPlugin.disable(); c.run(1)
    eq(#r, 1, 'no second report after a later disable')
end)

case('C2/WPD-6 failure: unreachable boss reports failed once with the reason', function()
    local e, c = boot()
    c.zone('Town')                                  -- boss teleport never lands
    local r = recorder()
    eq(e.ReaperPlugin.run_once('duriel', nil, r.cb), true)
    c.run(600, 0.5)
    eq(#r, 1, 'failure reported exactly once'); eq(r[1], 'failed')
    local st = e.ReaperPlugin.status()
    eq(st.enabled, false); eq(st.last_result, 'failed')
    eq(st.last_error, 'Boss teleport failed repeatedly', 'reason survives stop()')
end)

case('C2 cancel: disable() mid-run reports cancelled once', function()
    local e, c = boot()
    local r = recorder()
    eq(e.ReaperPlugin.run_once('duriel', nil, r.cb), true)
    c.run(2)
    e.ReaperPlugin.disable()
    eq(#r, 1); eq(r[1], 'cancelled')
    eq(e.ReaperPlugin.status().last_result, 'cancelled')
    e.ReaperPlugin.disable(); c.run(2)
    eq(#r, 1, 'second disable does not report again')
end)

case('C2 cancel: a request switched off before its first frame still reports', function()
    local e, c = boot()
    local r = recorder()
    eq(e.ReaperPlugin.run_once('duriel', nil, r.cb), true)
    c.enabled = false                               -- user unticks before Reaper's pulse
    c.step()
    eq(#r, 1); eq(r[1], 'cancelled')
    eq(e.ReaperPlugin.status().in_run, false)
end)

case('C2 refusals return false plus a reason', function()
    local e, c = boot()
    eq(e.ReaperPlugin.run_once('duriel', nil, function() end), true)
    local accepted, why = e.ReaperPlugin.run_once('zir', nil, function() end)
    eq(accepted, false); eq(why, 'busy')
    e.ReaperPlugin.disable()
    accepted, why = e.ReaperPlugin.run_once('nobody', nil, function() end)
    eq(accepted, false); eq(why, 'unknown boss')
    accepted, why = e.ReaperPlugin.run_once('duriel', 'sigil', function() end)
    eq(accepted, false); eq(type(why), 'string', 'sigil refusal has a reason')
    eq(e.ReaperPlugin.status().enabled, false, 'refused start does not enable')
end)

-- ── RPR-8: Belial one-shot without the Ritual of Lies sequence ─────────────
case('RPR-8 run_once(belial) is refused while the Belial chest sequence is off', function()
    local e, c, s = boot()
    s.belial_chest_enabled = false
    local r = recorder()
    local accepted, why = e.ReaperPlugin.run_once('belial', nil, r.cb)
    eq(accepted, false); eq(why, 'belial_chest_disabled')
    c.run(5)
    eq(c.boss_tps, 0, 'no teleport, nothing summoned'); eq(e.ReaperPlugin.status().enabled, false)
    eq(select(1, e.ReaperPlugin.run_boss('belial')), false, 'run_boss refuses too')
    s.belial_chest_enabled = true
    eq(e.ReaperPlugin.run_once('belial', nil, r.cb), true, 'accepted with the sequence on')
end)

-- ── RPR-2 provider side: a Reaper WarPigs did not start is not a run ───────
case('RPR-2 manual Reaper reports external_run=false and in_run only in committed phases', function()
    local e, c, s, p = boot()
    local item = {get_acd = function() return 7 end, get_sno_id = function() return 2558255 end,
        get_stack_count = function() return 9 end}
    p.get_dungeon_key_items = function() return {item} end
    e.ReaperPlugin.enable()
    c.run(2)
    local st = e.ReaperPlugin.status()
    eq(st.enabled, true); eq(st.external_run, false); eq(st.in_run, false, 'walking to the altar is not committed')
    e.require('core.tracker').altar_activated = true
    eq(e.ReaperPlugin.status().in_run, true, 'boss fight is committed')
end)

-- ── RPR-3: sticky advisory need_trigger ─────────────────────────────────────
local function sticky_alfred(e, counter, legacy)
    local api = {
        get_status = function()
            return {enabled = true, need_trigger = not legacy or nil, restock_count = 1,
                inventory_full = false, need_repair = false}
        end,
        trigger_tasks_with_teleport = function(_, cb) counter.n = counter.n + 1; cb() end,
    }
    if legacy then e.PLUGIN_alfred_the_butler = api else e.AlfredTheButlerPlugin = api end
end

case('RPR-3 the sticky grace survives run_once (no second trip)', function()
    local e, c, s = boot()
    s.use_alfred = true; c.zone('Town')
    local t = {n = 0}; sticky_alfred(e, t)
    eq(e.ReaperPlugin.run_once('duriel', nil, function() end), true)
    c.run(3)
    eq(t.n, 1, 'one maintenance trip in town')
    e.ReaperPlugin.disable()                        -- e.g. WarPigs handoff/cancel
    eq(e.ReaperPlugin.run_once('duriel', nil, function() end), true)
    c.run(10)
    eq(t.n, 1, 'run_once did not erase the completion grace')
end)

case('RPR-3 a sticky advisory flag never pulls the player out of the lair', function()
    local e, c, s = boot()
    s.use_alfred = true; c.zone('Boss_WT4_Duriel')  -- arrived, walking to the altar
    local t = {n = 0}; sticky_alfred(e, t)
    eq(e.ReaperPlugin.run_once('duriel', nil, function() end), true)
    c.run(300, 0.5)
    eq(t.n, 0, 'no advisory trips from inside the boss zone')
    local task = e.ReaperPlugin.status().task
    ok(task and task.name ~= 'alfred_running', 'navigation keeps running (task=' .. tostring(task and task.name) .. ')')
end)

case('RPR-3 legacy restock_count gets the same grace', function()
    local e, c, s = boot()
    s.use_alfred = true; c.zone('Town')
    local t = {n = 0}; sticky_alfred(e, t, true)
    local task = e.require('tasks.alfred')
    for _ = 1, 150 do
        c.now = c.now + 0.2; c.time(c.now)
        if task.shouldExecute() then task.Execute() end
    end
    eq(t.n, 1, 'one legacy trip in 30 s')
end)

case('RPR-3 a hard need still triggers between runs inside the lair', function()
    local e, c, s = boot()
    s.use_alfred = true
    local t = {n = 0}
    e.AlfredTheButlerPlugin = {get_status = function() return {enabled = true, need_trigger = true, inventory_full = true} end,
        trigger_tasks_with_teleport = function(_, cb) t.n = t.n + 1; cb() end}
    local task = e.require('tasks.alfred')
    eq(task.shouldExecute(), true); task.Execute(); eq(t.n, 1)
end)

-- ── RPR-4: paused / unreadable Alfred per C1 ───────────────────────────────
case('RPR-4 a foreign pause without work does not stop the run (use_alfred off)', function()
    local e, c, s = boot()
    s.use_alfred = false; c.zone('Town')
    e.AlfredTheButlerPlugin = {get_status = function() return {enabled = true, paused = true} end}
    eq(e.ReaperPlugin.run_once('duriel', nil, function() end), true)
    c.run(5)
    ok(c.boss_tps >= 1, 'boss teleport issued')
    eq(e.ReaperPlugin.status().task.name ~= 'alfred_running', true)
end)

case('RPR-4 a foreign pause without work does not stop the run (use_alfred on)', function()
    local e, c, s = boot()
    s.use_alfred = true; c.zone('Town')
    e.AlfredTheButlerPlugin = {get_status = function() return {enabled = true, paused = true} end,
        trigger_tasks_with_teleport = function() error('paused Alfred must not be triggered') end}
    eq(e.ReaperPlugin.run_once('duriel', nil, function() end), true)
    c.run(5)
    ok(c.boss_tps >= 1, 'boss teleport issued')
end)

case('RPR-4 an unreadable status holds at most ~10 s, then Alfred is unavailable', function()
    local e, c, s = boot()
    s.use_alfred = true; c.zone('Town')
    e.AlfredTheButlerPlugin = {get_status = function() error('reloading') end}
    eq(e.ReaperPlugin.run_once('duriel', nil, function() end), true)
    c.run(5)
    eq(c.boss_tps, 0, 'short hold while unreadable')
    c.run(9)
    ok(c.boss_tps >= 1, 'run continues after the bound')
    eq(c.count('treating Alfred as unavailable'), 1, 'one log line')
end)

case('RPR-4 use_alfred off: an unreadable status is not a hold', function()
    local e, c, s = boot()
    s.use_alfred = false; c.zone('Town')
    e.AlfredTheButlerPlugin = {get_status = function() error('reloading') end}
    eq(e.ReaperPlugin.run_once('duriel', nil, function() end), true)
    c.run(2)
    ok(c.boss_tps >= 1, 'boss teleport without waiting')
end)

-- ── RPR-5 / C3: Reaper's own Batmobile route always ends on release ───────
local function legacy_batmobile(e)
    local bm = {navigating = false, stops = 0, clears = 0}
    e.BatmobilePlugin = {
        navigate_long_path = function() bm.navigating = true; return true end,
        stop_long_path = function() bm.stops = bm.stops + 1; bm.navigating = false end,
        is_long_path_navigating = function() return bm.navigating end,
        reset = function() bm.navigating = false end, resume = function() end,
        clear_target = function() bm.clears = bm.clears + 1 end, update = function() end, move = function() end,
        clear_traversal_blacklist = function() end, set_target = function() return true end,
    }
    return bm
end

case('RPR-5 legacy Batmobile: yielding to a busy Alfred and disable() stop the own route', function()
    local e, c, s = boot()
    local bm = legacy_batmobile(e)
    local status = {enabled = false}
    e.AlfredTheButlerPlugin = {get_status = function() return status end}
    c.actors({c.actor('Boss_WT4_Duriel', e.vec3:new(30, 0, 0))})   -- altar 30 m away
    eq(e.ReaperPlugin.run_once('duriel', nil, function() end), true)
    c.run(3)
    eq(bm.navigating, true, 'Reaper long path to the altar')
    status = {enabled = true, trigger_tasks = true}                   -- Alfred self-triggers
    c.run(1)
    eq(bm.navigating, false, 'own route stopped while yielding'); eq(bm.clears, 0, 'Alfred goal untouched')
    status = {enabled = false}; c.run(3)
    eq(bm.navigating, true, 'route resumed after Alfred')
    status = {enabled = true, paused = true}
    e.ReaperPlugin.disable()
    eq(bm.navigating, false, 'disable() stops the route')
end)

case('RPR-5 C3 Batmobile: disable() hands off through BatmobilePlugin.release(reaper)', function()
    local e, c = boot()
    local bm = legacy_batmobile(e)
    local released = {}
    e.BatmobilePlugin.release = function(caller) released[#released + 1] = caller; bm.navigating = false end
    e.AlfredTheButlerPlugin = {get_status = function() return {enabled = true, running = true} end}
    c.actors({c.actor('Boss_WT4_Duriel', e.vec3:new(30, 0, 0))})
    eq(e.ReaperPlugin.run_once('duriel', nil, function() end), true)
    e.AlfredTheButlerPlugin = nil
    c.run(3)
    eq(bm.navigating, true)
    e.AlfredTheButlerPlugin = {get_status = function() return {enabled = true, running = true} end}
    e.ReaperPlugin.disable()
    eq(released[#released], 'reaper'); eq(bm.navigating, false)
    eq(bm.stops, 0, 'release() replaces the legacy stop/clear sequence')
end)

-- Real Batmobile (main.lua + long_path + navigator) under the Reaper route.
local V = {}; V.__index = V
function V:new(x, y, z) return setmetatable({x, y, z or 0}, self) end
function V:x() return self[1] end
function V:y() return self[2] end
function V:z() return self[3] end
local function real_batmobile()
    local b = {now = 100}
    local e = setmetatable({}, {__index = _G}); e._G = e
    local broot = SUITE .. '/Batmobile-1.0.12/'
    local player = {get_position = function() return V:new(0, 0, 0) end, get_buffs = function() return {} end,
        is_dead = function() return false end, get_attribute = function() return 0 end,
        get_active_spell_id = function() return -1 end, get_current_speed = function() return 0 end}
    e.vec3 = V; e.vec2 = V; e.get_hash = function() return 1 end
    e.get_time_since_inject = function() return b.now end
    e.get_local_player = function() return player end; e.get_player_position = player.get_position
    e.get_current_world = function() return {get_current_zone_name = function() return 'Boss_WT4_Duriel' end} end
    e.actors_manager = {get_all_actors = function() return {} end}; e.attributes = {PLAYER_IN_TOWN_LEVEL_AREA = 1}
    e.console = {print = function() end}
    e.utility = {set_height_of_valid_position = function(q) return q end, is_point_walkeable = function() return true end,
        can_cast_spell = function() return false end}
    e.pathfinder = {request_move = function() end}; e.cast_spell = {position = function() return false end}
    local function widget(v) return {get_state = function() return v and 1 or 0 end, set = function(_, n) v = n end} end
    local gui = {elements = {reset_keybind = widget(false), long_path_set_target = widget(false),
        long_path_set_target_cursor = widget(false), long_path_test = widget(false), freeroam_keybind_toggle = widget(false)},
        render = function() end}
    local settings = {normalizer = 2, step = .5, path_smooth_step = 0, log_level = 0, plugin_label = 'test', use_movement = false,
        spell_interval = .15, min_spell_dist = 3, explore_path_budget_ms = 80, update_settings = function() end, nav_viz = true}
    local tracker = {bench_enabled = false, bench_start = function() end, bench_stop = function() end,
        bench_count = function() end, bench_report = function() end, evaluated = {}, timer_update = 0, timer_move = 0}
    local explorer = {frontier_count = 0, visited_count = 0, retry_count = 0, backtrack = {}, frontier_node = {}, visited = {},
        update = function() end, reset = function() end, select_node = function() return nil end,
        clear_frontiers_in_box = function() return 0 end}
    local modules = {gui = gui, ['core.settings'] = settings, ['core.tracker'] = tracker, ['core.explorer'] = explorer,
        ['core.pathfinder'] = {find_path = function(a, q) return {a, q}, false end,
            find_path_debug = function(a, q) return {a, q}, 1, .001, 'found' end, clear_wall_penalty_cache = function() end}}
    e.require = function(name)
        if modules[name] ~= nil then return modules[name] end
        local value = assert(loadfile(broot .. name:gsub('%.', '/') .. '.lua', 't', e))(); modules[name] = value; return value
    end
    e.checkbox = {new = function() return {} end}; e.on_update = function(fn) b.update = fn end
    e.on_render_menu = function() end; e.on_render = function() end
    e.graphics = {circle_3d = function() end, line = function() end, text_2d = function() end}
    for _, color in ipairs({'white', 'green', 'red', 'blue', 'yellow'}) do e['color_' .. color] = function() return 0 end end
    e.get_screen_width = function() return 1920 end; e.get_screen_height = function() return 1080 end
    assert(loadfile(broot .. 'main.lua', 't', e))()
    b.update(); b.api = e.BatmobilePlugin; b.nav = e.require('core.navigator')
    return b
end

case('RPR-5 real Batmobile: a busy Alfred yield and disable() end the Reaper route', function()
    local b = real_batmobile()
    local e, c = boot()
    e.BatmobilePlugin = b.api
    local status = {enabled = false}
    e.AlfredTheButlerPlugin = {get_status = function() return status end}
    local altar = e.require('tasks.interact_altar')
    c.actors({c.actor('Boss_WT4_Duriel', e.vec3:new(30, 0, 0))})
    local fine, err = pcall(altar.Execute); ok(fine, tostring(err))
    eq(b.api.is_long_path_navigating(), true, 'Reaper route started on the real Batmobile')
    status = {enabled = true, external_trigger = true}
    local alfred = e.require('tasks.alfred')
    eq(alfred.shouldExecute(), true); alfred.Execute()
    eq(b.api.is_long_path_navigating(), false, 'yield ends the Reaper route')
    eq(b.nav.paused, true, 'Batmobile paused, no autonomous drive')
    status = {enabled = false}
    altar.Execute()
    eq(b.api.is_long_path_navigating(), true, 'route restarts after the yield')
    status = {enabled = true, paused = true}
    e.ReaperPlugin.disable()
    eq(b.api.is_long_path_navigating(), false, 'disable() ends the Reaper route')
end)

-- ── RPR-6: Looter before the lair exit (bounded) ────────────────────────────
local function chest_run(e, c, looter_busy)
    e.LooteerPlugin = {get_enabled = function() return true end, is_actively_looting = function() return looter_busy() end}
    eq(e.ReaperPlugin.run_once('duriel', nil, function() end), true)
    c.run(1)
    e.require('core.tracker').altar_activated = true
    local chest = c.actor('EGB_Chest_Boss', e.vec3:new(0, 0, 0)); c.actors({chest})
    c.run(1)
    chest.interactive = false
    return c.now
end

case('RPR-6 the town teleport waits for the Looter plus 3 s of quiet', function()
    local e, c = boot()
    local busy_until
    local gone = chest_run(e, c, function() return busy_until == nil or c.now < busy_until end)
    busy_until = gone + 10
    local fired
    while c.now < gone + 30 do
        c.step()
        if not fired and c.town_tps > 0 then fired = c.now end
    end
    ok(fired, 'teleport eventually fires')
    ok(fired >= busy_until + 3 - 1e-6, string.format('teleport %.1fs after despawn (Looter busy 10 s)', fired - gone))
    ok(fired <= busy_until + 4, 'no extra delay once the Looter is quiet')
end)

case('RPR-6 a never-idle Looter holds the exit at most ~30 s (C6 bound)', function()
    local e, c = boot()
    local gone = chest_run(e, c, function() return true end)
    local fired
    while c.now < gone + 60 do
        c.step()
        if not fired and c.town_tps > 0 then fired = c.now end
    end
    ok(fired and fired - gone >= 30 and fired - gone <= 36, 'bounded Looter hold (' .. tostring(fired and fired - gone) .. ')')
    eq(c.count('Looter busy for 30s'), 1, 'one log line')
end)

-- ── RPR-10 / C4: orbwalker ownership with the real settings module ──────────
local function real_settings_boot(values)
    local orb = {clear = true, block = false}
    local e, c, s = boot(function(e, c)
        local toggle = e.package.loaded.gui.elements.main_toggle
        local function el(key, default)
            return {get = function() local v = values[key]; if v == nil then return default end return v end,
                set = function(_, v) values[key] = v end}
        end
        local elements = setmetatable({main_toggle = toggle, boss_enabled = {}, belial_pool = {}},
            {__index = function(t, k) local x = el(k, 0); rawset(t, k, x); return x end})
        for _, k in ipairs({'use_alfred', 'use_batmobile', 'dungeon_reset_enabled', 'belial_chest_enabled', 'belial_show_xhairs'}) do
            elements[k] = el(k, false)
        end
        elements.manage_orbwalker = el('manage_orbwalker', true)
        elements.dungeon_reset_interval = el('dungeon_reset_interval', 10)
        e.package.loaded.gui = {elements = elements, render = function() end,
            town_data = {[0] = {zone_name = 'Town', waypoint_sno = 1}}}
        e.package.loaded['core.settings'] = nil
        e.orbwalker = {set_clear_toggle = function(v) orb.clear = v end, set_block_movement = function(v) orb.block = v end}
    end)
    return e, c, orb
end

case('RPR-10 run_once, fight and stop never leave the orbwalker clear toggle OFF', function()
    local values = {}
    local e, c, orb = real_settings_boot(values)
    c.run(0.4)                                      -- Reaper's settings pulse (manage_orbwalker ON)
    orb.clear = true                                -- WarPigs forces clear ON at the handoff
    eq(e.ReaperPlugin.run_once('duriel', nil, function() end), true)
    eq(orb.clear, true, 'synchronous run_once reset keeps clear ON')
    c.run(1)
    e.require('core.tracker').altar_activated = true
    c.run(1)
    eq(orb.clear, true); eq(orb.block, true, 'fight blocks movement')
    e.ReaperPlugin.disable()
    eq(orb.block, false, 'stop releases the block'); eq(orb.clear, true, 'stop leaves clear ON')
    values.manage_orbwalker = false; c.run(1)
    eq(orb.clear, true, 'turning management off does not force clear OFF')
end)

case('C4 switching away from the fight releases the movement block', function()
    local e, c = boot()
    eq(e.ReaperPlugin.run_once('duriel', nil, function() end), true)
    c.run(1)
    local tracker = e.require('core.tracker')
    tracker.altar_activated = true
    c.run(1)
    eq(c.blocked, true, 'Kill Monsters blocks orbwalker movement')
    tracker.altar_activated = false                 -- e.g. death reset the fight
    c.actors({c.actor('Boss_WT4_Duriel', e.vec3:new(1, 0, 0))})
    c.run(1)
    eq(e.ReaperPlugin.status().task.name, 'Interact Altar')
    eq(c.blocked, false, 'block released on the task switch')
end)

-- ── RPR-11: periodic dungeon reset under WarPigs one-shots ─────────────────
case('RPR-11 a due dungeon reset runs in town before the run reports', function()
    local e, c, s = boot()
    s.dungeon_reset_enabled = true; s.dungeon_reset_interval = 1
    local resets_at_callback = {}
    for run_no = 1, 2 do
        c.zone('Boss_WT4_Duriel')
        eq(e.ReaperPlugin.run_once('duriel', nil, function() resets_at_callback[run_no] = c.resets end), true)
        c.run(1)
        e.require('core.boss_rotation').consume_run()
        c.run(1)
        c.zone('Town'); c.run(6)
    end
    eq(resets_at_callback[1], 1, 'first one-shot reset before its callback')
    eq(resets_at_callback[2], 2, 'second one-shot reset too (baseline kept across run_once)')
end)

-- ── C5: yielding to Alfred does not count toward the chest timeout ─────────
case('C5 Alfred yields during WAIT_GONE do not abandon the chest', function()
    local e, c = boot()
    local status = {enabled = false}
    e.AlfredTheButlerPlugin = {get_status = function() return status end}
    eq(e.ReaperPlugin.run_once('duriel', nil, function() end), true)
    c.run(1)
    e.require('core.tracker').altar_activated = true
    local chest = c.actor('EGB_Chest_Boss', e.vec3:new(0, 0, 0)); c.actors({chest})
    c.run(1)                                        -- chest interacted -> WAIT_GONE
    for _ = 1, 3 do
        status = {enabled = true, external_trigger = true}  -- foreign Alfred trip
        c.run(15)
        status = {enabled = false}
        c.run(1)
    end
    local rot = e.require('core.boss_rotation')
    eq(rot.failed, false, 'chest not abandoned')
    eq(c.count("Chest didn't despawn"), 0, 'yield time is not a despawn timeout')
    chest.interactive = false
    c.run(5)
    eq(rot.external_consumed, true, 'run completes normally')
end)

-- ── C6: long Alfred holds are visible ──────────────────────────────────────
case('C6 a long Alfred hold is logged once and shown in status', function()
    local e, c = boot()
    e.AlfredTheButlerPlugin = {get_status = function() return {enabled = true, running = true} end}
    eq(e.ReaperPlugin.run_once('duriel', nil, function() end), true)
    c.run(70, 0.5)
    local reason = e.ReaperPlugin.status().hold_reason
    ok(type(reason) == 'string' and reason:find('Alfred busy', 1, true), 'hold_reason=' .. tostring(reason))
    eq(c.count('Holding for Alfred'), 1, 'logged once')
end)

-- ── Joint: real WarPigs orchestrator + real Reaper ─────────────────────────
local function warpigs_joint()
    local e, c, s, p = boot()
    local f = {now = 100, world = 'Sanctuary', zone = 'Skov_Temis', quests = {}, logs = {}}
    local w = setmetatable({}, {__index = _G}); w._G = w
    w.console = {print = function(m) f.logs[#f.logs + 1] = tostring(m) end}
    w.attributes = {PLAYER_IN_TOWN_LEVEL_AREA = 'town'}
    w.get_time_since_inject = function() return f.now end
    w.get_local_player = function() return {is_dead = function() return false end,
        get_attribute = function() return 1 end, get_buffs = function() return {} end} end
    w.get_current_world = function()
        return {get_name = function() return f.world end, get_current_zone_name = function() return f.zone end}
    end
    w.get_quests = function() return f.quests end
    w.actors_manager = {get_all_actors = function() return {} end}
    w.teleport_to_waypoint = function() end
    w.warplan = {teleport_to_activity = function() end}
    w.get_aether_count = function() return 0 end
    w.revive_at_checkpoint = function() end
    local wsettings = {enabled = true, manage_whispers = false, use_teleport_transition = false}
    local modules = {['core.settings'] = wsettings, ['core.tasks.turn_in_rewards'] = {tick = function() end}}
    local wroot = SUITE .. '/WarPigs-1.0.0/'
    w.require = function(name)
        if modules[name] then return modules[name] end
        local value = assert(loadfile(wroot .. name:gsub('%.', '/') .. '.lua', 't', w))()
        modules[name] = value; return value
    end
    f.o = w.require('core.orchestrator'); f.w = w
    w.ReaperPlugin = e.ReaperPlugin
    function f.set_quest(...)
        local q = {}
        for _, n in ipairs({...}) do q[#q + 1] = {get_name = function() return n end} end
        f.quests = q
    end
    function f.count(pattern)
        local n = 0
        for _, m in ipairs(f.logs) do if m:find(pattern, 1, true) then n = n + 1 end end
        return n
    end
    function f.run(seconds)
        local stop_at = f.now + seconds
        while f.now < stop_at do f.now = f.now + 0.5; c.now = f.now; c.time(f.now); c.update(); f.o.tick() end
    end
    return e, c, s, p, f
end

case('Joint RPR-2: WarPigs releases a manually started Reaper and runs the Pit', function()
    local e, c, s, p, f = warpigs_joint()
    local item = {get_acd = function() return 7 end, get_sno_id = function() return 2558255 end,
        get_stack_count = function() return 9 end}
    p.get_dungeon_key_items = function() return {item} end
    e.ReaperPlugin.enable()
    f.run(5)
    local arkham = {enabled = false, enables = 0}
    arkham.enable = function() arkham.enabled = true; arkham.enables = arkham.enables + 1 end
    arkham.disable = function() arkham.enabled = false end
    arkham.status = function() return {enabled = arkham.enabled} end
    f.w.ArkhamAsylumPlugin = arkham
    f.set_quest('WarPlans_QST_ThePit')
    f.run(60)
    eq(e.ReaperPlugin.status().enabled, false, 'Reaper released')
    eq(e.ReaperPlugin.status().last_result, 'cancelled')
    ok(arkham.enables >= 1, 'Pit plugin enabled')
end)

case('Joint WPD-6: a failing boss is reported with its reason and backed off', function()
    local e, c, s, p, f = warpigs_joint()
    local calls = 0
    local real = e.ReaperPlugin.run_once
    e.ReaperPlugin.run_once = function(...) calls = calls + 1; return real(...) end
    c.zone('Town')                                  -- boss teleport never lands
    f.set_quest('WarPlans_QST_BossLair_Duriel')
    f.run(1800)
    ok(calls >= 1 and calls <= 3, 'run_once dispatched ' .. calls .. ' times in 30 min')
    ok(f.count('Boss teleport failed repeatedly') >= 1, 'WarPigs logged the Reaper failure reason')
end)

print(string.format('Reaper integration: %d cases, %d checks, %d failures', cases, checks, #failures))
if #failures > 0 then error('Reaper integration failures:\n' .. table.concat(failures, '\n')) end
print('PASS: test_integration_reaper (' .. cases .. ' cases)')
