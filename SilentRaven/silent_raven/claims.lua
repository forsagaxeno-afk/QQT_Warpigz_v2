-- QQT_Warpigz_v3 (Q8): claim decisions outside a run, and the claim trip.
-- A whole night of Helltide farming under WarPigs claimed no reward and
-- logged nothing: SilentRaven was managed by WarPigs (no auto-fire), Rosie's
-- return-leg hand-off skipped a managed SilentRaven silently, and WarPigs
-- offers its own Whisper slot only between activities. This module
--   * logs the Whisper quest state when it changes (at most every 10 s),
--     'reward ready', and each distinct reason a ready reward is not claimed
--     yet (once per ready episode): the next live log shows why;
--   * requests a claim trip: a reward ready for settings.claim_trip_after
--     seconds with no Temis visit asks the town service (Rosie: `raven_handoff`
--     names its hand-off caller) for a with-teleport trip; its return leg hands the claim
--     over to SilentRaven. Only in the open world (never from a Pit,
--     Undercity, Horde, lair or dungeon, never during a Helltide event,
--     chest or maiden), with the town service, the Looter and WarPug idle, no
--     enemy close, and only while SilentRaven takes a hand-off (auto-fire when
--     standalone, WarPigs' delegation when WarPigs manages Whispers).
--     Bounded (C6): at most one trip per interval; a trip that teleported and
--     ended without a claim counts, and TRIP_LIMIT such trips (1 for an inferred readiness)
--     end the claim trips of this ready episode. The trip itself is Rosie's
--     (bounded by its service time and its 100 s SilentRaven wait).
local log = require 'silent_raven.log'
local tracker = require 'silent_raven.tracker'
local whispers = require 'silent_raven.whispers'
local coordination = require 'silent_raven.coordination'
local M = {}
local CALLER, CHECK_S, ENEMY_RADIUS, TRIP_BOUND, TRIP_LIMIT, QUEST_LOG_S = 'silent_raven', 1.0, 12, 400, 2, 10
local OPEN_WORLD = 'Sanctuary_Eastern_Continent'
local TOWNS = {Skov_Temis = true, Naha_Kurast = true, Kehj_Caldeum = true, Scos_Cerrigar = true,
    Frac_Kyovashad = true, Hawe_Zarbinzet = true, Kehj_Gea_Kul = true, Step_Jirandai = true}
-- HelltideRevamped states (its getState export) a town trip must not cut
-- short: events, ruptures, chests, the maiden, its own town legs and teleports.
-- QQT_Warpigz_v3 (3.1.1): any state naming a rift (MOVING_TO_RIFT, CHAOS_RIFT...)
-- is busy; '^RIFT_' let a claim trip start on the walk to a ritual ring.
local HR_BUSY = {'RIFT', '^CHAMBER_', 'MAIDEN', 'PYRE', 'CHAOS_RIFT', 'CHEST', 'TOWN', 'RETURN_', 'SHRINE', 'GOBLIN',
    'TELEPORT'}
local s = {ready_since = nil, inferred = false, said = {}, quest_line = nil, quest_t = -math.huge,
    check_t = -math.huge, trip = nil, last_trip_t = -math.huge, unclaimed = 0}
M.state = s

-- One line per decision key and ready episode.
local function say(key, message)
    if s.said[key] then return end
    s.said[key] = true
    log.info(message)
end

local function world_name()
    if type(get_current_world) ~= 'function' then return nil end
    local ok, world = pcall(get_current_world)
    if not ok or not world then return nil end
    return whispers.safe_method(world, 'get_name')
end
local function in_town()
    local zone = whispers.current_zone()
    if TOWNS[zone or ''] then return true end
    local attrs = rawget(_G, 'attributes')
    if type(attrs) ~= 'table' or attrs.PLAYER_IN_TOWN_LEVEL_AREA == nil or type(get_local_player) ~= 'function' then return false end
    local ok, player = pcall(get_local_player)
    return ok and whispers.safe_method(player, 'get_attribute', attrs.PLAYER_IN_TOWN_LEVEL_AREA) == 1
end
local function enemy_near()
    if not actors_manager or type(get_local_player) ~= 'function' then return false end
    local ok, player = pcall(get_local_player)
    local pp = ok and whispers.safe_method(player, 'get_position') or nil
    local px, py = whispers.safe_method(pp, 'x'), whispers.safe_method(pp, 'y')
    local enemies = whispers.safe_method(actors_manager, 'get_enemy_actors')
    if not px or not py or type(enemies) ~= 'table' then return false end
    for _, actor in pairs(enemies) do
        if whispers.safe_method(actor, 'is_dead') ~= true then
            local pos = whispers.safe_method(actor, 'get_position')
            local x, y = whispers.safe_method(pos, 'x'), whispers.safe_method(pos, 'y')
            if x and y and (x - px) ^ 2 + (y - py) ^ 2 <= ENEMY_RADIUS * ENEMY_RADIUS then return true end
        end
    end
    return false
end
local function helltide_busy()
    local hr = rawget(_G, 'HelltideRevampedPlugin')
    if type(hr) ~= 'table' or type(hr.getState) ~= 'function' then return nil end
    local ok, state = pcall(hr.getState)
    if not ok or type(state) ~= 'string' then return nil end
    for _, pattern in ipairs(HR_BUSY) do
        if state:find(pattern) then return state end
    end
    return nil
end

-- Why a due claim trip cannot start now (key, message), or nil.
local function blocker(now)
    if not whispers.player_ready() then return 'player', 'the player is dead or loading' end
    local world = world_name()
    if world ~= OPEN_WORLD then return 'world', 'the player is not in the open world (' .. tostring(world) .. ')' end
    if in_town() then return 'town', 'the player is in a town other than Temis' end
    -- QQT_Warpigz_v3 3.3.3: never teleport away from a third-party loop that
    -- owns the run (a claim is never urgent: a later Temis visit or trip claims).
    local owner = coordination.activity_owner()
    if owner then return 'activity', 'another activity owns the run (' .. owner .. ')' end
    -- QQT_Warpigz_v3 3.3.3: Butler's trip, Scavenger's pickup or a Navigator
    -- walk (Worldstone) would interrupt the Town Portal cast.
    local third = coordination.third_party_reason()
    if third then return third:match('^[^:]+'), 'a third-party addon is busy (' .. third .. ')' end
    local _, st = coordination.town_provider()
    if not st then return 'provider', 'no town service is loaded' end
    if type(st.raven_handoff) ~= 'string' then return 'provider', 'the town service has no SilentRaven hand-off (Rosie required)' end
    if st.enabled ~= true then return 'provider_off', 'the town service is disabled' end
    if st.allow_external == false then return 'provider_external', 'the town service refuses external requests' end
    if st.stuck == true then return 'provider_stuck', 'the town service is stuck (' .. tostring(st.stuck_reason) .. ')' end
    if st.paused == true then return 'provider_paused', 'the town service is paused by ' .. tostring(st.paused_by) end
    if coordination.alfred_live_work(st) then return 'provider_busy', 'the town service is on a trip' end
    local clear, why = coordination.companions('manual', now)
    if not clear then return 'companion', 'a companion is busy (' .. tostring(why) .. ')' end
    local busy = helltide_busy()
    if busy then return 'helltide', 'HelltideRevamped is busy (' .. busy .. ')' end
    if enemy_near() then return 'enemies', 'enemies are close' end
    return nil
end

local function request_trip(now)
    local p = coordination.town_provider()
    local fn = type(p) == 'table' and p.trigger_tasks_with_teleport or nil
    s.last_trip_t = now
    if type(fn) ~= 'function' then return end
    local trip = {t = now}
    s.trip = trip
    local ok, accepted, why = pcall(fn, CALLER, function(result)
        if s.trip == trip then trip.done, trip.result = true, result end
    end)
    if not ok or accepted == false then
        s.trip = nil
        log.info('claim trip refused by the town service: ' .. tostring(ok and why or accepted))
        return
    end
    log.info(string.format('reward ready for %.0fs with no Temis visit: claim trip requested (the town service hands the claim over on its return leg)',
        now - (s.ready_since or now)))
end

-- The trip in flight ends on its callback, on an idle town service after a
-- short grace, or at TRIP_BOUND.
local function watch_trip(now)
    local trip = s.trip
    local _, st = coordination.town_provider()
    local live = st ~= nil and coordination.alfred_live_work(st)
    -- QQT_Warpigz_v3 3.3.3: the trip's teleport was tried (Temis reached, or
    -- the cast ended done / failed). A trip that ended before any cast is not
    -- counted against TRIP_LIMIT; a failed cast is (no loop of failing casts).
    if whispers.in_whisper_town() or (st ~= nil and (st.teleport_done == true or st.teleport_failed == true)) then
        trip.teleported = true
    end
    if not trip.done and now - trip.t < TRIP_BOUND and (live or now - trip.t < 5) then return end
    s.trip, s.last_trip_t = nil, now
    if tracker.last_result == 'success' and (tracker.last_result_t or 0) >= trip.t then
        log.info('claim trip finished: the reward was claimed')
        return
    end
    if trip.teleported then s.unclaimed = s.unclaimed + 1 end
    log.info(string.format('claim trip ended without a claim (town service: %s; SilentRaven: %s, %s)%s',
        tostring(trip.done and (trip.result or 'completed') or 'no callback'),
        tostring(tracker.last_result_t and tracker.last_result_t >= trip.t and tracker.last_result or 'did not run'),
        tostring(tracker.last_reason), trip.teleported and '' or '; no teleport, not counted'))
