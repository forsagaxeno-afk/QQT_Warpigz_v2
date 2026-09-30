-- WarPug 1.0.19 (QQT_Warpigz_v3): "Existing selection preserved; clear it
-- manually before retrying" without any manual selection (owner live report,
-- WarPug 1.0.17: toggling WarPug off and on fixed it at once). Each case fails
-- on 1.0.17.
--   S1  a stale selected_path() read right after the table opens (the
--       previous plan) that clears within 2 s: no halt, plan confirmed.
--   S2  our own path after a pause while the board is slow to report it
--       complete: re-read, then confirmed (a shorter path after a pause stays
--       a user edit and halts, WPG-4).
--   S3  a real foreign selection, stable across the re-reads: halted with a
--       diagnostic line per read, never cleared or confirmed; the halt
--       retries itself after 60 s, bounded.
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
local function logger()
    local logs = {}
    console = { print = function(m) logs[#logs + 1] = m end }
    return logs
end
local function count(logs, text)
    local n = 0
    for _, m in ipairs(logs) do if m:find(text, 1, true) then n = n + 1 end end
    return n
end
local function run(f, seconds, each)
    for _ = 1, math.floor(seconds / 0.5) do f.tick(); if each then each() end end
end

do -- S1 stale read that clears within 2 s
    local f = fixture()
    local logs = logger()
    f.p = dofile(root .. 'core/planner.lua')
    local stale, stale_until = { 2 }, f.now + 2.0
    local path_fn, count_fn = warplan.selected_path, warplan.selected_count
    warplan.selected_path = function() if f.now < stale_until then return { (table.unpack or unpack)(stale) } end return path_fn() end
    warplan.selected_count = function() if f.now < stale_until then return #stale end return count_fn() end
    run(f, 40)
    equal(f.confirms, 1, 'S1 plan confirmed after the stale read cleared')
    equal(count(logs, 'Existing selection preserved'), 0, 'S1 no halt')
    equal(count(logs, 'not ours (read 1/3): [2:Warplans_ThePit]'), 1, 'S1 the stale read is logged')
end

do -- S2 our own path after a pause while the board is slow to report it complete
    local f = fixture()
    local logs = logger()
    f.p = dofile(root .. 'core/planner.lua')
    for _ = 1, 20 do if f.p.get_current_state() == 'CONFIRMING' then break end; f.tick() end
    equal(f.p.get_current_state(), 'CONFIRMING', 'S2 our path found')
    local busy = true
    LooteerPlugin = { get_enabled = function() return true end, is_actively_looting = function() return busy end }
    local desel = f.deselections              -- the DFS backtrack before the pause
    f.tick()                                   -- companion work: the session pauses
    local complete_fn, lag_until = warplan.is_complete, f.now + 6
    warplan.is_complete = function() if f.now < lag_until then return false end return complete_fn() end
    busy = false
    run(f, 40)
    LooteerPlugin = nil
    equal(f.confirms, 1, 'S2 our own path confirmed once the board reports it complete')
    equal(count(logs, 'Existing selection preserved'), 0, 'S2 not treated as manual')
    equal(f.deselections, desel, 'S2 our selection kept')
end

do -- S3 a real foreign selection
    local f = fixture()
    local logs = logger()
    f.p = dofile(root .. 'core/planner.lua')
    f.path = { 3 }                             -- the user selected Helltide by hand
    run(f, 40)
    equal(f.p.get_current_state(), 'HALTED', 'S3 halted')
    equal(count(logs, 'not ours (read'), 3, 'S3 three re-reads, each logged')
    equal(count(logs, 'not ours (read 3/3): [3:Warplans_Helltide], ours: []'), 1, 'S3 diagnostic with ids/names')
    equal(count(logs, 'Existing selection preserved; clear it manually'), 1, 'S3 the halt reason')
    equal(f.deselections, 0, 'S3 never cleared'); equal(f.confirms, 0, 'S3 never confirmed')
    run(f, 70)
    equal(count(logs, 'Retrying after "Existing selection preserved" (1/3)'), 1, 'S3 self-retry after 60 s')
    run(f, 600)
    equal(count(logs, 'Retrying after'), 3, 'S3 bounded retries')
    equal(f.p.get_current_state(), 'HALTED', 'S3 stays halted after the retries')
    equal(f.deselections + f.confirms, 0, 'S3 the user selection is untouched')
end
LooteerPlugin = nil
print('PASS WarPug selection (S1 stale read, S2 own path after a pause, S3 foreign selection: re-read, diagnose, bounded retry)')
