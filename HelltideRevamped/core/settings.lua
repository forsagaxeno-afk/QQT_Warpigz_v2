local gui = require "gui"
local settings = {
    enabled = false,
    -- Resolved from gui.town selection in update_settings(). Defaults match
    -- gui.town_data[0] (Temis); first-frame reads before the GUI pulse runs
    -- still get a valid zone/waypoint.
    town_zone = gui.town_data[0].zone_name,
    town_waypoint = gui.town_data[0].waypoint_sno,
    salvage = true,
    path_angle = 1,
    silent_chest = true,
    helltide_chest = true,
    ore = true,
    herb = true,
    shrine = true,
    goblin = true,
    event = true,
    chaos_rift = true,
    prioritize_traversals = false,
    kill_monsters = true,
    kill_monsters_rarity = 0, -- 0=All, 1=Rare+ (elite), 2=Champion+, 3=Boss only
    experimental_explorer = false,
    farm_cinder_threshold = 0,
    do_maiden = false,
    maiden_disable_cinders = 0,
    manage_orbwalker = false,
    draw_chest_status = false,
    debug_log = false, -- QQT_Warpigz_v3 2.6.4: periodic debug lines
    -- Run mode (core/hr_mode.lua): 0 = Warplan, 1 = Farm (default, manual use;
    -- an external enable / WarPigs adoption always runs Warplan).
    mode = 1,
    -- Pandemonium Ruptures (Farm mode, core/hr_tear_event.lua).
    hunt_rift = true,
    rupture_replace_local_events = true, -- QQT_Warpigz_v3 (rc.2): skip legacy events while hunting tears (3.0.0 default)
    rupture_prioritize_surging = false, -- S14 option, not shown (2.2.1)
    rupture_hunt_normal = true,
    rupture_hunt_surging = true,
    rupture_hunt_colossal = true,
    rupture_max_cinders = 0,
    tear_search_dist = 110,
    tear_passby_dist = 50,
    tear_event_radius = 12,
    tear_circle_radius = 2,
    rupture_linger_sec = 5,
    rupture_do_realmwalker = true,
    rupture_do_deathtoll_chamber = false,
    rupture_rw_wait_sec = 25,
    rupture_chamber_linger_sec = 8,
    rupture_open_chests = true,
    tear_use_charge_ring = true,
    log_tear_candidates = false,
    -- QQT_Warpigz_v3: smart farm (Farm mode; Warplan / WarPigs bypass the
    -- plan, the order, road routing and the event radius).
    cinder_plan = true,
    max_carry = 150,
    dump_min = 5,
    smart_order = true,
    road_routing = true,
    learn = true,
    fence = true,
    event_radius = 40,
    event_until_min = 45,
    map_pin = false,
    -- QQT_Warpigz_v3 (Q4): cinder run (core/hr_cinder_run.lua): Warplan /
    -- WarPigs use 'cinder_run', Farm mode the Smart farm goal 'farm_goal';
    -- both start the run at 'cinder_run_at' (default 2000, was 3000).
    cinder_run = false,
    farm_goal = true, -- QQT_Warpigz_v3: "Farm cinders until" (Farm mode)
    cinder_run_at = 2000,
    -- QQT_Warpigz_v3: live data & stats (every mode).
    live_api = false,
    live_source = 0,        -- 0 = helltides.com, 1 = diablo4.life
    live_poll_min = 5,
    overlay = true,
    overlay_rows = 0,       -- 0 = All, 1 = Helltide only, 2 = Timers + cinders
    -- QQT_Warpigz_v3: overlay appearance (core/hr_overlay.lua). New ids: the
    -- old Position X / Y (2%, 30%) put the panel over the party frames.
    overlay_anchor = 0,     -- 0 = top left, 1 = top right, 2 = bottom left, 3 = bottom right
    overlay_pos_x = 1,      -- % of the screen width from the anchored side
    overlay_pos_y = 3,      -- % of the screen height from the anchored side
    overlay_font = 15,
    overlay_columns = 1,    -- 0 = one column, 1 = two columns (default: STATS / OPENED on the right)
    overlay_width = 0,      -- px, 0 = auto
    overlay_bg = 25,        -- background opacity %
    overlay_theme = 0,      -- 0 = Bright, 1 = Classic, 2 = Minimal
    overlay_accent = 0,     -- 0 = Cyan, 1 = Gold, 2 = Green, 3 = Red, 4 = Purple, 5 = White
    overlay_bars = true,
    overlay_compact = false,
    overlay_show_timer = true, overlay_show_wave = true, overlay_show_cinders = true,
    overlay_show_now = true, overlay_show_target = true, overlay_show_stats = true,
    overlay_show_opened = true,
    dashboard = false,
    dashboard_sec = 10,
}

