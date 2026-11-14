"""serverless-patch-site-publisher: keeps the project website's dashboard up to date.

The website mirrors the CloudWatch dashboard PatchManagement-Dashboard. This Lambda gathers the
same data the dashboard reads and writes it as JSON the website draws:

  data/live.json        last LIVE_DAYS days, plus "patch cycle in progress" status
  data/evaluation.json  the fixed evaluation period EVAL_FROM..EVAL_TO (Malaysia time), if set

Each file holds:
  records   serverless-patch-metrics host and cycle records (scan and patch), newest first, with
            only the fields the dashboard shows (no account ID, ARNs, instance IDs or IP addresses)
  panels    the three coloured Patch Summary panels, rendered by summary_widget.py itself, so they
            are the same HTML as the CloudWatch custom widgets (light and dark)
  metrics   Step Functions / Lambda / SNS counts for the Orchestration Layer widget and the
            executions-per-day chart (CloudWatch GetMetricData)

Triggered by EventBridge on every status change of serverless-patch-cycle (RUNNING, SUCCEEDED,
FAILED, TIMED_OUT, ABORTED), and once by deploy-site.ps1. No host access, no secrets, no VPC.
"""
import json
import os
import re
import time
from datetime import datetime, timedelta, timezone

import summary_widget  # packaged alongside: same panels and same summarise() as the CloudWatch widgets

LOG_GROUP = os.environ.get("LOG_GROUP", "/aws/lambda/serverless-patch-metrics")
BUCKET = os.environ.get("BUCKET", "")
DISTRIBUTION_ID = os.environ.get("DISTRIBUTION_ID", "")
STATE_MACHINE_ARN = os.environ.get("STATE_MACHINE_ARN", "")
LIVE_DAYS = int(os.environ.get("LIVE_DAYS", "14"))
EVAL_FROM = os.environ.get("EVAL_FROM", "")     # YYYY-MM-DD, Malaysia time
EVAL_TO = os.environ.get("EVAL_TO", "")         # YYYY-MM-DD, inclusive
FUNCTIONS = [f for f in (os.environ.get("RHEL_FN", "serverless-patch-rhel"),
                         os.environ.get("WIN_FN", "serverless-patch-windows"),
                         os.environ.get("METRICS_FN", "serverless-patch-metrics")) if f]
TOPIC_NAME = os.environ.get("TOPIC_NAME", "serverless-patch-notify")
REGION = os.environ.get("AWS_REGION", "ap-southeast-5")
MYT = timezone(timedelta(hours=8))
LAMBDA_LIMIT_S = 900
QUERY = ("fields @timestamp, @message | filter record = 'host' or record = 'cycle' "
         "| sort @timestamp desc | limit 10000")

# Fields the dashboard shows. Everything else in a record (execution ARN, kernel builds,
# EMF metadata) stays in CloudWatch.
HOST_FIELDS = ("record", "run_id", "mode", "percent", "host", "platform", "workload", "unit", "status",
               "before", "after", "attempted", "succeeded", "duration_s", "rebooted", "healthy",
               "failed_at", "reason", "passes", "followup_passes", "first_pass_succeeded",
               "fixed_critical", "fixed_important", "fixed_moderate", "fixed_low", "fixed_unrated")
CYCLE_FIELDS = ("record", "run_id", "mode", "percent", "started", "finished", "duration_s", "hosts_total",
                "patched", "patched_partial", "compliant", "scanned", "skipped", "failed",
                "avg_host_seconds", "attempted", "succeeded", "transitions", "lambda_invocations",
                "lambda_seconds", "lambda_gb_s", "cost_sfn_usd", "cost_lambda_usd", "cost_other_usd",
                "cost_usd")
