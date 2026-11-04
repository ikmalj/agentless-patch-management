"""serverless-patch-windows: agentless Windows patch actions over WinRM (Iteration 2).

Same actions as the RHEL function, so the state machine treats both platforms alike:
  precheck        readiness: elevation, disk, Windows Update service, no run in progress,
                  IIS healthy, SSM agent absent
  scan            Windows Update search (built-in Microsoft.Update.Session API). Countable
                  updates = all software updates except Microsoft Defender (decided 25 Oct 2026)
  install_start   write a small worker script and run it once as SYSTEM through a scheduled
                  task (the update API refuses download/install from remote WinRM sessions),
                  then return at once
  install_status  read the worker's status file; when done, remove the task and the script
  reboot          schedule a restart 10 s out and return the current boot time
  health          post-patch check; raises so Step Functions can retry

Nothing is installed on the host: the task and worker script exist only for one run.
Status and log files stay in C:\\ProgramData\\serverless-patch as evidence.

Event: {"action": "...", "host": {"ip": "10.0.1.189", "name": "...", "workload": "iis"},
        "run_id": "...", "percent": 100, "strict": bool, "boot_id_before": "...",
        "check_ids": ["KB..."]}
"""
import base64
import json
import math
import os
import re
import time
from datetime import datetime, timezone

import boto3
import requests
import urllib3
import winrm
from botocore.config import Config
from winrm.exceptions import InvalidCredentialsError, WinRMError, WinRMOperationTimeoutError, WinRMTransportError

# Lab limitation: the WinRM listener uses a self-signed certificate (verification skipped).
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

SECRET_ID = os.environ["SECRET_ID"]
MIN_DISK_FREE_MB = int(os.environ.get("MIN_DISK_FREE_MB", "5120"))
# Follow-up passes wait until Windows servicing has settled after the cumulative-update reboot.
# Found 1 Nov 2026: a WinRE update (KB5131594) installed ~4 min after that reboot reported Succeeded
# but was still offered; the same update installed 1-5 h later took effect every time.
SETTLE_MIN_UPTIME_S = int(os.environ.get("SETTLE_MIN_UPTIME_S", "900"))
DATA_DIR = r"C:\ProgramData\serverless-patch"
TASK_PATH = "\\serverless-patch\\"
DEFENDER_KBS = ("KB2267602", "KB4052623")          # definitions, platform
SEVERITIES = ("Critical", "Important", "Moderate", "Low", "Unspecified")
SEV_RANK = {"Critical": 0, "Important": 1, "Moderate": 2, "Low": 3}

_sm = boto3.client(
    "secretsmanager",
    config=Config(connect_timeout=5, read_timeout=10, retries={"max_attempts": 2}),
)
_cache = {}


class HostUnreachable(Exception):
    """WinRM could not connect: host down, rebooting or too busy to answer."""


class AuthFailed(Exception):
    """WinRM reached the host but the credentials were rejected."""


class RebootPending(Exception):
    """Host answers but still has the pre-reboot boot time."""


class WorkloadNotHealthy(Exception):
    """Host is up but its workload check fails."""


class UpdateServiceBusy(Exception):
    """Windows Update refused the call for a passing reason (service restarting after a reboot).
    Step Functions retries this one with a longer wait."""


# Windows Update / COM results that mean "try again shortly", not "this host is broken".
# 0x8024001E WU_E_SERVICE_STOP: the service or system was being shut down (seen 30 Oct 2026 on
# the rescan right after the post-CU reboot). 0x800706BA / 0x800706BE: the RPC server behind the
# COM object went away mid-call, which happens when wuauserv restarts.
TRANSIENT_WU = ("0x8024001E", "0x800706BA", "0x800706BE")


class ServicingBusy(Exception):
    """Windows servicing has not settled yet (recent boot, TrustedInstaller/TiWorker active or
    operations pending). Step Functions waits and asks again before a follow-up pass."""