-- Keep external writes and the persisted GUI value in sync. A false setting
-- is still a supported setting, and must remain readable/writable.
local setting_controls = {
    enabled = "main_toggle", salvage = "salvage_toggle",
    silent_chest = "silent_chest_toggle", helltide_chest = "helltide_chest_toggle",
    ore = "ore_toggle", herb = "herb_toggle", shrine = "shrine_toggle",
    goblin = "goblin_toggle", event = "event_toggle", chaos_rift = "chaos_rift_toggle",
    prioritize_traversals = "prioritize_traversals_toggle", kill_monsters = "kill_monsters_toggle",
    kill_monsters_rarity = "kill_monsters_rarity", experimental_explorer = "experimental_explorer_toggle",
    farm_cinder_threshold = "farm_cinder_threshold", do_maiden = "do_maiden_toggle",
    maiden_disable_cinders = "maiden_disable_cinders", manage_orbwalker = "manage_orbwalker",
    draw_chest_status = "draw_chest_status", debug_log = "debug_log_toggle",
    mode = "mode", hunt_rift = "hunt_rift_toggle",
    rupture_replace_local_events = "rupture_replace_local_events",
    rupture_prioritize_surging = "rupture_prioritize_surging",
    rupture_hunt_normal = "rupture_hunt_normal", rupture_hunt_surging = "rupture_hunt_surging",
    rupture_hunt_colossal = "rupture_hunt_colossal", rupture_max_cinders = "rupture_max_cinders",
    tear_search_dist = "tear_search_dist", tear_passby_dist = "tear_passby_dist",
    tear_event_radius = "tear_event_radius", tear_circle_radius = "tear_circle_radius",
    rupture_linger_sec = "rupture_linger_sec", rupture_do_realmwalker = "rupture_do_realmwalker",
    rupture_do_deathtoll_chamber = "rupture_do_deathtoll_chamber",
    rupture_rw_wait_sec = "rupture_rw_wait_sec", rupture_chamber_linger_sec = "rupture_chamber_linger_sec",
    rupture_open_chests = "rupture_open_chests", tear_use_charge_ring = "tear_use_charge_ring",
    log_tear_candidates = "log_tear_candidates",
    -- QQT_Warpigz_v3: smart farm, live data & stats (controls named like the keys).
    cinder_plan = "cinder_plan", max_carry = "max_carry", dump_min = "dump_min",
    smart_order = "smart_order", road_routing = "road_routing", learn = "learn", fence = "fence",
    event_radius = "event_radius", event_until_min = "event_until_min", map_pin = "map_pin",
    cinder_run = "cinder_run", cinder_run_at = "cinder_run_at", -- QQT_Warpigz_v3 (Q4)
    farm_goal = "farm_goal", -- QQT_Warpigz_v3: Smart farm goal
    live_api = "live_api", live_source = "live_source", live_poll_min = "live_poll_min",
    overlay = "overlay", overlay_rows = "overlay_rows",
    -- QQT_Warpigz_v3: overlay appearance
    overlay_anchor = "overlay_anchor", overlay_pos_x = "overlay_pos_x", overlay_pos_y = "overlay_pos_y",
    overlay_font = "overlay_font", overlay_columns = "overlay_columns", overlay_width = "overlay_width", overlay_bg = "overlay_bg",
    overlay_theme = "overlay_theme", overlay_accent = "overlay_accent", overlay_bars = "overlay_bars",
    overlay_compact = "overlay_compact", overlay_show_timer = "overlay_show_timer",
    overlay_show_wave = "overlay_show_wave", overlay_show_cinders = "overlay_show_cinders",
    overlay_show_now = "overlay_show_now", overlay_show_target = "overlay_show_target",
    overlay_show_stats = "overlay_show_stats", overlay_show_opened = "overlay_show_opened",
    dashboard = "dashboard", dashboard_sec = "dashboard_sec",
}
-- Settings synced 1:1 from their control in update_settings (mode + ruptures).
-- QQT_Warpigz_v2 (2.2.1): the Season 14 only options (tear type filters and
-- priority, Deathtoll Chamber, scan log) are no longer shown or synced; every
-- tear type found is hunted, the chamber is never entered, the log is off.
local synced_controls = {
    "mode", "hunt_rift", "rupture_replace_local_events", "rupture_max_cinders",
    "tear_search_dist", "tear_passby_dist", "tear_event_radius", "tear_circle_radius",
    "rupture_linger_sec", "rupture_do_realmwalker",
    "rupture_rw_wait_sec", "rupture_open_chests", "tear_use_charge_ring",
    -- QQT_Warpigz_v3
    "cinder_plan", "max_carry", "dump_min", "smart_order", "road_routing", "learn", "fence",
    "event_radius", "event_until_min", "map_pin",
    "cinder_run", "cinder_run_at", -- QQT_Warpigz_v3 (Q4)
    "farm_goal", -- QQT_Warpigz_v3
    "live_api", "live_source", "live_poll_min", "overlay", "overlay_rows",
    -- QQT_Warpigz_v3: overlay appearance
    "overlay_anchor", "overlay_pos_x", "overlay_pos_y", "overlay_font", "overlay_columns", "overlay_width", "overlay_bg",
    "overlay_theme", "overlay_accent", "overlay_bars", "overlay_compact", "overlay_show_timer",
    "overlay_show_wave", "overlay_show_cinders", "overlay_show_now", "overlay_show_target",
    "overlay_show_stats", "overlay_show_opened",
    "dashboard", "dashboard_sec",
}

