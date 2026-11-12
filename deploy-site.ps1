#Requires -Version 7.0
<#
.SYNOPSIS
  Publish the project website (site\) on CloudFront.
    1. Rebuild site\data\patch-data.js from evidence\ (python site\build_site_data.py)
    2. S3 bucket serverless-patch-site-<account>: private, all public access blocked
    3. CloudFront Origin Access Control, so only CloudFront can read the bucket
    4. CloudFront distribution (HTTPS only, security headers, index.html as the root)
    5. Bucket policy: s3:GetObject for this distribution only
    6. Custom domain (optional): ACM certificate in us-east-1, then the domain on the distribution
    7. Upload site\ and clear the CloudFront cache
    8. Live updates: Lambda serverless-patch-site-publisher + EventBridge rule on every status change
       of the state machine; it rewrites data/live.json from the metrics records. First publish now.
  Safe to run again: every step reuses what already exists. After this, the Live view updates by
  itself; run the script again only to change the page, the evaluation period or the domain.
  Does not touch any host, the patch Lambdas, the state machine or the CloudWatch dashboard.

  Custom domain, DNS at Cloudflare (or any DNS host): the first run with a domain requests the
  certificate and prints a validation CNAME to add at the DNS host. Run again once the certificate
  is issued (usually a few minutes after the record is added): the domain is then attached to the
  distribution and the script prints the CNAME that points the domain at CloudFront.

.PARAMETER SkipBuild
  Upload site\ as it is, without rebuilding the data from evidence\.

.PARAMETER Domain
  Custom domain for the site, for example patch.example.com. Defaults to $SiteDomain in config.ps1.

.PARAMETER From
  First day of results to show, YYYY-MM-DD in Malaysia time. Defaults to $SiteFrom in config.ps1;
  empty means from the first patch cycle in evidence\.

.PARAMETER To
  Last day of results to show (inclusive), YYYY-MM-DD in Malaysia time. Defaults to $SiteTo in
  config.ps1; empty means up to the latest patch cycle.

.EXAMPLE
  .\deploy-site.ps1
  .\deploy-site.ps1 -SkipBuild
  .\deploy-site.ps1 -Domain patch.example.com
  .\deploy-site.ps1 -From 2026-11-01 -To 2026-11-12
