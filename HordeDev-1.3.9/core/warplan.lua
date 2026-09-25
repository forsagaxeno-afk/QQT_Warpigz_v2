-- F-H1: War Plan entry mode. InfernalHordesPlugin.enable({entry = 'warplan'})
-- runs a horde that the War Plan 'Teleport' (warplan.teleport_to_activity(),
-- driven by WarPigs) already entered: no compass, no Library/gate walk, no
-- portal walk-in, no built-in Cerrigar salvage and no second cycle after the
-- exit. Outside BSK the plugin idles visibly. Inside BSK the normal horde /
-- pylon / council / chest / exit logic runs; War Plan hordes have 6 waves and
-- nothing here counts waves. If no chest room (or stash) shows up after the
-- horde, completion is still reached within a bound and the Horde is left.
-- The mode lives in tracker.entry_mode (runtime only, never persisted).
local tracker = require 'core.tracker'
local utils = require 'core.utils'
local enums = require 'data.enums'

local HORDE_ZONE = 'S05_BSK_Prototype02'
local QUEST = 'WarPlans_QST_InfernalHordes'

local M = {
    -- Completion evidence (stash / objective gone / quiet boss room) without
    -- a gold chest for this long means the War Plan horde has no chest room.
    CHEST_WAIT = 20,
    -- Waves cleared and the boss room quiet (no target, pylon or locked door)
    -- this long counts as completion evidence when nothing else shows it.
    IDLE_WAIT = 40,
    -- Chest phase finished but no stash visible: leave after this long.
    STASH_WAIT = 10,
    WAIT_TASK = 'Waiting for War Plan teleport',
    WAIT_TEXT = 'waiting for War Plan teleport',
    DONE_TASK = 'War Plan horde complete',
    completed = false,   -- this War Plan run left the Horde (exit finished)
    last_result = nil,   -- 'completed' after a War Plan exit (C2 status)
}
local run = {evidence_since = nil, finished_since = nil, quest_seen = false, quest_gone = false,
    quest_moved_on = false, quest_checked = nil, checked_at = nil}
local idle_log = {since = nil, seen = nil, logged_at = nil}
local IDLE_LOG_EVERY = 60

function M.active()
    return tracker.entry_mode == 'warplan'
end

function M.mode()
    return tracker.entry_mode == 'warplan' and 'warplan' or 'compass'
end

function M.set_mode(mode)
    local new = mode == 'warplan' and 'warplan' or 'compass'
    if tracker.entry_mode ~= new then
        console.print('[HordeDev] Entry mode: ' .. new
            .. (new == 'warplan' and ' (War Plan teleport; no compass, no Library walk, one run)' or ''))
    end
    tracker.entry_mode = new
end

-- Inside the Horde: zone S05_BSK_Prototype02 in a loaded BSK world.
function M.inside_bsk()
    local ok, inside = pcall(function()
        local w = get_current_world()
        if not w then return false end
        local name, zone = w:get_name(), w:get_current_zone_name()
        if type(name) ~= 'string' or zone ~= HORDE_ZONE then return false end
        local lower = name:lower()
        if lower:find('loading', 1, true) or lower:find('limbo', 1, true) then return false end
        return lower:find('bsk', 1, true) ~= nil
    end)
    return ok and inside == true
end

-- Per-run state; the entry mode itself is kept.
function M.reset_run()
    M.completed, M.last_result = false, nil
    run.evidence_since, run.finished_since = nil, nil
    run.quest_seen, run.quest_gone, run.quest_checked, run.checked_at = false, false, nil, nil
    run.quest_moved_on = false
end

-- The War Plan exit finished outside the Horde: no new cycle follows.
function M.complete()
    M.completed, M.last_result = true, 'completed'
    console.print('[HordeDev] War Plan horde complete; no new cycle (waiting for WarPigs)')
end

-- C6: the visible wait outside BSK is logged when it starts and then at
-- most once a minute while it lasts (a gap of over a second starts anew).
function M.note_wait()
    local now = get_time_since_inject()
    local w = idle_log
    if not w.seen or now - w.seen > 1 then
        w.since, w.logged_at = now, now
        console.print('[HordeDev] War Plan entry: outside the Horde, waiting for the War Plan teleport'
            .. ' (no compass, no Library walk, no movement)')
    elseif now - w.logged_at >= IDLE_LOG_EVERY then
        w.logged_at = now
        console.print(string.format('[HordeDev] War Plan entry: still waiting for the War Plan teleport (%ds)',
            math.floor(now - w.since)))
    end
    w.seen = now
end

-- Seconds since the chest phase finished (0 while it has not).
function M.finished_for()
    if not run.finished_since then return 0 end
    return get_time_since_inject() - run.finished_since
