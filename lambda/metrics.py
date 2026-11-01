"""serverless-patch-metrics: visibility step at the end of every patch cycle (Phase D).

Called once per execution by the serverless-patch-cycle state machine, after the
per-host results are summarised. It never connects to a host. It:

  1. writes one JSON log record per host and one per cycle to CloudWatch Logs,
     using CloudWatch Embedded Metric Format (EMF) for patch runs, so the same
     line becomes custom metrics in the ServerlessPatch namespace;
  2. estimates the serverless cost of the run from the execution history
     (state transitions, Lambda invocations and duration) at list prices;
  3. returns the subject and text of the SNS notification, which Step Functions
     publishes itself.

Event (kind = "cycle"):
  {"kind": "cycle", "report": <Summarize Run output>, "execution_arn": "...", "notify": true}
Event (kind = "run_error"):
  {"kind": "run_error", "error": {"Error": "...", "Cause": "..."}, "failed_state": "...",
   "run_id": "...", "mode": "...", "percent": 100, "started": "...", "execution_arn": "...", "notify": true}

Runs outside the VPC. Its role can only write its own logs and read the history
of serverless-patch-cycle executions.
"""
import json
import math
import os
import time
from datetime import datetime, timedelta, timezone

NAMESPACE = os.environ.get("METRIC_NAMESPACE", "ServerlessPatch")
STATE_MACHINE = os.environ.get("STATE_MACHINE_NAME", "serverless-patch-cycle")
REGION = os.environ.get("AWS_REGION", "ap-southeast-5")

# List prices in USD, before the free tier. Defaults are the published US East
# (N. Virginia) rates; override per region with environment variables.
PRICE_SFN_TRANSITION = float(os.environ.get("PRICE_SFN_TRANSITION", "0.000025"))
PRICE_LAMBDA_GB_S = float(os.environ.get("PRICE_LAMBDA_GB_S", "0.0000166667"))
PRICE_LAMBDA_REQUEST = float(os.environ.get("PRICE_LAMBDA_REQUEST", "0.0000002"))
PRICE_SNS_PUBLISH = float(os.environ.get("PRICE_SNS_PUBLISH", "0.0000005"))
PRICE_SNS_EMAIL = float(os.environ.get("PRICE_SNS_EMAIL", "0.00002"))
PATCH_LAMBDA_MEMORY_MB = int(os.environ.get("PATCH_LAMBDA_MEMORY_MB", "256"))
# States still to run after this step: Should Notify, Notify, Any Host Failed, end state.
REMAINING_TRANSITIONS = int(os.environ.get("REMAINING_TRANSITIONS", "4"))

MYT = timezone(timedelta(hours=8))
PATCHED_STATES = ("patched", "patched_partial")


# ------------------------------------------------------------------ helpers
def _num(v, default=0):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else default


