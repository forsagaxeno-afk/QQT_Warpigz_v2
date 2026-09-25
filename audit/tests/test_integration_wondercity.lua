-- WonderCity integration regressions: CRT-1/L9 (bounded reward-chest
-- completion, resume after an Alfred round trip), WCY-1/2/5/6/7/8/9, F-C1
-- (advisory flag WarPigs reports serviced) and the cross-plugin contract
-- items C1-C5. Loads the real WonderCity main.lua ->
-- gui/settings -> external -> scheduler -> tasks with QQT-shaped host mocks
-- (Alfred/Batmobile/Looter are the synthetic boundaries). Runs under Lua 5.4
-- and LuaJIT.
local root = assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/WonderCity-main/'
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
        print('PASS WonderCity integration: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL WonderCity integration: ' .. name .. ': ' .. tostring(err))
    end
end

local Vec = {}; Vec.__index = Vec
function Vec:new(x, y, z) return setmetatable({xx = x or 0, yy = y or 0, zz = z or 0}, self) end
function Vec:x() return self.xx end
function Vec:y() return self.yy end
function Vec:z() return self.zz end
function Vec:dist_to(o) return math.sqrt((self.xx - o:x())^2 + (self.yy - o:y())^2 + (self.zz - o:z())^2) end
function Vec:squared_dist_to_ignore_z(o) return (self.xx - o:x())^2 + (self.yy - o:y())^2 end
local function v(x, y, z) return Vec:new(x, y, z) end

local next_id = 0
local function actor(name, x, y, opts)
    opts = opts or {}
    next_id = next_id + 1
    local a = {id = next_id, name = name, pos = v(x, y), health = opts.health or 100,
        interactable = opts.interactable ~= false, boss = opts.boss or false}
    function a:get_id() return self.id end
    function a:get_skin_name() return self.name end
    function a:get_position() return self.pos end
    function a:is_interactable() return self.interactable end
    function a:get_current_health() return self.health end
    function a:is_boss() return self.boss end
    function a:is_elite() return false end
    function a:is_champion() return false end
    function a:is_untargetable() return false end
    function a:is_dead() return self.health <= 0 end
    function a:get_active_spell_id() return 0 end
    function a:get_sno_id() return self.sno end
    return a
end
local function control(value, key)
    return {value = value, key = key, get = function(self) return self.value end,
        set = function(self, n) self.value = n end, get_key = function(self) return self.key end,
        get_state = function(self) return self.value and 1 or 0 end,
        render = function() end, push = function() return false end, pop = function() end}
end

local UC_WORLD, UC_ID, UC_ZONE = 'X1_Undercity_SnakeTemple', 77, 'X1_Undercity_SnakeTemple_02'

