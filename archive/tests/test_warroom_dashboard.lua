-- QQT_Warpigz_v3: WarRoom suite dashboard pages (WarRoom/dashboard/*.html, app.js,
-- base.css) and the Helltide map pages moved into WarRoom/dashboard/helltide/.
-- Static checks only: every SUITE_DATA field the app reads exists in the schema
-- sample (the lane contract, embedded below), no external resources, titles,
-- theme switchers, reload interval, and the Helltide pages read ../hr_data.js.
-- Runs under Lua 5.4 and LuaJIT.
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/WarRoom/dashboard/'
local checks, cases, failures = 0, 0, {}
local function ok(cond, message)
    checks = checks + 1
    if not cond then error(message or 'assertion failed', 2) end
end
local function eq(actual, expected, message)
    checks = checks + 1
    if actual ~= expected then
        error((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
end
local function case(name, fn)
    cases = cases + 1
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS WarRoom dashboard: ' .. name)
    else failures[#failures + 1] = name; print('FAIL WarRoom dashboard: ' .. name .. ': ' .. tostring(err)) end
end
local function read(rel)
    local f = assert(io.open(ROOT .. rel, 'rb'), 'missing ' .. rel)
    local text = f:read('*a'); f:close()
    return text
end
local function has(text, needle) return text:find(needle, 1, true) ~= nil end

-- The suite_data.js schema sample (lane contract, scratchpad/suite/ux/suite_data.js).
local SCHEMA = [==[
/* QQT_Warpigz_v3 suite dashboard: FAKE sample of dashboard/suite_data.js.
   Written by WarPigs (the orchestrator owns the file; plugins report through
   WarPigs' ledger API). One assignment, no functions, bounded to 512 KB.
   Times are epoch seconds (UTC); durations are seconds; the page formats them.
   Privacy: no character/account/battletag name, no realm, no file paths,
   no chat text, no screen captures. Items carry only in-game names/stats. */
window.SUITE_DATA = {
  v: 1,                                   // schema version; the page refuses v > known
  t: 1790500500,                          // written at (epoch s): drives the "stale" banner
  write_every: 15,                        // s between rewrites (5-60); stale after 3x, offline after 20x
  suite: "3.0.4",                         // suite version (no user data)

  session: {
    start: 1790476440,                    // this bot session (WarPigs enabled)
    uptime: 24060,                        // s since start
    active: 22540,                        // s spent inside an activity or its town trip (excl. idle/waits)
    status: "running",                    // running | paused | idle | stopped | error
    now: {                                // live "what the bot does now"
      plugin: "arkham", activity: "pit",
      title: "The Pit · Tier 98", step: "Floor 3 of 4 · fighting", progress: 0.62,
      since: 1790500180, eta: 190,        // s into the run / s est. remaining (null = unknown)
      zone: "The Pit"
    },
    next: [                               // WarPug war plan queue (top 3)
      { plugin: "helltide", activity: "helltide", label: "Helltide (starts in 12 m)", at: 1790501220 },
      { plugin: "arkham",   activity: "pit",      label: "Pit T98 (3 of 3 left)" },
      { plugin: "rosie",    activity: "town",     label: "Town: salvage + stash" }
    ],
    warplan: { name: "Weekday mix", step: 9, steps: 14 }
  },

  /* Same block per scope. The page's Session / Today / All-time switch picks one.
     "today" resets at local midnight on the bot PC; "alltime" since first install. */
  scopes: {
    session: {
      totals: { gold: 186420000, gold_spent: 21800000, xp: 1.94e9, levels: 0, paragon: 7, deaths: 2,
                obols: 1840, materials: 312, glyph_xp: 0 },
      rates:  { gold_hr: 27900000, xp_hr: 2.9e8 },
      /* per activity: runs = started, ok = finished with loot, failed = aborted/died/timed out */
      activities: {
        pit:       { runs: 7, ok: 6, failed: 1, time: 2485, avg_time: 355, best: 101, best_label: "Tier",   extra: { glyphs_up: 5 } },
        helltide:  { runs: 2, ok: 2, failed: 0, time: 6600, avg_time: 3300, best: 1120, best_label: "Cinders", extra: { chests: 23, mystery: 4, cinders: 1980 } },
        undercity: { runs: 1, ok: 1, failed: 0, time: 540,  avg_time: 540, best: 4, best_label: "Floor",  extra: { attunement: 3 } },
        hordes:    { runs: 3, ok: 3, failed: 0, time: 2340, avg_time: 780, best: 8, best_label: "Wave",   extra: { aether: 2100, council: 3 } },
        bosses:    { runs: 11, ok: 11, failed: 0, time: 1980, avg_time: 180, best: 0, best_label: "",     extra: { by_boss: { Duriel: 5, Andariel: 4, Belial: 2 } } },
        whispers:  { runs: 4, ok: 4, failed: 0, time: 0,    avg_time: 0,   best: 0, best_label: "",       extra: { caches: 4 } }
      },
      items: {
        looted: 438,
        by_rarity: { mythic: 2, unique: 14, legendary: 96, rare: 212, magic: 114, common: 0 },
        greater_affix: { ga1: 31, ga2: 6, ga3: 1 },
        salvaged: 262, sold: 131, stashed: 43, kept: 2
      },
      hourly: [                             // one row per clock hour of the scope (max 48 in session/today, 30 days in alltime = per day)
        { t: 1790474400, gold: 12.1e6, xp: 1.6e8, items: 38, act: { pit: 0, bosses: 3 } },
        { t: 1790478000, gold: 31.4e6, xp: 3.3e8, items: 71, act: { pit: 2 } },
        { t: 1790481600, gold: 28.8e6, xp: 2.4e8, items: 90, act: { helltide: 1 } },
        { t: 1790485200, gold: 34.9e6, xp: 3.6e8, items: 64, act: { hordes: 2, whispers: 2 } },
        { t: 1790488800, gold: 22.0e6, xp: 2.1e8, items: 58, act: { bosses: 8, undercity: 1 } },
        { t: 1790492400, gold: 29.6e6, xp: 3.1e8, items: 81, act: { helltide: 1, whispers: 2 } },
        { t: 1790496000, gold: 18.2e6, xp: 2.2e8, items: 22, act: { pit: 3, hordes: 1 } },
        { t: 1790499600, gold: 9.4e6,  xp: 0.9e8, items: 14, act: { pit: 2 } }
      ]
    },
    today: {
      totals: { gold: 241900000, gold_spent: 30100000, xp: 2.61e9, levels: 0, paragon: 9, deaths: 3, obols: 2410, materials: 420, glyph_xp: 0 },
      rates:  { gold_hr: 26100000, xp_hr: 2.8e8 },
      activities: {
        pit:       { runs: 9, ok: 8, failed: 1, time: 3190, avg_time: 354, best: 101, best_label: "Tier", extra: {} },
        helltide:  { runs: 3, ok: 3, failed: 0, time: 9900, avg_time: 3300, best: 1120, best_label: "Cinders", extra: {} },
        undercity: { runs: 1, ok: 1, failed: 0, time: 540, avg_time: 540, best: 4, best_label: "Floor", extra: {} },
        hordes:    { runs: 4, ok: 3, failed: 1, time: 3100, avg_time: 775, best: 8, best_label: "Wave", extra: {} },
        bosses:    { runs: 15, ok: 15, failed: 0, time: 2700, avg_time: 180, best: 0, best_label: "", extra: {} },
        whispers:  { runs: 5, ok: 5, failed: 0, time: 0, avg_time: 0, best: 0, best_label: "", extra: {} }
      },
      items: { looted: 571, by_rarity: { mythic: 2, unique: 19, legendary: 127, rare: 271, magic: 152, common: 0 },
               greater_affix: { ga1: 40, ga2: 8, ga3: 1 }, salvaged: 341, sold: 172, stashed: 55, kept: 3 },
      hourly: []
    },
    alltime: {
      since: 1787900000,
      totals: { gold: 4.82e9, gold_spent: 0.61e9, xp: 5.3e10, levels: 12, paragon: 188, deaths: 41, obols: 38100, materials: 9120, glyph_xp: 0 },
      rates:  { gold_hr: 24400000, xp_hr: 2.7e8 },
      activities: {
        pit:       { runs: 212, ok: 197, failed: 15, time: 75300, avg_time: 355, best: 104, best_label: "Tier", extra: {} },
        helltide:  { runs: 61, ok: 58, failed: 3, time: 198000, avg_time: 3246, best: 1310, best_label: "Cinders", extra: {} },
        undercity: { runs: 37, ok: 35, failed: 2, time: 20100, avg_time: 543, best: 4, best_label: "Floor", extra: {} },
        hordes:    { runs: 88, ok: 80, failed: 8, time: 68000, avg_time: 773, best: 8, best_label: "Wave", extra: {} },
        bosses:    { runs: 402, ok: 398, failed: 4, time: 72000, avg_time: 179, best: 0, best_label: "", extra: {} },
        whispers:  { runs: 140, ok: 140, failed: 0, time: 0, avg_time: 0, best: 0, best_label: "", extra: {} }
      },
      items: { looted: 14920, by_rarity: { mythic: 23, unique: 488, legendary: 3310, rare: 7120, magic: 3979, common: 0 },
               greater_affix: { ga1: 1030, ga2: 188, ga3: 21 }, salvaged: 8810, sold: 4700, stashed: 1310, kept: 100 },
      hourly: []
    }
  },

  /* Notable drops only (mythic, unique, legendary with GA or 925+, anything stashed): newest first, max 200. */
  drops: [
    { t: 1790499930, rarity: "unique",    name: "Tyrael's Might",           ga: 2, power: 925, src: "pit",      act: "Pit T98",          fate: "stashed" },
    { t: 1790497710, rarity: "legendary", name: "Gloves of the Illuminator", ga: 1, power: 925, src: "pit",     act: "Pit T98",          fate: "stashed" },
    { t: 1790494320, rarity: "mythic",    name: "Harlequin Crest",          ga: 1, power: 925, src: "helltide", act: "Helltide · Kehjistan", fate: "stashed" },
    { t: 1790491880, rarity: "unique",    name: "Ring of Starless Skies",   ga: 0, power: 925, src: "whispers", act: "Whisper cache",    fate: "stashed" },
    { t: 1790490110, rarity: "unique",    name: "Shroud of False Death",    ga: 3, power: 925, src: "bosses",   act: "Duriel",           fate: "stashed" },
    { t: 1790489420, rarity: "legendary", name: "Ring of the Sacrilegious Soul", ga: 2, power: 925, src: "undercity", act: "Undercity F4", fate: "stashed" },
    { t: 1790486300, rarity: "unique",    name: "Banished Lord's Talisman", ga: 1, power: 925, src: "hordes",   act: "Hordes wave 8",    fate: "stashed" },
    { t: 1790480950, rarity: "mythic",    name: "Shattered Vow",            ga: 0, power: 925, src: "bosses",   act: "Andariel",         fate: "stashed" },
    { t: 1790479200, rarity: "legendary", name: "Paingorger's Gauntlets",   ga: 1, power: 925, src: "pit",      act: "Pit T96",          fate: "salvaged" }
  ],

  /* What happened, newest first (max 300). kind: run_ok | run_fail | run_start | helltide_hour | town | drop | death | level | alert | plan */
  timeline: [
    { t: 1790500180, kind: "run_start", plugin: "arkham",   act: "pit",       text: "Pit Tier 98 started" },
    { t: 1790499930, kind: "drop",      plugin: "rosie",    act: "pit",       text: "Unique · Tyrael's Might (2 GA) stashed" },
    { t: 1790499880, kind: "run_ok",    plugin: "arkham",   act: "pit",       text: "Pit Tier 98 done in 5:31 · glyph upgraded", dur: 331 },
    { t: 1790499300, kind: "town",      plugin: "rosie",    act: "town",      text: "Town trip: salvaged 24, sold 9, stashed 2", dur: 118 },
    { t: 1790498700, kind: "run_ok",    plugin: "arkham",   act: "pit",       text: "Pit Tier 98 done in 5:49", dur: 349 },
    { t: 1790498010, kind: "run_fail",  plugin: "arkham",   act: "pit",       text: "Pit Tier 101 failed: timer ran out on floor 4", dur: 900 },
    { t: 1790497400, kind: "death",     plugin: "arkham",   act: "pit",       text: "Died on floor 4 (Tier 101)" },
    { t: 1790496200, kind: "run_ok",    plugin: "hordedev", act: "hordes",    text: "Infernal Hordes wave 8 cleared · council 1", dur: 790 },
    { t: 1790495800, kind: "plan",      plugin: "warpug",   act: "plan",      text: "War plan step 7 of 14: Hordes x1" },
    { t: 1790494900, kind: "run_ok",    plugin: "helltide", act: "helltide",  text: "Helltide done · 12 chests · 1,120 cinders", dur: 3300 },
    { t: 1790494320, kind: "drop",      plugin: "rosie",    act: "helltide",  text: "Mythic · Harlequin Crest stashed" },
    { t: 1790492200, kind: "run_ok",    plugin: "raven",    act: "whispers",  text: "Whisper cache x2 turned in" },
    { t: 1790489900, kind: "run_ok",    plugin: "wonder",   act: "undercity", text: "Undercity floor 4 cleared", dur: 540 },
    { t: 1790488900, kind: "run_ok",    plugin: "reaper",   act: "bosses",    text: "Duriel x5, Andariel x3 killed", dur: 1440 }
  ],

  /* Session strip: contiguous blocks for the day-strip chart (max 200). act "town"/"travel"/"idle" draw neutral. */
  strip: [
    { a: "bosses", s: 1790476440, e: 1790477000 }, { a: "town", s: 1790477000, e: 1790477200 },
    { a: "pit", s: 1790477200, e: 1790479900 }, { a: "town", s: 1790479900, e: 1790480100 },
    { a: "bosses", s: 1790480100, e: 1790480600 }, { a: "travel", s: 1790480600, e: 1790481800 },
    { a: "helltide", s: 1790481800, e: 1790485100 }, { a: "town", s: 1790485100, e: 1790485300 },
    { a: "hordes", s: 1790485300, e: 1790486900 }, { a: "whispers", s: 1790486900, e: 1790487300 },
    { a: "idle", s: 1790487300, e: 1790487700 }, { a: "bosses", s: 1790487700, e: 1790489360 },
    { a: "undercity", s: 1790489360, e: 1790489900 }, { a: "town", s: 1790489900, e: 1790490100 },
    { a: "travel", s: 1790490100, e: 1790491600 }, { a: "helltide", s: 1790491600, e: 1790494900 },
    { a: "whispers", s: 1790494900, e: 1790495400 }, { a: "hordes", s: 1790495400, e: 1790496200 },
    { a: "pit", s: 1790496200, e: 1790499300 }, { a: "town", s: 1790499300, e: 1790499420 },
    { a: "pit", s: 1790499420, e: 1790500500 }
  ],

  /* Problems a human might need to act on. level: info | warn | error. Cleared ones kept 1 h with resolved:true. */
  alerts: [
    { t: 1790498010, level: "warn",  plugin: "arkham", code: "pit_timeout", text: "Pit T101 failed; WarPug stepped down to T98", resolved: false },
    { t: 1790493100, level: "warn",  plugin: "batmobile", code: "stuck", text: "Stuck 42 s near Kehjistan waypoint; unstuck by re-path", resolved: true },
    { t: 1790476440, level: "info",  plugin: "rosie", code: "stash_space", text: "Stash tab 3 is 90% full", resolved: false }
  ],

  /* Per-plugin cards: health + a few plugin-owned figures (key/value, max 8 each). */
  plugins: {
    warpigs:   { name: "WarPigs",          role: "Orchestrator",        state: "running", ver: "3.0.4", kv: [["Lease holder","ArkhamAsylum"],["Switches","21"],["Recoveries","1"]] },
    warpug:    { name: "WarPug",           role: "War plans",           state: "running", ver: "3.0.4", kv: [["Plan","Weekday mix"],["Step","9 / 14"],["Loops","0"]] },
    rosie:     { name: "Rosie",            role: "Town & pickup",       state: "idle",    ver: "3.0.4", kv: [["Town trips","14"],["Bag","21 / 33"],["Stash free","37"]] },
    batmobile: { name: "Batmobile",        role: "Navigation",          state: "running", ver: "3.0.4", kv: [["Distance","41.2 km"],["Stucks","3"],["Unstuck ok","3"]] },
    helltide:  { name: "HelltideRevamped", role: "Helltide",            state: "idle",    ver: "3.0.4", kv: [["Chests","23"],["Mystery","4"],["Cinders","1,980"]] },
    hordedev:  { name: "HordeDev",         role: "Infernal Hordes",     state: "idle",    ver: "3.0.4", kv: [["Aether","2,100"],["Council","3"]] },
    reaper:    { name: "Reaper",           role: "Bosses",              state: "idle",    ver: "3.0.4", kv: [["Duriel","5"],["Andariel","4"],["Belial","2"]] },
    wonder:    { name: "WonderCity",       role: "Undercity",           state: "idle",    ver: "3.0.4", kv: [["Best floor","4"],["Attunement","3"]] },
    arkham:    { name: "ArkhamAsylum",     role: "The Pit",             state: "running", ver: "3.0.4", kv: [["Glyphs up","5"],["Tier now","98"],["Best","101"]] },
    raven:     { name: "SilentRaven",      role: "Whisper rewards",     state: "idle",    ver: "3.0.4", kv: [["Caches","4"],["Grim favors","0 / 10"]] }
  },

  /* Unchanged HR_DATA payload from HelltideRevamped/core/hr_dashboard.lua (map layers,
     chests, cinders, clocks...). Kept in its own file dashboard/hr_data.js so the
     Helltide tab can reuse the existing map code as-is; here only a summary. */
  helltide: { file: "hr_data.js", active: false, next_in: 720, zone: "Kehjistan", cinders: 0 }
};
]==]

