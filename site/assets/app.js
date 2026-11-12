/* Renders the patch results in window.PATCH_DATA (site/data/patch-data.js).
   Same counting rules as lambda/summary_widget.py: success = verified fixed / attempted,
   colours green from 90 %, amber from 80 %, red below (as the CloudWatch dashboard). */
(function () {
  'use strict';

  var DATA = window.PATCH_DATA;
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
  function dur(s) {
    s = Math.round(s);
    if (s < 60) return s + 's';
    var m = Math.floor(s / 60);
    return m + 'm ' + pad(s % 60) + 's';
  }
  function tone(pct) { return pct == null ? '' : pct >= RATE_GOOD ? 'tone-ok' : pct >= RATE_WARN ? 'tone-warn' : 'tone-bad'; }
  function isDone(r) { return r.status === 'patched' || r.status === 'patched_partial'; }

  if (!DATA || !DATA.host_runs || !DATA.cycles) {
    $('status-text').textContent = 'No results found. Run python site/build_site_data.py to create site/data/patch-data.js.';
    return;
  }

  var runs = DATA.host_runs;
  var cycles = DATA.cycles;
  var LIMIT = DATA.lambda_limit_s || 900;

  // ------------------------------------------------------------ summary (same as summary_widget.summarise)
  function rate(rows) {
    var ok = 0, att = 0, n = 0;
    rows.forEach(function (r) { ok += r.succeeded; att += r.attempted; if (r.attempted > 0) n += 1; });
    return { pct: att ? 100 * ok / att : null, ok: ok, att: att, runs: n };
  }
  var overall = rate(runs);
  var rhel = rate(runs.filter(function (r) { return r.platform === 'rhel'; }));
  var win = rate(runs.filter(function (r) { return r.platform === 'windows'; }));
  var latest = {};
  runs.forEach(function (r) { if (!latest[r.host] || r.started > latest[r.host].started) latest[r.host] = r; });
  var latestRows = Object.keys(latest).map(function (k) { return latest[k]; })
    .sort(function (a, b) { return (a.platform + a.host).localeCompare(b.platform + b.host); });
  var clean = latestRows.filter(function (r) { return r.after === 0; }).length;
  var failedHostRuns = cycles.reduce(function (a, c) { return a + c.failed; }, 0);
  var avgCycleMin = cycles.reduce(function (a, c) { return a + c.duration_s; }, 0) / cycles.length / 60;
  var longest = Math.max.apply(null, runs.filter(isDone).map(function (r) { return r.duration_s; }));
  var starts = cycles.map(function (c) { return c.started; }).sort();
  var firstDay = mytDay(starts[0]), lastDay = mytDay(starts[starts.length - 1]);

  // ------------------------------------------------------------ hero status line and window
  var status = $('status-line');
  status.classList.add(clean === latestRows.length ? 'is-ok' : 'is-warn');
  $('status-text').textContent = 'Latest run on each host: ' + clean + ' of ' + latestRows.length +
    ' hosts with no missing updates · results ' + firstDay + ' to ' + lastDay;
  $('window-note').textContent = cycles.length + ' patch cycles and ' + runs.length + ' host runs between ' + firstDay +
    ' and ' + lastDay + ' (MYT). Success counts only updates the post-install rescan confirmed as fixed.';
  if (DATA.commit) {
    $('foot-note').appendChild(document.createTextNode(' Data built from commit ' + DATA.commit + '.'));
  }

  // ------------------------------------------------------------ tiles
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
    t.appendChild(el('p', 'tile-sub', nf.format(r.ok) + ' of ' + nf.format(r.att) + ' ' + unit + ' verified · ' + r.runs + ' host runs'));
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
  tiles.appendChild(rateTile('Windows success rate', win, 'KB'));
  tiles.appendChild(plainTile('Patch cycles', String(cycles.length), '', failedHostRuns + ' failed host runs'));
  tiles.appendChild(plainTile('Average cycle time', nf1.format(avgCycleMin), 'min', 'From trigger to verified result'));
  tiles.appendChild(plainTile('Longest host run', nf1.format(longest / 60), 'min', 'Past the 15-min Lambda limit, so installs run on the host'));

  // ------------------------------------------------------------ host cards
  var hostColour = {};
  function colourFor(host, platform) {
    if (!hostColour[host]) {
      var used = Object.keys(hostColour).filter(function (h) { return hostColour[h].platform === platform; }).length;
      var name = platform === 'windows' ? '--win' : (used === 0 ? '--rhel' : '--rhel-2');
      hostColour[host] = { platform: platform, name: name };
    }
    return css(hostColour[host].name);
  }
  latestRows.forEach(function (r) { colourFor(r.host, r.platform); });

  var cards = $('host-cards');
  var barScale = Math.max.apply(null, [LIMIT * 2].concat(latestRows.map(function (r) { return r.duration_s * 1.1; })));
  latestRows.forEach(function (r) {
    var st = STATUS[r.status] || [String(r.status).toUpperCase(), 'muted'];
    var card = el('article', 'host');
    card.style.setProperty('--plat', 'var(' + hostColour[r.host].name + ')');
    var top = el('div', 'host-top');
    top.appendChild(el('span', 'host-name', r.host));
    top.appendChild(el('span', 'chip ' + st[1], st[0]));
    card.appendChild(top);
    card.appendChild(el('p', 'host-meta', (PLATFORM[r.platform] || r.platform) + ' · ' + r.workload + ' · ' + mytStamp(r.started) + ' MYT'));
    var big = el('p', 'host-big', r.status === 'failed' ? String(r.before) : r.before + ' → ' + r.after);
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

  // ------------------------------------------------------------ deployment time chart
  var done = runs.filter(isDone);
  var hosts = Array.from(new Set(done.map(function (r) { return r.host; }))).sort();
  var legend = $('dur-legend');
  hosts.forEach(function (h) {
    var s = el('span'); var i = el('i');
    if (hostColour[h].name === '--rhel-2') i.style.border = '2px solid var(--rhel-2)';
    else i.style.background = 'var(' + hostColour[h].name + ')';
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
    var W = Math.max(280, box.clientWidth), H = 270;
    var top = 10, bottom = 28;
    var yMax = niceMax(Math.max(LIMIT / 60 * 1.1, Math.max.apply(null, done.map(function (r) { return r.duration_s / 60; })) * 1.05));
    var tickStep = yMax <= 30 ? 5 : 10;
    var ticks = []; for (var t = 0; t <= yMax; t += tickStep) ticks.push(t);
    var s = svg('svg', { viewBox: '0 0 ' + W + ' ' + H, role: 'img', 'aria-label': 'Deployment time per host run, in minutes' });
    box.appendChild(s);
    // left margin from the widest tick label
    var probe = svg('text', {}); probe.textContent = yMax + ' min'; s.appendChild(probe);
    var left = Math.ceil(probe.getComputedTextLength()) + 12; s.removeChild(probe);
    var right = W - 10;
    var times = done.map(function (r) { return mytDate(r.started).getTime(); });
    var dayMs = 864e5;
    var t0 = Math.floor(Math.min.apply(null, times) / dayMs) * dayMs;
    var t1 = Math.ceil(Math.max.apply(null, times) / dayMs) * dayMs;
    function x(t) { return left + (t - t0) / (t1 - t0) * (right - left); }
    function y(m) { return H - bottom - m / yMax * (H - bottom - top); }

    ticks.forEach(function (tv) {
      s.appendChild(svg('line', { x1: left, x2: right, y1: y(tv), y2: y(tv), stroke: css('--grid') }));
      var lab = svg('text', { x: left - 8, y: y(tv), dy: '0.32em', 'text-anchor': 'end' });
      lab.textContent = tv + ' min'; s.appendChild(lab);
    });
    var days = (t1 - t0) / dayMs;
    var every = (right - left) / days < 52 ? 2 : 1;
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
      var ring = hostColour[r.host].name === '--rhel-2';
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
      dots.forEach(function (d) { var dd = (d.cx - px) * (d.cx - px) + (d.cy - py) * (d.cy - py); if (dd < bd) { bd = dd; best = d; } });
      return bd < 40 * 40 * k * k ? { d: best, k: k, rect: pt } : null;
    }
    s.addEventListener('pointermove', function (ev) {
      var hit = nearest(ev);
      dots.forEach(function (d) { d.node.setAttribute('r', hit && d === hit.d ? 7.5 : 5.5); d.node.setAttribute('fill-opacity', hit && d !== hit.d ? 0.3 : 0.88); });
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
      dots.forEach(function (d) { d.node.setAttribute('r', 5.5); d.node.setAttribute('fill-opacity', 0.88); });
    });
  }

  // ------------------------------------------------------------ severity chart
  function drawSeverity() {
    var box = $('sev-chart');
    box.replaceChildren();
    var by = {};
    runs.filter(isDone).forEach(function (r) {
      var p = by[r.platform] || (by[r.platform] = { runs: 0 });
      p.runs += 1;
      SEVERITIES.forEach(function (s) { p[s[1]] = (p[s[1]] || 0) + (r[s[1]] || 0); });
    });
    Object.keys(by).sort().forEach(function (plat) {
      var p = by[plat];
      var total = SEVERITIES.reduce(function (a, s) { return a + p[s[1]]; }, 0);
      var row = el('div', 'sev-row');
      row.appendChild(el('span', 'sev-name', plat === 'rhel' ? 'RHEL 9' : 'Windows'));
      var stack = el('div', 'sev-stack');
      SEVERITIES.forEach(function (s) {
        var v = p[s[1]];
        if (!total || !v) return;
        var share = 100 * v / total;
        var seg = el('div', 'sev-seg', share >= 9 ? nf.format(v) : '');
        seg.style.width = share.toFixed(2) + '%';
        seg.style.background = 'var(' + s[2] + ')';
        seg.tabIndex = 0;
        var lines = [{ text: plat === 'rhel' ? 'RHEL 9' : 'Windows' }, { text: s[0] + ': ' + nf.format(v) + ' (' + nf1.format(share) + '%)', colour: css(s[2]) }];
        seg.setAttribute('aria-label', s[0] + ' ' + v);
        function show() { var b = seg.getBoundingClientRect(); showTip(lines, b.left + window.scrollX + b.width / 2, b.top + window.scrollY); }
        seg.addEventListener('pointerenter', show); seg.addEventListener('focus', show);
        seg.addEventListener('pointerleave', hideTip); seg.addEventListener('blur', hideTip);
        stack.appendChild(seg);
      });
      row.appendChild(stack);
      row.appendChild(el('span', 'sev-tot', nf.format(total)));
      row.appendChild(el('span', 'sev-sub', p.runs + ' completed host runs · ' + (plat === 'rhel' ? 'advisories (RHSA)' : 'KB updates')));
      box.appendChild(row);
    });
    var lg = $('sev-legend');
    lg.replaceChildren();
    SEVERITIES.forEach(function (s) {
      var sp = el('span'); var i = el('i', 'sq'); i.style.background = 'var(' + s[2] + ')';
      sp.appendChild(i); sp.appendChild(document.createTextNode(s[0])); lg.appendChild(sp);
    });
  }

  // ------------------------------------------------------------ cycles table
  var sortKey = 'started', sortDir = -1;
  var table = $('cycle-table');
  function drawTable() {
    var rows = cycles.slice().sort(function (a, b) {
      var va = a[sortKey], vb = b[sortKey];
      if (Array.isArray(va)) { va = va.join(' '); vb = vb.join(' '); }
      if (typeof va === 'number') return (va - vb) * sortDir;
      return String(va).localeCompare(String(vb)) * sortDir;
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
      if (b && b.dataset.key === sortKey) th.setAttribute('aria-sort', sortDir === 1 ? 'ascending' : 'descending');
      else th.removeAttribute('aria-sort');
    });
  }
  table.querySelectorAll('th button').forEach(function (b) {
    b.addEventListener('click', function () {
      if (sortKey === b.dataset.key) sortDir = -sortDir;
      else { sortKey = b.dataset.key; sortDir = (sortKey === 'hosts' || sortKey === 'result') ? 1 : -1; }
      drawTable();
    });
  });

  // ------------------------------------------------------------ draw and keep in step with size and theme
  drawDurations();
  drawSeverity();
  drawTable();
  var lastW = $('dur-chart').clientWidth;
  if (window.ResizeObserver) {
    new ResizeObserver(function () {
      var w = $('dur-chart').clientWidth;
      if (Math.abs(w - lastW) > 4) { lastW = w; hideTip(); drawDurations(); }
    }).observe($('dur-chart'));
  }
  var mq = window.matchMedia('(prefers-color-scheme: dark)');
  if (mq.addEventListener) mq.addEventListener('change', function () { drawDurations(); });
})();
