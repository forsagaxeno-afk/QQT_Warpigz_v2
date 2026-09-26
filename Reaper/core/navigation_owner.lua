-- Track navigation issued by Reaper so idle cleanup cannot cancel another
-- plugin's Batmobile route. Alfred may already have taken control on yield.
local owner = { active = false, route = false }
function owner.claim() owner.active = true end
-- Called after BatmobilePlugin.navigate_long_path accepted a Reaper route.
function owner.route_started() owner.active = true; owner.route = true end

-- True when Alfred has (or may have) taken movement: C1 live work, or an
-- unreadable status. A foreign pause without live work does not own movement.
local function alfred_may_own_movement()
    local alfred = AlfredTheButlerPlugin or PLUGIN_alfred_the_butler
    if not alfred then return false end
    if type(alfred.get_status) ~= "function" then return true end
    local ok, s = pcall(alfred.get_status)
    if not ok or type(s) ~= "table" or type(s.enabled) ~= "boolean" then return true end
    if not s.enabled then return false end
    return s.trigger_tasks == true or s.external_trigger == true or s.pending == true or s.running == true
        or (s.teleport == true and s.teleport_done ~= true and s.teleport_failed ~= true)
end

-- RPR-5 / C3: releasing always ends the route Reaper started, also while
-- Alfred is busy and on disable(); Batmobile would otherwise keep driving it.
-- BatmobilePlugin.release(caller) is owner-aware (a goal Alfred claimed since
-- is left alone) and never clears the native path. Older Batmobile builds get
-- the previous sequence: stop our own route, clear the goal only while no
-- companion may own movement.
function owner.release()
    if not owner.active then return end
    local own_route = owner.route
    owner.active, owner.route = false, false
    local bm = BatmobilePlugin
    if type(bm) ~= "table" then return end
    if type(bm.release) == "function" then
        local ok, err = pcall(bm.release, "reaper")
        if not ok then console.print("[Reaper] Batmobile release failed: " .. tostring(err)) end
        return
    end
    local companion = alfred_may_own_movement()
    if (own_route or not companion) and type(bm.stop_long_path) == "function" then bm.stop_long_path("reaper") end
    if not companion and type(bm.clear_target) == "function" then bm.clear_target("reaper") end
end
return owner