function settings.set_setting(name, value)
    if settings[name] == nil or type(settings[name]) == "function"
        or type(value) ~= type(settings[name]) then return false end
    local control = setting_controls[name]
    if control then gui.elements[control]:set(value) end
    if name == "town_zone" or name == "town_waypoint" then
        local field = name == "town_zone" and "zone_name" or "waypoint_sno"
        local matched = false
        for index, town in pairs(gui.town_data) do
            if town[field] == value then
                gui.elements.town:set(index)
                matched = true
                break
            end
        end
        if not matched then return false end
    end
    settings[name] = value
    return true
end

function settings:update_settings()
    settings.enabled = gui.elements.main_toggle:get()
    local town_idx = gui.elements.town:get()
    local town_data = gui.town_data[town_idx] or gui.town_data[0]
    settings.town_zone = town_data.zone_name
    settings.town_waypoint = town_data.waypoint_sno
    settings.salvage = gui.elements.salvage_toggle:get()
    settings.silent_chest = gui.elements.silent_chest_toggle:get()
    settings.helltide_chest = gui.elements.helltide_chest_toggle:get()
    settings.ore = gui.elements.ore_toggle:get()
    settings.herb = gui.elements.herb_toggle:get()
    settings.shrine = gui.elements.shrine_toggle:get()
    settings.goblin = gui.elements.goblin_toggle:get()
    settings.event = gui.elements.event_toggle:get()
    settings.chaos_rift = gui.elements.chaos_rift_toggle:get()
    settings.prioritize_traversals = gui.elements.prioritize_traversals_toggle:get()
    settings.kill_monsters = gui.elements.kill_monsters_toggle:get()
    settings.kill_monsters_rarity = gui.elements.kill_monsters_rarity:get()
    settings.experimental_explorer = gui.elements.experimental_explorer_toggle:get()
    settings.farm_cinder_threshold = gui.elements.farm_cinder_threshold:get()
    settings.do_maiden = gui.elements.do_maiden_toggle:get()
    settings.maiden_disable_cinders = gui.elements.maiden_disable_cinders:get()
    settings.manage_orbwalker = gui.elements.manage_orbwalker:get()
    settings.draw_chest_status = gui.elements.draw_chest_status:get()
    settings.debug_log = gui.elements.debug_log_toggle:get() == true -- QQT_Warpigz_v3 2.6.4
    for _, name in ipairs(synced_controls) do
        local el = gui.elements[setting_controls[name]]
        if el then
            local v = el:get()
            if type(v) == type(settings[name]) then settings[name] = v end
        end
    end
