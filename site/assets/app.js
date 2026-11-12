/* Renders patch results in two views:
     Live        data/live.json, written by the serverless-patch-site-publisher Lambda after every
                 cycle starts or ends; re-checked every 60 s while the page is open.
     Evaluation  window.PATCH_DATA (data/patch-data.js), built from evidence/ by build_site_data.py
                 for the reporting period; never changes on its own.
   Same counting rules as lambda/summary_widget.py: success = verified fixed / attempted,
   colours green from 90 %, amber from 80 %, red below (as the CloudWatch dashboard). */
(function () {
  'use strict';

  var EVAL = window.PATCH_DATA && window.PATCH_DATA.cycles ? window.PATCH_DATA : null;
  var LIVE_URL = 'data/live.json';
  var POLL_MS = 60000;
  var RATE_GOOD = 90, RATE_WARN = 80;
  var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  var STATUS = {
    patched: ['PATCHED', 'ok'], patched_partial: ['PARTIAL', 'warn'], failed: ['FAILED', 'bad'],
    compliant: ['COMPLIANT', 'ok'], scanned: ['SCANNED', 'muted'], skipped: ['SKIPPED', 'muted'],
  };
  var RESULT_TONE = { PATCHED: 'ok', COMPLIANT: 'ok', PARTIAL: 'warn', FAILED: 'bad' };
  var PLATFORM = { rhel: 'RHEL 9', windows: 'Windows Server 2022' };
  var SEVERITIES = [
    ['Critical', 'fixed_critical', '--sev-critical'], ['Important', 'fixed_important', '--sev-important'],
    ['Moderate', 'fixed_moderate', '--sev-moderate'], ['Low', 'fixed_low', '--sev-low'],
    ['Unrated', 'fixed_unrated', '--sev-unrated'],
  ];
  var SVG_NS = 'http://www.w3.org/2000/svg';

  var state = {
    view: null,          // 'live' | 'evaluation'
    live: null,          // last live.json that loaded
    liveText: '',        // its raw text, to tell a new publish from the same one
    liveFailed: false,
    data: null,          // what is drawn now
    sortKey: 'started', sortDir: -1,
    hostColour: {},
    redraw: null,
  };

  // ------------------------------------------------------------ helpers
  function $(id) { return document.getElementById(id); }
  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }
  function svg(tag, attrs) {
    var n = document.createElementNS(SVG_NS, tag);
    for (var k in attrs) n.setAttribute(k, attrs[k]);
    return n;
  }
  function css(name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); }
  var nf = new Intl.NumberFormat('en');
  var nf1 = new Intl.NumberFormat('en', { minimumFractionDigits: 1, maximumFractionDigits: 1 });
  function mytDate(iso) { return new Date(Date.parse(iso) + 8 * 3600e3); } // read with UTC getters = MYT
  function pad(n) { return String(n).padStart(2, '0'); }
  function mytDay(iso) { var d = mytDate(iso); return d.getUTCDate() + ' ' + MONTHS[d.getUTCMonth()] + ' ' + d.getUTCFullYear(); }
  function mytStamp(iso) { var d = mytDate(iso); return d.getUTCDate() + ' ' + MONTHS[d.getUTCMonth()] + ', ' + pad(d.getUTCHours()) + ':' + pad(d.getUTCMinutes()); }
  function mytClock(iso) { var d = mytDate(iso); return pad(d.getUTCHours()) + ':' + pad(d.getUTCMinutes()); }
  function dayLabel(ymd) { var p = ymd.split('-'); return Number(p[2]) + ' ' + MONTHS[Number(p[1]) - 1] + ' ' + p[0]; }
  function dur(s) {
    s = Math.round(s);
    if (s < 60) return s + 's';
    var m = Math.floor(s / 60);
    return m + 'm ' + pad(s % 60) + 's';
  }
  function ago(iso) {
    var s = Math.max(0, (Date.now() - Date.parse(iso)) / 1000);
    if (s < 90) return 'just now';
    if (s < 3600) return Math.round(s / 60) + ' min ago';
    if (s < 48 * 3600) return Math.round(s / 3600) + ' h ago';
    return Math.round(s / 86400) + ' days ago';
  }
  function tone(pct) { return pct == null ? '' : pct >= RATE_GOOD ? 'tone-ok' : pct >= RATE_WARN ? 'tone-warn' : 'tone-bad'; }
  function isDone(r) { return r.status === 'patched' || r.status === 'patched_partial'; }
  function rate(rows) {
    var ok = 0, att = 0, n = 0;
    rows.forEach(function (r) { ok += r.succeeded; att += r.attempted; if (r.attempted > 0) n += 1; });
    return { pct: att ? 100 * ok / att : null, ok: ok, att: att, runs: n };
  }
  function evalRange() {
    var w = (EVAL && EVAL.window) || {};
    if (!w.from || !w.to) return '';
    var a = w.from.split('-'), b = w.to.split('-');
    if (a[0] === b[0] && a[1] === b[1]) return Number(a[2]) + '–' + Number(b[2]) + ' ' + MONTHS[Number(a[1]) - 1];
    return dayLabel(w.from) + ' – ' + dayLabel(w.to);
  }
  function latestPerHost(runs) {
    var latest = {};
    runs.forEach(function (r) { if (!latest[r.host] || r.started > latest[r.host].started) latest[r.host] = r; });
    return Object.keys(latest).map(function (k) { return latest[k]; })
      .sort(function (a, b) { return (a.platform + a.host).localeCompare(b.platform + b.host); });
  }

  // ------------------------------------------------------------ tooltip
  var tip = $('tip');
  function showTip(lines, x, y) {
    tip.replaceChildren();
    lines.forEach(function (l, i) {
      var row = el('div', i === 0 ? 'k' : null);
      if (l.colour) { var sw = el('i'); sw.style.background = l.colour; row.appendChild(sw); }
      row.appendChild(document.createTextNode(l.text));
      tip.appendChild(row);
    });
    tip.hidden = false;
    var w = tip.offsetWidth, h = tip.offsetHeight;
    var left = Math.min(Math.max(8 + window.scrollX, x - w / 2), window.scrollX + document.documentElement.clientWidth - w - 8);
    tip.style.left = left + 'px';
    tip.style.top = (y - h - 14) + 'px';
  }
  function hideTip() { tip.hidden = true; }

  // ------------------------------------------------------------ status line
  function periodLabels(data) {
    var starts = (data.cycles || []).map(function (c) { return c.started; }).sort();
    var first = starts.length ? mytDay(starts[0]) : '', last = starts.length ? mytDay(starts[starts.length - 1]) : '';
    var w = data.window || {};
    if (w.from) first = dayLabel(w.from);
    if (w.to) last = dayLabel(w.to);
    return { first: first, last: last };
  }
  function drawStatus() {
    var data = state.data;
    var line = $('status-line'), text = $('status-text');
    line.classList.remove('is-ok', 'is-warn', 'is-running');
    if (!data) { text.textContent = 'No results to show yet.'; return; }
    var latest = latestPerHost(data.host_runs || []);
    var clean = latest.filter(function (r) { return r.after === 0; }).length;
    var st = data.status || {};
    if (state.view === 'live' && st.state === 'running') {
      line.classList.add('is-running');
      text.textContent = (st.mode === 'patch' ? 'Patch cycle' : 'Scan') + ' in progress · started ' + mytClock(st.since) +
        ' MYT (' + ago(st.since) + ')' + (st.count > 1 ? ' · ' + st.count + ' runs' : '') + ' · this page updates when it finishes';
      return;
    }
    if (!latest.length) {
      text.textContent = state.view === 'live'
        ? 'No patch cycles in the last ' + ((data.window || {}).days || 30) + ' days · updated ' + ago(data.generated_at)
        : 'No patch cycles in this period.';
      return;
    }
    line.classList.add(clean === latest.length ? 'is-ok' : 'is-warn');
    var base = 'Latest run on each host: ' + clean + ' of ' + latest.length + ' hosts with no missing updates';
    if (state.view === 'live') {
      text.textContent = base + ' · updated ' + ago(data.generated_at);
    } else {
      var p = periodLabels(data);
      text.textContent = base + ' · results ' + p.first + ' to ' + p.last;
    }
  }

  // ------------------------------------------------------------ host colours (stable across redraws)
  function colourName(host, platform) {
    var hc = state.hostColour;
    if (!hc[host]) {
      var used = Object.keys(hc).filter(function (h) { return hc[h].platform === platform; }).length;
      hc[host] = { platform: platform, name: platform === 'windows' ? '--win' : (used === 0 ? '--rhel' : '--rhel-2') };
    }
    return hc[host].name;
  }
  function colourFor(host, platform) { return css(colourName(host, platform)); }

  // ------------------------------------------------------------ full render
  function render(data) {
    state.data = data;
    hideTip();
    var runs = data.host_runs || [];
    var cycles = data.cycles || [];
    var LIMIT = data.lambda_limit_s || 900;
    var live = state.view === 'live';

    $('results-h').textContent = live ? 'Live results' : 'Evaluation results';
    var days = (data.window || {}).days || 30;
    var p = periodLabels(data);
    $('window-note').textContent = live
      ? cycles.length + ' patch cycles and ' + runs.length + ' host runs in the last ' + days + ' days (times in MYT). ' +
        'Updates automatically when a patch cycle starts or finishes. Success counts only updates the post-install rescan confirmed as fixed.'
      : cycles.length + ' patch cycles and ' + runs.length + ' host runs between ' + p.first + ' and ' + p.last +
        ' (MYT). Success counts only updates the post-install rescan confirmed as fixed.';
    $('source-note').textContent = live
      ? 'Live results come from the records the serverless-patch-metrics Lambda writes after every cycle, published here by the serverless-patch-site-publisher Lambda.'
      : 'Evaluation results come from the cycle results in the repository\'s evidence/ folder' + (data.commit ? ' (commit ' + data.commit + ').' : '.');

    ['tiles', 'host-cards', 'dur-legend', 'dur-chart', 'sev-chart', 'sev-legend'].forEach(function (id) { $(id).replaceChildren(); });
    $('cycle-table').tBodies[0].replaceChildren();
    drawStatus();

    if (!cycles.length) {
      var msg = live ? 'No patch cycles in the last ' + days + ' days yet.' : 'No patch cycles in this period.';
      $('tiles').appendChild(el('p', 'empty', msg));
      $('host-cards').appendChild(el('p', 'empty', 'Host results appear after the first patch cycle.'));
      $('dur-chart').appendChild(el('p', 'empty', 'No completed host runs to chart.'));
      $('sev-chart').appendChild(el('p', 'empty', 'No completed host runs to chart.'));
      var tr = el('tr'); var td = el('td', 'empty', msg); td.colSpan = 7; tr.appendChild(td);
      $('cycle-table').tBodies[0].appendChild(tr);
      state.redraw = null;
      return;
    }

    // ---------------- tiles
    var overall = rate(runs);
    var rhel = rate(runs.filter(function (r) { return r.platform === 'rhel'; }));
    var windows = rate(runs.filter(function (r) { return r.platform === 'windows'; }));
    var latestRows = latestPerHost(runs);
    var done = runs.filter(isDone);
    var failedHostRuns = cycles.reduce(function (a, c) { return a + c.failed; }, 0);
    var avgCycleMin = cycles.reduce(function (a, c) { return a + c.duration_s; }, 0) / cycles.length / 60;
    var longest = done.length ? Math.max.apply(null, done.map(function (r) { return r.duration_s; })) : null;

    function rateTile(label, r, unit) {
      var t = el('div', 'tile ' + tone(r.pct));
      t.appendChild(el('p', 'tile-label', label));
      var v = el('p', 'tile-value', r.pct == null ? '–' : nf1.format(r.pct));
      if (r.pct != null) v.appendChild(el('small', null, '%'));
      t.appendChild(v);
      var m = el('div', 'meter');
      m.setAttribute('aria-hidden', 'true');
      var fill = el('span'); fill.style.width = (r.pct || 0).toFixed(1) + '%';
      var mark = el('i'); mark.style.left = RATE_GOOD + '%'; mark.title = 'Green from ' + RATE_GOOD + '%';
      m.appendChild(fill); m.appendChild(mark);
      t.appendChild(m);
      t.appendChild(el('p', 'tile-sub', r.att ? nf.format(r.ok) + ' of ' + nf.format(r.att) + ' ' + unit + ' verified · ' + r.runs + ' host runs' : 'No updates attempted'));
      return t;
    }
    function plainTile(label, value, unit, sub) {
      var t = el('div', 'tile');
      t.appendChild(el('p', 'tile-label', label));
      var v = el('p', 'tile-value', value);
      if (unit) v.appendChild(el('small', null, unit));
      t.appendChild(v);
      t.appendChild(el('p', 'tile-sub', sub));
      return t;
    }
    var tiles = $('tiles');
    tiles.appendChild(rateTile('Overall success rate', overall, 'updates'));
    tiles.appendChild(rateTile('RHEL 9 success rate', rhel, 'RHSA'));
    tiles.appendChild(rateTile('Windows success rate', windows, 'KB'));
    tiles.appendChild(plainTile('Patch cycles', String(cycles.length), '', failedHostRuns + ' failed host runs'));
    tiles.appendChild(plainTile('Average cycle time', nf1.format(avgCycleMin), 'min', 'From trigger to verified result'));
    tiles.appendChild(longest == null ? plainTile('Longest host run', '–', '', 'No completed host runs')
      : plainTile('Longest host run', nf1.format(longest / 60), 'min',
        longest > LIMIT ? 'Past the 15-min Lambda limit, so installs run on the host' : 'Within the 15-min Lambda limit'));

    // ---------------- host cards
    latestRows.forEach(function (r) { colourName(r.host, r.platform); });
    var cards = $('host-cards');
    var barScale = Math.max.apply(null, [LIMIT * 2].concat(latestRows.map(function (r) { return r.duration_s * 1.1; })));
    latestRows.forEach(function (r) {
      var st = STATUS[r.status] || [String(r.status).toUpperCase(), 'muted'];
      var card = el('article', 'host');
      card.style.setProperty('--plat', 'var(' + colourName(r.host, r.platform) + ')');
      var top = el('div', 'host-top');
      top.appendChild(el('span', 'host-name', r.host));
      top.appendChild(el('span', 'chip ' + st[1], st[0]));
      card.appendChild(top);
      card.appendChild(el('p', 'host-meta', (PLATFORM[r.platform] || r.platform) + ' · ' + r.workload + ' · ' + mytStamp(r.started) + ' MYT'));
      var big = el('p', 'host-big', r.status === 'failed' || r.after == null ? String(r.before) : r.before + ' → ' + r.after);
      big.appendChild(el('small', null, r.unit + ' missing'));
      card.appendChild(big);
      card.appendChild(el('p', 'host-row', r.status === 'failed'
        ? 'Failed at ' + (r.failed_at || 'an unknown step')
        : nf.format(r.succeeded) + ' of ' + nf.format(r.attempted) + ' verified fixed'));
      var bar = el('div', 'runbar');
      bar.setAttribute('role', 'img');
      bar.setAttribute('aria-label', 'Run time ' + dur(r.duration_s) + ' against the ' + LIMIT + ' second Lambda limit');
      var fill = el('span');
      fill.style.width = Math.min(100, 100 * r.duration_s / barScale).toFixed(1) + '%';
      fill.style.background = r.duration_s > LIMIT ? 'var(--bad)' : 'var(--ok)';
      var lim = el('i'); lim.style.left = (100 * LIMIT / barScale).toFixed(1) + '%';
      bar.appendChild(fill); bar.appendChild(lim);
      card.appendChild(bar);
      var timing = el('div', 'host-row');
      timing.appendChild(el('span', null, dur(r.duration_s) + ' run time'));
      timing.appendChild(el('span', null, '| ' + LIMIT + ' s Lambda limit'));
      card.appendChild(timing);
      var flags = el('div', 'flags');
      if (r.rebooted != null) flags.appendChild(el('span', 'flag' + (r.rebooted ? ' good' : ''), r.rebooted ? 'Rebooted' : 'No reboot needed'));
      if (r.healthy != null) flags.appendChild(el('span', 'flag ' + (r.healthy ? 'good' : 'bad'), r.healthy ? 'Workload healthy' : 'Workload not healthy'));
      card.appendChild(flags);
      cards.appendChild(card);
    });

    // ---------------- deployment time chart
    var hosts = Array.from(new Set(done.map(function (r) { return r.host; }))).sort();
    var legend = $('dur-legend');
    hosts.forEach(function (h) {
      var name = colourName(h, (done.filter(function (r) { return r.host === h; })[0] || {}).platform);
      var s = el('span'); var i = el('i');
      if (name === '--rhel-2') i.style.border = '2px solid var(--rhel-2)';
      else i.style.background = 'var(' + name + ')';
      s.appendChild(i); s.appendChild(document.createTextNode(h));
      legend.appendChild(s);
    });
    var limLegend = el('span'); var li = el('i', 'sq'); li.style.cssText = 'height:2px;background:var(--bad)';
    limLegend.appendChild(li); limLegend.appendChild(document.createTextNode('15-min Lambda limit'));
    legend.appendChild(limLegend);

    function niceMax(v) {
      var steps = [5, 10, 15, 20, 25, 30, 40, 50, 60, 90, 120];
      for (var i = 0; i < steps.length; i++) if (steps[i] >= v) return steps[i];
      return Math.ceil(v / 30) * 30;
    }
    function drawDurations() {
      var box = $('dur-chart');
      box.replaceChildren();
      if (!done.length) { box.appendChild(el('p', 'empty', 'No completed host runs to chart.')); return; }
      var W = Math.max(280, box.clientWidth), H = 270;
      var top = 10, bottom = 28;
      var yMax = niceMax(Math.max(LIMIT / 60 * 1.1, Math.max.apply(null, done.map(function (r) { return r.duration_s / 60; })) * 1.05));
      var tickStep = yMax <= 30 ? 5 : 10;
      var ticks = []; for (var t = 0; t <= yMax; t += tickStep) ticks.push(t);
      var s = svg('svg', { viewBox: '0 0 ' + W + ' ' + H, role: 'img', 'aria-label': 'Deployment time per host run, in minutes' });
      box.appendChild(s);
      var probe = svg('text', {}); probe.textContent = yMax + ' min'; s.appendChild(probe);
      var left = Math.ceil(probe.getComputedTextLength()) + 12; s.removeChild(probe);
      var right = W - 10;
      var times = done.map(function (r) { return mytDate(r.started).getTime(); });
      var dayMs = 864e5;
      var t0 = Math.floor(Math.min.apply(null, times) / dayMs) * dayMs;
      var t1 = Math.ceil(Math.max.apply(null, times) / dayMs) * dayMs;
      if (t1 <= t0) t1 = t0 + dayMs;
      function x(tv) { return left + (tv - t0) / (t1 - t0) * (right - left); }
      function y(m) { return H - bottom - m / yMax * (H - bottom - top); }

      ticks.forEach(function (tv) {
        s.appendChild(svg('line', { x1: left, x2: right, y1: y(tv), y2: y(tv), stroke: css('--grid') }));
        var lab = svg('text', { x: left - 8, y: y(tv), dy: '0.32em', 'text-anchor': 'end' });
        lab.textContent = tv + ' min'; s.appendChild(lab);
      });
      var days = (t1 - t0) / dayMs;
      var every = Math.max(1, Math.ceil(52 / ((right - left) / days)));
      for (var d = 0; d <= days; d += every) {
        var td = t0 + d * dayMs, dt = new Date(td);
        s.appendChild(svg('line', { x1: x(td), x2: x(td), y1: H - bottom, y2: H - bottom + 4, stroke: css('--line') }));
        var xl = svg('text', { x: x(td), y: H - 8, 'text-anchor': d === 0 ? 'start' : (td === t1 ? 'end' : 'middle') });
        xl.textContent = dt.getUTCDate() + ' ' + MONTHS[dt.getUTCMonth()]; s.appendChild(xl);
      }
      s.appendChild(svg('line', { x1: left, x2: right, y1: y(0), y2: y(0), stroke: css('--muted'), 'stroke-opacity': 0.5 }));
      s.appendChild(svg('line', { x1: left, x2: right, y1: y(LIMIT / 60), y2: y(LIMIT / 60), stroke: css('--bad'), 'stroke-width': 1.5, 'stroke-dasharray': '6 4' }));

      var dots = [];
      done.forEach(function (r, i) {
        // rhel-01 and rhel-02 run in the same cycle with near-identical times, so the second
        // RHEL host is drawn as a ring to stay visible on top of the first.
        var ring = colourName(r.host, r.platform) === '--rhel-2';
        var colour = colourFor(r.host, r.platform);
        var c = svg('circle', ring
          ? { cx: x(times[i]), cy: y(r.duration_s / 60), r: 5.5, fill: 'none', 'fill-opacity': 0.88, stroke: colour, 'stroke-width': 2.25 }
          : { cx: x(times[i]), cy: y(r.duration_s / 60), r: 5.5, fill: colour, 'fill-opacity': 0.88, stroke: css('--surface'), 'stroke-width': 1.5 });
        s.appendChild(c);
        dots.push({ node: c, r: r, cx: x(times[i]), cy: y(r.duration_s / 60) });
      });

      function nearest(ev) {
        var pt = s.getBoundingClientRect(); var k = W / pt.width;
        var px = (ev.clientX - pt.left) * k, py = (ev.clientY - pt.top) * k;
        var best = null, bd = Infinity;
        dots.forEach(function (dd) { var q = (dd.cx - px) * (dd.cx - px) + (dd.cy - py) * (dd.cy - py); if (q < bd) { bd = q; best = dd; } });
        return bd < 40 * 40 * k * k ? { d: best, k: k, rect: pt } : null;
      }
      s.addEventListener('pointermove', function (ev) {
        var hit = nearest(ev);
        dots.forEach(function (dd) { dd.node.setAttribute('r', hit && dd === hit.d ? 7.5 : 5.5); dd.node.setAttribute('fill-opacity', hit && dd !== hit.d ? 0.3 : 0.88); });
        if (!hit) { hideTip(); return; }
        var r = hit.d.r;
        showTip([
          { text: mytStamp(r.started) + ' MYT' },
          { text: r.host + ' · ' + dur(r.duration_s) + ' · ' + (STATUS[r.status] || [r.status])[0], colour: colourFor(r.host, r.platform) },
          { text: r.before + ' → ' + r.after + ' ' + r.unit + ' missing' + (r.scope_pct < 100 ? ' · ' + r.scope_pct + '% scope' : '') },
        ], hit.rect.left + window.scrollX + hit.d.cx / hit.k, hit.rect.top + window.scrollY + hit.d.cy / hit.k);
      });
      s.addEventListener('pointerleave', function () {
        hideTip();
        dots.forEach(function (dd) { dd.node.setAttribute('r', 5.5); dd.node.setAttribute('fill-opacity', 0.88); });
      });
    }

    // ---------------- severity chart
    function drawSeverity() {
      var box = $('sev-chart');
      box.replaceChildren();
      if (!done.length) { box.appendChild(el('p', 'empty', 'No completed host runs to chart.')); return; }
      var by = {};
      done.forEach(function (r) {
        var pl = by[r.platform] || (by[r.platform] = { runs: 0 });
        pl.runs += 1;
        SEVERITIES.forEach(function (sv) { pl[sv[1]] = (pl[sv[1]] || 0) + (r[sv[1]] || 0); });
      });
      Object.keys(by).sort().forEach(function (plat) {
        var pl = by[plat];
        var total = SEVERITIES.reduce(function (a, sv) { return a + pl[sv[1]]; }, 0);
        var row = el('div', 'sev-row');
        row.appendChild(el('span', 'sev-name', plat === 'rhel' ? 'RHEL 9' : 'Windows'));
        var stack = el('div', 'sev-stack');
        SEVERITIES.forEach(function (sv) {
          var v = pl[sv[1]];
          if (!total || !v) return;
          var share = 100 * v / total;
          var seg = el('div', 'sev-seg', share >= 9 ? nf.format(v) : '');
          seg.style.width = share.toFixed(2) + '%';
          seg.style.background = 'var(' + sv[2] + ')';
          seg.tabIndex = 0;
          var lines = [{ text: plat === 'rhel' ? 'RHEL 9' : 'Windows' }, { text: sv[0] + ': ' + nf.format(v) + ' (' + nf1.format(share) + '%)', colour: css(sv[2]) }];
          seg.setAttribute('aria-label', sv[0] + ' ' + v);
          function show() { var b = seg.getBoundingClientRect(); showTip(lines, b.left + window.scrollX + b.width / 2, b.top + window.scrollY); }
          seg.addEventListener('pointerenter', show); seg.addEventListener('focus', show);
          seg.addEventListener('pointerleave', hideTip); seg.addEventListener('blur', hideTip);
          stack.appendChild(seg);
        });
        row.appendChild(stack);
        row.appendChild(el('span', 'sev-tot', nf.format(total)));
        row.appendChild(el('span', 'sev-sub', pl.runs + ' completed host runs · ' + (plat === 'rhel' ? 'advisories (RHSA)' : 'KB updates')));
        box.appendChild(row);
      });
      var lg = $('sev-legend');
      lg.replaceChildren();
      SEVERITIES.forEach(function (sv) {
        var sp = el('span'); var i = el('i', 'sq'); i.style.background = 'var(' + sv[2] + ')';
        sp.appendChild(i); sp.appendChild(document.createTextNode(sv[0])); lg.appendChild(sp);
      });
    }

    state.redraw = drawDurations;
    drawDurations();
    drawSeverity();
    drawTable();
  }

  // ------------------------------------------------------------ cycles table (sort survives redraws)
  var table = $('cycle-table');
  function drawTable() {
    var cycles = (state.data && state.data.cycles) || [];
    if (!cycles.length) return;
    var key = state.sortKey, dir = state.sortDir;
    var rows = cycles.slice().sort(function (a, b) {
      var va = a[key], vb = b[key];
      if (Array.isArray(va)) { va = va.join(' '); vb = vb.join(' '); }
      if (typeof va === 'number') return (va - vb) * dir;
      return String(va).localeCompare(String(vb)) * dir;
    });
    var body = table.tBodies[0];
    body.replaceChildren();
    rows.forEach(function (c) {
      var tr = el('tr');
      tr.appendChild(el('td', null, mytStamp(c.started)));
      tr.appendChild(el('td', 'host-list', c.hosts.join(', ')));
      var td = el('td'); td.appendChild(el('span', 'chip ' + (RESULT_TONE[c.result] || 'muted'), c.result)); td.title = c.summary; tr.appendChild(td);
      tr.appendChild(el('td', 'num narrow-hide', c.scope_pct + '%'));
      tr.appendChild(el('td', 'num', nf.format(c.succeeded)));
      tr.appendChild(el('td', 'num', nf.format(c.attempted)));
      tr.appendChild(el('td', 'num', dur(c.duration_s)));
      body.appendChild(tr);
    });
    table.querySelectorAll('th').forEach(function (th) {
      var b = th.querySelector('button');
      if (b && b.dataset.key === key) th.setAttribute('aria-sort', dir === 1 ? 'ascending' : 'descending');
      else th.removeAttribute('aria-sort');
    });
  }
  table.querySelectorAll('th button').forEach(function (b) {
    b.addEventListener('click', function () {
      if (state.sortKey === b.dataset.key) state.sortDir = -state.sortDir;
      else { state.sortKey = b.dataset.key; state.sortDir = (state.sortKey === 'hosts' || state.sortKey === 'result') ? 1 : -1; }
      drawTable();
    });
  });

  // ------------------------------------------------------------ views and live updates
  var btnLive = $('view-live'), btnEval = $('view-evaluation');
  $('eval-range').textContent = evalRange();
  if (!EVAL) btnEval.disabled = true;

  function setView(view, automatic) {
    state.view = view;
    btnLive.setAttribute('aria-pressed', String(view === 'live'));
    btnEval.setAttribute('aria-pressed', String(view === 'evaluation'));
    if (!automatic) try {
      var url = new URL(window.location.href);
      if (view === 'evaluation') url.searchParams.set('view', 'evaluation'); else url.searchParams.delete('view');
      window.history.replaceState(null, '', url);
    } catch (e) { /* file:// or an old browser: the view still switches */ }
    if (view === 'evaluation') { if (EVAL) render(EVAL); return; }
    if (state.live) render(state.live);
    loadLive();
  }

  function loadLive() {
    return fetch(LIVE_URL + '?t=' + Date.now(), { cache: 'no-store' })
      .then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.text(); })
      .then(function (text) {
        var d = JSON.parse(text);
        if (!d || !Array.isArray(d.cycles)) throw new Error('unexpected live data');
        var changed = text !== state.liveText;
        if (changed) { state.live = d; state.liveText = text; }
        state.liveFailed = false;
        btnLive.title = '';
        if (state.view !== 'live') return;
        if (changed || state.data !== state.live) render(state.live); else drawStatus();
      })
      .catch(function () {
        state.liveFailed = true;
        btnLive.title = 'Live results are not available right now';
        if (state.view !== 'live') return;
        if (state.live) { drawStatus(); return; }          // keep the last good data on screen
        if (EVAL) {
          setView('evaluation', true);
          $('status-text').textContent += ' · live results are not published yet';
        } else {
          $('status-text').textContent = 'Live results are not available yet.';
        }
      });
  }

  btnLive.addEventListener('click', function () { if (state.view !== 'live') setView('live'); });
  btnEval.addEventListener('click', function () { if (state.view !== 'evaluation' && EVAL) setView('evaluation'); });

  // Re-check every minute while the live view is on screen, and as soon as the tab comes back.
  setInterval(function () {
    if (state.view !== 'live' || document.hidden) return;
    if (state.data) drawStatus();          // keeps "updated 3 min ago" honest between loads
    loadLive();
  }, POLL_MS);
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden && state.view === 'live') loadLive();
  });

  var wanted = new URLSearchParams(window.location.search).get('view') === 'evaluation' && EVAL ? 'evaluation' : 'live';
  var fromDisk = window.location.protocol === 'file:';
  if (wanted === 'live' && fromDisk && EVAL) wanted = 'evaluation'; // no live data when opened from disk
  setView(wanted, fromDisk);

  // ------------------------------------------------------------ keep charts in step with size and theme
  var lastW = $('dur-chart').clientWidth;
  if (window.ResizeObserver) {
    new ResizeObserver(function () {
      var w = $('dur-chart').clientWidth;
      if (Math.abs(w - lastW) > 4 && state.redraw) { lastW = w; hideTip(); state.redraw(); }
    }).observe($('dur-chart'));
  }
  var mq = window.matchMedia('(prefers-color-scheme: dark)');
  if (mq.addEventListener) mq.addEventListener('change', function () { if (state.redraw) state.redraw(); });
})();
