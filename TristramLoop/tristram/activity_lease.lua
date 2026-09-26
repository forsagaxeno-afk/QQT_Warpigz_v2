-- Shared execution ownership, independent of optional movement/rotation peers.
-- Lua callbacks are serialized: checking and installing this record cannot yield.
local CALLER = "TristramLoop"
local lease = {}
local token = {}
local cleanup = nil

local function owner()
    return rawget(_G, "TRISTRAM_LOOP_ACTIVITY_OWNER")
end

function lease.owns()
    local held = owner()
    return type(held) == "table" and held.token == token
end

function lease.owner_name()
    local held = owner()
    if held == nil then return nil end
    return type(held) == "table" and tostring(held.name) or "unknown activity"
end

-- No timer steals a paused owner's controls. Release or successful reload
-- cleanup is required before another activity may start.
function lease.acquire()
    if lease.owns() then return true, CALLER end
    if owner() ~= nil then return false, lease.owner_name() end
    _G.TRISTRAM_LOOP_ACTIVITY_OWNER = { name = CALLER, token = token, cleanup = cleanup }
    return true, CALLER
end

function lease.release()
    if not lease.owns() then return false end
    _G.TRISTRAM_LOOP_ACTIVITY_OWNER = nil
    return true
end

-- Direct bridge users retain their standalone behavior when no cycle owns the
-- slot. During a cycle only the matching module instance may write or clear it.
function lease.can_write()
    return owner() == nil or lease.owns()
end

function lease.bind_release(callback)
    cleanup = callback
    local held = owner()
    if lease.owns() then held.cleanup = callback end
    if type(held) == "table" and held.name == CALLER and held.token ~= token then
        if type(held.cleanup) ~= "function" then return false end
        local ok = pcall(held.cleanup)
        if not ok or owner() == held then return false end
    end
    return true
end

return lease
