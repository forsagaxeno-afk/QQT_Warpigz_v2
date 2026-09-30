local gui = require("gui")

local Settings = {}

-- Translate the rarity-combo index (0..4 over Common/Magic/Rare/Legendary/
-- Unique) into the runtime rarity threshold the loot engine compares
-- against `info:get_rarity()`. The runtime values aren't sequential —
-- Magic_2 / Rare_2 occupy gaps — so each label maps to the lowest runtime
-- value that semantically counts as that tier.
local RARITY_RUNTIME = { [0] = 0, [1] = 1, [2] = 3, [3] = 5, [4] = 6 }

local function rarity_threshold(combo_idx)
    return RARITY_RUNTIME[combo_idx or 0] or 0
end

-- Charm dropdown adds Set as index 5 (Talisman_Charm_Set_* drops only show
-- up on charms). Set runtime rarity is 7 — the slot the V2 build used for
-- the Set tier between Unique and uber-uniques.
local CHARM_RARITY_RUNTIME = { [0] = 0, [1] = 1, [2] = 3, [3] = 5, [4] = 6, [5] = 7 }

local function charm_rarity_threshold(combo_idx)
    return CHARM_RARITY_RUNTIME[combo_idx or 0] or 0
end

-- Reverse maps: runtime rarity value → combo index (for apply_to_gui)
local RARITY_COMBO_IDX = {}
for idx, rt in pairs(RARITY_RUNTIME) do RARITY_COMBO_IDX[rt] = idx end

local CHARM_RARITY_COMBO_IDX = {}
for idx, rt in pairs(CHARM_RARITY_RUNTIME) do CHARM_RARITY_COMBO_IDX[rt] = idx end

Settings._web_config = nil  -- set by gui.lua when web config checkbox is enabled

-- Pathfinder settings (read by core.pathfinder)
Settings.enabled           = false
Settings.path_angle        = 20
Settings.aggresive_movement        = false
Settings.use_evade_as_movement_spell = false

-- Full loot settings
local settings = {
    enabled = false, looting = false,
    custom_toggle = false,
    behavior = 0, rarity = 0, distance = 2, loot_priority = 0,
    ancestral_only = false, non_ancestral_uniques = false, pick_ancestral_normals = false,
    magic_ga_count = 0, rare_ga_count = 0,
    ga_count = 0, unique_ga_count = 0, uber_unique_ga_count = 0,
    quest_items = false, crafting_items = false, cinders = false,
    heavenly_sigil = false, gemstone = false, boss_items = false,
    sigils = false, compass = false, rune = false, tribute = false,
    scroll = false, event_items = true, goblin_cache = true, obols = true,
    cache = true, consumable = true,  recipe = false, trophy = false,
    -- Always-loot categories (opt-out — defaults are TRUE because these are
    -- high-value; users uncheck to skip them)
    uber          = true,
    keys_loot     = true,
    xp_powerup    = true,
    glyph_drop    = true,
    misc_trinkets = true,
    boss_drops    = true,
    -- Class-resource ground pickups (Sorc Crackling Energy, Necro Blood
    -- Orb, etc.) — default OFF because most builds auto-collect these.
    -- Flip on if your build/setup doesn't.
    class_powerup = false,
    -- Per-category min-rarity thresholds (0 = loot any, >0 = min rarity to loot)
    sigil_rarity       = 0,
    compass_rarity     = 0,
    tribute_rarity     = 0,
    rune_rarity        = 0,
    gemstone_rarity    = 0,
    cache_rarity       = 0,
    scroll_rarity      = 0,
    consumable_rarity  = 3,   -- Rare (combo idx 2 → runtime rarity 3) — covers
                              -- Profane Mindcage, Seething Opals, X1 Elixirs/Incense
                              -- without scooping every basic potion.
    recipe_rarity      = 0,
    crafting_rarity    = 0,
    boss_drops_rarity  = 0,
    -- jewelry
    legendary_amulet_ga_count=0, legendary_ring_ga_count=0,
    unique_amulet_ga_count=0,    unique_ring_ga_count=0,
    -- armor
    legendary_helm_ga_count=0,  legendary_chest_ga_count=0,
    legendary_gloves_ga_count=0,legendary_pants_ga_count=0,
    legendary_boots_ga_count=0,
    unique_helm_ga_count=0,     unique_chest_ga_count=0,
    unique_gloves_ga_count=0,   unique_pants_ga_count=0,
    unique_boots_ga_count=0,
    -- offhand
    legendary_focus_ga_count=0, legendary_totem_ga_count=0,
    legendary_shield_ga_count=0,unique_shield_ga_count=0,
    -- 1h weapons
    legendary_1h_mace_ga_count=0, legendary_1h_sword_ga_count=0,
    legendary_1h_axe_ga_count=0,  legendary_dagger_ga_count=0,
    legendary_wand_ga_count=0,
    unique_1h_mace_ga_count=0,    unique_1h_sword_ga_count=0,
    unique_1h_axe_ga_count=0,     unique_dagger_ga_count=0,
    unique_wand_ga_count=0,
    -- 2h weapons
    legendary_2h_mace_ga_count=0, legendary_2h_sword_ga_count=0,
    legendary_2h_axe_ga_count=0,  legendary_2h_polearm_ga_count=0,
    legendary_staff_ga_count=0,   legendary_bow_ga_count=0,
    legendary_crossbow_ga_count=0,legendary_glaive_ga_count=0,
    legendary_quarterstaff_ga_count=0,
    unique_2h_mace_ga_count=0,    unique_2h_sword_ga_count=0,
    unique_2h_axe_ga_count=0,     unique_2h_polearm_ga_count=0,
    unique_staff_ga_count=0,      unique_bow_ga_count=0,
    unique_crossbow_ga_count=0,   unique_glaive_ga_count=0,
    unique_quarterstaff_ga_count=0,
    -- per-material skip overrides (default false = loot; true = always skip)
    skip_obols=false, skip_baleful=false, skip_obducite=false,
    skip_veiled_crystal=false, skip_rawhide=false, skip_forgotten_soul=false,
    -- special item types
    charm=false, charm_rarity=0, charm_ga_count=0, ingame_filter_charm=false,
    cube=false,  cube_rarity=0,
    seal=false,  seal_rarity=0,
    fish=false,  fish_rarity=0,
    -- ingame loot filter override
    use_ingame_loot_filter = false,
    -- debug
    draw_wanted_items=false, scan_items=false, draw_path=false,
}

