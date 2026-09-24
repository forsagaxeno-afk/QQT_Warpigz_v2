-- ArkhamAsylum integration regressions (ARK-1/3/4/5/7/8/9, C1-C5).
-- Loads the REAL ArkhamAsylum main.lua -> gui/settings/external/task_manager
-- and every task with a per-plugin module cache. Only QQT host bindings,
-- Batmobile, AlfredTheButler and Looteer are behaviour-level mocks.
local ROOT = assert(SUITE_ROOT) .. '/ArkhamAsylum-1.0.6/'
local checks, failures = 0, {}
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        checks = checks + 1
        print('PASS arkham integration: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL arkham integration: ' .. name .. ': ' .. tostring(err))
    end
end

local function vector(x, y, z)
    local v = {xx = x or 0, yy = y or 0, zz = z or 0}
    function v:x() return self.xx end
    function v:y() return self.yy end
    function v:z() return self.zz end
    function v:dist_to(o) return math.sqrt((self.xx - o:x())^2 + (self.yy - o:y())^2 + (self.zz - o:z())^2) end
    return v
end
local function actor(name, x, opts)
    opts = opts or {}
    local a = {name = name, position = vector(x or 0, opts.y or 0), health = opts.health or 100,
        interactable = opts.interactable ~= false, boss = opts.boss or false}
    function a:get_skin_name() return self.name end
    function a:get_position() return self.position end
    function a:is_interactable() return self.interactable end
    function a:get_current_health() return self.health end
    function a:is_boss() return self.boss end
    function a:is_elite() return false end
    function a:is_champion() return false end
    function a:is_untargetable() return false end
    function a:is_dead() return self.health <= 0 end
    function a:get_active_spell_id() return 0 end
    return a
end

local TOWN = {'Skov_Temis_World', 'Skov_Temis', 7}
local PIT = {'PIT_Test', 'PIT_Subzone', 1}

