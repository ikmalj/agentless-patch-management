#Requires -Version 7.0
<#
.SYNOPSIS
  Start one patch cycle and follow it to the end.

.DESCRIPTION
  -Mode scan   read-only: precheck + scan on every running PatchTarget host (default)
  -Mode patch  installs security updates with `dnf -y upgrade --security`, reboots if needed, verifies health.
               This changes the hosts. Use restore-baseline.ps1 afterwards to return them
               to the unpatched AMI state.

  By default the run starts straight away with StartExecution. With -ViaSchedule, a one-time
  EventBridge Scheduler schedule fires it instead (the same path the weekly schedule uses);
  the one-time schedule deletes itself after it fires.

.EXAMPLE
  .\run-cycle.ps1                                   # scan all running targets
  .\run-cycle.ps1 -Mode patch -ViaSchedule          # Iteration 1 demonstration run
  .\run-cycle.ps1 -Mode patch -Targets serverless-patch-rhel-01 -NoReboot
  .\run-cycle.ps1 -Mode patch -Percent 5           # only 5% of missing RHSA, Critical first
  .\run-cycle.ps1 -Notify                           # scan only, but also email the result (Phase D test)

  Email (SNS): patch runs send one by default, scan runs do not. -Notify forces one, -NoNotify suppresses it.
  A run that stops on an unexpected error always sends one.
