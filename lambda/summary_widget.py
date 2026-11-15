"""serverless-patch-summary-widget: CloudWatch custom widget for PatchManagement-Dashboard.

CloudWatch calls this Lambda when the dashboard is opened or refreshed. It reads the
serverless-patch-metrics log records for the dashboard's time range (one Logs Insights query)
and returns HTML + CSS for one panel. No JavaScript (CloudWatch strips it). It never touches a host.

Widget parameters (properties.params in the dashboard):
  {"view": "kpi"}       coloured KPI tiles: success rate overall / RHEL / Windows, cycles, cycle time, cost
  {"view": "hosts"}     one status card per host: latest patch run, before -> after, duration vs 900 s limit
  {"view": "severity"}  updates fixed by severity, stacked per platform
"""
import html
import json
import os
import time
from datetime import datetime, timedelta, timezone

LOG_GROUP = os.environ.get("LOG_GROUP", "/aws/lambda/serverless-patch-metrics")
LAMBDA_LIMIT_S = 900
MYT = timezone(timedelta(hours=8))
QUERY = ("fields @timestamp, @message | filter record = 'host' or record = 'cycle' "
         "| sort @timestamp desc | limit 10000")

DOCS = """## serverless-patch summary widget
Draws a coloured panel from the `serverless-patch-metrics` log records for the dashboard time range.

| Param | Values |
|---|---|
| `view` | `kpi` (success rate, cycles, cycle time, cost), `hosts` (latest patch run per host), `severity` (updates fixed by severity) |

Example: `{"view": "hosts"}`. Read-only: one Logs Insights query per refresh, no access to any host.
"""

SEVERITIES = [("Critical", "fixed_critical", "#8b0000"), ("Important", "fixed_important", "#f97316"),
              ("Moderate", "fixed_moderate", "#eab308"), ("Low", "fixed_low", "#3b82f6"),
              ("Unrated", "fixed_unrated", "#9ca3af")]
STATUS = {"patched": ("PATCHED", "#16a34a"), "patched_partial": ("PARTIAL", "#f59e0b"),
          "failed": ("FAILED", "#dc2626"), "compliant": ("COMPLIANT", "#16a34a"),
          "scanned": ("SCANNED", "#2563eb"), "skipped": ("SKIPPED", "#6b7280")}
PLATFORM = {"rhel": ("RHEL 9", "#f97316"), "windows": ("Windows 2022", "#3b82f6")}


