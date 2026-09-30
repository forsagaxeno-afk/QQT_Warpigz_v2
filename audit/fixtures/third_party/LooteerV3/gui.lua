local plugin_label   = "LooteerV3"
local plugin_version = "1.5.0"
local plugin_author  = "Magoogle"
local gui = {}
local ItemFilter = require("core.item_filter")
local Updater    = require("core.updater")

-- Track the previous frame's state of the reload checkbox so we trigger
-- load_catalog only on the false->true transition (one reload per click)
-- rather than every frame the box is checked.
local _last_reload_state = false
local _last_dump_affixes_state = false
local _last_dump_currency_state = false

-- Dropdown labels. The combo's index is translated to the actual runtime
-- rarity threshold by Settings.update (see core/settings.lua).
local RARITIES  = { "Common", "Magic", "Rare", "Legendary", "Unique" }
-- Charms can drop at Set tier (Talisman_Charm_Set_*); other categories
-- can't, so the Set entry only appears in the charm dropdown.
local CHARM_RARITIES = { "Common", "Magic", "Rare", "Legendary", "Unique", "Set" }
local FISH_RARITIES  = { "Common", "Magic", "Rare", "Legendary" }
local BEHAVIORS = { "Always", "Orbwalk" }

gui.elements = {
    main_tree   = tree_node:new(0),
    main_toggle = checkbox:new(false, get_hash(plugin_label .. "_main_toggle")),

    -- Click-to-reload catalog. Acts like a button: when checked, we trigger
    -- a reload and immediately reset to false on the next frame.
    reload_catalog_toggle = checkbox:new(false, get_hash(plugin_label .. "_reload_catalog_toggle")),
    web_config_toggle     = checkbox:new(false, get_hash(plugin_label .. "_web_config_toggle")),
    ingame_loot_filter_toggle = checkbox:new(false, get_hash(plugin_label .. "_ingame_loot_filter_toggle")),

    general = {
        tree                    = tree_node:new(1),
        behavior_combo          = combo_box:new(0, get_hash(plugin_label .. "_behavior_combo")),
        loot_priority_combo     = combo_box:new(0, get_hash(plugin_label .. "_loot_priority_combo")),
        rarity_combo            = combo_box:new(0, get_hash(plugin_label .. "_rarity_combo")),
        distance_slider         = slider_int:new(1, 30, 2, get_hash(plugin_label .. "_distance_slider")),
        ancestral_only_toggle   = checkbox:new(false, get_hash(plugin_label .. "_ancestral_only")),
        non_anc_uniques_toggle  = checkbox:new(false, get_hash(plugin_label .. "_non_ancestral_uniques")),
        pick_anc_normals_toggle = checkbox:new(false, get_hash(plugin_label .. "_pick_ancestral_normals")),
    },

    affix = {
        tree                             = tree_node:new(1),
        magic_greater_affix_slider       = slider_int:new(0, 2, 0, get_hash(plugin_label .. "_magic_greater_affix_slider")),
        rare_greater_affix_slider        = slider_int:new(0, 4, 0, get_hash(plugin_label .. "_rare_greater_affix_slider")),
        greater_affix_slider             = slider_int:new(0, 3, 0, get_hash(plugin_label .. "_greater_affix_slider")),
        unique_greater_affix_slider      = slider_int:new(0, 4, 0, get_hash(plugin_label .. "_unique_greater_affix_slider")),
        uber_unique_greater_affix_slider = slider_int:new(0, 4, 0, get_hash(plugin_label .. "_uber_unique_greater_affix_slider")),
        innerTree    = tree_node:new(1),
        custom_toggle= checkbox:new(false, get_hash(plugin_label .. "_custom_toggle")),
        armorsTree   = tree_node:new(1),
        jewelryTree  = tree_node:new(1),
        weaponsTree  = tree_node:new(1),
        oneHandedTree= tree_node:new(1),
        twoHandedTree= tree_node:new(1),
        offHandsTree = tree_node:new(1),
        -- armor
        legendary_helm_slider   = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_helm_slider")),
        legendary_chest_slider  = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_chest_slider")),
        legendary_gloves_slider = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_gloves_slider")),
        legendary_pants_slider  = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_pants_slider")),
        legendary_boots_slider  = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_boots_slider")),
        unique_helm_slider      = slider_int:new(0, 4, 2, get_hash(plugin_label .. "_unique_helm_slider")),
        unique_chest_slider     = slider_int:new(0, 4, 2, get_hash(plugin_label .. "_unique_chest_slider")),
        unique_gloves_slider    = slider_int:new(0, 4, 2, get_hash(plugin_label .. "_unique_gloves_slider")),
        unique_pants_slider     = slider_int:new(0, 4, 2, get_hash(plugin_label .. "_unique_pants_slider")),
        unique_boots_slider     = slider_int:new(0, 4, 2, get_hash(plugin_label .. "_unique_boots_slider")),
        -- jewelry
        legendary_amulet_slider = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_amulet_slider")),
        unique_amulet_slider    = slider_int:new(0, 4, 2, get_hash(plugin_label .. "_unique_amulet_slider")),
        legendary_ring_slider   = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_ring_slider")),
        unique_ring_slider      = slider_int:new(0, 4, 2, get_hash(plugin_label .. "_unique_ring_slider")),
        -- offhands
        legendary_focus_slider  = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_focus_slider")),
        legendary_totem_slider  = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_totem_slider")),
        legendary_shield_slider = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_shield_slider")),
        unique_shield_slider    = slider_int:new(0, 4, 2, get_hash(plugin_label .. "_unique_shield_slider")),
        -- 1h weapons
        legendary_1h_mace_slider  = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_1h_mace_slider")),
        legendary_1h_sword_slider = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_1h_sword_slider")),
        legendary_1h_axe_slider   = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_1h_axe_slider")),
        legendary_dagger_slider   = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_dagger_slider")),
        legendary_wand_slider     = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_wand_slider")),
        unique_1h_mace_slider     = slider_int:new(0, 4, 2, get_hash(plugin_label .. "_unique_1h_mace_slider")),
        unique_1h_sword_slider    = slider_int:new(0, 4, 2, get_hash(plugin_label .. "_unique_1h_sword_slider")),
        unique_1h_axe_slider      = slider_int:new(0, 4, 2, get_hash(plugin_label .. "_unique_1h_axe_slider")),
        unique_dagger_slider      = slider_int:new(0, 4, 2, get_hash(plugin_label .. "_unique_dagger_slider")),
        unique_wand_slider        = slider_int:new(0, 4, 2, get_hash(plugin_label .. "_unique_wand_slider")),
        -- 2h weapons
        legendary_2h_mace_slider        = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_2h_mace_slider")),
        legendary_2h_sword_slider       = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_2h_sword_slider")),
        legendary_2h_axe_slider         = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_2h_axe_slider")),
        legendary_2h_polearm_slider     = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_2h_polearm_slider")),
        legendary_staff_slider          = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_staff_slider")),
        legendary_bow_slider            = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_bow_slider")),
        legendary_crossbow_slider       = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_crossbow_slider")),
        legendary_glaive_slider         = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_glaive_slider")),
        legendary_quarterstaff_slider   = slider_int:new(0, 3, 2, get_hash(plugin_label .. "_legendary_quarterstaff_slider")),
        unique_2h_mace_slider           = slider_int:new(0, 4, 2, get_hash(plugin_label .. "_unique_2h_mace_slider")),
        unique_2h_sword_slider          = slider_int:new(0, 4, 2, get_hash(plugin_label .. "_unique_2h_sword_slider")),
        unique_2h_axe_slider            = slider_int:new(0, 4, 2, get_hash(plugin_label .. "_unique_2h_axe_slider")),
        unique_2h_polearm_slider        = slider_int:new(0, 4, 2, get_hash(plugin_label .. "_unique_2h_polearm_slider")),
        unique_staff_slider             = slider_int:new(0, 4, 2, get_hash(plugin_label .. "_unique_staff_slider")),
        unique_bow_slider               = slider_int:new(0, 4, 2, get_hash(plugin_label .. "_unique_bow_slider")),
        unique_crossbow_slider          = slider_int:new(0, 4, 2, get_hash(plugin_label .. "_unique_crossbow_slider")),
        unique_glaive_slider            = slider_int:new(0, 4, 2, get_hash(plugin_label .. "_unique_glaive_slider")),
        unique_quarterstaff_slider      = slider_int:new(0, 4, 2, get_hash(plugin_label .. "_unique_quarterstaff_slider")),
    },

    types = {
        tree                  = tree_node:new(1),
        -- Per-type opt-out toggles
        quest_toggle          = checkbox:new(false, get_hash(plugin_label .. "_quest_toggle")),
        crafting_toggle       = checkbox:new(false, get_hash(plugin_label .. "_crafting_toggle")),
        boss_toggle           = checkbox:new(false, get_hash(plugin_label .. "_boss_toggle")),
        sigil_toggle          = checkbox:new(false, get_hash(plugin_label .. "_sigil_toggle")),
        compass_toggle        = checkbox:new(false, get_hash(plugin_label .. "_compass_toggle")),
        rune_toggle           = checkbox:new(false, get_hash(plugin_label .. "_rune_toggle")),
        cinders_toggle        = checkbox:new(false, get_hash(plugin_label .. "_cinders_toggle")),
        tribute_toggle        = checkbox:new(false, get_hash(plugin_label .. "_tribute_toggle")),
        scroll_toggle         = checkbox:new(false, get_hash(plugin_label .. "_scroll_toggle")),
        event_toggle          = checkbox:new(true,  get_hash(plugin_label .. "_event_toggle")),
        goblin_cache_toggle   = checkbox:new(true,  get_hash(plugin_label .. "_goblin_cache_toggle")),
        obols_toggle          = checkbox:new(true,  get_hash(plugin_label .. "_obols_toggle")),
        heavenly_sigil_toggle = checkbox:new(false, get_hash(plugin_label .. "_heavenly_sigil_toggle")),
        gemstone_toggle       = checkbox:new(false, get_hash(plugin_label .. "_gemstone_toggle")),
        cache_toggle          = checkbox:new(true,  get_hash(plugin_label .. "_cache_toggle")),
        consumable_toggle     = checkbox:new(true,  get_hash(plugin_label .. "_consumable_toggle")),
        recipe_toggle         = checkbox:new(false, get_hash(plugin_label .. "_recipe_toggle")),
        trophy_toggle         = checkbox:new(false, get_hash(plugin_label .. "_trophy_toggle")),
        -- Per-type minimum-rarity combos (0 = loot any rarity)
        sigil_rarity_combo      = combo_box:new(0, get_hash(plugin_label .. "_sigil_rarity_combo")),
        compass_rarity_combo    = combo_box:new(0, get_hash(plugin_label .. "_compass_rarity_combo")),
        tribute_rarity_combo    = combo_box:new(0, get_hash(plugin_label .. "_tribute_rarity_combo")),
        rune_rarity_combo       = combo_box:new(0, get_hash(plugin_label .. "_rune_rarity_combo")),
        gemstone_rarity_combo   = combo_box:new(0, get_hash(plugin_label .. "_gemstone_rarity_combo")),
        cache_rarity_combo      = combo_box:new(0, get_hash(plugin_label .. "_cache_rarity_combo")),
        scroll_rarity_combo     = combo_box:new(0, get_hash(plugin_label .. "_scroll_rarity_combo")),
        consumable_rarity_combo = combo_box:new(2, get_hash(plugin_label .. "_consumable_rarity_combo")),
        recipe_rarity_combo     = combo_box:new(0, get_hash(plugin_label .. "_recipe_rarity_combo")),
        crafting_rarity_combo   = combo_box:new(0, get_hash(plugin_label .. "_crafting_rarity_combo")),
    },

    -- "Always loot" categories — V2 hardcoded these as forced-loot. V3
    -- exposes them as opt-outs so users can stop picking up keys, glyphs,
    -- xp motes, etc. on alts where they don't care.
    always = {
        tree                     = tree_node:new(1),
        uber_toggle              = checkbox:new(true, get_hash(plugin_label .. "_uber_toggle")),
        keys_toggle              = checkbox:new(true, get_hash(plugin_label .. "_keys_toggle")),
        xp_powerup_toggle        = checkbox:new(true, get_hash(plugin_label .. "_xp_powerup_toggle")),
        glyph_drop_toggle        = checkbox:new(true, get_hash(plugin_label .. "_glyph_drop_toggle")),
        misc_trinkets_toggle     = checkbox:new(true, get_hash(plugin_label .. "_misc_trinkets_toggle")),
        boss_drops_toggle        = checkbox:new(true, get_hash(plugin_label .. "_boss_drops_toggle")),
        boss_drops_rarity_combo  = combo_box:new(0,   get_hash(plugin_label .. "_boss_drops_rarity_combo")),
        class_powerup_toggle     = checkbox:new(false, get_hash(plugin_label .. "_class_powerup_toggle")),
    },

    charm = {
        tree                = tree_node:new(1),
        toggle              = checkbox:new(false, get_hash(plugin_label .. "_charm_toggle")),
        rarity_combo        = combo_box:new(0,    get_hash(plugin_label .. "_charm_rarity_combo")),
        ga_slider           = slider_int:new(0, 3, 0, get_hash(plugin_label .. "_charm_ga_slider")),
        ingame_filter_toggle= checkbox:new(false, get_hash(plugin_label .. "_charm_ingame_filter")),
    },

    cube = {
        tree        = tree_node:new(1),
        toggle      = checkbox:new(false, get_hash(plugin_label .. "_cube_toggle")),
        rarity_combo= combo_box:new(0,    get_hash(plugin_label .. "_cube_rarity_combo")),
    },

    seal = {
        tree        = tree_node:new(1),
        toggle      = checkbox:new(false, get_hash(plugin_label .. "_seal_toggle")),
        rarity_combo= combo_box:new(0,    get_hash(plugin_label .. "_seal_rarity_combo")),
    },

    fish = {
        tree        = tree_node:new(1),
        toggle      = checkbox:new(false, get_hash(plugin_label .. "_fish_toggle")),
        rarity_combo= combo_box:new(0,    get_hash(plugin_label .. "_fish_rarity_combo")),
    },

    crafting_mats = {
        tree                       = tree_node:new(1),
        skip_obols_toggle          = checkbox:new(false, get_hash(plugin_label .. "_skip_obols")),
        skip_baleful_toggle        = checkbox:new(false, get_hash(plugin_label .. "_skip_baleful")),
        skip_obducite_toggle       = checkbox:new(false, get_hash(plugin_label .. "_skip_obducite")),
        skip_veiled_crystal_toggle = checkbox:new(false, get_hash(plugin_label .. "_skip_veiled_crystal")),
        skip_rawhide_toggle        = checkbox:new(false, get_hash(plugin_label .. "_skip_rawhide")),
        skip_forgotten_soul_toggle = checkbox:new(false, get_hash(plugin_label .. "_skip_forgotten_soul")),
    },

    debug = {
        tree                  = tree_node:new(1),
        draw_wanted_toggle    = checkbox:new(false, get_hash(plugin_label .. "_draw_wanted_toggle")),
        scan_items_toggle     = checkbox:new(false, get_hash(plugin_label .. "_scan_items_toggle")),
        draw_path_toggle      = checkbox:new(false, get_hash(plugin_label .. "_draw_path_toggle")),
        dump_affixes_toggle   = checkbox:new(false, get_hash(plugin_label .. "_dump_affixes_toggle")),
        dump_currency_toggle  = checkbox:new(false, get_hash(plugin_label .. "_dump_currency_toggle")),
    },
}