#>
param(
    [ValidateSet('scan', 'patch')][string]$Mode = 'scan',
    [string[]]$Targets = @(),
    [ValidateRange(1, 100)][int]$Percent = 100,
    [switch]$NoReboot,
    [switch]$ViaSchedule,
    [switch]$Notify,
    [switch]$NoNotify,
    [int]$DelayMinutes = 2,
    [int]$PollSeconds = 30
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\config.ps1"
if ($Notify -and $NoNotify) { throw 'use -Notify or -NoNotify, not both' }
Push-Location $PSScriptRoot
try {
    # ---------------------------------------------------------------- show what will be touched
    Write-Step 'Running PatchTarget hosts'
    $res = Invoke-Aws ec2 describe-instances --filters 'Name=tag:PatchTarget,Values=true' 'Name=tag:project,Values=serverless-patch' 'Name=instance-state-name,Values=running'
    $running = @($res.Reservations.Instances | ForEach-Object {
        [pscustomobject]@{
            Name    = ($_.Tags | Where-Object Key -eq 'Name').Value
            PatchOS = ($_.Tags | Where-Object Key -eq 'PatchOS').Value
            Ip      = $_.PrivateIpAddress
        } })
    if ($Targets) { $running = @($running | Where-Object Name -in $Targets) }
    if (-not $running) { Write-Note 'none running. Start hosts first: .\lab.ps1 start-rhel'; return }
    $running | Sort-Object Name | Format-Table -AutoSize | Out-String -Width 220 | Write-Host

    if ($Mode -eq 'patch') {
        $rhel = @($running | Where-Object PatchOS -eq 'rhel').Name

        # ------------------------------------------------------------ preview (read-only scan)
        Write-Step 'Patch preview (read-only scan of each host)'
        $defNotes = @()
        $preview = foreach ($h in ($running | Where-Object PatchOS -in 'rhel', 'windows' | Sort-Object Name)) {
            $fnName = if ($h.PatchOS -eq 'windows') { $WinFn } else { $RhelFn }
            Write-Host "   scanning $($h.Name)..."
            $evFile = Join-Path $BuildDir "preview-event.json"
            $outFile = Join-Path $BuildDir "preview-$($h.Name).json"
            Save-Json @{ action = 'scan'; refresh = $true; host = @{ ip = $h.Ip; name = $h.Name } } $evFile
            try {
                $meta = Invoke-Aws lambda invoke --function-name $fnName --cli-binary-format raw-in-base64-out `
                    --cli-read-timeout 900 --payload file://build/preview-event.json $outFile
                $s = Get-Content $outFile -Raw | ConvertFrom-Json
                if ($meta.FunctionError) { throw "$($s.errorType): $($s.errorMessage)" }
                $toApply = if ($Percent -lt 100) { [math]::Max(1, [math]::Ceiling($s.advisories * $Percent / 100)) } else { $s.advisories }
                if ($s.advisories -eq 0) { $toApply = 0 }
                if ($s.defender_excluded) { $defNotes += "$($h.Name): Defender excluded from count: $($s.defender_excluded -join ', ')" }
                [pscustomobject]@{
                    Host      = $h.Name
                    Unit      = if ($h.PatchOS -eq 'windows') { 'KB' } else { 'RHSA' }
                    Missing   = $s.advisories
                    Critical  = $s.by_severity.Critical
                    Important = $s.by_severity.Important
                    Moderate  = $s.by_severity.Moderate
                    Low       = $s.by_severity.Low
                    Other     = $s.by_severity.Unspecified
                    ToApply   = $toApply
                    Scope     = "$Percent%"
                    SecPkgs   = $s.pending_security_packages
                    AllPkgs   = $s.pending_packages
                }
            } catch {
                [pscustomobject]@{ Host = $h.Name; Unit = 'scan failed'; Scope = $_.Exception.Message.Split("`n")[0] }
            }
        }
        $preview | Format-Table Host, Unit, Missing, Critical, Important, Moderate, Low, Other, ToApply, Scope, SecPkgs, AllPkgs -AutoSize |
            Out-String -Width 240 | Write-Host
        $total = ($preview | Where-Object { $null -ne $_.ToApply } | Measure-Object ToApply -Sum).Sum
        Write-Ok "Total updates to apply across hosts: $total (RHSA advisories on RHEL, KB updates on Windows)"
        $defNotes | ForEach-Object { Write-Ok $_ }
        if ($Percent -lt 100) {
            Write-Ok 'Selection order: Critical, then Important, Moderate, Low, then unrated (by ID within each)'
        }
        Write-Host ''

        $winHosts = @($running | Where-Object PatchOS -eq 'windows').Name
        if ($rhel) {
            if ($Percent -lt 100) { Write-Note "RHEL: apply $Percent% of the missing RHSA advisories (highest severity first) on: $($rhel -join ', ')" }
            else { Write-Note "RHEL: 'dnf -y upgrade --security' on: $($rhel -join ', ')" }
        }
        if ($winHosts) {
            if ($Percent -lt 100) { Write-Note "Windows: install $Percent% of the missing updates (highest severity first, Defender excluded) on: $($winHosts -join ', ')" }
            else { Write-Note "Windows: install all missing updates except Defender (Windows Update API as SYSTEM) on: $($winHosts -join ', ')" }
        }
        Write-Note ("Reboot if required: " + $(if ($NoReboot) { 'no' } else { 'yes' }))
        Write-Note 'The hosts will no longer match their baseline AMIs afterwards (restore-baseline.ps1 resets them).'
        if ((Read-Host "Type PATCH to continue") -cne 'PATCH') { Write-Note 'cancelled'; return }
    }

    $runInput = [ordered]@{ mode = $Mode; reboot = -not $NoReboot.IsPresent; percent = $Percent }
    if ($Targets) { $runInput.targets = $Targets }
    if ($Notify)   { $runInput.notify = $true }
    if ($NoNotify) { $runInput.notify = $false }
    $inputJson = $runInput | ConvertTo-Json -Compress
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    # ---------------------------------------------------------------- start
    if ($ViaSchedule) {
        $fireUtc = (Get-Date).ToUniversalTime().AddMinutes($DelayMinutes)
        $fireUtc = $fireUtc.AddSeconds(60 - $fireUtc.Second)           # next whole minute
        $name = "serverless-patch-once-$stamp"
        $target = @{ Arn = $StateMachineArn; RoleArn = "arn:aws:iam::${Account}:role/$SchedRoleName"; Input = $inputJson
                     RetryPolicy = @{ MaximumEventAgeInSeconds = 600; MaximumRetryAttempts = 0 } }
        Save-Json $target (Join-Path $BuildDir 'target-once.json')
        Invoke-Aws scheduler create-schedule --name $name `
            --schedule-expression ("at({0:yyyy-MM-ddTHH:mm:ss})" -f $fireUtc) --schedule-expression-timezone UTC `
            --flexible-time-window Mode=OFF --action-after-completion DELETE `
            --description "One-time $Mode run" --target file://build/target-once.json | Out-Null
        Write-Step "EventBridge Scheduler: $name fires at $($fireUtc.ToLocalTime().ToString('HH:mm:ss')) local"
        $deadline = $fireUtc.AddMinutes(3)
        $exec = $null
        while (-not $exec) {
            Start-Sleep 15
            if ((Get-Date).ToUniversalTime() -gt $deadline) { throw 'schedule did not start an execution within 3 minutes of its fire time' }
            $list = Invoke-Aws stepfunctions list-executions --state-machine-arn $StateMachineArn --max-results 10
            $exec = $list.executions | Where-Object { ([datetime]$_.startDate).ToUniversalTime() -ge $fireUtc.AddSeconds(-5) } |
                    Sort-Object startDate | Select-Object -First 1
            if (-not $exec) { Write-Host '   waiting for the schedule to fire...' }
        }
        $execArn = $exec.executionArn
    } else {
        $execName = "manual-$Mode-$stamp"
        Save-Json $inputJson (Join-Path $BuildDir 'run-input.json')
        $execArn = (Invoke-Aws stepfunctions start-execution --state-machine-arn $StateMachineArn --name $execName `
            --input file://build/run-input.json).executionArn
    }
    Write-Step "Execution started"
    Write-Ok $execArn
    Write-Ok "Console: https://$Region.console.aws.amazon.com/states/home?region=$Region#/v2/executions/details/$execArn"

    # ---------------------------------------------------------------- follow
    $t0 = Get-Date
    do {
        Start-Sleep $PollSeconds
        $d = Invoke-Aws stepfunctions describe-execution --execution-arn $execArn
        Write-Host ("   {0}  {1}  elapsed {2:mm\:ss}" -f (Get-Date -Format 'HH:mm:ss'), $d.status, ((Get-Date) - $t0))
    } while ($d.status -eq 'RUNNING')

    # ---------------------------------------------------------------- report
    $report = $null
    if ($d.output) { $report = $d.output | ConvertFrom-Json }
    elseif ($d.cause) { try { $report = $d.cause | ConvertFrom-Json } catch { } }
    $file = Join-Path $EvidenceDir ("cycle-{0}-{1}.json" -f $Mode, ($execArn.Split(':')[-1]))
    Save-Json ([ordered]@{ execution = $execArn; status = $d.status; error = $d.error; report = $report }) $file -Depth 30

    Write-Step "Result: $($d.status)"
    if ($report) {
        Write-Ok ("run {0}s  hosts {1}  patched {2}  partial {3}  compliant {4}  scanned {5}  skipped {6}  failed {7}" -f `
            $report.duration_s, $report.hosts_total, $report.patched, $report.patched_partial, $report.compliant,
            $report.scanned, $report.skipped, $report.failed)
        $report.results | ForEach-Object {
            [pscustomobject]@{
                Host      = $_.host
                Status    = $_.status
                Unit      = $_.unit
                Before    = $_.advisories_before
                After     = $_.advisories_after
                Selected  = $_.advisories_selected
                SelLeft   = $_.selected_remaining
                SecPkgs   = $_.pending_security_packages_before
                Upgraded  = $_.packages_upgraded
                Rebooted  = $_.rebooted
                Healthy   = if ($null -ne $_.healthy_after) { $_.healthy_after } else { $_.healthy }
                Secs      = $_.duration_s
                FailedAt  = $_.failed_at
            }
        } | Format-Table Host, Status, Unit, Before, After, Selected, SelLeft, SecPkgs, Upgraded, Rebooted, Healthy, Secs, FailedAt -AutoSize |
            Out-String -Width 240 | Write-Host
    } else {
        Write-Note "$($d.error): $($d.cause)"
    }
    Write-Ok "saved $file"
    $willEmail = if ($Notify) { $true } elseif ($NoNotify) { $false } else { $Mode -eq 'patch' }
    if ($willEmail -or $d.error -eq 'RunError') { Write-Ok "email sent to $NotifyEmail (SNS $TopicName) if the subscription is confirmed" }
    Write-Ok "Dashboard: $DashboardUrl"
} finally { Pop-Location }
