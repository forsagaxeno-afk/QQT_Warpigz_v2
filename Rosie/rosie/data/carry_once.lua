-- QQT_Warpigz_v3 (Q9, Season 15): items a character may carry only one of
-- (one stack per SNO; these stack to 1, so one item). The game refuses a
-- second copy on the ground and cannot stash them.
-- Source: d4data build 3.2.1.73552 ItemDefinition (item SNOs, as in items.lua):
-- nMaxStackSize 1, fMustKeepInInventory true, dwFlags 0x28816 (bit 0x20000 is
-- otherwise set only on quest-type "one per character" items), ItemType
-- Consumable. Splinter text: "Replace your current splinter with the Splinter
-- of Terror." Live 2026-09-27: a second Splinter of the same kind is refused.
return {
    build = '3.2.1.73552',
    by_id = {
        [2656952] = {name = 'Splinter of Terror', bag = 'consumable', must_keep = true},      -- S15_SoulSplinter_TriadA_01 (Diablo)
        [2656956] = {name = 'Splinter of Destruction', bag = 'consumable', must_keep = true}, -- S15_SoulSplinter_TriadB_01 (Baal)
        [2656962] = {name = 'Splinter of Hatred', bag = 'consumable', must_keep = true},      -- S15_SoulSplinter_TriadC_01 (Mephisto)
        [2675902] = {name = 'Liquid Rainbow', bag = 'consumable', must_keep = true},          -- S15_Playhouse_Portal_Potion (same flags)
    },
    -- A later build's SNO missing above is recognized by its item skin.
    skins = {'S15_SoulSplinter_Triad'},
}
