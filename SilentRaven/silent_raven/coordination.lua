-- Read the controller's published reservation before its first update pulse.
-- This closes the startup race where SilentRaven auto-fired before WarPigs
-- could acquire the explicit managed lease. Existing running owners retain
-- their request; WarPigs joins only after that request has completed.
--
-- companions(mode) is SilentRaven's own admission for runs it starts itself
-- (auto-fire, the manual keybind) and its mid-run yield. External callers
-- queue through can_start only: they own their admission (the WarPigs bridge
-- has its own companion checks, and an Alfred-style caller may still report
-- itself busy while it waits for our callback).
-- Status APIs are read through the exported globals only; no module of
-- another plugin is required from here.
local log = require 'silent_raven.log'
local M = {}

-- Unreadable companion status: busy for at most UNKNOWN_LIMIT seconds, then
-- treated as unavailable (not busy) with one log line.
-- Alfred inventory_full/need_repair holds a NEW auto-fire for at most
-- HARD_NEED_LIMIT seconds; Alfred normally starts its own trip well before.
local UNKNOWN_LIMIT, HARD_NEED_LIMIT = 10, 60
local gate = {}

local function clock() return (get_time_since_inject and get_time_since_inject()) or 0 end

local function read(object, name)
    if type(object) ~= 'table' or type(object[name]) ~= 'function' then return false, nil end
    return pcall(object[name])
end

-- Seconds a condition has held. Readers only sample while they would act,
-- so a sampling gap longer than 2 s starts a new episode.
local function elapsed(key, now)
    local seen = gate[key .. '_seen']
    if not gate[key] or not seen or now < seen or now - seen > 2 then gate[key] = now end
    gate[key .. '_seen'] = now
    return now - gate[key]
end
local function unknown(key, now, label)
    if elapsed(key, now) < UNKNOWN_LIMIT then return true end
    if not gate[key .. '_logged'] then
        gate[key .. '_logged'] = true
        log.info(string.format('%s status unreadable for %ds; treating %s as unavailable', label, UNKNOWN_LIMIT, label))
    end
    return false
end
local function known(key) gate[key], gate[key .. '_seen'], gate[key .. '_logged'] = nil, nil, nil end

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

-- Suite-wide Alfred "live work" reading (contract C1). A teleport flag left
-- latched after a finished or failed trip is not live work.
local function alfred_live_work(s)
    return s.trigger_tasks == true or s.external_trigger == true or s.pending == true or s.running == true
        or (s.teleport == true and s.teleport_done ~= true and s.teleport_failed ~= true)
end
M.alfred_live_work = alfred_live_work

-- Returns a hold reason or nil. live_only (mid-run yield, manual keybind)
-- ignores the hard-need hold. need_trigger alone, restock/stash advisories
-- and a pause SilentRaven does not own are idle: we never trigger Alfred.
local function alfred_reason(now, live_only)
    local p = _G.AlfredTheButlerPlugin or _G.PLUGIN_alfred_the_butler
    if p == nil then known('alfred'); known('hard'); return nil end
    local ok, s = read(p, 'get_status')
    if not ok or type(s) ~= 'table' or type(s.enabled) ~= 'boolean' then
        return unknown('alfred', now, 'Alfred') and 'alfred_status_unavailable' or nil
    end
    known('alfred')
    if s.enabled == false then known('hard'); return nil end
    if alfred_live_work(s) then known('hard'); return 'alfred_busy' end
    if live_only then return nil end
    if s.inventory_full == true or s.need_repair == true then
        if elapsed('hard', now) < HARD_NEED_LIMIT then return 'alfred_work_pending' end
        if not gate.hard_logged then
            gate.hard_logged = true
            log.info(string.format('Alfred reports inventory_full/need_repair for %ds without starting a trip; auto-fire proceeds',
                HARD_NEED_LIMIT))
        end
        return nil
    end
    known('hard')
    return nil
end

-- Mirrors the WarPigs bridge reading: modern exports first; a legacy flag
-- cannot turn an unreadable modern owner into idle permission.
-- Returns true (busy) / false (idle) / nil (unknown), plus the source.
local function looter_state()
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
        local ok, active = pcall(p.is_actively_looting)
        if ok and type(active) == 'boolean' then return active, 'is_actively_looting' end
        modern_unknown = true
    end
    if type(p.is_idle) == 'function' then
        local ok, idle = pcall(p.is_idle)
        if ok and type(idle) == 'boolean' then return not idle, 'is_idle' end
        modern_unknown = true
    end
    if modern_unknown then return nil, 'activity_unavailable' end
    if type(p.getSettings) == 'function' then
        local ok_enabled, legacy_enabled = pcall(p.getSettings, 'enabled')
        local ok_looting, looting = pcall(p.getSettings, 'looting')
        if not ok_enabled then return nil, 'enabled_unavailable' end
        if legacy_enabled ~= nil and type(legacy_enabled) ~= 'boolean' then return nil, 'enabled_unavailable' end
        -- The legacy getter returns nil for stored false.
        if (legacy_enabled == false or legacy_enabled == nil) and enabled ~= true then
            return false, 'legacy_disabled'
        end
        if ok_looting and (type(looting) == 'boolean' or looting == nil) then
            return looting == true, 'getSettings.looting'
        end
    end
    return nil, 'unavailable'
end
M.looter_state = looter_state

local function looter_reason(now)
    local active, source = looter_state()
    if active == nil then
        return unknown('looter', now, 'Looter') and ('looter_status_unavailable:' .. tostring(source)) or nil
    end
    known('looter')
    if active then return 'looter_busy:' .. tostring(source) end
    return nil
end

-- WarPug mid-session (table approach, path search, rerolls, confirmation)
-- treats a SilentRaven run as a takeover. IDLE, HALTED and DONE_WAIT (plan
-- submitted, no movement or clicks) are safe to start from.
local WAR_PUG_IDLE = { IDLE = true, HALTED = true, DONE_WAIT = true }
local function war_pug_reason(now)
    local p = _G.WarPugPlugin
    if p == nil then known('war_pug'); return nil end
    local ok, s = read(p, 'status')
    if not ok or type(s) ~= 'table' then
        return unknown('war_pug', now, 'WarPug') and 'war_pug_status_unavailable' or nil
    end
    known('war_pug')
    if s.enabled == true and not WAR_PUG_IDLE[tostring(s.state)] then return 'war_pug_busy' end
    return nil
end

-- An enabled WarPigs that does not manage Whispers can still own town:
-- transitions, activity start/cleanup and turn-ins report busy.
local function war_pigs_reason()
    local ok, s = read(_G.WarPigsPlugin, 'status')
    if ok and type(s) == 'table' and s.enabled == true and s.busy == true then return 'war_pigs_busy' end
    return nil
end

-- mode 'auto'   : new auto-fire (WarPigs, WarPug, Alfred incl. hard need, Looter)
-- mode 'manual' : explicit keybind (WarPug, Alfred live work, Looter)
-- mode 'run'    : mid-run yield of our own run (Alfred live work, Looter)
-- Returns true, or false plus the hold reason.
function M.companions(mode, now)
    now = now or clock()
    local reason
    if mode == 'auto' then reason = war_pigs_reason() end
    if not reason and mode ~= 'run' then reason = war_pug_reason(now) end
    reason = reason or alfred_reason(now, mode ~= 'auto') or looter_reason(now)
    if reason then return false, reason end
    return true
end

return M
