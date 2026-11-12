"""serverless-patch-site-publisher: keeps the project website's live results up to date.

Triggered by EventBridge on every status change of the serverless-patch-cycle state machine
(RUNNING, SUCCEEDED, FAILED, TIMED_OUT, ABORTED), and once by deploy-site.ps1 after a deploy.

Each call:
  1. reads the patch host and cycle records that serverless-patch-metrics wrote to its log group
     (Logs Insights, last LIVE_DAYS days), waiting briefly for the record of a cycle that has just
     finished, so the page never shows a finished cycle as missing;
  2. lists running executions, so the page can show "patch cycle in progress";
  3. writes data/live.json to the site bucket (only the fields the page shows: no account ID,
     ARNs, instance IDs or IP addresses) and clears /data/live.json in CloudFront.

No host access, no secrets, no VPC.

Environment:
  LOG_GROUP          metrics log group (default /aws/lambda/serverless-patch-metrics)
  BUCKET             site bucket
  DISTRIBUTION_ID    CloudFront distribution of the site
  STATE_MACHINE_ARN  serverless-patch-cycle ARN
  LIVE_DAYS          how many days of results the live view shows (default 30)
"""
import json
import os
import time
from datetime import datetime, timedelta, timezone

import metrics  # packaged alongside: verdict() gives the same result word as the email and dashboard

LOG_GROUP = os.environ.get("LOG_GROUP", "/aws/lambda/serverless-patch-metrics")
BUCKET = os.environ.get("BUCKET", "")
DISTRIBUTION_ID = os.environ.get("DISTRIBUTION_ID", "")
STATE_MACHINE_ARN = os.environ.get("STATE_MACHINE_ARN", "")
LIVE_DAYS = int(os.environ.get("LIVE_DAYS", "30"))
KEY = "data/live.json"
LAMBDA_LIMIT_S = 900
TERMINAL = ("SUCCEEDED", "FAILED", "TIMED_OUT", "ABORTED")
QUERY = ("fields @timestamp, @message | filter record = 'host' or record = 'cycle' "
         "| filter mode = 'patch' | sort @timestamp desc | limit 10000")
SEVERITY_FIELDS = ("fixed_critical", "fixed_important", "fixed_moderate", "fixed_low", "fixed_unrated")


def _num(v, default=0):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else default


def _iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def short(host):
    return (host or "").replace("serverless-patch-", "")


# ------------------------------------------------------------------ records -> page data
def build_live(records, status, now, days=LIVE_DAYS):
    """Turn metrics log records (newest first or any order) into the page's data shape.

    records: dicts as written by metrics.host_records / metrics.cycle_record, each with "_ts"
    (the log event time). Only patch-mode cycles with at least one host are kept, as on the
    CloudWatch dashboard. When a cycle was recorded twice, the latest record wins.
    """
    cycles_by_run, hosts_by_run = {}, {}
    for rec in sorted(records, key=lambda r: str(r.get("_ts") or "")):
        if rec.get("mode") != "patch" or not rec.get("run_id"):
            continue
        if rec.get("record") == "cycle":
            if _num(rec.get("hosts_total")) > 0:
                cycles_by_run[rec["run_id"]] = rec
        elif rec.get("record") == "host" and rec.get("host"):   # one row per host; a later record wins
            hosts_by_run.setdefault(rec["run_id"], {})[rec["host"]] = rec

    host_runs, cycles = [], []
    for run_id, c in cycles_by_run.items():
        started = c.get("started")
        if not started:
            continue
        rows = list((hosts_by_run.get(run_id) or {}).values())
        for h in rows:
            row = {
                "run_id": run_id,
                "started": started,
                "host": short(h.get("host")),
                "platform": h.get("platform"),
                "workload": h.get("workload"),
                "unit": h.get("unit") or ("KB" if h.get("platform") == "windows" else "RHSA"),
                "status": h.get("status"),
                "scope_pct": _num(h.get("percent"), 100),
                "before": h.get("before"),
                "after": h.get("after"),
                "attempted": _num(h.get("attempted")),
                "succeeded": _num(h.get("succeeded")),
                "duration_s": _num(h.get("duration_s")),
                "rebooted": h.get("rebooted"),
                "healthy": h.get("healthy"),
                "failed_at": h.get("failed_at") or "",
            }
            for k in SEVERITY_FIELDS:
                row[k] = _num(h.get(k))
            host_runs.append(row)
        word, summary = metrics.verdict(c)
        cycles.append({
            "run_id": run_id,
            "started": started,
            "hosts": sorted(short(h.get("host")) for h in rows),
            "hosts_total": _num(c.get("hosts_total")),
            "scope_pct": _num(c.get("percent"), 100),
            "result": word,
            "summary": summary,
            "patched": _num(c.get("patched")),
            "partial": _num(c.get("patched_partial")),
            "failed": _num(c.get("failed")),
            "attempted": _num(c.get("attempted")),
            "succeeded": _num(c.get("succeeded")),
            "duration_s": _num(c.get("duration_s")),
        })
    host_runs.sort(key=lambda r: r["started"])
    cycles.sort(key=lambda r: r["started"])
    return {
        "view": "live",
        "generated_at": _iso(now),
        "region": metrics.REGION,
        "lambda_limit_s": LAMBDA_LIMIT_S,
        "window": {"days": days, "from": None, "to": None},
        "status": status,
        "host_runs": host_runs,
        "cycles": cycles,
    }


