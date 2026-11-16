#Requires -Version 7.0
<#
.SYNOPSIS
  Experiment 3 (scalability): patch an increasing number of hosts and record the cycle time per level.

  Main series:  RHEL at 1, 2, 4, 6, 8 hosts (rhel-01, rhel-02 + clones rhel-03..08 of the rhel-01 baseline AMI)
  Add-on:       Windows at 1 and 2 hosts (win-01 + clone win-02 of the win-01 baseline AMI)
  Mixed:        both platforms in the testbed ratio of two RHEL hosts to one Windows host.
                Hosts join in the order rhel-01, rhel-02, win-01, rhel-03, rhel-04, win-02, so level 3 is
                the testbed and level 6 doubles it (clones rhel-03, rhel-04 and win-02).

  Every level starts from baseline: the hosts in that level get their root volume replaced from the
  baseline AMI, then one patch cycle runs on exactly those hosts (targets), and the result is saved.
  Clones are tagged Experiment=exp3 and are removed with -Action teardown.

.EXAMPLE
  .\exp3-scale.ps1 -Action status
  .\exp3-scale.ps1 -Action launch -Platform rhel -Total 8          # adds rhel-03..rhel-08 (stop win-01 first)
  .\exp3-scale.ps1 -Action run    -Platform rhel -Levels 1,2,4,6,8
  .\exp3-scale.ps1 -Action launch -Platform windows -Total 2       # adds win-02 (stop the RHEL hosts first)
  .\exp3-scale.ps1 -Action run    -Platform windows -Levels 1,2
  .\exp3-scale.ps1 -Action launch -Platform mixed -Total 6         # adds rhel-03, rhel-04, win-02 (12 of 16 vCPUs)
  .\exp3-scale.ps1 -Action run    -Platform mixed -Levels 3,6
  .\exp3-scale.ps1 -Action collect -Platform mixed                 # after an interrupted run: save results, write the summary
  .\exp3-scale.ps1 -Action teardown                                # terminates every Experiment=exp3 clone
#>
param(
    [Parameter(Mandatory)][ValidateSet('status', 'launch', 'run', 'collect', 'teardown')][string]$Action,
    [ValidateSet('rhel', 'windows', 'mixed')][string]$Platform = 'rhel',
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
# Mixed defaults: the testbed (3 hosts) and the testbed doubled (6 hosts).
if ($Platform -eq 'mixed' -and -not $PSBoundParameters.ContainsKey('Levels')) { $Levels = @('3', '6') }
if ($Platform -eq 'mixed' -and -not $PSBoundParameters.ContainsKey('Total')) { $Total = 6 }
# Accept -Levels 1,2,4 typed at the prompt or passed as one string "1,2,4". Kept as numbers in $LevelNums
# ($Levels is a [string[]] parameter, so numbers assigned back to it would turn into text again).
[int[]]$LevelNums = @($Levels -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ } | Sort-Object -Unique)
if (-not $LevelNums -or ($LevelNums | Where-Object { $_ -lt 1 -or $_ -gt 8 })) { throw 'levels must be between 1 and 8' }
$rhelNames = @(1..8 | ForEach-Object { 'serverless-patch-rhel-{0:00}' -f $_ })
$winNames  = @(1..8 | ForEach-Object { 'serverless-patch-win-{0:00}' -f $_ })
# The order in which hosts join a level: level n patches the first n names.
$names = switch ($Platform) {
    'rhel'    { $rhelNames }
    'windows' { $winNames }
    'mixed'   { @($rhelNames[0], $rhelNames[1], $winNames[0], $rhelNames[2], $rhelNames[3], $winNames[1], $rhelNames[4], $rhelNames[5]) }
}
$OsValues = if ($Platform -eq 'mixed') { 'rhel,windows' } else { $Platform }

function Get-HostOs([string]$Name) { if ($Name -like 'serverless-patch-win-*') { 'windows' } else { 'rhel' } }
# Clones copy rhel-01 or win-01: same AMI, instance type, subnet, security group and key.
function Get-SourceHost([string]$Name) { if ((Get-HostOs $Name) -eq 'windows') { $Hosts['win-01'] } else { $Hosts['rhel-01'] } }

function Get-Tag($inst, [string]$key) { ($inst.Tags | Where-Object Key -eq $key).Value }

