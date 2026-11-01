#Requires -Version 7.0
<#
.SYNOPSIS
  Phase D deploy: visibility layer for serverless-patch-cycle.
    1. SNS topic serverless-patch-notify + email subscription
    2. Metrics Lambda serverless-patch-metrics (outside the VPC, no secret access) + its role and log group
    3. Step Functions role policy (invoke metrics Lambda, publish to the topic)
    4. State machine update (Record Metrics, Notify Result, run-error notification)
    5. Custom widget Lambda serverless-patch-summary-widget (coloured Patch Summary panels)
    6. CloudWatch dashboard PatchManagement-Dashboard (v3 layout from dashboard\dashboard-v3.json)
  Safe to run again: every step updates what already exists. Does not touch any host.

.PARAMETER DashboardOnly
  Rebuild only the dashboard, for example after tagging extra hosts for Experiment 3.

.EXAMPLE
  .\deploy-monitoring.ps1
  .\deploy-monitoring.ps1 -DashboardOnly
#>
param([switch]$DashboardOnly)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\config.ps1"
Push-Location $PSScriptRoot
try {

$sfnRoleArn     = "arn:aws:iam::${Account}:role/$SfnRoleName"
$metricsRoleArn = "arn:aws:iam::${Account}:role/$MetricsRoleName"
$WidgetFn       = 'serverless-patch-summary-widget'
$WidgetRoleName = 'serverless-patch-widget-lambda-role'
$WidgetLogGroup = "/aws/lambda/$WidgetFn"
$widgetFnArn    = "arn:aws:lambda:${Region}:${Account}:function:$WidgetFn"
$step = 0
$total = if ($DashboardOnly) { 2 } else { 7 }
function Next-Step([string]$Text) { $script:step++; Write-Step "$($script:step)/$total $Text" }

# ---------------------------------------------------------------- dashboard builder
# Hosts: the testbed hosts from config.ps1 plus any other instance tagged PatchTarget=true
# (Experiment 3 scale-out hosts), so the per-host widgets list every patched host.
function Get-DashboardHosts {
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($k in $Hosts.Keys) {
        $list.Add([pscustomobject]@{ Name = $Hosts[$k].Name; Platform = $(if ($k -like 'win-*') { 'windows' } else { 'rhel' }) })
    }
    $res = Invoke-Aws ec2 describe-instances --filters 'Name=tag:PatchTarget,Values=true' 'Name=tag:project,Values=serverless-patch' `
        'Name=instance-state-name,Values=pending,running,stopping,stopped'
    foreach ($i in $res.Reservations.Instances) {
        $name = ($i.Tags | Where-Object Key -eq 'Name').Value
        $os   = ($i.Tags | Where-Object Key -eq 'PatchOS').Value
        if ($name -and $os -in 'rhel', 'windows' -and -not ($list | Where-Object Name -eq $name)) {
            $list.Add([pscustomobject]@{ Name = $name; Platform = $os })
        }
    }
    return @($list | Sort-Object Platform, Name)
}

# Dashboard v3: the layout lives in dashboard\dashboard-v3.json with __TOKENS__ filled in here.
# The Host selector is a pattern variable: it swaps the default host name in the drill-down row,
# so that host name must appear nowhere else in the template.
function Set-Dashboard {
    $dashHosts = Get-DashboardHosts
    if (-not $dashHosts) { throw 'no PatchTarget hosts found for the Host selector' }
    Write-Ok ("hosts in the Host selector: " + (($dashHosts | ForEach-Object { "$($_.Name) ($($_.Platform))" }) -join ', '))
    $default = ($dashHosts | Where-Object Platform -eq 'rhel' | Select-Object -First 1).Name
    if (-not $default) { $default = $dashHosts[0].Name }
    $values = @($dashHosts | ForEach-Object {
        [ordered]@{ value = $_.Name; label = ('{0} ({1})' -f ($_.Name -replace '^serverless-patch-', ''), $_.Platform) } })
    $tokens = [ordered]@{
        '"__HOST_VALUES__"'      = (ConvertTo-Json -InputObject $values -Depth 5 -Compress)
        '__DEFAULT_HOST__'       = $default
        '__STATE_MACHINE_ARN__'  = $StateMachineArn
        '__STATE_MACHINE_NAME__' = $StateMachineName
        '__NAMESPACE__'          = $MetricNamespace
        '__LOG_GROUP__'          = $MetricsLogGroup
        '__TOPIC_NAME__'         = $TopicName
        '__RHEL_FN__'            = $RhelFn
        '__WIN_FN__'             = $WinFn
        '__METRICS_FN__'         = $MetricsFn
        '__WIDGET_FN_ARN__'      = $widgetFnArn
        '__REGION__'             = $Region
    }
    $tpl = Get-Content (Join-Path $PSScriptRoot 'dashboard\dashboard-v3.json') -Raw
    foreach ($k in $tokens.Keys) { $tpl = $tpl.Replace($k, [string]$tokens[$k]) }
    if ($tpl -match '__[A-Z_]+__') { throw "dashboard template has an unfilled token: $($Matches[0])" }
    $body = $tpl | ConvertFrom-Json -Depth 50        # fails here if the JSON is broken
    Save-Json $tpl (Join-Path $BuildDir 'dashboard-body.json')
    $r = Invoke-Aws cloudwatch put-dashboard --dashboard-name $DashboardName --dashboard-body file://build/dashboard-body.json
    if ($r.DashboardValidationMessages) {
        $r.DashboardValidationMessages | Format-Table DataPath, Message -AutoSize -Wrap | Out-String -Width 220 | Write-Host
        throw 'dashboard body was rejected'
    }
    Write-Ok "$DashboardName saved (v3, $($body.widgets.Count) widgets, Host selector default $default)"
    Write-Ok $DashboardUrl
}

if ($DashboardOnly) {
    Next-Step "Dashboard $DashboardName"
    Set-Dashboard
    Next-Step 'Done'
    return
}

# ---------------------------------------------------------------- 1. SNS
Next-Step "SNS topic $TopicName"
$topic = Invoke-Aws sns create-topic --name $TopicName --tags 'Key=project,Value=serverless-patch'
Write-Ok "topic $($topic.TopicArn)"
$subs = @((Invoke-Aws sns list-subscriptions-by-topic --topic-arn $TopicArn).Subscriptions | Where-Object { $_.Protocol -eq 'email' -and $_.Endpoint -eq $NotifyEmail })
if ($subs.Count -eq 0) {
    Invoke-Aws sns subscribe --topic-arn $TopicArn --protocol email --notification-endpoint $NotifyEmail | Out-Null
    Write-Note "subscription requested for $NotifyEmail. Open the AWS Notification email and click Confirm subscription."
} elseif ($subs[0].SubscriptionArn -eq 'PendingConfirmation') {
    Write-Note "$NotifyEmail is still PendingConfirmation. Click the link in the AWS Notification email (check spam)."
} else {
    Write-Ok "$NotifyEmail confirmed"
}

# ---------------------------------------------------------------- 2. metrics Lambda
Next-Step "Metrics Lambda $MetricsFn"
$roleCreated = $false
if (Test-Aws iam get-role --role-name $MetricsRoleName) {
    Invoke-Aws iam update-assume-role-policy --role-name $MetricsRoleName --policy-document 'file://iam/metrics-lambda-trust.json' | Out-Null
    Write-Ok "$MetricsRoleName exists, trust policy refreshed"
} else {
    Invoke-Aws iam create-role --role-name $MetricsRoleName --assume-role-policy-document 'file://iam/metrics-lambda-trust.json' `
        --tags 'Key=project,Value=serverless-patch' | Out-Null
    Write-Ok "$MetricsRoleName created"
    $roleCreated = $true
}
Invoke-Aws iam put-role-policy --role-name $MetricsRoleName --policy-name 'write-logs-read-cycle-history' `
    --policy-document 'file://iam/metrics-lambda-policy.json' | Out-Null
Write-Ok 'inline policy write-logs-read-cycle-history set (own log group + GetExecutionHistory only)'

# Log group first, so retention and tags are set before the first record arrives.
$lg = @((Invoke-Aws logs describe-log-groups --log-group-name-prefix $MetricsLogGroup).logGroups | Where-Object logGroupName -eq $MetricsLogGroup)
if (-not $lg) {
    Invoke-Aws logs create-log-group --log-group-name $MetricsLogGroup --tags 'project=serverless-patch' | Out-Null
    Write-Ok "log group $MetricsLogGroup created"
}
Invoke-Aws logs put-retention-policy --log-group-name $MetricsLogGroup --retention-in-days 365 | Out-Null
Write-Ok 'log retention 365 days (keeps the evaluation records through the report)'

$envFile = Join-Path $BuildDir 'metrics-env.json'
Save-Json @{ Variables = @{
    METRIC_NAMESPACE       = $MetricNamespace
    STATE_MACHINE_NAME     = $StateMachineName
    PATCH_LAMBDA_MEMORY_MB = '256'
    PRICE_SFN_TRANSITION   = '0.000025'
    PRICE_LAMBDA_GB_S      = '0.0000166667'
    PRICE_LAMBDA_REQUEST   = '0.0000002'
    PRICE_SNS_PUBLISH      = '0.0000005'
    PRICE_SNS_EMAIL        = '0.00002'
} } $envFile
Compress-Archive -Path (Join-Path $PSScriptRoot 'lambda\metrics.py') -DestinationPath (Join-Path $BuildDir "$MetricsFn.zip") -Force
$desc = 'serverless-patch Phase D: EMF metrics, cost estimate and notification text. No host access, no VPC.'
if (Test-Aws lambda get-function --function-name $MetricsFn) {
    Invoke-Aws lambda update-function-code --function-name $MetricsFn --zip-file "fileb://build/$MetricsFn.zip" | Out-Null
    Invoke-Aws lambda wait function-updated-v2 --function-name $MetricsFn | Out-Null
    Invoke-Aws lambda update-function-configuration --function-name $MetricsFn --timeout 60 --memory-size 128 `
        --description $desc --environment file://build/metrics-env.json | Out-Null
    Write-Ok 'updated'
} else {
    if ($roleCreated) { Write-Note 'new role: waiting 15 s for IAM to propagate'; Start-Sleep 15 }
    for ($try = 1; $try -le 4; $try++) {
        try {
            Invoke-Aws lambda create-function --function-name $MetricsFn --runtime python3.13 --architectures x86_64 `
                --handler metrics.lambda_handler --role $metricsRoleArn --zip-file "fileb://build/$MetricsFn.zip" `
                --timeout 60 --memory-size 128 --description $desc --environment file://build/metrics-env.json `
                --tags 'project=serverless-patch' | Out-Null
            break
        } catch {
            if ($try -eq 4 -or $_.Exception.Message -notmatch 'cannot be assumed|InvalidParameterValue') { throw }
            Write-Note "role not assumable yet, retrying in 15 s ($try/3)"; Start-Sleep 15
        }
    }
    Write-Ok 'created'
}
Invoke-Aws lambda wait function-updated-v2 --function-name $MetricsFn | Out-Null
$mf = Invoke-Aws lambda get-function-configuration --function-name $MetricsFn
Write-Ok "$MetricsFn  sha256 $($mf.CodeSha256), $($mf.Runtime), $($mf.MemorySize) MB, timeout $($mf.Timeout) s, VPC: $(if ($mf.VpcConfig.SubnetIds) { 'yes (unexpected)' } else { 'none' })"

