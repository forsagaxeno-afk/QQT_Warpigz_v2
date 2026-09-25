local settings = require 'core.settings'
local RavenBridge = require 'wp_silent_raven'

local orchestrator = {}
local function log(msg) console.print('[WarPigs] ' .. msg) end

-- ── transition sequencer ────────────────────────────────────────────────────
-- Goal: never have two activity plugins running at once and never start the
-- next plugin while the previous one is still wrapping up. Sequence per
-- handoff:
--   (1) Wait for outgoing plugin's disable_when() to return true
--       (e.g. Pit/WonderCity → back in town; Reaper → boss kill + 60s).
--   (2) Disable outgoing plugin.
--   (3) Wait TRANSITION_GAP_SECONDS for game state to settle.
--   (4) Enable incoming plugin.
-- MAX_DISABLE_DEFER_SECONDS controls stalled-cleanup diagnostics. A timer
-- cannot prove that loot or a dungeon RESET finished, so it never forces a
-- handoff while the outgoing activity still reports incomplete cleanup.
local TRANSITION_GAP_SECONDS    = 5
local MAX_DISABLE_DEFER_SECONDS = 120

-- Native QQT transition sequence. After the outgoing plugin finishes,
-- warplan.teleport_to_activity() navigates to the next activity. No desktop
-- keyboard or mouse events are synthesized. Allow the native channel to
-- finish before retrying, then confirm a loaded world/zone or destination.
local TELEPORT_CHECK_INTERVAL = 6.0

-- Let the next WarPlan appear in host quest data before native navigation.
local TELEPORT_INCOMING_SETTLE = 2.5

-- Set by on_alfred_cycle_complete (registered as the callback to
-- alfred.trigger_tasks). Used to detect "Steroid restock-stickiness":
-- Steroid recomputes tracker.need_trigger from
--   inventory_full or need_repair or restock_count > 0 or
--   need_stash_socketables or need_stash_consumables or need_stash_keys or
--   talisman_inventory_full
-- every 0.5s. If e.g. a configured restock item has no stash inventory to
-- pull from, restock_count stays > 0 forever — every Alfred cycle
-- completes without making progress and need_trigger flips back to true
-- on the next tracker pass. Without this guard, alfred_idle() returns
-- false forever, POST_ALFRED_SETTLE bounces back to TEMIS_ALFRED, and
-- the orchestrator loops re-triggering Alfred every ~20s (observed in
-- logzewx 1722 / 1749 / 1773 — three identical no-progress stash cycles).
local last_alfred_completion_at = nil
local last_alfred_completion_plugin = nil
local alfred_callback_generation = 0
local STUCK_NEED_TRIGGER_GRACE  = 20.0

-- C1: one Alfred reading for every WarPigs gate (alfred_idle, the kick,
-- alfred_trigger_now, the turn-in task and the Whisper bridge copy it).
-- Grouped in one table so orchestrator.tick() captures no extra upvalue.
--   * live work: trigger_tasks/external_trigger/pending/running, or a
--     teleport still in flight. A `teleport` latched after a finished or
--     failed trip (teleport_done/teleport_failed) is NOT live work (WPT-1).
--   * enabled == false: never busy. Unreadable status: busy for at most
--     UNREADABLE_HOLD, then "Alfred unavailable" (not busy), logged once.
--   * paused without hard need (inventory_full/need_repair) and without live
--     work: idle — WarPigs never owns an Alfred pause. Paused WITH hard work:
--     a bounded hold (PAUSED_WORK_HOLD), logged (WPT-5 / WPD-5).
--   * advisory need_trigger alone: idle within the completed-cycle grace, and
--     for the rest of the Temis visit once a WarPigs trigger (or a joined
--     cycle) had its chance (ADVISORY_SETTLE without live work). The kick
--     fires an advisory-only flag at most once per Temis visit (WPT-3).
local alfred_gate = {
    UNREADABLE_HOLD  = 10.0,
    PAUSED_WORK_HOLD = 180.0,  -- same cap as ALFRED_MAX_SECONDS
    ADVISORY_SETTLE  = 8.0,    -- same as ALFRED_PICKUP_TIMEOUT
    unreadable_since = nil, unreadable_logged = false,
    paused_since = nil, paused_logged = false,
    visit_trigger_at = nil, visit_alfred = nil,  -- WarPigs trigger in this Temis visit
    kick_deferred_logged = false,
}

-- C1 canonical live-work predicate (copied verbatim across the suite).
function alfred_gate.live(s)
    return s.trigger_tasks == true or s.external_trigger == true or s.pending == true or s.running == true
        or (s.teleport == true and s.teleport_done ~= true and s.teleport_failed ~= true)
end

-- Returns alfred, status. status is nil when Alfred is not loaded or its
-- status is unreadable (throws, non-table, non-boolean enabled); the third
-- result then says whether that still counts as busy.
function alfred_gate.read()
    local alfred = _G.AlfredTheButlerPlugin or _G.PLUGIN_alfred_the_butler
    if not alfred then return nil, nil, false end
    local G, now = alfred_gate, get_time_since_inject()
    local ok, s = false, nil
    if type(alfred) == 'table' and type(alfred.get_status) == 'function' then ok, s = pcall(alfred.get_status) end
    if ok and type(s) == 'table' and type(s.enabled) == 'boolean' then
        G.unreadable_since, G.unreadable_logged = nil, false
        return alfred, s, false
    end
    G.unreadable_since = G.unreadable_since or now
    if now - G.unreadable_since < G.UNREADABLE_HOLD then return alfred, nil, true end
    if not G.unreadable_logged then
        G.unreadable_logged = true
        log(string.format('Alfred unavailable — status unreadable for %.0fs; no longer holding for it',
            now - G.unreadable_since))
    end
    return alfred, nil, false
end

-- WPT-5: paused with hard work. True while the bounded hold still applies.
function alfred_gate.paused_work_hold(s)
    local G, now = alfred_gate, get_time_since_inject()
    if not G.paused_since then
        G.paused_since = now
        log(string.format('Alfred is paused by %s with pending work — holding for it up to %.0fs',
            tostring(s.paused_by or '?'), G.PAUSED_WORK_HOLD))
    end
    if now - G.paused_since < G.PAUSED_WORK_HOLD then return true end
    if not G.paused_logged then
        G.paused_logged = true
        log(string.format('Alfred still paused by %s with pending work after %.0fs — no longer holding for it (bounded hold)',
            tostring(s.paused_by or '?'), now - G.paused_since))
    end
    return false
end

-- A WarPigs trigger (kick, preamble or a joined live cycle) in this visit.
function alfred_gate.note_trigger(alfred)
    alfred_gate.visit_trigger_at, alfred_gate.visit_alfred = get_time_since_inject(), alfred
end

-- WPT-3 / WPG-4: WarPug is walking to the table, selecting, rerolling or
-- confirming. Unknown/unreadable status keeps the previous behavior.
function alfred_gate.plan_creator_active()
    local creator = _G.WarPugPlugin
    if type(creator) ~= 'table' or type(creator.status) ~= 'function' then return false end
    local ok, st = pcall(creator.status)
    if not ok or type(st) ~= 'table' or st.enabled ~= true or type(st.state) ~= 'string' then return false end
    return st.state ~= 'IDLE' and st.state ~= 'HALTED' and st.state ~= 'DONE_WAIT'
end

local function new_alfred_completion_callback(plugin)
    alfred_callback_generation = alfred_callback_generation + 1
    local generation = alfred_callback_generation
    return function(result)
        if generation ~= alfred_callback_generation then return end
        if (_G.AlfredTheButlerPlugin or _G.PLUGIN_alfred_the_butler) ~= plugin then return end
        if result == false or result == 'failed' or result == 'cancelled' then return end
        last_alfred_completion_at = get_time_since_inject()
        last_alfred_completion_plugin = plugin
    end
end

local function alfred_idle()
    local alfred, s, unreadable_busy = alfred_gate.read()
    -- Not loaded = nothing to wait on; unreadable = bounded busy (C1).
    if not s then return not unreadable_busy end
    -- Not enabled = nothing to wait on.
    if s.enabled == false then return true end
    -- Live work (queued external_trigger/pending included: external
    -- trigger_tasks() flips external_trigger synchronously, tracker
    -- trigger_tasks only 1+ ticks later) always wins over any grace. A
    -- teleport latched after a finished/failed trip is not live (WPT-1).
    -- Don't use all_task_done here: it is false on a cold start until
    -- Alfred ran one full cycle, so it would gate a fresh launch forever.
    local live = alfred_gate.live(s)
    local hard = s.inventory_full == true or s.need_repair == true
    -- A new paused-with-work episode gets its own full bound.
    if live or not hard or s.paused ~= true then alfred_gate.paused_since, alfred_gate.paused_logged = nil, false end
    if live then return false end
    -- Paused: Alfred cannot self-start. Without hard work (need_trigger
    -- alone is advisory) there is nothing to wait for; with hard work the
    -- kick resumes a WarPigs-owned pause, and any other pause is a bounded,
    -- logged hold instead of a gate that never opens (WPT-5 / WPD-5).
    if s.paused == true then
        if not hard then return true end
        return not alfred_gate.paused_work_hold(s)
    end
    -- inventory_full / need_repair: Alfred must finish before we teleport.
    if hard then return false end
    -- need_trigger alone: Alfred wants work (restock, socketables/keys,
    -- talismans). Steroid recomputes it every 0.5 s, so an unfillable
    -- restock keeps it true after every cycle. Idle within
    -- STUCK_NEED_TRIGGER_GRACE of a WarPigs-triggered completion by the same
    -- Alfred, and for the rest of this Temis visit once a WarPigs trigger had
    -- ADVISORY_SETTLE seconds to start (success, failure or no-op): another
    -- trip would make no progress and would interrupt WarPug (WPT-3).
    if s.need_trigger == true then
        local now = get_time_since_inject()
        if last_alfred_completion_at
            and last_alfred_completion_plugin == alfred
            and (now - last_alfred_completion_at) < STUCK_NEED_TRIGGER_GRACE
        then
            return true
        end
        if alfred_gate.visit_trigger_at and alfred_gate.visit_alfred == alfred
            and now - alfred_gate.visit_trigger_at >= alfred_gate.ADVISORY_SETTLE
        then
            return true
        end
        return false
    end
    return true
end
local raven_bridge = RavenBridge.new({alfred_idle = alfred_idle})
orchestrator.alfred_idle = alfred_idle

-- When Alfred has work to do (need_trigger / inventory_full) but isn't actively
-- running (trigger_tasks=false) and the player is in town, resume and trigger
-- it so the work runs before the next teleport. Called each tick while
-- teleport_pending is true so it fires as soon as we land in town after a
-- pit/undercity/horde exit.
--
-- We do NOT gate on s.paused: SteroidAlfredButler's get_status() omits the
-- paused field entirely (the upstream AlfredTheButler-main exposes it, the
-- steroid fork doesn't), so on that fork s.paused is always nil and a
-- paused-with-work Alfred would deadlock the gate forever. Gating on
-- "not s.trigger_tasks" instead correctly distinguishes "Alfred has work
-- queued but isn't processing it" from "Alfred is mid-cycle" without depending
-- on a field the active fork may not expose. Cooldown prevents per-tick spam
-- since trigger_tasks→true takes 1+ ticks to flip after we kick.
local ALFRED_KICK_COOLDOWN = 5.0
local last_alfred_kick_at  = -math.huge
local function alfred_kick_if_needed()
    -- Inline in-town check (in_town_disable_when is defined later in this file).
    local _lp = get_local_player()
    if not _lp then return end
    if not _G.attributes or _G.attributes.PLAYER_IN_TOWN_LEVEL_AREA == nil then return end
    if _G.attributes and _G.attributes.PLAYER_IN_TOWN_LEVEL_AREA ~= nil then
        local _ok, _val = pcall(function()
            return _lp:get_attribute(attributes.PLAYER_IN_TOWN_LEVEL_AREA) == 1
        end)
        if not (_ok and _val == true) then return end
    end
    local alfred, s = alfred_gate.read()
    if not s or s.enabled ~= true then return end
    -- Already actively processing — don't re-fire trigger_tasks (would
    -- overwrite external_caller and disrupt the in-flight cycle, see
    -- feedback_alfred_yield_rule). C1: a latched finished teleport is not.
    if alfred_gate.live(s) then return end
    local hard = s.inventory_full == true or s.need_repair == true
    if not (hard or s.need_trigger == true) then return end
    -- Completed-cycle grace / advisory already handled this visit / a
    -- foreign pause past its bounded hold.
    if alfred_idle() then return end
    -- WPT-3: an advisory-only flag gets one WarPigs trigger per Temis visit.
    if not hard and alfred_gate.visit_trigger_at and alfred_gate.visit_alfred == alfred then return end
    -- WPT-3 / WPG-4: never start Alfred's stash walk under an active WarPug
    -- session (it pauses for companion work itself and then shows IDLE).
    if alfred_gate.plan_creator_active() then
        if not alfred_gate.kick_deferred_logged then
            alfred_gate.kick_deferred_logged = true
            log('Alfred has work pending — not triggering it while WarPug is planning')
        end
        return
    end
    alfred_gate.kick_deferred_logged = false
    local now = get_time_since_inject()
    if (now - last_alfred_kick_at) < ALFRED_KICK_COOLDOWN then return end
    last_alfred_kick_at = now
    if s.paused == true then
        if s.paused_by ~= 'WarPigs' and s.external_caller ~= 'WarPigs' then return end
        if type(alfred.resume) ~= 'function' then return end
        local resumed, result = pcall(alfred.resume, 'WarPigs')
        if not resumed or result == false then return end
    end
    if type(alfred.trigger_tasks) == 'function' then
        -- Recorded even if the call fails: the advisory flag had its chance.
        alfred_gate.note_trigger(alfred)
        pcall(alfred.trigger_tasks, 'WarPigs', new_alfred_completion_callback(alfred))
    end
    log('Alfred had work pending but was not processing — task requested in town')
end

-- Via-Temis-Alfred preamble: before EVERY warplan teleport (cold start + each
-- handoff), drop the player at Temis and trigger Alfred so loot from the prior
-- activity is salvaged/stashed/repaired before the next quest starts. The user
-- explicitly asked for this — it costs an extra teleport for non-Pit activities
-- but guarantees a clean inventory each cycle.
local TEMIS_WP                = 0x1CE51E      -- Skov_Temis waypoint sno
local TEMIS_ZONE              = 'Skov_Temis'
local TEMIS_TELEPORT_TIMEOUT  = 30.0          -- retry the waypoint hop after this
local TEMIS_TELEPORT_DEBOUNCE = 6.0           -- min gap between waypoint calls (channel ≈ 5s)
-- Fast-retry cadence used ONLY when the player is stuck in a helltide zone
-- after the helltide quest ended with HR disabled — channel is constantly
-- broken by the 10s monster spawns, so we re-fire aggressively to catch a
-- damage-free window. Overrides both the timeout and the debounce.
local TEMIS_LINGER_RETRY_INTERVAL = TEMIS_TELEPORT_DEBOUNCE
-- Alfred dwell window. After firing trigger_tasks we need to give Alfred's main
-- loop a beat to pick up the trigger and flip its busy/trigger_tasks flag —
-- otherwise alfred_idle() returns true the instant we trigger and we leave the
-- state immediately. ALFRED_MIN_DWELL is a minimum hold (we never exit before
-- this even if Alfred reports idle — covers slow main_pulse pickup).
-- ALFRED_PICKUP_TIMEOUT is "Alfred's status task should have flipped
-- external_trigger=false by now if it had nothing to do; if it did, exit."
-- ALFRED_MAX_SECONDS is the absolute safety cap.
-- POST_ALFRED_SETTLE_SECONDS is the belt-and-suspenders settle in IDLE before
-- the warplan teleport fires — re-checks alfred_idle() to catch a re-armed
-- mini-cycle and bounces back to TEMIS_ALFRED if needed.
local ALFRED_MIN_DWELL              = 6.0
local ALFRED_PICKUP_TIMEOUT         = 8.0
local ALFRED_MAX_SECONDS            = 180.0
local POST_ALFRED_SETTLE_SECONDS    = 3.0

local function in_temis()
    local ok, w = pcall(function() return get_current_world() end)
    if not ok or w == nil then return false end
    local ok2, zname = pcall(function() return w:get_current_zone_name() end)
    return ok2 and zname == TEMIS_ZONE
end

-- Predicate: are we currently inside a BSK world (S05_BSK_*)? Used as the
-- enable_gate for InfernalHordes so the plugin is never started outside the
-- horde world while the teleport transition is enabled — without this, a
-- short-circuited warplan teleport (task_only_incoming, already_arrived,
-- warplan unavailable, or a stray world/zone change that "confirmed" the
-- TELEPORTING state) would let HordeDev enable in town and burn cycles in
-- "Walking to Horde".
local function in_bsk_world()
    local ok, w = pcall(function() return get_current_world() end)
    if not ok or w == nil then return false end
    local ok2, wname = pcall(function() return w:get_name() end)
    return ok2 and type(wname) == 'string' and wname:find('BSK', 1, true) ~= nil
end

-- HordeDev is currently mid-chest. Chest interaction is fragile (channeled
-- interact, VFX wait, loot wait, then "Trying next chest" → the next chest's
-- MOVING_TO_CHEST). Any teleport_to_waypoint() fired during this window cancels
-- the interact / yanks the player out of BSK and the run is lost. Even when
-- chests_done() correctly defers HordeDev's disable, a teleport_pending armed
-- earlier (prior plugin handoff, self-disable revive, cold start) plus the
-- TO_TEMIS retry loop can still re-fire teleport_to_waypoint(Temis) while the
-- chest task is running. This guard hard-blocks that window.
--
-- HordeDev's getState() returns "OPENING_CHESTS" iff the current task is
-- "Open Chests" (HordeDev-1.3.9/main.lua), which spans the whole INIT →
-- MOVING_TO_CHEST → OPENING_CHEST → WAITING_FOR_VFX → WAITING_FOR_LOOT →
-- (next chest) cycle. When that returns true we refuse to (a) start the
-- via-Temis preamble and (b) re-fire the TO_TEMIS retry teleport.
-- Returns a string tag if HordeDev is in a state that must block teleports,
-- or false if there is no block. Single function covers two cases so only one
-- upvalue slot is consumed by orchestrator.tick() (Lua 5.1 limit = 60).
--   'opening_chests' — HordeDev is mid-chest interact (fragile channeled action)
--   'has_aether'     — player still holds aether and is in BSK (must spend it)
--   false            — no block
-- The in_bsk_world() call lives here (not in tick()) to avoid consuming an
-- extra upvalue slot in tick() for in_bsk_world itself.
--
-- WPD-2 / HRD-1: only a running (or WarPigs-owned) HordeDev can spend the
-- aether or finish its chests, and a HordeDev that reports a latched fault
-- (C2 `fault`) never will. Holding the preamble for either would deadlock the
-- suite, so both holds apply only while HordeDev is on/owned and not faulted.
-- A HordeDev without a status() export keeps the original holds.
local function horde_teleport_block_reason(owned_by_warpigs)
    local p = _G.InfernalHordesPlugin
    if type(p) ~= 'table' then return false end
    if type(p.status) == 'function' then
        local ok, st = pcall(p.status)
        if ok and type(st) == 'table' then
            if type(st.fault) == 'string' and st.fault ~= '' then return false end
            if st.enabled ~= true and not owned_by_warpigs then return false end
        end
    end
    if p and type(p.chests_done) == 'function' then
        local ok, done = pcall(p.chests_done)
        if ok and done then return false end
    end
    if p and type(p.getState) == 'function' then
        local ok, state = pcall(p.getState)
        if ok and state == 'OPENING_CHESTS' then return 'opening_chests' end
    end
    -- Only flag aether when inside BSK. Outside BSK the count may be frozen
    -- or stale after a failed/completed horde and must not block the preamble.
    if in_bsk_world() and type(get_aether_count) == 'function' then
        local ok, count = pcall(get_aether_count)
        if ok and type(count) == 'number' and count > 0 then return 'has_aether' end
    end
    return false
end

-- Resume Alfred if paused, then fire trigger_tasks with the completion
-- callback. Returns true if a trigger was actually issued (Alfred loaded
-- AND enabled). False means caller should skip the TEMIS_ALFRED dwell
-- and go straight to the warplan teleport.
--
-- The callback (on_alfred_cycle_complete) records last_alfred_completion_at,
-- which alfred_idle() uses to break the Steroid restock-stickiness loop —
-- see comments on last_alfred_completion_at above. This mirrors Steroid's
-- documented create_task pattern (README §create_task) which also passes
-- a done-callback through trigger_tasks_with_teleport.
local function alfred_trigger_now()
    local alfred, s = alfred_gate.read()
    if not alfred or type(alfred.trigger_tasks) ~= 'function' then return false end
    if not s or s.enabled ~= true then return false end
    -- Join a LIVE cycle without replacing its caller/callback or pause. A
    -- teleport latched after a finished trip is not one: joining it waited
    -- for a cycle that did not exist and never triggered Alfred (WPT-1).
    if alfred_gate.live(s) then
        alfred_gate.note_trigger(alfred)
        return true
    end
    -- WPT-3 (one WarPigs Alfred cycle per Temis visit): a cycle WarPigs
    -- triggered in this visit (kick or preamble) by this Alfred has completed
    -- and no hard need came back since. Join it instead of a second Alfred
    -- walk, whatever its age (joint suite: kick + preamble = 2 cycles; critic
    -- round 3: turn-in preamble + the R6 re-arm after the turn-in = 2 cycles).
    -- A cycle that just finished (within STUCK_NEED_TRIGGER_GRACE) keeps the
    -- dwell and settle checks (true); an older one returns 'serviced' and the
    -- preamble only runs its settle checks. Hard work that came back triggers.
    if alfred_gate.visit_trigger_at and alfred_gate.visit_alfred == alfred
        and last_alfred_completion_plugin == alfred and last_alfred_completion_at
        and last_alfred_completion_at >= alfred_gate.visit_trigger_at
        and s.inventory_full ~= true and s.need_repair ~= true
    then
        if get_time_since_inject() - last_alfred_completion_at < STUCK_NEED_TRIGGER_GRACE then return true end
        return 'serviced'
    end
    if s.paused == true then
        if s.paused_by ~= 'WarPigs' and s.external_caller ~= 'WarPigs' then return false end
        if type(alfred.resume) ~= 'function' then return false end
        local resumed, result = pcall(alfred.resume, 'WarPigs')
        if not resumed or result == false then return false end
    end
    alfred_gate.note_trigger(alfred)
    local ok, accepted = pcall(alfred.trigger_tasks, 'WarPigs', new_alfred_completion_callback(alfred))
    return ok and accepted ~= false
