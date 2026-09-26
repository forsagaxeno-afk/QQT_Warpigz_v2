local plugin_label = 'wonder_city'
local utils = require 'core.utils'
local settings = require 'core.settings'
local tracker = require 'core.tracker'
local reward_phase = require 'core.reward_phase'

local INTERACT_REFIRE_COOLDOWN = 1
local INTERACT_TIMEOUT = 8
local CONFIRM_SECONDS = 1
-- CRT-1/L9 bounded waits (seconds of this task's own execution; time spent
-- yielding to Alfred is shifted out, C5):
--  * a chest that is non-interactable before our first click was opened
--    already (by hand, a companion, or before an Alfred round trip) unless
--    it unlocks. R14: LOCKED_WAIT after positive evidence of an opening
--    (our own earlier interaction, a loot burst next to it, or a boss kill
--    observed after the chest was first seen), else LOCKED_WAIT_UNKNOWN:
--    a chest whose boss is outside the actor stream may still be locked;
--  * our interacted chest vanished from stable scans without new loot;
--  * no approach progress at close range: interact from where we stand.
local LOCKED_WAIT, LOCKED_WAIT_UNKNOWN = 10, 60
local VANISH_WAIT = 5
local APPROACH_STALL, APPROACH_FALLBACK_RANGE, APPROACH_PROGRESS = 8, 4, 0.5
local task = {name = 'goto_chest', status = 'idle'}

local function item_ids()
    local ok, items = pcall(actors_manager.get_all_items)
    if not ok or type(items) ~= 'table' then return nil end
    local ids = {}
    for _, item in pairs(items) do
        local read, id = pcall(function() return item:get_id() end)
        if not read or type(id) ~= 'number' then return nil end
        ids[id] = true
    end
    return ids
end

local function has_new_loot()
    if not task.items_before then return false end
    local current = item_ids()
    if not current then return false end
    for id in pairs(current) do
        if not task.items_before[id] then return true end
    end
    return false
end

local function chest_key(chest)
    local ok, key = pcall(function()
        if chest.get_id then
            local id = chest:get_id()
            if type(id) == 'number' then return tostring(id) end
        end
        local pos = chest:get_position()
        return chest:get_skin_name() .. ':' .. tostring(pos:x()) .. ':' .. tostring(pos:y())
    end)
    return ok and key or nil
end

local function complete(reason)
    reward_phase.mark_opened(reason)
    task.reset()
    task.status = 'reward opened; waiting for loot'
    utils.stop_movement()
    settings.orb_set_clear(true)
end

local function confirm(reason)
    if task.confirm_reason ~= reason then
        task.confirm_reason = reason
        task.confirm_since = get_time_since_inject()
    elseif get_time_since_inject() - task.confirm_since >= CONFIRM_SECONDS then
        complete(reason)
    end
end

local function clear_confirmation()
    task.confirm_reason, task.confirm_since = nil, nil
end

-- R14: positive evidence that a never-clicked, non-interactable chest was
-- opened already rather than still locked. A corpse seen together with the
-- chest, or a kill before the chest was first seen (possibly another
-- is_boss() actor), is not evidence.
local function opened_evidence()
    if tracker.chest_interacted then return 'we interacted with the reward chest earlier' end
    if tracker.chest_loot_seen then return 'new loot dropped next to the chest' end
    local kill, seen = tracker.boss_kill_seen, tracker.chest_first_seen
    if kill and seen and kill >= seen then return 'boss kill observed after the chest was first seen' end
    return nil
end

-- One diagnostic line per wait and evidence state (R14 live check): the
-- chest key, its interactable state, boss_kill_time and the last boss seen.
local function locked_log(key, interactable, now, evidence)
    local state = tostring(key) .. '|' .. tostring(evidence)
    if task.locked_logged == state then return end
    task.locked_logged = state
    local stamp = function(t) return t and string.format('%.1f', t) or 'none' end
    local boss = tracker.last_boss_name and string.format('%s hp=%s seen %.0fs ago', tracker.last_boss_name,
        tostring(tracker.last_boss_health), now - (tracker.last_boss_at or now)) or 'none observed'
    console.print(string.format('[WonderCity:chest] reward chest %s is not interactable before our click '
        .. '(interactable=%s, boss_kill_time=%s, observed kill=%s, last boss=%s, chest first seen=%s); %s',
        tostring(key), tostring(interactable), stamp(tracker.boss_kill_time), stamp(tracker.boss_kill_seen), boss,
        stamp(tracker.chest_first_seen),
        evidence and string.format('opened evidence: %s; treating it as already opened in %ds unless it unlocks',
            evidence, LOCKED_WAIT)
        or string.format('no opened evidence; waiting up to %ds for an unlock', LOCKED_WAIT_UNKNOWN)))
end

-- Non-interactable before our first click: wait (bounded) for an unlock.
local function locked_wait(now, key, interactable)
    if tracker.boss_alive then
        task.locked_since, task.evidence_at = nil, nil
        task.status = 'waiting for reward chest to unlock (boss alive)'
        return
    end
    local evidence = opened_evidence()
    task.locked_since = task.locked_since or now
    if evidence then task.evidence_at = task.evidence_at or now end
    locked_log(key, interactable, now, evidence)
    local waited = now - task.locked_since
    local limit = task.evidence_at and math.min(LOCKED_WAIT_UNKNOWN, task.evidence_at - task.locked_since + LOCKED_WAIT)
        or LOCKED_WAIT_UNKNOWN
    if waited >= limit then
        complete(evidence and string.format('chest not interactable for %.0fs before our click; already opened (%s)',
            waited, evidence)
            or string.format('chest not interactable for %.0fs before our click and no opened evidence; '
                .. 'treating it as already opened', waited))
        return
    end
    task.status = string.format('waiting for reward chest to unlock (%.0fs%s)', limit - waited,
        evidence and '' or ', no opened evidence')