-- ── a small parser for the JS object literal above (comments, unquoted keys) ──
local function parse_js_literal(text)
    local pos = text:find('=', (text:find('window.SUITE_DATA', 1, true))) + 1
    local function skip()
        while true do
            local s = text:match('^[ \t\r\n]*()', pos); pos = s
            if text:sub(pos, pos + 1) == '//' then pos = (text:find('\n', pos, true) or #text) + 1
            elseif text:sub(pos, pos + 1) == '/*' then pos = assert(text:find('*/', pos + 2, true), 'open comment') + 2
            else return end
        end
    end
    local value
    local function key()
        skip()
        local q = text:sub(pos, pos)
        if q == '"' or q == "'" then
            local e = assert(text:find(q, pos + 1, true)); local k = text:sub(pos + 1, e - 1); pos = e + 1; return k
        end
        local k = assert(text:match('^[%a_][%w_]*', pos), 'key expected at ' .. pos); pos = pos + #k; return k
    end
    value = function()
        skip()
        local c = text:sub(pos, pos)
        if c == '{' then
            local t = {kind = 'object', fields = {}}
            pos = pos + 1; skip()
            while text:sub(pos, pos) ~= '}' do
                local k = key(); skip()
                assert(text:sub(pos, pos) == ':', ': expected at ' .. pos); pos = pos + 1
                t.fields[k] = value(); skip()
                if text:sub(pos, pos) == ',' then pos = pos + 1; skip() end
            end
            pos = pos + 1
            return t
        elseif c == '[' then
            local t = {kind = 'array', items = {}}
            pos = pos + 1; skip()
            while text:sub(pos, pos) ~= ']' do
                t.items[#t.items + 1] = value(); skip()
                if text:sub(pos, pos) == ',' then pos = pos + 1; skip() end
            end
            pos = pos + 1
            return t
        elseif c == '"' or c == "'" then
            local e = assert(text:find(c, pos + 1, true)); pos = e + 1; return {kind = 'scalar'}
        else
            local lit = assert(text:match('^[%w%.%+%-]+', pos), 'value expected at ' .. pos); pos = pos + #lit
            return {kind = 'scalar'}
        end
    end
    return value()
end

-- Every node of the tree (objects and array elements), so a relative path
-- such as 'totals.gold' or 'extra.chests' can start anywhere.
local function nodes_of(root)
    local list = {}
    local function walk(n)
        list[#list + 1] = n
        if n.kind == 'object' then for _, c in pairs(n.fields) do walk(c) end
        elseif n.kind == 'array' then for _, c in ipairs(n.items) do walk(c) end end
    end
    walk(root)
    return list
end
local function resolves(node, parts, i)
    if i > #parts then return true end
    if node.kind == 'array' then
        for _, item in ipairs(node.items) do if resolves(item, parts, i) then return true end end
        return false
    end
    if node.kind ~= 'object' then return false end
    local child = node.fields[parts[i]]
    return child ~= nil and resolves(child, parts, i + 1)
end

local THEMES = {'forge', 'daylight', 'console'}
local function no_external(page, name)
    for _, bad in ipairs({'http://', 'https://', 'src="//', "src='//", 'href="//', "href='//", '@import', 'url(', 'fetch(',
        'XMLHttpRequest', 'WebSocket', 'EventSource', 'sendBeacon', '<img'}) do
        ok(not has(page, bad), name .. ': no external resources: ' .. bad)
    end
    for src in page:gmatch('src="([^"]*)"') do ok(not src:match('^%a+:'), name .. ': local src ' .. src) end
    for href in page:gmatch('href="([^"]*)"') do ok(not href:match('^%a+:'), name .. ': local href ' .. href) end
end

case('the schema sample parses', function()
    local tree = parse_js_literal(SCHEMA)
    eq(tree.kind, 'object', 'root')
    for _, k in ipairs({'v', 't', 'write_every', 'session', 'scopes', 'drops', 'timeline', 'strip', 'alerts', 'plugins', 'helltide'}) do
        ok(tree.fields[k] ~= nil, 'schema has ' .. k)
    end
    ok(resolves(tree, {'scopes', 'session', 'items', 'by_rarity', 'mythic'}, 1), 'nested path resolves')
    ok(not resolves(tree, {'scopes', 'session', 'items', 'nope'}, 1), 'bad path does not resolve')
end)

case('every SUITE_DATA field app.js reads exists in the schema sample', function()
    local app = read('app.js')
    local nodes = nodes_of(parse_js_literal(SCHEMA))
    local seen = 0
    for fn, path in app:gmatch('%f[%w_]([%a]+)%([^,()]+,%s*\'([%w_%.]+)\'') do
        if fn == 'get' or fn == 'num' or fn == 'nz' or fn == 'arr' or fn == 'obj' or fn == 'str' then
            seen = seen + 1
            local parts = {}
            for p in path:gmatch('[^%.]+') do parts[#parts + 1] = p end
            local found = false
            for _, n in ipairs(nodes) do if resolves(n, parts, 1) then found = true; break end end
            ok(found, 'app.js reads "' .. path .. '" which is not in the suite_data.js schema')
        end
    end
    ok(seen >= 80, 'data reads go through the safe accessors: ' .. seen)
    -- the data object is never dereferenced directly (missing fields must not throw)
    ok(not app:find('[^%w_]D%.[%a_]'), 'no direct D.field reads')
    ok(not app:find('SUITE_DATA%.[%a_]'), 'no direct SUITE_DATA.field reads')
    ok(has(app, "(+get(d, 'v') || 0) > KNOWN_V"), 'refuses a newer schema version')
end)

case('entry page opens the last chosen theme (Forge by default, localStorage guarded)', function()
    local page = read('index.html')
    ok(has(page, '<title>WarRoom — Live</title>'), 'title')
    ok(has(page, "localStorage.getItem('wr_theme')"), 'reads the saved theme')
    ok(has(page, "var pick = 'forge'"), 'Forge by default')
    ok(has(page, "location.replace(pick + '.html'"), 'redirects without a history entry')
    local try_at, get_at, catch_at = page:find('try {', 1, true), page:find('localStorage.getItem', 1, true), page:find('} catch (e)', 1, true)
    ok(try_at and get_at and catch_at and try_at < get_at and get_at < catch_at, 'localStorage inside try/catch')
    for _, theme in ipairs(THEMES) do
        ok(has(page, theme .. ': 1'), 'known theme ' .. theme)
        ok(has(page, 'href="' .. theme .. '.html"'), 'fallback link ' .. theme)
    end
    ok(not has(page, 'suite_data.js?'), 'the entry page loads no data itself')
    no_external(page, 'index.html')
end)

case('three theme pages: title, switcher at the top, shared app, theme tokens', function()
    for _, theme in ipairs(THEMES) do
        local name = theme .. '.html'
        local page = read(name)
        ok(has(page, '<title>WarRoom — Live</title>'), name .. ': title')
        ok(has(page, 'data-wr-theme="' .. theme .. '"'), name .. ': declares its theme')
        ok(has(page, '<link rel="stylesheet" href="base.css">'), name .. ': shared layout')
        ok(has(page, '<script src="app.js"></script>'), name .. ': shared app')
        ok(has(page, '<div id="app"></div>'), name .. ': app root')
        for _, token in ipairs({'--bg:', '--panel:', '--ink:', '--accent:', '--a-pit:', '--r-mythic:', '--c-gold:'}) do
            ok(has(page, token), name .. ': theme token ' .. token)
        end
        local nav = page:match('<body>%s*(<nav class="hrsw".-</nav>)')
        ok(nav ~= nil, name .. ': theme switcher first in <body>')
        nav = nav or ''
        for _, other in ipairs(THEMES) do
            ok(has(nav, 'href="' .. other .. '.html" data-theme-file="' .. other .. '"'), name .. ': switcher links ' .. other)
        end
        ok(nav:find('href="' .. name .. '" data%-theme%-file="[%a]+" class="cur"') ~= nil, name .. ': current theme highlighted')
        local _, cur = nav:gsub('class="cur"', '')
        eq(cur, 1, name .. ': exactly one current theme')
        no_external(page, name)
    end
    no_external(read('base.css'), 'base.css')
end)

case('app.js: reload interval, scope switch, tabs, theme choice saved', function()
    local app = read('app.js')
    no_external(app, 'app.js')
    ok(has(app, "s.src = 'suite_data.js?_=' + Date.now();"), 'reloads suite_data.js with a cache buster (script tag)')
    ok(has(app, "document.createElement('script')"), 'script injection works from file://')
    ok(has(app, "setTimeout(load, Math.max(5, Math.min(60, num(D, 'write_every') || 15)) * 1000)"), 'every write_every s, min 5')
    ok(has(app, "localStorage.setItem('wr_theme'"), 'saves the theme choice')
    ok(has(app, "localStorage.setItem('wr_scope'") and has(app, "localStorage.getItem('wr_scope')"), 'remembers the scope')
    for _, s in ipairs({"session: 'Session'", "today: 'Today'", "alltime: 'All time'"}) do ok(has(app, s), 'scope ' .. s) end
    for _, tab in ipairs({'overview', 'helltide', 'pit', 'undercity', 'hordes', 'bosses', 'whispers', 'items', 'timeline', 'bot'}) do
        ok(has(app, "['" .. tab .. "', '"), 'tab ' .. tab)
    end
    -- freshness banners: live within 3 writes, stale within 20, else offline
    ok(has(app, 'age <= ev * 3') and has(app, 'age <= ev * 20'), 'live / stale / offline thresholds')
    ok(has(app, "'helltide/' + THEME + '.html"), 'Helltide tab shows the themed map page')
    -- localStorage never throws out of the page
    local n_ls, n_try = 0, 0
    for line in app:gmatch('[^\n]+') do
        if line:find('localStorage%.') then n_ls = n_ls + 1; if line:find('try {', 1, true) then n_try = n_try + 1 end end
    end
    ok(n_ls > 0 and n_ls == n_try, 'every localStorage call sits in try/catch: ' .. n_try .. '/' .. n_ls)
end)

case('Helltide map pages live in helltide/ and read ../hr_data.js', function()
    for _, theme in ipairs(THEMES) do
        local name = 'helltide/' .. theme .. '.html'
        local page = read(name)
        ok(has(page, "s.src = '../hr_data.js?ts=' + Date.now();"), name .. ': reads ../hr_data.js')
        local _, plain = page:gsub("'hr_data%.js%?ts='", '')
        eq(plain, 0, name .. ': no read of hr_data.js from its own folder')
        ok(has(page, 'setInterval(load, 5000)'), name .. ': every 5 s')
        ok(has(page, 'window.HR_DATA'), name .. ': reads window.HR_DATA')
        local nav = page:match('<body>%s*(<nav class="hrsw".-</nav>)')
        ok(nav ~= nil, name .. ': theme switcher at the top')
        nav = nav or ''
        for _, other in ipairs(THEMES) do ok(has(nav, 'href="' .. other .. '.html"'), name .. ': switcher links ' .. other) end
        local _, cur = nav:gsub('class="cur"', '')
        eq(cur, 1, name .. ': exactly one current theme')
        ok(has(nav, 'href="../' .. theme .. '.html#helltide"') and has(nav, 'Back to WarRoom'), name .. ': back to WarRoom')
        ok(has(page, "localStorage.setItem('wr_theme'"), name .. ': saves the shared theme choice')
        ok(has(page, 'html.embed .hrsw { display: none; }'), name .. ': embedded view hides its bar')
        no_external(page, name)
        ok(not has(page, '<iframe'), name .. ': no frames')
    end
    local idx = read('helltide/index.html')
    ok(has(idx, "localStorage.getItem('wr_theme')") and has(idx, "location.replace(pick + '.html')"), 'helltide/index.html opens the chosen theme')
    no_external(idx, 'helltide/index.html')
end)

-- QQT_Warpigz_v3 (3.3.0 review board A2, A3, D2, D6, D8): app.js run under
-- node with a minimal DOM (skipped without node). Hostile strings from a
-- tampered data file never reach innerHTML as markup; the strip and the
-- charts are placed by time; unreadable figures are n/a; the freshness
-- banner does not trust a clock difference between this device and the PC.
local DOM_SHIM = [==[
const fs = require('fs'), vm = require('vm');
const src = fs.readFileSync(process.argv[2], 'utf8');
let clock = 1790500000 * 1000;
const els = {}, docL = {}, timers = [], intervals = [];
function el(id) {
  return els[id] || (els[id] = { id, innerHTML: '', textContent: '', className: '', hidden: false, style: {}, attrs: {}, clientWidth: 600,
    offsetLeft: 0, offsetWidth: 0, scrollLeft: 0, children: [],
    setAttribute(k, v) { this.attrs[k] = String(v); }, getAttribute(k) { return this.attrs[k] == null ? null : this.attrs[k]; },
    removeAttribute(k) { delete this.attrs[k]; }, hasAttribute(k) { return k in this.attrs; },
    classList: { toggle() {}, add() {}, remove() {} }, querySelector() { return null; }, querySelectorAll() { return []; },
    appendChild(c) { this.children.push(c); }, removeChild() {}, getBoundingClientRect() { return { width: 10, height: 10 }; } });
}
let lastScript = null;
const document = {
  documentElement: { getAttribute: () => 'forge' },
  getElementById: el, querySelectorAll: () => [], querySelector: () => null,
  addEventListener: (k, f) => { docL[k] = f; },
  body: { classList: { toggle() {}, add() {}, remove() {} } },
  head: { appendChild(s) { lastScript = s; } },
  createElement: (t) => ({ tag: t, parentNode: null, style: {} })
};
const winL = {}, window = { innerWidth: 1440, addEventListener: (k, f) => { winL[k] = f; }, scrollTo() {} };
const ctx = { window, document, location: { hash: '#overview' }, localStorage: { getItem() { return null; }, setItem() {} },
  setTimeout: (f) => { timers.push(f); return timers.length; }, clearTimeout() {}, setInterval: (f) => { intervals.push(f); },
  innerWidth: 1440, innerHeight: 900, Date: class extends Date { constructor(...a) { if (a.length) super(...a); else super(clock); } static now() { return clock; } },
  Math, JSON, Object, Array, String, Number, isFinite, Infinity, console };
window.SUITE_DATA = undefined;
vm.createContext(ctx);
vm.runInContext(src, ctx);
function deliver(d) { while (!lastScript && timers.length) timers.shift()(); window.SUITE_DATA = d; const s = lastScript; lastScript = null; s.onload(); }
const decode = (x) => x.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&');
const tips = (html) => { const out = []; html.replace(/data-tip="([^"]*)"/g, (m, v) => { out.push(decode(v)); }); return out; };
const PWN = '<img src=x onerror=alert(1)>';
const base = () => {
  const t = clock / 1000 - 600, T0 = t - 7260, H = Math.floor(t / 3600) * 3600; /* the PC clock is 10 min behind */
  const act = { runs: 1, ok: 1, failed: 0, time: 60, avg_time: 60, best: 98, best_label: PWN, extra: {} };
  return { v: 1, t, write_every: 15, suite: '3.3.0',
    session: { start: T0, uptime: 7260, active: 60, status: PWN, now: { activity: 'pit', title: 'x' }, next: [], warplan: null },
    scopes: { session: { totals: { gold: 150, xp: 2, levels: 0, paragon: 0, deaths: 0 }, rates: {}, activities: { pit: act },
      items: { looted: 0, by_rarity: {}, greater_affix: {} },
      hourly: [{ t: H - 3 * 3600, gold: 100, xp: 1, items: 0, act: { [PWN]: 1 } }, { t: H, gold: 50, xp: 1, items: 0, act: {} }] } },
    drops: [], timeline: [], alerts: [],
    strip: [{ a: 'pit', s: T0, e: T0 + 60 }, { a: PWN, s: T0 + 7200, e: T0 + 7260 }],
    plugins: { arkham: { name: 'ArkhamAsylum', role: 'The Pit', state: 'constructor', kv: [] } },
    helltide: { file: 'hr_data.js', active: false, next_in: 0, zone: '', cinders: null } };
};
const R = {};
deliver(base());
R.first_banner_hidden = el('banner').hidden;
const strip = el('strip').innerHTML, gold = el('c-gold').innerHTML, all = strip + gold;
const tipList = tips(strip).concat(tips(gold));
R.tips = tipList.length;
R.tips_img = tipList.some((x) => x.indexOf('<img') >= 0);
docL.mousemove({ target: { closest: () => ({ getAttribute: () => tipList[tipList.length - 1] }) }, clientX: 1, clientY: 1 });
R.sink_img = el('tip').innerHTML.indexOf('<img') >= 0;
R.acts_img = el('acts').innerHTML.indexOf('<img') >= 0;
R.pill_text = el('statuspill').textContent === PWN;
R.strip_flex = strip.indexOf('flex:') >= 0;
const m = /left:0\.000%;width:([\d.]+)%/.exec(strip); R.pit_width = m ? +m[1] : -1;
const m2 = /left:([\d.]+)%;width:[\d.]+%;"/.exec(strip.split('<i').slice(-1)[0] || ''); R.last_left = m2 ? +m2[1] : -1;
R.axis_pos = /left:\d/.test(el('axis').innerHTML) && el('axis').innerHTML.indexOf('>now<') >= 0;
R.gold_slots = (gold.match(/class="hit"/g) || []).length;
R.zero_paragon = el('counters').innerHTML.indexOf('+0</b> paragon') >= 0;
clock += 15000; const d2 = base(); deliver(d2);
R.second_banner_hidden = el('banner').hidden; R.second_live = el('agetxt').textContent.indexOf('Live') === 0;
clock += 60000; intervals.forEach((f) => f());
R.stale_banner_hidden = el('banner').hidden;
ctx.location.hash = '#helltide'; winL.hashchange();
R.cinders_na = /Cinders now<\/div><div class="n na">n\/a</.test(el('h-kpis').innerHTML);
ctx.location.hash = '#bot'; winL.hashchange();
R.bot_class = el('plugins').innerHTML.indexOf('plug ') >= 0 && el('plugins').innerHTML.indexOf('plug constructor') < 0;
for (const k in R) console.log(k + '=' + R[k]);
]==]

local function node_path()
    local p = io.popen('command -v node 2>/dev/null')
    local path = p and p:read('*l')
    if p then p:close() end
    return path ~= '' and path or nil
end

case('app.js under node: escaping, time axis, n/a, clock-skew-free freshness', function()
    if not node_path() then print('SKIP WarRoom dashboard: node not found'); return end
    local js = os.tmpname()
    local f = assert(io.open(js, 'wb')); f:write(DOM_SHIM); f:close()
    local p = io.popen('node "' .. js .. '" "' .. ROOT .. 'app.js" 2>&1')
    local out = p:read('*a'); p:close(); os.remove(js)
    local R = {}
    for k, v in out:gmatch('([%w_]+)=([^\n]*)') do R[k] = v end
    ok(R.tips ~= nil, 'node run produced a result: ' .. out:sub(1, 400))
    -- A2: every decoded data-tip is safe HTML (no raw <img from the data)
    ok(tonumber(R.tips) >= 5, 'A2: tooltips found: ' .. tostring(R.tips))
    eq(R.tips_img, 'false', 'A2: tooltips carry no markup from the data')
    eq(R.sink_img, 'false', 'A2: the tooltip sink gets escaped text')
    -- A3: best_label and a status string are escaped; own keys only
    eq(R.acts_img, 'false', 'A3: best_label escaped in the activity table')
    eq(R.pill_text, 'true', 'A3: status pill is text')
    eq(R.bot_class, 'true', "A3: a plugin state 'constructor' is no known state")
    -- D2: blocks and ticks placed by time; nothing stretched over the gap
    eq(R.strip_flex, 'false', 'D2: no flex-sized blocks')
    local w1 = tonumber(R.pit_width)
    ok(w1 and w1 > 0 and w1 < 1, 'D2: a 60 s pit block in a 2 h span is under 1 % wide: ' .. tostring(w1))
    local l2 = tonumber(R.last_left)
    ok(l2 and l2 > 95, 'D2: the block after the 2 h gap starts at its time (' .. tostring(l2) .. ' %)')
    eq(R.axis_pos, 'true', 'D2: axis ticks are positioned by time')
    -- D6: the gold chart has a slot for every hour (2 empty hours between)
    eq(R.gold_slots, '4', 'D6: 4 hourly slots for rows 3 h apart')
    -- D8: n/a, paragon, freshness
    eq(R.cinders_na, 'true', 'D8: unreadable cinders show n/a')
    eq(R.zero_paragon, 'false', 'D8: no "+0 paragon" when nothing was gained')
    eq(R.first_banner_hidden, 'true', 'D8: a 10 min clock difference is no stale banner on load')
    eq(R.second_banner_hidden, 'true', 'D8: the next write is live')
    eq(R.second_live, 'true', 'D8: live pill after a new write')
    eq(R.stale_banner_hidden, 'false', 'D8: no new write for 60 s (4 x 15 s) on this device: stale')
end)

case('base.css: the strip never overflows the page', function()
    local css = read('base.css')
    ok(css:find('%.strip {[^}]*overflow: hidden') ~= nil, 'D2: .strip overflow hidden')
    ok(not css:find('%.strip {[^}]*display: flex'), 'D2: .strip is not a flex row (200 blocks x gap overflowed 390 px)')
    ok(css:find('%.strip i {[^}]*position: absolute') ~= nil, 'D2: blocks are placed absolutely')
end)

print(string.format('WarRoom dashboard: %d cases, %d checks, %d failures', cases, checks, #failures))
if #failures > 0 then error(#failures .. ' WarRoom dashboard case(s) failed') end
