local settings = require 'core.settings'
local planner = {}
-- QQT runs LuaJIT (Lua 5.1 library): table.unpack does not exist there.
local unpack = table.unpack or unpack

-- Existing sampled activity identifier. No Season 15 identifiers are guessed.
local BLOCKED = { ['Warplans_NightmareDungeons'] = true }
local TEMIS_ZONE = 'Skov_Temis'
local INTERACT_DIST, INTERACT_COOLDOWN = 3.0, 1.5
local WAIT_READY_TIMEOUT, SESSION_TIMEOUT = 12.0, 180.0
local REROLL_CLICK1_DELAY, REROLL_CLICK_DEADLINE = 1.5, 4.0
local REROLL_SETTLE_DELAY, DONE_WAIT_TIMEOUT = 4.0, 30.0
local MAX_REROLLS, SEARCH_BUDGET, MAX_PICKS = 10, 512, 64
local CLICK_FADE = 6.0
-- Companion gates: an advisory-only Alfred flag may hold a new session for
-- ADVISORY_HOLD; unreadable Alfred status holds for at most
-- ALFRED_UNREADABLE_LIMIT; a paused session resumes after RESUME_QUIET of
-- clear town; long holds are logged every HOLD_LOG_INTERVAL.
local ADVISORY_HOLD, ALFRED_UNREADABLE_LIMIT = 30.0, 10.0
local RESUME_QUIET, HOLD_LOG_INTERVAL = 3.0, 60.0
local state, state_entered = 'IDLE', -math.huge
local last_interact, last_diag = -math.huge, -math.huge
local session_started, session_world, owned_path
local reroll_count, reroll_pending, pending_click = 0, false, nil
local halt_reason
local recent_clicks = {}
-- session.alfred latches the Alfred API admitted at session start (false when
-- none was loaded). paused_at/paused_from describe a session suspended while a
-- companion owns town. Grouped tables keep tick() far below LuaJIT's limit.
local session = { alfred = nil, paused_at = nil, paused_from = nil }
local hold = { reason = nil, since = nil, logged_at = -math.huge, cleared_at = nil }
local alfred_gate = { advisory_since = nil, advisory_logged = false,
    unreadable_since = nil, unreadable_logged = false }

local function now() return get_time_since_inject() end
local function log(m) console.print('[WarPug] ' .. m) end
local function vlog(m) if settings.verbose_logs then log('debug: ' .. m) end end
local function set_state(s)
    if s ~= state then
        log('state ' .. state .. ' -> ' .. s)
        state, state_entered = s, now()
    end
end
local function halt(reason)
    halt_reason, pending_click, reroll_pending = reason, nil, false
    session.paused_at, session.paused_from = nil, nil
    log(reason .. ' — disable and re-enable WarPug to retry')
    set_state('HALTED')
end
local function reset()
    owned_path, session_started, session_world = nil, nil, nil
    reroll_count, reroll_pending, pending_click, halt_reason = 0, false, nil, nil
    session.alfred, session.paused_at, session.paused_from = nil, nil, nil
    hold.reason, hold.since, hold.cleared_at = nil, nil, nil
    alfred_gate.advisory_since = nil
    set_state('IDLE')
end

local function warplan_api_ready()
    if not warplan or type(warplan.is_ready) ~= 'function' then return false end
    local ok, ready = pcall(warplan.is_ready)
    return ok and ready == true
end

-- Unknown snapshots must never be mistaken for an empty quest log.
local function has_warplan_quests()
    local ok, quests = pcall(get_quests)
    if not ok or type(quests) ~= 'table' then return nil end
    local unknown = false
    for _, quest in pairs(quests) do
        local valid, name = pcall(function() return quest:get_name() end)
        if not valid or type(name) ~= 'string' or name == '' then unknown = true
        elseif name:find('WarPlans_QST', 1, true) then return true end
    end
    if unknown then return nil end
    return false
end

local function world_key()
    local ok, key = pcall(function()
        local world = get_current_world()
        if not world or world:get_current_zone_name() ~= TEMIS_ZONE then return nil end
        -- World IDs distinguish loading into a different instance of the same zone.
        local id, name = world:get_world_id(), world:get_name()
        if type(id) ~= 'number' or id ~= id or id == math.huge or id == -math.huge
            or type(name) ~= 'string' or name == '' or name == 'Limbo' then return nil end
        return tostring(id) .. ':' .. name
    end)
    return ok and key or nil
