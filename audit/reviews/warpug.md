# WarPug review

Reviewed plugin: `WarPug-1.0.0` (runtime version advanced from 1.0.9 to 1.0.10).
Scope: every Lua module, saved click calibration, native QQT declarations and actual WarPigs/Alfred public integration surfaces. No supplied position values were changed.

## Proven defects fixed

| Priority | Defect and consequence | Implemented correction |
|---|---|---|
| High | Failed quest reads were interpreted as no quests; dead/missing players and world changes could leave a delayed action armed. | Require a valid, fully readable quest snapshot, a live player and the same Temis world instance. Cancel active work on invalid context; no delayed confirmation survives it. |
| High | FIND_PATH cleared any selected path, including manual choices; disable could deselect an already submitted plan. | Track the exact path selected by this planner. Preserve initial/manual selections and edits. Undo only the unchanged, unsubmitted owned path in the same safe context. |
| High | DFS accepted unknown activity names and trusted a successful select/deselect return without progress. Broken host responses could recurse indefinitely or misclassify a path. | Validate every appended/removed node, fail closed on missing names or inconsistent snapshots, bound traversal and required-pick count, and revalidate the complete path immediately before submission. The existing Nightmare Dungeon exclusion remains. |
| High | Zero required picks auto-confirmed; confirmation exceptions or a 30-second timeout returned to IDLE and could repeat an ambiguous submission. | Reject invalid/zero pick counts. Treat the documented void confirm return as submission only; wait for quests and halt instead of resending after an ambiguous result or timeout. |
| High | Rerolls ignored capture flags, attempted confirmation even after first-click failure, could fire after lengthy stalls, and restarted after the nominal ten-reroll cap. | Require both valid client-coordinate captures, fresh vendor interaction, ready war-plan data, empty owned selection and unchanged context. Only arm confirmation after successful native dispatch; enforce its four-second deadline and snapshot resolution/coordinates. Ten attempts now halt until the user toggles Enable. |
| High | An empty quest snapshot allowed WarPug to compete with WarPigs turn-in, activity cleanup or native transitions. | Consume the new real WarPigs read-only busy contract. Integration tests load actual modules from both plugins, including outgoing cleanup, cooldown, turn-in, teleport intent and optional Pit filler priority. The WarPigs-side changes were implemented by the root reviewer and independently checked by the common auditor. |
| Medium | A held test key repeatedly rerolled; enabling the planner during the calibration sequence still allowed its delayed Confirm. | Capture/test keys use press edges. Tests snapshot context and deadline, cancel on interruption, and stop the planner if Enable is switched on during a pending test. |
| Medium | Persistence assumed Windows paths, accepted malformed/out-of-range coordinates, mishandled CRLF flags and reported success after failed writes. | Resolve the actual GUI module directory; validate each persisted coordinate and require both coordinates for a saved capture flag; accept CRLF; check writes/close. Invalid live captures preserve previous coordinates. Relative positions, GUI hashes, overlays and all three keybinds remain supported. |
| Medium | Vendor approach/panel waits could repeat indefinitely. | Bound the complete planning session; report a visible stopped reason with an explicit disable/re-enable retry. |

## Integration and native input

Input remains QQT `utility.send_mouse_move` / `utility.send_mouse_click`, documented by the supplied current declarations as **game-client coordinates**. No desktop automation, focus stealing, foreground-window requirement, invented UI selector or guessed seasonal identifier was added.

Alfred coordination uses fields actually exposed by the supplied `AlfredTheButler-main/core/external.lua`: `enabled`, `trigger_tasks`, `need_trigger`, `teleport` and `teleport_done`. An optional `external_trigger` is honored if another installed version exposes it. WarPug never triggers, resumes or overwrites Alfred's caller/callback.

WarPigs gives an enabled creator priority over optional Pit filler while retaining ordinary cleanup of an already owned filler. An idle, unstarted teleport intention with no incoming quest is not a busy transaction; an actual transition, owned activity, cleanup defer, matched quest/task or handoff cooldown remains busy. This distinction avoids two circular waits in the initial handshake design.

## Validation

Command: `python3 audit/tests/run_tests.py test_warpug.lua`

Result: PASS. All runtime Lua files also compiled under Lua 5.4. The regression file executes actual WarPug planner, GUI, settings, main update callback and external module with QQT-shaped mocks. Cross-suite cases execute the actual WarPigs orchestrator, internal turn-in task and public external module, with plugin-specific require scopes modeled explicitly. Cases include:

- Real branching search/backtracking, Nightmare exclusion and void native confirmation.
- Manual selection preservation, edits between search and confirm, owned-path rollback and accepted-plan preservation.
- Missing/malformed/sparse quest data, death, unavailable player/world, changed world instance and invalid native progress.
- Ambiguous submission, zero/invalid required counts, vendor deadline and the full ten-attempt reroll cap.
- First-click failure, calibration invalidation, context loss, stale second clicks and held-key behavior.
- Actual WarPigs cleanup after 400 seconds with no quests, cooldown release, native transitions both enabled and disabled, turn-in completion with Pit filler enabled, and already-owned filler cleanup when the creator becomes enabled.
- CRLF and invalid saved calibration, module-relative file path, real settings conversion and unchanged calibration after an out-of-client capture.

## Season 15 and live limitations

The suite-level `audit/SEASON_15.md` contains the official current season/API source review. No published material supplied a replacement for `Warplans_NightmareDungeons`, `Warplans_Vendor` or `Skov_Temis`, so these existing sampled identifiers were retained. New/renamed live activities still require real QQT observations.

QQT exposes war-plan **data readiness**, not a reliable reroll-dialog visibility selector. Calibrated native rerolls therefore remain dependent on the user's verified layout and the game's dialog timing. Guards significantly reduce stale/context-invalid clicks but cannot establish that the intended dialog is visible. Actual Season 15 UI transactions, background-client delivery and changed UI scaling/layout require in-game verification.

The supplied Alfred status omits queued `external_trigger`, pause and caller fields. WarPug cannot observe that hidden queued interval directly. A permanently unsatisfiable Alfred `need_trigger` (for example unavailable restock inventory) conservatively holds creation until that work/configuration is resolved; this audit does not claim an unconditional endless-loop guarantee or infer completion from a stale `all_task_done` flag.

A halted planner requires inspecting the panel and toggling Enable. Existing manually selected paths are left for the user to clear; the plugin does not silently replace them. Full QQT per-plugin module isolation and actual installed companion versions remain live integration prerequisites.

Changed files: `WarPug-1.0.0/core/planner.lua`, `core/settings.lua`, `core/external.lua`, `gui.lua`, `main.lua`; `audit/tests/test_warpug.lua`; this review. `WarPug-1.0.0/positions.txt` is unchanged.
