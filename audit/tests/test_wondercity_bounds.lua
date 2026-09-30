-- QQT_Warpigz_v3: WonderCity night-review regressions (area wondercity).
-- Each case failed on the pre-fix tree and passes after the fix:
--   B1 a boss seen once no longer idles the explorers for the whole floor
--      (dead miniboss without a chest; a revive far from the boss walks back)
--   B2 bounded walks (C6): an unreachable enticement, PortalSwitch/warp pad,
--      boss or goblin is given up (no progress or set_target()==false)
--   B3 Rosie serves Temis only: a request from Kurast is a completed trip
--      (no return leg, no fail_streak); a missing return portal after a
--      complete service is not a failure either
--   B4 WonderCity holds its movement while the Looter picks up (bounded)
--   B5 ACCEPT with the vendor closed and no portal restarts at the brazier
--   B6 a script reload keeps the reward-phase state of the same Undercity
--   B7 (QQT_Warpigz_v3, live "failed to leave floor 1") the floor exit
--      (PortalSwitch / warp pad) and the Grand Beacon are only set aside
--      after a failed walk (20 s, 40 s, 60 s cap) and the floor is left;
--      joint host with the real Batmobile on a closed floor
-- Unit cases use the QQT-shaped harness of test_wondercity.lua; B3 uses the
-- joint host with the real Rosie, B7 the joint host with the real Batmobile. Runs under Lua 5.4 and LuaJIT.
local SUITE = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local root = SUITE .. '/WonderCity/'
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
    if passed then print('PASS WonderCity bounds: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL WonderCity bounds: ' .. name .. ': ' .. tostring(err)) end
end

local function vector(x, y, z)
    local v = {xx = x, yy = y or 0, zz = z or 0}
    function v:x() return self.xx end
    function v:y() return self.yy end
    function v:z() return self.zz end
    function v:squared_dist_to_ignore_z(other) return (self:x()-other:x())^2+(self:y()-other:y())^2 end
    function v:dist_to(other)
        return math.sqrt((self:x()-other:x())^2+(self:y()-other:y())^2+(self:z()-other:z())^2)
    end
    return v
end
local next_actor_id = 0
local function actor(name, x, options)
    options = options or {}
    local a = {name = name, position = vector(x or 0), health = options.health or 100,
        interactable = options.interactable ~= false, boss = options.boss or false}
    next_actor_id = next_actor_id + 1
    a.id = next_actor_id
    function a:get_id() return self.id end
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
local function glyph(hash, level)
    local g = {glyph_name_hash=hash, level=level, allowed=true}
    function g:get_level() return self.level end
    function g:get_upgrade_chance() return 1 end
    function g:can_upgrade() return self.allowed end
    function g:get_max_level() return 100 end
    return g