# All serverless-patch instances of this platform (testbed + clones), not terminated.
function Get-PlatformHosts {
    $r = Invoke-Aws ec2 describe-instances --filters 'Name=tag:project,Values=serverless-patch' "Name=tag:PatchOS,Values=$OsValues" `
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
    if ($own) { $own.Ami } else { (Get-SourceHost $Name).Ami }
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

# One summary row per level, from the cycle report.
function Get-LevelRow([int]$n, $d, $report, [string]$arn) {
    $hs = @($report.results)
    $ok = @($hs | Where-Object { $_.status -like 'patched*' })
    $durs = @($ok | ForEach-Object { [double]$_.duration_s })
    $rd = @($ok | Where-Object platform -eq 'rhel' | ForEach-Object { [double]$_.duration_s })
    $wd = @($ok | Where-Object platform -eq 'windows' | ForEach-Object { [double]$_.duration_s })
    [pscustomobject]@{
        Hosts      = $n
        Status     = $d.status
        Patched    = $ok.Count
        Failed     = @($hs | Where-Object status -eq 'failed').Count
        CycleS     = $report.duration_s
        AvgHostS   = if ($durs) { [math]::Round(($durs | Measure-Object -Average).Average, 1) } else { $null }
        MaxHostS   = if ($durs) { ($durs | Measure-Object -Maximum).Maximum } else { $null }
        MinHostS   = if ($durs) { ($durs | Measure-Object -Minimum).Minimum } else { $null }
        RhelAvgS   = if ($rd) { [math]::Round(($rd | Measure-Object -Average).Average, 1) } else { $null }
        WinAvgS    = if ($wd) { [math]::Round(($wd | Measure-Object -Average).Average, 1) } else { $null }
        Before     = (@($hs.advisories_before) | Select-Object -Unique) -join '/'
        Execution  = $arn.Split(':')[-1]
    }
}
function Get-Report($d) {
    if ($d.output) { return $d.output | ConvertFrom-Json }
    if ($d.cause) { try { return $d.cause | ConvertFrom-Json } catch { } }
    $null
}
$cols = if ($Platform -eq 'mixed') { 'Hosts', 'Status', 'Patched', 'Failed', 'CycleS', 'RhelAvgS', 'WinAvgS', 'MaxHostS', 'Before' }
        else { 'Hosts', 'Status', 'Patched', 'Failed', 'CycleS', 'AvgHostS', 'MinHostS', 'MaxHostS', 'Before' }

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
    $Total = [math]::Min($Total, $names.Count)
    $want = $names[0..($Total - 1)]
    $missing = @($want | Where-Object { $_ -notin $have.Name })
    Write-Step "Launch $Platform clones up to $Total host(s)"
    if (-not $missing) { Write-Ok "all $Total already exist"; break }
    # One launch per platform: each clone copies its source host (rhel-01 or win-01).
    $plan = @(foreach ($g in @($missing | Group-Object -Property { Get-HostOs $_ })) {
        $s = Get-SourceHost $g.Group[0]
        $ref = (Invoke-Aws ec2 describe-instances --instance-ids $s.Id).Reservations[0].Instances[0]
        $per = ((Invoke-Aws ec2 describe-instance-types --instance-types $ref.InstanceType).InstanceTypes[0]).VCpuInfo.DefaultVCpus
        [pscustomobject]@{ Os = $g.Name; Names = @($g.Group); Src = $s; Ref = $ref; Per = $per }
    })
    $v = Get-VcpuUse
    $need = $v.Used
    foreach ($p in $plan) { $need += $p.Per * $p.Names.Count }
    $stopped = @($have | Where-Object { $_.Name -in $want -and $_.State -ne 'running' })
    if ($stopped) {
        $info = (Invoke-Aws ec2 describe-instance-types --instance-types @($stopped.Type | Sort-Object -Unique)).InstanceTypes
        foreach ($h in $stopped) { $need += ($info | Where-Object InstanceType -eq $h.Type).VCpuInfo.DefaultVCpus }
    }
    foreach ($p in $plan) { Write-Ok "new $($p.Os): $($p.Names -join ', ') ($($p.Ref.InstanceType), $($p.Per) vCPU each, from $($p.Src.Name))" }
    Write-Ok "vCPUs after the level runs: $need of $($v.Quota)"
    if ($need -gt $v.Quota) {
        throw "not enough vCPU quota ($need > $($v.Quota)). Stop the hosts this experiment does not use first (.\lab.ps1 stop-all, then start only what you need)."
    }
    $launched = @()
    foreach ($p in $plan) {
        $ref = $p.Ref
        $sgs = @($ref.SecurityGroups.GroupId)
        $tags = "ResourceType=instance,Tags=[{Key=project,Value=serverless-patch},{Key=PatchTarget,Value=true},{Key=PatchOS,Value=$($p.Os)},{Key=Workload,Value=$(Get-Tag $ref 'Workload')},{Key=Experiment,Value=$ExpTag}]"
        $runArgs = @('ec2', 'run-instances', '--image-id', $p.Src.Ami, '--instance-type', $ref.InstanceType, '--count', $p.Names.Count,
                  '--subnet-id', $ref.SubnetId, '--security-group-ids') + $sgs + @(
                  '--metadata-options', 'HttpTokens=required,HttpEndpoint=enabled',
                  '--tag-specifications', $tags, 'ResourceType=volume,Tags=[{Key=project,Value=serverless-patch},{Key=Experiment,Value=exp3}]')
        if ($ref.KeyName) { $runArgs += @('--key-name', $ref.KeyName) }
        if ($ref.InstanceType -like 't*') { $runArgs += @('--credit-specification', 'CpuCredits=standard') }
        $new = @((Invoke-Aws @runArgs).Instances)
        for ($i = 0; $i -lt $new.Count; $i++) {
            Invoke-Aws ec2 create-tags --resources $new[$i].InstanceId --tags "Key=Name,Value=$($p.Names[$i])" | Out-Null
            Write-Ok "$($p.Names[$i])  $($new[$i].InstanceId)"
            $launched += [pscustomobject]@{ Name = $p.Names[$i]; Id = $new[$i].InstanceId; Ami = $p.Src.Ami }
        }
    }
    Invoke-Aws ec2 wait instance-running --instance-ids @($launched.Id) | Out-Null
    Write-Ok 'running. They are already at baseline (fresh from the AMI); every level restores them again anyway.'
    Save-Json ([ordered]@{ launched_at = (Get-Date).ToString('s'); platform = $Platform
                          instances = @($launched.Id); names = @($launched.Name); amis = @($launched.Ami) }) `
        (Join-Path $EvidenceDir ("exp3-launch-{0}-{1}.json" -f $Platform, (Get-Date -Format 'yyyyMMdd-HHmmss')))
}

