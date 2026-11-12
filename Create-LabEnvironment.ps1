<#
.SYNOPSIS
    Bootstraps remote state and deploys the Azure SQL dashboard lab.
.DESCRIPTION
    Reads bootstrap values from terraform.tfvars, authenticates to Azure, creates
    the state resource group/account/container, grants blob data access, and runs
    Terraform. Hyper-V and Arc guest onboarding are separate workflows.
.PARAMETER TfvarsPath
    Terraform variable file. Defaults to terraform\terraform.tfvars in this repo.
#>
[CmdletBinding()]
param(
    [string]$TfvarsPath = (Join-Path $PSScriptRoot "terraform\terraform.tfvars")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AzureCli {
    param([string[]]$Arguments)

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $result = & az @Arguments --only-show-errors --output json 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    $text = ($result | ForEach-Object { $_.ToString() }) -join "`n"
    if ($exitCode -ne 0) {
        throw "Azure CLI failed ($exitCode): az $($Arguments -join ' ')`n$text"
    }
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        return ($text | ConvertFrom-Json)
    }
}

function Invoke-Terraform {
    param([string[]]$Arguments)

    & terraform @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Terraform failed ($LASTEXITCODE): terraform $($Arguments -join ' ')"
    }
}

foreach ($tool in @('az', 'terraform')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Required command '$tool' is not installed or not on PATH."
    }
}
if (-not (Test-Path -LiteralPath $TfvarsPath -PathType Leaf)) {
    throw "Variable file not found: $TfvarsPath. Copy terraform\terraform.tfvars.example and fill in your values."
}
$TfvarsPath = (Resolve-Path -LiteralPath $TfvarsPath).Path
$contents = Get-Content -LiteralPath $TfvarsPath -Raw
$config = @{}
$required = @(
    'tenant_id', 'subscription_id', 'backend_resource_group_name',
    'backend_storage_account_name', 'backend_storage_container_name',
    'location', 'alert_email_address'
)
foreach ($name in ($required + 'prefix')) {
    $matchesForValue = [regex]::Matches($contents, "(?m)^\s*$name\s*=\s*`"([^`"\r\n]*)`"\s*(?:(?:#|//)[^\r\n]*)?$")
    if ($matchesForValue.Count -gt 1) { throw "Duplicate variable: $name" }
    if ($matchesForValue.Count -eq 1) {
        $config[$name] = $matchesForValue[0].Groups[1].Value
    }
    elseif ($name -in $required) {
        throw "Set $name as a top-level quoted string in $TfvarsPath."
    }
}
foreach ($name in $required) {
    if ([string]::IsNullOrWhiteSpace($config[$name])) { throw "$name must not be empty." }
}
foreach ($name in @('tenant_id', 'subscription_id')) {
    $guid = [guid]::Empty
    if (-not [guid]::TryParse($config[$name], [ref]$guid) -or $guid -eq [guid]::Empty) {
        throw "$name must be a non-empty GUID."
    }
}
$storageName = $config.backend_storage_account_name
$containerName = $config.backend_storage_container_name
$backendGroup = $config.backend_resource_group_name
$prefix = if ($config.ContainsKey('prefix')) { $config.prefix } else { 'sql-bpa-lab' }
if ($storageName -notmatch '^[a-z0-9]{3,24}$') {
    throw 'backend_storage_account_name must contain 3-24 lowercase letters/digits, without hyphens.'
}
if ($containerName -notmatch '^(?!.*--)[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$') {
    throw 'backend_storage_container_name must contain 3-63 lowercase letters/digits or single hyphens, starting and ending with a letter/digit.'
}
if ($backendGroup -eq "$prefix-rg") {
    throw 'Use a separate backend resource group, not the lab resource group; destroying the lab must not delete its state.'
}
if ($config.alert_email_address -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$' -or $config.alert_email_address -match '@example\.com$') {
    throw 'Set alert_email_address to your real notification email address, not the example placeholder.'
}

Write-Host 'Signing in to Azure...' -ForegroundColor Cyan
Invoke-AzureCli -Arguments @('login', '--tenant', $config.tenant_id) | Out-Null
Invoke-AzureCli -Arguments @('account', 'set', '--subscription', $config.subscription_id) | Out-Null

# Read the signed-in principal from its ARM token without requiring directory-read permissions.
$token = Invoke-AzureCli -Arguments @('account', 'get-access-token', '--subscription', $config.subscription_id)
$payload = $token.accessToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
$payload = $payload.PadRight($payload.Length + ((4 - $payload.Length % 4) % 4), '=')
$claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
$principalId = [string]$claims.oid
if ([string]::IsNullOrWhiteSpace($principalId)) { throw 'The Azure access token does not identify a principal (oid).' }
$principalType = if ($claims.PSObject.Properties['idtyp'] -and $claims.idtyp -eq 'app') { 'ServicePrincipal' } else { 'User' }
$token = $null
$claims = $null
$payload = $null

Write-Host 'Bootstrapping the remote state backend...' -ForegroundColor Cyan
$groupExists = Invoke-AzureCli -Arguments @('group', 'exists', '--name', $backendGroup)
if (-not $groupExists) {
    Invoke-AzureCli -Arguments @('group', 'create', '--name', $backendGroup, '--location', $config.location) | Out-Null
}
$accounts = @(Invoke-AzureCli -Arguments @('storage', 'account', 'list', '--resource-group', $backendGroup))
$storage = $accounts | Where-Object { $_.name -eq $storageName } | Select-Object -First 1
if (-not $storage) {
    $availability = Invoke-AzureCli -Arguments @('storage', 'account', 'check-name', '--name', $storageName)
    if (-not $availability.nameAvailable) {
        throw "Storage account '$storageName' is unavailable outside the selected backend resource group. Choose a globally unique name."
    }
    $storage = Invoke-AzureCli -Arguments @(
        'storage', 'account', 'create', '--name', $storageName,
        '--resource-group', $backendGroup, '--location', $config.location,
        '--kind', 'StorageV2', '--sku', 'Standard_LRS',
        '--allow-blob-public-access', 'false', '--allow-shared-key-access', 'false',
        '--min-tls-version', 'TLS1_2'
    )
}
if ($storage.provisioningState -ne 'Succeeded') {
    throw "Backend storage account is not ready: $($storage.provisioningState)"
}

$assignments = @(Invoke-AzureCli -Arguments @(
    'role', 'assignment', 'list', '--scope', $storage.id, '--include-inherited'
))
$dataRoles = @('Storage Blob Data Contributor', 'Storage Blob Data Owner')
$hasDataAccess = @($assignments | Where-Object {
    $_.principalId -eq $principalId -and $_.roleDefinitionName -in $dataRoles
}).Count -gt 0
if (-not $hasDataAccess) {
    Invoke-AzureCli -Arguments @(
        'role', 'assignment', 'create', '--assignee-object-id', $principalId,
        '--assignee-principal-type', $principalType,
        '--role', 'Storage Blob Data Contributor', '--scope', $storage.id
    ) | Out-Null
}

Invoke-AzureCli -Arguments @(
    'storage', 'container-rm', 'create', '--name', $containerName,
    '--storage-account', $storageName, '--resource-group', $backendGroup,
    '--public-access', 'off'
) | Out-Null

Write-Host 'Waiting for backend DNS and blob data access (up to 15 minutes)...' -ForegroundColor Cyan
$deadline = (Get-Date).AddMinutes(15)
do {
    try {
        Invoke-AzureCli -Arguments @(
            'storage', 'blob', 'list', '--account-name', $storageName,
            '--container-name', $containerName, '--auth-mode', 'login', '--num-results', '1'
        ) | Out-Null
        break
    }
    catch {
        if ($_.Exception.Message -notmatch 'AuthorizationPermissionMismatch|AuthorizationFailure|Forbidden|403|no such host|NameResolutionFailure|could not be resolved|Name or service not known|getaddrinfo failed') {
            throw
        }
        if ((Get-Date) -ge $deadline) {
            throw "Backend data access did not become ready. Check RBAC, DNS, storage firewall, and private endpoint access. Last error: $($_.Exception.Message)"
        }
        Write-Warning 'Backend access is not ready yet; retrying in 15 seconds.'
        Start-Sleep -Seconds 15
    }
} while ($true)

$terraformPath = Join-Path $PSScriptRoot 'terraform'
$planPath = Join-Path $terraformPath "lab-$([guid]::NewGuid().ToString('N')).tfplan"
Push-Location $terraformPath
try {
    Invoke-Terraform -Arguments @(
        'init', '-input=false',
        "-backend-config=tenant_id=$($config.tenant_id)",
        "-backend-config=subscription_id=$($config.subscription_id)",
        "-backend-config=resource_group_name=$backendGroup",
        "-backend-config=storage_account_name=$storageName",
        "-backend-config=container_name=$containerName",
        '-backend-config=key=bpa.tfstate'
    )
    Invoke-Terraform -Arguments @('validate')
    Invoke-Terraform -Arguments @('plan', '-input=false', "-var-file=$TfvarsPath", "-out=$planPath")
    Invoke-Terraform -Arguments @('apply', '-input=false', $planPath)
    Invoke-Terraform -Arguments @('output')
    Write-Host 'Azure lab deployment completed. BPA runs Sunday at 09:00 UTC; Hyper-V/Arc onboarding is separate.' -ForegroundColor Green
}
finally {
    Pop-Location
    if (Test-Path -LiteralPath $planPath) { Remove-Item -LiteralPath $planPath -Force }
}
