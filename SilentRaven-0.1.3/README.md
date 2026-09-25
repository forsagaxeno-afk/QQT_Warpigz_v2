# SilentRaven 0.2.0 — WarPigs integration build

Based on magoogle's user-supplied SilentRaven 0.1.3. This build supports the current WarPigs suite directly; Loot Steward is not required. The installation folder retains its original name for replacement compatibility.

## Installation and behavior

Replace the existing `SilentRaven-0.1.3` folder with this complete folder; do not load both copies. Enable SilentRaven in its own menu and enable the SilentRaven option in WarPigs. Your existing slot priority settings retain their widget identifiers. WarPigs does not enable SilentRaven on your behalf.

WarPigs checks each settled visit to **Temis (`Skov_Temis`)**, including return visits. It reserves SilentRaven's automatic/manual execution while managing it, waits for current activity cleanup and observable Alfred/Looter work, then requests a town reward check. An orchestrated request never teleports. Other towns are ignored. Standalone manual teleport remains an explicit user action targeting Temis.

When WarPigs does not manage Whispers (option off, WarPigs disabled or absent), SilentRaven admits its own auto-fire: it waits while WarPug is mid-session (any state other than IDLE, HALTED or DONE_WAIT), while Alfred has live work (a teleport flag latched after a finished or failed trip is not live work; `inventory_full`/`need_repair` hold a new auto-fire for at most 60 seconds), while the Looter is collecting, and while an enabled WarPigs reports busy. Unreadable companion status counts as busy for at most 10 seconds. The manual keybind is deferred only by WarPug mid-session, Alfred live work or an active Looter. During its own run SilentRaven stops moving while Alfred works or the Looter collects, never clears that companion's path, and does not count the wait toward its walk, panel or run timeouts; after 120 seconds it cancels without latching the visit. A hold longer than 60 seconds is logged once and shown in `get_status().hold_reason` and the D4Remote status.

The task reads the named bounty meta quest. A known English collecting objective skips immediately; an untranslated objective can receive one bounded NPC interaction probe. Reward selection is permitted only after this task interacts with the verified Raven NPC and the real reward API reports an open panel. An already-open panel is left untouched. Slot priorities and the legendary bonus remain configurable in the existing UI.

Reward selection verifies the selected index and SNO before acceptance. It supports contiguous 1-based enumeration with 0-based selection, as documented in the supplied source, and explicit 0-based enumeration. Sparse or inconsistent layouts stop safely. Picking, claiming and verification share one rule: an entry explicitly marked invalid (`valid` false or 0) or without a readable SNO is never selected; a missing `valid` field is not a refusal, and a numeric-string SNO is accepted. The return value of `select()` is advisory (only an error or an explicit false refuses). Before accept, the re-enumerated entry at the chosen key must still carry the chosen SNO and `selected_index()` must name it, either in the 0-based selection space or in the enumerate key space; the read may settle for 0.5 seconds. When no card is usable or the selection cannot be verified, one automatic dump of every enumerated entry and field is printed per run so the host's conventions appear in the log. Receiving the chosen cache in inventory/consumables, a closed panel, and readable quest data must remain observable across two samples at least 0.5 seconds apart before success is reported. Once accept is attempted, the task never attempts it again during the same request, even if the host returns an error.

If inventory data is unavailable, acceptance is deferred. No unverified bag-capacity constant is assumed, and this plugin does not sell or salvage to make room. A full bag or unobservable receipt can result in `unconfirmed`; inspect the in-game result before another visit. The task does not open the received cache.