end

local function read_status(plugin, method)
    if type(plugin) ~= 'table' or type(plugin[method]) ~= 'function' then return nil end
    local ok, status = pcall(plugin[method])
    if ok and type(status) == 'table' then return status end
end

local function looter_busy()
    local looter = LooteerPlugin
    if not looter then return false end
    local function read(method, ...)
        if type(looter[method]) ~= 'function' then return false, nil end
        return pcall(looter[method], ...)
    end
    local enabled_ok, enabled = read('get_enabled')
    if type(looter.get_enabled) == 'function'
        and (not enabled_ok or type(enabled) ~= 'boolean') then return true end
    if enabled_ok and enabled == false then return false end
    local active_ok, active = read('is_actively_looting')
    if active_ok and type(active) == 'boolean' then return active end
    local idle_ok, idle = read('is_idle')
    if idle_ok and type(idle) == 'boolean' then return not idle end
    if type(looter.is_actively_looting) == 'function' or type(looter.is_idle) == 'function' then
        return true -- unreadable modern ownership cannot be replaced by legacy nil
    end
    local legacy_enabled_ok, legacy_enabled = read('getSettings', 'enabled')
    local legacy_active_ok, legacy_active = read('getSettings', 'looting')
    -- This legacy getter returns nil for stored false. A successful nil is
    -- distinct from a missing/throwing getter; modern exports take precedence.
    if legacy_enabled_ok and (legacy_enabled == false or legacy_enabled == nil)
        and enabled ~= true then return false end
    if legacy_active_ok and (type(legacy_active) == 'boolean' or legacy_active == nil) then
        return legacy_active == true
    end
    return true -- a loaded but unreadable collector may still own movement
end

-- Suite-wide Alfred "live work" reading. A teleport flag left latched after a
-- finished or failed trip is not live work.
local function alfred_live_work(s)
    return s.trigger_tasks == true or s.external_trigger == true or s.pending == true or s.running == true
        or (s.teleport == true and s.teleport_done ~= true and s.teleport_failed ~= true)
end

-- Returns a hold reason while Alfred owns town, or nil. need_trigger alone is
-- advisory (e.g. a restock the stash cannot fill): it holds only a NEW session,
-- and only until WarPigs reports its completed-cycle grace or ADVISORY_HOLD
-- passes without live work. An admitted session latches its Alfred API, so an
-- expiring grace can never stop it; live work, full inventory or repair can.
local function alfred_hold(alfred, dispatcher)
    local t = now()
    local status = read_status(alfred, 'get_status')
    if not status or type(status.enabled) ~= 'boolean' then
        alfred_gate.unreadable_since = alfred_gate.unreadable_since or t
        if t - alfred_gate.unreadable_since < ALFRED_UNREADABLE_LIMIT then return 'Alfred status unreadable' end
        if not alfred_gate.unreadable_logged then
            alfred_gate.unreadable_logged = true
            log(string.format('Alfred status unreadable for %.0fs; treating Alfred as unavailable',
                ALFRED_UNREADABLE_LIMIT))
        end
        return nil
    end
    alfred_gate.unreadable_since, alfred_gate.unreadable_logged = nil, false
    local live = alfred_live_work(status)
    local hard = status.inventory_full == true or status.need_repair == true
    -- The advisory timer runs only while need_trigger alone is what holds us.
    -- A pause WarPug does not own, with no hard need or live work, is idle.
    if status.enabled == false or live or hard or status.need_trigger ~= true or status.paused == true
        or (session.alfred ~= nil and session.alfred == alfred)
        or (dispatcher and dispatcher.enabled == true and dispatcher.alfred_idle == true) then
        alfred_gate.advisory_since, alfred_gate.advisory_logged = nil, false
        if status.enabled == false then return nil end
        if live then return 'Alfred working' end
        if hard then return 'Alfred inventory/repair work' end
        return nil
    end
    alfred_gate.advisory_since = alfred_gate.advisory_since or t
    if t - alfred_gate.advisory_since < ADVISORY_HOLD then return 'Alfred need_trigger' end
    if not alfred_gate.advisory_logged then
        alfred_gate.advisory_logged = true
        log(string.format('Alfred need_trigger stayed advisory for %.0fs without live work; planning anyway',
            ADVISORY_HOLD))
    end
    return nil