end

local teleport_transition = {
    -- IDLE | TO_TEMIS | TEMIS_ALFRED | POST_ALFRED_SETTLE | TELEPORTING
    -- TO_TEMIS:           teleport_to_waypoint(TEMIS_WP) sent, waiting for arrival.
    -- TEMIS_ALFRED:       alfred_trigger_now() fired, waiting for Alfred to finish.
    -- POST_ALFRED_SETTLE: Alfred reported done; re-check alfred_idle for a
    --                     few seconds before firing warplan teleport. Bounces
    --                     back to TEMIS_ALFRED if Alfred re-arms a mini-cycle.
    -- TELEPORTING:        warplan.teleport_to_activity() sent, waiting for confirmation.
    state             = 'IDLE',
    started_at        = -math.huge,
    snap_world        = nil,  -- world name at the moment teleport was sent
    snap_zone         = nil,  -- zone name at the moment teleport was sent
    last_temis_tp     = -math.huge,  -- debounce for repeated TEMIS_WP calls
    alfred_fired_at   = nil,  -- time alfred_trigger_now() was called
    alfred_was_busy   = false, -- went busy at least once after trigger (saw work)
    alfred_picked_up  = false, -- saw external_trigger flip false (status task ran)
    settle_started_at = nil,  -- entry time into POST_ALFRED_SETTLE
    helltide_hold_logged = false, -- dedup for "holding for helltide off-window" log
    retries           = 0,    -- WPT-6: unchanged-world warplan retries this TELEPORTING
    chest_hold_logged = nil,  -- dedup for "TO_TEMIS hold — HordeDev opening chests" per hold window
}
-- True when the teleport sequence still needs to start. Two trigger sources:
--   * plugin_disable() — fires AFTER the previous activity's disable_when
--     predicate satisfies (Reaper waits kill+60s for chest/loot, Pit/WC
--     wait for town arrival post-Alfred-salvage). This means "previous
--     activity finished cleanup, safe to teleport for the next one".
--   * cold-start — when no plugin/task has ever been active in this WarPigs
--     session and a quest first matches, fire teleport before the very
--     first activity begins.
-- A pattern-edge trigger ("next WarPlan's quest matches") was DELIBERATELY
-- rejected: WarPlan quests unmatch the moment the boss dies, while the bot
-- still has chests to open and loot to salvage. Triggering on the new
-- pattern's match would interrupt that cleanup and lose the loot.
local teleport_pending = false
-- Tracks when the *incoming* activity first matched after teleport_pending was
-- armed. We wait TELEPORT_INCOMING_SETTLE before calling teleport_to_activity()
-- so the warplan data reflects the new quest. Cleared when a sequence starts.
local teleport_incoming_first_seen = nil
-- Suppresses repeat "teleport holding — …" logs while waiting for predicates.
local teleport_holding_logged = false
-- Tracks whether ANY plugin/task has been active under this WarPigs session.
-- False until the first activity starts; switched true on first activation
-- so cold-start fires exactly once. Reset by release_all().
local had_active_session = false

-- Scans all actors for a given skin name. Used by arrived_when predicates so
-- the orchestrator can confirm "we are at the quest destination" without
-- importing plugin-specific utils modules.
local function actor_present(skin_name)
    local ok, actors = pcall(function() return actors_manager:get_all_actors() end)
    if not ok or type(actors) ~= 'table' then return false end
    for _, actor in ipairs(actors) do
        local ok2, name = pcall(function() return actor:get_skin_name() end)
        if ok2 and name == skin_name then return true end
    end
    return false
end

-- Predicate: is the player in a town level area? Reused by Pit / WonderCity /
-- Helltide entries since "back in town" is the natural settle point for all
-- three. Missing town evidence must not release a dungeon owner.
local function in_town_disable_when()
    local lp = get_local_player()
    if not lp then return false end
    if not _G.attributes or _G.attributes.PLAYER_IN_TOWN_LEVEL_AREA == nil then
        return false
    end
    local ok, val = pcall(function()
        return lp:get_attribute(attributes.PLAYER_IN_TOWN_LEVEL_AREA) == 1
    end)
    return ok and val == true
end

-- ── dispatch helpers ────────────────────────────────────────────────────────
-- Companion gates, provider completion signals and gate bookkeeping for the
-- dispatcher live in this one table so orchestrator.tick() captures a single
-- upvalue for all of them (LuaJIT: 60 upvalues per function; keep tick <= 50).
local dispatch = {
    LOOTER_HOLD_MAX        = 30.0,   -- bounded Looter hold before an outgoing teleport
    PROVIDER_HOLD_MAX      = 180.0,  -- plugin Alfred round trip / live Alfred work in town
    ENTRY_HOLD_MAX         = 60.0,   -- plugin-reported committed entry (tribute/portal)
    HORDE_FAULT_GRACE      = 60.0,   -- let a faulted HordeDev leave BSK on its own first
    -- R7: a faulted HordeDev that reports its own exit in progress (C2
    -- exit_pending) gets HordeDev's 120 s Looter hold plus the Leave/Reset time.
    HORDE_EXIT_GRACE       = 180.0,
    MAX_GATE_DENIALS       = 2,      -- WPD-3: enable_gate denials after a delivered teleport
    REAPER_FAILURE_BACKOFF = 300.0,  -- WPD-6: first cooldown after a failed boss run
    REAPER_BACKOFF_MAX     = 1800.0,
    -- R3 / RPR-2: a Reaper run WarPigs did not start that reports C2 in_run is
    -- kept this long once unwanted (the Reaper entries' disable-defer cap).
    REAPER_ADOPTED_HOLD    = 300.0,
    -- R8: an enable() that does not produce an enabled status is retried on
    -- this cadence instead of every tick (same cadence as Reaper refusals).
    ENABLE_RETRY           = 30.0,
    GATE_STATUS_SECS       = 60.0,   -- C6: show a held gate in the status line after this
    GATE_LOG_SECS          = 120.0,  -- C6: log a held gate (rate-limited) after this
    -- R1: a companion-hold episode belongs to one gate and ends only when that
    -- gate stopped asking for longer than its own cadence plus this margin.
    -- Gates consulted every tick use 0.5 s; the TELEPORTING retry check runs
    -- every TELEPORT_CHECK_INTERVAL.
    GATE_MARGIN            = 1.5,
    GATE_CADENCE           = {teleporting = TELEPORT_CHECK_INTERVAL},
    -- Teleport-transition state -> the companion gate consulted in it.
    TRANSITION_GATE        = {TO_TEMIS = 'to_temis', POST_ALFRED_SETTLE = 'settle', TELEPORTING = 'teleporting'},
    hold           = {},  -- gate -> companion hold episode {checked_at, alfred_since, looter_since, ...}
    hold_reasons   = {},  -- gate -> {reason, at}: last hold reported by dispatch.held (C6 display)
    notes          = {},  -- key -> last logged message (dedup)
    gate_denials   = {},  -- plugin -> enable_gate denials after delivered teleports
    delivered      = false, -- R2: TELEPORTING confirmed or released since the last enable attempt
    unconfirmed    = {},  -- R8: plugin -> {at, count} enable() without an enabled status
    disable_reason = {},  -- plugin -> why its disable is deferred
    watchdog       = {},  -- currently held gate {reason, since, logged_at}
    reaper_backoff = {},  -- boss_id -> {count, until_t, reason}
    unmapped       = {},  -- WarPlans quests matching no map key (this tick)
    unmapped_logged = {}, -- quest name -> true (logged once)
    paused         = {},  -- W5-4: plugin -> {since} while paused by the user (owned, in_run)
}

-- Log `message` once per change for `key`.
function dispatch.note(key, message)
    if dispatch.notes[key] == message then return end
    dispatch.notes[key] = message
    if message then log(message) end
end

-- Returns `reason`; logs `prefix .. reason` once per hold episode for `key`.
-- The latest reason is kept for the gate watchdog / status line (R1, C6).
function dispatch.held(key, reason, prefix)
    dispatch.hold_reasons[key] = reason and {reason = reason, at = get_time_since_inject()} or nil
    if not reason then
        dispatch.notes[key] = nil
        return nil
    end
    dispatch.note(key, prefix .. reason)
    return reason
end

-- pcall'd status()/get_status() of a plugin export, or nil when unreadable.
function dispatch.status_of(p)
    if type(p) ~= 'table' then return nil end
    local fn = (type(p.status) == 'function' and p.status)
        or (type(p.get_status) == 'function' and p.get_status) or nil
    if not fn then return nil end
    local ok, s = pcall(fn)
    if ok and type(s) == 'table' then return s end
    return nil
end

-- C1 canonical Alfred reading (the same predicate is copied into every
-- plugin of the suite). A latched `teleport` after a finished/failed trip is
-- not live work.
dispatch.alfred_live = alfred_gate.live

-- WPT-3: the advisory-once-per-visit latch belongs to one Temis visit. Called
-- every tick with a loaded world; leaving Temis ends the visit.
function dispatch.observe_alfred_visit()
    if alfred_gate.visit_trigger_at and not in_temis() then
        alfred_gate.visit_trigger_at, alfred_gate.visit_alfred = nil, nil
    end
end

-- busy, reason. enabled == false is never busy. An unreadable status counts
-- as busy for at most alfred_gate.UNREADABLE_HOLD, then as "Alfred
-- unavailable" (not busy) with one log line.
function dispatch.alfred_busy(now)
    -- One shared C1 reading (and one unreadable timer/log line) for every
    -- WarPigs Alfred gate; see alfred_gate.read().
    local alfred, s, unreadable_busy = alfred_gate.read()
    if not alfred then return false end
    if not s then
        if unreadable_busy then return true, 'Alfred status unreadable' end
        return false
    end
    if s.enabled == false then return false end
    if dispatch.alfred_live(s) then return true, 'Alfred cycle in progress' end
    return false
end

-- WPD-1 / C1: companion gate for every outgoing teleport_to_waypoint /
-- warplan call, in ANY zone: live Alfred work (bounded by ALFRED_MAX_SECONDS)
-- and an active Looter pickup (bounded by LOOTER_HOLD_MAX). Returns a reason
-- or nil. The bounds keep a latched companion flag from stalling the suite;
-- each expiry is logged once (C6).
-- R1: `gate` names the caller ('idle', 'to_temis', 'settle', 'teleporting',
-- 'task'). Each gate keeps its own hold episode, which ends only when that
-- gate stopped asking for longer than its own cadence (GATE_CADENCE, 0.5 s
-- per tick by default) plus GATE_MARGIN: a later hold gets its own full bound,
-- and a gate that asks only every 6 s (TELEPORTING retries) still reaches it.
function dispatch.companion_hold(now, gate)
    gate = gate or 'default'
    local H = dispatch.hold[gate]
    if not H then
        H = {alfred_expired = false, looter_expired = false}
        dispatch.hold[gate] = H
    end
    local tolerance = (dispatch.GATE_CADENCE[gate] or 0.5) + dispatch.GATE_MARGIN
    if H.checked_at and now - H.checked_at > tolerance then
        H.alfred_since, H.alfred_expired, H.looter_since, H.looter_expired = nil, false, nil, false
    end
    H.checked_at = now
    local busy, why = dispatch.alfred_busy(now)
    if busy then
        H.alfred_since = H.alfred_since or now
        if now - H.alfred_since < ALFRED_MAX_SECONDS then return why end
        if not H.alfred_expired then
            H.alfred_expired = true
            log(string.format('%s for %.0fs — proceeding with the teleport anyway (bounded hold, %s)',
                tostring(why), now - H.alfred_since, gate))
        end
    else
        H.alfred_since, H.alfred_expired = nil, false
    end
    if RavenBridge.looter_state() == true then
        H.looter_since = H.looter_since or now
        if now - H.looter_since < dispatch.LOOTER_HOLD_MAX then return 'Looter collecting loot' end
        if not H.looter_expired then
            H.looter_expired = true
            log(string.format('Looter busy for %.0fs — proceeding with the teleport anyway (bounded hold, %s)',
                now - H.looter_since, gate))
        end
    else
        H.looter_since, H.looter_expired = nil, false
    end
    return nil
end

-- True only when the town attribute is readable and says "not in a town".
function dispatch.outside_town()
    local lp = get_local_player()
    if not lp or not _G.attributes or _G.attributes.PLAYER_IN_TOWN_LEVEL_AREA == nil then return false end
    local ok, val = pcall(function() return lp:get_attribute(attributes.PLAYER_IN_TOWN_LEVEL_AREA) end)
    return ok and val ~= nil and val ~= 1
end

-- Mirrors ArkhamAsylum's utils.player_in_pit (world name PIT_*).
function dispatch.in_pit_world()
    local ok, name = pcall(function()
        local w = get_current_world()
        return w and w:get_name()
    end)
    return ok and type(name) == 'string' and name:match('^PIT_') ~= nil
end

-- WPD-4 / ARK-2 / WCY-3 / WCY-7: Pit and Undercity release on "back in
-- town", but the town leg of the plugin's own Alfred round trip (C2
-- alfred_trip), an entry already under way (C2 committed_entry) or live
-- Alfred work (C1) is not the end of the run. Missing C2 fields keep the town
-- check plus the Alfred check. Every hold is bounded and logged (C6).
function dispatch.town_release_when(plugin_name)
    local since, held_for
    return function()
        if not in_town_disable_when() then
            since, held_for = nil, nil
            return false, 'not back in town yet'
        end
        local now = get_time_since_inject()
        local st = dispatch.status_of(_G[plugin_name])
        local reason, cap
        if st and st.alfred_trip == true then
            reason, cap = plugin_name .. ' Alfred round trip in progress', dispatch.PROVIDER_HOLD_MAX
        elseif st and st.committed_entry == true then
            reason, cap = plugin_name .. ' entry under way', dispatch.ENTRY_HOLD_MAX
        else
            local busy, why = dispatch.alfred_busy(now)
            if busy then reason, cap = why, dispatch.PROVIDER_HOLD_MAX end
        end
        if not reason then
            since, held_for = nil, nil
            return true
        end
        if held_for ~= reason then since, held_for = now, reason end
        if now - since >= cap then
            log(string.format('%s for %.0fs in town — releasing %s anyway (bounded hold)',
                reason, now - since, plugin_name))
            return true
        end
        return false, reason
    end
end

-- Predicate: does the player currently have the Helltide buff (= we're inside
-- a helltide zone). Used as arrived_when for the Helltide WarPlans entry so
-- WarPigs skips warplan.teleport_to_activity() when we're already in the right
-- zone — without this, cold-start (or post-respawn re-arm) inside a helltide
-- fires the teleport which is a no-op (world/zone unchanged) and loops on
-- "teleport retry — world/zone unchanged" forever, fighting HR's chest /
-- patrol work the whole time.
local HELLTIDE_BUFF_HASH = 1066539
local function has_helltide_buff()
    local lp = get_local_player()
    if not lp then return false end
    local ok, buffs = pcall(function() return lp:get_buffs() end)
    if not ok or type(buffs) ~= 'table' then return false end
    for _, buff in ipairs(buffs) do
        local ok2, hash = pcall(function() return buff.name_hash end)
        if ok2 and hash == HELLTIDE_BUFF_HASH then return true end
    end
    return false
end

-- Predicate: is helltide currently active in-world? Mirrors HelltideRevamped's
-- `utils.helltide_active` (HelltideRevamped-0.4/core/utils.lua:139): minutes
-- 55-59 of every hour are the off-window when no helltide exists. Used to
-- hold the warplan teleport in POST_ALFRED_SETTLE when incoming is helltide
-- and we'd otherwise teleport into a helltide that doesn't exist yet.
local function helltide_active()
    local m = tonumber(os.date('%M'))
    if not m then return true end
    if m >= 55 and m <= 59 then return false end
    return true
end

-- Predicate: any wanted plugin in `wants_` is HelltideRevampedPlugin.
local function incoming_is_helltide(wants_)
    for _, entry in pairs(wants_) do
        if entry.plugin == 'HelltideRevampedPlugin' then return true end
    end
    return false
end

