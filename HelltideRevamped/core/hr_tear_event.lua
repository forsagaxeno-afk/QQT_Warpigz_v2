-- Pandemonium Ruptures ("tears", Season 14) for Helltide FARM mode.
--
-- Ported from upstream HelltideRevamped 2.5.0 core/tear_event.lua into this
-- fork: find a rupture (ritual ring / starter gizmo / live tear), walk there,
-- kill the cultists, close the tears, open the rupture chests, linger, and
-- optionally fight the Realmwalker and run the Deathtoll Chamber.
--
-- Differences from upstream (deliberate):
--   * Farm mode only (core/hr_mode.lua). Warplan / external enable never
--     enters or keeps a rupture state.
--   * No phase controller, external-rotation globals, session file logs,
--     HUD or Frigate: combat uses this fork's orbwalker gate
--     (settings.force_orb_clear_for) and movement uses the helltide task's
--     move_to / clear_movement (bound via M.bind at load time).
--   * Every host call on an actor or optional global is pcall-protected, so
--     a missing API only disables that step.
--   * A finished or abandoned rupture is blacklisted by AREA for a while (the
--     upstream key was wiped by its own session reset), and every rupture has
--     an approach watchdog and an overall time cap.
local utils = require "core.utils"
local settings = require "core.settings"
local enums = require "data.enums"
local skins = require "data.hr_tear_skins"
local leash = require "core.hr_rupture_leash"
local hr_mode = require "core.hr_mode"
local stand = require "core.hr_tear_stand" -- QQT_Warpigz_v3 (Q2): stand in the tear until it closes
local loot = require "core.hr_tear_loot" -- QQT_Warpigz_v3 (Q3): no looting until the whole event is over
local cinder_run = require "core.hr_cinder_run" -- QQT_Warpigz_v3 (rc.2): the save phase holds ring chests too

local M = { skins = skins }
local helpers = {}      -- bound by tasks/helltide.lua (move_to, clear_movement, get_actors, get_kill_target)
local sess = {}         -- per-rupture session
local live_evidence     -- QQT_Warpigz_v3 3.3.2: defined with the scans below
local area_blacklist = {} -- { pos, until_t, skin, spent_until } — survives session resets
local spent_tears = {}    -- QQT_Warpigz_v3 3.3.2: tear key -> until (survives session resets)

