# Activities: ArkhamAsylum (Pit 2.1.2), Reaper (bosses 1.10.3), HordeDev (Hordes 2.2.4), WonderCity (Undercity 2.2.3)

One session owns all four. Notes for each are below.

## ArkhamAsylum (Pit)
- In-pit pickup wait 15 s (`core/task_manager.lua:94,118`). `kill_monster.lua:123` ignores the Looter; the pickup wait is skipped when the boss is within 8 m.
- Town trips from inside the Pit go to Temis; the exit waits for the Looter.

## Reaper (bosses)
- Altar clicks and chest retries are bounded; after a death it returns to the fight; `loot_ready` waits for the Looter.

## HordeDev (Infernal Hordes)
- Pylon pause always released; the foreign Alfred pause hold is bounded (`tasks/alfred.lua`, `alfred_pause_expired`).

## WonderCity (Undercity)
- 3.2.2: a failed exit / beacon walk is set aside for 20/40/60 s and then retried (it was stuck on floor 1). Tests: `test_wondercity_bounds.lua` B1–B7.
- Town trips from Kurast hop to Temis; the caller's own travel returns.

## Open
- Nothing open from live reports right now.