class CommandFailed(Exception):
    """A remote command failed."""


class InvalidRequest(Exception):
    """The event is missing a required field."""


# ---------------------------------------------------------------- helpers

def _secret():
    if "v" not in _cache:
        _cache["v"] = json.loads(_sm.get_secret_value(SecretId=SECRET_ID)["SecretString"])
    return _cache["v"]


def _host(ev):
    h = ev.get("host")
    if isinstance(h, str):
        h = {"ip": h}
    if not isinstance(h, dict) or not h.get("ip"):
        raise InvalidRequest("host.ip is required")
    return h


def _rid(ev):
    rid = re.sub(r"[^A-Za-z0-9_-]", "-", str(ev.get("run_id") or ""))[:64]
    if not rid:
        raise InvalidRequest("run_id is required")
    return rid


def _session(ip):
    s = _secret()
    # Short per-request timeouts; pywinrm keeps polling long-running commands, so a slow
    # update search still completes, while a host that is down fails fast.
    return winrm.Session(f"https://{ip}:5986/wsman", auth=(s["username"], s["password"]),
                         transport="ntlm", server_cert_validation="ignore",
                         operation_timeout_sec=20, read_timeout_sec=30)


PS_PREAMBLE = "$ProgressPreference='SilentlyContinue'\n$ErrorActionPreference='Stop'\ntry {\n"
PS_TRAILER = ("\n} catch {\n  [ordered]@{ __error = $_.Exception.Message; "
              "__hresult = ('0x{0:X8}' -f $_.Exception.HResult) } | ConvertTo-Json -Compress\n}\n")


# pywinrm sends `powershell -encodedcommand <base64 of UTF-16 script>` through the WinRM
# cmd shell, whose command line is capped at 8191 characters (found 28 Oct 2026).
MAX_ENCODED = 7800


def _ps(sess, body):
    """Run PowerShell; the body must end by writing one JSON line. Returns the parsed object."""
    script = PS_PREAMBLE + body + PS_TRAILER
    encoded_len = len(base64.b64encode(script.encode("utf-16-le")))
    if encoded_len > MAX_ENCODED:
        raise CommandFailed(f"internal: PowerShell snippet too long for WinRM ({encoded_len} > {MAX_ENCODED})")
    try:
        r = sess.run_ps(script)
    except InvalidCredentialsError as e:
        raise AuthFailed(str(e)) from None
    except (requests.exceptions.RequestException, WinRMTransportError, WinRMOperationTimeoutError) as e:
        # WinRMOperationTimeoutError: the WinRM service accepted the connection but did not open a shell
        # within operation_timeout_sec (seen 31 Oct 2026 right after the post-CU reboot, while Windows was
        # still finishing servicing work). Same handling as an unreachable host: Step Functions waits and retries.
        raise HostUnreachable(f"{type(e).__name__}: {str(e) or 'WinRM operation timed out'}") from None
    except WinRMError as e:
        raise CommandFailed(f"{type(e).__name__}: {e}") from None
    out = r.std_out.decode("utf-8", errors="replace").strip().splitlines()
    line = next((l for l in reversed(out) if l.strip().startswith("{")), None)
    if line is None:
        err = r.std_err.decode("utf-8", errors="replace")
        raise CommandFailed(f"no JSON output (exit {r.status_code}): {err[-400:]}")
    data = json.loads(line)
    if isinstance(data, dict) and "__error" in data:
        msg = f"{data['__error']} ({data.get('__hresult')})"
        if any(code.lower() in msg.lower() for code in TRANSIENT_WU):
            raise UpdateServiceBusy(msg)
        raise CommandFailed(msg)
    return data


def _q(s):
    """PowerShell single-quoted literal."""
    return "'" + str(s).replace("'", "''") + "'"


# ---------------------------------------------------------------- remote snippets

