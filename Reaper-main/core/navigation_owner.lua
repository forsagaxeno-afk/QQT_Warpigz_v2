-- Track navigation issued by Reaper so idle cleanup cannot cancel another
-- plugin's Batmobile route. Alfred may already have taken control on yield.
local owner = { active = false }
function owner.claim() owner.active = true end
function owner.release()
    if not owner.active then return end
    owner.active = false
    local alfred = AlfredTheButlerPlugin or PLUGIN_alfred_the_butler
    if alfred then
        if type(alfred.get_status) ~= "function" then return end
        local ok, status = pcall(alfred.get_status)
        if not ok or type(status) ~= "table" or type(status.enabled) ~= "boolean" then return end
        if status.trigger_tasks or status.external_trigger or status.running
            or (status.teleport and not status.teleport_done and not status.teleport_failed)
            or status.pending or status.paused then return end
    end
    if BatmobilePlugin then
        if type(BatmobilePlugin.stop_long_path) == "function" then BatmobilePlugin.stop_long_path("reaper") end
        if type(BatmobilePlugin.clear_target) == "function" then BatmobilePlugin.clear_target("reaper") end
    end
end
return owner
