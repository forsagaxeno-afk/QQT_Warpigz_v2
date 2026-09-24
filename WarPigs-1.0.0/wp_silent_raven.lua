-- Optional SilentRaven v2-contract bridge; no Loot Steward dependency.
-- Only Temis visits, only after managed activity cleanup, no borrowed callbacks.
local M = {}
local OWNER, TEMIS = 'WarPigs', 'Skov_Temis'
-- Bounded waits (C1 / C6 / SRV-2 / L7), in seconds:
--   alfred_unreadable: unreadable Alfred status counts as busy this long, then
--                      Alfred is "unavailable" (not busy), logged once (C1).
--   wait_unknown:      unreadable/unknown companion data forfeits the visit
--                      after this long without a readable answer.
--   wait_live:         observable companion work (Alfred cycle, Looter
--                      pickup, WarPug session) is waited for this long per
--                      visit instead of forfeiting the visit after 20 s.
--   attempts:          requests per visit; one cancelled because a companion
--                      took over is retried in the same visit (SRV-2).
--   looter_quiet:      a loaded Looter must stay idle this long before a
--                      Whisper walk starts (L7: approach_stall retries leave
--                      short idle gaps between pickups).
--   unoffered:         WarPug is held for the Whisper check only while the
--                      orchestrator offers the slot at least this often.
--   traffic_looter:    continuous Looter activity holds WarPigs' town
--                      traffic at most this long (logged once).
local LIMIT = {alfred_unreadable = 10, wait_unknown = 20, wait_live = 120, attempts = 3,
    looter_quiet = 4, unoffered = 60, traffic_looter = 120}
local function call(object, name, ...)
    if type(object) ~= 'table' or type(object[name]) ~= 'function' then return nil end
    local ok, result = pcall(object[name], ...)
    if ok then return result end
end
local function log(message)
    if console and console.print then console.print('[WarPigs:Whispers] ' .. message) end
end
local function location()
    local ok, zone, world, town = pcall(function()
        local p, w = get_local_player(), get_current_world()
        if not p or not w or p:is_dead() then return nil end
        local z, n = w:get_current_zone_name(), w:get_name()
        local t = p:get_attribute((attributes and attributes.PLAYER_IN_TOWN_LEVEL_AREA) or 'Player_In_Town_Level_Area')
        return z, n, t
    end)
    if not ok or type(zone) ~= 'string' or zone == '' or zone == '[sno none]'
        or type(world) ~= 'string' or world == ''
        or world:lower():find('limbo', 1, true) or world:lower():find('loading', 1, true) then return nil end
    if zone == TEMIS and town ~= 1 then return nil end
    return zone
end

-- Prefer observed modern exports to the legacy flag, which can remain sticky.
function M.looter_state()
    local p = _G.LooteerPlugin
    if not p then return false, 'not_loaded' end
    if type(p) ~= 'table' then return nil, 'unavailable' end
    local enabled
    if type(p.get_enabled) == 'function' then
        local ok
        ok, enabled = pcall(p.get_enabled)
        if not ok or type(enabled) ~= 'boolean' then return nil, 'enabled_unavailable' end
        if enabled == false then return false, 'disabled' end
    end
    local modern_unknown = false
    if type(p.is_actively_looting) == 'function' then
        local active = call(p, 'is_actively_looting')
        if type(active) == 'boolean' then return active, 'is_actively_looting' end
        modern_unknown = true
    end
    if type(p.is_idle) == 'function' then
        local idle = call(p, 'is_idle')
        if type(idle) == 'boolean' then return not idle, 'is_idle' end
        modern_unknown = true
    end
    -- An explicit second modern status can resolve the first, but legacy
    -- nil/false cannot turn an unreadable modern owner into idle permission.
    if modern_unknown then return nil, 'activity_unavailable' end
    if type(p.getSettings) == 'function' then
        local ok_enabled, legacy_enabled = pcall(p.getSettings, 'enabled')
        local ok_looting, looting = pcall(p.getSettings, 'looting')
        if not ok_enabled then return nil, 'enabled_unavailable' end
        if legacy_enabled ~= nil and type(legacy_enabled) ~= 'boolean' then return nil, 'enabled_unavailable' end
        -- The supplied legacy getter returns nil for stored false. Distinguish
        -- that successful nil from an unavailable/throwing API.
        if ok_enabled and (legacy_enabled == false or legacy_enabled == nil) and enabled ~= true then
            return false, 'legacy_disabled'
        end
        if ok_looting and (type(looting) == 'boolean' or looting == nil) then
            return looting == true, 'getSettings.looting'
        end
    end
    return nil, 'unavailable'
