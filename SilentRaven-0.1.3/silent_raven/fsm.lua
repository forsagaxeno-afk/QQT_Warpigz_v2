-- Temis reward task. Only our NPC interaction can authorize selection.
local log = require 'silent_raven.log'
local whispers = require 'silent_raven.whispers'
local tracker = require 'silent_raven.tracker'
local rewards = require 'silent_raven.rewards'
local stats = require 'silent_raven.stats'
local M = {}
local MAX_ATTEMPTS, WALK_TIMEOUT, PANEL_TIMEOUT, RUN_TIMEOUT = 3, 20, 10, 100
local TELEPORT_RETRY_SECONDS, TELEPORT_SPELL_ID = 6, 186139
local function clock() return (get_time_since_inject and get_time_since_inject()) or 0 end
local function transition(state, now) tracker.state, tracker.state_t = state, now end
local function stop_owned()
    if tracker.movement_owned then whispers.stop_movement(); tracker.movement_owned = false end
end
local function finish(result, preserve_path)
    if not preserve_path then stop_owned() end
    if whispers.current_zone() == 'Skov_Temis' then tracker.last_zone_handled = 'Skov_Temis' end
    if result == 'success' and tracker.last_pick_entry then
        local item = tracker.last_pick_entry
        stats.bump_success(item.slot, item.legendary, item.name, tracker.last_reason)
    elseif result == 'failed' or result == 'unconfirmed' then
        stats.bump_failure(tracker.last_reason)
    end
    log.info('run finished: ' .. result .. ' (' .. tostring(tracker.last_reason) .. ')')
    tracker.finish(result)
end
M.check_guard = function()
    if not tracker.continuation_guard then return true end
    local ok, allowed, reason = pcall(tracker.continuation_guard)
    if ok and allowed == true then return true end
    tracker.last_reason = ok and (reason or 'guard_rejected') or 'guard_error'
    -- The other owner may already have moved. Never clear its path or UI.
    finish('cancelled', true)
    return false
end
local function retry(reason, now)
    tracker.last_reason = reason
    if tracker.interacts_fired > 0 then whispers.send_escape() end
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
    transition('WALK_NPC', now)
end
local function interact(npc, now)
    local ok = type(interact_object) == 'function' and pcall(interact_object, npc)
    if ok then
        tracker.interacts_fired = tracker.interacts_fired + 1
        tracker.last_interact_t = now
    end
end
local function claim(settings, now)
    if not whispers.has_quest_reward_api() then retry('reward_api_unavailable', now); return end
    local ok, entries = pcall(quest_reward.enumerate)
    if not ok or type(entries) ~= 'table' then retry('rewards_unavailable', now); return end
    local index = rewards.pick_best_index(entries, settings)
    local entry = index ~= nil and entries[index] or nil
    if not entry or entry.valid ~= true or type(entry.sno) ~= 'number' then
        retry('no_valid_reward', now); return
    end
    -- The source host enumerates 1-based and selects 0-based. A table with
    -- an explicit key 0 is already 0-based. Reject sparse/unknown layouts.
    local base = entries[0] ~= nil and 0 or 1
    for i = base, index do
        if type(entries[i]) ~= 'table' then retry('unsupported_reward_indices', now); return end
    end
    local host_index = index - base
    local before = whispers.cache_count(entry.sno)
    if before == nil then retry('inventory_unavailable', now); return end
    local selected_ok, selected = pcall(quest_reward.select, host_index)
    if not selected_ok or selected ~= true then retry('selection_failed', now); return end
    local read_ok, selected_index = pcall(quest_reward.selected_index)
    local list_ok, selected_entries = pcall(quest_reward.enumerate)
    local selected_entry = list_ok and type(selected_entries) == 'table' and selected_entries[index]
    if not read_ok or selected_index ~= host_index or not selected_entry
        or selected_entry.valid ~= true or selected_entry.sno ~= entry.sno then
        retry('selection_verification_failed', now); return
    end
    if not M.check_guard() then return end
    -- Once accept is sent its result is ambiguous even if the binding throws.
    -- Never send another accept for this request; wait for actual receipt.
    tracker.claim_before = before
    tracker.last_pick_entry = {
        sno = entry.sno, name = rewards.display_name(entry),
        slot = rewards.extract_slot(entry), legendary = rewards.is_legendary(entry),
    }
    tracker.claim_sent = true
    pcall(quest_reward.accept)
    transition('API_CLAIMING', now)
end

function M.start(settings, reason, with_tp, callback)
    tracker.running, tracker.all_task_done = true, false
    tracker.last_reason, tracker.external_callback = reason or 'auto', callback
    tracker.attempts, tracker.claim_sent, tracker.confirm_since = 0, false, nil
    tracker.run_started_t = clock()
    tracker.state, tracker.state_t = with_tp and not whispers.in_whisper_town() and 'TELEPORTING' or 'START', clock()
end
function M.tick(settings)
    if not tracker.running then return end
    if not M.check_guard() then return end
    local now, zone = clock(), whispers.current_zone()
    tracker.observe_zone(zone)
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
        if npc then
            local pos = whispers.safe_method(npc, 'get_position')
            local x, y, z = whispers.safe_method(pos, 'x'), whispers.safe_method(pos, 'y'), whispers.safe_method(pos, 'z')
            if x and y and z then move({x=x,y=y,z=z}) end
        elseif whispers.player_dist_to_pos(tracker.walk_intermediate) > whispers.INTERMEDIATE_ARRIVAL_RADIUS then
            move(tracker.walk_intermediate)
        else move(whispers.RAVEN_NPC_POSITION) end
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