end

-- Returns the companion that currently owns town, or nil.
local function integrations_busy()
    local dispatcher, dispatcher_reason
    if WarPigsPlugin then
        dispatcher = read_status(WarPigsPlugin, 'status')
        if not dispatcher then dispatcher_reason = 'WarPigs status unavailable'
        elseif dispatcher.busy == true then dispatcher_reason = 'WarPigs busy' end
    end
    -- Always read Alfred so its advisory/unreadable timers see every tick.
    local alfred = AlfredTheButlerPlugin or PLUGIN_alfred_the_butler
    if not alfred then alfred_gate.unreadable_since, alfred_gate.advisory_since = nil, nil end
    local alfred_reason = alfred and alfred_hold(alfred, dispatcher) or nil
    if dispatcher_reason or alfred_reason then return dispatcher_reason or alfred_reason end
    -- These direct guards also apply when the master dispatcher is disabled.
    local raven = SilentRavenPlugin or PLUGIN_silent_raven
    if raven then
        local status = read_status(raven, 'get_status')
        if not status then return 'SilentRaven status unavailable' end
        if status.running or status.pending or status.external_trigger then return 'SilentRaven busy' end
    end
    if looter_busy() then return 'Looter busy' end
    return nil
end

-- Third result true: only a companion owns town, so a session may pause.
local function context()
    local ok, alive = pcall(function()
        local player = get_local_player()
        return player ~= nil and player:is_dead() == false
    end)
    if not ok or not alive then return nil, 'player unavailable or dead' end
    local key = world_key()
    if not key then return nil, 'outside Temis or world unavailable' end
    local quests = has_warplan_quests()
    if quests ~= false then return nil, quests and 'war plan quest active' or 'quest snapshot unavailable' end
    local busy = integrations_busy()
    if busy then return nil, busy, true end
    return key
end

-- Rate-limited visibility for companion holds (status line + periodic log).
local function note_hold(reason)
    local t = now()
    if not reason then
        if hold.since then hold.since, hold.cleared_at = nil, t end
        hold.reason = nil
        return
    end
    if not hold.since then hold.since, hold.logged_at, hold.cleared_at = t, t, nil end
    hold.reason = reason
    if t - hold.logged_at >= HOLD_LOG_INTERVAL then
        hold.logged_at = t
        log(string.format('still waiting for town work after %.0fs: %s', t - hold.since, reason))
    end
end

local function same_path(a, b)
    if not a or not b or #a ~= #b then return false end
    for i, id in ipairs(a) do if b[i] ~= id then return false end end
    return true
end
local function selected_path()
    local path, count = warplan.selected_path(), warplan.selected_count()
    assert(type(path) == 'table' and type(count) == 'number' and count == #path,
        'inconsistent selected path')
    local copy = {}
    for i, id in ipairs(path) do
        assert(type(id) == 'number', 'invalid node ID')
        copy[i] = id
    end
    return copy
end
local function owns_current_path()
    local ok, path = pcall(selected_path)
    return ok and owned_path ~= nil and same_path(path, owned_path)
end

-- Only undo the exact path this instance selected, in the same live world.
-- Manual selections, edits, accepted plans and loading-state data are preserved.
local function clear_owned_path()
    if not owned_path or not warplan_api_ready() or context() ~= session_world then return end
    while #owned_path > 0 and owns_current_path() do
        local before = #owned_path
        local ok, accepted = pcall(warplan.deselect_last)
        if not ok or accepted ~= true then break end
        local valid, path = pcall(selected_path)
        if not valid or #path ~= before - 1 then break end
        local expected = { unpack(owned_path, 1, before - 1) }
        if not same_path(path, expected) then break end
        owned_path = path
    end
end

local function find_table_actor()
    if not settings.table_actor_name or settings.table_actor_name == '' then return nil end
    local ok, actors = pcall(function() return actors_manager.get_all_actors() end)
    if not ok or type(actors) ~= 'table' then return nil end
    for _, actor in pairs(actors) do
        local valid, name = pcall(function() return actor:get_skin_name() end)
        if valid and name == settings.table_actor_name then return actor end
    end