end
local function session()
    local s = {now=100, world_name='Undercity_First', world_id=1, zone='X1_Undercity_First',
        actors={}, enemies={}, items={}, keys={}, glyphs={}, mouse={}, vendor=false, key_slot=0, interactions={}, upgrades={}, paths=0,
        stops=0, moves=0, reset_calls=0, navigating=false, nav_accept=true,
        teleports=0, dungeon_resets=0, target=nil}
    s.player=actor('Player',0)
    local settings = {enabled=true, reset_timeout=600, check_distance=12,
        town_zone='Town', town_waypoint=1, town_pit_tower_pos=vector(0), pit_level=1,
        upgrade_toggle=true, use_chorons_soul=false, upgrade_mode=0, upgrade_threshold=1,
        minimum_glyph_level=1, maximum_glyph_level=100, upgrade_legendary_toggle=true,
        disable_orbwalker_at_glyphstone=false, death_recovery=false, use_long_path=false,
        exit_pit_delay=0, exit_mode=1, confirm_delay=1, pickup_heart_of_stone=true,
        use_burden_altar=true, interact_shrine=false, chase_goblin=false,
        party_enabled=false, speed_mode=false, speed_mode_2=false, push_mode=false,
        batmobile_priority='distance'}
    settings.orb_set_clear=function(v) s.orb_clear=v end
    settings.orb_set_block=function(v) s.orb_block=v end
    settings.exit_undercity_delay=0
    settings.max_enticement=3
    settings.enticement_timeout=4
    settings.beacon_timeout=10
    settings.boss_delay=3
    settings.loot_obols=true
    settings.tribute_priorities={}
    settings.skip_tribute=false
    settings.enable_bargains=false
    settings.bargain_timeout=10
    settings.bargain_priorities={}
    settings.bargain_cp={bargain_opener={x=20,y=20},scroll_bar={x=30,y=30},option1={x=40,y=40},option2={x=50,y=50}}
    settings.inventory_slot_0_x=100
    settings.inventory_slot_0_y=100
    settings.inventory_cell_size_x=50
    settings.inventory_cell_size_y=50
    settings.portal_button_x=200
    settings.portal_button_y=200
    settings.accept_button_x=300
    settings.accept_button_y=300
    s.settings=settings
    s.player.get_dungeon_key_items=function() return s.keys end
    s.player.get_item_slot_index=function() return s.key_slot end
    s.player.get_obols=function() return s.obols or 0 end
    local modules={['core.settings']=settings, ['gui']={bargains_data={{name='First',cp_key='option1',needs_scroll=false},{name='Second',cp_key='option2',needs_scroll=false}}}}
    local env=setmetatable({
        get_time_since_inject=function() return s.now end,
        get_current_world=function()
            if not s.world_name then return nil end
            return {get_name=function() return s.world_name end,
                get_current_zone_name=function() return s.zone end,
                get_world_id=function() return s.world_id end}
        end,
        get_player_position=function() return s.player.position end,
        get_local_player=function() return s.player end,
        vec3={new=function(_,x,y,z) return vector(x,y,z) end},
        console={print=function() end},
        actors_manager={get_ally_actors=function() return s.actors end,
            get_all_actors=function() return s.all_actors or s.actors end, get_all_items=function() return s.items end},
        target_selector={get_near_target_list=function() return s.enemies end},
        get_glyphs=function() return s.glyphs end,
        upgrade_glyph=function(g) s.upgrades[#s.upgrades+1]=g end,
        interact_object=function(a) s.interactions[#s.interactions+1]=a end,
        teleport_to_waypoint=function() s.teleports=s.teleports+1 end,
        reset_all_dungeons=function() s.dungeon_resets=s.dungeon_resets+1 end,
        loot_manager={any_item_around=function() return false end,
            is_in_vendor_screen=function() return s.vendor end, is_obols=function(item) return item.obols end},
        utility={open_pit_portal=function() end,
            send_mouse_move=function(x,y) s.hover={x=x,y=y} end,
            send_mouse_click=function(x,y) s.mouse[#s.mouse+1]={x=x,y=y,kind='left'} end,
            send_mouse_right_click=function(x,y) s.mouse[#s.mouse+1]={x=x,y=y,kind='right'} end},
        pathfinder={force_move_raw=function(v) s.target=v;s.moves=s.moves+1 end},
        BatmobilePlugin={
            pause=function() end, resume=function() end, update=function() end,
            reset=function() s.reset_calls=s.reset_calls+1;s.navigating=false end,
            set_priority=function() end, reset_movement=function() end,
            clear_traversal_blacklist=function() end,
            is_done=function() return s.nav_done or false end,
            is_traversal_routing=function() return false end,
            is_long_path_navigating=function() return s.navigating end,
            stop_long_path=function() s.stops=s.stops+1;s.navigating=false end,
            clear_target=function() s.target=nil end,
            set_target=function(_,target) s.target=target;return s.nav_accept end,
            move=function() s.moves=s.moves+1 end,
            get_closeby_node=function(_,target) return target end,
            navigate_long_path=function(_,target)
                s.paths=s.paths+1;s.target=target;s.navigating=s.nav_accept;return s.nav_accept
            end,
        },
    },{__index=_G})
    env._G=env
    function s.load(name)
        if modules[name] then return modules[name] end
        local file=assert(loadfile(root..name:gsub('%.','/')..'.lua','t',env))
        modules[name]=file()
        return modules[name]
    end
    env.require=s.load
    s.env=env
    -- A script reload: every WonderCity module loads again (fresh module
    -- state), the shared _G (env) and its globals are kept.
    function s.reload()
        modules={['core.settings']=settings, ['gui']=modules['gui']}
    end
    return s
end


local function logs(s)
    local lines = {}
    s.env.console = {print = function(m) lines[#lines + 1] = string.format('%.1f %s', s.now, tostring(m)) end}
    return lines
end
local function count(lines, text)
    local n = 0
    for _, l in ipairs(lines) do if l:find(text, 1, true) then n = n + 1 end end
    return n
end
-- The native target list honours its range (the base harness ignores it).
local function ranged_targets(s)
    s.env.target_selector = {get_near_target_list = function(pos, range)
        local out = {}
        for _, e in ipairs(s.enemies) do
            local p = e:get_position()
            if math.sqrt((p:x() - pos:x())^2 + (p:y() - pos:y())^2) <= (range or 50) then out[#out + 1] = e end
        end
        return out
    end}
end
local function run(s, manager, from, to, step)
    for t = from, to, step or 1 do s.now = t; manager.execute_tasks() end
end

-- ── B1 ─────────────────────────────────────────────────────────────────────
case('B1 a live miniboss that dies on a floor without a chest does not idle the explorer until reset_timeout', function()
    local s = session()
    local mini = actor('X1_Undercity_Ghost_Caster_Miniboss', 2, {boss = true})
    s.all_actors = {mini}; s.enemies = {mini}
    local manager = s.load('core.task_manager'); local tr = s.load('core.tracker')
    manager.execute_tasks()
    eq(manager.get_current_task().name, 'kill_monster', 'the miniboss is fought first')
    ok(tr.boss_trigger_time ~= nil, 'first sight stamped (boss_delay)')
    mini.health = 0; s.now = 102; manager.execute_tasks()
    s.all_actors = {}; s.enemies = {}
    run(s, manager, 103, 140)
    eq(tr.boss_kill_time, nil, 'the no-chest dismissal ran')
    eq(tr.boss_trigger_time, nil, 'the dismissal also clears the first-sight stamp')
    local moves = s.moves
    run(s, manager, 141, 200)
    eq(manager.get_current_task().name, 'explore_undercity')
    eq(manager.get_current_task().status, 'exploring', 'the explorer runs again')
    ok(s.moves - moves >= 50, 'Batmobile keeps moving after the dismissal: ' .. (s.moves - moves))
end)

case('B1 a revive at the checkpoint more than 50 m from the boss walks back to it; out of any range the explorer runs', function()
    local s = session(); ranged_targets(s)
    local boss = actor('X1_Undercity_Lacuni_Boss', 90, {boss = true, health = 1000})
    s.all_actors = {boss}; s.enemies = {boss}
    s.player.position = vector(60)
    local manager = s.load('core.task_manager'); local tr = s.load('core.tracker')
    manager.execute_tasks()
    eq(manager.get_current_task().name, 'kill_monster', 'boss within 50 m')
    run(s, manager, 101, 110)
    -- Death in the fight, revive at the floor checkpoint (90 m away).
    s.player.position = vector(0); s.now = 130
    manager.execute_tasks()
    eq(manager.get_current_task().name, 'kill_monster', 'the boss is re-acquired after the revive')
    eq(manager.get_current_task().status, 'walking to enemy')
    eq(s.target, boss, 'Batmobile target is the boss')
    -- The boss out of every range: the gate lapses and the explorer runs.
    boss.position = vector(400)
    run(s, manager, 131, 145)
    eq(manager.get_current_task().name, 'explore_undercity')
    eq(manager.get_current_task().status, 'exploring', 'no permanent idle after a boss was seen')
    ok(tr.boss_trigger_time == 100, 'boss_delay keeps the first-sight stamp')
end)

case('B1 the custom explorer uses the same non-sticky boss gate', function()
    local s = session(); s.settings.use_custom_explorer = true
    local task = s.load('tasks.custom_explorer'); local kill = s.load('tasks.kill_monster')
    local boss = actor('X1_Undercity_Snake_Brute_Miniboss', 5, {boss = true})
    s.enemies = {boss}
    ok(kill.shouldExecute()); kill:Execute()
    ok(not task.shouldExecute(), 'idle while the boss was seen just now')
    s.enemies = {} -- dead and gone (no chest on this floor), or out of range
    s.now = 111
    ok(task.shouldExecute(), 'exploring again once the boss is no longer seen')
end)

-- ── B2 ─────────────────────────────────────────────────────────────────────
case('B2 an enticement the player never gets closer to is given up after 12 s (not counted as interacted)', function()
    local s = session(); local lines = logs(s)
    s.actors = {actor('X1_Undercity_SpiritHearth_Switch', 10)}
    local manager = s.load('core.task_manager'); local tr = s.load('core.tracker'); local u = s.load('core.utils')
    manager.execute_tasks()
    eq(manager.get_current_task().name, 'interact_enticement')
    run(s, manager, 101, 111)
    eq(manager.get_current_task().name, 'interact_enticement', 'still walking inside the window')
    run(s, manager, 112, 120)
    ok(manager.get_current_task().name ~= 'interact_enticement', 'the enticement no longer wins the priority list')
    eq(count(lines, 'unreachable'), 1, 'one log line')
    eq(u.get_enticement_count(), 0, 'an unreachable switch is not an interacted one')
    local n = 0
    for _, v in pairs(tr.enticement) do if v == 'unreachable' then n = n + 1 end end
    eq(n, 1)
end)

case('B2 a Batmobile-rejected enticement target is skipped at once; yield time is not no-progress time', function()
    local s = session(); s.nav_accept = false
    s.actors = {actor('X1_Undercity_Enticements_SpiritBeaconSwitch', 10)}
    local task = s.load('tasks.interact_enticement')
    ok(task.shouldExecute()); task:Execute()
    ok(not task.shouldExecute(), 'set_target()==false gives it up')
    -- QQT_Warpigz_v3: the Grand Beacon precedes the warp pad: it is only set
    -- aside (20 s, then 40 s ...), never dropped for the floor.
    s.now = s.now + 19; ok(not task.shouldExecute(), 'still set aside after 19 s')
    s.now = s.now + 2; ok(task.shouldExecute(), 'the Grand Beacon is tried again after 20 s')
    task:Execute(); s.now = s.now + 39; ok(not task.shouldExecute(), 'second pause is 40 s')
    s.now = s.now + 2; ok(task.shouldExecute(), 'tried again after 40 s')
    local s3 = session(); s3.nav_accept = false
    s3.actors = {actor('X1_Undercity_SpiritHearth_Switch', 10)}
    local t3 = s3.load('tasks.interact_enticement')
    ok(t3.shouldExecute()); t3:Execute()
    s3.now = s3.now + 300; ok(not t3.shouldExecute(), 'an optional Spirit Hearth stays skipped for the floor')
    local s2 = session()
    s2.actors = {actor('X1_Undercity_Enticements_SpiritBeaconSwitch', 10)}
    local t2 = s2.load('tasks.interact_enticement')
    for t = 100, 108 do s2.now = t; t2:Execute() end
    t2.on_yield(20) -- another task / a yield ran from 109 to 128
    for t = 129, 138 do s2.now = t; t2:Execute() end
    ok(t2.shouldExecute(), 'time the task did not execute is not no-progress time')
end)

-- QQT_Warpigz_v3 (live "failed to leave floor 1"): the floor exit is set
-- aside for a growing pause (20 s, 40 s, 60 s cap), never for the floor.
case('B2 a PortalSwitch or warp pad Batmobile cannot reach is set aside, then tried again (never for the whole floor)', function()
    local s = session(); s.settings.check_distance = 20
    local portal = actor('X1_Undercity_PortalSwitch', 10)
    s.actors = {portal}
    local task = s.load('tasks.portal'); local tr = s.load('core.tracker')
    ok(task.shouldExecute()); task:Execute()
    local set_at = nil
    for t = 101, 113 do
        s.now = t
        if task.shouldExecute() then task:Execute() elseif not set_at then set_at = t end
    end
    ok(not task.shouldExecute(), 'no progress for 12 s: the PortalSwitch is set aside')
    s.now = set_at + 18; ok(not task.shouldExecute(), 'still set aside after 18 s')
    s.now = set_at + 21; ok(task.shouldExecute(), 'tried again after the 20 s pause')
    tr.floor_generation = tr.floor_generation + 1
    ok(task.shouldExecute(), 'a new floor forgets the pause')
    local s2 = session(); s2.nav_accept = false; s2.settings.check_distance = 20
    s2.actors = {actor('X1_Undercity_WarpPad', 10)}
    local t2 = s2.load('tasks.portal')
    ok(t2.shouldExecute()); t2:Execute()
    ok(not t2.shouldExecute(), 'a rejected warp pad is set aside at once')
    local pauses, last = {}, s2.now
    for t = s2.now, s2.now + 400 do
        s2.now = t
        if t2.shouldExecute() then pauses[#pauses + 1] = t - last; t2:Execute(); last = t end
    end
    eq(pauses[1], 20, 'first pause'); eq(pauses[2], 40, 'second pause'); eq(pauses[3], 60, 'third pause (cap)')
    eq(pauses[4], 60, 'the cap holds'); ok(#pauses >= 6, 'the warp pad keeps being retried on this floor')
end)

case('B2 kill_monster skips an unreachable goblin for a while, never a boss it is already fighting', function()
    local s = session(); s.settings.chase_goblin = true
    local gob = actor('X1_Undercity_Treasure_Goblin', 30)
    s.enemies = {gob}
    local task = s.load('tasks.kill_monster')
    ok(task.shouldExecute()); task:Execute()
    for t = 101, 113 do s.now = t; if task.shouldExecute() then task:Execute() end end
    ok(not task.shouldExecute(), 'no progress for 12 s: the goblin is skipped')
    s.now = 140
    ok(task.shouldExecute(), 'allowed again after the temporary skip')
    local s2 = session(); s2.nav_accept = false
    local boss = actor('X1_Undercity_Lacuni_Boss', 4, {boss = true})
    s2.enemies = {boss}
    local t2 = s2.load('tasks.kill_monster')
    for t = 100, 130 do s2.now = t; if t2.shouldExecute() then t2:Execute() end end
    ok(t2.shouldExecute(), 'a boss within engage range is never skipped')
    local s3 = session(); s3.nav_accept = false
    s3.enemies = {actor('X1_Undercity_Lacuni_Boss', 40, {boss = true})}
    local t3 = s3.load('tasks.kill_monster')
    for t = 100, 104 do s3.now = t; if t3.shouldExecute() then t3:Execute() end end
    ok(not t3.shouldExecute(), 'a far boss Batmobile rejects is skipped (after boss_delay)')
end)

-- ── B4 ─────────────────────────────────────────────────────────────────────
case('B4 WonderCity stops moving while the Looter picks up; bounded to 12 s per episode; yields shift windows', function()
    local s = session(); local lines = logs(s)
    s.env.LooteerPlugin = {get_enabled = function() return true end,
        is_actively_looting = function() return s.looting == true end}
    local manager = s.load('core.task_manager')
    manager.execute_tasks()
    eq(manager.get_current_task().name, 'explore_undercity')
    s.looting = true
    local moves = s.moves
    run(s, manager, 101, 108)
    eq(manager.get_current_task().name, 'loot_hold', 'the Looter owns movement')
    eq(s.moves, moves, 'no Batmobile move while the Looter picks up')
    s.looting = false; s.now = 109; manager.execute_tasks()
    eq(manager.get_current_task().name, 'explore_undercity', 'movement resumes after the pickup')
    s.looting = true
    run(s, manager, 110, 130)
    eq(manager.get_current_task().name, 'explore_undercity', 'an endless pickup does not hold the run')
    eq(count(lines, 'Looter busy'), 1, 'one log line when the hold is exceeded')
    -- A live boss fight is never held.
    local s2 = session()
    s2.env.LooteerPlugin = {is_actively_looting = function() return true end}
    local boss = actor('X1_Undercity_Lacuni_Boss', 4, {boss = true})
    s2.all_actors = {boss}; s2.enemies = {boss}
    local m2 = s2.load('core.task_manager'); m2.execute_tasks()
    eq(m2.get_current_task().name, 'kill_monster', 'boss fight not held')
    -- An unknown Looter contract never holds.
    local s3 = session(); s3.env.LooteerPlugin = {}
    local m3 = s3.load('core.task_manager'); m3.execute_tasks()
    eq(m3.get_current_task().name, 'explore_undercity')
    -- C5: the hold shifts the enticement walk window.
    local s4 = session()
    s4.env.LooteerPlugin = {is_actively_looting = function() return s4.looting == true end}
    s4.actors = {actor('X1_Undercity_SpiritHearth_Switch', 10)}
    local m4 = s4.load('core.task_manager')
    run(s4, m4, 100, 108)
    s4.looting = true; run(s4, m4, 109, 118)
    s4.looting = false; run(s4, m4, 119, 122)
    eq(m4.get_current_task().name, 'interact_enticement', 'the 10 s hold is not counted as no progress')
end)

-- ── B5 ─────────────────────────────────────────────────────────────────────
case('B5 ACCEPT with the vendor closed and no portal restarts at the brazier instead of blind re-clicks', function()
    local s = session(); local lines = logs(s)
    s.world_name = 'Town'; s.zone = 'Town'; s.vendor = true
    s.player.position = vector(10, 10)
    local brazier = actor('Aubrie_Test_Undercity_Crafter', 10); brazier.position = vector(10, 10)
    s.actors = {brazier}
    s.settings.skip_tribute = true
    local task = s.load('tasks.enter_undercity')
    local accepts, t = 0, 100
    while t < 400 do
        t = t + 0.05; s.now = t
        local before = #s.mouse
        task:Execute()
        for i = before + 1, #s.mouse do
            if s.mouse[i].x == 300 then accepts = accepts + 1; s.vendor = false end
        end
    end
    ok(accepts <= 2, 'blind ACCEPT clicks: ' .. accepts)
    ok(count(lines, 'restarting flow') >= 1, 'the flow restarted')
    ok(#s.interactions > 0, 'the brazier was interacted again')
    eq(task.committed(), false, 'the restart ended the commit window')
end)

-- ── B6 ─────────────────────────────────────────────────────────────────────
case('B6 a reload during chest confirmation keeps the reward phase: the run ends instead of exploring until the timeout', function()
    local s = session(); local lines = logs(s)
    local boss = actor('X1_Undercity_Lacuni_Boss', 6, {boss = true, health = 0})
    local chest = actor('X1_Undercity_Chest_Attunement', 1)
    s.all_actors = {boss, chest}
    local manager = s.load('core.task_manager'); local tr = s.load('core.tracker')
    run(s, manager, 100, 101, 0.5)
    ok(tr.reward_seen and tr.chest_interacted, 'reward chest seen and clicked')
    local started = tr.undercity_start_time
    chest.interactable = false
    s.now = 101.5; manager.execute_tasks()
    -- Reload now; the chest is removed while the script reloads.
    s.reload(); s.all_actors = {boss}
    manager = s.load('core.task_manager'); tr = s.load('core.tracker')
    run(s, manager, 102, 140, 0.5)
    eq(tr.undercity_start_time, started, 'the run deadline is kept')
    ok(tr.done, 'reward opening completed after the reload')
    ok(count(lines, 'not the district boss') == 0, 'the corpse is not dismissed as a miniboss')
    ok(s.teleports + s.dungeon_resets >= 1, 'the run exits')
    -- A different Undercity after the reload is a fresh run.
    s.reload(); s.world_id = 2; s.all_actors = {}
    manager = s.load('core.task_manager'); tr = s.load('core.tracker')
    s.now = 150; manager.execute_tasks()
    eq(tr.done, false); eq(tr.undercity_start_time, 150, 'another world is a new run')
    -- A stale saved state (no reload moments ago) is never restored.
    s.now = 160; manager.execute_tasks() -- saved for world 2
    s.reload(); s.now = 400; s.all_actors = {}
    manager = s.load('core.task_manager'); tr = s.load('core.tracker')
    manager.execute_tasks()
    eq(tr.undercity_start_time, 400, 'a state saved minutes ago is ignored')
    -- Leaving the Undercity (not for an Alfred trip) forgets the saved state.
    s.now = 401; manager.execute_tasks()
    s.world_name, s.zone, s.world_id = 'Town', 'Town', 3
    s.now = 402; manager.execute_tasks()
    eq(rawget(s.env, 'WonderCity_run_state'), nil, 'no saved state after the run')
end)

-- ── B3 (joint host) ────────────────────────────────────────────────────────
-- QQT_Warpigz_v3 owner-build: no Rosie in this build; the joint host's Alfred
-- mock services the bag-full trips (Rosie's outcome/fail_streak fields and
-- its missing-return-portal case are not part of the SteroidAlfred contract).
local J = dofile(SUITE .. '/audit/tests/joint_host.lua')

case('B3 standalone WonderCity in Kurast + a town service: bag-full trips complete, back into Kurast', function()
    local h = J.new({rosie = false, dirs = {'Batmobile', 'WonderCity'}, place = 'kurast'})
    h.assert_clean('load')
    local wc = h.mod('WonderCity', 'gui').elements
    wc.main_toggle:set(true); wc.skip_tribute:set(true); wc.exit_mode:set(1)
    for trip = 1, 3 do
        local mark = h.now
        h.alfred.need_trigger, h.alfred.inventory_full = true, true
        ok(h.run_until(function() return h.alfred.inventory_full == false and h.alfred.job == nil
            and h.place.key == 'kurast' end, 200),
            'trip ' .. trip .. ' ended back in Kurast\n' .. h.tail())
        ok(h.count(h.alfred.triggers, function(c) return c.t >= mark and c.context == 'WonderCity' end) >= 1,
            'trip ' .. trip .. ': WonderCity asked the town service')
        h.run(5)
    end
    eq(h.logged('teleport_failed'), 0, 'no teleport_failed')
    eq(#h.errors, 0, 'no host errors')
end)

-- ── B7 (joint host: real Batmobile + WonderCity on a closed floor) ─────────
-- QQT_Warpigz_v3, live report "tried WonderCity many times and failed to
-- leave floor 1". Floor 1 (X1_Undercity_Ziggurat_01) holds the warp pad and
-- its PortalSwitch 16-17 m from the spawn; interacting with the switch
-- leads to floor 2. Before the fix a single failed walk (Batmobile's 15 s
-- failed-goal cooldown answering set_target()==false, or 12 s without 1 m
-- of progress while a fight held the player) skipped the floor exit for the
-- whole floor, and the Grand Beacon the same way.
local function closed_floor(opts)
    local h = J.new({dirs = {'Batmobile', 'WonderCity'}, place = 'undercity'})
    h.assert_clean('load')
    local uc = h.P.undercity
    uc.zone, uc.slide, uc.box = 'X1_Undercity_Ziggurat_01', true, {-60, 60, -40, 40}
    h.P.uc2 = {name = 'X1_Undercity_Joint2', zone = 'X1_Undercity_Ziggurat_02', id = 78, town = false,
        spawn = h.v(0, 0), box = {-60, 60, -60, 60}, key = 'uc2', actors = {}}
    h.actor('undercity', 'X1_Undercity_WarpPad', 16, 0)
    local sw = h.actor('undercity', 'X1_Undercity_PortalSwitch', 17, 0, {interactable = not opts.beacon})
    sw.on_interact = function() if sw.interactable ~= false then h.travel_to(h.P.uc2, 0.5, 'floor portal') end end
    if opts.beacon then
        local beacon = h.actor('undercity', 'X1_Undercity_Enticements_SpiritBeaconSwitch', -16, 0)
        beacon.on_interact = function() beacon.interactable = false; sw.interactable = true end
    end
    if opts.barrier then
        uc.walls = {opts.barrier} -- the objective's area streams in / a gate opens after 4 s
        h.at(4, function() uc.walls = nil end)
    end
    if opts.fight then
        h.speed = 0 -- a fight holds the player in place for 15 s
        h.at(15, function() h.speed = 7 end)
    end
    h.mod('WonderCity', 'gui').elements.main_toggle:set(true)
    return h
end
case('B7 a floor exit Batmobile rejected once (failed-goal cooldown) is tried again and the floor is left', function()
    local h = closed_floor({barrier = {12, 22, -5, 5}})
    ok(h.run_until(function() return h.place == h.P.uc2 end, 120), 'floor 2 reached\n' .. h.tail(30))
    ok(h.logged('Batmobile rejected the target') >= 1, 'the rejection happened')
    eq(h.logged('skipping it on this floor'), 0, 'the exit is never skipped for the floor')
    ok(h.logged('exploring for 20s before trying it again') >= 1, 'set aside for 20 s')
    eq(#h.errors, 0, 'no host errors')
end)
case('B7 a floor exit without progress for 12 s while a fight holds the player is tried again and the floor is left', function()
    local h = closed_floor({fight = true})
    ok(h.run_until(function() return h.place == h.P.uc2 end, 120), 'floor 2 reached\n' .. h.tail(30))
    ok(h.logged('no progress for 12s') >= 1, 'the no-progress bound fired')
    eq(h.logged('skipping it on this floor'), 0, 'the exit is never skipped for the floor')
    eq(#h.errors, 0, 'no host errors')
end)
case('B7 a Grand Beacon Batmobile rejected once is tried again; its warp-pad portal then leads to floor 2', function()
    local h = closed_floor({beacon = true, barrier = {-22, -12, -5, 5}})
    ok(h.run_until(function() return h.place == h.P.uc2 end, 150), 'floor 2 reached\n' .. h.tail(30))
    ok(h.logged('SpiritBeaconSwitch unreachable (Batmobile rejected the target) - exploring for 20s') >= 1,
        'the beacon was set aside, not skipped')
    eq(h.logged('skipping it on this floor'), 0, 'nothing on the way down is skipped for the floor')
    eq(#h.errors, 0, 'no host errors')
end)

if #failures > 0 then error(#failures .. ' WonderCity bounds case(s) failed:\n' .. table.concat(failures, '\n')) end
print('WonderCity bounds: ' .. checks .. ' checks')
