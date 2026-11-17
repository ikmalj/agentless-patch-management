#Requires -Version 7.0
<#
.SYNOPSIS
  Read-only check of the Windows Lambda: runs precheck and scan on win-01 directly.
  Nothing on the host changes. Results are saved under .\evidence.
  WinRM needs about 4 minutes after the instance shows "running".
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\config.ps1"
Push-Location $PSScriptRoot
try {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $h = $Hosts['win-01']
    $hostObj = @{ ip = $h.Ip; name = $h.Name; workload = $h.Workload }
    foreach ($action in 'precheck', 'scan') {
        Write-Step "win-01 $action"
        if ($action -eq 'scan') { Write-Host '   Windows Update search can take 1-5 minutes...' }
        Save-Json @{ action = $action; host = $hostObj } (Join-Path $BuildDir 'test-event.json')
        $out = Get-EvidenceFile tests "test-win-01-$action-$stamp.json"
        $meta = Invoke-Aws lambda invoke --function-name $WinFn --cli-binary-format raw-in-base64-out `
            --cli-read-timeout 900 --payload file://build/test-event.json $out
        $res = Get-Content $out -Raw | ConvertFrom-Json
        if ($meta.FunctionError) {
            Write-Note "$($res.errorType): $($res.errorMessage)"
            continue
        }
        switch ($action) {
            'precheck' {
                Write-Ok "ready=$($res.ready) os='$($res.os)' build=$($res.kernel) user=$($res.user) elevated=$($res.elevated)"
                Write-Ok "disk_free_mb=$($res.disk_free_mb) agent_present=$($res.agent_present) reboot_pending=$($res.reboot_pending) health=$($res.health.healthy) ($($res.health.detail))"
                if ($res.reasons) { Write-Note ("reasons: " + ($res.reasons -join '; ')) }
            }
            'scan' {
                $s = $res.by_severity
                Write-Ok "countable updates=$($res.advisories) (Critical $($s.Critical), Important $($s.Important), Moderate $($s.Moderate), Low $($s.Low), unrated $($s.Unspecified))"
                Write-Ok "all found=$($res.pending_packages) defender_excluded=$($res.defender_excluded -join ',') method=$($res.method) scan_s=$($res.scan_s)"
                $res.updates | ForEach-Object { Write-Host ("     {0,-11} {1,-10} {2}" -f $_.kb, $_.severity, $_.title) }
                if ($res.defender) { Write-Ok "Defender installed: platform $($res.defender.platform), engine $($res.defender.engine), definitions $($res.defender.definitions)" }
            }
        }
        Write-Ok "saved $out"
    }
} finally { Pop-Location }