HEALTH_PS = r"""
$os = Get-CimInstance Win32_OperatingSystem
$ubr = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR
$w3 = Get-Service W3SVC -ErrorAction SilentlyContinue
$code = 0; $ok = $false
try {
  $r = Invoke-WebRequest 'http://localhost/health.html' -UseBasicParsing -TimeoutSec 10
  $code = [int]$r.StatusCode; $ok = ($code -eq 200 -and $r.Content -match 'OK')
} catch { }
$pend = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
"""

PRECHECK_PS = HEALTH_PS + r"""
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$busy = @(Get-ScheduledTask -TaskPath '\serverless-patch\' -ErrorAction SilentlyContinue | Where-Object State -eq 'Running').Count -gt 0
[ordered]@{
  os = $os.Caption; build = "$($os.Version).$ubr"
  boot_id = $os.LastBootUpTime.ToUniversalTime().ToString('o')
  uptime_s = [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds
  disk_free_mb = [int]($disk.FreeSpace / 1MB); user = $id.Name; elevated = $admin; busy = $busy
  ssm_agent = [bool](Get-Service AmazonSSMAgent -ErrorAction SilentlyContinue)
  wu_start = [string](Get-Service wuauserv).StartType
  w3svc = [string]$w3.Status; http = $code; app_ok = $ok; reboot_pending = $pend
} | ConvertTo-Json -Compress
"""

HEALTH_OUT_PS = HEALTH_PS + r"""
[ordered]@{
  build = "$($os.Version).$ubr"; boot_id = $os.LastBootUpTime.ToUniversalTime().ToString('o')
  uptime_s = [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds
  w3svc = [string]$w3.Status; http = $code; app_ok = $ok; reboot_pending = $pend
} | ConvertTo-Json -Compress
"""

SERVICING_PS = r"""
$os = Get-CimInstance Win32_OperatingSystem
$ti = Get-Service TrustedInstaller -ErrorAction SilentlyContinue
$tiw = @(Get-Process TiWorker -ErrorAction SilentlyContinue).Count
$cbs = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
[ordered]@{
  boot_id = $os.LastBootUpTime.ToUniversalTime().ToString('o')
  uptime_s = [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds
  trustedinstaller = [string]$ti.Status
  tiworker = $tiw
  cbs_reboot_pending = (Test-Path "$cbs\RebootPending")
  cbs_packages_pending = (Test-Path "$cbs\PackagesPending")
  pending_xml = (Test-Path "$env:windir\WinSxS\pending.xml")
  wu_reboot_required = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
} | ConvertTo-Json -Compress
"""

SCAN_PS = r"""
$s = New-Object -ComObject Microsoft.Update.Session
$s.ClientApplicationID = 'serverless-patch'
$r = $s.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Software' and IsHidden=0")
$found = foreach ($u in $r.Updates) {
  $kb = if ($u.KBArticleIDs.Count -gt 0) { 'KB' + $u.KBArticleIDs.Item(0) } else { $u.Identity.UpdateID }
  [ordered]@{ kb = $kb; title = $u.Title; severity = [string]$u.MsrcSeverity }
}
$mp = $null
try { $m = Get-MpComputerStatus; $mp = [ordered]@{ platform = $m.AMProductVersion; engine = $m.AMEngineVersion; definitions = $m.AntivirusSignatureVersion } } catch { }
[ordered]@{ found = @($found); defender = $mp } | ConvertTo-Json -Compress -Depth 4
"""

