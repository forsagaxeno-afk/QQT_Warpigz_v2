# SilentRaven (0.2.6) + WarRoom (1.0.3): session notes

## SilentRaven
- Claims Tree of Whispers rewards both under WarPigs and when a farm plugin runs standalone; auto-fire in Temis; call API `SilentRavenPlugin.trigger_tasks[_with_teleport]`, `get_status`, `pause` / `resume`.
- MOVING_TO_RIFT counts as busy (3.1.1). It works in any game language. Rosie hands off a ready reward on the return leg of a trip.
- 0.2.6: a third-party loop owning the run (`TRISTRAM_LOOP_STATE.status().owns_activity`) holds the claim trip and auto-fire / delegated auto-fire (not the manual keybind, not an external request such as Rosie's hand-off).
- 0.2.6 (auditor findings): Butler / Scavenger / Navigator (not paused, owner ≠ SilentRaven) hold every own-run admission, the mid-run yield and the claim trip; Navigator pause condition `SilentRaven` while a claim runs and does not yield; a trip counts against TRIP_LIMIT only once its teleport was tried; held auto-fire at 2 Hz; `yielding` published; cancel/disable through `fsm.finish_external`; RUN_TIMEOUT 90 s. With Worldstone the player is rarely idle in Temis: expect claims mostly from Rosie's hand-off (Rosie holds Navigator during its trip).
- Self-review 2026-09-28 (both modes, hand-off, any language): no other defect found. The owner plays a Russian client: readiness is always *inferred* there (no English turn-in text), so a Temis visit gets one NPC probe and a ready episode one claim trip (by design, C6). Selection uses SNOs / internal names only (language-independent).
- Live checks still open: the inferred path end to end on the Russian client (`reward ready (inferred …)` → `run finished: success`), a claim trip under WarPigs + Helltide, the new hold lines if Worldstone/TristramLoop runs.

## WarRoom
- Suite-wide dashboard. The `core/wr_*` collector writes `dashboard/suite_data.js` (`window.SUITE_DATA`) and persists to `data/`. Three themes (Forge / Daylight / Console); Helltide tab (`dashboard/helltide/`, which reads `../hr_data.js`).
- LAN server: `server/serve.ps1` (+ `serve.bat`, `serve-lan.bat`). It binds 127.0.0.1 by default; `-Lan` requires a token; GET/HEAD only. The scripts must keep CRLF line endings (`.gitattributes`).
- `wr_payload.lua` has `M.SUITE`: the Coordinator bumps it with each release.
- 1.0.3: set charms (QQT rarity 7) are their own `set` rarity (they were counted as unique; not on the drops list); `LooteerPlugin.status()` is no longer called (unused, and it runs Rosie's pickup `Settings.update()` + pause expiry); JSON encode ~40% cheaper (a full dashboard ~2.5 ms per write, was ~4.4 ms; persist ~2 ms per 60 s).
- 1.0.3 (auditor findings): a claim ended by `disabled` is no run; a restored scope keeps numbers only (a string counter made every payload build raise); a payload build error is logged once; a collector error sets `QQT_WarRoom.enabled = false`.
- WarRoom review 2026-09-28: figures checked against every emitter (gold/XP/obols/deaths from polls, items by rarity from `rosie.pickup`, runs from each activity's start/end events). Other plugins' status getters WarRoom must read are not all pure (BOARD request to Activities): HordeDev `status()` (exit latch, actor scan), WonderCity / Arkham `get_status()` (consume the return-window expiry). Batmobile `get_owner()` runs its one-time world sync (same as any API call).
- Known limits: a gold/XP change between the last poll and a loading screen (player nil) is not counted (the baseline restarts after a nil read; carrying it over would count a character switch).
- Open: a two-click confirm for "Reset all-time" was not added. Live checks: the gold / XP getters, `serve.ps1` on Windows PowerShell 5.1 and the firewall prompt.