# ------------------------------------------------------------------ AWS reads
def fetch_records(start, end, logs):
    qid = logs.start_query(logGroupName=LOG_GROUP, startTime=int(start.timestamp()),
                           endTime=int(end.timestamp()), queryString=QUERY, limit=10000)["queryId"]
    deadline = time.time() + 45
    while True:
        r = logs.get_query_results(queryId=qid)
        if r["status"] in ("Complete", "Failed", "Cancelled", "Timeout", "Unknown"):
            break
        if time.time() > deadline:
            try:
                logs.stop_query(queryId=qid)
            except Exception:  # noqa: BLE001 (best effort)
                pass
            raise TimeoutError("Logs Insights query took longer than 45 s")
        time.sleep(0.5)
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


def running_status(sfn):
    """What is running now. Asks Step Functions directly, so the answer is right whatever
    order the status-change events arrive in."""
    if not STATE_MACHINE_ARN:
        return {"state": "unknown"}
    res = sfn.list_executions(stateMachineArn=STATE_MACHINE_ARN, statusFilter="RUNNING", maxResults=10)
    execs = sorted(res.get("executions", []), key=lambda e: e["startDate"])
    if not execs:
        return {"state": "idle"}
    first = execs[0]
    mode = "scan"
    try:
        inp = json.loads(sfn.describe_execution(executionArn=first["executionArn"]).get("input") or "{}")
        mode = inp.get("mode") or "scan"
    except Exception:  # noqa: BLE001 (mode is a label only)
        pass
    return {"state": "running", "mode": mode if mode in ("scan", "patch") else "scan",
            "since": _iso(first["startDate"]), "count": len(execs)}


# ------------------------------------------------------------------ handler
def lambda_handler(event, context=None, logs=None, sfn=None, s3=None, cloudfront=None):
    if not (logs and sfn and s3 and cloudfront):
        import boto3
        logs = logs or boto3.client("logs")
        sfn = sfn or boto3.client("stepfunctions")
        s3 = s3 or boto3.client("s3")
        cloudfront = cloudfront or boto3.client("cloudfront")

    detail = (event or {}).get("detail") or {}
    exec_status = detail.get("status")
    exec_name = detail.get("name")
    try:
        exec_mode = (json.loads(detail.get("input") or "{}") or {}).get("mode") or "scan"
    except (ValueError, AttributeError):
        exec_mode = "scan"

    now = datetime.now(timezone.utc)
    start = now - timedelta(days=LIVE_DAYS)
    records = fetch_records(start, now, logs)

    # A patch cycle that has just succeeded: its records may take a few seconds to become
    # searchable. Wait for them (up to about 90 s) rather than publish a page without it.
    waited = 0
    if exec_status == "SUCCEEDED" and exec_mode == "patch" and exec_name:
        while not any(r.get("record") == "cycle" and r.get("run_id") == exec_name for r in records) and waited < 90:
            time.sleep(15)
            waited += 15
            now = datetime.now(timezone.utc)
            records = fetch_records(start, now, logs)

    status = running_status(sfn)
    data = build_live(records, status, now)
    body = json.dumps(data, separators=(",", ":"), default=str).encode("utf-8")
    s3.put_object(Bucket=BUCKET, Key=KEY, Body=body, ContentType="application/json; charset=utf-8",
                  CacheControl="public, max-age=30")
    inv = None
    if DISTRIBUTION_ID:
        inv = cloudfront.create_invalidation(DistributionId=DISTRIBUTION_ID, InvalidationBatch={
            "Paths": {"Quantity": 1, "Items": ["/" + KEY]},
            "CallerReference": f"live-{int(time.time() * 1000)}",
        })["Invalidation"]["Id"]
    result = {"key": KEY, "bytes": len(body), "cycles": len(data["cycles"]), "host_runs": len(data["host_runs"]),
              "status": status.get("state"), "trigger": exec_status or (event or {}).get("source") or "manual",
              "execution": exec_name, "waited_s": waited, "invalidation": inv}
    print(json.dumps(result))
    return result
