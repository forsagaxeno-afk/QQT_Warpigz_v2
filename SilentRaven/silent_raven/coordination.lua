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
local tracker = require 'silent_raven.tracker'
local whispers = require 'silent_raven.whispers' -- QQT_Warpigz_v3 0.2.8
local M = {}

-- QQT_Warpigz_v3 0.2.8 ("SilentRaven is manual now"): every third-party hold
-- is bounded per ready episode (tracker.ready_since, set by main.refresh_ready;
-- a first-seen clock, so sampling gaps never restart it).
-- ACTIVITY_DEFER_S: a loop owning the run (TristramLoop) holds auto-fire at a
--   Temis stop until the reward has been ready this long (Rosie DEFER_TOWN).
-- ACTIVITY_TRIP_S: the claim trip waits for it at most this long (DEFER_ANY).
-- THIRD_HOLD_S: Butler / Scavenger / a town-priority Navigator walk hold at
--   most this long (WarPug HOLD, WarPigs THIRD_PARTY).
-- NAV_TOWN_PRIORITY: a Navigator request below it (Worldstone's walk sends
--   none: 0) never holds; our pause condition stops it once the claim runs.
-- CHANNEL_CAP_S: a teleport channel (spell 186139) holds a new walk or trip
--   at most this long.
M.ACTIVITY_DEFER_S, M.ACTIVITY_TRIP_S, M.THIRD_HOLD_S, M.NAV_TOWN_PRIORITY, M.CHANNEL_CAP_S = 60, 600, 180, 10, 15
local TELEPORT_SPELL_ID = 186139

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

-- QQT_Warpigz_v3 (Q8): the town-service provider (Rosie behind the Alfred
-- exports) and its readable status, or nil. Rosie publishes the caller name
-- of its return-leg hand-off as status.raven_handoff (its adapters report
-- name = 'Rosie', the hand-off queues as its town label).
function M.town_provider()
    local p = _G.AlfredTheButlerPlugin or _G.PLUGIN_alfred_the_butler
    local ok, s = read(p, 'get_status')
    if ok and type(s) == 'table' then return p, s end
    return p, nil
end
local function town_caller(caller)
    local _, s = M.town_provider()
    return type(caller) == 'string' and s ~= nil and s.raven_handoff == caller
end

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
        -- QQT_Warpigz_v3 (Q8): WarPigs offers its own Whisper slot only
        -- between activities, so a whole Helltide night claimed nothing.
        -- While it delegates (status.whisper_handoff), the town service's
        -- return-leg hand-off (Rosie in Temis) may claim.
        if status.whisper_handoff == true and town_caller(caller) then return true end
        return false, 'reserved_by_war_pigs'
    end
    return true
end

-- QQT_Warpigz_v3 (Q8): WarPigs' delegation, cached from SilentRaven's own
-- pulse. get_status() reads only the cache: WarPigs' status() reads ours.
local delegation = {value = false, t = -math.huge, activity = false}
function M.refresh_delegation(now)
    if now >= delegation.t and now - delegation.t < 0.5 then return delegation.value end
    delegation.t = now
    local ok, s = read(_G.WarPigsPlugin, 'status')
    delegation.value = ok and type(s) == 'table' and s.manages_whispers == true and s.whisper_handoff == true
    -- QQT_Warpigz_v3 (Q8): an activity WarPigs runs keeps its own Whisper
    -- slot closed; a Temis stop of it (Arkham at the Pit obelisk, an activity's
    -- own bag trip) is claimed by SilentRaven itself (temis_delegated).
    delegation.activity = delegation.value and s.activity_on == true
    return delegation.value
end
-- QQT_Warpigz_v3 (Q8): SilentRaven may start its own claim in Temis while
-- WarPigs manages Whispers: WarPigs delegates and runs an activity (its own
-- Whisper visit only happens between activities).
function M.temis_delegated()
    return tracker.managed_by == 'WarPigs' and delegation.value == true and delegation.activity == true
end
-- A managed request from someone else than the manager: only the town
-- service's hand-off while WarPigs delegates (fresh read; can_start agrees).
function M.delegated(caller)
    if tracker.managed_by ~= 'WarPigs' or not town_caller(caller) then return false end
    local ok, s = read(_G.WarPigsPlugin, 'status')
    return ok and type(s) == 'table' and s.whisper_handoff == true