local C = {
    CHEST_INTERACT_DIST = 2.5,
    CHEST_INTERACT_COOLDOWN = 3.5,
    CHEST_LOOT_PAUSE = 2.5,
    CHEST_SCAN_PAD = 35,
    CHEST_SCAN_TTL = 0.75,
    BLACKLIST_TTL = 120,
    BLACKLIST_RADIUS = 25,
    PORTAL_INTERACT_DIST = 4.5,
    PORTAL_INTERACT_COOLDOWN = 1.25,
    PORTAL_ENTER_TIMEOUT = 25,
    PORTAL_POST_KILL_WAIT = 30,
    TEAR_ATTACK_DIST = 4,
    TEAR_STAND_MAX = 0.7,
    -- QQT_Warpigz_v3 (Q2): TEAR_CLOSE_STUCK_S (18) and TEAR_STATIC_SKIP_S
    -- (12) are gone; the per-tear bounds live in core/hr_tear_stand.lua.
    TEAR_SKIP_TTL_S = 45,
    RITUAL_CONTEXT_DIST = 45,
    SPAWN_WAIT_S = 5,
    HOLD_AREA_MAX_S = 30,
    CHEST_APPROACH_NO_PROGRESS_S = 12,
    APPROACH_NO_PROGRESS_S = 20,
    APPROACH_PROGRESS_M = 4,
    RUPTURE_MAX_S = 300,
    RW_CHAIN_MAX_S = loot.C.RW_CHAIN_MAX_S, -- QQT_Warpigz_v3 (rc.2 review): Realmwalker wait + fight + portal
    CHAMBER_MAX_S = 480,
    POLL_TTL = 0.5,
    KILL_SCAN_TTL = 2.0,
    -- QQT_Warpigz_v3 3.3.2 (live: "standing around, activity Pandemonium
    -- rupture, but there is no rupture"): a rupture state needs a live
    -- rupture actor. Strong evidence: an open tear, a living cultist or
    -- Realmwalker near the anchor. Marker evidence (an active-event marker
    -- or wave proxy) only proves the site was live, it never keeps it alive.
    LIVE_SCAN_M = 30,       -- the grace starts once the anchor is this close (its actors are listed)
    LIVE_GRACE_S = 6,       -- at the site with no live rupture actor at all: leave (abandoned)
    LIVE_TTL = 0.25,        -- evidence scan interval
    QUIET_OPEN_MAX_S = 30,  -- live (cultists / markers) but no tear ever opened: complete after this quiet
    QUIET_PAD_S = 8,        -- tears seen, all closed: complete after linger + this quiet (walk to the centre included)
    SPENT_TTL = 900,        -- a finished site / a tear stood in without closing is not re-armed without strong evidence
    SPENT_TEAR_INSIDE_S = 20, -- a tear skipped after this long inside its circle is spent
    -- QQT_Warpigz_v3 3.3.3 (live: "standing around"): a site or tear the bot
    -- could not reach, and cultists it could not kill or reach, are left
    -- for this long (the 120 s blacklist re-armed them while they lived).
    UNREACHABLE_S = 300,
    GUARD_STALL_S = 20,     -- no cultist hurt and none got closer for this long: leave them
    GUARD_PROGRESS_M = 2,
}
M.C = C

local TYPE_RANK = { Colossal = 3, Surging = 2, Normal = 1 }

local RIFT_STATES = {
    MOVING_TO_RIFT = true, RIFT_KILL_GUARDS = true, RIFT_WAIT_OPEN = true,
    RIFT_CLOSE_TEARS = true, RIFT_STAY_ACTIVE = true, RIFT_OPEN_CHEST = true,
    RIFT_WAIT_REALMWALKER = true, RIFT_KILL_REALMWALKER = true, RIFT_ENTER_CHAMBER = true,
    CHAMBER_START_RITUAL = true, CHAMBER_CLOSE_TEARS = true, CHAMBER_STAY_ACTIVE = true,
    CHAMBER_EXIT = true,
}
M.RIFT_STATES = RIFT_STATES

local CHEST_SCAN_STATES = {
    RIFT_KILL_GUARDS = true, RIFT_WAIT_OPEN = true, RIFT_CLOSE_TEARS = true,
    RIFT_STAY_ACTIVE = true, RIFT_WAIT_REALMWALKER = true, RIFT_KILL_REALMWALKER = true,
    CHAMBER_CLOSE_TEARS = true, CHAMBER_STAY_ACTIVE = true,
}

-- States from which a rupture may pre-empt the current work (Farm mode).
local POLL_STATES = {
    KILL_MONSTERS = true, FARM_CHEST_CINDERS = true, MOVING_TO_REMEMBERED_CHEST = true,
}

-- ── safe host access ───────────────────────────────────────────────────────
local function now() return get_time_since_inject() end

local function mcall(obj, method)
    if obj == nil then return nil end
    local ok, v = pcall(function() return obj[method](obj) end)
    if ok then return v end
    return nil
end

local function actor_skin(actor)
    local s = mcall(actor, "get_skin_name")
    if type(s) == "string" and s ~= "" then return s end
    return nil
end

local function actor_pos(actor) return mcall(actor, "get_position") end
local function actor_hp(actor)
    local hp = mcall(actor, "get_current_health")
    return type(hp) == "number" and hp or nil
end
local function actor_interactable(actor) return mcall(actor, "is_interactable") == true end

local function dist(target)
    local ok, d = pcall(utils.distance_to, target)
    if ok and type(d) == "number" then return d end
    return math.huge
end

local function pos_dist(a, b)
    if not a or not b then return math.huge end
    local ok, d = pcall(function() return a:dist_to(b) end)
    if ok and type(d) == "number" then return d end
    return math.huge
end

local function actor_attr(actor, key)
    if actor == nil then return nil end
    local ok, v = pcall(function() return actor:get_attribute(attributes[key]) end)
    if ok then return v end
    return nil
end

local function log(msg) console.print(msg) end

local function interact(actor)
    local fn = rawget(_G, "interact_object")
    if type(fn) == "function" then pcall(fn, actor) end
end

local function get_actors()
    local fn = helpers.get_actors
    if fn then
        local ok, list = pcall(fn)
        if ok and type(list) == "table" then return list end
        return {}
    end
    local am = rawget(_G, "actors_manager")
    local ok, list = pcall(function() return am:get_all_actors() end)
    return (ok and type(list) == "table") and list or {}
end

local function near_enemies(radius)
    local ts = rawget(_G, "target_selector")
    local ok, list = pcall(function()
        return ts.get_near_target_list(get_player_position(), radius)
    end)
    return (ok and type(list) == "table") and list or {}
end

-- helltide get_kill_target (reads target_selector unprotected).
local function kill_target()
    if not helpers.get_kill_target then return nil end
    local ok, t = pcall(helpers.get_kill_target)
    return ok and t or nil
end

local function move_to(target, close)
    if helpers.move_to then helpers.move_to(target, close) end
end

local function clear_movement()
    if helpers.clear_movement then helpers.clear_movement() end
end

-- Rupture combat: keep the orbwalker clearing even above the cinder gate.
local function combat_on()
    if settings.force_orb_clear_for then pcall(settings.force_orb_clear_for, 2) end
end

local function cinders()
    local ok, c = pcall(get_helltide_coin_cinders)
    return (ok and type(c) == "number") and c or 0
end

-- ── skin classification ────────────────────────────────────────────────────
local function skin_matches(skin, patterns)
    if type(skin) ~= "string" or not patterns then return false end
    for _, pat in ipairs(patterns) do
        if skin:match(pat) then return true end
    end
    return false
end

local function is_rupture_marker_skin(skin)
    if type(skin) ~= "string" or skin == "" or skin_matches(skin, skins.reject) then
        return false
    end
    for _, pref in ipairs(skins.rupture_prefixes) do
        if skin:sub(1, #pref) == pref then return true end
    end
    return false
end
M.is_rupture_marker_skin = is_rupture_marker_skin

-- QQT_Warpigz_v3 3.3.3 (audit): a rupture switch that can still be used
-- (the event has not started). Boundary gizmos in skins.starter are not.
local function startable(actor, skin)
    skin = skin or actor_skin(actor)
    return type(skin) == "string" and (skin:find("SwitchGizmo", 1, true) or skin:find("_LE_Gizmo", 1, true)) ~= nil
        and actor_interactable(actor)
end

local function rupture_type_label(skin)
    if not skin then return "Unknown" end
    for _, entry in ipairs(skins.type_by_skin) do
        if skin_matches(skin, entry.patterns) then return entry.label end
    end
    return "Unknown"
end
M.rupture_type_label = rupture_type_label

local function type_allowed(label)
    if label == "Surging" then return settings.rupture_hunt_surging ~= false end
    if label == "Colossal" then return settings.rupture_hunt_colossal ~= false end
    if label == "Normal" then return settings.rupture_hunt_normal ~= false end
    return false
end

local function in_deathtoll_chamber()
    local ok, z = pcall(function() return get_current_world():get_current_zone_name() end)
    if not ok or type(z) ~= "string" then return false end
    for _, frag in ipairs(skins.chamber_zones) do
        if z:find(frag, 1, true) then return true end
    end
    return false
end
M.in_deathtoll_chamber = in_deathtoll_chamber

local function realmwalker_chain(s)
    return settings.rupture_do_realmwalker == true
        and (s.rupture_type == "Surging" or s.rupture_type == "Colossal")
end

local function chamber_wanted(s)
    return settings.rupture_do_deathtoll_chamber == true and realmwalker_chain(s)
end

-- ── area blacklist ─────────────────────────────────────────────────────────
local function is_blacklisted(pos)
    if not pos then return false end
    local t = now()
    for i = #area_blacklist, 1, -1 do
        local e = area_blacklist[i]
        -- QQT_Warpigz_v3 3.3.2: kept as a spent site after the blacklist TTL.
        if t >= (e.spent_until or e.until_t) then
            table.remove(area_blacklist, i)
        elseif t < e.until_t and pos_dist(e.pos, pos) <= C.BLACKLIST_RADIUS then
            return true
        end
    end
    return false
end
M.is_blacklisted = is_blacklisted

-- QQT_Warpigz_v3 3.3.2: a site this machine already finished or abandoned.
-- Its leftover gizmos (ring, boundary, starter) are re-engaged only with
-- strong live evidence (the blacklist TTL alone re-armed the same spent
-- rupture every 120 s).
local function is_spent(pos)
    if not pos then return false end
    local t = now()
    for _, e in ipairs(area_blacklist) do
        if t < (e.spent_until or e.until_t) and pos_dist(e.pos, pos) <= C.BLACKLIST_RADIUS then
            return true
        end
    end
    return false
end
M.is_spent = is_spent

local function blacklist_area(pos, skin, secs, why)
    if not pos then return end
    secs = secs or C.BLACKLIST_TTL
    area_blacklist[#area_blacklist + 1] = { pos = pos, until_t = now() + secs, skin = skin,
        spent_until = now() + math.max(secs, C.SPENT_TTL) } -- QQT_Warpigz_v3 3.3.2
    local ok, x, y = pcall(function() return pos:x(), pos:y() end)
    log(string.format("[RIFT] Skipping rupture area (%s) at (%.0f,%.0f) for %ds — %s",
        tostring(skin or "?"), ok and x or 0, ok and y or 0, secs, why or "done"))
end

-- ── session ────────────────────────────────────────────────────────────────
local function resume_patrol(self, states, msg, abandoned, secs)
    local s = sess
    if s.anchor then
        blacklist_area(s.anchor, actor_skin(s.starter), secs or C.BLACKLIST_TTL,
            abandoned and "abandoned" or "completed")
    end
    if s.chamber_anchor and s.chamber_anchor ~= s.anchor then
        blacklist_area(s.chamber_anchor, "chamber", C.BLACKLIST_TTL, "chamber done")
    end
    if msg then log(msg) end
    clear_movement()
    self.current_state = states.EXPLORE_HELLTIDE
    sess = {}
    stand.sync_pause(false, now(), "rupture left") -- QQT_Warpigz_v3 (Q2)
end

-- ── scans ──────────────────────────────────────────────────────────────────
local function find_closest_actor(patterns, max_dist, predicate)
    local best, best_d = nil, math.huge
    for _, actor in pairs(get_actors()) do
        local skin = actor_skin(actor)
        if skin_matches(skin, patterns) and (not predicate or predicate(actor, skin)) then
            local d = dist(actor)
            if d <= max_dist and d < best_d then best, best_d = actor, d end
        end
    end
    if best and settings.log_tear_candidates then
        log(string.format("[RIFT] candidate %s dist=%.1f", actor_skin(best) or "?", best_d))
    end
    return best, best_d
end

-- QQT_Warpigz_v3 3.3.2: a remembered actor still in the actor list (a
-- stale handle can keep reporting its last position after it despawned).
local function listed(target)
    if target == nil then return false end
    -- QQT_Warpigz_v3 3.3.3 (audit): by id too (the host may hand out a new
    -- wrapper for the same actor on each call).
    local id = mcall(target, "get_id")
    for _, actor in pairs(get_actors()) do
        if actor == target or (type(id) == "number" and mcall(actor, "get_id") == id) then return true end
    end
    return false
end

local function find_closest_interactable(patterns, max_dist)
    return find_closest_actor(patterns, max_dist, actor_interactable)
end

local function find_best_starter(max_dist, skip_blacklisted)
    local best, best_d, best_rank = nil, math.huge, -1
    for _, actor in pairs(get_actors()) do
        local skin = actor_skin(actor)
        if skin_matches(skin, skins.starter) and is_rupture_marker_skin(skin) then
            local label = rupture_type_label(skin)
            local d = dist(actor)
            -- QQT_Warpigz_v3 3.3.2: a spent site's starter needs strong live evidence.
            local apos = skip_blacklisted and actor_pos(actor)
            if type_allowed(label) and d <= max_dist
                and not (skip_blacklisted and (is_blacklisted(apos)
                    or (is_spent(apos) and not live_evidence(apos, true, true)
                        and not startable(actor, skin)))) then
                local rank = TYPE_RANK[label] or 0
                if settings.rupture_prioritize_surging ~= false then
                    if rank > best_rank or (rank == best_rank and d < best_d) then
                        best, best_d, best_rank = actor, d, rank
                    end
                elseif d < best_d then
                    best, best_d, best_rank = actor, d, rank
                end
            end
        end
    end
    return best, best_d
end

-- Type of the closest rupture starter within radius of pos (any type, the
-- per-type toggles are applied by the caller), else "Unknown".
local function starter_label_near(pos, radius)
    if not pos then return "Unknown" end
    local best, best_d = nil, math.huge
    for _, actor in pairs(get_actors()) do
        local skin = actor_skin(actor)
        -- QQT_Warpigz_v3 3.3.2: a boundary gizmo (no type) never masks the real starter.
        if skin_matches(skin, skins.starter) and is_rupture_marker_skin(skin)
            and rupture_type_label(skin) ~= "Unknown" then
            local d = pos_dist(pos, actor_pos(actor))
            if d <= radius and d < best_d then best, best_d = skin, d end
        end
    end
    return best and rupture_type_label(best) or "Unknown"
end

-- A rupture engaged from its ring alone gets its type from the starter skin
-- once one is visible (Realmwalker chain only for a confirmed type).
local function refine_type(s, r)
    if s.rupture_type ~= "Unknown" or not s.anchor then return end
    local t = now()
    if s.refine_t and t - s.refine_t < 1 then return end
    s.refine_t = t
    local label = starter_label_near(s.anchor, r + 50)
    if label ~= "Unknown" then
        s.rupture_type = label
        log(string.format("[RIFT] Rupture type confirmed: %s", label))
    end
end

-- tears ---------------------------------------------------------------------
local function tear_key(actor, skin)
    -- QQT_Warpigz_v3 (Q2): the actor id keeps one key for a moving tear
    -- (focus, skip and stand bounds); the position key is the fallback.
    local id = mcall(actor, "get_id")
    if type(id) == "number" then return string.format("%s#%d", skin or "tear", id) end
    local pos = actor_pos(actor)
    if not pos then return skin or "tear" end
    return string.format("%s_%d_%d", skin or "tear", math.floor(pos:x()), math.floor(pos:y()))
end

local function tear_is_skipped(actor, skin)
    local key = tear_key(actor, skin)
    -- QQT_Warpigz_v3 3.3.2: a tear stood in without closing stays spent
    -- across sessions (a new session re-engaged it at once, another 90 s).
    local spent = spent_tears[key]
    if spent then
        if now() < spent then return true end
        spent_tears[key] = nil
    end
    local t = sess.tear_skip and sess.tear_skip[key]
    return t ~= nil and now() - t < C.TEAR_SKIP_TTL_S
end

local function skip_tear(actor, skin, reason)
    sess.tear_skip = sess.tear_skip or {}
    sess.tear_skip[tear_key(actor, skin)] = now()
    if reason then log(string.format("[RIFT] Skipping tear %s — %s", skin or "?", reason)) end
end

-- QQT_Warpigz_v3 (Q2): the 0-1 / 0-100 scale is inferred (hr_tear_stand
-- charge_full); ">= 0.99" closed every tear at 1 % on a 0-100 scale.
local function charge_open(progress, actor, skin)
    if type(progress) ~= "number" then return true end
    local key = progress >= 0.99 and progress <= 1.001 and actor and tear_key(actor, skin) or nil
    return not stand.charge_full(progress, now(), key)
end

local function is_chargeable(skin) return skin_matches(skin, skins.chargeable) end

-- QQT_Warpigz_v3 (Q2): a tear only charges while the player stands in it,
-- so "position and charge unchanged for 12 s" skipped every tear the bot was
-- not standing in (and the one it stood in when the charge read nil). The
-- no-progress check now runs on the engaged tear only, on inside-the-circle
-- time (core/hr_tear_stand.lua); a tear is not viable only while skipped.
local function tear_motion_viable(actor, skin)
    return not tear_is_skipped(actor, skin)
end

-- Charge progress and health (hr_tear_stand.signal).
local function tear_signal(actor)
    return stand.signal(actor_attr(actor, "CHARGEABLE_GIZMO_PROGRESS"), actor_hp(actor))
end

local function is_stand_on_tear(tear, skin)
    if skin and skin:match("Chargeable") then
        return dist(tear) <= C.TEAR_STAND_MAX + 0.35
    end
    local hp = actor_hp(tear)
    return hp ~= nil and hp <= 1
end

local function is_active_tear(actor, skin)
    if not skin_matches(skin, skins.tears) or tear_is_skipped(actor, skin) then return false end
    local operated = actor_attr(actor, "GIZMO_HAS_BEEN_OPERATED")
    if operated == 1 or operated == true then return false end
    local progress = actor_attr(actor, "CHARGEABLE_GIZMO_PROGRESS")
    if skin:match("Chargeable") then return charge_open(progress, actor, skin) end
    local hp = actor_hp(actor)
    if skin:match("MicroRupture") then
        if hp and hp > 1 then return true end
        if progress ~= nil then return charge_open(progress, actor, skin) end
        return false
    end
    return not (hp and hp <= 1)
end

local function find_best_tear(anchor, radius)
    local best, best_score = nil, -math.huge
    for _, actor in pairs(get_actors()) do
        local skin = actor_skin(actor)
        if is_active_tear(actor, skin) and tear_motion_viable(actor, skin) then
            local ap = actor_pos(actor)
            if ap and (not anchor or pos_dist(anchor, ap) <= radius) then
                local score = -dist(actor)
                local hp = actor_hp(actor) or 0
                if settings.tear_use_charge_ring ~= false and is_chargeable(skin)
                    and is_stand_on_tear(actor, skin) then
                    score = score + 8000
                elseif hp > 1 then
                    score = score + 10000
                elseif is_stand_on_tear(actor, skin) then
                    score = score - 2500
                end
                if score > best_score then best, best_score = actor, score end
            end
        end
    end
    return best
end

local function ritual_context_near(pos, radius)
    for _, actor in pairs(get_actors()) do
        local skin = actor_skin(actor)
        if skin_matches(skin, skins.hold_area) or skin_matches(skin, skins.starter) then
            if pos_dist(pos, actor_pos(actor)) <= radius then return true end
        end
    end
    return false
end

-- guards / bosses -----------------------------------------------------------
-- Living cultists within radius of anchor, and their total health.
local function guards_near(anchor, radius)
    local count, total = 0, 0
    for _, actor in pairs(get_actors()) do
        if skin_matches(actor_skin(actor), skins.guards) then
            local hp = actor_hp(actor) or 0
            if hp > 1 and pos_dist(anchor, actor_pos(actor)) <= radius then
                count, total = count + 1, total + hp
            end
        end
    end
    return count, total
end

-- QQT_Warpigz_v3 3.3.3: true once RIFT_KILL_GUARDS made no progress for
-- GUARD_STALL_S (no cultist lost health, the targeted one got no closer).
local function guards_stalled(s, r, guard)
    local t = now()
    local _, total = guards_near(s.anchor, r + 8)
    local d = guard and dist(guard) or nil
    if not s.guard_t or total < (s.guard_hp or total) - 0.5
        or (d and d < (s.guard_d or math.huge) - C.GUARD_PROGRESS_M) then
        s.guard_hp, s.guard_d, s.guard_t = total, d, t
        return false
    end
    s.guard_hp = math.min(s.guard_hp or total, total)
    return t - s.guard_t >= C.GUARD_STALL_S
end

local function find_enemy(patterns, max_dist, anchor, anchor_radius)
    local best, best_d = nil, math.huge
    for _, enemy in pairs(near_enemies(max_dist)) do
        if skin_matches(actor_skin(enemy), patterns) and (actor_hp(enemy) or 0) > 1
            and (not anchor or pos_dist(anchor, actor_pos(enemy)) <= anchor_radius) then
            local d = dist(enemy)
            if d < best_d then best, best_d = enemy, d end
        end
    end
    return best
end

local function find_realmwalker(max_dist)
    return find_enemy(skins.realmwalker_boss, max_dist)
        or find_closest_actor(skins.realmwalker_boss, max_dist, function(a)
            return (actor_hp(a) or 100) > 1
        end)
end

-- QQT_Warpigz_v3 3.3.2: what proves a rupture is running at `anchor`.
-- 'tear' (an open tear within the tear reach), 'cultists', 'Realmwalker'
-- (alive) are strong; 'marker' (an active-event marker or wave proxy) only
-- counts when strong_only is not set. nil: nothing live there - a leftover
-- ring, boundary, starter, closed tear, chest or goblin is not a rupture.
-- QQT_Warpigz_v3 3.3.3 (audit): an interactable starter within r + 15 is
-- weak evidence ('starter', like 'marker': an un-started rupture is not
-- judged dead in 6 s, but it never keeps the site alive past the quiet cap).
-- no_rw: a living Realmwalker does not count (a finished Surging site whose
-- Realmwalker lives on was re-armed and completed again every 120 s).
live_evidence = function(anchor, strong_only, no_rw)
    if not anchor then return nil end
    local r = settings.tear_event_radius or 12
    local marker = nil
    for _, actor in pairs(get_actors()) do
        local skin = actor_skin(actor)
        if skin then
            local kind
            if skin_matches(skin, skins.tears) then
                if is_active_tear(actor, skin) then kind = "tear" end
            elseif skin_matches(skin, skins.guards) then
                if (actor_hp(actor) or 0) > 1 then kind = "cultists" end
            elseif skin_matches(skin, skins.realmwalker_boss) then
                if not no_rw and (actor_hp(actor) or 100) > 1 then kind = "Realmwalker" end
            elseif not strong_only and not marker and skin_matches(skin, skins.live_markers) then
                if pos_dist(anchor, actor_pos(actor)) <= r + 15 then marker = "marker" end
            elseif not strong_only and not marker and startable(actor, skin)
                and pos_dist(anchor, actor_pos(actor)) <= r + 15 then
                marker = "starter"
            end
            if kind then
                local reach = (kind == "tear" and r + 30) or (kind == "cultists" and r + 15) or r + 70
                if pos_dist(anchor, actor_pos(actor)) <= reach then return kind end
            end
        end
    end
    return marker
end
M.live_evidence = live_evidence

-- chamber portal ------------------------------------------------------------
local function find_chamber_portal(max_dist, anchor)
    local best_click, bc_d, best_marker, bm_d = nil, math.huge, nil, math.huge
    for _, actor in pairs(get_actors()) do
        local skin = actor_skin(actor)
        if skin_matches(skin, skins.chamber_entrance) then
            local pos = actor_pos(actor)
            local d = dist(actor)
            if pos and d <= max_dist and (not anchor or pos_dist(pos, anchor) <= max_dist) then
                if actor_interactable(actor) and d < bc_d then
                    best_click, bc_d = actor, d
                elseif skin:find("PortalUIMarker", 1, true) and d < bm_d then
                    best_marker, bm_d = actor, d
                end
            end
        end
    end
    return best_click or best_marker
end

local function clickable_portal(portal)
    if actor_interactable(portal) then return portal end
    local ppos = actor_pos(portal)
    if not ppos then return portal end
    for _, actor in pairs(get_actors()) do
        local skin = actor_skin(actor)
        if skin and skin:find("RuptureEntrance_Portal", 1, true) and actor_interactable(actor)
            and pos_dist(actor_pos(actor), ppos) < 4 then
            return actor
        end
    end
    return portal
end

local function route_to_chamber_portal(self, states, anchor, search)
    if settings.rupture_do_deathtoll_chamber ~= true then return false end
    local portal = find_chamber_portal(search, anchor)
    if not portal then return false end
    log(string.format("[RIFT] Deathtoll Chamber portal found (%s, dist=%.1f) — entering",
        actor_skin(portal) or "?", dist(portal)))
    self.current_state = states.RIFT_ENTER_CHAMBER
    return true
end

-- rupture chests --------------------------------------------------------------
local function is_pandemonium_chest(skin) return type(skin) == "string" and skin:match("PandemoniumChest") ~= nil end

local function chest_label(skin)
    if is_pandemonium_chest(skin) then return skin end
    for name in pairs(enums.chest_types) do
        if skin:match(name) then return name end
    end
    return skin
end

local function can_open_event_chest(skin)
    if not skin_matches(skin, skins.event_chests) then return false end
    if is_pandemonium_chest(skin) then return true end
    local c = cinders()
    for name, cost in pairs(enums.chest_types) do
        -- QQT_Warpigz_v3 (rc.2, Q4 x Q2/Q3): a cinder chest in the ring obeys
        -- the cinder run's save phase like every other chest gate (option off:
        -- allowed as before); Pandemonium chests above cost nothing.
        if skin:match(name) and c >= cost then return cinder_run.allows(name) end
    end
    return false
end

local function chest_key(name, pos)
    return string.format("%s_%d_%d", name, math.floor(pos:x()), math.floor(pos:y()))
end

local function find_rift_chest(anchor, radius)
    if not settings.helltide_chest or settings.rupture_open_chests == false or not anchor then
        return nil
    end
    local t = now()
    if sess.last_chest_scan_t and t - sess.last_chest_scan_t < C.CHEST_SCAN_TTL then return nil end
    sess.last_chest_scan_t = t
    local skip = sess.chest_skip or {}
    local best, best_name, best_d = nil, nil, math.huge
    for _, actor in pairs(get_actors()) do
        local skin = actor_skin(actor)
        if can_open_event_chest(skin) and actor_interactable(actor) then
            local ap = actor_pos(actor)
            if ap and pos_dist(anchor, ap) <= radius then
                local name = chest_label(skin)
                local until_t = skip[chest_key(name, ap)]
                local d = dist(ap)
                if not (until_t and until_t > t) and d < best_d then
                    best, best_name, best_d = actor, name, d
                end
            end
        end
    end
    return best, best_name
end

local function find_rift_chest_actor(name, pos)
    local best, best_d = nil, math.huge
    for _, actor in pairs(get_actors()) do
        local skin = actor_skin(actor)
        if skin and (skin == name or skin:match(name) or chest_label(skin) == name) then
            local ap = actor_pos(actor)
            if ap and pos_dist(ap, pos) <= 10 then
                -- QQT_Warpigz_v3 2.6.4 (sweep H3): the chest AT the spotted
                -- position (ranked by the player's distance, a second chest
                -- within 10 m resolved to the opened one the player stood at:
                -- a spot / "opened" loop until the 300 s cap). An opened one
                -- only when no closed one is there.
                local d = pos_dist(ap, pos) + (actor_interactable(actor) and 0 or 20)
                if d < best_d then best, best_d = actor, d end
            end
        end
    end
    return best
end

local function try_interrupt_for_chest(self, states, anchor, radius)
    local chest, name = find_rift_chest(anchor, radius)
    local pos = chest and actor_pos(chest)
    if not pos then return false end
    sess.resume_state = self.current_state
    sess.chest_name, sess.chest_pos = name, pos
    sess.chest_pre_cinders, sess.chest_interact_t, sess.chest_loot_started = nil, nil, nil
    sess.chest_tries, sess.chest_best_d, sess.chest_best_t = nil, nil, nil
    log(string.format("[RIFT] %s spotted (dist=%.1f) — opening before the rupture closes",
        is_pandemonium_chest(name) and "Pandemonium chest" or ("Event chest " .. name), dist(pos)))
    self.current_state = states.RIFT_OPEN_CHEST
    return true
end

local function resume_after_chest(self, states)
    local resume = sess.resume_state or states.RIFT_STAY_ACTIVE
    sess.resume_state, sess.chest_name, sess.chest_pos = nil, nil, nil
    sess.chest_pre_cinders, sess.chest_interact_t, sess.chest_loot_started = nil, nil, nil
    -- Per-chest counters: the next chest starts with its own tries/watchdog.
    sess.chest_tries, sess.chest_best_d, sess.chest_best_t = nil, nil, nil
    sess.last_chest_scan_t = nil
    -- Tears were not observed during the detour: restart the static-tear
    -- check instead of counting the detour as "did not move".
    sess.tear_motion = nil
    self.current_state = resume
end

-- ── engage ─────────────────────────────────────────────────────────────────
local function engage(self, states, pos, rtype, msg, starter)
    if not pos or is_blacklisted(pos) then return false end
    if starter and not is_rupture_marker_skin(actor_skin(starter)) then
        blacklist_area(pos, actor_skin(starter), C.BLACKLIST_TTL, "not a rupture marker")
        return false
    end
    local from_rift = RIFT_STATES[self.current_state]
    if not from_rift then
        -- A fresh rupture: HR may have left the previous one without
        -- resume_patrol/on_reset (salvage trip -> return_from_salvage, walk
        -- back from outside the zone, ...). Never inherit its start time,
        -- chest/tear skips or leash (the area blacklist lives outside sess).
        clear_movement()
        sess = { poll_t = sess.poll_t, block_log_t = sess.block_log_t }
    end
    leash.reset(sess)
    sess.anchor, sess.starter = pos, starter
    sess.rupture_type = rtype or sess.rupture_type or "Unknown"
    sess.started_at = (from_rift and sess.started_at) or now()
    sess.wait_started, sess.no_tear_since = nil, nil
    sess.move_best, sess.move_best_t = nil, nil
    log(msg or string.format("[RIFT] %s rupture at dist=%.1f — engaging", sess.rupture_type, dist(pos)))
    local r = settings.tear_event_radius or 12
    if find_best_tear(pos, r + 30) then
        self.current_state = states.RIFT_CLOSE_TEARS
    elseif dist(pos) <= r + 8 then
        self.current_state = guards_near(pos, r + 8) > 0 and states.RIFT_KILL_GUARDS
            or states.RIFT_STAY_ACTIVE
    else
        self.current_state = states.MOVING_TO_RIFT
    end
    return true
end

-- Scan for ritual ring / starter / active tear within max_dist.
-- require_ritual_for_tear: a distant bare tear needs a live ritual nearby.
local function scan(self, states, max_dist, require_ritual_for_tear)
    local r = settings.tear_event_radius or 12
    local hold = find_closest_actor(skins.hold_area, max_dist, function(a, skin)
        -- QQT_Warpigz_v3 3.3.2: a ring left over from a rupture this machine
        -- already finished is engaged again only with strong live evidence.
        local ap = actor_pos(a)
        return is_rupture_marker_skin(skin) and not is_blacklisted(ap)
            and not (is_spent(ap) and not live_evidence(ap, true, true)
                and live_evidence(ap) ~= "starter")
    end)
    if hold then
        -- Without a visible starter the type is unknown (never assume
        -- Surging: that would start a Realmwalker wait for a Normal rupture
        -- and bypass the per-type toggles). refine_type() labels it once the
        -- starter shows up.
        local rtype = starter_label_near(actor_pos(hold), r + 50)
        local allowed
        if rtype ~= "Unknown" then
            allowed = type_allowed(rtype)
        else
            allowed = type_allowed("Normal") or type_allowed("Surging") or type_allowed("Colossal")
        end
        if allowed and engage(self, states, actor_pos(hold), rtype,
            string.format("[RIFT] Found ritual ring at dist=%.1f — engaging %s rupture", dist(hold), rtype)) then
            return true
        end
    end
    local starter = find_best_starter(max_dist, true)
    if starter then
        local skin = actor_skin(starter)
        local rtype = rupture_type_label(skin)
        if engage(self, states, actor_pos(starter), rtype,
            string.format("[RIFT] Found %s rupture %s at dist=%.1f — routing (cultists → tears)",
                rtype, skin or "?", dist(starter)), starter) then
            return true
        end
    end
    local tear = find_best_tear(get_player_position(), max_dist)
    local tpos = tear and actor_pos(tear)
    if tpos and not is_blacklisted(tpos)
        and (not require_ritual_for_tear or ritual_context_near(tpos, C.RITUAL_CONTEXT_DIST)) then
        local rtype = rupture_type_label(actor_skin(tear))
        if rtype == "Unknown" then rtype = "Normal" end
        if type_allowed(rtype) and engage(self, states, tpos, rtype,
            string.format("[RIFT] Found active tear %s at dist=%.1f — closing",
                actor_skin(tear) or "?", dist(tear))) then
            return true
        end
    end
    return false
end

-- ── tear closing ───────────────────────────────────────────────────────────
-- QQT_Warpigz_v3 (Q2): the engaged tear is kept until it closes, is gone or
-- is skipped (it was re-picked by distance every tick and dropped after 18 s).
local function focused_tear()
    local key = sess.tear_focus_key
    if not key then return nil end
    for _, actor in pairs(get_actors()) do
        local skin = actor_skin(actor)
        if skin_matches(skin, skins.tears) and tear_key(actor, skin) == key and is_active_tear(actor, skin) then
            return actor
        end
    end
    return nil
end

local function release_focus()
    sess.focus_tear, sess.tear_focus_key, sess.tear_focus_since, sess.tear_standing = nil, nil, nil, nil
end

local function close_tears_at(self, states, anchor, r, pad)
    local tear = focused_tear()
    if not tear and sess.tear_focus_key then
        -- QQT_Warpigz_v3 (Q2): the engaged tear closed (or left the actor list).
        sess.tears_closed = (sess.tears_closed or 0) + 1
        log(string.format("[RIFT] Tear closed after %.0fs in its circle (%d this rupture)",
            stand.inside_seconds(sess, sess.tear_focus_key), sess.tears_closed))
        release_focus()
    end
    tear = tear or find_best_tear(anchor, r + (pad or 30))
    if not tear then
        release_focus()
        return false
    end
    local skin = actor_skin(tear)
    local key = tear_key(tear, skin)
    local t = now()
    if sess.tear_focus_key ~= key then
        sess.tear_focus_key, sess.tear_focus_since, sess.tear_standing = key, t, nil
        -- The raw charge/health once per tear: the live log shows the scale.
        log(string.format("[RIFT] Engaging tear %s (dist=%.1f, charge=%s, hp=%s) — standing in it until it closes",
            skin or "?", dist(tear), tostring(actor_attr(tear, "CHARGEABLE_GIZMO_PROGRESS")), tostring(actor_hp(tear))))
        if settings.log_tear_candidates then
            -- Live check: the CHARGEABLE_GIZMO_PROGRESS scale (0-1 or 0-100)
            -- is unverified; charge_open() accepts both until it is known.
            log(string.format("[RIFT] tear focus %s hp=%s progress(raw)=%s", skin or "?",
                tostring(actor_hp(tear)), tostring(actor_attr(tear, "CHARGEABLE_GIZMO_PROGRESS"))))
        end
    end
    local d = dist(tear)
    local charge = settings.tear_use_charge_ring ~= false and is_chargeable(skin)
    -- Bounded per tear (C6): inside-the-circle time, approach and wall time.
    local why = stand.work(sess, key, d, tear_signal(tear), t, charge and stand.C.STAND_OUT or C.TEAR_ATTACK_DIST)
    if why then
        skip_tear(tear, skin, why)
        -- QQT_Warpigz_v3 3.3.2: stood in it this long and it never closed:
        -- a spent (or leftover) tear, never re-engaged by the next session.
        if stand.inside_seconds(sess, key) >= C.SPENT_TEAR_INSIDE_S then
            spent_tears[key] = t + C.SPENT_TTL
        elseif stand.inside_seconds(sess, key) <= 0 then
            -- QQT_Warpigz_v3 3.3.3: never reached its circle: not live
            -- evidence for this site (it re-armed the site every 120 s), and
            -- a rupture whose tears were all out of reach is not completed.
            spent_tears[key] = t + C.UNREACHABLE_S
            sess.tear_unreached = true
        end
        release_focus()
        return false
    end
    sess.focus_tear, sess.tears_seen = tear, true -- QQT_Warpigz_v3 3.3.2: tears_seen
    combat_on()
    if charge then
        -- Stop on the glint, walk back only when pushed out of the circle
        -- (hysteresis: no re-centering on every sub-metre drift).
        if d <= stand.C.STAND_IN or (sess.tear_standing and d <= stand.C.STAND_OUT) then
            sess.tear_standing = true
            clear_movement()
        else
            sess.tear_standing = nil
            move_to(tear, d <= stand.C.STAND_IN + 3)
        end
    elseif d <= C.TEAR_ATTACK_DIST then
        clear_movement()
    else
        move_to(tear, true)
    end
    return true
end

-- QQT_Warpigz_v3 (Q3): once the event is over, walk to the drops Rosie
-- wants in the event area before leaving (core/hr_tear_loot.lua; bounded).
local loot_ctx = {
    move_to = function(pos, precise) move_to(pos, precise) end,
    clear = function() clear_movement() end,
}
local function collect_loot(s, r, why)
    loot_ctx.anchor, loot_ctx.radius, loot_ctx.rw_pos = s.anchor, r + loot.C.AREA_PAD, s.rw_anchor
    return loot.collect(s, now(), why, loot_ctx)
end

-- ── state handlers (one function per state keeps upvalues low) ─────────────
local H = {}

H.MOVING_TO_RIFT = function(self, states, s, r)
    local starter = find_best_starter(r + 80, false)
    if starter and s.anchor and pos_dist(actor_pos(starter), s.anchor) > r * 2 then
        starter = nil -- a different rupture: keep the one we engaged
    end
    -- QQT_Warpigz_v3 3.3.2: only while the remembered starter is still listed.
    if not starter and s.starter and listed(s.starter) and actor_pos(s.starter) then starter = s.starter end
    local spos = starter and actor_pos(starter)
    if spos then
        s.anchor = spos
        local label = rupture_type_label(actor_skin(starter))
        if label ~= "Unknown" then s.rupture_type = label end
    end
    if not s.anchor then return resume_patrol(self, states, "[RIFT] Rupture anchor lost — resuming patrol") end
    local d = dist(s.anchor)
    if d <= r then
        self.current_state = states.RIFT_KILL_GUARDS
        return
    end
    local t = now()
    if not s.move_best or d < s.move_best - C.APPROACH_PROGRESS_M then
        s.move_best, s.move_best_t = d, t
    elseif t - (s.move_best_t or t) > C.APPROACH_NO_PROGRESS_S then
        return resume_patrol(self, states, string.format(
            "[RIFT] No progress towards rupture for %ds (dist=%.1f) — giving up", C.APPROACH_NO_PROGRESS_S, d), true,
            C.UNREACHABLE_S) -- QQT_Warpigz_v3 3.3.3: its cultists re-armed it every 120 s
    end
    move_to(starter or s.anchor, d <= 6)
end

H.RIFT_KILL_GUARDS = function(self, states, s, r)
    combat_on()
    refine_type(s, r)
    if find_best_tear(s.anchor, r + 25) then
        s.no_tear_since, s.hold_since = nil, nil
        self.current_state = states.RIFT_CLOSE_TEARS
        return
    end
    if settings.tear_use_charge_ring ~= false then
        local hold = find_closest_actor(skins.hold_area, r + 10, function(a)
            return pos_dist(s.anchor, actor_pos(a)) <= r + 10
        end)
        -- Bounded: a ring gizmo that outlives its rupture (or whose tears
        -- were all skipped as static) must not park us until RUPTURE_MAX_S.
        -- After HOLD_AREA_MAX_S the wait/linger/completion states take over.
        local t = now()
        if hold then s.hold_since = s.hold_since or t end
        if hold and t - s.hold_since < C.HOLD_AREA_MAX_S then
            move_to(hold, dist(hold) <= 6)
            return
        end
        if hold and not s.hold_expired_logged then
            s.hold_expired_logged = true
            log(string.format("[RIFT] No tear at the ritual ring for %ds — moving on", C.HOLD_AREA_MAX_S))
        end
    end
    if guards_near(s.anchor, r + 8) > 0 then
        local guard = find_enemy(skins.guards, r + 35, s.anchor, r + 15)
        if guard then move_to(guard, dist(guard) <= 8) end
        -- QQT_Warpigz_v3 3.3.3 (live: "standing around"): a cultist that
        -- cannot be targeted or reached parked the bot here until the 300 s
        -- rupture cap, then again every 120 s. Progress: a cultist lost
        -- health or the nearest one got closer.
        if guards_stalled(s, r, guard) then
            return resume_patrol(self, states, string.format(
                "[RIFT] Cultists not killed or reached for %ds — leaving this rupture", C.GUARD_STALL_S),
                true, C.UNREACHABLE_S)
        end
        return
    end
    s.guard_hp, s.guard_d, s.guard_t = nil, nil, nil
    s.wait_started = now()
    self.current_state = states.RIFT_WAIT_OPEN
end

H.RIFT_WAIT_OPEN = function(self, states, s, r)
    combat_on()
    local elapsed = now() - (s.wait_started or now())
    if elapsed < C.SPAWN_WAIT_S then return end
    local hold = find_closest_actor(skins.hold_area, r + 5, function(a)
        return pos_dist(s.anchor, actor_pos(a)) <= r + 5
    end)
    local starter = find_closest_actor(skins.starter, r + 10, function(_, skin)
        return is_rupture_marker_skin(skin)
    end)
    if hold or find_best_tear(s.anchor, r + 20) or (starter and actor_interactable(starter)) then
        s.no_tear_since = nil
        self.current_state = states.RIFT_CLOSE_TEARS
        return
    end
    if elapsed > C.SPAWN_WAIT_S + 15 then
        resume_patrol(self, states, "[RIFT] Timed out waiting for the rupture to open — resuming patrol", true)
    end
end

H.RIFT_CLOSE_TEARS = function(self, states, s, r)
    -- QQT_Warpigz_v3 (Q2): same reach as RIFT_STAY_ACTIVE (r + 30); a tear
    -- 25-30 m out bounced between the two states and was never approached.
    if close_tears_at(self, states, s.anchor, r, 30) then return end
    self.current_state = states.RIFT_STAY_ACTIVE
end

H.RIFT_STAY_ACTIVE = function(self, states, s, r)
    combat_on()
    -- QQT_Warpigz_v3 (Q3): the event is over; its loot is collected first.
    if loot.collecting(s) and collect_loot(s, r) then return end
    refine_type(s, r)
    if find_best_tear(s.anchor, r + 30) then
        s.no_tear_since = nil
        self.current_state = states.RIFT_CLOSE_TEARS
        return
    end
    -- QQT_Warpigz_v3 (rc.2 review): a finished loot window never walks back
    -- to the ring first (loot.done below resumes patrol, or reroutes).
    -- QQT_Warpigz_v3 3.3.2: nor once the quiet cap ended the rupture (an
    -- unreachable bubble centre walked us around until RUPTURE_MAX_S).
    if not s.quiet_over and leash.enforce(s, s.anchor, get_actors(), move_to,
        { busy = s.focus_tear ~= nil or kill_target() ~= nil or loot.done(s) }) then
        return
    end
    if not realmwalker_chain(s) then
        local elsewhere = find_best_starter(settings.tear_search_dist or 110, true)
        local epos = elsewhere and actor_pos(elsewhere)
        if epos and pos_dist(epos, s.anchor) > r * 2 then
            local new_type = rupture_type_label(actor_skin(elsewhere))
            if (TYPE_RANK[new_type] or 0) >= (TYPE_RANK[s.rupture_type] or 1) or not s.no_tear_since then
                -- QQT_Warpigz_v3 (Q3): this rupture's loot first; the next
                -- rupture gets its own pause.
                if collect_loot(s, r, "rupture complete") then return end
                loot.reset(s)
                blacklist_area(s.anchor, actor_skin(s.starter), C.BLACKLIST_TTL, "completed")
                s.anchor, s.starter, s.rupture_type = epos, elsewhere, new_type
                s.no_tear_since, s.move_best, s.move_best_t = nil, nil, nil
                -- The new rupture gets its own time cap and its own leash
                -- (the old leash centre would pull us back to the old ring).
                s.started_at, s.hold_since = now(), nil
                -- QQT_Warpigz_v3 3.3.2: the new site proves itself live on its own.
                s.live_seen, s.tears_seen, s.quiet_since, s.quiet_over, s.grace_since = nil, nil, nil, nil, nil
                leash.reset(s)
                log(string.format("[RIFT] New %s rupture elsewhere — rerouting", new_type))
                self.current_state = states.MOVING_TO_RIFT
                return
            end
        end
    end
    s.no_tear_since = s.no_tear_since or now()
    -- QQT_Warpigz_v3 (Q3): loot collected (the player may be away from the
    -- ring now): no walk back and second linger.
    if loot.done(s) then
        return resume_patrol(self, states, string.format("[RIFT] %s rupture complete — resuming patrol",
            s.rupture_type or "Pandemonium"))
    end
    if route_to_chamber_portal(self, states, s.anchor, r + 70) then return end
    -- QQT_Warpigz_v3 3.3.2: this rupture's ring (any ring within r + 10 of
    -- the player could be another, finished one).
    local hold = find_closest_actor(skins.hold_area, r + 10, function(a)
        return pos_dist(s.anchor, actor_pos(a)) <= r + 10
    end)
    local center = (hold and actor_pos(hold)) or s.anchor
    local tol = math.max((settings.tear_circle_radius or 2) + 2, 4)
    if settings.tear_use_charge_ring ~= false then tol = math.max(tol, r * 0.35) end
    if not s.quiet_over and dist(center) > tol then
        s.no_tear_since = nil
        move_to(hold or center, true)
        return
    end
    if s.quiet_over or now() - s.no_tear_since >= (settings.rupture_linger_sec or 5) then
        -- QQT_Warpigz_v3 3.3.2: nothing live was ever seen here: not a
        -- completed rupture (no stats, no Realmwalker wait); M.execute's
        -- grace leaves it.
        if not s.live_seen then
            clear_movement()
            return
        end
        -- QQT_Warpigz_v3 3.3.3: its only tears were out of reach: not a
        -- completed rupture (no stats, no Realmwalker wait).
        if s.live_seen == "starter" then
            -- QQT_Warpigz_v3 3.3.3 (audit): it has not started (nothing but an
            -- interactable starter): wait at the ring for the quiet cap (it
            -- may start), then leave: not completed, not re-armed for a while.
            if not s.quiet_over then
                clear_movement()
                return
            end
            return resume_patrol(self, states, "[RIFT] The rupture never started — leaving it",
                true, C.UNREACHABLE_S)
        end
        if s.tear_unreached and (s.tears_closed or 0) == 0 then
            return resume_patrol(self, states, "[RIFT] The rupture's tears were out of reach — leaving it",
                true, C.UNREACHABLE_S)
        end
        -- QQT_Warpigz_v3: one completed tear event for the stats (main.lua sets the hook).
        if not s.completed_counted and type(M.on_complete) == "function" then
            s.completed_counted = true
            pcall(M.on_complete, s.rupture_type)
        end
        if realmwalker_chain(s) then
            s.rw_wait_started = now()
            -- QQT_Warpigz_v3 (rc.2 review): the chain's own bound (M.execute).
            s.rw_chain_at = s.rw_wait_started
            loot.rw_chain(s, s.rw_wait_started)
            log(string.format("[RIFT] %s rupture complete — waiting for Realmwalker", s.rupture_type))
            self.current_state = states.RIFT_WAIT_REALMWALKER
            return
        end
        -- QQT_Warpigz_v3 (Q3): no Realmwalker chain: the event is over.
        if collect_loot(s, r, "rupture complete") then return end
        resume_patrol(self, states, string.format("[RIFT] %s rupture complete — resuming patrol",
            s.rupture_type or "Pandemonium"))
    end
