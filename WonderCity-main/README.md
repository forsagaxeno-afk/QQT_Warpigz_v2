# WonderCity
#### V1.0.4
## Description
WonderCity is the new undercity utilizing a newer (and possibly more efficient) explorer (batmobile).
Fully integrated and requires Alfred the butler, Batmobile and Looter.

WARNING: the only build that I have reliably able to complete Mythic tributes is crackling sorc with both tele enchant and teleport enabled on batmobile.

## Settings
- Enable -- checkbox to enable or disable WonderCity
- Use Keybind -- checkbox to use keybind to quick pause/resume WonderCity
    - Toggle keybind - toggle pause/resume

### undercity Settings
- Batmobile priority -- set batmobile's exploration priority
    - DIRECTION -- batmobile will priortize exploring the same direction
    - DISTANCE -- batmobile will prioritize exploring furthest distance from start. May result in more backtracking
- Reset time -- how long in seconds to give up on current undercity
- Exit delay -- how long to wait in seconds before initiating exit when all task are done or when reset time is up
- Boss delay -- how long to wait in seconds before start attacking boss
- Max enticement -- maximum number of enticement to activate
- Enticement timeout -- how long to wait in seconds around enticement
- Beacon timeout -- how long to wait in seconds around beacon
- Loot obols -- checkbox to move and pick up obols
- Reorder tribute -- checkbox to use stash to reorder tributes to the first slot if first slot is not correct tribute
- Tribute 1/2/3 -- choose which tribute that should be on the first slot

### Party Settings (coming soon™)
- Enable Party mode -- checkbox to enable party specific interaction, only needed if you are planing to play in party
- Party mode -- choose whether you are the party leader (the one that will complete the undercity) or follower
- Accept delay -- choose how long to wait for followers to accept start undercity/reset undercity notification before retrying
- Follower explore? -- choose whether or not to explore undercity as follower 

## Changelog
### V1.0.4
Fix  reorder tribute triggering even when not enabled

### V1.0.3
Implemented Reorder tribute

### V1.0.2
Fix bug where exit triggered too early due to exploration is done but boss is not dead

### V1.0.1
Added safeguard to only exit if final chest is seen

### V1.0.0
Initial release

### V0.0.8
Added option to set batmobile priority
Added spirit brazier as final point in path (fix janky movement after exit)
Changed logic for enticement timeout so that it doesnt move back if timer expired while far away
Added goblins to priority for kill_monsters

### V0.0.7
increased check distance
reduce priority of loot obols below enticement
added max enticement

### V0.0.6
disable explore once boss is found

### V0.0.5
fix obols again

### V0.0.4
added goto_chest file!
fix obols not near enticement not picking up

### V0.0.3
added distance check (16) to portal and enticement.
ignore obols that spawned in beacon.
Added goto_chest task to mark as done

### V0.0.2
Priortize enticement/beacon over portal.
kill_monsters only target boss now. 
Introduced enticement/beacon delay. 
Target portal warppoint instead of just portal.
Updated enticement logic

### V0.0.1
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
- TesXter
## Current entry and audit corrections

The current tribute UI uses per-item priorities: `0` skips an item and lower positive numbers take precedence. WonderCity selects the matching inventory slot directly; the old three-slot stash-reordering workflow is no longer registered. If no selected tribute is available, entry waits. Enable **Skip tribute** explicitly for a run without a selected tribute.

Calibrate the inventory origin/cell size and portal, accept and bargain click points for your screen layout. Entry validates slot bounds, rechecks the selected item before clicking, protects actor loading windows across the entire scheduler, and preserves bargain retry order when a previous choice fails.

Floor transitions reset local navigation/objective state without extending the configured run deadline. Dead enemies no longer block reward handling. Normal exit requires successful chest handling; exploration exhaustion alone does not complete the run. Failed chest interactions remain failures until the configured reset handles the run.

### V2.0.10 feedback corrections

- Reward chests are searched in the complete actor list, including gizmos absent from the ally list.
- A fresh boss corpse or reward chest starts reward cleanup. A missing boss, missing world or failed actor read never proves a kill. Leftover portal switches, beacons and goblins cannot starve confirmed reward cleanup.
- Chest completion requires this runner's own interaction, then a stable non-interactable state, or stable disappearance accompanied by new loot. A temporary empty actor list is insufficient. Chest unlocking has its own wait; the eight-second interaction budget starts only when the chest can be clicked.
- After opening, exit waits for three seconds of Looter inactivity, restarting the quiet period after Looter, obols or Alfred work. LooteerV3 activity/idle exports are read when available, with the legacy settings fallback. No Looter settings are modified.
- Positive reward evidence grants one bounded 45-second cleanup window if the run timeout is reached. The grace never refreshes on repeated scans. An unconfirmed chest remains a failure; the configured reset can still recover the run after this window.

The public status includes `boss_dead_observed`, `reward_seen`, `reward_opened`, `reward_failed` and `completion_reason` for diagnostics. `reward_opened` is not permission to interrupt looting or the return journey. WarPigs still waits for the town return before handing off. Existing Batmobile pathfinding and Pit behavior are unchanged. These corrections are covered by offline regressions; the actual boss/chest lifecycle still needs a live run.

Alfred service cycles retain ownership of their own travel, and disabling WonderCity invalidates its pending local callbacks without pausing another caller's service cycle. Existing configuration keys, priorities and actor/item IDs are preserved.

Offline regressions are in `audit/tests/test_wondercity.lua`; detailed findings and live-validation limits are in `audit/reviews/wondercity.md` at the suite root.