Navigation is bounded even when the NPC remains visible but unreachable. SilentRaven caps standalone work at 100 seconds, with up to three 20-second walk attempts, 10 seconds waiting for the reward panel, and 8 seconds verifying a sent claim. The WarPigs bridge may apply a shorter overall timeout. Each walk attempt passes the intermediate waypoint first (it avoids a wall on the direct line) unless the player is already within 9 yards of the Raven, and does not return to it once reached. A walk that gets no closer for 3 seconds is stalled: one log line (with Batmobile's read-only state) is printed per run, and while no companion can own movement the stale stored path is dropped and the move re-issued. From the second stall an unreachable intermediate is skipped, then a direct move is sent. ESC is sent only while the reward panel is observably open, so a panel timeout or a stop after accept never opens the game menu.

## Integration API (contract version 2)

All functions use dot calls. `get_status()` includes `api_version`, `enabled`, `pending`, `running`, `owner`, `managed_by`, `paused`, `paused_by`, `last_result`, `last_reason`, and `hold_reason` (the companion SilentRaven is waiting for, or nil).

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

`trigger_tasks(caller, callback, continuation_guard)` returns `true, 'queued'` only after accepting ownership. A second request cannot overwrite pending work or its callback. The guard is protected and checked before consuming the queue, every task tick, and immediately before accepting a reward. False/error revokes the request without clearing another task's path or UI; a revoked request that sent no accept does not consume the Temis visit, so the owner may ask again. Completion clears ownership before invoking the callback and invokes it at most once.

The guard may instead return `false, 'yield:<reason>'` to **pause** the request, for example while the Looter briefly collects. SilentRaven then keeps the request and its ownership, issues no move, interaction, selection or accept, and drops its movement ownership without clearing the companion's path. Paused time consumes no attempt and no walk, panel or run timeout. When the guard returns `true` again, the current step resumes: a walk heads for the same waypoint in the same attempt, and a panel step whose panel closed meanwhile goes back to the NPC. `get_status().hold_reason` shows `<reason>` while paused, including while the request is still queued. A pause is logged once at 60 s and cancelled at 120 s of continuous pause with `last_reason = 'yield_timeout'`, without consuming the visit. A definite departure from Temis still ends a paused request (`left_temis`), and disabling SilentRaven aborts it without clearing any path. After accept there is nothing left to pause, so a `yield:` answer there only lets the receipt be confirmed. Any other `false` answer keeps the revoke semantics above.

`cancel(caller, preserve_navigation)` requires the actual request owner. Passing `true` preserves global path/UI state during preemption. Omitting the flag rechecks the guard to detect a newly active competing task. Explicit `false` is for a clean owner stop after the caller has freshly verified companions are idle; it clears the owned native path even after the caller revokes its own guard. Pending requests never clear paths. `pause(caller)` and `resume(caller)` require matching ownership. `set_managed(caller, false)` releases a reservation only after its request is inactive. Reservations suppress standalone auto/manual triggers but do not override the user's enable checkbox.

With D4Remote installed, SilentRaven registers its card (retrying at 1 Hz if D4Remote loads later), pushes a flat status payload at 1 Hz, and calls `D4Remote.record_loot(category, rarity)` once per confirmed claim (rarity 5 for legendary picks, 4 otherwise).

## Catalog and module loading

All modules use unique `silent_raven.*` import names, including the GUI and catalog, to avoid shared `core.*`/`gui` cache collisions with other plugins. Replace the folder completely when upgrading.

The menu's **Reload Catalog (local)** action only reloads the local file. It never spawns a shell on the game update thread. The original optional `Updater.bat` remains for manual use, with its output path adjusted to `silent_raven/data`; it is not run by automation. The bundled catalog is sufficient to start.

## Validation and limits

`python3 audit/tests/run_tests.py test_silentraven.lua test_integration_silentraven.lua` runs the focused and integration regressions against the actual Lua modules (and the real WarPug planner in one joint case) with QQT-shaped mocks, under Lua 5.4 and LuaJIT. Tests cover ownership, queue/cancel/disable behavior, namespace collisions, Temis gating, repeat visits, localization fallback, reward selection, real receipt requirements, errors after accept, unreachable NPC timeouts, and continuation-guard preemption.

These are offline regressions, not proof of an in-game run. NPC coordinates, current host enumeration/selection conventions, bag delivery behavior, and companion status exports still need live validation. Unknown Looter status is handled conservatively by the WarPigs bridge. No undocumented Looter control function is invented.