-- Read the timestamp Updater.bat writes to data/last_sync.lua on every
-- successful fetch. This is the actual sync time, independent of when
-- Lua last reloaded the catalog into memory.
--
-- We deliberately bypass require() — package.loaded caching in QQT was
-- pinning the value to the first load. io.open + regex on the raw file
-- gives us a fresh read every time. Cached at the Lua level for 5s so
-- we don't stat the filesystem on every render frame.
local _sync_cache = nil
local _sync_check_at = 0

local function _last_sync_epoch()
    local now = os.time()
    if now - _sync_check_at < 5 then return _sync_cache end
    _sync_check_at = now

    -- Resolve the path the same way require() would, but io.open it
    -- ourselves so we always get the file content as it is on disk.
    local path = package.searchpath and package.searchpath("data.last_sync", package.path)
    local epoch = nil
    if path then
        local f = io.open(path, "r")
        if f then
            local content = f:read("*a") or ""
            f:close()
            epoch = tonumber(content:match("return%s+(%-?%d+)"))
        end
    end
    _sync_cache = epoch
    return epoch
end

local function _sync_age_str()
    local t = _last_sync_epoch()
    if not t then return "never synced" end
    local age = os.time() - t
    if age < 0      then return "synced just now"
    elseif age < 60 then return "synced just now"
    elseif age < 3600  then return "synced " .. tostring(math.floor(age / 60))   .. "m ago"
    elseif age < 86400 then return "synced " .. tostring(math.floor(age / 3600)) .. "h ago"
    else                    return "synced " .. tostring(math.floor(age / 86400)) .. "d ago"
    end
