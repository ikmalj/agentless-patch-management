"""serverless-patch-rhel: agentless RHEL patch actions over SSH (Iteration 1).

Called by the serverless-patch-cycle state machine, one action per call:
  precheck        readiness: sudo, dnf idle, disk space, workload healthy
  scan            RHSA advisories by severity + dnf check-update --security
  install_start   start `dnf -y upgrade --security` on the host as a transient systemd unit
                  (with "percent" < 100: only that share of RHSA, highest severity first,
                  via `dnf -y upgrade --advisory=...`)
                  and return at once, so Lambda never waits on dnf (15 min limit)
  install_status  poll that unit; when done, report counts and reboot need
  reboot          schedule a reboot 5 s out and return the current boot ID
  health          post-patch check; raises so Step Functions can retry

Event: {"action": "...",
        "host": {"ip": "10.0.1.175", "name": "...", "workload": "nginx|mysql"},
        "run_id": "...", "refresh": bool, "strict": bool, "boot_id_before": "..."}

Exception class names below are matched by Retry/Catch in the state machine.
Nothing is installed on the host. The only files written are the dnf log and
exit code under /var/log/serverless-patch.
"""
import io
import json
import math
import os
import re
import time
from datetime import datetime, timezone

import boto3
import paramiko
from botocore.config import Config

SECRET_ID = os.environ["SECRET_ID"]
MIN_DISK_FREE_MB = int(os.environ.get("MIN_DISK_FREE_MB", "1024"))
INSTALL_CMD = os.environ.get("INSTALL_CMD", "dnf -y upgrade --security")  # security advisories only
LOG_DIR = "/var/log/serverless-patch"

_sm = boto3.client(
    "secretsmanager",
    config=Config(connect_timeout=5, read_timeout=10, retries={"max_attempts": 2}),
)
_cache = {}


class HostUnreachable(Exception):
    """SSH could not connect: host down, rebooting or network blocked."""


class AuthFailed(Exception):
    """SSH reached the host but the key was rejected."""


class RebootPending(Exception):
    """Host answers but still has the pre-reboot boot ID."""


class WorkloadNotHealthy(Exception):
    """Host is up but its workload check fails."""


class CommandFailed(Exception):
    """A remote command failed or timed out."""


class InvalidRequest(Exception):
    """The event is missing a required field."""


# ---------------------------------------------------------------- helpers

def _secret():
    if "v" not in _cache:
        raw = _sm.get_secret_value(SecretId=SECRET_ID)["SecretString"]
        _cache["v"] = json.loads(raw)
    return _cache["v"]


def _host(ev):
    h = ev.get("host")
    if isinstance(h, str):
        h = {"ip": h}
    if not isinstance(h, dict) or not h.get("ip"):
        raise InvalidRequest("host.ip is required")
    return h


def _rid(ev):
    # run_id ends up in unit names and file paths, so only safe characters pass.
    rid = re.sub(r"[^A-Za-z0-9_-]", "-", str(ev.get("run_id") or ""))[:64]
    if not rid:
        raise InvalidRequest("run_id is required")
    return rid


def _connect(ip):
    s = _secret()
    key = paramiko.RSAKey.from_private_key(io.StringIO(s["private_key"]))
    c = paramiko.SSHClient()
    # Lab limitation: host keys are not pinned (cloud-init regenerates them on relaunch).
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        # Generous handshake limits: a host busy installing packages can take tens of
        # seconds to answer SSH (seen in the first full run, 27 Oct 2026).
        c.connect(ip, username=s["username"], pkey=key, timeout=20,
                  banner_timeout=60, auth_timeout=30,
                  look_for_keys=False, allow_agent=False)
    except paramiko.AuthenticationException as e:
        c.close()
        raise AuthFailed(f"{ip}: {e}") from None
    except (OSError, EOFError, paramiko.SSHException) as e:
        c.close()
        raise HostUnreachable(f"{ip}: {type(e).__name__}: {e}") from None
    return c


def _run(c, cmd, timeout=60):
    """Run one command. Reads stdout and stderr together so neither buffer can block."""
    chan = c.get_transport().open_session()
    chan.exec_command(cmd)
    out, err = bytearray(), bytearray()
    deadline = time.monotonic() + timeout
    while True:
        busy = False
        while chan.recv_ready():
            out += chan.recv(65536)
            busy = True
        while chan.recv_stderr_ready():
            err += chan.recv_stderr(65536)
            busy = True
        if chan.exit_status_ready() and not chan.recv_ready() and not chan.recv_stderr_ready():
            break
        if time.monotonic() > deadline:
            chan.close()
            raise CommandFailed(f"remote command timed out after {timeout}s: {cmd.strip()[:80]}")
        if not busy:
            time.sleep(0.05)
    rc = chan.recv_exit_status()
    chan.close()
    return rc, out.decode(errors="replace"), err.decode(errors="replace")


