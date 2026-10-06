local root = assert(SUITE_ROOT) .. '/WarPug/'
package.path = SUITE_ROOT .. '/WarPigs/?.lua;' .. package.path
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


-- Rosie latched after a failed trip it cannot fix by retrying (stash full /
-- needs left after a complete service): exactly Rosie's get_status shape.
do
    local f = fixture()
    local logs = {}
    console = { print = function(m) logs[#logs + 1] = m end }
    AlfredTheButlerPlugin = { get_status = function() return {
        enabled = true, paused = false, pending = false, running = false, trigger_tasks = false,
        external_trigger = false, stuck = true, stuck_reason = 'stash full', stuck_retry_in = nil,
        inventory_full = true, need_repair = false, need_trigger = false, teleport = false } end }
    WarPigsPlugin = { status = function() return { enabled = true, busy = false, alfred_idle = true } end }
    for _ = 1, 7200 do f.tick() end   -- one hour
    print('state after 1h: ' .. f.p.get_current_state() .. ' selections=' .. f.selections .. ' line=' .. tostring(f.p.get_status_line()))
    for _, m in ipairs(logs) do if m:find('still waiting', 1, true) then print('LOG ' .. m); break end end
    equal(f.selections > 0, true, 'WarPug should plan once WarPigs itself treats the latched Alfred as idle')
end
print('PASS zz_wp warpug stuck')