# Runs as SYSTEM through a one-shot scheduled task. Writes progress to <run>.status.json.
WORKER_PS = r"""param([string]$RunId, [string]$Mode = 'install', [double]$Percent = 100, [string]$Kbs = '')
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$dir = 'C:\ProgramData\serverless-patch'
$statusFile = Join-Path $dir "$RunId.status.json"; $logFile = Join-Path $dir "$RunId.log"
$st = [ordered]@{ run_id = $RunId; mode = $Mode; state = 'starting'; started = (Get-Date).ToUniversalTime().ToString('o') }
function Save { $st.updated = (Get-Date).ToUniversalTime().ToString('o'); ($st | ConvertTo-Json -Compress -Depth 5) | Set-Content -Path $statusFile -Encoding UTF8 }
function Log($m) { Add-Content -Path $logFile -Value ("{0:u} {1}" -f (Get-Date).ToUniversalTime(), $m) }
function Id($u) { if ($u.KBArticleIDs.Count -gt 0) { 'KB' + $u.KBArticleIDs.Item(0) } else { $u.Identity.UpdateID } }
function IsDefender($u) { $k = Id $u; ($k -in 'KB2267602','KB4052623') -or ($u.Title -match 'Defender') }
function Brief($u) { [ordered]@{ kb = (Id $u); title = $u.Title; severity = [string]$u.MsrcSeverity } }
$rank = @{ Critical = 0; Important = 1; Moderate = 2; Low = 3 }
try {
  $st.state = 'searching'; Save; Log "search ($Mode, $Percent%, '$Kbs')"
  $session = New-Object -ComObject Microsoft.Update.Session
  $session.ClientApplicationID = 'serverless-patch'
  $found = $session.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Software' and IsHidden=0")
  $all = @(); foreach ($u in $found.Updates) { $all += $u }
  $st.found = @($all | ForEach-Object { Brief $_ }); Log "found $($all.Count)"
  if ($Mode -eq 'scan') { $st.state = 'done'; Save; return }
  $countable = @($all | Where-Object { -not (IsDefender $_) })
  if ($Kbs) { $want = $Kbs.Split(','); $sel = @($countable | Where-Object { (Id $_) -in $want }) }
  else {
    $ordered = @($countable | Sort-Object @{ e = { $s = [string]$_.MsrcSeverity; if ($rank.ContainsKey($s)) { $rank[$s] } else { 4 } } }, @{ e = { Id $_ } })
    $n = if ($Percent -ge 100) { $ordered.Count } else { [math]::Max(1, [math]::Ceiling($ordered.Count * $Percent / 100)) }
    $sel = @($ordered | Select-Object -First $n)
  }
  $st.selected = @($sel | ForEach-Object { Brief $_ })
  if ($sel.Count -eq 0) { $st.rc = 2; $st.reboot_required = $false; $st.results = @(); $st.state = 'done'; Save; Log 'nothing to install'; return }
  $coll = New-Object -ComObject Microsoft.Update.UpdateColl
  foreach ($u in $sel) { if (-not $u.EulaAccepted) { $u.AcceptEula() }; [void]$coll.Add($u) }
  $st.state = 'downloading'; Save; Log "download $($coll.Count)"
  $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll; $st.download_rc = [int]$dl.Download().ResultCode
  $st.state = 'installing'; Save; Log "install (download rc $($st.download_rc))"
  $inst = $session.CreateUpdateInstaller(); $inst.Updates = $coll
  try { $inst.ForceQuiet = $true } catch { }
  $ires = $inst.Install()
  $names = @{ 0 = 'NotStarted'; 1 = 'InProgress'; 2 = 'Succeeded'; 3 = 'SucceededWithErrors'; 4 = 'Failed'; 5 = 'Aborted' }
  $res = @(); for ($i = 0; $i -lt $coll.Count; $i++) { $r = $ires.GetUpdateResult($i); $res += [ordered]@{ kb = (Id $coll.Item($i)); result = $names[[int]$r.ResultCode]; hresult = ('0x{0:X8}' -f $r.HResult) } }
  $st.results = $res; $st.rc = [int]$ires.ResultCode; $st.reboot_required = [bool]$ires.RebootRequired
  $st.state = 'done'; Save; Log "install rc $($st.rc) reboot $($st.reboot_required)"
} catch {
  $st.state = 'failed'; $st.error = $_.Exception.Message; $st.hresult = ('0x{0:X8}' -f $_.Exception.HResult); Save; Log "failed: $($st.error)"
}
"""