end

H.RIFT_OPEN_CHEST = function(self, states, s)
    if s.chest_loot_started then
        clear_movement()
        if now() - s.chest_loot_started >= C.CHEST_LOOT_PAUSE then resume_after_chest(self, states) end
        return
    end
    if not s.chest_name or not s.chest_pos then return resume_after_chest(self, states) end
    local chest = find_rift_chest_actor(s.chest_name, s.chest_pos)
    local cur = cinders()
    if s.chest_pre_cinders and cur < s.chest_pre_cinders then
        log(string.format("[RIFT] Event chest %s opened (cinders %d→%d)", s.chest_name, s.chest_pre_cinders, cur))
        s.chest_loot_started = now()
        return
    end
    if chest and s.chest_interact_t and not actor_interactable(chest) then
        log(string.format("[RIFT] Chest %s opened — resuming rupture", s.chest_name))
        s.chest_loot_started = now()
        return
    end
    local cpos = chest and actor_pos(chest)
    if not cpos then
        log("[RIFT] Event chest gone — resuming rupture")
        s.chest_skip = s.chest_skip or {}
        s.chest_skip[chest_key(s.chest_name, s.chest_pos)] = now() + 20
        return resume_after_chest(self, states)
    end
    s.chest_pos = cpos
    local d = dist(cpos)
    if d > C.CHEST_INTERACT_DIST then
        -- Approach watchdog: an unreachable chest (up to r+35 m from the
        -- anchor) must not hold the rupture until RUPTURE_MAX_S.
        local t = now()
        if not s.chest_best_d or d < s.chest_best_d - 1 then
            s.chest_best_d, s.chest_best_t = d, t
        elseif t - (s.chest_best_t or t) > C.CHEST_APPROACH_NO_PROGRESS_S then
            s.chest_skip = s.chest_skip or {}
            s.chest_skip[chest_key(s.chest_name, cpos)] = t + 60
            log(string.format("[RIFT] No progress towards chest %s for %ds (dist=%.1f) — skipping it",
                s.chest_name, C.CHEST_APPROACH_NO_PROGRESS_S, d))
            return resume_after_chest(self, states)
        end
        move_to(chest, d <= 8)
        return
    end
    clear_movement()
    local t = now()
    if not s.chest_interact_t or t - s.chest_interact_t >= C.CHEST_INTERACT_COOLDOWN then
        s.chest_interact_t, s.chest_pre_cinders = t, cur
        s.chest_tries = (s.chest_tries or 0) + 1
        if s.chest_tries > 4 then
            s.chest_skip = s.chest_skip or {}
            s.chest_skip[chest_key(s.chest_name, cpos)] = t + 60
            s.chest_tries = nil
            log("[RIFT] Chest did not open after 4 tries — skipping it")
            return resume_after_chest(self, states)
        end
        log(string.format("[RIFT] Interacting with %s (cinders=%d)", s.chest_name, cur))
        interact(chest)
    end
