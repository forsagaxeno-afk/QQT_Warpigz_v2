local utils = require "core.utils"
local tracker = require "core.tracker"
local helltide_task = require "tasks.helltide"
local enums = require "data.enums"
local settings = require "core.settings"
local zone_overrides = require "data.zone_overrides"
local recovery = require "core.recovery"
local loot_guard = require "core.loot_guard"
local plugin_label = "helltide_revamped"

-- HLT-8: never teleport away while the Looter is still collecting (e.g. the
-- chest drop the WarPlan run was for when the buff drops at :55). Bounded so
-- a Looter that never reports idle cannot pin the search.
local LOOT_HOLD_MAX_S = 20.0
local loot_hold_since, loot_hold_logged = nil, false
local function loot_hold()
    if not loot_guard.busy() then
        loot_hold_since, loot_hold_logged = nil, false
        return false
    end
    local now = get_time_since_inject()
    loot_hold_since = loot_hold_since or now
    if now - loot_hold_since < LOOT_HOLD_MAX_S then return true end
    if not loot_hold_logged then
        loot_hold_logged = true
        console.print(string.format("[HelltideRevamped] Looter still busy after %.0fs — teleporting anyway",
            now - loot_hold_since))
    end
    return false
end

-- HLT-7 (needs live confirmation): after an external enable (WarPigs lands
-- the player with the warplan teleport and then enables HR) give the buff a
-- short grace to apply before searching teleports away and undoes the
-- arrival. Bounded; the landing zone is logged once for live diagnosis.
local ARRIVAL_GRACE_S = 15.0

local current_city_index = 0
-- Remembers which helltide_tps entry is active this hour so we can return directly
-- instead of cycling through all waypoints after being displaced from the zone.
-- Cleared only when helltide_active() returns false (minute >= 55, new hour).
local confirmed_helltide_tp = nil

-- Debounce for the idle-town teleport. The "wait until helltide starts"
-- branch fires teleport_to_waypoint(town) every pulse for as long as the
-- player isn't in the town zone — but the teleport is a multi-second channel
-- that gets cancelled if re-fired before completion, so the player ends up
-- spinning in place instead of arriving. 6s covers the channel + arrival.
local IDLE_TELEPORT_DEBOUNCE_S = 6.0
local idle_teleport_fired_time = nil
local idle_salvage_requested = false

-- After exhausting all helltide_tps entries with no helltide found, wait this
-- long before starting another scan cycle.  Prevents spamming teleports for
-- the entire helltide window when no zone has spawned yet.
local SEARCH_CYCLE_COOLDOWN_S = 45.0
local cycle_tp_count      = 0    -- TPs attempted in the current scan cycle
local last_cycle_end_time = nil  -- when the last full scan completed with no result

-- QQT_Warpigz_v3 (C6): a waypoint the character cannot use (not unlocked, a
-- Nahantu waypoint without the expansion) or whose landing zone differs from
-- the enum pinned the search on it for the rest of the hour (re-fired every
-- 6 s). After a refused teleport or TP_MAX_FIRES fires without a teleport
-- buff or arrival the entry is skipped until the hour ends.
local TP_MAX_FIRES = 3
local unreachable_tps = {}
local function mark_unreachable(tp)
    if unreachable_tps[tp.id] then return end
    unreachable_tps[tp.id] = true
    console.print("[HelltideRevamped] waypoint " .. tostring(tp.file) .. " unreachable — skipping this hour")
end
-- QQT_Warpigz_v3: a channel that started (teleport buff) but left the player
-- in the zone it was fired from was interrupted (a hit, a move), not refused:
-- it does not count toward TP_MAX_FIRES, at most TP_MAX_INTERRUPTS times per
-- destination (the only active Helltide must not be skipped for the hour).
local TP_MAX_INTERRUPTS = 5
local function current_zone_name()
    local world = get_current_world()
    return world and world:get_current_zone_name() or nil
end

local function detect_helltide_zone()
    for _, tp in ipairs(enums.helltide_tps) do
        if utils.player_in_region(tp.region) then
            return tp
        end
    end
    return nil
end

local function index_of_tp(tp)
    for i, entry in ipairs(enums.helltide_tps) do
        if entry.id == tp.id then return i end
    end
    return 1
end

