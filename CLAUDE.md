# QQT_Warpigz_v3: rules for every Claude session

Diablo IV (Season 15) bot plugins for the **QQT** Lua host. There are 10 plugin folders. `versions.json` lists each one with its version. `archive/` holds parked code that is not shipped, versioned or tested (WarRoom since 3.3.6; see `archive/README.md`); the suite only checks that it stays parked there.

The work is split across several Claude sessions. Every session reads this file first, then `audit/BOARD.md`, then the `NOTES.md` of its own plugin(s).

## The owner (user)

- Reply in **Russian**. Short, direct, no filler. Code, comments, CHANGELOG and commit messages are in **English**.
- **Every release comes with a nice English Discord changelog**, pasted in the reply: at most 2000 characters, emoji headings, and a "⬆️ Update" line saying which folders to replace. The owner said so explicitly and is tired of asking. Never skip it.
- "Сразу в релиз": when a fix is done and verified, release it. Don't ask for permission.
- The owner runs the game and sends logs and screenshots. Offline tests are not live verification, so say which live checks remain.
- **Rejected ideas. Do not build them:**
  - a Mythic item-power slider (only plain Uniques have "Keep Uniques with Item Power ≥");
  - Rosie sorting items into stash tabs.
- Other authors' addons the owner also runs have no sources (`.pak`): Navigator, Worldstone, Butler, Scavenger, TristramLoop, Universal Rotation, ClickRevive, Debug Tools. `tools/ApiProbe/main.lua` is a read-only probe that logs their published APIs and calls. It is not shipped.

## Session layout (branches)

| Session | Owns | Branch |
|---|---|---|
| Coordinator | releases, versions, CHANGELOG, Discord changelog, CI, merges, PR #1 | `claude/qqt-diablo4-plugins-orchestrator-4439v5` (release branch) |
| Rosie | `Rosie/` | `claude/qqt-rosie` |
| Helltide | `HelltideRevamped/` | `claude/qqt-helltide` |
| Orchestrator | `WarPigs/`, `WarPug/` | `claude/qqt-warpigs` |
| Batmobile | `Batmobile/` (movement/navigation used by everyone) | `claude/qqt-batmobile` |
| Activities | `ArkhamAsylum/` (Pit), `Reaper/` (bosses), `HordeDev/` (Infernal Hordes), `WonderCity/` (Undercity) | `claude/qqt-activities` |
| Raven+WarRoom | `SilentRaven/` (WarRoom archived in `archive/WarRoom` by the owner, 2026-09-28) | `claude/qqt-raven-warroom` |
| Auditor+Critic | reviews every plugin branch before release; owns `audit/BOARD.md` | `claude/qqt-audit` |

Rules:
- Work **only** in your own folder(s), your own tests (`audit/tests/test_<plugin>_*.lua`) and your own `NOTES.md`. For a change in another plugin's folder, write a request on `audit/BOARD.md` and let its session make it.
- Shared files have one owner: the Coordinator changes `audit/tests/joint_host.lua`, `audit/tests/run_tests.py`, `audit/*.py`, README, CHANGELOG, VERSION and `versions.json`. Propose changes to these on the BOARD.
- **Only the Coordinator bumps `VERSION`**. CI publishes a release from any `claude/**` branch whose VERSION has no release yet. A plugin session may bump its own component version, both in `versions.json` and in the version string it displays. The Coordinator checks this at merge.
- Before each session starts work, rebase or merge from the release branch: `git fetch origin claude/qqt-diablo4-plugins-orchestrator-4439v5`.
- When a fix is ready and tested, push it to your branch and add a line to `audit/BOARD.md` under "Ready for review". The Auditor reviews it, then the Coordinator merges, runs the full suite and releases.
- Each commit message ends with the attribution lines the harness gives you.

## QQT host constraints (hard)

- **LuaJIT 2.1 / Lua 5.1 rules**: no `goto`, no `//`, and no `table.unpack` / `table.pack` / `math.type` / `utf8`.
  - Write `table.unpack or unpack` in exactly that order; the host library scan rejects `unpack or table.unpack`.
