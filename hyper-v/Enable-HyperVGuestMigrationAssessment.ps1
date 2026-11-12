<#
.SYNOPSIS
    Tests guest telemetry connectivity and enables Arc SQL migration assessment.
.DESCRIPTION
    Run elevated on the Azure Hyper-V host. Defaults to arcsql-01 through
    arcsql-08. Uses PowerShell Direct and Az.Accounts on the host. Sign in with
    Connect-AzAccount first, or supply TenantId and ServicePrincipalClientId to
    prompt securely for a service principal secret.
    Does not install agents, upgrade extensions, change licensing, or alter BPA.
    Uses the stable 2026-01-01 Arc SQL API. Requires SQL extension 1.1.2594.118+.
    All target checks must pass before any assessment is enabled.
.EXAMPLE
    Connect-AzAccount
    .\Enable-HyperVGuestMigrationAssessment.ps1 -SubscriptionId '<subscription-guid>' `
        -ResourceGroupName 'sql-bpa-lab-rg'
.EXAMPLE
    .\Enable-HyperVGuestMigrationAssessment.ps1 -SubscriptionId '<subscription-guid>' `
        -ResourceGroupName 'sql-bpa-lab-rg' -TenantId '<tenant-guid>' `
        -ServicePrincipalClientId '<application-guid>' -RunAssessment
.PARAMETER RunAssessment
    Also requests an immediate assessment. Accepted/running is not completion.
.PARAMETER CheckOnly
    Performs preflight without enabling or triggering assessments.
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [string[]]$VMName = @(1..8 | ForEach-Object { 'arcsql-{0:00}' -f $_ }),
    [Parameter(Mandatory)] [guid]$SubscriptionId,
    [Parameter(Mandatory)] [ValidatePattern('^[\w().-]+$')] [string]$ResourceGroupName,
    [PSCredential]$GuestCredential,
    [guid]$TenantId = [guid]::Empty,
    [guid]$ServicePrincipalClientId = [guid]::Empty,
    [Security.SecureString]$ServicePrincipalSecret,
    [switch]$RunAssessment,
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-MigrationArm {
    param([string]$Path, [string]$Method = 'GET', [object]$Body)
    $arguments = @{Path=$Path; Method=$Method; ErrorAction='Stop'}
    if ($null -ne $Body) { $arguments.Payload = $Body | ConvertTo-Json -Depth 50 -Compress }
    $response = Invoke-AzRestMethod @arguments
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "ARM $Method $Path failed (HTTP $($response.StatusCode)): $($response.Content)"
    }
    if ($response.Content) { return $response.Content | ConvertFrom-Json }
}

function Get-MigrationInstances {
    param([string]$GroupId)
    $path = "$GroupId/providers/Microsoft.AzureArcData/sqlServerInstances?api-version=2026-01-01"
    do {
        $page = Invoke-MigrationArm -Path $path
        $page.value
        $path = $null
        if ($page.PSObject.Properties['nextLink'] -and $page.nextLink) {
            $next = [uri]$page.nextLink
            if ($next.Scheme -ne 'https' -or $next.Host -ne 'management.azure.com') {
                throw 'Unexpected SQL discovery pagination URL.'
            }
            $path = $next.PathAndQuery
        }
    } while ($path)
}

$guestConnectivity = {
    param($Endpoint)
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    $services = @(Get-Service | Where-Object { $_.Name -eq 'MSSQLSERVER' -or $_.Name -like 'MSSQL$*' })
    if (-not ($services | Where-Object { $_.Status -eq 'Running' })) { throw 'No running SQL Server engine service found.' }
    $addresses = @(Resolve-DnsName -Name $Endpoint -ErrorAction Stop |
        Where-Object { $_.PSObject.Properties['IPAddress'] } | ForEach-Object { $_.IPAddress })
    if (-not $addresses.Count) { throw "DNS returned no addresses for $Endpoint." }
    $tcp = [Net.Sockets.TcpClient]::new()
    try {
        $pending = $tcp.BeginConnect($Endpoint, 443, $null, $null)
        try {
            if (-not $pending.AsyncWaitHandle.WaitOne(15000)) { throw "TCP 443 connection timed out for $Endpoint." }
            $tcp.EndConnect($pending)
        } finally { $pending.AsyncWaitHandle.Close() }
        # Default certificate validation and SNI; no bypass for invalid certificates.
        $tls = [Net.Security.SslStream]::new($tcp.GetStream(), $false)
        try {
            $tls.ReadTimeout = 15000
            $tls.WriteTimeout = 15000
            $tls.AuthenticateAsClient($Endpoint, $null, [Security.Authentication.SslProtocols]::Tls12, $true)
            [pscustomobject]@{
                Endpoint=$Endpoint; Addresses=($addresses -join ','); Tcp443=$true
                TlsValidated=$true; Protocol=$tls.SslProtocol.ToString()
            }
        } finally { $tls.Dispose() }
    } finally { $tcp.Dispose() }
}

function Enable-MigrationInstance {
    param([object]$Instance, [switch]$Trigger)
    $path = "$($Instance.id)?api-version=2026-01-01"
    $assessment = $null
    if ($Instance.properties.PSObject.Properties['migration'] -and $Instance.properties.migration -and
        $Instance.properties.migration.PSObject.Properties['assessment']) {
        $assessment = $Instance.properties.migration.assessment
    }
    $enabled = $assessment -and $assessment.PSObject.Properties['enabled'] -and $assessment.enabled -eq $true
    if (-not $enabled) {
        # PATCH only this flag; preserve pricing, migration strategy, licensing and BPA.
        Invoke-MigrationArm -Path $path -Method PATCH -Body @{
            properties=@{migration=@{assessment=@{enabled=$true}}}
        } | Out-Null
        $deadline = (Get-Date).AddMinutes(5)
        do {
            $updated = Invoke-MigrationArm -Path $path
            if ($updated.properties.PSObject.Properties['provisioningState'] -and
                $updated.properties.provisioningState -in @('Failed','Canceled')) {
                throw "Migration enablement failed for $($Instance.name): $($updated | ConvertTo-Json -Depth 20 -Compress)"
            }
            if ($updated.properties.PSObject.Properties['migration'] -and $updated.properties.migration -and
                $updated.properties.migration.PSObject.Properties['assessment'] -and
                $updated.properties.migration.assessment -and
                $updated.properties.migration.assessment.PSObject.Properties['enabled'] -and
                $updated.properties.migration.assessment.enabled -eq $true) { break }
            if ((Get-Date) -ge $deadline) { throw "Timed out verifying migration enablement for $($Instance.name)." }
            Start-Sleep -Seconds 10
        } while ($true)
    }
    $status = 'Enabled; scheduled assessment'
    if ($Trigger) {
        $job = Invoke-MigrationArm -Path "$($Instance.id)/runMigrationAssessment?api-version=2026-01-01" -Method POST
        if (-not $job -or -not $job.PSObject.Properties['jobStatus'] -or
            $job.jobStatus -notin @('NotStarted','InProgress','Succeeded')) {
            throw "Migration run failed or returned an unexpected response for $($Instance.name): $($job | ConvertTo-Json -Depth 20 -Compress)"
        }
        $status = "Run requested: $($job.jobStatus)"
    }
    [pscustomobject]@{Instance=$Instance.name; ResourceId=$Instance.id; Enabled=$true; Status=$status}
}

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run elevated on the Hyper-V host.' }
if (-not $VMName.Count -or @($VMName | Select-Object -Unique).Count -ne $VMName.Count) { throw 'Supply unique guest VM names.' }
if ($CheckOnly -and $RunAssessment) { throw 'CheckOnly and RunAssessment cannot be combined.' }
if (($TenantId -eq [guid]::Empty) -ne ($ServicePrincipalClientId -eq [guid]::Empty)) {
    throw 'Supply both TenantId and ServicePrincipalClientId, or neither to reuse the current Azure sign-in.'
}
if ($ServicePrincipalSecret -and $ServicePrincipalClientId -eq [guid]::Empty) { throw 'A service principal secret requires TenantId and ServicePrincipalClientId.' }
Import-Module Hyper-V -ErrorAction Stop
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) { throw 'Install-Module Az.Accounts -Scope AllUsers -Repository PSGallery, then rerun.' }
Import-Module Az.Accounts -ErrorAction Stop
Disable-AzContextAutosave -Scope Process | Out-Null
if ($ServicePrincipalClientId -ne [guid]::Empty) {
    if (-not $ServicePrincipalSecret) { $ServicePrincipalSecret = Read-Host 'Azure service principal secret' -AsSecureString }
    if ($ServicePrincipalSecret.Length -eq 0) { throw 'A nonempty service principal secret is required.' }
    Connect-AzAccount -ServicePrincipal -Tenant $TenantId.ToString() -Subscription $SubscriptionId.ToString() `
        -Credential ([PSCredential]::new($ServicePrincipalClientId.ToString(), $ServicePrincipalSecret)) `
        -Environment AzureCloud -Scope Process | Out-Null
} else {
    $context = Get-AzContext
    if (-not $context -or $context.Environment.Name -ne 'AzureCloud') { throw 'Sign in with Connect-AzAccount to Azure public cloud first.' }
    Set-AzContext -SubscriptionId $SubscriptionId.ToString() -ErrorAction Stop | Out-Null
}
if (-not $GuestCredential) { $GuestCredential = Get-Credential -UserName Administrator -Message 'Local Administrator for the selected guests' }
if (-not $GuestCredential) { throw 'Guest credentials are required.' }
$groupId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
$instances = @(Get-MigrationInstances -GroupId $groupId)
$plan = @()
foreach ($name in $VMName) {
    if ($name -eq $env:COMPUTERNAME -or $name -notmatch '^[a-zA-Z][a-zA-Z0-9-]{0,13}[a-zA-Z0-9]$') { throw "Invalid guest name: $name" }
    if ((Get-VM -Name $name -ErrorAction Stop).State -ne 'Running') { throw "Guest $name is not running." }
    $machineId = "$groupId/providers/Microsoft.HybridCompute/machines/$name"
    $machine = Invoke-MigrationArm -Path "$machineId`?api-version=2024-07-10"
    if ($machine.properties.status -ne 'Connected') { throw "$name is not Arc-connected." }
    $extension = Invoke-MigrationArm -Path "$machineId/extensions/WindowsAgent.SqlServer?api-version=2024-07-10"
    $version = $null
    if ($extension.properties.provisioningState -ne 'Succeeded' -or
        -not [version]::TryParse([string]$extension.properties.typeHandlerVersion, [ref]$version) -or
        $version -lt [version]'1.1.2594.118') {
        throw "$name needs a successfully provisioned SQL extension version 1.1.2594.118 or later. Upgrade it in Azure, then rerun."
    }
    $matched = @($instances | Where-Object { $_.properties.containerResourceId -eq $machineId })
    if (-not $matched.Count) { throw "No Arc SQL instances found with exact parent $machineId." }
    $endpoint = "telemetry.$($machine.location).arcdataservices.com"
    Write-Host "Checking $name -> $endpoint (DNS, TCP 443, validated TLS)..." -ForegroundColor Cyan
    $connectivity = Invoke-Command -VMName $name -Credential $GuestCredential -ScriptBlock $guestConnectivity -ArgumentList $endpoint -ErrorAction Stop
    $connectivity | Select-Object @{n='VMName';e={$name}}, Endpoint, Addresses, Tcp443, TlsValidated, Protocol
    $plan += @{VMName=$name; Instances=$matched}
}
if ($CheckOnly) { Write-Host 'All selected guest connectivity and Arc prerequisites passed. No assessments changed.'; return }
foreach ($target in $plan) {
    foreach ($instance in $target.Instances) {
        Write-Host "Enabling migration assessment: $($target.VMName) / $($instance.name)" -ForegroundColor Cyan
        Enable-MigrationInstance -Instance $instance -Trigger:$RunAssessment
    }
}
Write-Host 'Migration assessment configuration verified. A requested run is not proof of completion; check Migration > Assessments for results.'