def _kv(text):
    d = {}
    for line in text.splitlines():
        k, sep, v = line.partition("=")
        if sep:
            d[k.strip()] = v.strip()
    return d


def _workload_health(c, workload):
    """Same checks as the testbed record: HTTP 200 + OK, or sakila.film = 1000."""
    if workload == "nginx":
        svc = "nginx"
        _, out, _ = _run(c, "curl -s -m 5 -w '|%{http_code}' http://localhost/health.html", 15)
        body, _, code = out.rpartition("|")
        app_ok = code.strip() == "200" and "OK" in body
        detail = f"http {code.strip() or 'none'}"
    elif workload == "mysql":
        svc = "mysqld"
        rc, out, _ = _run(c, "sudo -n mysql -N -B -e 'SELECT COUNT(*) FROM sakila.film;'", 20)
        app_ok = rc == 0 and out.strip() == "1000"
        detail = f"sakila.film rows {out.strip() or 'none'}"
    else:
        return {"healthy": True, "service": None, "service_state": None,
                "detail": "no workload check defined"}
    _, state, _ = _run(c, f"systemctl is-active {svc}", 10)
    state = state.strip()
    return {"healthy": state == "active" and app_ok, "service": svc,
            "service_state": state, "detail": detail}


# ---------------------------------------------------------------- actions

PRECHECK_SCRIPT = r"""
. /etc/os-release
echo "os=$PRETTY_NAME"
echo "kernel=$(uname -r)"
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
echo "uptime_s=$(cut -d. -f1 /proc/uptime)"
echo "disk_free_mb=$(df -Pm / | awk 'NR==2{print $4}')"
if pgrep -x dnf >/dev/null || pgrep -x dnf-automatic >/dev/null; then echo dnf_busy=1; else echo dnf_busy=0; fi
if sudo -n true 2>/dev/null; then echo sudo=1; else echo sudo=0; fi
if rpm -q amazon-ssm-agent >/dev/null 2>&1; then echo ssm_agent=1; else echo ssm_agent=0; fi
"""


def act_precheck(c, ev):
    _, out, _ = _run(c, PRECHECK_SCRIPT, 30)
    f = _kv(out)
    health = _workload_health(c, _host(ev).get("workload"))
    disk = int(f.get("disk_free_mb") or 0)
    reasons = []
    if f.get("sudo") != "1":
        reasons.append("passwordless sudo unavailable")
    if f.get("dnf_busy") != "0":
        reasons.append("another dnf process is running")
    if disk < MIN_DISK_FREE_MB:
        reasons.append(f"only {disk} MB free on / (need {MIN_DISK_FREE_MB})")
    if not health["healthy"]:
        reasons.append(f"workload unhealthy before patching: {health['detail']}")
    return {"ready": not reasons, "reasons": reasons, "os": f.get("os"),
            "kernel": f.get("kernel"), "boot_id": f.get("boot_id"),
            "uptime_s": int(f.get("uptime_s") or 0), "disk_free_mb": disk,
            "agent_present": f.get("ssm_agent") == "1", "health": health}


ADVISORY_RE = re.compile(r"^(RHSA-\d{4}:\d+)\s+(\S+)/Sec\.\s+(\S+)$")
SEVERITIES = ("Critical", "Important", "Moderate", "Low")


SEV_RANK = {"Critical": 0, "Important": 1, "Moderate": 2, "Low": 3}


def _security_advisories(c, flags=""):
    """Return ({advisory_id: severity}, {package names in those advisories}, unparsed_lines).

    The package names are what the install step will touch: each advisory line names
    the fixed package build, e.g. openssl-1:3.0.7-16.el9_2.x86_64 -> openssl.
    """
    rc, out, err = _run(c, f"sudo -n dnf -q {flags}updateinfo list --security", 240)
    if rc != 0:
        raise CommandFailed(f"dnf updateinfo exit {rc}: {err.strip()[-500:]}")
    advisories, names, unparsed = {}, set(), 0
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        m = ADVISORY_RE.match(line)
        if m:
            advisories.setdefault(m.group(1), m.group(2))
            names.add(m.group(3).rsplit("-", 2)[0])
        else:
            unparsed += 1
    return advisories, names, unparsed


def _select(advisories, percent):
    """Highest severity first (NIST SP 800-40 risk-based priority), then oldest ID."""
    ordered = sorted(advisories, key=lambda a: (SEV_RANK.get(advisories[a], 9), a))
    n = max(1, math.ceil(len(ordered) * percent / 100))
    return ordered[:n]


