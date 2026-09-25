local plugin_label = 'arkham_asylum' -- change to your plugin name

local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'

local status_enum = {
    IDLE = 'idle',
    WAITING = 'waiting for alfred to complete',
    LOOTING = 'looting stuff on floor'
}
local task = {
    name = 'alfred_running', -- change to your choice of task name
    status = status_enum['IDLE'],
    -- Why the task is holding (shown next to the status; nil = no hold).
    note = nil,
    loot_start = get_time_since_inject(),
    loot_timeout = 3,
    debounce_time = -1,
    debounce_timeout = 3
}

local function get_alfred()
    return AlfredTheButlerPlugin or PLUGIN_alfred_the_butler
end

local floor_has_loot = function ()
    local ok, present = pcall(function()
        return loot_manager.any_item_around(get_player_position(), 30, true, true)
    end)
    return not ok or present == true -- unreadable floor still gets a brief loot window
end

local teleport_with_debounce = function ()
    if task.debounce_time + task.debounce_timeout > get_time_since_inject() then return end
    task.debounce_time = get_time_since_inject()
    pcall(teleport_to_waypoint, settings.town_waypoint)
    return true -- a thrown binding may already have submitted the channel
end

-- Tracks last cycle completion for restock-stickiness escape. See
-- HelltideRevamped/tasks/alfred.lua for the full rationale.
-- ARK-1: a task switch (on_cancel) never erases it; the grace expires by itself.
local last_completion_at = nil
local STUCK_NEED_TRIGGER_GRACE = 30.0

local generation = 0
local request_plugin, request_started, quiet_since
local manual_teleport, manual_attempts = false, 0
local retry_after = -math.huge
local RETRY_DELAY, PICKUP_WINDOW, QUIET_WINDOW = 5, 8, 2
-- Bounded holds (C6). A paused Alfred with hard work cannot self-start;
-- after PAUSED_HOLD_MAX we continue without it. Looter yield before a new
-- trip (ARK-4) and the pending-glyph deferral are bounded the same way.
local PAUSED_HOLD_MAX, LOOTER_HOLD_MAX, GLYPH_DEFER_MAX = 60, 20, 120
-- A with-teleport trip's callback may land before the return portal; the
-- trip still counts as ours until back in the pit (bounded, C2 alfred_trip).
local RETURN_WINDOW = 30
local HOLD_LOG_AFTER = 60
local trip = {teleport = false, return_until = nil, live_seen = false,
    paused_since = nil, paused_logged = false, glyph_since = nil,
    hold = nil, hold_since = nil, hold_logged = -math.huge, return_logged = false, advisory_logged = -math.huge}

-- C1 canonical live-work predicate (a latched teleport after a finished or
-- failed trip is not live work).
local function live_work(s)
    return s.trigger_tasks == true or s.external_trigger == true or s.pending == true or s.running == true
        or (s.teleport == true and s.teleport_done ~= true and s.teleport_failed ~= true)
end
-- Hard need leaves a pit; advisory flags (restock/stash) never do. A legacy
-- provider that exposes only need_trigger keeps it as its only signal.
local function hard_need(s)
    if s.inventory_full == true or s.need_repair == true then return true end
    return s.need_trigger == true and s.inventory_full == nil and s.need_repair == nil
end
local function in_pit()
    return type(utils.player_in_pit) == 'function' and utils.player_in_pit() or false
end
-- Suite policy (round 5): while WarPigs is loaded and its status() reports
-- enabled == true, WarPigs services advisory-only flags (need_trigger without
-- inventory_full/need_repair: restock/stash extras) once per Temis visit, and
-- Arkham never starts an Alfred trip for them, whatever alfred_idle says.
-- Waiting only for alfred_idle (its 20 s grace) still cost one extra trip at
-- every activity start with a sticky flag. Hard needs are unchanged. WarPigs
-- absent, disabled, without status(), throwing or returning a non-table:
-- standalone rules.
local function warpigs_advisory_idle()
    local wp = WarPigsPlugin
    if type(wp) ~= 'table' or type(wp.status) ~= 'function' then return false end
    local ok, st = pcall(wp.status)
    return ok and type(st) == 'table' and st.enabled == true
end
-- Status text + one rate-limited log line for any hold longer than a minute.
local function note_hold(reason)
    local now = get_time_since_inject()
    if reason ~= trip.hold then trip.hold, trip.hold_since = reason, now end
    task.note = reason
    if reason and now - trip.hold_since >= HOLD_LOG_AFTER and now - trip.hold_logged >= HOLD_LOG_AFTER then
        trip.hold_logged = now
        console.print(string.format('[alfred] holding for %.0fs: %s', now - trip.hold_since, reason))
    end