end

H.RIFT_WAIT_REALMWALKER = function(self, states, s, r)
    combat_on()
    if not realmwalker_chain(s) then return resume_patrol(self, states) end
    local boss = find_realmwalker(r + 70)
    if boss then
        s.rw_anchor = actor_pos(boss)
        loot.interrupt(s) -- QQT_Warpigz_v3 (Q3): a late Realmwalker's fight is gated again
        log("[RIFT] Realmwalker spawned — engaging")
        self.current_state = states.RIFT_KILL_REALMWALKER
        return
    end
    if chamber_wanted(s) and route_to_chamber_portal(self, states, s.anchor, r + 70) then return end
    local waited = now() - (s.rw_wait_started or now())
    local wait_max = settings.rupture_rw_wait_sec or 25
    -- QQT_Warpigz_v3 (Q3): no Realmwalker within RW_ABSENT_S after the
    -- rupture completed: the event is over; collect its loot (the wait for a
    -- late Realmwalker goes on meanwhile).
    local absent = math.min(loot.C.RW_ABSENT_S, wait_max)
    if waited >= absent and collect_loot(s, r, string.format("no Realmwalker within %ds", absent)) then return end
    if waited >= wait_max then
        resume_patrol(self, states, "[RIFT] Realmwalker wait timed out — resuming patrol")
    end
