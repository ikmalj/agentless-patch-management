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
  Safe to run again: every step reuses what already exists. Run it after new patch cycles.
  Does not touch any host, Lambda, state machine or the CloudWatch dashboard.

  Custom domain, DNS at Cloudflare (or any DNS host): the first run with a domain requests the
  certificate and prints a validation CNAME to add at the DNS host. Run again once the certificate
  is issued (usually a few minutes after the record is added): the domain is then attached to the
  distribution and the script prints the CNAME that points the domain at CloudFront.

.PARAMETER SkipBuild
  Upload site\ as it is, without rebuilding the data from evidence\.

.PARAMETER Domain
  Custom domain for the site, for example patch.example.com. Defaults to $SiteDomain in config.ps1.

.EXAMPLE
  .\deploy-site.ps1
  .\deploy-site.ps1 -SkipBuild
  .\deploy-site.ps1 -Domain patch.example.com
#>
param([switch]$SkipBuild, [string]$Domain)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\config.ps1"
Push-Location $PSScriptRoot
try {

$SiteDir = Join-Path $PSScriptRoot 'site'
if (-not $Domain) { $Domain = $SiteDomain }
$Domain = ([string]$Domain).Trim().TrimEnd('.').ToLowerInvariant()
if ($Domain -and $Domain -notmatch '^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$') {
    throw "'$Domain' is not a valid domain name (use the bare name, e.g. patch.example.com, no https://)"
}
$step = 0
$total = 8
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
    & $py.Source @pyArgs (Join-Path $SiteDir 'build_site_data.py')
    if ($LASTEXITCODE -ne 0) { throw 'build_site_data.py failed' }
    Write-Ok 'site\data\patch-data.js rebuilt'
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
# Remove objects that are no longer in site\.
$remote = @((Invoke-Aws s3api list-objects-v2 --bucket $SiteBucket).Contents | ForEach-Object Key)
foreach ($old in ($remote | Where-Object { $_ -and $_ -notin $keys })) {
    Invoke-Aws s3 rm "s3://$SiteBucket/$old" --only-show-errors | Out-Null
    Write-Note "removed $old"
}
$files = @($keys)
Write-Ok "$($files.Count) files uploaded to s3://$SiteBucket/ ($($files -join ', '))"
Save-Json @{ Paths = @{ Quantity = 1; Items = @('/*') }; CallerReference = "site-$(Get-Date -Format 'yyyyMMddHHmmss')" } `
    (Join-Path $BuildDir 'site-invalidation.json')
$inv = Invoke-Aws cloudfront create-invalidation --distribution-id $distId --invalidation-batch file://build/site-invalidation.json
Write-Ok "cache invalidation $($inv.Invalidation.Id) started (/*)"

# ---------------------------------------------------------------- 7. summary
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
    files           = @(@($files) | ForEach-Object Key)
}
$summary.GetEnumerator() | Where-Object Key -ne 'files' | ForEach-Object { Write-Ok ('{0,-16} {1}' -f $_.Key, $_.Value) }
Save-Json $summary (Join-Path $EvidenceDir 'deploy-site.json')
Write-Host "`nDone. Website: $url" -ForegroundColor Cyan

} finally { Pop-Location }
