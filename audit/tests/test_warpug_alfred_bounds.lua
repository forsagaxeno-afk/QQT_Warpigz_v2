-- WarPug 1.0.16 (QQT_Warpigz_v3): the plan creator's Alfred and third-party
-- holds are bounded (Auditor findings on 1.0.15; each case fails there).
--   P1  a `stuck` Alfred that waits for an explicit retry (Rosie latched:
--       stash full) held planning forever; it is not waited on (C1).
--   P2  hard work (inventory_full) without live work and without WarPigs
--       held planning forever; it holds at most 180 s.
--   P3  a `stuck` Alfred that allows a retry holds at most 150 s.
--   P4  a busy third-party Scavenger / Butler owns town: a new session waits,
--       bounded (180 s), guarded against a throwing addon.
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


local function rosie(fields)
    local s = { enabled = true, paused = false, pending = false, running = false, trigger_tasks = false,
        external_trigger = false, need_trigger = false, teleport = false }
    for k, v in pairs(fields) do s[k] = v end
    AlfredTheButlerPlugin = { get_status = function() return s end }
    return s
end
local function selections_after(f, seconds)
    for _ = 1, math.floor(seconds / 0.5) do f.tick() end
    return f.selections
end

do -- P1
    local f = fixture()
    rosie({ stuck = true, stuck_reason = 'stash full', inventory_full = true })
    equal(selections_after(f, 10) > 0, true, 'P1 a stuck Alfred waiting for an explicit retry is not waited on')
end
do -- P2
    local f = fixture()
    local logs = {}
    console = { print = function(m) logs[#logs + 1] = m end }
    rosie({ inventory_full = true })
    equal(selections_after(f, 150), 0, 'P2 hard work holds a new session first')
    equal(selections_after(f, 60) > 0, true, 'P2 then plans after the 180 s bound')
    local n = 0
    for _, m in ipairs(logs) do if m:find('planning anyway (bounded hold)', 1, true) then n = n + 1 end end
    equal(n, 1, 'P2 expiry logged once')
end
do -- P3
    local f = fixture()
    rosie({ stuck = true, stuck_reason = 'teleport_failed', stuck_retry_in = 400, need_repair = true })
    equal(selections_after(f, 140), 0, 'P3 a stuck Alfred with a retry window holds')
    equal(selections_after(f, 30) > 0, true, 'P3 at most 150 s')
end
do -- P4
    local f = fixture()
    local busy = true
    Scavenger = { is_busy = function() return busy end }
    Butler = { is_busy = function() error('broken addon') end }
    equal(selections_after(f, 20), 0, 'P4 a busy Scavenger holds a new session')
    busy = false
    equal(selections_after(f, 10) > 0, true, 'P4 plans once Scavenger is idle')
    local g = fixture()
    Scavenger = nil
    Butler = { is_busy = function() return true end }
    equal(selections_after(g, 170), 0, 'P4 a Butler town trip holds')
    equal(selections_after(g, 30) > 0, true, 'P4 bounded at 180 s')
    Butler = nil
end
do -- P5 (WarPigs 1.1.13): Rosie's Butler stand-in (_rosie) never holds a new session
    local f = fixture()
    Scavenger = nil
    Butler = { _rosie = true, is_busy = function() return true end }
    equal(selections_after(f, 10) > 0, true, 'P5 a _rosie Butler does not hold planning')
    Butler = nil
end
AlfredTheButlerPlugin, Scavenger, Butler = nil, nil, nil
print('PASS WarPug Alfred / third-party bounds (P1 stuck, P2 hard hold, P3 stuck retry, P4 Scavenger/Butler, P5 Rosie Butler stand-in)')
