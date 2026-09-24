-- Independent integration checks: actual WarPigs bridge + actual SilentRaven
-- main, external, FSM and tracker modules. Only native host APIs and widgets
-- are simulated; cancellation is deliberately not mocked.
local root = assert(SUITE_ROOT)
local checks = 0
local function eq(actual, expected, message)
    assert(actual == expected, (message or 'mismatch') .. ': ' .. tostring(actual) .. ' ~= ' .. tostring(expected))
    checks = checks + 1
end

local function fixture(options)
    options = options or {}
    local c = {now = 100, zone = 'Skov_Temis', world = 'Town', enabled = true,
        moves = 0, clears = 0, escapes = 0, interacts = 0, teleports = 0, panel = false}
    local e = setmetatable({}, {__index = _G}); e._G = e
    e.WarPigsPlugin = options.controller
    local V = {}; V.__index = V
    function V:x() return self[1] end
    function V:y() return self[2] end
    function V:z() return self[3] end
    e.vec3 = {new = function(_, x, y, z) return setmetatable({x, y, z}, V) end}
    c.pos = e.vec3:new(2560, -480, 30)
    c.npc_pos = e.vec3:new(2596, -495, 30)
    c.npc = {get_skin_name = function() return 'temis_bounty_meta_raven_npc' end,
        is_interactable = function() return true end, get_position = function() return c.npc_pos end}
    local player = {is_dead = function() return c.dead == true end,
        get_active_spell_id = function() return c.active_spell or 0 end,
        get_buffs = function() return {} end,
        get_position = function() return c.pos end,
        get_attribute = function() return c.zone == 'Skov_Temis' and 1 or 0 end,
        get_inventory_items = function() return {} end, get_consumable_items = function() return {} end}
    e.get_local_player = function() return player end
    e.get_current_world = function() return {get_current_zone_name = function() return c.zone end,
        get_name = function() return c.world end} end
    e.get_time_since_inject = function() return c.now end
    e.attributes = {PLAYER_IN_TOWN_LEVEL_AREA = 1}
    e.get_quests = function() return {{get_name = function() return 'Bounty_Meta_Quest' end,
        get_objectives = function() return {{text = 'Return to the Tree of Whispers'}} end}} end
    e.actors_manager = {get_ally_actors = function() return {c.npc} end}
    e.console = {print = function() end}
    e.pathfinder = {request_move = function() c.moves = c.moves + 1 end,
        clear_stored_path = function() c.clears = c.clears + 1 end}
    e.utility = {send_key_press = function() c.escapes = c.escapes + 1; c.panel = false end}
    e.interact_object = function() c.interacts = c.interacts + 1; c.panel = true end
    e.teleport_to_waypoint = function() c.teleports = c.teleports + 1 end
    e.quest_reward = {is_open = function() return c.panel end}
    local function widget(value)
        return {get = function() return value end, set = function(_, next_value) value = next_value end,
            get_state = function() return value and 1 or 0 end}
    end
    local gui = {elements = {main_toggle = {get = function() return c.enabled end},
        debug_toggle = widget(false), auto_fire_toggle = widget(options.auto_fire == true), prefer_legendary_toggle = widget(true),
        legendary_bonus_slider = widget(50), manual_fire_keybind = widget(false), reload_catalog_toggle = widget(false)},
        render = function() end}
    local foreign_tracker = {foreign = true}
    local modules = {gui = {foreign = true}, ['core.tracker'] = foreign_tracker,
        ['core.settings'] = {foreign = true}, ['silent_raven.gui'] = gui}
    e.package = {loaded = modules}
    e.require = function(name)
        if modules[name] ~= nil then return modules[name] end
        assert(name:match('^silent_raven%.'), 'unexpected non-namespaced dependency: ' .. name)
        local value = assert(loadfile(root .. '/SilentRaven-0.1.3/' .. name:gsub('%.', '/') .. '.lua', 't', e))()
        modules[name] = value
        return value
    end
    e.on_update = function(fn) c.update = fn end
    e.on_render_menu = function() end
    assert(loadfile(root .. '/SilentRaven-0.1.3/main.lua', 't', e))()
    c.update()
    c.api, c.tracker = e.SilentRavenPlugin, e.require('silent_raven.tracker')
    local bridge_options = {}
    if options.alfred_idle then bridge_options.alfred_idle = function() return options.alfred_idle(c) end end
    c.bridge = assert(loadfile(root .. '/WarPigs-1.0.0/wp_silent_raven.lua', 't', e))().new(bridge_options)
    c.env, c.modules, c.gui, c.foreign_tracker = e, modules, gui, foreign_tracker
    function c:queue()
        self.bridge:observe(self.now, true)
        self.now = self.now + 1.1
        self.bridge:observe(self.now, true)
        eq(self.bridge:tick(self.now, true), true, 'visit owns a queued reward task')
        eq(self.api.get_status().pending, true, 'actual external queue is visible')
    end
    function c:walk()
        self:queue(); self.update()
        eq(self.tracker.running, true, 'actual FSM started')
        eq(self.tracker.movement_owned, true, 'actual FSM owns its native path')
        eq(self.moves > 0, true, 'actual native move requested')
    end
    return c
