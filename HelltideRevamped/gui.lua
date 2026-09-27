local gui = {}
local version = "v2.4.0"
local plugin_label = "helltide_revamped"

local function create_checkbox(value, key)
    return checkbox:new(value, get_hash(plugin_label .. "_" .. key))
end

-- Town options for the idle / give-up teleport target. Order matches Alfred's
-- ordering (Temis, Cerrigar). Resolved to zone/waypoint in core/settings.lua.
gui.town = { "Temis", "Cerrigar" }
gui.town_data = {
    [0] = { zone_name = "Skov_Temis",    waypoint_sno = 0x1CE51E },
    [1] = { zone_name = "Scos_Cerrigar", waypoint_sno = 0x76D58 },
}

-- Rarity floor for kill_monsters. Maps to enemy:is_*() in helltide.lua
-- get_kill_target. Order is ascending — "All" includes everything, each step
-- raises the floor by one tier.
gui.kill_rarity = { "All", "Rare+", "Champion+", "Boss only" }

-- Run mode (core/hr_mode.lua): index 0 = Warplan, 1 = Farm. An external
-- enable (WarPigs) always runs Warplan whatever is selected here, so the combo
-- only matters for manual use and defaults to Farm (keeps maiden / chaos rift
-- working for standalone users after the update).
gui.mode = { "Warplan", "Farm" }

-- QQT_Warpigz_v3: live zone source and overlay row choices.
gui.live_source = { "helltides.com", "diablo4.life" }
gui.overlay_rows = { "All", "Helltide only", "Compact" }
-- Menu buttons only raise a request here; main.lua handles it (no file work
-- inside the menu callback).
gui.request_forget, gui.request_reset_stats = false, false