def _write_remote_file(sess, path, data, chunk=1200):
    """Write bytes to a file on the host in pieces small enough for the WinRM command line."""
    _ps(sess, f"""
New-Item -ItemType Directory -Force -Path {_q(DATA_DIR)} | Out-Null
[IO.File]::WriteAllBytes({_q(path)}, [byte[]]@())
[ordered]@{{ created = $true }} | ConvertTo-Json -Compress
""")
    for i in range(0, len(data), chunk):
        piece = base64.b64encode(data[i:i + chunk]).decode()
        _ps(sess, f"""
$b = [Convert]::FromBase64String({_q(piece)})
$f = [IO.File]::Open({_q(path)}, [IO.FileMode]::Append, [IO.FileAccess]::Write)
try {{ $f.Write($b, 0, $b.Length) }} finally {{ $f.Close() }}
[ordered]@{{ size = (Get-Item {_q(path)}).Length }} | ConvertTo-Json -Compress
""")
    d = _ps(sess, f"""
$h = (Get-FileHash -Algorithm SHA256 -Path {_q(path)}).Hash
[ordered]@{{ size = (Get-Item {_q(path)}).Length; sha256 = $h }} | ConvertTo-Json -Compress
""")
    import hashlib
    want = hashlib.sha256(data).hexdigest().upper()
    if d.get("sha256") != want:
        raise CommandFailed(f"worker script upload mismatch ({d.get('size')} bytes, {d.get('sha256')} != {want})")


def _start_worker(sess, rid, mode, percent=100, kbs=""):
    """Write the worker script and run it once as SYSTEM via a scheduled task."""
    _write_remote_file(sess, DATA_DIR + "\\worker.ps1", WORKER_PS.encode("utf-8"))
    task = f"run-{rid}"
    args = (f'-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{DATA_DIR}\\worker.ps1" '
            f'-RunId {rid} -Mode {mode} -Percent {percent} -Kbs "{kbs}"')
    body = f"""
$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument {_q(args)}
$p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 3) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskPath {_q(TASK_PATH)} -TaskName {_q(task)} -Action $a -Principal $p -Settings $s -Force | Out-Null
Start-ScheduledTask -TaskPath {_q(TASK_PATH)} -TaskName {_q(task)}
[ordered]@{{ started = $true; task = {_q(TASK_PATH + task)} }} | ConvertTo-Json -Compress
"""
    return _ps(sess, body)


def _read_worker(sess, rid):
    task = f"run-{rid}"
    body = f"""
$f = {_q(DATA_DIR + '\\' + rid + '.status.json')}
$st = $null; if (Test-Path $f) {{ $st = Get-Content $f -Raw | ConvertFrom-Json }}
$t = Get-ScheduledTask -TaskPath {_q(TASK_PATH)} -TaskName {_q(task)} -ErrorAction SilentlyContinue
$ti = $null; if ($t) {{ $ti = $t | Get-ScheduledTaskInfo }}
$pend = (Test-Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Component Based Servicing\\RebootPending') -or
        (Test-Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WindowsUpdate\\Auto Update\\RebootRequired')
[ordered]@{{
  status = $st
  task_state = $(if ($t) {{ [string]$t.State }} else {{ $null }})
  last_result = $(if ($ti) {{ [int64]$ti.LastTaskResult }} else {{ $null }})
  reboot_pending = $pend
}} | ConvertTo-Json -Compress -Depth 6
"""
    return _ps(sess, body)


def _cleanup_worker(sess, rid):
    """Remove the one-shot task and the worker script; status and log files stay as evidence."""
    body = f"""
Unregister-ScheduledTask -TaskPath {_q(TASK_PATH)} -TaskName {_q('run-' + rid)} -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item {_q(DATA_DIR + '\\worker.ps1')} -Force -ErrorAction SilentlyContinue
[ordered]@{{ cleaned = $true }} | ConvertTo-Json -Compress
"""
    try:
        _ps(sess, body)
    except Exception as e:  # cleanup must never fail the run
        print(json.dumps({"cleanup_warning": str(e)}))