end

-- Approach progress (close-range stall falls back to interacting in place).
local function approach_stalled(distance, now)
    if task.approach_best == nil or distance < task.approach_best - APPROACH_PROGRESS then
        task.approach_best, task.approach_time = distance, now
        return false
    end
    return distance <= APPROACH_FALLBACK_RANGE and now - task.approach_time >= APPROACH_STALL
end

task.shouldExecute = function ()
    return utils.player_in_undercity() and not tracker.done and not tracker.chest_failed
        and (utils.get_undercity_chest() ~= nil or task.last_interact_call ~= nil)
end

task.Execute = function ()
    local player = get_local_player()
    if not player or not utils.player_in_undercity() then return end
    BatmobilePlugin.pause(plugin_label)
    BatmobilePlugin.update(plugin_label)
    local now = get_time_since_inject()
    local chest, scan_ok = utils.get_undercity_chest()
    if not scan_ok then clear_confirmation();task.status = 'waiting for valid chest scan';return end
    if task.last_interact_call and has_new_loot() then task.loot_observed = true end

    -- A single empty actor list is not an opened chest. Disappearance requires
    -- our own close-range interaction, and newly observed loot or a stable
    -- absence of VANISH_WAIT seconds.
    if not chest then
        if task.last_interact_call and task.loot_observed then
            task.loot_observed = true
            confirm('chest disappeared with new loot')
        elseif task.last_interact_call then
            clear_confirmation()
            task.missing_since = task.missing_since or now
            if now - task.missing_since >= VANISH_WAIT then
                console.print('[WonderCity:chest] interacted reward chest vanished; treating it as opened')
                complete('interacted chest vanished')
                return
            end
        else
            clear_confirmation()
        end
        task.status = tracker.done and 'reward opened; waiting for loot' or 'waiting for chest confirmation'
    else
        task.missing_since = nil
        local key = chest_key(chest)
        if not key then clear_confirmation();return end
        if task.active_key and task.active_key ~= key then task.reset() end
        task.active_key = key
        local read, distance, interactable = pcall(function()
            return utils.distance(player, chest), chest:is_interactable()
        end)
        if not read then clear_confirmation();return end
        if distance > 2 and not approach_stalled(distance, now) then
            clear_confirmation()
            BatmobilePlugin.set_target(plugin_label, chest)
            BatmobilePlugin.move(plugin_label)
            task.status = 'walking to reward chest'
            return
        end
        utils.stop_movement()
        if interactable then
            task.locked_since, task.evidence_at = nil, nil
            task.interact_time = task.interact_time or now
            clear_confirmation()
            settings.orb_set_clear(false)
            if not task.last_interact_call or now - task.last_interact_call >= INTERACT_REFIRE_COOLDOWN then
                if not task.last_interact_call then task.items_before = item_ids() end
                console.print('[WonderCity:chest] interact_object dist=' .. string.format('%.2f', distance))
                interact_object(chest)
                task.last_interact_call = now
                tracker.chest_interacted = tracker.chest_interacted or now -- R14 evidence (kept per floor)
            end
            task.status = 'interacting with reward chest'
        elseif task.last_interact_call then
            settings.orb_set_clear(true)
            confirm('interacted chest no longer interactable')
            task.status = tracker.done and 'reward opened; waiting for loot' or 'confirming reward chest'
        else
            -- A closed/non-interactable object seen before our first click
            -- may still be locked by the boss. Bounded (L9: an already opened
            -- chest stays non-interactable forever).
            settings.orb_set_clear(true)
            locked_wait(now, key, interactable)
        end
    end

    if not tracker.done and task.interact_time and now - task.interact_time > INTERACT_TIMEOUT then
        -- CRT-1: the host can keep an opened chest flagged interactable.
        -- Bounded completion (upstream behavior) instead of waiting for
        -- the run reset; loot still gets its quiet period before the exit.
        console.print('[WonderCity:chest] opening unconfirmed after ' .. INTERACT_TIMEOUT
            .. 's of interaction; treating the reward chest as opened')
        complete(task.loot_observed and 'interacted; new loot observed (chest stays interactable)'
            or 'interaction unconfirmed; chest stays interactable')
    end
end

-- C5: time spent yielding (e.g. to Alfred) is not waiting/progress time.
task.on_yield = function (seconds)
    for _, field in ipairs({'interact_time', 'last_interact_call', 'confirm_since', 'locked_since',
        'evidence_at', 'missing_since', 'approach_time'}) do
        if task[field] then task[field] = task[field] + seconds end
    end
end

task.reset = function ()
    task.interact_time, task.last_interact_call, task.active_key = nil, nil, nil
    task.items_before, task.loot_observed = nil, false
    task.locked_since, task.missing_since, task.evidence_at, task.locked_logged = nil, nil, nil, nil
    task.approach_best, task.approach_time = nil, nil
    clear_confirmation()
end

return task
