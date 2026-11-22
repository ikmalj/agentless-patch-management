#Requires -Version 7.0
<#
.SYNOPSIS
  Demonstration: lets the recurring weekly schedule start a patch cycle on its own, once.

.DESCRIPTION
  serverless-patch-weekly normally fires every Sunday 02:00 MYT and is kept DISABLED in the lab. This script:
    1. moves the weekly rule to a time a few minutes from now (still a weekly cron rule) and enables it
    2. waits for EventBridge Scheduler to start the Step Functions workflow, with nobody starting it
    3. puts the rule straight back to Sunday 02:00 MYT, DISABLED (also if the script stops or fails)
    4. follows the cycle to the end, prints the result table and saves the evidence
  The cycle uses the weekly rule's own input ({"mode":"patch","reboot":true}, no targets), so it patches
  every RUNNING host tagged PatchTarget=true. Start (and restore) only the hosts you mean to patch.

  Evidence: evidence\cycles\cycle-patch-<execution>.json (same format as run-cycle.ps1) and
  evidence\schedule\weekly-test-<time>.json (the rule before, during and after, fire time, start lag).

.EXAMPLE
  .\weekly-test.ps1                  # fires 5 minutes from now
  .\weekly-test.ps1 -InMinutes 3
  .\weekly-test.ps1 -RestoreOnly     # put the weekly rule back to Sunday 02:00 MYT, DISABLED
