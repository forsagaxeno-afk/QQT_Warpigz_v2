-- R15 joint regression: the actual WarPigs bridge with the actual SilentRaven
-- main/external/FSM/tracker modules (only native host APIs are simulated).
-- A short Looter burst before accept must not make the bridge cancel the
-- managed Whisper request: the continuation guard answers
-- (false, 'yield:looter_busy'). A yield-aware SilentRaven pauses and keeps the
-- request; an older build treats the answer as a cancel, which must stay safe
-- (path and reward UI preserved, the request is retried in the same visit).
-- The assertions accept both SilentRaven builds. Hard cancels (Alfred live
-- work) are unchanged; a burst after accept never cancels the claim.
-- Fixture adapted from test_secondpass_contracts.lua.
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
        local queued = self.bridge:tick(self.now, true)
        -- L7: with a Looter loaded, the bridge first waits for its quiet window.
        for _ = 1, 6 do
            if self.api.get_status().pending then break end
            self.now = self.now + 1
            self.bridge:observe(self.now, true)
            queued = self.bridge:tick(self.now, true)
        end
        eq(queued, true, 'visit owns a queued reward task')
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

local function pulse(c, seconds, busy_fn)
    local stop = c.now + seconds
    while c.now < stop - 1e-9 do
        c.now = c.now + 0.5
        if busy_fn then c.busy = busy_fn(c) end
        c.bridge:observe(c.now, true)
        c.bridge:tick(c.now, true)
        c.update()
    end
end

-- Looter burst mid-walk: paused by the bridge, then either paused by
-- SilentRaven (yield-aware) or cancelled by it with the yield reason.
for _, order in ipairs({'bridge_first', 'raven_first'}) do
    local c = fixture(); c:walk()
    c.env.LooteerPlugin = {get_enabled = function() return true end,
        is_actively_looting = function() return c.busy == true end}
    c.busy = true
    local clears, escapes = c.clears, c.escapes
    local ok, why = c.tracker.continuation_guard()
    eq(ok, false); eq(why, 'yield:looter_busy', order .. ': guard asks SilentRaven to pause')
    if order == 'raven_first' then c.now = c.now + 0.5; c.update() end
    local held = c.bridge:tick(c.now, false)
    local st = c.api.get_status()
    local older = st.running == false and st.last_result == 'cancelled' and st.last_reason == 'yield:looter_busy'
    if order == 'bridge_first' then
        eq(held, true, order .. ': the bridge does not cancel on a Looter burst')
        eq(st.running, true, order .. ': request still running after the bridge pulse')
    else
        -- An older SilentRaven already cancelled on the yield answer; the
        -- bridge only acknowledges it (and retries later in the visit).
        eq(held == true or older, true, order .. ': paused, or acknowledged older-build cancel')
    end
    c.now = c.now + 0.5; c.update()
    st = c.api.get_status()
    local paused = st.running == true and st.owner == 'WarPigs'
    older = st.running == false and st.last_result == 'cancelled' and st.last_reason == 'yield:looter_busy'
    eq(paused or older, true, order .. ': paused (yield-aware) or cancelled with the yield reason (older build)')
    eq(c.clears, clears, order .. ': the Looter path is preserved')
    eq(c.escapes, escapes, order .. ': the reward UI is preserved')
    -- The burst ends: the same request resumes, or a new one is made in this visit.
    c.busy = false
    pulse(c, 10)
    st = c.api.get_status()
    eq(st.owner, 'WarPigs', order .. ': Whisper claim continues in the visit')
    eq(st.running == true or st.pending == true, true, order .. ': request active again')
end

-- A burst after accept (API_CLAIMING): SilentRaven only verifies the cache
-- receipt, so the bridge answers the yield (SilentRaven ignores a pause after
-- accept) and neither side cancels the claimed request (joint suite: a
-- claimed reward was reported 'cancelled' and re-requested twice).
do
    local c = fixture(); c:walk()
    c.env.LooteerPlugin = {get_enabled = function() return true end, is_actively_looting = function() return true end}
    c.tracker.state, c.tracker.claim_sent = 'API_CLAIMING', true
    local ok, why = c.tracker.continuation_guard()
    eq(ok, false); eq(why, 'yield:looter_busy', 'after accept: yield answer')
    eq(c.bridge:tick(c.now, false), true, 'after accept the bridge keeps the request')
    c.now = c.now + 0.5; c.update()
    eq(c.api.get_status().running, true, 'SilentRaven keeps verifying')
    eq(c.api.get_status().paused, false, 'no pause after accept')
end

-- Live Alfred work stays a hard cancel with the other owner's path preserved.
do
    local c = fixture(); c:walk()
    c.env.AlfredTheButlerPlugin = {get_status = function() return {enabled = true, trigger_tasks = true} end}
    local clears, escapes = c.clears, c.escapes
    local ok, why = c.tracker.continuation_guard()
    eq(ok, false); eq(why, 'alfred_busy')
    eq(c.bridge:tick(c.now, false), false, 'Alfred preempts our request')
    eq(c.clears, clears); eq(c.escapes, escapes)
    eq(c.api.get_status().running, false)
end

print('PASS WarPigs/SilentRaven R15 yield contract: ' .. checks .. ' checks (actual bridge + actual SilentRaven)')