gui.elements = {
    main_tree = tree_node:new(0),
    main_toggle = create_checkbox(false, "main_toggle"),
    settings_tree = tree_node:new(1),
    mode = combo_box:new(1, get_hash(plugin_label .. "_mode")),
    town = combo_box:new(0, get_hash(plugin_label .. "_town")),
    salvage_toggle = create_checkbox(true, plugin_label .. "salvage_toggle"),
    silent_chest_toggle = create_checkbox(true, plugin_label .. "silent_chest_toggle"),
    helltide_chest_toggle = create_checkbox(true, plugin_label .. "helltide_chest_toggle"),
    ore_toggle = create_checkbox(true, plugin_label .. "ore_toggle"),
    herb_toggle = create_checkbox(true, plugin_label .. "herb_toggle"),
    shrine_toggle = create_checkbox(true, plugin_label .. "shrine_toggle"),
    goblin_toggle = create_checkbox(true, plugin_label .. "goblin_toggle"),
    event_toggle = create_checkbox(true, plugin_label .. "event_toggle"),
    chaos_rift_toggle = create_checkbox(true, plugin_label .. "chaos_rift_toggle"),
    prioritize_traversals_toggle = create_checkbox(false, plugin_label .. "prioritize_traversals_toggle"),
    kill_monsters_toggle = create_checkbox(true, plugin_label .. "kill_monsters_toggle"),
    kill_monsters_rarity = combo_box:new(0, get_hash(plugin_label .. "_kill_monsters_rarity")),
    experimental_explorer_toggle = create_checkbox(false, plugin_label .. "experimental_explorer_toggle"),
    farm_cinder_threshold = slider_int:new(0, 250, 0, get_hash(plugin_label .. "_farm_cinder_threshold")),
    do_maiden_toggle = create_checkbox(false, plugin_label .. "do_maiden_toggle"),
    maiden_disable_cinders = slider_int:new(0, 1000, 0, get_hash(plugin_label .. "_maiden_disable_cinders")),
    manage_orbwalker = create_checkbox(false, plugin_label .. "manage_orbwalker"),
    -- Pandemonium Ruptures (Farm mode only), ported from upstream HR 2.5.0.
    ruptures_tree = tree_node:new(3),
    hunt_rift_toggle = create_checkbox(true, plugin_label .. "hunt_rift_toggle"),
    -- QQT_Warpigz_v3 (rc.2, user approved): on by default again under the
    -- original 3.0.0 menu id (rc.1 had moved it to a "_v3" id, default off):
    -- with Hunt tears on, Farm skips the legacy flame pillar / pyre events.
    rupture_replace_local_events = create_checkbox(true, plugin_label .. "rupture_replace_local_events"),
    rupture_prioritize_surging = create_checkbox(true, plugin_label .. "rupture_prioritize_surging"),
    rupture_hunt_normal = create_checkbox(true, plugin_label .. "rupture_hunt_normal"),
    rupture_hunt_surging = create_checkbox(true, plugin_label .. "rupture_hunt_surging"),
    rupture_hunt_colossal = create_checkbox(true, plugin_label .. "rupture_hunt_colossal"),
    rupture_max_cinders = slider_int:new(0, 1000, 0, get_hash(plugin_label .. "_rupture_max_cinders")),
    tear_search_dist = slider_int:new(30, 200, 110, get_hash(plugin_label .. "_tear_search_dist")),
    tear_passby_dist = slider_int:new(15, 80, 50, get_hash(plugin_label .. "_tear_passby_dist")),
    tear_event_radius = slider_int:new(4, 30, 12, get_hash(plugin_label .. "_tear_event_radius")),
    tear_circle_radius = slider_int:new(1, 8, 2, get_hash(plugin_label .. "_tear_circle_radius")),
    rupture_linger_sec = slider_int:new(1, 20, 5, get_hash(plugin_label .. "_rupture_linger_sec")),
    rupture_do_realmwalker = create_checkbox(true, plugin_label .. "rupture_do_realmwalker"),
    rupture_do_deathtoll_chamber = create_checkbox(false, plugin_label .. "rupture_do_deathtoll_chamber"),
    rupture_rw_wait_sec = slider_int:new(10, 60, 25, get_hash(plugin_label .. "_rupture_rw_wait_sec")),
    rupture_chamber_linger_sec = slider_int:new(3, 30, 8, get_hash(plugin_label .. "_rupture_chamber_linger_sec")),
    rupture_open_chests = create_checkbox(true, plugin_label .. "rupture_open_chests"),
    tear_use_charge_ring = create_checkbox(true, plugin_label .. "tear_use_charge_ring"),
    log_tear_candidates = create_checkbox(false, plugin_label .. "log_tear_candidates"),
    debug_tree = tree_node:new(2),
    draw_chest_status = create_checkbox(false, plugin_label .. "draw_chest_status"),
    -- QQT_Warpigz_v3: smart farm (Farm mode).
    smart_tree = tree_node:new(1),
    smart_order = create_checkbox(true, plugin_label .. "smart_order"),
    cinder_plan = create_checkbox(true, plugin_label .. "cinder_plan"),
    max_carry = slider_int:new(0, 500, 150, get_hash(plugin_label .. "_max_carry")),
    dump_min = slider_int:new(0, 15, 5, get_hash(plugin_label .. "_dump_min")),
    road_routing = create_checkbox(true, plugin_label .. "road_routing"),
    learn = create_checkbox(true, plugin_label .. "learn"),
    fence = create_checkbox(true, plugin_label .. "fence"),
    event_radius = slider_int:new(12, 80, 40, get_hash(plugin_label .. "_event_radius")),
    event_until_min = slider_int:new(30, 55, 45, get_hash(plugin_label .. "_event_until_min")),
    map_pin = create_checkbox(false, plugin_label .. "map_pin"),
    -- QQT_Warpigz_v3 (Q4): cinder run (every mode).
    cinder_run = create_checkbox(false, plugin_label .. "cinder_run"),
    cinder_run_at = slider_int:new(250, 10000, 3000, get_hash(plugin_label .. "_cinder_run_at")),
    forget_zone = button:new(get_hash(plugin_label .. "_forget_zone")),
    -- QQT_Warpigz_v3: live data & stats.
    live_tree = tree_node:new(1),
    live_api = create_checkbox(false, plugin_label .. "live_api"),
    live_source = combo_box:new(0, get_hash(plugin_label .. "_live_source")),
    live_poll_min = slider_int:new(2, 15, 5, get_hash(plugin_label .. "_live_poll_min")),
    overlay = create_checkbox(true, plugin_label .. "overlay"),
    overlay_x = slider_int:new(0, 100, 2, get_hash(plugin_label .. "_overlay_x")),
    overlay_y = slider_int:new(0, 100, 30, get_hash(plugin_label .. "_overlay_y")),
    overlay_rows = combo_box:new(0, get_hash(plugin_label .. "_overlay_rows")),
    dashboard = create_checkbox(false, plugin_label .. "dashboard"),
    dashboard_sec = slider_int:new(5, 60, 10, get_hash(plugin_label .. "_dashboard_sec")),
    reset_alltime = button:new(get_hash(plugin_label .. "_reset_alltime")),
}

