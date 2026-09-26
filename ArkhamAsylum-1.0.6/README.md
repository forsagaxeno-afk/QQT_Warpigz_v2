# Arkham Asylum (Pit)
#### V1.0.6
## Description
Arkham Asylum is the new pit utilizing a newer (and possibly more efficient) explorer (batmobile).
Fully integrated and requires Alfred the butler, Batmobile and Looteer v2.

## Settings
- Enable -- checkbox to enable or disable arkham asylum
- Use Keybind -- checkbox to use keybind to quick pause/resume arkham asylum
    - Toggle keybind - toggle pause/resume

### Pit Settings
- Batmobile priority -- set batmobile's exploration priority
    - DIRECTION -- batmobile will priortize exploring the same direction
    - DISTANCE -- batmobile will prioritize exploring furthest distance from start. May result in more backtracking
- Pit level -- which pit level to run
- Reset time -- how long in seconds to give up on current pit
- Exit delay -- how long to wait in seconds before initiating exit when all task are done or when reset time is up
- Exit mode -- choose to either exit by reset dungeon or teleport out
- Return for loot -- checkbox to return for loot after alfred is done or abandon remaining loot on floor to start new pit
- Enable shrine interaction -- checkbox to interact with shrine while exploring pit
- Enable glyph upgrade -- checkbox to choose to upgrade glyphs or not
- Upgrade mode -- choose between upgrading higest glyph first or lowest glyphs first
- Upgrade threshold -- only upgrade glyph have have upgrade % > than threshold
- Minimum level -- only upgrade glyphs that are >= minimum level
- Maximum level -- only upgrade glyphs that are <= maximum level
- Upgrade to legendary -- choose to upgrade glyph to legendary or not

### Party Settings
- Enable Party mode -- checkbox to enable party specific interaction, only needed if you are planing to play in party
- Party mode -- choose whether you are the party leader (the one that will complete the pit) or follower
- Accept delay -- choose how long to wait for followers to accept start pit/reset pit notification before retrying
- Follower explore? -- choose whether or not to explore pit as follower 

## Changelog
### V1.0.6
Added option to set batmobile priority
Set portal priority to be higher than follower afk (so that follower still goes in portal)

### V1.0.5
fix missing betrayer eye due to blizzard making it not interactable

### V1.0.4
optimized enter pit
removed raycast check for monsters

### V1.0.3
Reduced distance for disabling batmobile's movement spell to <= 4 so that it still uses movement spell to close the gap until distance of <= 4.
It improves movement to shrine/portal/glyphs for both evade spiritborn and other classes

### V1.0.2
Disable batmobile's movement spell while navigating to shrine and glyph (for evade spiritborn)

### V1.0.1
Disable batmobile's movement spell while navigating to portal (for evade spiritborn)

### V1.0.0
Initial release

### V0.0.1 - V0.0.11
Beta test

## To do
Magoogle D4 assistant integration

## Credits
In no particular order, the following have provided help in various form:
- Zewx
- Pinguu
- NotNeer
- Letrico
- SupraDad13
- Lanvi
- RadicalDadical55
- Diobyte
## Audit corrections

Pit floor changes now reset navigation and per-floor interaction state while preserving the configured run timeout. Loading screens pause task dispatch. Normal exit waits for the glyphstone; exhausting the exploration map alone no longer abandons a run. The reset timeout can preempt boss and reward tasks.

Glyph upgrades support the documented Lua table API and older vector wrappers, select the requested highest/lowest level explicitly, and count actual upgrade attempts rather than scheduler polls. Soul consumption retains its final XP sweep if the actor despawns. Heart, altar and shrine failure state is cleared between floors/runs.

Disabling Arkham stops its pending navigation and invalidates its own Alfred callback without pausing a foreign Alfred service cycle. Existing configuration keys, defaults, Pit level identifiers and Warplans interactions are preserved. The Magoogle integration remains an upstream TODO.

### Integration review fixes

- Alfred: a finished cycle's 30 s grace for a sticky `need_trigger` (for example a restock item missing from the stash) survives task switches, so Arkham no longer re-triggers Alfred in a loop. Restock or stash flags alone never pull the bot out of a pit; a full inventory or repair still does. A paused Alfred with only advisory work counts as idle. With a full inventory or repair pending, Arkham waits up to 60 s and shows the reason in its status. An unreadable Alfred status holds at most 10 s and never blocks the reset-timeout exit.
- Returning to the same pit after an Alfred trip resumes the run: the reset timeout, boss and glyph state, and the back-portal blacklist of a floor reached through a portal are kept, and Arkham does not reset Batmobile. Batmobile hands back the explored map when the floor is re-entered near the point it was left within 5 minutes (Alfred's return portal). If Alfred's callback arrives in town before its return portal, Arkham holds for up to 30 s (shown in its status, logged) instead of walking to the obelisk, teleporting away or resetting Batmobile; a failed return ends the hold at once. Opening a new pit always starts a new run.
- The Awakened Glyphstone is used before any inventory trip. Both the glyph upgrade and a new Alfred trip yield to an active Looter, with a bound so a stuck Looter cannot hold the pit.
- Hand-off to Alfred, disabling Arkham, and a WarPigs release always hand Batmobile back through `BatmobilePlugin.release` (or stop Arkham's own long route on older Batmobile builds) and restore the default explorer priority. Orbwalker block-movement is released on every task switch and on release, even if "Manage orbwalker" was unticked in the meantime. Time spent yielding to Alfred or Looter no longer counts toward walk or stuck timeouts.
- `enable()` works with "Use keybind" ticked but no key bound (logged once). `ArkhamAsylumPlugin.get_status()` additionally reports `alfred_trip`, `in_run` and `committed_entry`.

Offline regression coverage is in `audit/tests/test_arkham.lua`, `audit/tests/test_integration_arkham.lua` and `audit/tests/test_integration_arkham_batmobile.lua` (the real Batmobile plugin loaded alongside Arkham); the dedicated findings and live-validation limits are in `audit/reviews/arkham.md` at the suite root.
