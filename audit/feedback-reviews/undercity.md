# Undercity completion audit — WonderCity 2.0.10

## Scope and evidence

The supplied feedback describes an Undercity boss dying without the runner recognizing the end. In this suite, WarPigs delegates Undercity to `WonderCityPlugin`; Arkham handles the Pit. WarPigs already defers the Undercity handoff until the player returns to town. No Arkham code or Batmobile pathfinding was changed.

Code inspection identified concrete failure paths, not proof of which one occurred in the reported live run:

- `utils.get_undercity_chest()` searched only ally actors. The reward chest is a gizmo and can be missing from that list. The same actor-list mismatch was already documented for the Undercity entrance.
- `boss_kill_time` was never set by an active combat task. After seeing a boss, both explorers stop exploring, so a missed reward chest leaves no productive task.
- Beacon/portal tasks precede chest cleanup and can starve it when stale objectives remain visible.
- A single empty actor enumeration following an interaction counted as a successfully opened chest.
- Normal exit used the old Looter settings flag without an independent post-opening quiet period.

## Implemented changes

- Fresh all-actor observations recognize a known boss corpse by health or a reward chest. Boss absence, loading and failed enumeration do not count as a kill. No boss or chest actor handles are retained between pulses.
- Reward cleanup owns a dedicated scheduler lane. Existing Alfred ownership and a live boss take priority; stale beacons, portal switches and goblins cannot block the chest.
- Chest lookup uses `get_all_actors()` with explicit read validity. Confirmation follows an interaction with the same chest identity, then one second of a non-interactable state, or one second of disappearance with new loot observed since the click. A replacement chest cannot inherit the prior interaction.
- Chest unlocking does not start the eight-second interaction budget. Failed confirmations remain failures, with a visible status and a diagnostic log.
- A confirmed reward is followed by three seconds of Looter inactivity. Obols, Alfred and live-boss work reset the quiet period. Read-only LooteerV3 APIs use active -> inverse idle -> legacy activity, with disabled state checked first. Unknown activity holds the normal exit.
- A first positive corpse/chest observation grants one fixed 45-second cleanup grace against the configured run timeout. It never renews on repeated scans. Once the grace expires, the configured reset remains a bounded recovery path and does not mark a failed reward successful.
- Public status exposes `boss_dead_observed`, `reward_seen`, `reward_opened`, `reward_failed`, and `completion_reason`. These are diagnostics; `reward_opened` does not mean looting or return travel is complete. Existing WarPigs town-confirmed handoff is unchanged.

## Independent review and feedback

The suite critic identified that a quiet timer could remain stale while the obols task won priority. The scheduler now explicitly resets that timer while servicing obols, Alfred or a live boss, and a scheduler-level regression covers the obols scenario. The reviewer otherwise found the interaction evidence and scan-validity handling materially safer.

The town/Looter critic confirmed `LooteerPlugin` exports from the supplied `stationary_wall_cycle.log`. Export presence, not a guaranteed ABI, is the available runtime evidence. Every optional call is feature-detected, protected, and accepted only when it returns a boolean. No pause/resume or write API was assumed, and Looter settings are not changed.

## Validation

Command:

```text
python3 audit/tests/run_tests.py test_wondercity.lua test_arkham.lua
```

Result: 38 WonderCity focused regression cases and 21 existing Arkham cases pass under Lua 5.4. Suite runtime files compile. The runner's aggregate file count can change as other audit agents add modules.

Regressions include chest visibility outside the ally list; dead versus absent/live bosses; stale objective priority; unknown/loading actor state; stable own-click confirmation; transient disappearance; replacement chest identity; failed confirmation; delayed Looter activity; V3/legacy API precedence; foreign Alfred ownership; floor resets; bounded cleanup grace; and scheduler quiet-time restart after obols work.

## Live validation still required

Run one Undercity with the user's current tribute/boss. Capture `[WonderCity:finish]` and `[WonderCity:chest]` output from boss death through chest opening, loot collection and town arrival. This confirms the actual reward actor name and lifecycle on the current game build. If the chest stays interactable or disappears without any observable loot, this build reports an unconfirmed reward rather than inventing success. The configured timeout remains a failure recovery mechanism and can eventually exit even when Looter is stuck. No live-game test has been performed here.
