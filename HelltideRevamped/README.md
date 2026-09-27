# HelltideRevamped

Helltide farming with chest collection, regional patrols, optional Maiden runs,
Alfred service trips, and Batmobile navigation. Existing setting keys, routes,
chest names and cinder costs are preserved.

## Chest detection

Discovery combines the host actor list with the documented loot-and-chest list.
Only names already listed in `data/enums.lua` receive a cinder cost. The nearest
eligible chest is chosen after checking interactability, affordability, range
and its temporary blacklist. Opened chests no longer hide another chest of the
same type. Once selected, a chest is tracked by name and position.

Chests within 50 units use direct approach; remembered chests within 150 units
use the existing recall navigation. An affordable chest seen beyond the direct
range is remembered for recall. A chest that rejects six interaction attempts
is skipped for 60 seconds so the patrol can continue.

If a chest is still missed, enable **Debug settings → Draw chest status** and
capture the console output near that chest:

- `[CHEST SCAN]` reports the chest toggle, cinders, recognized actors,
  interactable actors, affordable actors, actors within 50 units and blacklisted
  actors. These counts are independent, not a sequential filtering funnel.
- `[CHEST UNKNOWN]` records an unrecognized Helltide/reward-gizmo skin, its
  interactability and distance. Each skin is logged once per session.
- `[CHEST RETRY LIMIT]` identifies a recognized chest whose interaction was
  repeatedly rejected.

Scan diagnostics run at most once every five seconds. Unknown actors are never
assigned a guessed cost or opened merely because their name mentions Helltide.
If `known=0`, attach the unknown-skin lines and a screenshot showing the chest's
actual cost. If the host exposes the actor in neither documented list, this
plugin cannot discover it from those lists.

## Navigation and companion plugins

Patrol routes cover the existing `Frac_`, `Scos_`, `Kehj_`, `Hawe_` and `Step_`
regions. Unsupported regions use Batmobile free exploration. Existing explicit
zone overrides and exclusions remain in `data/zone_overrides.lua`; these are
source-provided coordinates, not newly validated seasonal data. Batmobile is
needed for the unsupported-region exploration fallback and traversal-aware
long-distance navigation.

Alfred handles salvage when enabled. Helltide yields to an existing Alfred
cycle, including hosts that do not expose its caller. Completion callbacks
update Helltide state without pausing Alfred. Disabling Helltide invalidates
outstanding callbacks and pending chest/search state, and stops movement it
issued. A disabled Looteer with a stale `looting` flag no longer blocks Helltide.

Only a hard Alfred need (`inventory_full` or `need_repair`, or the local item
count when Alfred publishes no inventory view) sends Helltide to town, and it
still does so at once. An advisory flag alone (`need_trigger` next to
`inventory_full`/`need_repair` that are both off, or the legacy fork's
`restock_count`) never starts an Alfred trip from inside a helltide: restock
waits for the next inventory-full or repair trip, or for WarPigs' Temis visit,
so standalone Helltide does not restock for those flags while it farms. A
provider that publishes only `need_trigger` keeps it as its town signal, at
most once per 30-second grace after any finished cycle. A teleport flag left
over from a finished or failed trip is not treated as work. An unreadable Alfred status
holds for at most about 10 seconds; a pause set by another plugin holds a
pending town request for at most 60 seconds.