def act_scan(c, ev):
    t = time.time()
    refresh = "--refresh " if ev.get("refresh") else ""

    # 1. Security advisories (the RHEL counting unit for Experiment 2).
    advisories, sec_pkgs, unparsed = _security_advisories(c, refresh)
    by_sev = {s: 0 for s in SEVERITIES}
    for sev in advisories.values():
        key = sev if sev in by_sev else "Unknown"
        by_sev[key] = by_sev.get(key, 0) + 1

    # Partial runs: how many of the advisories chosen for install are still missing.
    check = ev.get("check_ids") or []
    check = [check] if isinstance(check, str) else [a for a in check if isinstance(a, str)]
    still = sorted(set(check) & set(advisories))

    # 2. dnf check-update --security (scan command): exit 100 = security updates available.
    rc_cu, _, err = _run(c, "sudo -n dnf -q -C check-update --security >/dev/null", 120)
    if rc_cu not in (0, 100):
        raise CommandFailed(f"dnf check-update exit {rc_cu}: {err.strip()[-500:]}")

    # 3. Package counts. Security packages come from the open advisories above (what the
    #    install step will touch). `repoquery --upgrades --security` is NOT used: it also
    #    lists packages whose installed version is already fixed (seen 27 Oct 2026).
    #    All pending packages (bug fix, enhancement, non-advisory) are context only.
    rc, out, err = _run(c, "sudo -n dnf -q -C repoquery --upgrades --qf '%{name}.%{arch}'", 120)
    if rc != 0:
        raise CommandFailed(f"dnf repoquery exit {rc}: {err.strip()[-500:]}")
    all_pkgs = {p.strip() for p in out.splitlines() if p.strip()}

    # Full lists go to CloudWatch Logs as evidence; the state machine keeps counts only.
    print(json.dumps({"scan_advisory_ids": sorted(advisories),
                      "scan_security_packages": sorted(sec_pkgs)}))
    return {"advisories": len(advisories), "by_severity": by_sev,
            "updates_available": rc_cu == 100,
            "pending_security_packages": len(sec_pkgs),
            "pending_packages": len(all_pkgs),
            "unparsed_lines": unparsed, "refreshed": bool(refresh),
            **({"checked": len(check), "checked_remaining": len(still),
                "checked_remaining_ids": still[:50]} if check else {}),
            "scan_s": round(time.time() - t, 1)}


def act_install_start(c, ev):
    rid = _rid(ev)
    unit, log, rcf = f"sp-{rid}", f"{LOG_DIR}/{rid}.log", f"{LOG_DIR}/{rid}.rc"
    sel_file = f"{LOG_DIR}/{rid}.advisories"
    percent = float(ev.get("percent") or 100)
    if not 0 < percent <= 100:
        raise InvalidRequest("percent must be between 1 and 100")

    # Idempotent: a retried call never starts a second dnf run, and returns the
    # advisory selection that the first call saved on the host.
    _, out, _ = _run(c, f"""
if sudo -n test -f {rcf}; then echo state=already_done
elif systemctl is-active --quiet {unit}; then echo state=already_running
else echo state=new; fi
""", 20)
    state = _kv(out).get("state")
    selected, total = [], None
    if state != "new":
        _, saved, _ = _run(c, f"sudo -n cat {sel_file} 2>/dev/null || true", 15)
        selected = [a for a in saved.split() if a != "ALL"]
        return {"state": state, "unit": unit, "log": log, "percent": percent,
                "selected": len(selected) or None, "selected_ids": selected}

    cmd = INSTALL_CMD
    if percent < 100:
        advisories, _, _ = _security_advisories(c, "-C ")
        total = len(advisories)
        selected = _select(advisories, percent) if advisories else []
        if selected:
            cmd = "dnf -y upgrade " + " ".join(f"--advisory={a}" for a in selected)

    # The exit code is written to a file, so the result survives the unit being cleaned up.
    script = f"""
sudo -n mkdir -p {LOG_DIR}
printf '%s\\n' {" ".join(selected) or "ALL"} | sudo -n tee {sel_file} >/dev/null
if sudo -n systemd-run --unit={unit} --description="serverless-patch install {rid}" -p Nice=10 -p IOSchedulingClass=best-effort -p IOSchedulingPriority=7 /bin/bash -c '{cmd} > {log} 2>&1; echo $? > {rcf}' >/dev/null 2>&1; then echo state=started; else echo state=start_failed; fi
"""
    _, out, err = _run(c, script, 30)
    state = _kv(out).get("state")
    if state != "started":
        raise CommandFailed(f"could not start install unit: {err.strip()[-500:]}")
    return {"state": state, "unit": unit, "log": log, "command": cmd if len(cmd) < 300 else cmd[:300] + "...",
            "percent": percent, "advisories_total": total,
            "selected": len(selected) if percent < 100 else None, "selected_ids": selected}