-- A persisted combo index outside the item list crashes the client when the
-- combo renders; clamp it back to 0 first.
local function clamp_combo(el, items)
    if not el or not el.get then return end
    local ok, v = pcall(el.get, el)
    if ok and type(v) == "number" and (v < 0 or v >= #items) then pcall(el.set, el, 0) end
end

local function render_ruptures()
    local e = gui.elements
    -- QQT_Warpigz_v2 (2.2.1): Season 15 calls these Tears; the Season 14
    -- only options (Surging/Colossal filters and priority, Deathtoll Chamber,
    -- scan log) are no longer shown and stay at fixed values (core/settings.lua).
    if not e.ruptures_tree:push("Tears (Farm mode)") then return end
    e.hunt_rift_toggle:render("Hunt tears",
        "Farm mode: go to tears first: kill the cultists, close the golden tears, open the chests, then go back to chests/monsters. Rosie's pickup waits while you are at the tear event until it is over (Realmwalker killed, or none within 10 s after the rupture completes); then the bot collects the event's drops before it moves on. The walk to a tear and back after a death are never paused.") -- QQT_Warpigz_v3 (Q3, rc.2 review)
    if e.hunt_rift_toggle:get() then
        e.rupture_replace_local_events:render("Skip legacy Helltide events",
            "On by default. Farm mode: never walk to flame pillars / ravenous soul pyres while hunting tears (Event radius and Events until minute then do nothing). Untick it to run those events too; tears in reach are always taken before events.") -- QQT_Warpigz_v3 (rc.2)
        e.rupture_max_cinders:render("  Pause hunt at cinders",
            "Stop looking for NEW ruptures once you hold this many cinders so they get spent on chests first (0 = always hunt). A rupture already in progress is finished.", 1)
        e.tear_search_dist:render("  Search distance", "Scan this far for ritual rings, rupture gizmos and active tears", 5)
        e.tear_passby_dist:render("  Pass-by distance", "While walking to a remembered chest or farming cinders, detour for ruptures this close", 1)
        e.tear_event_radius:render("  Ritual stay radius", "Stay within this distance of the rupture anchor while closing tears", 1)
        e.tear_circle_radius:render("  Hold-area tolerance", "How far from the ritual circle centre before walking back", 1)
        e.rupture_linger_sec:render("  Linger after last tear", "Seconds to stay in the ring after the tears are gone (more kills, rupture rewards)", 1)
        e.rupture_do_realmwalker:render("  Fight Realmwalker",
            "Wait for and kill the Realmwalker when it spawns after tears.")
        if e.rupture_do_realmwalker:get() then
            e.rupture_rw_wait_sec:render("    Realmwalker wait (sec)", "How long to wait for the Realmwalker to spawn", 1)
        end
        -- QQT_Warpigz_v3 (Q2): the bot now stays until the tear closes.
        e.tear_use_charge_ring:render("  Stand on chargeable tears",
            "Walk onto each golden tear and stay inside its circle while your rotation kills the adds, until the tear closes (at most 90 s inside one tear), then the next tear. No chest or Rosie pickup detour meanwhile.")
        e.rupture_open_chests:render("  Open tear chests",
            "Open Pandemonium chests (free) and affordable helltide chests inside the ritual ring, once the tear you stand in is closed. Requires Open Helltide Chest.") -- QQT_Warpigz_v3 (Q2)
    end
    e.ruptures_tree:pop()
end

-- QQT_Warpigz_v3 (Q4): cinder run (core/hr_cinder_run.lua), Farm and Warplan.
local function render_cinder_run()
    local e = gui.elements
    e.cinder_run:render("Spend cinders on chests at",
        "Off by default. On: below this many cinders no Helltide chest is opened (they are remembered; the last minutes of the Helltide, 'Spend everything in the last (min)' but at least 2, spend the savings; not under WarPigs, whose Helltide step ends once its War Plan cinders are spent). Holding at least this many cinders starts a chest run (Farm and Warplan / WarPigs): Hell's Prize first (666, War Plan node Hell's Prize), then Mystery chests (250), then the rest nearest first, using the chests in sight, remembered and learned spots. No new tears are hunted while the run has a chest to go to. The run ends when the cinders fall below the cheapest known chest. Hell's Prize chests are opened only by this run. Requires Open Helltide Chest.") -- QQT_Warpigz_v3 (Q4): save phase
    if e.cinder_run:get() then
        e.cinder_run_at:render("  Cinders", "Start the chest run at this many cinders", 1)
    end
end

-- QQT_Warpigz_v3: probed only while the live option is shown (reading an
-- absent host global is harmless but noisy on some hosts).
local function has_curl()
    local c = curl
    return type(c) == "table" and type(c.http_get) == "function"
end

local function render_smart_farm()
    local e = gui.elements
    if not e.smart_tree:push("Smart farm (Farm mode)") then return end
    e.smart_order:render("Smart chest order",
        "Farm mode: Mystery chests first, chests you saw before learned (predicted) spots, nearest first along the patrol road, no ping-pong across the map. After each chest reset (UTC :00/:15/:20/:30/:40/:45) fresh Mystery chests come first again. Warplan / WarPigs keep the plain order.")
    e.cinder_plan:render("Cinder plan",
        "Farm mode: keep 250 cinders for a known Mystery chest you can still reach, counting what you are expected to earn before the Helltide ends. Regular chests are opened when the reserve stays, when income refills it, when you carry too many, or in the last minutes.")
    if e.cinder_plan:get() then
        e.max_carry:render("  Max carry above reserve", "Open regular chests anyway once you hold more than the reserve plus this many cinders", 1)
        e.dump_min:render("  Spend everything in the last (min)", "In the last minutes of the Helltide every affordable chest is opened", 1)
    end
    e.road_routing:render("Road routing",
        "Reach far chests along the patrol road and leave it only for the last stretch. Stuck off the road: back to the road and another way (up to 3); the way that worked is remembered.")
    e.learn:render("Learn while farming",
        "Remember chest spots, the Helltide boundary and spots where the bot got stuck (HelltideRevamped\\learned). Learned chest spots are routed to on later runs without blind exploring.")
    e.fence:render("Stay inside the Helltide",
        "Skip chests and events outside the learned Helltide area; a trip that leaves the Helltide is cancelled and not tried again at once.")
    e.event_radius:render("Event radius (m)", "Farm mode: walk to pyres / flame pillars up to this far (Warplan: 12 m)", 1)
    e.event_until_min:render("Events until minute (UTC)", "Farm mode: start legacy events only before this minute (Warplan: 45)", 1)
    e.map_pin:render("Pin the target on the map", "Put the game's map pin on the chest the bot is walking to")
    e.forget_zone:render("Forget learned data (this zone)",
        "Delete the learned chest spots, boundary and stuck spots of the zone you are in", 0)
    if e.forget_zone:get() then gui.request_forget = true end
    e.smart_tree:pop()
end

local function render_live_stats()
    local e = gui.elements
    if not e.live_tree:push("Live data & stats") then return end
    e.live_api:render("Live Helltide zone (internet)",
        "Off by default. Asks helltides.com (or diablo4.life) which region has the Helltide this hour and teleports there directly instead of trying the towns one by one. Only the zone is read, nothing about you is sent; one small request at a time, a few per hour. Unofficial sources: without an answer the search works as before.")
    if e.live_api:get() then
        e.live_source:render("  Source", gui.live_source,
            "helltides.com: zone and hour (checked against the clock). diablo4.life: community tracker; it currently sends no Helltide zone, and then helltides.com is asked for that hour.")
        e.live_poll_min:render("  Ask every (min)", "How often to ask while this hour's zone is still unknown", 1)
        if not has_curl() then
            render_menu_header("  This QQT build has no curl API: the option does nothing.")
        end
    end
    e.overlay:render("Stats overlay",
        "On-screen panel: Helltide timer and next chest reset, cinders per minute / hour, earned / spent / lost, chests and deaths per Helltide, session and all time")
    if e.overlay:get() then
        e.overlay_x:render("  Position X (%)", "Left edge of the panel, percent of the screen width", 1)
        e.overlay_y:render("  Position Y (%)", "Top edge of the panel, percent of the screen height", 1)
        e.overlay_rows:render("  Rows", gui.overlay_rows, "All: Helltide, session and all time. Helltide only. Compact: timer and cinders.")
    end
    e.dashboard:render("Web dashboard",
        "Writes HelltideRevamped\\dashboard\\hr_data.js. Open HelltideRevamped\\dashboard\\index.html in a browser (from disk, no internet) for live stats, map, history and performance.")
    if e.dashboard:get() then
        e.dashboard_sec:render("  Update every (s)", "How often the dashboard data file is rewritten", 1)
    end
    e.reset_alltime:render("Reset all-time stats", "Clear the all-time totals and the Helltide history", 0)
    if e.reset_alltime:get() then gui.request_reset_stats = true end
    e.live_tree:pop()
end

function gui.render()
    clamp_combo(gui.elements.mode, gui.mode)
    clamp_combo(gui.elements.town, gui.town)
    clamp_combo(gui.elements.kill_monsters_rarity, gui.kill_rarity)
    clamp_combo(gui.elements.live_source, gui.live_source) -- QQT_Warpigz_v3
    clamp_combo(gui.elements.overlay_rows, gui.overlay_rows) -- QQT_Warpigz_v3
    if not gui.elements.main_tree:push("Z | Helltide Revamped | Letrico | " .. version) then return end

    gui.elements.main_toggle:render("Enable", "Enable the bot")
    gui.elements.mode:render("Mode", gui.mode,
        "Warplan: farm cinders, open chests as soon as affordable and keep moving (no ruptures, maiden or chaos rifts).\n" ..
        "Farm: Pandemonium ruptures first, then chests when cinders suffice, else monsters, until the helltide ends.\n" ..
        "When WarPigs (or any plugin) enables Helltide the mode is always Warplan.")
    if gui.elements.mode:get() == 1 then render_ruptures() end

    if gui.elements.settings_tree:push("Settings") then
        gui.elements.manage_orbwalker:render("Manage orbwalker", "When enabled, this script will toggle orbwalker clear during helltide tasks. Off by default — leaves orbwalker fully under your rotation's control.")
        gui.elements.town:render("Idle town", gui.town, "Town to teleport to between helltides and after Batmobile gives up. Match this to your Alfred town setting to avoid bouncing.")
        gui.elements.salvage_toggle:render("Salvage with alfred", "Enable salvaging items with alfred")
        gui.elements.silent_chest_toggle:render("Open Silent Chest (key required)", "Open silent chest")
        gui.elements.helltide_chest_toggle:render("Open Helltide Chest", "Open helltide chest")
        render_cinder_run() -- QQT_Warpigz_v3 (Q4)
        gui.elements.ore_toggle:render("Collect Ore", "Collect ore")
        gui.elements.herb_toggle:render("Collect Herb", "Collect herb")
        gui.elements.shrine_toggle:render("Use Shrine", "Use shrine")
        gui.elements.goblin_toggle:render("Chase goblin", "Chase goblin")
        gui.elements.event_toggle:render("Do events (flame pillar/ravenous soul)", "Do events")
        gui.elements.chaos_rift_toggle:render("Do chaos rift (Farm mode only)", "Do chaos rift. Ignored in Warplan mode and whenever WarPigs drives Helltide.")
        gui.elements.prioritize_traversals_toggle:render("Prioritize Traversals", "Move to nearby traversals (ladders/portals) before kill monsters; blacklists unreachable ones for 30s")
        gui.elements.kill_monsters_toggle:render("Kill Monsters", "Navigate to and kill nearby monsters while exploring")
        if gui.elements.kill_monsters_toggle:get() then
            gui.elements.kill_monsters_rarity:render("  Rarity floor", gui.kill_rarity, "Only route to monsters of this rarity or higher. 'All' = include normal trash, 'Rare+' = elites and up, 'Champion+' = champions and bosses, 'Boss only' = bosses.")
        end
        gui.elements.experimental_explorer_toggle:render("Experimental Explorer", "Zone-wide grid coverage instead of Batmobile frontier. Tracks chest locations across the full helltide hour. Resets only when helltide ends.")
        gui.elements.farm_cinder_threshold:render("Farm Cinder Threshold (beta)", "Stay near a remembered chest and kill monsters when you are within this many cinders of affording it (0 = disabled)")
        gui.elements.do_maiden_toggle:render("Do Maiden (Farm mode only)", "Walk to the maiden altar, insert hearts (up to 3) and stay pinned to fight the maiden. Requires Helltide Coin Hearts in your inventory. Ignored in Warplan mode and whenever WarPigs drives Helltide.")
        if gui.elements.do_maiden_toggle:get() then
            gui.elements.maiden_disable_cinders:render("Disable Maiden at Cinders", "Stop running maiden once you reach this cinder count (0 = never disable). Useful so the bot can spend cinders before saving more for chests.", 1)
        end
        gui.elements.settings_tree:pop()
    end

    render_smart_farm() -- QQT_Warpigz_v3
    render_live_stats() -- QQT_Warpigz_v3

    if gui.elements.debug_tree:push("Debug settings") then
        gui.elements.draw_chest_status:render("Draw chest status", "Draw tracked chest labels and log scan counts every 5 seconds plus unrecognized Helltide skins once per session")
        gui.elements.debug_tree:pop()
    end

    gui.elements.main_tree:pop()
end

return gui