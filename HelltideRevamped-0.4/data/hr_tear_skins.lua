-- Pandemonium Rupture (Season 14 — Season of Death Awakening) actor skin
-- patterns used by core/hr_tear_event.lua (Farm mode only).
-- Ported from upstream HelltideRevamped 2.5.0 data/tear_skins.lua (names from
-- DiabloTools/d4data). Entries are Lua patterns unless noted otherwise.

return {
    -- Plain-prefix validation for rupture scans (not Lua patterns).
    rupture_prefixes = {
        "S14_Rupture_",
        "PandemoniumRift_",
        "S14_PandemoniumCrack_",
    },

    -- Town markers, NPCs, and other actors that must never route as ruptures.
    reject = {
        "^Start_Location",
        "^TWN_",
        "Crafter_",
        "Blacksmtih",
        "MarkerLocation_",
    },

    -- Rupture anchors: the switch / marker gizmos that start or mark a rupture.
    starter = {
        "S14_Rupture_SMP_SwitchGizmo",
        "S14_Rupture_LE_SwitchGizmo",
        "S14_Rupture_LE_Gizmo",
        "S14_Rupture_LE_ActiveUIMarker",
        "S14_Rupture_LE_Wave_Proxy",
        "S14_Rupture_SMP_Wave_Proxy",
        "S14_Rupture_ZE_Pillar",
        "S14_Rupture_Major_Proxy",
        "PandemoniumRift_gizmo_Boundry",
    },

    -- Cultists guarding a Death's Head Idol before the rupture opens.
    guards = {
        "S14_cultist_",
    },

    -- Closable tears (golden glints / micro ruptures).
    tears = {
        "S14_Rupture_SMP_Chargeable",
        "S14_Rupture_Major_ZE_MicroRupture",
        "S14_Rupture_Major_ZE_MicroRupture_Mobile",
        "S14_Rupture_Major_ZE_MicroRupture_Mobile_Sprint",
    },

    chargeable = {
        "S14_Rupture_SMP_Chargeable",
    },

    -- Ritual ring centre (stand here while the rupture is active).
    hold_area = {
        "S14_PandemoniumCrack_gizmo_holdArea",
    },

    -- Rupture edge markers used by the leash (both spellings seen).
    boundary = {
        "PandemoniumRift_gizmo_Boundry",
        "PandemoniumRift_gizmo_Boundary",
    },

    goblin = {
        "S14_Rupture_SMP_PandemoniumGoblin",
    },

    -- Rupture reward chests inside the ritual ring. PandemoniumChest is free
    -- (no cinder cost); usz_rewardGizmo_* still use enums.chest_types costs.
    event_chests = {
        "S14_Rupture_.-PandemoniumChest",
        "PandemoniumChest",
        "usz_rewardGizmo_",
        "Helltide_RewardChest_Random",
    },

    -- Realmwalker 2.0 boss (Surging mastery / Colossal completion)
    realmwalker_boss = {
        "S14_Golem_Stone_Realmwalker",
        "S14_Golem_Stone_Realmwalker_UE",
    },

    realmwalker_spawner = {
        "S14_Rupture_LE_FinalBossSpawner",
        "S14_Rupture_SMP_FinalBossSpawner",
    },

    chamber_entrance = {
        "S14_Realmwalker_eventEnd_RuptureEntrance_Portal",
        "S14_DeathtollChamber_PortalUIMarker",
        "RuptureEntrance_Portal",
        "DeathtollChamber_Portal",
    },

    chamber_start = {
        "S14_DRLG_Chamber_PortalSwitch",
        "S14_Prop_Crucible_Chamber_Totem_01_Dyn",
    },

    chamber_exit = {
        "S14_RuptureChamber_ExitPortal",
        "S14_RuptureChamber_ReturnPortalMarker",
    },

    -- Zone-name fragments that identify the Deathtoll Chamber instance.
    chamber_zones = {
        "RuptureChamber",
        "Deathtoll",
        "DRLG_Chamber",
    },

    type_by_skin = {
        { patterns = { "S14_Rupture_LE_" },     label = "Surging" },
        { patterns = { "S14_Rupture_Major_", "S14_Rupture_ZE_" }, label = "Colossal" },
        { patterns = { "S14_Rupture_SMP_" },    label = "Normal" },
    },
}
