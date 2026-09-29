local gui = {}
local tracker = require "core.tracker" -- QQT_Warpigz_v3: tracker.hr_external (WarPigs drives: Warplan)
local version = "v2.6.4"
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
gui.overlay_rows = { "All", "Helltide only", "Timers + cinders" } -- QQT_Warpigz_v3: same indices
-- QQT_Warpigz_v3: overlay appearance (core/hr_overlay.lua uses the indices).
gui.overlay_anchor = { "Top left", "Top right", "Bottom left", "Bottom right" }
gui.overlay_theme = { "Bright", "Classic", "Minimal" }
gui.overlay_columns = { "One column", "Two columns" }
gui.overlay_accent = { "Cyan", "Gold", "Green", "Red", "Purple", "White" }
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
    -- QQT_Warpigz_v3: shown in Smart farm (the "Tears (Farm mode)" tree is gone).
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
    debug_log_toggle = create_checkbox(false, plugin_label .. "debug_log"), -- QQT_Warpigz_v3 2.6.4
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
    -- QQT_Warpigz_v3 (Q4): cinder run. 'cinder_run' is the Warplan / WarPigs
    -- option "Spend cinders on chests at" (id and default unchanged).
    cinder_run = create_checkbox(false, plugin_label .. "cinder_run"),
    -- QQT_Warpigz_v3: Smart farm goal (Farm mode): "Farm cinders until N,
    -- then open chests". A new id, on by default: the goal IS the cinder run
    -- in Farm mode (core/hr_cinder_run.lua on()); the amount is the shared
    -- run threshold 'cinder_run_at' (same meaning in both modes, the stored
    -- value is kept; default 3000 -> 2000, the amount the Farm flow aims at).
    farm_goal = create_checkbox(true, plugin_label .. "farm_goal"),
    cinder_run_at = slider_int:new(250, 10000, 2000, get_hash(plugin_label .. "_cinder_run_at")),
    advanced_tree = tree_node:new(2), -- QQT_Warpigz_v3: Smart farm > Advanced
    forget_zone = button:new(get_hash(plugin_label .. "_forget_zone")),
    -- QQT_Warpigz_v3: live data & stats.
    live_tree = tree_node:new(1),
    live_api = create_checkbox(false, plugin_label .. "live_api"),
    live_source = combo_box:new(0, get_hash(plugin_label .. "_live_source")),
    live_poll_min = slider_int:new(2, 15, 5, get_hash(plugin_label .. "_live_poll_min")),
    overlay = create_checkbox(true, plugin_label .. "overlay"),
    overlay_rows = combo_box:new(0, get_hash(plugin_label .. "_overlay_rows")),
    -- QQT_Warpigz_v3: overlay appearance (new ids; the old Position X / Y ids
    -- "_overlay_x" / "_overlay_y" are no longer read).
    overlay_tree = tree_node:new(2),
    overlay_anchor = combo_box:new(0, get_hash(plugin_label .. "_overlay_anchor")),
    overlay_pos_x = slider_int:new(0, 60, 1, get_hash(plugin_label .. "_overlay_pos_x")),
    overlay_pos_y = slider_int:new(0, 90, 3, get_hash(plugin_label .. "_overlay_pos_y")),
    overlay_font = slider_int:new(10, 28, 15, get_hash(plugin_label .. "_overlay_font")),
    overlay_columns = combo_box:new(1, get_hash(plugin_label .. "_overlay_columns")),
    overlay_width = slider_int:new(0, 900, 0, get_hash(plugin_label .. "_overlay_width")),
    overlay_bg = slider_int:new(0, 70, 25, get_hash(plugin_label .. "_overlay_bg")),
    overlay_theme = combo_box:new(0, get_hash(plugin_label .. "_overlay_theme")),
    overlay_accent = combo_box:new(0, get_hash(plugin_label .. "_overlay_accent")),
    overlay_bars = create_checkbox(true, plugin_label .. "overlay_bars"),
    overlay_compact = create_checkbox(false, plugin_label .. "overlay_compact"),
    overlay_show_timer = create_checkbox(true, plugin_label .. "overlay_show_timer"),
    overlay_show_wave = create_checkbox(true, plugin_label .. "overlay_show_wave"),
    overlay_show_cinders = create_checkbox(true, plugin_label .. "overlay_show_cinders"),
    overlay_show_now = create_checkbox(true, plugin_label .. "overlay_show_now"),
    overlay_show_target = create_checkbox(true, plugin_label .. "overlay_show_target"),
    overlay_show_stats = create_checkbox(true, plugin_label .. "overlay_show_stats"),
    overlay_show_opened = create_checkbox(true, plugin_label .. "overlay_show_opened"),
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

