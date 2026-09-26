-- Read-only compatibility with the supplied LooteerV2/V3 public exports.
local M = {}
local quiet_since = nil
local exit_committed = false
local QUIET_SECONDS = 3

function M.busy()
    local looter = LooteerPlugin
    if not looter then return false end
    local function read(fn, ...)
        if type(fn) ~= 'function' then return false, nil end
        return pcall(fn, ...)
    end
    -- Modern contracts expose booleans. A failed/invalid read is not idle.
    if type(looter.get_enabled) == 'function' then
        local ok, enabled = read(looter.get_enabled)
        if not ok or type(enabled) ~= 'boolean' then return true end
        if not enabled then return false end
    elseif type(looter.getSettings) == 'function' then
        local ok, enabled = read(looter.getSettings, 'enabled')
        if not ok then return true end
        -- Supplied LooteerV2 intentionally returns nil for stored false.
        if enabled == false or enabled == nil then return false end
        if enabled ~= true then return true end
    end
    local modern_unknown = false
    if type(looter.is_actively_looting) == 'function' then
        local ok, active = read(looter.is_actively_looting)
        if ok and type(active) == 'boolean' then return active end
        modern_unknown = true
    end
    if type(looter.is_idle) == 'function' then
        local ok, idle = read(looter.is_idle)
        if ok and type(idle) == 'boolean' then return not idle end
        modern_unknown = true
    end
    -- A second explicit modern status can resolve an unavailable first one.
    -- Legacy nil must not turn an unreadable modern owner into idle.
    if modern_unknown then return true end
    if type(looter.getSettings) == 'function' then
        local ok, active = read(looter.getSettings, 'looting')
        if not ok then return true end
        if active == false or active == nil then return false end
        return true
    end
    return true -- no readable ownership contract
end

-- C6: an unreadable or never-idle Looter must not hold the chest/exit
-- handoff forever. After LOOTER_MAX_HOLD of continuous busy the hold is
-- released with one log line (a quiet sample re-arms the bound).
local LOOTER_MAX_HOLD = 120
local busy_since, busy_logged = nil, false

function M.ready()
    if exit_committed then return true end
    if not LooteerPlugin then return true end
    local now = get_time_since_inject()
    if M.busy() then
        quiet_since = nil
        busy_since = busy_since or now
        if now - busy_since < LOOTER_MAX_HOLD then return false end
        if not busy_logged then
            busy_logged = true
            console.print(string.format("[HordeDev] Looter busy for %ds; no longer holding the chest/exit handoff", LOOTER_MAX_HOLD))
        end
        return true
    end
    busy_since, busy_logged = nil, false
    quiet_since = quiet_since or now
    return now - quiet_since >= QUIET_SECONDS
end

-- Reason text while the Looter is holding HordeDev (nil when not holding).
function M.hold_reason()
    if exit_committed or not LooteerPlugin or not busy_since then return nil end
    return string.format("waiting for Looter (%ds)", math.floor(get_time_since_inject() - busy_since))
end

-- Live report (2.1.3): during pylon selection the Looter (LooteerV3 reports
-- busy while ANY wanted item is nearby, even an unreachable one) and HordeDev
-- both steered the player every tick, so neither the item nor the pylon was
-- reached. For a pylon/altar HordeDev now:
--   * pauses a Looter that offers acquire_pause/release_pause (Rosie) for at
--     most PYLON_PAUSE_MAX s, released as soon as no pylon is pending;
--   * otherwise yields movement to a busy Looter for at most PYLON_YIELD_MAX s
--     per pylon episode, then walks to the pylon regardless (logged once).
local PYLON_PAUSE_MAX, PYLON_YIELD_MAX = 20, 8
local PAUSE_CALLER = 'HordeDev'
local pylon = {paused_at = nil, yield_since = nil, yield_over = false, logged = false}

-- true: HordeDev must not issue movement this tick (yielding to the Looter).
function M.pylon_pending()
    local looter = LooteerPlugin
    if type(looter) ~= 'table' then return false end
    local now = get_time_since_inject()
    if type(looter.acquire_pause) == 'function' and type(looter.release_pause) == 'function' then
        if not pylon.paused_at then
            local ok, acquired = pcall(looter.acquire_pause, PAUSE_CALLER)
            if ok and acquired ~= false then
                pylon.paused_at = now
                console.print('[HordeDev] pausing Looter pickup while taking the pylon')
                return false
            end
        elseif now - pylon.paused_at < PYLON_PAUSE_MAX then
            return false
        else
            M.pylon_done()
            pylon.yield_over = true
        end
    end
    if pylon.yield_over or not M.busy() then return false end
    pylon.yield_since = pylon.yield_since or now
    if now - pylon.yield_since < PYLON_YIELD_MAX then return true end
    pylon.yield_over = true
    if not pylon.logged then
        pylon.logged = true
        console.print(string.format('[HordeDev] Looter still busy after %ds; walking to the pylon anyway', PYLON_YIELD_MAX))
    end
    return false
end

-- No pylon pending any more (taken, gone, reset): release the pause.
function M.pylon_done()
    if pylon.paused_at then
        local looter = LooteerPlugin
        if type(looter) == 'table' and type(looter.release_pause) == 'function' then
            pcall(looter.release_pause, PAUSE_CALLER)
        end
    end
    pylon.paused_at, pylon.yield_since, pylon.yield_over, pylon.logged = nil, nil, false, false
end

function M.reset()
    quiet_since = nil
    exit_committed = false
    busy_since, busy_logged = nil, false
    M.pylon_done()
end

function M.commit_exit()
    exit_committed = true
end

-- Companion callbacks may already have replaced the shared native path before
-- our next update observes their ownership. Release our flag without clearing it.
function M.companion_may_own_movement()
    if M.busy() then return true end
    local alfred = AlfredTheButlerPlugin or PLUGIN_alfred_the_butler
    if not alfred then return false end
    if type(alfred.get_status) ~= 'function' then return true end
    local ok, status = pcall(alfred.get_status)
    if not ok or type(status) ~= 'table' or type(status.enabled) ~= 'boolean' then return true end
    if not status.enabled then return false end
    -- C1: a teleport latched after a finished or failed trip is not live work.
    return status.trigger_tasks == true or status.external_trigger == true or status.running == true
        or status.pending == true
        or (status.teleport == true and status.teleport_done ~= true and status.teleport_failed ~= true)
end

return M
