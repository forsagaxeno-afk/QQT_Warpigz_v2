-- QQT_Warpigz_v3: Farm-mode smart chest order.
--
-- Candidates: chest actors in reach (interactable), remembered chests and
-- the learned atlas' likely chests (predicted). A candidate must not be
-- blacklisted, fenced out (core/hr_fence.lua), in a bad cell
-- (core/hr_roads.lua) or refused by the cinder plan (core/hr_cinder_plan.lua).
--
-- Order: class first (0 Mystery seen, 1 Mystery predicted, 2 regular seen,
-- 3 regular predicted), then the travel cost (the straight distance up to
-- 100 m, patrol-road metres beyond, the straight distance without a loop),
-- then the forward loop direction.
-- An allowed chest actor within 15 m is taken first (it is on the way).
-- A chest whose trips left the Helltide twice this hour is not a candidate
-- (on_left, QQT_Warpigz_v3).
--
-- No ping-pong: the current target is kept unless a candidate has a better
-- class or the same class at less than half the remaining cost, and the
-- target changes at most 3 times a minute.
--
-- Chest resets (UTC :00/:15/:20/:30/:40/:45, or a chest we opened seen
-- closed again): regular remembered chests not seen again since the reset
-- are dropped, the switch limit is cleared, and Mystery spots opened before
-- the reset are candidates again (one log line).
--
-- Warplan / WarPigs never get here (enabled() is Farm mode + 'Smart chest
-- order'); the legacy selection in tasks/helltide.lua runs unchanged there.
-- QQT_Warpigz_v3 (Q4): except during a cinder run (core/hr_cinder_run.lua,
-- every mode): Hell's Prize (666) first (class -2 seen, -1 predicted), then
-- the classes above; Hell's Prize is never a candidate outside the run, and
-- a chest on the way is not taken when it would leave too few cinders for
-- the run's target. While the run saves toward its threshold no chest is a
-- candidate (they stay remembered; the last minutes spend the savings).
local clock = require "core.hr_clock"
local atlas = require "core.hr_atlas"
local fence = require "core.hr_fence"
local roads = require "core.hr_roads"
local plan = require "core.hr_cinder_plan"
local stats = require "core.hr_stats"
local settings = require "core.settings"
local hr_mode = require "core.hr_mode"
local chest_targets = require "core.chest_targets"
local enums = require "data.enums"
local run = require "core.hr_cinder_run" -- QQT_Warpigz_v3 (Q4)

local M = {
    ROAD_MIN = 100,         -- farther: along the patrol road (when usable)
    RECALL_MAX = 150,       -- without a road route nothing farther is picked
    DETOUR_MAX = 2.5,       -- within RECALL_MAX a road this much longer than the straight way is not used
    OPPORTUNISTIC = 15,
    SWITCH_RATIO = 0.5,
    SWITCH_MAX = 3,
    SWITCH_WINDOW = 60,
    DUP_M = 6,
    RESET_SETTLE = 2.5,
    FORWARD_TIE_M = 5,
    MYSTERY = 'usz_rewardGizmo_Uber',
    EXIT_MAX = 2,           -- QQT_Warpigz_v3: trips out of the Helltide before a chest is dropped for the hour
}

-- QQT_Warpigz_v3 (night review): confirmed trips out of the Helltide per chest
-- key in this hour. Kept across task resets (the 180 s blacklist is not), so
-- a chest whose route leaves the Helltide EXIT_MAX times is not picked again
-- in that Helltide.
local exits = {hour = nil, n = {}}

local st
local function fresh()
    st = {incumbent = nil, switches = {}, slot = nil, reset_pending_at = nil, reset_minute = nil,
        reset_seen = nil, error_logged = false}
end
fresh()
M.last_plan = nil

local sqrt = math.sqrt

function M.enabled()
    if settings.smart_order == true and settings.helltide_chest ~= false and hr_mode.is_farm() then return true end
    return run.engaged() -- QQT_Warpigz_v3 (Q4): the cinder run uses this order in every mode
end

local function d2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return sqrt(dx * dx + dy * dy)
end

local function is_mystery(name) return name == M.MYSTERY end

-- ── chest resets ─────────────────────────────────────────────────────────
local function check_reset(ctx, now)
    local crossed, slot = clock.crossed_reset(st.slot)
    st.slot = slot
    local seen = atlas.reset_seen_at
    local spot_reset = seen ~= nil and seen ~= st.reset_seen
    if spot_reset then st.reset_seen = seen end
    if crossed or spot_reset then
        st.reset_pending_at = now
        st.reset_minute = clock.minute()
        st.switches = {}
    end
    if st.reset_pending_at and (now - st.reset_pending_at >= M.RESET_SETTLE or now < st.reset_pending_at) then
        local dropped = 0
        for key, entry in pairs(ctx.remembered or {}) do
            if not is_mystery(entry.name) and key ~= ctx.current
                and (entry.seen_at or entry.discovered_at or 0) < st.reset_pending_at then
                ctx.remembered[key] = nil
                dropped = dropped + 1
            end
        end
        stats.note(string.format('[CHEST ORDER] Chest reset at :%02d — %d stale regular chest(s) dropped, Mystery chests first again',
            st.reset_minute or 0, dropped))
        st.reset_pending_at = nil
        return true
    end
    return false
end

-- ── candidates ───────────────────────────────────────────────────────────
local function remember(ctx, key, name, cost, position, now)
    local entry = ctx.remembered[key]
    if entry then
        entry.seen_at = now
    else
        ctx.remembered[key] = {name = name, cost = cost, position = position, discovered_at = now, seen_at = now}
    end
end

local function collect(ctx, now)
    local cands, by_key, spent = {}, {}, {}
    local function add(c)
        if by_key[c.key] then return end
        by_key[c.key] = c
        cands[#cands + 1] = c
    end
    -- One classified snapshot per actor-cache refresh (shared with the atlas).
    for _, e in ipairs(atlas.classified(ctx.actors)) do
        local x, y, z = atlas.xyz(e.position)
        if x then
            if e.interactable then
                local key = ctx.key_of(e.name, e.position)
                remember(ctx, key, e.name, e.cost, e.position, now)
                add({kind = 'visible', key = key, name = e.name, cost = e.cost, position = e.position,
                    actor = e.actor, x = x, y = y, z = z})
            else
                spent[#spent + 1] = {x = x, y = y, mystery = is_mystery(e.name)}
            end
        end
    end
    local function spent_near(x, y, mystery)
        for _, s in ipairs(spent) do
            if s.mystery == mystery and d2(s.x, s.y, x, y) <= 4 then return true end
        end
        return false
    end
    for key, entry in pairs(ctx.remembered or {}) do
        local x, y, z = atlas.xyz(entry.position)
        if x and not by_key[key] then
            if spent_near(x, y, is_mystery(entry.name)) and key ~= ctx.current then
                ctx.remembered[key] = nil -- opened meanwhile
            else
                add({kind = entry.predicted and 'predicted' or 'remembered', key = key, name = entry.name,
                    cost = entry.cost, position = entry.position, spot = entry.spot, x = x, y = y, z = z})
            end
        end
    end
    local predicted = atlas.predicted(function(spot)
        local x, y = spot.x, spot.y
        if spent_near(x, y, spot.type == 'mystery') then return false end
        for _, c in ipairs(cands) do
            if is_mystery(c.name) == (spot.type == 'mystery') and d2(c.x, c.y, x, y) <= M.DUP_M then return false end
        end
        return true
    end)
    for _, spot in ipairs(predicted) do
        local pos = vec3:new(spot.x, spot.y, spot.z)
        add({kind = 'predicted', key = ctx.key_of(spot.name, pos), name = spot.name, cost = spot.cost,
            position = pos, spot = spot, x = spot.x, y = spot.y, z = spot.z})
    end
    return cands, by_key
end

local function classify(c, running)
    local base = run.class(c.name, running) or (is_mystery(c.name) and 0 or 2) -- QQT_Warpigz_v3 (Q4)
    if c.kind == 'predicted' then return base + 1 end
    return base
end

-- ── pick ─────────────────────────────────────────────────────────────────
-- ctx = {actors, remembered (map, updated in place), blacklisted(key),
--        key_of(name, pos), player, cinders, current (target key), now}
-- Returns the chosen candidate {kind, key, name, cost, position, actor,
-- class, cost_est, distance, route, predicted, spot, opportunistic} or nil.
function M.pick(ctx)
    local now = tonumber(ctx.now) or 0
    local px, py, pz = atlas.xyz(ctx.player)
    if not px then return nil end
    ctx.remembered = ctx.remembered or {}
    check_reset(ctx, now)
    local cands = collect(ctx, now)
    local minutes_left = clock.minutes_left()
    local eligible, mystery_known = {}, 0
    local cinders = tonumber(ctx.cinders) or 0
    -- QQT_Warpigz_v3 (Q4): the cinder run starts at its threshold and ends
    -- below the cheapest known chest that is not blacklisted (and that the
    -- run could pick: no learned Hell's Prize spot while the node is not taken).
    local cheapest = nil
    if run.on() then
        for _, c in ipairs(cands) do
            local cost = tonumber(c.cost)
            if cost and (cheapest == nil or cost < cheapest) and not (ctx.blacklisted and ctx.blacklisted(c.key))
                and run.candidate(c.name, c.kind, true, now) then
                cheapest = cost
            end
        end
    end
    local running = run.update(cinders, cheapest, now)
    for _, c in ipairs(cands) do
        local ok = not (ctx.blacklisted and ctx.blacklisted(c.key))
        -- QQT_Warpigz_v3 (Q4): Hell's Prize only during the run; nothing while
        -- the run saves toward its threshold (the chests stay remembered).
        if ok and not run.candidate(c.name, c.kind, running, now) then ok = false end
        -- An unaffordable regular chest can never be picked: no road
        -- planning for it (a Mystery still needs its cost: the reserve).
        if ok and not is_mystery(c.name) and cinders < (tonumber(c.cost) or math.huge) then ok = false end
        if ok and fence.allowed(c.position) == false then ok = false end
        if ok and roads.is_bad(c.position) then ok = false end
        if ok and exits.hour == clock.hour_id() and (exits.n[c.key] or 0) >= M.EXIT_MAX then ok = false end
        if ok then
            -- 3D, as the chest trip measures it (utils.distance_to).
            local flat, dz = d2(px, py, c.x, c.y), (c.z or pz) - pz
            c.distance = sqrt(flat * flat + dz * dz)
            if c.distance < M.ROAD_MIN then
                -- near: the direct approach / recall walks the straight way
                c.cost_est, c.route = c.distance, nil
            else
                c.cost_est, c.route = roads.cost(c.position, ctx.player, c.spot and c.spot.exit_idx)
                if c.route and c.distance <= M.RECALL_MAX and c.cost_est > c.distance * M.DETOUR_MAX then
                    -- the loop folds back: the direct recall is the shorter try
                    c.cost_est, c.route = c.distance, nil
                end
                if not c.route and c.distance > M.RECALL_MAX then ok = false end
            end
        end
        if ok then
            c.class = classify(c, running)
            c.mystery = is_mystery(c.name)
            if c.mystery and plan.reachable(c.cost_est, minutes_left) then mystery_known = mystery_known + 1 end
            eligible[#eligible + 1] = c
        end
    end
    local plan_ctx = {
        cinders = cinders,
        rate_min = stats.rate_min(),
        minutes_left = minutes_left,
        mystery_known = mystery_known,
        farm_mode = hr_mode.is_farm(),
        plan_on = settings.cinder_plan ~= false,
        max_carry = settings.max_carry,
        dump_min = settings.dump_min,
    }
    local allowed, by_key = {}, {}
    local refused = nil
    for _, c in ipairs(eligible) do
        local ok, why = plan.allow(c.cost, plan_ctx, c.mystery)
        if ok then
            allowed[#allowed + 1] = c
            by_key[c.key] = c
        elseif not refused and why ~= 'not affordable' then
            refused = why
        end
    end
    local reserve = plan.reserve(plan_ctx)
    M.last_plan = {reserve = reserve, mystery_known = mystery_known, refused = refused,
        candidates = #cands, allowed = #allowed, at = now, cinder_run = running or nil}
    if #allowed == 0 then
        run.note_empty(now) -- QQT_Warpigz_v3 (Q4): nothing to spend on: tears may be hunted
        return nil
    end

    -- A strict order (class, cost, key); the forward-direction tie-break is
    -- a separate pass (a tolerance inside the comparator is not transitive).
    table.sort(allowed, function(a, b)
        if a.class ~= b.class then return a.class < b.class end
        if a.cost_est ~= b.cost_est then return a.cost_est < b.cost_est end
        return a.key < b.key
    end)
    local lead = allowed[1]
    if not (lead.route and lead.route.dir == 1) then
        for i = 2, #allowed do
            local c = allowed[i]
            if c.class ~= lead.class or c.cost_est - lead.cost_est > M.FORWARD_TIE_M then break end
            if c.route and c.route.dir == 1 then
                table.remove(allowed, i)
                table.insert(allowed, 1, c)
                break
            end
        end
    end

    -- Opportunistic: an allowed chest actor right next to the player.
    -- QQT_Warpigz_v3 (Q4): during a cinder run only when the run's target
    -- (allowed[1]) stays affordable after it.
    local near = nil
    local lead_cost = tonumber(allowed[1].cost) or 0
    for _, c in ipairs(allowed) do
        if c.kind == 'visible' and c.distance <= M.OPPORTUNISTIC
            and (not running or c == allowed[1] or cinders - (tonumber(c.cost) or 0) >= lead_cost)
            and (not near or c.class < near.class or (c.class == near.class and c.distance < near.distance)) then
            near = c
        end
    end
    local choice
    if near then
        choice = near
        choice.opportunistic = true
    else
        local best = allowed[1]
        local inc_key = ctx.current or (st.incumbent and st.incumbent.key)
        local inc = inc_key and by_key[inc_key] or nil
        for i = #st.switches, 1, -1 do
            if now - st.switches[i] > M.SWITCH_WINDOW or now < st.switches[i] then table.remove(st.switches, i) end
        end
        if inc and best.key ~= inc.key then
            local better = best.class < inc.class
                or (best.class == inc.class and best.cost_est < inc.cost_est * M.SWITCH_RATIO)
            if better and #st.switches < M.SWITCH_MAX then
                choice = best
                st.switches[#st.switches + 1] = now
            else
                choice = inc
            end
        else
            choice = inc or best
        end
        st.incumbent = {key = choice.key, class = choice.class}
    end
    choice.predicted = choice.kind == 'predicted'
    M.last_plan.target_name = choice.name
    M.last_plan.target_pos = choice.position
    M.last_plan.target_key = choice.key
    M.last_plan.class = choice.class
    if running then run.note_target(now) end -- QQT_Warpigz_v3 (Q4)
    return choice
end

-- The target was opened, lost or abandoned: forget it as the incumbent.
function M.release(key)
    if st.incumbent and (key == nil or st.incumbent.key == key) then st.incumbent = nil end
    if M.last_plan and (key == nil or M.last_plan.target_key == key) then
        M.last_plan.target_name, M.last_plan.target_pos, M.last_plan.target_key = nil, nil, nil
    end
end

-- QQT_Warpigz_v3: a trip to `key` left the Helltide (confirmed). Returns the
-- count this hour and true once the chest is dropped for the hour.
function M.on_left(key)
    if key == nil then return 0, false end
    local hour = clock.hour_id()
    if exits.hour ~= hour then exits.hour, exits.n = hour, {} end
    local n = (exits.n[key] or 0) + 1
    exits.n[key] = n
    return n, n >= M.EXIT_MAX
end

function M.note_error(err)
    if st.error_logged then return end
    st.error_logged = true
    stats.note('[CHEST ORDER] smart chest order failed, using the plain order: ' .. tostring(err))
end

-- Helltide task reset (tasks/helltide.lua reset_run_state_second). A spot
-- reset seen before stays reported (no second "Chest reset" note for it).
function M.on_reset()
    local logged = st.error_logged
    fresh()
    st.error_logged = logged
    st.reset_seen = atlas.reset_seen_at
    M.last_plan = nil
    run.on_reset() -- QQT_Warpigz_v3 (Q4)
end

function M._state() return st end

return M
