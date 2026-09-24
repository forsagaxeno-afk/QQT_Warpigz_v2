# Cross-plugin feedback audit

Scope: external API dependency resolution and companion-service ownership. Independent of the Reaper, Horde, WonderCity and SilentRaven implementation owners. The only implementation change made by this reviewer is the explicitly assigned WarPug external-import fix.

## Confirmed defect: delayed imports under a foreign caller

Reaper's original `core/task_manager.lua` resolved `core.tracker` inside `reset_all()`. The reported traceback is consistent with invoking that function from WarPigs after the active module resolver/cache points at another plugin. Manual startup succeeds because Reaper's own callback context is active. Merely checking whether `reset_run` exists would suppress the exception while leaving run state uncleared.

The same pattern existed in:

- `WarPigs-1.0.0/core/external.lua`: public `status()` and `disable()` resolved `core.orchestrator` each time.
- `WarPug-1.0.0/core/external.lua`: public `status()` resolved `core.settings` and `core.planner` each time.
- Reaper navigation path loading and the Alfred task's runtime reset imports also crossed delayed callback boundaries.

Dependencies used through external callbacks should be captured while their owning plugin initializes. WarPigs GUI's circular GUI/settings/orchestrator relationship requires explicit post-bootstrap binding rather than moving its import blindly to the top.

WarPug now captures settings/planner. The focused regression changes the module resolver to throw after module initialization, then verifies that `status()` still reads the original live settings and planner state. `test_warpug.lua` passes.

## Loader evidence and limits

The supplied `qqt_extracted/diablo_qqt/scripts/ClickRevive/main.lua` and its README explicitly describe shared `package.loaded` and use unique module names. Supplied `WarPigs-2.0-main/main.lua` prepends its own search root and clears generic cached modules; its orchestrator describes a foreign-call lazy-import failure in another activity plugin. These are corroborating plugin implementations, not the native QQT loader implementation.

The native loader implementation is not available in the supplied API declarations. Startup cache isolation therefore cannot be independently proven here. The specific live report demonstrates that Reaper initially loads and works manually, supporting captured imports as the focused correction. Clearing generic cache entries globally would mutate other plugins' live dependencies; a suite-wide module rename is not justified by a single external-call failure. SilentRaven's newly namespaced modules avoid adding another generic-name collision.

## Companion contracts used for integration review

- The supplied Alfred external status omits queued `external_trigger`, `external_caller`, and `paused` fields. Unknown omitted fields must not be treated as proof of a pending request's absence. Published active/queued work must be yielded; triggering replaces the existing callback.
- Alfred `resume()` clears the caller string. Caller strings alone are not an enforceable movement lease.
- Supplied LooteerV2's setter only updates fields whose current value is truthy. Disabling it with `setSettings('enabled', false)` cannot be symmetrically reversed by the same setter. Whisper integration must not use this as a temporary pause/restore mechanism.
- LooteerV2 may retain a stale `looting` flag while disabled. Activity and service gates must require enabled state before interpreting that flag.
- Batmobile caller labels are diagnostic; a global `clear_stored_path()` or Escape press during another owner's work can interrupt that owner. Cleanup should happen only for the service's own active operation.

## Validation boundary

Offline Lua tests verify callback contracts and state transitions. No game process or native QQT loader execution is available. Actual navigation, new actor names and live reward behavior still require in-game confirmation.

## Independent implementation reviews

- Reaper: reviewed final captured dependencies and bootstrap path cache, plus the test that changes resolver context and contaminates generic cache keys. The test verifies Reaper's real tracker reset, preservation of a foreign tracker, and the recorded-path branch. No blocker found in these changes.
- Horde: reviewed exact-name Chaos Rift targeting, hostile/alive/immune/hazard gates, boss precedence, objective holding, cancellation and resumed movement. The new tests exercise both Batmobile and native movement paths. No blocker found; the precise actor in the user's reported wave is still unobserved.
- WonderCity: identified a stale loot-quiet timer when the obols branch prevented the exit predicate from observing intervening Looteer activity. The owner reports fixing the scheduler to reset the timer while obols/Alfred/live-boss work owns the reward lane and adding a scheduler regression. The reviewed chest confirmation requires the task's own interaction and subsequent stable evidence.
- WarPigs Whisper bridge: identified legacy Looteer nil-for-false handling, which otherwise makes idle legacy Looter appear unavailable and a disabled stale flag appear busy. Reported to the implementation owner for correction.
- WarPigs Whisper bridge: identified the active WarPug planning race. Whisper admission must defer to an already active table selection/reroll operation; an idle planner may be held by a pending Whisper reservation, but applying the hold after planning starts would itself force WarPug to halt. Reported to the implementation owner for correction and regression coverage.
