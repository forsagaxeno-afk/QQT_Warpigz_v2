# Batmobile: session notes (current 2.2.1)

The shared movement / navigation core: explorer, pathfinding, long paths, the movement-skill catalog (evade, Warlock Rampage) and freeroam. Most activity plugins move through `BatmobilePlugin` (`set_target` / `move` / `pause` / `resume` / `stop_long_path` / `is_paused` / `get_owner`).

- Rosie pauses Batmobile during a town trip (`lifecycle.hold_peers`).
- Freeroam holds its movement 10 s for a busy Looter (`main.lua:37`).
- Known test caveat: the explorer's `pairs` order depends on the hash seed; the joint host has an `ordered_pairs` option (the old W2 flake).
- The third-party **Navigator** (with Worldstone) is a different navigator and not ours.

## Open
- The "[nav] world changed … resetting explorer" and "back in … explorer map restored (0 frontiers)" lines are normal.