end

-- C1 canonical Alfred live-work predicate (copied verbatim across the suite).
-- A teleport latched after a finished/failed trip is not live work.
local function alfred_live_work(s)
    return s.trigger_tasks == true or s.external_trigger == true or s.pending == true or s.running == true
        or (s.teleport == true and s.teleport_done ~= true and s.teleport_failed ~= true)
end

-- Observable companion work: worth waiting for (wait_live) and, when it
-- cancels a running request, worth a retry within the visit.
local function live_reason(reason)
    return reason == 'alfred_busy' or reason == 'alfred_work_pending' or reason == 'war_pug_busy'
        or reason == 'looter_settling' or reason == 'silent_raven_busy'
        or (type(reason) == 'string' and reason:find('looter_busy', 1, true) == 1)
end
local function companion_reason(reason)
    return live_reason(reason)
        or (type(reason) == 'string' and reason:find('_status_unavailable', 1, true) ~= nil)
end

-- `gate` keeps the per-bridge unreadable-Alfred timer (C1).
local function companions_clear(advisory_idle, admitted_alfred, gate)
    local advisory_alfred
    if location() ~= TEMIS then return false, 'not_in_temis' end
    local p = _G.AlfredTheButlerPlugin or _G.PLUGIN_alfred_the_butler
    if p then
        local s = call(p, 'get_status')
        local now = get_time_since_inject()
        if type(s) ~= 'table' or type(s.enabled) ~= 'boolean' then
            gate.alfred_unreadable_since = gate.alfred_unreadable_since or now
            if now - gate.alfred_unreadable_since < LIMIT.alfred_unreadable then
                return false, 'alfred_status_unavailable'
            end
            if not gate.alfred_unreadable_logged then
                gate.alfred_unreadable_logged = true
                log(string.format('Alfred status unreadable for %.0fs — treating Alfred as unavailable',
                    now - gate.alfred_unreadable_since))
            end
        elseif s.enabled == true then
            gate.alfred_unreadable_since, gate.alfred_unreadable_logged = nil, false
            if alfred_live_work(s) then return false, 'alfred_busy' end
            if s.inventory_full == true or s.need_repair == true then return false, 'alfred_work_pending' end
            -- need_trigger alone is advisory. A paused Alfred without hard or
            -- live work is idle for us (WarPigs never owns an Alfred pause).
            if s.need_trigger == true then
                if p ~= admitted_alfred and s.paused ~= true then
                    local ok, idle = false, false
                    if type(advisory_idle) == 'function' then ok, idle = pcall(advisory_idle) end
                    if not (ok and idle == true) then return false, 'alfred_work_pending' end
                end
                advisory_alfred = p
            end
        else
            -- enabled == false: nothing to wait on (C1 checks it first).
            gate.alfred_unreadable_since, gate.alfred_unreadable_logged = nil, false
        end
    end
    local looting, source = M.looter_state()
    if looting == nil then return false, 'looter_status_unavailable' end
    if looting then return false, 'looter_busy:' .. source end
    local creator = _G.WarPugPlugin
    if creator then
        local s = call(creator, 'status')
        if type(s) ~= 'table' then return false, 'war_pug_status_unavailable' end
        if s.enabled == true and s.state ~= 'IDLE' and s.state ~= 'HALTED' then
            return false, 'war_pug_busy'
        end
    end
    return true, nil, advisory_alfred
end

