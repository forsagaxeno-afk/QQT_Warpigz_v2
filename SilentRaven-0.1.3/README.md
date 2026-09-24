# SilentRaven 0.1.4 — WarPigs integration build

Based on magoogle's user-supplied SilentRaven 0.1.3. This build supports the current WarPigs suite directly; Loot Steward is not required. The installation folder retains its original name for replacement compatibility.

## Installation and behavior

Replace the existing `SilentRaven-0.1.3` folder with this complete folder; do not load both copies. Enable SilentRaven in its own menu and enable the SilentRaven option in WarPigs. Your existing slot priority settings retain their widget identifiers. WarPigs does not enable SilentRaven on your behalf.

WarPigs checks each settled visit to **Temis (`Skov_Temis`)**, including return visits. It reserves SilentRaven's automatic/manual execution while managing it, waits for current activity cleanup and observable Alfred/Looter work, then requests a town reward check. An orchestrated request never teleports. Other towns are ignored. Standalone manual teleport remains an explicit user action targeting Temis.

The task reads the named bounty meta quest. A known English collecting objective skips immediately; an untranslated objective can receive one bounded NPC interaction probe. Reward selection is permitted only after this task interacts with the verified Raven NPC and the real reward API reports an open panel. An already-open panel is left untouched. Slot priorities and the legendary bonus remain configurable in the existing UI.

Reward selection verifies the selected index and SNO before acceptance. It supports contiguous 1-based enumeration with 0-based selection, as documented in the supplied source, and explicit 0-based enumeration. Sparse or inconsistent layouts stop safely. Invalid reward entries are never selected. Receiving the chosen cache in inventory/consumables, a closed panel, and readable quest data must remain observable across two samples at least 0.5 seconds apart before success is reported. Once accept is attempted, the task never attempts it again during the same request, even if the host returns an error.

If inventory data is unavailable, acceptance is deferred. No unverified bag-capacity constant is assumed, and this plugin does not sell or salvage to make room. A full bag or unobservable receipt can result in `unconfirmed`; inspect the in-game result before another visit. The task does not open the received cache.

Navigation is bounded even when the NPC remains visible but unreachable. SilentRaven caps standalone work at 100 seconds, with up to three 20-second walk attempts, 10 seconds waiting for the reward panel, and 8 seconds verifying a sent claim. The WarPigs bridge may apply a shorter overall timeout.

## Integration API (contract version 2)

All functions use dot calls. `get_status()` includes `api_version`, `enabled`, `pending`, `running`, `owner`, `managed_by`, `paused`, `paused_by`, `last_result`, and `last_reason`.

```lua
local owner = 'WarPigs'
local reserved = SilentRavenPlugin.set_managed(owner, true)
local accepted, reason = SilentRavenPlugin.trigger_tasks(owner, function(result)
    -- success / skipped_not_ready / skipped_unknown / skipped_busy /
    -- skipped_latched / failed / unconfirmed / cancelled / disabled
end, function()
    -- Continuously verify that navigation and interaction are still ours.
    return true
end)
```

`trigger_tasks(caller, callback, continuation_guard)` returns `true, 'queued'` only after accepting ownership. A second request cannot overwrite pending work or its callback. The guard is protected and checked before consuming the queue, every task tick, and immediately before accepting a reward. False/error revokes the request without clearing another task's path or UI. Completion clears ownership before invoking the callback and invokes it at most once.

`cancel(caller, preserve_navigation)` requires the actual request owner. Passing `true` preserves global path/UI state during preemption. Omitting the flag rechecks the guard to detect a newly active competing task. Explicit `false` is for a clean owner stop after the caller has freshly verified companions are idle; it clears the owned native path even after the caller revokes its own guard. Pending requests never clear paths. `pause(caller)` and `resume(caller)` require matching ownership. `set_managed(caller, false)` releases a reservation only after its request is inactive. Reservations suppress standalone auto/manual triggers but do not override the user's enable checkbox.

## Catalog and module loading

All modules use unique `silent_raven.*` import names, including the GUI and catalog, to avoid shared `core.*`/`gui` cache collisions with other plugins. Replace the folder completely when upgrading.

The menu's **Reload Catalog (local)** action only reloads the local file. It never spawns a shell on the game update thread. The original optional `Updater.bat` remains for manual use, with its output path adjusted to `silent_raven/data`; it is not run by automation. The bundled catalog is sufficient to start.

## Validation and limits

`python3 audit/tests/run_tests.py test_silentraven.lua` runs 101 focused assertions against the actual Lua modules with QQT-shaped mocks. Tests cover ownership, queue/cancel/disable behavior, namespace collisions, Temis gating, repeat visits, localization fallback, reward selection, real receipt requirements, errors after accept, unreachable NPC timeouts, and continuation-guard preemption.

These are offline regressions, not proof of an in-game run. NPC coordinates, current host enumeration/selection conventions, bag delivery behavior, and companion status exports still need live validation. Unknown Looter status is handled conservatively by the WarPigs bridge. No undocumented Looter control function is invented.