end

H.RIFT_KILL_REALMWALKER = function(self, states, s, r)
    combat_on()
    local boss = find_realmwalker(r + 70)
    if boss then
        sess.focus_tear = boss
        s.rw_anchor = actor_pos(boss) or s.rw_anchor -- QQT_Warpigz_v3 (Q3): its drops land here
        local d = dist(boss)
        if d > 14 then move_to(boss, d <= 8) else clear_movement() end
        return
    end
    sess.focus_tear = nil
    if not s.rw_kill_done_at then
        log("[RIFT] Realmwalker defeated")
        s.rw_kill_done_at = now()
    end
    -- QQT_Warpigz_v3 (Q3): the event is over; its loot first, then the
    -- chamber or the patrol.
    if collect_loot(s, r, "Realmwalker defeated") then return end
    if chamber_wanted(s) and route_to_chamber_portal(self, states, s.anchor, r + 70) then return end
    if not chamber_wanted(s) or now() - s.rw_kill_done_at > C.PORTAL_POST_KILL_WAIT then
        resume_patrol(self, states, "[RIFT] Realmwalker chain done — resuming patrol")
    end
end

H.RIFT_ENTER_CHAMBER = function(self, states, s, r)
    if in_deathtoll_chamber() then
        s.chamber_anchor = get_player_position()
        s.chamber_enter_started = now()
        -- QQT_Warpigz_v3 (rc.2 review): the Realmwalker chain has its own
        -- bound now; the chamber keeps at least CHAMBER_MAX_S - RUPTURE_MAX_S.
        s.started_at = math.max(s.started_at or now(), now() - C.RUPTURE_MAX_S)
        self.current_state = states.CHAMBER_START_RITUAL
        return
    end
    local portal = find_chamber_portal(r + 70, s.anchor)
    if not portal then
        if not s.chamber_enter_started or now() - s.chamber_enter_started > C.PORTAL_ENTER_TIMEOUT then
            resume_patrol(self, states, "[RIFT] Chamber portal gone — resuming patrol", true)
        end
        return
    end
    portal = clickable_portal(portal)
    local d = dist(portal)
    if d > C.PORTAL_INTERACT_DIST then
        move_to(portal, d <= 8)
        return
    end
    clear_movement()
    local t = now()
    s.chamber_enter_started = s.chamber_enter_started or t
    if t - s.chamber_enter_started > C.PORTAL_ENTER_TIMEOUT then
        return resume_patrol(self, states, "[RIFT] Chamber portal interact timed out — resuming patrol", true)
    end
    if not s.chamber_portal_t or t - s.chamber_portal_t >= C.PORTAL_INTERACT_COOLDOWN then
        s.chamber_portal_t = t
        log(string.format("[RIFT] Clicking Deathtoll Chamber portal %s (dist=%.1f)", actor_skin(portal) or "?", d))
        interact(portal)
    end
