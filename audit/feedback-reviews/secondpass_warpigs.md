# Independent second pass: WarPigs and WarPug

## Scope and method

This reviewer did not author the new WarPigs/SilentRaven bridge or the original
WarPug planner. All 12 runtime Lua files in the two plugin folders were read
end-to-end, including GUI setup, inline callback bodies, settings, exported
surfaces and the dispatcher state machine. Changed WarPigs guard sections were
read again after fixes. This is source review plus targeted offline execution,
not proof of every possible QQT/game state or every runtime branch.

The review traced the combined sequence: quest snapshot -> outgoing activity
cleanup -> town collector/Alfred -> optional Whisper request -> reward turn-in
-> WarPug plan selection and submission -> observed quest -> next activity.
It also traced master stop, failed external disable, death, world loading,
unknown quest/status reads, stale callbacks and repeated visits.

## Complete file and function coverage

| Runtime file | Functions / contracts reviewed |
|---|---|
| `WarPigs-1.0.0/main.lua` | `main_pulse`, `render_pulse`, menu closure, update throttle, keybind gate, repeated `release_all` after failed stop, public `WarPigsPlugin` assignment. |
| `WarPigs-1.0.0/gui.lua` | Checkbox factory, `bind_orchestrator`, `render`, missing-plugin notices, tree push/pop, teleport/filler/Whisper options. |
| `WarPigs-1.0.0/core/settings.lua` | `update_settings`, `get_keybind_state`, defaults and unbound-key sentinel. |
| `WarPigs-1.0.0/core/external.lua` | `enable`, `disable`, `status`; captured dependencies, busy and Alfred-idle handshake, effective enabled/keybind state. |
| `WarPigs-1.0.0/core/orchestrator.lua` | Every helper and inline map hook; exported `tick`, `release_all`, `is_busy`, `get_status_line`, and `alfred_idle`. Detailed groups are below. |
| `WarPigs-1.0.0/core/tasks/turn_in_rewards.lua` | `log`, `now`, `alfred_idle`, `set_state`, `get_zone`, `in_town_attribute`, `find_npc`, `diagnose_missing_npc`, `tick`, `get_state`; teleport debounce, NPC interaction and stop reset. |
| `WarPigs-1.0.0/wp_silent_raven.lua` | `call`, `log`, `location`, `looter_state`, `companions_clear`, `new`; instance `cancel`, `release`, `observe`, `traffic_hold`, `tick`, `is_busy`, `blocks_plan_creator`, `status_line`; private status/active/note/finish and completion/continuation callbacks. |
| `WarPug-1.0.0/main.lua` | `tick_test`, `main_pulse`, `draw_crosshair`, `render_pulse`, menu closure; independent capture polling, disabled processing, delayed calibration confirmation and public `WarPugPlugin` assignment. |
| `WarPug-1.0.0/gui.lua` | `ck`, plugin-root resolution, fraction validation, `valid_position`, save/load positions, `fmt_pos`, `poll_keybinds` and its capture closure, `render`; client bounds, edge-trigger capture and file write failures. |
| `WarPug-1.0.0/core/settings.lua` | `update_settings`; live resolution conversion, captured-position validation and table actor identifier. |
| `WarPug-1.0.0/core/external.lua` | `status`; captured settings/planner references, simple state lookup without recursive integration queries. |
| `WarPug-1.0.0/core/planner.lua` | `now`, `log`, `vlog`, `set_state`, `halt`, `reset`, API-ready/quest/world/context guards, `read_status`, `looter_busy`, `integrations_busy`, path comparison/read/ownership/cleanup, table actor search, `find_path` and bounded DFS, coordinate validation, click/calibration helpers; exports `tick`, `get_recent_clicks`, `get_current_state`, `stop`, `get_status_line`, `click_context`, `fire_click`. |

The dispatcher helper review includes:

- Alfred completion, idle, kick and trigger functions; town and BSK predicates;
  Horde chest/aether teleport blockers and every transition timeout.
- Actor lookup; Helltide buff, time-window, incoming and combat predicates;
  Undercity destination predicate.
- Reaper run generation/reset, completion callback, run dispatch, disable gate
  and diagnostic-only altar watchdog.
- Every quest-map entry, activity priority, alias matching, normalization,
  current-entry selection and managed-plugin collection.
- Quest snapshot collection, plugin status/enable/disable helpers, quest dump,
  match function, optional plan-creator/filler handshake and stale owner cleanup.
- Every branch of the dispatcher source: adoption, preemption, outgoing disable,
  cooldown, Whisper slot, same-activity continuation, Temis/Alfred/native teleport
  transitions, internal task ticks, activity enable and master release.