-- Predicate: is the player already inside an Undercity dungeon zone? Mirrors
-- WonderCity's `utils.player_in_undercity` (zone name match `X1_Undercity_`).
-- Used as part of arrived_when for WarPlans_QST_Undercity so the orchestrator
-- recognises an in-progress run and stops re-firing warplan.teleport_to_activity()
-- — without this, mid-run teleport snapshots inside e.g. X1_Undercity_SnakeTemple_*
-- never confirm (brazier-only arrived_when can't see it deep in the dungeon),
-- and WarPigs loops on "teleport retry — world/zone unchanged" while WonderCity
-- is trying to do its job.
local function in_undercity_zone()
    local ok, w = pcall(function() return get_current_world() end)
    if not ok or w == nil then return false end
    local ok2, zname = pcall(function() return w:get_current_zone_name() end)
    if not ok2 or type(zname) ~= 'string' then return false end
    return zname:match('X1_Undercity_') ~= nil
end

-- Predicate: are there live enemies close enough that the teleport channel
-- will be interrupted by incoming damage? Used to defer
-- warplan.teleport_to_activity() out of a helltide zone — once the rotation
-- plugin clears the area, this returns false and the teleport fires
-- immediately on the next tick.
local COMBAT_NEARBY_RANGE = 12
local function enemies_near_player()
    if not _G.target_selector or type(target_selector.get_near_target_list) ~= 'function' then
        return false
    end
    local lp = get_local_player()
    if not lp then return false end
    local ok_pos, pos = pcall(function() return lp:get_position() end)
    if not ok_pos or not pos then return false end
    local ok, list = pcall(target_selector.get_near_target_list, pos, COMBAT_NEARBY_RANGE)
    if not ok or type(list) ~= 'table' then return false end
    for _, e in pairs(list) do
        local ok2, hp = pcall(function() return e:get_current_health() end)
        if ok2 and hp and hp > 1 then
            local ok3, untarg = pcall(function() return e:is_untargetable() end)
            if not (ok3 and untarg) then return true end
        end
    end
    return false
end

-- Reaper run-once tracker. Reaper v1.9+ exposes
-- ReaperPlugin.run_once(boss_id, run_type, on_complete): a callback fires
-- after Reaper kills the boss, loots, and returns to town (just before it
-- self-disables). We register a callback per request and flip `complete`
-- true when it fires; disable_when reads that flag.
--
-- run_id is bumped on every reset so a stale callback from a prior run_once
-- cannot mark a fresh run done. Specifically: when the boss pattern changes
-- mid-run, the old run_once is overwritten in Reaper's `run_once_callback`
-- slot (run_once just reassigns it), but if the new run_once is queued
-- before the orchestrator processes the change, the captured rid in the
-- old closure still wouldn't match the new run_id — so even a stray
-- invocation is a no-op.
--
-- C2 / WPD-6: on_complete(result) is called once per run with 'success',
-- 'failed' or 'cancelled' (Reaper <= 1.9.1 calls it without arguments and only
-- on success). `started` marks a run WarPigs itself started through run_once;
-- `accounted` makes the failure bookkeeping run once per run. A busy refusal
-- (`run_once` returning false) is retried on REAPER_REFUSE_RETRY, not every tick.
local REAPER_REFUSE_RETRY = 30.0
local reaper_run_once = { complete = false, run_id = 0, started = false, accounted = false,
    result = nil, boss = nil, refused_boss = nil, refused_at = -math.huge, refuse_reason = nil }

-- Diagnostic only: an altar task taking a long time does not establish
-- that the boss, chest, loot collection or return-to-town phase completed.
local ALTAR_WATCHDOG_COOLDOWN = 30.0
local reaper_altar_watchdog = {
    first_seen_at = nil,
    triggered     = false,
}

local function reset_reaper_run_once()
    reaper_run_once.complete = false
    reaper_run_once.run_id   = (reaper_run_once.run_id or 0) + 1
    reaper_run_once.started   = false
    reaper_run_once.accounted = false
    reaper_run_once.result    = nil
    reaper_altar_watchdog.first_seen_at = nil
    reaper_altar_watchdog.triggered     = false
end

local function make_reaper_callback()
    local rid = reaper_run_once.run_id
    return function(result)
        if rid ~= reaper_run_once.run_id or reaper_run_once.complete then return end
        reaper_run_once.complete = true
        if result == nil or result == true then result = 'success' elseif result == false then result = 'failed' end
        reaper_run_once.result = tostring(result)
    end
end

local function reaper_run_boss(p, boss_id)
    local R = reaper_run_once
    local now = get_time_since_inject()
    -- WPD-6: a busy/unknown-boss refusal keeps the current run id and is
    -- retried on a cooldown instead of on every 0.5 s tick.
    if R.refused_boss == boss_id and now - R.refused_at < REAPER_REFUSE_RETRY then return false end
    reset_reaper_run_once()
    R.boss = boss_id
    if type(p.run_once) == 'function' then
        local accepted, why = p.run_once(boss_id, nil, make_reaper_callback())
        if accepted == false then
            local reason = tostring(why or 'busy or unknown boss')
            if R.refused_boss ~= boss_id or R.refuse_reason ~= reason then
                console.print(string.format('[WarPigs] ReaperPlugin.run_once(%s) refused (%s) — retrying every %.0fs',
                    tostring(boss_id), reason, REAPER_REFUSE_RETRY))
            end
            R.refused_boss, R.refused_at, R.refuse_reason = boss_id, now, reason
            return false
        end
        R.refused_boss, R.refuse_reason = nil, nil
        R.started = true
        return accepted
    else
        -- Reaper < v1.9: no completion signal. Falling back to run_boss leaves
        -- disable_when waiting until Reaper self-disables or the user stops it.
        console.print('[WarPigs] WARNING: ReaperPlugin.run_once unavailable (need Reaper v1.9+) — falling back to run_boss')
        local accepted = p.run_boss(boss_id)
        R.started = accepted ~= false
        return accepted
    end
end

-- RPR-2: only a run WarPigs started through run_once ever calls back.
-- R3: when Reaper publishes the C2 fields they decide. A Reaper that reports
-- it is not a run_once run (external_run == false: manual toggle, persisted
-- main_toggle) or not in a run (in_run == false) is released as soon as it
-- is unwanted. One that reports in_run == true is still in a committed phase
-- (boss, chest, loot, return), also when WarPigs adopted it after a reload:
-- it is held, and a run WarPigs did not start (no callback will come) is held
-- at most REAPER_ADOPTED_HOLD, logged. Only a legacy Reaper without in_run
-- falls back to "release unless WarPigs started it".
local function reaper_run_once_disable_when()
    local R = reaper_run_once
    if R.complete == true then R.adopted_since = nil; return true end
    local st = dispatch.status_of(_G.ReaperPlugin)
    if st and (st.external_run == false or st.in_run == false) then R.adopted_since = nil; return true end
    if st and st.in_run == true and not R.started then
        local now = get_time_since_inject()
        -- A new hold episode (the disable phase asks every tick).
        if not R.adopted_seen or now - R.adopted_seen > 5 then
            R.adopted_since, dispatch.notes.reaper_adopted = now, nil
        end
        R.adopted_seen = now
        if now - R.adopted_since < dispatch.REAPER_ADOPTED_HOLD then
            return false, 'Reaper run in progress (in_run, not started by WarPigs)'
        end
        dispatch.note('reaper_adopted', string.format(
            'Reaper still reports in_run %.0fs after its quest ended (run not started by WarPigs) — releasing it (bounded hold)',
            dispatch.REAPER_ADOPTED_HOLD))
        return true
    end
    if st and st.in_run == true then return false, 'waiting for the Reaper run_once completion' end
    if not R.started then return true end
    return false, 'waiting for the Reaper run_once completion'
end

-- One Reaper boss-lair entry. `boss_id` also keys the failure backoff so
-- aliases of the same boss share it.
local function reaper_entry(boss_id)
    return {
        plugin = 'ReaperPlugin',
        boss_id = boss_id,
        enable = function(p) return reaper_run_boss(p, boss_id) end,
        disable_when = reaper_run_once_disable_when,
        max_disable_defer_seconds = 300,
    }
end

-- Map keys are matched as PLAIN SUBSTRINGS against the names of active
-- quests. Only quests whose name contains "WarPlans_QST" are eligible —
-- everything else (Bounty_*, story quests, etc.) is ignored. Multiple keys
-- may target the same plugin; the plugin stays enabled while at least one
-- key still matches.
--
-- Each value is either:
--   * a STRING — the plugin global name (calls plugin.enable()/disable())
--   * a TABLE  — {
--         plugin       = 'GlobalName',
--         enable       = fn(p)         -- optional custom enable hook
--         disable      = fn(p)         -- optional custom disable hook
--         disable_when = fn() -> bool  -- optional. When the quest disappears,
--                                      -- disable is deferred until this
--                                      -- returns true. Re-checked every tick.
--                                      -- Use to let the plugin finish a
--                                      -- post-quest wrap-up before WarPigs
--                                      -- flips it off (e.g. Arkham collecting
--                                      -- the glyphstone reward and TPing out
--                                      -- of the pit).
--     }
--   * a TABLE with `task` — {
--         task = require 'core.tasks.<name>'  -- module exposing tick(active)
--     }
--     The task module's tick(true) is called each WarPigs tick while the
--     trigger pattern matches; tick(false) when it stops. Used for actions
--     WarPigs performs itself (teleport, NPC interaction) instead of just
--     toggling another plugin.
-- Activity-plugin preemption priority. When more than one plugin's quest is
-- matched simultaneously, only the highest-priority one stays "wanted" — the
-- rest are treated as if their quest had gone unmatched (disabled per the
-- normal disable/disable_when path).
--
-- Why: WarPlans for short-lived objectives (Pit, Boss runs, Hordes) frequently
-- overlap with ambient/long-running activities (Undercity, Helltide). Without
-- preemption, both plugins stay enabled and fight for BatmobilePlugin/orbwalker
-- — in practice the ambient one wins the per-pulse race because it's already
-- mid-run, and the short-lived objective never starts. Specifically, completing
-- a Kurast boss and returning to Temis with an active Pit WarPlan should hand
-- off to Arkham; before this preemption, WonderCity just looped into the next
-- Undercity run instead.
--
-- Higher number = higher priority. Plugins not listed default to 0 (no
-- preemption — they always run alongside others if their quest matches).
local PLUGIN_PRIORITY = {
    ArkhamAsylumPlugin     = 100,  -- Pit: short objective, preempt ambient activities
    InfernalHordesPlugin   = 90,   -- Horde wave: also short
    ReaperPlugin           = 80,   -- Boss runs: short
    WonderCityPlugin       = 50,   -- Undercity: ambient/repeatable
    HelltideRevampedPlugin = 40,   -- Helltide: ambient/timed
}

orchestrator.quest_plugin_map = {
    WarPlans_QST_ThePit = {
        plugin = 'ArkhamAsylumPlugin',
        -- Pit quest can vanish while still inside the pit (post-quest reward
        -- phase). Wait for the player to fully return to town before letting
        -- the next plugin take over — but not on the town leg of Arkham's own
        -- Alfred round trip (return_for_loot) or while Alfred works (WPD-4).
        disable_when = dispatch.town_release_when('ArkhamAsylumPlugin'),
        -- Pit tower lives in Temis. If we're already in Temis when the teleport
        -- sequence fires, world/zone won't change and the confirmation loop
        -- would retry forever. arrived_when lets the orchestrator skip or
        -- confirm the teleport when the pit tower actor is already visible.
        -- Inside a PIT_* world the run is already under way (WCY-4 class:
        -- never teleport out of it to come back).
        arrived_when = function()
            return actor_present('TWN_Kehj_IronWolves_PitKey_Crafter')
                or dispatch.in_pit_world()
        end,
    },

    -- Helltide handoff: no disable_when. The quest disappearing means the
    -- helltide event ended (or the bot left it), and there's no in-zone
    -- wrap-up worth waiting for — HR can be cut immediately. The standard
    -- TRANSITION_GAP_SECONDS (5s) gap still applies via last_disable_time
    -- before the next plugin enables.
    --
    -- arrived_when = has_helltide_buff: when the player is already inside the
    -- helltide zone (cold-start with both plugins enabled, or post-respawn
    -- re-arm), warplan.teleport_to_activity() is a no-op and the orchestrator
    -- otherwise loops on "teleport retry — world/zone unchanged" while HR
    -- tries to do its job (logzewx 3337-3343 confirmed). The buff check is the
    -- ground truth — it fires when we're in the active helltide regardless of
    -- which specific Helltide_* zone we landed in.
    WarPlans_QST_Helltide_TorturedGifts = {
        plugin       = 'HelltideRevampedPlugin',
        arrived_when = has_helltide_buff,
    },

    WarPlans_QST_Undercity = {
        plugin       = 'WonderCityPlugin',
        -- Wait for the Kurast/Temis return; not during WonderCity's own Alfred
        -- with-teleport trip, live Alfred work or an entry already under way
        -- (tribute used / portal accepted) — WPD-4, WCY-3, WCY-7.
        disable_when = dispatch.town_release_when('WonderCityPlugin'),
        -- Two-layer arrived check:
        --   1. Brazier visible (Aubrie_Test_Undercity_Crafter) — we're at the
        --      Undercity town crafter, ready to start a run. Same loop-prevention
        --      as the Pit entry above — if already in town the teleport is a no-op.
        --   2. Already inside an X1_Undercity_* zone — we're mid-run. WonderCity
        --      owns the bot; WarPigs must not re-fire teleport_to_activity()
        --      because the dungeon world/zone snapshot won't change between
        --      retries and arrived_when is the only confirmation path.
        arrived_when = function()
            return actor_present('Aubrie_Test_Undercity_Crafter')
                or in_undercity_zone()
        end,
    },

    -- Confirmed seen in logs as WarPlans_QST_InfernalHordes_BSK; substring
    -- match covers any tier/variant suffix.
    --
    -- Quest vanishes when the wave bosses die, but HordeDev still has to
    -- open chests and pick up loot. Defer disable until we either leave the
    -- BSK world after confirmed chest/RESET completion.
    WarPlans_QST_InfernalHordes = {
        plugin = 'InfernalHordesPlugin',
        -- HARD GATE: when use_teleport_transition is on, never enable HordeDev
        -- unless we are currently inside a BSK world. The teleport state
        -- machine *should* land us there, but its confirmation is just
        -- "world/zone changed" — a stray zone change in town will satisfy it
        -- and the plugin would otherwise enable outside BSK and walk forever.
        -- With teleport off, the user is driving navigation themselves, so we
        -- don't impose the gate.
        -- War Plan entry (settings.horde_warplan_entry, default ON): the gate
        -- holds outside the Horde whatever 'Use teleport' says; `deliver`
        -- then fires the War Plan teleport and `enable` passes
        -- {entry = 'warplan'} (no compass). The compass fallback opens the
        -- gate only after dispatch.HORDE_WARPLAN_TRIES missed deliveries.
        enable_gate = function()
            if dispatch.horde_warplan() then return dispatch.hwe_gate() end
            if not settings.use_teleport_transition then return true end
            if in_bsk_world() then return true end
            return false, 'not in BSK world (teleport transition is on — refusing to start HordeDev outside BSK)'
        end,
        enable = function(p) return dispatch.hwe_enable(p) end,
        deliver = function(now, delivered) return dispatch.hwe_deliver(now, delivered) end,
        -- W5-2: in War Plan mode the Horde itself is the destination: a
        -- warplan teleport is never fired (preamble or retry) and a
        -- TELEPORTING state confirms while the player stands in the Horde.
        -- Option off: false (d275b9d, no arrived_when).
        arrived_when = function() return dispatch.horde_warplan() and dispatch.inside_horde() end,
        -- War Plan mode: HordeDev never starts a second cycle after its exit.
        -- A finished run (in_run == false outside the Horde) with the Horde
        -- quest still wanted is released so the next one gets a new War
        -- Plan teleport (back-to-back plans: exit, then a new teleport).
        run_finished = function(now, by_warpigs) return dispatch.hwe_run_finished(now, by_warpigs) end,
        -- Quest vanishes when the wave bosses die, but HordeDev still has to
        -- run its full post-boss cycle: open the talisman chest (if enabled),
        -- the greater-affix chest (if enabled), the materials/selected chest,
        -- then exit_horde teleports back to town. WarPigs must not preempt
        -- any of those steps.
        --
        -- Primary gate: chests_done() — HordeDev sets this true only after
        -- finish_chest_opening (or a hard exhaust). While it's false we hold
        -- unconditionally; the previous version's 60s in-BSK timer fired in
        -- the middle of "Waiting Talisman loot" and dropped GA + materials.
        --
        -- Once chests are done we wait for out-of-BSK as confirmation that
        -- exit_horde has actually fired (it teleports the player to Caldeum).
        -- Small safety cap covers a stuck exit_horde channel; while chests
        -- are still progressing the cap is not started.
        --
        -- This interval controls the stalled-cleanup diagnostic only. It
        -- never overrides chests_done or the entry/reset completion gate.
        max_disable_defer_seconds = 300,
        -- Opt out of same-activity continuation. Back-to-back BSK WarPlans
        -- leave the player in an empty BSK after the prior wave (no sigil,
        -- no chests left). The next run requires the full transition:
        -- exit_horde → Temis → Alfred → warplan.teleport_to_activity() →
        -- HordeDev re-enable inside a fresh horde. Without this flag,
        -- SAME_ACTIVITY_SECS (30s) would short-circuit the preamble and
        -- HordeDev would re-enable in place, doing nothing.
        same_activity_continuation = false,
        -- C2 (when HordeDev publishes it): in_run == false means HordeDev is
        -- not committed to a horde (idle, walking, persisted toggle, manual
        -- enable), so there is no chest/RESET work to protect (CRT-2). A
        -- latched `fault` can never finish its chest phase; HordeDev gets
        -- HORDE_FAULT_GRACE to leave BSK through its own exit, then it is
        -- released (HRD-1; the aether hold ignores a faulted HordeDev).
        -- R7: while a faulted HordeDev reports its own exit in progress (C2
        -- exit_pending == true: Leave/Reset or its Looter wait) the grace is
        -- HORDE_EXIT_GRACE instead, so WarPigs does not cut that exit. A
        -- missing field keeps the 60 s grace.
        disable_when = (function()
            local exit_defer_start
            local fault_since, exit_logged
            local left = {} -- joint K2: dispatch.hwe_left_hold state (since, busy_at)
            return function()
                local p = _G.InfernalHordesPlugin
                -- Joint K1: a HordeDev nobody owns that is still on inside the
                -- Horde after its quest ended (QQT reload after the Council):
                -- the one-time War Plan retag, so its bounded exit applies.
                dispatch.hwe_retag_orphan()
                local st = dispatch.status_of(p)
                local fault = st and type(st.fault) == 'string' and st.fault ~= '' and st.fault or nil
                if fault then
                    local now = get_time_since_inject()
                    if not fault_since then
                        fault_since, exit_logged = now, false
                        log('HordeDev reports a fault (' .. fault .. ') — allowing '
                            .. dispatch.HORDE_FAULT_GRACE .. 's for its own exit before releasing it')
                    end
                    local grace = dispatch.HORDE_FAULT_GRACE
                    if st.exit_pending == true then
                        grace = dispatch.HORDE_EXIT_GRACE
                        if not exit_logged then
                            exit_logged = true
                            log(string.format('HordeDev reports its exit in progress — extending the fault grace to %.0fs',
                                grace))
                        end
                    end
                    if now - fault_since >= grace then
                        dispatch.note('horde_fault', string.format(
                            'HordeDev fault grace expired after %.0fs — releasing it (bounded hold)', grace))
                        return true
                    end
                else
                    fault_since = nil
                    dispatch.notes.horde_fault = nil
                end
                if st and st.in_run == false then
                    exit_defer_start = nil
                    local hold, why = dispatch.hwe_left_hold(st, get_time_since_inject(), left)
                    if hold then return false, why end
                    return true
                end
                left.since, left.busy_at = nil, nil
                local done = p and type(p.chests_done) == 'function' and p.chests_done()
                if not done then
                    exit_defer_start = nil
                    if fault and st.exit_pending == true then return false, 'HordeDev fault, its own exit in progress' end
                    if fault then return false, 'HordeDev fault, waiting for its exit' end
                    return false, 'HordeDev chests/exit/RESET in progress'
                end
                local world = get_current_world()
                local name
                if world then
                    local ok, n = pcall(function() return world:get_name() end)
                    if ok then name = n end
                end
                local in_bsk = type(name) == 'string'
                    and name:find('BSK', 1, true) ~= nil
                if not in_bsk then
                    exit_defer_start = nil
                    return true
                end
                exit_defer_start = exit_defer_start or get_time_since_inject()
                if get_time_since_inject() - exit_defer_start >= 60 then
                    exit_defer_start = nil
                    return true
                end
                return false, 'HordeDev chests done, waiting to leave BSK'
            end
        end)(),
    },

    -- After a WarPlan finishes, this quest returns to drive the reward
    -- turn-in. WarPigs handles it directly: teleport to Temis, walk to
    -- Tyrael, interact.
    WarPlans_QST_TurnIn_Rewards = { task = require 'core.tasks.turn_in_rewards' },

    -- Boss runs via Reaper. boss_id must match an entry in
    -- Reaper-main/data/enums.lua boss_zones (duriel, andariel, varshan,
    -- grigoire, zir, beast, harbinger, urivar, butcher, belial).
    --
    -- Quest-name suffixes are confirmed where marked; the rest are best
    -- guesses based on the "Andariel" and "Harby" precedents. A wrong guess
    -- matches nothing; a WarPlans quest that matches no key is logged once and
    -- shown in the status line (CRT-5) — verify via the "Log ALL quests" mode
    -- and rename as needed.
    WarPlans_QST_BossLair_Andariel = reaper_entry('andariel'),  -- CONFIRMED
    WarPlans_QST_BossLair_Harby = reaper_entry('harbinger'),     -- CONFIRMED (harbinger)
    WarPlans_QST_BossLair_Duriel = reaper_entry('duriel'),    -- guess
    WarPlans_QST_BossLair_Varshan = reaper_entry('varshan'),   -- guess
    WarPlans_QST_BossLair_PenitentKnight = reaper_entry('grigoire'),  -- CONFIRMED (grigoire)
    WarPlans_QST_BossLair_Zir = reaper_entry('zir'),  -- CONFIRMED (log 2026-05-03: id=2317384)
    -- Beast in Ice: asset name is Boss_WT4_MegaDemon, but quests typically use
    -- the display name (per Harby/PenitentKnight precedent). Listing multiple
    -- aliases so we match whatever Blizzard chose. Multiple keys → same plugin
    -- is supported (kept enabled while ANY matches). Confirm the real name by
    -- enabling settings.log_all_quests and watching for "NEW QUEST: ..."
    -- containing WarPlans_QST_BossLair_*; trim the misses afterward.
    WarPlans_QST_BossLair_MegaDemon = reaper_entry('beast'),      -- asset-name guess
    WarPlans_QST_BossLair_Beast = reaper_entry('beast'),          -- display-name guess (also matches BeastInIce via substring)
    WarPlans_QST_BossLair_BeastInIce = reaper_entry('beast'),     -- display-name (full) guess
    WarPlans_QST_BossLair_IceBeast = reaper_entry('beast'),       -- guess (alternate word order)
    WarPlans_QST_BossLair_Wendigo = reaper_entry('beast'),        -- guess (lore name for Beast in Ice)
    WarPlans_QST_BossLair_Urivar = reaper_entry('urivar'),    -- guess
    WarPlans_QST_BossLair_Butcher = reaper_entry('butcher'),   -- guess
    WarPlans_QST_BossLair_Belial = reaper_entry('belial'),    -- guess
}

local function normalize(entry)
    if type(entry) == 'string' then return { plugin = entry } end
    return entry
end

-- WarPigs is the master orchestrator: any plugin in quest_plugin_map is
-- bound to its trigger pattern. When no pattern matches, the plugin is
-- forcibly disabled — even if it was enabled outside WarPigs (e.g. by a
-- manual toggle, a stale state surviving a script reload, or a previous
-- WarPigs session whose owned[] table was lost).
local owned          = {}  -- plugin_name -> true (currently enabled by us)
local last_wanted    = {}  -- plugin_name -> true (was-wanted on previous tick)
local last_matches   = {}  -- pattern -> true (for verbose log only)
local pending_disable = {} -- plugin_name -> true (disable deferred by predicate)
local pending_disable_since = {}  -- plugin_name -> time when deferral started (for MAX_DISABLE_DEFER_SECONDS)
local last_disable_time     = {}  -- plugin_name -> time the disable actually fired (for TRANSITION_GAP_SECONDS gate)
local enable_blocked        = {}  -- plugin_name -> last gate-reason logged (suppresses repeat logs)
local was_off        = {}  -- plugin_name -> true (we believe it is currently off; suppresses repeated logs)
-- Same-activity continuation: when the same plugin re-matches within this
-- window after being disabled (e.g. back-to-back helltide WarPlans), cancel
-- the pending teleport so we don't fire warplan.teleport_to_activity() while
-- the plugin is already positioned in the right zone.
local last_disabled_plugin = nil
local last_disabled_at     = -math.huge
local last_disabled_reason = nil   -- quest pattern that triggered the last disable
local SAME_ACTIVITY_SECS   = 30.0
-- Track which trigger pattern was last used to enable each plugin. When the
-- matched pattern changes mid-run (e.g. ReaperPlugin running Zir but a new
-- Varshan WarPlan appears before Zir's kill+60s defer satisfies), re-fire
-- enable() so the plugin's enable hook switches to the new boss. Without this
-- the orchestrator owns the plugin under the OLD entry, the enable phase's
-- edge-trigger short-circuits, and the plugin keeps running stale context.
local last_enabled_reason   = {}  -- plugin_name -> pattern

-- Hard filter: only quests containing this substring can drive WarPigs.
-- Prevents accidental matches against bounty/story quests when a map key is
-- an unintentionally broad substring.
local QUEST_FILTER = 'WarPlans_QST'

local function get_active_quest_names()
    local names = {}
    local ok, quests = pcall(get_quests)
    -- An unavailable snapshot is not an empty quest list. Keep the current
    -- activity intact until the host can report quests again.
    if not ok or type(quests) ~= 'table' then return nil end
    for _, quest in pairs(quests) do
        local ok_n, name = pcall(function() return quest:get_name() end)
        if not ok_n or type(name) ~= 'string' or name == '' then return nil end
        if name:find(QUEST_FILTER, 1, true) then
            names[#names+1] = name
        end
    end
    return names
end

-- Best-effort check: is the plugin currently reporting itself enabled?
-- Returns true if a status surface says enabled=true. Returns false if no
-- status is exposed — in which case we fall back to our own owned[] table.
-- (Defined ABOVE plugin_enable so the resilient-enable code can reference it
--  — Lua locals aren't hoisted, so a forward reference would resolve to a
--  global nil at call time.)
local function is_plugin_on(plugin_name)
    local p = _G[plugin_name]
    if not p then return false end
    local status_fn = (type(p.status) == 'function' and p.status)
                   or (type(p.get_status) == 'function' and p.get_status)
                   or nil
    if status_fn then
        local ok, s = pcall(status_fn)
        if ok and type(s) == 'table' then return s.enabled == true end
    end
    return owned[plugin_name] == true
end

-- Predicate: helltide quest just ended (or never was incoming) but the player
-- is still in the helltide zone with HR disabled. In this state the 10s
-- monster spawns hit the player, the via-Temis preamble's teleport channel
-- gets cancelled by damage, and HR isn't around to clear the area. Used to
-- (a) bypass the in_helltide_combat hold so the preamble is allowed to fire
-- even while taking hits, and (b) shorten the TO_TEMIS retry cadence to
-- TEMIS_LINGER_RETRY_INTERVAL (6s) so a complete channel can finish before
-- one attempt lands between hits.
local function helltide_lingering_post_quest(wants_)
    if not has_helltide_buff() then return false end
    if is_plugin_on('HelltideRevampedPlugin') then return false end
    if incoming_is_helltide(wants_) then return false end
    return true
end

-- Force orbwalker clear ON at a handoff. Some plugins (HR cinder gate, Reaper
-- boss approach / reset, manual toggles) leave clear OFF; the next plugin
-- often assumes it starts ON and never re-asserts it, so trash gets ignored
-- for the entire run. Gated by settings.manage_orbwalker so users who hand
-- orbwalker control to their rotation aren't disturbed. WPD-7 / RPR-10 /
-- HLT-6: applied consistently before and after each enable (a synchronous
-- reset inside enable/run_once cannot undo it) and after each disable.
function dispatch.restore_orbwalker(context)
    if settings.manage_orbwalker and orbwalker and orbwalker.set_clear_toggle then
        local ok = pcall(orbwalker.set_clear_toggle, true)
        if not ok then
            log('orbwalker.set_clear_toggle(true) threw ' .. context)
        end
    end
end

local function plugin_enable(entry, reason)
    local p = _G[entry.plugin]
    if not p then
        log('cannot enable ' .. entry.plugin .. ' — plugin not loaded')
        return
    end
    -- WPD-6: a refused Reaper run_once (busy) is retried on its cooldown only;
    -- do not re-force the orbwalker on every tick in between.
    if entry.boss_id and reaper_run_once.refused_boss == entry.boss_id
        and get_time_since_inject() - reaper_run_once.refused_at < REAPER_REFUSE_RETRY
    then
        return
    end
    -- R8: an enable() that did not produce an enabled status (e.g. HordeDev
    -- with 'Use keybind' on and no key bound) is retried every ENABLE_RETRY
    -- seconds, not every tick: each enable() may reset the plugin's run state.
    -- A plugin that reports enabled during that cooldown (the user fixed the
    -- keybind, a transient status() failure cleared) is adopted at once,
    -- without a second enable() (round-3 audit).
    local unconfirmed = dispatch.unconfirmed[entry.plugin]
    if unconfirmed and get_time_since_inject() - unconfirmed.at < dispatch.ENABLE_RETRY then
        if is_plugin_on(entry.plugin) then
            owned[entry.plugin] = true
            enable_blocked[entry.plugin] = nil
            dispatch.gate_denials[entry.plugin] = nil
            dispatch.unconfirmed[entry.plugin] = nil
            last_enabled_reason[entry.plugin] = reason
            log(string.format('%s reports enabled after %d unconfirmed enable(s) — adopted without another enable() (%s)',
                entry.plugin, unconfirmed.count or 0, reason or '?'))
        end
        return
    end
    dispatch.restore_orbwalker('before enabling ' .. entry.plugin)
    -- Wrap enable() in pcall: a misbehaving plugin (e.g. HR.enable referencing
    -- a missing GUI element) used to crash the orchestrator and trigger an
    -- infinite enable loop because owned[] never got set, so the edge check
    -- fired again next tick.
    local ok, err
    if entry.enable then
        ok, err = pcall(entry.enable, p)
    elseif type(p.enable) == 'function' then
        ok, err = pcall(p.enable)
    else
        log('cannot enable ' .. entry.plugin .. ' — no enable function')
        return
    end
    if not ok then
        log('enable() of ' .. entry.plugin .. ' threw: ' .. tostring(err))
    end
    dispatch.restore_orbwalker('after enabling ' .. entry.plugin)
    -- Trust the plugin's status() over enable()'s exit path — partial enables
    -- (HR sets main_toggle, then crashes on missing keybind_toggle, but the
    -- plugin IS active because main_toggle is what status() reports) should
    -- count as enabled. Otherwise we'd keep retrying and crashing forever.
    local has_status = type(p.status) == 'function' or type(p.get_status) == 'function'
    if err ~= false and (is_plugin_on(entry.plugin) or (ok and not has_status)) then
        owned[entry.plugin] = true
        enable_blocked[entry.plugin] = nil
        dispatch.gate_denials[entry.plugin] = nil
        dispatch.unconfirmed[entry.plugin] = nil
        last_enabled_reason[entry.plugin] = reason
        log('enabled ' .. entry.plugin .. ' (' .. (reason or '?') .. ')')
        return
    end
    -- A refused Reaper run_once has its own cooldown and status entry (R4).
    local refused = entry.boss_id and reaper_run_once.refused_boss == entry.boss_id
    if not refused then
        local u = dispatch.unconfirmed[entry.plugin] or {count = 0}
        u.at, u.count = get_time_since_inject(), u.count + 1
        dispatch.unconfirmed[entry.plugin] = u
    end
    if enable_blocked[entry.plugin] ~= 'enable not confirmed' then
        -- Logged once per episode: a refused Reaper run_once and an
        -- unconfirmed enable are retried on a cooldown (R8).
        enable_blocked[entry.plugin] = 'enable not confirmed'
        log(string.format('enable of %s did not result in enabled status — retrying every %.0fs%s',
            entry.plugin, refused and REAPER_REFUSE_RETRY or dispatch.ENABLE_RETRY,
            refused and '' or ' (check its toggle / keybind settings)'))
    end
end

local function plugin_disable(entry)
    local p = _G[entry.plugin]
    if p then
        local ok, result
        if entry.disable then
            ok, result = pcall(entry.disable, p)
        elseif type(p.disable) == 'function' then
            ok, result = pcall(p.disable)
        else
            ok, result = false, 'no disable function'
        end
        if not ok or result == false or is_plugin_on(entry.plugin)
            and (type(p.status) == 'function' or type(p.get_status) == 'function')
        then
            log('cannot confirm disable of ' .. entry.plugin .. ': ' .. tostring(result))
            owned[entry.plugin] = true
            pending_disable[entry.plugin] = true
            pending_disable_since[entry.plugin] = pending_disable_since[entry.plugin] or get_time_since_inject()
            return false
        end
        log('disabled ' .. entry.plugin)
        dispatch.restore_orbwalker('after disabling ' .. entry.plugin)
    end
    if entry.plugin == 'ReaperPlugin' then dispatch.reaper_run_ended(get_time_since_inject(), true) end
    dispatch.disable_reason[entry.plugin] = nil
    owned[entry.plugin] = nil
    last_disabled_reason = last_enabled_reason[entry.plugin]
    last_enabled_reason[entry.plugin] = nil
    last_disable_time[entry.plugin] = get_time_since_inject()
    last_disabled_plugin = entry.plugin
    last_disabled_at     = get_time_since_inject()
    -- Arm the teleport sequence for the NEXT activity. plugin_disable only
    -- fires after disable_when has satisfied (Reaper: kill+60s, Pit/WC: in
    -- town after Alfred salvage), so we're in a clean state to teleport.
    if settings.use_teleport_transition then
        teleport_pending = true
    end
    return true
end

-- Quest-dump mode: record every quest name+id we have ever seen and print
-- on first sighting. Lets us discover quest names for new activities without
-- needing the in-game overlay.
local seen_all = {}

local function dump_all_quests()
    local ok, quests = pcall(get_quests)
    if not ok or type(quests) ~= 'table' then return end
    for _, quest in ipairs(quests) do
        local ok_n, name = pcall(function() return quest:get_name() end)
        local ok_i, qid  = pcall(function() return quest:get_id() end)
        if ok_n and type(name) == 'string' and not seen_all[name] then
            seen_all[name] = true
            log(string.format('NEW QUEST: id=%s name=%s',
                ok_i and tostring(qid) or '?', name))
        end
    end
end

-- Returns true if any active quest name contains pattern (plain substring).
local function pattern_has_match(pattern, active_names)
    for _, name in ipairs(active_names) do
        if name:find(pattern, 1, true) then return true end
    end
    return false
end

-- Picks any map entry that targets plugin_name (used when disabling, so the
-- entry's custom disable hook is preserved even if the matching pattern has
-- already gone away).
local function find_entry_for_plugin(plugin_name)
    local reason = last_enabled_reason[plugin_name]
    local current = reason and orchestrator.quest_plugin_map[reason]
    if current then return normalize(current) end
    for _, raw in pairs(orchestrator.quest_plugin_map) do
        local e = normalize(raw)
        if e.plugin == plugin_name then return e end
    end
    return { plugin = plugin_name }
end

-- Build the set of all distinct plugin globals referenced by the map. Used
-- by the state-based disable phase to enforce "off" on plugins WarPigs may
-- not have enabled itself (manual toggle, stale state from before reload).
local function get_managed_plugins()
    local set = {}
    for _, raw in pairs(orchestrator.quest_plugin_map) do
        local e = normalize(raw)
        if e.plugin then set[e.plugin] = find_entry_for_plugin(e.plugin) end
    end
    return set
end

-- Death-handling state: log "died" once on transition so respawn loops don't
-- spam.  Cleared the moment is_dead() goes false.
local was_dead          = false

-- Filler-pit state for `settings.run_pit_after_turnin`.  We arm the filler
-- once at least one WarPlans_QST_TurnIn_Rewards cycle has completed in this
-- session (matched → unmatched edge); after arming, whenever no real WarPlans
-- quest is active and no internal task is running, we inject ArkhamAsylumPlugin
-- into `wants` so pit fills the gap.  Cleared by `release_all`.
local TURN_IN_PATTERN          = 'WarPlans_QST_TurnIn_Rewards'
local turn_in_was_matched      = false
local had_turn_in_complete     = false
local pit_filler_active_logged = false   -- dedup the "filler engaged"/"yielded" logs

local function plan_creator_enabled()
    local creator = _G.WarPugPlugin
    if not creator or type(creator.status) ~= 'function' then return false end
    local ok, status = pcall(creator.status)
    -- A failed companion query is not evidence that an optional filler can
    -- take over. An enabled creator has priority, including a held error that
    -- needs attention; otherwise filler and planner can wait on each other.
    return not ok or type(status) ~= 'table' or status.enabled == true
end

local function check_reaper_altar_watchdog()
    if reaper_altar_watchdog.triggered then return end
    if type(_G.ReaperPlugin) ~= 'table' then return end
    if type(_G.ReaperPlugin.status) ~= 'function' then return end

    local ok, st = pcall(_G.ReaperPlugin.status)
    if not ok or type(st) ~= 'table' then return end
    -- Only police runs that WarPigs initiated. Standalone Reaper is the user's call.
    if not st.enabled or not st.external then return end

    local task_name = st.task and st.task.name
    if task_name ~= 'Interact Altar' then return end

    local now = get_time_since_inject()
    if not reaper_altar_watchdog.first_seen_at then
        reaper_altar_watchdog.first_seen_at = now
        log(string.format('reaper altar watchdog: first Interact Altar at %.1f', now))
        return
    end

    local elapsed = now - reaper_altar_watchdog.first_seen_at
    if elapsed > ALTAR_WATCHDOG_COOLDOWN then
        reaper_altar_watchdog.triggered  = true
        log(string.format(
            'reaper altar watchdog: Interact Altar active for %.0fs; waiting for Reaper completion (no forced loot handoff)',
            elapsed))
    end
end

-- ── dispatch helpers used by tick() (table declared above) ──────────────────
dispatch.WARPLAN_MAX_RETRIES = 5  -- WPT-6: unchanged-world retries before releasing the gate

-- WPD-8: no helltide exists in minutes 55-59.
function dispatch.helltide_off_window(wants_)
    return incoming_is_helltide(wants_) and not helltide_active()
end

-- Hold for every warplan.teleport_to_activity() call (first call and retries):
-- helltide off-window (WPD-8) and the companion gate (WPD-1) of `gate` (R1).
function dispatch.warplan_hold(wants_, now, gate)
    if dispatch.helltide_off_window(wants_) then
        return 'incoming is helltide, helltide is in off-window (minute 55-59)'
    end
    return dispatch.companion_hold(now, gate)
end

-- WPD-2 / WCY-4: is the player already inside an incoming activity? A quest
-- actor seen in a town (Pit tower, Undercity brazier) does not count, so a
-- town handoff keeps its via-Temis Alfred step. HordeDev's BSK counts only on
-- a cold start (back-to-back hordes need the full exit/re-entry sequence).
-- Returns the plugin name or nil.
-- W5-2: with War Plan entry on, being inside the Horde while the Horde quest
-- is wanted is always "in place": HordeDev reports 'completed' only after it
-- left the Horde, so a Horde the player stands in is the one to play.
function dispatch.incoming_in_place(wants_, cold)
    if wants_.InfernalHordesPlugin then
        if dispatch.horde_warplan() and dispatch.inside_horde() then return 'InfernalHordesPlugin' end
        if cold and in_bsk_world() then return 'InfernalHordesPlugin' end
    end
    if not dispatch.outside_town() then return nil end
    for plugin_name, entry in pairs(wants_) do
        if plugin_name ~= 'InfernalHordesPlugin' and type(entry.arrived_when) == 'function' then
            local ok, arrived = pcall(entry.arrived_when)
            if ok and arrived == true then return plugin_name end
        end
    end
    return nil
end

-- WPD-3 (needs a live check of the Horde warplan landing): an enable_gate
-- that still denies after a delivered teleport re-arms the whole detour.
-- Log the landing each time and, after MAX_GATE_DENIALS deliveries, let the
-- plugin start and navigate itself instead of looping Temis→Alfred→warplan.
-- R2: `delivered` is true only when a warplan TELEPORTING state confirmed or
-- released since the last enable attempt (dispatch.delivered). A denial with
-- no warplan teleport before it (e.g. the first enable of a new plan in Temis
-- after the turn-in) only re-arms the sequence and is not counted.
function dispatch.gate_bypass(plugin_name, why, delivered)
    if not delivered then return false end
    -- War Plan Horde entry: never enable HordeDev outside the Horde to walk
    -- there itself (that walk ends at an Infernal Compass). Missed deliveries
    -- are counted by hwe_deliver; only the compass fallback opens the gate.
    if plugin_name == 'InfernalHordesPlugin' and dispatch.horde_warplan() then return false end
    local count = (dispatch.gate_denials[plugin_name] or 0) + 1
    dispatch.gate_denials[plugin_name] = count
    local ok, w, z = pcall(function()
        local world = get_current_world()
        return world:get_name(), world:get_current_zone_name()
    end)
    local where = string.format('world=%s zone=%s', tostring(ok and w or '?'), tostring(ok and z or '?'))
    if count < dispatch.MAX_GATE_DENIALS then
        log(string.format('enable_gate for %s denied after warplan teleport %d of %d (landed %s): %s',
            plugin_name, count, dispatch.MAX_GATE_DENIALS, where, tostring(why)))
        return false
    end
    log(string.format('enable_gate for %s still denied after %d warplan teleports (landed %s) — enabling it to navigate itself',
        plugin_name, count, where))
    return true
end

-- ── Infernal Hordes War Plan entry (user feature, round 4) ─────────────────
-- settings.horde_warplan_entry (default ON). The War Plan panel's Teleport
-- (warplan.teleport_to_activity()) drops the player straight into the Horde
-- (a 6-wave War Plan horde): no Infernal Compass is needed, and the old entry
-- (Library walk + compass) stopped when the compasses ran out (live report).
-- WarPigs fires that teleport itself, whatever 'Use teleport' says:
--   * only from the enable phase without a transition gate, i.e. after the
--     outgoing activity's cleanup/disable and the post-disable gap;
--   * behind the C1 Alfred live-work and the bounded Looter holds
--     (companion_hold gate 'horde_warplan');
--   * protected (pcall), at most one call per TELEPORT_CHECK_INTERVAL and
--     never into its own channel while it still casts (HORDE_CAST_CAP);
--   * with 'Use teleport' on, a round starts with the via-Temis preamble
--     (Alfred in Temis first, as for every activity); retries are direct.
-- HordeDev is enabled with {entry = 'warplan'} only inside the Horde (alive,
-- BSK world, zone S05_BSK_Prototype02); the landing of every delivery is
-- logged once. After HORDE_WARPLAN_TRIES deliveries that miss the Horde,
-- HordeDev is never enabled outside it (the WPD-3 bypass is off) unless
-- settings.horde_compass_fallback (default OFF) is ticked: then enable()
-- without arguments (compass mode), logged. Otherwise the reason is shown in
-- the status line and logged (rate-limited), and the teleport is retried
-- after HORDE_WARPLAN_BACKOFF. With the setting off nothing here runs.
dispatch.HORDE_ZONE            = 'S05_BSK_Prototype02'
dispatch.HORDE_WARPLAN_TRIES   = 3
dispatch.HORDE_WARPLAN_BACKOFF = 60.0
dispatch.HORDE_CAST_CAP        = 15.0    -- never trust a stuck teleport cast longer than this
dispatch.HORDE_DONE_SETTLE     = 3.0     -- a finished War Plan run must look finished this long
-- W5-2: a War Plan run that is out of the Horde without 'completed' (a trip
-- HordeDev did not start, a revive outside) is released only after this long
-- with no C1 Alfred live work and no teleport cast.
dispatch.HORDE_LEFT_SETTLE     = 30.0
dispatch.TELEPORT_SPELL_ID     = 186139  -- the teleport channel (HordeDev and SilentRaven use it too)
dispatch.HORDE_WAIT_REASON     = 'waiting for War Plan teleport into the Horde (War Plan entry, no compass)'

-- Delivery state of one Horde want. `fired_at` survives a reset: the
-- channel debounce also covers a new want right after the last call.
-- `landing_bsk`: the last missed landing was in a BSK world/zone (W5-3).
-- `retagged`: an adopted/foreign HordeDev was switched to War Plan mode (W5-1).
function dispatch.hwe_new(fired_at)
    return {state = 'IDLE', fired_at = fired_at or -math.huge, snap_world = nil, snap_zone = nil,
        missed = 0, round = 1, backoff_until = nil, compass = false, mode = nil,
        reason = nil, reason_at = nil, logged_at = nil, landing = nil, done_since = nil,
        landing_bsk = false, landing_zone = nil, landing_world = nil, left_since = nil, retagged = nil,
        busy_since = nil, busy_logged = nil}
end
dispatch.hwe = dispatch.hwe_new()

function dispatch.horde_warplan() return settings.horde_warplan_entry == true end

-- W5-3: a BSK world or zone (any case) — a place of the Horde family.
function dispatch.bsk_place(world, zone)
    local function has(s) return type(s) == 'string' and s:lower():find('bsk', 1, true) ~= nil end
    return has(world) or has(zone)
end

-- W5-3: why a round of missed War Plan teleports did not reach the Horde.
function dispatch.hwe_miss_reason()
    local H = dispatch.hwe
    if H.landing_bsk then
        return string.format('%d War Plan teleports did not reach the Horde: landed in a BSK zone '
            .. 'HordeDev does not know (zone=%s, world=%s) — please report; not using a compass', H.missed,
            tostring(H.landing_zone), tostring(H.landing_world))
    end
    return string.format('%d War Plan teleports did not reach the Horde (last landing %s), compass fallback off',
        H.missed, tostring(H.landing))
end

-- Alive, in a loaded BSK world and in the Horde zone (HordeDev's own test).
function dispatch.inside_horde()
    local ok, inside = pcall(function()
        local lp = get_local_player()
        if not lp or lp:is_dead() then return false end
        local w = get_current_world()
        return w ~= nil and w:get_current_zone_name() == dispatch.HORDE_ZONE
    end)
    return ok and inside == true and in_bsk_world()
end

function dispatch.where()
    local ok, w, z = pcall(function()
        local world = get_current_world()
        return world:get_name(), world:get_current_zone_name()
    end)
    return tostring(ok and w or '?'), tostring(ok and z or '?')
end

function dispatch.teleport_casting()
    local ok, id = pcall(function()
        local lp = get_local_player()
        return lp and lp:get_active_spell_id()
    end)
    return ok and id == dispatch.TELEPORT_SPELL_ID
end

-- C6: the current wait of the War Plan entry, shown at once in the status line.
function dispatch.hwe_status(now, reason)
    dispatch.hwe.reason, dispatch.hwe.reason_at = reason, now
end

function dispatch.hwe_gate()
    if dispatch.inside_horde() or dispatch.hwe.compass then return true end
    return false, dispatch.HORDE_WAIT_REASON
end

-- One delivery that did not reach the Horde, logged once with its landing.
function dispatch.hwe_missed(now, what)
    local H = dispatch.hwe
    local w, z = dispatch.where()
    H.missed = H.missed + 1
    H.landing = string.format('world=%s zone=%s', w, z)
    H.landing_world, H.landing_zone, H.landing_bsk = w, z, dispatch.bsk_place(w, z)
    log(string.format('War Plan Horde entry: %s — landed %s, not inside the Horde (%d of %d)',
        what, H.landing, H.missed, dispatch.HORDE_WARPLAN_TRIES))
    if H.missed < dispatch.HORDE_WARPLAN_TRIES then return end
    -- W5-3: a landing in a BSK world/zone HordeDev does not know never
    -- engages the compass fallback (its compass entry would leave the place
    -- the War Plan teleport chose): the backoff, the reason and a report.
    if H.landing_bsk then
        H.backoff_until, H.logged_at = now + dispatch.HORDE_WARPLAN_BACKOFF, now
        log(string.format('War Plan Horde entry: %d War Plan teleports did not reach the Horde: landed in a BSK zone '
            .. 'HordeDev does not know (zone=%s, world=%s) — please report; not using a compass%s; retrying in %.0fs',
            H.missed, z, w,
            settings.horde_compass_fallback == true and ' (compass fallback not used in a BSK zone)' or '',
            dispatch.HORDE_WARPLAN_BACKOFF))
    elseif settings.horde_compass_fallback ~= true then
        H.backoff_until, H.logged_at = now + dispatch.HORDE_WARPLAN_BACKOFF, now
        log(string.format('War Plan Horde entry: %d War Plan teleports did not reach the Horde (last landing %s) — '
            .. 'not using a compass (compass fallback off); retrying in %.0fs',
            H.missed, H.landing, dispatch.HORDE_WARPLAN_BACKOFF))
    end
end

-- Enable phase, InfernalHordes gate denied, no transition gate this tick.
-- `delivered`: the via-Temis preamble's warplan teleport (TELEPORTING
-- confirmed or released, R2) arrived since the last enable attempt. Returns
-- true when the War Plan entry handles the delivery (the caller then does
-- not re-arm the via-Temis sequence).
function dispatch.hwe_deliver(now, delivered)
    if not dispatch.horde_warplan() then return false end
    local H = dispatch.hwe
    -- Nothing would run the Horde: never teleport the player into it.
    if type(_G.InfernalHordesPlugin) ~= 'table' then
        dispatch.hwe_status(now, 'InfernalHordesPlugin not loaded — no War Plan teleport')
        return true
    end
    if delivered then dispatch.hwe_missed(now, 'the via-Temis warplan teleport arrived') end
    if H.compass then return true end
    if H.state == 'TELEPORTING' then
        local age = now - H.fired_at
        if age < TELEPORT_CHECK_INTERVAL or (age < dispatch.HORDE_CAST_CAP and dispatch.teleport_casting()) then
            dispatch.hwe_status(now, 'War Plan teleport in flight')
            return true
        end
        H.state = 'IDLE'
        local w, z = dispatch.where()
        dispatch.hwe_missed(now, string.format('War Plan teleport %d%s', H.missed + 1,
            (w == H.snap_world and z == H.snap_zone) and ' did not move the player' or ' arrived'))
    end
    if H.missed >= dispatch.HORDE_WARPLAN_TRIES then
        -- W5-3: only a landing outside the BSK family engages the fallback.
        if settings.horde_compass_fallback == true and not H.landing_bsk then
            H.compass = true
            log(string.format('War Plan Horde entry: %d War Plan teleports did not reach the Horde (last landing %s) — '
                .. 'compass fallback is on: starting HordeDev in compass mode (it uses an Infernal Compass)',
                H.missed, tostring(H.landing)))
            return true
        end
        H.backoff_until = H.backoff_until or now + dispatch.HORDE_WARPLAN_BACKOFF
        if now < H.backoff_until then
            dispatch.hwe_status(now, dispatch.hwe_miss_reason())
            if now - (H.logged_at or -math.huge) >= dispatch.HORDE_WARPLAN_BACKOFF then
                H.logged_at = now
                log(string.format('War Plan Horde entry: still waiting — %s; retrying in %.0fs',
                    dispatch.hwe_miss_reason(), H.backoff_until - now))
            end
            return true
        end
        H.missed, H.backoff_until, H.round = 0, nil, H.round + 1
        log(string.format('War Plan Horde entry: retrying the War Plan teleport (round %d)', H.round))
    end
    -- 'Use teleport' on: a round starts with the via-Temis preamble; the
    -- caller re-arms it (the preamble's warplan teleport comes back here as
    -- `delivered` when it misses the Horde).
    if settings.use_teleport_transition and H.missed == 0 then
        dispatch.hwe_status(now, 'via-Temis preamble, then the War Plan teleport')
        return false
    end
    -- C1 / WPD-1: never over live Alfred work or a Looter pickup (bounded).
    local hold = dispatch.companion_hold(now, 'horde_warplan')
    if hold then
        dispatch.hwe_status(now, hold .. ' — holding the War Plan teleport')
        return true
    end
    -- Channel debounce: never re-fire into our own channel.
    local age = now - H.fired_at
    if age < TELEPORT_CHECK_INTERVAL or (age < dispatch.HORDE_CAST_CAP and dispatch.teleport_casting()) then
        dispatch.hwe_status(now, 'War Plan teleport channel settling')
        return true
    end
    H.fired_at = now
    if not (_G.warplan and type(warplan.teleport_to_activity) == 'function') then
        dispatch.hwe_missed(now, 'warplan.teleport_to_activity() is unavailable')
        return true
    end
    H.snap_world, H.snap_zone = dispatch.where()
    local fired, err = pcall(warplan.teleport_to_activity)
    if not fired then
        dispatch.hwe_missed(now, 'warplan.teleport_to_activity() threw: ' .. tostring(err))
        return true
    end
    H.state = 'TELEPORTING'
    log(string.format('War Plan Horde entry: warplan.teleport_to_activity() called (teleport %d of %d, round %d) — world=%s zone=%s',
        H.missed + 1, dispatch.HORDE_WARPLAN_TRIES, H.round, H.snap_world, H.snap_zone))
    dispatch.hwe_status(now, 'War Plan teleport in flight')
    return true
end

-- entry.enable of InfernalHordes. War Plan mode: enable({entry = 'warplan'})
-- inside the Horde only; enable() only as the logged compass fallback.
function dispatch.hwe_enable(p)
    if type(p.enable) ~= 'function' then
        log('cannot enable InfernalHordesPlugin — no enable function')
        return false
    end
    if not dispatch.horde_warplan() then return p.enable() end
    local H = dispatch.hwe
    if dispatch.inside_horde() then
        if H.state == 'TELEPORTING' or dispatch.delivered then
            local w, z = dispatch.where()
            log(string.format('War Plan Horde entry: %s — landed world=%s zone=%s, inside the Horde',
                H.state == 'TELEPORTING' and 'War Plan teleport arrived' or 'the via-Temis warplan teleport arrived', w, z))
        end
        H.state, H.mode, H.retagged = 'IDLE', 'warplan', nil
        log('starting HordeDev in War Plan entry mode (inside the Horde, no compass)')
        return p.enable({entry = 'warplan'})
    end
    if H.compass then
        H.mode = 'compass'
        log('starting HordeDev in compass mode (compass fallback: the War Plan teleport did not reach the Horde)')
        return p.enable()
    end
    log('War Plan Horde entry: not inside the Horde — not starting HordeDev (no compass)')
    return false
end

-- W5-1: a HordeDev WarPigs owns inside the Horde that reports another entry
-- mode (adopted on a cold start after a reload mid-horde, or found on and
-- owned) is switched to War Plan mode once: enable({entry = 'warplan'}).
-- HordeDev keeps a healthy run inside the Horde (keep_run_on_enable), and
-- War Plan mode brings its bounded completion (no chest room) and the Leave
-- Dungeon exit. Not for the explicit compass fallback, and only for a
-- HordeDev that publishes entry_mode (i.e. knows the War Plan mode).
function dispatch.hwe_retag(why)
    local H = dispatch.hwe
    if H.retagged or H.mode == 'compass' or not dispatch.horde_warplan() or not dispatch.inside_horde() then return end
    local p = _G.InfernalHordesPlugin
    local st = dispatch.status_of(p)
    if not st or st.enabled ~= true or type(st.entry_mode) ~= 'string' or st.entry_mode == 'warplan' then return end
    H.retagged = true
    log(string.format('InfernalHordesPlugin runs inside the Horde in %s mode (%s) — '
        .. "switching it to War Plan entry mode: enable({entry = 'warplan'}) keeps the current run", st.entry_mode,
        why or 'adopted, not started by WarPigs'))
    local ok, err = pcall(p.enable, {entry = 'warplan'})
    if not ok then
        log('enable({entry = \'warplan\'}) of InfernalHordesPlugin threw: ' .. tostring(err))
        return
    end
    H.mode = 'warplan'
end

-- Joint K1 (round 5): after the Council the Horde quest is gone, so nobody
-- adopts a HordeDev whose toggle was persisted on across a QQT reload in the
-- chest room / boss room; WarPigs only holds its disable (disable_when). In
-- compass mode a horde without a chest room never exits (no stash, no chest
-- phase), so the handoff waited forever. Same one-time retag as W5-1, only for
-- a HordeDev WarPigs does not own (never the explicit compass fallback: that
-- one is owned); HordeDev then takes its War Plan exit (Leave Dungeon).
function dispatch.hwe_retag_orphan()
    if owned.InfernalHordesPlugin then return end
    dispatch.hwe_retag('on inside the Horde after its War Plan quest ended, not started by WarPigs')
end

-- Joint K2 (round 5): once the Horde quest is gone (after the Council), the
-- disable phase's C2 `in_run == false` release also fired for a War Plan run
-- that was merely out of the Horde on a trip HordeDev did not start: Alfred's
-- own teleport cycle from the chest room, whose portal returns into the same
-- horde and its chests. WarPigs released HordeDev in Temis and the turn-in
-- then teleported out of BSK after Alfred's return: chests and Leave Dungeon
-- lost. Such a run (War Plan mode, quest no longer wanted, no 'completed', no
-- fault) is held while C1 Alfred live work (its return teleport included) or
-- a teleport cast lasts, then HORDE_DONE_SETTLE; bounded by HORDE_TRIP_CAP.
-- Without that trip (a forced leave, a revive outside) it is released at once
-- as before. While the quest is wanted, hwe_run_finished (W5-2) decides.
-- `L` is the caller's state table {since, busy_at}.
dispatch.HORDE_TRIP_CAP = 180.0  -- same cap as ALFRED_MAX_SECONDS
function dispatch.hwe_left_hold(st, now, L)
    if dispatch.horde_wanted or not dispatch.horde_warplan() or st.entry_mode ~= 'warplan'
        or st.last_result == 'completed' or (type(st.fault) == 'string' and st.fault ~= '')
        or dispatch.inside_horde() then
        L.since, L.busy_at = nil, nil
        return false
    end
    if dispatch.alfred_busy(now) or dispatch.teleport_casting() then
        L.since, L.busy_at = L.since or now, now
        if now - L.since < dispatch.HORDE_TRIP_CAP then
            return true, 'HordeDev War Plan run is out of the Horde during an Alfred trip or a teleport '
                .. '(chests/exit not done; Alfred returns into the same horde)'
        end
    elseif L.busy_at and now - L.busy_at < dispatch.HORDE_DONE_SETTLE then
        return true, 'HordeDev War Plan run is out of the Horde (settling after the Alfred trip or teleport)'
    end
    if L.since then
        log(string.format('HordeDev War Plan run is still out of the Horde %.0fs after an Alfred trip or teleport '
            .. 'began — releasing it', now - L.since))
    end
    L.since, L.busy_at = nil, nil
    return false
end

-- Disable phase, InfernalHordes wanted and on. True when it must be released:
--   * a HordeDev WarPigs did not start that is on outside the Horde without
--     a run (persisted toggle, manual enable): it would farm with a compass;
--   * W5-2, a War Plan run WarPigs owns outside the Horde: finished only on
--     last_result 'completed' (no own Alfred trip, no exit in progress) for
--     HORDE_DONE_SETTLE, or when in_run == false has held HORDE_LEFT_SETTLE
--     with no C1 Alfred live work and no teleport cast (a trip HordeDev did
--     not start, e.g. Alfred's own teleport cycle, returns into the same
--     horde; a revive outside is released after the bound). HordeDev never
--     starts a second cycle, so the next War Plan Horde gets its own
--     teleport (back-to-back);
--   * a run HordeDev reports in compass mode (the retag was refused) as soon
--     as in_run == false outside the Horde: its own start_dungeon would use a
--     compass seconds later.
-- The explicit compass fallback keeps HordeDev's own farming cycle.
function dispatch.hwe_run_finished(now, by_warpigs)
    local H = dispatch.hwe
    -- An enable() of ours still unconfirmed (R8) is not a foreign start.
    by_warpigs = by_warpigs or dispatch.unconfirmed.InfernalHordesPlugin ~= nil
    if by_warpigs then dispatch.hwe_retag() end
    local st = dispatch.horde_warplan() and not dispatch.inside_horde() and dispatch.status_of(_G.InfernalHordesPlugin)
    if not st or st.enabled ~= true or (by_warpigs and H.mode == 'compass') then
        H.done_since, H.left_since, H.busy_since, H.busy_logged = nil, nil, nil, nil
        return false
    end
    if not by_warpigs then
        H.done_since, H.left_since, H.busy_since, H.busy_logged = nil, nil, nil, nil
        if st.in_run ~= false then return false end
        log('InfernalHordesPlugin is on outside the Horde without a run and was not started by WarPigs — '
            .. 'stopping it (War Plan entry: HordeDev starts inside the Horde, no compass)')
        return true
    end
    if st.last_result == 'completed' and st.alfred_trip ~= true and st.exit_pending ~= true then
        H.left_since, H.busy_since, H.busy_logged = nil, nil, nil
        H.done_since = H.done_since or now
        if now - H.done_since < dispatch.HORDE_DONE_SETTLE then return false end
        H.done_since = nil
        log('HordeDev finished its War Plan run (completed) — releasing it; '
            .. 'the next War Plan Horde gets a new War Plan teleport')
        return true
    end
    H.done_since = nil
    if st.in_run ~= false then
        H.left_since, H.busy_since, H.busy_logged = nil, nil, nil
        return false
    end
    if st.entry_mode == 'compass' then
        H.left_since, H.busy_since, H.busy_logged = nil, nil, nil
        log('HordeDev (compass mode) is out of the Horde without a run — releasing it before its compass entry; '
            .. 'the next War Plan Horde gets a new War Plan teleport')
        return true
    end
    -- C6: the keep while C1 Alfred live work or a teleport cast lasts is
    -- bounded by HORDE_TRIP_CAP, measured from the first busy sample of this
    -- out-of-Horde episode (a flapping Alfred flag cannot extend it), logged
    -- once and shown in the status line (dispatch.status_suffix).
    if dispatch.alfred_busy(now) or dispatch.teleport_casting() then
        H.left_since = nil
        H.busy_since = H.busy_since or now
        local held = now - H.busy_since
        if held < dispatch.HORDE_TRIP_CAP then
            if not H.busy_logged then
                H.busy_logged = true
                log(string.format('HordeDev War Plan run is out of the Horde during Alfred work or a teleport — '
                    .. 'holding it (up to %.0fs)', dispatch.HORDE_TRIP_CAP))
            end
            return false
        end
        H.busy_since, H.busy_logged = nil, nil
        log(string.format('HordeDev War Plan run is still out of the Horde %.0fs after Alfred work or a teleport '
            .. 'began — releasing it; the War Plan Horde gets a new War Plan teleport', held))
        return true
    end
    H.left_since = H.left_since or now
    if now - H.left_since < dispatch.HORDE_LEFT_SETTLE then return false end
    H.left_since, H.busy_since, H.busy_logged = nil, nil, nil
    log(string.format('HordeDev left the Horde without a completed run (in_run=false outside the Horde for %.0fs, '
        .. 'no Alfred work, no teleport) — releasing it; the War Plan Horde gets a new War Plan teleport',
        dispatch.HORDE_LEFT_SETTLE))
    return true
end

-- Cold-start adoption (tick): in War Plan mode a HordeDev that is on outside
-- the Horde and not in a run is not adopted (hwe_run_finished stops it).
function dispatch.adoptable(plugin_name)
    if plugin_name ~= 'InfernalHordesPlugin' or not dispatch.horde_warplan() or dispatch.inside_horde() then
        return true
    end
    local st = dispatch.status_of(_G.InfernalHordesPlugin)
    return st ~= nil and st.in_run == true
end

-- WPD-6 / RPR-7: account for a finished Reaper run once. A run that failed
-- (on_complete('failed'), status last_result/failed, or a self-stop without
-- any completion callback from Reaper <= 1.9.1) puts its boss on a growing
-- cooldown so the same failing boss is not re-dispatched forever and other
-- WarPlans can run. `by_warpigs` marks a stop WarPigs requested itself.
function dispatch.reaper_run_ended(now, by_warpigs)
    local R = reaper_run_once
    if not R.started or R.accounted or not R.boss then return end
    R.accounted = true
    local result, reason = R.result, nil
    if by_warpigs and not R.complete then return end
    local st = dispatch.status_of(_G.ReaperPlugin)
    if st then
        if result == nil and type(st.last_result) == 'string' then result = st.last_result end
        if result == nil and st.failed == true then result = 'failed' end
        reason = (type(st.last_error) == 'string' and st.last_error)
            or (type(st.failure_reason) == 'string' and st.failure_reason) or nil
    end
    if result == nil then result, reason = 'failed', reason or 'stopped without a completion callback' end
    if result == 'success' then
        dispatch.reaper_backoff[R.boss] = nil
        return
    end
    if result ~= 'failed' then return end
    local b = dispatch.reaper_backoff[R.boss] or {count = 0}
    b.count = b.count + 1
    local delay = math.min(dispatch.REAPER_FAILURE_BACKOFF * 2 ^ (b.count - 1), dispatch.REAPER_BACKOFF_MAX)
    b.until_t, b.reason = now + delay, reason or 'failed'
    dispatch.reaper_backoff[R.boss] = b
    log(string.format('ReaperPlugin run for %s failed (%s) — backing off %.0fs before dispatching it again (failure %d)',
        R.boss, b.reason, delay, b.count))
end

function dispatch.reaper_backed_off(entry, now)
    local b = entry.boss_id and dispatch.reaper_backoff[entry.boss_id]
    return b ~= nil and now < b.until_t
end

-- CRT-5: a WarPlans quest that matches no map key would stall silently
-- (WarPug waits for it to finish). Log each one once and keep the current
-- list for the status line.
function dispatch.note_unmapped(names, patterns)
    local current = {}
    for _, name in ipairs(names) do
        local mapped = false
        for _, pattern in ipairs(patterns) do
            if name:find(pattern, 1, true) then mapped = true; break end
        end
        if not mapped then
            current[#current + 1] = name
            if not dispatch.unmapped_logged[name] then
                dispatch.unmapped_logged[name] = true
                log('unmapped WarPlans quest "' .. name .. '" — no WarPigs map key matches it, so no plugin '
                    .. 'will run it (check the quest name and the quest_plugin_map key)')
            end
        end
    end
    dispatch.unmapped = current
end

-- W5-4: an owned plugin that reports enabled == false while its C2 in_run is
-- true (HordeDev in the Horde, Arkham in the Pit, WonderCity in an Undercity,
-- their own Alfred trip or committed entry) was paused by the user (its
-- hotkey), it did not disable itself: WarPigs keeps owning it, arms no
-- teleport and does not re-enable it (that would silently override the
-- pause); the wait is logged once and shown in the status line. It resumes
-- managing the plugin as soon as it reports enabled again. in_run == false
-- or no C2 in_run is a real self-disable (unchanged handling). Called every
-- tick for each owned plugin; returns true while it is paused.
function dispatch.user_paused(plugin_name, running, now)
    local P = dispatch.paused[plugin_name]
    local st = not running and dispatch.status_of(_G[plugin_name])
    if st and st.enabled == false and st.in_run == true then
        if not P then
            dispatch.paused[plugin_name] = {since = now}
            log(plugin_name .. ' paused by its hotkey — WarPigs waiting (it reports a run in progress: '
                .. 'no teleport, no re-enable until it reports enabled again)')
        end
        return true
    end
    if P then
        dispatch.paused[plugin_name] = nil
        if running then
            log(string.format('%s reports enabled again after %.0fs — WarPigs manages it again',
                plugin_name, now - P.since))
        end
    end
    return false
end

-- CRT-6 / L4: nothing WarPigs manages is on, pending disable or inside its
-- post-disable gap, so no exit plugin can still be steering the player.
function dispatch.activity_quiet(owned_, pending_, managed_, disabled_at_, now, gap)
    if next(owned_) ~= nil or next(pending_) ~= nil then return false end
    for plugin_name in pairs(managed_) do
        if is_plugin_on(plugin_name) then return false end
    end
    for _, stopped_at in pairs(disabled_at_) do
        if now - stopped_at < gap then return false end
    end
    return true
end

-- R4 / R8: a wanted plugin whose start keeps failing without any gate: a
-- refused Reaper run_once (e.g. 'belial_chest_disabled', a manual 'busy') or
-- an enable() that never produces an enabled status. Returns a reason or nil.
function dispatch.stalled_enable(wants_)
    local R = reaper_run_once
    for plugin_name, entry in pairs(wants_) do
        if R.refused_boss and entry.boss_id == R.refused_boss then
            return string.format('Reaper refused %s: %s', tostring(R.refused_boss), tostring(R.refuse_reason))
        end
        if dispatch.unconfirmed[plugin_name] and not owned[plugin_name] then
            return string.format('%s enable not confirmed (retrying every %.0fs)', plugin_name, dispatch.ENABLE_RETRY)
        end
        -- C6: the War Plan Horde entry is waiting (stable text for the watchdog).
        local H = dispatch.hwe
        if plugin_name == 'InfernalHordesPlugin' and not owned[plugin_name] and dispatch.horde_warplan()
            and H.reason_at and get_time_since_inject() - H.reason_at <= 2
        then
            return plugin_name .. ' ' .. dispatch.HORDE_WAIT_REASON
        end
    end
    return nil
end

-- End-of-tick cleanup: capped re-arm counts (WPD-3), unconfirmed enables
-- (R8) and a Reaper refusal (R4) belong to the current want only.
function dispatch.forget_unwanted(wants_)
    for plugin_name in pairs(dispatch.gate_denials) do
        if not wants_[plugin_name] then dispatch.gate_denials[plugin_name] = nil end
    end
    for plugin_name in pairs(dispatch.unconfirmed) do
        if not wants_[plugin_name] or owned[plugin_name] then dispatch.unconfirmed[plugin_name] = nil end
    end
    -- War Plan Horde entry: the delivery belongs to one want; an enabled
    -- HordeDev ends it (its mode is kept while it is owned).
    local H = dispatch.hwe
    -- Joint K2: read by hwe_left_hold (the disable phase of the next tick).
    dispatch.horde_wanted = wants_.InfernalHordesPlugin ~= nil
    if not wants_.InfernalHordesPlugin or not dispatch.horde_warplan() then
        if H.state ~= 'IDLE' or H.missed > 0 or H.compass or H.mode or H.reason then
            dispatch.hwe = dispatch.hwe_new(H.fired_at)
        end
    elseif owned.InfernalHordesPlugin then
        H.state, H.missed, H.round, H.backoff_until, H.compass, H.reason = 'IDLE', 0, 1, nil, false, nil
    else
        -- W5-1: the once-per-ownership War Plan retag belongs to one owner.
        H.retagged, H.left_since, H.busy_since, H.busy_logged = nil, nil, nil, nil
    end
    local R = reaper_run_once
    if R.refused_boss then
        local wanted = false
        for _, entry in pairs(wants_) do
            if entry.boss_id == R.refused_boss then wanted = true; break end
        end
        if not wanted then R.refused_boss, R.refuse_reason = nil, nil end
    end
end

-- C6 watchdog: track the gate that currently holds a wanted activity, show it
-- in the status line after GATE_STATUS_SECS and log it (rate-limited) after
-- GATE_LOG_SECS. Reporting only: loot-safety gates are not forced here.
-- R1: `state` is the teleport-transition state; the companion hold its gate
-- reported last is shown with it (display only, the held time is the gate's).
-- R4 / R8: without a gate, a refused or unconfirmed enable is the reason.
function dispatch.watch_gate(now, gate_reason, wants_, pending_, task_matches_, pending_teleport, holding, state)
    local reason = gate_reason or dispatch.stalled_enable(wants_)
    local has_work = next(wants_) ~= nil or next(pending_) ~= nil
    for _, matched in pairs(task_matches_) do
        if matched then has_work = true; break end
    end
    if not has_work then reason = nil end
    local detail
    if reason then
        local pd = next(pending_)
        if pd and dispatch.disable_reason[pd] then
            reason = reason .. ' (' .. dispatch.disable_reason[pd] .. ')'
        elseif pending_teleport and type(holding) == 'string' then
            reason = 'teleport pending: ' .. holding
        else
            local gate = state and dispatch.TRANSITION_GATE[state]
            local h = gate and dispatch.hold_reasons[gate]
            local tolerance = gate and (dispatch.GATE_CADENCE[gate] or 0.5) + dispatch.GATE_MARGIN
            if h and now - h.at <= tolerance then detail = h.reason end
        end
    end
    local W = dispatch.watchdog
    if reason ~= W.reason then W.reason, W.since, W.logged_at = reason, now, nil end
    W.detail = detail
    if not reason then return end
    local held = now - W.since
    if held >= dispatch.GATE_LOG_SECS and (not W.logged_at or now - W.logged_at >= dispatch.GATE_LOG_SECS) then
        W.logged_at = now
        log(string.format('watchdog: handoff gate held for %.0fs — %s%s', held, reason,
            detail and (' (' .. detail .. ')') or ''))
    end
end

-- Status-line decorations: long-held gate (C6), Reaper cooldowns (WPD-6),
-- refused or unconfirmed enables (R4 / R8, shown at once).
function dispatch.status_suffix(now)
    local parts = {}
    local W = dispatch.watchdog
    local shown = ''
    if W.reason and W.since and now - W.since >= dispatch.GATE_STATUS_SECS then
        shown = W.reason
        parts[#parts + 1] = string.format('held %.0fs: %s%s', now - W.since, W.reason,
            W.detail and (' (' .. W.detail .. ')') or '')
    end
    -- W5-4: a user pause of an owned plugin, shown at once (once).
    for plugin_name in pairs(dispatch.paused) do
        local text = plugin_name .. ' paused by its hotkey — WarPigs waiting'
        if owned[plugin_name] and not shown:find(text, 1, true) then parts[#parts + 1] = text end
    end
    for boss, b in pairs(dispatch.reaper_backoff) do
        if now < b.until_t then
            parts[#parts + 1] = string.format('Reaper %s backed off %.0fs', boss, b.until_t - now)
        end
    end
    local R = reaper_run_once
    if R.refused_boss and not shown:find('Reaper refused', 1, true) then
        parts[#parts + 1] = string.format('Reaper refused %s: %s (retrying every %.0fs)',
            tostring(R.refused_boss), tostring(R.refuse_reason), REAPER_REFUSE_RETRY)
    end
    for plugin_name, u in pairs(dispatch.unconfirmed) do
        if not owned[plugin_name] and not shown:find(plugin_name .. ' enable not confirmed', 1, true) then
            parts[#parts + 1] = string.format('%s enable not confirmed (%d tries, retrying every %.0fs)',
                plugin_name, u.count, dispatch.ENABLE_RETRY)
        end
    end
    -- War Plan Horde entry: what the delivery waits for, shown at once (a
    -- loading screen, when tick() does not run, keeps the last reason).
    local H = dispatch.hwe
    if H.busy_since and owned.InfernalHordesPlugin then
        parts[#parts + 1] = string.format('Horde: HordeDev out of the Horde during Alfred work or a teleport — '
            .. 'holding %.0fs of %.0fs', now - H.busy_since, dispatch.HORDE_TRIP_CAP)
    end
    if H.reason and H.reason_at and now - H.reason_at <= 10 and not owned.InfernalHordesPlugin then
        parts[#parts + 1] = 'Horde: ' .. H.reason .. ((H.backoff_until and now < H.backoff_until)
            and string.format(' — retrying the War Plan teleport in %.0fs', H.backoff_until - now) or '')
    end
    if #parts == 0 then return '' end
    return ' | ' .. table.concat(parts, ' | ')
end

-- Master stop: forget every hold, counter and cooldown.
function dispatch.reset()
    dispatch.hold, dispatch.notes, dispatch.gate_denials = {}, {}, {}
    dispatch.disable_reason, dispatch.watchdog, dispatch.reaper_backoff = {}, {}, {}
    dispatch.unmapped, dispatch.hold_reasons, dispatch.unconfirmed = {}, {}, {}
    dispatch.paused = {}
    dispatch.delivered = false
    dispatch.hwe = dispatch.hwe_new(dispatch.hwe.fired_at)
    -- C1 / WPT-3: the next session starts without Alfred holds or latches.
    alfred_gate.visit_trigger_at, alfred_gate.visit_alfred = nil, nil
    alfred_gate.paused_since, alfred_gate.paused_logged = nil, false
    alfred_gate.unreadable_since, alfred_gate.unreadable_logged = nil, false
    alfred_gate.kick_deferred_logged = false
end

-- QQT runs LuaJIT (Lua 5.1 rules): a function may capture at most 60
-- upvalues, otherwise this whole file fails to compile and WarPigs never
-- loads. tick() reads its read-only constants through this one table so it
-- keeps a safe margin below that limit.
local TICK_CONSTANTS = {
    TRANSITION_GAP_SECONDS      = TRANSITION_GAP_SECONDS,
    MAX_DISABLE_DEFER_SECONDS   = MAX_DISABLE_DEFER_SECONDS,
    SAME_ACTIVITY_SECS          = SAME_ACTIVITY_SECS,
    POST_ALFRED_SETTLE_SECONDS  = POST_ALFRED_SETTLE_SECONDS,
    TELEPORT_CHECK_INTERVAL     = TELEPORT_CHECK_INTERVAL,
    TELEPORT_INCOMING_SETTLE    = TELEPORT_INCOMING_SETTLE,
    TEMIS_TELEPORT_DEBOUNCE     = TEMIS_TELEPORT_DEBOUNCE,
    TEMIS_WP                    = TEMIS_WP,
    TEMIS_LINGER_RETRY_INTERVAL = TEMIS_LINGER_RETRY_INTERVAL,
    TEMIS_TELEPORT_TIMEOUT      = TEMIS_TELEPORT_TIMEOUT,
    ALFRED_MIN_DWELL            = ALFRED_MIN_DWELL,
    ALFRED_PICKUP_TIMEOUT       = ALFRED_PICKUP_TIMEOUT,
    ALFRED_MAX_SECONDS          = ALFRED_MAX_SECONDS,
    TURN_IN_PATTERN             = TURN_IN_PATTERN,
    PLUGIN_PRIORITY             = PLUGIN_PRIORITY,
}

function orchestrator.tick()
    local C = TICK_CONSTANTS
    local TRANSITION_GAP_SECONDS      = C.TRANSITION_GAP_SECONDS
    local MAX_DISABLE_DEFER_SECONDS   = C.MAX_DISABLE_DEFER_SECONDS
    local SAME_ACTIVITY_SECS          = C.SAME_ACTIVITY_SECS
    local POST_ALFRED_SETTLE_SECONDS  = C.POST_ALFRED_SETTLE_SECONDS
    local TELEPORT_CHECK_INTERVAL     = C.TELEPORT_CHECK_INTERVAL
    local TELEPORT_INCOMING_SETTLE    = C.TELEPORT_INCOMING_SETTLE
    local TEMIS_TELEPORT_DEBOUNCE     = C.TEMIS_TELEPORT_DEBOUNCE
    local TEMIS_WP                    = C.TEMIS_WP
    local TEMIS_LINGER_RETRY_INTERVAL = C.TEMIS_LINGER_RETRY_INTERVAL
    local TEMIS_TELEPORT_TIMEOUT      = C.TEMIS_TELEPORT_TIMEOUT
    local ALFRED_MIN_DWELL            = C.ALFRED_MIN_DWELL
    local ALFRED_PICKUP_TIMEOUT       = C.ALFRED_PICKUP_TIMEOUT
    local ALFRED_MAX_SECONDS          = C.ALFRED_MAX_SECONDS
    local TURN_IN_PATTERN             = C.TURN_IN_PATTERN
    local PLUGIN_PRIORITY             = C.PLUGIN_PRIORITY
    local bridge_now = get_time_since_inject()
    if not raven_bridge:observe(bridge_now, settings.manage_whispers == true) then return end
    if raven_bridge:is_busy() and raven_bridge:tick(bridge_now, false) then return end
    if not settings.use_teleport_transition then
        teleport_pending = false
        teleport_incoming_first_seen = nil
        teleport_transition.state = 'IDLE'
        teleport_transition.snap_world = nil
        teleport_transition.snap_zone = nil
    end
    if settings.log_all_quests then dump_all_quests() end

    -- Death recovery — handle this before any other state, in case the player
    -- got killed during the native teleport sequence (mob aggro on
    -- the way out of town, late-arriving boss attack, etc).  When dead we
    --   (1) abort any in-flight transition + re-arm so it restarts after
    --       respawn — the native teleport may have been interrupted,
    --   (2) call revive_at_checkpoint() each tick until it takes,
    --   (3) early-return so the orchestrator doesn't try to drive plugins
    --       while the player is on the death screen.
    local lp = get_local_player()
    if lp and lp:is_dead() then
        if not was_dead then
            log('player died — aborting any in-flight transition and reviving')
            was_dead = true
        end
        if teleport_transition.state ~= 'IDLE' then
            log('died mid-transition (state=' .. teleport_transition.state ..
                ') — re-arming teleport sequence for after respawn')
            teleport_transition.state             = 'IDLE'
            teleport_transition.started_at        = -math.huge
            teleport_transition.alfred_fired_at   = nil
            teleport_transition.alfred_was_busy   = false
            teleport_transition.alfred_picked_up  = false
            teleport_transition.settle_started_at = nil
            teleport_transition.helltide_hold_logged = false
            teleport_pending                      = true
            teleport_incoming_first_seen          = nil
            teleport_holding_logged               = false
        elseif settings.use_teleport_transition and not teleport_pending and next(owned) == nil then
            -- Death outside an active transition still likely cancelled any
            -- in-progress in-game teleport channel (common when a mob hits
            -- you during the 3-5s teleport cast).  Arm the sequence so we
            -- retry navigation after respawn when no activity owns the player.
            teleport_pending = true
        end
        revive_at_checkpoint()
        return
    end
    if was_dead then
        log('player revived — resuming orchestrator')
        was_dead = false
    end

    -- A live player handle can survive into Limbo/loading. Do not turn an
    -- empty quest snapshot there into completion or a new activity handoff.
    local loaded_ok, loaded = pcall(function()
        local world = get_current_world()
        if not world then return false end
        local name, zone = world:get_name(), world:get_current_zone_name()
        return type(name) == 'string' and name ~= '' and name ~= 'Limbo'
            and type(zone) == 'string' and zone ~= '' and zone ~= '[sno none]'
    end)
    if not loaded_ok or not loaded then return end
    dispatch.observe_alfred_visit()

    check_reaper_altar_watchdog()

    local active_names = get_active_quest_names()
    if not active_names then return end
    local now          = get_time_since_inject()

    -- Compute which plugins should be enabled this tick, and drive any
    -- task entries directly. Matching is plain substring (string.find
    -- with plain=true).
    local wants          = {}  -- plugin_name -> entry to use for enable hook
    local matches        = {}  -- pattern -> true (verbose tracking)
    local matched_reason = {}  -- plugin_name -> first matching pattern (log)
    local task_matches = {}
    local patterns = {}
    for pattern in pairs(orchestrator.quest_plugin_map) do patterns[#patterns + 1] = pattern end
    -- Prefer the most specific alias, with a stable tie-breaker. Retain the
    -- current reason while it still matches instead of switching bosses on
    -- Lua's unspecified table iteration order.
    table.sort(patterns, function(a, b)
        if #a ~= #b then return #a > #b end
        return a < b
    end)
    for _, pattern in ipairs(patterns) do
        local entry = normalize(orchestrator.quest_plugin_map[pattern])
        local matched = pattern_has_match(pattern, active_names)
        if matched then matches[pattern] = true end
        if entry.task then
            task_matches[pattern] = matched
        elseif matched and entry.plugin and not dispatch.reaper_backed_off(entry, now) then
            if not wants[entry.plugin] or last_enabled_reason[entry.plugin] == pattern then
                wants[entry.plugin] = entry
                matched_reason[entry.plugin] = pattern
            end
        end
    end
    dispatch.note_unmapped(active_names, patterns)
    -- Reward turn-in owns the same movement/teleport channel as activities.
    -- Finish it before starting a simultaneously visible next activity.
    if matches[TURN_IN_PATTERN] then
        wants = {}
        matched_reason = {}
    end

    -- ── PREEMPTION ──────────────────────────────────────────────────────────
    -- When multiple activity plugins match at the same time, only the highest
    -- priority one stays wanted. Demoted plugins fall through to the disable
    -- phase (disable_when still applies, so an in-flight activity gets to
    -- wrap up before being cut). Priorities are static — see PLUGIN_PRIORITY.
    do
        local max_priority = -1
        local max_owner    = nil
        for plugin_name in pairs(wants) do
            local p = PLUGIN_PRIORITY[plugin_name] or 0
            if p > max_priority then
                max_priority = p
                max_owner    = plugin_name
            end
        end
        if max_priority > 0 then
            for plugin_name in pairs(wants) do
                local p = PLUGIN_PRIORITY[plugin_name] or 0
                if p < max_priority then
                    log(string.format('preempting %s (priority %d) — %s (priority %d) also matched',
                        plugin_name, p, max_owner, max_priority))
                    wants[plugin_name]          = nil
                    matched_reason[plugin_name] = nil
                end
            end
        end
    end

    -- An already-running matching activity owns its current run. Adopt it
    -- without resetting its chest/entry state or starting a cold-start town
    -- detour through the middle of that run.
    -- War Plan Horde entry: not a HordeDev that is on outside the Horde
    -- without a run (it would farm with a compass; see dispatch.adoptable).
    if not had_active_session then
        for plugin_name in pairs(wants) do
            if is_plugin_on(plugin_name) and dispatch.adoptable(plugin_name) then
                owned[plugin_name] = true
                last_enabled_reason[plugin_name] = matched_reason[plugin_name]
                last_wanted[plugin_name] = true
                had_active_session = true
                log('adopted active ' .. plugin_name .. ' — preserving current run')
            end
        end
    end

    if settings.verbose_logs then
        for pattern in pairs(matches) do
            if not last_matches[pattern] then log('trigger matched: ' .. pattern) end
        end
        for pattern in pairs(last_matches) do
            if not matches[pattern] then log('trigger unmatched: ' .. pattern) end
        end
    end

    -- ── RUN PIT AFTER TURN-IN ───────────────────────────────────────────────
    -- Track the turn-in pattern's matched→unmatched edge.  First time we see
    -- it, arm the pit filler for the rest of the session.  This way cold-start
    -- with no WarPlans quests doesn't auto-launch pit — the user has to have
    -- completed at least one WarPlans cycle first.
    local turn_in_matched_now = matches[TURN_IN_PATTERN] == true
    if turn_in_was_matched and not turn_in_matched_now then
        if not had_turn_in_complete then
            had_turn_in_complete = true
            log('turn-in cycle completed — pit filler armed (run_pit_after_turnin)')
        end
        -- R6 / WPG-7: the turn-in consumed the pending teleport (task-only
        -- skip). The first activity of the next plan needs the native
        -- transition too; with nothing incoming yet this is only an idle
        -- intention (the Whisper slot stays open, see WPT-2).
        if settings.use_teleport_transition and not teleport_pending then
            teleport_pending             = true
            teleport_incoming_first_seen = nil
            log('teleport queued — turn-in finished (next plan)')
        end
    end
    turn_in_was_matched = turn_in_matched_now

    -- Inject ArkhamAsylumPlugin as filler when:
    --   • setting on
    --   • turn-in has happened at least once this session
    --   • no real WarPlans plugin matched this tick (next(wants) == nil)
    --   • no internal task is currently active (turn-in mid-flight, etc.)
    -- Done AFTER preemption so a real WarPlans match always wins; the filler
    -- only ever fills empty gaps.  When a new WarPlans quest arrives next
    -- tick, the filler skips this block and the normal disable phase pulls
    -- ArkhamAsylumPlugin out (deferred by its in_town_disable_when).
    if settings.run_pit_after_turnin
        and had_turn_in_complete
        and next(wants) == nil
        and not plan_creator_enabled()
    then
        local any_task_active = false
        for pattern, raw_entry in pairs(orchestrator.quest_plugin_map) do
            if matches[pattern] then
                local entry = normalize(raw_entry)
                if entry.task then any_task_active = true; break end
            end
        end
        if not any_task_active then
            local arkham_entry
            for _, raw in pairs(orchestrator.quest_plugin_map) do
                local entry = normalize(raw)
                if entry.plugin == 'ArkhamAsylumPlugin' then
                    arkham_entry = entry
                    break
                end
            end
            if arkham_entry then
                wants['ArkhamAsylumPlugin']          = arkham_entry
                matched_reason['ArkhamAsylumPlugin'] = 'filler:run_pit_after_turnin'
                -- No active WarPlan exists for the native quest teleport.
                -- Arkham drives its own navigation for filler runs.
                if teleport_pending then
                    teleport_pending             = false
                    teleport_incoming_first_seen = nil
                    teleport_holding_logged      = false
                end
                if not pit_filler_active_logged then
                    log('pit filler engaged — no WarPlans quest active, enabling ArkhamAsylumPlugin (teleport sequence skipped)')
                    pit_filler_active_logged = true
                end
            end
        elseif pit_filler_active_logged then
            -- A task is now active (typically turn-in just appeared) — yield
            -- the filler back so future cycles re-log on re-engage.
            pit_filler_active_logged = false
        end
    elseif pit_filler_active_logged then
        -- A real WarPlans plugin matched, or setting was turned off — log the yield.
        log('pit filler yielding — WarPlans activity resumed')
        pit_filler_active_logged = false
    end

    -- ── COLD-START TELEPORT ─────────────────────────────────────────────────
    -- For the very first activity in a WarPigs session there's no preceding
    -- plugin_disable to arm the teleport, so detect "we have something to do
    -- AND have never run before" and fire the sequence here. Plugin →
    -- plugin and plugin → task transitions are armed inside plugin_disable
    -- (which only fires after disable_when satisfies — i.e. AFTER chests
    -- are looted, Alfred has salvaged, and the player is back in town).
    if settings.use_teleport_transition and not had_active_session then
        local has_any_plugin_want = next(wants) ~= nil
        local has_any_task_match  = false
        for pattern, raw_entry in pairs(orchestrator.quest_plugin_map) do
            if matches[pattern] then
                local entry = normalize(raw_entry)
                if entry.task then has_any_task_match = true; break end
            end
        end
        if has_any_plugin_want or has_any_task_match then
            -- WPD-2 / WCY-4: evaluate arrival BEFORE the trip. Already inside
            -- the incoming activity (BSK for a horde, an X1_Undercity_* or
            -- PIT_* run, a helltide) means WarPigs was (re)started mid-run:
            -- enable the owner in place instead of teleporting out of it.
            local in_place = dispatch.incoming_in_place(wants, true)
            if in_place then
                log('cold start: already inside the ' .. in_place .. ' activity — enabling it in place (teleport sequence skipped)')
            else
                log('teleport queued — cold start (first activity of session)')
                teleport_pending = true
            end
            had_active_session = true
        end
    elseif not had_active_session
        and (next(wants) ~= nil or next(matches) ~= nil)
    then
        -- Even with the option off, mark that we've seen activity so a later
        -- toggle of "Use teleport" doesn't retro-trigger a cold-start fire.
        had_active_session = true
    end

    -- ── DISABLE PHASE (runs first) ──────────────────────────────────────────
    -- Every managed plugin without a matching trigger must be off. Honors
    -- disable_when so post-quest wrap-up windows apply. After the deferral
    -- exceeds MAX_DISABLE_DEFER_SECONDS the disable is forced to keep a stuck
    -- activity from blocking the orchestrator forever.
    local managed = get_managed_plugins()
    for plugin_name, entry in pairs(managed) do
        local changed = owned[plugin_name] and wants[plugin_name]
            and matched_reason[plugin_name] ~= last_enabled_reason[plugin_name]
        local running = is_plugin_on(plugin_name)
        -- Reconcile self-disable even while the same quest is still visible.
        -- W5-4: a user (hotkey) pause with C2 in_run is not a self-disable.
        if owned[plugin_name] and not dispatch.user_paused(plugin_name, running, now) and not running then
            last_disable_time[plugin_name] = now
            last_disabled_plugin = plugin_name
            last_disabled_at = now
            last_disabled_reason = last_enabled_reason[plugin_name]
            owned[plugin_name] = nil
            last_wanted[plugin_name] = nil
            last_enabled_reason[plugin_name] = nil
            pending_disable[plugin_name] = nil
            pending_disable_since[plugin_name] = nil
            if settings.use_teleport_transition then teleport_pending = true end
            log('detected self-disable of ' .. plugin_name .. ' — sequencing handoff')
            -- WPD-6: a Reaper run that ended by itself may have failed.
            if plugin_name == 'ReaperPlugin' then dispatch.reaper_run_ended(now, false) end
        end
        -- War Plan Horde entry: a finished War Plan run, or a HordeDev that is
        -- on outside the Horde without WarPigs, is released while its quest
        -- is still wanted (dispatch.hwe_run_finished).
        if running and wants[plugin_name] and type(entry.run_finished) == 'function'
            and entry.run_finished(now, owned[plugin_name] == true)
        then
            changed = true
        end
        if not wants[plugin_name] or changed or pending_disable[plugin_name] then
            if not running and not wants[plugin_name] and owned[plugin_name] and dispatch.paused[plugin_name] then
                -- W5-4: a paused plugin whose quest is gone is still owned;
                -- it holds the handoff (like a deferred disable) until the
                -- user resumes it (then disable_when decides) or WarPigs stops.
                pending_disable[plugin_name] = true
                pending_disable_since[plugin_name] = pending_disable_since[plugin_name] or now
                dispatch.disable_reason[plugin_name] = plugin_name .. ' paused by its hotkey — WarPigs waiting'
            elseif not running then
                pending_disable[plugin_name] = nil
                pending_disable_since[plugin_name] = nil
                dispatch.disable_reason[plugin_name] = nil
                was_off[plugin_name] = true
            else
                local ready = true
                local why
                if entry.disable_when then
                    local ok, result, detail = pcall(entry.disable_when)
                    ready = ok and result == true
                    why = ok and detail or (not ok and ('disable_when error: ' .. tostring(result))) or nil
                end
                if not ready then
                    -- C6: say why the handoff waits; re-log when the reason changes.
                    why = type(why) == 'string' and why or 'cleanup not yet complete'
                    if not pending_disable[plugin_name] or dispatch.disable_reason[plugin_name] ~= why then
                        log('deferring disable of ' .. plugin_name .. ' — ' .. why)
                        pending_disable[plugin_name] = true
                        pending_disable_since[plugin_name] = pending_disable_since[plugin_name] or now
                        dispatch.disable_reason[plugin_name] = why
                    end
                    -- A timeout cannot prove that chests, loot or a RESET are
                    -- complete. Keep waiting; disabling WarPigs remains the
                    -- explicit stop path for a stuck activity.
                    local cap = entry.max_disable_defer_seconds or MAX_DISABLE_DEFER_SECONDS
                    if now - pending_disable_since[plugin_name] >= cap then
                        log('cleanup still pending for ' .. plugin_name .. ' — keeping loot-safe handoff gate')
                        pending_disable_since[plugin_name] = now
                    end
                elseif plugin_disable(entry) then
                    pending_disable[plugin_name] = nil
                    pending_disable_since[plugin_name] = nil
                    last_wanted[plugin_name] = nil
                    was_off[plugin_name] = true
                end
            end
        else
            was_off[plugin_name] = nil
        end
    end

    -- Reserve the optional Whisper slot only after all outgoing cleanup.
    local whisper_safe = next(owned) == nil and next(pending_disable) == nil
    for plugin_name in pairs(managed) do
        if is_plugin_on(plugin_name) then whisper_safe = false; break end
    end
    for _, stopped_at in pairs(last_disable_time) do
        if now - stopped_at < TRANSITION_GAP_SECONDS then whisper_safe = false; break end
    end
    for _, raw in pairs(orchestrator.quest_plugin_map) do
        local entry = normalize(raw)
        if entry.task and type(entry.task.get_state) == 'function' then
            local ok, state = pcall(entry.task.get_state)
            if not ok or (state and state ~= 'IDLE') then whisper_safe = false end
        end
    end
    -- Give town Looter/SilentRaven priority over our Tyrael paths, Alfred
    -- triggers and outgoing teleports. Never mutate the Looter toggle.
    if next(owned) == nil and next(pending_disable) == nil then
        local traffic_reason = raven_bridge:traffic_hold()
        if traffic_reason then
            if teleport_holding_logged ~= traffic_reason then
                log('town movement held — ' .. traffic_reason)
                teleport_holding_logged = traffic_reason
            end
            dispatch.watch_gate(now, 'town movement held — ' .. traffic_reason, wants, pending_disable,
                task_matches, false, nil)
            -- L5: resetting a task whose quest vanished issues no movement,
            -- so the hold must not keep it in a stale state.
            for pattern, matched in pairs(task_matches) do
                if not matched then
                    local ok, err = pcall(normalize(orchestrator.quest_plugin_map[pattern]).task.tick, false)
                    if not ok then log('task error (' .. pattern .. '): ' .. tostring(err)) end
                end
            end
            -- is_busy() must see this tick's quests, not a stale snapshot.
            last_matches = matches
            return
        end
    end
    -- Anything for the teleport sequence to deliver: a wanted plugin or a
    -- matched task quest.
    local has_incoming = next(wants) ~= nil
    if not has_incoming then
        for _, matched in pairs(task_matches) do
            if matched then has_incoming = true; break end
        end
    end
    -- WPT-2 / WPG-3 / SRV-1: a pending teleport with nothing incoming is only
    -- an idle intention (see is_busy). The Whisper slot stays open then:
    -- closing it while blocks_plan_creator() holds WarPug was a circular wait
    -- (the incoming quest can only come from the plan WarPug is not allowed
    -- to create).
    -- R5: an incoming activity or task quest closes the IDLE slot whether or
    -- not a teleport is pending (with 'Use teleport' off none ever is): the
    -- admission wait (up to 120 s) must not keep tick() from starting it.
    -- The via-Temis preamble still offers the slot in POST_ALFRED_SETTLE.
    local whisper_slot = whisper_safe and (
        (teleport_transition.state == 'IDLE' and not has_incoming)
        or teleport_transition.state == 'POST_ALFRED_SETTLE')
    -- The Temis Alfred kick keeps its previous window (R5 changes only the
    -- Whisper admission).
    if whisper_safe and in_temis() and (whisper_slot
        or (teleport_transition.state == 'IDLE' and not teleport_pending))
    then
        alfred_kick_if_needed()
    end
    if raven_bridge:tick(now, whisper_slot) then return end

    -- ── SAME-ACTIVITY CONTINUATION ──────────────────────────────────────────
    -- If the plugin we just disabled is the incoming activity (same quest
    -- pattern re-matched, e.g. back-to-back helltide WarPlans), skip the
    -- warplan teleport entirely. The player is already in the right zone and
    -- firing warplan.teleport_to_activity() would either do nothing (world/zone
    -- unchanged → retry loop) or fight with the plugin's own navigation.
    -- The transition gap (last_disable_time) still applies, giving the game
    -- state a beat to settle before the plugin re-enables.
    --
    -- Per-entry opt-out via same_activity_continuation = false: Infernal
    -- Hordes leaves the player in an empty BSK after the wave; back-to-back
    -- BSK WarPlans need the FULL exit_horde → Temis → Alfred → warplan
    -- teleport sequence to actually re-enter a fresh horde. Without the
    -- opt-out, WarPigs would re-enable HordeDev in place and the player
    -- would be stuck in an empty BSK with no sigil opened.
    if teleport_pending
        and last_disabled_plugin
        and wants[last_disabled_plugin]
        and (now - last_disabled_at) <= SAME_ACTIVITY_SECS
        and matched_reason[last_disabled_plugin] == last_disabled_reason
    then
        local incoming_entry = wants[last_disabled_plugin]
        local opt_out = incoming_entry
            and incoming_entry.same_activity_continuation == false
        if opt_out then
            log(string.format(
                '%s: same-activity continuation OPT-OUT (entry sets same_activity_continuation=false) — proceeding to full transition',
                last_disabled_plugin))
        else
            log(string.format(
                '%s: same-activity continuation pattern=%s (%.1fs since disable) — cancelling teleport, re-enable in place',
                last_disabled_plugin, tostring(last_disabled_reason), now - last_disabled_at))
            teleport_pending             = false
            teleport_incoming_first_seen = nil
            teleport_holding_logged      = false
            last_disabled_plugin         = nil
            last_disabled_reason         = nil
        end
    end

    -- ── TELEPORT TRANSITION (optional) ──────────────────────────────────────
    -- After an activity ends, call warplan.teleport_to_activity() and wait
    -- for the channel to settle before enabling the next plugin. We hold the
    -- call until the incoming quest has been visible for TELEPORT_INCOMING_SETTLE
    -- so warplan data reflects the new activity, and until Alfred finishes any
    -- loot/salvage work.

    -- Shared "fire warplan teleport (or skip)" used both by the IDLE→ready
    -- branch (when via-Temis preamble is unavailable) and by TEMIS_ALFRED on
    -- exit. Decides between three outcomes:
    --   * Task-only incoming (e.g. TurnIn_Rewards) — task drives its own nav,
    --     so we just release the gate (state stays IDLE).
    --   * arrived_when() already true — we're at the destination already, skip.
    --   * Otherwise — fire warplan.teleport_to_activity() and enter TELEPORTING.
    -- `gate` is the companion gate of the caller's state (R1).
    local function start_warplan_teleport(wants_, now_, gate)
        if raven_bridge:tick(now_, whisper_safe) then
            teleport_transition.state = 'POST_ALFRED_SETTLE'
            teleport_transition.settle_started_at = now_ - POST_ALFRED_SETTLE_SECONDS
            return
        end
        local task_only_incoming = next(wants_) == nil
        local already_arrived = false
        for _, entry in pairs(wants_) do
            if type(entry.arrived_when) == 'function' and entry.arrived_when() then
                already_arrived = true
                break
            end
        end
        if task_only_incoming then
            log('teleport skipped — incoming is task-only (handles own navigation)')
            teleport_transition.state = 'IDLE'
        elseif already_arrived then
            log('teleport skipped — quest actor present, already at destination')
            teleport_transition.state = 'IDLE'
        elseif dispatch.warplan_hold(wants_, now_, gate) then
            -- WPD-8 / WPD-1: helltide off-window or a companion still working.
            -- Park in POST_ALFRED_SETTLE (re-checked every tick) on every
            -- path, not only after an Alfred cycle.
            teleport_transition.state = 'POST_ALFRED_SETTLE'
            teleport_transition.settle_started_at = now_ - POST_ALFRED_SETTLE_SECONDS
        else
            teleport_transition.state      = 'TELEPORTING'
            teleport_transition.started_at = now_
            teleport_transition.retries    = 0
            dispatch.delivered             = false
            if _G.warplan and type(warplan.teleport_to_activity) == 'function' then
                local snap_w = get_current_world()
                teleport_transition.snap_world = snap_w and snap_w:get_name()
                teleport_transition.snap_zone  = snap_w and snap_w:get_current_zone_name()
                -- WPT-6: a throwing host binding must not escape tick().
                local fired, err = pcall(warplan.teleport_to_activity)
                if not fired then
                    log('warplan.teleport_to_activity() failed: ' .. tostring(err)
                        .. ' — releasing the gate; the activity navigates itself')
                    teleport_transition.state      = 'IDLE'
                    teleport_transition.snap_world = nil
                    teleport_transition.snap_zone  = nil
                    dispatch.delivered             = true  -- R2: TELEPORTING released
                    return
                end
                log(string.format(
                    'warplan.teleport_to_activity() called — world=%s zone=%s check_in=%.1fs',
                    tostring(teleport_transition.snap_world),
                    tostring(teleport_transition.snap_zone),
                    TELEPORT_CHECK_INTERVAL))
            else
                log('warplan.teleport_to_activity not available — skipping teleport')
                teleport_transition.state = 'IDLE'
                dispatch.delivered        = true  -- R2: TELEPORTING released
            end
        end
    end

    if settings.use_teleport_transition
        and teleport_pending
        and teleport_transition.state == 'IDLE'
    then
        -- has_incoming was computed before the Whisper slot above.
        if not has_incoming then
            teleport_incoming_first_seen = nil
        elseif teleport_incoming_first_seen == nil then
            teleport_incoming_first_seen = now
            log(string.format('teleport: incoming activity matched, settling for %.1fs',
                TELEPORT_INCOMING_SETTLE))
        end
        local incoming_settled = teleport_incoming_first_seen
            and (now - teleport_incoming_first_seen) >= TELEPORT_INCOMING_SETTLE
        -- WPD-1: WarPigs starts Alfred only in Temis while a teleport is
        -- pending. Kicking it in another town and then teleporting away 5 s
        -- later cancelled the very cycle WarPigs had started.
        if in_temis() then alfred_kick_if_needed() end
        -- Pending Alfred WORK (need_trigger / inventory_full) only blocks in
        -- Temis (where it can actually progress). Outside town, "Alfred wants
        -- work" is exactly what the via-Temis preamble is about to enable.
        -- Gating on it here would deadlock us in the activity zone (e.g.
        -- helltide ends with inventory_full set → Alfred can't run outside
        -- town → gate never clears → no TP to town → forever).
        local alfred_done = (not in_temis()) or alfred_idle()
        -- WPD-1 / C1: live Alfred work (a cycle that is running, queued or
        -- teleporting) and an active Looter pickup hold the outgoing teleport
        -- in ANY zone; both holds are bounded (companion_hold). R1: the
        -- 'idle' gate's episode starts once there is something to deliver.
        local companion_hold = has_incoming and dispatch.companion_hold(now, 'idle') or nil

        -- Helltide combat hold: when teleporting out of a helltide zone, the
        -- channel is interrupted by any incoming damage. Wait for the rotation
        -- plugin to clear nearby enemies before firing teleport_to_activity().
        -- Gated on has_helltide_buff() so town-to-town handoffs (Pit/Undercity)
        -- aren't affected — the player is in town, no enemies, no-op.
        -- Bypassed when the helltide quest is over and HR is disabled: nothing
        -- is going to clear the area, so waiting is just waiting to die. The
        -- TO_TEMIS state's fast-retry path handles channel breaks.
        local in_helltide_combat = has_helltide_buff() and enemies_near_player()
            and not helltide_lingering_post_quest(wants)

        local has_pending = next(pending_disable) ~= nil
        local disable_gap = false
        for _, disabled_at in pairs(last_disable_time) do
            if now - disabled_at < TRANSITION_GAP_SECONDS then disable_gap = true; break end
        end
        local horde_block    = horde_teleport_block_reason(owned.InfernalHordesPlugin == true)
        local horde_chesting = horde_block == 'opening_chests'
        local horde_aether   = horde_block == 'has_aether'
        local ready = has_incoming and incoming_settled and alfred_done
            and not companion_hold
            and not has_pending and not in_helltide_combat
            and not horde_block and not disable_gap
        if not ready then
            local reason
            if not has_incoming then
                reason = 'no incoming activity yet'
            elseif horde_aether then
                reason = 'player still holding aether — HordeDev must spend all aether before preamble'
            elseif horde_chesting then
                reason = 'HordeDev is opening chests — chest interact is fragile, refusing to fire Temis preamble'
            elseif has_pending then
                local pname = next(pending_disable)
                reason = 'waiting for ' .. tostring(pname) .. ' to finish (deferred disable)'
            elseif disable_gap then
                reason = 'waiting for the outgoing activity transition gap'
            elseif not alfred_done then
                reason = 'Alfred busy (loot/salvage in progress)'
            elseif companion_hold then
                reason = companion_hold .. ' — holding the outgoing teleport'
            elseif in_helltide_combat then
                reason = 'in helltide combat — waiting for area to clear before teleport'
            else
                local left = TELEPORT_INCOMING_SETTLE - (now - teleport_incoming_first_seen)
                reason = string.format('settling incoming (%.1fs left)', left)
            end
            if teleport_holding_logged ~= reason then
                log('teleport holding — ' .. reason)
                teleport_holding_logged = reason
            end
        else
            teleport_pending             = false
            teleport_incoming_first_seen = nil
            teleport_holding_logged      = false
            -- If incoming is helltide AND HelltideRevamped is already running
            -- OR we're already inside a helltide zone: skip the entire teleport
            -- sequence (including the via-Temis preamble). HR drives its own
            -- navigation in-zone, and yanking the player to Temis just to
            -- warplan-teleport back races with HR's chest/event/teleport calls.
            -- The via-Temis arrived_when fallback can't catch this case because
            -- the preamble teleports us out of helltide before arrived_when
            -- (has_helltide_buff) is evaluated.
            if incoming_is_helltide(wants)
                and (is_plugin_on('HelltideRevampedPlugin') or has_helltide_buff())
            then
                log('teleport skipped — incoming is helltide and HR is already running / in helltide zone')
                teleport_transition.state = 'IDLE'
            elseif dispatch.incoming_in_place(wants, false) then
                -- WPD-2 / WCY-4: evaluate arrived_when BEFORE the via-Temis
                -- trip — never teleport out of an Undercity/Pit run only to
                -- warplan-teleport back into a fresh one.
                log('teleport skipped — already inside the incoming activity ('
                    .. tostring(dispatch.incoming_in_place(wants, false)) .. ')')
                teleport_transition.state = 'IDLE'
            else
                -- Decide whether to begin the via-Temis-Alfred preamble. We always
                -- want to detour through Temis + run Alfred between activities, EXCEPT
                -- when teleport_to_waypoint isn't available on this host (then we
                -- jump straight to the warplan-teleport / skip decision below).
                local can_temis_detour = type(teleport_to_waypoint) == 'function'
                if can_temis_detour and in_temis() then
                    -- Already in Temis: skip the waypoint hop and trigger Alfred now.
                    local alfred_step = alfred_trigger_now()
                    if alfred_step == 'serviced' then
                        -- WPT-3: this visit's WarPigs Alfred cycle completed
                        -- and no hard need came back: settle checks only.
                        teleport_transition.state             = 'POST_ALFRED_SETTLE'
                        teleport_transition.settle_started_at = now - POST_ALFRED_SETTLE_SECONDS
                        log('via-Temis preamble: already in Temis — Alfred already serviced this visit, skipping the Alfred step')
                    elseif alfred_step then
                        teleport_transition.state             = 'TEMIS_ALFRED'
                        teleport_transition.started_at        = now
                        teleport_transition.alfred_fired_at   = now
                        teleport_transition.alfred_was_busy   = false
                        teleport_transition.alfred_picked_up  = false
                        teleport_transition.settle_started_at = nil
                        log('via-Temis preamble: already in Temis — Alfred triggered')
                    else
                        -- Alfred not loaded/enabled — go straight to the warplan
                        -- teleport / skip decision (start_warplan_teleport below).
                        log('via-Temis preamble: Alfred not loaded/enabled — skipping Alfred step')
                        start_warplan_teleport(wants, now, 'idle')
                    end
                elseif can_temis_detour then
                    if (now - teleport_transition.last_temis_tp) >= TEMIS_TELEPORT_DEBOUNCE then
                        teleport_to_waypoint(TEMIS_WP)
                        teleport_transition.last_temis_tp = now
                    end
                    teleport_transition.state      = 'TO_TEMIS'
                    teleport_transition.started_at = now
                    log('via-Temis preamble: teleport_to_waypoint(Temis) sent')
                else
                    -- No teleport_to_waypoint on this host — fall back to the original
                    -- behaviour (warplan teleport directly or skip).
                    start_warplan_teleport(wants, now, 'idle')
                end
            end
        end
    end
    if teleport_transition.state == 'TO_TEMIS' then
        if in_temis() then
            if alfred_trigger_now() then
                teleport_transition.state             = 'TEMIS_ALFRED'
                teleport_transition.started_at        = now
                teleport_transition.alfred_fired_at   = now
                teleport_transition.alfred_was_busy   = false
                teleport_transition.alfred_picked_up  = false
                teleport_transition.settle_started_at = nil
                log('via-Temis preamble: arrived in Temis — Alfred triggered')
            else
                log('via-Temis preamble: arrived in Temis, Alfred not loaded/enabled — proceeding to warplan teleport')
                start_warplan_teleport(wants, now, 'to_temis')
            end
        elseif horde_teleport_block_reason(owned.InfernalHordesPlugin == true) == 'opening_chests' then
            -- The Temis channel was broken (combat in BSK / chest interact
            -- yanked us back) and HordeDev is now mid-chest. Re-firing
            -- teleport_to_waypoint(Temis) here would cancel the chest interact
            -- channel, lose the chest, and abort the run. Hold all retries
            -- (both the helltide-lingering fast retry and the timeout retry)
            -- until HordeDev leaves the chest cycle. started_at is also bumped
            -- so the timeout doesn't accumulate while we're holding — once
            -- chests_done, the normal timeout cadence resumes from now.
            if teleport_transition.chest_hold_logged ~= teleport_transition.started_at then
                log('via-Temis preamble: TO_TEMIS hold — HordeDev is opening chests, refusing to retry waypoint')
                teleport_transition.chest_hold_logged = teleport_transition.started_at
            end
            teleport_transition.started_at = now
        elseif dispatch.held('to_temis', dispatch.companion_hold(now, 'to_temis'), 'via-Temis preamble: TO_TEMIS hold — ') then
            -- WPD-1 / C5: never re-fire the waypoint over a live Alfred cycle
            -- or a Looter pickup (bounded), and do not count the wait toward
            -- the retry timeout.
            teleport_transition.started_at = now
        elseif helltide_lingering_post_quest(wants)
            and (now - teleport_transition.last_temis_tp) >= TEMIS_LINGER_RETRY_INTERVAL
        then
            -- Helltide-lingering fast retry: the channel is being broken by
            -- ongoing damage from the 10s monster spawns and HR is off, so
            -- retry only after a full channel window has elapsed.
            log('via-Temis preamble: helltide-lingering fast retry — re-firing waypoint')
            teleport_to_waypoint(TEMIS_WP)
            teleport_transition.last_temis_tp = now
            teleport_transition.started_at    = now
        elseif (now - teleport_transition.started_at) >= TEMIS_TELEPORT_TIMEOUT then
            if (now - teleport_transition.last_temis_tp) >= TEMIS_TELEPORT_DEBOUNCE then
                log('via-Temis preamble: TO_TEMIS timeout — retrying waypoint')
                teleport_to_waypoint(TEMIS_WP)
                teleport_transition.last_temis_tp = now
                teleport_transition.started_at    = now
            end
        end
    end
    if teleport_transition.state == 'TEMIS_ALFRED' then
        local elapsed   = now - teleport_transition.alfred_fired_at
        local busy_now  = not alfred_idle()
        if busy_now then teleport_transition.alfred_was_busy = true end
        -- Track external_trigger pickup edge: alfred_trigger_now() set
        -- external_trigger=true; Alfred's status task clears it after the
        -- cycle completes. Observing the clear means Alfred actually picked
        -- up our trigger — distinguishes "didn't pick up yet" from "picked
        -- up but had nothing to do".
        local picked_up_now = false
        do
            local alfred = (_G.AlfredTheButlerPlugin or _G.PLUGIN_alfred_the_butler)
            if alfred and type(alfred.get_status) == 'function' then
                local ok, s = pcall(alfred.get_status)
                if ok and type(s) == 'table' and s.external_trigger == false then
                    picked_up_now = true
                end
            end
        end
        if picked_up_now and teleport_transition.alfred_was_busy then
            -- Already saw work AND status task cleared the trigger — clean done.
            teleport_transition.alfred_picked_up = true
        elseif picked_up_now and elapsed >= ALFRED_MIN_DWELL then
            -- Status task ran, cleared trigger, and we never observed busy →
            -- Alfred decided there was nothing to do. Honor min-dwell.
            teleport_transition.alfred_picked_up = true
        end
        local done = false
        if elapsed < ALFRED_MIN_DWELL then
            -- Hold until min dwell regardless of reported state — covers
            -- slow main_pulse pickup window where alfred_idle() can flicker
            -- true between trigger queue and status task Execute.
        elseif teleport_transition.alfred_was_busy and not busy_now then
            done = true
            log('via-Temis preamble: Alfred finished its work')
        elseif teleport_transition.alfred_picked_up and not busy_now then
            done = true
            log('via-Temis preamble: Alfred picked up trigger, no work pending')
        elseif elapsed >= ALFRED_PICKUP_TIMEOUT
            and not teleport_transition.alfred_was_busy
            and not busy_now
        then
            done = true
            log(string.format(
                'via-Temis preamble: Alfred pickup timeout (%.1fs), proceeding', elapsed))
        elseif elapsed >= ALFRED_MAX_SECONDS then
            done = true
            log(string.format(
                'via-Temis preamble: Alfred max wait (%.0fs) exceeded — proceeding anyway', elapsed))
        end
        if done then
            -- Bounce into POST_ALFRED_SETTLE rather than firing teleport
            -- immediately. Re-checks alfred_idle for POST_ALFRED_SETTLE_SECONDS
            -- and flips back to TEMIS_ALFRED if Alfred re-arms a mini-cycle.
            teleport_transition.state             = 'POST_ALFRED_SETTLE'
            teleport_transition.settle_started_at = now
            log(string.format(
                'via-Temis preamble: entering post-Alfred settle (%.1fs)',
                POST_ALFRED_SETTLE_SECONDS))
        end
    end
    if teleport_transition.state == 'POST_ALFRED_SETTLE' then
        local settled = now - teleport_transition.settle_started_at
        local busy_now = not alfred_idle()
        if busy_now then
            -- Alfred re-armed (e.g. inventory scan re-detected something).
            -- Bounce back to TEMIS_ALFRED with a fresh dwell window.
            log('via-Temis preamble: Alfred re-armed during settle — back to TEMIS_ALFRED')
            teleport_transition.state             = 'TEMIS_ALFRED'
            teleport_transition.alfred_fired_at   = now
            teleport_transition.alfred_was_busy   = true  -- we just observed it busy
            teleport_transition.alfred_picked_up  = false
            teleport_transition.settle_started_at = nil
        elseif settled >= POST_ALFRED_SETTLE_SECONDS
            and dispatch.helltide_off_window(wants)
        then
            -- Helltide off-window (minute 55-59): no helltide exists for the
            -- warplan teleport to land in. Stay parked in Temis with Alfred
            -- already done — re-checks every tick, fires the teleport as soon
            -- as the new helltide hour begins. We deliberately don't clear
            -- settle_started_at so the busy_now branch above stays correct
            -- (Alfred could still re-arm mid-wait).
            if not teleport_transition.helltide_hold_logged then
                log('via-Temis preamble: holding warplan teleport — incoming is helltide, helltide is in off-window (minute 55-59)')
                teleport_transition.helltide_hold_logged = true
            end
        elseif settled >= POST_ALFRED_SETTLE_SECONDS
            and dispatch.held('settle', dispatch.companion_hold(now, 'settle'), 'via-Temis preamble: holding warplan teleport — ')
        then
            -- WPD-1: a companion (bounded) is still working; re-check next tick.
            -- (Alfred work in Temis already bounced to TEMIS_ALFRED above.)
        elseif settled >= POST_ALFRED_SETTLE_SECONDS then
            if teleport_transition.helltide_hold_logged then
                log('via-Temis preamble: helltide window active again — proceeding to warplan teleport')
                teleport_transition.helltide_hold_logged = false
            end
            log(string.format(
                'via-Temis preamble: post-Alfred settle clear (%.1fs) — proceeding to warplan teleport',
                settled))
            teleport_transition.alfred_fired_at   = nil
            teleport_transition.alfred_was_busy   = false
            teleport_transition.alfred_picked_up  = false
            teleport_transition.settle_started_at = nil
            start_warplan_teleport(wants, now, 'settle')
        end
    end
    if teleport_transition.state == 'TELEPORTING' then
        -- If a deferred-disable is still pending, abort the teleport — the
        -- outgoing plugin (e.g. InfernalHordes) hasn't finished yet.
        local blocking_pending
        for p in pairs(pending_disable) do blocking_pending = p; break end
        if blocking_pending then
            log('teleport aborted — deferred disable pending for ' .. tostring(blocking_pending))
            teleport_transition.state      = 'IDLE'
            teleport_transition.snap_world = nil
            teleport_transition.snap_zone  = nil
            teleport_pending               = false
            teleport_incoming_first_seen   = nil
            teleport_holding_logged        = false
        elseif (now - teleport_transition.started_at) >= TELEPORT_CHECK_INTERVAL then
            local w         = get_current_world()
            local cur_world = w and w:get_name()
            local cur_zone  = w and w:get_current_zone_name()
            -- Loading-screen guard: between activities the game briefly reports
            -- world=Limbo / zone=[sno none]. That's the in-flight transition
            -- state, NOT the destination — confirming on it released the gate
            -- before BSK actually loaded, then enable_gate denied and re-armed
            -- the whole detour in a loop. Treat Limbo as "still teleporting":
            -- don't confirm, don't retry the warplan call (the channel landed,
            -- we just haven't finished loading), just re-poll next interval.
            local in_limbo = not cur_world or not cur_zone or cur_world == '' or cur_zone == ''
                or cur_world == 'Limbo' or cur_zone == '[sno none]'
            if in_limbo then
                teleport_transition.started_at = now
                log(string.format(
                    'teleport in-flight — world=%s zone=%s, holding for load to finish',
                    tostring(cur_world), tostring(cur_zone)))
                return
            end
            local changed   = cur_world ~= teleport_transition.snap_world
                           or cur_zone  ~= teleport_transition.snap_zone
            -- Secondary confirmation: quest actor visible means we arrived even
            -- if world/zone didn't change (warplan teleported us to the same
            -- zone the actor lives in, e.g. Pit/Undercity → Temis while already
            -- in Temis on a retry path).
            local arrived_now = false
            if not changed then
                for _, entry in pairs(wants) do
                    if type(entry.arrived_when) == 'function' and entry.arrived_when() then
                        arrived_now = true
                        break
                    end
                end
            end
            if changed or arrived_now then
                teleport_transition.state    = 'IDLE'
                teleport_transition.snap_world = nil
                teleport_transition.snap_zone  = nil
                dispatch.delivered             = true  -- R2: counted by the next enable attempt
                log(string.format('teleport confirmed (%s world=%s zone=%s) — releasing enable gate',
                    arrived_now and 'arrived_when' or 'world/zone',
                    tostring(cur_world), tostring(cur_zone)))
            else
                teleport_transition.started_at = now
                if dispatch.held('teleporting', dispatch.warplan_hold(wants, now, 'teleporting'), 'teleport retry held — ') then
                    -- WPD-1 / WPD-8: no retry over a companion's live work or
                    -- into a helltide off-window; the wait is not a retry.
                elseif _G.warplan and type(warplan.teleport_to_activity) == 'function' then
                    -- WPT-6: bounded, protected retries. A binding that throws
                    -- or never moves the player releases the gate so the
                    -- activity can navigate itself.
                    teleport_transition.retries = (teleport_transition.retries or 0) + 1
                    local fired, err = false, nil
                    if teleport_transition.retries <= dispatch.WARPLAN_MAX_RETRIES then
                        fired, err = pcall(warplan.teleport_to_activity)
                    end
                    if fired then
                        log(string.format(
                            'teleport retry %d/%d — world/zone unchanged (world=%s zone=%s), retrying in %.1fs',
                            teleport_transition.retries, dispatch.WARPLAN_MAX_RETRIES,
                            tostring(cur_world), tostring(cur_zone), TELEPORT_CHECK_INTERVAL))
                    else
                        teleport_transition.state      = 'IDLE'
                        teleport_transition.snap_world = nil
                        teleport_transition.snap_zone  = nil
                        dispatch.delivered             = true  -- R2: TELEPORTING released
                        if err ~= nil then
                            log('teleport retry failed: ' .. tostring(err)
                                .. ' — releasing the gate; the activity navigates itself')
                        else
                            log(string.format(
                                'teleport: world/zone unchanged after %d retries (world=%s zone=%s) — releasing the gate; the activity navigates itself',
                                dispatch.WARPLAN_MAX_RETRIES, tostring(cur_world), tostring(cur_zone)))
                        end
                    end
                else
                    teleport_transition.state    = 'IDLE'
                    teleport_transition.snap_world = nil
                    teleport_transition.snap_zone  = nil
                    dispatch.delivered             = true  -- R2: TELEPORTING released
                    log('teleport: warplan not available on retry — releasing gate')
                end
            end
        end
    end

    -- ── ENABLE GATE ─────────────────────────────────────────────────────────
    -- Don't start the next plugin while:
    --   (a) any plugin's disable is still deferred (outgoing not finished), or
    --   (b) we just disabled something within TRANSITION_GAP_SECONDS, or
    --   (c) teleport transition state machine is mid-sequence.
    -- This is the actual handoff sequencer — pairs with disable_when to give
    -- the game state a clean break between activities.
    local gate_reason = nil
    for p in pairs(pending_disable) do
        gate_reason = 'pending disable: ' .. p
        break
    end
    if not gate_reason and teleport_transition.state ~= 'IDLE' then
        gate_reason = 'teleport transition: ' .. teleport_transition.state
    end
    -- Also gate while teleport_pending is true but the sequence hasn't
    -- started yet (state still IDLE because we're waiting for incoming /
    -- settle / alfred_idle). Without this, cold-start enables fire BEFORE
    -- native navigation starts because the state machine has not left
    -- of IDLE yet.
    if not gate_reason and teleport_pending then
        gate_reason = 'teleport pending (waiting for prerequisites)'
    end
    if not gate_reason then
        for p, t in pairs(last_disable_time) do
            local age = now - t
            if age < TRANSITION_GAP_SECONDS then
                gate_reason = string.format('post-disable cooldown: %s (%.1fs left)',
                    p, TRANSITION_GAP_SECONDS - age)
                break
            end
        end
    end

    -- C6: surface a gate that keeps holding a wanted activity.
    dispatch.watch_gate(now, gate_reason, wants, pending_disable, task_matches,
        teleport_pending, teleport_holding_logged, teleport_transition.state)

    -- Task context (CRT-6 / L4 / WPD-1): `activity_quiet` tells the turn-in
    -- that no managed plugin is on, pending disable or inside its post-disable
    -- gap (a short settle is enough); `hold` is the bounded companion gate for
    -- its own teleports.
    local task_ctx
    for pattern, matched in pairs(task_matches) do
        local task = normalize(orchestrator.quest_plugin_map[pattern]).task
        local active = matched and not gate_reason and next(wants) == nil
        if active and not task_ctx then
            task_ctx = {
                activity_quiet = dispatch.activity_quiet(owned, pending_disable, managed,
                    last_disable_time, now, TRANSITION_GAP_SECONDS),
                hold = dispatch.companion_hold(now, 'task'),
            }
        end
        local ok, err = pcall(task.tick, active, active and task_ctx or nil)
        if not ok then log('task error (' .. pattern .. '): ' .. tostring(err)) end
    end

    -- ── ENABLE PHASE ────────────────────────────────────────────────────────
    -- Edge-trigger: enable plugins newly wanted, unless gated.
    -- ALSO re-fire enable when the matched pattern changes for an
    -- already-owned plugin: Reaper's run_boss('zir') vs run_boss('varshan')
    -- both target ReaperPlugin, so without re-firing the plugin would keep
    -- running the old boss while WarPigs thinks the handoff is done.
    for plugin_name, entry in pairs(wants) do
        local newly_wanted = not last_wanted[plugin_name] and not owned[plugin_name]
        local reason       = matched_reason[plugin_name]
        local reason_changed = owned[plugin_name]
            and reason
            and last_enabled_reason[plugin_name]
            and last_enabled_reason[plugin_name] ~= reason
        if newly_wanted or reason_changed then
            -- Per-entry hard gate (e.g. InfernalHordes refuses to enable
            -- outside BSK while teleport transition is on). Evaluated AFTER
            -- the transition gate so the orchestrator's normal sequencing
            -- runs first; this is a final safety net for the case where the
            -- teleport state machine "confirmed" without actually landing us
            -- at the destination.
            local entry_gate_reason
            if type(entry.enable_gate) == 'function' then
                local ok, allowed, why = pcall(entry.enable_gate)
                if not ok or not allowed then
                    entry_gate_reason = why or 'enable_gate denied or unavailable'
                end
            end
            if gate_reason then
                -- Once per episode: the post-disable countdown is not part
                -- of the dedup key (round-3 audit: logged every tick).
                local gate_key = (gate_reason:gsub(' %([%d%.]+s left%)$', ''))
                if enable_blocked[plugin_name] ~= gate_key then
                    log('deferring enable of ' .. plugin_name .. ' — ' .. gate_reason)
                    enable_blocked[plugin_name] = gate_key
                end
            elseif entry_gate_reason and dispatch.gate_bypass(plugin_name, entry_gate_reason,
                settings.use_teleport_transition and not teleport_pending and teleport_transition.state == 'IDLE'
                    and dispatch.delivered)
            then
                -- WPD-3: capped re-arms — the plugin navigates itself now.
                plugin_enable(entry, reason)
            elseif entry_gate_reason then
                if enable_blocked[plugin_name] ~= entry_gate_reason then
                    log('BLOCKING enable of ' .. plugin_name .. ' — ' .. entry_gate_reason)
                    enable_blocked[plugin_name] = entry_gate_reason
                end
                -- An entry that delivers the player itself (War Plan Horde
                -- entry: warplan teleport, independent of 'Use teleport')
                -- handles the delivery; `deliver` runs only here, i.e. with no
                -- transition gate (after cleanup and the post-disable gap).
                local delivers = false
                if type(entry.deliver) == 'function' then
                    local ok, handled = pcall(entry.deliver, now, dispatch.delivered)
                    if not ok then log('deliver error (' .. plugin_name .. '): ' .. tostring(handled)) end
                    delivers = ok and handled == true
                end
                -- Re-arm the teleport sequence if it has gone idle without
                -- delivering us to the destination — otherwise the gate would
                -- deadlock. Only re-arm when the state machine isn't already
                -- working: teleport_pending false AND state IDLE.
                if not delivers and settings.use_teleport_transition
                    and not teleport_pending
                    and teleport_transition.state == 'IDLE'
                then
                    log('re-arming teleport_pending — enable_gate denied with state IDLE')
                    teleport_pending = true
                end
            else
                if reason_changed then
                    log(string.format('re-enabling %s — pattern changed: %s -> %s',
                        plugin_name, last_enabled_reason[plugin_name], reason))
                    -- Clear the stale defer for the OLD pattern: the old
                    -- entry's disable_when (e.g. Reaper kill+60s for the
                    -- previous boss that was never actually killed) is no
                    -- longer relevant once we hand off to a new entry.
                    pending_disable[plugin_name]       = nil
                    pending_disable_since[plugin_name] = nil
                end
                plugin_enable(entry, reason)
            end
            -- R2: a delivery counts for this enable attempt only.
            if not gate_reason then dispatch.delivered = false end
        end
    end

    -- last_wanted tracks "this plugin was actually owned at end of last tick".
    -- Plugins that were gated out of enabling must NOT be marked wanted, so
    -- the next tick's edge check fires the enable once the gate clears.
    last_wanted = {}
    for plugin_name in pairs(wants) do
        if owned[plugin_name] then last_wanted[plugin_name] = true end
    end
    -- WPD-3 / R4 / R8: re-arm counts, unconfirmed enables and a Reaper
    -- refusal belong to the current want only.
    dispatch.forget_unwanted(wants)
    last_matches = matches
end

-- Release every plugin we currently own. Called when WarPigs itself is
-- disabled so it doesn't leave a managed plugin running.
function orchestrator.release_all()
    alfred_callback_generation = alfred_callback_generation + 1
    local raven_released = raven_bridge:release()
    for _, raw in pairs(orchestrator.quest_plugin_map) do
        local entry = normalize(raw)
        if entry.task then pcall(entry.task.tick, false) end
    end
    local releasing = {}
    for plugin_name in pairs(owned) do releasing[plugin_name] = true end
    for plugin_name in pairs(pending_disable) do releasing[plugin_name] = true end
    for plugin_name in pairs(releasing) do
        plugin_disable(find_entry_for_plugin(plugin_name))
    end
    last_wanted           = {}
    last_matches          = {}
    pending_disable       = {}
    pending_disable_since = {}
    last_disable_time     = {}
    enable_blocked        = {}
    last_enabled_reason   = {}
    teleport_pending             = false
    teleport_incoming_first_seen = nil
    teleport_holding_logged      = false
    teleport_transition.chest_hold_logged = nil
    teleport_transition.retries           = 0
    teleport_transition.state             = 'IDLE'
    teleport_transition.started_at        = -math.huge
    teleport_transition.snap_world        = nil
    teleport_transition.snap_zone         = nil
    teleport_transition.last_temis_tp     = -math.huge
    last_alfred_kick_at                   = -math.huge
    last_alfred_completion_at             = nil
    last_alfred_completion_plugin         = nil
    teleport_transition.alfred_fired_at   = nil
    teleport_transition.alfred_was_busy   = false
    teleport_transition.alfred_picked_up  = false
    teleport_transition.settle_started_at = nil
    teleport_transition.helltide_hold_logged = false
    had_active_session       = false
    was_dead                 = false
    -- Filler-pit state — re-arm only after the next session sees a turn-in.
    turn_in_was_matched      = false
    had_turn_in_complete     = false
    pit_filler_active_logged = false
    last_disabled_plugin     = nil
    last_disabled_at         = -math.huge
    last_disabled_reason     = nil
    -- Drop any pending Reaper run_once callback by bumping run_id; clear flag.
    reset_reaper_run_once()
    reaper_run_once.refused_boss, reaper_run_once.refuse_reason = nil, nil
    -- Companion holds, capped re-arms, Reaper cooldowns and the gate watchdog
    -- start over with the next session (toggling WarPigs retries a boss).
    dispatch.reset()
    return next(owned) == nil and raven_released
end

-- Read-only handoff signal for the plan creator. An empty quest log alone
-- does not mean that the outgoing activity or native teleport has finished.
function orchestrator.is_busy()
    if raven_bridge:blocks_plan_creator() then return true end
    if next(owned) ~= nil or next(pending_disable) ~= nil
        or teleport_transition.state ~= 'IDLE' then
        return true
    end
    if next(last_matches) ~= nil then return true end
    local now = get_time_since_inject()
    for _, stopped_at in pairs(last_disable_time) do
        if now - stopped_at < TRANSITION_GAP_SECONDS then return true end
    end
    -- teleport_pending with no incoming quest is only an idle intention.
    -- The plan creator must be allowed to supply that incoming quest after
    -- all owned cleanup, native transitions and the cooldown have finished.
    return false
end

local function base_status_line()
    local names = {}
    for n in pairs(owned) do names[#names+1] = n end
    if #names > 0 then return 'WarPigs: managing ' .. table.concat(names, ', ') end
    -- Show active task state so "watching quests" doesn't mask turn-in work.
    for pattern in pairs(last_matches) do
        local raw_entry = orchestrator.quest_plugin_map[pattern]
        if raw_entry then
            local entry = normalize(raw_entry)
            if entry.task then
                local task_label = pattern:gsub('WarPlans_QST_', '')
                local task_state = type(entry.task.get_state) == 'function'
                    and entry.task.get_state() or '?'
                return 'WarPigs: task ' .. task_label .. ' [' .. task_state .. ']'
            end
        end
    end
    -- CRT-5: an unmapped WarPlans quest is visible instead of "watching".
    if dispatch.unmapped[1] and next(last_matches) == nil then
        return 'WarPigs: no handler for quest ' .. dispatch.unmapped[1]
    end
    return 'WarPigs: watching quests'
end

function orchestrator.get_status_line()
    local raven_status = raven_bridge:status_line()
    if raven_status then return raven_status end
    -- C6: a gate held for minutes and Reaper cooldowns are appended.
    return base_status_line() .. dispatch.status_suffix(get_time_since_inject())
end

return orchestrator