-- QQT_Warpigz_v3: Warplan / WarPigs: the cinder run option (Settings,
-- Warplan mode only; Farm mode has the Smart farm goal instead).
local function render_cinder_run()
    local e = gui.elements
    e.cinder_run:render("Spend cinders on chests at",
        "Warplan mode (and WarPigs). Off by default. On: holding at least this many cinders starts a chest run: Hell's Prize first (666, War Plan node Hell's Prize), then Mystery chests (250), then the rest nearest first, using the chests in sight, remembered and learned spots. The run ends when the cinders fall below the cheapest known chest. Manual Warplan: below the amount no Helltide chest is opened (they are remembered; the last minutes of the Helltide spend the savings). Under WarPigs nothing is saved: its Helltide step ends once its War Plan cinders are spent. Hell's Prize chests are opened only by this run. Requires Open Helltide Chest.")
    if e.cinder_run:get() then
        e.cinder_run_at:render("  Cinders", "Start the chest run at this many cinders", 1)
        -- QQT_Warpigz_v3: the save phase's end (core/hr_cinder_run.lua
        -- dump_minutes) was set in the Smart farm tree, which Warplan no
        -- longer shows; kept reachable here.
        e.dump_min:render("  Spend all in the last (min)",
            "In the last minutes of the Helltide the cinders held are spent on chests in the run order, even below the amount (at least 2 min)", 1)
    end
end

-- QQT_Warpigz_v3: probed only while the live option is shown (reading an
-- absent host global is harmless but noisy on some hosts).
local function has_curl()
    local c = curl
    return type(c) == "table" and type(c.http_get) == "function"
end

-- QQT_Warpigz_v3: Farm mode, one section in the order of the Helltide flow:
-- 1. the goal (farm cinders, then the chest run), 2. how to farm (tears
-- first), 3. movement and logic, then the tuning sliders under Advanced.
local function header(text)
    if type(render_menu_header) == "function" then render_menu_header(text) end
end

local function render_advanced()
    local e = gui.elements
    if not e.advanced_tree:push("Advanced") then return end
    e.tear_search_dist:render("Tear search distance",
        "How far the bot looks for tears (ritual rings, rupture stones, open tears) while patrolling or fighting. Higher finds more tears, lower keeps it on the road.", 5)
    e.tear_passby_dist:render("Pass-by distance",
        "While it walks to a chest the bot only turns aside for a tear this close", 1)
    e.tear_event_radius:render("Ritual stay radius",
        "While closing tears the bot stays within this distance of the ritual", 1)
    e.tear_circle_radius:render("Hold-area tolerance",
        "How far the bot may drift from the ritual circle centre before it walks back", 1)
    e.rupture_linger_sec:render("Linger after last tear",
        "Seconds the bot stays in the ring after the last tear is gone (more kills, rupture rewards)", 1)
    e.rupture_rw_wait_sec:render("Realmwalker wait (sec)",
        "How long the bot waits for the Realmwalker to spawn after the tears (Fight Realmwalker)", 1)
    e.rupture_max_cinders:render("Pause tears at cinders",
        "0 = off (recommended: the goal already stops new tears while the chest run has a chest to go to). Otherwise no NEW tear is started once you hold this many cinders; a tear in progress is finished.", 1)
    e.max_carry:render("Max carry above reserve",
        "Goal off only: with 'Keep 250 for a Mystery chest', regular chests are opened anyway once you hold more than 250 plus this many cinders", 1)
    e.event_radius:render("Event radius (m)",
        "Legacy events (pyres / flame pillars) only: walk to one up to this far. Only used when 'Skip legacy Helltide events' is off or tears are not hunted (Warplan: 12 m)", 1)
    e.event_until_min:render("Events until minute (UTC)",
        "Legacy events only: start one only before this minute of the hour (Warplan: 45)", 1)
    e.advanced_tree:pop()
