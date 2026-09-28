# Third-party addons: observed APIs

These addons ship as closed `.pak` files, so nothing below comes from their sources. Everything was observed with `tools/ApiProbe` on the owner's PC. Each fact is marked **seen** (in a probe log) or **inferred**. Never call a function marked inferred without a `type(fn)=='function'` guard and a `pcall`.

Load order in the owner's log: Worldstone publishes its API early; Navigator, Scavenger and Butler load a little later (their "has loaded" lines appear about 2 s after the other plugins).

## Navigator (`_G.Navigator`)
A navigation/exploration service shared by several callers. Only one request is active at a time. A new request replaces the old one: the old one ends with "A new navigation request replaced this one." (seen)

- `Navigator.navigate(opts) -> request_id` (seen). Observed `opts` fields:
  - `owner` (string, the caller);
  - `actor_name` (skin), optionally with `interact=true` and `scene_hint="Entrance"`;
  - `position` (a vec3), optionally with `explore=false`;
  - `arrive_distance` (number);
  - `on_arrive` (function), `on_fail` (function), `is_excluded` (function).
- `Navigator.stop()` (seen; no argument). It ends the current request with "The navigation request was stopped."
- `Navigator.get_status()` (seen) returns:
  - `state`: planning / travelling / following_hint / exploring / interacting / arrived / idle;
  - `owner`, `request_id`, `is_busy`, `is_paused`, `priority` (0 for Worldstone's requests);
  - `mode`: travel / explore;
  - `remaining_distance`;
  - `last_result = {is_success, message, owner}`;
  - `frontier_count`, `walkable_cell_count`, `chunk_count`, `visited_count`, `seen_cell_count`.
- `Navigator.get_known_scenes()` (seen) returns a list of `{id, name, center, walkable_cell_count}`.
- The `is_paused` status field and the `priority` field point to a pause/resume API and prioritized requests (**inferred**). The exact function names come from the `API Navigator: …` line of the probe log (still needed).

## Scavenger (`_G.Scavenger`): Navigator's own looter
- `Scavenger.is_busy() -> boolean` (seen). Worldstone polls it about every 5 s.
- `Scavenger.pause(caller)` (seen: Worldstone calls `Scavenger.pause("Worldstone")` when it heads to the boss, `Harbinger_Center`). A `resume(caller)` presumably exists (**inferred**).

## Worldstone (`_G.Worldstone` API)
An activity bot for the S15 Worldstone capstone (`S15_Triad_B_Worldstone_UberCapstone`). It drives Navigator and pauses Scavenger. **It polls `AlfredTheButlerPlugin.get_status()` about every 5 s** (seen), so it is Alfred/Rosie-aware: it reads Rosie's status and probably reacts to `need_trigger` / `running`. Which fields it uses, and whether it calls `trigger_tasks*` itself, is still unknown.
- It returns to Temis between runs (`Skov_Temis`), then re-enters via `Prefab_Portal_Dungeon_Generic`.

## Butler (`_G.Butler`?): a Navigator-aware Rosie-like town service
No calls captured yet. The owner still needs to run one Butler town trip with ApiProbe loaded to see how it holds Navigator during the Town Portal cast.

## Consequences for this suite
1. **Rosie (town trip)**: during a trip Rosie must hold Navigator (call `stop()`, and pause it if a pause function exists) and pause Scavenger. After the trip it must resume only what it paused itself. Otherwise Navigator keeps moving the player and breaks the Town Portal cast (`teleport_failed`, live 2026-09-28).
2. **Rosie (pickup)**: while `Scavenger.is_busy()` is true, another looter owns the drops. Treat it like `TRISTRAM_LOOP_STATE.controls_loot` or a busy Batmobile: yield, and don't fight over the path.
3. **Farm plugins** (Helltide, Pit, bosses, Hordes, Undercity, Batmobile freeroam) that wait for `LooteerPlugin.is_actively_looting()` should also wait for `Scavenger.is_busy()` if the owner runs Scavenger instead of Rosie's pickup. Do this through one guarded helper per plugin.
