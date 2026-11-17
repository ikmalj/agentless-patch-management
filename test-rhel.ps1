#Requires -Version 7.0
<#
.SYNOPSIS
  Read-only check of the new RHEL Lambda: runs precheck and scan on each RHEL host directly.
  Nothing on the hosts changes. Results are saved under .\evidence.
#>
param([ValidateSet('rhel-01', 'rhel-02')][string[]]$Target = @('rhel-01', 'rhel-02'))
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\config.ps1"
Push-Location $PSScriptRoot
try {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    foreach ($key in $Target) {
        $h = $Hosts[$key]
        $hostObj = @{ ip = $h.Ip; name = $h.Name; workload = $h.Workload }
        foreach ($action in 'precheck', 'scan') {
            Write-Step "$key $action"
            $ev = @{ action = $action; host = $hostObj }
            if ($action -eq 'scan') { $ev.refresh = $true }
            Save-Json $ev (Join-Path $BuildDir 'test-event.json')
            $out = Get-EvidenceFile tests "test-$key-$action-$stamp.json"
            # A scan can take 1-3 minutes; the default CLI read timeout (60 s) would cut it off and retry.
            $meta = Invoke-Aws lambda invoke --function-name $RhelFn --cli-binary-format raw-in-base64-out `
                --cli-read-timeout 900 --payload file://build/test-event.json $out
            $res = Get-Content $out -Raw | ConvertFrom-Json
            if ($meta.FunctionError) {
                Write-Note "$($res.errorType): $($res.errorMessage)"
                continue
            }
            switch ($action) {
                'precheck' {
                    Write-Ok "ready=$($res.ready) os='$($res.os)' kernel=$($res.kernel)"
                    Write-Ok "disk_free_mb=$($res.disk_free_mb) agent_present=$($res.agent_present) health=$($res.health.healthy) ($($res.health.detail))"
                    if ($res.reasons) { Write-Note ("reasons: " + ($res.reasons -join '; ')) }
                }
                'scan' {
                    $s = $res.by_severity
                    Write-Ok "RHSA advisories=$($res.advisories) (Critical $($s.Critical), Important $($s.Important), Moderate $($s.Moderate), Low $($s.Low))"
                    Write-Ok "security_updates_available=$($res.updates_available) security_packages=$($res.pending_security_packages) (all pending: $($res.pending_packages)) scan_s=$($res.scan_s) unparsed_lines=$($res.unparsed_lines)"
                }
            }
            Write-Ok "saved $out"
        }
    }
} finally { Pop-Location }
