-- Read-only LooteerV2/V3 ownership; unreadable state holds movement.
local M = {}

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
    -- C1 live work: a teleport latched after a finished or failed trip is not.
    return status.trigger_tasks == true or status.external_trigger == true or status.pending == true
        or status.running == true
        or (status.teleport == true and status.teleport_done ~= true and status.teleport_failed ~= true)
end

return M
