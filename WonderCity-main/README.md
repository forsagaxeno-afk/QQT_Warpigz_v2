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

The current tribute UI uses per-item priorities: `0` skips an item and lower positive numbers take precedence. WonderCity selects the matching inventory slot directly; the old three-slot stash-reordering workflow is no longer registered. An unselected tribute is never consumed. If no selected tribute is available (the shipped defaults select none, or the selected ones ran out), entry waits two seconds, logs it once and opens the Undercity without a tribute, exactly like **Skip tribute**.

Calibrate the inventory origin/cell size and portal, accept and bargain click points for your screen layout. Entry validates slot bounds, rechecks the selected item before clicking, protects actor loading windows across the entire scheduler, and preserves bargain retry order when a previous choice fails.

Floor transitions reset local navigation/objective state without extending the configured run deadline. Dead enemies no longer block reward handling. Normal exit requires reward-chest handling; exploration exhaustion alone does not complete the run. Every chest wait is bounded (see below).

### V2.0.10 feedback corrections

- Reward chests are searched in the complete actor list, including gizmos absent from the ally list.
- A fresh boss corpse or reward chest starts reward cleanup. A missing boss, missing world or failed actor read never proves a kill. Leftover portal switches, beacons and goblins cannot starve confirmed reward cleanup.
- Chest completion: our own interaction followed by a stable non-interactable state, or disappearance with new loot (1 s), or a stable disappearance of the interacted chest (5 s). A chest that stays interactable eight seconds after our interaction counts as opened (the host can keep an opened chest flagged interactable). A chest that is not interactable before our first click was already opened unless it unlocks within 10 s after an observed boss kill (30 s without one; never while a boss is alive). A reward chest that was seen and then vanished from complete actor scans for 20 s near its position counts as opened elsewhere. A temporary empty or failed actor list is never evidence. Time spent yielding to Alfred does not count toward these windows.
- An Alfred trip that leaves the Undercity (before `exit_undercity` started) is resumed when the player returns to the same world within five minutes: the run deadline, enticements and an already opened chest are kept. Opening a new portal forgets it.
- After opening, exit waits for three seconds of Looter inactivity, restarting the quiet period after Looter, obols or Alfred work. LooteerV3 activity/idle exports are read when available, with the legacy settings fallback. No Looter settings are modified.
- Positive reward evidence grants one bounded 45-second cleanup window if the run timeout is reached. The grace never refreshes on repeated scans; the configured reset recovers the run after this window. At the run timeout, only a known live Alfred cycle may hold the exit, for at most 120 s; an unreadable Alfred status never does (it counts as unavailable after 10 s).

The public status includes `boss_dead_observed`, `reward_seen`, `reward_opened`, `reward_failed` and `completion_reason` for diagnostics, plus `alfred_trip` (WonderCity's own Alfred round trip in progress), `in_run` (inside or committed to an Undercity run) and `committed_entry` (tribute used, portal opened or being entered, bounded to 60 s per attempt). `reward_opened` is not permission to interrupt looting or the return journey. WarPigs still waits for the town return before handing off. Existing Batmobile pathfinding and Pit behavior are unchanged. These corrections are covered by offline regressions; the actual boss/chest lifecycle still needs a live run.

Alfred service cycles retain ownership of their own travel, and disabling WonderCity invalidates its pending local callbacks without pausing another caller's service cycle. Existing configuration keys, priorities and actor/item IDs are preserved.

Offline regressions are in `audit/tests/test_wondercity.lua`; detailed findings and live-validation limits are in `audit/reviews/wondercity.md` at the suite root.
