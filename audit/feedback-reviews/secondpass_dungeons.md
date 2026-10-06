# Independent second pass: WonderCity and Arkham

## Scope and method

Reviewed every runtime Lua file in `WonderCity-main` and `ArkhamAsylum-1.0.6`, including registered tasks, dormant tasks, exported functions, internal helpers, GUI/settings and data tables. This is a source review plus synthetic runtime verification, not a game-client test. The reviewer did not author the earlier WonderCity reward integration or the baseline Arkham fixes.

The independent regression harness loads each real `main.lua`, real GUI/settings, real external API, real task manager and real task implementations in an isolated environment. Only QQT native services/widgets and companion APIs are mocked. Consequently, the main-to-external-to-scheduler paths are exercised together; this does not simulate two autonomous game plugins driving native movement concurrently.

## Confirmed defects corrected

1. **Legacy Looter compatibility / reward completion.** The supplied LooteerV2 `getSettings` implementation returns nil for stored false. WonderCity's prior boolean-only reader treated successful idle reads as unknown/busy forever, preventing normal completion. Both dungeon utilities now recognize the legacy contract, support modern active/idle APIs and hold on unreadable modern state. A valid second modern status can resolve a failed first status; a legacy nil cannot override a still-unknown modern owner. Arkham also no longer requires the old getter to exist when a modern companion is used.
2. **Arkham Alfred ownership.** `teleport_cerrigar` previously preceded Alfred in normal task selection. A foreign/in-progress service trip to another town could be preempted by relocation. The scheduler now gives busy Alfred ownership before ordinary town/reward task selection. Alfred task request acceptance and callbacks are separately owned by the town-integration reviewer; no edits to those tasks were made in this pass.
3. **Arkham interaction cadence.** Burden Altar and Heart of Stone reused the first-click timestamp as the recurring cooldown, producing per-tick interactions after the first second. Shrines also interacted every scheduler tick. Each now has a separate last-click timestamp, retains a bounded first-attempt timeout and stops before attempting again after expiry.
4. **Rejected progress-orb paths.** A nil cached target bypassed the stated retry interval after every failed `navigate_long_path`. Arkham now observes that interval after rejection, while target changes and interrupted partial navigation still retain their existing behavior.
5. **Traversal completion.** Walking more than ten units toward a traversal could previously be called a successful crossing before any interaction. Movement-based crossing confirmation now requires an interaction in the active engagement. Batmobile's own traversal-routing branch is unchanged.
6. **Transient world state.** Both mains, schedulers and lifecycle trackers rejected only `[sno none]`, allowing Limbo/Loading snapshots with an old zone string to scan actors or reset run/boss state. They now reject those names and empty/invalid world/zone identifiers before task selection or lifecycle mutation.
7. **GUI/API export agreement.** Both runtime adapters accept `PLUGIN_alfred_the_butler`, but their GUIs hid controls without `AlfredTheButlerPlugin`. The presence checks now accept the same two exports.

## Verification

`python3 audit/tests/run_tests.py test_secondpass_dungeons.lua test_wondercity.lua test_arkham.lua`

All three files pass: fourteen independent scenarios, thirty-nine existing WonderCity regressions and twenty-one existing Arkham regressions. The suite runner also compiles runtime Lua files. The independent cases verify disabled/enable/disable behavior through real mains and real widgets/settings, both Looter API generations, unknown status, reward cleanup before exit, foreign Alfred ownership, click cadence over multiple seconds, loading-state preservation, revival debounce, failed-path cadence, traversal approach and alternate-export GUI access.

No chest-open confirmation or dungeon reset/exit policy was loosened. Existing configured hard run deadlines still override normal loot waits. Boss, glyphstone, soul, altar, Heart of Stone and floor-transition priorities were traced through the real task manager, and existing focused tests remain passing.

## Remaining limits and non-active code

- Actual native actor lifetime, map navigation, combat casting, UI timing and client-specific actor names require an in-game run. Lua `pcall` cannot recover a native use-after-free; the guards address recognizable transition states, not every possible native race.
- WonderCity tribute/bargain submission relies on calibrated screen coordinates. It validates the selected item/slot again before clicking, but no game confirmation of tribute consumption is available in these tests.
- Arkham's glyphstone discovery still uses the supplied ally-actor contract. Successful Pit feedback and existing tests support retaining it; the review does not claim it appears in that list on every client build.
- The independent loader uses separate per-plugin module caches. Shared QQT import isolation and truly concurrent movement/Looter scheduling are covered by other suite reviewers, not proven by this harness.
- WonderCity `sort_tribute`, `d4assistant` and `follower` are not registered in its active task list. Their bodies were reviewed; dormant helper functionality is not advertised as enabled. Assistant/party messaging branches contain placeholders and do not implement communications.
- Main death handling suppresses task execution and debounces revive requests. The autonomous Batmobile driver's response to death is a separate companion responsibility.

## Reviewed runtime files

### WonderCity-main

- `WonderCity-main/core/external.lua`
- `WonderCity-main/core/reward_phase.lua`
- `WonderCity-main/core/settings.lua`
- `WonderCity-main/core/task_manager.lua`
- `WonderCity-main/core/tracker.lua`
- `WonderCity-main/core/utils.lua`
- `WonderCity-main/data/path.lua`
- `WonderCity-main/gui.lua`
- `WonderCity-main/main.lua`
- `WonderCity-main/tasks/alfred.lua`
- `WonderCity-main/tasks/custom_explorer.lua`
- `WonderCity-main/tasks/d4assistant.lua`
- `WonderCity-main/tasks/enter_undercity.lua`
- `WonderCity-main/tasks/exit_undercity.lua`
- `WonderCity-main/tasks/explore_undercity.lua`
- `WonderCity-main/tasks/follower.lua`
- `WonderCity-main/tasks/goto_chest.lua`
- `WonderCity-main/tasks/idle.lua`
- `WonderCity-main/tasks/interact_enticement.lua`
- `WonderCity-main/tasks/kill_monster.lua`
- `WonderCity-main/tasks/loot_obols.lua`
- `WonderCity-main/tasks/portal.lua`
- `WonderCity-main/tasks/sort_tribute.lua`
- `WonderCity-main/tasks/teleport_kurast.lua`
- `WonderCity-main/tasks/walk_kurast.lua`