end
-- Whether SilentRaven takes a town trip's hand-off now, plus why not:
-- standalone its auto-fire setting, managed WarPigs' delegation.
function M.handoff_ok(settings)
    if settings.enabled ~= true then return false, 'SilentRaven is disabled' end
    if tracker.managed_by == nil then
        if settings.auto_fire == true then return true end
        return false, 'SilentRaven auto-fire is off'
    end
    if tracker.managed_by == 'WarPigs' and delegation.value then return true end
    return false, 'WarPigs manages Whispers and does not delegate right now (its own Temis check or teleport is under way)'
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
    -- QQT_Warpigz_v3: the Alfred/Rosie trip that queued the current request
    -- (Rosie's return-leg hand-off) waits for it: its live work is ours.
    if (tracker.running or tracker.external_trigger) and tracker.external_caller ~= nil
        and (tracker.external_caller == s.name or tracker.external_caller == s.raven_handoff) then -- QQT_Warpigz_v3 (Q8)
        known('hard'); return nil
    end
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

-- QQT_Warpigz_v3 3.3.3: a third-party loop (TristramLoop, driven by
-- Worldstone) that owns the run, as Rosie reads it (it defers its own
-- automatic trip for it). Returns its label or nil. A run of ours never starts
-- over it: the reward stays ready for a later Temis visit or a Rosie trip.
function M.activity_owner()
    local peer = rawget(_G, 'TRISTRAM_LOOP_STATE')
    if type(peer) ~= 'table' or type(peer.status) ~= 'function' then return nil end
    local ok, st = pcall(peer.status)
    if ok and type(st) == 'table' and st.running and st.owns_activity then
        return 'TristramLoop' .. (type(st.phase) == 'string' and (', ' .. st.phase) or '')
    end
    return nil
end

-- QQT_Warpigz_v3 3.3.3: third-party movers and town services (closed
-- .pak addons; docs/THIRD_PARTY_APIS.md). Every call is guarded and pcall'd.
-- Butler.is_busy(): its town trip walks Temis through Navigator (priority 10).
-- Scavenger.is_busy(): Navigator's looter owns the drops.
-- Navigator.get_status(): busy and not paused for another owner (Worldstone
-- walking to its portal, Butler's in-town walk). A paused Navigator (our own
-- pause condition during a claim, Worldstone's looting pause) moves nobody.
-- Returns a hold reason or nil.
local function third_call(name, fn)
    local obj = rawget(_G, name)
    if type(obj) ~= 'table' or type(obj[fn]) ~= 'function' then return nil end
    local ok, v = pcall(obj[fn])
    if ok then return v end
    return nil
end
-- Seconds the ready episode has lasted (0 when nothing is ready).
local function ready_for(now)
    local since = tracker.ready_since
    if type(since) ~= 'number' or now < since then return 0 end
    return now - since
end
M.ready_for = ready_for
-- One info line per key and ready episode.
local said = {ep = nil, keys = {}}
local function say_once(key, message)
    if said.ep ~= tracker.ready_since then said.ep, said.keys = tracker.ready_since, {} end
    if said.keys[key] then return end
    said.keys[key] = true
    log.info(message)
end
M.say_once = say_once
-- QQT_Warpigz_v3 0.2.8 (RC2): the first time each third-party hold was seen in
-- this ready episode; past THIRD_HOLD_S it no longer holds (one line).
local third = {ep = nil, first = {}}
local function bounded(kind, reason, now)
    if third.ep ~= tracker.ready_since then third.ep, third.first = tracker.ready_since, {} end
    third.first[kind] = third.first[kind] or now
    if now - third.first[kind] < M.THIRD_HOLD_S then return reason end
    say_once('third:' .. kind, string.format('waited %ds for %s this ready episode; no longer holding for it',
        M.THIRD_HOLD_S, reason))
    return nil
end
function M.third_party_reason(now)
    now = now or clock()
    if third_call('Butler', 'is_busy') == true then
        local r = bounded('butler', 'butler_busy', now)
        if r then return r end
    end
    -- QQT_Warpigz_v3 0.2.7: Rosie's Scavenger stand-in (`_rosie=true`) is
    -- Rosie's pickup, already held through the Looter; skip it.
    local scavenger = rawget(_G, 'Scavenger')
    if not (type(scavenger) == 'table' and rawget(scavenger, '_rosie') == true)
        and third_call('Scavenger', 'is_busy') == true then
        local r = bounded('scavenger', 'scavenger_busy', now)
        if r then return r end
    end
    local st = third_call('Navigator', 'get_status')
    if type(st) == 'table' and st.is_busy == true and st.is_paused ~= true and st.owner ~= 'SilentRaven'
        and (tonumber(st.priority) or 0) >= M.NAV_TOWN_PRIORITY then -- QQT_Warpigz_v3 0.2.8 (RC2)
        local r = bounded('navigator', 'navigator_busy:' .. tostring(st.owner or '?'), now)
        if r then return r end
    end
    return nil
end
-- QQT_Warpigz_v3 0.2.8: the player channels a teleport (a WonderCity / Rosie /
-- War Plan cast: a claim walk or a claim trip would cut it). Bounded per cast.
local channel = {since = nil}
function M.teleport_channel(now)
    now = now or clock()
    local ok, player = false, nil
    if type(get_local_player) == 'function' then ok, player = pcall(get_local_player) end
    local casting = ok and player ~= nil and whispers.safe_method(player, 'get_active_spell_id') == TELEPORT_SPELL_ID
    if not casting then channel.since = nil; return false end
    channel.since = channel.since or now
    return now - channel.since < M.CHANNEL_CAP_S
end
-- QQT_Warpigz_v3 0.2.8 (RC1): a loop owning the run holds a new auto-fire,
-- except at a Temis stop once the reward has been ready ACTIVITY_DEFER_S.
function M.activity_hold(now)
    local owner = M.activity_owner()
    if not owner then return nil end
    if whispers.in_whisper_town() and ready_for(now) >= M.ACTIVITY_DEFER_S then
        say_once('activity_defer', string.format('auto-fire waited %ds for %s; claiming at this Temis stop',
            M.ACTIVITY_DEFER_S, owner))
        return nil
    end
    return 'activity_owner:' .. owner
end
-- Navigator pause condition 'SilentRaven': Navigator stands still while a
-- claim of ours runs (not while it yields: Butler walks through Navigator).
-- Registered once per Navigator table (it loads after SilentRaven).
local nav_registered = nil
function M.register_navigator()
    local nav = rawget(_G, 'Navigator')
    if type(nav) ~= 'table' or nav_registered == nav or type(nav.set_pause_condition) ~= 'function' then return end
    nav_registered = nav
    -- QQT_Warpigz_v3 0.2.8 (RC3): Navigator stays held during a yield too,
    -- except one for a town service that walks through Navigator (Butler, a
    -- town-priority Navigator walk); releasing it for a Looter blip let the
    -- loop's walk resume and hold the yield until its 120 s timeout.
    pcall(nav.set_pause_condition, 'SilentRaven', function()
        if tracker.running ~= true then return false end
        if tracker.yield_since == nil then return true end
        local why = tostring(tracker.yield_reason)
        return not (why == 'butler_busy' or why:find('^navigator_busy:') ~= nil)
    end)
end

-- mode 'auto'   : new auto-fire (WarPigs, a third-party loop, WarPug, Alfred incl. hard need, Looter)
-- mode 'delegated': a claim WarPigs delegates during its activity (as 'auto'
--                 without WarPigs, which owns no Temis movement then) -- QQT_Warpigz_v3 (Q8)
-- mode 'manual' : explicit keybind (WarPug, Alfred live work, Looter)
-- mode 'run'    : mid-run yield of our own run (Alfred live work, Looter)
-- Every mode also waits for Butler, Scavenger and a moving town-priority
-- Navigator (3.3.3; 0.2.8: priority >= 10, each at most 180 s per ready
-- episode); every mode but 'run' for a teleport channel (0.2.8, <= 15 s).
-- Returns true, or false plus the hold reason.
function M.companions(mode, now)
    now = now or clock()
    local reason
    if mode == 'auto' then reason = war_pigs_reason() end
    if not reason and (mode == 'auto' or mode == 'delegated') then -- QQT_Warpigz_v3 3.3.3 / 0.2.8 (RC1 bound)
        reason = M.activity_hold(now)
    end
    -- QQT_Warpigz_v3 0.2.8: never start a claim walk over a teleport channel.
    if not reason and mode ~= 'run' and M.teleport_channel(now) then reason = 'teleport_channel' end
    if not reason and mode ~= 'run' then reason = war_pug_reason(now) end
    reason = reason or alfred_reason(now, mode ~= 'auto' and mode ~= 'delegated') or looter_reason(now) -- QQT_Warpigz_v3 (Q8)
        or M.third_party_reason(now) -- QQT_Warpigz_v3 3.3.3: every mode (auto, delegated, manual, mid-run yield)
    if reason then return false, reason end
    return true
end

return M
