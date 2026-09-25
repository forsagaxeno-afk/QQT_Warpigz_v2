-- Helltide run mode: Warplan / Farm.
--
--   Warplan  cinder run for the War Plan step: kill monsters on the way, open
--            chests as soon as they are affordable, keep moving. No Pandemonium
--            ruptures, no maiden, no chaos-rift detours. WarPigs decides when
--            the step is done (quest), exactly as before.
--   Farm     manual farming until the helltide ends: ruptures (tears) first,
--            then chests when cinders suffice, else monsters. Maiden and chaos
--            rift toggles keep working.
--
-- The GUI combo only picks the mode for manual use. Whenever HR is enabled by
-- an external caller (HelltideRevampedPlugin.enable, i.e. WarPigs) the
-- EFFECTIVE mode is Warplan regardless of the GUI value, until HR is disabled.
-- An orchestrator that adopts an HR that is already on (no enable() call)
-- marks it the same way through HelltideRevampedPlugin.set_external(true).
local settings = require "core.settings"
local tracker = require "core.tracker"

local M = {
    WARPLAN = "warplan",
    FARM = "farm",
    -- Combo index -> label (index 0 = Warplan, 1 = Farm).
    LABELS = { "Warplan", "Farm" },
}

-- External enable edge (main.lua HelltideRevampedPlugin.enable/disable).
function M.set_external(on)
    tracker.hr_external = on and true or nil
end

function M.is_external()
    return tracker.hr_external == true
end

-- Mode picked in the GUI (settings.mode: 0 = Warplan, 1 = Farm).
function M.selected()
    if settings.mode == 1 then return M.FARM end
    return M.WARPLAN
end

function M.effective()
    if M.is_external() then return M.WARPLAN end
    return M.selected()
end

function M.is_farm()
    return M.effective() == M.FARM
end

-- Maiden / chaos rift are Farm-only detours.
function M.allow_maiden()
    return M.is_farm()
end

function M.allow_chaos_rift()
    return M.is_farm()
end

-- Proactive rupture hunting (and pass-by). Returns ok, reason.
function M.hunt_ruptures()
    if not M.is_farm() then return false, "warplan mode" end
    if not settings.hunt_rift then return false, "hunt off" end
    local cap = settings.rupture_max_cinders or 0
    if cap > 0 then
        local ok, cinders = pcall(get_helltide_coin_cinders)
        if ok and type(cinders) == "number" and cinders >= cap then
            return false, string.format("cinders %d >= %d (spend on chests first)", cinders, cap)
        end
    end
    return true, nil
end

-- Farm mode with ruptures on replaces the legacy pyre / flame pillar events.
function M.skip_local_events()
    return M.is_farm() and settings.hunt_rift == true
        and settings.rupture_replace_local_events == true
end

-- Logs the effective mode once per change (called from the task tick).
function M.tick()
    local mode = M.effective()
    if tracker.hr_mode_logged ~= mode then
        tracker.hr_mode_logged = mode
        console.print(string.format("[MODE] Helltide mode: %s%s", mode,
            M.is_external() and " (external enable forces warplan)" or ""))
        if mode == M.WARPLAN and (settings.do_maiden or settings.chaos_rift) then
            console.print("[MODE] Maiden / chaos rift toggles are Farm-mode only — ignored in warplan")
        end
    end
    return mode
end

return M
