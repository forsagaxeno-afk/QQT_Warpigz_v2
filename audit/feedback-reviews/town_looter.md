# Town movement / Looteer critic

## Evidence and limits

- The supplied screenshot shows ground equipment and repeated `[LooteerV3] skip loot (4.7m) (approach_stall)` / `give up loot (4.7m) (approach_stall)` messages. The distance is unchanged across multiple messages. This establishes failed approach progress, not which plugin stopped movement.
- The screenshot alone does not establish inventory capacity, item pickup ownership, path walkability, the current town, or active movement owner.
- No LooteerV3 source was found in the local supplied files. Available related files are older `LooteerV2-main` Lua sources and `Looter-V1.6.4.pack`. There is no basis for claiming a repaired LooteerV3 internal approach or blacklist algorithm.
- The earlier supplied `upload/stationary_wall_cycle.log` (2026-09-22, another session) enumerates public exports `getSettings`, `setSettings`, `get_enabled`, `is_actively_looting`, `is_idle`, `has_wanted_nearby`, `enable`, and `disable`. It does not contain a pause/resume export. These exports are evidence for that earlier loaded Looter, not a guaranteed contract for every LooteerV3 version.

## Grounded coordination requirements

1. Feature-detect read-only Looter status. Prefer a boolean `is_actively_looting()`, then inverse boolean `is_idle()`, then the older `getSettings('looting')` contract. Honor a confirmed disabled state before a stale busy value. Treat exceptions or malformed values as unknown rather than success.
2. Do not invent a Looter pause API or use `setSettings('enabled', false)` as a pause. The supplied LooteerV2 setter tests the current value for truthiness, so a false setting cannot be restored through that setter; its settings update also rebuilds state from GUI widgets each pulse.
3. Yield our own movement, interaction, and teleport commands while another controller is actively looting. If a Whisper attempt reaches its wait limit, defer/skip the attempt, not force movement over the Looter.
4. Apply coordination to Tyrael turn-in as well as the normal Alfred town preamble. Existing `WarPigs-1.0.0/core/tasks/turn_in_rewards.lua` checks Alfred but initially has no Looter or SilentRaven guard.
5. A running SilentRaven must stop issuing new movement while Alfred or Looter acquires work. Clear only a path owned by the yielding component, and never blindly clear a shared path after another controller has taken over.
6. Own-only pause release requires both the same plugin instance and matching owner. Do not resume a foreign pause or adopt another caller's trigger/callback.

## Verification boundary

Offline tests can establish command gating, bounded waits, owner checks, and return transitions. They cannot establish whether the screenshot's ground item is collectible or whether a proprietary LooteerV3 approach bug is repaired. A current LooteerV3 package and a runtime diagnostic log are needed if the same `approach_stall` continues with the coordinated town build.

## Bridge review

Reviewed `WarPigs-1.0.0/wp_silent_raven.lua`, the orchestrator town slot and traffic gate, and SilentRaven's namespaced external API, tracker, FSM, and main pulse.

- The bridge uses the direct SilentRaven v2 queue/owner contract and the Temis zone only; there is no Loot Steward dependency.
- WarPigs reserves the Whisper slot after outgoing activity cleanup. The town traffic guard precedes its Tyrael movement, Alfred triggers, and activity teleport logic. Existing activity cleanup remains owned by its activity plugin.
- Modern and legacy Looter reads are protected. The corrected legacy branch distinguishes a successful `nil` (the older getter's representation of false) from a thrown read. It does not mutate Looter settings or invent a pause API.
- Found and fixed: `release()` discarded its plugin reference when status was unreadable, potentially stranding SilentRaven's managed lease. It now retains the reference and requests another release attempt.
- Found and fixed: failed cancellation left the continuation guard enabled after WarPigs master disable. `release()` now revokes it immediately, before cancellation. An independent Lua probe against the corrected bridge confirms both failure scenarios: unknown status retains the lease; a throwing cancel cannot keep the continuation guard authorized.
- Found and fixed by the SilentRaven implementer: disabling SilentRaven bypassed the continuation guard and could clear a successor controller's path using stale `movement_owned`. Its disabled branch now evaluates the guard before cleanup; the implementer added regression coverage.
- Found and fixed after integration: revoking the bridge guard before a clean master stop also prevented cleanup of Raven's own path. Cancellation now distinguishes explicit preservation, an omitted preservation decision that requires a fresh guard check, and explicit false from the owner after a fresh companion-idle check. The final explicit-false regression verifies cleanup after `request_revoked`.

Independent rerun: `python3 audit/tests/run_tests.py test_silentraven.lua` passes all 101 focused checks and compilation of 197 runtime Lua files at the reviewed snapshot. Two additional inline adversarial probes confirm release/reference retention and immediate guard revocation on failed cancellation.

Integration follow-up reported to root: the new pre-Whisper call to `alfred_kick_if_needed()` also runs in `POST_ALFRED_SETTLE`. Its recent-completion behavior should match the existing `alfred_idle()` grace for Steroid's documented sticky `need_trigger` state, or it can repeatedly re-trigger Alfred and skip the Whisper attempt despite a just-completed service cycle. Real `trigger_tasks`, `external_trigger`, repair, full inventory, and teleport remain blocking work.

No remaining blocker was identified in the queue acceptance / ambiguous trigger handling: an uncertain queued request is polled rather than resubmitted, callbacks are scoped by generation, and a foreign owner is not adopted or cancelled.
