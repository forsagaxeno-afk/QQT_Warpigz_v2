-- Optional town service through the installed Alfred public API.
local host = require("tristram.host")
local data = require("tristram.data")
local M = {}
local aliases = { "AlfredTheButlerPlugin", "PLUGIN_alfred_the_butler" }
function M.read(peer)
    local status = type(peer) == "table" and host.try(rawget(peer, "get_status"))
    return type(status) == "table" and status or nil
end
function M.find()
    local fallback, fallback_status, enabled, enabled_status
    local seen = {}
    for _, name in ipairs(aliases) do
        local peer = rawget(_G, name)
        if type(peer) == "table" and not seen[peer] and type(rawget(peer, "get_status")) == "function"
            and type(rawget(peer, "trigger_tasks_with_teleport")) == "function" then
            seen[peer] = true
            local status = M.read(peer)
            if M.busy(status) then return peer, status end
            if not enabled and status and status.enabled == true then enabled, enabled_status = peer, status end
            if not fallback then fallback, fallback_status = peer, status end
        end
    end
    if enabled then return enabled, enabled_status end
    return fallback, fallback_status
end
function M.busy(status)
    return status ~= nil and (status.trigger_tasks == true or status.running == true
        or status.external_trigger == true
        -- Older providers expose teleport before the runner accepts the request.
        -- Keep that fallback beside current providers' explicit pending fields.
        or status.teleport == true and status.teleport_done ~= true and status.teleport_failed ~= true)
end
function M.needed(status, count)
    return type(count) == "number" and count >= data.INVENTORY_CAPACITY or status ~= nil and
        (status.need_trigger == true or status.need_repair == true or status.inventory_full == true
            or status.talisman_inventory_full == true)
end
function M.failure(status)
    for _, key in ipairs({ "skipped_reason", "refused_reason", "failure_reason" }) do
        if type(status[key]) == "string" and status[key] ~= "" then return "Alfred reports " .. key .. ": " .. status[key] end
    end
    for _, key in ipairs({ "teleport_failed", "salvage_failed", "sell_failed", "stash_failed", "repair_failed",
        "stash_full", "restock_failed", "gamble_failed", "salvage_talisman_failed", "stash_pull_failed" }) do
        if status[key] == true then return "Alfred reports " .. key .. ". Check its settings and town log." end
    end
end
function M.pause_owner(status)
    if type(status) ~= "table" then return false, nil end
    local paused = status.external_pause == true or status.paused == true
    return paused, paused and (status.pause_caller or status.paused_by) or nil
end
function M.begin(peer, status, adopt)
    if not peer or not status then return nil, "Alfred is unavailable. Enable SteroidAlfredV2 for automatic town service." end
    if status.enabled ~= true then return nil, "Alfred is disabled. Enable SteroidAlfredV2 and its external calls." end
    if not adopt and status.allow_external == false then return nil, "Alfred external calls are disabled." end
    -- Legacy providers publish external_pause/pause_caller; AlfredTheButler-WarPigz
    -- publishes paused/paused_by. Read both.
    local paused, pauser = M.pause_owner(status)
    if not adopt and paused and pauser ~= "TristramLoop" then
        return nil, "Alfred is paused by " .. tostring(pauser or "another caller") .. "."
    end
    local ticket = { active = true, done = false, adopted = adopt == true, paused = false }
    function ticket.set_recovering(on)
        if ticket.adopted or not on and not ticket.paused then return true end
        local pause, resume = rawget(peer, "pause"), rawget(peer, "resume")
        if type(pause) ~= "function" or type(resume) ~= "function" then return true end
        local ok, result
        if on then ok, result = pcall(pause, "TristramLoop") else ok, result = pcall(resume, "TristramLoop") end
        if not ok or result == false then return false end
        ticket.paused = on
        return true
    end
    function ticket.cancel()
        ticket.active = false
        return ticket.set_recovering(false)
    end
    function ticket.poll()
        if ticket.failure then return false, ticket.failure end
        local current = M.read(peer)
        if not current then return false, "Alfred status became unreadable." end
        if current.enabled ~= true then return false, "Alfred was disabled during town service." end
        local failure = M.failure(current)
        if failure then return false, failure end
        if ticket.adopted and current.all_task_done == true and not M.busy(current) then ticket.done = true end
        return ticket.done and not M.busy(current), nil, current
    end
    if not ticket.adopted then
        if status.external_caller and status.external_caller ~= "TristramLoop" then
            return nil, "Alfred is reserved by " .. tostring(status.external_caller) .. "."
        end
        -- A stale pause of our own (e.g. from an interrupted recovery) is lifted here.
        -- Never resume someone else's pause: Alfred's resume() clears any caller's.
        -- Do not pause from our callback: its status task would then prevent
        -- subsequent work, including the return.
        local resume = rawget(peer, "resume")
        if paused and pauser == "TristramLoop" and type(resume) == "function" then
            local ok, result = pcall(resume, "TristramLoop")
            if not ok or result == false then return nil, "Alfred refused to resume." end
        end
        -- Construct the ticket before the call: a synchronous callback is valid.
        local ok, result = pcall(rawget(peer, "trigger_tasks_with_teleport"), "TristramLoop", function()
            if ticket.active then
                ticket.done = true
                -- Some providers reset outcomes when the next request starts.
                -- Preserve any failure that was visible at this callback boundary.
                ticket.failure = M.failure(M.read(peer) or {})
            end
        end)
        if not ok or result == false then ticket.cancel(); return nil, "Alfred refused the town request." end
        -- Older providers return nil, current Alfred returns true. Neither proves completion.
    end
    return ticket
end
return M
