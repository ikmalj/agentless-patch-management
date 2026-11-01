#Requires -Version 7.0
<#
.SYNOPSIS
  Return hosts to their unpatched baseline AMI with EC2 "replace root volume".
  Instance ID, private IP, tags and security groups stay the same, so nothing else
  in the framework changes. The patched root volume is deleted.
.EXAMPLE
  .\restore-baseline.ps1                       # rhel-01 and rhel-02
  .\restore-baseline.ps1 -Target win-01
#>
param([ValidateSet('rhel-01', 'rhel-02', 'win-01')][string[]]$Target = @('rhel-01', 'rhel-02'))
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\config.ps1"

Write-Step 'Restore to baseline AMI'
$Target | ForEach-Object { Write-Note ("{0}  {1}  <-  {2}" -f $_, $Hosts[$_].Id, $Hosts[$_].Ami) }
Write-Note 'The current root volume of each host is deleted. Any patching on it is lost.'
if ((Read-Host 'Type RESTORE to continue') -cne 'RESTORE') { Write-Note 'cancelled'; return }

# Replace root volume needs the instance running.
$ids = @($Target | ForEach-Object { $Hosts[$_].Id })
$states = (Invoke-Aws ec2 describe-instances --instance-ids @ids).Reservations.Instances
$stopped = @($states | Where-Object { $_.State.Name -ne 'running' } | ForEach-Object InstanceId)
if ($stopped) {
    Write-Ok "starting $($stopped -join ', ')"
    Invoke-Aws ec2 start-instances --instance-ids @stopped | Out-Null
    Invoke-Aws ec2 wait instance-running --instance-ids @stopped | Out-Null
}

$tasks = @{}
foreach ($key in $Target) {
    $h = $Hosts[$key]
    $t = Invoke-Aws ec2 create-replace-root-volume-task --instance-id $h.Id --image-id $h.Ami --delete-replaced-root-volume `
        --tag-specifications 'ResourceType=replace-root-volume-task,Tags=[{Key=project,Value=serverless-patch}]'
    $tasks[$key] = $t.ReplaceRootVolumeTask.ReplaceRootVolumeTaskId
    Write-Ok "$key task $($tasks[$key])"
}

Write-Step 'Waiting for the tasks (usually 2-5 minutes)'
$done = @{}
while ($done.Count -lt $tasks.Count) {
    Start-Sleep 20
    $r = Invoke-Aws ec2 describe-replace-root-volume-tasks --replace-root-volume-task-ids @($tasks.Values)
    foreach ($t in $r.ReplaceRootVolumeTasks) {
        $key = ($tasks.GetEnumerator() | Where-Object Value -eq $t.ReplaceRootVolumeTaskId).Key
        if (-not $key) { continue }
        if ($t.TaskState -in 'succeeded', 'failed', 'failed-detached') {
            if (-not $done[$key]) { $done[$key] = $t.TaskState; Write-Ok "$key $($t.TaskState)" }
        }
    }
    if ($done.Count -lt $tasks.Count) { Write-Host "   $(Get-Date -Format HH:mm:ss) still running..." }
}

Save-Json ([ordered]@{ restored_at = (Get-Date).ToString('s'); tasks = $tasks; result = $done }) `
    (Join-Path $EvidenceDir ("restore-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
if ($done.Values -contains 'succeeded') {
    Write-Note 'Hosts reboot onto the baseline disk. Wait ~1 min, then confirm with: .\test-rhel.ps1'
}