Time spent yielding to Looteer or Alfred does not count toward the chest,
chest-recall, traversal or patrol stuck timers, so a reachable chest is no
longer blacklisted right after a long Looteer pickup. After a Batmobile
give-up the town teleport is retried every 6 seconds while the Helltide buff
is still present, and no Alfred round trip starts from inside the trap. During
minutes 55-59 Helltide teleports to the idle town first and asks Alfred for
salvage only after arriving. Search teleports wait up to 20 seconds for an
active Looteer pickup. After an external enable (WarPigs) without the buff,
search waits up to 15 seconds for the buff before teleporting away. Every HR
session starts with a Batmobile exploration reset, and disabling Helltide
releases Batmobile and turns orbwalker clear back on and movement unblocked
when **Manage orbwalker** is on, or when Helltide itself forced them (the
cinder gate's clear OFF) before the option was switched off. `HelltideRevampedPlugin.status().hold` names any Looteer/Alfred hold, and
holds longer than a minute are logged once a minute.

**Search after a trap recovery** (QQT_Warpigz_v3 3.1.0). After a Batmobile
trap the search scans the other towns once (`skip_cached_zone set — cycling
...` once per scan) and, when the abandoned zone is the only Helltide, returns
to it right after the last hop (`no other Helltide found — returning to
<zone>`). A second trap in the same hour returns without another scan (`<zone>
is the only Helltide this hour (scanned) — returning without another scan`). A
return fired while you are still in the Helltide's zone but outside its area
really teleports (a channel that ends within 12 m of where it started counts as
interrupted and is fired again, at most 5 times). Four returns that never show
the Helltide buff, or a refused waypoint to this hour's only Helltide, make the
search wait for the next hour (logged once) instead of scanning towns that
cannot hold it. The hour's zone and the trap skip belong to the UTC hour in
which the buff was seen, so a new hour forgets last hour's zone (`new Helltide
hour — forgetting last hour's zone <zone>`), while a WarPigs enable or a
re-enable inside this hour's Helltide keeps it. After 3 scans in an hour that
find nothing (a Helltide in a region without a patrol loop), scans wait 240 s
instead of 45 s. `Helltide is not active, wait until helltide starts` prints
once per idle window.

**Tears (Farm mode).** A tear closes while you stand inside its golden
circle and enemies die there. The bot keeps the tear it engaged until that
tear closes, standing on it (a push of up to 2 m is not corrected, a push
further out walks back), then goes to the next tear. A tear's charge counts
as full only at 99+ (0-100 reading) or when a 0.99-1.0 reading holds for 1 s
(earlier a 0-100 charge read as closed at 1 %). Only the time inside the
circle counts: a tear still open after 90 s inside (or 30 s inside without
any charge/health change once its reading was seen to change), one it cannot
get closer to for 15 s, or one engaged for 150 s is skipped (logged once);
the rupture keeps its 300 s cap, and the Realmwalker wait and fight after it
get their own 180 s. While a tear is engaged no chest is
opened (the chest waits until the tear is closed). Rosie's pickup is paused
for the whole tear event, not only inside a tear (`[RIFT] Pausing Looter
pickup until the tear event is over`): from the arrival at the rupture
through the cultists, the tears, the linger and the Realmwalker wait and
fight, but only while you are at the event (within about 45 m of the ring,
at an engaged tear, or next to the Realmwalker). The walk there (a ring with
open tears is engaged from up to 110 m), a walk back after a revive and the
town are never paused, so Rosie still takes what you pass on the way. The
event is over when the Realmwalker
dies, or when none showed up within 10 s after the rupture completed (a
Normal rupture, or Fight Realmwalker off: when the rupture completes). The
pause is refreshed every 5 s, lasts at most 300 s for the tears and 180 s
for the Realmwalker, and is
released on every way out: rupture left or abandoned, reset, zone change,
Helltide end, Warplan, disable, WarPigs taking over, death, and a script
reload. Then the bot walks to each drop Rosie wants inside the event area
until she picks it up (`[RIFT] Tear event over (...) — collecting its
loot`; at most 10 s per drop and 45 s in all) and moves on from where the
last drop was, without walking back to the ring. The
Deathtoll Chamber keeps only the per-tear pause. WarPigs runs Helltide in
Warplan mode, which never enters tears.

**Do Maiden** takes priority over chest selection while its conditions hold.
Use **Disable Maiden at Cinders** to release Maiden farming for chest spending.
The existing Chaos Rift option still uses its source-provided seasonal name;
its presence in the menu is not proof that the activity exists this season.

## Smart farm, stats and live data (QQT_Warpigz_v3)

Everything below sits behind menu options with safe defaults and works with
only HelltideRevamped + Rosie + your combat script (WarPigs is not needed).
When WarPigs drives Helltide (Warplan) the cinder plan, the smart chest
order, road routing and the event radius are bypassed and the plain order
runs as before; stats, the overlay, the dashboard, chest-spot learning, the
Helltide boundary learning and the live zone hint stay on (they only watch).

**The Helltide hour is UTC.** Helltides run minutes 0-54 of every UTC hour.
The plugin used to read the local minute, which is 30 minutes off in
half-hour time zones (India, parts of Australia, Newfoundland): it idled in
town for 5 minutes in the middle of every Helltide, searched during the real
55-59 break, and stopped events at the wrong minute. The hour, the break, the
events cut-off and the chest resets now follow the UTC minute.

### Smart farm menu (Farm mode)

In Farm mode the menu has one **Smart farm** section, in the order of a
Helltide: the goal, how to farm, how to move, then **Advanced** (tuning).
Warplan mode (and WarPigs, which always runs Warplan) does not show it; its
options stay under **Settings**.

**1. Goal: farm cinders, then open chests**

- **Farm cinders until** (on) with **Cinders** (2000): below the goal the bot
  only farms (tears first, below) and opens no Helltide chest; the chests it
  passes are remembered and learned. At the goal it goes on a chest run:
  Hell's Prize (666) > Mystery (250) > the rest, nearest first along the
  road (details under *Cinder run* below), until the cinders fall below the
  cheapest chest; then it farms up to the goal again. **Spend all in the
  last (min)** (5, at least 2): in the last minutes of the Helltide it spends
  whatever it holds, so no cinders are lost at the hour's end. Untick the
  goal to open chests as soon as they are affordable (the old way); then
  **Keep 250 for a Mystery chest** (the former *Cinder plan*, on) is shown.
  The goal replaces **Farm Cinder Threshold (beta)** in Farm mode: that
  option (stay next to an almost affordable chest and fight there) parked
  the bot at a chest for minutes and is now Warplan only.

**2. How to farm: tears first**

- **Hunt tears** (on): tears are the best cinder farm. The bot goes to every
  tear it finds (Advanced: **Tear search distance**, 110 m) before anything
  else, then collects the event's drops and walks on. With no tear in
  sight it farms monsters along the patrol road: after 25 s of fighting in
  one spot (a stream of plain monsters, e.g. round a chest) it moves on along
  the road and passes plain monsters until it is 50 m away (at most 45 s;
  elites, champions and bosses are still fought; your rotation still kills
  what it passes), so it finds
  the next tear instead of standing still (`[KILL MONSTERS] Farm: 25 s of
  fighting in one spot — moving on along the patrol road ...`).
- **Stand on chargeable tears**, **Fight Realmwalker**, **Open tear chests**
  (all on) and **Skip legacy Helltide events** (on: no flame pillars /
  pyres) tune the tear event (see *Tears* above).

**3. Movement and logic**

- **Smart chest order** (on): Mystery chests first, chests you saw before
  learned (predicted) spots, then the nearest by travel (patrol road metres
  for far chests). The current target is kept unless another one is of a
  better kind or less than half as far, and the target changes at most 3
  times a minute: no ping-pong across the map. An affordable chest right next
  to you (15 m) is opened on the way when the goal (or, goal off, the 250
  rule) allows it.
  Distances are 3D, like the chest trip itself: a chest on a ledge above you
  is not "right next to you".
- **Chest resets**: at UTC :00/:15/:20/:30/:40/:45 (helltides.com rotation
  timing, needs a live check), or when a chest opened earlier is seen closed
  again, regular chests not seen since are dropped and fresh Mystery chests
  come first again (`[CHEST ORDER] Chest reset at :15 ...`). A Mystery spot
  you opened yourself this hour is expected back only once that spot was seen
  closed again after an opening, including after a reset (opened at :10,
  seen closed at :16); whether they respawn within the hour is not
  confirmed yet. A Mystery chest in sight is always a candidate.
- **Road routing** (on): chests more than 100 m away are reached along the
  patrol loop the shorter way round, leaving it only for the last stretch
  (at most 80 m). Stuck off the road, the bot walks back to the road and
  tries another way at least 30 m further along (up to 3), then gives up on
  the chest for 60 s as before; the way that worked is remembered. Within
  150 m a road that is more than 2.5 times the straight distance is not used.
  Zones without a loop (Nahantu, Skovos) keep the direct recall. A chest trip
  that fails (stuck, no progress, too far) is not picked again for 60 s; a
  chest the bot got stuck on 3 times in a Helltide is left alone for the rest
  of that Helltide and the next one (counted by the hour, in whatever zone
  you are at the hour change and across restarts).
- **Learn while farming** (on): every Helltide chest seen becomes a spot of
  its zone (`learned/<zone>.txt`, at most 200 spots); spots seen in at least
  two chest rotations are routed to later without blind exploring, and a
  spot found empty counts as a miss. Also learned: where the Helltide buff is
  and where it dropped (the Helltide boundary, 20 m cells) and the chests
  trips got stuck on (4 m cells, one count less for every Helltide without a
  new failure there).
- **Stay inside the Helltide** (on): chests and events outside the learned
  Helltide area are skipped; a chest trip on which the buff stayed away for
  3 s is not tried again for 3 minutes, and after 2 such trips not again in
  that Helltide. A buff that is back within 3 s (a buff-list refresh) only
  interrupts the trip.
- **Pin the target on the map** (off): the game's map pin marks the chest the
  bot is walking to.
- **Forget learned data (this zone)** clears that zone's file.

**Advanced** (sliders): **Tear search distance** (110), **Pass-by distance**
(50: while walking to a chest only a tear this close is taken), **Ritual
stay radius** (12), **Hold-area tolerance** (2), **Linger after last tear**
(5 s), **Realmwalker wait** (25 s), **Pause tears at cinders** (0 = off; the
goal already stops new tears while the run has a chest to go to), **Max
carry above reserve** (150, goal off only), **Event radius** and **Events
until minute** (legacy events only).

- **Keep 250 for a Mystery chest** (goal off only; the former *Cinder
  plan*, same setting): keeps 250 cinders for a Mystery chest you can still
  reach before the Helltide ends, counting what you are expected to earn
  until the last minutes start (your recent cinders per minute). A regular
  chest is opened when the reserve stays, when you carry more than the
  reserve plus **Max carry above reserve** (150), when the expected income
  refills the reserve before the last minutes, or in the last **Spend
  all in the last (min)** (5) minutes. With 250 in hand and a Mystery
  you can reach, the Mystery comes first: no regular chest may take the
  balance below 250 on the way. No more walking past chests with 600
  cinders; nothing is left unspent at minute 55.
- **Event radius** (40 m, Warplan 12 m) and **Events until minute** (45):
  pyres and flame pillars within reach (Farm mode: only when **Skip legacy
  Helltide events** is unticked or **Hunt tears** is off; the
  skip is on by default, as in 3.0.0, and tears in reach are always taken
  before events). The bot goes to the event it chose
  (not a spent one next to it); the walk is given up after 45 s and the
  whole event after 4 minutes, and an event given up on is skipped for 3
  minutes. New Helltide event skins are logged once with **Draw chest
  status** on (`[EVENT SKIN] ...`).

### Cinder run (Farm: the goal; Warplan: Spend cinders on chests at)

In Farm mode the run is the Smart farm goal (**Farm cinders until**, on by
default). In Warplan mode and under WarPigs it is **Settings → Spend cinders
on chests at** (off by default, unchanged). Both use the same amount,
**Cinders** (2000; it was 3000 — a value you set yourself is kept). With the
run on the bot saves up and then spends:

- **Saving**: below the set amount no Helltide chest is opened. The chests
  you pass are remembered (and learned) so the run can go back to them; the
  log says so once per Helltide (`[CINDER RUN] Saving cinders for the run at
  2000 (have 420): chests are remembered, not opened; ...`). Cinders are lost
  when the Helltide ends, so in its last minutes (**Spend all in the last
  (min)**, at least 2; Warplan: under the option) the savings are spent in the run's order. Not
  under WarPigs: its Helltide step (War Plan quest *Helltide Harvest*,
  spend 250 cinders, 750 on Elite, on Tortured Gifts) ends as soon as those
  cinders are spent and WarPigs then leaves the Helltide, so saving would
  stall the War Plan and strand the savings. Under WarPigs chests are opened
  as before and the run starts only when you already hold the amount.
- **The run**: once you hold that many cinders (and a known chest is
  affordable) the bot goes on a chest run in this order:

1. **Hell's Prize** (666 cinders), the chest of the War Plan Helltide node
   *Hell's Prize* (actor `Warplan_Helltide_HellsPrize`, also the
   `_PreTorment` variant; the 666 cost is the game data lock cost). The
   actor only spawns when the node is taken, so a Hell's Prize in sight is
   what counts. A learned Hell's Prize spot is skipped while the War Plan
   read says the node is not taken (an unknown read keeps it); the start log
   says what the read gave (`Hell's Prize node taken / not in the War Plan /
   unknown`; English client only).