end

function gui.render()
    local e = gui.elements

    if not e.main_tree:push("LooteerV3 v" .. plugin_version .. " by " .. plugin_author) then return end

    local catalog_loaded = ItemFilter._catalog_loaded
    if catalog_loaded then
        render_menu_header("Catalog: v" .. tostring(ItemFilter._items_version)
            .. "  (" .. _sync_age_str() .. ")")
    else
        render_menu_header("!! CATALOG NOT LOADED — click Load Catalog !!")
    end

    e.main_toggle:render("Enable", "Toggles the main module on/off")

    -- Reload catalog via curl. False->true transition so it fires once per
    -- click; label shows current state including in-flight fetch.
    local catalog_btn_label = Updater._fetching_items and "Fetching..."
        or catalog_loaded and "Reload Catalog" or "Load Catalog"
    local catalog_btn_tip = "Fetch the latest items.lua from the cloud and reload "
        .. "it into memory. The catalog also auto-syncs every 60 s in the background."
    e.reload_catalog_toggle:render(catalog_btn_label, catalog_btn_tip)
    local now_reload = e.reload_catalog_toggle:get()
    if now_reload and not _last_reload_state then
        Updater.fetch_items()
        pcall(function() e.reload_catalog_toggle:set(false) end)
    end
    _last_reload_state = e.reload_catalog_toggle:get()

    -- Catalog is mandatory. Without it, hide the rest of the UI so users
    -- can't accidentally configure settings against an empty catalog and
    -- expect loot to happen.
    if not catalog_loaded then
        e.main_tree:pop()
        return
    end

    -- Web config toggle: load data/config.lua and apply over GUI settings each frame
    local Settings = require("core.settings")
    local was_web = Settings._web_config ~= nil
    e.web_config_toggle:render("Use Web Config",
        "Apply loot settings from your cloud profile config. "
        .. "While enabled, settings sync live from the server every 30 seconds.")
    local want_web = e.web_config_toggle:get()
    if want_web and not was_web then
        -- Register live-update callback so every config fetch applies immediately
        Updater.web_config_active = true
        Updater.on_config_fetched = function(cfg)
            Settings._web_config = cfg
            Settings.apply_config(cfg)
        end
        -- Apply whatever is on disk right now, then the 30s tick will keep it fresh
        package.loaded["data.config"] = nil
        local ok, cfg = pcall(require, "data.config")
        if ok and type(cfg) == "table" then
            Settings._web_config = cfg
            Settings.apply_config(cfg)
            console.print("[LooteerV3] Web config active — live sync every 30s")
        else
            Settings._web_config = nil
            console.print("[LooteerV3] Web config not on disk yet — will apply on next sync.")
        end
    elseif not want_web and was_web then
        Updater.web_config_active = false
        Updater.on_config_fetched = nil
        Settings.apply_to_gui(Settings._web_config)
        Settings._web_config = nil
        console.print("[LooteerV3] Web config disabled — settings applied to GUI.")
    end

    e.ingame_loot_filter_toggle:render("Use Ingame Loot Filter (Gear)",
        "Apply the game's loot filter to equipment (weapons, armor, jewelry). "
        .. "When on, gear that the in-game filter would hide is skipped — "
        .. "use this to enforce Ancestral-only or other in-game filter rules on drops. "
        .. "Rarity and GA settings still apply as a floor.")

    if not e.main_toggle:get() then
        e.main_tree:pop()
        return
    end

    if e.general.tree:push("General Settings") then
        e.general.behavior_combo:render("Behavior", BEHAVIORS,
            "When do you want the autolooter to execute?")
        e.general.rarity_combo:render("Rarity", RARITIES,
            "Minimum rarity for the bot to consider picking up.")
        e.general.distance_slider:render("Distance", "Distance from loot to execute pickup")
        e.general.loot_priority_combo:render("Loot Priority", {"Closest First", "Best First"},
            "Select the priority for looting items")
        e.general.ancestral_only_toggle:render("Ancestral Only",
            "Only loot equipment that is ancestral. Use with the options below to fine-tune.")
        e.general.non_anc_uniques_toggle:render("Non-Ancestral Uniques",
            "When Ancestral Only is on, still loot unique-tier items even if they are not ancestral.")
        e.general.pick_anc_normals_toggle:render("Pick Ancestral Bases",
            "Loot ancestral normal-tier (base rarity) items regardless of your rarity threshold.")
        e.general.tree:pop()
    end

    if e.affix.tree:push("Affix Settings") then
        e.affix.magic_greater_affix_slider:render("Magic GA Count",
            "Minimum GAs to consider picking up magic items (0 = ignore GA)")
        e.affix.rare_greater_affix_slider:render("Rare GA Count",
            "Minimum GAs to consider picking up rare items (0 = ignore GA)")
        e.affix.greater_affix_slider:render("Legendary GA Count",
            "Minimum GAs to consider picking up legendaries")
        e.affix.unique_greater_affix_slider:render("Unique GA Count",
            "Minimum GAs to consider picking up uniques")
        e.affix.uber_unique_greater_affix_slider:render("Uber GA Count",
            "Minimum GAs to consider picking up uber uniques")
        if e.affix.innerTree:push("Advanced Settings") then
            e.affix.custom_toggle:render("Force Per-Slot Settings",
                "Use the per-slot GA thresholds below instead of the global Legendary/Unique counts")
            if e.affix.armorsTree:push("Armor") then
                e.affix.legendary_helm_slider:render("Legendary Helm GA",   "Min GAs for legendary helms")
                e.affix.legendary_chest_slider:render("Legendary Chest GA", "Min GAs for legendary chests")
                e.affix.legendary_gloves_slider:render("Legendary Gloves GA","Min GAs for legendary gloves")
                e.affix.legendary_pants_slider:render("Legendary Pants GA", "Min GAs for legendary pants")
                e.affix.legendary_boots_slider:render("Legendary Boots GA", "Min GAs for legendary boots")
                e.affix.unique_helm_slider:render("Unique Helm GA",         "Min GAs for unique helms")
                e.affix.unique_chest_slider:render("Unique Chest GA",       "Min GAs for unique chests")
                e.affix.unique_gloves_slider:render("Unique Gloves GA",     "Min GAs for unique gloves")
                e.affix.unique_pants_slider:render("Unique Pants GA",       "Min GAs for unique pants")
                e.affix.unique_boots_slider:render("Unique Boots GA",       "Min GAs for unique boots")
                e.affix.armorsTree:pop()
            end
            if e.affix.jewelryTree:push("Jewelry") then
                e.affix.legendary_amulet_slider:render("Legendary Amulet GA","Min GAs for legendary amulets")
                e.affix.unique_amulet_slider:render("Unique Amulet GA",      "Min GAs for unique amulets")
                e.affix.legendary_ring_slider:render("Legendary Ring GA",    "Min GAs for legendary rings")
                e.affix.unique_ring_slider:render("Unique Ring GA",          "Min GAs for unique rings")
                e.affix.jewelryTree:pop()
            end
            if e.affix.weaponsTree:push("Weapons") then
                if e.affix.oneHandedTree:push("1-Handed") then
                    e.affix.legendary_1h_mace_slider:render("Legendary 1H Mace GA",  "Min GAs for legendary 1H maces")
                    e.affix.legendary_1h_axe_slider:render("Legendary 1H Axe GA",    "Min GAs for legendary 1H axes")
                    e.affix.legendary_1h_sword_slider:render("Legendary 1H Sword GA","Min GAs for legendary 1H swords")
                    e.affix.legendary_dagger_slider:render("Legendary Dagger GA",    "Min GAs for legendary daggers")
                    e.affix.legendary_wand_slider:render("Legendary Wand GA",        "Min GAs for legendary wands")
                    e.affix.unique_1h_mace_slider:render("Unique 1H Mace GA",        "Min GAs for unique 1H maces")
                    e.affix.unique_1h_axe_slider:render("Unique 1H Axe GA",          "Min GAs for unique 1H axes")
                    e.affix.unique_1h_sword_slider:render("Unique 1H Sword GA",      "Min GAs for unique 1H swords")
                    e.affix.unique_dagger_slider:render("Unique Dagger GA",          "Min GAs for unique daggers")
                    e.affix.unique_wand_slider:render("Unique Wand GA",              "Min GAs for unique wands")
                    e.affix.oneHandedTree:pop()
                end
                if e.affix.twoHandedTree:push("2-Handed") then
                    e.affix.legendary_2h_mace_slider:render("Legendary 2H Mace GA",        "Min GAs for legendary 2H maces")
                    e.affix.legendary_2h_axe_slider:render("Legendary 2H Axe GA",          "Min GAs for legendary 2H axes")
                    e.affix.legendary_2h_sword_slider:render("Legendary 2H Sword GA",      "Min GAs for legendary 2H swords")
                    e.affix.legendary_2h_polearm_slider:render("Legendary 2H Polearm GA",  "Min GAs for legendary 2H polearms")
                    e.affix.legendary_staff_slider:render("Legendary Staff GA",            "Min GAs for legendary staves")
                    e.affix.legendary_bow_slider:render("Legendary Bow GA",                "Min GAs for legendary bows")
                    e.affix.legendary_crossbow_slider:render("Legendary Crossbow GA",      "Min GAs for legendary crossbows")
                    e.affix.legendary_glaive_slider:render("Legendary Glaive GA",          "Min GAs for legendary glaives")
                    e.affix.legendary_quarterstaff_slider:render("Legendary Quarterstaff GA","Min GAs for legendary quarterstaves")
                    e.affix.unique_2h_mace_slider:render("Unique 2H Mace GA",              "Min GAs for unique 2H maces")
                    e.affix.unique_2h_axe_slider:render("Unique 2H Axe GA",                "Min GAs for unique 2H axes")
                    e.affix.unique_2h_sword_slider:render("Unique 2H Sword GA",            "Min GAs for unique 2H swords")
                    e.affix.unique_2h_polearm_slider:render("Unique 2H Polearm GA",        "Min GAs for unique 2H polearms")
                    e.affix.unique_staff_slider:render("Unique Staff GA",                  "Min GAs for unique staves")
                    e.affix.unique_bow_slider:render("Unique Bow GA",                      "Min GAs for unique bows")
                    e.affix.unique_crossbow_slider:render("Unique Crossbow GA",            "Min GAs for unique crossbows")
                    e.affix.unique_glaive_slider:render("Unique Glaive GA",                "Min GAs for unique glaives")
                    e.affix.unique_quarterstaff_slider:render("Unique Quarterstaff GA",    "Min GAs for unique quarterstaves")
                    e.affix.twoHandedTree:pop()
                end
                if e.affix.offHandsTree:push("Off-Hands") then
                    e.affix.legendary_focus_slider:render("Legendary Focus GA",  "Min GAs for legendary focuses")
                    e.affix.legendary_totem_slider:render("Legendary Totem GA",  "Min GAs for legendary totems")
                    e.affix.legendary_shield_slider:render("Legendary Shield GA","Min GAs for legendary shields")
                    e.affix.unique_shield_slider:render("Unique Shield GA",      "Min GAs for unique shields")
                    e.affix.offHandsTree:pop()
                end
                e.affix.weaponsTree:pop()
            end
            e.affix.innerTree:pop()
        end
        e.affix.tree:pop()
    end

    if e.always.tree:push("Always-Loot Categories") then
        e.always.uber_toggle:render("Uber Uniques",
            "Pickup ubers (Tyrael's Might, Harlequin Crest, etc.). Default ON.")
        e.always.boss_drops_toggle:render("Boss Drops",
            "Pickup boss-fight world drops (Boss_Flippy, Spirit Heart). Default ON.")
        e.always.boss_drops_rarity_combo:render("  Boss Drop Rarity", RARITIES,
            "Minimum rarity for boss drops.")
        e.always.misc_trinkets_toggle:render("Misc Trinkets",
            "Pickup small misc drops (Flippy_Misc). Default ON.")
        e.always.xp_powerup_toggle:render("XP Powerups",
            "Pickup experience motes (Experience_PowerUp drops). Default ON.")
        e.always.class_powerup_toggle:render("Class Powerups",
            "Pickup class-resource ground orbs: Sorc Crackling Energy, Necro Blood Orb, "
            .. "Spiritborn Feather, Rogue Dance of Knives, Health Potion charges. "
            .. "Default OFF — most builds auto-collect these. Flip on if yours doesn't.")
        e.always.glyph_drop_toggle:render("Glyph Drops",
            "Pickup paragon glyphs that drop in nightmare dungeons. Default ON.")
        e.always.keys_toggle:render("Keys",
            "Pickup whispering / dungeon keys. Default ON.")
        e.always.tree:pop()
    end

    if e.types.tree:push("Item Types") then
        e.types.quest_toggle:render("Quest Items",
            "Pickup quest objectives and dungeon items. No rarity filter — "
            .. "quest items are looted in full when this is on.")

        e.types.boss_toggle:render("Boss Materials",
            "Pickup boss summon materials (Living Steel, lair keys, husks, etc).")
        e.types.event_toggle:render("Event Items",
            "Pickup event items (if inventory not full).")
        e.types.goblin_cache_toggle:render("Goblin Cache",
            "Pickup treasure goblin cache bags.")
        e.types.obols_toggle:render("Obols",
            "Pickup obols.")
        e.types.cinders_toggle:render("Cinders",
            "Pickup cinders.")
        e.types.heavenly_sigil_toggle:render("Heavenly Sigils",
            "Pickup heavenly sigils (if consumable inventory not full).")

        -- Categories with optional rarity filters: pair the toggle with a
        -- min-rarity combo immediately below.
        e.types.cache_toggle:render("Caches",
            "Pickup treasure / reward caches.")
        e.types.cache_rarity_combo:render("  Cache Rarity", RARITIES,
            "Minimum rarity for caches.")

        e.types.sigil_toggle:render("Nightmare Sigils",
            "Pickup nightmare dungeon sigils.")
        e.types.sigil_rarity_combo:render("  Sigil Rarity", RARITIES,
            "Minimum rarity for nightmare sigils.")

        e.types.compass_toggle:render("Horde Compasses",
            "Pickup horde compasses (BSK_Sigil).")
        e.types.compass_rarity_combo:render("  Compass Rarity", RARITIES,
            "Minimum rarity for horde compasses.")

        e.types.tribute_toggle:render("Tributes",
            "Pickup undercity tributes.")
        e.types.tribute_rarity_combo:render("  Tribute Rarity", RARITIES,
            "Minimum rarity for tributes.")

        e.types.rune_toggle:render("Runes",
            "Pickup runes (Generic_Rune_*, Socketables).")
        e.types.rune_rarity_combo:render("  Rune Rarity", RARITIES,
            "Minimum rarity for runes.")

        e.types.gemstone_toggle:render("Gemstones",
            "Pickup gems and gemstones.")
        e.types.gemstone_rarity_combo:render("  Gemstone Rarity", RARITIES,
            "Minimum rarity for gemstones.")

        e.types.trophy_toggle:render("Trophies (cosmetic)",
            "Pickup cosmetic trophy items (back trophies, mount trophies, banners). "
            .. "Default OFF — these don't affect gameplay.")

        -- Consumables — covers high-value uniques like Profane Mindcage
        -- (boss-summon stim) and other rare/legendary consumables. Default
        -- rarity gate is Legendary so you don't pick up junk potions.
        e.types.consumable_toggle:render("Consumables",
            "Pickup consumables (e.g. Profane Mindcage, Seething Opals, "
            .. "Elixirs, Incense). Skips full consumable inventories.")
        e.types.consumable_rarity_combo:render("  Consumable Rarity", RARITIES,
            "Minimum rarity for consumables. Default Rare — covers Profane "
            .. "Mindcage and the X1 elixirs/incense without grabbing every "
            .. "basic potion. Drop to Common to scoop everything.")

        e.types.tree:pop()
    end

    if e.crafting_mats.tree:push("Crafting Materials") then
        e.types.crafting_toggle:render("Crafting Materials",
            "Pickup raw crafting materials (essences, ores, horadric mats).")
        e.types.crafting_rarity_combo:render("  Crafting Rarity", RARITIES,
            "Minimum rarity for crafting materials.")

        e.types.recipe_toggle:render("Recipes / Manuals",
            "Pickup tempering manuals, books, mount items. Independent of Crafting Materials.")
        e.types.recipe_rarity_combo:render("  Recipe Rarity", RARITIES,
            "Minimum rarity for recipes/manuals.")

        e.types.scroll_toggle:render("Scrolls",
            "Pickup scrolls (Scroll_Of_*).")
        e.types.scroll_rarity_combo:render("  Scroll Rarity", RARITIES,
            "Minimum rarity for scrolls. Set to Common to loot all.")

        render_menu_header("Skip specific materials (overrides above toggles)")
        e.crafting_mats.skip_obols_toggle:render("Disable Obols",
            "Never loot murmuring obols regardless of other settings.")
        e.crafting_mats.skip_baleful_toggle:render("Disable Baleful Fragments",
            "Never loot Baleful Fragments.")
        e.crafting_mats.skip_obducite_toggle:render("Disable Obducite",
            "Never loot Obducite.")
        e.crafting_mats.skip_veiled_crystal_toggle:render("Disable Veiled Crystals",
            "Never loot Veiled Crystals.")
        e.crafting_mats.skip_rawhide_toggle:render("Disable Rawhide",
            "Never loot Rawhide.")
        e.crafting_mats.skip_forgotten_soul_toggle:render("Disable Forgotten Souls",
            "Never loot Forgotten Souls.")
        e.crafting_mats.tree:pop()
    end

    if e.charm.tree:push("Charm Settings") then
        e.charm.toggle:render("Pickup Charms",
            "Enable pickup of charms (Generic_Charm_*).")
        e.charm.rarity_combo:render("Charm Rarity", CHARM_RARITIES,
            "Minimum rarity for charms. Independent of the General Rarity setting. "
            .. "Charms specifically can drop at Set tier (green).")
        e.charm.ga_slider:render("Charm GA Count",
            "Minimum GAs to consider picking up a charm (0 = no GA requirement).")
        e.charm.ingame_filter_toggle:render("Use Ingame Loot Filter",
            "Apply the game's loot filter to charms/talismans. "
            .. "Use this to enforce Ancestral-only charm rules via the in-game filter.")
        e.charm.tree:pop()
    end

    if e.cube.tree:push("Cube Item Settings") then
        e.cube.toggle:render("Pickup Cube Items",
            "Enable pickup of Horadric Cube items (HoradricCube_*).")
        e.cube.rarity_combo:render("Cube Rarity", RARITIES,
            "Minimum rarity for cube items.")
        e.cube.tree:pop()
    end

    if e.seal.tree:push("Seal Settings") then
        e.seal.toggle:render("Pickup Seals",
            "Enable pickup of Talisman Seals (Talisman_Seal_*).")
        e.seal.rarity_combo:render("Seal Rarity", RARITIES,
            "Minimum rarity for seals.")
        e.seal.tree:pop()
    end

    if e.fish.tree:push("Fish Settings") then
        e.fish.toggle:render("Pickup Fish",
            "Enable pickup of fishing items.")
        e.fish.rarity_combo:render("Fish Rarity", FISH_RARITIES,
            "Minimum rarity to loot. Unique (Mythic) fish are always looted when enabled.")
        e.fish.tree:pop()
    end

    if e.debug.tree:push("Debug") then
        e.debug.draw_wanted_toggle:render("Draw Wanted Items",
            "Draw circles on items the bot considers picking up.")
        e.debug.scan_items_toggle:render("Scan Items",
            "Print skin / rarity / sno_id / category of all nearby items to console and screen.")
        e.debug.draw_path_toggle:render("Draw Path / Target",
            "Show the pathfinder's current target marker and pathing nodes on screen. "
            .. "Off by default — only useful for debugging movement issues.")
        e.debug.dump_affixes_toggle:render("Dump Ground Item Affixes",
            "One-shot click: prints get_affixes() output for every ground item "
            .. "actors_manager can see, so we can confirm whether affix data is "
            .. "readable on drops before pickup. Resets after firing.")
        local now_dump = e.debug.dump_affixes_toggle:get()
        if now_dump and not _last_dump_affixes_state then
            local Utils = require("utils.utils")
            local items = actors_manager:get_all_items()
            local sorted = {}
            for _, it in pairs(items) do sorted[#sorted+1] = it end
            table.sort(sorted, function(a, b) return Utils.distance_to(a) < Utils.distance_to(b) end)
            console.print("[LooteerV3 Affix Dump] === BEGIN (" .. tostring(#sorted) .. " ground items) ===")
            for _, item in ipairs(sorted) do
                local info = item:get_item_info()
                local skin   = (info and info:get_skin_name()) or "?"
                local rarity = (info and info:get_rarity())    or -1
                local sno    = (info and info:get_sno_id())    or 0
                local cat    = ItemFilter.classify(item) or "-"
                local dist   = Utils.distance_to(item)
                console.print(string.format("[Affix Dump] %s | r=%d | id=%d | cat=%s | dist=%.1f",
                    tostring(skin), rarity, sno, tostring(cat), dist))

                local ok, affixes = pcall(function() return item:get_affixes() end)
                if not ok then
                    console.print("  get_affixes() ERROR: " .. tostring(affixes))
                elseif affixes == nil then
                    console.print("  get_affixes() returned nil")
                elseif type(affixes) ~= "table" then
                    console.print("  get_affixes() returned " .. type(affixes) .. " = " .. tostring(affixes))
                else
                    local n = 0
                    for _ in pairs(affixes) do n = n + 1 end
                    console.print("  get_affixes() count: " .. tostring(n))
                    for i, affix in pairs(affixes) do
                        local hash = (type(affix) == "table" and (affix.affix_name_hash or affix.sno_id or affix.id)) or "?"
                        local name_ok, name = pcall(function() return affix:get_name() end)
                        local roll_ok, roll = pcall(function() return affix:get_roll() end)
                        local rmax_ok, rmax = pcall(function() return affix:get_roll_max() end)
                        local rmin_ok, rmin = pcall(function() return affix:get_roll_min() end)
                        console.print(string.format("    [%s] hash=%s name=%s roll=%s range=[%s..%s]",
                            tostring(i), tostring(hash),
                            name_ok and tostring(name) or "ERR",
                            roll_ok and tostring(roll) or "ERR",
                            rmin_ok and tostring(rmin) or "ERR",
                            rmax_ok and tostring(rmax) or "ERR"))
                    end
                end
            end
            console.print("[LooteerV3 Affix Dump] === END ===")
            pcall(function() e.debug.dump_affixes_toggle:set(false) end)
        end
        _last_dump_affixes_state = e.debug.dump_affixes_toggle:get()

        e.debug.dump_currency_toggle:render("Dump Currencies",
            "One-shot click: calls all known currency globals and probes speculative "
            .. "crafting-material getters so we can find dedicated count functions.")
        local now_dump_cur = e.debug.dump_currency_toggle:get()
        if now_dump_cur and not _last_dump_currency_state then
            console.print("[LooteerV3 Currency Dump] === Known currency globals ===")
            local known = {
                { "aether",           get_aether_count },
                { "helltide_cinders", get_helltide_coin_cinders },
                { "helltide_hearts",  get_helltide_coin_hearts },
            }
            for _, entry in ipairs(known) do
                local nm, fn = entry[1], entry[2]
                local ok, val = pcall(fn)
                console.print(string.format("  %-28s = %s", nm,
                    ok and tostring(val) or ("ERR: " .. tostring(val))))
            end

            console.print("[LooteerV3 Currency Dump] === Speculative crafting getters ===")
            local probes = {
                "get_obducite_count", "get_baleful_fragment_count",
                "get_forgotten_soul_count", "get_iron_chunks_count",
                "get_rawhide_count", "get_veiled_crystal_count",
                "get_abstruse_sigil_count", "get_angelbreath_count",
                "get_fiend_rose_count", "get_gallowvine_count",
                "get_crushed_beast_bone_count", "get_gold_count",
                "get_gold", "get_murmuring_obols_count",
            }
            for _, fname in ipairs(probes) do
                local fn = _G[fname]
                if fn then
                    local ok, val = pcall(fn)
                    console.print(string.format("  %-42s = %s", fname,
                        ok and tostring(val) or ("ERR: " .. tostring(val))))
                else
                    console.print(string.format("  %-42s (not in _G)", fname))
                end
            end

            -- Also try player:get_currency() — exists on game.item_data, may exist on player too
            local player = get_local_player()
            if player then
                local ok, val = pcall(function() return player:get_currency() end)
                console.print("[player:get_currency()] = " .. (ok and tostring(val) or ("ERR: " .. tostring(val))))
            end

            console.print("[LooteerV3 Currency Dump] === END ===")
            pcall(function() e.debug.dump_currency_toggle:set(false) end)
        end
        _last_dump_currency_state = e.debug.dump_currency_toggle:get()

        e.debug.tree:pop()
    end

    e.main_tree:pop()
end

return gui