end

-- Every accepted selection must append exactly one node. Bounded traversal
-- prevents broken host results or exceptionally large trees from hanging a tick.
local function find_path(required)
    local budget = SEARCH_BUDGET
    local function dfs()
        budget = budget - 1
        assert(budget >= 0, 'path search budget exceeded')
        assert(owns_current_path(), 'selection changed during search')
        local depth = #owned_path
        if depth == required then return warplan.is_complete() == true end
        local legal = warplan.get_selectable_now()
        assert(type(legal) == 'table', 'selectable nodes unavailable')
        for _, id in ipairs(legal) do
            budget = budget - 1
            assert(budget >= 0, 'path search budget exceeded')
            local name = warplan.node_name(id)
            assert(type(name) == 'string' and name ~= '', 'activity name unavailable')
            if not BLOCKED[name] then
                local before = { unpack(owned_path) }
                vlog('Trying node ' .. tostring(id) .. ': ' .. name)
                local accepted = warplan.select_node(id)
                local current = selected_path()
                if accepted == true then
                    local expected = { unpack(before) }
                    expected[#expected + 1] = id
                    assert(same_path(current, expected), 'select_node made inconsistent progress')
                    owned_path = current
                    if dfs() then return true end
                    assert(owns_current_path(), 'selection changed before backtracking')
                    assert(warplan.deselect_last() == true, 'backtracking refused')
                    assert(same_path(selected_path(), before), 'backtracking made inconsistent progress')
                    owned_path = before
                    vlog('Backtracked node ' .. tostring(id))
                else
                    assert(same_path(current, before), 'rejected selection changed the path')
                end
            end
        end
        return false
    end
    return dfs()
end

local function valid_coordinates(x, y)
    local sw, sh = get_screen_width(), get_screen_height()
    return type(x) == 'number' and type(y) == 'number' and x == x and y == y and
        sw > 0 and sh > 0 and x >= 0 and y >= 1 and x < sw and y < sh
end
local function do_click(x, y, label)
    if not valid_coordinates(x, y) or not utility or type(utility.send_mouse_click) ~= 'function' then
        log(label .. ': valid captured client coordinates and native click API required')
        return false
    end
    local ok, err = pcall(function()
        -- QQT documents both calls in game-window client coordinates.
        if type(utility.send_mouse_move) == 'function' then utility.send_mouse_move(x, y) end
        utility.send_mouse_click(x, y)
    end)
    if not ok then log(label .. ': native click failed: ' .. tostring(err)); return false end
    recent_clicks[#recent_clicks + 1] = { label = label, x = x, y = y, t = now() }
    while #recent_clicks > 8 do table.remove(recent_clicks, 1) end
    log(string.format('%s: CLICKED (%d, %d)', label, x, y))
    return true
end
local function calibrated()
    return settings.reroll_set and settings.confirm_set and
        valid_coordinates(settings.reroll_click_x, settings.reroll_click_y) and
        valid_coordinates(settings.reroll_confirm_x, settings.reroll_confirm_y)
end

-- A companion (Alfred, Looter, SilentRaven, WarPigs) took over town mid-session.
-- Never move or click against it: drop any delayed click and report IDLE so
-- every companion treats WarPug as idle. The owned selection, reroll budget
-- and Alfred admission are kept; the session resumes with a fresh search.
local function pause_session(reason)
    session.paused_at, session.paused_from = now(), state
    pending_click, reroll_pending = nil, false
    log('Pausing ' .. state .. ' for town work (' .. reason .. '); planning resumes when it clears')
    set_state('IDLE')
end
local function resume_session(key)
    if hold.cleared_at and now() - hold.cleared_at < RESUME_QUIET then return end
    local paused, from = now() - session.paused_at, session.paused_from
    session.paused_at, session.paused_from = nil, nil
    if key ~= session_world then
        -- A selection from another instance cannot be verified or undone here.
        if owned_path and #owned_path > 0 then halt('World changed during planning') else reset() end
        return
    end
    -- Time spent yielding is not planning time.
    session_started = session_started + paused
    log(string.format('Resuming after %.0fs of town work (paused in %s)', paused, tostring(from)))
    set_state(warplan_api_ready() and 'FIND_PATH' or 'APPROACH_TABLE')
end

function planner.tick()
    if not settings.enabled then
        if state ~= 'DONE_WAIT' then clear_owned_path() end
        reset()
        return
    end
    local key, reason, companion = context()
    note_hold(companion and reason or nil)
    if not key then
        -- An accepted plan appearing is normal completion. Never deselect it.
        if has_warplan_quests() == true then reset(); return end
        -- Companion work is transient: pause instead of a permanent stop.
        if companion then
            if state ~= 'IDLE' and state ~= 'HALTED' and state ~= 'DONE_WAIT' then pause_session(reason) end
            return
        end
        if state ~= 'IDLE' and state ~= 'HALTED' then
            halt('Stopped: ' .. reason)
        end
        return
    end
    if state == 'HALTED' then return end
    if session.paused_at then resume_session(key); return end
    if session_world and key ~= session_world then halt('World changed during planning'); return end
    if state ~= 'IDLE' and state ~= 'DONE_WAIT' and now() - session_started >= SESSION_TIMEOUT then
        halt('Planning session timed out'); return
    end

    if state == 'IDLE' then
        session_world, session_started = key, now()
        -- Latch Alfred admission for this session (see alfred_hold).
        session.alfred = AlfredTheButlerPlugin or PLUGIN_alfred_the_butler or false
        set_state(warplan_api_ready() and 'FIND_PATH' or 'APPROACH_TABLE')
        return
    end
    if state == 'APPROACH_TABLE' or state == 'INTERACT_TABLE' then
        local actor = find_table_actor()
        if not actor then
            if now() - last_diag >= 5 then log('Waiting for war plan table actor'); last_diag = now() end
            return
        end
        local ok, distance, pos = pcall(function()
            local target, player = actor:get_position(), get_player_position()
            return player:dist_to(target), target
        end)
        if not ok then return end
        if distance > INTERACT_DIST then
            set_state('APPROACH_TABLE')
            pathfinder.request_move(pos)
        elseif state == 'APPROACH_TABLE' then
            set_state('INTERACT_TABLE')
        elseif now() - last_interact >= INTERACT_COOLDOWN then
            local interacted, err = pcall(interact_vendor, actor)
            if not interacted then halt('Vendor interaction failed: ' .. tostring(err)); return end
            last_interact = now()
            set_state('WAIT_READY')
        end
        return
    end
    if state == 'WAIT_READY' then
        if warplan_api_ready() then
            set_state(reroll_pending and 'REROLL_CLICK1' or 'FIND_PATH')
        elseif now() - state_entered >= WAIT_READY_TIMEOUT then
            set_state('APPROACH_TABLE')
        end
        return
    end
    if state == 'FIND_PATH' then
        if not warplan_api_ready() then set_state('APPROACH_TABLE'); return end
        local ok, found = pcall(function()
            local path = selected_path()
            -- A user's existing path must never be cleared or auto-confirmed.
            -- Only this session's own complete selection, kept while paused
            -- for town work, continues to the full CONFIRMING validation.
            if #path > 0 then
                if owned_path and #owned_path > 0 and same_path(path, owned_path)
                    and warplan.is_complete() == true then return true end
                return 'manual'
            end
            owned_path = path
            local required = warplan.required_picks()
            assert(type(required) == 'number' and required > 0 and required <= MAX_PICKS and
                required % 1 == 0, 'required picks unavailable or invalid')
            return find_path(required)
        end)
        if not ok then halt('Path search stopped: ' .. tostring(found)); return end
        if found == 'manual' then halt('Existing selection preserved; clear it manually before retrying'); return end
        if found then
            reroll_pending = false
            set_state('CONFIRMING')
        elseif reroll_count >= MAX_REROLLS then
            halt('Maximum rerolls reached; check the saved positions')
        elseif not calibrated() then
            halt('Capture valid Reroll and Confirm positions before rerolling')
        else
            reroll_pending = true
            set_state('APPROACH_TABLE')
        end
        return
    end
    if state == 'CONFIRMING' then
        if not warplan_api_ready() then halt('War plan data lost before confirmation'); return end
        local ok, valid = pcall(function()
            if not owns_current_path() or #owned_path == 0 or #owned_path ~= warplan.required_picks() or
                warplan.is_complete() ~= true then return false end
            local names = {}
            for i, id in ipairs(owned_path) do
                local name = warplan.node_name(id)
                if type(name) ~= 'string' or name == '' or BLOCKED[name] then return false end
                names[i] = name
            end
            return names
        end)
        if not ok or not valid then halt('Selection changed or became invalid before confirmation'); return end
        -- WarPug excludes only Nightmare Dungeons. Name every node so a plan
        -- step WarPigs cannot map is visible in the log.
        log('Submitting war plan path: ' .. table.concat(valid, ' -> ') ..
            ' (only Nightmare Dungeons are excluded; WarPigs runs the activities it maps)')
        -- confirm() has no documented return value; a successful call is a
        -- submission, not proof of server acceptance. Never resend on a timer.
        local sent, err = pcall(warplan.confirm)
        owned_path, pending_click = nil, nil
        if not sent then halt('Confirmation outcome unknown: ' .. tostring(err)); return end
        log('War plan submitted; waiting for quests')
        reroll_pending = false
        set_state('DONE_WAIT')
        return
    end
    if state == 'DONE_WAIT' then
        if now() - state_entered >= DONE_WAIT_TIMEOUT then
            halt('No war plan quests observed after confirmation; submission will not be repeated')
        end
        return
    end
    if state == 'REROLL_CLICK1' then
        if not warplan_api_ready() or not calibrated() or not owns_current_path() or #owned_path ~= 0 then
            halt('Reroll context or calibration changed'); return
        end
        if now() - last_interact > WAIT_READY_TIMEOUT then halt('Reroll vendor interaction expired'); return end
        if not do_click(settings.reroll_click_x, settings.reroll_click_y, 'Reroll') then
            halt('Reroll click failed'); return
        end
        reroll_count = reroll_count + 1
        pending_click = { t = now(), x = settings.reroll_confirm_x, y = settings.reroll_confirm_y,
            width = get_screen_width(), height = get_screen_height() }
        set_state('REROLL_WAIT1')
        return
    end
    if state == 'REROLL_WAIT1' then
        if now() - state_entered >= REROLL_CLICK1_DELAY then set_state('REROLL_CLICK2') end
        return
    end
    if state == 'REROLL_CLICK2' then
        local p = pending_click
        if not p or now() - p.t > REROLL_CLICK_DEADLINE or not warplan_api_ready() or
            not calibrated() or not owns_current_path() or #owned_path ~= 0 or
            p.width ~= get_screen_width() or p.height ~= get_screen_height() or
            p.x ~= settings.reroll_confirm_x or p.y ~= settings.reroll_confirm_y then
            halt('Reroll confirmation expired or context changed'); return
        end
        if not do_click(p.x, p.y, 'RerollConfirm') then halt('Reroll confirmation click failed'); return end
        pending_click = nil
        set_state('REROLL_WAIT2')
        return
    end
    if state == 'REROLL_WAIT2' and now() - state_entered >= REROLL_SETTLE_DELAY then
        reroll_pending = false
        set_state(warplan_api_ready() and 'FIND_PATH' or 'APPROACH_TABLE')
    end
end

function planner.get_recent_clicks()
    while recent_clicks[1] and now() - recent_clicks[1].t > CLICK_FADE do table.remove(recent_clicks, 1) end
    return recent_clicks, CLICK_FADE
end
function planner.get_current_state() return state end
function planner.stop(reason) halt(reason or 'Stopped by caller') end
function planner.get_status_line()
    if not settings.enabled then return nil end
    if halt_reason then return 'WarPug: ' .. halt_reason end
    if hold.since then
        return string.format('WarPug: %s for %s (%.0fs)', session.paused_at and 'paused' or 'waiting',
            tostring(hold.reason), now() - hold.since)
    end
    if session.paused_at then return 'WarPug: resuming after town work' end
    return string.format('WarPug: %s (reroll %d/%d)', state, reroll_count, MAX_REROLLS)
end
-- Manual calibration uses the same native path and safety context. No OS input.
function planner.click_context()
    local key = context()
    if not key or not warplan_api_ready() then return nil end
    local ok, path = pcall(selected_path)
    return ok and #path == 0 and key or nil
end
function planner.fire_click(x, y, label)
    if not planner.click_context() then return false end
    return do_click(x, y, label)
end
return planner