end

-- Above this cinder count, force orbwalker clear OFF so the bot stops lingering
-- to fight for cinders we don't need and can prioritize finding/opening chests.
local CINDER_CLEAR_OFF_THRESHOLD = 150

local function cinder_gate_active()
    return get_helltide_coin_cinders() > CINDER_CLEAR_OFF_THRESHOLD
end

-- Temporary override timestamp: until this time, force_orb_clear_for() callers
-- want orbwalker clear ON regardless of the cinder gate. Used by chest combat
-- detection so monsters can't park us at >149 cinders forever.
local force_clear_until = -math.huge

local function force_active()
    return get_time_since_inject() <= force_clear_until
end

-- QQT_Warpigz_v3 2.6.8 (owner live: "stopped casting skills ... until the
-- character was killed"): the gate kept clear OFF while HR fought (and
-- kill_monsters' own orb_set_clear(true) was gated too), so the rotation
-- never cast. A living enemy within THREAT_M of the player, or HR fighting
-- (combat_clear), keeps clear ON; logged once per episode.
local THREAT_M = 10
local threat = {at = -math.huge, yes = false, logged = false}
local function threatened()
    local now = get_time_since_inject()
    if now - threat.at < 0.25 and now >= threat.at then return threat.yes end
    threat.at, threat.yes = now, false
    local ok, list = pcall(function()
        return target_selector.get_near_target_list(get_player_position(), THREAT_M)
    end)
    if ok and type(list) == 'table' then
        local okp, here = pcall(get_player_position)
        for _, e in pairs(list) do
            -- QQT_Warpigz_v3 2.6.9 (review of 2.6.8): get_kill_target's filters:
            -- not on another floor (> 12 m up/down), not unreachable or ignored
            -- (settings.threat_skip, bound by tasks/helltide.lua).
            local okz, far = pcall(function()
                return math.abs(here:z() - e:get_position():z()) > 12
            end)
            local skip = okp and okz and far
            if not skip and settings.threat_skip then
                local oks, s = pcall(settings.threat_skip, e)
                skip = oks and s == true
            end
            if not skip then
                local okh, hp = pcall(function() return e:get_current_health() end)
                if not okh or hp == nil or hp > 1 then threat.yes = true break end
            end
        end
    end
    return threat.yes
end

local function threat_log(why)
    if threat.logged then return end
    threat.logged = true
    console.print('[HR] Cinder gate: clear forced ON — ' .. why)
end

-- C4/L12b: orbwalker states HR itself forced (clear OFF, block ON). Like
-- WonderCity's orb_forced, they are handed back even when 'Manage orbwalker'
-- was switched off after HR forced them; HR never touches an orbwalker it
-- did not force while management is off.
local orb_forced = {clear = false, block = false}

local function set_clear(v)
    orbwalker.set_clear_toggle(v)
    orb_forced.clear = not v
end

settings.orb_set_clear = function (v)
    if not settings.manage_orbwalker then
        if v and orb_forced.clear then set_clear(true) end
        return
    end
    if v and cinder_gate_active() and not force_active() then
        if threatened() then
            threat_log('enemies on the player') -- QQT_Warpigz_v3 2.6.8
        else
            v = false
        end
    end
    set_clear(v)
end

-- Tick driver: call from the main task pulse so the gate is asserted every
-- frame, regardless of which state handler is running. Previously this only
-- forced OFF above threshold, which left orbwalker stuck OFF after cinders
-- dropped back below 150 (e.g. we just opened a chest) until the next state
-- that explicitly called orb_set_clear(true). Now it's symmetric.
-- With management switched off mid-run, a clear OFF the gate forced is
-- handed back once and the gate then leaves the orbwalker alone.
settings.apply_cinder_orb_gate = function ()
    if not settings.manage_orbwalker then
        if orb_forced.clear then set_clear(true) end
        return
    end
    if force_active() then
        set_clear(true)
    elseif cinder_gate_active() then
        -- QQT_Warpigz_v3 2.6.8: never OFF with enemies on the player.
        if threatened() then
            threat_log('enemies on the player')
            set_clear(true)
        else
            set_clear(false)
        end
    else
        threat.logged = false -- QQT_Warpigz_v3 2.6.9: logged once per gate episode, not per fight
        set_clear(true)
    end
end

-- QQT_Warpigz_v3 2.6.9 (review of 2.6.8): with HR fighting, clear stays ON
-- (combat_clear), so above the gate HR must not start fights for cinders it
-- does not need: a plain monster farther than THREAT_M is not engaged
-- (elites, champions and bosses still are; a closer one is self-defence).
-- Only with 'Manage orbwalker' (the gate is its feature).
settings.km_gated = function (target, dist)
    if not (settings.manage_orbwalker and target and cinder_gate_active()) then return false end
    if type(dist) == 'number' and dist <= THREAT_M then return false end
    local ok, special = pcall(function()
        return target:is_boss() or target:is_champion() or target:is_elite()
    end)
    return not (ok and special)
end

-- QQT_Warpigz_v3 2.6.8: HR is fighting (KILL_MONSTERS, the maiden fight, a
-- chest farm): clear ON for 1.5 s whatever the cinder gate says, refreshed
-- every tick while the fight lasts.
settings.combat_clear = function ()
    if not settings.manage_orbwalker then
        settings.orb_set_clear(true)
        return
    end
    if cinder_gate_active() and not force_active() then threat_log('HR is fighting') end
    force_clear_until = math.max(force_clear_until, get_time_since_inject() + 1.5)
    set_clear(true)
end

-- Force orbwalker clear ON for `seconds` regardless of the cinder gate. Used
-- when monsters are interrupting a chest channel: we'd rather burn the cinders
-- we don't need than stand there getting hit while never killing anything.
settings.force_orb_clear_for = function (seconds)
    if not settings.manage_orbwalker then return end
    force_clear_until = get_time_since_inject() + (seconds or 5)
    set_clear(true)
end

settings.orb_set_block = function (v)
    if settings.manage_orbwalker or (not v and orb_forced.block) then
        orbwalker.set_block_movement(v)
        orb_forced.block = v and true or false
    end
end

-- C4/HLT-6: leaving HR (disable, task switch, loading) hands the orbwalker
-- back in its neutral state: movement unblocked and clear ON, which the
-- cinder gate may have forced OFF. A pending chest-combat force window is
-- dropped so it cannot outlive the session. A state HR forced is restored
-- even if 'Manage orbwalker' was switched off since (L12b).
settings.orb_release = function ()
    force_clear_until = -math.huge
    if settings.manage_orbwalker or orb_forced.block then
        orbwalker.set_block_movement(false)
    end
    if settings.manage_orbwalker or orb_forced.clear then
        orbwalker.set_clear_toggle(true)
    end
    orb_forced.clear, orb_forced.block = false, false
end

return settings