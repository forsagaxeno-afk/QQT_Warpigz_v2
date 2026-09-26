# Season 15 compatibility review

Review date: 2026-09-23. This is a source and offline behavior audit, not a live game certification.

## Verified public changes

Blizzard's Season of Hell's Legacy announcement includes the live **3.2.1 build 73552** notes for September 15, 2026. Soul Splinter modifiers affect the activities driven by this suite. Relevant changes include Helltide orb rewards; Pit guardian floor-transition and glyph-reward fixes; Undercity exit-map-icon fixes; Belial quest-credit fixes; and War Plans reward and teleport fixes. War Plans progress is shared within matching realm/Hardcore/SSF partitions, while character allocations remain individual.

These notes do **not** provide QQT actor skin names, quest substrings, buff hashes, chest costs, waypoint IDs or portal SNOs. Existing identifiers were retained unless a separate, concrete source defect justified changing the surrounding logic. Additional seasonal encounters and every modifier combination remain unverified in game.

Primary source: [Blizzard — Season of Hell's Legacy and live 3.2.1 patch notes](https://news.blizzard.com/en-us/article/24295394/celebrate-30-years-of-diablo-in-season-of-hell-s-legacy).

## QQT API baseline

The current public [QQT API declarations](https://github.com/qqtnn/qqt_diablo/tree/14acd83bd3e94d6da27f0c361c9d1cbc3b06e916/scripts/%23api) were compared with the supplied framework:

- 22 API files match byte for byte. Five declaration files differ, and two additional examples exist upstream.
- New global declarations include Horde counters and native boss teleport. Actor, loot-manager, menu, vector and callback declarations used in this audit are unchanged.
- Current world declarations describe native pathfinding and scene/level-area access. Height resolution is documented inconsistently (in-place modification versus a returned vector), so a runtime assumption must not rely on one annotation alone.
- No removed `attributes.*` constant is referenced by the suite.

API declarations describe the host interface, not a guarantee that every user's installed QQT binary exposes the latest additions. No framework files or external companions are bundled or overwritten by this patch.

## Live verification still required

| Area | What offline checks cannot establish |
|---|---|
| Helltide | Current chest skins, costs, spawned variants, streaming distance, and movement around real obstacles. |
| Batmobile | Real frame time, movement speed, navigation mesh quality, traversal animations, and route completion in every dungeon. |
| Pit / Undercity / Horde | Every seasonal modifier, floor layout, objective ordering, live portal visibility, and reward timing. |
| Reaper | Current boss/material IDs, reward-dialog placement, all lair variants, and Belial reward UI. |
| WarPigs / WarPug | Every quest-name mapping and live War Plan UI transaction. Existing guessed boss aliases are not promoted to verified mappings. |
| Companion integration | Actual installed Alfred, Looteer and combat-plugin versions and QQT's module isolation. |

The suite still does not implement Nightmare Dungeon activities. Reaper's unfinished explicit sigil-run interface must not be treated as a working seasonal feature.
