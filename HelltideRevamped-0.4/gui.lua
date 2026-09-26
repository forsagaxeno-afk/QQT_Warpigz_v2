local gui = {}
local version = "v2.2.0"
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
    if not e.ruptures_tree:push("Pandemonium Ruptures (Farm mode)") then return end
    e.hunt_rift_toggle:render("Hunt Pandemonium Ruptures",
        "Farm mode: route to ruptures (tears) first — kill the cultists, close the golden tears, open the rupture chests, then go back to chests/monsters.")
    if e.hunt_rift_toggle:get() then
        e.rupture_replace_local_events:render("Prefer ruptures over legacy Helltide events",
            "Skip flame pillar / ravenous soul events while hunting ruptures.")
        e.rupture_prioritize_surging:render("Prioritize Surging ruptures",
            "Route to Colossal and Surging ruptures before Normal ones when several are in range.")
        e.rupture_hunt_normal:render("  Hunt Normal ruptures", "S14_Rupture_SMP_* ruptures")
        e.rupture_hunt_surging:render("  Hunt Surging ruptures", "S14_Rupture_LE_* ruptures (Realmwalker chance)")
        e.rupture_hunt_colossal:render("  Hunt Colossal ruptures", "S14_Rupture_Major_* / ZE_* ruptures")
        e.rupture_max_cinders:render("  Pause hunt at cinders",
            "Stop looking for NEW ruptures once you hold this many cinders so they get spent on chests first (0 = always hunt). A rupture already in progress is finished.", 1)
        e.tear_search_dist:render("  Search distance", "Scan this far for ritual rings, rupture gizmos and active tears", 5)
        e.tear_passby_dist:render("  Pass-by distance", "While walking to a remembered chest or farming cinders, detour for ruptures this close", 1)
        e.tear_event_radius:render("  Ritual stay radius", "Stay within this distance of the rupture anchor while closing tears", 1)
        e.tear_circle_radius:render("  Hold-area tolerance", "How far from the ritual circle centre before walking back", 1)
        e.rupture_linger_sec:render("  Linger after last tear", "Seconds to stay in the ring after the tears are gone (more kills, rupture rewards)", 1)
        e.rupture_do_realmwalker:render("  Fight Realmwalker after Surging/Colossal",
            "Wait for and kill the Realmwalker (S14_Golem_Stone_Realmwalker) after a Surging/Colossal rupture.")
        if e.rupture_do_realmwalker:get() then
            e.rupture_rw_wait_sec:render("    Realmwalker wait (sec)", "How long to wait for the Realmwalker to spawn", 1)
            e.rupture_do_deathtoll_chamber:render("    Enter Deathtoll Chamber (experimental)",
                "Use the portal after the Realmwalker dies. Leaves the helltide zone for a while; off by default.")
            if e.rupture_do_deathtoll_chamber:get() then
                e.rupture_chamber_linger_sec:render("    Chamber linger (sec)", "Stay on the tears in the chamber after they clear", 1)
            end
        end
        e.tear_use_charge_ring:render("  Stand on chargeable tears", "Walk onto golden tears and stay put while your rotation clears the adds")
        e.rupture_open_chests:render("  Open rupture chests",
            "Open Pandemonium chests (free) and affordable helltide chests inside the ritual ring. Requires Open Helltide Chest.")
        e.log_tear_candidates:render("  Log rupture scan hits", "Print matched rupture actors to the console (debug)")
    end
    e.ruptures_tree:pop()
end

function gui.render()
    clamp_combo(gui.elements.mode, gui.mode)
    clamp_combo(gui.elements.town, gui.town)
    clamp_combo(gui.elements.kill_monsters_rarity, gui.kill_rarity)
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

    if gui.elements.debug_tree:push("Debug settings") then
        gui.elements.draw_chest_status:render("Draw chest status", "Draw tracked chest labels and log scan counts every 5 seconds plus unrecognized Helltide skins once per session")
        gui.elements.debug_tree:pop()
    end

    gui.elements.main_tree:pop()
end

return gui