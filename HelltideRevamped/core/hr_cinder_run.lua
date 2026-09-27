-- QQT_Warpigz_v3 (Q4): cinder run — "Spend cinders on chests at".
--
-- Off by default. With the option on:
--   * save phase (HR on its own, Farm or Warplan mode): below the set amount
--     of cinders (default 3000) no Helltide chest is opened; the chests seen
--     are remembered (and learned) so the run can go back to them. In the
--     last minutes of the Helltide ('Spend everything in the last (min)', at
--     least 2) the saved cinders are spent by the run's order, so they are
--     not lost at the hour's end. Not under WarPigs (external enable): the
--     War Plan step WarPlans_QST_Helltide_TorturedGifts is "spend 250 (Elite
--     750) cinders on Tortured Gifts" and WarPigs cuts HR as soon as it is
--     done, so saving would stall the War Plan and then strand the savings;
--   * the run: holding at least the set amount starts a chest run: the chest
--     order (core/hr_chest_order.lua) is used in every mode (Farm and
--     Warplan / WarPigs) and ranks the known chests by priority:
--       1. Hell's Prize (666 cinders; the War Plan Helltide node "Hell's Prize")
--       2. Mystery chests (Tortured Gift of Mysteries, 250)
--       3. the rest, nearest first by road / straight distance.
-- Known chests are the chests in sight, the remembered ones and the learned
-- (atlas) spots; trips reuse the chest order's bounds (blacklist after a
-- failed / stuck trip, bad cells, trips that left the Helltide, 150 m reach
-- without a road route). While the run is engaged and its last chest pick
-- was not empty, no new tear hunt starts (core/hr_mode.lua hunt_ruptures);
-- a tear in progress is finished, and tears are hunted again once the run
-- finds nothing to spend on.
-- The run starts only when a known chest is affordable, and ends when the
-- cinders fall below the cheapest known chest (or the option is switched
-- off: released on the next poll in every mode); it resumes in the same
-- Helltide hour after a task reset (town trip, death) while a known chest is
-- still affordable (every mode).
--
-- Hell's Prize: actor Warplan_Helltide_HellsPrize (and _PreTorment), d4data
-- ActorDefinition sno 2425942, lock data eCurrencyType 25 (Helltide cinders),
-- dwCurrencyAmount 666. The actor is a War Plan spawn: it only exists when the
-- node is taken, so the chest actor in sight (or remembered) is the ground
-- truth. A learned (predicted) Hell's Prize spot is skipped while the War
-- Plan read (warplan.selected_path / node_name, English client) says the node
-- is not taken; an unknown read keeps it. Hell's Prize chests are only opened
-- by the cinder run (default off: no change for players who do not use it).
local settings = require "core.settings"

local M = {
    HELLS_PRIZE = 'Warplan_Helltide_HellsPrize',
    HELLS_PRIZE_COST = 666,
    MYSTERY = 'usz_rewardGizmo_Uber',
    DEFAULT_AT = 3000,
    MIN_AT = 250,
    MAX_AT = 10000,
    MIN_COST = 75,          -- the cheapest Helltide chest (no chest known)
    BUSY_S = 10,            -- an empty run pick this recent: tears may be hunted
    NODE_CHECK_S = 60,
    DUMP_MIN = 5,           -- settings.dump_min default
    SAVE_DUMP_MIN = 2,      -- the save phase ends at least this long before the Helltide ends
}

-- resume_hour: the Helltide hour of a run a task reset interrupted.
-- empty_at: the last engaged chest pick that found nothing to spend on.
local st
local function fresh(resume_hour)
    st = {active = false, since = nil, start_cinders = nil, resume_hour = resume_hour,
        target_at = nil, empty_at = nil, node = nil, node_at = nil}
end
fresh()
local save_log_hour = nil -- the "saving" line: once per Helltide hour

local function num(v, default)
    v = tonumber(v)
    if v == nil or v ~= v then return default end
    return v
end

local function now()
    local ok, t = pcall(get_time_since_inject)
    return ok and tonumber(t) or 0
end

local function read_cinders()
    local ok, c = pcall(get_helltide_coin_cinders)
    if ok and type(c) == 'number' and c == c then return c end
    return nil
end

local clock_mod = nil
local function clock_call(fn)
    if clock_mod == nil then
        local ok, c = pcall(require, "core.hr_clock")
        clock_mod = (ok and type(c) == 'table') and c or false
    end
    if not clock_mod or type(clock_mod[fn]) ~= 'function' then return nil end
    local ok, v = pcall(clock_mod[fn])
    if ok then return v end
    return nil
