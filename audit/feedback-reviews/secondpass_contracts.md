# Second independent pass: SilentRaven and suite contracts

## Scope actually read

All SilentRaven runtime files were read: `main.lua`; `silent_raven/coordination.lua`, `external.lua`, `fsm.lua`, `gui.lua`, `log.lua`, `rewards.lua`, `settings.lua`, `stats.lua`, `tracker.lua`, `whispers.lua`; and `silent_raven/data/caches.lua`. The optional Windows updater was inspected but never executed. Review also covered WarPigs's bridge, public API, GUI binding, visit admission, release and busy gates, and WarPug's external status/planning ownership.

The exported suite interfaces and delayed imports were checked across all nine plugins. Reaper's captured dependency fix, Horde portal targeting and later Looter/exit guards, and WonderCity's reward lane received independent focused review. This does not claim a second line-by-line reading of every other plugin; their assigned reviewers own those reports.

## Findings fixed during the reviews

1. **External imports resolved in the caller's context.** Captured dependencies fix Reaper resets, path variants, WarPigs status/stop, WarPigs GUI binding, and WarPug status. SR's modules use `silent_raven.*`, avoiding new collisions with generic `gui`/`core.*` keys.
2. **Legacy Looteer returns nil for false.** The bridge now distinguishes a successful nil result from a thrown read, accepts actual idle, and ignores a stale busy flag from a disabled legacy Looter. Modern activity exports retain precedence.
3. **Active WarPug planning could be interrupted by Raven.** The bridge defers to an existing selection/reroll transaction; its reservation blocks only an idle planner. A planner already working does not receive a new busy signal that would halt its own transaction.
4. **Master-stop cancellation and timeout had different cleanup behavior.** SR's `cancel` now has a documented tri-state navigation argument. The bridge supplies explicit false after verifying idle companions, including a clean timeout; true preserves an observed successor. Actual bridge plus actual SR tests first reproduced the timeout leaving its native path active, then passed after correction.
5. **SR-first update could auto-fire before WarPigs acquired management.** New `silent_raven.coordination` checks the controller's published `status().manages_whispers` reservation before automatic, manual or foreign external startup. The intended caller WarPigs is admitted. The opposite callback order is covered by the explicit lease. A request already running before WarPigs starts retains ownership, and WarPigs waits for it; no callback is overwritten.
6. **Loading sentinels could be interpreted as usable town context.** SR now normalizes `[sno none]`, empty zones and Limbo/loading worlds to unavailable. They do not authorize automatic work or manufacture a new completed-town visit.
7. **Standalone teleport rewrite omitted the original active-cast check.** The retained manual/public teleport mode now checks spell 186139, permits at least six seconds between requests, and suppresses native actions with a dead/missing player or unavailable world. WarPigs's managed Whisper request never uses teleport mode.
8. **WonderCity's quiet timer missed intervening obols work.** Reported to its owner and corrected by resetting the timer while reward-lane obols, Alfred or a live boss owns the queue. Its scheduler regression covers the timing gap.
9. **Alfred's 20-second completion grace could abort a 60-second Whisper request.** The bridge previously re-evaluated that short admission grace on every running tick and SR continuation callback. An unchanged advisory `need_trigger` therefore became a false new-work signal mid-request. Admission now captures only that already approved advisory flag on the same Alfred API object. Live/queued activity, teleport, full inventory, repair, pause and unreadable status still revoke permission. The permission is discarded when the flag clears, the request finishes or the API object changes; a later flag cannot borrow it. Actual bridge and SR regressions cover both callback orders across grace expiry, genuine new activity, replacement instances and cleared/rearmed flags.
10. **A replacement Alfred could borrow the previous instance's completion grace.** The orchestrator now records the completing API identity alongside its timestamp and requires both for admission. Release clears both and increments callback generation. Tests use the actual orchestrator callback, confirming that replacement instances and late callbacks cannot establish grace. Optional `pending` also blocks new requests, re-triggers and ongoing Raven work.
11. **Unreadable modern Looter state could fall through to legacy nil and authorize movement.** The bridge now retains unknown enabled/activity state rather than interpreting the fallback as idle. A second explicit modern activity method may resolve the first method's failure. Tests cover blocked admission, a running request yielding without clearing the unknown owner's path, and legacy-only compatibility retained by the existing bridge suite. Its town-location check now rejects normalized Limbo/loading world names before queue admission.
12. **Farming cleanup could erase a successor's native path.** Final independent Horde/Helltide review found that an old `native_movement_owned` flag could survive a later Looter `request_move`; clearing that shared path on the next busy tick interrupted the successor. Reported to the farming owner, who updated Helltide and Horde cleanup to preserve the global path when Looter or Alfred already owns or may own movement, discard the old ownership flag, and retain ordinary idle cleanup. The farming tests now model the replacement target itself instead of only counting clear calls.