#>
param([switch]$SkipBuild, [string]$Domain, [string]$From, [string]$To)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\config.ps1"
Push-Location $PSScriptRoot
try {

$SiteDir = Join-Path $PSScriptRoot 'site'
if (-not $Domain) { $Domain = $SiteDomain }
if (-not $From -and (Get-Variable SiteFrom -ErrorAction SilentlyContinue)) { $From = $SiteFrom }
if (-not $To -and (Get-Variable SiteTo -ErrorAction SilentlyContinue)) { $To = $SiteTo }
$Domain = ([string]$Domain).Trim().TrimEnd('.').ToLowerInvariant()
if ($Domain -and $Domain -notmatch '^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$') {
    throw "'$Domain' is not a valid domain name (use the bare name, e.g. patch.example.com, no https://)"
}
$step = 0
$total = 9
function Next-Step([string]$Text) { $script:step++; Write-Step "$($script:step)/$total $Text" }

# AWS managed CloudFront policies (same IDs in every account)
$CachingOptimized = '658327ea-f89d-4fab-a63d-7e88639e58f6'
$SecurityHeaders  = '67f7725c-6f97-4210-82d7-5512b31e9d03'

# ---------------------------------------------------------------- 1. data
Next-Step 'Site data from evidence\'
if ($SkipBuild) {
    Write-Note 'skipped (-SkipBuild): uploading site\data\patch-data.js as it is'
} else {
    $py = Get-Command python -ErrorAction SilentlyContinue
    $pyArgs = @()
    if (-not $py) { $py = Get-Command py -ErrorAction SilentlyContinue; $pyArgs = @('-3') }
    if (-not $py) { throw 'Python 3 not found (python or py). Install it, or run with -SkipBuild.' }
    $window = @()
    if ($From) { $window += @('--from', $From) }
    if ($To)   { $window += @('--to', $To) }
    & $py.Source @pyArgs (Join-Path $SiteDir 'build_site_data.py') @window
    if ($LASTEXITCODE -ne 0) { throw 'build_site_data.py failed' }
    Write-Ok ("site\data\patch-data.js rebuilt, results " + $(if ($From -or $To) { "from $(if ($From) { $From } else { 'the first run' }) to $(if ($To) { $To } else { 'the latest run' }) (MYT)" } else { 'from every patch cycle in evidence\' }))
}
if (-not (Test-Path (Join-Path $SiteDir 'data\patch-data.js'))) { throw 'site\data\patch-data.js is missing' }

# ---------------------------------------------------------------- 2. bucket
Next-Step "S3 bucket $SiteBucket"
if (Test-Aws s3api head-bucket --bucket $SiteBucket) {
    Write-Ok 'exists'
} else {
    Invoke-Aws s3api create-bucket --bucket $SiteBucket --create-bucket-configuration "LocationConstraint=$Region" | Out-Null
    Write-Ok "created in $Region"
}
Invoke-Aws s3api put-public-access-block --bucket $SiteBucket --public-access-block-configuration `
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' | Out-Null
Invoke-Aws s3api put-bucket-ownership-controls --bucket $SiteBucket --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]' | Out-Null
Invoke-Aws s3api put-bucket-tagging --bucket $SiteBucket --tagging 'TagSet=[{Key=project,Value=serverless-patch}]' | Out-Null
Write-Ok 'public access blocked, ACLs disabled, tagged project=serverless-patch'

# ---------------------------------------------------------------- 3. origin access control
Next-Step "Origin Access Control $SiteOacName"
$oac = @((Invoke-Aws cloudfront list-origin-access-controls).OriginAccessControlList.Items | Where-Object Name -eq $SiteOacName) | Select-Object -First 1
if ($oac) {
    $oacId = $oac.Id
    Write-Ok "exists ($oacId)"
} else {
    Save-Json @{
        Name                          = $SiteOacName
        Description                   = 'CloudFront reads the serverless-patch website bucket (SigV4)'
        SigningProtocol               = 'sigv4'
        SigningBehavior               = 'always'
        OriginAccessControlOriginType = 's3'
    } (Join-Path $BuildDir 'site-oac.json')
    $oacId = (Invoke-Aws cloudfront create-origin-access-control --origin-access-control-config file://build/site-oac.json).OriginAccessControl.Id
    Write-Ok "created ($oacId)"
}

# ---------------------------------------------------------------- 4. distribution
Next-Step 'CloudFront distribution'
$dist = @((Invoke-Aws cloudfront list-distributions).DistributionList.Items | Where-Object Comment -eq $SiteComment) | Select-Object -First 1
if ($dist) {
    $distId = $dist.Id; $distDomain = $dist.DomainName; $distArn = $dist.ARN
    Write-Ok "exists ($distId, status $($dist.Status))"
} else {
    $originId = "s3-$SiteBucket"
    $cfg = [ordered]@{
        CallerReference   = "serverless-patch-site-$(Get-Date -Format 'yyyyMMddHHmmss')"
        Comment           = $SiteComment
        Enabled           = $true
        DefaultRootObject = 'index.html'
        PriceClass        = 'PriceClass_200'          # includes Asia edge locations
        HttpVersion       = 'http2and3'
        IsIPV6Enabled     = $true
        Origins           = @{ Quantity = 1; Items = @(@{
            Id                    = $originId
            DomainName            = "$SiteBucket.s3.$Region.amazonaws.com"
            OriginAccessControlId = $oacId
            S3OriginConfig        = @{ OriginAccessIdentity = '' }
        }) }
        DefaultCacheBehavior = [ordered]@{
            TargetOriginId          = $originId
            ViewerProtocolPolicy    = 'redirect-to-https'
            CachePolicyId           = $CachingOptimized
            ResponseHeadersPolicyId = $SecurityHeaders
            Compress                = $true
            AllowedMethods          = @{ Quantity = 2; Items = @('GET', 'HEAD'); CachedMethods = @{ Quantity = 2; Items = @('GET', 'HEAD') } }
        }
        ViewerCertificate = @{ CloudFrontDefaultCertificate = $true }
    }
    Save-Json @{ DistributionConfig = $cfg; Tags = @{ Items = @(@{ Key = 'project'; Value = 'serverless-patch' }) } } `
        (Join-Path $BuildDir 'site-distribution.json') -Depth 30
    $new = (Invoke-Aws cloudfront create-distribution-with-tags --distribution-config-with-tags file://build/site-distribution.json).Distribution
    $distId = $new.Id; $distDomain = $new.DomainName; $distArn = $new.ARN
    Write-Ok "created ($distId). The first deployment to edge locations takes about 5 to 15 minutes."
}

# ---------------------------------------------------------------- 5. bucket policy
Next-Step 'Bucket policy (this distribution only)'
Save-Json ([ordered]@{
    Version   = '2012-10-17'
    Statement = @([ordered]@{
        Sid       = 'CloudFrontReadSite'
        Effect    = 'Allow'
        Principal = @{ Service = 'cloudfront.amazonaws.com' }
        Action    = 's3:GetObject'
        Resource  = "arn:aws:s3:::$SiteBucket/*"
        Condition = @{ StringEquals = @{ 'AWS:SourceArn' = $distArn } }
    })
}) (Join-Path $BuildDir 'site-bucket-policy.json') -Depth 10
Invoke-Aws s3api put-bucket-policy --bucket $SiteBucket --policy file://build/site-bucket-policy.json | Out-Null
Write-Ok "s3:GetObject for $distArn only"

# ---------------------------------------------------------------- 6. custom domain
Next-Step 'Custom domain'
# CloudFront only accepts certificates from ACM in us-east-1, whatever region the bucket is in.
function Invoke-AwsUsEast1 {
    $errPath = [System.IO.Path]::GetTempFileName()
    $raw = & aws @args --region us-east-1 --output json 2>$errPath
    $code = $LASTEXITCODE
    $err = Get-Content $errPath -Raw -ErrorAction SilentlyContinue
    Remove-Item $errPath -ErrorAction SilentlyContinue
    if ($code -ne 0) { throw "aws $($args -join ' ') (us-east-1) failed (exit $code)`n$err" }
    $text = ($raw -join "`n").Trim()
    if ($text) { return $text | ConvertFrom-Json } else { return $null }
}
$certArn = $null; $certStatus = $null; $domainLive = $false
if (-not $Domain) {
    Write-Ok 'none set (optional: -Domain patch.example.com, or $SiteDomain in config.ps1)'
} else {
    $cert = @((Invoke-AwsUsEast1 acm list-certificates --certificate-statuses PENDING_VALIDATION ISSUED).CertificateSummaryList |
        Where-Object DomainName -eq $Domain) | Select-Object -First 1
    if ($cert) {
        $certArn = $cert.CertificateArn
    } else {
        $certArn = (Invoke-AwsUsEast1 acm request-certificate --domain-name $Domain --validation-method DNS `
            --key-algorithm RSA_2048 --tags 'Key=project,Value=serverless-patch').CertificateArn
        Write-Ok "certificate requested for $Domain"
    }
    # The validation record appears a few seconds after the request.
    $rr = $null
    for ($try = 1; $try -le 10 -and -not $rr; $try++) {
        $desc = (Invoke-AwsUsEast1 acm describe-certificate --certificate-arn $certArn).Certificate
        $certStatus = $desc.Status
        $rr = ($desc.DomainValidationOptions | Where-Object DomainName -eq $Domain | Select-Object -First 1).ResourceRecord
        if (-not $rr) { Start-Sleep 3 }
    }
    Write-Ok "certificate $certArn"
    Write-Ok "status $certStatus"

    if ($certStatus -ne 'ISSUED') {
        if (-not $rr) { throw 'ACM has not produced the validation record yet. Run the script again in a minute.' }
        Write-Note 'Add this record at your DNS host (Cloudflare: DNS > Records > Add record), then run this script again:'
        Write-Host ('     Type    CNAME') -ForegroundColor Yellow
        Write-Host ('     Name    {0}' -f $rr.Name.TrimEnd('.')) -ForegroundColor Yellow
        Write-Host ('     Target  {0}' -f $rr.Value.TrimEnd('.')) -ForegroundColor Yellow
        Write-Host  '     Proxy   DNS only (grey cloud)' -ForegroundColor Yellow
        Write-Note 'ACM checks the record every few minutes. Keep the record afterwards: ACM uses it to renew the certificate.'
    } else {
        $dc = Invoke-Aws cloudfront get-distribution-config --id $distId
        $cfg = $dc.DistributionConfig
        $aliases = @($cfg.Aliases.Items | Where-Object { $_ })
        if ($aliases -contains $Domain -and $cfg.ViewerCertificate.ACMCertificateArn -eq $certArn) {
            Write-Ok "$Domain already attached to $distId"
        } else {
            $cfg.Aliases = [pscustomobject]@{ Quantity = 1; Items = @($Domain) }
            $cfg.ViewerCertificate = [pscustomobject]@{
                ACMCertificateArn      = $certArn
                SSLSupportMethod       = 'sni-only'
                MinimumProtocolVersion = 'TLSv1.2_2021'
            }
            Save-Json $cfg (Join-Path $BuildDir 'site-distribution-update.json') -Depth 40
            Invoke-Aws cloudfront update-distribution --id $distId --if-match $dc.ETag `
                --distribution-config file://build/site-distribution-update.json | Out-Null
            Write-Ok "$Domain attached to $distId (TLS 1.2 or later, SNI). CloudFront takes a few minutes to roll this out."
        }
        $domainLive = $true
        Write-Note 'Point the domain at CloudFront at your DNS host (Cloudflare: DNS > Records), if not done yet:'
        Write-Host  '     Type    CNAME' -ForegroundColor Yellow
        Write-Host ('     Name    {0}' -f $Domain) -ForegroundColor Yellow
        Write-Host ('     Target  {0}' -f $distDomain) -ForegroundColor Yellow
        Write-Host  '     Proxy   DNS only (grey cloud)' -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------- 7. upload and cache
Next-Step 'Upload site\ and clear the cache'
# Each file goes up with an explicit Content-Type: CloudFront sends X-Content-Type-Options: nosniff,
# so a script guessed as text/plain (Windows MIME settings vary) would not run.
# The generator script stays in the repository; only the page, assets and data go online.
$types = @{
    '.html' = 'text/html; charset=utf-8';       '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'text/javascript; charset=utf-8'; '.json' = 'application/json; charset=utf-8'
    '.svg'  = 'image/svg+xml'; '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.ico' = 'image/x-icon'; '.webp' = 'image/webp'
}
$local = @(Get-ChildItem $SiteDir -Recurse -File | Where-Object {
    $_.Extension -ne '.py' -and $_.FullName -notmatch '[\\/]__pycache__[\\/]' -and -not $_.Name.StartsWith('.') })
$keys = foreach ($f in $local) {
    $key = [System.IO.Path]::GetRelativePath($SiteDir, $f.FullName).Replace('\', '/')
    $type = $types[$f.Extension.ToLowerInvariant()]
    if (-not $type) { throw "no Content-Type for $key; add its extension to `$types in deploy-site.ps1" }
    Invoke-Aws s3 cp $f.FullName "s3://$SiteBucket/$key" --content-type $type --cache-control 'public, max-age=300' --only-show-errors | Out-Null
    $key
}
# Remove objects that are no longer in site\. data/live.json belongs to the publisher Lambda: keep it.
$remote = @((Invoke-Aws s3api list-objects-v2 --bucket $SiteBucket).Contents | ForEach-Object Key)
foreach ($old in ($remote | Where-Object { $_ -and $_ -notin $keys -and $_ -ne 'data/live.json' })) {
    Invoke-Aws s3 rm "s3://$SiteBucket/$old" --only-show-errors | Out-Null
    Write-Note "removed $old"
}
$files = @($keys)
Write-Ok "$($files.Count) files uploaded to s3://$SiteBucket/ ($($files -join ', '))"
Save-Json @{ Paths = @{ Quantity = 1; Items = @('/*') }; CallerReference = "site-$(Get-Date -Format 'yyyyMMddHHmmss')" } `
    (Join-Path $BuildDir 'site-invalidation.json')
$inv = Invoke-Aws cloudfront create-invalidation --distribution-id $distId --invalidation-batch file://build/site-invalidation.json
Write-Ok "cache invalidation $($inv.Invalidation.Id) started (/*)"

# ---------------------------------------------------------------- 8. live updates
Next-Step "Live updates: $SitePublisherFn"
$pubRoleArn  = "arn:aws:iam::${Account}:role/$SitePublisherRole"
$pubFnArn    = "arn:aws:lambda:${Region}:${Account}:function:$SitePublisherFn"
$pubLogGroup = "/aws/lambda/$SitePublisherFn"
$ruleName    = 'serverless-patch-site-publish'

$pubRoleNew = $false
if (Test-Aws iam get-role --role-name $SitePublisherRole) {
    Invoke-Aws iam update-assume-role-policy --role-name $SitePublisherRole --policy-document 'file://iam/metrics-lambda-trust.json' | Out-Null
    Write-Ok "$SitePublisherRole exists, trust policy refreshed"
} else {
    Invoke-Aws iam create-role --role-name $SitePublisherRole --assume-role-policy-document 'file://iam/metrics-lambda-trust.json' `
        --tags 'Key=project,Value=serverless-patch' | Out-Null
    Write-Ok "$SitePublisherRole created"
    $pubRoleNew = $true
}
# Least privilege: query the metrics log group, see this state machine's runs, write one file, clear its cache.
Save-Json ([ordered]@{
    Version   = '2012-10-17'
    Statement = @(
        [ordered]@{ Sid = 'WriteOwnLogs'; Effect = 'Allow'; Action = @('logs:CreateLogStream', 'logs:PutLogEvents')
                    Resource = "arn:aws:logs:${Region}:${Account}:log-group:${pubLogGroup}:*" }
        [ordered]@{ Sid = 'QueryMetricsRecordsOnly'; Effect = 'Allow'; Action = 'logs:StartQuery'
                    Resource = "arn:aws:logs:${Region}:${Account}:log-group:$MetricsLogGroup" }
        [ordered]@{ Sid = 'ReadQueryResults'; Effect = 'Allow'; Action = @('logs:GetQueryResults', 'logs:StopQuery'); Resource = '*' }
        [ordered]@{ Sid = 'SeeRunningCycles'; Effect = 'Allow'; Action = 'states:ListExecutions'; Resource = $StateMachineArn }
        [ordered]@{ Sid = 'ReadRunMode'; Effect = 'Allow'; Action = 'states:DescribeExecution'
                    Resource = "arn:aws:states:${Region}:${Account}:execution:${StateMachineName}:*" }
        [ordered]@{ Sid = 'WriteLiveDataOnly'; Effect = 'Allow'; Action = 's3:PutObject'; Resource = "arn:aws:s3:::$SiteBucket/data/live.json" }
        [ordered]@{ Sid = 'ClearSiteCache'; Effect = 'Allow'; Action = 'cloudfront:CreateInvalidation'; Resource = $distArn }
    )
}) (Join-Path $BuildDir 'site-publisher-policy.json') -Depth 10
Invoke-Aws iam put-role-policy --role-name $SitePublisherRole --policy-name 'publish-live-site-data' `
    --policy-document 'file://build/site-publisher-policy.json' | Out-Null
Write-Ok 'inline policy publish-live-site-data set (metrics log group query, list/describe runs, put data/live.json, invalidate)'

$plg = @((Invoke-Aws logs describe-log-groups --log-group-name-prefix $pubLogGroup).logGroups | Where-Object logGroupName -eq $pubLogGroup)
if (-not $plg) { Invoke-Aws logs create-log-group --log-group-name $pubLogGroup --tags 'project=serverless-patch' | Out-Null }
Invoke-Aws logs put-retention-policy --log-group-name $pubLogGroup --retention-in-days 30 | Out-Null

Save-Json @{ Variables = @{
    LOG_GROUP         = $MetricsLogGroup
    BUCKET            = $SiteBucket
    DISTRIBUTION_ID   = $distId
    STATE_MACHINE_ARN = $StateMachineArn
    LIVE_DAYS         = [string]$SiteLiveDays
} } (Join-Path $BuildDir 'site-publisher-env.json')
$zip = Join-Path $BuildDir "$SitePublisherFn.zip"
Compress-Archive -Path (Join-Path $PSScriptRoot 'lambda\site_publisher.py'), (Join-Path $PSScriptRoot 'lambda\metrics.py') -DestinationPath $zip -Force
$pDesc = 'serverless-patch website: rewrites data/live.json after each cycle starts or ends. Read-only on AWS, no host access, no VPC.'
if (Test-Aws lambda get-function --function-name $SitePublisherFn) {
    Invoke-Aws lambda update-function-code --function-name $SitePublisherFn --zip-file "fileb://build/$SitePublisherFn.zip" | Out-Null
    Invoke-Aws lambda wait function-updated-v2 --function-name $SitePublisherFn | Out-Null
    Invoke-Aws lambda update-function-configuration --function-name $SitePublisherFn --timeout 180 --memory-size 256 `
        --description $pDesc --environment file://build/site-publisher-env.json | Out-Null
    Write-Ok 'Lambda updated'
} else {
    if ($pubRoleNew) { Write-Note 'new role: waiting 15 s for IAM to propagate'; Start-Sleep 15 }
    for ($try = 1; $try -le 4; $try++) {
        try {
            Invoke-Aws lambda create-function --function-name $SitePublisherFn --runtime python3.13 --architectures x86_64 `
                --handler site_publisher.lambda_handler --role $pubRoleArn --zip-file "fileb://build/$SitePublisherFn.zip" `
                --timeout 180 --memory-size 256 --description $pDesc --environment file://build/site-publisher-env.json `
                --tags 'project=serverless-patch' | Out-Null
            break
        } catch {
            if ($try -eq 4 -or $_.Exception.Message -notmatch 'cannot be assumed|InvalidParameterValue') { throw }
            Write-Note "role not assumable yet, retrying in 15 s ($try/3)"; Start-Sleep 15
        }
    }
    Write-Ok 'Lambda created'
}
Invoke-Aws lambda wait function-updated-v2 --function-name $SitePublisherFn | Out-Null

# EventBridge: Step Functions sends a status-change event for every Standard execution to the default bus.
Save-Json ([ordered]@{
    source        = @('aws.states')
    'detail-type' = @('Step Functions Execution Status Change')
    detail        = [ordered]@{ stateMachineArn = @($StateMachineArn); status = @('RUNNING', 'SUCCEEDED', 'FAILED', 'TIMED_OUT', 'ABORTED') }
}) (Join-Path $BuildDir 'site-publish-pattern.json') -Depth 10
$rule = Invoke-Aws events put-rule --name $ruleName --event-pattern file://build/site-publish-pattern.json --state ENABLED `
    --description 'serverless-patch-cycle started or finished: refresh the website live data' --tags 'Key=project,Value=serverless-patch'
Invoke-Aws events put-targets --rule $ruleName --targets "Id=site-publisher,Arn=$pubFnArn" | Out-Null
$hasPerm = $false
if (Test-Aws lambda get-policy --function-name $SitePublisherFn) {
    $pol = (Invoke-Aws lambda get-policy --function-name $SitePublisherFn).Policy | ConvertFrom-Json
    $hasPerm = [bool]($pol.Statement | Where-Object Sid -eq 'eventbridge-site-publish')
}
if (-not $hasPerm) {
    Invoke-Aws lambda add-permission --function-name $SitePublisherFn --statement-id 'eventbridge-site-publish' `
        --action 'lambda:InvokeFunction' --principal 'events.amazonaws.com' --source-arn $rule.RuleArn | Out-Null
}
Write-Ok "EventBridge rule $ruleName -> $SitePublisherFn (RUNNING, SUCCEEDED, FAILED, TIMED_OUT, ABORTED)"

# First publish now, so the Live view has data before the next cycle.
Save-Json @{ source = 'deploy-site.ps1' } (Join-Path $BuildDir 'site-publisher-test.json')
$meta = Invoke-Aws lambda invoke --function-name $SitePublisherFn --cli-binary-format raw-in-base64-out `
    --cli-read-timeout 200 --payload file://build/site-publisher-test.json build/site-publisher-out.json
$pout = Get-Content (Join-Path $BuildDir 'site-publisher-out.json') -Raw
if ($meta.FunctionError) { throw "first publish failed: $pout" }
$pres = $pout | ConvertFrom-Json
Write-Ok "data/live.json published: $($pres.cycles) patch cycles, $($pres.host_runs) host runs in the last $SiteLiveDays days, status $($pres.status)"

# ---------------------------------------------------------------- 9. summary
Next-Step 'Summary'
$url = "https://$distDomain/"
if ($domainLive) { $url = "https://$Domain/" }
$summary = [ordered]@{
    deployed_at     = (Get-Date).ToString('s')
    url             = $url
    cloudfront_url  = "https://$distDomain/"
    custom_domain   = $(if ($Domain) { $Domain } else { $null })
    certificate     = $(if ($certArn) { "$certArn ($certStatus)" } else { $null })
    distribution_id = $distId
    bucket          = $SiteBucket
    region          = $Region
    oac_id          = $oacId
    live_publisher  = $pubFnArn
    live_rule       = $ruleName
    live_days       = $SiteLiveDays
    files           = @($files)
}
$summary.GetEnumerator() | Where-Object Key -ne 'files' | ForEach-Object { Write-Ok ('{0,-16} {1}' -f $_.Key, $_.Value) }
Save-Json $summary (Join-Path $EvidenceDir 'deploy-site.json')
Write-Host "`nDone. Website: $url" -ForegroundColor Cyan

} finally { Pop-Location }