end

local function hour_id() return clock_call('hour_id') end

-- HR enabled by WarPigs (or any external caller): no save phase.
local mode_mod = nil
local function external()
    if mode_mod == nil then
        local ok, m = pcall(require, "core.hr_mode")
        mode_mod = (ok and type(m) == 'table' and type(m.is_external) == 'function') and m or false
    end
    if not mode_mod then return false end
    local ok, v = pcall(mode_mod.is_external)
    return ok and v == true
end

local function log(text)
    if console and console.print then console.print('[CINDER RUN] ' .. text) end
end

-- Option on (and Helltide chests on).
function M.on()
    return settings.cinder_run == true and settings.helltide_chest ~= false
end

function M.threshold()
    local v = num(settings.cinder_run_at, M.DEFAULT_AT)
    if v < M.MIN_AT then return M.MIN_AT end
    if v > M.MAX_AT then return M.MAX_AT end
    return v
end

function M.is_prize(name) return name == M.HELLS_PRIZE end

-- Chest kind: 'prize' | 'mystery' | 'regular' (a learned spot matches a
-- chest of its own kind only).
function M.kind(name)
    if name == M.HELLS_PRIZE then return 'prize' end
    if name == M.MYSTERY then return 'mystery' end
    return 'regular'
end

-- Minutes the save phase leaves for spending the saved cinders.
function M.dump_minutes()
    return math.max(M.SAVE_DUMP_MIN, num(settings.dump_min, M.DUMP_MIN))
end

-- The last minutes of the Helltide: saved cinders are spent (the run order).
function M.dump_window()
    local left = tonumber(clock_call('minutes_left'))
    return left ~= nil and left <= M.dump_minutes()
end

local function node_text(v)
    if v == true then return "Hell's Prize node taken" end
    if v == false then return "Hell's Prize node not in the War Plan" end
    return "Hell's Prize node unknown"
end

local function start(c, t, why)
    st.active, st.since, st.start_cinders, st.target_at, st.empty_at = true, t, c, nil, nil
    st.resume_hour = nil
    log(string.format('%d cinders %s — spending on chests: Hell\'s Prize (666) > Mystery (250) > the rest, nearest first (%s)',
        c, why, node_text(M.node_taken(t))))
end

local function stop(c, why)
    if st.active then
        log(string.format('Done: %s; cinders %d -> %d — back to normal farming',
            why, st.start_cinders or c, c))
    end
    st.active, st.since, st.target_at, st.resume_hour, st.empty_at = false, nil, nil, nil, nil
end

-- Option switched off (or Helltide chests off): the run and a pending resume
-- are released on the first poll, in every mode (C6). true: off.
local function release_if_off()
    if M.on() then return false end
    if st.active or st.resume_hour ~= nil then
        stop(read_cinders() or 0, 'the option was switched off')
    end
    st.empty_at = nil
    return true
end

function M.active()
    if release_if_off() then return false end
    return st.active == true
end

local function resume_pending()
    return st.resume_hour ~= nil and st.resume_hour == hour_id()
end

-- The chest order runs the run's order in every mode: the run is on, the
-- threshold is reached, a resume is pending in this Helltide hour, or the
-- saved cinders are due (last minutes); pick() then starts or resumes it.
function M.engaged()
    if release_if_off() then return false end
    if st.active then return true end
    local c = read_cinders()
    if c == nil or c < M.MIN_COST then return false end
    if c >= M.threshold() or resume_pending() then return true end
    return M.dump_window()
end

-- Save phase: the option is on, the run is not, HR runs on its own (not
-- WarPigs) and the Helltide is not in its last minutes. Chests are
-- remembered, not opened.
function M.saving()
    if release_if_off() or st.active or external() then return false end
    return not M.dump_window()
end

local function note_saving()
    local h = hour_id()
    if save_log_hour ~= nil and save_log_hour == h then return end
    save_log_hour = h
    log(string.format('Saving cinders for the run at %d (have %d): chests are remembered, not opened; the last %d min of the Helltide spend them',
        M.threshold(), read_cinders() or 0, M.dump_minutes()))
end

-- Legacy selection gates (tasks/helltide.lua: plain select, recall, Farm
-- Cinder Threshold): Hell's Prize only during the run; nothing while saving.
function M.allows(name)
    if release_if_off() then return name ~= M.HELLS_PRIZE end
    if st.active then return true end
    if name == M.HELLS_PRIZE then return false end
    if not external() and not M.dump_window() then
        note_saving()
        return false
    end
    return true
