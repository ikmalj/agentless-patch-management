#Requires -Version 7.0
<#
.SYNOPSIS
  Experiment 3 (scalability): patch an increasing number of hosts and record the cycle time per level.

  Main series:  RHEL at 1, 2, 4, 6, 8 hosts (rhel-01, rhel-02 + clones rhel-03..08 of the rhel-01 baseline AMI)
  Add-on:       Windows at 1 and 2 hosts (win-01 + clone win-02 of the win-01 baseline AMI)

  Every level starts from baseline: the hosts in that level get their root volume replaced from the
  baseline AMI, then one patch cycle runs on exactly those hosts (targets), and the result is saved.
  Clones are tagged Experiment=exp3 and are removed with -Action teardown.

.EXAMPLE
  .\exp3-scale.ps1 -Action status
  .\exp3-scale.ps1 -Action launch -Platform rhel -Total 8          # adds rhel-03..rhel-08 (stop win-01 first)
  .\exp3-scale.ps1 -Action run    -Platform rhel -Levels 1,2,4,6,8
  .\exp3-scale.ps1 -Action launch -Platform windows -Total 2       # adds win-02 (stop the RHEL hosts first)
  .\exp3-scale.ps1 -Action run    -Platform windows -Levels 1,2
  .\exp3-scale.ps1 -Action teardown                                # terminates every Experiment=exp3 clone
#>
param(
    [Parameter(Mandatory)][ValidateSet('status', 'launch', 'run', 'teardown')][string]$Action,
    [ValidateSet('rhel', 'windows')][string]$Platform = 'rhel',
    [ValidateRange(1, 8)][int]$Total = 8,
    [string[]]$Levels = @('1', '2', '4', '6', '8'),
    [switch]$Notify,
    [int]$PollSeconds = 20
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\config.ps1"
Push-Location $PSScriptRoot
try {

$ExpTag = 'exp3'
# Accept -Levels 1,2,4 typed at the prompt or passed as one string "1,2,4".
$Levels = @($Levels -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ } | Sort-Object -Unique)
if ($Levels | Where-Object { $_ -lt 1 -or $_ -gt 8 }) { throw 'levels must be between 1 and 8' }
$src = if ($Platform -eq 'windows') { $Hosts['win-01'] } else { $Hosts['rhel-01'] }
$prefix = if ($Platform -eq 'windows') { 'serverless-patch-win-' } else { 'serverless-patch-rhel-' }
$names = @(1..8 | ForEach-Object { '{0}{1:00}' -f $prefix, $_ })
$bootWait = if ($Platform -eq 'windows') { 300 } else { 90 }

function Get-Tag($inst, [string]$key) { ($inst.Tags | Where-Object Key -eq $key).Value }

# All serverless-patch instances of this platform (testbed + clones), not terminated.
function Get-PlatformHosts {
    $r = Invoke-Aws ec2 describe-instances --filters 'Name=tag:project,Values=serverless-patch' "Name=tag:PatchOS,Values=$Platform" `
        'Name=instance-state-name,Values=pending,running,stopping,stopped'
    @($r.Reservations.Instances | ForEach-Object {
        [pscustomobject]@{ Name = Get-Tag $_ 'Name'; Id = $_.InstanceId; State = $_.State.Name; Type = $_.InstanceType
                           Ip = $_.PrivateIpAddress; Exp = Get-Tag $_ 'Experiment' } }) | Sort-Object Name
}

function Get-VcpuUse {
    $quota = [int](Invoke-Aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A).Quota.Value
    $run = @((Invoke-Aws ec2 describe-instances --filters 'Name=instance-state-name,Values=pending,running').Reservations.Instances |
             Where-Object { $_ })
    $used = 0
    if ($run) {
        $types = @($run.InstanceType | Sort-Object -Unique)
        $info = (Invoke-Aws ec2 describe-instance-types --instance-types @types).InstanceTypes
        foreach ($i in $run) { $used += ($info | Where-Object InstanceType -eq $i.InstanceType).VCpuInfo.DefaultVCpus }
    }
    [pscustomobject]@{ Quota = $quota; Used = $used; Running = $run.Count }
}

function Wait-Running([string[]]$Ids) {
    $stopped = @((Invoke-Aws ec2 describe-instances --instance-ids @Ids).Reservations.Instances |
                 Where-Object { $_.State.Name -ne 'running' } | ForEach-Object InstanceId)
    if ($stopped) {
        Invoke-Aws ec2 start-instances --instance-ids @stopped | Out-Null
        Write-Ok "starting $($stopped.Count) stopped host(s)"
    }
    Invoke-Aws ec2 wait instance-running --instance-ids @Ids | Out-Null
}

# Baseline AMI per host: testbed hosts use their own AMI (rhel-02 is the MySQL host),
# clones use the AMI they were launched from (rhel-01 or win-01).
function Get-BaselineAmi([string]$Name) {
    $own = $Hosts.Values | Where-Object Name -eq $Name | Select-Object -First 1
    if ($own) { $own.Ami } else { $src.Ami }
}

# Replace the root volume of each host with its baseline AMI (same as restore-baseline.ps1).
function Restore-Hosts([object[]]$List) {
    Wait-Running @($List.Id)
    $tasks = @{}
    foreach ($h in $List) {
        $t = Invoke-Aws ec2 create-replace-root-volume-task --instance-id $h.Id --image-id (Get-BaselineAmi $h.Name) --delete-replaced-root-volume `
            --tag-specifications 'ResourceType=replace-root-volume-task,Tags=[{Key=project,Value=serverless-patch},{Key=Experiment,Value=exp3}]'
        $tasks[$h.Name] = $t.ReplaceRootVolumeTask.ReplaceRootVolumeTaskId
    }
    $done = @{}
    while ($done.Count -lt $tasks.Count) {
        Start-Sleep 15
        foreach ($t in (Invoke-Aws ec2 describe-replace-root-volume-tasks --replace-root-volume-task-ids @($tasks.Values)).ReplaceRootVolumeTasks) {
            $n = ($tasks.GetEnumerator() | Where-Object Value -eq $t.ReplaceRootVolumeTaskId).Key
            if ($n -and $t.TaskState -in 'succeeded', 'failed', 'failed-detached' -and -not $done[$n]) { $done[$n] = $t.TaskState }
        }
    }
    $bad = @($done.GetEnumerator() | Where-Object Value -ne 'succeeded')
    if ($bad) { throw "restore failed for: $(($bad | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')" }
    Write-Ok "restored to baseline: $(($List.Name) -join ', ')"
}