#>
param(
    [ValidateRange(2, 60)][int]$InMinutes = 5,
    [switch]$RestoreOnly,
    [int]$PollSeconds = 30
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\config.ps1"
Push-Location $PSScriptRoot

$StdCron = 'cron(0 2 ? * SUN *)'
$StdTz   = 'Asia/Kuala_Lumpur'
$StdDesc = 'Weekly patch window, Sunday 02:00 MYT. Enable only when hosts are meant to be patched.'
$Myt     = [System.TimeZoneInfo]::FindSystemTimeZoneById($(if ($IsWindows) { 'Singapore Standard Time' } else { 'Asia/Kuala_Lumpur' }))

function Get-Weekly { Invoke-Aws scheduler get-schedule --name $WeeklySchedule }

function Set-Weekly([string]$Cron, [string]$State, [string]$Description) {
    # update-schedule replaces the whole rule, so the target is carried over from the live rule.
    $t = (Get-Weekly).Target
    Save-Json $t (Join-Path $BuildDir 'target-weekly.json')
    Invoke-Aws scheduler update-schedule --name $WeeklySchedule --schedule-expression $Cron `
        --schedule-expression-timezone $StdTz --flexible-time-window Mode=OFF --state $State `
        --description $Description --target file://build/target-weekly.json | Out-Null
}

function Restore-Weekly {
    Set-Weekly $StdCron 'DISABLED' $StdDesc
    $s = Get-Weekly
    Write-Ok "restored: $($s.ScheduleExpression) $($s.ScheduleExpressionTimezone), $($s.State)"
    $s
}

# Calls during a long wait can fail when the aws login session expires; the cycle keeps running regardless.
$script:warned = $false
function Invoke-Patient {
    param([scriptblock]$Call)
    try { $r = & $Call; $script:warned = $false; return $r }
    catch {
        if (-not $script:warned) {
            Write-Note "cannot reach AWS: $(($_.Exception.Message -split "`n" | Where-Object { $_ } | Select-Object -Last 1))"
            Write-Note 'If your sign-in expired, run  aws login  in another PowerShell window; this script then continues.'
            $script:warned = $true
        }
        return $null
    }
}

$changed = $false
$restored = $null
try {
    if ($RestoreOnly) {
        Write-Step "Restore $WeeklySchedule"
        Restore-Weekly | Out-Null
        return
    }

    # ---------------------------------------------------------------- checks
    $before = Get-Weekly
    Write-Step "Weekly rule now: $($before.ScheduleExpression) $($before.ScheduleExpressionTimezone), $($before.State)"
    if ($before.ScheduleExpression -ne $StdCron -or $before.State -ne 'DISABLED') {
        Write-Note "not the standard Sunday 02:00 DISABLED rule (an earlier test may have stopped). It is restored at the end."
    }

    Write-Step 'Hosts the weekly rule will patch (running, PatchTarget=true)'
    $res = Invoke-Aws ec2 describe-instances --filters 'Name=tag:PatchTarget,Values=true' 'Name=tag:project,Values=serverless-patch' 'Name=instance-state-name,Values=running'
    $running = @($res.Reservations.Instances | ForEach-Object {
        [pscustomobject]@{
            Name    = ($_.Tags | Where-Object Key -eq 'Name').Value
            PatchOS = ($_.Tags | Where-Object Key -eq 'PatchOS').Value
            Ip      = $_.PrivateIpAddress
        } })
    if (-not $running) { Write-Note 'none running. Start the hosts first: .\lab.ps1 start-all'; return }
    $running | Sort-Object Name | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    $ep = @((Invoke-Aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VpcId" "Name=service-name,Values=$SmService").VpcEndpoints |
            Where-Object State -eq 'available')
    if (-not $ep) { throw 'no available Secrets Manager endpoint: run .\lab.ps1 endpoint-up first (the Lambdas cannot read their credentials without it)' }

    # ---------------------------------------------------------------- plan
    $nowMyt = [System.TimeZoneInfo]::ConvertTimeFromUtc((Get-Date).ToUniversalTime(), $Myt)
    $fireMyt = $nowMyt.AddMinutes($InMinutes)
    $fireMyt = $fireMyt.AddSeconds(-$fireMyt.Second).AddMilliseconds(-$fireMyt.Millisecond).AddMinutes(1)   # next whole minute
    $fireUtc = [System.TimeZoneInfo]::ConvertTimeToUtc([datetime]::SpecifyKind($fireMyt, 'Unspecified'), $Myt)
    $dow = $fireMyt.DayOfWeek.ToString().Substring(0, 3).ToUpper()
    $testCron = 'cron({0} {1} ? * {2} *)' -f $fireMyt.Minute, $fireMyt.Hour, $dow
    $testDesc = "TEST $(Get-Date -Format 'yyyy-MM-dd'): weekly rule moved to $dow $($fireMyt.ToString('HH:mm')) MYT for one firing; weekly-test.ps1 restores it."

    Write-Step 'Plan'
    Write-Note "1. Set $WeeklySchedule to $testCron $StdTz (every $dow at $($fireMyt.ToString('HH:mm'))) and ENABLE it"
    Write-Note "2. Wait for it to start the workflow at $($fireMyt.ToString('HH:mm')) MYT, nobody starting it"
    Write-Note "3. Put it back to $StdCron $StdTz, DISABLED, as soon as the workflow has started"
    Write-Note "4. Follow the patch cycle (security updates on RHEL, all but Defender on Windows, reboot, rescan, email)"
    if ((Read-Host 'Type WEEKLY to continue') -cne 'WEEKLY') { Write-Note 'cancelled'; return }

    # ---------------------------------------------------------------- enable
    $changed = $true
    Set-Weekly $testCron 'ENABLED' $testDesc
    $during = Get-Weekly
    Write-Step "Weekly rule ENABLED: $($during.ScheduleExpression) $($during.ScheduleExpressionTimezone)"
    Write-Ok "fires at $($fireMyt.ToString('HH:mm:ss')) MYT. Screenshot: EventBridge > Scheduler > Schedules > $WeeklySchedule"

    # ---------------------------------------------------------------- wait for the firing
    $deadline = $fireUtc.AddMinutes(5)
    $exec = $null
    while (-not $exec) {
        Start-Sleep 15
        $list = Invoke-Patient { Invoke-Aws stepfunctions list-executions --state-machine-arn $StateMachineArn --max-results 10 }
        if ($list) {
            $exec = $list.executions | Where-Object { ([datetime]$_.startDate).ToUniversalTime() -ge $fireUtc.AddSeconds(-5) } |
                    Sort-Object startDate | Select-Object -First 1
        }
        if (-not $exec) {
            if ((Get-Date).ToUniversalTime() -gt $deadline) { throw 'the weekly rule did not start an execution within 5 minutes of its fire time' }
            $left = $fireUtc - (Get-Date).ToUniversalTime()
            Write-Host ("   {0}  waiting for the weekly rule to fire ({1})" -f (Get-Date -Format 'HH:mm:ss'),
                $(if ($left.TotalSeconds -gt 0) { 'in {0:mm\:ss}' -f $left } else { 'due now' }))
        }
    }
    $execArn = $exec.executionArn
    $startUtc = ([datetime]$exec.startDate).ToUniversalTime()
    $lag = [math]::Round(($startUtc - $fireUtc).TotalSeconds, 1)
    $startMyt = [System.TimeZoneInfo]::ConvertTimeFromUtc($startUtc, $Myt)
    Write-Step "Workflow started by the weekly rule at $($startMyt.ToString('HH:mm:ss')) MYT ($lag s after the fire time)"
    Write-Ok $execArn
    Write-Ok "Console: https://$Region.console.aws.amazon.com/states/home?region=$Region#/v2/executions/details/$execArn"
    $desc = Invoke-Aws stepfunctions describe-execution --execution-arn $execArn
    Write-Ok "input: $($desc.input)"

    # ---------------------------------------------------------------- restore right away
    Write-Step "Restore $WeeklySchedule"
    $restored = Restore-Weekly
    $changed = $false

    # ---------------------------------------------------------------- follow
    $t0 = Get-Date
    do {
        Start-Sleep $PollSeconds
        $d = Invoke-Patient { Invoke-Aws stepfunctions describe-execution --execution-arn $execArn }
        if (-not $d) { $d = [pscustomobject]@{ status = 'RUNNING' }; continue }
        Write-Host ("   {0}  {1}  elapsed {2:mm\:ss}" -f (Get-Date -Format 'HH:mm:ss'), $d.status, ((Get-Date) - $t0))
    } while ($d.status -eq 'RUNNING')

    # ---------------------------------------------------------------- report and evidence
    $report = $null
    if ($d.output) { $report = $d.output | ConvertFrom-Json }
    elseif ($d.cause) { try { $report = $d.cause | ConvertFrom-Json } catch { } }
    $file = Get-EvidenceFile cycles ("cycle-patch-{0}.json" -f $execArn.Split(':')[-1])
    Save-Json ([ordered]@{ execution = $execArn; status = $d.status; error = $d.error; trigger = 'weekly schedule'; report = $report }) $file -Depth 30
    $sched = Get-EvidenceFile schedule ("weekly-test-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Save-Json ([ordered]@{
        schedule = $WeeklySchedule
        rule_before = [ordered]@{ expression = $before.ScheduleExpression; timezone = $before.ScheduleExpressionTimezone; state = $before.State }
        rule_during = [ordered]@{ expression = $during.ScheduleExpression; timezone = $during.ScheduleExpressionTimezone; state = $during.State; description = $during.Description }
        rule_after  = [ordered]@{ expression = $restored.ScheduleExpression; timezone = $restored.ScheduleExpressionTimezone; state = $restored.State }
        fire_time_myt = $fireMyt.ToString('yyyy-MM-ddTHH:mm:ss')
        execution = $execArn; execution_started_myt = $startMyt.ToString('yyyy-MM-ddTHH:mm:ss'); start_lag_s = $lag
        execution_input = $desc.input; status = $d.status; cycle_evidence = (Split-Path $file -Leaf)
    }) $sched

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
                Passes    = if ($_.install_passes) { @($_.install_passes).Count } elseif ($_.status -like 'patched*') { 1 } else { $null }
                FirstLeft = $_.first_pass_remaining
                Upgraded  = $_.packages_upgraded
                Rebooted  = $_.rebooted
                Healthy   = if ($null -ne $_.healthy_after) { $_.healthy_after } else { $_.healthy }
                Secs      = $_.duration_s
                FailedAt  = $_.failed_at
            }
        } | Format-Table Host, Status, Unit, Before, After, Selected, SelLeft, Passes, FirstLeft, Upgraded, Rebooted, Healthy, Secs, FailedAt -AutoSize |
            Out-String -Width 240 | Write-Host
    } else {
        Write-Note "$($d.error): $($d.cause)"
    }
    Write-Ok "saved $file"
    Write-Ok "saved $sched"
    Write-Ok "email sent to $NotifyEmail (SNS $TopicName) if the subscription is confirmed"
} finally {
    if ($changed) {
        Write-Step "Restore $WeeklySchedule (script stopped early)"
        try { Restore-Weekly | Out-Null }
        catch { Write-Note "could not restore it: $($_.Exception.Message). Run  aws login  then  .\weekly-test.ps1 -RestoreOnly" }
    }
    Pop-Location
}
