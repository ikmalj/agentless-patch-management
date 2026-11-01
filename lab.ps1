#Requires -Version 7.0
<#
.SYNOPSIS
  Lab housekeeping: host power, the Secrets Manager endpoint, and a status view.
.EXAMPLE
  .\lab.ps1 status
  .\lab.ps1 start-rhel
  .\lab.ps1 endpoint-up
  .\lab.ps1 stop-all
  .\lab.ps1 endpoint-down
#>
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('status', 'start-rhel', 'start-win', 'start-all', 'stop-all', 'endpoint-up', 'endpoint-down')]
    [string]$Action
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\config.ps1"

function Get-Endpoint {
    @((Invoke-Aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VpcId" "Name=service-name,Values=$SmService").VpcEndpoints |
      Where-Object { $_.State -notin 'deleted', 'deleting' })
}

function Start-Hosts([string[]]$Keys) {
    $ids = @($Keys | ForEach-Object { $Hosts[$_].Id })
    Invoke-Aws ec2 start-instances --instance-ids @ids | Out-Null
    Write-Ok "starting $($Keys -join ', ') ... waiting for running"
    Invoke-Aws ec2 wait instance-running --instance-ids @ids | Out-Null
    Write-Ok 'running. Allow ~1 min for SSH (RHEL) or ~4 min for WinRM (Windows) before testing.'
}

switch ($Action) {
    'status' {
        Write-Step 'Hosts'
        $ids = @($Hosts.Values | ForEach-Object { $_.Id })
        $res = Invoke-Aws ec2 describe-instances --instance-ids @ids
        $res.Reservations.Instances | ForEach-Object {
            [pscustomobject]@{
                Name       = ($_.Tags | Where-Object Key -eq 'Name').Value
                State      = $_.State.Name
                PrivateIp  = $_.PrivateIpAddress
                PublicIp   = $_.PublicIpAddress
                PatchOS    = ($_.Tags | Where-Object Key -eq 'PatchOS').Value
            }
        } | Sort-Object Name | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
        Write-Step 'Secrets Manager endpoint'
        $ep = Get-Endpoint
        if ($ep) { Write-Ok "$($ep[0].VpcEndpointId) $($ep[0].State) (billed hourly while it exists)" } else { Write-Note 'none (Lambda cannot read secrets until endpoint-up)' }
        Write-Step 'Schedules'
        $s = Invoke-Aws scheduler list-schedules --name-prefix serverless-patch
        if ($s.Schedules) { $s.Schedules | Select-Object Name, State | Format-Table -AutoSize | Out-String -Width 220 | Write-Host } else { Write-Note 'none' }
    }
    'start-rhel' { Start-Hosts @('rhel-01', 'rhel-02') }
    'start-win'  { Start-Hosts @('win-01') }
    'start-all'  { Start-Hosts @('rhel-01', 'rhel-02', 'win-01') }
    'stop-all' {
        $ids = @($Hosts.Values | ForEach-Object { $_.Id })
        Invoke-Aws ec2 stop-instances --instance-ids @ids | Out-Null
        Write-Ok 'stop requested for all three hosts'
    }
    'endpoint-up' {
        $ep = Get-Endpoint
        if ($ep) {
            $epId = $ep[0].VpcEndpointId
            Write-Ok "already exists: $epId ($($ep[0].State))"
        } else {
            $tags = 'ResourceType=vpc-endpoint,Tags=[{Key=project,Value=serverless-patch},{Key=Name,Value=serverless-patch-secretsmanager-vpce}]'
            $new = Invoke-Aws ec2 create-vpc-endpoint --vpc-id $VpcId --vpc-endpoint-type Interface --service-name $SmService `
                --subnet-ids $PrivSubnet --security-group-ids $EndpointSg --private-dns-enabled --tag-specifications $tags
            $epId = $new.VpcEndpoint.VpcEndpointId
            Write-Ok "created $epId (billed hourly while it exists)"
        }
        # Lambda cannot reach Secrets Manager until the endpoint is available (found 1 Nov 2026:
        # a test right after creation timed out on secretsmanager.ap-southeast-5.amazonaws.com).
        $state = ''
        for ($i = 0; $i -lt 30; $i++) {
            $state = (Invoke-Aws ec2 describe-vpc-endpoints --vpc-endpoint-ids $epId).VpcEndpoints[0].State
            if ($state -eq 'available') { break }
            if ($i -eq 0) { Write-Note 'waiting for the endpoint to become available (usually 1-2 min)...' }
            Start-Sleep 10
        }
        if ($state -ne 'available') { throw "endpoint $epId is still '$state' after 5 minutes" }
        Write-Ok "$epId available. Lambda can read its secrets now."
    }
    'endpoint-down' {
        $ep = Get-Endpoint
        if (-not $ep) { Write-Ok 'no endpoint to delete'; break }
        Invoke-Aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $ep[0].VpcEndpointId | Out-Null
        Write-Ok "deleted $($ep[0].VpcEndpointId) (billing stops)"
    }
}