end

-- A published controller reservation applies before WarPigs's first pulse,
-- including auto-fire, manual input and a competing external caller.
do
    local c = fixture({auto_fire = true, controller = {status = function()
        return {enabled = true, manages_whispers = true}
    end}})
    eq(c.moves, 0, 'SR-first update respects controller reservation')
    eq(c.api.get_status().running, false)
    c.gui.elements.manual_fire_keybind:set(true); c.update()
    eq(c.teleports, 0, 'manual request cannot race a reserved town visit')
    eq(c.api.trigger_tasks('AnotherController'), false, 'foreign queue cannot take reserved slot')
    c:walk()
    eq(c.api.get_status().owner, 'WarPigs', 'reservation admits owning controller')
end

-- The opposite update order uses the explicit lease and remains safe even
-- when automatic operation is enabled between controller and SR pulses.
do
    local c = fixture()
    c.bridge:observe(c.now, true)
    c.gui.elements.auto_fire_toggle:set(true); c.update()
    eq(c.api.get_status().managed_by, 'WarPigs')
    eq(c.moves, 0, 'WP-first update prevents standalone auto-fire')
end

-- A missing response is not permission to seize the controller's slot.
do
    local c = fixture({auto_fire = true, controller = {status = function() error('unreadable controller') end}})
    eq(c.moves, 0); eq(c.api.get_status().running, false)
    eq(c.api.trigger_tasks('Other'), false)
end

-- Standalone mode remains available without a controller reservation. An
-- already running standalone request retains its ownership when WP starts.
do
    local c = fixture({auto_fire = true})
    eq(c.api.get_status().running, true, 'standalone auto-fire still runs')
    local before = c.moves
    c.env.WarPigsPlugin = {status = function() return {enabled = true, manages_whispers = true} end}
    c.bridge:observe(c.now, true)
    eq(c.api.get_status().managed_by, nil, 'new controller cannot claim a live standalone task')
    eq(c.api.get_status().owner, nil)
    eq(c.bridge:traffic_hold() ~= nil, true, 'controller yields to existing request')
    eq(c.api.cancel('WarPigs'), false, 'controller cannot cancel another owner')
    c.update(); eq(c.moves > before, true, 'existing request continues until completion')
end

-- Both modules agree on the explicit-false cleanup contract after the bridge
-- revokes its guard. This failed when external.cancel treated false as nil.
do
    local c = fixture(); c:walk()
    local before = c.clears
    eq(c.bridge:release(), true, 'master stop completes')
    eq(c.clears, before + 1, 'master stop clears its actual native path')
    eq(c.api.get_status().running, false)
    eq(c.api.get_status().pending, false)
    eq(c.api.get_status().managed_by, nil)
    eq(c.bridge:is_busy(), false)
    eq(c.api.cancel('WarPigs'), false, 'completed request cannot cancel twice')
    eq(c.clears, before + 1, 'no duplicate path cleanup')
end

-- The same cleanup is required at the bridge's deadline when no other owner
-- appeared; a surviving path could interrupt the next activity teleport.
do
    local c = fixture(); c:walk()
    local before = c.clears
    c.now = c.now + 61
    eq(c.bridge:tick(c.now, false), false, 'deadline closes owned request')
    eq(c.clears, before + 1, 'timeout clears its actual native path')
    eq(c.api.get_status().last_result, 'cancelled')
    eq(c.api.get_status().running, false)
end

-- Another owner's arrival revokes the guard and preserves its replacement
-- movement and UI; root cancellation is still an exactly-once completion.
for _, companion in ipairs({'looter', 'alfred'}) do
    local c = fixture(); c:walk()
    if companion == 'looter' then
        c.env.LooteerPlugin = {is_actively_looting = function() return true end}
    else
        c.env.AlfredTheButlerPlugin = {get_status = function() return {enabled = true, trigger_tasks = true} end}
    end
    local clears, escapes = c.clears, c.escapes
    eq(c.bridge:tick(c.now, false), false, companion .. ' preempts our request')
    eq(c.clears, clears, companion .. ' path is preserved')
    eq(c.escapes, escapes, companion .. ' UI is preserved')
    eq(c.api.get_status().running, false)
    eq(c.api.cancel('WarPigs'), false)
end