# Read-only self test against a real result file (no execution ARN, so no history call).
$sample = Get-ChildItem (Join-Path $EvidenceDir 'cycle-patch-*.json') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
if ($sample) {
    $rep = (Get-Content $sample.FullName -Raw | ConvertFrom-Json).report
    Save-Json @{ kind = 'cycle'; report = $rep; notify = $false; self_test = $true } (Join-Path $BuildDir 'metrics-selftest.json') -Depth 30
    Write-Note "self test with $($sample.Name) (formats the message only, writes no metrics)"
    $meta = Invoke-Aws lambda invoke --function-name $MetricsFn --cli-binary-format raw-in-base64-out `
        --payload file://build/metrics-selftest.json build/metrics-selftest-out.json
    $out = Get-Content (Join-Path $BuildDir 'metrics-selftest-out.json') -Raw | ConvertFrom-Json
    if ($meta.FunctionError) { throw "metrics self test failed: $($out.errorType): $($out.errorMessage)" }
    Write-Ok "self test ok, subject: $($out.subject)"
}

# ---------------------------------------------------------------- 3. Step Functions role
Next-Step "Step Functions role $SfnRoleName"
Invoke-Aws iam put-role-policy --role-name $SfnRoleName --policy-name 'invoke-patch-lambdas-discover-ec2' `
    --policy-document 'file://iam/sfn-policy.json' | Out-Null
Write-Ok 'policy now also allows: invoke serverless-patch-metrics, sns:Publish to serverless-patch-notify'

# ---------------------------------------------------------------- 4. state machine
Next-Step "State machine $StateMachineName"
$def = 'file://statemachine/patch-cycle.asl.json'
$v = Invoke-Aws stepfunctions validate-state-machine-definition --definition $def --type STANDARD
if ($v.result -ne 'OK') {
    $v.diagnostics | Format-Table severity, code, location, message -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    throw 'state machine definition failed validation'
}
if ($v.diagnostics) {
    $v.diagnostics | Format-Table severity, code, location, message -AutoSize -Wrap | Out-String -Width 220 | Write-Host
}
Write-Ok 'definition validated'
Invoke-Aws stepfunctions update-state-machine --state-machine-arn $StateMachineArn --definition $def --role-arn $sfnRoleArn | Out-Null
Write-Ok 'updated (Record Metrics, Should Notify, Notify Result, Format Run Error, Notify Run Error, Run Errored)'

# ---------------------------------------------------------------- 5. custom widget Lambda
Next-Step "Custom widget Lambda $WidgetFn"
$wRoleNew = $false
if (Test-Aws iam get-role --role-name $WidgetRoleName) {
    Invoke-Aws iam update-assume-role-policy --role-name $WidgetRoleName --policy-document 'file://iam/metrics-lambda-trust.json' | Out-Null
    Write-Ok "$WidgetRoleName exists, trust policy refreshed"
} else {
    Invoke-Aws iam create-role --role-name $WidgetRoleName --assume-role-policy-document 'file://iam/metrics-lambda-trust.json' `
        --tags 'Key=project,Value=serverless-patch' | Out-Null
    Write-Ok "$WidgetRoleName created"
    $wRoleNew = $true
}
Invoke-Aws iam put-role-policy --role-name $WidgetRoleName --policy-name 'query-metrics-records' `
    --policy-document 'file://iam/widget-lambda-policy.json' | Out-Null
Write-Ok 'inline policy query-metrics-records set (Logs Insights on the metrics log group only, own logs)'
$wlg = @((Invoke-Aws logs describe-log-groups --log-group-name-prefix $WidgetLogGroup).logGroups | Where-Object logGroupName -eq $WidgetLogGroup)
if (-not $wlg) { Invoke-Aws logs create-log-group --log-group-name $WidgetLogGroup --tags 'project=serverless-patch' | Out-Null }
Invoke-Aws logs put-retention-policy --log-group-name $WidgetLogGroup --retention-in-days 30 | Out-Null
Save-Json @{ Variables = @{ LOG_GROUP = $MetricsLogGroup } } (Join-Path $BuildDir 'widget-env.json')
Compress-Archive -Path (Join-Path $PSScriptRoot 'lambda\summary_widget.py') -DestinationPath (Join-Path $BuildDir "$WidgetFn.zip") -Force
$wDesc = 'serverless-patch dashboard custom widget: coloured Patch Summary panels (HTML/CSS). Read-only, no VPC.'
if (Test-Aws lambda get-function --function-name $WidgetFn) {
    Invoke-Aws lambda update-function-code --function-name $WidgetFn --zip-file "fileb://build/$WidgetFn.zip" | Out-Null
    Invoke-Aws lambda wait function-updated-v2 --function-name $WidgetFn | Out-Null
    Invoke-Aws lambda update-function-configuration --function-name $WidgetFn --timeout 60 --memory-size 256 `
        --description $wDesc --environment file://build/widget-env.json | Out-Null
    Write-Ok 'updated'
} else {
    if ($wRoleNew) { Write-Note 'new role: waiting 15 s for IAM to propagate'; Start-Sleep 15 }
    for ($try = 1; $try -le 4; $try++) {
        try {
            Invoke-Aws lambda create-function --function-name $WidgetFn --runtime python3.13 --architectures x86_64 `
                --handler summary_widget.lambda_handler --role "arn:aws:iam::${Account}:role/$WidgetRoleName" `
                --zip-file "fileb://build/$WidgetFn.zip" --timeout 60 --memory-size 256 --description $wDesc `
                --environment file://build/widget-env.json --tags 'project=serverless-patch' | Out-Null
            break
        } catch {
            if ($try -eq 4 -or $_.Exception.Message -notmatch 'cannot be assumed|InvalidParameterValue') { throw }
            Write-Note "role not assumable yet, retrying in 15 s ($try/3)"; Start-Sleep 15
        }
    }
    Write-Ok 'created'
}
Invoke-Aws lambda wait function-updated-v2 --function-name $WidgetFn | Out-Null
Save-Json @{ view = 'kpi'; widgetContext = @{ theme = 'light' } } (Join-Path $BuildDir 'widget-test.json')
$meta = Invoke-Aws lambda invoke --function-name $WidgetFn --cli-binary-format raw-in-base64-out `
    --payload file://build/widget-test.json build/widget-test-out.json
$wout = Get-Content (Join-Path $BuildDir 'widget-test-out.json') -Raw
if ($meta.FunctionError) { throw "widget test failed: $wout" }
if ($wout -match 'Widget error: ([^<]+)') { Write-Note "widget answered with an error: $($Matches[1])" }
else { Write-Ok "test call ok ($($wout.Length) characters of HTML for the last 7 days)" }

# ---------------------------------------------------------------- 6. dashboard
Next-Step "Dashboard $DashboardName"
Set-Dashboard

# ---------------------------------------------------------------- 7. summary
Next-Step 'Summary'
$sub = @((Invoke-Aws sns list-subscriptions-by-topic --topic-arn $TopicArn).Subscriptions | Where-Object Endpoint -eq $NotifyEmail)
$summary = [ordered]@{
    deployed_at       = (Get-Date).ToString('s')
    sns_topic         = $TopicArn
    email             = $NotifyEmail
    email_status      = if ($sub -and $sub[0].SubscriptionArn -ne 'PendingConfirmation') { 'confirmed' } else { 'PendingConfirmation' }
    metrics_lambda    = $mf.FunctionArn
    metrics_sha256    = $mf.CodeSha256
    metrics_role      = $metricsRoleArn
    metrics_log_group = $MetricsLogGroup
    namespace         = $MetricNamespace
    state_machine     = $StateMachineArn
    dashboard         = $DashboardName
    summary_widget    = $widgetFnArn
}
$summary.GetEnumerator() | ForEach-Object { Write-Ok ('{0,-17} {1}' -f $_.Key, $_.Value) }
Save-Json $summary (Join-Path $EvidenceDir 'deploy-monitoring.json')
if ($summary.email_status -ne 'confirmed') { Write-Note 'Confirm the email subscription before the test run, or the email is dropped.' }
Write-Host "`nDone. Next: .\run-cycle.ps1 -Notify   (scan only, sends a test email, fills the logs widgets)" -ForegroundColor Cyan

} finally { Pop-Location }
