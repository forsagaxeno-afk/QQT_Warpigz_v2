-- Read-only compatibility with the supplied LooteerV2/V3 public exports.
local M = {}
local quiet_since = nil
local exit_committed = false
local QUIET_SECONDS = 3

-- QQT_Warpigz_v3 2.2.5: the third-party Navigator looter (docs/THIRD_PARTY_APIS.md):
-- a busy Scavenger holds the same loot waits as a busy Looter.
local function scavenger_busy()
    local s = Scavenger
    -- QQT_Warpigz_v3 2.2.7: Rosie's Scavenger stand-in (`_rosie=true`, published
    -- while Worldstone runs) is Rosie's pickup, already read through the Looter.
    if type(s) ~= 'table' or rawget(s, '_rosie') == true or type(s.is_busy) ~= 'function' then return false end
    local ok, busy = pcall(s.is_busy)
    return ok and busy == true
end
-- QQT_Warpigz_v3 2.2.5 (audit MED, Rosie yield rest <-> exit guards): a drop
-- Rosie stepped back from (yield, 4-30 s) or rests between rounds reads as
-- "not busy", yet Rosie still means to take it. A drop Rosie wants within
-- its own pickup range and has not given up on (evaluate_item: wanted by
-- distance, and not settled/exhausted) keeps the exit waiting, inside the
-- same bound. Sampled at most every PENDING_EVERY s.
local PENDING_EVERY = 0.5
local pending = {at = nil, value = false}
local function loot_pending()
    local looter = LooteerPlugin
    if type(looter) ~= 'table' or type(looter.evaluate_item) ~= 'function' then return false end
    local now = get_time_since_inject()
    if pending.at and now >= pending.at and now - pending.at < PENDING_EVERY then return pending.value end
    pending.at = now
    local ok, found = pcall(function()
        if type(looter.get_enabled) == 'function' and looter.get_enabled() ~= true then return false end
        -- QQT_Warpigz_v3 2.2.5 (Coordinator review): only a pickup that can act now
        -- (Rosie status().ready: enabled, not paused, not activity-owned, world
        -- loaded, no menu open) holds the exit for a pending drop.
        if type(looter.status) ~= 'function' then return false end
        local st = looter.status()
        if type(st) ~= 'table' or st.ready ~= true then return false end
        for _, item in pairs(actors_manager.get_all_items() or {}) do
            if looter.evaluate_item(item, false) and looter.evaluate_item(item, true) then return true end
        end
        return false
    end)
    pending.value = ok and found == true
    return pending.value
end

function M.busy()
    if scavenger_busy() then return true end -- QQT_Warpigz_v3 2.2.5
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
    if not LooteerPlugin and not scavenger_busy() then return true end -- QQT_Warpigz_v3 2.2.5
    local now = get_time_since_inject()
    if M.busy() or loot_pending() then -- QQT_Warpigz_v3 2.2.5: a yielded/resting drop
        quiet_since = nil
        busy_since = busy_since or now
        if now - busy_since < LOOTER_MAX_HOLD then return false end
        if not busy_logged then
            busy_logged = true
            console.print(string.format("[HordeDev] Looter busy for %ds; no longer holding the chest/exit handoff", LOOTER_MAX_HOLD))
        end
        return true
    end
    -- QQT_Warpigz_v3 2.2.5: a quiet gap shorter than QUIET_SECONDS does not
    -- end the busy episode. A Looter busy 2 s / idle 1 s over and over
    -- re-armed LOOTER_MAX_HOLD on every quiet sample and held forever.
    quiet_since = quiet_since or now
    if now - quiet_since < QUIET_SECONDS then return busy_logged end -- a spent bound stays released
    busy_since, busy_logged = nil, false
    return true
end

-- Reason text while the Looter is holding HordeDev (nil when not holding).
function M.hold_reason()
    if exit_committed or not busy_since then return nil end
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
local pylon = {paused_at = nil, pause_spent = false, yield_since = nil, yield_over = false, logged = false}

