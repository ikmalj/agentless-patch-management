#Requires -Version 7.0
<#
.SYNOPSIS
  Experiment 4 (operational cost): reads the current list prices for ap-southeast-5 from the AWS Price List
  API and saves them under .\evidence. Read-only: it changes nothing in the account.

.DESCRIPTION
  The Price List API answers only in us-east-1, so this script calls it there (the prices are still those of
  $Region). It covers every paid service the framework uses:
    per patch cycle   Step Functions state transitions, Lambda requests and duration, SNS publish and email,
                      EventBridge Scheduler invocations
    per month         Secrets Manager secrets and API calls, the Secrets Manager interface endpoint,
                      CloudWatch logs, custom metrics and dashboards
  Output: a price table on screen, evidence\exp4\exp4-prices-<region>-<time>.csv (the rows shown) and
  evidence\exp4\exp4-prices-<region>-<time>.json (every price returned for these services, for checking).

.EXAMPLE
  .\exp4-prices.ps1
#>
param([string]$PriceRegion = $null)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\config.ps1"
if (-not $PriceRegion) { $PriceRegion = $Region }

# Which usage types matter, per service (matched against the usage type, which starts with a region prefix).
$Want = [ordered]@{
    'AWSLambda'         = 'Lambda-GB-Second$|-Request$'
    'AmazonStates'      = 'StateTransition'
    'AWSStepFunctions'  = 'StateTransition'
    'AmazonSNS'         = 'Requests-Tier1$|DeliveryAttempts-SMTP$'
    'AWSEvents'         = 'Scheduler'
    'AWSSecretsManager' = 'AWSSecretsManager'
    'AmazonVPC'         = 'VpcEndpoint-Hours$|VpcEndpoint-Bytes$'
    'AmazonCloudWatch'  = 'DataProcessing-Bytes$|TimedStorage-ByteHrs$|CW:MetricMonitorUsage$|DashboardsUsageHour|DataScanned-Bytes$'
}

function Invoke-Pricing {
    $errPath = [System.IO.Path]::GetTempFileName()
    $raw = & aws pricing @args --region us-east-1 --output json 2>$errPath
    $code = $LASTEXITCODE
    $err = Get-Content $errPath -Raw -ErrorAction SilentlyContinue
    Remove-Item $errPath -ErrorAction SilentlyContinue
    if ($code -ne 0) { throw "aws pricing $($args -join ' ') failed (exit $code)`n$err" }
    ($raw -join "`n") | ConvertFrom-Json
}

Write-Step "AWS Price List: $PriceRegion"
$codes = @((Invoke-Pricing describe-services).Services.ServiceCode)
$rows = @(); $all = [ordered]@{}
foreach ($svc in $Want.Keys) {
    if ($svc -notin $codes) { continue }
    $items = @((Invoke-Pricing get-products --service-code $svc `
                --filters "Type=TERM_MATCH,Field=regionCode,Value=$PriceRegion").PriceList | ForEach-Object { $_ | ConvertFrom-Json })
    $all[$svc] = $items
    $n = 0
    foreach ($p in $items) {
        $ut = [string]$p.product.attributes.usagetype
        if ($ut -notmatch $Want[$svc]) { continue }
        foreach ($term in $p.terms.OnDemand.PSObject.Properties.Value) {
            foreach ($dim in $term.priceDimensions.PSObject.Properties.Value) {
                $n++
                $rows += [pscustomobject]@{
                    Service   = $svc
                    UsageType = $ut
                    Unit      = $dim.unit
                    USD       = [string]$dim.pricePerUnit.USD     # as published, all digits kept
                    From      = $dim.beginRange
                    To        = $dim.endRange
                    Description = $dim.description
                }
            }
        }
    }
    Write-Ok ("{0,-18} {1,4} products for {2}, {3} price rows kept" -f $svc, $items.Count, $PriceRegion, $n)
}
if (-not $rows) { throw "no prices returned for $PriceRegion" }

$rows = @($rows | Sort-Object Service, UsageType, @{ Expression = { [double]$_.From } })
$rows | Format-Table Service, UsageType, Unit, USD, From, To,
    @{ Label = 'Description'; Expression = { if ($_.Description.Length -gt 70) { $_.Description.Substring(0, 70) + '...' } else { $_.Description } } } `
    -AutoSize | Out-String -Width 260 | Write-Host
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csv = Get-EvidenceFile exp4 "exp4-prices-$PriceRegion-$stamp.csv"
$rows | Export-Csv $csv -Encoding utf8
Save-Json ([ordered]@{ region = $PriceRegion; retrieved_at = (Get-Date).ToString('o'); source = 'AWS Price List API (pricing get-products)'
                       products = $all }) (Get-EvidenceFile exp4 "exp4-prices-$PriceRegion-$stamp.json") -Depth 40
Write-Ok "saved $csv and the full price list (.json)"
Write-Note 'Unchanged: the PRICE_* values on serverless-patch-metrics. Send the table for the Experiment 4 calculation.'
