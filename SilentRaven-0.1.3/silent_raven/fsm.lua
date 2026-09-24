-- Temis reward task. Only our NPC interaction can authorize selection.
local log = require 'silent_raven.log'
local whispers = require 'silent_raven.whispers'
local tracker = require 'silent_raven.tracker'
local rewards = require 'silent_raven.rewards'
local stats = require 'silent_raven.stats'
local coordination = require 'silent_raven.coordination'
local M = {}
local MAX_ATTEMPTS, WALK_TIMEOUT, PANEL_TIMEOUT, RUN_TIMEOUT = 3, 20, 10, 100
local TELEPORT_RETRY_SECONDS, TELEPORT_SPELL_ID = 6, 186139
-- The host may apply select() a frame later: a mismatching read is final
-- only after this settle time.
local SELECT_SETTLE = 0.5
-- A walk that gets no STALL_PROGRESS yards closer to its target within
-- STALL_SECONDS is stalled (request_move ignored behind a stale stored
-- path, or the player walking someone else's route).
local STALL_SECONDS, STALL_PROGRESS = 3, 1
-- Pauses (own-run companion yield, or an owner's 'yield:' guard answer):
-- one log line at YIELD_LOG_S, give up (without latching the visit) at
-- YIELD_LIMIT_S of continuous pause.
local YIELD_LOG_S, YIELD_LIMIT_S = 60, 120
local YIELD_STATES = { START = true, WAIT_RETRY = true, WALK_NPC = true, INTERACT_NPC = true }
-- R15: a continuation guard answering (false, 'yield:<reason>') pauses the
-- request instead of revoking it.
local YIELD_PREFIX = 'yield:'
-- Automatic reward dumps: one per run, a few per session.
local AUTO_DUMP_LIMIT = 5
local session = { dumps = 0 }
local function clock() return (get_time_since_inject and get_time_since_inject()) or 0 end
local function transition(state, now) tracker.state, tracker.state_t = state, now end
local function stop_owned()
    if tracker.movement_owned then whispers.stop_movement(); tracker.movement_owned = false end
end
-- D4Remote loot history (documented: once per successful claim).
local function record_loot(item)
    local remote = D4Remote
    if not (remote and remote.record_loot) then return end
    local category = rewards.SLOT_TO_D4REMOTE_CATEGORY[item.slot] or 'cache'
    pcall(remote.record_loot, category, item.legendary and 5 or 4)
end
-- keep_visit: nothing was accepted (revoked request, expired yield), so the
-- per-visit latch stays open and the owner may ask again during this visit.
local function finish(result, preserve_path, keep_visit)
    if not preserve_path then stop_owned() end
    if not keep_visit and whispers.current_zone() == 'Skov_Temis' then tracker.last_zone_handled = 'Skov_Temis' end
    if result == 'success' and tracker.last_pick_entry then
        local item = tracker.last_pick_entry
        stats.bump_success(item.slot, item.legendary, item.name, tracker.last_reason)
        record_loot(item)
    elseif result == 'failed' or result == 'unconfirmed' then
        stats.bump_failure(tracker.last_reason)
    end
    log.info('run finished: ' .. result .. ' (' .. tostring(tracker.last_reason) .. ')')
    tracker.finish(result)
end
-- Pause bookkeeping shared by own-run companion yields and an owner's
-- 'yield:' guard answer. The companion owns movement: no more moves from
-- us and its path is never cleared (movement_owned is dropped). Paused time
-- does not consume the walk, panel, settle or run timeouts (C5). Logged once
-- at YIELD_LOG_S; cancelled with `expired` at YIELD_LIMIT_S without latching
-- the visit (C6). Returns true while paused, false once cancelled.
local function hold(now, reason, expired)
    local dt = tracker.yield_t and math.max(0, now - tracker.yield_t) or 0
    tracker.yield_t, tracker.yield_reason = now, reason
    if not tracker.yield_since then
        tracker.yield_since = now
        tracker.movement_owned = false
    end
    if tracker.state_t then tracker.state_t = tracker.state_t + dt end
    if tracker.run_started_t then tracker.run_started_t = tracker.run_started_t + dt end
    if tracker.walk_progress_t then tracker.walk_progress_t = tracker.walk_progress_t + dt end
    local held = now - tracker.yield_since
    if held >= YIELD_LOG_S and not tracker.yield_logged then
        tracker.yield_logged = true
        log.info(string.format('waiting %.0fs for %s before continuing the Whisper claim (gives up at %ds)',
            held, reason, YIELD_LIMIT_S))
    end
    if held < YIELD_LIMIT_S then return true end
    tracker.last_reason = expired
    finish('cancelled', true, not tracker.claim_sent)
    return false
end
-- End of a pause: the current step resumes (a walk heads for the same
-- waypoint, in the same attempt). The companion may have moved the player,
-- so stall tracking is re-baselined, and a panel step whose panel closed
-- meanwhile goes back to the NPC: interact again in range, else walk back.
local function unhold(now)
    if tracker.yield_since then
        if tracker.yield_logged then
            log.info(string.format('resuming after %.0fs waiting for %s', now - tracker.yield_since, tostring(tracker.yield_reason)))
        end
        tracker.walk_kind = nil
        local state = tracker.state
        if (state == 'INTERACT_NPC' or state == 'SELECT_VERIFY') and whispers.reward_panel_open() ~= true then
            local npc = whispers.find_tree_npc()
            tracker.claim_pick = nil
            if not (npc and whispers.player_dist_sq(npc) <= 8 * 8) then
                tracker.walk_via_done = false
                transition('WALK_NPC', now)
            elseif state == 'SELECT_VERIFY' then
                transition('INTERACT_NPC', now)
            end
        end
    end
    tracker.yield_reason, tracker.yield_since, tracker.yield_t = nil, nil, nil
end
-- Continuation guard of an external owner. true: continue. (false,
-- 'yield:<reason>') (R15): pause the request -- no moves, interactions,
-- selection or accept, timeouts frozen -- and resume the current step once
-- it answers true again; cancelled as 'yield_timeout' after YIELD_LIMIT_S.
-- After accept there is nothing left to pause, so a yield there only lets
-- the receipt be observed. Any other answer, or an error, revokes the
-- request as before, never clearing the other owner's path or UI.
-- Returns true to continue; false, 'yield' while paused; false once finished.
M.check_guard = function(now)
    if not tracker.continuation_guard then return true end
    now = now or clock()
    local ok, allowed, reason = pcall(tracker.continuation_guard)
    if ok and allowed == true then
        -- An own run's companion pause is ended by yielding() only.
        if not tracker.companion_yield then unhold(now) end
        return true
    end
    if ok and allowed == false and type(reason) == 'string' and reason:sub(1, #YIELD_PREFIX) == YIELD_PREFIX then
        if tracker.claim_sent then return true end
        local why = reason:sub(#YIELD_PREFIX + 1)
        if hold(now, why ~= '' and why or 'owner', 'yield_timeout') then return false, 'yield' end
        return false
    end
    tracker.last_reason = ok and (reason or 'guard_rejected') or 'guard_error'
    -- The other owner may already have moved. Never clear its path or UI.
    finish('cancelled', true, not tracker.claim_sent)
    return false
end
-- One automatic dump of every enumerated entry per run, so a live log shows
-- the host's real fields when no card is usable or a selection fails.
local function diagnose(reason, detail)
    if tracker.reward_dumped or session.dumps >= AUTO_DUMP_LIMIT then return end
    tracker.reward_dumped, session.dumps = true, session.dumps + 1
    log.info('reward diagnostics (' .. reason .. (detail and ('; ' .. detail) or '') .. '):')
    pcall(whispers.dump_rewards, rewards)
end
local function retry(reason, now)
    tracker.last_reason = reason
    -- ESC only for a panel we can see: with nothing open, D4 opens the game menu.
    if tracker.interacts_fired > 0 and whispers.reward_panel_open() == true then whispers.send_escape() end
    stop_owned()
    if tracker.attempts >= MAX_ATTEMPTS then finish('failed')
    else transition('WAIT_RETRY', now) end
end
local function move(pos)
    if not pos then return end
    tracker.movement_owned = true
    whispers.move_to_pos(pos)
end
local function begin_walk(now)
    tracker.attempts = tracker.attempts + 1
    tracker.interacts_fired, tracker.interact_npc, tracker.last_interact_t = 0, nil, nil
    tracker.walk_intermediate = whispers.choose_intermediate()
    tracker.walk_via_done, tracker.walk_kind, tracker.walk_best = false, nil, nil
    tracker.walk_progress_t, tracker.walk_stalls = nil, 0
    transition('WALK_NPC', now)
end
-- The intermediate avoids a wall on the direct line to the Raven, which
-- request_move does not route around. It is used even when the NPC is
-- already in the actor stream, and once reached it is not re-targeted in
-- this attempt: leaving its radius toward the NPC is progress.
local function walk_target(npc)
    local via = tracker.walk_intermediate
    if via and not tracker.walk_via_done then
        local skip = whispers.VIA_SKIP_RADIUS
        if whispers.player_dist_to_pos(via) <= whispers.INTERMEDIATE_ARRIVAL_RADIUS
            or whispers.player_dist_to_pos(whispers.RAVEN_NPC_POSITION) <= skip
            or (npc and whispers.player_dist_sq(npc) <= skip * skip) then
            tracker.walk_via_done = true
        else
            return via, 'intermediate'
        end
    end
    if npc then
        local pos = whispers.safe_method(npc, 'get_position')
        local x, y, z = whispers.safe_method(pos, 'x'), whispers.safe_method(pos, 'y'), whispers.safe_method(pos, 'z')
        if x and y and z then return { x = x, y = y, z = z }, 'npc' end
    end
    return whispers.RAVEN_NPC_POSITION, 'npc'
end
-- Stall recovery drops the stored path (ours or an orphan) and re-issues the
-- move; from the second stall on it gives up an unreachable intermediate, or
-- sends a direct move toward the NPC. It runs only while no companion can
-- own movement. Returns true when a direct move was sent this tick.
local function watch_walk(target, kind, now)
    local d = whispers.player_dist_to_pos(target)
    if d == math.huge then return false end
    if tracker.walk_kind ~= kind or not tracker.walk_best then
        tracker.walk_kind, tracker.walk_best, tracker.walk_progress_t = kind, d, now
        return false
    end
    if d <= tracker.walk_best - STALL_PROGRESS then
        tracker.walk_best, tracker.walk_progress_t = d, now
        return false
    end
    if now - tracker.walk_progress_t < STALL_SECONDS then return false end
    tracker.walk_progress_t = now
    if not coordination.companions('run', now) then return false end
    tracker.walk_stalls = tracker.walk_stalls + 1
    if not tracker.walk_stall_logged then
        tracker.walk_stall_logged = true
        log.info(string.format('walk stalled: no progress toward %s for %ds (dist %.1f, attempt %d, %s); dropping the stale path and re-issuing the move',
            kind, STALL_SECONDS, d, tracker.attempts, whispers.batmobile_brief()))
    end
    whispers.stop_movement()
    if tracker.walk_stalls < 2 then return false end
    -- An intermediate we cannot approach (arrival from another side of the
    -- wall) is dropped for this attempt; the next tick heads for the NPC.
    if kind == 'intermediate' then tracker.walk_via_done = true; return false end
    return whispers.force_move(target)
end
-- Own runs (auto-fire/manual) stop moving and interacting while Alfred has
-- live work or the Looter is collecting (see hold/unhold). An open reward
-- panel is claimed without waiting.
local function yielding(now)
    if not tracker.companion_yield then return false end
    if not YIELD_STATES[tracker.state]
        or (tracker.state == 'INTERACT_NPC' and whispers.reward_panel_open() == true) then
        unhold(now)
        return false
    end
    local clear, reason = coordination.companions('run', now)
    if clear then unhold(now); return false end
    hold(now, reason, 'yield_timeout:' .. reason)
    return true
end
local function interact(npc, now)
    local ok = type(interact_object) == 'function' and pcall(interact_object, npc)
    if ok then
        tracker.interacts_fired = tracker.interacts_fired + 1
        tracker.last_interact_t = now
    end
end
-- Before accept the selected card must be ours: re-enumerated, same usable
-- SNO at our key, and selected_index() naming it either in the documented
-- 0-based selection space or in enumerate's own key space (both name our
-- card; the live convention is unverified).
local function verify_selection(now)
    local pick = tracker.claim_pick
    if not pick or whispers.reward_panel_open() ~= true then retry('panel_closed_before_accept', now); return end
    local read_ok, raw = pcall(quest_reward.selected_index)
    local selected_index = read_ok and tonumber(raw) or nil
    local list_ok, list = pcall(quest_reward.enumerate)
    local current = list_ok and type(list) == 'table' and list[pick.index] or nil
    local ours = rewards.entry_usable(current) and rewards.entry_sno(current) == pick.sno
    if not (ours and (selected_index == pick.host_index or selected_index == pick.index)) then
        if now - tracker.state_t < SELECT_SETTLE then return end
        diagnose('selection_verification_failed', string.format('selected_index=%s(%s), wanted %d (0-based) or %d (enumerate key)',
            tostring(raw), type(raw), pick.host_index, pick.index))
        retry('selection_verification_failed', now); return
    end
    -- Never accept while the owner revoked or paused the request (R15): a
    -- paused request stays here and re-verifies before accepting.
    if not M.check_guard(now) then return end
    -- Once accept is sent its result is ambiguous even if the binding throws.
    -- Never send another accept for this request; wait for actual receipt.
    local entry = pick.entry
    tracker.claim_before = pick.before
    tracker.last_pick_entry = {
        sno = pick.sno, name = rewards.display_name(entry),
        slot = rewards.extract_slot(entry), legendary = rewards.is_legendary(entry),
    }
    tracker.claim_sent = true
    pcall(quest_reward.accept)
    transition('API_CLAIMING', now)
end
local function claim(settings, now)
    if not whispers.has_quest_reward_api() then retry('reward_api_unavailable', now); return end
    local ok, entries = pcall(quest_reward.enumerate)
    if not ok or type(entries) ~= 'table' then retry('rewards_unavailable', now); return end
    local index = rewards.pick_best_index(entries, settings)
    local entry = index ~= nil and entries[index] or nil
    local sno = rewards.entry_sno(entry)
    -- One usability rule for picking, claiming and verification: only an
    -- explicit refusal rejects a card; its SNO must be readable.
    if not sno or not rewards.entry_usable(entry) then
        diagnose('no_valid_reward'); retry('no_valid_reward', now); return
    end
    -- The source host enumerates 1-based and selects 0-based. A table with
    -- an explicit key 0 is already 0-based. Reject sparse/unknown layouts.
    local base = entries[0] ~= nil and 0 or 1
    for i = base, index do
        if type(entries[i]) ~= 'table' then retry('unsupported_reward_indices', now); return end
    end
    local host_index = index - base
    local before = whispers.cache_count(sno)
    if before == nil then retry('inventory_unavailable', now); return end
    -- select() has no verified return convention (a void binding returns
    -- nil): only an error or an explicit false is a refusal. The selection
    -- itself is verified before accept.
    local selected_ok, selected = pcall(quest_reward.select, host_index)
    if not selected_ok or selected == false then
        diagnose('selection_failed', 'select(' .. tostring(host_index) .. ') -> ' .. tostring(selected))
        retry('selection_failed', now); return
    end
    tracker.claim_pick = { index = index, host_index = host_index, sno = sno, before = before, entry = entry }
    transition('SELECT_VERIFY', now)
    verify_selection(now)
end

function M.start(settings, reason, with_tp, callback)
    tracker.running, tracker.all_task_done = true, false
    tracker.last_reason, tracker.external_callback = reason or 'auto', callback
    tracker.attempts, tracker.claim_sent, tracker.confirm_since = 0, false, nil
    tracker.run_started_t = clock()
    tracker.companion_yield = reason == 'auto' or reason == 'manual'
    tracker.state, tracker.state_t = with_tp and not whispers.in_whisper_town() and 'TELEPORTING' or 'START', clock()
end
function M.tick(settings)
    if not tracker.running then return end
    local now = clock()
    local go = M.check_guard(now)
    if not tracker.running then return end
    local zone = whispers.current_zone()
    tracker.observe_zone(zone)
    if not go or yielding(now) then
        -- A paused request still ends on a definite departure from Temis.
        if tracker.running and tracker.state ~= 'TELEPORTING' and zone and zone ~= '' and zone ~= 'Skov_Temis'
            and whispers.player_ready() then
            tracker.last_reason = 'left_temis'; finish('cancelled', true)
        end
        return
    end
    if now - (tracker.run_started_t or now) >= RUN_TIMEOUT then
        tracker.last_reason = 'run_timeout'; finish(tracker.claim_sent and 'unconfirmed' or 'failed'); return
    end
    if tracker.paused then return end
    -- Loading/death may retain stale town data. No native movement, reward
    -- interaction or teleport retries are allowed until the player is live.
    if not zone or not whispers.player_ready() then return end
    if tracker.state == 'TELEPORTING' then
        if zone == 'Skov_Temis' then transition('START', now)
        elseif now - tracker.state_t >= 30 then tracker.last_reason = 'teleport_timeout'; finish('failed'); return
        else
            local player = get_local_player()
            local casting = whispers.safe_method(player, 'get_active_spell_id') == TELEPORT_SPELL_ID
            if not casting and now - (tracker.tp_last_cast_t or -math.huge) >= TELEPORT_RETRY_SECONDS
                and type(teleport_to_waypoint) == 'function' then
                pcall(teleport_to_waypoint, settings.teleport_target_sno or 0x1CE51E)
                tracker.tp_last_cast_t = now; stats.bump_tp()
            end
            return
        end
    end
    -- Missing world/zone is a loading sample, not a departure or claim.
    if not zone or zone == '' then return end
    if zone ~= 'Skov_Temis' then tracker.last_reason = 'left_temis'; finish('cancelled', true); return end

    if tracker.state == 'API_CLAIMING' then
        local entry = tracker.last_pick_entry
        local count = entry and whispers.cache_count(entry.sno)
        local snapshot = whispers.quest_snapshot()
        local closed = whispers.reward_panel_open() == false
        if count and count > tracker.claim_before and snapshot and closed then
            tracker.confirm_since = tracker.confirm_since or now
            if now - tracker.confirm_since >= 0.5 then finish('success'); return end
        else tracker.confirm_since = nil end
        if now - tracker.state_t >= 8 then
            tracker.last_reason = 'receipt_unconfirmed'; finish('unconfirmed')
        end
        return
    end
    if tracker.state == 'SELECT_VERIFY' then verify_selection(now); return end
    if tracker.state == 'WAIT_RETRY' then
        if now - tracker.state_t < 1.5 then return end
        transition('START', now)
    end
    if tracker.state == 'START' then
        local snapshot = whispers.quest_snapshot()
        if not snapshot then tracker.last_reason = 'quest_data_unavailable'; finish('skipped_unknown'); return end
        if not snapshot.present or (snapshot.collecting and not snapshot.ready) then
            tracker.last_reason = 'no_completed_whispers'; finish('skipped_not_ready'); return
        end
        -- Never consume a reward panel opened by another task or the player.
        if whispers.reward_panel_open() ~= false then
            tracker.last_reason = 'reward_panel_busy_or_unknown'; finish('skipped_busy'); return
        end
        begin_walk(now)
    end
    if tracker.state == 'WALK_NPC' then
        -- Visible but unreachable NPCs have the same bounded timeout.
        if now - tracker.state_t >= WALK_TIMEOUT then retry('npc_walk_timeout', now); return end
        local npc = whispers.find_tree_npc()
        tracker.interact_npc = npc
        if npc and whispers.player_dist_sq(npc) <= 8 * 8 then
            stop_owned(); interact(npc, now); transition('INTERACT_NPC', now); return
        end
        local target, kind = walk_target(npc)
        -- A direct move was just sent: do not re-request over it this tick.
        if watch_walk(target, kind, now) then tracker.movement_owned = true; return end
        move(target)
        return
    end
    if tracker.state == 'INTERACT_NPC' then
        if tracker.interacts_fired > 0 and whispers.reward_panel_open() == true then
            claim(settings, now); return
        end
        if now - tracker.state_t >= PANEL_TIMEOUT then
            -- An untranslated, incomplete meta quest gets one bounded probe.
            local snapshot = whispers.quest_snapshot()
            if snapshot and not snapshot.ready then
                tracker.last_reason = 'no_reward_panel'; finish('skipped_not_ready')
            else retry('panel_timeout', now) end
            return
        end
        if now - (tracker.last_interact_t or -math.huge) >= 1.5 then
            local npc = whispers.find_tree_npc()
            if npc and whispers.player_dist_sq(npc) <= 8 * 8 then interact(npc, now) end
        end
    end
end
function M.is_running() return tracker.running == true end
return M
