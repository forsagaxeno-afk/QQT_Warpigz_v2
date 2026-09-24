# Second pass: town interfaces, callbacks, and movement handoffs

## Scope and evidence boundary

This pass reviewed the available Alfred/Looter public interfaces and the outer task/ownership gates of the nine-plugin working suite. It does not claim to inspect every private function inside the unavailable proprietary packs. Combat, reward, navigation-algorithm, and GUI internals have separate component reviews.

Reference source root: `/workspace/scratch/896e1c8c15f3/qqt_extracted/diablo_qqt/scripts`.

| Reference | Examined files / evidence | What is established |
| --- | --- | --- |
| AlfredTheButler Lua source, GUI version 1.7.9 | `AlfredTheButler-main/core/external.lua`, `core/tracker.lua`, `core/settings.lua`, `core/task_manager.lua`, `core/utils.lua` reset section, `tasks/status.lua`, `tasks/external-template.lua`, `main.lua`, GUI version declaration | Actual public implementations, published status fields, queue state, callback ordering, task priority, external-pause behavior |
| LooteerV2 Lua source | `LooteerV2-main/main.lua`, `src/settings.lua`, `src/item_manager.lua` interface/selection sections; prior explorer interface inspection | Actual legacy getters/setters, GUI refresh, pulse ordering, and absence of a pause API |
| Earlier runtime Looter export observation | `/workspace/scratch/896e1c8c15f3/upload/stationary_wall_cycle.log`, export records at elapsed 13450.709 and following samples | Function names present in that earlier session; not their complete implementation or a universal V3 contract |
| SteroidAlfred documentation snapshot | `/workspace/scratch/896e1c8c15f3/loot_sorter_research/steroid/README.md`, API reference | Documented global names, `create_task`, status fields and trigger/pause calls; implementation remains uninspected |
| BetterAlfred captured export index | `/workspace/scratch/896e1c8c15f3/alfred_feasibility_sources/dump/dump/capture-index.tsv` | Export names and captured bytecode provenance, not recovered full source or verified private item rules |
| Current reported LooteerV3 behavior | User screenshot | Repeated `approach_stall` at 4.7 m. No proof of which controller prevented movement, whether the item is collectible, or the current inventory capacity |

Unavailable internals: `Looter-V1.6.4.pack`, `BetterAlfred-v1.7.113.pack`, inspected but unextracted `SteroidAlfredV2-1.1.3.pack`, and the screenshot's exact LooteerV3 build/source. Their private movement, item classification, blacklist, stash, sell, and salvage implementations cannot be certified by this review. No pack is replaced or executed by these tests.

## Public contract matrix

All calls below use dot syntax unless otherwise stated. The integration feature-detects optional exports.