_MASKS = [(re.compile(r"\barn:aws[\w:/+=,.@-]*"), "arn:…"),
          (re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b"), "x.x.x.x"),
          (re.compile(r"\bi-[0-9a-f]{8,17}\b"), "i-…"),
          (re.compile(r"\b\d{12}\b"), "…")]


def _mask(text):
    text = "" if text is None else str(text)
    for rx, repl in _MASKS:
        text = rx.sub(repl, text)
    return text


def safe_record(rec):
    keep = HOST_FIELDS if rec.get("record") == "host" else CYCLE_FIELDS
    out = {k: rec[k] for k in keep if k in rec}
    if "reason" in out:
        out["reason"] = _mask(out["reason"])
    if "failed_at" in out:
        out["failed_at"] = _mask(out["failed_at"])
    out["_ts"] = rec.get("_ts")
    return out


def _iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def logs_ts(dt):
    """A time in the format Logs Insights gives @timestamp (UTC), which summary_widget expects."""
    dt = dt.astimezone(timezone.utc)
    return dt.strftime("%Y-%m-%d %H:%M:%S.") + f"{dt.microsecond // 1000:03d}"


# ------------------------------------------------------------------ the page's data
def build_payload(records, view, start, end, label, metrics=None, status=None, source="cloudwatch", now=None,
                  cost_known=True):
    """records: metrics log records with "_ts" (Logs Insights @timestamp format), any order.
    cost_known=False (records rebuilt from evidence/, which has no cost) shows cost as "-"."""
    now = now or datetime.now(timezone.utc)
    recs = [safe_record(r) for r in records if r.get("record") in ("host", "cycle")]
    recs.sort(key=lambda r: str(r.get("_ts") or ""), reverse=True)      # newest first, as Logs Insights
    s = summary_widget.summarise(recs)
    if not cost_known:
        s["avg_cost"] = None
    panels = {theme: {name: summary_widget.render(name, s, theme == "dark")
                      for name in ("kpi", "hosts", "severity")}
              for theme in ("light", "dark")}
    return {
        "view": view,
        "source": source,
        "generated_at": _iso(now),
        "region": REGION,
        "lambda_limit_s": LAMBDA_LIMIT_S,
        "range": {"start": _iso(start), "end": _iso(end), "label": label},
        "status": status,
        "records": recs,
        "panels": panels,
        "metrics": metrics,
        "cost_known": cost_known,
    }


def live_label(days):
    """Name of the Live view's period: "Last 2 weeks" for whole weeks, else "Last 10 days"."""
    if days % 7 == 0:
        weeks = days // 7
        return "Last week" if weeks == 1 else f"Last {weeks} weeks"
    return "Last day" if days == 1 else f"Last {days} days"


def eval_window(now, date_from=None, date_to=None):
    """(start, end, label) for a reporting period of whole days in Malaysia time, or None."""
    date_from, date_to = date_from or EVAL_FROM, date_to or EVAL_TO
    if not (date_from and date_to):
        return None
    start = datetime.strptime(date_from, "%Y-%m-%d").replace(tzinfo=MYT)
    last = datetime.strptime(date_to, "%Y-%m-%d").replace(tzinfo=MYT)
    end = min(last + timedelta(days=1), now)
    label = (f"{start.day} to {last.day} {last.strftime('%b %Y')}" if (start.year, start.month) == (last.year, last.month)
             else f"{start.day} {start.strftime('%b %Y')} to {last.day} {last.strftime('%b %Y')}")
    return start, end, label


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


def fetch_metrics(start, end, cw, now):
    """Counts for the Orchestration Layer widget and Step Functions Executions per Day."""
    specs = [("executions", "AWS/States", "ExecutionsStarted", "StateMachineArn", STATE_MACHINE_ARN),
             ("succeeded", "AWS/States", "ExecutionsSucceeded", "StateMachineArn", STATE_MACHINE_ARN),
             ("failed", "AWS/States", "ExecutionsFailed", "StateMachineArn", STATE_MACHINE_ARN),
             ("emails", "AWS/SNS", "NumberOfNotificationsDelivered", "TopicName", TOPIC_NAME)]
    for i, fn in enumerate(FUNCTIONS):
        specs.append((f"inv{i}", "AWS/Lambda", "Invocations", "FunctionName", fn))
        specs.append((f"err{i}", "AWS/Lambda", "Errors", "FunctionName", fn))
    # Hourly data is kept 63 days; older ranges are read per day.
    period = 3600 if (now - start) < timedelta(days=60) else 86400
    queries = [{"Id": qid, "ReturnData": True, "MetricStat": {
        "Metric": {"Namespace": ns, "MetricName": name, "Dimensions": [{"Name": dim, "Value": val}]},
        "Period": period, "Stat": "Sum"}} for qid, ns, name, dim, val in specs if val]
    series, token = {}, None
    while True:
        kw = {"MetricDataQueries": queries, "StartTime": start, "EndTime": end, "ScanBy": "TimestampAscending"}
        if token:
            kw["NextToken"] = token
        page = cw.get_metric_data(**kw)
        for res in page.get("MetricDataResults", []):
            series.setdefault(res["Id"], []).extend(zip(res.get("Timestamps", []), res.get("Values", [])))
        token = page.get("NextToken")
        if not token:
            break

    def total(qid):
        return round(sum(v for _, v in series.get(qid, [])))

    per_day = {}
    for key in ("succeeded", "failed"):
        for ts, v in series.get(key, []):
            day = ts.astimezone(timezone.utc).strftime("%Y-%m-%d")      # CloudWatch day periods are UTC
            per_day.setdefault(day, {"day": day, "succeeded": 0, "failed": 0})[key] += v
    return {
        "executions": total("executions"),
        "succeeded": total("succeeded"),
        "failed": total("failed"),
        "lambda_invocations": sum(total(f"inv{i}") for i in range(len(FUNCTIONS))),
        "lambda_errors": sum(total(f"err{i}") for i in range(len(FUNCTIONS))),
        "emails": total("emails"),
        "per_day": [{"day": d["day"], "succeeded": round(d["succeeded"]), "failed": round(d["failed"])}
                    for d in sorted(per_day.values(), key=lambda d: d["day"])],
    }


def running_status(sfn):
    """What is running now, asked of Step Functions directly (right whatever order events arrive in)."""
    if not STATE_MACHINE_ARN:
        return {"state": "unknown"}
    res = sfn.list_executions(stateMachineArn=STATE_MACHINE_ARN, statusFilter="RUNNING", maxResults=10)
    execs = sorted(res.get("executions", []), key=lambda e: e["startDate"])
    if not execs:
        return {"state": "idle"}
    mode = "scan"
    try:
        inp = json.loads(sfn.describe_execution(executionArn=execs[0]["executionArn"]).get("input") or "{}")
        mode = inp.get("mode") or "scan"
    except Exception:  # noqa: BLE001 (the mode is a label only)
        pass
    return {"state": "running", "mode": mode if mode in ("scan", "patch") else "scan",
            "since": _iso(execs[0]["startDate"]), "count": len(execs)}


def put_json(s3, key, data):
    body = json.dumps(data, separators=(",", ":"), default=str).encode("utf-8")
    s3.put_object(Bucket=BUCKET, Key=key, Body=body, ContentType="application/json; charset=utf-8",
                  CacheControl="public, max-age=30")
    return len(body)


# ------------------------------------------------------------------ handler
def lambda_handler(event, context=None, logs=None, sfn=None, s3=None, cloudfront=None, cw=None):
    if not (logs and sfn and s3 and cloudfront and cw):
        import boto3
        logs = logs or boto3.client("logs")
        sfn = sfn or boto3.client("stepfunctions")
        s3 = s3 or boto3.client("s3")
        cloudfront = cloudfront or boto3.client("cloudfront")
        cw = cw or boto3.client("cloudwatch")

    detail = (event or {}).get("detail") or {}
    exec_status, exec_name = detail.get("status"), detail.get("name")
    try:
        exec_mode = (json.loads(detail.get("input") or "{}") or {}).get("mode") or "scan"
    except (ValueError, AttributeError):
        exec_mode = "scan"

    now = datetime.now(timezone.utc)
    start = now - timedelta(days=LIVE_DAYS)
    records = fetch_records(start, now, logs)
    # A patch cycle that has just succeeded: its records can take a few seconds to become
    # searchable. Wait for them (up to about 90 s) rather than publish a page without it.
    waited = 0
    if exec_status == "SUCCEEDED" and exec_mode == "patch" and exec_name:
        while not any(r.get("record") == "cycle" and r.get("run_id") == exec_name for r in records) and waited < 90:
            time.sleep(15)
            waited += 15
            now = datetime.now(timezone.utc)
            records = fetch_records(start, now, logs)

    live = build_payload(records, "live", start, now, live_label(LIVE_DAYS),
                         metrics=fetch_metrics(start, now, cw, now), status=running_status(sfn), now=now)
    written = {"data/live.json": put_json(s3, "data/live.json", live)}

    ev = eval_window(now)
    if ev:
        e_start, e_end, e_label = ev
        e_records = fetch_records(e_start, e_end, logs)
        evaluation = build_payload(e_records, "evaluation", e_start, e_end, e_label,
                                   metrics=fetch_metrics(e_start, e_end, cw, now), now=now)
        written["data/evaluation.json"] = put_json(s3, "data/evaluation.json", evaluation)

    inv = None
    if DISTRIBUTION_ID:
        paths = ["/" + k for k in written]
        inv = cloudfront.create_invalidation(DistributionId=DISTRIBUTION_ID, InvalidationBatch={
            "Paths": {"Quantity": len(paths), "Items": paths},
            "CallerReference": f"live-{int(time.time() * 1000)}",
        })["Invalidation"]["Id"]
    result = {"written": written, "records": len(live["records"]),
              "patch_cycles": sum(1 for r in live["records"] if r.get("record") == "cycle" and r.get("mode") == "patch"),
              "status": (live["status"] or {}).get("state"), "trigger": exec_status or (event or {}).get("source") or "manual",
              "execution": exec_name, "waited_s": waited, "invalidation": inv}
    print(json.dumps(result))
    return result