end

H.CHAMBER_START_RITUAL = function(self, states, s, r)
    if settings.rupture_do_deathtoll_chamber ~= true then return resume_patrol(self, states) end
    s.chamber_anchor = s.chamber_anchor or s.anchor or get_player_position()
    s.chamber_enter_started = s.chamber_enter_started or now()
    local gizmo = find_closest_interactable(skins.chamber_start, 45) or find_closest_actor(skins.chamber_start, 45)
    if gizmo then
        s.chamber_anchor = actor_pos(gizmo) or s.chamber_anchor
        local d = dist(gizmo)
        if d > C.PORTAL_INTERACT_DIST then
            move_to(gizmo, d <= 8)
            return
        end
        if actor_interactable(gizmo) then
            clear_movement()
            local t = now()
            if not s.chamber_start_t or t - s.chamber_start_t >= C.PORTAL_INTERACT_COOLDOWN then
                s.chamber_start_t = t
                log("[RIFT] Clicking Deathtoll Chamber ritual pillar")
                interact(gizmo)
            end
            s.chamber_ritual_started = t
        end
    end
    if s.chamber_ritual_started or in_deathtoll_chamber() or find_best_tear(s.chamber_anchor, r + 35) then
        s.no_tear_since = nil
        self.current_state = states.CHAMBER_CLOSE_TEARS
        return
    end
    if now() - s.chamber_enter_started > 20 then
        resume_patrol(self, states, "[RIFT] Chamber ritual start timed out — resuming patrol")
    end