-- Alfred's completed-cycle grace grants admission, not a shorter deadline
-- for an already admitted reward task. Exercise both real callback orders.
for _, sr_first in ipairs({false, true}) do
    local c = fixture({alfred_idle = function(state) return state.now < 120 end})
    local alfred_status = {enabled = true, need_trigger = true}
    c.env.AlfredTheButlerPlugin = {get_status = function() return alfred_status end}
    c:walk()
    c.now = 125
    if sr_first then c.update() end
    eq(c.bridge:tick(c.now, false), true, 'admitted advisory survives 20s grace expiry')
    if not sr_first then c.update() end
    eq(c.api.get_status().running, true, 'real SR continuation survives grace expiry')
    eq(c.bridge:is_busy(), true)
    -- Live Alfred work still revokes the admitted request immediately.
    alfred_status.running = true
    eq(c.bridge:tick(c.now, false), false, 'new Alfred activity revokes advisory permission')
    eq(c.api.get_status().running, false)
end

-- A replacement Alfred cannot borrow the previous instance's advisory
-- permission, even while the original admission grace still returns true.
do
    local c = fixture({alfred_idle = function() return true end})
    c.env.AlfredTheButlerPlugin = {get_status = function() return {enabled = true, need_trigger = true} end}
    c:walk()
    c.env.AlfredTheButlerPlugin = {get_status = function() return {enabled = true, need_trigger = true} end}
    eq(c.bridge:tick(c.now, false), false, 'replacement Alfred does not inherit advisory permission')
    eq(c.api.get_status().running, false)
end

-- Permission expires when the original sticky flag clears. Its subsequent
-- return is fresh pending work, not the previously admitted sticky sample.
do
    local c = fixture({alfred_idle = function() return true end})
    local alfred_status = {enabled = true, need_trigger = true}
    c.env.AlfredTheButlerPlugin = {get_status = function() return alfred_status end}
    c:walk()
    alfred_status.need_trigger = false
    eq(c.bridge:tick(c.now, false), true)
    alfred_status.need_trigger = true
    eq(c.bridge:tick(c.now, false), false, 'fresh pending work cannot reuse cleared advisory')
end

-- Unreadable modern Looter ownership cannot become idle through the legacy
-- getter's false-as-nil compatibility. A second valid modern read may resolve it.
do
    local c = fixture()
    local looter = {get_enabled = function() return true end,
        is_actively_looting = function() error('status unavailable') end,
        getSettings = function() return nil end}
    c.env.LooteerPlugin = looter
    c.bridge:observe(c.now, true); c.now = c.now + 1.1; c.bridge:observe(c.now, true)
    eq(c.bridge:tick(c.now, true), true, 'unreadable modern owner holds admission')
    eq(c.api.get_status().pending, false, 'legacy nil cannot authorize SR queue')
    looter.is_idle = function() return true end
    c:walk()
    looter.is_idle = nil
    local clears = c.clears
    eq(c.bridge:tick(c.now, false), false, 'unreadable modern activity revokes running request')
    eq(c.clears, clears, 'unreadable owner retains its shared native path')
end
do
    local c = fixture()
    c.env.LooteerPlugin = {get_enabled = function() error('status unavailable') end,
        is_actively_looting = function() return false end, getSettings = function() return nil end}
    c.bridge:observe(c.now, true); c.now = c.now + 1.1; c.bridge:observe(c.now, true)
    eq(c.bridge:tick(c.now, true), true)
    eq(c.api.get_status().pending, false, 'unreadable modern enabled flag is not legacy disabled')
end

-- A published Alfred queue is busy before its running flag flips, including
-- while a previously admitted sticky advisory is still present.
do
    local c = fixture({alfred_idle = function() return true end})
    local status = {enabled = true, need_trigger = true, pending = true}
    c.env.AlfredTheButlerPlugin = {get_status = function() return status end}
    c.bridge:observe(c.now, true); c.now = c.now + 1.1; c.bridge:observe(c.now, true)
    eq(c.bridge:tick(c.now, true), true)
    eq(c.api.get_status().pending, false, 'Alfred pending holds a new SR queue')
    status.pending = false; c:walk()
    status.pending = true; c.update()
    eq(c.api.get_status().running, false, 'real SR guard yields to new Alfred pending flag')
    eq(c.bridge:tick(c.now, false), false)
end

