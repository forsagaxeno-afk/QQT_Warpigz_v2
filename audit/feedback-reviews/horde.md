# Horde chaos portal feedback review

## Report and findings

The live report says pathing, Pit, Horde boss/chests and handoff improved, but a Horde chaos wave left the character near the arena center instead of engaging spawned portals. No runtime skin/SNO capture from that wave was supplied.

Two source issues are relevant:

1. `tasks/horde.lua` had no explicit Chaos Rift portal classification. Its selection priority put elite/boss actors, mass objectives, occupied markers, soulspires and aether ahead of ordinary valid enemies. Even a recognized combat portal could therefore lose to nearby adds or loot.
2. Reaching a selected actor within 1.5 units unconditionally called `shoot_in_circle()`. That function moves back toward the arena center when the player is more than 15 units from the center. Reaching an edge objective could therefore immediately abandon it. This is a confirmed source behavior, not a live reproduction.

## Source evidence for actor names

Primary source: DiabloTools/d4data, `json/base/meta/Actor` tree `dec1ab5ae80f7aea49964e5add246e3f1223bd3f`, retrieved through the GitHub API on 2026-09-24. The existing research snapshot reports build 3.2.1.73552; this identifies the data snapshot, not the user's running client.

The tree records `S10_ChaosRift_Portal4` and portal variants `BossRush`, `BulletHell`, `Goblin`, `Hellwyrm`, `LunaticSiege`, `MovingAether`, `TeleportHell` (prefix `S10_ChaosRift_Portal_`). Only these exact eight names were added.

Retrieved actor blob `4c247e0e025185682d13043f4d3383d87eded9e8` (`S10_ChaosRift_Portal_LunaticSiege.acr.json`) has SNO 2405174, eType 1, non-NPC monster data and family `S10_ChaosRifts`.

Retrieved actor blob `d2eab09b26dffcd567e703d2b1b645b2d22665a0` (`BSK_AmbushPlus_Fallen_LunaticPortal.acr.json`) has SNO 1924090 and `SpawnerGizmoData` with proximity radius 5. It was deliberately not classified as an attackable portal. Controllers, choice gizmos, town portals and similarly named visual effects are not selected by a broad `portal` substring.

Reproducible source endpoints:

- https://api.github.com/repos/DiabloTools/d4data/git/trees/dec1ab5ae80f7aea49964e5add246e3f1223bd3f
- https://api.github.com/repos/DiabloTools/d4data/git/blobs/4c247e0e025185682d13043f4d3383d87eded9e8
- https://api.github.com/repos/DiabloTools/d4data/git/blobs/d2eab09b26dffcd567e703d2b1b645b2d22665a0

## Change

Known portals with positive health and hostile status are prioritized before adds/loot. Where exposed, dead, immune and untargetable states reject the portal; the existing dangerous-position filter still applies. Living bosses retain precedence. Selection remains inside the existing Horde task and world/zone settle gates.

At a known portal or existing occupied event marker, release only Horde-owned movement and hold position for the combat rotation instead of recentering. Suppress repeated Batmobile movement pulses and keep the native explorer paused while holding. Navigation resumes when a target moves, disappears or changes. Cancellation clears the hold. This module does not send combat casts or interact blindly with a portal.

Boss activation, chest spending, aether payment confirmation, exit/reset and orchestrator handoff were not edited.

## Validation

Command:

`python3 audit/tests/run_tests.py test_horde_feedback.lua test_horde_audit.lua test_horde_reset_exit.lua test_horde_sigil_entry.lua`

Nine new behavior scenarios cover all eight portal names, portal priority, no center retreat in Batmobile/native movement modes, autonomous explorer suppression, occupied-marker holding, boss priority, invalid portal rejection, hazard rejection, noncombat gizmo exclusion, cancellation and the one-hit-point boundary (some combined in the same scenario). The pre-existing Horde audit, reset/handoff and sigil/entry regressions also pass.

These are isolated offline Lua regressions. No game client was run. The exact actor name from the user's problematic wave and whether the active combat rotation will attack it still require an in-game check; the implementation must not be described as a verified live fix for every portal type.
