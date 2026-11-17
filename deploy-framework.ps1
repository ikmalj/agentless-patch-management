#Requires -Version 7.0
<#
.SYNOPSIS
  Phase B deploy: RHEL patch Lambda, Step Functions state machine, EventBridge Scheduler.
  Safe to run again: every step updates what already exists.
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\config.ps1"
Push-Location $PSScriptRoot
try {

# ---------------------------------------------------------------- 1. endpoint
Write-Step '1/6 Secrets Manager endpoint'
$eps = @((Invoke-Aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VpcId" "Name=service-name,Values=$SmService").VpcEndpoints |
         Where-Object { $_.State -notin 'deleted', 'deleting' })
if ($eps.Count -gt 0) {
    Write-Ok "exists: $($eps[0].VpcEndpointId) ($($eps[0].State))"
} else {
    Write-Note 'not found, creating (hourly billing starts now)'
    $tags = 'ResourceType=vpc-endpoint,Tags=[{Key=project,Value=serverless-patch},{Key=Name,Value=serverless-patch-secretsmanager-vpce}]'
    $new = Invoke-Aws ec2 create-vpc-endpoint --vpc-id $VpcId --vpc-endpoint-type Interface --service-name $SmService `
        --subnet-ids $PrivSubnet --security-group-ids $EndpointSg --private-dns-enabled --tag-specifications $tags
    $epId = $new.VpcEndpoint.VpcEndpointId
    Write-Ok "created $epId, waiting for available..."
    for ($i = 0; $i -lt 40; $i++) {
        $state = (Invoke-Aws ec2 describe-vpc-endpoints --vpc-endpoint-ids $epId).VpcEndpoints[0].State
        if ($state -eq 'available') { break }
        Start-Sleep 10
    }
    Write-Ok "state: $state"
}

# ---------------------------------------------------------------- 2. Lambdas
function Update-PatchLambda([string]$Name, [string]$File, [int]$Timeout, [string]$Desc) {
    $zipName = "$Name.zip"
    Compress-Archive -Path (Join-Path $PSScriptRoot "lambda\$File") -DestinationPath (Join-Path $BuildDir $zipName) -Force
    Invoke-Aws lambda update-function-code --function-name $Name --zip-file "fileb://build/$zipName" | Out-Null
    Invoke-Aws lambda wait function-updated-v2 --function-name $Name | Out-Null
    Invoke-Aws lambda update-function-configuration --function-name $Name --timeout $Timeout --description $Desc | Out-Null
    Invoke-Aws lambda wait function-updated-v2 --function-name $Name | Out-Null
    $f = Invoke-Aws lambda get-function-configuration --function-name $Name
    Write-Ok "$Name  sha256 $($f.CodeSha256), timeout $($f.Timeout) s, layer $($f.Layers[0].Arn.Split(':')[-2]):$($f.Layers[0].Arn.Split(':')[-1])"
    return $f
}
Write-Step '2/6 Lambdas (code + timeout)'
$fn = Update-PatchLambda $RhelFn 'patch_rhel.py' 300 'serverless-patch RHEL actions: precheck, scan, install, reboot, health'
$wfn = Update-PatchLambda $WinFn 'patch_windows.py' 900 'serverless-patch Windows actions: precheck, scan, install (SYSTEM task), reboot, health'

# ---------------------------------------------------------------- 3. IAM roles
function Set-PatchRole([string]$Name, [string]$Trust, [string]$PolicyName, [string]$Policy) {
    $created = $false
    if (Test-Aws iam get-role --role-name $Name) {
        Invoke-Aws iam update-assume-role-policy --role-name $Name --policy-document "file://iam/$Trust" | Out-Null
        Write-Ok "$Name exists, trust policy refreshed"
    } else {
        Invoke-Aws iam create-role --role-name $Name --assume-role-policy-document "file://iam/$Trust" `
            --tags 'Key=project,Value=serverless-patch' | Out-Null
        Write-Ok "$Name created"
        $created = $true
    }
    Invoke-Aws iam put-role-policy --role-name $Name --policy-name $PolicyName --policy-document "file://iam/$Policy" | Out-Null
    Write-Ok "$Name inline policy $PolicyName set"
    return $created
}

Write-Step '3/6 IAM roles for Step Functions and Scheduler'
$new1 = Set-PatchRole $SfnRoleName   'sfn-trust.json'       'invoke-patch-lambdas-discover-ec2' 'sfn-policy.json'
$new2 = Set-PatchRole $SchedRoleName 'scheduler-trust.json' 'start-patch-cycle'                 'scheduler-policy.json'
if ($new1 -or $new2) { Write-Note 'new role(s): waiting 15 s for IAM to propagate'; Start-Sleep 15 }
$sfnRoleArn   = "arn:aws:iam::${Account}:role/$SfnRoleName"
$schedRoleArn = "arn:aws:iam::${Account}:role/$SchedRoleName"

# ---------------------------------------------------------------- 4. state machine
Write-Step "4/6 State machine $StateMachineName"
$def = 'file://statemachine/patch-cycle.asl.json'
$v = Invoke-Aws stepfunctions validate-state-machine-definition --definition $def --type STANDARD
if ($v.result -ne 'OK') {
    $v.diagnostics | Format-Table severity, code, location, message -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    throw 'state machine definition failed validation'
}
Write-Ok 'definition validated'
if (Test-Aws stepfunctions describe-state-machine --state-machine-arn $StateMachineArn) {
    Invoke-Aws stepfunctions update-state-machine --state-machine-arn $StateMachineArn --definition $def --role-arn $sfnRoleArn | Out-Null
    Write-Ok 'updated'
} else {
    for ($try = 1; $try -le 4; $try++) {
        try {
            Invoke-Aws stepfunctions create-state-machine --name $StateMachineName --definition $def --role-arn $sfnRoleArn `
                --type STANDARD --tags 'key=project,value=serverless-patch' | Out-Null
            break
        } catch {
            if ($try -eq 4 -or $_.Exception.Message -notmatch 'not authorized to assume|AccessDenied') { throw }
            Write-Note "role not assumable yet, retrying in 15 s ($try/3)"; Start-Sleep 15
        }
    }
    Write-Ok 'created'
}

# ---------------------------------------------------------------- 5. weekly schedule
Write-Step "5/6 EventBridge Scheduler $WeeklySchedule (created DISABLED)"
$target = @{
    Arn         = $StateMachineArn
    RoleArn     = $schedRoleArn
    Input       = (@{ mode = 'patch'; reboot = $true } | ConvertTo-Json -Compress)
    RetryPolicy = @{ MaximumEventAgeInSeconds = 3600; MaximumRetryAttempts = 0 }
}
$targetFile = Join-Path $BuildDir 'target-weekly.json'
Save-Json $target $targetFile
$schedArgs = @('--name', $WeeklySchedule,
    '--schedule-expression', 'cron(0 2 ? * SUN *)',
    '--schedule-expression-timezone', 'Asia/Kuala_Lumpur',
    '--flexible-time-window', 'Mode=OFF',
    '--state', 'DISABLED',
    '--description', 'Weekly patch window, Sunday 02:00 MYT. Enable only when hosts are meant to be patched.',
    '--target', 'file://build/target-weekly.json')
if (Test-Aws scheduler get-schedule --name $WeeklySchedule) {
    Invoke-Aws scheduler update-schedule @schedArgs | Out-Null; Write-Ok 'updated (DISABLED)'
} else {
    Invoke-Aws scheduler create-schedule @schedArgs | Out-Null; Write-Ok 'created (DISABLED)'
}

# ---------------------------------------------------------------- 6. summary
Write-Step '6/6 Summary'
$summary = [ordered]@{
    deployed_at      = (Get-Date).ToString('s')
    lambda           = $fn.FunctionArn
    lambda_sha256    = $fn.CodeSha256
    win_lambda       = $wfn.FunctionArn
    win_lambda_sha256 = $wfn.CodeSha256
    state_machine    = $StateMachineArn
    sfn_role         = $sfnRoleArn
    scheduler_role   = $schedRoleArn
    weekly_schedule  = $WeeklySchedule
}
$summary.GetEnumerator() | ForEach-Object { Write-Ok ('{0,-16} {1}' -f $_.Key, $_.Value) }
Save-Json $summary (Get-EvidenceFile deploy 'deploy-framework.json')
Write-Host "`nDone. Next: .\test-rhel.ps1" -ForegroundColor Cyan

} finally { Pop-Location }