end

-- Chest order candidate filter (core/hr_chest_order.lua pick). kind:
-- 'visible' | 'remembered' | 'predicted'.
function M.candidate(name, kind, running, t)
    if running then
        -- A learned Hell's Prize spot while the War Plan read says the node
        -- is not taken: a sure miss (an actor in sight is the ground truth).
        if name == M.HELLS_PRIZE and kind == 'predicted' and M.node_taken(t) == false then return false end
        return true
    end
    if name == M.HELLS_PRIZE then return false end
    if M.on() and not external() and not M.dump_window() then
        note_saving()
        return false
    end
    return true
end

-- No new tear hunt while the run is engaged, unless its last chest pick (in
-- the last BUSY_S seconds) found nothing to spend on.
function M.busy()
    if not M.engaged() then return false end
    local e, t = st.empty_at, now()
    return not (e ~= nil and t >= e and t - e <= M.BUSY_S)
end

function M.note_target(t)
    st.target_at = tonumber(t) or now()
    st.empty_at = nil
end

function M.note_empty(t)
    if M.on() then st.empty_at = tonumber(t) or now() end
end

-- Class offset for the chest order: Hell's Prize first during the run.
function M.class(name, running)
    if running and name == M.HELLS_PRIZE then return -2 end
    return nil
end

-- War Plan node "Hell's Prize" selected: true / false / nil (unknown: no
-- War Plan API or data, or a non-English client).
local function match_node(text)
    if type(text) ~= 'string' then return false end
    local l = text:lower():gsub('\226\128\153', "'")
    return l:find("hell's prize", 1, true) ~= nil or l:find("hells prize", 1, true) ~= nil
        or l:find("hellsprize", 1, true) ~= nil
end

function M.node_taken(t)
    t = tonumber(t) or now()
    if st.node_at and t >= st.node_at and t - st.node_at < M.NODE_CHECK_S then return st.node end
    st.node_at = t
    local api = rawget(_G, 'warplan')
    if type(api) ~= 'table' or type(api.selected_path) ~= 'function' then
        st.node = nil
        return nil
    end
    local ok, found = pcall(function()
        local path = api.selected_path()
        if type(path) ~= 'table' or #path == 0 then return nil end
        for _, id in ipairs(path) do
            if match_node(api.node_name and api.node_name(id))
                or match_node(api.node_reward_name and api.node_reward_name(id)) then
                return true
            end
        end
        return false
    end)
    if ok and found ~= nil then st.node = found == true else st.node = nil end
    return st.node
end

-- Called by the chest order with the live cinders and the cost of the
-- cheapest known chest that is not blacklisted (nil: none known). Returns
-- true while the run is active. A run starts only when a known chest (or,
-- none known, the cheapest Helltide chest) is affordable, so a threshold
-- below the cheapest known chest does not start and end a run on every pick.
function M.update(cinders, cheapest, t)
    t = tonumber(t) or now()
    local c = num(cinders, 0)
    if release_if_off() then return false end
    local floor_cost = num(cheapest, M.MIN_COST)
    if st.active then
        if c < floor_cost then
            stop(c, cheapest and string.format('below the cheapest known chest (%d)', floor_cost)
                or string.format('below the cheapest chest (%d)', floor_cost))
        end
        return st.active
    end
    if c < floor_cost then return false end
    if c >= M.threshold() then
        start(c, t, string.format('>= %d', M.threshold()))
    elseif cheapest and resume_pending() then
        start(c, t, 'left after a reset in this Helltide hour, run resumed')
    elseif cheapest and M.dump_window() then
        start(c, t, string.format('%s, the Helltide ends in %d min or less',
            external() and 'held' or 'saved', M.dump_minutes()))
    end
    return st.active
end

-- Helltide task reset (core/hr_chest_order.lua on_reset). The run of this
-- Helltide hour may resume (update) while a known chest is affordable.
function M.on_reset()
    local resume = st.resume_hour
    if st.active and M.on() then resume = hour_id() end
    if resume ~= nil and resume ~= hour_id() then resume = nil end
    fresh(resume)
end

function M.status()
    return {active = M.active(), since = st.since, start_cinders = st.start_cinders, node = st.node,
        threshold = M.threshold(), on = M.on(), saving = M.on() and M.saving() or nil}
end

function M._state() return st end
function M._reset() fresh(); save_log_hour = nil end

return M