local search_helltide_state = {
    SEARCHING_HELLTIDE = "SEARCHING_HELLTIDE",
    TELEPORTING = "TELEPORTING",
    WAITING_FOR_TELEPORT = "WAITING_FOR_TELEPORT",
    FOUND_HELLTIDE = "FOUND_HELLTIDE",
}

local search_helltide_task = {
    name = "Search helltide",
    current_state = search_helltide_state.SEARCHING_HELLTIDE,

    shouldExecute = function()
        -- Zone-override suppression: when WarPigs (or another external trigger)
        -- has dropped us into a non-canonical helltide zone, the helltide task
        -- owns the walk-to-entry handoff.  Letting search_helltide fire here
        -- would teleport us back to a known town and undo the WarPigs TP.
        if zone_overrides.get_current() and helltide_task.shouldExecute() then return false end
        -- Excluded zones: helltide task refused to run here, so we own the
        -- teleport-away even if the helltide buff is active.
        if zone_overrides.is_excluded_zone() then return true end
        return not utils.is_in_helltide()
    end,

    Execute = function(self)
        -- console.print("Current state: " .. self.current_state)

        local lp = get_local_player()
        if recovery.revive_if_dead(lp) then
            return
        end
        -- QQT_Warpigz_v3: no teleport (idle, scan, return to the Helltide)
        -- and no idle salvage request while SilentRaven claims a Whisper
        -- reward (bounded by SilentRaven).
        if (utils.raven_claim_active and utils.raven_claim_active()) then
            if not self._raven_logged then
                self._raven_logged = true
                console.print("[HelltideRevamped] SilentRaven is claiming a Whisper reward - waiting before teleporting")
            end
            return
        end
        self._raven_logged = nil

        -- QQT_Warpigz_v3: the trap recovery (helltide.lua) asks for a fresh
        -- scan. The helltide task took the tick on arrival, so our state may
        -- still be WAITING_FOR_TELEPORT for the abandoned zone, with the
        -- previous scan's count.
        if tracker.search_restart then
            tracker.search_restart = nil
            cycle_tp_count, last_cycle_end_time = 0, nil
            self._teleport_fired_at, self._tp_fires = nil, nil
            tracker.teleporting = false
            tracker.clear_key("wait_in_town")
            self.current_state = search_helltide_state.SEARCHING_HELLTIDE
        end
        if tracker.helltide_end then
            self:reset()
        elseif self.current_state == search_helltide_state.SEARCHING_HELLTIDE then
            self:searching_helltide()
        elseif self.current_state == search_helltide_state.TELEPORTING then
            self:teleporting_to_helltide()
        elseif self.current_state == search_helltide_state.WAITING_FOR_TELEPORT then
            self:waiting_for_teleport()
        elseif self.current_state == search_helltide_state.FOUND_HELLTIDE then
            self:found_helltide()
        end
    end,

    searching_helltide = function(self)
        if not self._farming_reset then
            helltide_task:reset()
            self._farming_reset = true
        end
        if tracker.confirmed_helltide_tp then
            confirmed_helltide_tp = tracker.confirmed_helltide_tp
            tracker.confirmed_helltide_tp = nil
            self._farming_reset = false
        end
        if not utils.helltide_active() then
            -- New hour window: forget the cached zone so next hour we search fresh
            if confirmed_helltide_tp then
                console.print("[HelltideRevamped] Helltide hour ended, clearing confirmed zone: " .. confirmed_helltide_tp.file)
                confirmed_helltide_tp = nil
            end
            unreachable_tps = {} -- QQT_Warpigz_v3: retried next hour
            console.print("Helltide is not active, wait until helltide starts")
            if not utils.player_in_zone(settings.town_zone) then
                local now = get_time_since_inject()
                if (not idle_teleport_fired_time
                    or now - idle_teleport_fired_time >= IDLE_TELEPORT_DEBOUNCE_S)
                    and not loot_hold()
                then
                    teleport_to_waypoint(settings.town_waypoint) -- Idle in selected home town until helltide starts
                    idle_teleport_fired_time = now
                end
            else
                -- We're in the home town zone — channel completed, drop the
                -- debounce stamp so the next "go idle" cycle fires immediately.
                idle_teleport_fired_time = nil
                -- HLT-4: one mover at a time. Salvage is requested only after
                -- our own teleport has arrived, and only for a hard Alfred
                -- need; the dedicated Alfred task keeps caller/callback
                -- ownership. Advisory restock never costs an off-window trip.
                if settings.salvage and not idle_salvage_requested and not tracker.alfred_paused_skip
                    and not utils.alfred_town_blocked() -- QQT_Warpigz_v3
                    and utils.alfred_available() == true and utils.is_inventory_full() == true
                then
                    tracker.needs_salvage = true
                    idle_salvage_requested = true
                end
            end
            return
        elseif utils.is_in_helltide() and not zone_overrides.is_excluded_zone() then
            idle_salvage_requested = false
            self._farming_reset = false
            -- Confirm and cache the zone (replacing any stale cached zone if
            -- the trap-recovery flag was set, since we're now in a *different*
            -- zone than the one we abandoned).
            local detected = detect_helltide_zone()
            if detected and (not confirmed_helltide_tp
                or tracker.skip_cached_zone
                or confirmed_helltide_tp.id ~= detected.id)
            then
                confirmed_helltide_tp = detected
                console.print("[HelltideRevamped] Confirmed helltide zone: " .. confirmed_helltide_tp.file)
            end
            -- Player landed in a working helltide; clear the skip flag and
            -- any pending scan-cycle cooldown so future returns are fast.
            tracker.skip_cached_zone = false
            tracker.external_enable_at = nil
            cycle_tp_count = 0
            last_cycle_end_time = nil
            console.print("Found helltide")
            self.current_state = search_helltide_state.FOUND_HELLTIDE
        elseif self:arrival_grace() then
            return
        elseif confirmed_helltide_tp and not tracker.skip_cached_zone
            and not unreachable_tps[confirmed_helltide_tp.id] then -- QQT_Warpigz_v3
            -- We know where this hour's helltide is — go back directly
            console.print("[HelltideRevamped] Returning to known helltide zone: " .. confirmed_helltide_tp.file)
            current_city_index = index_of_tp(confirmed_helltide_tp)
            cycle_tp_count = 0
            last_cycle_end_time = nil
            tracker.wait_in_town = nil  -- reset arrival timer so we don't use a stale one
            self._teleport_fired_at = nil
            self._tp_fires = nil -- QQT_Warpigz_v3
            self.current_state = search_helltide_state.WAITING_FOR_TELEPORT
        elseif self:live_hint() then -- QQT_Warpigz_v3: opt-in live zone (core/hr_live.lua)
            return
        else
            local now = get_time_since_inject()
            if last_cycle_end_time then
                if now - last_cycle_end_time < SEARCH_CYCLE_COOLDOWN_S then return end
                cycle_tp_count, last_cycle_end_time = 0, nil
            end
            -- Either no cached zone yet, OR trap-recovery told us to skip the
            -- cached one and try a different helltide region.  Cycle through.
            if tracker.skip_cached_zone then
                console.print("[HelltideRevamped] skip_cached_zone set — cycling through TPs to find a different helltide")
            else
                console.print("Not in helltide, teleport to next town to check")
            end
            self.current_state = search_helltide_state.TELEPORTING
        end
    end,

    teleporting_to_helltide = function(self)
        local world = get_current_world()
        if world and world:get_name() ~= "Limbo" and not tracker.teleporting then
            -- Check the completed count before choosing the next destination;
            -- otherwise the last waypoint is skipped on every scan cycle.
            -- QQT_Warpigz_v3: a cycle visits each usable destination once: it
            -- skips unreachable waypoints and the abandoned zone (otherwise the
            -- first town is visited twice).
            local n = #enums.helltide_tps
            local abandoned = tracker.skip_cached_zone and confirmed_helltide_tp or nil
            local function skipped(tp)
                return unreachable_tps[tp.id] or (abandoned and tp.id == abandoned.id)
            end
            local cycle_len = 0
            for _, tp in ipairs(enums.helltide_tps) do
                if not skipped(tp) then cycle_len = cycle_len + 1 end
            end
            if cycle_tp_count >= cycle_len then
                -- QQT_Warpigz_v3: the trap-recovery skip lasts one scan cycle.
                -- D4 runs one Helltide region at a time, so a cycle without a
                -- different one means the abandoned zone is the only one: go
                -- back now (the "Returning to known helltide zone" branch runs
                -- before the cooldown gate; search's helltide_task:reset()
                -- starts that session fresh) instead of cycling the other
                -- towns until minute 55.
                if abandoned and not unreachable_tps[abandoned.id] then
                    tracker.skip_cached_zone = false
                    console.print("[HelltideRevamped] no other Helltide found — returning to " .. abandoned.file)
                    last_cycle_end_time = nil
                else
                    tracker.skip_cached_zone = false
                    last_cycle_end_time = get_time_since_inject()
                end
                self.current_state = search_helltide_state.SEARCHING_HELLTIDE
                return
            end
            if current_city_index > n then
                current_city_index = 1
            else
                current_city_index = (current_city_index % n) + 1
            end
            -- Skip the cached zone when trap-recovery told us to find a
            -- different helltide, and every unreachable waypoint.
            for _ = 1, n do
                local tp = enums.helltide_tps[current_city_index]
                if not skipped(tp) then break end
                if abandoned and tp.id == abandoned.id then
                    console.print("[HelltideRevamped] skipping abandoned zone " .. abandoned.file)
                end
                current_city_index = (current_city_index % n) + 1
            end
            -- Track how many TPs we've tried this cycle; once all are exhausted,
            -- record the time and fall back to SEARCHING so the cooldown gate fires.
            cycle_tp_count = cycle_tp_count + 1
            console.print("Teleporting to: " .. tostring(enums.helltide_tps[current_city_index].file))
            tracker.wait_in_town = nil
            self._teleport_fired_at = nil
            self._tp_fires = nil -- QQT_Warpigz_v3
            self.current_state = search_helltide_state.WAITING_FOR_TELEPORT
        else
            console.print("Currently in loading screen. Waiting before attempting teleport.")
            return
        end
    end,

    waiting_for_teleport = function(self)
        if utils.player_in_zone(enums.helltide_tps[current_city_index].name) then
            if not tracker.check_time("wait_in_town", 4) then
                return
            end
            -- QQT_Warpigz_v3: a live-zone teleport that shows no Helltide
            -- after the wait refutes the hint for this hour.
            if self._live_tp and self._live_tp.id == enums.helltide_tps[current_city_index].id
                and not utils.is_in_helltide() and tracker.hr_live then
                pcall(tracker.hr_live.refute, self._live_hour, self._live_zone)
            end
            self._live_tp, self._live_hour, self._live_zone = nil, nil, nil
            tracker.teleporting = false
            self._teleport_fired_at = nil
            self._tp_fires = nil -- QQT_Warpigz_v3
            self.current_state = search_helltide_state.SEARCHING_HELLTIDE
        else
            if utils.is_teleporting() then
                tracker.teleporting = true
                self._tp_channel = true -- QQT_Warpigz_v3
                return
            else
                local now = get_time_since_inject()
                if (not self._teleport_fired_at or now - self._teleport_fired_at >= IDLE_TELEPORT_DEBOUNCE_S)
                    and not loot_hold()
                then
                    -- QQT_Warpigz_v3 (C6): bounded per destination; the API
                    -- returns false when the teleport is refused. The old
                    -- "fail teleport, retry" fallback sat after this return
                    -- and could never run.
                    local tp = enums.helltide_tps[current_city_index]
                    local zone_now = current_zone_name()
                    if not self._tp_fires then self._tp_interrupts = 0 end
                    if self._tp_channel and self._tp_fires and self._tp_zone == zone_now
                        and (self._tp_interrupts or 0) < TP_MAX_INTERRUPTS then
                        self._tp_interrupts = (self._tp_interrupts or 0) + 1
                        self._tp_fires = self._tp_fires - 1
                        console.print(string.format("[HelltideRevamped] teleport to %s interrupted — trying again (%d/%d)",
                            tostring(tp.file), self._tp_interrupts, TP_MAX_INTERRUPTS))
                    end
                    self._tp_channel = nil
                    local fired = false
                    if (self._tp_fires or 0) < TP_MAX_FIRES then
                        self._tp_zone = zone_now
                        fired = teleport_to_waypoint(tp.id) ~= false
                    end
                    if not fired then
                        mark_unreachable(tp)
                        -- Not a visit: the cycle length shrinks by this entry.
                        cycle_tp_count = math.max(0, cycle_tp_count - 1)
                        self._teleport_fired_at, self._tp_fires = nil, nil
                        tracker.teleporting = false
                        tracker.clear_key('wait_in_town')
                        self.current_state = search_helltide_state.TELEPORTING
                        return
                    end
                    self._tp_fires = (self._tp_fires or 0) + 1
                    self._teleport_fired_at = now
                end
                return
            end
        end
    end,

    found_helltide = function(self)
        if not utils.is_in_helltide() or not utils.helltide_active()
            or zone_overrides.is_excluded_zone() then
            self.current_state = search_helltide_state.SEARCHING_HELLTIDE
            self._farming_reset = false
            self:searching_helltide()
            return
        end
        console.print("Found helltide")
    end,

    -- QQT_Warpigz_v3: the opt-in live Helltide zone (core/hr_live.lua) names
    -- this hour's region: teleport straight there instead of the town cycle.
    -- Never to an unusable waypoint or the zone a trap recovery abandoned;
    -- refuted (no buff on arrival) it is ignored for the rest of the hour.
    live_hint = function(self)
        local live = tracker.hr_live
        if not live then return false end
        -- The first answer of the hour is on its way: hold (at most 5 s).
        local okw, waiting = pcall(live.waiting, get_time_since_inject())
        if okw and waiting then return true end
        local ok, tp = pcall(live.zone_tp)
        if not ok or type(tp) ~= 'table' or unreachable_tps[tp.id] then return false end
        if tracker.skip_cached_zone and confirmed_helltide_tp and confirmed_helltide_tp.id == tp.id then return false end
        if self._live_tp and self._live_tp.id == tp.id then return false end
        local okh, hour = pcall(function() return tracker.hr_clock and tracker.hr_clock.hour_id() end)
        local okz, zone = pcall(live.zone_name)
        self._live_tp, self._live_hour, self._live_zone = tp, okh and hour or nil, okz and zone or nil
        console.print("[HelltideRevamped] Live Helltide zone: " .. tostring(tp.file) .. " — teleporting there directly")
        current_city_index = index_of_tp(tp)
        tracker.wait_in_town = nil
        self._teleport_fired_at = nil
        self._tp_fires = nil
        self.current_state = search_helltide_state.WAITING_FOR_TELEPORT
        return true
    end,

    -- HLT-7: true while a fresh external arrival without the buff is inside
    -- ARRIVAL_GRACE_S (never in the idle town, never after the grace).
    arrival_grace = function(self)
        local at = tracker.external_enable_at
        if not at or utils.player_in_zone(settings.town_zone) then return false end
        local world = get_current_world()
        local where = world and (tostring(world:get_name()) .. "/" .. tostring(world:get_current_zone_name())) or "?"
        local now = get_time_since_inject()
        if now - at < ARRIVAL_GRACE_S then
            if self._arrival_logged ~= at then
                self._arrival_logged = at
                console.print(string.format(
                    "[HelltideRevamped] External enable in %s without the helltide buff — waiting up to %.0fs before searching",
                    where, ARRIVAL_GRACE_S))
            end
            return true
        end
        tracker.external_enable_at = nil
        console.print(string.format(
            "[HelltideRevamped] Still no helltide buff %.0fs after arriving in %s — searching other zones",
            ARRIVAL_GRACE_S, where))
        return false
    end,

    cancel_pending = function(self)
        cycle_tp_count = 0
        last_cycle_end_time = nil
        idle_teleport_fired_time = nil
        idle_salvage_requested = false
        confirmed_helltide_tp = nil
        tracker.confirmed_helltide_tp = nil
        tracker.teleporting = false
        tracker.clear_key("wait_in_town")
        tracker.external_enable_at = nil
        loot_hold_since, loot_hold_logged = nil, false
        tracker.skip_cached_zone = false -- QQT_Warpigz_v3: never carried into a new session
        tracker.search_restart = nil
        unreachable_tps = {} -- QQT_Warpigz_v3
        self._tp_fires = nil
        self._farming_reset = false
        self._teleport_fired_at = nil
        self._live_tp, self._live_hour, self._live_zone = nil, nil, nil -- QQT_Warpigz_v3
        self.current_state = search_helltide_state.SEARCHING_HELLTIDE
    end,

    reset = function(self)
        tracker.helltide_end = false
        helltide_task:reset()
        cycle_tp_count = 0
        last_cycle_end_time = nil
        self._teleport_fired_at = nil
        self._tp_fires = nil -- QQT_Warpigz_v3
        self._farming_reset = false
        tracker.teleporting = false
        tracker.clear_key("wait_in_town")
        tracker.skip_cached_zone = false -- QQT_Warpigz_v3
        self._live_tp, self._live_hour, self._live_zone = nil, nil, nil -- QQT_Warpigz_v3
        self.current_state = search_helltide_state.SEARCHING_HELLTIDE
    end
}

return search_helltide_task
