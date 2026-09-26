-- Local movement boundary. The host pathfinder drives every leg.
local bridge = {}
local last_error = nil

function bridge.refresh()
    -- The host pathfinder is always resolved at the call site.
end

function bridge.provider_name()
    return "pathfinder"
end

function bridge.is_degraded()
    return false
end

function bridge.last_error()
    return last_error
end

-- A successful request means the host accepted the command, not that arrival
-- was observed. The controller checks position before advancing a route.
function bridge.go_to(position, opts)
    if position == nil then
        last_error = "no position to walk to"
        return false
    end
    opts = opts or {}
    local command = pathfinder.request_move
    if opts.force_move_raw == true then command = pathfinder.force_move_raw
    elseif opts.force == true then command = pathfinder.force_move end
    local ok, result = pcall(command, position)
    if not ok or result == false then
        last_error = ok and "pathfinder refused the destination" or tostring(result)
        return false
    end
    last_error = nil
    return true
end

function bridge.release()
    local ok, result = pcall(pathfinder.clear_stored_path)
    if not ok or result == false then
        last_error = ok and "pathfinder refused to clear its path" or tostring(result)
        return false
    end
    last_error = nil
    return true
end

return bridge