-- opts.release: Batmobile exposes the C3 release(caller) API.
-- opts.town: start in Naha_Kurast (default: inside an Undercity).
local function session(opts)
    opts = opts or {}
    local s = {now = 100, world = UC_WORLD, world_id = UC_ID, zone = UC_ZONE,
        actors = {}, enemies = {}, items = {}, keys = {}, mouse = {}, vendor = false, key_slot = 0,
        interactions = {}, teleports = {}, resets = 0, bat = {}, logs = {}, updates = {}, orb = {},
        navigating = false, nav_owner = nil, priority = 'direction', paused = false, target = nil}
    if opts.town then s.world, s.world_id, s.zone = 'Sanctuary', 1, 'Naha_Kurast' end
    s.player = actor('Player', 0, 0)
    s.player.get_dungeon_key_items = function() return s.keys end
    s.player.get_item_slot_index = function() return s.key_slot end
    s.player.get_obols = function() return 0 end
    local function rec(name, caller, a1)
        s.bat[#s.bat + 1] = {name = name, caller = caller, arg = a1, t = s.now}
    end
    local bat = {
        pause = function(c) rec('pause', c); s.paused = true end,
        resume = function(c) rec('resume', c); s.paused = false end,
        update = function(c) rec('update', c) end,
        move = function(c) rec('move', c) end,
        reset = function(c) rec('reset', c); s.navigating, s.nav_owner, s.priority = false, nil, 'direction' end,
        set_priority = function(c, p) rec('set_priority', c, p); s.priority = p end,
        is_long_path_navigating = function() return s.navigating end,
        stop_long_path = function(c) rec('stop_long_path', c); s.navigating, s.nav_owner = false, nil end,
        clear_target = function(c) rec('clear_target', c); s.target = nil end,
        set_target = function(c, t) rec('set_target', c, t); s.target = t; return true end,
        navigate_long_path = function(c, t)
            rec('navigate_long_path', c, t); s.navigating, s.nav_owner, s.target = true, c, t; return true
        end,
        get_owner = function() return s.navigating and s.nav_owner or nil end,
        get_closeby_node = function(_, t) return t end,
    }
    if opts.release then
        bat.release = function(c)
            rec('release', c)
            if s.nav_owner == c then s.navigating, s.nav_owner = false, nil end
            s.target, s.paused, s.priority = nil, true, 'direction'
            return true
        end
    end
    local env = setmetatable({
        vec3 = Vec, vec2 = Vec, get_hash = function(k) return k end,
        console = {print = function(m) s.logs[#s.logs + 1] = tostring(m) end},
        get_time_since_inject = function() return s.now end,
        get_local_player = function() return s.player end,
        get_player_position = function() return s.player.pos end,
        get_current_world = function()
            if not s.world then return nil end
            return {get_name = function() return s.world end, get_current_zone_name = function() return s.zone end,
                get_world_id = function() return s.world_id end}
        end,
        checkbox = {new = function(_, value) return control(value) end},
        combo_box = {new = function(_, value) return control(value) end},
        slider_int = {new = function(_, _, _, value) return control(value) end},
        tree_node = {new = function() return control(false) end},
        keybind = {new = function(_, key, value) return control(value, key) end},
        actors_manager = {get_all_actors = function() return s.actors end,
            get_ally_actors = function() return s.actors end, get_all_items = function() return s.items end},
        target_selector = {get_near_target_list = function() return s.enemies end},
        loot_manager = {any_item_around = function() return false end,
            is_in_vendor_screen = function() return s.vendor end, is_obols = function(item) return item.obols end},
        utility = {send_mouse_move = function() end,
            send_mouse_click = function(x, y) s.mouse[#s.mouse + 1] = {x = x, y = y, kind = 'left', t = s.now} end,
            send_mouse_right_click = function(x, y) s.mouse[#s.mouse + 1] = {x = x, y = y, kind = 'right', t = s.now} end},
        pathfinder = {force_move_raw = function() end},
        interact_object = function(a) s.interactions[#s.interactions + 1] = {actor = a, t = s.now} end,
        teleport_to_waypoint = function(w) s.teleports[#s.teleports + 1] = {w = w, t = s.now} end,
        reset_all_dungeons = function() s.resets = s.resets + 1; s.reset_at = s.reset_at or s.now end,
        revive_at_checkpoint = function() end,
        orbwalker = {set_clear_toggle = function(val) s.orb[#s.orb + 1] = {'clear', val} end,
            set_block_movement = function(val) s.orb[#s.orb + 1] = {'block', val} end},
        on_update = function(fn) s.updates[#s.updates + 1] = fn end,
        on_render = function() end, on_render_menu = function() end,
        get_screen_width = function() return 1920 end, render_menu_header = function() end,
        graphics = {text_2d = function() end, line = function() end, circle_2d = function() end},
        BatmobilePlugin = bat,
    }, {__index = _G})
    env._G = env
    for _, color in ipairs({'green', 'red', 'white', 'cyan', 'yellow', 'blue', 'purple', 'orange'}) do
        env['color_' .. color] = function() return {} end
    end
    local modules = {}
    env.require = function(name)
        if modules[name] == nil then
            modules[name] = assert(loadfile(root .. name:gsub('%.', '/') .. '.lua', 't', env))()
        end
        return modules[name]
    end
    assert(loadfile(root .. 'main.lua', 't', env))()
    s.env, s.bat_api = env, bat
    s.external = env.WonderCityPlugin
    s.gui = env.require('gui')
    s.tracker = env.require('core.tracker')
    s.manager = env.require('core.task_manager')
    s.settings = env.require('core.settings')
    function s:tick(dt)
        self.now = self.now + (dt or 0.1)
        if self.before_tick then self.before_tick(self) end
        for _, fn in ipairs(self.updates) do fn() end
    end
    function s:run(seconds, dt)
        local stop = self.now + seconds - 1e-9
        while self.now < stop do self:tick(dt) end
    end
    -- Ticks until pred() holds; returns the elapsed seconds (nil on timeout).
    function s:until_true(pred, max_seconds, dt)
        local start = self.now
        while self.now - start < max_seconds do
            self:tick(dt)
            if pred() then return self.now - start end
        end
        return nil
    end
    function s:task() return self.manager.get_current_task() end
    function s:count(name, caller)
        local n = 0
        for _, c in ipairs(self.bat) do
            if c.name == name and (caller == nil or c.caller == caller) then n = n + 1 end
        end
        return n
    end
    function s:logged(pattern)
        for _, line in ipairs(self.logs) do if line:find(pattern, 1, true) then return true end end
        return false
    end
    function s:status() return self.external.get_status() end
    function s:enable() self.external.enable(); self:tick() end
    return s
end

-- Alfred mock: get_status() returns s.alfred; with-teleport trips are driven
-- by the case through s.alfred_cb.
local function alfred(s, status)
    s.alfred = status or {enabled = true}
    s.triggers = {}
    s.env.AlfredTheButlerPlugin = {
        get_status = function()
            if s.alfred_error then error('status unavailable') end
            return s.alfred
        end,
        trigger_tasks_with_teleport = function(caller, cb)
            s.triggers[#s.triggers + 1] = {caller = caller, t = s.now}
            s.alfred_cb = cb
            if s.on_trigger then s.on_trigger(cb) end
            return nil
        end,
    }
end

local function reward_chest(x, interactable)
    return actor('X1_Undercity_Chest_Attunement_Reward', x or 1, 0, {interactable = interactable})
end
local function dead_boss()
    return actor('X1_Undercity_Lacuni_Boss', 3, 0, {boss = true, health = 0})
end

-- ── CRT-1 / L9: bounded reward-chest completion ─────────────────────────────

case('L9: already opened (non-interactable) chest after an observed boss kill completes and exits', function()
    -- Live L9 with the R14 evidence rule: the boss fight was observed while
    -- the reward chest was in the actor stream; after the kill the chest
    -- stays non-interactable (already opened) -> bounded 10 s, then exit.
    local s = session()
    local boss = actor('X1_Undercity_Lacuni_Boss', 30, 0, {boss = true, health = 100})
    s.actors = {s.player, boss, reward_chest(1, false)}
    s:enable(); s:run(2)
    boss.health = 0
    s:run(3)
    eq(s:task().name, 'goto_chest')
    ok(s:task().status:find('waiting for reward chest to unlock', 1, true), 'status names the unlock wait')
    ok(s:logged('not interactable before our click'), 'the ambiguous chest state is logged')
    ok(s:logged('boss kill observed after the chest was first seen'), 'the evidence is named in the log')
    local t = s:until_true(function() return s.tracker.done end, 12)
    ok(t ~= nil and t <= 7.5, 'reward phase completes within the 10 s unlock wait (was: forever)')
    eq(#s.interactions, 0, 'an opened chest is never clicked')
    ok(s.tracker.completion_reason:find('already opened', 1, true))
    -- 3 s loot quiet + 10 s default exit delay, then the configured reset.
    ok(s:until_true(function() return s.resets > 0 end, 20) ~= nil, 'exit follows instead of waiting for reset_timeout')
end)

case('L9: opened chest replaced by a new non-interactable actor after our click', function()
    local s = session()
    local chest = reward_chest(1, true)
    s.actors = {s.player, dead_boss(), chest}
    s:enable(); s:run(0.5)
    eq(#s.interactions, 1)
    -- The host swaps the chest actor (new id, same place) and it is not
    -- interactable any more: the key change must not wait forever.
    s.actors = {s.player, dead_boss(), reward_chest(1, false)}
    local t = s:until_true(function() return s.tracker.done end, 15)
    ok(t ~= nil and t <= 10.5, 'replacement chest completes within the bounded unlock wait')
    eq(#s.interactions, 1)
end)

case('CRT-1: chest that stays interactable after our interaction completes in ~8 s', function()
    local s = session()
    s.actors = {s.player, reward_chest(1, true)}
    s:enable()
    local t = s:until_true(function() return s.tracker.done end, 12)
    ok(t ~= nil and t >= 7.5 and t <= 9.5, 'bounded completion (was: chest_failed + 600 s run reset)')
    ok(not s.tracker.chest_failed)
    ok(#s.interactions >= 2 and #s.interactions <= 10, 'interaction re-fires stay spaced')
    ok(s:until_true(function() return s.resets > 0 end, 20) ~= nil, 'exit follows')
end)

case('CRT-1: interacted chest that vanishes without new loot completes after 5 s', function()
    local s = session()
    s.actors = {s.player, reward_chest(1, true)}
    s:enable(); s:run(0.5)
    eq(#s.interactions, 1)
    s.actors = {s.player}
    s:run(4.5)
    ok(not s.tracker.done, 'a short absence is not completion')
    ok(s:until_true(function() return s.tracker.done end, 2) ~= nil, 'stable absence completes')
    eq(s.tracker.completion_reason, 'interacted chest vanished')
end)

case('CRT-1: chest seen but opened elsewhere (vanished, never clicked) completes after 20 s', function()
    local s = session()
    s.actors = {s.player, reward_chest(1, false)}
    s:enable(); s:run(2)
    ok(s.tracker.reward_seen and not s.tracker.done)
    s.actors = {s.player}
    s:run(19)
    ok(not s.tracker.done, 'absence shorter than 20 s is not completion')
    eq(s:task().name, 'finish_undercity')
    ok(s:until_true(function() return s.tracker.done end, 2) ~= nil, 'vanished chest completes the reward phase')
    ok(s.tracker.completion_reason:find('vanished', 1, true))
end)

case('CRT-1: an unreadable scan streak never counts as a vanished chest', function()
    local s = session()
    s.actors = {s.player, reward_chest(1, false)}
    s:enable(); s:run(2)
    local enumerate = s.env.actors_manager.get_all_actors
    s.env.actors_manager.get_all_actors = function() error('actor list unavailable') end
    s:run(30)
    ok(not s.tracker.done, 'failed scans are not absence evidence')
    s.env.actors_manager.get_all_actors = enumerate
end)

case('CRT-1: a locked chest waits while the boss lives, then the bounded unlock wait runs', function()
    local s = session()
    local boss = actor('X1_Undercity_Lacuni_Boss', 30, 0, {boss = true, health = 100})
    s.actors = {s.player, boss, reward_chest(1, false)}
    s:enable(); s:run(60)
    ok(not s.tracker.done, 'never completed while the boss lives')
    ok(s:task().status:find('boss alive', 1, true), 'status says why')
    boss.health = 0
    local t = s:until_true(function() return s.tracker.done end, 12)
    ok(t ~= nil and t <= 10.5, 'after the kill the 10 s unlock wait completes')
end)

case('R14: without opened evidence the unlock wait is 60 s (was 30 s)', function()
    local s = session()
    s.actors = {s.player, reward_chest(1, false)}
    s:enable(); s:run(58.5)
    ok(not s.tracker.done, 'no early completion without evidence')
    ok(s:task().status:find('no opened evidence', 1, true), 'status says why it waits')
    ok(s:until_true(function() return s.tracker.done end, 3) ~= nil, 'still bounded')
    ok(s.tracker.completion_reason:find('no opened evidence', 1, true), s.tracker.completion_reason)
    eq(#s.interactions, 0)
end)

case('CRT-1: close-range approach stall interacts from where the player stands', function()
    local s = session()
    s.actors = {s.player, reward_chest(3, true)} -- 3 m away; the mock player never moves
    s:enable(); s:run(7)
    eq(#s.interactions, 0, 'still walking inside the stall window')
    ok(s:until_true(function() return #s.interactions > 0 end, 3) ~= nil, 'stalled approach falls back to interacting')
end)

-- ── R14: a never-clicked locked chest completes early only with evidence ──

local function chest_log_lines(s)
    local n, last = 0, nil
    for _, line in ipairs(s.logs) do
        if line:find('[WonderCity:chest] reward chest', 1, true) and line:find('not interactable before our click', 1, true) then
            n, last = n + 1, line
        end
    end
    return n, last
end
local function item(x, y, obols)
    local a = actor('Item', x, y); a.obols = obols
    return a
end

case('R14: a boss corpse seen together with the locked chest is not evidence; one diagnostic line', function()
    local s = session()
    local chest = reward_chest(1, false)
    s.actors = {s.player, dead_boss(), chest}
    s:enable(); s:run(30)
    ok(not s.tracker.done, 'not recorded as opened after 30 s (was: 10 s after the corpse)')
    eq(#s.interactions, 0)
    local n, line = chest_log_lines(s)
    eq(n, 1, 'one diagnostic line per wait')
    ok(line:find(tostring(chest.id), 1, true), 'names the chest key: ' .. line)
    ok(line:find('interactable=false', 1, true), 'names the interactable state')
    ok(line:find('boss_kill_time=100.1', 1, true), 'names boss_kill_time: ' .. line)
    ok(line:find('last boss=X1_Undercity_Lacuni_Boss hp=0', 1, true), 'names the last boss seen: ' .. line)
    ok(line:find('no opened evidence', 1, true))
    ok(s:until_true(function() return s.tracker.done end, 32) ~= nil, 'bounded by the 60 s fallback')
    eq(select(1, chest_log_lines(s)), 1, 'still one line for the whole wait')
end)

case('R14: a chest still locked by a boss outside the actor stream is opened when it unlocks after 30 s', function()
    local s = session()
    local chest = reward_chest(1, false)
    s.actors = {s.player, chest}
    s:enable(); s:run(45)
    ok(not s.tracker.done, 'the reward chest is not skipped at 30 s (critic R14)')
    chest.interactable = true -- the boss died out of stream; the chest unlocks
    ok(s:until_true(function() return #s.interactions > 0 end, 2) ~= nil, 'the unlocked chest is clicked')
    chest.interactable = false
    ok(s:until_true(function() return s.tracker.done end, 3) ~= nil)
    eq(s.tracker.completion_reason, 'interacted chest no longer interactable')
end)

case('R14: a kill observed before the chest was first seen (another boss) is not evidence', function()
    local s = session()
    local mini = actor('X1_Undercity_Snake_Brute_Miniboss', 20, 0, {boss = true, health = 100})
    s.actors = {s.player, mini}
    s:enable(); s:run(1)
    mini.health = 0
    s:run(2)
    ok(s.tracker.boss_kill_time ~= nil, 'the miniboss kill is observed')
    s.actors = {s.player, mini, reward_chest(1, false)}
    s:run(30)
    ok(not s.tracker.done, 'not recorded as opened 10 s after an earlier kill')
    local _, line = chest_log_lines(s)
    ok(line and line:find('last boss=X1_Undercity_Snake_Brute_Miniboss', 1, true), tostring(line))
    ok(s:until_true(function() return s.tracker.done end, 31) ~= nil, 'bounded by the 60 s fallback')
end)

case('R14: a kill seen across a brief gap is observed; a corpse returning long after is not', function()
    local s = session()
    local chest = reward_chest(1, false)
    local boss = actor('X1_Undercity_Lacuni_Boss', 30, 0, {boss = true, health = 100})
    s.actors = {s.player, boss, chest}
    s:enable(); s:run(2)
    s.actors = {s.player, chest}          -- the dying boss leaves the list for 1 s
    s:run(1)
    boss.health = 0
    s.actors = {s.player, boss, chest}
    local t = s:until_true(function() return s.tracker.done end, 12)
    ok(t ~= nil and t <= 11, 'observed kill -> bounded 10 s wait: ' .. tostring(t))
    ok(s.tracker.completion_reason:find('boss kill observed', 1, true))
    local s2 = session()
    local boss2 = actor('X1_Undercity_Lacuni_Boss', 30, 0, {boss = true, health = 100})
    s2.actors = {s2.player, boss2, reward_chest(1, false)}
    s2:enable(); s2:run(2)
    s2.actors = {s2.player, s2.actors[3]}  -- boss leaves the stream alive
    s2:run(10)
    boss2.health = 0
    s2.actors[#s2.actors + 1] = boss2     -- its corpse shows up much later
    s2:run(20)
    ok(not s2.tracker.done, 'a corpse long after the last live sighting is not an observed kill')
end)

case('R14: a loot burst next to the locked chest is evidence; a single drop, obols or far loot are not', function()
    local s = session()
    s.actors = {s.player, reward_chest(1, false)}
    s:enable(); s:run(5)
    s.items = {item(1, 1)}                                   -- one mob drop next to the chest
    s:run(5)
    s.items[#s.items + 1] = item(2, 0, true); s.items[#s.items + 1] = item(1, 2, true) -- obols
    s:run(5)
    s.items[#s.items + 1] = item(25, 0); s.items[#s.items + 1] = item(25, 1)         -- far away
    s:run(20)
    ok(not s.tracker.done and not s.tracker.chest_loot_seen, 'no opened evidence yet at 35 s')
    s.items[#s.items + 1] = item(1, -1); s.items[#s.items + 1] = item(0, 1)          -- the chest's drop
    s:run(1)
    ok(s.tracker.chest_loot_seen ~= nil, 'the loot burst is seen')
    ok(s:logged('new items dropped within'), 'and logged')
    local t = s:until_true(function() return s.tracker.done end, 12)
    ok(t ~= nil and t <= 10, 'completes within 10 s of the evidence (was: 30 s blind, now 60 s blind)')
    ok(s.tracker.completion_reason:find('new loot dropped next to the chest', 1, true))
    eq(#s.interactions, 0)
end)

case('R14: our click before an Alfred round trip is evidence for the non-interactable chest on return', function()
    local s = session()
    alfred(s, {enabled = true})
    s.actors = {s.player, reward_chest(1, true)}
    s:enable(); s:run(0.3)
    eq(#s.interactions, 1)
    ok(not s.tracker.done)
    s.alfred = {enabled = true, trigger_tasks = true, teleport = true}
    s:tick()
    s.world, s.world_id, s.zone = 'Sanctuary', 1, 'Naha_Kurast'
    s.actors = {s.player}
    s:run(20)
    s.world, s.world_id, s.zone = UC_WORLD, UC_ID, UC_ZONE
    s.actors = {s.player, reward_chest(1, false)}
    s:tick()
    s.alfred = {enabled = true, teleport = true, teleport_done = true}
    s:tick()
    ok(s:logged('resuming the run'))
    local t = s:until_true(function() return s.tracker.done end, 15)
    ok(t ~= nil and t <= 10.5, 'our earlier interaction bounds the wait at 10 s: ' .. tostring(t))
    ok(s.tracker.completion_reason:find('we interacted with the reward chest earlier', 1, true))
    eq(#s.interactions, 1)
end)

case('R14/C5: an Alfred yield does not count toward the 60 s evidence-free wait', function()
    local s = session()
    alfred(s, {enabled = true})
    s.actors = {s.player, reward_chest(1, false)}
    s:enable(); s:run(20)
    s.alfred = {enabled = true, trigger_tasks = true}   -- foreign cycle in place
    s:run(50)
    eq(s:task().name, 'alfred_running')
    s.alfred = {enabled = true}
    s:run(35)
    ok(not s.tracker.done, 'only 55 s of our own wait so far')
    ok(s:until_true(function() return s.tracker.done end, 8) ~= nil)
end)

case('CRT-1: a foreign Alfred trip after opening resumes the same run with the chest done', function()
    local s = session()
    alfred(s, {enabled = true})
    s.actors = {s.player, reward_chest(1, true)}
    s:enable(); s:run(0.5)
    s.actors[2].interactable = false
    s:run(2)
    ok(s.tracker.done, 'opening confirmed')
    local start = s.tracker.undercity_start_time
    -- Alfred's own inventory trip (another caller) takes the player to town
    -- and back through its portal into the same Undercity world.
    s.alfred = {enabled = true, trigger_tasks = true, teleport = true}
    s:tick()
    s.world, s.world_id, s.zone = 'Sanctuary', 1, 'Naha_Kurast'
    s.actors = {s.player}
    s:run(20)
    ok(s:logged('for an Alfred trip'), 'leaving for the trip is logged')
    s.world, s.world_id, s.zone = UC_WORLD, UC_ID, UC_ZONE
    s.actors = {s.player, reward_chest(1, false)}
    s:tick()
    s.alfred = {enabled = true, teleport = true, teleport_done = true}
    s:tick()
    ok(s:logged('resuming the run'), 'same world key is a resume')
    eq(s.tracker.undercity_start_time, start, 'the run deadline is not restarted by the town trip')
    ok(s.tracker.done, 'the opened chest is remembered for this world')
    ok(s:until_true(function() return s.resets > 0 end, 20) ~= nil, 'exit follows without re-opening')
    eq(#s.interactions, 1)
end)

case('CRT-1: own with-teleport trip before the boss keeps deadline and enticements; new entry forgets it', function()
    local s = session()
    alfred(s, {enabled = true})
    s:enable(); s:run(1)
    local start = s.tracker.undercity_start_time
    s.tracker.enticement['1|SpiritHearth_Switch:1:2'] = true
    s.alfred = {enabled = true, need_trigger = true, inventory_full = true}
    s:run(0.5)
    eq(#s.triggers, 1, 'inventory_full inside triggers the with-teleport trip')
    ok(s:status().alfred_trip and s:status().in_run, 'C2: own trip inside a run')
    s.alfred = {enabled = true, trigger_tasks = true, teleport = true}
    s:tick()
    s.world, s.world_id, s.zone = 'Sanctuary', 1, 'Naha_Kurast'
    s:run(10)
    ok(s:status().alfred_trip and s:status().in_run, 'C2: the town leg is still the trip')
    s.world, s.world_id, s.zone = UC_WORLD, UC_ID, UC_ZONE
    s.alfred = {enabled = true}
    s:tick()
    s.alfred_cb()
    s:run(1)
    eq(s.tracker.undercity_start_time, start)
    ok(s.tracker.enticement['1|SpiritHearth_Switch:1:2'], 'enticement memory kept')
    -- Leaving again for a (foreign) trip, then a genuinely new entry: the
    -- Open Portal click forgets the Undercity we left, so a new instance
    -- that reports the same world key restarts the run.
    s.alfred = {enabled = true, trigger_tasks = true}
    s:tick()
    s.world, s.world_id, s.zone = 'Sanctuary', 1, 'Naha_Kurast'
    s:tick()
    ok(s.tracker.resume_key ~= nil)
    s.alfred = {enabled = true}
    s.gui.elements.skip_tribute:set(true)
    s.player.pos = v(10, 10)
    s.actors = {s.player, actor('Aubrie_Test_Undercity_Crafter', 10, 10)}
    s.vendor = true
    ok(s:until_true(function() return #s.mouse > 0 end, 6) ~= nil, 'Open Portal clicked')
    ok(s.tracker.resume_key == nil, 'a new entry forgets the resume key')
    s.vendor = false
    s.actors = {s.player}
    s:run(6) -- past the post-click actor guards
    s.world, s.world_id, s.zone = UC_WORLD, UC_ID, UC_ZONE
    s:run(1)
    ok(s.tracker.undercity_start_time > start, 'a new instance restarts the run')
end)

case('CRT-1: leaving through the exit (not an Alfred trip) never resumes', function()
    local s = session()
    s:enable(); s:run(1)
    local start = s.tracker.undercity_start_time
    s.tracker.exit_trigger_time = s.now
    s.world, s.world_id, s.zone = 'Sanctuary', 1, 'Naha_Kurast'
    s:run(1)
    ok(s.tracker.resume_key == nil)
    s.world, s.world_id, s.zone = UC_WORLD, UC_ID, UC_ZONE
    s:run(1)
    ok(s.tracker.undercity_start_time > start)
end)

-- ── WCY-2: default/exhausted tributes never stall the entry ──────────────────

local function at_brazier(s)
    s.player.pos = v(10, 10)
    s.actors = {s.player, actor('Aubrie_Test_Undercity_Crafter', 10, 10)}
    s.vendor = true
end
local function tribute(sno) local a = actor('Tribute', 0, 0); a.sno = sno; return a end

for _, variant in ipairs({'defaults with tributes', 'empty inventory', 'configured tribute exhausted',
    'configured tribute without a valid slot'}) do
    case('WCY-2: ' .. variant .. ' opens the portal without a tribute', function()
        local s = session({town = true})
        at_brazier(s)
        if variant == 'defaults with tributes' then s.keys = {tribute(2125049), tribute(2090358)}
        elseif variant == 'configured tribute exhausted' then
            s.gui.elements.tribute_priority_1:set(1); s.keys = {tribute(2090358)}
        elseif variant == 'configured tribute without a valid slot' then
            s.gui.elements.tribute_priority_1:set(1); s.keys = {tribute(2125049)}; s.key_slot = -1
        end
        ok(s.gui.elements.skip_tribute:get() == false, 'shipped default: Skip tribute off')
        s:enable()
        local stuck_since, worst = nil, 0
        local t = s:until_true(function()
            local st = s:task().status or ''
            if st:find('no item available', 1, true) or st:find('valid tribute inventory slot', 1, true) then
                stuck_since = stuck_since or s.now
                worst = math.max(worst, s.now - stuck_since)
            else
                stuck_since = nil
            end
            return #s.mouse > 0
        end, 10)
        ok(t ~= nil and t <= 6, 'Open Portal clicked within CLICK_DELAY*3 (was: never)')
        eq(s.mouse[1].kind, 'left', 'no tribute right-click: an unselected tribute is never consumed')
        eq(s.mouse[1].x, s.settings.portal_button_x)
        ok(worst <= 5, 'no pulse stays in the tribute wait longer than 5 s')
        ok(s:logged('without a tribute'), 'the fallback is logged')
        ok(s:status().committed_entry == true, 'C2: Open Portal commits the entry')
    end)
end

-- ── WCY-7 / C2 provider fields ───────────────────────────────────────────────

case('C2/WCY-7: committed_entry and in_run follow the entry and are bounded', function()
    local s = session({town = true})
    at_brazier(s)
    s.gui.elements.skip_tribute:set(true)
    s:enable()
    local st = s:status()
    ok(st.committed_entry == false and st.in_run == false and st.alfred_trip == false, 'idle in town')
    ok(s:until_true(function() return #s.mouse > 0 end, 6) ~= nil)
    st = s:status()
    ok(st.committed_entry == true and st.in_run == true, 'Open Portal click: entry under way')
    -- Nothing ever spawns (Accept keeps being re-clicked): the commitment
    -- expires for WarPigs; re-clicks do not extend it.
    s:run(61)
    ok(s:status().committed_entry == false, 'commitment is bounded')
    -- Portal interaction commits too; entering the Undercity ends it.
    s = session({town = true})
    s.player.pos = v(10, 10)
    s.actors = {s.player, actor('Portal_Dungeon_Undercity', 10, 10)}
    s:enable(); s:run(1.5)
    ok(#s.interactions >= 1)
    ok(s:status().committed_entry == true, 'portal interaction is a committed entry')
    s.world, s.world_id, s.zone = UC_WORLD, UC_ID, UC_ZONE
    s.actors = {s.player}
    s:run(1.5)
    st = s:status()
    ok(st.committed_entry == false and st.in_run == true, 'inside: in_run, no longer entering')
    eq(type(st.task), 'string')
end)

-- ── WCY-1 / C1: sticky grace survives preemption ─────────────────────────────

case('WCY-1: a sticky need_trigger does not livelock the town route', function()
    local s = session({town = true})
    s.player.pos = v(1035, 151)
    alfred(s, {enabled = true, need_trigger = true, inventory_full = false, need_repair = false, restock_count = 1})
    local cycle_end
    s.on_trigger = function() s.alfred.trigger_tasks = true; cycle_end = s.now + 5 end
    s.before_tick = function()
        if cycle_end and s.now >= cycle_end then
            cycle_end = nil
            s.alfred.trigger_tasks = false -- restock_count stays: need_trigger stays true
            s.alfred_cb()
        end
    end
    s:enable()
    local walk = 0
    for _ = 1, 600 do
        s:tick()
        if s:task().name == 'walk_kurast' then walk = walk + 1 end
    end
    ok(#s.triggers <= 2, 'at most one trigger per 30 s grace (was 12 in 60 s): ' .. #s.triggers)
    ok(walk > 100, 'the town route makes progress: ' .. walk)
end)

case('WCY-1: preemption/cancel keeps the grace; a hard need still re-triggers', function()
    local s = session({town = true})
    s.player.pos = v(1035, 151)
    alfred(s, {enabled = true, need_trigger = true})
    s:enable(); s:run(0.3)
    eq(#s.triggers, 1)
    s.alfred_cb()
    s.external.disable()   -- release_control -> alfred.on_cancel
    s.external.enable()
    s:run(10)
    eq(#s.triggers, 1, 'advisory need_trigger stays suppressed after a cancel')
    s.alfred.inventory_full = true
    s:run(0.5)
    eq(#s.triggers, 2, 'hard need re-triggers within the grace')
end)

case('WCY-1: a lost legacy callback gets the same sticky grace', function()
    local s = session({town = true})
    s.player.pos = v(1035, 151)
    alfred(s, {enabled = true, need_trigger = true})
    s:enable(); s:run(0.3)
    eq(#s.triggers, 1)
    s:run(35) -- never called back: pickup window (8 s) + quiet retire (2 s)
    eq(#s.triggers, 1, 'no re-trigger inside the grace after a quiet retirement')
    s:run(6)
    eq(#s.triggers, 2, 'the grace expires by itself')
end)

-- ── F-C1: WarPigs already serviced the advisory flag ────────────────────────
-- Joint round-3 OPEN item: with a sticky restock flag (need_trigger alone)
-- WonderCity started its own advisory Alfred trip at every activity start
-- although WarPigs had just serviced the flag and reported alfred_idle. The
-- same reading as ArkhamAsylum's warpigs_advisory_idle().

-- WarPigs mock: status() returns s.wp (s.wp_error makes it throw).
local function warpigs(s, st)
    s.wp = st
    s.env.WarPigsPlugin = {status = function()
        if s.wp_error then error('status unavailable') end
        return s.wp
    end}
end
local function count_logs(s, pattern)
    local n = 0
    for _, line in ipairs(s.logs) do if line:find(pattern, 1, true) then n = n + 1 end end
    return n
end
local STICKY = {enabled = true, need_trigger = true, inventory_full = false, need_repair = false, restock_count = 2}
local function sticky() local t = {}; for k, val in pairs(STICKY) do t[k] = val end; return t end

case('F-C1: an advisory-only flag WarPigs reports serviced starts no trip at activity start', function()
    local s = session({town = true})
    s.player.pos = v(1035, 151)
    alfred(s, sticky())
    warpigs(s, {enabled = true, alfred_idle = true})
    s:enable()
    local walk = 0
    for _ = 1, 400 do
        s:tick()
        if s:task().name == 'walk_kurast' then walk = walk + 1 end
    end
    eq(#s.triggers, 0, 'no advisory Alfred trip while WarPigs reports the flag serviced (d275b9d: 1 at the start)')
    ok(walk > 350, 'the town route runs from the first frame: ' .. walk)
    eq(s:task().note, nil, 'not a hold')
    eq(count_logs(s, 'advisory Alfred restock skipped'), 1, 'one diagnostic line, rate-limited')
    s:run(25)
    eq(count_logs(s, 'advisory Alfred restock skipped'), 2, 'at most one line a minute')
    -- Hard needs are unchanged: they trigger at once under WarPigs.
    s.alfred.inventory_full = true
    s:run(0.5)
    eq(#s.triggers, 1, 'inventory_full still triggers')
end)

case('F-C1: need_repair triggers; WarPigs no longer idle, disabled or unreadable restores the advisory trip', function()
    local s = session({town = true})
    s.player.pos = v(1035, 151)
    alfred(s, sticky())
    s.alfred.need_repair = true
    warpigs(s, {enabled = true, alfred_idle = true})
    s:enable(); s:run(0.5)
    eq(#s.triggers, 1, 'need_repair is a hard need')
    local variants = {
        {'WarPigs reports Alfred not idle', function(x) warpigs(x, {enabled = true, alfred_idle = false}) end},
        {'WarPigs disabled', function(x) warpigs(x, {enabled = false, alfred_idle = true}) end},
        {'WarPigs status throws', function(x) warpigs(x, {enabled = true, alfred_idle = true}); x.wp_error = true end},
        {'WarPigs status not a table', function(x) warpigs(x, 'on') end},
        {'WarPigs without status()', function(x) x.env.WarPigsPlugin = {enabled = true} end},
        {'standalone (no WarPigs)', function() end},
    }
    for _, variant in ipairs(variants) do
        local w = session({town = true})
        w.player.pos = v(1035, 151)
        alfred(w, sticky())
        variant[2](w)
        w:enable(); w:run(0.5)
        eq(#w.triggers, 1, variant[1] .. ': advisory trip at the start as on d275b9d')
        eq(count_logs(w, 'advisory Alfred restock skipped'), 0, variant[1] .. ': no skip line')
    end
    -- The rule follows the WarPigs signal: once it stops reporting idle, the
    -- standalone rules apply again (own grace after its own cycles).
    local x = session({town = true})
    x.player.pos = v(1035, 151)
    alfred(x, sticky())
    warpigs(x, {enabled = true, alfred_idle = true})
    x:enable(); x:run(10)
    eq(#x.triggers, 0)
    x.wp.alfred_idle = false
    x:run(0.5)
    eq(#x.triggers, 1, 'advisory trip once WarPigs no longer reports the flag serviced')
    x.alfred_cb()
    x:run(20)
    eq(#x.triggers, 1, 'own sticky grace after its own completed cycle is unchanged')
end)

case('F-C1: inside an Undercity the rules are unchanged under WarPigs', function()
    local s = session()
    alfred(s, sticky())
    warpigs(s, {enabled = true, alfred_idle = true})
    s:enable(); s:run(2)
    eq(#s.triggers, 0, 'advisory flag never leaves a run')
    eq(count_logs(s, 'advisory Alfred restock skipped'), 0, 'WarPigs is not consulted inside a run')
    s.alfred.inventory_full = true
    s:run(0.5)
    eq(#s.triggers, 1, 'inventory_full inside still triggers the with-teleport trip')
    ok(s:status().alfred_trip and s:status().in_run, 'C2: own trip inside a run')
end)

case('C1: paused Alfred without hard need is idle; with hard need the hold is bounded', function()
    local s = session({town = true})
    s.player.pos = v(1035, 151)
    alfred(s, {enabled = true, need_trigger = true, paused = true})
    s:enable(); s:run(1)
    eq(s:task().name, 'walk_kurast', 'a foreign pause without hard work does not hold WonderCity')
    s.alfred.inventory_full = true
    s:run(1)
    eq(s:task().name, 'alfred_running', 'paused with hard work holds')
    eq(#s.triggers, 0)
    s:run(59)
    eq(s:task().name, 'alfred_running')
    s:run(2)
    eq(s:task().name, 'walk_kurast', 'the paused hold ends after 60 s')
    s:run(5)
    eq(s:task().name, 'walk_kurast', 'and is not restarted by the task switch')
    ok(s:logged('continuing without it'))
end)

-- ── WCY-9: failed/cancelled completion results ──────────────────────────────

case('WCY-9: failed/cancelled results retry without the grace; repeated failures stop the loop', function()
    local s = session({town = true})
    s.player.pos = v(1035, 151)
    alfred(s, {enabled = true, need_trigger = true})
    s:enable(); s:run(0.3)
    eq(#s.triggers, 1)
    s.alfred_cb('failed')
    ok(s:logged('result=failed'), 'one-time diagnostic of the callback argument')
    s:run(4.5)
    eq(#s.triggers, 1, 'retry waits RETRY_DELAY')
    s:run(1)
    eq(#s.triggers, 2, 'a failed cycle is not a completed one: retried after 5 s')
    s.alfred_cb('cancelled'); s:run(5.5)
    eq(#s.triggers, 3)
    s.alfred_cb(false); s:run(10)
    eq(#s.triggers, 3, 'after 3 failures in a row the sticky grace applies')
    s:run(25)
    eq(#s.triggers, 4, 'and expires by itself')
    s.alfred_cb(true); s:run(10)
    eq(#s.triggers, 4, 'a successful result starts the grace')
end)

-- ── WCY-6 / C1: unreadable status is bounded ─────────────────────────────────

case('WCY-6: unreadable Alfred status never blocks the forced run-timeout exit', function()
    local s = session()
    alfred(s); s.alfred_error = true
    s:enable()
    s.now = s.tracker.undercity_start_time + 700
    s:tick()
    eq(s:task().name, 'exit_undercity', 'forced exit owns the pulse (was: alfred_running forever)')
    ok(s:until_true(function() return s.resets > 0 end, 12) ~= nil, 'reset after the exit delay')
end)

case('WCY-6: unreadable status in town holds at most ~10 s, logged once', function()
    local s = session({town = true})
    s.player.pos = v(1035, 151)
    alfred(s); s.alfred_error = true
    s:enable(); s:run(5)
    eq(s:task().name, 'alfred_running', 'short unknown window holds like busy')
    s:run(6)
    eq(s:task().name, 'walk_kurast', 'then Alfred counts as unavailable')
    local n = 0
    for _, line in ipairs(s.logs) do if line:find('treating Alfred as unavailable', 1, true) then n = n + 1 end end
    eq(n, 1)
    s.alfred_error = false; s.alfred = {enabled = true}
    s:tick()
    ok(s:logged('readable again'))
end)

case('C6: a known live Alfred holds the forced exit at most 120 s', function()
    local s = session()
    alfred(s, {enabled = true, trigger_tasks = true})
    s:enable()
    s.now = s.tracker.undercity_start_time + 700
    s:run(100)
    eq(s.resets, 0, 'a live Alfred cycle keeps its trip')
    eq(s:task().name, 'alfred_running')
    ok(s:until_true(function() return s:task().name == 'exit_undercity' end, 25) ~= nil, 'then the exit runs')
    ok(s:until_true(function() return s.resets > 0 end, 12) ~= nil)
    ok(s:logged('exiting anyway'))
end)

-- ── WCY-5 / WCY-8 / C3: Batmobile release ────────────────────────────────────

local function temis(s)
    s.gui.elements.town:set(1)
    s.world, s.world_id, s.zone = 'Sanctuary', 1, 'Skov_Temis'
    s.player.pos = v(2400, -400)
end

for _, with_release in ipairs({false, true}) do
    local label = with_release and ' (BatmobilePlugin.release)' or ' (older Batmobile)'
    case('WCY-5: foreign Alfred takes over: own Temis long path stops' .. label, function()
        local s = session({town = true, release = with_release})
        temis(s)
        alfred(s, {enabled = true})
        s:enable(); s:run(0.3)
        eq(s:task().name, 'walk_kurast')
        ok(s.navigating and s.nav_owner == 'wonder_city', 'own long route started')
        s.alfred = {enabled = true, trigger_tasks = true, need_trigger = true, inventory_full = true}
        s:run(1)
        eq(s:task().name, 'alfred_running')
        ok(not s.navigating, 'own autonomous route no longer drives the player (was: kept driving)')
        eq(#s.triggers, 0, 'the foreign cycle is not overwritten')
        if with_release then
            ok(s:count('release', 'wonder_city') >= 1, 'C3: owner-aware release on the switch to Alfred')
        end
        -- WarPigs disables WonderCity while Alfred still owns movement.
        s.external.disable()
        if with_release then
            ok(s:count('release', 'wonder_city') >= 1, 'C3: release(caller) used on disable even while Alfred owns control')
        end
        eq(s.priority, 'direction', 'WCY-8: default explorer priority restored')
    end)
end

case('WCY-5: a route another caller claimed since is never stopped by WonderCity', function()
    local s = session({town = true})
    temis(s)
    alfred(s, {enabled = true})
    s:enable(); s:run(0.3)
    ok(s.navigating)
    s.nav_owner = 'alfred' -- Alfred replaced the route with its own
    s.alfred = {enabled = true, trigger_tasks = true}
    local stops = s:count('stop_long_path')
    s:run(1)
    s.external.disable()
    eq(s:count('stop_long_path'), stops, 'foreign route untouched')
    ok(s.navigating)
end)

for _, with_release in ipairs({false, true}) do
    case('WCY-8: exploring leaves no distance priority behind after disable' .. (with_release and ' (release)' or ''),
    function()
        local s = session({release = with_release})
        s:enable(); s:run(1)
        eq(s:task().name, 'explore_undercity')
        eq(s.priority, 'distance', 'GUI default while exploring')
        s.external.disable()
        eq(s.priority, 'direction')
        if with_release then ok(s:count('release', 'wonder_city') == 1) end
    end)
end

-- ── C2 return leg of an own with-teleport trip ───────────────────────────────

case('C2: own trip callback in town holds for the return portal (bounded 30 s)', function()
    local s = session()
    alfred(s, {enabled = true, need_trigger = true, inventory_full = true})
    s:enable(); s:run(0.3)
    eq(#s.triggers, 1)
    s.alfred = {enabled = true, trigger_tasks = true, teleport = true}
    s:tick()
    s.world, s.world_id, s.zone = 'Sanctuary', 1, 'Naha_Kurast'
    s.player.pos = v(1035, 151)
    s:run(2)
    s.alfred = {enabled = true}
    s.alfred_cb()
    s:run(20)
    local st = s:status()
    ok(st.alfred_trip == true and st.in_run == true, 'return leg still belongs to the run')
    eq(s:task().name, 'alfred_running', 'no town walk while the return portal is pending')
    ok(s:task().note and s:task().note:find('return portal', 1, true), 'status names the hold')
    s:run(11)
    ok(s:status().alfred_trip == false, 'bounded')
    eq(s:task().name, 'walk_kurast')
    ok(s:logged('no Alfred return portal'))
end)

-- ── C4: orbwalker state is restored ──────────────────────────────────────────

case('C4: a forced clear-toggle off is restored on disable even after Manage orbwalker was switched off', function()
    local s = session()
    s.gui.elements.manage_orbwalker:set(true)
    s.actors = {s.player, reward_chest(1, true)}
    s:enable(); s:run(0.5)
    local last
    for _, c in ipairs(s.orb) do if c[1] == 'clear' then last = c[2] end end
    eq(last, false, 'chest interaction forced clear off')
    s.gui.elements.manage_orbwalker:set(false)
    s:run(0.5)
    s.external.disable()
    for _, c in ipairs(s.orb) do if c[1] == 'clear' then last = c[2] end end
    eq(last, true, 'clear toggle restored')
    for _, c in ipairs(s.orb) do ok(not (c[1] == 'block' and c[2] == true), 'WonderCity never blocks movement') end
end)

-- ── C5: yielding to Alfred is not progress/timeout time ──────────────────────

case('C5: an Alfred yield does not expire the chest interaction window', function()
    local s = session()
    alfred(s, {enabled = true})
    s.actors = {s.player, reward_chest(1, true)}
    s:enable(); s:run(3)
    ok(#s.interactions >= 1 and not s.tracker.done)
    s.alfred = {enabled = true, trigger_tasks = true}   -- foreign cycle in place
    s:run(30)
    eq(s:task().name, 'alfred_running')
    s.alfred = {enabled = true}
    s:tick()
    ok(not s.tracker.done, 'resuming does not immediately time the chest out')
    local t = s:until_true(function() return s.tracker.done end, 10)
    ok(t ~= nil and t >= 4, 'only the remaining interaction window runs: ' .. tostring(t))
end)

case('C5: an Alfred yield does not mark obols unreachable', function()
    local s = session()
    alfred(s, {enabled = true})
    local obols = actor('Obols', 10, 0); obols.obols = true
    s.items = {obols}
    s:enable(); s:run(6)
    eq(s:task().name, 'loot_obols')
    s.alfred = {enabled = true, trigger_tasks = true}
    s:run(20)
    s.alfred = {enabled = true}
    s:run(1)
    eq(s:task().name, 'loot_obols', 'obols still pursued after the yield')
    ok(s:task().status ~= 'unreachable obols — continuing')
    ok(s:until_true(function() return s:task().status == 'unreachable obols — continuing' end, 8) ~= nil,
        'the genuine no-progress window still applies')
end)

case('C5: a preempted Temis walk starts a fresh stuck window', function()
    local s = session({town = true})
    temis(s)
    alfred(s, {enabled = true})
    s:enable(); s:run(6)
    s.alfred = {enabled = true, trigger_tasks = true}
    s:run(20)
    s.alfred = {enabled = true}
    local teleports = #s.teleports
    s:run(3)
    eq(#s.teleports, teleports, 'no immediate stuck re-teleport after the yield')
end)

print(string.format('WonderCity integration: %d cases, %d checks, %d failures', cases, checks, #failures))
if #failures > 0 then error('WonderCity integration failures:\n' .. table.concat(failures, '\n')) end
print('PASS: test_integration_wondercity (' .. cases .. ' cases)')