### ArkhamAsylum-1.0.6

- `ArkhamAsylum-1.0.6/core/external.lua`
- `ArkhamAsylum-1.0.6/core/settings.lua`
- `ArkhamAsylum-1.0.6/core/task_manager.lua`
- `ArkhamAsylum-1.0.6/core/tracker.lua`
- `ArkhamAsylum-1.0.6/core/utils.lua`
- `ArkhamAsylum-1.0.6/data/pitlevels.lua`
- `ArkhamAsylum-1.0.6/gui.lua`
- `ArkhamAsylum-1.0.6/main.lua`
- `ArkhamAsylum-1.0.6/tasks/alfred.lua`
- `ArkhamAsylum-1.0.6/tasks/consume_chorons_soul.lua`
- `ArkhamAsylum-1.0.6/tasks/cross_traversal.lua`
- `ArkhamAsylum-1.0.6/tasks/d4assistant.lua`
- `ArkhamAsylum-1.0.6/tasks/enter_pit.lua`
- `ArkhamAsylum-1.0.6/tasks/exit_pit.lua`
- `ArkhamAsylum-1.0.6/tasks/explore_pit.lua`
- `ArkhamAsylum-1.0.6/tasks/follower.lua`
- `ArkhamAsylum-1.0.6/tasks/idle.lua`
- `ArkhamAsylum-1.0.6/tasks/interact_shrine.lua`
- `ArkhamAsylum-1.0.6/tasks/kill_boss.lua`
- `ArkhamAsylum-1.0.6/tasks/kill_monster.lua`
- `ArkhamAsylum-1.0.6/tasks/pickup_heart_of_stone.lua`
- `ArkhamAsylum-1.0.6/tasks/portal.lua`
- `ArkhamAsylum-1.0.6/tasks/push_monsters.lua`
- `ArkhamAsylum-1.0.6/tasks/teleport_cerrigar.lua`
- `ArkhamAsylum-1.0.6/tasks/upgrade_glyph.lua`
- `ArkhamAsylum-1.0.6/tasks/use_burden_altar.lua`

Total: 51 runtime Lua files reviewed.

## Independent cross-review of the second-pass changes

A second reviewer compared the changed runtime against the delivered baseline,
read the changed behavior and its surrounding scheduler paths, and inspected the
independent regression harness. This cross-review covered the 19 changed files
listed below; it does not claim another complete read of all 51 files. Alfred
task implementation remained with the town-integration reviewer.

Two additional defects were reproduced and corrected:

1. **Traversal approach was still counted after the first click.** Requiring an
   interaction was insufficient while distance was measured from the original
   approach position. A 23-unit approach followed by one unsuccessful click
   immediately satisfied the 10-unit crossing threshold. The test was extended
   through approach, first click, stationary next pulse and actual displacement;
   it failed before the fix. Distance now uses a copied position captured at the
   interaction, preserving ownership until actual post-click movement occurs.
2. **Scheduler cleanup could cancel an already active Alfred route.** Both
   schedulers remembered only their prior task when deciding to stop Batmobile.
   If Alfred acquired movement between pulses, selecting the Alfred task first
   stopped its route. Immediate plugin disable had the same issue. Batmobile's
   caller string is a label, not an ownership guard. Cleanup now checks live
   Alfred ownership before stopping movement. Floor/run navigation reset is
   deferred while service owns movement and performed once after release, so
   preserving the service route does not leave stale dungeon navigation state.

The cross-review added two independent scenarios, extended the traversal case,
and reran `test_secondpass_dungeons.lua`, `test_wondercity.lua`, `test_arkham.lua`
and `test_secondpass_town.lua`: **4/4 pass**, including all 210 town-contract
checks. All 201 runtime Lua files present at this checkpoint compiled.

Cross-reviewed changed runtime files:

- WonderCity: `core/external.lua`, `core/reward_phase.lua`, `core/task_manager.lua`,
  `core/tracker.lua`, `core/utils.lua`, `gui.lua`, `main.lua`,
  `tasks/exit_undercity.lua`, `tasks/goto_chest.lua`.
- Arkham: `core/task_manager.lua`, `core/tracker.lua`, `core/utils.lua`, `gui.lua`,
  `main.lua`, `tasks/cross_traversal.lua`, `tasks/explore_pit.lua`,
  `tasks/interact_shrine.lua`, `tasks/pickup_heart_of_stone.lua`,
  `tasks/use_burden_altar.lua`.

Additional contract references inspected: Arkham's ordinary exit task, both
Alfred tasks' public busy/execute/reset shape, and Batmobile's public pause,
clear, stop and reset functions. No other concrete blocker was established in
the reviewed change set. Native concurrency and actor lifetime remain subject
to the live limits above.

Final Looter consistency check: when the modern activity API is present without
`get_enabled`, the legacy enabled getter could previously return nil before the
modern activity method was queried. Both dungeon utilities now prioritize the
modern state and preserve unknown when it fails, instead of returning legacy
idle. Focused cases cover throwing enabled/activity methods, explicit modern
activity overriding legacy nil, secondary modern idle recovery, and unchanged
legacy-only nil behavior. The older WonderCity fallback expectation was updated
to the required unknown-ownership hold.
