-- Static TristramLoop data. A coordinate without a world is a hint, never a route.
return {
    name = "TristramLoop", version = "1.0.1",
    -- Exact boss skins observed in the user's live runs. A replacement actor of
    -- the same council boss cannot stand in for another boss's missing death.
    BOSS_SLOTS = { Triad_A_Boss_Council = "A", S15_Triad_B_Boss_Council = "B", Triad_C_Boss_Council = "C" },
    INCOMPLETE_EMPTY_SECONDS = 30,
    RETRY_WAIT_SECONDS = 5,
    -- Local bag threshold; a full bag pauses pickup until space is observed.
    INVENTORY_CAPACITY = 33,
    -- User-required delay after observed revival, before returning to the arena.
    REVIVE_WAIT_SECONDS = 45,
    -- Live local-state world/zone and position; available even without file libraries.
    ARENA = { name = "S15_Secret_UberTristram", zone = "S15_Secret_UberTristram",
        x = -10.5507813, y = -13.5917969, z = 0.033203125 },
    -- Loot wait (minutes) before the next reset. The game keeps the council's
    -- loot locked for about one hour per character, so 60 is the default.
    LOOT_WAIT_MIN = 15, LOOT_WAIT_MAX = 120, LOOT_WAIT_DEFAULT = 60,
    -- Interactable blue party-member portal (observed in live runs).
    ENTRY_PORTAL_SKIN = "PartyMemberPortal_Index0",
    -- Reviewed full-window screenshots: client origin (1,31), size 1920x1108.
    -- Positions are scaled to the live viewport by party.position().
    PARTY_WIDTH = 1920, PARTY_HEIGHT = 1108,
    PARTY_ANCHORS = { search = "right", friend = "right", join = "center",
        transfer = "left", leave = "left", leaveaccept = "center", teleport = "left" },
    POINTS = { "search", "friend", "join", "transfer", "leave", "leaveaccept", "teleport" },
    POINT_LABELS = { "Friends search box", "First search result (right click)",
        "Join Party", "Transfer Now", "Leave Party in Social", "Accept after Leave Party", "Teleport to Party Leader: Accept" },
    PARTY_POINTS = {
        search = { x = 1545, y = 246 }, friend = { x = 1617, y = 339 },
        join = { x = 949, y = 503 }, transfer = { x = 225, y = 345 },
        leave = { x = 449, y = 97 }, leaveaccept = { x = 883, y = 671 },
        -- Retained screenshot evidence/legacy storage key; first entry uses the town portal.
        teleport = { x = 216, y = 390 },
    },
}