-- Actual orchestrator completion callbacks bind their short admission grace
-- to the Alfred instance that completed, and stop invalidates old callbacks.
do
    local c = fixture()
    local previous_require = c.env.require
    c.env.require = function(name)
        if name == 'core.settings' then return {manage_whispers = true, use_teleport_transition = false} end
        if name == 'wp_silent_raven' then
            return assert(loadfile(root .. '/WarPigs-1.0.0/wp_silent_raven.lua', 't', c.env))()
        end
        if name == 'core.tasks.turn_in_rewards' then return {tick = function() end, get_state = function() return 'IDLE' end} end
        return previous_require(name)
    end
    c.env.actors_manager.get_all_actors = function() return {} end
    c.env.get_quests = function() return {} end
    c.env.get_aether_count = function() return 0 end
    local completed
    local first_status = {enabled = true, need_trigger = true, pending = true}
    local first = {get_status = function() return first_status end,
        trigger_tasks = function(_, callback) completed = callback; return true end}
    c.env.AlfredTheButlerPlugin = first
    local orchestrator = assert(loadfile(root .. '/WarPigs-1.0.0/core/orchestrator.lua', 't', c.env))()
    orchestrator.tick()
    eq(completed, nil, 'actual orchestrator does not retrigger Alfred pending queue')
    eq(orchestrator.alfred_idle(), false, 'published pending flag is not idle')
    first_status.pending = false; orchestrator.tick()
    eq(type(completed), 'function', 'actual orchestrator requested Alfred completion callback')
    completed('done')
    eq(orchestrator.alfred_idle(), true, 'same Alfred receives its completed-cycle grace')
    c.env.AlfredTheButlerPlugin = {get_status = first.get_status}
    eq(orchestrator.alfred_idle(), false, 'replacement Alfred cannot borrow completed-cycle grace')
    completed('done')
    eq(orchestrator.alfred_idle(), false, 'late previous-instance callback is rejected')
    eq(orchestrator.release_all(), true)
    c.env.AlfredTheButlerPlugin = first
    completed('done')
    eq(orchestrator.alfred_idle(), false, 'release invalidates completion callback and grace identity')
end

-- Cancellation before SR's first pulse never owned movement or a panel.
do
    local c = fixture(); c:queue()
    eq(c.bridge:release(), true)
    eq(c.moves, 0); eq(c.clears, 0); eq(c.escapes, 0)
    c.update(); eq(c.api.get_status().running, false)
end

-- SR's public API uses captured modules even when a different plugin owns
-- the loader context; generic suite keys are neither read nor rewritten.
do
    local c = fixture(); c:queue()
    c.env.require = function(name) error('foreign import context: ' .. name) end
    eq(c.api.get_status().owner, 'WarPigs')
    eq(c.bridge:release(), true)
    eq(c.modules['core.tracker'], c.foreign_tracker)
    eq(c.foreign_tracker.foreign, true)
    eq(c.env.PLUGIN_silent_raven, c.env.SilentRavenPlugin, 'legacy alias is same API object')
end

-- QQT's named loading sentinels must not rearm a completed Temis visit or
-- allow a standalone auto-fire while the world is not live.
do
    local c = fixture()
    c.gui.elements.auto_fire_toggle:set(true)
    c.tracker.last_observed_zone, c.tracker.last_zone_handled = 'Skov_Temis', 'Skov_Temis'
    c.zone = '[sno none]'; c.update()
    eq(c.tracker.last_zone_handled, 'Skov_Temis', 'named missing-zone sentinel preserves visit')
    c.zone, c.world = 'Skov_Temis', 'Limbo'; c.update()
    eq(c.api.get_status().running, false, 'Limbo with stale Temis zone cannot auto-fire')
    eq(c.tracker.last_zone_handled, 'Skov_Temis')
    c.world = 'Town'; c.update()
    eq(c.moves, 0, 'loading samples did not manufacture another visit')
end

-- The controller also rejects a stale Temis zone under a named loading world
-- before SR receives a queue, and starts normally after stable live samples.
do
    local c = fixture(); c.world = 'Loading_World'
    c.bridge:observe(c.now, true); c.now = c.now + 2; c.bridge:observe(c.now, true)
    eq(c.bridge:tick(c.now, true), false, 'named loading world cannot admit a request')
    eq(c.api.get_status().pending, false)
    c.world = 'Town'; c:queue()
end

-- Standalone teleport requests retain the source plugin's channel guard and
-- cannot recast into a loading screen or while the player is dead.
do
    local c = fixture(); c.zone = 'Dungeon'
    eq(c.api.trigger_tasks_with_teleport('StandaloneCaller'), true)
    c.update(); eq(c.teleports, 1)
    c.now = c.now + 4; c.update(); eq(c.teleports, 1, 'full channel window before retry')
    c.now = c.now + 3; c.active_spell = 186139; c.update()
    eq(c.teleports, 1, 'active portal cast suppresses retry even after debounce')
    c.active_spell = 0; c.update(); eq(c.teleports, 2)
    c.now = c.now + 7; c.world = 'Limbo'; c.update(); eq(c.teleports, 2, 'no teleport during loading')
    c.world = 'Town'; c.dead = true; c.update(); eq(c.teleports, 2, 'no teleport while dead')
    c.dead = false; c.update(); eq(c.teleports, 3, 'retry resumes with live player and world')
end

print('PASS independent bridge/SilentRaven contracts: ' .. checks .. ' assertions')