| Provider | Operation / field | Verified availability and semantics | Coordination consequence |
| --- | --- | --- | --- |
| Source Alfred | `get_status()` | New table exposing `name`, `version`, `enabled`, `teleport`, `teleport_done`, `teleport_failed`, `inventory_full`, `inventory_count`, `salvage_count`, `sell_count`, `stash_count`, `restock_count`, `trigger_tasks`, `last_reset`, `salvage_failed`, `salvage_done`, `sell_failed`, `sell_done`, `all_task_done`, `need_repair`, `need_trigger` | Safe read; `trigger_tasks` is live work, not proof there is no queued work |
| Source Alfred | `external_trigger`, `external_caller`, `paused`, `paused_by`, `running` status fields | Not exposed, even though related private tracker fields exist | Missing fields are not proof of an unowned pause or an empty request queue |
| Source Alfred | `trigger_tasks(caller, callback)` | Sets caller and pending flag immediately; optional callback overwrites existing callback; returns nil; no busy/owner validation | Nil is legacy acceptance. Caller must serialize requests and avoid overwriting any observed live/queued work |
| Source Alfred | `trigger_tasks_with_teleport(caller, callback)` | Same as above plus immediate `teleport=true` | Even when pending is hidden, the public teleport flag covers this queue window |
| Source Alfred | `pause(caller)` / `resume()` | Set/clear private pause and caller, return nil; resume has no owner check | These are mutations, not ownership locks. New handoffs do not resume a pause they never acquired |
| Source Alfred | `stock_take(caller, callback)` | Sets stocktake and pending work, replaces callback/caller, returns nil | Not a read-only inventory query; unused by this bridge |
| Source Alfred | `get_restock_items()` | Returns the live tracker table | Treat returned data as read-only; mutating it would modify Alfred |
| Source Alfred | `override_restock_item`, `clear_override`, `update_stash_count` | Validate some argument types and matching SNO; mutate the tracker; return boolean; no exclusive caller ownership | Not used by town coordination |
| Source Alfred | `check_version(string)` | Version comparison; expects string input | Metadata helper; not a capability or ownership check |
| Steroid README | `create_task(caller, on_done)`, `trigger_tasks_with_teleport`, `pause`, `resume`, `get_status` | Documented. Status includes `enabled`, `need_trigger`, `inventory_full`, `talisman_inventory_full`, `need_repair`, inventory/task counts, `trigger_tasks`, `all_task_done` | Documentation does not prove pending/owner fields. `create_task` presence is a fork hint, not authorization to resume a foreign pause |
| Captured BetterAlfred | Trigger variants, pause/resume, status, enable/disable, overlays, restock helpers, `suspend_for_external`, `clear_stale_pause` | Names confirmed by export index only in the captured build | No guessed new calls or assumptions about current pack internals |
| Source LooteerV2 | `getSettings(key)` | Returns the stored value only when truthy; stored false returns nil | A successful legacy nil is false; a thrown read is unknown |
| Source LooteerV2 | `setSettings(key, value)` | Only writes when current value is truthy; true→false works, false→true fails. Settings are rebuilt from GUI on updates | Cannot be used as a reliable pause/resume mechanism |
| Source LooteerV2 | `enabled`, `behavior`, `looting` | Settings fields. Main pulse refreshes GUI state, checks enable/behavior, then updates looting around item selection | `looting` is a compatibility flag, not an ownership token |
| Earlier runtime Looter | `get_enabled()`, `is_actively_looting()`, `is_idle()`, `has_wanted_nearby()`, `enable()`, `disable()`, `getSettings`, `setSettings` | Export names observed. Existing integration uses zero-argument dot calls for the first three | Prefer protected boolean active, then inverse idle, then legacy flag. Mutation semantics are not assumed |
| Current LooteerV3 | Pause, ownership, blacklist reset, movement target setters | Unverified/unavailable | No invented API calls; no claim that its private approach-stall algorithm was repaired |
| Patched SilentRaven | API v2 status: `enabled`, `running`, `pending`, `owner`, `managed_by`, `paused`, `paused_by`, result fields | Actual namespaced source and real-module tests | Pending queue is visible; strict owner checks reject duplicate/foreign triggers and cancellation |
| Patched SilentRaven | `trigger_tasks(caller, callback, guard)`, `set_managed`, `cancel(caller, preserve_navigation)` | Boolean acceptance; one callback per request; guard checked on progression; tri-state path preservation | WarPigs controls only its own request/management lease; no direct Looter or Alfred toggle changes |
| Batmobile | Target/path reads; pause/resume/reset/move/set-target/clear-target/long-path/traversal mutators | Actual source. Most mutators accept any non-nil caller and overwrite `tracker.external_caller`; they do not compare an owner token | A caller label is advisory. Callers must stop only their own navigation and yield before touching successor movement |
| WarPug | `status()` with `enabled`, `state` | Actual module captures settings/planner at load time | Active planner transaction wins over a new Whisper request; idle planner waits for reserved Whisper work |
| WarPigs | `status()` with `enabled`, `busy`, `manages_whispers`, `alfred_idle` | Actual module; `alfred_idle` reflects live work and the shared completed-cycle advisory grace | Planner and Raven use the same town-service boundary instead of separate contradictory sticky-flag rules |

## Actual callback order

The supplied source Alfred's completion task first resets task flags, clears `trigger_tasks`, marks `all_task_done`, and clears `external_trigger`/`external_caller`. It then invokes the callback under `pcall`, clears the callback reference afterward, and may subsequently resume Batmobile. Consequently:

- A callback observes an already-idle public status.
- Reentrant triggering from inside that callback can lose the new callback when Alfred clears the old reference afterward. Our callbacks update local state only; they do not submit a new service request or pause Alfred.
- Callback completion does not mean a newly acquired foreign movement owner may be cleared.
- The source callback does not carry a structured success result. A completed service cycle and a proven successful salvage/stash result are different claims.

Patched SilentRaven performs the opposite reference-safety step explicitly: it captures the callback, resets its request state, then invokes the captured callback. Its managed lease remains separate from request completion. The bridge's generation guards prevent a late completion from changing a later visit.

## Nine-plugin outer gate review

