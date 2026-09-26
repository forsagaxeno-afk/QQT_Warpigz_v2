-- SilentRaven integration regressions (CRT-3/L6, SRV-3, SRV-4/WPT-7, SRV-5,
-- SRV-6, SRV-8, L10, R15/L7, C1/C5/C6). Loads the real SilentRaven modules (and, in
-- one joint case, the real WarPug planner) with QQT-shaped host mocks.
-- SR_ROOT may point at another copy of SilentRaven (used to confirm that
-- each case fails on the pre-fix sources).
local root = rawget(_G, 'SR_ROOT') or (SUITE_ROOT .. '/SilentRaven-0.1.3/')
local PUG = SUITE_ROOT .. '/WarPug-1.0.0/'
local RAVEN, VIA, ARRIVAL = { 2596.38, -495.79 }, { 2597.24, -488.08 }, { 2579.58, -482.19 }
local checks, failures, cases = 0, {}, 0

local function eq(a, b, message)
    if a ~= b then error((message or 'mismatch') .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b), 2) end
    checks = checks + 1
end
local function ok(value, message)
    if not value then error(message or 'expected true', 2) end
    checks = checks + 1
end
local function case(name, fn)
    cases = cases + 1
    local passed, err = pcall(fn)
    if not passed then failures[#failures + 1] = name .. ': ' .. tostring(err) end
end
local function dist(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2) end

local function widget(value)
    return { get = function() return value end, set = function(_, v) value = v end,
        get_state = function() return value and 1 or 0 end, render = function() end,
        push = function() return true end, pop = function() end }
end

local function harness(o)
    o = o or {}
    local e = setmetatable({}, { __index = _G }); e._G = e
    local at = o.at or RAVEN
    local c = { time = 100, zone = 'Skov_Temis', enabled = o.enabled ~= false, quest = o.quest ~= false,
        text = 'Return to the Tree of Whispers', panel = false, items = {}, log = {},
        accepts = 0, selects = 0, interacts = 0, clears = 0, moves = 0, forces = 0, escapes = 0,
        esc_no_panel = 0, targets = {}, requires = {}, speed = 6, walk = o.walk == true,
        px = at[1], py = at[2], npc_x = RAVEN[1], npc_y = RAVEN[2], sel_mode = o.sel_mode or 'zero',
        entries = o.entries or { [1] = { sno = 1087411, valid = true, internal_name = 'BountyMeta_Cache_Helms' } } }
    math.randomseed(7)
    local V = {}; V.__index = V
    function V:x() return self[1] end; function V:y() return self[2] end; function V:z() return self[3] end
    function V:dist_to(other) return math.sqrt((self[1] - other[1]) ^ 2 + (self[2] - other[2]) ^ 2) end
    e.vec3 = { new = function(_, x, y, z) return setmetatable({ x, y, z }, V) end }
    c.dist_npc = function() return dist({ c.px, c.py }, { c.npc_x, c.npc_y }) end
    c.npc = { get_skin_name = function() return 'temis_bounty_meta_raven_npc' end,
        is_interactable = function() return true end,
        get_position = function() return e.vec3:new(c.npc_x, c.npc_y, 30.52) end }
    c.table_actor = { get_skin_name = function() return 'Warplans_Vendor' end,
        get_position = function() return e.vec3:new(c.px, c.py, 30.5) end }
    e.attributes = { PLAYER_IN_TOWN_LEVEL_AREA = 1 }
    e.get_time_since_inject = function() return c.time end
    e.get_current_world = function()
        if c.zone == nil then return nil end
        return { get_current_zone_name = function() return c.zone end, get_name = function() return 'Sanctuary' end,
            get_world_id = function() return 7 end }
    end
    local player = { is_dead = function() return false end,
        get_position = function() return e.vec3:new(c.px, c.py, 30.5) end,
        get_active_spell_id = function() return 0 end, get_attribute = function() return 1 end,
        get_buffs = function() return {} end,
        get_inventory_items = function() return c.items end, get_consumable_items = function() return {} end }
    e.get_local_player = function() return player end
    e.get_player_position = function() return player:get_position() end
    e.actors_manager = {
        get_ally_actors = function()
            if c.hide_npc or c.dist_npc() > (c.stream or math.huge) then return {} end
            return { c.npc }
        end,
        get_all_actors = function() return { c.npc, c.table_actor } end }
    e.get_quests = function()
        local out = {}
        if c.quest then
            out[1] = { get_name = function() return 'Bounty_Meta_Quest' end,
                get_objectives = function() return { { text = c.text } } end }
        end
        for _, name in ipairs(c.warplan_quests or {}) do
            out[#out + 1] = { get_name = function() return name end, get_objectives = function() return {} end }
        end
        return out
    end
    e.console = { print = function(m) c.log[#c.log + 1] = tostring(m) end }
    local function point(p) return { p:x(), p:y() } end
    e.pathfinder = {
        request_move = function(p)
            c.moves = c.moves + 1; c.targets[#c.targets + 1] = point(p)
            -- "Request to move if not already moving": a stale stored path wins.
            if not c.stale then c.target = point(p) end
        end,
        force_move_raw = function(p) c.forces = c.forces + 1; c.target = point(p) end,
        clear_stored_path = function() c.clears = c.clears + 1; c.stale = nil; c.target = nil end }
    e.utility = { send_key_press = function(key)
        if key ~= 0x1B then return end
        c.escapes = c.escapes + 1
        if not c.panel then c.esc_no_panel = c.esc_no_panel + 1 end
        c.panel = false
    end, send_mouse_click = function() end, send_mouse_move = function() end }
    e.interact_object = function() c.interacts = c.interacts + 1; if not c.no_panel then c.panel = true end end
    e.interact_vendor = function() end
    e.teleport_to_waypoint = function() end
    local function base() return c.entries[0] ~= nil and 0 or 1 end
    -- Live 2.1.2: the host enumerates fixed slots (empty ones sno=0,
    -- valid=false) but selects over the real cards only.
    local function real_cards()
        local out = {}
        for i = base(), base() + 16 do
            local entry = c.entries[i]
            if entry == nil then break end
            if entry.valid ~= false and tonumber(entry.sno) and tonumber(entry.sno) ~= 0 then out[#out + 1] = entry end
        end
        return out
    end
    e.quest_reward = {
        is_open = function() return c.panel end,
        enumerate = function() return c.entries end,
        select = function(i)
            c.selects = c.selects + 1
            if c.sel_mode == 'card' and (type(i) ~= 'number' or i < 0 or i >= #real_cards()) then return false end
            c.select_arg, c.select_t = i, c.time
            if c.select_ret == 'nil' then return nil end
            if c.select_ret == nil then return true end
            return c.select_ret
        end,
        selected_index = function()
            local i = c.select_arg
            if c.sel_mode == 'card' then return i or 0 end              -- panel opens on the first card
            if i == nil then return -1 end
            if c.sel_mode == 'key' then return i + 1 end              -- enumerate key space
            if c.sel_mode == 'late' then return c.time > c.select_t and i or -1 end -- next frame
            if c.sel_mode == 'wrong' then return 99 end
            if c.sel_mode == 'nil' then return nil end
            return i
        end,
        accept = function()
            c.accepts = c.accepts + 1
            local entry = c.sel_mode == 'card' and real_cards()[(c.select_arg or 0) + 1]
                or c.entries[(c.select_arg or 0) + base()]
            c.accepted_sno = entry and tonumber(entry.sno)
            if not c.no_delivery then
                local sno = c.accepted_sno
                c.items = { { get_sno_id = function() return sno end, get_acd = function() return 4321 end,
                    get_stack_count = function() return 1 end } }
                c.quest = false
            end
            c.panel = false
            return true
        end }
    if o.alfred ~= nil then
        c.alfred = o.alfred
        e.AlfredTheButlerPlugin = { get_status = function()
            if c.alfred == 'throw' then error('alfred status error') end
            return c.alfred
        end }
    end
    if o.looter then
        c.looting = o.looter == 'busy'
        e.LooteerPlugin = { get_enabled = function() return true end, is_actively_looting = function() return c.looting end }
    end
    if o.pug then c.pug = o.pug; e.WarPugPlugin = { status = function() return c.pug end } end
    if o.warpigs then c.wp = o.warpigs; e.WarPigsPlugin = { status = function() return c.wp end } end
    local gui = { elements = { main_toggle = { get = function() return c.enabled end }, debug_toggle = widget(false),
        auto_fire_toggle = widget(o.auto_fire == true), prefer_legendary_toggle = widget(true),
        legendary_bonus_slider = widget(50), manual_fire_keybind = widget(false),
        reload_catalog_toggle = widget(false) }, render = function() end }
    c.gui = gui
    local modules = {}
    if o.real_gui then
        local function ctor() return { new = function(_, a, b, d) return widget(d ~= nil and d or a) end } end
        e.checkbox = { new = function(_, default) return widget(default) end }
        e.slider_int = { new = function(_, _, _, default) return widget(default) end }
        e.keybind = { new = function() return widget(false) end }
        e.tree_node = ctor(); e.button = ctor()
        e.get_hash = function(s) return s end
        e.render_menu_header = function() end
    else
        modules['silent_raven.gui'] = gui
    end
    e.package = { loaded = modules }
    local function sr_require(name)
        c.requires[name] = (c.requires[name] or 0) + 1
        if modules[name] ~= nil then return modules[name] end
        local chunk = loadfile(root .. name:gsub('%.', '/') .. '.lua', 't', e)
        if not chunk then error("module '" .. name .. "' not found") end
        local value = chunk(); modules[name] = value; return value
    end
    e.require = sr_require
    c.e, c.sr_require = e, sr_require
    e.on_update = function(fn) c.update = fn end
    e.on_render_menu = function(fn) c.render = fn end
    if o.setup then o.setup(c, e) end
    e.require = sr_require
    assert(loadfile(root .. 'main.lua', 't', e))()
    c.api = e.SilentRavenPlugin
    c.tracker = sr_require('silent_raven.tracker'); c.rewards = sr_require('silent_raven.rewards')
    c.coordination = sr_require('silent_raven.coordination')
    c.sr_update = c.update
    function c.frame()
        e.require = sr_require
        c.sr_update()
        if c.after_update then c.after_update() end
    end
    function c.tick(dt)
        dt = dt or 0.1
        c.time = c.time + dt
        local t = c.stale or c.target
        -- block_via: a wall between the player and the intermediate.
        if c.walk and t and not c.frozen and not (c.block_via and dist(t, VIA) <= 3) then
            local d = dist({ c.px, c.py }, t)
            local step = c.speed * dt
            if d <= step then c.px, c.py = t[1], t[2]
            else c.px, c.py = c.px + (t[1] - c.px) / d * step, c.py + (t[2] - c.py) / d * step end
        end
        c.frame()
    end
    function c.run(seconds, dt)
        dt = dt or 0.1
        for _ = 1, math.floor(seconds / dt + 0.5) do c.tick(dt) end
    end
    function c.start(guard)
        c.api.set_managed('WarPigs', true)
        return c.api.trigger_tasks('WarPigs', function(result)
            c.callbacks = (c.callbacks or 0) + 1; c.result = result end, guard)
    end
    function c.count(pattern)
        local n = 0
        for _, m in ipairs(c.log) do if m:find(pattern, 1, true) then n = n + 1 end end
        return n
    end
    function c.status() return c.api.get_status() end
    c.frame()   -- first pulse reads the settings, as the host does
    return c, e
end

local FOUR_REGULAR = function(valid)
    return {
        [1] = { sno = 1087411, internal_name = 'BountyMeta_Cache_Helms', valid = valid },
        [2] = { sno = 1087551, internal_name = 'BountyMeta_Cache_LegGuards', valid = valid },
        [3] = { sno = 1087555, internal_name = 'BountyMeta_Cache_Gauntlets', valid = valid },
        [4] = { sno = 1087572, internal_name = 'BountyMeta_Cache_Amulets', valid = valid },
    }
end

-- CRT-3 / L6: the live panel (4 regular caches, all priorities 5) failed as
-- no_valid_reward. A missing `valid` field must not reject a card.
case('CRT-3 missing valid field claims the first regular cache', function()
    local c = harness({ entries = FOUR_REGULAR(nil) })
    eq(c.start(), true, 'queued')
    c.run(2)
    eq(c.result, 'success', 'claimed'); eq(c.accepts, 1); eq(c.accepted_sno, 1087411, 'priority pick is index 1')
    eq(c.count('/dump]'), 0, 'no dump on success')
end)
case('CRT-3 numeric-string sno and numeric valid are usable', function()
    local c = harness({ entries = {
        [1] = { sno = '1087411', internal_name = 'BountyMeta_Cache_Helms', valid = 0 },
        [2] = { sno = '1087551', internal_name = 'BountyMeta_Cache_LegGuards', valid = 1 },
    } })
    c.start(); c.run(2)
    eq(c.result, 'success'); eq(c.accepted_sno, 1087551, 'explicit 0 rejected, string sno normalized')
    eq(c.rewards.entry_usable({ sno = 1087411 }), true, 'missing valid is usable')
    eq(c.rewards.entry_usable({ sno = 1087411, valid = false }), false, 'explicit false rejected')
    eq(c.rewards.entry_usable({ valid = true }), false, 'no sno cannot be verified')
    eq(c.rewards.pick_best_index({ [1] = { valid = false, sno = 1087411 }, [2] = { sno = 1087551 } }, c.tracker and
        { slot_priorities = { helms = 5, legs = 5 }, prefer_legendary = true, legendary_bonus_weight = 50 }), 2)
end)
case('L6 no usable card prints exactly one automatic dump with every entry', function()
    local c = harness({ entries = FOUR_REGULAR(false) })
    c.entries[4].rarity = 'Legendary'
    c.start(); c.run(12)
    eq(c.result, 'failed'); eq(c.status().last_reason, 'no_valid_reward'); eq(c.accepts, 0)
    eq(c.count('reward diagnostics (no_valid_reward'), 1, 'one automatic dump per run')
    for k = 1, 4 do ok(c.count('/dump]   [' .. k .. '] table') == 1, 'entry ' .. k .. ' dumped once') end
    ok(c.count('valid=false(boolean)') == 4, 'valid value and type printed')
    ok(c.count('rarity=Legendary(string)') == 1, 'every other field printed')
    ok(c.count('selected index:') == 1 and c.count('api: ') == 1, 'host conventions printed')
    eq(c.esc_no_panel, 0, 'retries never press ESC without an open panel')
end)

-- SRV-3: select()/selected_index() conventions are unverified. Tolerate a
-- void select(), an enumerate-key selected_index and a next-frame update;
-- still refuse a selection that does not name our card.
for _, variant in ipairs({ { 'select returns nil', 'nil', 'zero' }, { 'selected_index in key space', true, 'key' },
    { 'selected_index updates next frame', true, 'late' } }) do
    case('SRV-3 ' .. variant[1], function()
        local c = harness({ entries = FOUR_REGULAR(true), sel_mode = variant[3] })
        c.select_ret = variant[2]
        c.start(); c.run(3)
        eq(c.result, 'success', variant[1]); eq(c.accepts, 1); eq(c.accepted_sno, 1087411)
    end)
end
for _, mode in ipairs({ 'wrong', 'nil' }) do
    case('SRV-3 unverifiable selection (' .. mode .. ') never accepts', function()
        local c = harness({ entries = FOUR_REGULAR(true), sel_mode = mode })
        c.start(); c.run(15)
        eq(c.accepts, 0); eq(c.result, 'failed'); eq(c.status().last_reason, 'selection_verification_failed')
        eq(c.count('reward diagnostics (selection_verification_failed'), 1, 'one dump')
        ok(c.escapes >= 1 and c.esc_no_panel == 0, 'ESC only closes the open panel')
    end)
end
case('live 2.1.2: empty leading slots, host selects over real cards only', function()
    local empty = function() return { sno = 0, valid = false, internal_name = '' } end
    local c = harness({ sel_mode = 'card', entries = { [1] = empty(), [2] = empty(),
        [3] = { sno = 1087411, valid = true, internal_name = 'BountyMeta_Cache_Helms' } } })
    c.start(); c.run(5)
    eq(c.result, 'success', 'claimed (was: selection_failed on select(2))'); eq(c.accepts, 1)
    eq(c.accepted_sno, 1087411)
    eq(c.count('card index space'), 1, 'convention logged once')
end)
case('live 2.1.2: card-space selection never accepts a different real card', function()
    local c = harness({ sel_mode = 'card', entries = {
        [1] = { sno = 0, valid = false, internal_name = '' },
        [2] = { sno = 1087411, valid = true, internal_name = 'BountyMeta_Cache_Helms' },
        [3] = { sno = 1087411, valid = true, internal_name = 'BountyMeta_Cache_Helms' } } })
    c.start(); c.run(5)
    eq(c.accepts <= 1, true)
    if c.accepts == 1 then eq(c.accepted_sno, 1087411) end
end)
case('SRV-3 explicit select() false is a refusal', function()
    local c = harness({ entries = FOUR_REGULAR(true) })
    c.select_ret = false
    c.start(); c.run(15)
    eq(c.accepts, 0); eq(c.status().last_reason, 'selection_failed')
end)

-- SRV-5: ESC only while a reward panel is observably open.
case('SRV-5 panel never opens: no ESC', function()
    local c = harness()
    c.no_panel = true
    c.start(); c.run(60)
    eq(c.result, 'failed'); eq(c.status().last_reason, 'panel_timeout'); eq(c.escapes, 0, 'no ESC without a panel')
end)
case('SRV-5 clean cancel after accept (panel closed): no ESC', function()
    local c = harness()
    c.no_delivery = true
    c.start()
    for _ = 1, 20 do c.tick(); if c.accepts > 0 then break end end
    eq(c.status().state, 'API_CLAIMING')
    eq(c.api.cancel('WarPigs', false), true); eq(c.result, 'cancelled'); eq(c.escapes, 0)
end)
case('SRV-5 clean cancel with the panel open still closes it', function()
    local c = harness({ sel_mode = 'wrong' })
    c.start(); c.tick(); c.tick()
    eq(c.panel, true)
    c.api.cancel('WarPigs', false)
    eq(c.escapes, 1); eq(c.esc_no_panel, 0)
end)

-- SRV-4 / WPT-7: unmanaged auto-fire admission.
case('SRV-4 auto-fire waits for a WarPug session and for the Looter', function()
    local c = harness({ auto_fire = true, pug = { enabled = true, state = 'FIND_PATH' }, looter = true })
    c.run(2)
    eq(c.status().running, false, 'no start while WarPug is mid-session'); eq(c.interacts, 0)
    eq(c.status().hold_reason, 'war_pug_busy', 'hold reason in status')
    c.pug.state = 'IDLE'; c.looting = true
    c.run(2)
    eq(c.status().running, false, 'no start while the Looter collects')
    eq(c.status().hold_reason, 'looter_busy:is_actively_looting')
    c.looting = false
    c.run(2)
    eq(c.status().last_result, 'success', 'claims once town is clear'); eq(c.accepts, 1)
    eq(c.status().hold_reason, nil)
end)
case('SRV-4 WarPigs busy (not managing Whispers) holds auto-fire', function()
    local c = harness({ auto_fire = true, warpigs = { enabled = true, manages_whispers = false, busy = true } })
    c.run(2); eq(c.interacts, 0); eq(c.status().hold_reason, 'war_pigs_busy')
    c.wp.busy = false; c.run(2); eq(c.status().last_result, 'success')
end)
case('C1/C6 Alfred matrix and bounded holds for auto-fire', function()
    local rows = {
        { { enabled = true, running = true }, false },
        { { enabled = true, pending = true }, false },
        { { enabled = true, teleport = true }, false },
        { { enabled = true, teleport = true, teleport_done = true }, true },
        { { enabled = true, teleport = true, teleport_failed = true }, true },
        { { enabled = false, running = true, inventory_full = true }, true },
        { { enabled = true, paused = true, need_trigger = true, restock_count = 3 }, true },
        { { enabled = true, inventory_full = true }, false },
        { { enabled = true, need_repair = true }, false },
    }
    for i, row in ipairs(rows) do
        local c = harness({ auto_fire = true, alfred = row[1] })
        c.run(1)
        eq(c.status().last_result == 'success', row[2], 'row ' .. i)
    end
    -- Hard need without a trip: bounded at 60 s, one log line.
    local c = harness({ auto_fire = true, alfred = { enabled = true, inventory_full = true } })
    c.run(59); eq(c.accepts, 0, 'hard need holds a new auto-fire')
    eq(c.count('auto-fire waiting'), 0)
    c.run(3); eq(c.status().last_result, 'success', 'then proceeds')
    eq(c.count('without starting a trip'), 1)
    -- Unreadable status: busy for at most 10 s, then unavailable with one log.
    c = harness({ auto_fire = true, alfred = 'throw' })
    c.run(9); eq(c.accepts, 0); eq(c.status().hold_reason, 'alfred_status_unavailable')
    c.run(2); eq(c.status().last_result, 'success'); eq(c.count('Alfred status unreadable'), 1)
end)
case('C6 a long companion hold is logged once and shown in the D4Remote status', function()
    local payloads = {}
    local c = harness({ auto_fire = true, looter = 'busy', setup = function(_, e)
        e.D4Remote = { register = function() end, update_stats = function(_, p) payloads[#payloads + 1] = p end }
    end })
    c.run(130)
    eq(c.accepts, 0); eq(c.count('auto-fire waiting'), 1, 'one log line after 60 s')
    eq(payloads[#payloads].status, 'Waiting: looter_busy:is_actively_looting')
    eq(payloads[#payloads].hold_reason, 'looter_busy:is_actively_looting')
end)
case('SRV-4 manual keybind defers while WarPug is mid-session', function()
    local c = harness({ pug = { enabled = true, state = 'CONFIRMING' } })
    c.gui.elements.manual_fire_keybind:set(true)
    c.tick()
    eq(c.status().running, false); eq(c.count('manual trigger deferred: war_pug_busy'), 1)
end)

-- SRV-4 / C5: an own run yields while the Looter collects; yield time does
-- not consume the walk/run timeouts and the Looter's path is never cleared.
case('C5 own run yields to the Looter without losing the walk', function()
    local c = harness({ auto_fire = true, looter = true, at = ARRIVAL, walk = true })
    c.stream = 12
    c.tick(); eq(c.status().running, true, 'auto-fire started')
    c.run(1)
    c.looting = true
    c.tick()
    local moves, clears = c.moves, c.clears
    c.run(30)
    eq(c.moves, moves, 'no movement requests while yielding'); eq(c.clears, clears, 'companion path untouched')
    eq(c.status().state, 'WALK_NPC'); eq(c.status().hold_reason, 'looter_busy:is_actively_looting')
    c.looting = false
    c.run(10)
    eq(c.status().last_result, 'success', 'walk resumed and claimed'); eq(c.accepts, 1)
    eq(c.count('npc_walk_timeout'), 0)
end)
case('C6 own-run yield is bounded and does not latch the visit', function()
    local c = harness({ auto_fire = true, looter = true, at = ARRIVAL, walk = true })
    c.stream = 12
    c.tick(); c.run(1); c.looting = true
    c.run(125)
    eq(c.status().last_result, 'cancelled'); eq(c.count('waiting 60s for looter_busy'), 1)
    eq(c.status().last_zone_handled, nil, 'visit stays eligible')
    c.looting = false; c.run(15)
    eq(c.status().last_result, 'success', 'auto-fire retries once the Looter is idle')
end)
case('Guard revocation keeps the visit eligible for the owner', function()
    local c = harness({ at = ARRIVAL })
    c.hide_npc = true
    local allowed = true
    c.start(function() return allowed, 'looter_busy' end); c.tick(); allowed = false; c.tick()
    eq(c.result, 'cancelled')
    eq(c.start(), true); c.tick()
    ok(c.result ~= 'skipped_latched', 'a revoked request can be asked again during the visit')
end)

-- R15 (live L7): the owner's continuation guard may answer
-- (false, 'yield:<reason>'): pause the request (no moves, clicks or accept,
-- companion path kept, attempts and timeouts frozen) and resume the current
-- step; 120 s of continuous pause cancels it as 'yield_timeout'.
local function owner_guard(c)
    c.answer = true
    return function()
        if c.answer == true then return true end
        return false, c.answer
    end
end
case('R15 guard yields 10 s mid-walk: paused, then the same request completes', function()
    local c = harness({ at = ARRIVAL, walk = true })
    local attempts = 0
    c.after_update = function() attempts = math.max(attempts, c.tracker.attempts) end
    eq(c.start(owner_guard(c)), true)
    c.run(1)
    eq(c.status().state, 'WALK_NPC'); ok(dist(c.target, VIA) <= 3, 'heading for the intermediate')
    local via = c.tracker.walk_intermediate
    c.answer = 'yield:looter_busy'; c.frozen = true       -- the Looter drives the player
    c.tick()
    local moves, clears, escapes = c.moves, c.clears, c.escapes
    c.run(10)
    local st = c.status()
    eq(st.running, true, 'request kept'); eq(st.owner, 'WarPigs'); eq(st.state, 'WALK_NPC')
    eq(st.attempts, 1, 'no attempt consumed'); eq(st.hold_reason, 'looter_busy', 'pause visible in the status')
    eq(c.moves, moves, 'no movement request while paused'); eq(c.clears, clears, 'companion path untouched')
    eq(c.escapes, escapes); eq(c.accepts, 0); eq(c.tracker.movement_owned, false, 'movement ownership dropped')
    eq(c.callbacks, nil, 'no completion while paused')
    c.answer = true; c.frozen = false
    c.tick()
    eq(c.moves, moves + 1, 'walk re-requested on resume'); eq(c.status().hold_reason, nil)
    eq(c.tracker.walk_intermediate, via, 'same waypoint kept')
    ok(dist(c.targets[#c.targets], VIA) <= 3, 'walk continues toward the same waypoint')
    c.run(10)
    eq(c.result, 'success', 'the same request completes'); eq(c.callbacks, 1); eq(c.accepts, 1)
    eq(attempts, 1, 'attempts unchanged'); eq(c.count('npc_walk_timeout'), 0)
end)
case('R15 a 100 s pause consumes no walk or run timeout (C5)', function()
    local c = harness({ at = ARRIVAL, walk = true })
    local attempts = 0
    c.after_update = function() attempts = math.max(attempts, c.tracker.attempts) end
    eq(c.start(owner_guard(c)), true)
    c.run(1)
    c.answer = 'yield:looter_busy'; c.frozen = true
    c.run(100)
    eq(c.status().running, true, 'still paused'); eq(c.count('waiting 60s for looter_busy'), 1, 'logged once')
    c.answer = true; c.frozen = false
    c.run(10)
    eq(c.result, 'success'); eq(attempts, 1); eq(c.count('resuming after'), 1)
    eq(c.count('npc_walk_timeout'), 0); eq(c.count('run_timeout'), 0)
end)
case('R15 guard yielding 130 s cancels as yield_timeout (bounded, visit kept)', function()
    local c = harness({ at = ARRIVAL, walk = true })
    eq(c.start(owner_guard(c)), true)
    c.run(1)
    c.answer = 'yield:looter_busy'; c.frozen = true
    local clears, escapes = c.clears, c.escapes
    c.run(119)
    eq(c.status().running, true, 'still paused before the 120 s bound'); eq(c.callbacks, nil)
    c.run(11)
    eq(c.result, 'cancelled'); eq(c.callbacks, 1, 'callback exactly once')
    eq(c.status().last_reason, 'yield_timeout'); eq(c.status().owner, nil)
    eq(c.clears, clears, 'companion path untouched'); eq(c.escapes, escapes); eq(c.accepts, 0)
    eq(c.count('waiting 60s for looter_busy'), 1, 'logged once (C6)')
    eq(c.status().last_zone_handled, nil, 'visit not consumed')
    eq(c.start(owner_guard(c)), true, 'the owner may ask again in this visit')
    c.frozen = false; c.run(10)
    eq(c.result, 'success')
end)
case('R15 a pause right before accept never accepts, then re-verifies and claims', function()
    local c = harness()           -- at the Raven: interact, open the panel, select
    local guard, paused_once = owner_guard(c), false
    c.start(function()
        -- The Looter starts the moment our card is selected.
        if c.selects > 0 and not paused_once then c.answer, paused_once = 'yield:looter_busy', true end
        return guard()
    end)
    c.run(1)
    eq(c.selects, 1, 'card selected'); eq(c.accepts, 0, 'no accept while paused')
    eq(c.status().running, true); eq(c.status().state, 'SELECT_VERIFY')
    c.run(5)
    eq(c.accepts, 0, 'still no accept while paused'); eq(c.selects, 1)
    c.answer = true
    c.run(2)
    eq(c.accepts, 1, 'accepted once after the pause'); eq(c.selects, 1, 'selection kept')
    eq(c.result, 'success'); eq(c.callbacks, 1)
end)
case('R15 a queued request stays queued while paused, then starts; the pause is bounded', function()
    local c = harness({ at = ARRIVAL, walk = true })
    local guard = owner_guard(c)
    c.answer = 'yield:looter_busy'
    eq(c.start(guard), true)
    c.run(5)
    local st = c.status()
    eq(st.pending, true, 'still queued'); eq(st.running, false); eq(st.owner, 'WarPigs')
    eq(st.hold_reason, 'looter_busy', 'pause visible while queued'); eq(c.moves, 0); eq(c.callbacks, nil)
    c.answer = true
    c.run(10)
    eq(c.result, 'success'); eq(c.callbacks, 1)
    local d = harness({ at = ARRIVAL })
    d.start(owner_guard(d)); d.answer = 'yield:looter_busy'
    d.run(121)
    eq(d.result, 'cancelled'); eq(d.status().last_reason, 'yield_timeout'); eq(d.moves, 0)
end)
case('R15 auto-fire never starts over a paused queued request (callback kept)', function()
    local c = harness({ at = ARRIVAL, walk = true })     -- auto-fire off until queued
    local results = {}
    local guard = owner_guard(c)
    c.answer = 'yield:looter_busy'
    eq(c.api.trigger_tasks('Other', function(r) results[#results + 1] = r end, guard), true, 'unmanaged caller queued')
    c.gui.elements.auto_fire_toggle:set(true)
    c.run(5)
    local st = c.status()
    eq(st.running, false, 'auto-fire did not start'); eq(st.pending, true); eq(st.owner, 'Other')
    c.answer = true
    c.run(10)
    eq(#results, 1, 'the queued caller is completed exactly once'); eq(results[1], 'success')
end)
case('R15 other false answers still revoke, also during a pause', function()
    for _, answer in ipairs({ 'alfred_busy', 'yield', 'looter_busy:yield:x' }) do
        local c = harness({ at = ARRIVAL, walk = true })
        eq(c.start(owner_guard(c)), true); c.run(1)
        c.answer = 'yield:looter_busy'; c.run(3)
        eq(c.status().running, true, answer .. ': paused first')
        local clears = c.clears
        c.answer = answer; c.tick()
        eq(c.result, 'cancelled', answer); eq(c.status().last_reason, answer)
        eq(c.clears, clears, answer .. ': path preserved'); eq(c.status().last_zone_handled, nil)
    end
    local c = harness({ at = ARRIVAL })
    c.start(function() return nil, 'yield:looter_busy' end); c.tick()
    eq(c.result, 'cancelled', 'only an explicit false pauses'); eq(c.status().last_reason, 'yield:looter_busy')
    c = harness({ at = ARRIVAL })
    c.start(function() error('guard broke') end); c.tick()
    eq(c.result, 'cancelled'); eq(c.status().last_reason, 'guard_error')
end)
case('R15 disabling SilentRaven aborts a paused request without clearing any path', function()
    local c = harness({ at = ARRIVAL, walk = true })
    eq(c.start(owner_guard(c)), true); c.run(1)
    c.answer = 'yield:looter_busy'; c.run(2)
    eq(c.status().running, true)
    local clears = c.clears
    c.enabled = false; c.tick()
    eq(c.result, 'disabled'); eq(c.callbacks, 1); eq(c.clears, clears, 'companion path untouched')
    eq(c.status().running, false)
end)
case('R15 panel closed and player moved away while paused: back to the NPC in the same attempt', function()
    local c = harness({ walk = true })   -- at the Raven
    local attempts = 0
    c.after_update = function() attempts = math.max(attempts, c.tracker.attempts) end
    local guard = owner_guard(c)
    c.start(function()
        if c.panel and c.selects == 0 and not c.moved then c.answer = 'yield:looter_busy' end
        return guard()
    end)
    c.run(1)
    eq(c.status().state, 'INTERACT_NPC'); eq(c.selects, 0, 'no selection while paused')
    -- The Looter walks the player away and the panel closes.
    c.moved, c.panel, c.px, c.py = true, false, ARRIVAL[1], ARRIVAL[2]
    c.run(3)
    eq(c.status().running, true)
    c.answer = true
    c.tick()
    eq(c.status().state, 'WALK_NPC', 'walks back to the NPC')
    c.run(15)
    eq(c.result, 'success'); eq(attempts, 1, 'same attempt'); eq(c.count('panel_timeout'), 0)
end)
case('R15 a definite departure from Temis ends a paused request', function()
    local c = harness({ at = ARRIVAL, walk = true })
    eq(c.start(owner_guard(c)), true); c.run(1)
    c.answer = 'yield:looter_busy'; c.run(2)
    local clears = c.clears
    c.zone = nil; c.run(1)
    eq(c.status().running, true, 'a loading sample is not a departure')
    c.zone = 'Kehj_Caldeum'; c.tick()
    eq(c.result, 'cancelled'); eq(c.status().last_reason, 'left_temis'); eq(c.clears, clears)
end)
case('R15 a yield answer after accept does not cancel the receipt', function()
    local c = harness()
    local guard = owner_guard(c)
    c.start(function()
        if c.accepts > 0 then c.answer = 'yield:looter_busy' end
        return guard()
    end)
    c.run(3)
    eq(c.accepts, 1); eq(c.result, 'success'); eq(c.callbacks, 1)
end)

-- L10: robust walk to the Raven.
case('L10 walk goes via the intermediate even when the NPC is visible', function()
    local c = harness({ at = ARRIVAL, walk = true })
    c.start(); c.tick()
    ok(#c.targets > 0, 'walking')
    ok(dist(c.targets[1], VIA) <= 3, 'first target is the intermediate, not the NPC behind the wall')
    c.run(8)
    eq(c.result, 'success')
end)
case('L10 reached intermediate is not re-targeted (no oscillation)', function()
    local c = harness({ at = ARRIVAL, walk = true })
    c.stream = 5     -- the NPC only enters the actor stream when very close
    local attempts = 0
    c.after_update = function() attempts = math.max(attempts, c.tracker.attempts) end
    c.start(); c.run(15)
    eq(c.result, 'success', 'reaches the Raven'); eq(attempts, 1, 'first attempt')
    local seen_npc = false
    for _, t in ipairs(c.targets) do
        if dist(t, RAVEN) < 0.5 then seen_npc = true end
        if seen_npc then ok(dist(t, RAVEN) < 0.5, 'never back to the intermediate') end
    end
    ok(seen_npc, 'targeted the NPC after the intermediate')
end)
case('L10 stale stored path: stall detected, dropped once, walk proceeds', function()
    local c = harness({ at = ARRIVAL, walk = true })
    c.stale = { 2560, -470 }     -- leftover route leading away from the Raven
    local attempts = 0
    c.after_update = function() attempts = math.max(attempts, c.tracker.attempts) end
    c.start(); c.run(12)
    eq(c.result, 'success', 'claimed'); eq(attempts, 1, 'first attempt')
    eq(c.count('walk stalled'), 1, 'one log line'); ok(c.clears >= 1, 'stale path dropped')
    eq(c.count('npc_walk_timeout'), 0, 'recovered within the first attempt')
end)
case('L10 unreachable intermediate falls back to the NPC within the attempt', function()
    local c = harness({ at = { 2596.38, -510.8 }, walk = true })
    c.block_via = true
    local attempts = 0
    c.after_update = function() attempts = math.max(attempts, c.tracker.attempts) end
    c.start(); c.run(12)
    eq(c.result, 'success'); eq(attempts, 1, 'first attempt'); eq(c.count('walk stalled'), 1)
end)
case('L10 immobile player: one log line, direct move from the second stall, bounded', function()
    local c = harness({ at = ARRIVAL, walk = true })
    c.frozen = true
    c.start(); c.run(10)
    eq(c.count('walk stalled'), 1); ok(c.forces >= 1, 'direct move attempted')
    ok(c.count('batmobile=absent') == 1, 'Batmobile state in the diagnostic')
    c.run(70)
    eq(c.result, 'failed'); eq(c.count('walk stalled'), 1, 'still one line per run')
end)
case('L10 stall diagnostic reports a leftover Batmobile target read-only', function()
    local c = harness({ at = ARRIVAL, walk = true, setup = function(c, e)
        e.BatmobilePlugin = { is_paused = function() return false end, get_target = function() return { 1, 2 } end,
            get_path = function() return { 1, 2, 3 } end,
            clear_target = function() c.bat_mutated = true end, stop_long_path = function() c.bat_mutated = true end }
    end })
    c.frozen = true
    c.start(); c.run(4)
    eq(c.count('batmobile paused=false target=set path=#3'), 1); eq(c.bat_mutated, nil, 'Batmobile untouched')
end)
case('L10 stall recovery never clears while the Looter may own movement', function()
    local c = harness({ at = ARRIVAL, walk = true, looter = true })
    c.frozen = true; c.looting = true
    c.start(function() return true end)  -- owner-verified run; SR's own reading still sees the Looter
    c.run(10)
    eq(c.clears, 0); eq(c.forces, 0); eq(c.count('walk stalled'), 0)
end)

-- SRV-6: the menu renderer must not probe the disk every frame.
case('SRV-6 last_sync is read at most once per 30 s', function()
    local c = harness({ real_gui = true })
    for _ = 1, 100 do c.time = c.time + 0.016; c.render() end
    ok((c.requires['silent_raven.data.last_sync'] or 0) <= 1, 'renders re-required last_sync ' ..
        tostring(c.requires['silent_raven.data.last_sync']) .. 'x')
    c.time = c.time + 31; c.render()
    eq(c.requires['silent_raven.data.last_sync'], 2, 'refreshed after the TTL')
end)

-- SRV-8: D4Remote record_loot per success and late registration.
case('SRV-8 D4Remote late register and record_loot once per claim', function()
    local c = harness()
    local registered, loot = 0, {}
    c.e.D4Remote = { register = function() registered = registered + 1 end, update_stats = function() end,
        record_loot = function(category, rarity) loot[#loot + 1] = category .. ':' .. tostring(rarity) end }
    c.run(3)
    eq(registered, 1, 'registered after a late load, once')
    c.start(); c.run(2)
    eq(c.result, 'success'); eq(#loot, 1); eq(loot[1], 'helm:4')
end)

-- Joint: real WarPug planner. SR never starts while WarPug is mid-session,
-- WarPug is never halted by SR, and both finish (SRV-4 test guidance).
case('SRV-4 joint with the real WarPug planner', function()
    local c = harness({ auto_fire = true, quest = false, setup = function(c, e)
        c.path, c.required, c.confirms, c.warplan_ready = {}, 2, 0, false
        e.warplan = {
            is_ready = function() return c.warplan_ready end,
            required_picks = function() return c.required end,
            selected_count = function() return #c.path end,
            selected_path = function() local out = {}; for i, v in ipairs(c.path) do out[i] = v end; return out end,
            is_complete = function() return #c.path == c.required end,
            get_selectable_now = function()
                return ({ root = { 2, 3 }, [2] = { 3 }, [3] = { 2 } })[c.path[#c.path] or 'root'] or {}
            end,
            node_name = function(id) return ({ [2] = 'Warplans_ThePit', [3] = 'Warplans_Helltide' })[id] end,
            select_node = function(id) c.path[#c.path + 1] = id; return true end,
            deselect_last = function() return table.remove(c.path) ~= nil end,
            confirm = function() c.confirms = c.confirms + 1; c.warplan_quests = { 'WarPlans_QST_ThePit' } end,
            teleport_to_activity = function() end,
        }
        e.get_screen_width = function() return 1000 end
        e.get_screen_height = function() return 800 end
        local pug_settings = { enabled = true, table_actor_name = 'Warplans_Vendor', verbose_logs = false,
            reroll_set = true, confirm_set = true, reroll_click_x = 1, reroll_click_y = 1,
            reroll_confirm_x = 2, reroll_confirm_y = 2, plugin_version = 'test' }
        local pug_modules = { ['core.settings'] = pug_settings }
        local function pug_require(name)
            if pug_modules[name] ~= nil then return pug_modules[name] end
            local value = assert(loadfile(PUG .. name:gsub('%.', '/') .. '.lua', 't', e))()
            pug_modules[name] = value; return value
        end
        e.require = pug_require
        c.planner = pug_require('core.planner')
        e.WarPugPlugin = pug_require('core.external')
        c.pug_require = pug_require
    end })
    local sr_frame = c.frame
    local starts_mid_session, halted = 0, false
    function c.frame()
        -- WarPug's callback runs first in the frame, as in the reviewer's repro.
        c.e.require = c.pug_require; c.planner.tick()
        local was_running = c.status().running
        sr_frame()
        local state = c.planner.get_current_state()
        if not was_running and c.status().running and state ~= 'IDLE' and state ~= 'HALTED' and state ~= 'DONE_WAIT' then
            starts_mid_session = starts_mid_session + 1
        end
        if state == 'HALTED' then halted = true end
    end
    c.run(0.6)
    ok(c.planner.get_current_state() ~= 'IDLE', 'WarPug session started')
    c.quest = true               -- the bounty becomes ready mid-session
    c.run(3)
    eq(c.status().running, false, 'SR waits for the WarPug session')
    c.warplan_ready = true       -- the war plan board opens
    c.run(40)
    eq(starts_mid_session, 0, 'SR never started inside a WarPug session')
    eq(halted, false, 'WarPug never halted'); eq(c.confirms, 1, 'WarPug confirmed its plan')
    eq(c.status().last_result, 'success', 'SR claimed after WarPug finished')
end)

if #failures > 0 then
    error('SilentRaven integration regressions failed (' .. #failures .. '/' .. cases .. '):\n  ' ..
        table.concat(failures, '\n  '))
end
print('PASS: SilentRaven integration regressions: ' .. cases .. ' cases, ' .. checks .. ' checks')