local function session(opts)
    opts = opts or {}
    local s = {now = 1000, actors = {}, enemies = {}, floor_loot = false, log = {}, waypoints = {},
        resets = 0, interactions = {}, looting = false, orb = {}, glyphs = {}, upgrades = {},
        pit_opens = 0, vendor = false}
    local where = opts.town and TOWN or PIT
    s.world, s.zone, s.world_id = where[1], where[2], where[3]
    function s.go(place) s.world, s.zone, s.world_id = place[1], place[2], place[3] end
    s.player = actor('Player', 0)
    local env = setmetatable({}, {__index = _G})
    env._G = env
    local function widget(default)
        local w = {v = default}
        function w:get() return self.v end
        function w:set(v) self.v = v end
        function w:render() end
        function w:push() return false end
        function w:pop() end
        return w
    end
    env.checkbox = {new = function(_, d) return widget(d) end}
    env.combo_box = {new = function(_, d) return widget(d) end}
    env.slider_int = {new = function(_, _, _, d) return widget(d) end}
    env.tree_node = {new = function() return widget(nil) end}
    env.keybind = {new = function(_, key, st)
        local w = widget(st); w.key = key; w.state = st and 1 or 0
        function w:get_key() return self.key end
        function w:get_state() return self.state end
        function w:set(v) self.state = v and 1 or 0 end
        return w
    end}
    env.get_hash = function(x) return x end
    env.render_menu_header = function() end
    env.console = {print = function(m) s.log[#s.log + 1] = tostring(m) end}
    env.get_time_since_inject = function() return s.now end
    env.get_local_player = function() return s.player end
    env.get_player_position = function() return s.player.position end
    env.get_current_world = function()
        return {get_name = function() return s.world end,
            get_current_zone_name = function() return s.zone end,
            get_world_id = function() return s.world_id end}
    end
    env.vec3 = {new = function(_, x, y, z) return vector(x, y, z) end}
    env.vec2 = {new = function() return {} end}
    env.actors_manager = {get_ally_actors = function() return s.actors end,
        get_all_actors = function() return s.actors end}
    env.target_selector = {get_near_target_list = function() return s.enemies end}
    env.loot_manager = {any_item_around = function() return s.floor_loot end,
        is_in_vendor_screen = function() return s.vendor end}
    env.interact_object = function(a) s.interactions[#s.interactions + 1] = {actor = a, t = s.now} end
    env.teleport_to_waypoint = function(sno) s.waypoints[#s.waypoints + 1] = {t = s.now, sno = sno} end
    env.reset_all_dungeons = function() s.resets = s.resets + 1 end
    env.revive_at_checkpoint = function() end
    env.utility = {open_pit_portal = function() s.pit_opens = s.pit_opens + 1 end}
    env.pathfinder = {force_move_raw = function() end, request_move = function() end}
    env.orbwalker = {set_clear_toggle = function(v) s.orb.clear = v end,
        set_block_movement = function(v) s.orb.block = v end}
    env.get_glyphs = function() return s.glyphs end
    env.upgrade_glyph = function(g) s.upgrades[#s.upgrades + 1] = g end
    env.get_screen_width = function() return 1920 end
    env.graphics = {text_2d = function(msg) s.overlay = msg end}
    env.color_white = function() return 0 end
    local cbs = {}
    env.on_update = function(f) cbs.update = f end
    env.on_render = function(f) cbs.render = f end
    env.on_render_menu = function(f) cbs.menu = f end

    -- Batmobile: a long route keeps driving autonomously while navigating
    -- and not paused (Batmobile main.lua), like the real module.
    local bm = {paused = false, navigating = false, target = nil, calls = {}, priority = 'direction'}
    s.bm = bm
    local function rec(n, c) bm.calls[#bm.calls + 1] = {name = n, caller = c, t = s.now} end
    env.BatmobilePlugin = {
        pause = function(c) rec('pause', c); bm.paused = true end,
        resume = function(c) rec('resume', c); bm.paused = false end,
        reset = function(c) rec('reset', c); bm.navigating = false; bm.target = nil end,
        reset_movement = function(c) rec('reset_movement', c) end,
        update = function() end, move = function() end,
        set_priority = function(c, p) rec('set_priority', c); bm.priority = p end,
        clear_traversal_blacklist = function() end,
        set_target = function(c, t) rec('set_target', c); bm.target = t; return true end,
        clear_target = function(c) rec('clear_target', c); bm.target = nil end,
        navigate_long_path = function(c, t) rec('navigate_long_path', c); bm.navigating = true
            bm.paused = false; bm.target = t; return true end,
        stop_long_path = function(c) rec('stop_long_path', c); bm.navigating = false end,
        is_long_path_navigating = function() return bm.navigating end,
        is_traversal_routing = function() return false end,
        is_trapped = function() return false end,
        is_done = function() return false end,
        get_closeby_node = function(_, t) return t end,
    }
    if opts.release then
        -- C3 contract shape (owner-aware in the real module).
        env.BatmobilePlugin.release = function(c)
            rec('release', c); bm.navigating = false; bm.target = nil; bm.paused = true
            bm.priority = 'direction'; return true
        end
    end
    function s.batmobile_autodriving() return bm.navigating and not bm.paused end
    function s.count(name, caller, since)
        local n = 0
        for _, c in ipairs(bm.calls) do
            if c.name == name and (caller == nil or c.caller == caller) and (since == nil or c.t >= since) then n = n + 1 end
        end
        return n
    end

    -- AlfredTheButler: source-shaped status and async completion callback.
    local al = {enabled = true, need_trigger = false, inventory_full = false, need_repair = false,
        trigger_tasks = false, teleport = false, teleport_done = false, teleport_failed = false,
        restock_count = 0, paused = false, triggers = {}}
    s.alfred = al
    env.AlfredTheButlerPlugin = {
        get_status = function()
            if s.alfred_error then error('reloading') end
            return {enabled = al.enabled, need_trigger = al.need_trigger, inventory_full = al.inventory_full,
                need_repair = al.need_repair, trigger_tasks = al.trigger_tasks, teleport = al.teleport,
                teleport_done = al.teleport_done, teleport_failed = al.teleport_failed,
                restock_count = al.restock_count, paused = al.paused}
        end,
        trigger_tasks = function(caller, cb)
            al.triggers[#al.triggers + 1] = {t = s.now, caller = caller, teleport = false}; al.cb = cb
        end,
        trigger_tasks_with_teleport = function(caller, cb)
            al.triggers[#al.triggers + 1] = {t = s.now, caller = caller, teleport = true}; al.cb = cb
            al.teleport, al.teleport_done = true, false
        end,
    }
    function s.alfred_pickup() al.trigger_tasks = true end
    function s.alfred_complete()
        al.trigger_tasks = false; al.teleport_done = al.teleport
        local cb = al.cb; al.cb = nil
        if cb then cb() end
    end
    env.LooteerPlugin = {get_enabled = function() return true end,
        is_actively_looting = function() return s.looting == true end}

    local modules = {}
    env.require = function(name)
        if s.poison_require then error('late require of ' .. name) end
        if modules[name] ~= nil then return modules[name] end
        local chunk = assert(loadfile(ROOT .. name:gsub('%.', '/') .. '.lua', 't', env))
        local r = chunk(); if r == nil then r = true end
        modules[name] = r
        return r
    end
    assert(loadfile(ROOT .. 'main.lua', 't', env))()
    s.env, s.mod, s.api = env, modules, env.ArkhamAsylumPlugin
    s.gui, s.tracker, s.tm = modules['gui'], modules['core.tracker'], modules['core.task_manager']
    function s.frame(dt) s.now = s.now + (dt or 0.1); cbs.update() end
    function s.frames(n, dt) for _ = 1, n do s.frame(dt) end end
    function s.run_for(seconds, dt) local stop = s.now + seconds; while s.now < stop do s.frame(dt) end end
    function s.task() return s.tm.get_current_task().name end
    function s.logged(text)
        for _, l in ipairs(s.log) do if l:find(text, 1, true) then return true end end
        return false
    end
    return s
end

-------------------------------------------------------------------------------
-- ARK-1: preemption never erases the sticky-need_trigger grace.
test('ARK-1 sticky restock need_trigger does not re-trigger Alfred right after a cycle in town', function()
    local s = session({town = true})
    s.actors = {actor('TWN_Kehj_IronWolves_PitKey_Crafter', 30)}
    s.api.enable()
    s.alfred.need_trigger = true; s.alfred.restock_count = 1 -- advisory, never clears
    local guard = 0
    while #s.alfred.triggers == 0 and guard < 50 do s.frame(); guard = guard + 1 end
    assert(#s.alfred.triggers == 1, 'first advisory cycle in town is allowed')
    s.alfred_pickup(); s.frames(10, 0.2); s.alfred_complete()
    local done_at = s.now
    local walks = 0
    for _ = 1, 280 do -- 28 s, inside the 30 s grace
        s.frame()
        if s.task() == 'enter_pit' then walks = walks + 1 end
    end
    assert(#s.alfred.triggers == 1, string.format('re-triggered %.1fs after completion',
        (s.alfred.triggers[2] or {t = 0}).t - done_at))
    assert(walks > 100 and s.count('set_target', 'arkham_asylum', done_at) > 0, 'enter_pit made no progress')
end)

test('ARK-1 advisory-only Alfred flags never pull Arkham out of a pit; hard needs still do', function()
    local s = session()
    s.api.enable()
    s.alfred.need_trigger = true; s.alfred.restock_count = 1
    s.run_for(10)
    assert(#s.alfred.triggers == 0 and #s.waypoints == 0, 'left the pit for a restock flag')
    s.alfred.inventory_full = true
    s.run_for(1)
    assert(#s.alfred.triggers == 1, 'inventory_full must still start a trip')
end)

-------------------------------------------------------------------------------
-- ARK-3: returning to the same pit world after an Alfred trip resumes the run.
test('ARK-3 same pit after an Alfred round trip keeps deadline, boss state and explorer map', function()
    local s = session()
    s.api.enable()
    s.frames(3)
    local t0 = s.tracker.pit_start_time
    s.now = s.now + 500
    s.tracker.boss_dead = true; s.tracker.glyph_anchor_pos = vector(5)
    s.floor_loot = true; s.alfred.need_trigger = true; s.alfred.inventory_full = true
    s.frames(2)
    assert(#s.alfred.triggers == 1 and s.alfred.triggers[1].teleport, 'with-teleport trip from the pit')
    s.go(TOWN); s.alfred_pickup(); s.frames(10, 0.2)
    s.alfred.inventory_full = false; s.alfred.need_trigger = false
    s.go(PIT); s.alfred_complete(); s.frames(60)
    assert(s.tracker.pit_start_time == t0, string.format('deadline restarted (%.1f -> %.1f)', t0, s.tracker.pit_start_time))
    assert(s.tracker.boss_dead == true and s.tracker.glyph_anchor_pos ~= nil, 'boss/glyph floor state wiped')
    assert(s.count('reset', 'arkham_asylum') == 1, 'explorer map wiped on re-entry')
    assert(s.logged('resuming the run'), 'resume is logged once')
    -- Leaving again without an Alfred trip and coming back is a new run.
    s.go(TOWN); s.frames(3); s.go(PIT); s.frames(3)
    assert(s.tracker.pit_start_time > t0 and s.tracker.boss_dead == false, 'plain re-entry must be a new run')
end)

-- R10: a floor reached through a portal has the portal up to the previous
-- floor next to its arrival point. Resuming that floor after an Alfred trip
-- must keep it blacklisted instead of walking back up a floor.
test('R10 resuming a floor reached via portal keeps its back portal blacklisted', function()
    local s = session()
    s.api.enable(); s.frames(3)
    local descend = actor('Prefab_Portal_Dungeon_Generic', 2)
    s.actors = {descend}
    s.frames(3)
    assert(#s.interactions >= 1 and s.interactions[#s.interactions].actor == descend, 'descend portal used')
    local FLOOR2 = {'PIT_Test_Floor2', 'PIT_Subzone', 2}
    local back = actor('Prefab_Portal_Dungeon_Generic', -5)
    s.go(FLOOR2); s.actors = {back}; s.interactions = {}
    s.frames(5)
    assert(s.logged('back-portal blacklisted'), 'arrival back portal blacklisted')
    assert(s.task() ~= 'portal', 'back portal taken on arrival')
    -- Alfred with-teleport trip from this floor and back to the same floor
    s.floor_loot = true; s.alfred.need_trigger = true; s.alfred.inventory_full = true
    s.frames(2)
    assert(#s.alfred.triggers == 1 and s.alfred.triggers[1].teleport, 'with-teleport trip from floor 2')
    s.go(TOWN); s.actors = {}; s.alfred_pickup(); s.frames(10, 0.2)
    s.floor_loot = false; s.alfred.inventory_full = false; s.alfred.need_trigger = false
    s.go(FLOOR2); s.actors = {back}; s.alfred_complete()
    local took_back = false
    for _ = 1, 40 do
        s.frame()
        if s.task() == 'portal' then took_back = true end
    end
    assert(s.logged('resuming the run'), 'same floor resumed')
    assert(not took_back and #s.interactions == 0, 'resumed floor walked back into the portal it arrived through')
    assert(s.logged('back-portal blacklist near'), 'kept blacklist is logged')
    -- A different pit world afterwards starts without that blacklist.
    s.go(TOWN); s.frames(3); s.go({'PIT_Other', 'PIT_Subzone', 9}); s.actors = {actor('Prefab_Portal_Dungeon_Generic', -5)}
    s.frames(3)
    assert(s.task() == 'portal', 'a new run does not inherit the old floor\'s blacklist')
end)

test('ARK-3 opening a new pit discards the pending resume', function()
    local s = session()
    s.api.enable(); s.frames(3)
    s.alfred.need_trigger = true; s.alfred.inventory_full = true
    s.frames(2)
    assert(#s.alfred.triggers == 1 and not s.alfred.triggers[1].teleport, 'plain trip + own town hop')
    s.go(TOWN); s.frames(2)
    assert(s.tracker.resume_key ~= nil, 'left the pit for an Alfred trip')
    s.alfred_complete(); s.alfred.need_trigger = false; s.alfred.inventory_full = false
    s.actors = {actor('TWN_Kehj_IronWolves_PitKey_Crafter', 1)}; s.vendor = true
    s.run_for(3)
    assert(s.pit_opens >= 1 and s.tracker.resume_key == nil, 'a newly opened pit cannot resume the old run')
end)

-------------------------------------------------------------------------------
-- ARK-4: glyph upgrade first; Alfred and glyph yield to Looter the same way.
test('ARK-4 full inventory waits for the glyph upgrade instead of leaving the pit', function()
    local s = session()
    s.api.enable(); s.frames(3)
    s.actors = {actor('Gizmo_Paragon_Glyph_Upgrade', 1)}
    s.looting = true
    s.alfred.need_trigger = true; s.alfred.inventory_full = true
    s.run_for(5)
    assert(#s.alfred.triggers == 0 and #s.waypoints == 0, 'Alfred trip started before the glyph upgrade')
    s.looting = false
    s.run_for(12)
    assert(#s.interactions >= 1, 'glyphstone never touched')
    assert(s.tracker.glyph_done, 'glyph upgrade did not finish')
    s.run_for(3)
    assert(#s.alfred.triggers == 1 and s.alfred.triggers[1].t > s.interactions[1].t,
        'Alfred must start after the glyph interaction')
end)

test('ARK-4 a Looter that never goes idle delays the glyph upgrade only for a bounded time', function()
    local s = session()
    s.api.enable(); s.frames(3)
    s.actors = {actor('Gizmo_Paragon_Glyph_Upgrade', 1)}
    s.looting = true
    s.run_for(30)
    assert(#s.interactions == 0, 'glyph must yield to an active Looter at first')
    s.run_for(20)
    assert(#s.interactions >= 1, 'glyph upgrade held forever by Looter')
    assert(s.logged('Looter busy for'), 'bounded Looter yield is logged')
end)

test('ARK-4 an Alfred trip yields to an active Looter (bounded) like the glyph upgrade', function()
    local s = session()
    s.api.enable(); s.frames(3)
    s.looting = true
    s.alfred.need_trigger = true; s.alfred.inventory_full = true
    s.run_for(15)
    assert(#s.alfred.triggers == 0, 'Alfred trip started while Looter collects')
    s.run_for(8)
    assert(#s.alfred.triggers == 1, 'Alfred trip held forever by Looter')
end)

-------------------------------------------------------------------------------
-- ARK-5 / ARK-8 / C3: Arkham's own Batmobile route never survives a hand-off.
for _, mode in ipairs({'foreign_trigger', 'status_error'}) do
    test('ARK-5 hand-off to a busy Alfred stops Arkham\'s own long path (' .. mode .. ', no release API)', function()
        local s = session()
        s.api.enable()
        s.actors = {actor('TWR_ProgressOrb', 40)}
        s.frames(3)
        assert(s.task() == 'explore_pit' and s.bm.navigating, 'orb long path active')
        local handoff = s.now
        if mode == 'foreign_trigger' then s.alfred.trigger_tasks = true else s.alfred_error = true end
        s.frames(3)
        assert(s.task() == 'alfred_running', 'Alfred owns control')
        assert(s.count('stop_long_path', 'arkham_asylum', handoff) >= 1 and not s.bm.navigating,
            'Arkham long path left armed')
        assert(s.count('clear_target', 'arkham_asylum', handoff) == 0,
            'older Batmobile: a companion may own the target, only the own route stops')
        s.api.disable()
        s.go(TOWN)
        s.env.BatmobilePlugin.resume('wonder_city')
        assert(not s.batmobile_autodriving(), 'stale pit route re-driven after the next resume')
    end)
end

test('ARK-5/ARK-8 C3 release is used on hand-off and disable, also while Alfred is busy', function()
    local s = session({release = true})
    s.gui.elements.batmobile_priority:set(1) -- 'distance'
    s.api.enable()
    s.actors = {actor('TWR_ProgressOrb', 40)}
    s.frames(3)
    local handoff = s.now
    s.alfred.trigger_tasks = true
    s.frames(3)
    assert(s.count('release', 'arkham_asylum', handoff) >= 1 and not s.bm.navigating, 'hand-off did not release')
    local before = s.count('release', 'arkham_asylum')
    s.api.disable()
    assert(s.count('release', 'arkham_asylum') == before + 1, 'disable during an Alfred trip did not release')
    assert(s.bm.priority == 'direction', 'explorer priority leaked')
end)

test('ARK-8 older Batmobile: disable restores the default explorer priority', function()
    local s = session()
    s.gui.elements.batmobile_priority:set(1)
    s.api.enable(); s.frames(3)
    assert(s.bm.priority == 'distance', 'explore_pit applies the pit priority')
    s.api.disable()
    assert(s.bm.priority == 'direction' and not s.bm.navigating, 'priority/route leaked to the next plugin')
end)

-------------------------------------------------------------------------------
-- ARK-7: enable() works with 'Use keybind' on and no key bound.
test('ARK-7 external enable succeeds with an unbound keybind; manual gate unchanged', function()
    local s = session({town = true})
    s.gui.elements.use_keybind:set(true) -- ticked, never bound (0x0A)
    s.api.enable()
    assert(s.api.get_status().enabled == true, 'enable() did not result in enabled status')
    s.frames(3)
    assert(s.task() ~= 'Idle', 'enabled Arkham does not run')
    assert(s.logged('no key is bound'), 'misconfiguration is logged')
    s.api.disable()
    assert(s.api.get_status().enabled == false, 'disable() must stick')
    s.gui.elements.main_toggle:set(true) -- the user, not an external controller
    s.frames(2)
    assert(s.api.get_status().enabled == false, 'manual keybind gate changed')
end)

-------------------------------------------------------------------------------
-- ARK-9 / WCY-6 (C1): an unreadable Alfred status is bounded and never blocks the forced exit.
test('ARK-9 unreadable Alfred status holds at most ~10s, then Arkham continues', function()
    local s = session()
    s.api.enable(); s.frames(3)
    s.alfred_error = true
    s.run_for(5)
    assert(s.task() == 'alfred_running', 'unknown status holds briefly')
    s.run_for(7)
    assert(s.task() ~= 'alfred_running', 'unknown status pins Arkham')
    assert(s.logged('unreadable'), 'unavailable Alfred is logged')
end)

test('ARK-9 reset timeout exits even while Alfred status is unreadable', function()
    local s = session()
    s.api.enable(); s.frames(3)
    s.alfred_error = true
    s.now = s.tracker.pit_start_time + 700
    s.frame()
    assert(s.task() == 'exit_pit', 'forced exit blocked by unknown Alfred')
    s.run_for(12)
    assert(s.resets >= 1, 'reset never issued')
end)

-------------------------------------------------------------------------------
-- C1: a paused Alfred is idle without hard work; with hard work the hold is bounded and visible.
test('C1 paused Alfred with advisory flags does not hold Arkham in town', function()
    local s = session({town = true})
    s.actors = {actor('TWN_Kehj_IronWolves_PitKey_Crafter', 30)}
    s.api.enable()
    s.alfred.paused = true; s.alfred.need_trigger = true; s.alfred.restock_count = 1
    s.run_for(3)
    assert(s.task() == 'enter_pit', 'paused Alfred with advisory work pinned Arkham: ' .. s.task())
end)

test('C1/C6 paused Alfred with hard work: visible bounded hold, then continue', function()
    local s = session({town = true})
    s.actors = {actor('TWN_Kehj_IronWolves_PitKey_Crafter', 30)}
    s.api.enable()
    s.alfred.paused = true; s.alfred.need_trigger = true; s.alfred.inventory_full = true
    s.run_for(5)
    assert(s.task() == 'alfred_running' and s.api.get_status().task:find('paused', 1, true), 'hold is not visible')
    s.run_for(60)
    assert(s.task() == 'enter_pit', 'paused Alfred held Arkham forever')
    assert(s.logged('continuing without it'), 'bounded hold is logged')
    assert(#s.alfred.triggers == 0, 'a paused Alfred is never triggered')
end)

-------------------------------------------------------------------------------
-- C2 provider fields.
test('C2 get_status exposes alfred_trip, in_run and committed_entry', function()
    local s = session({town = true})
    s.actors = {actor('TWN_Kehj_IronWolves_PitKey_Crafter', 1)}
    local st = s.api.get_status()
    assert(st.alfred_trip == false and st.in_run == false and st.committed_entry == false, 'fields missing')
    s.api.enable(); s.vendor = true
    s.run_for(2)
    st = s.api.get_status()
    assert(s.pit_opens >= 1 and st.committed_entry == true and st.in_run == true, 'entry under way not reported')
    s.vendor = false; s.actors = {}
    s.go(PIT); s.frames(3)
    st = s.api.get_status()
    assert(st.in_run == true and st.committed_entry == false and st.alfred_trip == false, 'in-pit status')
    -- own with-teleport trip: town leg and a callback that lands before the return portal
    s.floor_loot = true; s.alfred.need_trigger = true; s.alfred.inventory_full = true
    s.frames(2)
    assert(s.api.get_status().alfred_trip == true, 'own request in flight')
    s.go(TOWN); s.alfred_pickup(); s.frames(5)
    st = s.api.get_status()
    assert(st.alfred_trip == true and st.in_run == true, 'town leg of the own trip')
    s.floor_loot = false; s.alfred.need_trigger = false; s.alfred.inventory_full = false
    s.alfred_complete(); s.frames(2)
    assert(s.api.get_status().alfred_trip == true, 'callback before the return portal ends the trip too early')
    s.go(PIT); s.frames(2)
    assert(s.api.get_status().alfred_trip == false, 'trip must end back in the pit')
    s.api.disable()
    st = s.api.get_status()
    assert(st.alfred_trip == false and st.committed_entry == false, 'released plugin still reports work')
end)

-------------------------------------------------------------------------------
-- C4: orbwalker block_movement is released on task switch and release.
test('C4 block_movement is released when a combat task hands off and on disable', function()
    local s = session()
    s.gui.elements.manage_orbwalker:set(true)
    s.api.enable(); s.frames(3)
    assert(s.orb.block == true, 'explore_pit blocks orbwalker movement')
    s.alfred.trigger_tasks = true
    s.frames(2)
    assert(s.task() == 'alfred_running' and s.orb.block == false, 'movement stayed blocked during the Alfred trip')
    s.alfred.trigger_tasks = false
    s.frames(3)
    assert(s.orb.block == true, 'combat task re-blocks')
    s.gui.elements.manage_orbwalker:set(false) -- user unticks while blocked
    s.frames(1)
    s.api.disable()
    assert(s.orb.block == false and s.orb.clear == true, 'release skipped because the option was unticked')
end)

-------------------------------------------------------------------------------
-- C5: yielding to Alfred/Looter never counts toward walk/stuck windows.
test('C5 an in-place Alfred yield does not blacklist the Burden Altar being walked to', function()
    local s = session()
    s.api.enable(); s.frames(3)
    s.actors = {actor('Warplans_Pit_ChoronsBurden_Receptacle', 20)}
    s.run_for(5)
    assert(s.task() == 'use_burden_altar', 'walking to the altar')
    s.alfred.trigger_tasks = true -- foreign cycle, no world change
    s.run_for(40)
    s.alfred.trigger_tasks = false
    s.run_for(2)
    assert(not s.logged('walk timeout'), 'Alfred yield counted as walking time')
    assert(s.task() == 'use_burden_altar', 'altar abandoned after the yield')
end)

test('C5 a Looter yield mid-upgrade does not finish the glyph as "no glyphs available"', function()
    local s = session()
    s.api.enable(); s.frames(3)
    s.actors = {actor('Gizmo_Paragon_Glyph_Upgrade', 1)}
    s.run_for(1)
    local first = #s.interactions
    assert(first >= 1, 'glyphstone interacted')
    s.looting = true
    s.run_for(20)
    s.looting = false
    s.run_for(1)
    assert(not s.tracker.glyph_done, 'Looter yield consumed the empty-list window')
    assert(#s.interactions > first, 'glyphstone re-interacted after the yield')
end)

-------------------------------------------------------------------------------
-- Module cache: nothing in Arkham resolves modules after load.
test('no late require from the exported API or the scheduler (shared module cache)', function()
    local s = session()
    s.poison_require = true
    s.api.enable()
    s.now = s.tracker.pit_start_time + 700 -- exercises utils.exit_pit_forced
    s.frames(5)
    local st = s.api.get_status()
    assert(st.enabled == true and st.in_run == true)
    s.api.disable()
end)

if #failures > 0 then
    error(#failures .. ' Arkham integration regression(s) failed:\n' .. table.concat(failures, '\n'))
end
print('PASS: Arkham integration: ' .. checks .. ' regressions passed')
