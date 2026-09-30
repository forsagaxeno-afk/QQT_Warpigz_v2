-- Hardcoded fallback item data.
-- Run Updater.bat to download the full cloud catalog which replaces this.
local M = {
    version = "default",

    ubers = {
        [1901484] = "Tyrael's Might",
        [223271]  = "The Grandfather",
        [241930]  = "Andariel's Visage",
        [359165]  = "Ahavarion, Spear of Lycander",
        [221017]  = "Doombringer",
        [609820]  = "Harlequin Crest",
        [1275935] = "Melted Heart of Selig",
        [1306338] = "Ring of Starless Skies",
        [2059803] = "Shroud of False Death",
        [1982241] = "Nesekem, the Herald",
        [2059799] = "Heir of Perdition",
        [2059813] = "Shattered Vow",
    },

    boss_materials = {
        [1502128] = "Living Steel",       [1518053] = "Distilled Fear",
        [1522891] = "Exquisite Blood",    [1524924] = "Shard of Agony",
        [1489420] = "Malignant Heart",    [1489418] = "Gurgling Head",
        [1850845] = "Stygian Stone",      [1524917] = "Mucus-Slick Egg",
        [1810144] = "Sandscorched Shackles", [1812685] = "Pincushioned Doll",
        [1489422] = "Blackened Femur",    [1882910] = "Profane Mindcage",
        [1489411] = "Trembling Hand",     [1971857] = "Abyssal Scroll",
        [2136706] = "Fugitive Head",      [2193876] = "Judicator's Mask",
        [2194099] = "Betrayer's Husk",    [2194097] = "Abhorrent Heart",
        [2255243] = "Behelit",
        [2429471] = "Corrupted Horn of Duriel",
        [2429467] = "Corrupted Tongue of Azmodan",
        [2429469] = "Corrupted Eye of Belial",
        [2429465] = "Corrupted Claw of Andariel",
        [2429475] = "Purified Tongue of Azmodan",
        [2429479] = "Purified Horn of Duriel",
        [2429473] = "Purified Claw of Andariel",
        [2429477] = "Purified Eye of Belial",
        [2567119] = "Malignant Orb",
        [2403989] = "Trace of Echoes",
    },

    event_items = {
        [1930727] = "Treasure Bag",
        [1930725] = "Treasure Bag",
        [1931272] = "Greater Treasure Bag",
        [1468409] = "Gileon's Brew",
    },

    catalog = {},
    -- Name patterns are server-managed — ship empty here so a fresh install
    -- without a synced items.lua simply has no fallback patterns. Once the
    -- Updater.bat / first cloud sync lands, the real list arrives in
    -- data/items.lua and replaces this default.
    name_patterns = {},
}

return M