end

H.CHAMBER_CLOSE_TEARS = function(self, states, s, r)
    combat_on()
    -- QQT_Warpigz_v3 (Q2): same reach as CHAMBER_STAY_ACTIVE (r + 35).
    if close_tears_at(self, states, s.chamber_anchor or s.anchor, r, 35) then return end
    self.current_state = states.CHAMBER_STAY_ACTIVE
end

H.CHAMBER_STAY_ACTIVE = function(self, states, s, r)
    combat_on()
    if find_best_tear(s.chamber_anchor or s.anchor, r + 35) then
        s.no_tear_since = nil
        self.current_state = states.CHAMBER_CLOSE_TEARS
        return
    end
    s.no_tear_since = s.no_tear_since or now()
    if now() - s.no_tear_since < (settings.rupture_chamber_linger_sec or 8) then return end
    if find_closest_interactable(skins.chamber_exit, 55) then
        log("[RIFT] Deathtoll Chamber complete — exiting")
        self.current_state = states.CHAMBER_EXIT
        return
    end
    resume_patrol(self, states, "[RIFT] Chamber linger complete — resuming patrol")
end

H.CHAMBER_EXIT = function(self, states, s)
    local exit_p = find_closest_interactable(skins.chamber_exit, 60)
    if exit_p then
        local d = dist(exit_p)
        if d > C.PORTAL_INTERACT_DIST then
            move_to(exit_p, d <= 8)
            return
        end
        clear_movement()
        local t = now()
        if not s.chamber_exit_t or t - s.chamber_exit_t >= C.PORTAL_INTERACT_COOLDOWN then
            s.chamber_exit_t = t
            log(string.format("[RIFT] Clicking Deathtoll Chamber exit (dist=%.1f)", d))
            interact(exit_p)
        end
        s.chamber_exit_at = s.chamber_exit_at or t
    end
    if not in_deathtoll_chamber() or (s.chamber_exit_at and now() - s.chamber_exit_at > 6) then
        resume_patrol(self, states, "[RIFT] Deathtoll Chamber exited — resuming patrol")
    end
end