def _workload_health(h, workload):
    if workload != "iis":
        return {"healthy": True, "service": None, "service_state": None, "detail": "no workload check defined"}
    ok = h.get("w3svc") == "Running" and h.get("http") == 200 and bool(h.get("app_ok"))
    return {"healthy": ok, "service": "W3SVC", "service_state": h.get("w3svc"),
            "detail": f"http {h.get('http') or 'none'}"}


def _is_defender(u):
    return u.get("kb") in DEFENDER_KBS or "Defender" in (u.get("title") or "")


def _summarise(found):
    found = found or []
    countable = [u for u in found if not _is_defender(u)]
    by_sev = {s: 0 for s in SEVERITIES}
    for u in countable:
        sev = u.get("severity") if u.get("severity") in SEV_RANK else "Unspecified"
        by_sev[sev] += 1
    return countable, by_sev


def _search(sess, rid_hint="scan"):
    """Update search over WinRM; falls back to the SYSTEM task if the session is refused."""
    try:
        d = _ps(sess, SCAN_PS)
        return d.get("found") or [], d.get("defender"), "winrm"
    except CommandFailed as e:
        if "0x80070005" not in str(e) and "denied" not in str(e).lower():
            raise
    # Fallback: run the same search as SYSTEM and wait for it here (Lambda timeout 900 s).
    rid = f"{rid_hint}-{int(time.time())}"
    _start_worker(sess, rid, "scan")
    deadline = time.time() + 780
    try:
        while time.time() < deadline:
            time.sleep(10)
            d = _read_worker(sess, rid)
            st = d.get("status") or {}
            if st.get("state") == "done":
                return st.get("found") or [], None, "system-task"
            if st.get("state") == "failed":
                raise CommandFailed(f"scan task failed: {st.get('error')} ({st.get('hresult')})")
        raise CommandFailed("scan task did not finish within 13 minutes")
    finally:
        _cleanup_worker(sess, rid)


# ---------------------------------------------------------------- actions

def act_precheck(sess, ev):
    f = _ps(sess, PRECHECK_PS)
    health = _workload_health(f, _host(ev).get("workload"))
    reasons = []
    if not f.get("elevated"):
        reasons.append(f"{f.get('user')} has no administrator token over WinRM")
    if f.get("busy"):
        reasons.append("a serverless-patch task is already running")
    if (f.get("disk_free_mb") or 0) < MIN_DISK_FREE_MB:
        reasons.append(f"only {f.get('disk_free_mb')} MB free on C: (need {MIN_DISK_FREE_MB})")
    if f.get("wu_start") == "Disabled":
        reasons.append("Windows Update service (wuauserv) is disabled")
    if not health["healthy"]:
        reasons.append(f"workload unhealthy before patching: {health['detail']}")
    return {"ready": not reasons, "reasons": reasons, "os": f.get("os"), "kernel": f.get("build"),
            "boot_id": f.get("boot_id"), "uptime_s": f.get("uptime_s"), "disk_free_mb": f.get("disk_free_mb"),
            "user": f.get("user"), "elevated": f.get("elevated"), "agent_present": bool(f.get("ssm_agent")),
            "reboot_pending": f.get("reboot_pending"), "health": health}


