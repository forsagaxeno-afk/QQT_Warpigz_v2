# archive/: parked code (not shipped, not tested)

This folder keeps code that is **not part of the QQT_Warpigz_v3 package**. `audit/build_release.py` never ships it, `versions.json` does not list it, and the suite (`audit/tests/run_tests.py` and the source scans in the tests) neither compiles nor runs it. The only thing the suite checks here is that the code is still parked: `audit/tests/test_release_layout.lua` asserts that `archive/WarRoom/main.lua`, this README and the four archived tests exist, and that no `test_warroom_*` file is back in `audit/tests/`. Nothing in the 10 shipped plugins needs this folder.

| Path | What it is |
| --- | --- |
| `WarRoom/` | The WarRoom plugin at **1.0.6** (never released; its last release was 1.0.5 in v3.3.5). A read-only web dashboard for the whole suite (gold, XP, runs, loot, Helltide tab) with a local/LAN PowerShell server. |
| `tests/test_warroom_collector.lua`, `test_warroom_dashboard.lua`, `test_warroom_joint.lua`, `test_warroom_server.lua` | Its offline tests, moved out of `audit/tests/` so the suite does not pick them up. |

## Why it is parked

The owner asked on **2026-09-28**: "remove WarRoom from the project for now — maybe we'll use it some day, but not now". Release 3.3.6 ships 10 plugins without it. The code is kept here, unchanged, so it can come back.

What stays in the other plugins (harmless without WarRoom):

- The suite event bus (`core/qqt_events.lua` in every plugin; Rosie: `rosie/private/qqt_events.lua`; SilentRaven: `silent_raven/qqt_events.lua`). WarRoom was the only plugin that created the bus: `events.bus(true)` in `WarRoom/core/wr_collector.lua` (three call sites). Without it `emit()` returns at once and creates no global. The 10 copies stay byte-identical; their header comment still says "The collector (WarRoom) creates the bus at load". Reword it the next time the shared emitter changes for another reason (editing it touches all 10 copies and forces a bump of every plugin, Rosie included).
- HelltideRevamped's optional `_G.QQT_WarRoom` integration (`core/hr_dashboard.lua` `warroom_path()` / `warroom_on()`, and the `QQT_WarRoom` check in `gui.lua`): nil without WarRoom, so `hr_data.js` is written only by its own **Web dashboard** option (off by default). 2.6.3 reworded that option's tooltip so it no longer points users to WarRoom. A user who keeps an old WarRoom 1.0.5 folder still gets the old behaviour (WarRoom creates the bus, HR feeds its Helltide tab); the release notes tell users to delete that folder.
- `WarPigsPlugin.peek()` (side-effect-free status, written for WarRoom).

## How to bring it back

1. Move the folders back:

   ```sh
   git mv archive/WarRoom WarRoom
   git mv archive/tests/test_warroom_collector.lua audit/tests/
   git mv archive/tests/test_warroom_dashboard.lua audit/tests/
   git mv archive/tests/test_warroom_joint.lua audit/tests/
   git mv archive/tests/test_warroom_server.lua audit/tests/
   ```

   The tests use `SUITE_ROOT .. '/WarRoom/...'` paths and run unchanged once the folder is back at the top level. `run_tests.py` and the source scans in `test_joint_suite.lua` / `test_qqt_events_bus.lua` skip only `archive/`, so the top-level `WarRoom/` is compiled and scanned again by itself.

2. `versions.json`: add the component again. **Any version is accepted**: once the release base (v3.3.6 or later) no longer lists WarRoom, `check_release.py` treats it as a new component (no "must increase" check). 1.0.6 was never released, so keeping 1.0.6 is fine; a later number works too. Whatever you pick, set the same value in `WarRoom/gui.lua` (`local version = 'v1.0.6'`, which `check_release.py` compares) and in the README row (step 3). In `WarRoom/core/wr_payload.lua` set `M.SUITE` (the suite version the page shows) to the current `VERSION`.

   ```json
       "Rosie": "1.0.23",
       "WarRoom": "1.0.6"
   ```

   (add the comma after the line that is last today).

3. `README.md`: restore the component row and the dashboard section (both removed in 3.3.6):

   ```
   | `WarRoom` | Read-only web dashboard for the whole suite (gold, XP, runs, loot, Helltide); optional phone/LAN view | 1.0.6 |
   ```

   and change "Copy **only the 10 plugin folders above**" back to 11; drop the "delete an existing `WarRoom` folder" note and the "`archive` keeps the parked WarRoom dashboard" remark. The removed `## WarRoom dashboard` section is in `git show v3.3.5:README.md`. Restore part 7 of `docs/GUIDE_EN.md` and item 18 of `docs/INSTALL_RU.txt` the same way (`git show v3.3.5:docs/GUIDE_EN.md`, `git show v3.3.5:docs/INSTALL_RU.txt`) and drop their "delete the WarRoom folder" notes. If the Helltide tab returns, restore HelltideRevamped's **Web dashboard** tooltip (`git show v3.3.5:HelltideRevamped/gui.lua`) and its README item, and bump HelltideRevamped.

4. `audit/check_release.py`: re-add the WarRoom checks inside the `for folder, component_version in manifest["components"].items():` loop, before the README row check (removed in 3.3.6):

   ```python
       if folder == "WarRoom":
           # QQT_Warpigz_v3: the dashboard page and the Windows server scripts ship
           # with the plugin; the scripts must stay ASCII with CRLF line endings.
           require((ROOT / folder / "dashboard" / "index.html").is_file(), "Missing WarRoom/dashboard/index.html")
           for script in ("serve.ps1", "serve.bat", "serve-lan.bat"):
               path = ROOT / folder / "server" / script
               if not path.is_file():
                   errors.append(f"Missing WarRoom/server/{script}")
                   continue
               data = path.read_bytes()
               require(data.isascii(), f"WarRoom/server/{script} must be ASCII")
               require(data.count(b"\n") == data.count(b"\r\n") > 0, f"WarRoom/server/{script} must use CRLF line endings")
   ```

   The 3.3.6 rules for removed components and unlisted top-level plugin folders need no change.

