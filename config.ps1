# Shared settings for the Phase B scripts. Dot-sourced by every script; not run on its own.

$Region     = 'ap-southeast-5'
$Account    = '588589592508'
$VpcId      = 'vpc-0091f528e491e5f8b'
$PrivSubnet = 'subnet-0ca8d9ab6c3df888b'
$EndpointSg = 'sg-01cffc49e5d0e9ff7'
$SmService  = 'com.amazonaws.ap-southeast-5.secretsmanager'

$RhelFn           = 'serverless-patch-rhel'
$WinFn            = 'serverless-patch-windows'
$StateMachineName = 'serverless-patch-cycle'
$StateMachineArn  = "arn:aws:states:${Region}:${Account}:stateMachine:$StateMachineName"
$SfnRoleName      = 'serverless-patch-sfn-role'
$SchedRoleName    = 'serverless-patch-scheduler-role'
$WeeklySchedule   = 'serverless-patch-weekly'

# Phase D: visibility (metrics Lambda, SNS, dashboard)
$MetricsFn        = 'serverless-patch-metrics'
$MetricsRoleName  = 'serverless-patch-metrics-lambda-role'
$MetricsLogGroup  = "/aws/lambda/$MetricsFn"
$MetricNamespace  = 'ServerlessPatch'
$TopicName        = 'serverless-patch-notify'
$TopicArn         = "arn:aws:sns:${Region}:${Account}:$TopicName"
$NotifyEmail      = 'ikmalj.tech@gmail.com'
$DashboardName    = 'PatchManagement-Dashboard'
$DashboardUrl     = "https://$Region.console.aws.amazon.com/cloudwatch/home?region=$Region#dashboards/dashboard/$DashboardName"

# Host name -> instance ID / private IP / baseline AMI (testbed build record)
$Hosts = [ordered]@{
    'rhel-01' = @{ Id = 'i-0ba983a12665d852f'; Ip = '10.0.1.175'; Ami = 'ami-0bf7b60a5f0dc4edc'; Name = 'serverless-patch-rhel-01'; Workload = 'nginx' }
    'rhel-02' = @{ Id = 'i-008641b7be92f9871'; Ip = '10.0.1.254'; Ami = 'ami-0f57a82478bedfd3b'; Name = 'serverless-patch-rhel-02'; Workload = 'mysql' }
    'win-01'  = @{ Id = 'i-0b6462c157a7d6763'; Ip = '10.0.1.189'; Ami = 'ami-01b25632c46bf40fb'; Name = 'serverless-patch-win-01';  Workload = 'iis' }
}

$EvidenceDir = Join-Path $PSScriptRoot 'evidence'
$BuildDir    = Join-Path $PSScriptRoot 'build'

# Run an AWS CLI command, throw on failure, return parsed JSON (or $null when there is no output).
function Invoke-Aws {
    $errPath = [System.IO.Path]::GetTempFileName()
    $raw = & aws @args --region $Region --output json 2>$errPath
    $code = $LASTEXITCODE
    $err = Get-Content $errPath -Raw -ErrorAction SilentlyContinue
    Remove-Item $errPath -ErrorAction SilentlyContinue
    if ($code -ne 0) { throw "aws $($args -join ' ') failed (exit $code)`n$err" }
    $text = ($raw -join "`n").Trim()
    if ($text) { return $text | ConvertFrom-Json } else { return $null }
}

# True when an AWS CLI command succeeds (used for "does it exist?" checks).
function Test-Aws {
    & aws @args --region $Region --output json *> $null
    return ($LASTEXITCODE -eq 0)
}

function Write-Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "   $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "   $Text" -ForegroundColor Yellow }

# Write JSON without a BOM (the AWS CLI rejects BOM-prefixed files).
function Save-Json($Object, [string]$Path, [int]$Depth = 20) {
    $json = if ($Object -is [string]) { $Object } else { $Object | ConvertTo-Json -Depth $Depth }
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

New-Item -ItemType Directory -Force $EvidenceDir, $BuildDir | Out-Null