function M.new(options)
    options = options or {}
    local self = {enabled = false, serial = 0, generation = 0, attempts = 0}
    local function clear_companions()
        -- Completed Alfred cycles may retain an advisory need_trigger flag.
        -- The short admission grace must not expire halfway through our 60s
        -- request. Preserve only the already admitted flag on the same API
        -- object; every live-work flag above still revokes the request.
        local admission_check = not self.running and options.alfred_idle or nil
        local clear, reason, advisory_alfred = companions_clear(admission_check, self.advisory_alfred, self)
        -- Once the admitted advisory flag clears, a later flag is new work.
        if self.running and not advisory_alfred then self.advisory_alfred = nil end
        return clear, reason, advisory_alfred
    end
    local function status(p) return call(p, 'get_status') end
    local function active(s) return type(s) == 'table' and (s.running == true or s.pending == true) end
    local function note(reason)
        if self.reason ~= reason then self.reason = reason; log(reason) end
    end
    -- C6: each distinct wait reason is logged once per visit (a flapping
    -- Looter must not spam the log).
    local function wait_note(reason)
        local key = tostring(reason):gsub(':.*', '')
        self.wait_logged = self.wait_logged or {}
        if self.wait_logged[key] then self.reason = 'waiting: ' .. tostring(reason); return end
        self.wait_logged[key] = true
        note('waiting: ' .. tostring(reason))
    end
    -- L7: a loaded, enabled Looter must have been idle for looter_quiet
    -- continuous seconds. Read-only: the Looter is never mutated.
    local function looter_quiet(now)
        local looting, source = M.looter_state()
        if looting == false and (source == 'not_loaded' or source == 'disabled' or source == 'legacy_disabled') then
            self.quiet_since = nil
            return true
        end
        if looting ~= false or (self.quiet_seen and now - self.quiet_seen > 2) then self.quiet_since = nil end
        self.quiet_seen = now
        if looting ~= false then return false end
        self.quiet_since = self.quiet_since or now
        return now - self.quiet_since >= LIMIT.looter_quiet
    end
    local function new_visit(now)
        self.checked, self.wait_spent, self.unknown_spent, self.wait_reason, self.waiting_at = false, 0, 0, nil, nil
        self.attempts, self.wait_logged, self.quiet_since = 0, {}, nil
        self.visit_at, self.offered_at, self.unoffered_logged = now, nil, false
    end
    -- `detail` is SilentRaven's last_reason for a result it reported itself.
    local function finish(result, detail)
        self.running, self.last_result = false, result
        self.started = nil
        self.advisory_alfred = nil
        self.generation = self.generation + 1
        -- SRV-2: a request cancelled because a companion took over (our own
        -- revocation, or SilentRaven's guard reporting it) is retried in this
        -- visit once companions are clear, at most LIMIT.attempts requests.
        local cause = result == 'cancelled' and detail or result
        if self.enabled and companion_reason(cause) and (self.attempts or 0) < LIMIT.attempts
            and location() == TEMIS then
            self.checked, self.quiet_since, self.unknown_spent = false, nil, 0
            note(string.format('visit %s: %s (%s) — retrying when companions are clear (request %d/%d)',
                tostring(self.serial), tostring(result), tostring(cause), self.attempts, LIMIT.attempts))
            return
        end
        self.checked, self.unknown_spent, self.wait_reason, self.waiting_at = true, 0, nil, nil
        note('visit ' .. tostring(self.serial) .. ': ' .. tostring(result))
    end
    function self:cancel(reason)
        if self.running and self.plugin then
            local clear = clear_companions()
            call(self.plugin, 'cancel', OWNER, not clear)
            local s = status(self.plugin)
            if type(s) ~= 'table' or (active(s) and s.owner == OWNER) then
                note('waiting for SilentRaven cancellation confirmation')
                return false
            end
            finish(reason or 'cancelled')
        end
        return true
    end
    function self:release()
        self.enabled = false -- revoke the continuation guard even if cancel throws
        if not self:cancel('stopped') then return false end
        if self.plugin then
            local s = status(self.plugin)
            if type(s) ~= 'table' then
                note('waiting for SilentRaven management release confirmation')
                return false
            end
            if type(s) == 'table' and s.managed_by == OWNER then
                if call(self.plugin, 'set_managed', OWNER, false) ~= true then return false end
            end
        end
        self.plugin, self.enabled, self.pending_since = nil, false, nil
        self.last_zone, self.candidate, self.candidate_since = nil, nil, nil
        self.checked, self.wait_spent, self.unknown_spent, self.wait_reason, self.waiting_at = nil, 0, 0, nil, nil
        self.visit_at, self.offered_at = nil, nil
        return true
    end
    -- Called even when quests are unreadable; it suppresses SR autonomous runs.
    function self:observe(now, enabled)
        if not enabled then return self:release() end
        self.enabled = true
        local p = _G.SilentRavenPlugin or _G.PLUGIN_silent_raven
        if self.plugin and self.plugin ~= p then
            if not self:release() then return false end
            self.enabled = true
        end
        local s = status(p)
        if type(s) == 'table' and (s.api_version or 0) >= 2 then
            if s.managed_by == OWNER or call(p, 'set_managed', OWNER, true) == true then self.plugin = p end
        end
        local zone = location()
        if not zone then self.candidate, self.candidate_since = nil, nil; return true end
        if zone ~= self.candidate then self.candidate, self.candidate_since = zone, now end
        if now - self.candidate_since < 1 then return true end
        if zone ~= self.last_zone then
            if zone == TEMIS then
                self.serial = self.serial + 1
                new_visit(now)
            else
                self:cancel('left_temis')
                self.checked, self.wait_spent, self.unknown_spent, self.wait_reason, self.waiting_at = nil, 0, 0, nil, nil
                self.visit_at, self.offered_at = nil, nil
            end
            self.last_zone = zone
        end
        -- L7: sample the Looter every pulse in Temis, so a Looter that has
        -- been quiet all along adds no delay once the slot opens.
        if zone == TEMIS then looter_quiet(now) end
        return true
    end
    -- Hold all new WarPigs town navigation while a public Looter export says busy.
    -- An unknown Looter blocks only the new Whisper attempt, not existing features.
    -- C6: continuous Looter activity holds town traffic for at most
    -- LIMIT.traffic_looter seconds, then WarPigs resumes (logged once).
    function self:traffic_hold()
        if location() ~= TEMIS then
            self.looter_hold_since, self.looter_hold_logged = nil, false
            return nil
        end
        local looting, source = M.looter_state()
        if looting == true then
            self.quiet_since = nil
            local now = get_time_since_inject()
            if self.looter_hold_at and now - self.looter_hold_at > 2 then
                self.looter_hold_since, self.looter_hold_logged = nil, false
            end
            self.looter_hold_at = now
            self.looter_hold_since = self.looter_hold_since or now
            if now - self.looter_hold_since < LIMIT.traffic_looter then
                return 'Looter collecting town loot (' .. source .. ')'
            end
            if not self.looter_hold_logged then
                self.looter_hold_logged = true
                log(string.format('Looter has reported busy for %.0fs — no longer holding WarPigs town movement for it',
                    now - self.looter_hold_since))
            end
        else
            self.looter_hold_since, self.looter_hold_logged = nil, false
        end
        local p = _G.SilentRavenPlugin or _G.PLUGIN_silent_raven
        local s = status(p)
        if active(s) then return 'SilentRaven has a queued or active reward task' end
        if self.running then return 'waiting for SilentRaven result' end
        return nil
    end
    function self:tick(now, safe_to_start)
        if self.running then
            local s = status(self.plugin)
            local clear, reason = clear_companions()
            if not self.enabled or not clear or now - self.started >= 60 then
                self:cancel(reason or 'timeout')
                return self.running == true
            end
            if type(s) ~= 'table' then note('SilentRaven status unavailable during owned request'); return true end
            if not active(s) then
                finish(self.callback_result or s.last_result or 'unconfirmed', s.last_reason)
                return false
            end
            if s.owner ~= OWNER then finish('ownership_changed'); return true end
            return true
        end
        if not self.enabled or not safe_to_start or location() ~= TEMIS then return false end
        self.offered_at = now
        local s = status(self.plugin)
        if type(s) ~= 'table' or s.enabled ~= true or (s.api_version or 0) < 2 then
            note('SilentRaven unavailable/disabled; Whisper step skipped')
            return false
        end
        if self.last_zone ~= TEMIS or self.candidate ~= TEMIS then return true end
        if self.checked then return false end
        local clear, reason, advisory_alfred
        if active(s) then
            clear, reason = false, 'silent_raven_busy'
        elseif s.managed_by ~= OWNER then
            clear, reason = false, 'silent_raven_not_managed'
        else
            local quiet = looter_quiet(now)
            clear, reason, advisory_alfred = clear_companions()
            if clear and not quiet then clear, reason = false, 'looter_settling' end
        end
        if not clear then
            -- SRV-2: observable companion work (an Alfred cycle WarPigs may
            -- just have kicked, a Looter pickup) is waited for up to
            -- LIMIT.wait_live per visit; only unknown data gives up early.
            -- Budgets count only time spent actually holding the orchestrator
            -- (consecutive waiting pulses), not time the slot was closed.
            local step = (self.waiting_at and now - self.waiting_at <= 2) and (now - self.waiting_at) or 0
            self.wait_spent = (self.wait_spent or 0) + step
            if live_reason(reason) then self.unknown_spent = 0 else self.unknown_spent = (self.unknown_spent or 0) + step end
            if self.wait_spent >= LIMIT.wait_live or self.unknown_spent >= LIMIT.wait_unknown then
                finish('skipped:' .. tostring(reason)); return false
            end
            self.wait_reason, self.waiting_at = reason, now
            wait_note(reason)
            return true
        end
        self.wait_reason, self.unknown_spent, self.waiting_at = nil, 0, nil
        self.generation = self.generation + 1
        local generation = self.generation
        self.advisory_alfred = advisory_alfred
        self.running, self.started, self.callback_result = true, now, nil
        self.attempts = (self.attempts or 0) + 1
        local function guard()
            if generation ~= self.generation or not self.enabled then return false, 'request_revoked' end
            return clear_companions()
        end
        local function completed(result)
            if generation == self.generation and self.running then self.callback_result = result end
        end
        local accepted = call(self.plugin, 'trigger_tasks', OWNER, completed, guard)
        if accepted ~= true then
            local after = status(self.plugin)
            -- A throwing call may have queued the request. Never submit twice.
            if type(after) ~= 'table' or (active(after) and after.owner == OWNER) then
                note('trigger response ambiguous; waiting for owned request'); return true
            end
            finish('trigger_rejected'); return active(after)
        end
        note('checking completed Whispers in Temis')
        return true
    end
    function self:is_busy() return self.running == true end
    function self:blocks_plan_creator()
        if self.running then return true end
        if not self.enabled or self.checked or location() ~= TEMIS then return false end
        local s = status(self.plugin)
        if type(s) ~= 'table' or s.enabled ~= true then return false end
        local creator = _G.WarPugPlugin
        if creator then
            local c = call(creator, 'status')
            -- Do not invalidate an already active planner transaction.
            if type(c) ~= 'table' or (c.enabled == true and c.state ~= 'IDLE' and c.state ~= 'HALTED') then
                return false
            end
        end
        -- WPT-2 / C6: hold the plan creator only while the orchestrator
        -- actually offers the Whisper slot. A slot that stays closed (for any
        -- reason) must not starve WarPug: after LIMIT.unoffered it plans.
        local since = self.offered_at or self.visit_at
        local now = get_time_since_inject()
        if since and now - since >= LIMIT.unoffered then
            if not self.unoffered_logged then
                self.unoffered_logged = true
                log(string.format('Whisper check not admitted for %.0fs — no longer holding WarPug for it', now - since))
            end
            return false
        end
        return true
    end
    function self:status_line()
        if self.running then return 'WarPigs: SilentRaven reward check' end
        -- C6: an admission wait is visible while it lasts.
        local now = get_time_since_inject()
        if self.wait_reason and self.waiting_at and now - self.waiting_at < 2 then
            return string.format('WarPigs: Whisper check waiting for %s (%.0fs)',
                tostring(self.wait_reason), self.wait_spent or 0)
        end
        return nil
    end
    return self
end
return M