# ------------------------------------------------------------------ run
'run' {
    $all = Get-PlatformHosts
    $maxLevel = ($LevelNums | Measure-Object -Maximum).Maximum
    if ($maxLevel -gt $names.Count) { throw "level $maxLevel is more than the $($names.Count) hosts this platform has" }
    $use = $names[0..($maxLevel - 1)]
    $absent = @($use | Where-Object { $_ -notin $all.Name })
    if ($absent) { throw "missing hosts for level ${maxLevel}: $($absent -join ', '). Run -Action launch -Platform $Platform -Total $maxLevel first." }
    $v = Get-VcpuUse
    Write-Step "Experiment 3 ($Platform), levels $($LevelNums -join ', ')"
    Write-Ok "vCPUs in use now: $($v.Used) of $($v.Quota)"
    Write-Note 'Each level: restore the level hosts to baseline, wait for boot, run one patch cycle on exactly those hosts.'
    Write-Note ("Email per level: " + $(if ($Notify) { 'yes' } else { 'no (use -Notify to send)' }))
    if ((Read-Host 'Type SCALE to start') -cne 'SCALE') { Write-Note 'cancelled'; break }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $rows = @()
    foreach ($n in $LevelNums) {
        $level = @($all | Where-Object { $_.Name -in $names[0..($n - 1)] })
        Write-Step "Level $n host(s): $(($level.Name | ForEach-Object { $_ -replace '^serverless-patch-', '' }) -join ', ')"
        Restore-Hosts $level
        $hasWin = [bool]($level.Name | Where-Object { (Get-HostOs $_) -eq 'windows' })
        $bootWait = if ($hasWin) { 300 } else { 90 }
        Write-Ok "waiting $bootWait s for boot ($(if ($hasWin) { 'WinRM' } else { 'SSH' }))"
        Start-Sleep $bootWait

        $runInput = [ordered]@{ mode = 'patch'; reboot = $true; percent = 100; targets = @($level.Name); notify = [bool]$Notify }
        Save-Json ($runInput | ConvertTo-Json -Compress) (Join-Path $BuildDir 'exp3-input.json')
        $execName = "exp3-$Platform-n$n-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        $arn = (Invoke-Aws stepfunctions start-execution --state-machine-arn $StateMachineArn --name $execName `
                --input file://build/exp3-input.json).executionArn
        $t0 = Get-Date
        $warned = $false
        do {
            Start-Sleep $PollSeconds
            # The cycle runs in Step Functions whether or not this window can reach AWS. If a call fails
            # (most often an expired sign-in), keep waiting: sign in again in another window and this continues.
            try { $d = Invoke-Aws stepfunctions describe-execution --execution-arn $arn; $warned = $false }
            catch {
                if (-not $warned) {
                    Write-Note "cannot reach AWS: $(($_.Exception.Message -split "`n" | Where-Object { $_ } | Select-Object -Last 1))"
                    Write-Note 'The cycle keeps running. If your sign-in expired, run  aws login  in another PowerShell window; this run then continues.'
                    $warned = $true
                }
                $d = [pscustomobject]@{ status = 'RUNNING' }
                continue
            }
            Write-Host ("   {0}  {1}  elapsed {2:mm\:ss}" -f (Get-Date -Format 'HH:mm:ss'), $d.status, ((Get-Date) - $t0))
        } while ($d.status -eq 'RUNNING')

        $report = Get-Report $d
        Save-Json ([ordered]@{ execution = $arn; status = $d.status; error = $d.error; level = $n; report = $report }) `
            (Join-Path $EvidenceDir "$($arn.Split(':')[-1]).json") -Depth 30
        $row = Get-LevelRow $n $d $report $arn
        $rows += $row
        $row | Format-Table $cols -AutoSize | Out-String -Width 200 | Write-Host
    }

    Write-Step "Experiment 3 summary ($Platform)"
    $rows | Format-Table $cols -AutoSize | Out-String -Width 200 | Write-Host
    $csv = Join-Path $EvidenceDir "exp3-$Platform-summary-$stamp.csv"
    $rows | Export-Csv $csv -Encoding utf8
    Write-Ok "saved $csv"
    Write-Note 'Hosts are left patched. Teardown clones with: .\exp3-scale.ps1 -Action teardown'
}

# ------------------------------------------------------------------ collect
# For a run whose PowerShell window stopped (expired sign-in, closed window, lost network): the cycles
# themselves keep running in Step Functions. This finds today's exp3-<platform>-n<level> executions, waits for
# any still running, saves each one's evidence file if it is missing, and writes the summary CSV.
'collect' {
    $today = Get-Date -Format 'yyyyMMdd'
    $ex = @((Invoke-Aws stepfunctions list-executions --state-machine-arn $StateMachineArn --max-results 50).executions |
            Where-Object { $_.name -match "^exp3-$Platform-n(\d+)-$today-" })
    Write-Step "Collect Experiment 3 ($Platform) executions from today"
    if (-not $ex) { Write-Note "no exp3-$Platform executions today"; break }
    # The latest execution per level counts (a level that was run again replaces the earlier attempt).
    $latest = @($ex | Group-Object { [int]($_.name -replace "^exp3-$Platform-n(\d+)-.*$", '$1') } |
                ForEach-Object { $_.Group | Sort-Object startDate | Select-Object -Last 1 } | Sort-Object startDate)
    $latest | ForEach-Object { [pscustomobject]@{ Execution = $_.name; Status = $_.status } } | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    $rows = @()
    foreach ($e in $latest) {
        $n = [int]($e.name -replace "^exp3-$Platform-n(\d+)-.*$", '$1')
        $t0 = Get-Date
        do {
            $d = Invoke-Aws stepfunctions describe-execution --execution-arn $e.executionArn
            if ($d.status -eq 'RUNNING') {
                Write-Host ("   {0}  level {1} still RUNNING, waiting  {2:mm\:ss}" -f (Get-Date -Format 'HH:mm:ss'), $n, ((Get-Date) - $t0))
                Start-Sleep $PollSeconds
            }
        } while ($d.status -eq 'RUNNING')
        $report = Get-Report $d
        $file = Join-Path $EvidenceDir "$($e.name).json"
        if (Test-Path $file) { Write-Ok "level ${n}: evidence already saved" }
        else {
            Save-Json ([ordered]@{ execution = $e.executionArn; status = $d.status; error = $d.error; level = $n; report = $report }) $file -Depth 30
            Write-Ok "level ${n}: saved $file"
        }
        $rows += Get-LevelRow $n $d $report $e.executionArn
    }
    Write-Step "Experiment 3 summary ($Platform)"
    $rows | Format-Table $cols -AutoSize | Out-String -Width 200 | Write-Host
    $csv = Join-Path $EvidenceDir "exp3-$Platform-summary-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
    $rows | Export-Csv $csv -Encoding utf8
    Write-Ok "saved $csv"
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
    $clones | Format-Table Name, Id, State -AutoSize | Out-String -Width 200 | Write-Host
    if ((Read-Host 'Type TERMINATE to delete these clones') -cne 'TERMINATE') { Write-Note 'cancelled'; break }
    Invoke-Aws ec2 terminate-instances --instance-ids @($clones.Id) | Out-Null
    Invoke-Aws ec2 wait instance-terminated --instance-ids @($clones.Id) | Out-Null
    Write-Ok "terminated $($clones.Count) clone(s); their volumes are deleted with them"
}
}
} finally { Pop-Location }