2. **Mystery chests** (Tortured Gift of Mysteries, 250).
3. The rest, nearest first (patrol-road metres for far chests).

It uses the chests in sight, the remembered chests and the learned spots
(Hell's Prize spots are learned as their own kind), with the smart chest
order's bounds: a failed or stuck trip is not retried for 60 s, a chest the
bot got stuck on 3 times is skipped, trips that leave the Helltide are
dropped, and without a road route nothing beyond 150 m is picked. A chest
right next to you is opened on the way only if the run's target stays
affordable after it. From the moment the run is due no new tear is hunted
(a tear already started is finished); tears are hunted again as soon as
the run finds no chest to spend on (they bring cinders). The run ends when
your cinders fall below the cheapest known chest (`[CINDER RUN] Done: below
the cheapest known chest (75); cinders 3012 -> 60`), and starts again only
at the threshold. Switching the option off ends it at once in every mode
(`Done: the option was switched off`). A task reset (town trip, death) in
the same Helltide hour resumes it while a known chest is still affordable,
in every mode. Hell's Prize chests are opened only by this run; with the
option off nothing changes. With the run on, the 250 reserve rule (*Keep
250 for a Mystery chest*) is not used: the run's order already puts a
Mystery before the regular chests. After the run has spent every known
chest it keeps the rest for the next chest it finds and hunts tears
meanwhile. The overlay's Plan row shows `Cinder run: ...` while it runs and
`Saving cinders for the run at 2000` while it saves. The save phase also
holds the Helltide chests next to a tear event (*Open tear chests*); the
free Pandemonium chests are still opened.

### Live data & stats menu

- **Live Helltide zone (internet)** (off): asks helltides.com (or the
  diablo4.life tracker, which currently sends no Helltide zone; helltides.com
  is then asked for that hour) which region has the Helltide this hour, and the
  search teleports there directly instead of trying the towns one by one.
  Only the zone is read, nothing about you is sent. One small request at a
  time: at the start of an hour every minute until the zone is known, then
  nothing until the next hour; failures back off up to 15 minutes. A zone
  that shows no Helltide buff on arrival is ignored for the rest of the hour
  (a corrected answer naming another zone is still used).
  There is no public source of chest positions in world coordinates, so chest
  positions are learned in game (above). Needs the host's `curl` API.
- **Stats overlay** (on): a sectioned panel: region and RUNNING / SEARCHING /
  IDLE; Helltide time left and the chest-reset wave (both with a bar);
  CINDERS (balance, per minute and hour, a bar to the next goal: the target's
  cost, the cinder run's threshold or the Mystery reserve, and this Helltide's
  earned / spent / lost); NOW (activity, movement, in Helltide, plan); TARGET
  (chest and cost, distance, seen or learned, position); STATS (chests,
  Mystery, earned, spent, lost, deaths, time and cinders per minute for this
  Helltide, the session and all time); OPENED THIS WAVE (the last three with
  age and position, and how many known chests are still to open). Rebuilt at
  most 4 times a second. Position and rows (All / Helltide only: the STATS
  table shows this Helltide only / Compact: timers and cinders) are
  adjustable.
- **Web dashboard** (off): writes `dashboard\hr_data.js` every 10 s (5-60).
  Open `HelltideRevamped\dashboard\index.html` in a browser straight from the
  disk (no server, no internet). Pick a look with the theme switcher at the
  top of the page (**Forge** · **Daylight** · **Console**); the browser
  remembers it and `index.html` opens that theme next time (Forge if it
  cannot remember, e.g. when it blocks storage for local files). Every theme
  shows the same data. It reloads by itself every 5 s and shows:
  the chest-reset and Helltide-end countdowns (UTC, from your computer's
  clock), cinders against the current goal, chests this session and all
  time; a map drawn like the in-game map (drag to pan, wheel or +/- to zoom,
  Fit, Follow, Border, Coords, a site filter) with the zone's patrol road,
  the learned Helltide border, your position and trail, the target with a
  line to it, every known chest site (`#id Name cost`, coloured opened /
  target / seen / learned), ruptures seen this hour and the Blood Maiden;
  the NOW card (activity, target, source, distance), the stats table (this
  Helltide / session / all time), the chests opened this wave, recent events,
  the Helltide history and the slowest code sections. *Background* lets you
  pick a local map image and calibrate it with two points (kept in that
  browser only).
- **Reset all-time stats** clears the all-time totals and the history.

Files are written only while the plugin is enabled: `learned\stats.txt` and
`learned\<zone>.txt` every 5 minutes (only when something changed), when a
Helltide ends and when you switch the plugin off; `dashboard\hr_data.js` only
with the dashboard on. Every file is bounded (512 KB, the dashboard 256 KB);
a file that cannot be written three times in a row is not tried again that
session (one log line). A save goes to `<file>.tmp` first and replaces the
file only when complete; if the file itself cannot be written, the `.tmp`
copy stays and is read at the next load. A file that exists but cannot be
read (locked by another program, over 1 MB) is never overwritten that
session; **Forget learned data** and **Reset all-time stats** still replace
it. `HelltideRevampedPlugin.status().stats` adds `cinders_per_min`,
`earned`, `spent`, `lost` (session).

Still to confirm in game: the chest reset minutes and whether a Mystery chest
comes back within the hour; whether cinders vanish exactly at minute 55 (that
decides "lost"); the Season 15 Helltide event skins; the Rampage spell name
and cast; whether `os.rename` exists (saves fall back to a direct write); the
live sources' availability.

## Compatibility and tests

No Season 15 actor IDs, chest costs, buffs, waypoints or seasonal interactions
have been invented. The supplied QQT API confirms the actor and loot discovery
methods; actual current-season actors, chest prices, routes and combat behavior
still require an in-game check.

From the suite directory, run:

```sh
python3 audit/tests/run_tests.py test_helltide.lua
```

The offline regressions cover chest discovery and selection, completed and
rejected interactions, cinder loss, recall, cache invalidation, cancellation,
diagnostics, zone search, teleport debounce, movement handoff and settings.
The smart farm has its own: `test_helltide_clock.lua`, `test_helltide_stats.lua`,
`test_helltide_cinder_plan.lua`, `test_helltide_chest_order.lua`,
`test_helltide_roads.lua`, `test_helltide_atlas_fence.lua`,
`test_helltide_live.lua`, `test_helltide_dashboard.lua` and the joint-host
Farm hour `test_helltide_standalone_smart.lua` (HelltideRevamped + Rosie +
Batmobile, no WarPigs).