-- QQT_Warpigz_v3 3.3.2 (live: "standing around, activity Pandemonium
-- rupture, but there is no rupture"). Every tear-event state needs a live
-- rupture actor (live_evidence):
--   * never seen one at the site (a leftover ring / boundary / starter /
--     chest, or a rupture someone else finished): leave after LIVE_GRACE_S
--     at the site, abandoned (area spent: not re-armed without strong
--     evidence), no completion, no Realmwalker wait;
--   * seen, then quiet (no open tear, cultist or Realmwalker): the rupture
--     completes (linger, Realmwalker chain, loot) at the latest after
--     linger + QUIET_PAD_S once tears were seen, QUIET_OPEN_MAX_S before
--     any tear opened, whatever the walk to the ring centre, the leash or
--     the hold-area / open waits would still do.
-- Returns true when it ended the rupture this tick.
local LIVE_STATES = {
    MOVING_TO_RIFT = true, RIFT_KILL_GUARDS = true, RIFT_WAIT_OPEN = true,
    RIFT_CLOSE_TEARS = true, RIFT_STAY_ACTIVE = true,
}
local function check_live(self, states, s, r, t)
    if not LIVE_STATES[self.current_state] or loot.collecting(s) or loot.done(s) then return false end
    if s.live_t and t >= s.live_t and t - s.live_t < C.LIVE_TTL then return false end
    s.live_t = t
    -- QQT_Warpigz_v3 3.3.3 (audit): the Realmwalker counts only when this
    -- rupture would fight it.
    local ev = s.tear_focus_key and "tear" or live_evidence(s.anchor, false, not realmwalker_chain(s))
    local weak = ev == "marker" or ev == "starter"
    if ev and not weak then
        if not s.live_seen or s.live_seen == "marker" or s.live_seen == "starter" then
            log(string.format("[RIFT] Live rupture confirmed (%s)", ev))
        end
        s.live_seen, s.quiet_since, s.quiet_over, s.grace_since = ev, nil, nil, nil
        if ev == "tear" then s.tears_seen = true end
        return false
    end
    -- QQT_Warpigz_v3 3.3.3 (review): the starter was used and the event
    -- marker appeared: a started rupture (the marker upgrades 'starter';
    -- its quiet cap starts again from here).
    if weak and (not s.live_seen or (s.live_seen == "starter" and ev == "marker")) then
        if s.live_seen == "starter" then s.quiet_since, s.grace_since = nil, nil end
        s.live_seen = ev
        log(ev == "marker" and "[RIFT] Live rupture confirmed (event marker)"
            or "[RIFT] Rupture not started yet (its starter is interactable)")
    end
    -- QQT_Warpigz_v3 3.3.3 (audit): the grace and quiet timers run only at
    -- the site. Away from it (a revive at a checkpoint, a knock-back, the
    -- walk there) its actors are not listed: that is not a dead rupture.
    if dist(s.anchor) > C.LIVE_SCAN_M then
        s.grace_since = nil
        if not s.quiet_over then s.quiet_since = nil end
        return false
    end
    -- An un-started rupture holds off the grace only while its starter is
    -- still there (a starter that despawned proves nothing).
    if not s.live_seen or (s.live_seen == "starter" and ev ~= "starter") then
        s.grace_since = s.grace_since or t
        if t - s.grace_since >= C.LIVE_GRACE_S then
            resume_patrol(self, states, string.format(
                "[RIFT] No live rupture here (no open tear, cultist or Realmwalker for %ds) — leaving",
                C.LIVE_GRACE_S), true)
            return true
        end
        return false
    end
    s.quiet_since = s.quiet_since or t
    local cap = s.tears_seen and ((settings.rupture_linger_sec or 5) + C.QUIET_PAD_S) or C.QUIET_OPEN_MAX_S
    if not s.quiet_over and t - s.quiet_since >= cap then
        s.quiet_over = true
        log(string.format("[RIFT] Rupture quiet for %ds (no open tear, cultist or Realmwalker) — finishing it", cap))
        clear_movement()
        self.current_state = states.RIFT_STAY_ACTIVE
        return true -- QQT_Warpigz_v3 3.3.3 (audit): not the old state's handler this tick
    end
    return false
end

-- ── public API ─────────────────────────────────────────────────────────────
function M.bind(h)
    for k, v in pairs(h or {}) do helpers[k] = v end
end

function M.is_rift_state(state)
    return state ~= nil and RIFT_STATES[state] == true
end

function M.session() return sess end

-- QQT_Warpigz_v3 3.3.2: the dashboard / overlay activity line. It says
-- "Pandemonium rupture" only while a live rupture actor was seen and the
-- site has not gone quiet; every other rupture state names what the bot
-- is actually doing (nil: not a rupture state).
local ACTIVITY = {
    RIFT_OPEN_CHEST = "Opening a rupture chest",
    RIFT_WAIT_REALMWALKER = "Rupture done: waiting for the Realmwalker",
    RIFT_ENTER_CHAMBER = "Entering the Deathtoll Chamber",
    CHAMBER_START_RITUAL = "Deathtoll Chamber", CHAMBER_CLOSE_TEARS = "Deathtoll Chamber",
    CHAMBER_STAY_ACTIVE = "Deathtoll Chamber", CHAMBER_EXIT = "Leaving the Deathtoll Chamber",
}
function M.activity_label(state)
    if not M.is_rift_state(state) then return nil end
    local s = sess
    if loot.collecting(s) then return "Collecting the rupture loot" end
    if ACTIVITY[state] then return ACTIVITY[state] end
    if state == "RIFT_KILL_REALMWALKER" then
        return s.rw_kill_done_at and "Realmwalker down: finishing up" or "Fighting the Realmwalker"
    end
    if not s.live_seen then
        return state == "MOVING_TO_RIFT" and "Walking to a rupture site" or "Checking a rupture site (nothing live yet)"
    end
    if s.live_seen == "starter" then return "Rupture not started yet" end -- QQT_Warpigz_v3 3.3.3
    if s.quiet_since or s.quiet_over then return "Rupture ending: no open tear" end
    if state == "MOVING_TO_RIFT" then return "Walking to a Pandemonium rupture" end
    return "Pandemonium rupture"
end

-- True while a chamber run owns the player outside the helltide zone.
-- Also true right after the chamber portal was clicked: the helltide buff can
-- drop (loading screen) before the zone name reports the chamber, and the
-- "left the helltide zone" walk-back must not steal the run in that gap.
-- Bounded by PORTAL_ENTER_TIMEOUT; RIFT_ENTER_CHAMBER gives up after that.
function M.holds_zone(state)
    if not M.is_rift_state(state) then return false end
    if state == "RIFT_ENTER_CHAMBER" and sess.chamber_portal_t
        and now() - sess.chamber_portal_t <= C.PORTAL_ENTER_TIMEOUT then
        return true
    end
    return sess.chamber_anchor ~= nil and in_deathtoll_chamber()
end

-- Proactive hunt (called from helltide check_events, EXPLORE state).
-- Returns true when the current state is (now) a rupture state.
function M.check_events(self, states)
    if M.is_rift_state(self.current_state) then return true end
    if not hr_mode.is_farm() then return false end
    if settings.rupture_do_deathtoll_chamber == true and in_deathtoll_chamber() then
        -- Not in a rupture state: whatever is left in sess is stale.
        sess = { rupture_type = "Chamber", started_at = now(), chamber_anchor = get_player_position() }
        log("[RIFT] Detected Deathtoll Chamber — running chamber ritual")
        self.current_state = states.CHAMBER_START_RITUAL
        return true
    end
    local ok, why = hr_mode.hunt_ruptures()
    if not ok then
        if settings.log_tear_candidates and (not sess.block_log_t or now() - sess.block_log_t > 8) then
            sess.block_log_t = now()
            log("[RIFT] rupture hunt blocked: " .. tostring(why))
        end
        return false
    end
    return scan(self, states, settings.tear_search_dist or 110, true)
end

-- Per-tick hook from the helltide Execute (before the state dispatch).
-- * a rupture state while the effective mode is no longer Farm is abandoned;
-- * from KILL_MONSTERS (proactive range) and chest recall / cinder farming
--   (pass-by range) a rupture pre-empts the current work.
-- Returns true when it changed the state this tick.
function M.poll(self, states)
    hr_mode.tick()
    local state = self.current_state
    if M.is_rift_state(state) then
        if not hr_mode.is_farm() then
            resume_patrol(self, states, "[RIFT] Mode is warplan — leaving the rupture", true)
            return true
        end
        return false
    end
    if not POLL_STATES[state] or not hr_mode.hunt_ruptures() then return false end
    local t = now()
    local ttl = state == states.KILL_MONSTERS and C.KILL_SCAN_TTL or C.POLL_TTL
    if sess.poll_t and t - sess.poll_t < ttl then return false end
    sess.poll_t = t
    local range = state == states.KILL_MONSTERS and (settings.tear_search_dist or 110)
        or (settings.tear_passby_dist or 50)
    return scan(self, states, range, state == states.KILL_MONSTERS)
end

function M.execute(self, states)
    local state = self.current_state
    if not hr_mode.is_farm() then
        return resume_patrol(self, states, "[RIFT] Mode is warplan — leaving the rupture", true)
    end
    local s = sess
    s.started_at = s.started_at or now()
    local cap = s.chamber_anchor and C.CHAMBER_MAX_S or C.RUPTURE_MAX_S
    -- QQT_Warpigz_v3 (rc.2 review): tears that each close within their own
    -- 90 s bound left the Realmwalker too little of the rupture-wide cap:
    -- the chain (wait, fight, portal) has its own RW_CHAIN_MAX_S, and the
    -- post-event loot window runs on its own C6 bounds (hr_tear_loot).
    local since, what = s.started_at, "Rupture"
    if s.rw_chain_at and not s.chamber_anchor then
        since, cap, what = s.rw_chain_at, C.RW_CHAIN_MAX_S, "Realmwalker chain"
    end
    if now() - since > cap and not loot.collecting(s) then
        return resume_patrol(self, states, string.format(
            "[RIFT] %s took longer than %ds — resuming patrol", what, cap), true)
    end
    local r = settings.tear_event_radius or 12
    -- QQT_Warpigz_v3 3.3.2: no rupture state without a live rupture actor.
    if s.anchor and check_live(self, states, s, r, now()) then return end
    -- QQT_Warpigz_v3 (Q2): never leave an engaged tear for a chest; the
    -- chest is opened once the tear is closed (or skipped).
    if state ~= states.RIFT_OPEN_CHEST and CHEST_SCAN_STATES[state] and not s.tear_focus_key
        and try_interrupt_for_chest(self, states, s.chamber_anchor or s.anchor, r + C.CHEST_SCAN_PAD) then
        return
    end
    local handler = H[state]
    if not handler then return resume_patrol(self, states) end
    if not s.anchor and not s.chamber_anchor and state ~= states.CHAMBER_START_RITUAL then
        return resume_patrol(self, states, "[RIFT] No rupture anchor — resuming patrol")
    end
    return handler(self, states, s, r)
end

-- C5/L11: `gap` seconds in which the state handlers did not run (Looter hold,
-- Alfred hold, revive, another task) never count toward a rupture timeout
-- that abandons or blacklists (called from helltide credit_yield).
local CREDITED = {
    "started_at", "wait_started", "move_best_t", "rw_wait_started", "no_tear_since",
    "tear_focus_since", "hold_since", "chest_best_t", "chest_loot_started",
    "rw_kill_done_at", "chamber_enter_started",
    "rw_chain_at", -- QQT_Warpigz_v3 (rc.2 review)
    "quiet_since", "grace_since", -- QQT_Warpigz_v3 3.3.2
    "guard_t", -- QQT_Warpigz_v3 3.3.3
}
function M.credit_yield(gap)
    if type(gap) ~= "number" or gap <= 0 then return end
    local s = sess
    for _, key in ipairs(CREDITED) do
        if type(s[key]) == "number" then s[key] = s[key] + gap end
    end
    for _, entry in pairs(s.tear_motion or {}) do
        if type(entry.since) == "number" then entry.since = entry.since + gap end
    end
    stand.credit(s, gap) -- QQT_Warpigz_v3 (Q2): per-tear stand bounds
    loot.credit(s, gap) -- QQT_Warpigz_v3 (Q3): post-event loot window
end

-- Full reset (helltide task reset / new session).
function M.on_reset()
    sess = {}
    area_blacklist = {}
    spent_tears = {} -- QQT_Warpigz_v3 3.3.2
    stand.sync_pause(false, now(), "reset") -- QQT_Warpigz_v3 (Q2)
    stand.reset_scale_probe()
end

-- QQT_Warpigz_v3 (Q2): Rosie's pickup is paused while a tear is engaged
-- (core/hr_tear_stand.lua). Called by the helltide task every tick before
-- its Looter hold, so a busy Looter never pulls the player out of the
-- circle; released in a non-rupture state and in Warplan.
-- QQT_Warpigz_v3 (Q3): the pause now lasts from the first tick at the
-- rupture until the whole event is over (core/hr_tear_loot.lua), at most
-- PAUSE_MAX_S per rupture (that cap covers the per-tear pause too).
local EVENT_PAUSE_MSG = "[RIFT] Pausing Looter pickup until the tear event is over (Realmwalker killed, or none within 10s)"
-- QQT_Warpigz_v3 (rc.2 review): both pauses hold only while the player is
-- at the event: never on the walk to a ring whose tears are already open
-- (engaged from up to tear_search_dist), on a revive walk-back, or on the
-- town tick after a teleport out (this runs before the "Left helltide
-- zone" check), so Rosie keeps taking what she passes outside the event
-- area (the post-event loot window only covers that area).
function M.sync_holds(state)
    local t = now()
    local rift = M.is_rift_state(state) and hr_mode.is_farm()
        and (utils.is_in_helltide() or M.holds_zone(state))
    local fkey = rift and sess.tear_focus_key or nil
    local at_tear = stand.at_tear(sess, fkey, fkey and sess.focus_tear and dist(sess.focus_tear))
    local event = rift and loot.gate_wants(sess, state, t, settings.tear_event_radius or 12, at_tear)
    local g = sess.loot_gate
    local engaged = at_tear and not (g and g.expired)
    local over = loot.over_reason(sess)
    local why = (over and ("tear event over: " .. over)) or (g and g.expired and "pause cap")
        or (rift and loot.away(sess) and "away from the rupture") or (rift and "tear done") or "rupture left"
    if stand.sync_pause(event or engaged, t, why, event and EVENT_PAUSE_MSG or nil) then
        loot.note_held(sess)
    end
end

-- Disable, task switch, death (helltide task): drop the pause now.
function M.release_holds(why)
    -- QQT_Warpigz_v3 2.6.4 (sweep H4): a pause that held Rosie's pickup back
    -- is remembered for a moment: at :55 the town teleport fired in the same
    -- tick, before Rosie was busy again, and the drops it held were left.
    if stand.pause_held() then M.released_held_at = now() end
    stand.sync_pause(false, now(), why)
end

-- True within `secs` (default 4) after release_holds dropped a pause that held.
function M.recent_release(secs)
    local at = M.released_held_at
    if not at then return false end
    local age = now() - at
    return age >= 0 and age < (secs or 4)
end

return M