## Public interface map

| Export | Control and status used by the suite | Ownership boundary |
|---|---|---|
| `WarPigsPlugin` | `enable`, `disable`, `status` | Owns activity handoffs; `status.busy` reserves the next safe operation; `manages_whispers` publishes admission before the first controller pulse. |
| `WarPugPlugin` | `status` | Reports live planning state. Its own table selection and reroll transaction must finish before Raven starts. |
| `ReaperPlugin` | `enable`, `disable`, `run_boss`, `run_once`, `clear_external`, `status` | External one-shot callback fires after confirmed town return; obsolete callbacks are discarded on stop. Captured dependencies remain Reaper's. |
| `ArkhamAsylumPlugin` | `enable`, `disable`, `get_status` | Owns Pit work and its cleanup until the orchestrator's release gate permits handoff. |
| `WonderCityPlugin` | `enable`, `disable`, `get_status` | Reports reward evidence separately from enabled state; chest opening and quiet loot completion precede normal exit. |
| `InfernalHordesPlugin` | `enable`, `disable`, `status`, `getState`, `chests_done` | Chest spending, Looter quiet time, committed exit/reset and town confirmation protect handoff. |
| `HelltideRevampedPlugin` | `enable`, `disable`, `status`, `getState` | Disabled state and task cleanup release its movement before another activity starts. |
| `BatmobilePlugin` | Movement target/update/move, pause/resume, long-path start/stop and queries | Caller strings identify usage but are not an enforceable lock. Consumers must stop their owned movement before handing it off. |
| `SilentRavenPlugin` and `PLUGIN_silent_raven` | `get_status`, `set_managed`, `trigger_tasks`, `trigger_tasks_with_teleport`, `cancel`, `pause`, `resume` | Both names reference one API object. API version 2 exposes queued work, running state and caller. A new request cannot replace an existing callback. Managed requests are Temis-only and cannot request teleport. |

External Alfred and Looteer implementations remain companion dependencies rather than files changed by this review. The bridge reads their exported state without disabling Looteer or replacing an Alfred callback. Missing fields on older Alfred versions cannot reveal an unpublished queued request.

## Independent regressions and results

`audit/tests/test_secondpass_contracts.lua` loads the **actual** WarPigs bridge and SR main, external, FSM, tracker and helpers. Only native host APIs and widgets are mocked. In particular, it does not stub cancellation, the interaction that the earlier isolated tests missed.

The independent file passes **155 assertions** covering both callback orders, automatic/manual/foreign admission, an existing standalone owner, actual clean-stop and timeout path cleanup, Looter/Alfred preemption, advisory Alfred permission across its admission-grace expiry, actual orchestrator completion identity/generation, pending-only cancellation, unique module imports under poisoned generic keys, loading sentinels and standalone teleport channel/death gates.

The final focused command at this review checkpoint was:

```text
python3 audit/tests/run_tests.py test_silentraven.lua test_secondpass_contracts.lua test_warpigs_whispers.lua test_suite_contracts.lua
```

All four files passed: 101 SR checks, 155 independent assertions, 55 WarPigs/Whisper assertions and 33 suite contract checks. The suite fixture was extended only with the newly required idle reward-phase module and world-name method; its assertions were retained. The runtime files present at that checkpoint also compiled successfully under Lua 5.4. Final farming cross-review additionally checked `test_secondpass_farming.lua` and the corrected successor-path ownership cases.

## Remaining limits

- No native QQT loader implementation or game process is available. Generic startup import scoping is still the host's responsibility. The fixes protect delayed callbacks after a correct bootstrap; they do not replace that loader or support duplicate installed versions exporting the same globals.
- The supplied reward catalog and fallback name/rarity heuristics are retained. They are not live verification of every future cache variant. Native reward entries, the selected index/SNO and receipt are rechecked before a claim is counted successful.
- An already running standalone SR request is allowed to finish before newly enabled WarPigs takes management. That is an explicit ownership choice, not an immediate forced transfer.
- No outstanding blocker was found in the reviewed bridge/SR contract after these fixes. Actual NPC navigation, live cache delivery and the user's reported Horde portal variant still require in-game confirmation.