switch ($Action) {
# ------------------------------------------------------------------ status
'status' {
    Write-Step "Hosts ($Platform)"
    Get-PlatformHosts | Format-Table Name, State, Type, Ip, Exp -AutoSize | Out-String -Width 200 | Write-Host
    Write-Step 'Capacity'
    $v = Get-VcpuUse
    Write-Ok "EC2 standard vCPUs: $($v.Used) used by $($v.Running) running instance(s), quota $($v.Quota)"
    $c = (Invoke-Aws lambda get-account-settings).AccountLimit
    Write-Ok "Lambda concurrent executions limit: $($c.ConcurrentExecutions) (unreserved $($c.UnreservedConcurrentExecutions))"
    if ($c.ConcurrentExecutions -le 10) {
        Write-Note "Limit $($c.ConcurrentExecutions): an 8-host level runs 8 patch Lambdas at once, and the dashboard's custom widgets add 3 more per refresh."
        Write-Note 'Request an increase before Experiment 3 (Service Quotas > AWS Lambda > Concurrent executions), and keep the dashboard closed during the runs.'
    }
}

# ------------------------------------------------------------------ launch
'launch' {
    $have = Get-PlatformHosts
    $want = $names[0..($Total - 1)]
    $missing = @($want | Where-Object { $_ -notin $have.Name })
    Write-Step "Launch $Platform clones up to $Total host(s)"
    if (-not $missing) { Write-Ok "all $Total already exist"; break }
    $ref = (Invoke-Aws ec2 describe-instances --instance-ids $src.Id).Reservations[0].Instances[0]
    $v = Get-VcpuUse
    $per = ((Invoke-Aws ec2 describe-instance-types --instance-types $ref.InstanceType).InstanceTypes[0]).VCpuInfo.DefaultVCpus
    $notRunning = @($have | Where-Object { $_.Name -in $want -and $_.State -ne 'running' }).Count
    $need = $v.Used + $per * ($missing.Count + $notRunning)
    Write-Ok "new: $($missing -join ', ') ($($ref.InstanceType), $per vCPU each); vCPUs after the level runs: $need of $($v.Quota)"
    if ($need -gt $v.Quota) {
        throw "not enough vCPU quota ($need > $($v.Quota)). Stop the other platform's hosts first (.\lab.ps1 stop-all, then start only what you need)."
    }
    $sgs = @($ref.SecurityGroups.GroupId)
    $tags = "ResourceType=instance,Tags=[{Key=project,Value=serverless-patch},{Key=PatchTarget,Value=true},{Key=PatchOS,Value=$Platform},{Key=Workload,Value=$(Get-Tag $ref 'Workload')},{Key=Experiment,Value=$ExpTag}]"
    $runArgs = @('ec2', 'run-instances', '--image-id', $src.Ami, '--instance-type', $ref.InstanceType, '--count', $missing.Count,
              '--subnet-id', $ref.SubnetId, '--security-group-ids') + $sgs + @(
              '--metadata-options', 'HttpTokens=required,HttpEndpoint=enabled',
              '--tag-specifications', $tags, 'ResourceType=volume,Tags=[{Key=project,Value=serverless-patch},{Key=Experiment,Value=exp3}]')
    if ($ref.KeyName) { $runArgs += @('--key-name', $ref.KeyName) }
    if ($ref.InstanceType -like 't*') { $runArgs += @('--credit-specification', 'CpuCredits=standard') }
    $new = (Invoke-Aws @runArgs).Instances
    for ($i = 0; $i -lt $new.Count; $i++) {
        Invoke-Aws ec2 create-tags --resources $new[$i].InstanceId --tags "Key=Name,Value=$($missing[$i])" | Out-Null
        Write-Ok "$($missing[$i])  $($new[$i].InstanceId)"
    }
    Invoke-Aws ec2 wait instance-running --instance-ids @($new.InstanceId) | Out-Null
    Write-Ok 'running. They are already at baseline (fresh from the AMI); every level restores them again anyway.'
    Save-Json ([ordered]@{ launched_at = (Get-Date).ToString('s'); platform = $Platform; ami = $src.Ami
                          instances = @($new | ForEach-Object { $_.InstanceId }); names = $missing }) `
        (Join-Path $EvidenceDir ("exp3-launch-{0}-{1}.json" -f $Platform, (Get-Date -Format 'yyyyMMdd-HHmmss')))
}

# ------------------------------------------------------------------ run
'run' {
    $all = Get-PlatformHosts
    $maxLevel = ($Levels | Measure-Object -Maximum).Maximum
    $use = $names[0..($maxLevel - 1)]
    $absent = @($use | Where-Object { $_ -notin $all.Name })
    if ($absent) { throw "missing hosts for level ${maxLevel}: $($absent -join ', '). Run -Action launch -Platform $Platform -Total $maxLevel first." }
    $v = Get-VcpuUse
    Write-Step "Experiment 3 ($Platform), levels $($Levels -join ', ')"
    Write-Ok "vCPUs in use now: $($v.Used) of $($v.Quota)"
    Write-Note 'Each level: restore the level hosts to baseline, wait for boot, run one patch cycle on exactly those hosts.'
    Write-Note ("Email per level: " + $(if ($Notify) { 'yes' } else { 'no (use -Notify to send)' }))
    if ((Read-Host 'Type SCALE to start') -cne 'SCALE') { Write-Note 'cancelled'; break }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $rows = @()
    foreach ($n in ($Levels | Sort-Object)) {
        $level = @($all | Where-Object { $_.Name -in $names[0..($n - 1)] })
        Write-Step "Level $n host(s): $(($level.Name | ForEach-Object { $_ -replace '^serverless-patch-', '' }) -join ', ')"
        Restore-Hosts $level
        Write-Ok "waiting $bootWait s for boot ($(if ($Platform -eq 'windows') { 'WinRM' } else { 'SSH' }))"
        Start-Sleep $bootWait

        $runInput = [ordered]@{ mode = 'patch'; reboot = $true; percent = 100; targets = @($level.Name); notify = [bool]$Notify }
        Save-Json ($runInput | ConvertTo-Json -Compress) (Join-Path $BuildDir 'exp3-input.json')
        $execName = "exp3-$Platform-n$n-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        $arn = (Invoke-Aws stepfunctions start-execution --state-machine-arn $StateMachineArn --name $execName `
                --input file://build/exp3-input.json).executionArn
        $t0 = Get-Date
        do {
            Start-Sleep $PollSeconds
            $d = Invoke-Aws stepfunctions describe-execution --execution-arn $arn
            Write-Host ("   {0}  {1}  elapsed {2:mm\:ss}" -f (Get-Date -Format 'HH:mm:ss'), $d.status, ((Get-Date) - $t0))
        } while ($d.status -eq 'RUNNING')

        $report = $null
        if ($d.output) { $report = $d.output | ConvertFrom-Json }
        elseif ($d.cause) { try { $report = $d.cause | ConvertFrom-Json } catch { } }
        Save-Json ([ordered]@{ execution = $arn; status = $d.status; error = $d.error; level = $n; report = $report }) `
            (Join-Path $EvidenceDir "$($arn.Split(':')[-1]).json") -Depth 30
        $hs = @($report.results)
        $durs = @($hs | Where-Object { $_.status -like 'patched*' } | ForEach-Object { [double]$_.duration_s })
        $row = [pscustomobject]@{
            Hosts      = $n
            Status     = $d.status
            Patched    = @($hs | Where-Object status -like 'patched*').Count
            Failed     = @($hs | Where-Object status -eq 'failed').Count
            CycleS     = $report.duration_s
            AvgHostS   = if ($durs) { [math]::Round(($durs | Measure-Object -Average).Average, 1) } else { $null }
            MaxHostS   = if ($durs) { ($durs | Measure-Object -Maximum).Maximum } else { $null }
            MinHostS   = if ($durs) { ($durs | Measure-Object -Minimum).Minimum } else { $null }
            Before     = (@($hs.advisories_before) | Select-Object -Unique) -join '/'
            Execution  = $arn.Split(':')[-1]
        }
        $rows += $row
        $row | Format-Table Hosts, Status, Patched, Failed, CycleS, AvgHostS, MinHostS, MaxHostS, Before -AutoSize | Out-String -Width 200 | Write-Host
    }

    Write-Step "Experiment 3 summary ($Platform)"
    $rows | Format-Table Hosts, Status, Patched, Failed, CycleS, AvgHostS, MinHostS, MaxHostS, Before -AutoSize | Out-String -Width 200 | Write-Host
    $csv = Join-Path $EvidenceDir "exp3-$Platform-summary-$stamp.csv"
    $rows | Export-Csv $csv -NoTypeInformation -Encoding utf8
    Write-Ok "saved $csv"
    Write-Note 'Hosts are left patched. Teardown clones with: .\exp3-scale.ps1 -Action teardown'
}

# ------------------------------------------------------------------ teardown
'teardown' {
    $r = Invoke-Aws ec2 describe-instances --filters "Name=tag:Experiment,Values=$ExpTag" 'Name=tag:project,Values=serverless-patch' `
        'Name=instance-state-name,Values=pending,running,stopping,stopped'
    $clones = @($r.Reservations.Instances | ForEach-Object { [pscustomobject]@{ Name = Get-Tag $_ 'Name'; Id = $_.InstanceId; State = $_.State.Name } })
    Write-Step 'Terminate Experiment 3 clones'
    if (-not $clones) { Write-Ok 'none found'; break }
    # Safety: never the testbed hosts.
    $clones = @($clones | Where-Object { $_.Id -notin @($Hosts.Values.Id) })
    $clones | Format-Table Name, Id, State -AutoSize | Out-String | Write-Host
    if ((Read-Host 'Type TERMINATE to delete these clones') -cne 'TERMINATE') { Write-Note 'cancelled'; break }
    Invoke-Aws ec2 terminate-instances --instance-ids @($clones.Id) | Out-Null
    Invoke-Aws ec2 wait instance-terminated --instance-ids @($clones.Id) | Out-Null
    Write-Ok "terminated $($clones.Count) clone(s); their volumes are deleted with them"
}
}
} finally { Pop-Location }