def act_scan(sess, ev):
    t = time.time()
    found, defender, method = _search(sess)
    countable, by_sev = _summarise(found)
    ids = [u["kb"] for u in countable]
    check = ev.get("check_ids") or []
    check = [check] if isinstance(check, str) else [a for a in check if isinstance(a, str)]
    still = sorted(set(check) & set(ids))
    print(json.dumps({"scan_found": found, "defender_versions": defender}))
    return {"advisories": len(countable), "by_severity": by_sev,
            "updates_available": bool(countable),
            "pending_security_packages": len(countable), "pending_packages": len(found),
            "update_ids": ids, "updates": [{"kb": u["kb"], "severity": u.get("severity") or "Unspecified",
                                            "title": (u.get("title") or "")[:120]} for u in countable],
            "defender_excluded": [u["kb"] for u in found if _is_defender(u)], "defender": defender,
            "method": method,
            **({"checked": len(check), "checked_remaining": len(still), "checked_remaining_ids": still}
               if check else {}),
            "scan_s": round(time.time() - t, 1)}


def act_install_start(sess, ev):
    rid = _rid(ev)
    percent = float(ev.get("percent") or 100)
    if not 0 < percent <= 100:
        raise InvalidRequest("percent must be between 1 and 100")

    # Idempotent: if this run already started, report its selection instead of starting again.
    d = _read_worker(sess, rid)
    st = d.get("status") or {}
    if st or d.get("task_state"):
        sel = [u.get("kb") for u in (st.get("selected") or [])]
        return {"state": "already_started", "unit": TASK_PATH + "run-" + rid, "percent": percent,
                "selected": len(sel) or None, "selected_ids": sel}

    selected, total = [], None
    kbs = ev.get("kbs") or []
    kbs = [k for k in ([kbs] if isinstance(kbs, str) else kbs) if isinstance(k, str) and re.fullmatch(r"KB\d+", k)]
    if kbs:   # follow-up pass: only the selected updates that the rescan still found
        selected = sorted(set(kbs))
    elif percent < 100:
        found, _, _ = _search(sess, rid_hint=f"sel-{rid}")
        countable, _ = _summarise(found)
        total = len(countable)
        ordered = sorted(countable, key=lambda u: (SEV_RANK.get(u.get("severity"), 4), u["kb"]))
        selected = [u["kb"] for u in ordered[:max(1, math.ceil(len(ordered) * percent / 100))]] if ordered else []
    _start_worker(sess, rid, "install", percent=int(percent) if percent == int(percent) else percent,
                  kbs=",".join(selected))
    return {"state": "started", "unit": TASK_PATH + "run-" + rid,
            "log": f"{DATA_DIR}\\{rid}.log", "command": "Windows Update API (Microsoft.Update.Session) as SYSTEM",
            "percent": percent, "advisories_total": total,
            "selected": len(selected) if (percent < 100 or kbs) else None, "selected_ids": selected,
            "followup": bool(kbs)}


def act_install_status(sess, ev):
    rid = _rid(ev)
    d = _read_worker(sess, rid)
    st = d.get("status") or {}
    state, task_state, last = st.get("state"), d.get("task_state"), d.get("last_result")
    base = {"unit": TASK_PATH + "run-" + rid, "log": f"{DATA_DIR}\\{rid}.log", "worker_state": state,
            "task_state": task_state, "selected_ids": [u.get("kb") for u in (st.get("selected") or [])]}

    if state in ("starting", "searching", "downloading", "installing"):
        if task_state in ("Running", "Queued"):
            return {"state": "running", "reboot_required": False, **base}
        _cleanup_worker(sess, rid)
        return {"state": "failed", "reason": f"worker stopped while {state} (task result {last})",
                "reboot_required": False, **base}
    if state is None:
        if task_state in ("Running", "Queued") or last == 267011:   # 0x41303 = not run yet
            return {"state": "running", "reboot_required": False, **base}
        return {"state": "failed", "reason": f"no status file and task is {task_state} (result {last})",
                "reboot_required": False, **base}

    _cleanup_worker(sess, rid)
    if state == "failed":
        return {"state": "failed", "reason": st.get("error"), "hresult": st.get("hresult"),
                "reboot_required": False, **base}

    results = st.get("results") or []
    ok = [r for r in results if r.get("result") in ("Succeeded", "SucceededWithErrors")]
    bad = [r for r in results if r.get("result") not in ("Succeeded", "SucceededWithErrors")]
    rc = st.get("rc")
    reboot = bool(st.get("reboot_required")) or bool(d.get("reboot_pending"))
    common = {"rc": rc, "packages_upgraded": len(ok), "packages_installed": 0, "packages_removed": 0,
              "updates_failed": len(bad), "update_results": results,
              "reboot_required": reboot,
              "reboot_reason": "Windows Update installer requested a restart" if st.get("reboot_required")
              else ("reboot pending in registry" if reboot else "not required"), **base}
    if rc in (2, 3):
        return {"state": "succeeded", **common}
    return {"state": "failed", "reason": f"installer result code {rc}", **common}


