# Third-party addons: observed APIs

These addons ship as closed `.pak` files, so nothing below comes from their sources. Everything was observed with `tools/ApiProbe` on the owner's PC. Each fact is marked **seen** (in a probe log) or **inferred**. Never call a function marked inferred without a `type(fn)=='function'` guard and a `pcall`.

Load order in the owner's log: Worldstone publishes its API early; Navigator, Scavenger and Butler load a little later (their "has loaded" lines appear about 2 s after the other plugins).

## Navigator (`_G.Navigator`, v0.1.0)
A navigation/exploration service shared by several callers. Only one request is active at a time. A new request replaces the old one: the old one ends with "A new navigation request replaced this one." (seen)

Full function list (seen, `API Navigator:` line): `explore, find_path, get_known_scenes, get_path, get_status, is_busy, is_paused, is_walkable, navigate, pause, resume, set_pause_condition, stop`.

- `Navigator.navigate(opts) -> request_id` (seen). Observed `opts` fields:
  - `owner` (string, the caller);
  - `priority` (number; Butler sends `10`, Worldstone sends nothing, so its status shows `0`);
  - `actor_name` (skin) or `actor_id`, optionally with `interact=true` and `scene_hint="Entrance"`;
  - `position` (a vec3), optionally with `explore=false`;
  - `arrive_distance` (number);
  - `on_arrive` (function), `on_fail` (function), `is_excluded` (function).
- `Navigator.stop()` (seen; no argument). It ends the current request with "The navigation request was stopped."
- `Navigator.set_pause_condition(name, fn)` (seen: Worldstone registers `"Worldstone Looting"` with a function). While `fn()` returns true, Navigator is paused. This is the cleanest way for another plugin to hold Navigator.
- `Navigator.pause` / `Navigator.resume` / `Navigator.is_paused` / `Navigator.is_busy` exist (seen in the function list). Their arguments were not captured; call them only guarded (`type(fn)=='function'`, `pcall`).
- `Navigator.get_status()` (seen) returns:
  - `state`: planning / exploring / following_hint / travelling / interacting / arrived / idle / failed;
  - `owner`, `request_id`, `is_busy`, `is_paused`, `priority`;
  - `mode`: travel / explore;
  - `remaining_distance`;
  - `last_result = {is_success, message, owner}`. Messages seen: "A new navigation request replaced this one.", "The navigation request was stopped.", "The world changed before the destination was reached.", "The target was not found in the explored area.", "The character arrived at the destination.", "The character arrived and interacted with the target.";
  - `frontier_count`, `walkable_cell_count`, `chunk_count`, `visited_count`, `seen_cell_count`.
- `Navigator.get_known_scenes()` (seen) returns a list of `{id, name, center, walkable_cell_count}`.

## Scavenger (`_G.Scavenger`, v0.1.0): Navigator's own looter
Functions (seen): `get_status, get_wanted_items, is_busy, pause, resume`.
- `Scavenger.is_busy() -> boolean` (seen). Worldstone polls it about every 5 s.
- `Scavenger.pause(caller)` / `Scavenger.resume(caller)` (seen: `pause("Worldstone")`, `resume("Worldstone")`). The pause is keyed by the caller's name, so each plugin resumes only its own pause.
- **Rosie's stand-in** (Rosie 1.0.23+, only while Worldstone runs and no real Scavenger is installed) is a `_G.Scavenger` table with `_rosie = true`. Our non-Rosie plugins must treat it as absent (`rawget(t, '_rosie') == true`): Rosie's pickup is already read through `LooteerPlugin` (3.3.6).

## Worldstone (`_G.Worldstone`, v0.1.4-public)
An activity bot for the S15 Worldstone capstone (`S15_Triad_B_Worldstone_UberCapstone`). It exposes only `get_status`. It drives Navigator (no `priority`, so 0), pauses Scavenger and registers the Navigator pause condition `"Worldstone Looting"`.
- It returns to Temis between runs (`Skov_Temis`), then re-enters via `Prefab_Portal_Dungeon_Generic`.
- **It yields to town services by polling** (seen, about every 5 s): `Butler.is_busy()`, and in town `Butler.needs_visit()`; `Scavenger.is_busy()`; `AlfredTheButlerPlugin.get_status()`. In the owner's session Alfred's (Rosie's) status never showed a trip (`trigger_tasks=false`, `returned=false`), so which Alfred field makes Worldstone wait is still unconfirmed.

## Butler (`_G.Butler`, v0.1.0): a Navigator-aware Rosie-like town service
Functions (seen): `cancel, clear_restock_target, get_items, get_last_result, get_restock_items, get_status, is_busy, is_in_town, needs_visit, pause, request, resume, set_restock_target`.
- `Butler.needs_visit() -> false, {}` or `true, needs` (seen).
- `Butler.get_status()` (seen): `needs_visit, is_in_town, needs, owner="Butler", is_paused, is_busy, is_enabled, message, state="running", step (travel / blacksmith / occultist / stash), town="Temis", counts{stash, salvage, inventory, talismans, keep, sell}, obols`.

### One Butler town trip (owner's log, t = 1463 to 1482)
1. Trigger: "The inventory is full." Worldstone had already stopped its own Navigator request.
2. Butler teleports ("Waiting for the loading screen." then "Arrived in town."). The Town Portal itself does not go through Navigator, and Butler does **not** call `Navigator.stop` or `Navigator.pause`.
3. In town Butler walks with `Navigator.navigate{actor_id=…, owner="Butler", priority=10, arrive_distance=3, explore=false, on_arrive, on_fail}`: Blacksmith (salvage 14, repair), Occultist (salvage 6 talismans), Stash (36 items).
4. The whole time Worldstone polls `Butler.is_busy()` (true at 1463, 1468, 1473, 1478) and sends **no** navigate. Its next `navigate` comes at 1496, after `Butler.is_busy()` is false and `Butler.needs_visit()` is false (1482).

So Butler never fights Navigator: **Worldstone itself stands still while `Butler.is_busy()` is true.** Butler's `priority=10` protects its in-town walks against anything else.

## Consequences for this suite
1. **Rosie (town trip)**: Worldstone will not wait for Rosie unless Rosie looks busy through the one channel Worldstone reads for her, `AlfredTheButlerPlugin.get_status()`. During the whole trip (from the decision to go, through the Town Portal cast, to the return) Rosie's Alfred status must report a trip in progress the way the original Alfred does (`trigger_tasks=true`, and no `returned=true` until the end). As a belt-and-braces hold that does not depend on Worldstone: register once `Navigator.set_pause_condition("Rosie", function() return <Rosie trip in progress> end)`, call `Navigator.stop()` right before the cast when `get_status().owner ~= "Rosie"`, and `Scavenger.pause("Rosie")` / `Scavenger.resume("Rosie")`. If Rosie walks in town through Navigator, use `owner="Rosie", priority=10` like Butler.
2. **Rosie (pickup)**: while `Scavenger.is_busy()` is true, another looter owns the drops. Treat it like `TRISTRAM_LOOP_STATE.controls_loot` or a busy Batmobile: yield, and don't fight over the path.
3. **Farm plugins** (Helltide, Pit, bosses, Hordes, Undercity, Batmobile freeroam) that wait for `LooteerPlugin.is_actively_looting()` should also wait for `Scavenger.is_busy()` if the owner runs Scavenger instead of Rosie's pickup. Do this through one guarded helper per plugin.
4. **Butler and Rosie together**: if both are installed, only one should do town trips. While `Butler.is_busy()` is true, Rosie should not start a trip.