| Plugin | Examined outer files | Handoff conclusion |
| --- | --- | --- |
| WarPigs | `main.lua`, `core/external.lua`, `core/orchestrator.lua`, `core/tasks/turn_in_rewards.lua`, `wp_silent_raven.lua` | Main/keybind stop retries incomplete release. Outgoing activity cleanup precedes the Whisper slot; Looter/Raven traffic hold precedes Tyrael paths, service triggers, and activity teleports. Temis visit debounce ignores loading samples. Release retains the lease on unknown status and revokes its guard immediately |
| SilentRaven | `main.lua`, `silent_raven/external.lua`, `tracker.lua`, `fsm.lua`, relevant `whispers.lua` helpers | Managed mode suppresses autonomous starts. Pending/live ownership and continuation guards prevent callback replacement or concurrent acceptance; new reward acceptance requires its own interaction. Competing movement is preserved on cancellation |
| WarPug | `main.lua`, `core/external.lua`, `core/planner.lua` context/state/stop paths | Both planner-first and Raven-first execution orders are tested with actual modules. Existing planning is not invalidated by an incoming reservation, and an idle planner resumes after the Whisper result |
| WonderCity | `main.lua`, `core/task_manager.lua`, `core/utils.lua` Looter/status sections, `tasks/alfred.lua` | Reward/deadline routing can execute Alfred without calling its predicate; lost-callback recovery therefore runs in both paths. Protected status reads, no borrowed pause, and generation/plugin-instance checks added |
| ArkhamAsylum | `main.lua`, `core/task_manager.lua`, `core/utils.lua` Looter sections, `tasks/alfred.lua` | Same direct-execute recovery; rejected service requests no longer trigger its own immediate town teleport. A foreign live/queued/teleporting Alfred is checked before Batmobile pause |
| HelltideRevamped | `main.lua`, `core/task_manager.lua`, relevant `core/utils.lua`, `tasks/alfred.lua`, `tasks/helltide.lua` Looter section | Callback result changes only local service state. Trigger exceptions/rejections and malformed status are contained; existing task suspension owns route cleanup |
| HordeDev | `main.lua` outer update/export/handoff sections, `core/task_manager.lua`, relevant `core/utils.lua`, `tasks/alfred.lua`, service checks in `tasks/start_dungeon.lua` and `tasks/open_chests.lua` | RESET/sigil/entry transaction gates still precede ordinary task dispatch. Same protected Alfred request lifecycle added. Chest/exit completion remains activity-owned |
| Reaper | `main.lua` outer update/export sections, `core/task_manager.lua`, `core/navigation_owner.lua`, `tasks/alfred.lua` | Load-time dependency binding already reviewed in component pass. Additional read-error/unowned-resume/lost-callback risks were reported to the Reaper owner for its second pass; this reviewer did not edit those files |
| Batmobile | `main.lua`, `core/external.lua`; caller uses inspected in task managers | Autonomous update honors pause and loading/death gates. Its public caller labels do not create exclusive leases, so coordination remains caller-side |

## Runtime corrections owned by this pass

Changed only the authorized four `tasks/alfred.lua` files: WonderCity, ArkhamAsylum, HelltideRevamped, and HordeDev.

- Status failures or malformed `enabled` values hold the activity queue; they do not prove the companion is idle/disabled.
- Legacy nil return remains acceptance. Explicit false retires the local request and starts a five-second retry hold. A thrown trigger retains its generation and wait because it may already have queued work; only its callback or fresh stable readable idle reconciles that uncertainty. Observed `pending`, live work, or an unfinished teleport prevents resubmission.
- A request with no completion callback is not left in `WAITING` forever after Alfred becomes demonstrably quiet: allow eight seconds for initial pickup, then require two seconds of stable idle before retiring the local wait. Every intervening unknown, busy, pending, or paused observation resets that quiet interval. Completed/failed teleport latches are not treated as live movement. Retirement does not claim maintenance success and does not cancel Alfred.
- Direct `Execute()` paths apply the same recovery even when a task manager bypasses `shouldExecute()`. Arkham separately retains at most three debounced town-hop attempts for its own accepted plain-trigger request; uncertain, with-teleport, foreign, loading, paused, or pending work cannot authorize those retries.
- Callback generations, current plugin instance, and local waiting state must match. Obsolete, repeated, or replaced-plugin callbacks cannot mark a later service complete.
- WonderCity/Arkham no longer resume an Alfred pause they did not acquire. They check foreign work before pausing Batmobile. Unreadable floor loot gets a brief existing loot window after an otherwise completed callback.

## Verification and limits

`audit/tests/test_secondpass_town.lua`: 322 assertions pass at this review snapshot. This uses actual four task modules, actual SilentRaven external/tracker modules, and the actual WarPug planner/external module. It covers rejects, exceptions before/after queueing, legacy nil returns, synchronous/late/replaced callbacks, interrupted idle-confirmation intervals, pending-only status, terminal teleport latches, forced task execution, bounded Arkham town-hop recovery, foreign busy/pause/teleport guards, both planner/Whisper orderings, and clean versus contested master stop. Cross-review by the SilentRaven/Reaper reviewer identified the queue uncertainty, quiet-interval, pending, and unreachable retry cases; these regressions exercise the resulting fixes.

The same test optionally executes original Alfred and LooteerV2 source probes using `QQT_REFERENCE_ROOT`; these probes ran successfully in the provided workspace. If the original reference source is absent on another machine, those probes explicitly print `SKIP`, not a fabricated pass. They verify the real false-as-nil getter, non-restorable legacy setter, hidden Alfred pending/pause fields, nil trigger result, lack of source caller enforcement, and callback ordering.

Final targeted run passed all six files: this second-pass test, suite contracts (33 checks), WonderCity (39 scenarios), Horde audit (22 scenarios), Arkham (21 scenarios), and Helltide (16 scenarios). At that snapshot, all 201 runtime Lua files compiled. These are offline checks. No run claims live game verification, correctness of inaccessible packed item rules, or guaranteed resolution of the screenshot's proprietary LooteerV3 approach failure.

Final independent cross-review: the SilentRaven/Reaper reviewer reread all four complete changed task files, confirmed the previously reported blockers resolved, and approved freezing these diffs. No further runtime edits are pending in this reviewer's scope.