def act_reboot(sess, ev):
    rid = _rid(ev)
    body = f"""
$os = Get-CimInstance Win32_OperatingSystem
$bid = $os.LastBootUpTime.ToUniversalTime().ToString('o')
& shutdown.exe /r /t 10 /d p:2:17 /c {_q('serverless-patch run ' + rid)} | Out-Null
[ordered]@{{ boot_id = $bid; scheduled = ($LASTEXITCODE -eq 0) }} | ConvertTo-Json -Compress
"""
    d = _ps(sess, body)
    if not d.get("scheduled"):
        raise CommandFailed("could not schedule restart")
    return {"boot_id_before": d.get("boot_id"), "scheduled": True}


def act_health(sess, ev):
    d = _ps(sess, HEALTH_OUT_PS)
    before = ev.get("boot_id_before")
    if before and d.get("boot_id") == before:
        raise RebootPending("host still has its pre-reboot boot time")
    h = _workload_health(d, _host(ev).get("workload"))
    if ev.get("strict") and not h["healthy"]:
        raise WorkloadNotHealthy(json.dumps(h))
    return {"kernel": d.get("build"), "boot_id": d.get("boot_id"), "uptime_s": d.get("uptime_s"),
            "rebooted": bool(before), "reboot_pending": d.get("reboot_pending"), **h}


def act_servicing(sess, ev):
    """Read-only: has Windows servicing settled enough for a follow-up install pass?"""
    d = _ps(sess, SERVICING_PS)
    min_up = int(ev.get("min_uptime_s") or SETTLE_MIN_UPTIME_S)
    waiting = []
    if (d.get("uptime_s") or 0) < min_up:
        waiting.append(f"uptime {d.get('uptime_s')} s < {min_up} s")
    if d.get("trustedinstaller") == "Running" or (d.get("tiworker") or 0) > 0:
        waiting.append(f"Windows Modules Installer busy (TrustedInstaller {d.get('trustedinstaller')}, TiWorker {d.get('tiworker')})")
    if d.get("cbs_reboot_pending") or d.get("cbs_packages_pending") or d.get("pending_xml"):
        waiting.append("component servicing operations pending")
    out = {"settled": not waiting, "waiting_for": waiting, **d}
    if waiting and ev.get("raise_if_busy", True):
        print(json.dumps(out))
        raise ServicingBusy("; ".join(waiting))
    return out


ACTIONS = {
    "precheck": act_precheck,
    "scan": act_scan,
    "install_start": act_install_start,
    "install_status": act_install_status,
    "reboot": act_reboot,
    "health": act_health,
    "servicing": act_servicing,
}


def lambda_handler(event, context):
    action = event.get("action")
    if action not in ACTIONS:
        raise InvalidRequest(f"unknown action {action!r}")
    host = _host(event)
    t0 = time.time()
    result = ACTIONS[action](_session(host["ip"]), event)
    result.update({
        "action": action,
        "host": host.get("name") or host["ip"],
        "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "duration_ms": round((time.time() - t0) * 1000),
    })
    print(json.dumps(result, default=str))
    return result