5. `audit/build_release.py`: re-add WarRoom's generated files to `GENERATED` (removed in 3.3.6). Today the tuple ends with `"HelltideRevamped/dashboard/*.tmp")`: replace that closing `)` with a `,` and append

   ```python
                "WarRoom/dashboard/suite_data.js", "WarRoom/dashboard/hr_data.js",
                "WarRoom/dashboard/*.tmp", "WarRoom/data/*",
                "WarRoom/server/.dashboard-token", "WarRoom/server/stop.flag",
                "WarRoom/*.tmp", "WarRoom/*.log")
   ```

   Restore the WarRoom half of the comment above it too. `NEVER_SHIP` needs no change (a top-level `WarRoom/` is not in it).

6. `.gitattributes`: change the two `archive/WarRoom/server/*` lines back to

   ```
   WarRoom/server/*.bat -text
   WarRoom/server/*.ps1 -text
   ```

   `.gitignore`: change the seven `archive/WarRoom/...` lines back to

   ```
   WarRoom/dashboard/suite_data.js
   WarRoom/dashboard/hr_data.js
   WarRoom/dashboard/*.tmp
   WarRoom/data/*
   !WarRoom/data/.keep
   WarRoom/server/.dashboard-token
   WarRoom/server/stop.flag
   ```

7. Test assertions outside WarRoom's own files that 3.3.6 added or changed. Each of these fails once WarRoom is back, so drop or flip every one:
   - `audit/tests/test_release_layout.lua`
     - `COMPONENTS`: add `'WarRoom'` (11 components); rename the "10 components" / "10 plugin folders" check labels and the header comment.
     - `NEVER`: drop `'WarRoom'` (keep `'archive'`).
     - Check "versions.json lists exactly the 10 components, no WarRoom": drop `assert(not block:find('WarRoom', 1, true), ...)`.
     - Check "WarRoom is parked in archive/, not at the top level": delete it (it requires `archive/WarRoom/main.lua` and rejects `WarRoom/main.lua` and any `audit/tests/test_warroom_*`).
     - `ships` / `not_shipped` lists for `build_release.ships()`: add `WarRoom/main.lua`, `WarRoom/dashboard/index.html`, `WarRoom/data/.keep` to `ships` and `WarRoom/dashboard/suite_data.js`, `WarRoom/data/alltime.txt`, `WarRoom/server/.dashboard-token` to `not_shipped`; the `archive/...` entries can stay or go.
     - Zip check: drop `assert(not e:find('WarRoom', 1, true), 'WarRoom in the package: ' .. e)`, and flip `NOTES-WARROOM False` to `True` (the RELEASE_NOTES folder table lists WarRoom again). `NOTES-10` reads "only the 10 folders"; change the Python probe and the assert to 11 (`build_release.py` prints the count of `versions.json`).
     - Check ".gitignore / .gitattributes keep WarRoom entries under archive/WarRoom": point it back to the `WarRoom/...` lines of step 6 and drop the "stale WarRoom/ line" asserts.
     - Check "no shipped string literal points to WarRoom": skip WarRoom's own folder (`gui.lua` lines 27, 37, 38, `main.lua` lines 40, 47, `core/wr_collector.lua` line 24 and `core/wr_store.lua` line 30 name WarRoom in menu and log text), or delete the check.
   - `audit/tests/test_qqt_events_bus.lua`
     - Append `'WarRoom/core/qqt_events.lua'` to `COPIES` and `'WarRoom'` to `SHIPPED` **at the same index** (the "copies cover exactly the shipped plugins" case pairs `COPIES[i]` with `SHIPPED[i]`).
     - In that case drop `ok(not listed.WarRoom, 'WarRoom is not shipped (archived in 3.3.6)')`.
     - Case "no shipped plugin creates the bus": allow `WarRoom/core/wr_collector.lua` as the one creator (`events.bus(true)` at lines 71, 108, 320), e.g. skip that file in the `bus(true)` / `QQT_Warpigz_events` scan, and restore the header's "only WarRoom creates the bus".
   - `audit/tests/test_helltide_dashboard.lua`, case "3.3.6 package without WarRoom: …": drop `ok(not tip:find('WarRoom', 1, true), ...)` if the tooltip names WarRoom again (step 3). The rest of that case (no `_G.QQT_WarRoom` in its own session → nothing written) stays valid.
   - `audit/tests/test_qqt_events_joint.lua` (E5, E7 "without a collector") and `audit/tests/test_release_check.lua` need no change.

8. `CLAUDE.md`, `audit/BOARD.md`, `audit/INTERACTIONS.md`: give the Raven session WarRoom again (the "Raven+WarRoom" row), restore the host notes (the LAN server is a separate PowerShell script; WarRoom publishes `_G.QQT_WarRoom = {dashboard_dir, version, enabled}`; only WarRoom creates the bus), and drop the "(archived)" marks.

9. Run `python3 audit/check_release.py --base <last release>` and the full suite (`python3 audit/tests/run_tests.py --luajit require`).

Open WarRoom findings from the last review are still on `audit/BOARD.md` (collector error leaves `QQT_WarRoom.enabled` true; silent `payload.encode` failures; `M.SUITE` not checked against `VERSION`; the Activities status getters it polls are not all pure) and the withdrawn `test_warroom_joint` clock / W1 determinism requests.
