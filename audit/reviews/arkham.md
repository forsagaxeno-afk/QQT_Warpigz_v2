# Arkham Asylum dedicated review

Scope: all runtime modules, task priority, Pit entry and floor transitions, boss/reward/exit flow, Batmobile and Alfred handoffs, settings/UI and bundled Pit IDs. This is an offline code/API review; no game-client validation was possible. Existing setting identifiers, defaults, town choices, numeric Pit data and Warplans actor identifiers remain intact.

## Corrected findings

| Severity | Finding | Correction |
| --- | --- | --- |
| High | Loading frames dereferenced a missing world; lower-priority predicates never received town transitions, so blacklists, rewards and navigation memory survived into later runs. | Guard loading worlds and observe stable name/world-ID transitions before task selection. Reset task-local floor state centrally and reset Batmobile once on confirmed entry/descent. Preserve the run deadline across floors. |
| High | The configured reset deadline could not preempt boss, soul, altar or glyph tasks. | Dispatch forced exit before ordinary priorities while preserving observable in-flight Alfred work; stop navigation before channeling and retain a minimum retry window. Party follower mode also respects the configured deadline. |
| High | Exploration exhaustion was treated as completed Pit content, allowing premature exits before a portal/Guardian/reward appeared. | Normal completion requires the glyphstone; the configured reset deadline remains the escape for failed runs. |
| High | A single missing boss scan marked it dead permanently, even during temporary disappearance/streaming; remembered-boss gates then froze exploration. | Require an observed dead boss or glyphstone for completion. Missing boss memory yields to search when recovery is disabled/suppressed. |
| High | Glyph eligibility checks mutated failure counts on each scheduler poll; a live glyph handle was used as the old-level snapshot; highest-first selected container order; QQT declares a Lua table rather than a required vector wrapper. | Pure eligibility; numeric pending-attempt snapshots; retries counted only after a real attempt; explicit highest/lowest selection; support Lua tables and legacy vectors. Honor legendary conversion toggle and bound an empty glyph response. |
| High | Soul disappearance after a click discarded the XP sweep. A skipped/finished but visible soul blocked glyph work forever. | Retain the last soul position, let an in-flight channel finish, sweep after despawn, and gate glyph work on the soul task's actual pending state. |
| High | Pausing Batmobile leaves its independent long-path driver running, so old paths could interrupt reward channels or the next task. | Stop and clear movement during task handoff and stationary interactions. Preserve native traversal takeover. Release synchronously when externally disabled; never cancel Alfred's trip on its behalf. |
| High | Alfred was paused on module load/completion, unnamed/paused foreign cycles could be replaced, synchronous completion was overwritten by WAITING, and stale callbacks survived cancellation. | Local-only completion, busy-cycle yield, WAITING before trigger, generation-guarded callbacks, both supported global aliases, and explicit cancellation. Preserve callbacks across Alfred's own world transitions. |
| Medium | Portal cleanup referenced a global due to a local declared below its closure; death recovery ran before new-floor tracking; transition state was reset on a click rather than confirmed arrival. | Correct lexical scope and transition ordering; retain portal-use evidence for the arrival back-portal blacklist; debounce interactions. |
| Medium | A visible stationary boss reset its cached long-path target every poll, rebuilding A* repeatedly. | Preserve the target while the path is active; replan after an ended path or target movement. |
| Medium | Disabled Looteer could expose stale looting=true indefinitely. | Require the companion's enabled flag before honoring its busy flag. |
| Medium | Portal opening and revive calls could be repeated every pulse; teleport was retried during its known active spell. | Debounce opening/entry and checkpoint revive; preserve an active teleport cast. |
| Medium | Current-task display could retain a task that no longer qualified. | Clear the display state before each priority scan. |

## Verification

`python3 audit/tests/run_tests.py test_arkham.lua` passes 21 focused Lua 5.4 regressions. Scenarios include nil/loading worlds; deadline retention; reward preemption; navigation handoff/disable; incomplete exploration; disabled Looteer; entry debounce; same-name/different-world-ID back portals; transient boss absence and confirmed death; long-path reuse; glyph ordering, live-level mutation, actual retries, vector compatibility, empty results and legendary toggle; soul despawn/channel/sweep; heart/altar blacklist reset; exactly-once explorer resets; and preserving a foreign Alfred cycle at the reset deadline.

The independent suite contracts also pass Arkham's Alfred load/busy/reentrancy/cancellation and stale-task checks. The runner compiles every runtime Lua file before executing tests.

## Remaining limitations and preserved behavior

- Warplans actor names, town coordinates, Pit level SNOs, legendary level-45 fallback, soul channel duration/click cap, orb sweep radius and traversal approach parameters originate in the supplied source. No authoritative Season 15 QQT identifier mapping was available, so none was guessed or relabeled as verified.
- Live validation is still needed for corpse visibility, floor/world IDs, actor loading latency, reward UI behavior, party acceptance and navigation around traversal geometry. A reused name **and** world ID with no observable town transition cannot uniquely identify a new instance.
- `use_magoogle_tool` still points to explicitly unfinished upstream integration comments; no external party messaging was invented. Existing follower behavior is preserved.
- Alfred's older status API omits external caller/pending-request details. The adapter can preserve observable busy work and its own in-flight generation, but cannot identify an unreported request from another plugin.
- Disabled Looteer is handled. An enabled companion that publishes a stale looting flag has no richer progress API in this bundle; the configured Pit deadline remains the bounded escape.
- No live-game or Season 15 compatibility claim follows from the offline passing tests.