- At most **60 upvalues per function**; the suite warns at 50, so stay under.
- At most **200 locals per function**. `HelltideRevamped/tasks/helltide.lua` has about 186 file-level locals, so add no new file-level locals there; use tables.
- `_G` is shared by all plugins. `require` resolves per plugin folder. Every plugin publishes its API as a global table (`AlfredTheButlerPlugin`, `LooteerPlugin`, `RosiePlugin`, `BatmobilePlugin`, `WarPigsPlugin`, `SilentRavenPlugin`, …).
- Host API facts:
  - `utility.send_key_press(0x1B)` is Escape.
  - `curl.http_get` is async.
  - `io.open` works.
  - There are no sockets, so no server inside QQT. (The archived WarRoom's LAN server was a separate PowerShell script.)
  - The host draws `text_2d` **under** `rect_filled`.
  - `get_gold()` and the XP getters exist but are not verified live.
- Season 15 item model:
  - A Mythic is rarity 6 plus the affix `S14_Mythic_UniquePotency` (hash 2628989).
  - The Iconic Season 14 re-issues are in `MYTHIC_SNOS`.
  - Splinters of the Prime Evils are one per character (SNO 2656952 / 2656956 / 2656962).
  - Hell's Prize (`Warplan_Helltide_HellsPrize`) costs 666 cinders.
- Suite event bus: `core/qqt_events.lua` in every plugin (Rosie: `rosie/private/qqt_events.lua`, SilentRaven: `silent_raven/qqt_events.lua`).
  - These files are **byte-identical**; a test enforces it. Change them only through the Coordinator.
  - `emit` is pcall-guarded and takes scalar fields only. No shipped plugin creates the bus now (WarRoom, its only creator, is archived), so `emit` is a no-op in the package; tests create the bus themselves.

## Tests and release tooling

- Full suite: `python3 audit/tests/run_tests.py --luajit require`, about 110 files, each run under Lua 5.4 and LuaJIT. It takes over 10 minutes; run two halves in parallel in the background.
- One file: `python3 audit/tests/run_tests.py --luajit require test_x.lua`.
- `audit/tests/joint_host.lua` is an emulated QQT host that loads the real plugins together (`J.new({rosie=true, dirs={...}, place='pit'})`).
- Every bug fix needs a **regression test that fails on the old code**. Prove it by stashing the fix, running the test and restoring the fix. Mark code changes `-- QQT_Warpigz_v3 X.Y.Z: why`.
- `python3 audit/check_release.py --base <previous release tag or sha>` checks versions, changelog and credits. `audit/build_release.py` builds the zip. Only the component folders ship; `archive/`, `tools/`, `audit/` and `docs/` do not (the user guide and install notes go in as documents). A top-level folder with a `main.lua` must be listed in `versions.json`; a component removed since the base needs no bump.
- CI (`.github/workflows/release.yml`) runs on every push to `main` / `claude/**`: checks, then the suite, then publish. It publishes only if `VERSION` is new: `X.Y.Z` is a public release marked latest, `X.Y.Z-rc.N` a private draft. Runs are serialized.
- Docs: `docs/GUIDE_EN.md` (user guide), `docs/INSTALL_RU.txt`, `audit/LIVE_CHECKLIST.md` (live checks), `AUDIT.md` (cross-plugin contracts C1…).

## Cross-plugin contracts (short)

- **Rosie ↔ farm plugins**:
  - Farm plugins read `AlfredTheButlerPlugin.get_status()`: `need_trigger`, `running`, `pending`, `paused`, `stuck`, `stuck_retry_in`, `teleport*`.
  - They request trips with `trigger_tasks[_with_teleport](caller, cb)`, where `cb(nil|'failed'|'cancelled', result)`.
  - They wait for pickup with `LooteerPlugin.is_actively_looting()` / `is_idle()`.
  - Rosie pauses Batmobile and the looter during a trip (`lifecycle.hold_peers`). It **cannot** pause the third-party Navigator; that is open work for the Rosie session.
- Rosie's automatic town trip:
  - Deferred while `TRISTRAM_LOOP_STATE.status().owns_activity`, or while a foreign pause is set: at most 60 s in town, or 600 s anywhere.
  - A latched failure is retried every 600 s.
  - Each wait is logged once: `[Rosie] Bag needs a town trip … but it waits: …`.
- SilentRaven claims Whisper rewards both under WarPigs and when you run it standalone. Rosie hands off ready rewards on the return leg of a trip (`raven_handoff`).
- WarRoom is archived (not shipped since 3.3.6). HelltideRevamped keeps its optional `_G.QQT_WarRoom` path (`hr_data.js` into `dashboard_dir`), which is a no-op while the global is absent.
