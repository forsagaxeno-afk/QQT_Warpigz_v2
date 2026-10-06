# Reaper feedback review

## Report and diagnosis

WarPigs reports `core/task_manager.lua:51: attempt to call field 'reset_run'
(a nil value)` while a manual Reaper start works. The delivered Reaper tracker
already defines `reset_run`; adding that function or ignoring a nil result would
not repair the underlying state reset.

`task_manager.reset_all()` instead resolved `core.tracker` and `core.utils` again
inside the external call. Those generic names can resolve another plugin's
objects when the caller's loader context or shared module cache has changed.
This matches the supplied line and the external/manual difference. The offline
regression models both a replaced `require` context and contaminated
`package.loaded` entries after Reaper bootstraps. The exact QQT loader internals
and an in-game reproduction remain unverified.

## Changes

- Bind tracker and utility modules when the task manager loads, so reset always
  clears Reaper's actual run state and boss-quest latch.
- Bind revive, Alfred handoff task helpers and material eligibility enums during
  load as well, removing the same dependency-resolution hazard from callbacks.
- Load all shipped boss path variants during Reaper bootstrap; runtime navigation
  reads its own cache. Nearest-variant selection, waypoint traversal, lookahead,
  fallback behavior and recorded path coordinates are unchanged.
- No global `require` or `package.loaded` rewriting, no missing-method suppression,
  and no changes to other plugins.

This change assumes QQT resolves a plugin's own modules correctly during its
initial load, as in the reported successful manual startup. It protects calls
after that bootstrap; it does not implement a replacement for QQT's loader.

## Verification

Command: `python3 audit/tests/run_tests.py test_reaper.lua test_reaper_feedback.lua`

Result: 66 existing Reaper behavioral assertions and 20 focused feedback
assertions pass with system Lua 5.4. The runner also compiled the runtime Lua
files present at test time successfully.

The new checks exercise external `run_once`, `run_boss`, `clear_external`, ordinary
enable/disable, startup pulses, the real recorded-path branch, material
eligibility, Alfred's synchronous handoff and clearing the actual boss-quest
latch after module-cache contamination. Foreign tracker state is left untouched
and runtime imports are rejected in the caller-context regression.

## Live follow-up

Reload the updated Reaper folder before testing; existing closures remain from
the old version until reload. Start a Reaper boss run through WarPigs, confirm it
enables without the `reset_run` error, and verify a return-to-town and a subsequent
run. Offline tests cannot establish live pathfinding or game-client behavior.
