/* Mirror of the CloudWatch dashboard PatchManagement-Dashboard (dashboard/dashboard-v3.json).

   Data (same format from every source, see lambda/site_publisher.py):
     data/live.json      the last 2 weeks, written by serverless-patch-site-publisher when a cycle
                         starts or ends; re-checked every 60 s while the page is open
     window.PATCH_DATA   fallback built from evidence/ (no cost, no orchestration counts), shown when
                         the page is opened from disk or live.json is not published yet

   The three coloured panels are the HTML of summary_widget.py itself (shown in a shadow root).
   Every other widget is redrawn here from the same records, following its Logs Insights query or
   metric expression in dashboard-v3.json, with the CloudWatch chart palette. */
(function () {
  'use strict';

  var FALLBACK = window.PATCH_DATA && Array.isArray(window.PATCH_DATA.records) ? window.PATCH_DATA : null;
  var POLL_MS = 60000;
  var LIMIT_S = 900;
  // The CloudWatch chart palette and status colours come from the tokens in dashboard.css
  // (--cw-c1 to --cw-c10, --cw-green and so on); readColours() fills them before each render.
  var PALETTE = [], GREEN, RED, ORANGE, GREY;
  var PATCHED = { patched: 1, patched_partial: 1 };
  var SVG_NS = 'http://www.w3.org/2000/svg';
  var LIMIT_LABEL = 'Lambda 15-min limit (900 s): installs run on the host';

  // The dashboard layout, as in dashboard/dashboard-v3.json (x, y, width, height on a 24-column grid).
  var LAYOUT = [
    { id: 'kpi', x: 0, y: 0, w: 24, h: 4, type: 'custom', title: 'Patch Summary' },
    { id: 'hosts', x: 0, y: 4, w: 16, h: 7, type: 'custom', title: 'Host Status: latest patch run per host' },
    { id: 'severity', x: 16, y: 4, w: 8, h: 7, type: 'custom', title: 'Updates Fixed by Severity (verified by rescan)' },
    { id: 'hostGauge', x: 0, y: 11, w: 5, h: 6, title: 'Selected host {host}: success rate' },
    { id: 'hostTime', x: 5, y: 11, w: 9, h: 6, title: 'Selected host {host}: deployment time per run (s)', scale: true },
    { id: 'hostHistory', x: 14, y: 11, w: 10, h: 6, title: 'Selected host {host}: run history', table: true },
    { id: 'barHost', x: 0, y: 17, w: 8, h: 7, title: 'Patch Deployment Time per Host (Experiment 1, longest run in range, s)', scale: true },
    { id: 'timeAll', x: 8, y: 17, w: 16, h: 7, title: 'Deployment Time per Run (each point is one host in one patch run, s)', scale: true },
    { id: 'pie', x: 0, y: 24, w: 6, h: 7, title: 'Host Outcomes (patch runs)' },
    { id: 'exp3', x: 6, y: 24, w: 9, h: 7, title: 'Scalability Across Multiple Hosts (Experiment 3, RHEL full-scope runs, x = hosts in run)' },
    { id: 'orch', x: 15, y: 24, w: 9, h: 7, title: 'Orchestration Layer (Step Functions, Lambda, SNS)' },
    { id: 'perDay', x: 0, y: 31, w: 12, h: 6, title: 'Step Functions Executions per Day' },
    { id: 'platform', x: 12, y: 31, w: 12, h: 6, title: 'Success Rate by Platform (from CloudWatch Logs)', table: true },
    { id: 'costSv', x: 0, y: 37, w: 6, h: 6, title: 'Estimated Operational Cost (Experiment 4, USD)' },
    { id: 'costTable', x: 6, y: 37, w: 18, h: 6, title: 'Cost per Cycle (list price before free tier)', table: true },
    { id: 'latest', x: 0, y: 43, w: 24, h: 7, title: 'Latest Host Results (scan and patch runs)', table: true },
    { id: 'footer', x: 0, y: 50, w: 24, h: 2, type: 'text', plain: true },
  ];

  var state = {
    view: null, data: null, host: null,
    live: null, liveText: '',
    redrawTimer: null,
  };

  // ------------------------------------------------------------ helpers
  function $(id) { return document.getElementById(id); }
  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }
  function svg(tag, attrs, text) {
    var n = document.createElementNS(SVG_NS, tag);
    for (var k in attrs) n.setAttribute(k, attrs[k]);
    if (text != null) n.textContent = text;
    return n;
  }
  function css(name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); }
  function isDark() {
    var t = document.documentElement.getAttribute('data-theme');
    if (t) return t === 'dark';
    return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
  }
  function pad(n, w) { return String(n).padStart(w || 2, '0'); }
  function tsMs(ts) { return Date.parse(String(ts).replace(' ', 'T') + (/[zZ+]/.test(String(ts).slice(10)) ? '' : 'Z')); }
  function myt(ms) { return new Date(ms + 8 * 3600e3); }                  // read with UTC getters
  function stamp(ts) {                                                    // Logs Insights format, in MYT
    var ms = tsMs(ts); if (isNaN(ms)) return '';
    var d = myt(ms);
    return d.getUTCFullYear() + '-' + pad(d.getUTCMonth() + 1) + '-' + pad(d.getUTCDate()) + ' ' +
      pad(d.getUTCHours()) + ':' + pad(d.getUTCMinutes()) + ':' + pad(d.getUTCSeconds()) + '.' + pad(d.getUTCMilliseconds(), 3);
  }
  function clock(iso) { var d = myt(Date.parse(iso)); return pad(d.getUTCHours()) + ':' + pad(d.getUTCMinutes()); }
  function ago(iso) {
    var s = Math.max(0, (Date.now() - Date.parse(iso)) / 1000);
    if (s < 90) return 'just now';
    if (s < 3600) return Math.round(s / 60) + ' min ago';
    if (s < 48 * 3600) return Math.round(s / 3600) + ' h ago';
    return Math.round(s / 86400) + ' days ago';
  }
  function num(v) { return typeof v === 'number' && isFinite(v) ? v : 0; }
  function short(h) { return String(h || '').replace('serverless-patch-', ''); }
  function cell(v) {                                                      // a Logs Insights table value
    if (v == null || v === '') return '';
    if (typeof v === 'number') return Number.isInteger(v) ? String(v) : String(Math.round(v * 10000) / 10000);
    return String(v);
  }
  function single(v) {                                                    // a single-value widget number
    if (v == null || !isFinite(v)) return '–';
    if (Number.isInteger(v)) return v.toLocaleString('en');
    if (Math.abs(v) < 1) return String(Number(v.toPrecision(3)));
    return v.toLocaleString('en', { maximumFractionDigits: 2 });
  }
  function niceMax(v) {
    if (v <= 0) return 1;
    var p = Math.pow(10, Math.floor(Math.log10(v))), m = v / p;
    return (m <= 1 ? 1 : m <= 2 ? 2 : m <= 2.5 ? 2.5 : m <= 5 ? 5 : 10) * p;
  }
  function ticks(max, n) { var out = [], step = max / n; for (var i = 0; i <= n; i++) out.push(Math.round(step * i * 1000) / 1000); return out; }

  // ------------------------------------------------------------ records (Logs Insights equivalents)
  function hostRecs(d) { return (d.records || []).filter(function (r) { return r.record === 'host'; }); }
  function cycleRecs(d) { return (d.records || []).filter(function (r) { return r.record === 'cycle'; }); }
  function emfHost(r) {   // records that produce the PatchesAttempted / PatchesSucceeded metrics
    return r.record === 'host' && r.mode === 'patch' && (PATCHED[r.status] || r.status === 'failed') && r.host && r.platform;
  }
  function hostSeconds(r) { return r.record === 'host' && r.mode === 'patch' && PATCHED[r.status] && r.host && r.platform; }
  function hostList(d) {
    var seen = {};
    hostRecs(d).forEach(function (r) { if (r.host && !seen[r.host]) seen[r.host] = r.platform || ''; });
    return Object.keys(seen).map(function (h) { return { host: h, platform: seen[h] }; })
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
    tip.style.left = Math.min(Math.max(8 + window.scrollX, x - w / 2), window.scrollX + document.documentElement.clientWidth - w - 8) + 'px';
    tip.style.top = (y - h - 12) + 'px';
  }
  function hideTip() { tip.hidden = true; }
  function tipAt(node, lines) {
    function show() { var b = node.getBoundingClientRect(); showTip(lines, b.left + window.scrollX + b.width / 2, b.top + window.scrollY); }
    node.addEventListener('pointerenter', show);
    node.addEventListener('pointerleave', hideTip);
  }

  // ------------------------------------------------------------ chart frame
  function frame(body, opts) {
    var wrap = el('div', 'cw-chart');
    body.appendChild(wrap);
    var legend = opts.legend ? el('div', 'cw-legend') : null;
    var foot = opts.footnote ? el('p', 'cw-foot', opts.footnote) : null;
    var W = Math.max(200, body.clientWidth - 32), H = Math.max(120, body.clientHeight - 16 - (legend ? 26 : 0) - (foot ? 20 : 0));
    var s = svg('svg', { viewBox: '0 0 ' + W + ' ' + H, width: W, height: H, role: 'img', 'aria-label': opts.label || '' });
    wrap.appendChild(s);
    if (legend) wrap.appendChild(legend);
    if (foot) wrap.appendChild(foot);
    return { svg: s, W: W, H: H, legend: legend };
  }
  // A y scale: linear from 0, or log10 between powers of ten (for durations where one long
  // run would otherwise flatten every other point against the axis).
  function yScale(values, floor, log) {
    var top = Math.max.apply(null, [floor].concat(values));
    if (!log) { var max = niceMax(top * 1.05); return { log: false, lo: 0, hi: max, ticks: ticks(max, 4) }; }
    var pos = values.filter(function (v) { return v > 0; });
    var lo = Math.pow(10, Math.floor(Math.log10(Math.max(1, Math.min.apply(null, pos.length ? pos : [10])))));
    var hi = Math.pow(10, Math.ceil(Math.log10(top * 1.05)));
    var tv = []; for (var t = lo; t <= hi; t *= 10) tv.push(t);
    return { log: true, lo: lo, hi: hi, ticks: tv };
  }
  function yAxis(f, sc, left, top, bottom, label) {
    var H = f.H, span = H - bottom - top;
    function y(v) {
      if (!sc.log) return H - bottom - v / sc.hi * span;
      var lv = Math.log10(Math.max(v, sc.lo));
      return H - bottom - (lv - Math.log10(sc.lo)) / (Math.log10(sc.hi) - Math.log10(sc.lo)) * span;
    }
    y.base = sc.log ? sc.lo : 0;
    sc.ticks.forEach(function (t) {
      f.svg.appendChild(svg('line', { x1: left, x2: f.W - 6, y1: y(t), y2: y(t), stroke: css('--cw-grid'), 'stroke-width': 1 }));
      f.svg.appendChild(svg('text', { x: left - 6, y: y(t), dy: '0.32em', 'text-anchor': 'end' }, t.toLocaleString('en')));
    });
    if (label) {
      var mid = (top + H - bottom) / 2;
      f.svg.appendChild(svg('text', { x: 10, y: mid, transform: 'rotate(-90 10 ' + mid + ')', 'text-anchor': 'middle' }, label + (sc.log ? ' (log scale)' : '')));
    }
    return y;
  }
  function leftMargin(f, sc, label) {
    var probe = svg('text', {}, sc.ticks[sc.ticks.length - 1].toLocaleString('en')); f.svg.appendChild(probe);
    var w = probe.getComputedTextLength(); f.svg.removeChild(probe);
    return Math.ceil(w) + 12 + (label ? 16 : 0);
  }
  function annotation(f, y, x0, x1, value, colour, text) {
    f.svg.appendChild(svg('line', { x1: x0, x2: x1, y1: y(value), y2: y(value), stroke: colour, 'stroke-width': 1.5 }));
    if (text) {
      // Under the line, clear of the 1,000 gridline just above it on the log scale; a halo in the
      // panel colour keeps it readable where it crosses a bar or a line.
      var t = svg('text', { x: x0 + 4, y: y(value) + 13, 'paint-order': 'stroke', 'stroke-width': 4, 'stroke-linejoin': 'round' },
        (x1 - x0) < 380 ? 'Lambda limit 900 s' : text);
      t.style.fill = css('--cw-red-text') || colour; t.style.stroke = css('--cw-panel'); f.svg.appendChild(t);
    }
  }
  function legendItem(f, colour, text, square) {
    var s = el('span'); var i = el('i', square ? 'sq' : null); i.style.background = colour;
    s.appendChild(i); s.appendChild(document.createTextNode(text)); f.legend.appendChild(s);
  }
  function timeAxis(f, start, end, left, right, bottom) {
    function x(ms) { return left + (ms - start) / (end - start) * (right - left); }
    var span = end - start, day = 864e5;
    var stepDays = Math.max(1, Math.ceil((span / day) / Math.max(1, Math.floor((right - left) / 56))));
    var d0 = myt(start); var first = Date.UTC(d0.getUTCFullYear(), d0.getUTCMonth(), d0.getUTCDate()) - 8 * 3600e3;
    if (first < start) first += day;
    for (var t = first; t <= end; t += stepDays * day) {
      var d = myt(t);
      f.svg.appendChild(svg('line', { x1: x(t), x2: x(t), y1: f.H - bottom, y2: f.H - bottom + 4, stroke: css('--cw-axis') }));
      f.svg.appendChild(svg('text', { x: x(t), y: f.H - bottom + 16, 'text-anchor': 'middle' }, pad(d.getUTCMonth() + 1) + '/' + pad(d.getUTCDate())));
    }
    f.svg.appendChild(svg('line', { x1: left, x2: right, y1: f.H - bottom, y2: f.H - bottom, stroke: css('--cw-axis') }));
    return x;
  }

  // ------------------------------------------------------------ widget bodies
  function note(body, text) { body.appendChild(el('p', 'cw-note', text)); }

  function lineChart(body, series, opts) {      // series: [{name, colour, points:[{t, v, r}]}]
    var all = []; series.forEach(function (s) { all = all.concat(s.points); });
    if (!all.length) { note(body, 'No data available.'); return; }
    var f = frame(body, { legend: opts.legend, label: opts.label });
    var sc = yScale(all.map(function (p) { return p.v; }), LIMIT_S * 1.08, opts.log);
    var left = leftMargin(f, sc, opts.yLabel), top = 14, bottom = 22, right = f.W - 6;
    var y = yAxis(f, sc, left, top, bottom, opts.yLabel);
    var x = timeAxis(f, opts.start, opts.end, left, right, bottom);
    annotation(f, y, left, right, LIMIT_S, RED, LIMIT_LABEL);
    var dots = [];
    series.forEach(function (s) {
      var pts = s.points.slice().sort(function (a, b) { return a.t - b.t; });
      // Runs are days apart, so the line between them is not a measurement: keep it faint.
      if (pts.length > 1) f.svg.appendChild(svg('polyline', { points: pts.map(function (p) { return x(p.t) + ',' + y(p.v); }).join(' '), fill: 'none', stroke: s.colour, 'stroke-width': 1.25, 'stroke-opacity': 0.35, 'stroke-linejoin': 'round' }));
      pts.forEach(function (p) {
        var c = svg('circle', { cx: x(p.t), cy: y(p.v), r: 3.5, fill: s.colour });
        f.svg.appendChild(c); dots.push({ c: c, p: p, s: s, cx: x(p.t), cy: y(p.v) });
      });
      if (f.legend) legendItem(f, s.colour, s.name);
    });
    hover(f, dots, function (d) {
      return [{ text: stamp(d.p.ts) }, { text: d.s.name + ': ' + d.p.v.toLocaleString('en') + ' s', colour: d.s.colour }];
    });
  }
  function hover(f, dots, lines) {
    f.svg.addEventListener('pointermove', function (ev) {
      var b = f.svg.getBoundingClientRect(), k = f.W / b.width;
      var px = (ev.clientX - b.left) * k, py = (ev.clientY - b.top) * k, best = null, bd = 900 * k * k;
      dots.forEach(function (d) { var q = (d.cx - px) * (d.cx - px) + (d.cy - py) * (d.cy - py); if (q < bd) { bd = q; best = d; } });
      dots.forEach(function (d) { d.c.setAttribute('r', d === best ? 5.5 : 3.5); });
      if (!best) { hideTip(); return; }
      showTip(lines(best), b.left + window.scrollX + best.cx / k, b.top + window.scrollY + best.cy / k);
    });
    f.svg.addEventListener('pointerleave', function () { hideTip(); dots.forEach(function (d) { d.c.setAttribute('r', 3.5); }); });
  }

  function barChart(body, groups, seriesNames, opts) {  // groups: [{label, values:[...]}]
    if (!groups.length) { note(body, 'No data available.'); return; }
    var f = frame(body, { legend: true, label: opts.label, footnote: opts.footnote });
    var vals = []; groups.forEach(function (g) { vals = vals.concat(g.values); });
    var sc = yScale(vals, opts.limit ? LIMIT_S * 1.08 : 0, opts.log);
    var left = leftMargin(f, sc, opts.yLabel), top = 14, bottom = opts.xLabels ? 22 : 8, right = f.W - 6;
    var y = yAxis(f, sc, left, top, bottom, opts.yLabel);
    var gw = (right - left) / groups.length, n = seriesNames.length;
    var bw = Math.min(56, (gw * 0.7) / n);
    groups.forEach(function (g, gi) {
      var gx = left + gi * gw + (gw - bw * n) / 2;
      g.values.forEach(function (v, si) {
        var colour = opts.colours ? opts.colours[gi] : PALETTE[si % PALETTE.length];
        var r = svg('rect', { x: gx + si * bw, y: y(v), width: Math.max(1, bw - 2), height: Math.max(0, y(y.base) - y(v)), fill: colour });
        f.svg.appendChild(r);
        tipAt(r, [{ text: opts.xLabels ? opts.xLabels(g) : g.label }, { text: seriesNames[si] + ': ' + cell(v), colour: colour }]);
      });
      if (opts.xLabels) f.svg.appendChild(svg('text', { x: left + gi * gw + gw / 2, y: f.H - bottom + 16, 'text-anchor': 'middle' }, opts.xLabels(g)));
    });
    f.svg.appendChild(svg('line', { x1: left, x2: right, y1: y(y.base), y2: y(y.base), stroke: css('--cw-axis') }));
    if (opts.limit) annotation(f, y, left, right, LIMIT_S, RED, LIMIT_LABEL);
    if (opts.colours) groups.forEach(function (g, gi) { legendItem(f, opts.colours[gi], g.label, true); });
    else seriesNames.forEach(function (n2, si) { legendItem(f, PALETTE[si % PALETTE.length], n2, true); });
  }

  function table(body, cols, rows) {
    if (!rows.length) { note(body, 'No data found.'); return; }
    var t = el('table', 'cw-table'), thead = el('thead'), hr = el('tr');
    cols.forEach(function (c) { hr.appendChild(el('th', null, c)); });
    thead.appendChild(hr); t.appendChild(thead);
    var tb = el('tbody');
    rows.forEach(function (r) {
      var tr = el('tr');
      r.forEach(function (v) { tr.appendChild(el('td', typeof v === 'number' ? 'n' : null, cell(v))); });
      tb.appendChild(tr);
    });
    t.appendChild(tb); body.appendChild(t);
  }

  var W = {};
  W.footer = function (body) {
    var md = el('div', 'cw-md');
    var p = el('p'); p.appendChild(el('strong', null, 'Control plane only.'));
    p.appendChild(document.createTextNode(' Every value comes from Step Functions, Lambda, SNS and the serverless-patch-metrics log records. ' +
      'The coloured panels at the top are CloudWatch custom widgets drawn by the read-only Lambda serverless-patch-summary-widget. ' +
      'No monitoring agent is installed on any host. Success counts only updates confirmed fixed by the post-install rescan. ' +
      'Cost is a list-price estimate from the execution history, before the free tier. Microsoft Defender updates are excluded from the Windows counts by design.'));
    md.appendChild(p); body.appendChild(md);
  };
  function custom(name) {
    return function (body) {
      var panels = (state.data.panels || {})[isDark() ? 'dark' : 'light'] || {};
      if (!panels[name]) { note(body, 'No data available.'); return; }
      var host = el('div', 'cw-custom');
      body.appendChild(host);
      var root = host.attachShadow ? host.attachShadow({ mode: 'open' }) : host;
      root.innerHTML = panels[name];       // generated by summary_widget.py; every value in it is HTML-escaped
    };
  }
  W.kpi = custom('kpi'); W.hosts = custom('hosts'); W.severity = custom('severity');

  W.hostGauge = function (body) {
    var rows = hostRecs(state.data).filter(function (r) { return emfHost(r) && r.host === state.host; });
    var att = rows.reduce(function (a, r) { return a + num(r.attempted); }, 0);
    var ok = rows.reduce(function (a, r) { return a + num(r.succeeded); }, 0);
    if (!att) { note(body, 'No data available.'); return; }
    var pct = 100 * ok / att;
    var f = frame(body, { legend: true, label: 'Success rate gauge' });
    var r = Math.min(f.W / 2 - 16, f.H - 34, 120), cx = f.W / 2, cy = Math.min(f.H - 22, r + 40);
    function pt(v, rad) { var a = Math.PI * (1 - v / 100); return [cx + rad * Math.cos(a), cy - rad * Math.sin(a)]; }
    function arc(v0, v1, rad, colour, w) {
      var a = pt(v0, rad), b = pt(v1, rad);
      f.svg.appendChild(svg('path', { d: 'M' + a[0] + ' ' + a[1] + ' A' + rad + ' ' + rad + ' 0 0 1 ' + b[0] + ' ' + b[1], fill: 'none', stroke: colour, 'stroke-width': w }));
    }
    arc(0, 100, r - 10, css('--cw-grid'), 18);
    arc(0, Math.min(100, pct), r - 10, GREEN, 18);
    arc(0, 80, r + 3, RED, 4); arc(80, 90, r + 3, ORANGE, 4); arc(90, 100, r + 3, GREEN, 4);
    var v = svg('text', { x: cx, y: cy - 8, 'text-anchor': 'middle' }, (Math.round(pct * 100) / 100).toLocaleString('en') + '%');
    v.style.cssText = 'font-size:' + Math.max(18, Math.min(34, r / 3)) + 'px;fill:var(--cw-text)'; f.svg.appendChild(v);
    f.svg.appendChild(svg('text', { x: cx - r + 10, y: cy + 16, 'text-anchor': 'middle' }, '0'));
    f.svg.appendChild(svg('text', { x: cx + r - 10, y: cy + 16, 'text-anchor': 'middle' }, '100'));
    legendItem(f, GREEN, 'Verified / attempted (%)');
  };
  // Deployment-time charts share one Log scale switch. Left alone, it turns on when the longest
  // run is over 4x the median, so one long Windows run does not flatten every RHEL run.
  function useLog() {
    if (state.log != null) return state.log;
    var v = hostRecs(state.data).filter(hostSeconds).map(function (r) { return num(r.duration_s); }).sort(function (a, b) { return a - b; });
    if (v.length < 3) return false;
    return v[v.length - 1] > 4 * v[Math.floor(v.length / 2)];
  }
  W.hostTime = function (body) {
    var pts = hostRecs(state.data).filter(function (r) { return hostSeconds(r) && r.host === state.host; })
      .map(function (r) { return { t: tsMs(r._ts), v: num(r.duration_s), ts: r._ts }; });
    lineChart(body, [{ name: 'Deployment time (s)', colour: GREY, points: pts }],
      { log: useLog(), start: Date.parse(state.data.range.start), end: Date.parse(state.data.range.end), label: 'Deployment time per run' });
  };
  var HIST_COLS = ['@timestamp', 'mode', 'status', 'unit', 'before', 'after', 'succeeded', 'attempted', 'duration_s', 'rebooted', 'healthy', 'failed_at'];
  W.hostHistory = function (body) {
    var rows = hostRecs(state.data).filter(function (r) { return r.host === state.host; }).slice(0, 20);
    table(body, HIST_COLS, rows.map(function (r) { return HIST_COLS.map(function (c) { return c === '@timestamp' ? stamp(r._ts) : r[c]; }); }));
  };
  function seriesByHost() {
    var by = {};
    hostRecs(state.data).filter(hostSeconds).forEach(function (r) {
      (by[r.host] = by[r.host] || []).push({ t: tsMs(r._ts), v: num(r.duration_s), ts: r._ts });
    });
    return Object.keys(by).sort().map(function (h, i) { return { name: h, colour: PALETTE[i % PALETTE.length], points: by[h] }; });
  }
  W.barHost = function (body) {
    var s = seriesByHost();
    barChart(body, s.map(function (x) { return { label: x.name, values: [Math.max.apply(null, x.points.map(function (p) { return p.v; }))] }; }),
      ['Longest run (s)'], { log: useLog(), limit: true, yLabel: 'seconds', colours: s.map(function (x) { return x.colour; }), label: 'Longest deployment per host' });
  };
  W.timeAll = function (body) {
    lineChart(body, seriesByHost(), { log: useLog(), legend: true, yLabel: 'seconds', start: Date.parse(state.data.range.start), end: Date.parse(state.data.range.end), label: 'Deployment time per run' });
  };
  W.pie = function (body) {
    var counts = {};
    hostRecs(state.data).filter(function (r) { return r.mode === 'patch'; }).forEach(function (r) { counts[r.status] = (counts[r.status] || 0) + 1; });
    var keys = Object.keys(counts).sort(function (a, b) { return counts[b] - counts[a]; });
    if (!keys.length) { note(body, 'No data found.'); return; }
    var f = frame(body, { legend: true, label: 'Host outcomes' });
    var total = keys.reduce(function (a, k) { return a + counts[k]; }, 0);
    var cx = f.W / 2, cy = f.H / 2, r = Math.min(f.W, f.H) / 2 - 6, a0 = -Math.PI / 2;
    keys.forEach(function (k, i) {
      var colour = PALETTE[i % PALETTE.length], a1 = a0 + 2 * Math.PI * counts[k] / total;
      var node = keys.length === 1 ? svg('circle', { cx: cx, cy: cy, r: r, fill: colour })
        : svg('path', { d: 'M' + cx + ' ' + cy + ' L' + (cx + r * Math.cos(a0)) + ' ' + (cy + r * Math.sin(a0)) + ' A' + r + ' ' + r + ' 0 ' + (a1 - a0 > Math.PI ? 1 : 0) + ' 1 ' + (cx + r * Math.cos(a1)) + ' ' + (cy + r * Math.sin(a1)) + ' Z', fill: colour, stroke: css('--cw-panel'), 'stroke-width': 1 });
      f.svg.appendChild(node);
      tipAt(node, [{ text: 'host_runs' }, { text: k + ': ' + counts[k] + ' (' + Math.round(1000 * counts[k] / total) / 10 + '%)', colour: colour }]);
      legendItem(f, colour, k + ' (' + counts[k] + ')', true);
      a0 = a1;
    });
  };
  W.exp3 = function (body) {
    var runs = {};
    hostRecs(state.data).filter(function (r) { return r.mode === 'patch' && num(r.percent) === 100 && r.platform === 'rhel' && /^patched/.test(r.status || ''); })
      .forEach(function (r) { (runs[r.run_id] = runs[r.run_id] || []).push(num(r.duration_s)); });
    var byN = {};
    Object.keys(runs).forEach(function (id) {
      var d = runs[id], n = d.length;
      (byN[n] = byN[n] || []).push({ run_s: Math.max.apply(null, d), host_s: d.reduce(function (a, b) { return a + b; }, 0) / n });
    });
    var groups = Object.keys(byN).map(Number).sort(function (a, b) { return a - b; }).map(function (n) {
      var g = byN[n], avg = function (k) { return g.reduce(function (a, x) { return a + x[k]; }, 0) / g.length; };
      return { label: String(n), values: [avg('run_s'), avg('host_s')] };
    });
    barChart(body, groups, ['total_workflow_s', 'per_host_s'], {
      xLabels: function (g) { return 'hosts_in_run ' + g.label; }, label: 'Scalability',
      footnote: groups.length === 1 ? 'Only ' + groups[0].label + '-host runs in this range, so there is no host count to compare yet.' : null,
    });
  };
  W.orch = function (body) {
    var m = state.data.metrics;
    if (!m) { note(body, 'These Step Functions, Lambda and SNS counts come from CloudWatch metrics, so they appear on the published site only.'); return; }
    var sv = el('div', 'cw-sv');
    [['Executions', m.executions], ['Succeeded', m.succeeded], ['Failed', m.failed],
      ['Lambda invocations', m.lambda_invocations], ['Lambda errors (incl. retried)', m.lambda_errors], ['Emails delivered', m.emails]]
      .forEach(function (x, i) {
        var d = el('div'); d.appendChild(el('div', 'l', x[0]));
        var v = el('div', 'v', single(x[1]));
        if (i === 1) v.style.color = GREEN; if (i === 2) v.style.color = RED;
        d.appendChild(v); sv.appendChild(d);
      });
    body.appendChild(sv);
  };
  W.perDay = function (body) {
    var m = state.data.metrics;
    if (!m) { note(body, 'Comes from CloudWatch metrics; appears on the published site only.'); return; }
    var days = m.per_day || [];
    if (!days.length) { note(body, 'No data available.'); return; }
    var f = frame(body, { legend: true, label: 'Executions per day' });
    var sc = yScale(days.map(function (d) { return d.succeeded + d.failed; }), 1, false);
    var left = leftMargin(f, sc), top = 10, bottom = 22, right = f.W - 6;
    var y = yAxis(f, sc, left, top, bottom);
    var x = timeAxis(f, Date.parse(state.data.range.start), Date.parse(state.data.range.end), left, right, bottom);
    var pts = days.map(function (d) { return { t: Date.parse(d.day + 'T00:00:00Z'), s: d.succeeded, f: d.failed, day: d.day }; });
    function area(lo, hi, colour) {
      var top1 = pts.map(function (p) { return x(p.t) + ',' + y(hi(p)); }), base = pts.slice().reverse().map(function (p) { return x(p.t) + ',' + y(lo(p)); });
      f.svg.appendChild(svg('polygon', { points: top1.concat(base).join(' '), fill: colour, 'fill-opacity': 0.35, stroke: 'none' }));
      f.svg.appendChild(svg('polyline', { points: top1.join(' '), fill: 'none', stroke: colour, 'stroke-width': 2 }));
    }
    area(function () { return 0; }, function (p) { return p.s; }, GREEN);
    area(function (p) { return p.s; }, function (p) { return p.s + p.f; }, RED);
    var dots = pts.map(function (p) {
      var c = svg('circle', { cx: x(p.t), cy: y(p.s + p.f), r: 3, fill: p.f ? RED : GREEN }); f.svg.appendChild(c);
      return { c: c, p: p, cx: x(p.t), cy: y(p.s + p.f) };
    });
    hover(f, dots, function (d) { return [{ text: d.p.day + ' (UTC)' }, { text: 'Succeeded: ' + d.p.s, colour: GREEN }, { text: 'Failed: ' + d.p.f, colour: RED }]; });
    legendItem(f, GREEN, 'Succeeded'); legendItem(f, RED, 'Failed');
  };
  W.platform = function (body) {
    var g = {};
    hostRecs(state.data).filter(function (r) { return r.mode === 'patch' && num(r.attempted) > 0; }).forEach(function (r) {
      var k = (r.platform || '') + '|' + (r.unit || '');
      var x = g[k] || (g[k] = { platform: r.platform, unit: r.unit, verified: 0, tried: 0, host_runs: 0 });
      x.verified += num(r.succeeded); x.tried += num(r.attempted); x.host_runs += 1;
    });
    var rows = Object.keys(g).sort().map(function (k) { var x = g[k]; return [x.platform, x.unit, x.verified, x.tried, 100 * x.verified / x.tried, x.host_runs]; });
    table(body, ['platform', 'unit', 'verified', 'tried', 'success_pct', 'host_runs'], rows);
  };
  W.costSv = function (body) {
    if (state.data.cost_known === false) { note(body, 'Cost is estimated in CloudWatch from each execution\'s history and is not in the evidence files; it appears on the published site.'); return; }
    var c = cycleRecs(state.data).filter(function (r) { return r.mode === 'patch' && num(r.hosts_total) > 0 && typeof r.cost_usd === 'number'; });
    var sum = c.reduce(function (a, r) { return a + r.cost_usd; }, 0);
    var sv = el('div', 'cw-sv');
    [['Per patch cycle (avg)', c.length ? sum / c.length : null], ['All cycles in range', c.length ? sum : null]].forEach(function (x) {
      var d = el('div'); d.appendChild(el('div', 'l', x[0])); d.appendChild(el('div', 'v', single(x[1]))); sv.appendChild(d);
    });
    body.appendChild(sv);
  };
  W.costTable = function (body) {
    var rows = cycleRecs(state.data).filter(function (r) { return r.mode === 'patch'; }).slice(0, 20);
    table(body, ['@timestamp', 'hosts', 'cycle_s', 'transitions', 'invokes', 'gb_s', 'sfn_usd', 'lambda_usd', 'total_usd'],
      rows.map(function (r) { return [stamp(r._ts), r.hosts_total, r.duration_s, r.transitions, r.lambda_invocations, r.lambda_gb_s, r.cost_sfn_usd, r.cost_lambda_usd, r.cost_usd]; }));
  };
  var LATEST_COLS = ['@timestamp', 'mode', 'host', 'status', 'unit', 'before', 'after', 'succeeded', 'attempted', 'duration_s', 'rebooted', 'healthy', 'failed_at'];
  W.latest = function (body) {
    table(body, LATEST_COLS, hostRecs(state.data).slice(0, 30).map(function (r) {
      return LATEST_COLS.map(function (c) { return c === '@timestamp' ? stamp(r._ts) : r[c]; });
    }));
  };

  // ------------------------------------------------------------ grid
  var grid = $('cw-grid');
  function title(spec) { return (spec.title || '').replace('{host}', state.host || '—'); }
  function readColours() {
    PALETTE = [];
    for (var i = 1; i <= 10; i++) PALETTE.push(css('--cw-c' + i));
    GREEN = css('--cw-green'); RED = css('--cw-red'); ORANGE = css('--cw-orange'); GREY = css('--cw-grey');
  }
  function render() {
    readColours();
    hideTip();
    grid.replaceChildren();
    if (!state.data) return;
    LAYOUT.forEach(function (spec) {
      var w = el('section', 'cw-w' + (spec.plain ? ' cw-plain' : '') + (spec.type === 'text' || spec.type === 'custom' ? ' cw-auto' : ''));
      w.style.setProperty('--x', spec.x + 1); w.style.setProperty('--y', spec.y + 1);
      w.style.setProperty('--w', spec.w); w.style.setProperty('--h', spec.h);
      w.dataset.widget = spec.id;
      if (spec.title) {
        var head = el('header', 'cw-wh'); head.appendChild(el('h3', null, title(spec))); w.appendChild(head);
        w.setAttribute('aria-label', title(spec));
        if (spec.scale) {
          var btn = el('button', 'cw-tool', 'Log scale');
          btn.type = 'button';
          btn.setAttribute('aria-pressed', String(useLog()));
          btn.title = 'Log scale shows short and long runs together. Applies to all deployment-time charts.';
          btn.addEventListener('click', function () { state.log = !useLog(); render(); });
          head.appendChild(btn);
        }
      }
      var body = el('div', 'cw-wb' + (spec.table ? ' cw-tbl' : '') + (spec.type || spec.table ? '' : ' cw-fill'));
      w.appendChild(body);
      grid.appendChild(w);
      try { W[spec.id](body); } catch (e) { body.replaceChildren(); note(body, 'This widget could not be drawn.'); if (window.console) console.error(spec.id, e); }
      if (spec.table) moreHint(w, body);
    });
  }

  // A table wider than its widget: fade the right edge and put a "More columns" button in the
  // widget's title row, so the hidden columns are not mistaken for missing ones.
  function moreHint(w, body) {
    var head = w.querySelector('.cw-wh');
    var fade = el('div', 'cw-fade'); fade.setAttribute('aria-hidden', 'true');
    var more = el('button', 'cw-tool cw-more', 'More columns'); more.type = 'button';
    more.title = 'Scroll the table sideways to show the rest of its columns';
    fade.style.top = (head ? head.offsetHeight : 0) + 'px';
    w.appendChild(fade);
    (head || w).appendChild(more);
    function update() {
      var wide = body.scrollWidth - body.clientWidth > 4;
      var rest = body.scrollWidth - body.clientWidth - body.scrollLeft > 4;
      more.hidden = !wide; more.disabled = !rest; fade.hidden = !rest;
    }
    more.addEventListener('click', function () { body.scrollBy({ left: Math.max(160, body.clientWidth * 0.6), behavior: 'smooth' }); });
    body.addEventListener('scroll', update, { passive: true });
    update();
  }

  // ------------------------------------------------------------ host selector (the dashboard's var_host)
  var select = $('cw-host');
  function fillHosts() {
    var hosts = hostList(state.data);
    var wanted = state.host || new URLSearchParams(window.location.search).get('host');
    if (!hosts.some(function (h) { return h.host === wanted; })) {
      var rhel = hosts.filter(function (h) { return h.platform === 'rhel'; })[0];
      wanted = (rhel || hosts[0] || {}).host || null;
    }
    state.host = wanted;
    select.replaceChildren();
    hosts.forEach(function (h) {
      var o = el('option', null, short(h.host) + ' (' + h.platform + ')'); o.value = h.host;
      if (h.host === wanted) o.selected = true; select.appendChild(o);
    });
    select.disabled = !hosts.length;
  }
  select.addEventListener('change', function () {
    state.host = select.value;
    setUrl();
    ['hostGauge', 'hostTime', 'hostHistory'].forEach(function (id) {
      var w = grid.querySelector('[data-widget="' + id + '"]'); if (!w) return;
      var spec = LAYOUT.filter(function (s) { return s.id === id; })[0];
      w.querySelector('h3').textContent = title(spec); w.setAttribute('aria-label', title(spec));
      var body = w.querySelector('.cw-wb'); body.replaceChildren(); W[id](body);
    });
  });

  // ------------------------------------------------------------ status line
  // One status sentence for a data set: {cls, text}. Used by the dashboard and by the line under
  // the page title, which always speaks for the live data when there is any.
  function statusFor(d, view) {
    if (!d) return { cls: '', text: 'No results to show yet.' };
    var st = d.status || {};
    if (view === 'live' && st.state === 'running') {
      var run = (st.mode === 'patch' ? 'Patch cycle' : 'Scan') + ' in progress, started ' + clock(st.since) + ' MYT (' + ago(st.since) + ')' +
        (st.count > 1 ? ', ' + st.count + ' runs' : '');
      return { cls: 'is-running', base: run, text: run + '. The dashboard updates when it finishes.' };
    }
    var latest = {};
    hostRecs(d).forEach(function (r) { if (r.mode === 'patch' && r.host && !latest[r.host]) latest[r.host] = r; });
    var hosts = Object.keys(latest), clean = hosts.filter(function (h) { return latest[h].after === 0; }).length;
    var base = hosts.length ? 'Latest patch run on each host: ' + clean + ' of ' + hosts.length + ' hosts with no missing updates' : 'No patch runs in this range';
    return {
      cls: hosts.length && clean === hosts.length ? 'is-ok' : 'is-warn',
      base: base,
      text: view === 'live' ? base + '. Updated ' + ago(d.generated_at) + '.'
        : base + '. ' + (d.source === 'evidence' ? 'From the evidence files (cost and orchestration counts only on the published site).' : 'From CloudWatch.'),
    };
  }
  function paint(line, text, s) {
    line.classList.remove('is-ok', 'is-warn', 'is-running');
    if (s.cls) line.classList.add(s.cls);
    text.textContent = s.text;
  }
  function drawStatus() {
    paint($('status-line'), $('status-text'), statusFor(state.data, state.view));
    var hero = state.live ? statusFor(state.live, 'live')
      : (state.data ? statusFor(state.data, state.view) : { cls: '', text: 'Checking the latest patch results…' });
    paint($('hero-status'), $('hero-status-text'), hero);
  }
  function show(d) {
    state.data = d;
    $('cw-range').textContent = d.source === 'evidence' ? 'Evidence files' : ((d.range && d.range.label) || '');
    $('source-note').textContent = d.source === 'evidence'
      ? 'This view is built from the cycle results in the repository\'s evidence/ folder.'
      : 'Data from CloudWatch (serverless-patch-metrics records and Step Functions, Lambda and SNS metrics), published by the serverless-patch-site-publisher Lambda.';
    fillHosts(); drawStatus(); render();
  }

  // ------------------------------------------------------------ loading
  // One view: the last 2 weeks from data/live.json, re-checked every POLL_MS. Opened from disk, or
  // before the publisher has run, the page shows the evidence fallback (data/patch-data.js) instead.
  var fromDisk = window.location.protocol === 'file:';

  function setUrl() {
    if (fromDisk) return;
    try {
      var url = new URL(window.location.href);
      url.searchParams.delete('view');
      if (state.host) url.searchParams.set('host', state.host); else url.searchParams.delete('host');
      window.history.replaceState(null, '', url);
    } catch (e) { /* the view still works */ }
  }
  function getJson(path) {
    return fetch(path + '?t=' + Date.now(), { cache: 'no-store' }).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.text();
    }).then(function (text) {
      var d = JSON.parse(text);
      if (!d || !Array.isArray(d.records)) throw new Error('unexpected data');
      return { d: d, text: text };
    });
  }
  function showEvidence(extra) {
    state.view = 'evidence';
    show(FALLBACK);
    if (extra) $('status-text').textContent += ' ' + extra;
  }
  function loadLive() {
    return getJson('data/live.json').then(function (x) {
      var changed = x.text !== state.liveText;
      if (changed) { state.live = x.d; state.liveText = x.text; }
      state.view = 'live';
      if (changed || state.data !== state.live) show(state.live); else drawStatus();
    }).catch(function () {
      if (state.live) { drawStatus(); return; }
      if (FALLBACK) { if (state.data !== FALLBACK) showEvidence('Live data is not published yet.'); }
      else $('status-text').textContent = 'Live data is not available yet.';
    });
  }

  if (!fromDisk) {
    setInterval(function () {
      if (document.hidden) return;
      if (state.data) drawStatus();
      loadLive();
    }, POLL_MS);
    document.addEventListener('visibilitychange', function () { if (!document.hidden) loadLive(); });
  }
  // Drop the old Evaluation view's ?view= from shared links; ?host= is kept for fillHosts().
  if (!fromDisk) try {
    var u = new URL(window.location.href);
    if (u.searchParams.has('view')) { u.searchParams.delete('view'); window.history.replaceState(null, '', u); }
  } catch (e) { /* the page still works */ }
  if (fromDisk) { if (FALLBACK) showEvidence(); else $('status-text').textContent = 'No results to show yet.'; }
  else loadLive();

  // Redraw charts when the layout width or the theme changes.
  var lastW = grid.clientWidth;
  function redrawSoon() { clearTimeout(state.redrawTimer); state.redrawTimer = setTimeout(render, 150); }
  if (window.ResizeObserver) new ResizeObserver(function () { if (Math.abs(grid.clientWidth - lastW) > 8) { lastW = grid.clientWidth; redrawSoon(); } }).observe(grid);
  var mq = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)');
  if (mq && mq.addEventListener) mq.addEventListener('change', redrawSoon);
  document.addEventListener('themechange', redrawSoon);   // the Auto / Light / Dark switch (assets/theme.js)
})();