def act_install_status(c, ev):
    rid = _rid(ev)
    unit, log, rcf = f"sp-{rid}", f"{LOG_DIR}/{rid}.log", f"{LOG_DIR}/{rid}.rc"
    _, out, _ = _run(c, f"""
if sudo -n test -f {rcf}; then echo rc=$(sudo -n cat {rcf})
elif systemctl is-active --quiet {unit}; then echo running=1
else echo lost=1; fi
echo log_lines=$(sudo -n wc -l < {log} 2>/dev/null || echo 0)
""", 20)
    f = _kv(out)
    base = {"unit": unit, "log": log, "log_lines": int(f.get("log_lines") or 0)}

    if "running" in f:
        return {"state": "running", "reboot_required": False, **base}
    if "lost" in f:
        return {"state": "failed", "reboot_required": False,
                "reason": "install unit not running and no exit code recorded", **base}

    rc = int(f.get("rc") or -1)
    if rc != 0:
        _, tail, _ = _run(c, f"sudo -n tail -n 20 {log}", 15)
        return {"state": "failed", "rc": rc, "reboot_required": False,
                "log_tail": tail.splitlines(), **base}

    # Succeeded: read the transaction summary and decide on reboot (Red Hat needs-restarting -r).
    _, summary, _ = _run(c, f"sudo -n grep -E '^(Upgrade|Install|Remove) +[0-9]+ Package' {log}", 15)
    counts = {m.group(1).lower(): int(m.group(2))
              for m in re.finditer(r"^(Upgrade|Install|Remove)\s+(\d+)\s+Package", summary, re.M)}
    _, nr, _ = _run(c, "sudo -n dnf -q needs-restarting -r 2>&1", 60)
    _, k, _ = _run(c, "echo running=$(uname -r); "
                      "echo newest=$(rpm -q --last kernel-core | head -1 | awk '{print $1}')", 15)
    k = _kv(k)
    kernel_pending = bool(k.get("newest")) and not k["newest"].endswith(k.get("running", "?"))
    if "Reboot is required" in nr:
        reboot, why = True, "needs-restarting: core libraries or services updated"
    elif "should not be necessary" in nr:
        reboot, why = kernel_pending, "needs-restarting: not necessary"
    else:
        reboot, why = kernel_pending, "needs-restarting unavailable, compared kernels"
    return {"state": "succeeded", "rc": 0,
            "packages_upgraded": counts.get("upgrade", 0),
            "packages_installed": counts.get("install", 0),
            "packages_removed": counts.get("remove", 0),
            "reboot_required": reboot, "reboot_reason": why,
            "kernel_running": k.get("running"), "kernel_newest": k.get("newest"), **base}


def act_reboot(c, ev):
    rid = _rid(ev)
    # Delayed reboot so this SSH session closes cleanly before the host goes down.
    _, out, _ = _run(c, f"""
echo boot_id=$(cat /proc/sys/kernel/random/boot_id)
if sudo -n systemd-run --on-active=5 --unit=sp-reboot-{rid} /usr/bin/systemctl reboot >/dev/null 2>&1; then echo scheduled=1; else echo scheduled=0; fi
""", 20)
    f = _kv(out)
    if f.get("scheduled") != "1":
        raise CommandFailed("could not schedule reboot")
    return {"boot_id_before": f.get("boot_id"), "scheduled": True}


def act_health(c, ev):
    _, out, _ = _run(c, "echo boot_id=$(cat /proc/sys/kernel/random/boot_id); "
                        "echo kernel=$(uname -r); echo uptime_s=$(cut -d. -f1 /proc/uptime)", 15)
    f = _kv(out)
    before = ev.get("boot_id_before")
    if before and f.get("boot_id") == before:
        raise RebootPending("host still has its pre-reboot boot ID")
    h = _workload_health(c, _host(ev).get("workload"))
    if ev.get("strict") and not h["healthy"]:
        raise WorkloadNotHealthy(json.dumps(h))
    return {"kernel": f.get("kernel"), "boot_id": f.get("boot_id"),
            "uptime_s": int(f.get("uptime_s") or 0),
            "rebooted": bool(before), **h}


ACTIONS = {
    "precheck": act_precheck,
    "scan": act_scan,
    "install_start": act_install_start,
    "install_status": act_install_status,
    "reboot": act_reboot,
    "health": act_health,
}


def lambda_handler(event, context):
    action = event.get("action")
    if action not in ACTIONS:
        raise InvalidRequest(f"unknown action {action!r}")
    host = _host(event)
    t0 = time.time()
    c = _connect(host["ip"])
    try:
        result = ACTIONS[action](c, event)
    finally:
        c.close()
    result.update({
        "action": action,
        "host": host.get("name") or host["ip"],
        "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "duration_ms": round((time.time() - t0) * 1000),
    })
    print(json.dumps(result))
    return result
