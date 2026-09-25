-- ============================================================
--  Reaper - tasks/alfred.lua
--  Yields to Alfred butler plugin when he needs to work.
--  Fork-aware: SteroidAlfredButler vs AlfredTheButler-main.
-- ============================================================

local plugin_label = "Reaper"
local settings     = require "core.settings"
local tracker      = require "core.tracker"
local utils        = require "core.utils"
local navigate_to_boss = require "tasks.navigate_to_boss"
local interact_altar = require "tasks.interact_altar"

local status_enum = {
    IDLE    = "idle",
    WAITING = "waiting for alfred to complete",
}

local task = {
    name   = "alfred_running",
    status = status_enum.IDLE,
}

local function get_alfred()
    return AlfredTheButlerPlugin or PLUGIN_alfred_the_butler
end

-- Tracks last cycle completion for restock-stickiness escape. See
-- HelltideRevamped/tasks/alfred.lua for the full rationale. Never cleared by
-- a reset, run_once or task switch (C1/RPR-3): the grace expires by itself.
local last_completion_at = nil
local STUCK_NEED_TRIGGER_GRACE = 30.0

local generation = 0
local request_plugin, request_started, quiet_since
local retry_after = -math.huge
local RETRY_DELAY, PICKUP_WINDOW, QUIET_WINDOW = 5, 8, 2
-- C1/C6 bounds: an unreadable status holds like busy for UNKNOWN_HOLD, then
-- Alfred counts as unavailable; a pause Reaper does not own holds Reaper's
-- own hard request for PAUSED_HOLD_MAX; any hold past HOLD_LOG_SECS is
-- logged once and shown in the status text.
local UNKNOWN_HOLD, PAUSED_HOLD_MAX, HOLD_LOG_SECS = 10, 60, 60
local watch = { unknown_since = nil, unknown_logged = false, live_seen = false,
    paused_since = nil, paused_logged = false,
    hold = nil, hold_since = nil, hold_logged = false, yield_at = nil, advisory_logged = -math.huge }

-- C1 canonical live-work predicate (a teleport latched after a finished or
-- failed trip is not live work).
local function live_work(s)
    return s.trigger_tasks == true or s.external_trigger == true or s.pending == true or s.running == true
        or (s.teleport == true and s.teleport_done ~= true and s.teleport_failed ~= true)
end

-- C1 hard need; everything else (need_trigger alone, restock, stash extras)
-- is advisory.
local function hard_need(s)
    return s.inventory_full == true or s.need_repair == true
end

-- Suite policy (round 5; the same reading as ArkhamAsylum and WonderCity):
-- while WarPigs is loaded and its status() reports enabled == true, WarPigs
-- services advisory-only flags once per Temis visit, and Reaper never starts
-- an Alfred trip for them. Before, a run_once started in town (the
-- boss-zone rule covers only the lair) with a sticky restock flag cost one
-- Alfred trip per boss run. Hard needs are unchanged. WarPigs absent,
-- disabled, without status(), throwing or returning a non-table: standalone
-- rules.
local function warpigs_advisory_idle()
    local wp = WarPigsPlugin
    if type(wp) ~= "table" or type(wp.status) ~= "function" then return false end
    local ok, st = pcall(wp.status)
    return ok and type(st) == "table" and st.enabled == true
end