end

-- The War Plan objective disappears when the horde is beaten. Only a quest
-- seen during this run and then gone counts; an unreadable list is no
-- evidence either way. Rate-limited to once a second.
-- Joint K1: a run that has never seen its objective while the readable list
-- already shows another War Plan step (the TurnIn or the next activity) was
-- started after the horde was beaten (a QQT reload after the Council; the
-- fresh tracker never sees the door or the Council): quest_moved_on.
local function track_quest(now)
    if run.quest_checked and now - run.quest_checked < 1 then return end
    run.quest_checked = now
    if type(get_quests) ~= 'function' then return end
    local ok, quests = pcall(get_quests)
    if not ok or type(quests) ~= 'table' then return end
    local other_step = false
    for _, quest in pairs(quests) do
        local ok_n, name = pcall(function() return quest:get_name() end)
        if not ok_n or type(name) ~= 'string' then return end
        if name:find(QUEST, 1, true) then
            run.quest_seen, run.quest_gone, run.quest_moved_on = true, false, false
            return
        end
        if name:find('WarPlans_', 1, true) then other_step = true end
    end
    if run.quest_seen then run.quest_gone = true
    elseif other_step then run.quest_moved_on = true end
end

-- Only after the waves (the locked door was seen, or a Council/Bartuc
-- pylon) AND while the wave task is idle in the boss room: a stash visible
-- from the start, the door approach, a pylon or a Council fight, or a
-- transient empty quest list mid-wave is no evidence. horde_idle_since is
-- cleared by every horde pulse that targets, moves to the door or uses a
-- pylon, so the CHEST_WAIT window restarts after each of them; task_manager
-- also clears it whenever another task (an Alfred hold, the exit) or no task
-- runs, so a stale idle reading never counts while the wave task is not
-- looking (H5-1).
-- Joint K1: nothing of a wave in sight — no offering pylon (the wave task's
-- last pulse) and no living enemy (the same actor scan as its get_target).
-- An unreadable actor list is not quiet.
local function arena_quiet()
    if tracker.interacting_pylon then return false end
    local ok, busy = pcall(function()
        for _, actor in pairs(actors_manager:get_all_actors()) do
            if actor:is_enemy() and actor:get_current_health() > 1 then return true end
        end
        return false
    end)
    return ok and busy == false
end

local function completion_evidence(now)
    local waves_over = tracker.locked_door_found or tracker.council_seen
    -- Joint K1: the objective was already complete before this run started
    -- (see track_quest; a reload after the Council, where the fresh tracker
    -- never sees the door or the Council) and no wave is in sight. A run that
    -- sees the door or a Council pylon itself takes the gate below instead;
    -- a chest room still owns completion (M.update).
    if run.quest_moved_on and not run.quest_seen and not waves_over then
        return arena_quiet() and 'War Plan objective already complete' or nil
    end
    if not waves_over then return nil end
    local idle = tracker.horde_idle_since
    if not idle then return nil end
    local ok, stash = pcall(utils.get_stash)
    if ok and stash ~= nil then return 'stash visible' end
    if run.quest_gone then return 'War Plan objective complete' end
    if now - idle >= M.IDLE_WAIT then return 'boss room quiet' end
    return nil
end

-- Every pulse in War Plan mode (rate-limited): the bounded no-chest-room
-- completion. A running chest phase or a visible gold chest owns completion.
function M.update(chest_state)
    if not M.active() then return end
    local now = get_time_since_inject()
    if tracker.finished_chest_looting then
        run.finished_since, run.evidence_since = run.finished_since or now, nil
        return
    end
    run.finished_since = nil
    if run.checked_at and now - run.checked_at < 0.25 then return end
    run.checked_at = now
    if not M.inside_bsk() then run.evidence_since = nil; return end
    track_quest(now)
    local gold_type = enums.chest_types and enums.chest_types.GOLD
    local ok, gold = pcall(utils.get_chest, gold_type)
    if (chest_state ~= nil and chest_state ~= 'INIT') or (ok and gold ~= nil) then
        run.evidence_since = nil
        return
    end
    local evidence = completion_evidence(now)
    if not evidence then run.evidence_since = nil; return end
    run.evidence_since = run.evidence_since or now
    if now - run.evidence_since < M.CHEST_WAIT then return end
    tracker.chests_skipped = 'no chest room (' .. evidence .. ')'
    tracker.finished_chest_looting = true
    run.finished_since, run.evidence_since = now, nil
    console.print(string.format('[HordeDev] War Plan horde: %s for %ds and no chest room; leaving without chests',
        evidence, M.CHEST_WAIT))
end

return M
