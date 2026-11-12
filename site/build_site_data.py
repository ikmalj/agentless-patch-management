"""Build the data file for the project website from evidence/.

Reads every evidence/cycle-patch-*.json result, turns each one into per-host and per-cycle
records with the same rules the serverless-patch-metrics Lambda uses (lambda/metrics.py),
and writes site/data/patch-data.js, which site/index.html loads.

Only what the dashboard shows is written: no account ID, ARNs, instance IDs or IP addresses.
Run it again after new patch runs:

    python site/build_site_data.py
    python site/build_site_data.py --from 2026-11-01 --to 2026-11-12

--from / --to keep only cycles that started on those days, Malaysia time (UTC+8), both inclusive.
The page then shows that window as its reporting period.
"""
import argparse
import glob
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone

sys.dont_write_bytecode = True
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "lambda"))
import metrics  # noqa: E402  (lambda/metrics.py: attempted / verified counts and verdicts)

EVIDENCE = os.path.join(ROOT, "evidence")
OUT = os.path.join(ROOT, "site", "data", "patch-data.js")
SEVERITY_FIELDS = ("fixed_critical", "fixed_important", "fixed_moderate", "fixed_low", "fixed_unrated")
MYT = timezone(timedelta(hours=8))


def myt_day(text):
    """A YYYY-MM-DD argument as the start of that day in Malaysia time."""
    try:
        return datetime.strptime(text, "%Y-%m-%d").replace(tzinfo=MYT)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{text!r} is not a date like 2026-11-01")


def parse_time(text):
    return datetime.fromisoformat(str(text).replace("Z", "+00:00"))


def short(host):
    return (host or "").replace("serverless-patch-", "")


def commit():
    try:
        return subprocess.run(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"], capture_output=True,
                              text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def main():
    ap = argparse.ArgumentParser(description="Build site/data/patch-data.js from evidence/.")
    ap.add_argument("--from", dest="date_from", type=myt_day, help="first day to include, YYYY-MM-DD (MYT)")
    ap.add_argument("--to", dest="date_to", type=myt_day, help="last day to include, YYYY-MM-DD (MYT)")
    args = ap.parse_args()
    start = args.date_from
    end = args.date_to + timedelta(days=1) if args.date_to else None   # exclusive
    if start and end and end <= start:
        sys.exit("--to is before --from")

    host_runs, cycles = [], []
    skipped = 0
    files = sorted(glob.glob(os.path.join(EVIDENCE, "cycle-patch-*.json")))
    if not files:
        sys.exit(f"no cycle-patch-*.json files in {EVIDENCE}")
    for path in files:
        with open(path, encoding="utf-8-sig") as f:
            doc = json.load(f)
        report = doc.get("report") or {}
        if report.get("mode") != "patch" or not report.get("results"):
            continue
        began = parse_time(report.get("started"))
        if (start and began < start) or (end and began >= end):
            skipped += 1
            continue
        hosts = metrics.host_records(report, 0)
        for h in hosts:
            row = {
                "run_id": report.get("run_id"),
                "started": report.get("started"),
                "host": short(h["host"]),
                "platform": h["platform"],
                "workload": h["workload"],
                "unit": h["unit"],
                "status": h["status"],
                "scope_pct": h["percent"],
                "before": h["before"],
                "after": h["after"],
                "attempted": h["attempted"],
                "succeeded": h["succeeded"],
                "duration_s": h["duration_s"],
                "rebooted": h["rebooted"],
                "healthy": h["healthy"],
                "failed_at": h["failed_at"],
            }
            for k in SEVERITY_FIELDS:
                row[k] = h.get(k, 0)
            host_runs.append(row)
        cycle = metrics.cycle_record(report, hosts, {"cost_usd": None}, None, 0)
        word, summary = metrics.verdict(report)
        cycles.append({
            "run_id": report.get("run_id"),
            "started": report.get("started"),
            "hosts": [short(r.get("host")) for r in report["results"]],
            "hosts_total": cycle["hosts_total"],
            "scope_pct": cycle["percent"],
            "result": word,
            "summary": summary,
            "patched": cycle["patched"],
            "partial": cycle["patched_partial"],
            "failed": cycle["failed"],
            "attempted": cycle["attempted"],
            "succeeded": cycle["succeeded"],
            "duration_s": cycle["duration_s"],
        })

    if not cycles:
        sys.exit("no patch cycles in the selected dates; nothing written")
    host_runs.sort(key=lambda r: r["started"])
    cycles.sort(key=lambda r: r["started"])
    data = {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "commit": commit(),
        "region": "ap-southeast-5",
        "lambda_limit_s": 900,
        "window": {
            "from": start.strftime("%Y-%m-%d") if start else None,
            "to": args.date_to.strftime("%Y-%m-%d") if args.date_to else None,
        },
        "host_runs": host_runs,
        "cycles": cycles,
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("// Generated by site/build_site_data.py from evidence/. Do not edit by hand.\n")
        f.write("window.PATCH_DATA = ")
        json.dump(data, f, indent=1)
        f.write(";\n")
    window = ""
    if start or end:
        window = f" from {data['window']['from'] or 'the first run'} to {data['window']['to'] or 'the last run'} (MYT)"
    print(f"wrote {os.path.relpath(OUT, ROOT)}: {len(cycles)} patch cycles, {len(host_runs)} host runs{window}"
          + (f"; {skipped} cycles outside the dates left out" if skipped else ""))


if __name__ == "__main__":
    main()
