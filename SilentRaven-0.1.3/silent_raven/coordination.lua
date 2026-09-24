-- Read the controller's published reservation before its first update pulse.
-- This closes the startup race where SilentRaven auto-fired before WarPigs
-- could acquire the explicit managed lease. Existing running owners retain
-- their request; WarPigs joins only after that request has completed.
local M = {}

function M.can_start(caller)
    local controller = _G.WarPigsPlugin
    if controller == nil then return true end
    if type(controller) ~= 'table' or type(controller.status) ~= 'function' then
        return false, 'war_pigs_status_unavailable'
    end
    local ok, status = pcall(controller.status)
    if not ok or type(status) ~= 'table' then
        return false, 'war_pigs_status_unavailable'
    end
    if status.manages_whispers == true and caller ~= 'WarPigs' then
        return false, 'reserved_by_war_pigs'
    end
    return true
end

return M