function Settings.update()
    local e = gui.elements
    settings = {
        enabled      = e.main_toggle:get(),
        behavior     = e.general.behavior_combo:get(),
        rarity       = rarity_threshold(e.general.rarity_combo:get()),
        distance     = e.general.distance_slider:get(),
        loot_priority         = e.general.loot_priority_combo:get(),
        ancestral_only        = e.general.ancestral_only_toggle:get(),
        non_ancestral_uniques = e.general.non_anc_uniques_toggle:get(),
        pick_ancestral_normals= e.general.pick_anc_normals_toggle:get(),

        magic_ga_count      = e.affix.magic_greater_affix_slider:get(),
        rare_ga_count       = e.affix.rare_greater_affix_slider:get(),
        ga_count            = e.affix.greater_affix_slider:get(),
        unique_ga_count     = e.affix.unique_greater_affix_slider:get(),
        uber_unique_ga_count= e.affix.uber_unique_greater_affix_slider:get(),
        custom_toggle       = e.affix.custom_toggle:get(),

        legendary_amulet_ga_count  = e.affix.legendary_amulet_slider:get(),
        unique_amulet_ga_count     = e.affix.unique_amulet_slider:get(),
        legendary_ring_ga_count    = e.affix.legendary_ring_slider:get(),
        unique_ring_ga_count       = e.affix.unique_ring_slider:get(),

        legendary_helm_ga_count    = e.affix.legendary_helm_slider:get(),
        legendary_chest_ga_count   = e.affix.legendary_chest_slider:get(),
        legendary_gloves_ga_count  = e.affix.legendary_gloves_slider:get(),
        legendary_pants_ga_count   = e.affix.legendary_pants_slider:get(),
        legendary_boots_ga_count   = e.affix.legendary_boots_slider:get(),
        unique_helm_ga_count       = e.affix.unique_helm_slider:get(),
        unique_chest_ga_count      = e.affix.unique_chest_slider:get(),
        unique_gloves_ga_count     = e.affix.unique_gloves_slider:get(),
        unique_pants_ga_count      = e.affix.unique_pants_slider:get(),
        unique_boots_ga_count      = e.affix.unique_boots_slider:get(),

        legendary_focus_ga_count   = e.affix.legendary_focus_slider:get(),
        legendary_totem_ga_count   = e.affix.legendary_totem_slider:get(),
        legendary_shield_ga_count  = e.affix.legendary_shield_slider:get(),
        unique_shield_ga_count     = e.affix.unique_shield_slider:get(),

        legendary_1h_mace_ga_count = e.affix.legendary_1h_mace_slider:get(),
        legendary_1h_sword_ga_count= e.affix.legendary_1h_sword_slider:get(),
        legendary_1h_axe_ga_count  = e.affix.legendary_1h_axe_slider:get(),
        legendary_dagger_ga_count  = e.affix.legendary_dagger_slider:get(),
        legendary_wand_ga_count    = e.affix.legendary_wand_slider:get(),
        unique_1h_mace_ga_count    = e.affix.unique_1h_mace_slider:get(),
        unique_1h_sword_ga_count   = e.affix.unique_1h_sword_slider:get(),
        unique_1h_axe_ga_count     = e.affix.unique_1h_axe_slider:get(),
        unique_dagger_ga_count     = e.affix.unique_dagger_slider:get(),
        unique_wand_ga_count       = e.affix.unique_wand_slider:get(),

        legendary_2h_mace_ga_count = e.affix.legendary_2h_mace_slider:get(),
        legendary_2h_sword_ga_count= e.affix.legendary_2h_sword_slider:get(),
        legendary_2h_axe_ga_count  = e.affix.legendary_2h_axe_slider:get(),
        legendary_2h_polearm_ga_count=e.affix.legendary_2h_polearm_slider:get(),
        legendary_staff_ga_count   = e.affix.legendary_staff_slider:get(),
        legendary_bow_ga_count     = e.affix.legendary_bow_slider:get(),
        legendary_crossbow_ga_count= e.affix.legendary_crossbow_slider:get(),
        legendary_glaive_ga_count  = e.affix.legendary_glaive_slider:get(),
        legendary_quarterstaff_ga_count=e.affix.legendary_quarterstaff_slider:get(),
        unique_2h_mace_ga_count    = e.affix.unique_2h_mace_slider:get(),
        unique_2h_sword_ga_count   = e.affix.unique_2h_sword_slider:get(),
        unique_2h_axe_ga_count     = e.affix.unique_2h_axe_slider:get(),
        unique_2h_polearm_ga_count = e.affix.unique_2h_polearm_slider:get(),
        unique_staff_ga_count      = e.affix.unique_staff_slider:get(),
        unique_bow_ga_count        = e.affix.unique_bow_slider:get(),
        unique_crossbow_ga_count   = e.affix.unique_crossbow_slider:get(),
        unique_glaive_ga_count     = e.affix.unique_glaive_slider:get(),
        unique_quarterstaff_ga_count=e.affix.unique_quarterstaff_slider:get(),

        quest_items     = e.types.quest_toggle:get(),
        crafting_items  = e.types.crafting_toggle:get(),
        boss_items      = e.types.boss_toggle:get(),
        sigils          = e.types.sigil_toggle:get(),
        compass         = e.types.compass_toggle:get(),
        rune            = e.types.rune_toggle:get(),
        cinders         = e.types.cinders_toggle:get(),
        tribute         = e.types.tribute_toggle:get(),
        scroll          = e.types.scroll_toggle:get(),
        event_items     = e.types.event_toggle:get(),
        goblin_cache    = e.types.goblin_cache_toggle:get(),
        obols           = e.types.obols_toggle:get(),
        heavenly_sigil  = e.types.heavenly_sigil_toggle:get(),
        gemstone        = e.types.gemstone_toggle:get(),
        cache           = e.types.cache_toggle:get(),
        consumable      = e.types.consumable_toggle:get(),
        recipe          = e.types.recipe_toggle:get(),
        trophy          = e.types.trophy_toggle:get(),

        -- Per-category rarity thresholds (combo index → runtime rarity)
        sigil_rarity      = rarity_threshold(e.types.sigil_rarity_combo:get()),
        compass_rarity    = rarity_threshold(e.types.compass_rarity_combo:get()),
        tribute_rarity    = rarity_threshold(e.types.tribute_rarity_combo:get()),
        rune_rarity       = rarity_threshold(e.types.rune_rarity_combo:get()),
        gemstone_rarity   = rarity_threshold(e.types.gemstone_rarity_combo:get()),
        cache_rarity      = rarity_threshold(e.types.cache_rarity_combo:get()),
        scroll_rarity     = rarity_threshold(e.types.scroll_rarity_combo:get()),
        consumable_rarity = rarity_threshold(e.types.consumable_rarity_combo:get()),
        recipe_rarity     = rarity_threshold(e.types.recipe_rarity_combo:get()),
        crafting_rarity   = rarity_threshold(e.types.crafting_rarity_combo:get()),

        -- Always-loot opt-outs
        uber          = e.always.uber_toggle:get(),
        keys_loot     = e.always.keys_toggle:get(),
        xp_powerup    = e.always.xp_powerup_toggle:get(),
        glyph_drop    = e.always.glyph_drop_toggle:get(),
        misc_trinkets = e.always.misc_trinkets_toggle:get(),
        boss_drops    = e.always.boss_drops_toggle:get(),
        boss_drops_rarity = rarity_threshold(e.always.boss_drops_rarity_combo:get()),
        class_powerup = e.always.class_powerup_toggle:get(),

        charm              = e.charm.toggle:get(),
        charm_rarity       = charm_rarity_threshold(e.charm.rarity_combo:get()),
        charm_ga_count     = e.charm.ga_slider:get(),
        ingame_filter_charm= e.charm.ingame_filter_toggle:get(),
        cube         = e.cube.toggle:get(),
        cube_rarity  = rarity_threshold(e.cube.rarity_combo:get()),
        seal         = e.seal.toggle:get(),
        seal_rarity  = rarity_threshold(e.seal.rarity_combo:get()),
        fish         = e.fish.toggle:get(),
        fish_rarity  = rarity_threshold(e.fish.rarity_combo:get()),

        skip_obols           = e.crafting_mats.skip_obols_toggle:get(),
        skip_baleful         = e.crafting_mats.skip_baleful_toggle:get(),
        skip_obducite        = e.crafting_mats.skip_obducite_toggle:get(),
        skip_veiled_crystal  = e.crafting_mats.skip_veiled_crystal_toggle:get(),
        skip_rawhide         = e.crafting_mats.skip_rawhide_toggle:get(),
        skip_forgotten_soul  = e.crafting_mats.skip_forgotten_soul_toggle:get(),

        use_ingame_loot_filter = e.ingame_loot_filter_toggle:get(),

        draw_wanted_items = e.debug.draw_wanted_toggle:get(),
        scan_items        = e.debug.scan_items_toggle:get(),
        draw_path         = e.debug.draw_path_toggle:get(),
    }

    -- Sync pathfinder settings
    Settings.enabled = settings.enabled

    -- Web config overrides GUI values when loaded
    if Settings._web_config then
        Settings.apply_config(Settings._web_config)
    end
