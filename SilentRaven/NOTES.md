# SilentRaven (0.2.5) + WarRoom (1.0.2): session notes

## SilentRaven
- Claims Tree of Whispers rewards both under WarPigs and when a farm plugin runs standalone; auto-fire in Temis; call API `SilentRavenPlugin.trigger_tasks[_with_teleport]`, `get_status`, `pause` / `resume`.
- MOVING_TO_RIFT counts as busy (3.1.1). It works in any game language. Rosie hands off a ready reward on the return leg of a trip.

## WarRoom
- Suite-wide dashboard. The `core/wr_*` collector writes `dashboard/suite_data.js` (`window.SUITE_DATA`) and persists to `data/`. Three themes (Forge / Daylight / Console); Helltide tab (`dashboard/helltide/`, which reads `../hr_data.js`).
- LAN server: `server/serve.ps1` (+ `serve.bat`, `serve-lan.bat`). It binds 127.0.0.1 by default; `-Lan` requires a token; GET/HEAD only. The scripts must keep CRLF line endings (`.gitattributes`).
- `wr_payload.lua` has `M.SUITE`: the Coordinator bumps it with each release.
- Open: a two-click confirm for "Reset all-time" was not added. Live checks: the gold / XP getters, `serve.ps1` on Windows PowerShell 5.1 and the firewall prompt.