Only the two intended public plugin exports are assigned by the entrypoints.
Native host APIs and other plugin exports are read as globals. Dependencies used
by exported callbacks are captured during bootstrap. The WarPug external status
function remains a simple lookup, so WarPigs -> WarPug status queries do not
recursively enter the creator's integration guard.

## Findings and response

1. **Quest-handle failures became false completion.** WarPigs skipped failed or
   empty `get_name()` results and used `ipairs`, losing sparse entries. A live
   Helltide was disabled under an unreadable snapshot. Root fixed the reader to
   return unknown for bad entries and traverse valid sparse snapshots.
2. **Loading became activity completion.** A surviving player handle plus an
   empty quest array in Limbo could disable the current owner. Root added a
   general loaded-world check before dispatch decisions, after death handling.
3. **Unknown town attribute became town arrival.** The missing-attribute fallback
   returned true and could release Pit/WonderCity in a dungeon. Root changed the
   predicate to hold when the town attribute is unavailable.
4. **Unreadable Alfred state permitted movement.** Turn-in and dispatcher idle
   helpers treated failed status reads as idle. The regression reached Tyrael
   interaction while Alfred's status threw. Root changed these paths to hold.
5. **Creator ignored completed-maintenance grace.** WarPug rechecked raw
   `need_trigger`, so sticky advisory restock flags still blocked creation after
   WarPigs considered maintenance complete. This reviewer changed WarPug to use
   `alfred_idle=true` only from an enabled dispatcher for this advisory flag.
   Running/queued work, teleport, full inventory and repair always override it.
6. **Standalone town companions were omitted.** WarPug queried only WarPigs and
   Alfred. It now also holds for running/queued SilentRaven and actual Looter
   activity; unknown companion states hold. Modern Looter exports outrank its
   potentially sticky legacy `looting` flag. The reviewer also asked the
   SilentRaven owner to guard autonomous start against an already active planner.
7. **Old Alfred callbacks survived master release.** An old completion callback
   could refresh the advisory grace in a later session. A new test reproduced
   this after `release_all`; root added generation and plugin-identity guards.
   The same regression now passes.
8. **A stale Temis zone could conceal an invalid planner world.** The creator
   accepted `Limbo`/empty names or a missing world ID if the zone still said
   Temis. Its world key now requires a finite numeric ID and a loaded world
   name; independent regressions cover these stale-zone cases.

## Targeted verification

Command:

`python3 audit/tests/run_tests.py test_warpug.lua test_secondpass_warpigs.lua`

The original WarPug suite was adjusted only to add the WarPigs module search path
required by its existing combined fixture. It covers actual DFS/backtracking,
manual selection ownership, disabled/death/loading behavior, reroll bounds,
confirmation ambiguity, calibration persistence and the actual main sequencer.

The new independent suite covers all findings above and combines the actual
WarPigs dispatcher with the actual WarPug planner and a SilentRaven public-contract
mock. That sequence checks visit stabilization, one Whisper request, no planner
confirmation during the reward task, plan submission after release, dispatching
the resulting quest once, and no repeat Whisper request on the same visit.
It also tests six live Alfred flags against advisory grace, disabled/old
dispatchers, standalone Raven ownership and modern/legacy Looter status cases.

The original WarPug suite and all **60 independent second-pass assertions pass**.
The runner also compiled all 199 runtime Lua files present at this checkpoint.
Final package validation should rerun the command above after any further edits.

The final Looter consistency check added four cases: failed modern enabled and
activity reads cannot fall back to legacy nil/false, while an explicit secondary
modern idle result can resolve an unreadable activity result. Legacy-only
successful nil remains supported.

## Limits and remaining live checks

- Supplied QQT `pathfinder.request_move` documentation says it requests movement
  only when not already moving. `clear_stored_path` documents the *custom*
  pathfinder cache; it does not establish that it cancels `request_move` or offers
  a route ownership token. No speculative shared-path clear was added. Check
  residual movement when disabling a planner that is walking to the table.
- WarPug intentionally halts on ambiguous submission, changed manual selection,
  expired delayed confirmation or invalid host data. Continuous automation does
  not mean resubmitting an outcome the host cannot confirm.
- Quest aliases marked as guesses in the dispatcher remain guesses. Unknown
  activity names and future game data require live identifiers; mocks cannot
  validate them. A plan containing an unmapped activity cannot be claimed to
  have automatic dispatcher support.
- Live QQT loading order, NPC streaming, channel behavior and reward timing need
  an in-game run. The tests demonstrate the represented contracts and failure
  cases, not exhaustive native-host behavior.