def _parse_ts(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except ValueError:
        return None


def _myt(s):
    t = _parse_ts(s)
    return t.astimezone(MYT).strftime("%d %b %Y %H:%M:%S MYT") if t else "unknown"


def _dur(seconds):
    s = int(round(_num(seconds)))
    if s < 60:
        return f"{_num(seconds):.1f} s"
    m, s = divmod(s, 60)
    if m < 60:
        return f"{m}m {s:02d}s"
    h, m = divmod(m, 60)
    return f"{h}h {m:02d}m {s:02d}s"


def _console(execution_arn):
    if not execution_arn:
        return ""
    return (f"https://{REGION}.console.aws.amazon.com/states/home?region={REGION}"
            f"#/v2/executions/details/{execution_arn}")


def _subject(text):
    # SNS subject: ASCII, no line breaks, under 100 characters.
    clean = "".join(ch if 32 <= ord(ch) < 127 else "?" for ch in text)
    return clean[:99]


def _reason(fail_detail):
    """Short, readable failure reason from a Catch errorOutput or a precheck reason list."""
    if not fail_detail:
        return ""
    if isinstance(fail_detail, dict):
        if fail_detail.get("reasons"):
            return "; ".join(str(r) for r in fail_detail["reasons"])[:300]
        err = fail_detail.get("Error") or fail_detail.get("errorType") or ""
        cause = fail_detail.get("Cause") or fail_detail.get("errorMessage") or fail_detail.get("reason") or ""
        if isinstance(cause, str) and cause.startswith("{"):
            try:
                cause = json.loads(cause).get("errorMessage", cause)
            except ValueError:
                pass
        return f"{err}: {cause}".strip(": ")[:300]
    return str(fail_detail)[:300]


def attempted_succeeded(r, percent):
    """Updates attempted and verified as fixed by the post-install rescan, for one host."""
    status = r.get("status")
    if status in PATCHED_STATES:
        attempted = _num(r.get("advisories_selected"))
        remaining = _num(r.get("selected_remaining"))
        return attempted, max(0, attempted - remaining)
    if status == "failed":
        before = _num(r.get("advisories_before"))
        if before <= 0:
            return 0, 0
        attempted = before if percent >= 100 else max(1, math.ceil(before * percent / 100))
        return attempted, 0  # nothing verified, so nothing counts as succeeded
    return 0, 0


# ------------------------------------------------------------------ cost
def estimate_cost(execution_arn, notify, client=None):
    """List-price estimate of this execution from its history so far."""
    out = {"transitions": 0, "lambda_invocations": 0, "lambda_seconds": 0.0, "lambda_gb_s": 0.0,
           "cost_sfn_usd": 0.0, "cost_lambda_usd": 0.0, "cost_other_usd": 0.0, "cost_usd": 0.0,
           "cost_note": "list price before free tier"}
    if not execution_arn:
        out["cost_note"] = "no execution ARN"
        return out
    try:
        if client is None:
            import boto3
            client = boto3.client("stepfunctions")
        events, token = [], None
        while True:
            kw = {"executionArn": execution_arn, "maxResults": 1000, "includeExecutionData": False}
            if token:
                kw["nextToken"] = token
            page = client.get_execution_history(**kw)
            events.extend(page.get("events", []))
            token = page.get("nextToken")
            if not token:
                break
    except Exception as e:  # cost is informative only, never fail the run for it
        out["cost_note"] = f"history unavailable: {type(e).__name__}"
        return out

    by_id = {e["id"]: e for e in events}
    transitions = sum(1 for e in events if e.get("type", "").endswith("StateEntered"))
    lambda_scheduled = {e["id"] for e in events if e.get("type") == "TaskScheduled"
                        and e.get("taskScheduledEventDetails", {}).get("resourceType") == "lambda"}
    started = {e["id"]: e for e in events if e.get("type") == "TaskStarted"
               and e.get("previousEventId") in lambda_scheduled}
    seconds = 0.0
    for e in events:
        if e.get("type") in ("TaskSucceeded", "TaskFailed", "TaskTimedOut") and e.get("previousEventId") in started:
            t0 = started[e["previousEventId"]]["timestamp"]
            t1 = e["timestamp"]
            if isinstance(t0, str):
                t0, t1 = _parse_ts(t0), _parse_ts(t1)
            seconds += max(0.0, (t1 - t0).total_seconds())
    # len(started) already includes this invocation (its TaskStarted is in the history).
    # It is still running, so add about 1 s at 128 MB for it.
    invocations = len(started)
    gb_s = seconds * PATCH_LAMBDA_MEMORY_MB / 1024 + 1.0 * 128 / 1024
    transitions += REMAINING_TRANSITIONS

    out.update({
        "transitions": transitions,
        "lambda_invocations": invocations,
        "lambda_seconds": round(seconds, 1),
        "lambda_gb_s": round(gb_s, 2),
        "cost_sfn_usd": transitions * PRICE_SFN_TRANSITION,
        "cost_lambda_usd": invocations * PRICE_LAMBDA_REQUEST + gb_s * PRICE_LAMBDA_GB_S,
        "cost_other_usd": (PRICE_SNS_PUBLISH + PRICE_SNS_EMAIL) if notify else 0.0,
    })
    out["cost_usd"] = out["cost_sfn_usd"] + out["cost_lambda_usd"] + out["cost_other_usd"]
    for k in ("cost_sfn_usd", "cost_lambda_usd", "cost_other_usd", "cost_usd"):
        out[k] = round(out[k], 6)
    return out


# ------------------------------------------------------------------ log records
def _emf(ts_ms, dims, metrics):
    return {"Timestamp": ts_ms, "CloudWatchMetrics": [
        {"Namespace": NAMESPACE, "Dimensions": [dims], "Metrics": metrics}]}


def host_records(report, ts_ms):
    mode = report.get("mode")
    percent = _num(report.get("percent"), 100)
    out = []
    for r in report.get("results") or []:
        attempted, succeeded = attempted_succeeded(r, percent)
        rec = {
            "record": "host",
            "run_id": report.get("run_id"),
            "mode": mode,
            "percent": percent,
            "host": r.get("host"),
            "platform": r.get("platform"),
            "workload": r.get("workload"),
            "unit": r.get("unit") or ("KB" if r.get("platform") == "windows" else "RHSA"),
            "status": r.get("status"),
            "before": r.get("advisories_before"),
            "after": r.get("advisories_after"),
            "attempted": attempted,
            "succeeded": succeeded,
            "duration_s": _num(r.get("duration_s")),
            "rebooted": r.get("rebooted"),
            "healthy": r.get("healthy_after") if "healthy_after" in r else r.get("healthy"),
            "failed_at": r.get("failed_at") or "",
            "reason": _reason(r.get("fail_detail")),
            "build_before": r.get("kernel_before") or r.get("kernel"),
            "build_after": r.get("kernel_after"),
        }
        # Updates closed per severity (missing before minus missing after the verified rescan).
        # Log fields only (no custom metrics), used by the "Fixed by severity" dashboard widget.
        if r.get("status") in PATCHED_STATES:
            before_sev = r.get("by_severity_before") or {}
            after_sev = r.get("by_severity_after") or {}
            for sev, field in (("Critical", "fixed_critical"), ("Important", "fixed_important"),
                               ("Moderate", "fixed_moderate"), ("Low", "fixed_low"), ("Unspecified", "fixed_unrated")):
                rec[field] = max(0, _num(before_sev.get(sev)) - _num(after_sev.get(sev)))
        if mode == "patch" and r.get("status") in PATCHED_STATES + ("failed",) and r.get("host") and r.get("platform"):
            metrics = [{"Name": "PatchesAttempted", "Unit": "Count"}, {"Name": "PatchesSucceeded", "Unit": "Count"}]
            rec["Platform"] = r["platform"]
            rec["Host"] = r["host"]
            rec["PatchesAttempted"] = attempted
            rec["PatchesSucceeded"] = succeeded
            if r.get("status") in PATCHED_STATES:  # time to a verified result; failures would distort it
                metrics.insert(0, {"Name": "HostPatchSeconds", "Unit": "Seconds"})
                rec["HostPatchSeconds"] = rec["duration_s"]
            rec["_aws"] = _emf(ts_ms, ["Platform", "Host"], metrics)
        out.append(rec)
    return out


def cycle_record(report, hosts, cost, execution_arn, ts_ms):
    done = [h for h in hosts if h["status"] in PATCHED_STATES]
    rec = {
        "record": "cycle",
        "run_id": report.get("run_id"),
        "mode": report.get("mode"),
        "percent": _num(report.get("percent"), 100),
        "started": report.get("started"),
        "finished": report.get("finished"),
        "duration_s": _num(report.get("duration_s")),
        "hosts_total": _num(report.get("hosts_total")),
        "patched": _num(report.get("patched")),
        "patched_partial": _num(report.get("patched_partial")),
        "compliant": _num(report.get("compliant")),
        "scanned": _num(report.get("scanned")),
        "skipped": _num(report.get("skipped")),
        "failed": _num(report.get("failed")),
        "avg_host_seconds": round(sum(h["duration_s"] for h in done) / len(done), 1) if done else None,
        "attempted": sum(h["attempted"] for h in hosts),
        "succeeded": sum(h["succeeded"] for h in hosts),
        "execution_arn": execution_arn,
        **cost,
    }
    if rec["mode"] == "patch" and rec["hosts_total"] > 0:
        rec["StateMachine"] = STATE_MACHINE
        rec["CycleSeconds"] = rec["duration_s"]
        rec["HostsFailed"] = rec["failed"]
        rec["EstimatedCostUSD"] = cost["cost_usd"]
        rec["_aws"] = _emf(ts_ms, ["StateMachine"], [
            {"Name": "CycleSeconds", "Unit": "Seconds"},
            {"Name": "HostsFailed", "Unit": "Count"},
            {"Name": "EstimatedCostUSD", "Unit": "None"},
        ])
    return rec


# ------------------------------------------------------------------ notification text
def verdict(report):
    mode = report.get("mode")
    total = _num(report.get("hosts_total"))
    if total == 0:
        return "NO TARGETS", "no running PatchTarget hosts found"
    if mode == "scan":
        return "SCANNED", f"{_num(report.get('scanned'))}/{total} hosts scanned"
    failed = _num(report.get("failed"))
    partial = _num(report.get("patched_partial"))
    patched = _num(report.get("patched"))
    compliant = _num(report.get("compliant"))
    if failed:
        return "FAILED", f"{failed} of {total} hosts failed"
    if partial:
        return "PARTIAL", f"{patched + compliant}/{total} hosts compliant, {partial} partial"
    if patched == 0 and compliant == total:
        return "COMPLIANT", f"{total}/{total} hosts already compliant"
    return "PATCHED", f"{patched + compliant}/{total} hosts compliant"


def host_lines(r, h):
    unit = h["unit"]
    status = h["status"]
    label = {"patched_partial": "PARTIAL"}.get(status, str(status).upper())
    lines = [f"{h['host']} ({h['platform']}, {h['workload']}): {label}"]
    if status in PATCHED_STATES:
        lines.append(f"  {unit} missing {h['before']} -> {h['after']}, verified {h['succeeded']}/{h['attempted']} applied"
                     + (f" ({h['percent']}% scope)" if h["percent"] < 100 else ""))
        detail = []
        if r.get("packages_upgraded") is not None:
            detail.append(f"{r.get('packages_upgraded')} packages upgraded" if unit == "RHSA"
                          else f"{r.get('packages_upgraded')} updates installed")
        detail.append("rebooted" if r.get("rebooted") else "no reboot")
        detail.append(("healthy" if h["healthy"] else "NOT healthy") +
                      (f" ({r.get('health_detail')})" if r.get("health_detail") else ""))
        detail.append(_dur(h["duration_s"]))
        lines.append("  " + ", ".join(detail))
        if h["build_before"] and h["build_after"] and h["build_before"] != h["build_after"]:
            lines.append(f"  {'kernel' if unit == 'RHSA' else 'build'} {h['build_before']} -> {h['build_after']}")
        if status == "patched_partial":
            sev = r.get("by_severity_after") or {}
            left = ", ".join(f"{k} {v}" for k, v in sev.items() if v)
            lines.append(f"  Still offered after the post-install rescan: {h['after']} {unit}"
                         + (f" ({left})" if left else "") + ". Run the cycle again to apply.")
        bad = [u for u in r.get("update_results") or [] if u.get("result") not in ("Succeeded", None)]
        for u in bad:
            lines.append(f"  {u.get('kb')}: {u.get('result')} {u.get('hresult', '')}".rstrip())
    elif status == "failed":
        lines.append(f"  failed at {h['failed_at'] or 'unknown step'} after {_dur(h['duration_s'])}")
        if h["reason"]:
            lines.append(f"  reason: {h['reason']}")
    elif status == "scanned":
        sev = r.get("by_severity_before") or {}
        left = ", ".join(f"{k} {v}" for k, v in sev.items() if v)
        lines.append(f"  {h['before']} {unit} missing" + (f" ({left})" if left else "")
                     + f", workload {'healthy' if h['healthy'] else 'NOT healthy'}")
    elif status == "compliant":
        lines.append(f"  0 {unit} missing, nothing to install")
    elif status == "skipped":
        lines.append(f"  skipped: {r.get('note', 'not patched')}")
    if r.get("defender_excluded"):
        lines.append(f"  Defender updates excluded by design: {', '.join(r['defender_excluded'])}")
    return lines


def cycle_message(report, hosts, cycle, execution_arn):
    word, short = verdict(report)
    subject = _subject(f"serverless-patch {report.get('mode', '')} run {word}: {short}, {_dur(report.get('duration_s'))}")
    body = [
        f"Patch cycle result: {word} ({short})",
        "",
        f"Run:      {report.get('run_id')}",
        f"Mode:     {report.get('mode')}" + (f", scope {cycle['percent']}%" if report.get("mode") == "patch" else ""),
        f"Started:  {_myt(report.get('started'))}",
        f"Duration: {_dur(report.get('duration_s'))}",
        f"Hosts:    {cycle['hosts_total']} total, {cycle['patched']} patched, {cycle['patched_partial']} partial, "
        f"{cycle['compliant']} compliant, {cycle['scanned']} scanned, {cycle['skipped']} skipped, {cycle['failed']} failed",
    ]
    if report.get("mode") == "patch" and cycle["attempted"]:
        pct = 100 * cycle["succeeded"] / cycle["attempted"]
        body.append(f"Verified: {cycle['succeeded']}/{cycle['attempted']} updates fixed ({pct:.1f}%), "
                    "checked by rescanning each host after install")
    body.append("")
    by_name = {r.get("host"): r for r in report.get("results") or []}
    for h in hosts:
        body.extend(host_lines(by_name.get(h["host"], {}), h))
        body.append("")
    body.append(f"Estimated serverless cost of this run: USD {cycle['cost_usd']:.4f} "
                f"({cycle['transitions']} state transitions, {cycle['lambda_invocations']} Lambda invocations, "
                f"{cycle['cost_note']})")
    body.append("Control plane only. No agent is installed on any host.")
    if execution_arn:
        body += ["", "Execution:", _console(execution_arn)]
    return subject, "\n".join(body)


def error_message(event):
    err = event.get("error") or {}
    name = err.get("Error") or "UnknownError"
    cause = err.get("Cause") or ""
    if isinstance(cause, str) and cause.startswith("{"):
        try:
            parsed = json.loads(cause)
            cause = parsed.get("errorMessage") or parsed.get("message") or cause
        except ValueError:
            pass
    state = event.get("failed_state") or "unknown state"
    subject = _subject(f"serverless-patch {event.get('mode', '')} run ERROR: {name} at {state}")
    body = [
        f"Patch cycle stopped before it could finish: {name}",
        "",
        f"Run:     {event.get('run_id')}",
        f"Mode:    {event.get('mode')}",
        f"Started: {_myt(event.get('started'))}",
        f"State:   {state}",
        f"Cause:   {str(cause)[:1500]}",
        "",
        "Host results are not available for this run. Check the execution graph,",
        "and confirm whether any host was changed before running again.",
    ]
    if event.get("execution_arn"):
        body += ["", "Execution:", _console(event["execution_arn"])]
    return subject, "\n".join(body)


# ------------------------------------------------------------------ handler
def lambda_handler(event, context=None, sfn_client=None):
    kind = event.get("kind", "cycle")
    execution_arn = event.get("execution_arn")
    notify = bool(event.get("notify", True))
    ts_ms = int(time.time() * 1000)

    if kind == "run_error":
        subject, message = error_message(event)
        print(json.dumps({"record": "run_error", "run_id": event.get("run_id"), "mode": event.get("mode"),
                          "failed_state": event.get("failed_state"), "error": (event.get("error") or {}).get("Error"),
                          "execution_arn": execution_arn}))
        return {"subject": subject, "message": message, "records": 1}

    report = event.get("report") or {}
    if event.get("self_test"):  # deploy check: format only, write no records or metrics
        hosts = host_records(report, ts_ms)
        cycle = cycle_record(report, hosts, estimate_cost(None, notify), None, ts_ms)
        subject, message = cycle_message(report, hosts, cycle, None)
        return {"subject": subject, "message": message, "records": 0, "self_test": True}
    hosts = host_records(report, ts_ms)
    cost = estimate_cost(execution_arn, notify, sfn_client)
    cycle = cycle_record(report, hosts, cost, execution_arn, ts_ms)
    for rec in hosts + [cycle]:
        print(json.dumps(rec, default=str))
    subject, message = cycle_message(report, hosts, cycle, execution_arn)
    return {"subject": subject, "message": message, "records": len(hosts) + 1,
            "cost_usd": cycle["cost_usd"], "attempted": cycle["attempted"], "succeeded": cycle["succeeded"]}