-- Any observed live -> idle edge is a finished cycle (ours or a foreign
-- caller's): advisory flags get the same sticky grace either way.
local function observe_cycle(status)
    if status.enabled and live_work(status) then
        watch.live_seen = true
    elseif watch.live_seen then
        watch.live_seen = false
        last_completion_at = get_time_since_inject()
    end
end

-- nil while an unreadable status is still inside UNKNOWN_HOLD (busy);
-- afterwards Alfred counts as unavailable, with one log line (C1).
local function get_alfred_status()
    local a = get_alfred()
    if not a then watch.unknown_since = nil; return {enabled = false} end
    local status
    if type(a.get_status) == "function" then
        local ok, s = pcall(a.get_status)
        if ok and type(s) == "table" and type(s.enabled) == "boolean" then status = s end
    end
    if status then
        watch.unknown_since, watch.unknown_logged = nil, false
        observe_cycle(status)
        return status
    end
    local now = get_time_since_inject()
    watch.unknown_since = watch.unknown_since or now
    if now - watch.unknown_since < UNKNOWN_HOLD then return nil end
    if not watch.unknown_logged then
        watch.unknown_logged = true
        console.print(string.format("[Reaper] Alfred status unreadable for %.0fs — treating Alfred as unavailable",
            now - watch.unknown_since))
    end
    return {enabled = false, unavailable = true}
end

-- C1: a pause Reaper never owns holds only Reaper's own queued hard request,
-- bounded by PAUSED_HOLD_MAX; afterwards the request is retired normally.
local function paused_hold(status)
    if status.paused ~= true then
        watch.paused_since, watch.paused_logged = nil, false
        return false
    end
    if not (task.status == status_enum.WAITING and hard_need(status)) then return false end
    local now = get_time_since_inject()
    watch.paused_since = watch.paused_since or now
    if now - watch.paused_since < PAUSED_HOLD_MAX then return true end
    if not watch.paused_logged then
        watch.paused_logged = true
        console.print(string.format("[Reaper] Alfred paused by another plugin for %.0fs with our town request pending — continuing without Alfred",
            now - watch.paused_since))
    end
    return false
end

local function clear_request()
    request_plugin, request_started, quiet_since = nil, nil, nil
end

local function retire_request()
    generation = generation + 1
    clear_request()
    task.status = status_enum.IDLE
    retry_after = get_time_since_inject() + RETRY_DELAY
end

local function waiting_for_request(status)
    if task.status ~= status_enum.WAITING then return false end
    if get_alfred() ~= request_plugin then retire_request(); return true end
    if not status or live_work(status) or paused_hold(status) then quiet_since = nil; return true end
    -- The legacy API accepts a request with nil and omits its queue flag.
    -- Never infer completion from that return value. If its callback is lost,
    -- allow pickup and require a fresh stable idle observation before retry.
    local now = get_time_since_inject()
    if now - (request_started or now) < PICKUP_WINDOW then return true end
    quiet_since = quiet_since or now
    if now - quiet_since >= QUIET_WINDOW then retire_request() end
    return true
end

-- C6: remember why Reaper is holding for Alfred; log a long hold once.
local function note_hold(reason)
    if reason == nil then watch.hold = nil; return end
    local now = get_time_since_inject()
    if watch.hold ~= reason then watch.hold, watch.hold_since, watch.hold_logged = reason, now, false end
    if not watch.hold_logged and now - watch.hold_since >= HOLD_LOG_SECS then
        watch.hold_logged = true
        console.print(string.format("[Reaper] Holding for Alfred for %.0fs (%s)", now - watch.hold_since, reason))
    end
end

function task.hold_reason()
    if not watch.hold then return nil end
    return string.format("%s (%ds)", watch.hold, math.floor(get_time_since_inject() - watch.hold_since))
end

function task.reset()
    generation = generation + 1
    clear_request()
    task.status = status_enum.IDLE
    retry_after = -math.huge
    -- The sticky grace (last_completion_at) is kept on purpose (C1). A new
    -- session re-evaluates a foreign pause from scratch.
    watch.paused_since, watch.paused_logged = nil, false
    watch.hold, watch.yield_at = nil, nil
end

local function trigger_alfred()
    local a = get_alfred()
    if not a or type(a.trigger_tasks_with_teleport) ~= "function" then
        retry_after = get_time_since_inject() + RETRY_DELAY
        return false
    end
    generation = generation + 1
    local token = generation
    task.status = status_enum.WAITING
    request_plugin, request_started, quiet_since = a, get_time_since_inject(), nil
    -- Reaper did not acquire an Alfred pause, so it cannot resume one.
    local ok, accepted = pcall(a.trigger_tasks_with_teleport, plugin_label, function()
        if token ~= generation or task.status ~= status_enum.WAITING or get_alfred() ~= a then return end
        -- A callback only releases our wait. It must not pause an unrelated
        -- caller's cycle, even if the callback was delayed by a transition.
        task.status = status_enum.IDLE
        clear_request()
        retry_after = -math.huge
        last_completion_at = get_time_since_inject()
    end)
    if ok and accepted == false then
        if token == generation and task.status == status_enum.WAITING then retire_request() end
        return false
    end
    -- A host method can enqueue before throwing. Keep its request reserved
    -- until a callback or stable readable idle reconciles that uncertainty.
    if not ok then return false end
    return true
end

-- Returns (run this task?, hold reason or nil).
local function evaluate()
    local status = get_alfred_status()
    if not status then
        quiet_since = nil -- unknown interrupts idle confirmation
        -- C1: Reaper's own setting first. An unreadable Alfred (bounded in
        -- get_alfred_status) holds only when Reaper uses Alfred or waits on
        -- its own request.
        if settings.use_alfred or task.status == status_enum.WAITING then
            return true, "Alfred status unreadable"
        end
        return false
    end
    if not status.enabled then
        if task.status == status_enum.WAITING then retire_request() end
        return false
    end

    if waiting_for_request(status) then return true, "waiting for Reaper's Alfred trip" end

    -- Never fight Alfred's movement or teleport, whoever started it.
    if live_work(status) then return true, "Alfred busy" end

    if not settings.use_alfred then return false end
    -- C1/RPR-4: a pause Reaper does not own is idle for Reaper.
    if status.paused then return false end
    local now = get_time_since_inject()
    if now < retry_after then return true end

    -- Start maintenance between runs; a live boss/chest sequence owns the dungeon.
    if tracker.altar_activated or tracker.chest_opened_time then return false end

    -- need_trigger is the unified signal across both forks. The legacy
    -- AlfredTheButler-main fork (PLUGIN_alfred_the_butler) reports its work
    -- through individual flags instead.
    local legacy = PLUGIN_alfred_the_butler ~= nil
    if hard_need(status) and (status.need_trigger or legacy) then return true end
    local advisory = status.need_trigger == true
        or (legacy and type(status.restock_count) == "number" and status.restock_count > 0)
    if not advisory then return false end
    -- RPR-3: advisory flags alone (restock / stash extras) can stay stuck when
    -- Alfred cannot clear them. They wait out the grace after any finished
    -- cycle and never pull the player out of a boss lair before the altar.
    if last_completion_at and now - last_completion_at < STUCK_NEED_TRIGGER_GRACE then return false end
    if type(utils.in_any_boss_zone) == "function" and utils.in_any_boss_zone() then return false end
    if not warpigs_advisory_idle() then return true end
    -- Not a hold (the run continues); one line per minute at most.
    if now - watch.advisory_logged >= HOLD_LOG_SECS then
        watch.advisory_logged = now
        console.print("[Reaper] advisory Alfred restock skipped: WarPigs is enabled and services it in Temis")
    end
    return false
end

function task.shouldExecute()
    local run, hold = evaluate()
    note_hold(hold)
    return run
end

function task.Execute()
    -- Stop our autonomous route before handing movement to Alfred. If Alfred
    -- is already busy, navigation_owner leaves Alfred's own goal alone.
    navigate_to_boss.reset()
    interact_altar.reset()
    settings.orb_set_block(false)
    -- C5: account the yield so chest timeouts exclude it.
    local now = get_time_since_inject()
    if watch.yield_at and now - watch.yield_at <= 1.0 then
        tracker.companion_yield = (tracker.companion_yield or 0) + (now - watch.yield_at)
    end
    watch.yield_at = now
    local status = get_alfred_status()
    if not status then quiet_since = nil; return end
    if not status.enabled then
        if task.status == status_enum.WAITING then retire_request() end
        return
    end

    if waiting_for_request(status) then return end
    if live_work(status) or status.paused or not settings.use_alfred or now < retry_after then return end

    -- Don't overwrite another caller's in-flight cycle.
    if task.status == status_enum.IDLE then
        trigger_alfred()
    end
end

return task
