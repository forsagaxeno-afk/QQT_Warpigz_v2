/* QQT_Warpigz_v3: WarRoom suite dashboard, shared by forge.html, daylight.html
   and console.html (the pages differ only in their theme CSS).
   Reads window.SUITE_DATA from suite_data.js in this folder (written by
   WarRoom); re-injects that script every write_every s (min 5 s, max 60 s),
   which works from disk (file://) without a server. No external resources.
   Every read of the data goes through get/num/arr/obj/str with a literal
   field path from the suite_data.js schema, so a missing field shows "—"
   instead of breaking the page. */
(function () {
  'use strict';
  var KNOWN_V = 1;
  var THEME = document.documentElement.getAttribute('data-wr-theme') || 'forge';

  var ACT = {
    pit:       { name: 'The Pit',         short: 'Pit',       plugin: 'ArkhamAsylum',     key: 'arkham' },
    helltide:  { name: 'Helltide',        short: 'Helltide',  plugin: 'HelltideRevamped', key: 'helltide' },
    undercity: { name: 'Undercity',       short: 'Undercity', plugin: 'WonderCity',       key: 'wonder' },
    hordes:    { name: 'Infernal Hordes', short: 'Hordes',    plugin: 'HordeDev',         key: 'hordedev' },
    bosses:    { name: 'Bosses',          short: 'Bosses',    plugin: 'Reaper',           key: 'reaper' },
    whispers:  { name: 'Whisper rewards', short: 'Whispers',  plugin: 'SilentRaven',      key: 'raven' }
  };
  var ORDER = ['pit', 'helltide', 'undercity', 'hordes', 'bosses', 'whispers'];
  var RAR = ['mythic', 'unique', 'legendary', 'rare', 'magic'];
  var RNAME = { mythic: 'Mythic', unique: 'Unique', legendary: 'Legendary', rare: 'Rare', magic: 'Magic', common: 'Common' };
  var TABS = [['overview', 'Overview'], ['helltide', 'Helltide'], ['pit', 'Pit'], ['undercity', 'Undercity'], ['hordes', 'Hordes'],
    ['bosses', 'Bosses'], ['whispers', 'Whispers'], null, ['items', 'Items'], ['timeline', 'Timeline'], ['bot', 'Bot']];
  var EXTRA = { glyphs_up: 'Glyphs upgraded', chests: 'Chests opened', mystery: 'Mystery chests', cinders: 'Cinders collected',
    attunement: 'Attunement', aether: 'Aether', council: 'Council kills', caches: 'Caches turned in' };
  var SCOPES = { session: 'Session', today: 'Today', alltime: 'All time' };
  var STATUS = { running: 'Running', paused: 'Paused', idle: 'Idle', stopped: 'Stopped', error: 'Error' };
  var PSTATE = { running: 1, idle: 1, paused: 1, waiting: 1, error: 1, stopped: 1, disabled: 1 };
  var SIGIL = {
    forge: '<svg class="sigil" viewBox="0 0 48 48" aria-hidden="true"><path d="M24 2 L46 24 L24 46 L2 24 Z" fill="none" stroke="#8f7b5c" stroke-width="1.5"/>' +
      '<path d="M24 8 L40 24 L24 40 L8 24 Z" fill="#1d150f" stroke="#4a3a2a"/><path d="M14 30 L24 14 L34 30" fill="none" stroke="#e8743b" stroke-width="2.4"/>' +
      '<path d="M17 34 H31" stroke="#e3ab45" stroke-width="2"/><circle cx="24" cy="24" r="2.6" fill="#f6cf7a"/></svg>',
    daylight: '<svg class="sigil" viewBox="0 0 30 30" aria-hidden="true"><rect x="4" y="4" width="22" height="22" transform="rotate(45 15 15)" fill="#b3121b"/>' +
      '<path d="M9 19 L15 9 L21 19" fill="none" stroke="#f3f1ed" stroke-width="1.8"/><path d="M11 21.5 H19" stroke="#f3f1ed" stroke-width="1.6"/></svg>',
    console: ''
  };

  var D = null, scope = 'session', NOW = Date.now() / 1000, OFF = false, TOO_NEW = false, tabNow = 'overview';
  var iFilter = { rar: 'all', src: 'all', ga: 0, fate: 'all' }, tFilter = { kind: 'all', act: 'all' };
  try { var s0 = localStorage.getItem('wr_scope'); if (s0 && SCOPES.hasOwnProperty(s0)) scope = s0; } catch (e) { /* blocked */ }

  /* ── safe data access (literal schema paths) ── */
  function get(o, path, dflt) {
    var ks = String(path).split('.');
    for (var i = 0; i < ks.length; i++) {
      if (o == null || typeof o !== 'object') return dflt;
      o = o[ks[i]];
    }
    return o == null ? dflt : o;
  }
  function num(o, path) { var v = get(o, path); return typeof v === 'number' && isFinite(v) ? v : null; }
  function nz(o, path) { var v = num(o, path); return v == null ? 0 : v; }
  function arr(o, path) { var v = get(o, path); return Array.isArray(v) ? v : []; }
  function obj(o, path) { var v = get(o, path); return v && typeof v === 'object' && !Array.isArray(v) ? v : {}; }
  function str(o, path, d) { var v = get(o, path); return v == null || typeof v === 'object' ? (d == null ? '' : d) : String(v); }
  function at(o, k) { return o && typeof o === 'object' ? o[k] : undefined; }
  /* own keys only: a data string like 'constructor' or '__proto__' is not a known key */
  function own(o, k) { return Object.prototype.hasOwnProperty.call(o, k) ? o[k] : undefined; }

  /* ── formatting ── */
  function $(id) { return document.getElementById(id); }
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
  /* data-tip holds HTML that the tooltip puts into innerHTML: the attribute is
     decoded once by the parser, so the whole tip is escaped once more here and
     every dynamic part inside it is escaped by the caller. */
  function tipAttr(html) { return ' data-tip="' + esc(html) + '"'; }
  function big(n) {
    if (n == null || !isFinite(n)) return '—';
    var a = Math.abs(n);
    if (a >= 1e9) return (n / 1e9).toFixed(a >= 1e10 ? 1 : 2).replace(/\.?0+$/, '') + 'B';
    if (a >= 1e6) return (n / 1e6).toFixed(a >= 1e8 ? 0 : 1).replace(/\.0$/, '') + 'M';
    if (a >= 1e4) return Math.round(n / 1e3) + 'K';
    return Math.round(n).toLocaleString('en-US');
  }
  function dur(s) {
    if (s == null || !isFinite(s)) return '—';
    s = Math.max(0, Math.round(s));
    if (s < 60) return s + ' s';
    if (s < 3600) return Math.floor(s / 60) + ':' + ('0' + s % 60).slice(-2);
    return Math.floor(s / 3600) + 'h ' + ('0' + Math.floor(s % 3600 / 60)).slice(-2) + 'm';
  }
  function mins(s) {
    if (s == null || !isFinite(s)) return '—';
    s = Math.max(0, Math.round(s));
    return s < 90 ? s + ' s' : s < 5400 ? Math.round(s / 60) + ' min' : (s / 3600).toFixed(1) + ' h';
  }
  function hhmm(t) { if (!t) return '—'; var d = new Date(t * 1000); return ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2); }
  var MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  function dlabel(t) { var d = new Date(t * 1000); return d.getDate() + ' ' + MON[d.getMonth()]; }
  function stamp(t) { return scope === 'session' ? hhmm(t) : dlabel(t) + ' ' + hhmm(t); }
  function ago(t) {
    var s = Math.max(0, NOW - t);
    return s < 60 ? 'just now' : s < 3600 ? Math.round(s / 60) + ' min ago' : s < 86400 ? Math.floor(s / 3600) + ' h ' + Math.round(s % 3600 / 60) + ' min ago' : Math.floor(s / 86400) + ' d ago';
  }
  function pct(a, b) { return b ? Math.round(a / b * 100) + '%' : '—'; }
  function human(k) { return own(EXTRA, k) || String(k).replace(/_/g, ' ').replace(/^./, function (c) { return c.toUpperCase(); }); }
  function acolor(k) { return own(ACT, k) ? 'var(--a-' + k + ')' : 'var(--a-neutral)'; }
  function sw(k) { return '<i class="sw" style="background:' + acolor(k) + '"></i>'; }
  function rarity(r) { return RNAME.hasOwnProperty(r) ? r : 'common'; }
  function pname(k) { return str(at(obj(D, 'plugins'), k), 'name') || (k ? String(k) : '—'); }

  /* ── scope helpers ── */
  function SC() { return obj(obj(D, 'scopes'), scope); }
  function scopeStart() {
    if (scope === 'session') return nz(D, 'session.start');
    if (scope === 'today') { var d = new Date(NOW * 1000); d.setHours(0, 0, 0, 0); return d.getTime() / 1000; }
    return 0;
  }
  function inScope(e) { var t = nz(e, 't'); return t >= scopeStart(); }
  function actBlock(k) { return obj(obj(SC(), 'activities'), k); }

  /* ── shell ── */
  function shell() {
    var h = '<header class="top"><div class="in">' + (SIGIL[THEME] || '') +
      '<div class="brand"><h1>War<em>Room</em></h1><div class="sub" id="subtitle">Waiting for suite_data.js</div></div><div class="grow"></div>' +
      '<div class="seals"><span class="pill" id="statuspill">—</span><span class="pill" id="agepill"><i id="dot"></i><span id="agetxt">No data</span></span>' +
      '<div class="scope" role="group" aria-label="Scope">' + Object.keys(SCOPES).map(function (k) { return '<button type="button" data-scope="' + k + '" aria-pressed="false">' + SCOPES[k] + '</button>'; }).join('') + '</div></div>' +
      '</div></header><div class="wrap"><nav class="tabbar" id="tabbar" aria-label="Pages"></nav><div id="banner" class="banner"></div>';
    h += '<main id="p-overview" data-page>' +
      '<div class="row r-now"><section class="panel framed now live-only" aria-label="What the bot is doing now"><div><div class="cap">Now</div><h3 id="now-title">—</h3><div class="sub" id="now-step">—</div>' +
      '<div class="bar" id="now-barw"><i id="now-bar" style="width:0"></i></div><div class="meta" id="now-meta"></div></div>' +
      '<div class="queue"><div class="cap">Up next</div><ol id="queue"></ol><div class="plan" id="plan"></div></div></section>' +
      '<section class="panel" aria-label="Alerts"><div class="phead"><h2>Alerts</h2><span class="aside" id="alert-sum"></span></div><ul class="alerts" id="alerts"></ul></section></div>' +
      '<section class="counters" id="counters" aria-label="Totals"></section>' +
      '<div class="row r-2"><section class="panel"><div class="phead"><h2>Activities</h2><span class="aside" id="act-sum"></span></div>' +
      '<table class="acts"><thead><tr><th>Activity</th><th>Done</th><th style="text-align:left">Success</th><th>Avg time</th><th>Best</th><th></th></tr></thead><tbody id="acts"></tbody></table></section>' +
      '<section class="panel"><div class="phead"><h2>Items by rarity</h2><span class="aside" id="items-sum"></span></div><div class="rar" id="rarity"></div><div class="ga" id="ga"></div><div class="fate" id="fate"></div><div class="myth" id="myth"></div></section></div>' +
      '<section class="panel" id="strip-panel"><div class="phead"><h2>Session at a glance</h2><span class="aside">What ran when · neutral = town, travel, idle</span></div><div class="strip" id="strip"></div><div class="axis" id="axis"></div><div class="legend" id="legend"></div></section>' +
      '<div class="row r-half"><section class="panel"><div class="phead"><h2 id="gold-h">Gold per hour</h2><span class="aside" id="gold-avg"></span></div><div class="chart" id="c-gold"></div></section>' +
      '<section class="panel"><div class="phead"><h2 id="xp-h">XP per hour</h2><span class="aside" id="xp-avg"></span></div><div class="chart" id="c-xp"></div></section></div>' +
      '<div class="row r-2"><section class="panel"><div class="phead"><h2>Latest events</h2><a href="#timeline">Full timeline &rsaquo;</a></div><ul class="feed" id="feed"></ul></section>' +
      '<section class="panel"><div class="phead"><h2>Notable drops</h2><a href="#items">All items &rsaquo;</a></div><ul class="drops" id="drops"></ul></section></div></main>';
    h += '<main id="p-helltide" data-page hidden><section class="kpis k6" id="h-kpis"></section>' +
      '<section class="panel framed"><div class="phead"><h2>War table</h2><span class="aside" id="h-aside">The Helltide map: cinders, chest reset and Helltide clocks, road, border and chests</span></div>' +
      '<div class="golink" style="margin-bottom:14px"><a class="btn" id="h-open" href="helltide/' + THEME + '.html">Open the Helltide map &rsaquo;</a><span class="sub">Reads hr_data.js, written by HelltideRevamped into this folder.</span></div>' +
      '<div class="frame" id="h-frame"></div></section></main>';
    h += '<main id="p-activity" data-page hidden><section class="panel framed ahead"><div class="cap" id="a-plugin">—</div><h3 id="a-title">—</h3><div class="sub" id="a-state">—</div></section>' +
      '<section class="kpis" id="a-kpis"></section>' +
      '<div class="row r-2"><section class="panel"><div class="phead"><h2>Runs</h2><span class="aside">From the timeline</span></div><div class="scroll"><table class="t" id="a-runs"></table></div></section>' +
      '<section class="panel"><div class="phead"><h2>Details</h2><span class="aside" id="a-scope"></span></div><div class="kvs" id="a-extra"></div><div id="a-byboss"></div>' +
      '<div class="phead" style="margin-top:18px"><h2>Plugin</h2></div><div class="kvs" id="a-kv"></div></section></div>' +
      '<div class="row r-2"><section class="panel"><div class="phead"><h2 id="a-ch">Runs per hour</h2></div><div class="chart" id="a-chart"></div></section>' +
      '<section class="panel"><div class="phead"><h2>Drops from here</h2></div><ul class="drops" id="a-drops"></ul></section></div></main>';
    h += '<main id="p-items" data-page hidden><section class="panel"><div class="phead"><h2>Notable drops</h2><span class="aside">Mythic, unique, legendary with greater affixes, anything stashed</span></div>' +
      '<div class="filters" id="i-filters"></div><div class="scroll wide-only"><table class="t" id="i-table"></table></div><ul class="drops narrow-only" id="i-list"></ul></section></main>';
    h += '<main id="p-timeline" data-page hidden><section class="panel"><div class="phead"><h2>Timeline</h2><span class="aside" id="t-aside">Newest first</span></div>' +
      '<div class="filters" id="t-filters"></div><ul class="feed" id="t-feed"></ul></section></main>';
    h += '<main id="p-bot" data-page hidden><section class="kpis" id="b-kpis"></section>' +
      '<section class="panel"><div class="phead"><h2>Plugins</h2><span class="aside">Health and a few figures each plugin reports</span></div><div class="plugins" id="plugins"></div></section>' +
      '<section class="panel"><div class="phead"><h2>All alerts</h2><span class="aside" id="b-alerts"></span></div><ul class="alerts" id="alerts-all"></ul></section></main>';
    h += '<footer class="foot"><span id="foot-file">suite_data.js</span><span>No names, accounts or chat are written to this file.</span><span>Times shown in this device’s time zone.</span></footer></div><div class="tip" id="tip"></div>';
    $('app').innerHTML = h;
  }

  /* ── tabs + routing ── */
  function buildTabs() {
    var h = '', sc = SC(), have = !!D;
    TABS.forEach(function (t) {
      if (!t) { h += '<span class="sep" aria-hidden="true"></span>'; return; }
      var cnt = '';
      if (ACT[t[0]] && have) { var ok = num(actBlock(t[0]), 'ok'); if (ok != null) cnt = '<span class="cnt">' + big(ok) + '</span>'; }
      if (t[0] === 'items' && have) { var lo = num(sc, 'items.looted'); if (lo != null) cnt = '<span class="cnt">' + big(lo) + '</span>'; }
      if (t[0] === 'bot' && have) { var al = openAlerts(); if (al) cnt = '<span class="cnt alert">' + al + ' !</span>'; }
      h += '<a href="#' + t[0] + '" data-tab="' + t[0] + '">' + (ACT[t[0]] ? sw(t[0]) : '') + t[1] + cnt + '</a>';
    });
    $('tabbar').innerHTML = h;
    markTab();
    scrollTab();
  }
  var needScroll = true;
  function scrollTab() {
    var bar = $('tabbar'), cur = bar && bar.querySelector('a[aria-current]');
    if (!needScroll || !cur) return;
    if (D) needScroll = false;
    var l = cur.offsetLeft, r = l + cur.offsetWidth;
    if (l < bar.scrollLeft || r > bar.scrollLeft + bar.clientWidth) bar.scrollLeft = Math.max(0, l - 24);
  }
  function markTab() {
    var links = document.querySelectorAll('#tabbar a');
    for (var i = 0; i < links.length; i++) {
      if (links[i].getAttribute('data-tab') === tabNow) links[i].setAttribute('aria-current', 'page');
      else links[i].removeAttribute('aria-current');
    }
  }
  function currentTab() {
    var tab = (location.hash || '#overview').slice(1);
    return TABS.some(function (t) { return t && t[0] === tab; }) ? tab : 'overview';
  }
  function route(wantScroll) {
    tabNow = currentTab();
    var page = ACT[tabNow] && tabNow !== 'helltide' ? 'activity' : tabNow;
    var mains = document.querySelectorAll('[data-page]');
    for (var i = 0; i < mains.length; i++) mains[i].hidden = mains[i].id !== 'p-' + page;
    markTab();
    if (wantScroll) { needScroll = true; scrollTab(); }
    renderPage();
  }
  function renderPage() {
    var p = tabNow;
    if (p === 'overview') renderOverview();
    else if (p === 'helltide') renderHelltide();
    else if (ACT[p]) renderActivity(p);
    else if (p === 'items') renderItems();
    else if (p === 'timeline') renderTimeline();
    else if (p === 'bot') renderBot();
  }

  /* ── freshness ── */
  function every() { var w = num(D, 'write_every'); return Math.min(60, Math.max(5, w || 15)); }
  /* Data age without comparing clocks: the phone's and the bot PC's clocks can
     differ by minutes, so the age is the time (on this device) since the file's
     own write time t last changed. Until t has changed once while the page is
     open, a file whose t is far from this device's clock is "Checking" (a
     skewed clock or old data: the next write tells). */
  var seenT = null, seenAt = 0, tChanged = false;
  function noteWrite() {
    var t = num(D, 't');
    if (t == null || t === seenT) return;
    if (seenT !== null) tChanged = true;
    seenT = t; seenAt = Date.now() / 1000;
  }
  function freshness() {
    var b = $('banner'), pill = $('agepill'), dot = $('dot'), txt = $('agetxt');
    if (!D) {
      OFF = true; document.body.classList.add('offline');
      pill.className = 'pill'; dot.className = ''; txt.textContent = 'No data';
      b.hidden = false; b.className = 'banner warn';
      b.innerHTML = TOO_NEW ? '<b>This data format is newer than this page</b>Update the WarRoom plugin folder (dashboard pages) to the version the bot runs.'
        : '<b>Waiting for suite_data.js</b>Enable WarRoom in the bot. It writes the file into this folder and this page reloads it every few seconds.';
      return;
    }
    var t = nz(D, 't'), ev = every(), age = seenT === null ? 0 : Math.max(0, NOW - seenAt);
    var state = age <= ev * 3 ? 'live' : age <= ev * 20 ? 'stale' : 'offline';
    if (state === 'live' && !tChanged && Math.abs(NOW - t) > ev * 3) state = 'check';
    if (str(D, 'session.status') === 'stopped') state = 'offline';
    OFF = state === 'offline';
    document.body.classList.toggle('offline', OFF);
    dot.className = state === 'live' ? 'live' : '';
    pill.className = 'pill ' + (state === 'live' ? 'ok' : state === 'stale' || state === 'check' ? 'warn' : 'bad');
    txt.textContent = state === 'live' ? 'Live · ' + Math.round(age) + ' s ago' : state === 'check' ? 'Checking for updates' : t ? 'No update for ' + mins(age) : 'No time stamp';
    if (state === 'live' || state === 'check') { b.hidden = true; return; }
    b.hidden = false;
    b.className = 'banner ' + (state === 'stale' ? 'warn' : 'bad');
    b.innerHTML = state === 'stale'
      ? '<b>No new data for ' + mins(age) + '</b>The bot writes every ' + ev + ' s. Probably a loading screen, or your sync app is catching up.'
      : str(D, 'session.status') === 'stopped' && age <= ev * 20
        ? '<b>The bot is stopped</b>Last write ' + hhmm(t) + '. Everything below is the last known state.'
        : '<b>No update for ' + mins(age) + ' (last write ' + hhmm(t) + ')</b>The PC may be asleep, the game closed, or the sync stopped. Everything below is the last known state.';
  }
  function openAlerts() { return arr(D, 'alerts').filter(function (x) { return !get(x, 'resolved') && str(x, 'level') !== 'info'; }).length; }

  /* ── header ── */
  function renderHead() {
    var se = obj(D, 'session'), sc = SC();
    var sub = 'Waiting for suite_data.js';
    if (D) {
      if (scope === 'alltime') { var since = num(sc, 'since'); sub = 'All time' + (since ? ' · since ' + new Date(since * 1000).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) : ''); }
      else sub = SCOPES[scope] + (num(se, 'start') ? ' · started ' + hhmm(num(se, 'start')) : '') + (num(se, 'uptime') != null ? ' · up ' + dur(num(se, 'uptime')) : '');
      var v = str(D, 'suite'); if (v) sub += ' · v' + v;
    }
    $('subtitle').textContent = sub;
    var sp = $('statuspill'), st = str(se, 'status');
    sp.textContent = own(STATUS, st) || (st || '—');
    sp.className = 'pill ' + (st === 'running' ? 'ok' : st === 'error' ? 'bad' : st ? 'warn' : '');
    if (OFF && st) { sp.textContent = 'Last: ' + sp.textContent; sp.className = 'pill'; }
    var bs = document.querySelectorAll('.scope button');
    for (var i = 0; i < bs.length; i++) bs[i].setAttribute('aria-pressed', String(bs[i].getAttribute('data-scope') === scope));
  }

  /* ── overview ── */
  function renderNow() {
    var se = obj(D, 'session'), n = obj(se, 'now'), a = str(n, 'activity');
    var title = str(n, 'title');
    $('now-title').innerHTML = title ? (own(ACT, a) ? sw(a) : '') + esc(title) : esc(own(STATUS, str(se, 'status')) || 'Nothing running');
    $('now-step').textContent = str(n, 'step', title ? '' : (D ? 'Waiting for the next step of the plan' : 'No data yet'));
    var p = num(n, 'progress');
    $('now-barw').hidden = p == null;
    $('now-bar').style.width = Math.round(Math.min(1, Math.max(0, p || 0)) * 100) + '%';
    var since = num(n, 'since'), eta = get(n, 'eta'), meta = [];
    if (since) meta.push('Running <b>' + dur((OFF ? nz(D, 't') : NOW) - since) + '</b>');
    if (title) meta.push('About <b>' + (typeof eta === 'number' ? mins(eta) : '?') + '</b> left');
    var pl = str(n, 'plugin'); if (pl) meta.push('Plugin <b>' + esc(pname(pl)) + '</b>');
    var z = str(n, 'zone'); if (z) meta.push('Zone <b>' + esc(z) + '</b>');
    $('now-meta').innerHTML = meta.map(function (m) { return '<span>' + m + '</span>'; }).join('');
    var q = arr(se, 'next').slice(0, 3);
    $('queue').innerHTML = q.length ? q.map(function (x) {
      var t = num(x, 'at'); return '<li>' + (own(ACT, str(x, 'activity')) ? sw(str(x, 'activity')) + ' ' : '') + esc(str(x, 'label', '—')) + (t ? '<small>' + hhmm(t) + '</small>' : '') + '</li>';
    }).join('') : '<li class="sub">Nothing queued</li>';
    var wp = obj(se, 'warplan'), wn = str(wp, 'name');
    $('plan').textContent = wn ? 'War plan “' + wn + '”' + (num(wp, 'steps') ? ' · step ' + nz(wp, 'step') + ' of ' + num(wp, 'steps') : '') : '';
  }
  function renderAlerts(el, list) {
    el.innerHTML = list.length ? list.map(function (x) {
      var lv = str(x, 'level', 'info'); if (lv !== 'warn' && lv !== 'error') lv = 'info';
      var res = !!get(x, 'resolved');
      return '<li class="' + lv + (res ? ' res' : '') + '"><span class="ic" aria-label="' + lv + '">' + (lv === 'info' ? 'i' : '!') + '</span><span><span class="txt">' + esc(str(x, 'text', '—')) + '</span><span class="who">' +
        esc(pname(str(x, 'plugin'))) + (res ? ' · resolved' : '') + '</span></span><time>' + (num(x, 't') ? stamp(num(x, 't')) : '') + '</time></li>';
    }).join('') : '<li><span></span><span class="sub">Nothing to report</span><span></span></li>';
  }
  function counters() {
    var sc = SC(), se = obj(D, 'session'), done = 0, runs = 0, fail = 0, busy = 0, any = false;
    ORDER.forEach(function (k) { var x = actBlock(k); if (num(x, 'runs') != null) any = true; done += nz(x, 'ok'); runs += nz(x, 'runs'); fail += nz(x, 'failed'); busy += nz(x, 'time'); });
    var gold = num(sc, 'totals.gold'), xp = num(sc, 'totals.xp'), lo = num(sc, 'items.looted'), de = num(sc, 'totals.deaths');
    var lv = nz(sc, 'totals.levels'), pg = nz(sc, 'totals.paragon'), up = num(se, 'uptime'), ac = num(se, 'active');
    var lastDeath = arr(D, 'timeline').filter(function (e) { return str(e, 'kind') === 'death'; })[0];
    var cards = [
      ['Activities done', any ? big(done) : null, '', any ? '<b>' + fail + '</b> failed of ' + runs + ' started' : 'no runs yet', true],
      ['Gold farmed', gold == null ? null : big(gold), '', gold == null ? 'gold not readable' : '<b>' + big(num(sc, 'rates.gold_hr')) + '</b>/h · spent ' + big(nz(sc, 'totals.gold_spent')), true],
      ['XP gained', xp == null ? null : big(xp), '', xp == null ? 'XP not readable' : lv || pg ? [lv ? '<b>+' + lv + '</b> levels' : '', pg ? '<b>+' + pg + '</b> paragon' : ''].filter(Boolean).join(' · ') : 'no level-ups yet', false],
      ['Items looted', lo == null ? null : big(lo), '', '<b class="mark">' + nz(sc, 'items.by_rarity.mythic') + ' mythic</b> · ' + nz(sc, 'items.by_rarity.unique') + ' unique', false],
      ['Deaths', de == null ? null : big(de), '', de ? 'last: ' + (lastDeath ? ago(nz(lastDeath, 't')) : '—') : 'none', false]
    ];
    if (scope === 'alltime') cards.push(['Time botted', busy ? Math.round(busy / 3600) : null, 'h', 'in activities', false]);
    else cards.push(['Busy', up && ac != null ? Math.round(ac / up * 100) : null, '%', up ? dur(ac) + ' of ' + dur(up) : 'uptime unknown', false]);
    $('counters').innerHTML = cards.map(function (c) {
      return '<div class="counter' + (c[4] ? ' hero' : '') + '"><div class="cap">' + c[0] + '</div><div class="n' + (c[1] == null ? ' na' : '') + '">' + (c[1] == null ? 'n/a' : c[1] + (c[2] ? '<small>' + c[2] + '</small>' : '')) + '</div><div class="note">' + c[3] + '</div></div>';
    }).join('');
  }
  function activityTable() {
    var maxRuns = 1, total = 0;
    ORDER.forEach(function (k) { maxRuns = Math.max(maxRuns, nz(actBlock(k), 'runs')); total += nz(actBlock(k), 'time'); });
    $('acts').innerHTML = ORDER.map(function (k) {
      var x = actBlock(k), A = ACT[k], r = nz(x, 'runs'), ok = nz(x, 'ok'), f = nz(x, 'failed'), w = r / maxRuns * 100;
      var okw = r ? ok / r * w : 0, fw = r ? f / r * w : 0, bl = str(x, 'best_label'), bv = num(x, 'best'), avg = num(x, 'avg_time');
      var best = bv ? (bl ? bl + ' ' : '') + big(bv) : '—';
      var okl = ok + ' of ' + r + ' ok' + (f ? ' · <span class="bad-t">' + f + ' failed</span>' : '');
      var aux = [okl, avg ? 'avg ' + dur(avg) : '', bv ? 'best ' + esc(best.toLowerCase()) : ''].filter(Boolean).join(' · ');
      return '<tr data-go="' + k + '"><td class="c-nm"><div class="nm">' + sw(k) + '<div><b>' + A.name + '</b><span>' + A.plugin + '</span></div></div></td>' +
        '<td class="c-cnt"><span class="cnt">' + big(ok) + '<small>×</small></span></td>' +
        '<td class="succ"><div class="sbar">' + (okw ? '<i style="width:' + okw + '%;background:' + acolor(k) + '"></i>' : '') + (fw ? '<i class="f" style="width:' + fw + '%"></i>' : '') + '</div>' +
        '<div class="slbl">' + (r ? okl : 'none yet') + '</div></td><td class="c-avg aux">' + (avg ? dur(avg) : '—') + '</td><td class="c-best aux">' + esc(best) + '</td><td class="c-chev"><span class="chev">&rsaquo;</span></td>' +
        '<td class="c-aux">' + (r ? aux : 'none yet') + '</td></tr>';
    }).join('');
    $('act-sum').textContent = total ? mins(total) + ' in activities' : '';
  }
  function itemsPanel() {
    var sc = SC(), br = obj(sc, 'items.by_rarity'), looted = nz(sc, 'items.looted'), maxR = 1;
    RAR.forEach(function (r) { maxR = Math.max(maxR, +at(br, r) || 0); });
    $('rarity').innerHTML = RAR.map(function (r) {
      var v = +at(br, r) || 0, share = looted ? v / looted * 100 : 0;
      return '<div class="lbl"' + (r === 'mythic' ? ' style="color:var(--r-mythic)"' : '') + '>' + (r === 'mythic' ? '&#9670; ' : '') + RNAME[r] + '</div>' +
        '<div class="trk"' + tipAttr(RNAME[r] + ': ' + v + (looted ? ' (' + share.toFixed(1) + '%)' : '')) + '><i style="width:' + (v ? Math.max(v / maxR * 100, 1.2) : 0) + '%;background:var(--r-' + r + ')"></i></div>' +
        '<div class="v num">' + big(v) + '</div><div class="p">' + (looted ? share.toFixed(share < 1 && share > 0 ? 1 : 0) + '%' : '—') + '</div>';
    }).join('');
    $('items-sum').textContent = num(sc, 'items.looted') != null ? big(looted) + ' picked up' : '';
    $('ga').innerHTML = 'Greater affixes: <b>' + nz(sc, 'items.greater_affix.ga1') + '</b> with 1 · <b>' + nz(sc, 'items.greater_affix.ga2') + '</b> with 2 · <b>' + nz(sc, 'items.greater_affix.ga3') + '</b> with 3';
    $('fate').innerHTML = [['Stashed', num(sc, 'items.stashed')], ['Salvaged', num(sc, 'items.salvaged')], ['Sold', num(sc, 'items.sold')], ['Kept', num(sc, 'items.kept')]].map(function (f) {
      return '<div><div class="cap">' + f[0] + '</div><div class="n num">' + big(f[1]) + '</div></div>';
    }).join('');
    var my = drops().filter(function (d) { return str(d, 'rarity') === 'mythic'; });
    $('myth').innerHTML = '<div class="cap">&#9670; Mythics</div><ul>' + (my.length ? my.map(function (d) {
      return '<li><b>' + esc(str(d, 'name', '?')) + '</b><span>' + esc(str(d, 'act')) + ' · ' + stamp(nz(d, 't')) + '</span></li>';
    }).join('') : '<li class="sub">None ' + (scope === 'alltime' ? 'listed' : 'yet') + '</li>') + '</ul>';
  }
  /* Blocks and ticks are placed by time (left/width = share of the span), so
     a gap the collector did not record (WarRoom off, PC asleep) stays empty
     and an hour tick sits where that hour is. The axis starts at the first
     block kept (the collector keeps the newest 200). */
  function renderStrip() {
    var S = arr(D, 'strip'), t1 = Math.max(nz(D, 't'), OFF ? 0 : Math.min(NOW, nz(D, 't') + every() * 3));
    var t0 = Math.max(nz(D, 'session.start'), S.length ? nz(S[0], 's') : 0);
    var panel = $('strip-panel');
    panel.hidden = scope === 'alltime';
    if (!S.length || !t0 || t1 <= t0) { $('strip').innerHTML = '<span class="empty">Nothing recorded this session yet</span>'; $('axis').innerHTML = ''; $('legend').innerHTML = ''; return; }
    var span = t1 - t0, pos = function (t) { return Math.min(100, Math.max(0, (t - t0) / span * 100)); };
    $('strip').innerHTML = S.map(function (b, i) {
      var a = str(b, 'a'), A = own(ACT, a), s = Math.max(nz(b, 's'), t0), last = i === S.length - 1;
      var e = Math.min(last ? Math.max(nz(b, 'e'), t1) : (nz(b, 'e') || s), t1), l = pos(s), w = pos(e) - l;
      if (w <= 0) return '';
      var lbl = A ? A.name : a ? a.charAt(0).toUpperCase() + a.slice(1) : '?';
      return '<i class="' + (A ? '' : 'n') + (last ? ' cur' : '') + '" style="left:' + l.toFixed(3) + '%;width:' + w.toFixed(3) + '%;' + (A ? 'background:' + acolor(a) : '') + '"' +
        tipAttr('<b>' + esc(lbl) + '</b><br>' + hhmm(s) + '–' + (last && !OFF ? 'now' : hhmm(e)) + ' · ' + mins(e - s)) + '>' + (A && w > 7 ? '<span>' + A.short + '</span>' : '') + '</i>';
    }).join('');
    var step = 3600;
    while (span / step > 6) step *= 2;
    var ticks = [[0, hhmm(t0), 'first']];
    for (var t = Math.ceil(t0 / 3600) * 3600; t < t1; t += 3600) {
      var x = pos(t);
      if ((t - Math.ceil(t0 / 3600) * 3600) % step || x < 9 || x > 91) continue;
      ticks.push([x, hhmm(t), '']);
    }
    ticks.push([100, OFF ? hhmm(t1) : 'now', 'last']);
    $('axis').innerHTML = ticks.map(function (x) { return '<span class="' + x[2] + '" style="left:' + x[0].toFixed(3) + '%">' + x[1] + '</span>'; }).join('');
    $('legend').innerHTML = ORDER.map(function (k) { return '<span>' + sw(k) + ACT[k].name + '</span>'; }).join('') + '<span><i style="background:var(--a-neutral)"></i>Town / travel / idle</span><span><i class="off"></i>Not recorded</span>';
  }
  function actsOf(r) { var a = obj(r, 'act'); return Object.keys(a).filter(function (k) { return +a[k]; }).map(function (k) { return a[k] + '× ' + (own(ACT, k) ? own(ACT, k).short : k); }).join(', '); }
  /* The x axis is time: hours (days for all time) with nothing recorded get
     an empty slot between the first and the last row, so a sleep or an off
     period shows as a gap, never as neighbouring bars. */
  function timeRows(rows, daily) {
    var step = daily ? 86400 : 3600, tol = daily ? 3 * 3600 : 900, max = daily ? 30 : 48, out = [], i = 0;
    var list = rows.filter(function (r) { return num(r, 't') != null; }).sort(function (a, b) { return nz(a, 't') - nz(b, 't'); });
    if (!list.length) return out;
    var cur = nz(list[0], 't'), end = nz(list[list.length - 1], 't');
    while (cur <= end + tol && out.length < 5000) {
      var rt = i < list.length ? nz(list[i], 't') : Infinity;
      if (rt < cur - tol) { i++; continue; }
      if (Math.abs(rt - cur) <= tol) { out.push(list[i]); cur = rt; i++; } else out.push({ t: cur });
      cur += step;
    }
    return out.slice(-max);
  }
  function chart(el, rows0, pick, color, unit, daily) {
    var rows = timeRows(rows0, daily), vals = rows.map(pick);
    if (!rows.length || !vals.some(function (v) { return v > 0; })) {
      el.innerHTML = '<div class="empty">' + (rows.length ? 'Nothing earned in this period yet' : 'No ' + (daily ? 'daily' : 'hourly') + ' figures for this scope yet') + '</div>';
      return;
    }
    var W = Math.max(260, Math.min(1400, el.clientWidth || 600)), Hh = W < 500 ? 150 : 180, pl = 44, pb = 22, pt = 8, max = 0;
    vals.forEach(function (v) { max = Math.max(max, v || 0); });
    var mag = Math.pow(10, Math.floor(Math.log(max) / Math.LN10)), stepv = mag * 10;
    [1, 2, 2.5, 5, 10].some(function (m) { if (max / (m * mag) <= 4) { stepv = m * mag; return true; } return false; });
    var top = Math.ceil(max / stepv) * stepv, n = rows.length, bw = (W - pl) / n, g = '';
    for (var v = 0; v <= top + 1e-9; v += stepv) {
      var y = pt + (Hh - pb - pt) * (1 - v / top);
      g += '<line class="gl' + (v === 0 ? ' z' : '') + '" x1="' + pl + '" x2="' + W + '" y1="' + y + '" y2="' + y + '"/><text class="gt" x="' + (pl - 8) + '" y="' + (y + 4) + '" text-anchor="end">' + big(v) + '</text>';
    }
    var every2 = Math.max(1, Math.ceil(46 / bw));
    rows.forEach(function (r, i) {
      var val = vals[i] || 0, t = nz(r, 't'), h = (Hh - pb - pt) * val / top, w = Math.max(1, bw * .64), x = pl + i * bw + bw * .18, y = Hh - pb - h, cur = i === n - 1 && !OFF && scope !== 'alltime';
      var lab = daily ? dlabel(t) : hhmm(t) + '–' + hhmm(t + 3600), ac = actsOf(r);
      g += '<rect class="hit" x="' + (pl + i * bw) + '" y="' + pt + '" width="' + bw + '" height="' + (Hh - pt) + '"' +
        tipAttr('<b>' + lab + (cur ? ' (so far)' : '') + '</b><br>' + big(val) + ' ' + esc(unit) + (ac ? '<br><span class="m">' + esc(ac) + '</span>' : '')) + '/>';
      if (val > 0) {
        var rr = Math.min(4, w / 2, h);
        g += '<path d="M' + x + ',' + (Hh - pb) + 'V' + (y + rr) + 'q0,-' + rr + ' ' + rr + ',-' + rr + 'h' + (w - 2 * rr) + 'q' + rr + ',0 ' + rr + ',' + rr + 'V' + (Hh - pb) + 'Z" style="fill:' + color + (cur ? ';fill-opacity:.45;stroke:' + color + ';stroke-dasharray:3 2' : '') + '"/>';
      }
      if (i % every2 === 0) g += '<text class="gt" x="' + (x + w / 2) + '" y="' + (Hh - 5) + '" text-anchor="middle">' + (daily ? dlabel(t) : hhmm(t)) + '</text>';
    });
    el.innerHTML = '<svg viewBox="0 0 ' + W + ' ' + Hh + '" role="img" aria-label="' + esc(unit) + ' per ' + (daily ? 'day' : 'hour') + '">' + g + '</svg>';
  }
  function rateCharts() {
    var sc = SC(), rows = arr(sc, 'hourly'), daily = scope === 'alltime';
    $('gold-h').textContent = daily ? 'Gold per day' : 'Gold per hour';
    $('xp-h').textContent = daily ? 'XP per day' : 'XP per hour';
    chart($('c-gold'), rows, function (r) { return num(r, 'gold'); }, 'var(--c-gold)', 'gold', daily);
    chart($('c-xp'), rows, function (r) { return num(r, 'xp'); }, 'var(--c-xp)', 'XP', daily);
    var gh = num(sc, 'rates.gold_hr'), xh = num(sc, 'rates.xp_hr');
    $('gold-avg').textContent = gh == null ? '' : 'avg ' + big(gh) + ' / h';
    $('xp-avg').textContent = xh == null ? '' : 'avg ' + big(xh) + ' / h';
  }
  function kColor(e) { var a = str(e, 'act'), k = str(e, 'kind'); return own(ACT, a) ? acolor(a) : k === 'death' || k === 'run_fail' ? 'var(--bad)' : k === 'drop' ? 'var(--r-unique)' : 'var(--a-neutral)'; }
  function feedHtml(list, dated) {
    return list.length ? list.map(function (e) {
      var k = str(e, 'kind'), d = num(e, 'dur');
      return '<li><time>' + (dated ? stamp(nz(e, 't')) : hhmm(nz(e, 't'))) + '</time><i class="k" style="background:' + kColor(e) + '"></i><span class="' + (k === 'run_fail' || k === 'death' || k === 'alert' ? 'fail' : '') + '">' +
        esc(str(e, 'text', k || '—')) + (dated && d ? '<span class="src">' + dur(d) + '</span>' : '') + '</span></li>';
    }).join('') : '<li><span></span><span></span><span class="sub">Nothing in this scope yet</span></li>';
  }
  function drops() { return arr(D, 'drops').filter(inScope); }
  function dropsHtml(list) {
    return list.length ? list.map(function (d) {
      var r = rarity(str(d, 'rarity')), ga = nz(d, 'ga'), pw = num(d, 'power');
      return '<li><i class="stripe" style="background:var(--r-' + r + ')"></i><div style="min-width:0"><b style="color:' + (r === 'mythic' ? 'var(--r-mythic)' : 'var(--ink)') + '">' + esc(str(d, 'name', '?')) + '</b>' +
        '<div class="m"><span class="tag">' + RNAME[r] + '</span>' + (ga ? '<span class="tag ga">' + ga + ' GA</span>' : '') + (pw ? '<span class="tag">' + pw + '</span>' : '') + esc(str(d, 'act')) + '</div></div>' +
        '<div class="r">' + stamp(nz(d, 't')) + '<br>' + esc(str(d, 'fate')) + '</div></li>';
    }).join('') : '<li class="sub" style="display:block">Nothing notable ' + (scope === 'alltime' ? 'listed' : 'yet') + '</li>';
  }
  function renderOverview() {
    renderNow();
    var al = arr(D, 'alerts'), open = openAlerts();
    renderAlerts($('alerts'), al.filter(function (x) { return !get(x, 'resolved'); }).concat(al.filter(function (x) { return get(x, 'resolved'); })).slice(0, 4));
    $('alert-sum').textContent = !D ? '' : open ? open + ' need a look' : 'All clear';
    counters(); activityTable(); itemsPanel(); renderStrip(); rateCharts();
    $('feed').className = 'feed' + (scope !== 'session' ? ' dated' : '');
    $('feed').innerHTML = feedHtml(arr(D, 'timeline').filter(inScope).slice(0, 7), scope !== 'session');
    $('drops').innerHTML = dropsHtml(drops().slice(0, 6));
  }

  /* ── helltide ── */
  var frameTheme = '';
  function renderHelltide() {
    var x = actBlock('helltide'), h = obj(D, 'helltide'), nx = num(h, 'next_in'), active = !!get(h, 'active');
    var left = nx == null ? null : Math.max(0, nx - Math.max(0, NOW - nz(D, 't')));
    $('h-kpis').innerHTML = [
      ['Helltides done', num(x, 'ok') == null ? '—' : big(num(x, 'ok')), num(x, 'runs') ? 'of ' + nz(x, 'runs') + ' started' : ''],
      ['Chests', big(num(x, 'extra.chests')), num(x, 'extra.mystery') != null ? nz(x, 'extra.mystery') + ' mystery' : ''],
      ['Cinders', big(num(x, 'extra.cinders')), 'collected in this scope'],
      ['Best run', num(x, 'best') ? big(num(x, 'best')) : '—', esc(str(x, 'best_label').toLowerCase())],
      /* null: the cinder count could not be read (not 0) */
      ['Cinders now', num(h, 'cinders') == null ? 'n/a' : big(num(h, 'cinders')), 'on the character'],
      /* next_in 0: a Helltide is on in the world now (the bot is not in it) */
      [active ? 'Helltide' : 'Next Helltide', active ? 'Now' : left == null ? '—' : nx === 0 ? 'On now' : mins(left), esc(str(h, 'zone'))]
    ].map(function (c) { return '<div><div class="cap">' + c[0] + '</div><div class="n' + (c[1] === '—' || c[1] === 'n/a' ? ' na' : '') + '">' + c[1] + '</div><div class="note">' + c[2] + '</div></div>'; }).join('');
    var file = str(h, 'file', 'hr_data.js');
    $('h-aside').textContent = 'The Helltide map, from ' + file;
    var fr = $('h-frame');
    if (window.innerWidth > 700 && frameTheme !== THEME) {
      frameTheme = THEME;
      var f = document.createElement('iframe');
      f.title = 'Helltide map'; f.loading = 'lazy'; f.src = 'helltide/' + THEME + '.html?embed=1';
      fr.innerHTML = ''; fr.appendChild(f);
    }
  }

  /* ── activity pages (pit, undercity, hordes, bosses, whispers) ── */
  function renderActivity(k) {
    var A = ACT[k], x = actBlock(k), p = obj(obj(D, 'plugins'), A.key), se = obj(D, 'session');
    $('a-plugin').textContent = A.plugin + (str(p, 'role') ? ' · ' + str(p, 'role') : '');
    $('a-title').innerHTML = sw(k) + A.name;
    var running = str(se, 'now.activity') === k;
    $('a-state').textContent = !D ? 'No data yet' : running ? 'Running now: ' + (str(se, 'now.step') || str(se, 'now.title') || '') : 'Not running now' + (str(p, 'state') ? ' · ' + str(p, 'state') : '');
    var r = nz(x, 'runs'), ok = nz(x, 'ok'), bl = str(x, 'best_label'), bv = num(x, 'best');
    $('a-kpis').innerHTML = [['Done', num(x, 'runs') == null ? '—' : ok + ' <small>of ' + r + '</small>'], ['Success', pct(ok, r)], ['Avg time', num(x, 'avg_time') ? dur(num(x, 'avg_time')) : '—'],
      bl && bv ? ['Best ' + bl.toLowerCase(), big(bv)] : ['Time spent', num(x, 'time') ? mins(num(x, 'time')) : '—']]
      .map(function (c) { return '<div><div class="cap">' + esc(c[0]) + '</div><div class="n' + (c[1] === '—' ? ' na' : '') + '">' + c[1] + '</div></div>'; }).join('');
    var runs = arr(D, 'timeline').filter(function (e) { var kd = str(e, 'kind'); return str(e, 'act') === k && inScope(e) && (kd === 'run_ok' || kd === 'run_fail' || kd === 'run_start' || kd === 'death'); });
    $('a-runs').innerHTML = '<thead><tr><th>Time</th><th class="l">Result</th><th>Duration</th></tr></thead><tbody>' + (runs.length ? runs.map(function (e) {
      var kd = str(e, 'kind'), d = num(e, 'dur');
      return '<tr><td>' + stamp(nz(e, 't')) + '</td><td class="l wrap-ok' + (kd === 'run_fail' || kd === 'death' ? ' fail' : '') + '">' + esc(str(e, 'text', kd)) + '</td><td>' + (d ? dur(d) : kd === 'run_start' ? 'started' : '—') + '</td></tr>';
    }).join('') : '<tr><td colspan="3" class="sub">No runs in this scope</td></tr>') + '</tbody>';
    var ex = obj(x, 'extra'), keys = Object.keys(ex).filter(function (q) { return typeof ex[q] !== 'object'; });
    var kv = keys.map(function (q) { return [human(q), typeof ex[q] === 'number' ? big(ex[q]) : ex[q]]; });
    if (num(x, 'time')) kv.push(['Time spent', mins(num(x, 'time'))]);
    if (r) kv.push(['Failed', nz(x, 'failed')]);
    $('a-extra').innerHTML = kv.length ? kv.map(function (q) { return '<div class="kv"><span>' + esc(q[0]) + '</span><span>' + esc(q[1]) + '</span></div>'; }).join('') : '<div class="empty">Nothing recorded in this scope</div>';
    $('a-scope').textContent = SCOPES[scope];
    var bb = obj(x, 'extra.by_boss'), bk = Object.keys(bb).filter(function (q) { return +bb[q] > 0; }).sort(function (a, b) { return bb[b] - bb[a]; }), bmax = 1;
    bk.forEach(function (q) { bmax = Math.max(bmax, +bb[q]); });
    $('a-byboss').innerHTML = bk.length ? '<div class="hbar">' + bk.map(function (q) {
      return '<span>' + esc(q) + '</span><div class="trk"><i style="width:' + (bb[q] / bmax * 100) + '%;background:' + acolor(k) + '"></i></div><span class="v">' + big(+bb[q]) + '</span>';
    }).join('') + '</div>' : '';
    var pk = arr(p, 'kv');
    $('a-kv').innerHTML = (str(p, 'state') ? '<div class="kv"><span>State</span><span>' + esc(str(p, 'state')) + '</span></div>' : '') +
      (pk.length ? pk.map(function (q) { return '<div class="kv"><span>' + esc(at(q, 0)) + '</span><span>' + esc(at(q, 1)) + '</span></div>'; }).join('') : '<div class="empty">The plugin reports nothing yet</div>');
    var rows = arr(SC(), 'hourly'), daily = scope === 'alltime';
    $('a-ch').textContent = daily ? 'Runs per day' : 'Runs per hour';
    chart($('a-chart'), rows, function (q) { return +own(obj(q, 'act'), k) || 0; }, acolor(k), 'runs', daily);
    $('a-drops').innerHTML = dropsHtml(drops().filter(function (d) { return str(d, 'src') === k; }));
  }

  /* ── items ── */
  function sel(id, label, opts, cur) {
    return '<label>' + label + ' <select data-f="' + id + '">' + opts.map(function (o) { return '<option value="' + esc(o[0]) + '"' + (String(o[0]) === String(cur) ? ' selected' : '') + '>' + esc(o[1]) + '</option>'; }).join('') + '</select></label>';
  }
  function renderItems() {
    var all = drops(), fates = {};
    all.forEach(function (d) { var f = str(d, 'fate'); if (f) fates[f] = 1; });
    var rows = all.filter(function (d) {
      return (iFilter.rar === 'all' || str(d, 'rarity') === iFilter.rar) && (iFilter.src === 'all' || str(d, 'src') === iFilter.src) &&
        nz(d, 'ga') >= iFilter.ga && (iFilter.fate === 'all' || str(d, 'fate') === iFilter.fate);
    });
    $('i-filters').innerHTML = '<div class="chips">' + ['all', 'mythic', 'unique', 'legendary'].map(function (o) {
      return '<button type="button" data-if="' + o + '" aria-pressed="' + (o === iFilter.rar) + '">' + (o === 'all' ? 'All' : RNAME[o]) + '</button>';
    }).join('') + '</div>' + sel('src', 'From', [['all', 'Anywhere']].concat(ORDER.map(function (k) { return [k, ACT[k].short]; })), iFilter.src) +
      sel('ga', 'GA', [[0, 'Any'], [1, '1+'], [2, '2+'], [3, '3']], iFilter.ga) +
      sel('fate', 'Fate', [['all', 'Any']].concat(Object.keys(fates).sort().map(function (f) { return [f, f]; })), iFilter.fate) +
      '<span class="count">' + rows.length + ' of ' + all.length + ' · ' + SCOPES[scope] + '</span>';
    $('i-list').innerHTML = dropsHtml(rows);
    $('i-table').innerHTML = '<thead><tr><th>Item</th><th class="l">Rarity</th><th>GA</th><th>Power</th><th class="l">From</th><th class="l">Fate</th><th>Time</th></tr></thead><tbody>' + (rows.length ? rows.map(function (d) {
      var r = rarity(str(d, 'rarity'));
      return '<tr><td><span style="display:inline-block;width:4px;height:14px;vertical-align:-2px;margin-right:9px;background:var(--r-' + r + ')"></span><span' + (r === 'mythic' ? ' class="mark"' : '') + '>' + esc(str(d, 'name', '?')) + '</span></td>' +
        '<td class="l">' + RNAME[r] + '</td><td>' + (nz(d, 'ga') || '—') + '</td><td>' + (num(d, 'power') || '—') + '</td><td class="l">' + esc(str(d, 'act', str(d, 'src'))) + '</td><td class="l">' + esc(str(d, 'fate')) + '</td><td>' + stamp(nz(d, 't')) + '</td></tr>';
    }).join('') : '<tr><td colspan="7" class="sub">No drops match</td></tr>') + '</tbody>';
  }

  /* ── timeline ── */
  var TK = [['all', 'All'], ['runs', 'Runs'], ['drop', 'Drops'], ['problems', 'Problems'], ['town', 'Town'], ['plan', 'Plan']];
  function renderTimeline() {
    var all = arr(D, 'timeline').filter(inScope), f = tFilter;
    var rows = all.filter(function (e) {
      var k = str(e, 'kind');
      var okk = f.kind === 'all' || (f.kind === 'runs' ? /^run_/.test(k) : f.kind === 'problems' ? (k === 'run_fail' || k === 'death' || k === 'alert') : f.kind === 'plan' ? (k === 'plan' || k === 'level') : k === f.kind);
      return okk && (f.act === 'all' || str(e, 'act') === f.act);
    });
    $('t-filters').innerHTML = '<div class="chips">' + TK.map(function (o) { return '<button type="button" data-tf="' + o[0] + '" aria-pressed="' + (o[0] === f.kind) + '">' + o[1] + '</button>'; }).join('') + '</div>' +
      sel('act', 'Activity', [['all', 'All']].concat(ORDER.map(function (k) { return [k, ACT[k].short]; })).concat([['town', 'Town']]), f.act) +
      '<span class="count">' + rows.length + ' of ' + all.length + '</span>';
    $('t-aside').textContent = 'Newest first · ' + SCOPES[scope];
    var el = $('t-feed'); el.className = 'feed' + (scope !== 'session' ? ' dated' : '');
    el.innerHTML = feedHtml(rows, scope !== 'session');
  }

  /* ── bot ── */
  function renderBot() {
    var se = obj(D, 'session'), wp = obj(se, 'warplan'), st = str(se, 'status');
    $('b-kpis').innerHTML = [['Status', esc(own(STATUS, st) || st || '—')], ['Uptime', dur(num(se, 'uptime'))], ['War plan', esc(str(wp, 'name', '—')) + (num(wp, 'steps') ? '<small>' + nz(wp, 'step') + '/' + num(wp, 'steps') + '</small>' : '')],
      ['Writes every', num(D, 'write_every') ? num(D, 'write_every') + '<small>s</small>' : '—']]
      .map(function (c, i) { return '<div><div class="cap">' + c[0] + '</div><div class="n' + (c[1] === '—' ? ' na' : '') + (i === 2 ? ' txt' : '') + '">' + c[1] + '</div></div>'; }).join('');
    var P = obj(D, 'plugins'), keys = Object.keys(P);
    $('plugins').innerHTML = keys.length ? keys.map(function (k) {
      var p = at(P, k), s = str(p, 'state'), cls = own(PSTATE, s) ? s : '', kv = arr(p, 'kv'), ver = str(p, 'ver');
      return '<div class="plug ' + cls + '"><h3>' + esc(str(p, 'name', k)) + '<span class="st ' + cls + '">' + esc(s || '—') + '</span></h3><div class="sub" style="margin:2px 0 8px">' + esc(str(p, 'role')) + (ver ? ' · v' + esc(ver) : '') + '</div><div class="kvs">' +
        kv.slice(0, 8).map(function (r) { return '<div class="kv"><span>' + esc(at(r, 0)) + '</span><span>' + esc(at(r, 1)) + '</span></div>'; }).join('') + '</div></div>';
    }).join('') : '<div class="empty">No plugin has reported yet</div>';
    var al = arr(D, 'alerts');
    renderAlerts($('alerts-all'), al);
    var open = openAlerts();
    $('b-alerts').textContent = !D ? '' : open ? open + ' need a look' : 'All clear';
  }

  function renderAll() {
    NOW = Date.now() / 1000;
    freshness(); renderHead(); buildTabs(); renderPage();
  }

  /* ── events ── */
  document.addEventListener('click', function (ev) {
    var t = ev.target.closest ? ev.target.closest('[data-scope],[data-go],[data-if],[data-tf],.hrsw a[data-theme-file]') : null;
    if (!t) return;
    if (t.hasAttribute('data-theme-file')) {
      try { localStorage.setItem('wr_theme', t.getAttribute('data-theme-file')); } catch (e) { /* blocked */ }
      if (location.hash) t.setAttribute('href', t.getAttribute('href').split('#')[0] + location.hash);
      return;
    }
    if (t.hasAttribute('data-scope')) { scope = t.getAttribute('data-scope'); try { localStorage.setItem('wr_scope', scope); } catch (e) { /* blocked */ } renderAll(); }
    else if (t.hasAttribute('data-go')) location.hash = t.getAttribute('data-go');
    else if (t.hasAttribute('data-if')) { iFilter.rar = t.getAttribute('data-if'); renderItems(); }
    else if (t.hasAttribute('data-tf')) { tFilter.kind = t.getAttribute('data-tf'); renderTimeline(); }
  });
  document.addEventListener('change', function (ev) {
    var f = ev.target.getAttribute && ev.target.getAttribute('data-f');
    if (!f) return;
    var v = ev.target.value;
    if (f === 'ga') iFilter.ga = +v || 0; else if (f === 'act') tFilter.act = v; else iFilter[f] = v;
    if (f === 'act') renderTimeline(); else renderItems();
  });
  var rz; window.addEventListener('resize', function () { clearTimeout(rz); rz = setTimeout(renderAll, 150); });
  window.addEventListener('hashchange', function () { route(true); window.scrollTo(0, 0); });
  document.addEventListener('mousemove', function (ev) {
    var tip = $('tip'); if (!tip) return;
    var t = ev.target.closest && ev.target.closest('[data-tip]');
    if (!t) { tip.style.display = 'none'; return; }
    tip.innerHTML = t.getAttribute('data-tip'); tip.style.display = 'block';
    var x = ev.clientX + 14, y = ev.clientY + 14, r = tip.getBoundingClientRect();
    if (x + r.width > innerWidth - 8) x = ev.clientX - r.width - 14;
    if (y + r.height > innerHeight - 8) y = ev.clientY - r.height - 14;
    tip.style.left = x + 'px'; tip.style.top = y + 'px';
  });

  /* ── data loading: re-inject the script (works from file://, no fetch) ── */
  var timer = null;
  function schedule() { clearTimeout(timer); timer = setTimeout(load, Math.max(5, Math.min(60, num(D, 'write_every') || 15)) * 1000); }
  function load() {
    var s = document.createElement('script');
    s.src = 'suite_data.js?_=' + Date.now();
    s.onload = function () {
      s.parentNode && s.parentNode.removeChild(s);
      var d = window.SUITE_DATA;
      TOO_NEW = !!(d && typeof d === 'object' && (+get(d, 'v') || 0) > KNOWN_V);
      if (d && typeof d === 'object' && !TOO_NEW) D = d; else if (TOO_NEW) D = null;
      noteWrite();
      renderAll(); schedule();
    };
    s.onerror = function () { s.parentNode && s.parentNode.removeChild(s); renderAll(); schedule(); };
    document.head.appendChild(s);
  }

  shell();
  tabNow = currentTab();
  route(true);
  renderAll();
  load();
  setInterval(function () { if (!D) return; NOW = Date.now() / 1000; freshness(); if (tabNow === 'overview') renderNow(); }, 1000);
})();