end

local function quest_line(now, snapshot)
    local line
    if not snapshot.present then
        line = 'no Whisper quest (Bounty_Meta_*) in the quest list'
    else
        local state = snapshot.ready and (snapshot.inferred and 'ready (inferred, no English turn-in text)' or 'ready')
            or (snapshot.collecting and 'collecting' or 'not ready')
        line = 'Whisper quest ' .. tostring(snapshot.detail or 'present, no objective text') .. ' -> ' .. state
    end
    if line ~= s.quest_line and now - s.quest_t >= QUEST_LOG_S then
        s.quest_line, s.quest_t = line, now
        log.info(line)
    end
end

-- Called at the ready-check rate with this pulse's quest snapshot (nil when
-- unreadable), never during a run.
function M.observe(now, settings, snapshot)
    if s.trip then watch_trip(now) end
    if snapshot == nil then return end
    quest_line(now, snapshot)
    if not snapshot.ready then
        if s.ready_since then s.ready_since, s.said, s.unclaimed = nil, {}, 0 end
        return
    end
    if not s.ready_since then
        s.ready_since, s.inferred = now, snapshot.inferred == true
        log.info('reward ready' .. (s.inferred and ' (inferred: one probe per Temis visit)' or ''))
    end
    if tracker.running or tracker.external_trigger or s.trip then return end
    local consent, why = coordination.handoff_ok(settings)
    if whispers.in_whisper_town() then
        if tracker.last_zone_handled == 'Skov_Temis' then
            say('latched', 'reward ready but skipped because this Temis visit is already handled (last: '
                .. tostring(tracker.last_result) .. ', ' .. tostring(tracker.last_reason) .. '); next visit')
        elseif tracker.managed_by and not consent then
            say('managed_temis', 'reward ready but skipped because ' .. tostring(why))
        end
        -- QQT_Warpigz_v3 (Q8 review): a delegating WarPigs with an activity on
        -- leaves this Temis stop to SilentRaven (main.lua maybe_autofire,
        -- reason 'delegated'); between activities its own Whisper visit claims.
        return
    end
    if not consent then say('consent:' .. tostring(why), 'reward ready but skipped because ' .. tostring(why)); return end
    local after = tonumber(settings.claim_trip_after) or 0
    if after <= 0 then
        say('trip_off', 'reward ready: claimed on the next Temis visit (a Rosie trip hands it over on its return leg); claim trips are off')
        return
    end
    local limit = s.inferred and 1 or TRIP_LIMIT
    if s.unclaimed >= limit then
        say('trip_limit', string.format('reward ready: no more claim trips after %d without a claim; waiting for a Temis visit', s.unclaimed))
        return
    end
    local due = math.max(s.ready_since, s.last_trip_t) + after
    if now < due then
        say('wait', string.format('reward ready: claimed on the next Temis visit, or by a claim trip in %.0fs', due - now))
        return
    end
    if now - s.check_t < CHECK_S then return end
    s.check_t = now
    local key, message = blocker(now)
    if key then say('trip:' .. key, 'reward ready: claim trip waits because ' .. message); return end
    request_trip(now)
end

return M