local function release_pause()
    if pylon.paused_at then
        local looter = LooteerPlugin
        if type(looter) == 'table' and type(looter.release_pause) == 'function' then
            pcall(looter.release_pause, PAUSE_CALLER)
        end
    end
    pylon.paused_at = nil
end

-- true: HordeDev must not issue movement this tick (yielding to the Looter).
function M.pylon_pending()
    local looter = LooteerPlugin
    if type(looter) ~= 'table' then return false end
    local now = get_time_since_inject()
    if type(looter.acquire_pause) == 'function' and type(looter.release_pause) == 'function' then
        -- One bounded pause per pylon episode: once spent it is not re-taken
        -- until pylon_done() (no pylon pending) ends the episode.
        if pylon.pause_spent then
            -- fall through to the bounded movement yield below
        elseif not pylon.paused_at then
            local ok, acquired = pcall(looter.acquire_pause, PAUSE_CALLER)
            if ok and acquired ~= false then
                pylon.paused_at = now
                console.print('[HordeDev] pausing Looter pickup while taking the pylon')
                return false
            end
        elseif now - pylon.paused_at < PYLON_PAUSE_MAX then
            return false
        else
            release_pause()
            pylon.pause_spent, pylon.yield_over = true, true
            console.print(string.format('[HordeDev] Looter paused for %ds; releasing it and walking to the pylon', PYLON_PAUSE_MAX))
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
    release_pause()
    pylon.pause_spent, pylon.yield_since, pylon.yield_over, pylon.logged = false, nil, false, false
end

-- QQT_Warpigz_v3: Rosie keeps a pause until its owner releases it (and
-- restores it across its own reload), so HordeDev's pylon pause must never
-- outlive the episode that took it:
--  * bound_pause(): held 5 s past PYLON_PAUSE_MAX (the wave task, which
--    normally releases it, did not run: preempted, player out of BSK), it
--    is released here;
--  * release_stale_pause(): a reloaded HordeDev starts with paused_at = nil
--    and so could never release the previous instance's pause. Called on
--    every update until Rosie's export is seen once (Rosie may load after
--    HordeDev); release_pause is idempotent in Rosie.
function M.bound_pause()
    if pylon.paused_at and get_time_since_inject() - pylon.paused_at >= PYLON_PAUSE_MAX + 5 then
        release_pause()
        pylon.pause_spent, pylon.yield_over = true, true
    end
end

local stale_pause_checked = false
function M.release_stale_pause()
    if stale_pause_checked then return end
    local looter = LooteerPlugin
    if type(looter) ~= 'table' or type(looter.release_pause) ~= 'function' then return end
    stale_pause_checked = true
    if pylon.paused_at then return end -- our own live pause (bounded above)
    pcall(looter.release_pause, PAUSE_CALLER)
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
    return M.alfred_may_own_movement()
end

-- QQT_Warpigz_v3: the Alfred/Rosie town-service half of the check above
-- (a trip under any caller, including Rosie's own automatic service).
-- readable_only: an unreadable status is not live work (callers that would
-- otherwise hold on it without a bound).
function M.alfred_may_own_movement(readable_only)
    local alfred = AlfredTheButlerPlugin or PLUGIN_alfred_the_butler
    if not alfred then return false end
    if type(alfred.get_status) ~= 'function' then return not readable_only end
    local ok, status = pcall(alfred.get_status)
    if not ok or type(status) ~= 'table' or type(status.enabled) ~= 'boolean' then return not readable_only end
    if not status.enabled then return false end
    -- C1: a teleport latched after a finished or failed trip is not live work.
    return status.trigger_tasks == true or status.external_trigger == true or status.running == true
        or status.pending == true
        or (status.teleport == true and status.teleport_done ~= true and status.teleport_failed ~= true)
end

return M