# ------------------------------------------------------------------ data
def fetch(start_ms, end_ms, client=None):
    if client is None:
        import boto3
        client = boto3.client("logs")
    qid = client.start_query(logGroupName=LOG_GROUP, startTime=int(start_ms // 1000),
                             endTime=int(end_ms // 1000), queryString=QUERY, limit=10000)["queryId"]
    deadline = time.time() + 40
    while True:
        r = client.get_query_results(queryId=qid)
        if r["status"] in ("Complete", "Failed", "Cancelled", "Timeout", "Unknown"):
            break
        if time.time() > deadline:
            try:
                client.stop_query(queryId=qid)
            except Exception:
                pass
            raise TimeoutError("Logs Insights query took longer than 40 s")
        time.sleep(0.4)
    if r["status"] != "Complete":
        raise RuntimeError(f"Logs Insights query {r['status']}")
    out = []
    for row in r.get("results", []):
        f = {c["field"]: c.get("value") for c in row}
        try:
            rec = json.loads(f.get("@message") or "")
        except ValueError:
            continue
        if isinstance(rec, dict) and rec.get("record") in ("host", "cycle"):
            rec["_ts"] = f.get("@timestamp")
            out.append(rec)
    return out


def num(v, default=0.0):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else default


def summarise(records):
    hosts = [r for r in records if r["record"] == "host" and r.get("mode") == "patch"]
    cycles = [r for r in records if r["record"] == "cycle" and r.get("mode") == "patch" and num(r.get("hosts_total")) > 0]

    def rate(rows):
        att = sum(num(r.get("attempted")) for r in rows)
        ok = sum(num(r.get("succeeded")) for r in rows)
        return (100.0 * ok / att if att else None), int(ok), int(att), sum(1 for r in rows if num(r.get("attempted")) > 0)

    latest = {}
    for r in hosts:  # records arrive newest first
        if r.get("host") and r["host"] not in latest:
            latest[r["host"]] = r
    sev = {}
    for r in hosts:
        if str(r.get("status", "")).startswith("patched") and any(k in r for _, k, _ in SEVERITIES):
            p = sev.setdefault(r.get("platform") or "other", {k: 0 for _, k, _ in SEVERITIES})
            for _, k, _ in SEVERITIES:
                p[k] += int(num(r.get(k)))
    return {
        "overall": rate(hosts),
        "rhel": rate([r for r in hosts if r.get("platform") == "rhel"]),
        "windows": rate([r for r in hosts if r.get("platform") == "windows"]),
        "cycles": len(cycles),
        "avg_cycle_s": (sum(num(c.get("duration_s")) for c in cycles) / len(cycles)) if cycles else None,
        "avg_cost": (sum(num(c.get("cost_usd")) for c in cycles) / len(cycles)) if cycles else None,
        "host_failures": int(sum(num(c.get("failed")) for c in cycles)),
        "latest": [latest[k] for k in sorted(latest, key=lambda h: (latest[h].get("platform") or "", h))],
        "severity": sev,
    }


# ------------------------------------------------------------------ formatting
def esc(v):
    return html.escape("" if v is None else str(v))


def dur(s):
    s = num(s, None)
    if s is None:
        return "-"
    s = int(round(s))
    if s < 60:
        return f"{s}s"
    m, s = divmod(s, 60)
    return f"{m}m {s:02d}s" if m < 60 else f"{m // 60}h {m % 60:02d}m"


def when(ts):
    try:
        t = datetime.strptime(ts[:19], "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc).astimezone(MYT)
        return t.strftime("%d %b %H:%M")
    except (TypeError, ValueError):
        return ""


def short(hostname):
    return (hostname or "").replace("serverless-patch-", "")


def rate_colour(pct):
    if pct is None:
        return ("#6b7280", "#4b5563")
    if pct >= 90:
        return ("#22c55e", "#15803d")
    if pct >= 80:
        return ("#f59e0b", "#b45309")
    return ("#ef4444", "#b91c1c")


def css(dark):
    fg, sub, card, border, track = (("#e5e7eb", "#9ca3af", "#1f2937", "#374151", "#374151") if dark
                                    else ("#111827", "#6b7280", "#ffffff", "#e5e7eb", "#e5e7eb"))
    return f"""<style>
.sp {{font-family: 'Amazon Ember', 'Helvetica Neue', Arial, sans-serif; color: {fg}; padding: 4px 2px;}}
.sp-tiles {{display: flex; gap: 10px; flex-wrap: wrap;}}
.sp-tile {{flex: 1 1 150px; min-width: 140px; border-radius: 10px; padding: 10px 14px; color: #fff;
  box-shadow: 0 2px 6px rgba(0,0,0,.18);}}
.sp-tile .l {{font-size: 13px; font-weight: 600; opacity: .95;}}
.sp-tile .v {{font-size: 38px; font-weight: 700; line-height: 1.1; margin: 4px 0 2px;}}
.sp-tile .v small {{font-size: 18px; font-weight: 600; margin-left: 2px;}}
.sp-tile .s {{font-size: 12px; opacity: .9;}}
.sp-cards {{display: flex; gap: 10px; flex-wrap: wrap;}}
.sp-card {{flex: 1 1 240px; min-width: 230px; background: {card}; border: 1px solid {border}; border-radius: 10px;
  padding: 10px 12px; border-top: 5px solid #6b7280;}}
.sp-card .top {{display: flex; align-items: center; justify-content: space-between; gap: 6px;}}
.sp-card .name {{font-size: 18px; font-weight: 700;}}
.sp-chip {{display: inline-block; border-radius: 999px; padding: 1px 8px; font-size: 11px; font-weight: 700; color: #fff;}}
.sp-card .big {{font-size: 26px; font-weight: 700; margin: 6px 0 0;}}
.sp-card .big .u {{font-size: 13px; color: {sub}; font-weight: 600; margin-left: 4px;}}
.sp-card .meta {{font-size: 12px; color: {sub}; margin-top: 2px;}}
.sp-bar {{position: relative; height: 12px; border-radius: 6px; background: {track}; margin: 10px 0 4px; overflow: visible;}}
.sp-bar .fill {{height: 12px; border-radius: 6px;}}
.sp-bar .limit {{position: absolute; top: -4px; width: 2px; height: 20px; background: #dc2626;}}
.sp-row {{display: flex; justify-content: space-between; font-size: 12px; color: {sub};}}
.sp-sev .plat {{display: flex; align-items: center; gap: 10px; margin: 8px 0;}}
.sp-sev .pl {{width: 96px; font-size: 13px; font-weight: 700;}}
.sp-sev .stack {{flex: 1; display: flex; height: 26px; border-radius: 6px; overflow: hidden; background: {track};}}
.sp-sev .seg {{height: 26px; color: #fff; font-size: 12px; font-weight: 700; display: flex; align-items: center;
  justify-content: center; white-space: nowrap; overflow: hidden;}}
.sp-sev .tot {{width: 64px; text-align: right; font-size: 13px; font-weight: 700;}}
.sp-legend {{display: flex; gap: 12px; flex-wrap: wrap; font-size: 12px; color: {sub}; margin-top: 6px;}}
.sp-legend i {{display: inline-block; width: 10px; height: 10px; border-radius: 2px; margin-right: 4px; vertical-align: -1px;}}
.sp-empty {{font-size: 13px; color: {sub}; padding: 12px 4px;}}
</style>"""


# ------------------------------------------------------------------ views
def tile(label, value, unit, sub, c1, c2):
    return (f'<div class="sp-tile" style="background: linear-gradient(135deg, {c1}, {c2});">'
            f'<div class="l">{esc(label)}</div><div class="v">{value}<small>{esc(unit)}</small></div>'
            f'<div class="s">{esc(sub)}</div></div>')


def view_kpi(s):
    out = []
    for key, label in (("overall", "Overall success"), ("rhel", "RHEL 9 success"), ("windows", "Windows success")):
        pct, ok, att, n = s[key]
        c1, c2 = rate_colour(pct)
        val = "-" if pct is None else f"{pct:.1f}"
        sub = f"{ok:,} / {att:,} verified, {n} host run{'' if n == 1 else 's'}" if att else "no patch runs in range"
        out.append(tile(label, val, "%" if pct is not None else "", sub, c1, c2))
    out.append(tile("Patch cycles", s["cycles"], "", f"{s['host_failures']} host failure{'' if s['host_failures'] == 1 else 's'}", "#3b82f6", "#1d4ed8"))
    avg = s["avg_cycle_s"]
    out.append(tile("Avg cycle time", "-" if avg is None else f"{avg / 60:.1f}", "" if avg is None else "min",
                    "trigger to verified result", "#a855f7", "#7e22ce"))
    cost = s["avg_cost"]
    out.append(tile("Avg cost per cycle", "-" if cost is None else f"${cost:.4f}", "",
                    "list price, before free tier", "#14b8a6", "#0f766e"))
    return f'<div class="sp-tiles">{"".join(out)}</div>'


def view_hosts(s):
    rows = s["latest"]
    if not rows:
        return '<div class="sp-empty">No patch runs in the selected time range.</div>'
    scale = max([LAMBDA_LIMIT_S * 2] + [num(r.get("duration_s")) * 1.1 for r in rows])
    cards = []
    for r in rows:
        label, colour = STATUS.get(r.get("status"), (str(r.get("status", "")).upper(), "#6b7280"))
        plat, pcol = PLATFORM.get(r.get("platform"), (r.get("platform") or "", "#6b7280"))
        unit = r.get("unit") or ""
        d = num(r.get("duration_s"))
        fill = "#ef4444" if d > LAMBDA_LIMIT_S else "#22c55e"
        if r.get("status") == "failed":
            body = (f'<div class="big">{esc(r.get("before"))}<span class="u">{esc(unit)} missing</span></div>'
                    f'<div class="meta">failed at {esc(r.get("failed_at") or "?")}: {esc((r.get("reason") or "")[:90])}</div>')
        else:
            body = (f'<div class="big">{esc(r.get("before"))} &rarr; {esc(r.get("after"))}<span class="u">{esc(unit)}</span></div>'
                    f'<div class="meta">verified {esc(r.get("succeeded"))} / {esc(r.get("attempted"))}'
                    + (f' &middot; {esc(r.get("percent"))}% scope' if num(r.get("percent"), 100) < 100 else "")
                    + (f' &middot; {int(num(r.get("passes")))} passes (first pass {esc(r.get("first_pass_succeeded"))}/{esc(r.get("attempted"))})'
                       if num(r.get("passes")) > 1 else "") + "</div>")
        chips = []
        if r.get("rebooted") is not None:
            chips.append("rebooted" if r.get("rebooted") else "no reboot")
        if r.get("healthy") is not None:
            chips.append("workload healthy" if r.get("healthy") else "workload NOT healthy")
        cards.append(
            f'<div class="sp-card" style="border-top-color: {colour};">'
            f'<div class="top"><span class="name">{esc(short(r.get("host")))}</span>'
            f'<span class="sp-chip" style="background: {colour};">{esc(label)}</span></div>'
            f'<div class="meta"><span class="sp-chip" style="background: {pcol};">{esc(plat)}</span> '
            f'{esc(r.get("workload") or "")} &middot; {esc(when(r.get("_ts")))}</div>'
            f'{body}'
            f'<div class="sp-bar"><div class="fill" style="width: {min(100, 100 * d / scale):.1f}%; background: {fill};"></div>'
            f'<div class="limit" style="left: {100 * LAMBDA_LIMIT_S / scale:.1f}%;" title="Lambda 15-min limit"></div></div>'
            f'<div class="sp-row"><span>{esc(dur(d))} deployment</span><span>| = 900 s Lambda limit</span></div>'
            f'<div class="sp-row"><span>{esc(" · ".join(chips))}</span></div></div>')
    return f'<div class="sp-cards">{"".join(cards)}</div>'


def view_severity(s):
    sev = s["severity"]
    if not sev:
        return ('<div class="sp-empty">No severity data in this range yet. It is recorded for patch runs '
                'after the v2.2 metrics update.</div>')
    rows = []
    for plat in sorted(sev):
        vals = sev[plat]
        total = sum(vals.values())
        name, _ = PLATFORM.get(plat, (plat, ""))
        segs = "".join(
            f'<div class="seg" style="width: {100 * vals[k] / total:.2f}%; background: {c};" title="{n} {vals[k]}">'
            f'{vals[k] if 100 * vals[k] / total >= 7 else ""}</div>'
            for n, k, c in SEVERITIES if total and vals[k])
        rows.append(f'<div class="plat"><span class="pl">{esc(name)}</span>'
                    f'<div class="stack">{segs}</div><span class="tot">{total:,}</span></div>')
    legend = "".join(f'<span><i style="background: {c};"></i>{n}</span>' for n, _, c in SEVERITIES)
    return f'<div class="sp-sev">{"".join(rows)}<div class="sp-legend">{legend}</div></div>'


VIEWS = {"kpi": view_kpi, "hosts": view_hosts, "severity": view_severity}


def render(view, s, dark=False):
    """One panel as the widget returns it. Also used by site_publisher.py, so the website shows the same HTML."""
    return f'<div class="sp cwdb-no-default-styles">{css(dark)}{VIEWS[view](s)}</div>'


def lambda_handler(event, context=None, logs_client=None):
    if event.get("describe"):
        return DOCS
    ctx = event.get("widgetContext") or {}
    dark = ctx.get("theme") == "dark"
    view = event.get("view", "kpi")
    tr = ctx.get("timeRange") or {}
    end = num(tr.get("end"), time.time() * 1000)
    start = num(tr.get("start"), end - 7 * 86400 * 1000)
    try:
        if view not in VIEWS:
            raise ValueError(f"unknown view {view!r}; use kpi, hosts or severity")
        return render(view, summarise(fetch(start, end, logs_client)), dark)
    except Exception as e:  # show the problem in the widget instead of a blank panel
        print(json.dumps({"error": type(e).__name__, "detail": str(e)}))
        body = f'<div class="sp-empty">Widget error: {esc(type(e).__name__)}: {esc(str(e))}</div>'
    return f'<div class="sp cwdb-no-default-styles">{css(dark)}{body}</div>'