end

local function render_smart_farm()
    local e = gui.elements
    if not e.smart_tree:push("Smart farm") then return end
    header("1. Goal: farm cinders, then open chests")
    e.farm_goal:render("Farm cinders until",
        "On by default. Below this many cinders the bot only farms (tears first) and opens no Helltide chest: the chests it sees are remembered and learned. At the goal it goes to open chests: Hell's Prize (666) > Mystery (250) > the rest nearest first, along the road, then farms again until the goal. In the last minutes of the Helltide it spends whatever it holds, so no cinders are lost. Off: chests are opened as soon as they are affordable (the old way). Requires Open Helltide Chest.")
    if e.farm_goal:get() then
        e.cinder_run_at:render("  Cinders", "The goal: the chest run starts at this many cinders (default 2000)", 1)
        e.dump_min:render("  Spend all in the last (min)",
            "In the last minutes of the Helltide every cinder is spent on chests, even below the goal (at least 2 min)", 1)
    else
        e.cinder_plan:render("Keep 250 for a Mystery chest",
            "Goal off only. Keep 250 cinders for a known Mystery chest you can still reach (counting what you will earn before the Helltide ends); regular chests are opened when the 250 stays, when you carry too many (Advanced), or in the last minutes.")
        if e.cinder_plan:get() then
            e.dump_min:render("  Spend all in the last (min)", "In the last minutes of the Helltide every affordable chest is opened", 1)
        end
    end
    header("2. How to farm: tears first")
    e.hunt_rift_toggle:render("Hunt tears",
        "Tears are the best cinder farm: the bot goes to every tear it finds before anything else, kills the cultists, closes the golden tears, then collects the event's drops (Rosie's pickup waits until the event is over) and goes on. No tear in sight: it farms monsters along the patrol road (never parked in one spot) until the next tear shows up.") -- QQT_Warpigz_v3 (Q3, rc.2 review)
    if e.hunt_rift_toggle:get() then
        -- QQT_Warpigz_v3 (Q2): the bot stays until the tear closes.
        e.tear_use_charge_ring:render("  Stand on chargeable tears",
            "Walk onto each golden tear and stay inside its circle while your rotation kills the adds, until the tear closes (at most 90 s per tear), then the next tear.")
        e.rupture_do_realmwalker:render("  Fight Realmwalker",
            "Wait for the Realmwalker after the tears and kill it (Advanced: how long to wait)")
        e.rupture_open_chests:render("  Open tear chests",
            "Open the free Pandemonium chests in the ritual ring once the tear you stand in is closed (Helltide chests there only when the goal allows). Requires Open Helltide Chest.") -- QQT_Warpigz_v3 (Q2)
        e.rupture_replace_local_events:render("  Skip legacy Helltide events",
            "On by default: never walk to flame pillars / ravenous soul pyres, tears pay more. Off: those events are run too (Advanced: event radius and minute); tears in reach still come first.") -- QQT_Warpigz_v3 (rc.2)
    end
    header("3. Movement and logic")
    e.smart_order:render("Smart chest order",
        "Mystery chests first, chests you saw before learned (predicted) spots, nearest first along the patrol road, no ping-pong across the map. After each chest reset (UTC :00/:15/:20/:30/:40/:45) fresh Mystery chests come first again.")
    e.road_routing:render("Road routing",
        "Reach far chests along the patrol road and leave it only for the last stretch. Stuck off the road: back to the road and another way (up to 3); the way that worked is remembered.")
    e.learn:render("Learn while farming",
        "Remember chest spots, the Helltide boundary and spots where the bot got stuck (HelltideRevamped\\learned). The chest run also goes to learned chest spots.")
    e.fence:render("Stay inside the Helltide",
        "Skip chests and events outside the learned Helltide area; a trip that leaves the Helltide is cancelled and not tried again at once.")
    e.map_pin:render("Pin the target on the map", "Put the game's map pin on the chest the bot is walking to")
    e.forget_zone:render("Forget learned data (this zone)",
        "Delete the learned chest spots, boundary and stuck spots of the zone you are in", 0)
    if e.forget_zone:get() then gui.request_forget = true end
    render_advanced()
    e.smart_tree:pop()