end
-- A paused Alfred with hard work: hold (true) up to PAUSED_HOLD_MAX.
local function paused_hold(status)
    if not (status.paused and hard_need(status)) then
        trip.paused_since, trip.paused_logged = nil, false
        return false
    end
    local now = get_time_since_inject()
    trip.paused_since = trip.paused_since or now
    if now - trip.paused_since < PAUSED_HOLD_MAX then return true end
    if not trip.paused_logged then
        trip.paused_logged = true
        console.print(string.format('[alfred] Alfred paused with inventory/repair work for %.0fs — continuing without it',
            now - trip.paused_since))
    end
    return false
end
-- Any observed live -> idle edge is a finished cycle (ours or a foreign
-- caller's): advisory flags get the same sticky grace either way.
local function observe_cycle(status)
    if status.enabled and live_work(status) then
        trip.live_seen = true
    elseif trip.live_seen then
        trip.live_seen = false
        last_completion_at = get_time_since_inject()
    end
end
-- C1: an unreadable status (throws, non-table, non-boolean enabled) holds
-- like busy for at most UNKNOWN_HOLD seconds, then Alfred counts as
-- unavailable (not busy) with one log line until it reads again.
local UNKNOWN_HOLD = 10
local UNAVAILABLE = {enabled = false, unavailable = true}
local unknown = {since = nil, logged = false}
local function get_alfred_status()
    local a = get_alfred()
    if not a then unknown.since = nil; return {enabled = false} end
    local status
    if type(a.get_status) == 'function' then
        local ok, s = pcall(a.get_status)
        if ok and type(s) == 'table' and type(s.enabled) == 'boolean' then status = s end
    end
    if status then
        if unknown.logged then console.print('[alfred] Alfred status readable again') end
        unknown.since, unknown.logged = nil, false
        observe_cycle(status)
        return status
    end
    local now = get_time_since_inject()
    unknown.since = unknown.since or now
    if now - unknown.since < UNKNOWN_HOLD then return nil end
    if not unknown.logged then
        unknown.logged = true
        console.print(string.format('[alfred] Alfred status unreadable for %.0fs — treating Alfred as unavailable',
            now - unknown.since))
    end
    return UNAVAILABLE
end

local function clear_request()
    request_plugin, request_started, quiet_since = nil, nil, nil
    manual_teleport, manual_attempts = false, 0
end
local function retire_request()
    generation = generation + 1
    clear_request()
    task.status = status_enum.IDLE
    retry_after = get_time_since_inject() + RETRY_DELAY
    -- A lost callback most likely means a finished cycle: same grace.
    last_completion_at = get_time_since_inject()
end
local function waiting_for_request(status)
    if task.status ~= status_enum.WAITING then return false end
    if get_alfred() ~= request_plugin then retire_request(); return true end
    -- C1: a paused Alfred without hard work is idle for us (we never own
    -- its pause); with hard work it holds, bounded by paused_hold().
    if not status or live_work(status) or paused_hold(status) then
        quiet_since = nil
        return true
    end
    -- Legacy trigger calls return nil and do not expose their queued flag.
    -- Allow pickup first, then require stable idle before retiring a lost callback.
    local now = get_time_since_inject()
    if now - (request_started or now) < PICKUP_WINDOW then return true end
    quiet_since = quiet_since or now
    if now - quiet_since >= QUIET_WINDOW then retire_request() end
    return true
end
-- The plain-trigger branch owns a town hop only after the call returned
-- acceptance. Never retry a with-teleport or uncertain/foreign request.
local function retry_manual_teleport(status)
    if not manual_teleport or task.status ~= status_enum.WAITING
        or get_alfred() ~= request_plugin or not status or status.paused or live_work(status) then return end
    local caller = status.external_caller or status.owner
    if caller and caller ~= '' and caller ~= plugin_label then manual_teleport = false; return end
    local ok, ready = pcall(function()
        local world = get_current_world()
        if not world then return false end
        local zone, name = world:get_current_zone_name(), world:get_name()
        return type(zone) == 'string' and zone ~= '' and zone ~= '[sno none]'
            and type(name) == 'string' and name ~= '' and name ~= 'Limbo'
            and not name:lower():find('loading', 1, true)
    end)
    if not ok or not ready then return end
    if utils.player_in_zone(settings.town_zone) then manual_teleport = false; return end
    if manual_attempts >= 3 then return end
    if teleport_with_debounce() then
        manual_attempts = manual_attempts + 1
        quiet_since = nil
    end
end
local reset = function ()
    -- Completing our request only changes our state. Pausing Alfred here
    -- can stop its service/status loop or a newly started foreign cycle.
    if floor_has_loot() then
        task.loot_start = get_time_since_inject()
        task.status = status_enum['LOOTING']
    else
        task.status = status_enum['IDLE']
    end
    trip.return_until = trip.teleport and not in_pit() and get_time_since_inject() + RETURN_WINDOW or nil
    trip.return_logged = false
    trip.teleport = false
    clear_request()
    retry_after = -math.huge
    last_completion_at = get_time_since_inject()
end

local function trigger_alfred(use_teleport)
    local a = get_alfred()
    local method = a and (use_teleport and a.trigger_tasks_with_teleport or a.trigger_tasks)
    if type(method) ~= 'function' then
        retry_after = get_time_since_inject() + RETRY_DELAY
        return false
    end
    generation = generation + 1
    local token = generation
    task.status = status_enum.WAITING
    trip.teleport, trip.return_until = use_teleport == true, nil
    request_plugin, request_started, quiet_since = a, get_time_since_inject(), nil
    local ok, accepted = pcall(method, plugin_label, function ()
        if token == generation and task.status == status_enum.WAITING and get_alfred() == a then reset() end
    end)
    if ok and accepted == false then
        if token == generation and task.status == status_enum.WAITING then retire_request() end
        return false
    end
    -- A throwing call may already have queued work. Reserve this generation
    -- until callback or stable readable idle reconciles the uncertain result.
    if not ok then return false end
    return true -- legacy nil is an accepted request, not a rejection
end

-- ARK-4: the Awakened Glyphstone is used before any town trip (a trip from
-- here loses the upgrade). Bounded so an unreachable gizmo cannot pin a full
-- inventory forever; the reset timeout still wins over everything.
local function glyph_pending()
    if not settings.upgrade_toggle or tracker.glyph_done or not in_pit()
        or type(utils.get_glyph_upgrade_gizmo) ~= 'function' or utils.get_glyph_upgrade_gizmo() == nil
    then
        trip.glyph_since = nil
        return false
    end
    local now = get_time_since_inject()
    if trip.glyph_since == nil then
        trip.glyph_since = now
        console.print('[alfred] Alfred trip deferred until the glyph upgrade is done')
    end
    return now - trip.glyph_since < GLYPH_DEFER_MAX
end

-- Should a NEW request start now (no own request, no live work)?
local function wants_new_request(status)
    if status.need_trigger ~= true then return false end
    if not hard_need(status) then
        -- need_trigger covers restock/stash extras too (Steroid). Those are
        -- advisory: never leave a pit for them, and not again within the
        -- grace after a completed cycle (sticky restock_count; mirrors the
        -- WarPigs orchestrator's alfred_idle escape). Paused = idle (C1).
        if in_pit() or status.paused then return false end
        local now = get_time_since_inject()
        if last_completion_at and (now - last_completion_at) < STUCK_NEED_TRIGGER_GRACE then
            return false -- stuck need_trigger — skip
        end
        if not warpigs_advisory_idle() then return true end
        -- Not a hold (the route continues); one line per minute at most.
        if now - trip.advisory_logged >= HOLD_LOG_AFTER then
            trip.advisory_logged = now
            console.print('[alfred] advisory Alfred restock skipped: WarPigs is enabled and services it in Temis')
        end
        return false
    end
    if status.paused then return paused_hold(status) end
    if glyph_pending() then return false end
    -- ARK-4: yield to Looter like upgrade_glyph does, bounded.
    if type(utils.looter_hold) == 'function' and utils.looter_hold(LOOTER_HOLD_MAX, 'Alfred trip') then
        return false
    end
    return true
end

-- R10/ARK-3: a with-teleport callback that lands in town comes before
-- Alfred's return portal. Until the player is back in the pit (at most
-- RETURN_WINDOW), no town task may walk to the obelisk, open a new pit,
-- teleport away (cancelling the return) or reset Batmobile (dropping the
-- pit map it keeps for the return). Visible and bounded (C6); a failed or
-- disabled Alfred return ends it at once.
local function awaiting_return(status)
    if trip.return_until == nil or in_pit() then return false end
    local now = get_time_since_inject()
    if status.teleport_failed == true or now >= trip.return_until then
        console.print(status.teleport_failed == true
            and "[alfred] Alfred's return to the pit failed — continuing in town"
            or string.format('[alfred] Alfred did not return to the pit within %ds — continuing in town', RETURN_WINDOW))
        trip.return_until = nil
        return false
    end
    if not trip.return_logged then
        trip.return_logged = true
        console.print(string.format("[alfred] Alfred cycle done in town — holding up to %.0fs for its return portal to the pit",
            trip.return_until - now))
    end
    return true
end

task.shouldExecute = function ()
    local status = get_alfred_status()
    if not status then quiet_since = nil; return true end -- unknown interrupts idle confirmation
    if not status.enabled then
        if task.status == status_enum.WAITING then retire_request() end
        if task.status == status_enum.LOOTING then task.status = status_enum.IDLE end
        return false
    end

    -- Hold while we have our own cycle in flight or floor-loot to grab.
    if waiting_for_request(status)
        or get_time_since_inject() < retry_after
        or task.status == status_enum['LOOTING']
    then
        return true
    end

    -- Yield while Alfred is busy under any caller (WarPigs preamble, etc.),
    -- and while our own with-teleport return is still ahead.
    if live_work(status) or awaiting_return(status) then return true end

    return wants_new_request(status)
end

task.Execute = function ()
    local status = get_alfred_status()
    if not status then quiet_since = nil; note_hold('Alfred status unreadable'); return end
    if not status.enabled then
        if task.status == status_enum.WAITING then retire_request() end
        note_hold(nil)
        return
    end
    -- Forced cleanup paths can execute this task without shouldExecute().
    if task.status == status_enum.WAITING then
        waiting_for_request(status)
        retry_manual_teleport(status)
        note_hold(task.status == status_enum.WAITING and (status.paused and 'Alfred paused with our request pending'
            or 'waiting for our Alfred cycle') or nil)
        return
    end
    -- The local floor-loot window always expires (a paused or busy Alfred
    -- must not keep is_busy() true through it forever).
    if task.status == status_enum['LOOTING'] then
        note_hold(nil)
        if get_time_since_inject() > task.loot_start + task.loot_timeout then
            task.status = status_enum['IDLE']
        end
        return
    end
    if awaiting_return(status) then
        note_hold('waiting for Alfred to return to the pit')
        return
    end
    if status.paused then
        note_hold(hard_need(status) and 'Alfred paused with inventory/repair work' or nil)
        return
    end
    if get_time_since_inject() < retry_after then note_hold(nil); return end

    -- Don't overwrite another caller's in-flight cycle.
    local alfred_busy = live_work(status)
    if alfred_busy then
        note_hold('Alfred busy with another caller')
        return
    end
    note_hold(nil)

    if task.status == status_enum['IDLE'] then
        if BatmobilePlugin and type(BatmobilePlugin.pause) == 'function' then
            BatmobilePlugin.pause(plugin_label)
        end
        -- Mode selection mirrors upstream: if we're already in town, no
        -- teleport. If we have floor loot and the setting wants us to
        -- return for it, use the teleport variant (Alfred handles the
        -- round-trip). Else do a plain trigger and teleport ourselves
        -- via teleport_with_debounce so we don't double-channel.
        if utils.player_in_zone(settings.town_zone) then
            trigger_alfred(false)
        elseif not floor_has_loot() or not settings.return_for_loot then
            if trigger_alfred(false) and task.status == status_enum.WAITING then
                manual_teleport, manual_attempts = true, 0
                retry_manual_teleport(get_alfred_status())
            end
        else
            trigger_alfred(true)
        end
    end
end

-- known_only: count only positive evidence (own request/loot window or C1
-- live work). The forced reset-timeout exit uses it so an unreadable status
-- can never block it (ARK-9/WCY-6).
task.is_busy = function (known_only)
    local status = get_alfred_status()
    if not status then return not known_only end
    if not status.enabled then return false end
    return task.status == status_enum.WAITING or task.status == status_enum.LOOTING
        or live_work(status) or awaiting_return(status)
end

-- C2 alfred_trip: Arkham's own Alfred round trip is in progress (request in
-- flight, post-callback loot window, or a with-teleport return not yet back
-- in the pit). Reads only local state; safe from the exported get_status.
task.own_trip = function ()
    if task.status == status_enum.WAITING or task.status == status_enum.LOOTING then return true end
    if trip.return_until == nil then return false end
    if in_pit() or get_time_since_inject() >= trip.return_until then
        trip.return_until = nil
        return false
    end
    return true
end

task.on_cancel = function ()
    generation = generation + 1
    clear_request()
    retry_after = -math.huge
    task.status = status_enum.IDLE
    task.loot_start = get_time_since_inject()
    task.debounce_time = -math.huge
    trip.teleport, trip.return_until = false, nil
    task.note = nil
    -- last_completion_at is kept: preemption/cancel must not re-arm a
    -- sticky need_trigger (ARK-1).
end

-- Ordinary preemption by another task (task_manager.execute): same as a
-- cancel, but a with-teleport trip whose callback already fired keeps its
-- return window (C2 alfred_trip) until Arkham is back in the pit.
task.on_preempt = function ()
    local return_until = trip.return_until
    task.on_cancel()
    trip.return_until = return_until
end

task.reset = function (transition)
    -- Alfred's own town/return trip changes worlds while its callback is
    -- still valid. Explicit cancellation/reset invalidates that callback.
    if type(transition) ~= 'string' then task.on_cancel() end
end

return task