end

function Settings.get()
    return settings
end

-- Apply a config table downloaded from the web (data/config.lua).
-- Called after Settings.update() so web values override the local GUI.
function Settings.apply_config(cfg)
    if type(cfg) ~= "table" then return end
    for k, v in pairs(cfg) do
        if settings[k] ~= nil then
            settings[k] = v
        end
    end
    Settings.enabled = settings.enabled
end

-- Push a config table's values back into the GUI elements so QQT persists
-- them via get_hash(). Call this before clearing _web_config so the values
-- survive the toggle-off and become the new baseline for Settings.update().
function Settings.apply_to_gui(cfg)
    if type(cfg) ~= "table" then return end
    local e = gui.elements
    local function s(el, key)
        if cfg[key] ~= nil then pcall(el.set, el, cfg[key]) end
    end
    local function sr(el, key, map)
        if cfg[key] ~= nil then pcall(el.set, el, map[cfg[key]] or 0) end
    end

    s(e.main_toggle, "enabled")
    s(e.general.behavior_combo, "behavior")
    sr(e.general.rarity_combo, "rarity", RARITY_COMBO_IDX)
    s(e.general.distance_slider, "distance")
    s(e.general.loot_priority_combo, "loot_priority")
    s(e.general.ancestral_only_toggle, "ancestral_only")
    s(e.general.non_anc_uniques_toggle, "non_ancestral_uniques")
    s(e.general.pick_anc_normals_toggle, "pick_ancestral_normals")

    s(e.affix.magic_greater_affix_slider, "magic_ga_count")
    s(e.affix.rare_greater_affix_slider, "rare_ga_count")
    s(e.affix.greater_affix_slider, "ga_count")
    s(e.affix.unique_greater_affix_slider, "unique_ga_count")
    s(e.affix.uber_unique_greater_affix_slider, "uber_unique_ga_count")
    s(e.affix.custom_toggle, "custom_toggle")

    s(e.affix.legendary_amulet_slider, "legendary_amulet_ga_count")
    s(e.affix.unique_amulet_slider, "unique_amulet_ga_count")
    s(e.affix.legendary_ring_slider, "legendary_ring_ga_count")
    s(e.affix.unique_ring_slider, "unique_ring_ga_count")

    s(e.affix.legendary_helm_slider, "legendary_helm_ga_count")
    s(e.affix.legendary_chest_slider, "legendary_chest_ga_count")
    s(e.affix.legendary_gloves_slider, "legendary_gloves_ga_count")
    s(e.affix.legendary_pants_slider, "legendary_pants_ga_count")
    s(e.affix.legendary_boots_slider, "legendary_boots_ga_count")
    s(e.affix.unique_helm_slider, "unique_helm_ga_count")
    s(e.affix.unique_chest_slider, "unique_chest_ga_count")
    s(e.affix.unique_gloves_slider, "unique_gloves_ga_count")
    s(e.affix.unique_pants_slider, "unique_pants_ga_count")
    s(e.affix.unique_boots_slider, "unique_boots_ga_count")

    s(e.affix.legendary_focus_slider, "legendary_focus_ga_count")
    s(e.affix.legendary_totem_slider, "legendary_totem_ga_count")
    s(e.affix.legendary_shield_slider, "legendary_shield_ga_count")
    s(e.affix.unique_shield_slider, "unique_shield_ga_count")

    s(e.affix.legendary_1h_mace_slider, "legendary_1h_mace_ga_count")
    s(e.affix.legendary_1h_sword_slider, "legendary_1h_sword_ga_count")
    s(e.affix.legendary_1h_axe_slider, "legendary_1h_axe_ga_count")
    s(e.affix.legendary_dagger_slider, "legendary_dagger_ga_count")
    s(e.affix.legendary_wand_slider, "legendary_wand_ga_count")
    s(e.affix.unique_1h_mace_slider, "unique_1h_mace_ga_count")
    s(e.affix.unique_1h_sword_slider, "unique_1h_sword_ga_count")
    s(e.affix.unique_1h_axe_slider, "unique_1h_axe_ga_count")
    s(e.affix.unique_dagger_slider, "unique_dagger_ga_count")
    s(e.affix.unique_wand_slider, "unique_wand_ga_count")

    s(e.affix.legendary_2h_mace_slider, "legendary_2h_mace_ga_count")
    s(e.affix.legendary_2h_sword_slider, "legendary_2h_sword_ga_count")
    s(e.affix.legendary_2h_axe_slider, "legendary_2h_axe_ga_count")
    s(e.affix.legendary_2h_polearm_slider, "legendary_2h_polearm_ga_count")
    s(e.affix.legendary_staff_slider, "legendary_staff_ga_count")
    s(e.affix.legendary_bow_slider, "legendary_bow_ga_count")
    s(e.affix.legendary_crossbow_slider, "legendary_crossbow_ga_count")
    s(e.affix.legendary_glaive_slider, "legendary_glaive_ga_count")
    s(e.affix.legendary_quarterstaff_slider, "legendary_quarterstaff_ga_count")
    s(e.affix.unique_2h_mace_slider, "unique_2h_mace_ga_count")
    s(e.affix.unique_2h_sword_slider, "unique_2h_sword_ga_count")
    s(e.affix.unique_2h_axe_slider, "unique_2h_axe_ga_count")
    s(e.affix.unique_2h_polearm_slider, "unique_2h_polearm_ga_count")
    s(e.affix.unique_staff_slider, "unique_staff_ga_count")
    s(e.affix.unique_bow_slider, "unique_bow_ga_count")
    s(e.affix.unique_crossbow_slider, "unique_crossbow_ga_count")
    s(e.affix.unique_glaive_slider, "unique_glaive_ga_count")
    s(e.affix.unique_quarterstaff_slider, "unique_quarterstaff_ga_count")

    s(e.types.quest_toggle, "quest_items")
    s(e.types.crafting_toggle, "crafting_items")
    s(e.types.boss_toggle, "boss_items")
    s(e.types.sigil_toggle, "sigils")
    s(e.types.compass_toggle, "compass")
    s(e.types.rune_toggle, "rune")
    s(e.types.cinders_toggle, "cinders")
    s(e.types.tribute_toggle, "tribute")
    s(e.types.scroll_toggle, "scroll")
    s(e.types.event_toggle, "event_items")
    s(e.types.goblin_cache_toggle, "goblin_cache")
    s(e.types.obols_toggle, "obols")
    s(e.types.heavenly_sigil_toggle, "heavenly_sigil")
    s(e.types.gemstone_toggle, "gemstone")
    s(e.types.cache_toggle, "cache")
    s(e.types.consumable_toggle, "consumable")
    s(e.types.recipe_toggle, "recipe")
    s(e.types.trophy_toggle, "trophy")

    sr(e.types.sigil_rarity_combo, "sigil_rarity", RARITY_COMBO_IDX)
    sr(e.types.compass_rarity_combo, "compass_rarity", RARITY_COMBO_IDX)
    sr(e.types.tribute_rarity_combo, "tribute_rarity", RARITY_COMBO_IDX)
    sr(e.types.rune_rarity_combo, "rune_rarity", RARITY_COMBO_IDX)
    sr(e.types.gemstone_rarity_combo, "gemstone_rarity", RARITY_COMBO_IDX)
    sr(e.types.cache_rarity_combo, "cache_rarity", RARITY_COMBO_IDX)
    sr(e.types.scroll_rarity_combo, "scroll_rarity", RARITY_COMBO_IDX)
    sr(e.types.consumable_rarity_combo, "consumable_rarity", RARITY_COMBO_IDX)
    sr(e.types.recipe_rarity_combo, "recipe_rarity", RARITY_COMBO_IDX)
    sr(e.types.crafting_rarity_combo, "crafting_rarity", RARITY_COMBO_IDX)

    s(e.always.uber_toggle, "uber")
    s(e.always.keys_toggle, "keys_loot")
    s(e.always.xp_powerup_toggle, "xp_powerup")
    s(e.always.glyph_drop_toggle, "glyph_drop")
    s(e.always.misc_trinkets_toggle, "misc_trinkets")
    s(e.always.boss_drops_toggle, "boss_drops")
    sr(e.always.boss_drops_rarity_combo, "boss_drops_rarity", RARITY_COMBO_IDX)
    s(e.always.class_powerup_toggle, "class_powerup")

    s(e.charm.toggle, "charm")
    sr(e.charm.rarity_combo, "charm_rarity", CHARM_RARITY_COMBO_IDX)
    s(e.charm.ga_slider, "charm_ga_count")
    s(e.charm.ingame_filter_toggle, "ingame_filter_charm")

    s(e.cube.toggle, "cube")
    sr(e.cube.rarity_combo, "cube_rarity", RARITY_COMBO_IDX)

    s(e.seal.toggle, "seal")
    sr(e.seal.rarity_combo, "seal_rarity", RARITY_COMBO_IDX)

    s(e.fish.toggle, "fish")
    sr(e.fish.rarity_combo, "fish_rarity", RARITY_COMBO_IDX)

    s(e.crafting_mats.skip_obols_toggle, "skip_obols")
    s(e.crafting_mats.skip_baleful_toggle, "skip_baleful")
    s(e.crafting_mats.skip_obducite_toggle, "skip_obducite")
    s(e.crafting_mats.skip_veiled_crystal_toggle, "skip_veiled_crystal")
    s(e.crafting_mats.skip_rawhide_toggle, "skip_rawhide")
    s(e.crafting_mats.skip_forgotten_soul_toggle, "skip_forgotten_soul")

    s(e.ingame_loot_filter_toggle, "use_ingame_loot_filter")
end

function Settings.should_execute()
    return settings.behavior == 0 or
        (settings.behavior == 1 and orbwalker.get_orb_mode() == orb_mode.clear)
end

return Settings
