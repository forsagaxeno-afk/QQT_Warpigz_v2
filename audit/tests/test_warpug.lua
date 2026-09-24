local root = assert(SUITE_ROOT) .. '/WarPug-1.0.0/'
-- The cross-plugin cases load the actual WarPigs dispatcher, which now captures
-- its dedicated Whisper bridge during bootstrap.
package.path = SUITE_ROOT .. '/WarPigs-1.0.0/?.lua;' .. package.path
local function equal(actual, expected, message)
    assert(actual == expected, (message or 'mismatch') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end
local function fixture()
    local f = { now = 100, dead = false, player = true, zone = 'Skov_Temis', world = 7,
        ready = true, quests = {}, path = {}, required = 2, confirms = 0, selections = 0,
        deselections = 0, clicks = {}, interacts = 0, moves = 0, width = 1000, height = 800 }
    f.settings = { enabled = true, table_actor_name = 'Warplans_Vendor', verbose_logs = false,
        reroll_set = true, confirm_set = true, reroll_click_x = 150, reroll_click_y = 700,
        reroll_confirm_x = 700, reroll_confirm_y = 550 }
    f.names = { [1] = 'Warplans_NightmareDungeons', [2] = 'Warplans_ThePit', [3] = 'Warplans_Helltide',
        [4] = 'Warplans_InfernalHordes', [5] = 'Warplans_Undercity' }
    f.edges = { root = { 1, 2, 3 }, [2] = { 1 }, [3] = { 4, 5 } }
    package.loaded['core.settings'] = f.settings
    WarPigsPlugin, AlfredTheButlerPlugin, PLUGIN_alfred_the_butler = nil, nil, nil
    console = { print = function() end }
    get_time_since_inject = function() return f.now end
    get_local_player = function() if f.player then return { is_dead = function() return f.dead end } end end
    get_current_world = function()
        if f.world then return { get_current_zone_name = function() return f.zone end,
            get_world_id = function() return f.world end, get_name = function() return 'Sanctuary' end } end
    end
    get_quests = function()
        local out = {}
        for i, name in pairs(f.quests) do out[i] = { get_name = function() return name end } end
        return out
    end
    get_screen_width = function() return f.width end
    get_screen_height = function() return f.height end
    warplan = {
        is_ready = function() return f.ready end,
        required_picks = function() return f.required end,
        selected_count = function() return #f.path end,
        selected_path = function() return { (table.unpack or unpack)(f.path) } end,
        is_complete = function() return #f.path == f.required end,
        get_selectable_now = function() return f.edges[f.path[#f.path] or 'root'] or {} end,
        node_name = function(id) return f.names[id] end,
        select_node = function(id)
            for _, legal in ipairs(warplan.get_selectable_now()) do
                if legal == id then f.path[#f.path + 1] = id; f.selections = f.selections + 1; return true end
            end
            return false
        end,
        deselect_last = function() f.deselections = f.deselections + 1; return table.remove(f.path) ~= nil end,
        confirm = function() f.confirms = f.confirms + 1 end,
    }
    utility = {
        send_mouse_move = function() end,
        send_mouse_click = function(x, y) f.clicks[#f.clicks + 1] = { x, y } end,
    }
    actors_manager = { get_all_actors = function()
        return { { get_skin_name = function() return 'Warplans_Vendor' end,
            get_position = function() return {} end } }
    end }
    get_player_position = function() return { dist_to = function() return 0 end } end
    pathfinder = { request_move = function() f.moves = f.moves + 1 end }
    interact_vendor = function() f.interacts = f.interacts + 1 end
    f.p = dofile(root .. 'core/planner.lua')
    function f.tick(dt) f.now = f.now + (dt or 0.5); f.p.tick() end
    function f.until_state(wanted)
        for _ = 1, 60 do if f.p.get_current_state() == wanted then return end; f.tick() end
        error('Never reached ' .. wanted .. '; got ' .. f.p.get_current_state())
    end
    function f.blocked() f.edges = { root = { 1 } } end
    return f
end

-- Actual DFS must backtrack from a dead end, exclude nightmares and submit
-- only the valid complete path. The host confirm() intentionally returns nil.
do
    local f = fixture(); f.until_state('CONFIRMING')
    equal(table.concat(f.path, ','), '3,4'); equal(f.deselections, 1)
    f.tick(); equal(f.confirms, 1); equal(f.p.get_current_state(), 'DONE_WAIT')
    f.quests = { [4] = 'WarPlans_QST_ThePit' }; f.tick()
    equal(f.p.get_current_state(), 'IDLE'); equal(f.deselections, 1, 'accepted plan preserved')
end

-- User selections and edits belong to the user, including at disable time.
do
    local f = fixture(); f.path = { 3 }; f.tick(); f.tick(); f.settings.enabled = false; f.tick()
    equal(table.concat(f.path, ','), '3'); equal(f.confirms, 0); equal(f.deselections, 0)
    f = fixture(); f.until_state('CONFIRMING'); f.path = { 2, 1 }; f.tick()
    equal(f.confirms, 0); f.settings.enabled = false; f.tick(); equal(table.concat(f.path, ','), '2,1')
end

-- Disabling can undo an unchanged bot-owned path, but never a submitted plan.
do
    local f = fixture(); f.until_state('CONFIRMING'); f.settings.enabled = false; f.tick(); equal(#f.path, 0)
    f = fixture(); f.until_state('DONE_WAIT'); local before = f.deselections
    f.settings.enabled = false; f.tick(); equal(#f.path, 2); equal(f.deselections, before)
end

-- Missing/malformed quests fail closed, including sparse quest snapshots.
do
    local f = fixture(); get_quests = function() error('loading') end; f.tick(); f.tick(); equal(f.selections, 0)
    f = fixture(); get_quests = function() return { { get_name = function() error('stale') end } } end
    f.tick(); equal(f.p.get_current_state(), 'IDLE')
    f = fixture(); f.quests = { [9] = 'WarPlans_QST_TurnIn_Rewards' }; f.tick(); equal(f.p.get_current_state(), 'IDLE')
end

-- A dead/missing player, changed instance, or lost world cannot confirm a
-- previously selected plan or mutate selections during a loading screen.
for _, invalidate in ipairs({
    function(f) f.dead = true end, function(f) f.player = false end,
    function(f) f.world = nil end, function(f) f.world = 8 end,
}) do
    local f = fixture(); f.until_state('CONFIRMING'); local before = f.deselections
    invalidate(f); f.tick(); equal(f.confirms, 0); equal(f.deselections, before)
end

-- Bad native snapshots do not recurse forever, confirm empty data, or spend
-- rerolls on names that cannot be classified.
for _, damage in ipairs({
    function(f) f.required = 0 end,
    function(f) f.required = -1 end,
    function(f) f.required = '2' end,
    function(f) f.names[2] = '' end,
    function() warplan.select_node = function() return true end end,
    function() warplan.deselect_last = function() return true end end,
}) do
    local f = fixture(); damage(f); f.tick(); f.tick()
    equal(f.p.get_current_state(), 'HALTED'); equal(f.confirms, 0); equal(#f.clicks, 0)
end

-- No timeout or native exception may blindly resubmit an ambiguous plan.
do
    local f = fixture(); f.until_state('DONE_WAIT'); f.tick(31); f.tick(1000)
    equal(f.confirms, 1); equal(f.p.get_current_state(), 'HALTED')
    f = fixture(); warplan.confirm = function() f.confirms = f.confirms + 1; error('after send') end
    f.until_state('CONFIRMING'); f.tick(); f.tick(31); equal(f.confirms, 1)
end

-- Rerolls use native client coordinates only after a fresh vendor interaction;
-- the safety cap stops the session instead of resetting and starting again.
do
    local f = fixture(); f.blocked()
    for _ = 1, 500 do if f.p.get_current_state() == 'HALTED' then break end; f.tick() end
    equal(f.p.get_current_state(), 'HALTED'); equal(#f.clicks, 20); equal(f.interacts, 10)
    equal(f.clicks[1][1], 150); equal(f.clicks[2][1], 700)
    f.tick(200); equal(#f.clicks, 20)
end

-- Invalid calibration and a failed first native click cannot fire Confirm.
for _, damage in ipairs({
    function(f) f.settings.reroll_set = false end,
    function(f) f.settings.reroll_click_x = math.huge end,
    function(f) f.settings.reroll_confirm_y = 900 end,
    function() utility.send_mouse_click = function() error('host unavailable') end end,
}) do
    local f = fixture(); f.blocked(); damage(f)
    f.until_state('HALTED'); equal(#f.clicks, 0)
end

-- Every delayed Confirm must still match its live context and short deadline.
for _, invalidate in ipairs({
    function(f) f.dead = true end,
    function(f) f.player = false end,
    function(f) f.zone = 'Dungeon' end,
    function(f) f.world = 8 end,
    function(f) f.ready = false end,
    function(f) f.path = { 3 } end,
    function(f) f.settings.enabled = false end,
    function(f) f.width = 1200 end,
    function(f) f.settings.reroll_confirm_x = 500 end,
    function(f) f.now = f.now + 20 end,
    function() get_quests = function() return nil end end,
    function() AlfredTheButlerPlugin = { get_status = function() return { enabled = true, trigger_tasks = true } end } end,
}) do
    local f = fixture(); f.blocked(); f.until_state('REROLL_WAIT1'); equal(#f.clicks, 1)
    invalidate(f); for _ = 1, 8 do f.tick() end
    equal(#f.clicks, 1, 'unsafe delayed confirmation suppressed')
end

-- Existing integration contracts hold off plan creation during cleanup, even
-- if the war plan quest disappears before the turn-in/Alfred task has ended.
do
    local f = fixture(); local busy = true
    WarPigsPlugin = { status = function() return { enabled = true, busy = busy } end }
    f.tick(); f.tick(10); equal(f.selections, 0)
    busy = false; f.until_state('DONE_WAIT'); equal(f.confirms, 1)
    f = fixture(); local status = { enabled = true, trigger_tasks = true }
    AlfredTheButlerPlugin = { get_status = function() return status end }
    f.tick(); equal(f.selections, 0)
    status.trigger_tasks, status.need_trigger = false, true; f.tick(); equal(f.selections, 0)
    status.need_trigger = false; f.until_state('DONE_WAIT'); equal(f.confirms, 1)
end

-- Cross-suite regression: load the actual WarPigs orchestrator and public
-- external module, so the busy handshake is exercised rather than invented.
for _, transitions in ipairs({ false, true }) do
    local f = fixture()
    local pigs_root = SUITE_ROOT .. '/WarPigs-1.0.0/'
    local pigs_settings = { use_teleport_transition = transitions, run_pit_after_turnin = true,
        get_keybind_state = function() return true end }
    package.loaded['core.settings'] = pigs_settings
    package.loaded.gui = { elements = { main_toggle = { get = function() return true end } } }
    package.loaded['core.tasks.turn_in_rewards'] = dofile(pigs_root .. 'core/tasks/turn_in_rewards.lua')
    local o = dofile(pigs_root .. 'core/orchestrator.lua')
    package.loaded['core.orchestrator'] = o
    WarPigsPlugin = dofile(pigs_root .. 'core/external.lua')
    -- QQT isolates each plugin's require scope; preserve that boundary while
    -- executing the real WarPug external surface in this combined fixture.
    WarPugPlugin = assert(loadfile(root .. 'core/external.lua', 't', setmetatable({
        require = function(name)
            if name == 'core.settings' then return f.settings end
            if name == 'core.planner' then return f.p end
            error('unexpected WarPug dependency: ' .. name)
        end,
    }, { __index = _G })))()
    local filler_enables = 0
    ArkhamAsylumPlugin = { enable = function() filler_enables = filler_enables + 1 end,
        status = function() return { enabled = false } end }
    equal(WarPigsPlugin.status().busy, false, 'real cold idle contract')
    local enabled, done = true, false
    InfernalHordesPlugin = {
        status = function() return { enabled = enabled } end,
        disable = function() enabled = false end,
        chests_done = function() return done end,
    }
    f.quests = { 'WarPlans_QST_InfernalHordes_BSK' }; o.tick()
    equal(WarPigsPlugin.status().busy, true, 'real adopted activity contract')
    f.quests = {}; o.tick(); f.tick()
    f.tick(400); o.tick(); equal(f.selections, 0, 'empty quests do not bypass outgoing cleanup')
    done = true; o.tick(); f.tick(); equal(enabled, false)
    equal(WarPigsPlugin.status().busy, true, 'real handoff cooldown contract')
    equal(f.selections, 0)
    f.now = f.now + 6; o.tick(); equal(WarPigsPlugin.status().busy, false)
    f.until_state('DONE_WAIT'); equal(f.confirms, 1, 'creator resumes only after actual orchestrator release')
    InfernalHordesPlugin = nil
    -- A still-matched internal turn-in remains busy even before the next
    -- orchestrator tick consumes the now-empty host quest snapshot.
    f.quests = { 'WarPlans_QST_TurnIn_Rewards' }; o.tick()
    equal(WarPigsPlugin.status().busy, true)
    f.quests = {}; equal(WarPigsPlugin.status().busy, true)
    o.tick(); equal(WarPigsPlugin.status().busy, false)
    equal(filler_enables, 0, 'enabled creator takes priority over optional Pit filler')
    WarPugPlugin, ArkhamAsylumPlugin = nil, nil
end

-- A filler already owned before the creator is enabled still finishes its
-- ordinary cleanup. Native-transition intent must not then block creation.
do
    local f = fixture(); f.settings.enabled = false
    local pigs_root = SUITE_ROOT .. '/WarPigs-1.0.0/'
    local pigs_settings = { use_teleport_transition = false, run_pit_after_turnin = true,
        get_keybind_state = function() return true end }
    package.loaded['core.settings'] = pigs_settings
    package.loaded.gui = { elements = { main_toggle = { get = function() return true end } } }
    package.loaded['core.tasks.turn_in_rewards'] = dofile(pigs_root .. 'core/tasks/turn_in_rewards.lua')
    local o = dofile(pigs_root .. 'core/orchestrator.lua'); package.loaded['core.orchestrator'] = o
    WarPigsPlugin = dofile(pigs_root .. 'core/external.lua')
    WarPugPlugin = assert(loadfile(root .. 'core/external.lua', 't', setmetatable({
        require = function(name) return name == 'core.settings' and f.settings or f.p end,
    }, { __index = _G })))()
    attributes = { PLAYER_IN_TOWN_LEVEL_AREA = 1 }
    local town, active, disables = false, false, 0
    get_local_player = function() return { is_dead = function() return false end,
        get_attribute = function() return town and 1 or 0 end, get_buffs = function() return {} end } end
    ArkhamAsylumPlugin = { status = function() return { enabled = active } end,
        enable = function() active = true end,
        disable = function() active = false; disables = disables + 1 end }
    f.quests = { 'WarPlans_QST_TurnIn_Rewards' }; o.tick()
    f.quests = {}; o.tick(); equal(active, true, 'disabled creator preserves optional filler')
    -- Turning native transitions on exercises the real outbound disable path.
    pigs_settings.use_teleport_transition, f.settings.enabled = true, true
    o.tick(); f.tick(); equal(disables, 0); equal(f.selections, 0)
    f.now = f.now + 300; o.tick(); f.tick(); equal(disables, 0); equal(f.selections, 0)
    town = true; o.tick(); f.tick(); equal(disables, 1); equal(f.selections, 0)
    f.now = f.now + 6; o.tick(); equal(WarPigsPlugin.status().busy, false)
    f.until_state('DONE_WAIT'); equal(f.confirms, 1)
    WarPugPlugin, ArkhamAsylumPlugin = nil, nil
end

-- Unavailable vendor/panel eventually stops instead of issuing endless moves.
do
    local f = fixture(); f.ready = false; f.tick(); f.tick(181)
    equal(f.p.get_current_state(), 'HALTED'); equal(f.interacts, 0)
end

-- Exercise real GUI persistence/calibration with a virtual file. This catches
-- Windows-only path derivation, CRLF flags and out-of-client input regressions.
local real_io, real_package_path = io, package.path
local function gui_fixture(contents)
    local f = { saved = '', writes = 0, now = 100, x = 200, y = 300 }
    local function element(value)
        return { value = value, state = 0, key = 65,
            get = function(self) return self.value end, set = function(self, v) self.value = v end,
            get_state = function(self) return self.state end, get_key = function(self) return self.key end }
    end
    checkbox = { new = function(_, value) return element(value) end }
    keybind = { new = function() return element(false) end }
    tree_node = { new = function() return {} end }
    get_hash = function(s) return s end
    console = { print = function() end }
    get_screen_width = function() return 1000 end
    get_screen_height = function() return 800 end
    get_time_since_inject = function() return f.now end
    utility = { get_cursor_screen_position = function() return f.x, f.y end }
    package.path = root .. '?.lua;' .. real_package_path
    io = { open = function(path, mode)
        equal(path, root .. 'positions.txt', 'module-relative calibration path')
        if mode == 'r' then
            return { lines = function() return contents:gmatch('[^\n]+') end, close = function() return true end }
        end
        f.saved, f.writes = '', f.writes + 1
        return { write = function(_, chunk) f.saved = f.saved .. chunk; return true end, close = function() return true end }
    end }
    f.gui = dofile(root .. 'gui.lua')
    return f
end
do
    local f = gui_fixture('reroll_rx=0.2\r\nreroll_ry=0.4\r\nreroll_set=true\r\nconfirm_rx=0.8\nconfirm_ry=2\nconfirm_set=true\n')
    equal(f.gui.positions.reroll_set, true); equal(f.gui.positions.confirm_set, false)
    local kb = f.gui.elements.keybind_set_confirm; kb.state = 1
    f.gui.poll_keybinds(); equal(f.writes, 1); equal(f.gui.positions.confirm_rx, 0.2)
    f.x = 600; f.now = 105; f.gui.poll_keybinds(); equal(f.writes, 1, 'held key only captures once')
    kb.state = 0; f.gui.poll_keybinds(); kb.state = 1; f.x = -5; f.gui.poll_keybinds()
    equal(f.writes, 1); equal(f.gui.positions.confirm_rx, 0.2, 'invalid capture preserves previous calibration')
    package.loaded.gui = f.gui; package.loaded['core.settings'] = nil
    local s = dofile(root .. 'core/settings.lua'); s:update_settings(); equal(s.reroll_click_x, 200)
    f.gui.positions.reroll_rx = 0 / 0; s:update_settings(); equal(s.reroll_set, false); equal(s.reroll_click_x, 0)
end
io, package.path = real_io, real_package_path

-- Drive the actual main update callback through a held calibration-test key,
-- live enable transition, death and a late callback; no delayed click survives.
local function main_fixture()
    local f = fixture(); f.settings.enabled = false
    local function element(value) return { value = value, get = function(self) return self.value end } end
    local kb = { state = 0, get_state = function(self) return self.state end, get_key = function() return 65 end }
    local g = { positions = {}, elements = { main_toggle = element(false), keybind_test_clicks = kb,
        show_click_points = element(false) }, poll_keybinds = function() end }
    f.settings.update_settings = function() f.settings.enabled = g.elements.main_toggle:get() end
    package.loaded.gui, package.loaded['core.settings'], package.loaded['core.planner'] = g, f.settings, f.p
    package.loaded['core.external'] = {}
    on_update = function(fn) f.update = fn end
    on_render_menu, on_render = function() end, function() end
    color_green = function() return {} end
    dofile(root .. 'main.lua')
    f.gui, f.kb = g, kb
    function f.pulse(dt) f.now = f.now + (dt or 0.5); f.update() end
    return f
end
do
    local f = main_fixture(); f.kb.state = 1; f.pulse(); equal(#f.clicks, 1)
    f.pulse(2); equal(#f.clicks, 2); f.pulse(3); equal(#f.clicks, 2, 'held test key does not reroll twice')
end
for _, invalidate in ipairs({
    function(f) f.gui.elements.main_toggle.value = true end,
    function(f) f.dead = true end,
    function(f) f.player = false end,
    function(f) f.now = f.now + 10 end,
}) do
    local f = main_fixture(); f.kb.state = 1; f.pulse(); invalidate(f); f.pulse(2)
    equal(#f.clicks, 1)
    if f.gui.elements.main_toggle.value then
        f.pulse(); f.pulse(); equal(f.confirms, 0, 'enabling mid-test must not submit into an open dialog')
    end
end
-- An external status call runs after another plugin has changed the active
-- module resolver. It must retain WarPug's modules and current local state.
do
    local settings = {plugin_version = 'war-pug-test', enabled = true}
    local state, own_context = 'IDLE', true
    local external = assert(loadfile(root .. 'core/external.lua', 't', setmetatable({
        require = function(name)
            assert(own_context, 'external status performed a caller-scoped require')
            if name == 'core.settings' then return settings end
            if name == 'core.planner' then return {get_current_state = function() return state end} end
            error('unexpected dependency: ' .. name)
        end,
    }, {__index = _G})))()
    own_context, settings.enabled, state = false, false, 'DONE_WAIT'
    local status = external.status()
    equal(status.version, 'war-pug-test')
    equal(status.enabled, false, 'captured settings remain live')
    equal(status.state, 'DONE_WAIT', 'captured planner remains live')
end
print('PASS WarPug: real DFS, manual ownership, context/death/loading, bounded rerolls, confirmation outcomes, integration gates, persistence, actual main sequencer and external import isolation')