end

-- QQT_Warpigz_v3: Live data & stats > Stats overlay > Overlay appearance.
local function render_overlay_appearance()
    local e = gui.elements
    if not e.overlay_tree:push("Overlay appearance") then return end
    e.overlay_anchor:render("Anchor", gui.overlay_anchor, "Screen corner the panel is placed from. The offsets below are measured from this corner.")
    e.overlay_pos_x:render("Offset X (%)", "Distance from the anchored left / right screen edge, percent of the screen width. The game's party frames sit at the left edge at about half the screen height: the default top-left two-column panel ends above them; a tall one-column panel is better moved right (about 13%) or to a right anchor.", 1)
    e.overlay_pos_y:render("Offset Y (%)", "Distance from the anchored top / bottom screen edge, percent of the screen height", 1)
    e.overlay_font:render("Font size", "Text size; line spacing, columns, bars and the panel size follow it", 1)
    e.overlay_columns:render("Layout", gui.overlay_columns, "One column: every section under the other. Two columns: STATS and OPENED THIS WAVE to the right of the rest, about half as tall and twice as wide.")
    e.overlay_width:render("Width (px, 0 = auto)", "Width of one column in pixels. 0: fits the text at the chosen font size. Longer texts are cut to the width.", 1)
    e.overlay_theme:render("Colors", gui.overlay_theme, "Bright: white text with a dark shadow (readable on any scene). Classic: the first overlay's softer colours. Minimal: no panel, white text in a black outline.")
    e.overlay_accent:render("Accent", gui.overlay_accent, "Colour of the section titles and the Helltide timer bar")
    if e.overlay_theme:get() ~= 2 then
        e.overlay_bg:render("Background opacity (%)", "Darkness of the panel behind the text. The game draws text beneath the panel, so a darker panel also dims the text: keep it at 40% or lower.", 1)
    end
    e.overlay_bars:render("Show bars", "Progress bars under the Helltide timer, the wave and the cinder goal")
    e.overlay_compact:render("Compact layout", "Tighter lines; drops the section titles NOW / TARGET, the per hour rate, This HT earned / spent / lost, Position and the footers")
    header("Sections") -- QQT_Warpigz_v3
    e.overlay_show_timer:render("Helltide timer", "Time left in the Helltide (or until the next one)")
    e.overlay_show_wave:render("Wave", "Chest reset wave and the next reset")
    e.overlay_show_cinders:render("Cinders", "Balance, per minute / hour, the goal")
    e.overlay_show_now:render("Now", "Activity, movement, in Helltide, plan")
    e.overlay_show_target:render("Target", "The chest the bot goes to")
    e.overlay_show_stats:render("Stats table", "This HT / Session / All time")
    e.overlay_show_opened:render("Opened this wave", "Last chests opened and how many are still to open")
    e.overlay_tree:pop()
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
        e.overlay_rows:render("  Rows", gui.overlay_rows, "All: every section, the STATS table with This HT, Session and All time. Helltide only: the STATS table shows This HT only. Timers + cinders: only the header, timers and cinders.")
        render_overlay_appearance() -- QQT_Warpigz_v3
    end
    -- QQT_Warpigz_v3 3.3.6: WarRoom (the page that showed this data) is archived and not shipped, so
    -- the tooltip no longer points to it; the optional QQT_WarRoom check below is a no-op without it.
    e.dashboard:render("Web dashboard",
        "Writes the Helltide map data file (HelltideRevamped/dashboard/hr_data.js). No viewer page ships with the suite at the moment: leave it off")
    local room = rawget(_G, 'QQT_WarRoom')
    if e.dashboard:get() or (type(room) == 'table' and room.enabled == true) then
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
    clamp_combo(gui.elements.overlay_anchor, gui.overlay_anchor) -- QQT_Warpigz_v3
    clamp_combo(gui.elements.overlay_theme, gui.overlay_theme) -- QQT_Warpigz_v3
    clamp_combo(gui.elements.overlay_columns, gui.overlay_columns) -- QQT_Warpigz_v3
    clamp_combo(gui.elements.overlay_accent, gui.overlay_accent) -- QQT_Warpigz_v3
    if not gui.elements.main_tree:push("Z | Helltide Revamped | Letrico | " .. version) then return end

    gui.elements.main_toggle:render("Enable", "Enable the bot")
    gui.elements.mode:render("Mode", gui.mode,
        "Warplan: farm cinders, open chests as soon as affordable and keep moving (no ruptures, maiden or chaos rifts).\n" ..
        "Farm: tears first and monsters along the road until the cinder goal, then a chest run (Hell's Prize > Mystery > the rest), again until the helltide ends (Smart farm).\n" ..
        "When WarPigs (or any plugin) enables Helltide the mode is always Warplan.")
    -- QQT_Warpigz_v3: the menu follows the EFFECTIVE mode (core/hr_mode.lua):
    -- an external enable (WarPigs) always runs Warplan.
    local external = tracker.hr_external == true
    local farm = gui.elements.mode:get() == 1 and not external
    if external then header("Enabled by WarPigs: Warplan mode (Smart farm is not used)") end
    if farm then render_smart_farm() end -- QQT_Warpigz_v3: one Smart farm section (Farm mode)

    if gui.elements.settings_tree:push("Settings") then
        gui.elements.manage_orbwalker:render("Manage orbwalker", "When enabled, this script will toggle orbwalker clear during helltide tasks. Off by default — leaves orbwalker fully under your rotation's control.")
        gui.elements.town:render("Idle town", gui.town, "Town to teleport to between helltides and after Batmobile gives up. Match this to your Alfred town setting to avoid bouncing.")
        gui.elements.salvage_toggle:render("Salvage with alfred", "Enable salvaging items with alfred")
        gui.elements.silent_chest_toggle:render("Open Silent Chest (key required)", "Open silent chest")
        gui.elements.helltide_chest_toggle:render("Open Helltide Chest", "Open helltide chest")
        if not farm then render_cinder_run() end -- QQT_Warpigz_v3 (Q4): Warplan; Farm has the Smart farm goal
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
        if not farm then -- QQT_Warpigz_v3: Warplan only (Farm mode ignores it: tears first, see Smart farm)
            gui.elements.farm_cinder_threshold:render("Farm Cinder Threshold (beta)", "Warplan mode only. Stay near a remembered chest and kill monsters when you are within this many cinders of affording it (0 = disabled). Farm mode never waits at a chest: it hunts tears and farms along the road until its goal.")
        end
        gui.elements.do_maiden_toggle:render("Do Maiden (Farm mode only)", "Walk to the maiden altar, insert hearts (up to 3) and stay pinned to fight the maiden. Requires Helltide Coin Hearts in your inventory. Ignored in Warplan mode and whenever WarPigs drives Helltide.")
        if gui.elements.do_maiden_toggle:get() then
            gui.elements.maiden_disable_cinders:render("Disable Maiden at Cinders", "Stop running maiden once you reach this cinder count (0 = never disable). Useful so the bot can spend cinders before saving more for chests.", 1)
        end
        if not farm then -- QQT_Warpigz_v3: the learned atlas works in every mode (Farm: Smart farm)
            gui.elements.learn:render("Learn while farming",
                "Remember chest spots, the Helltide boundary and spots where the bot got stuck (HelltideRevamped\\learned); the cinder run also goes to learned chest spots.")
            gui.elements.forget_zone:render("Forget learned data (this zone)",
                "Delete the learned chest spots, boundary and stuck spots of the zone you are in", 0)
            if gui.elements.forget_zone:get() then gui.request_forget = true end
        end
        gui.elements.settings_tree:pop()
    end

    render_live_stats() -- QQT_Warpigz_v3

    if gui.elements.debug_tree:push("Debug settings") then
        gui.elements.draw_chest_status:render("Draw chest status", "Draw tracked chest labels and log scan counts every 5 seconds plus unrecognized Helltide skins once per session")
        gui.elements.debug_log_toggle:render("Debug log", "Log the patrol, navigation and chest-walk state every 1-2 seconds ([PATROL], [NAV], [CHEST RECALL] ...). Off: only events are logged.")
        gui.elements.debug_tree:pop()
    end

    gui.elements.main_tree:pop()
end

return gui