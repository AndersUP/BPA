<#
.SYNOPSIS
    Installs the Azure Arc Connected Machine Agent on a Windows VM and enables
    the SQL Server Best Practice Assessment feature via Azure Arc.

.DESCRIPTION
    This script:
      1. Validates the required Azure resource providers are registered.
      2. Downloads and installs the Azure Connected Machine Agent.
      3. Connects the machine to Azure Arc using a service principal.
      4. Verifies the SQL Server extension is present (auto-deployed by Arc).
      5. Enables the SQL Best Practices Assessment on the Arc-enabled SQL Server.

    Run this script with local Administrator privileges on the target machine.

.PARAMETER TenantId
    The Azure Active Directory tenant ID.

.PARAMETER SubscriptionId
    The Azure subscription ID where Arc resources will be created.

.PARAMETER ResourceGroupName
    The resource group name for the Arc-enabled server resource.

.PARAMETER Location
    The Azure region (e.g. 'eastus', 'westeurope') for the Arc resource.

.PARAMETER MachineName
    The name to register the Arc-enabled server under. Defaults to the local
    computer name.

.PARAMETER ServicePrincipalClientId
    The client (application) ID of the service principal used for Arc onboarding.

.PARAMETER ServicePrincipalSecret
    The client secret of the service principal used for Arc onboarding.

.PARAMETER WorkspaceId
    The resource ID of the Log Analytics workspace used for assessment results.
    Format: /subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>

.PARAMETER WorkspaceKey
    The primary key of the Log Analytics workspace.

.PARAMETER ProxyUrl
    Optional. The HTTPS proxy URL the agent should use (e.g. 'https://proxy.contoso.com:8080').

.EXAMPLE
    .\Install-AzureArcAgent-SqlBPA.ps1 `
        -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ResourceGroupName "rg-arc-sql" `
        -Location "eastus" `
        -ServicePrincipalClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ServicePrincipalSecret "your-secret" `
        -WorkspaceId "/subscriptions/.../workspaces/law-sql-bpa" `
        -WorkspaceKey "your-workspace-key"

.NOTES
    Prerequisites:
      - Windows Server 2012 R2 or later / Windows 10 or later.
      - Local Administrator rights.
      - Outbound HTTPS (port 443) access to Azure endpoints.
      - Az PowerShell module (Az.Accounts, Az.ConnectedMachine, Az.ArcData).
      - The service principal must have the "Azure Connected Machine Onboarding"
        role (or Contributor) on the target resource group.
    
    References:
      - https://learn.microsoft.com/azure/azure-arc/servers/onboard-powershell
      - https://learn.microsoft.com/sql/sql-server/azure-arc/connect
      - https://learn.microsoft.com/sql/sql-server/azure-arc/assess
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$Location,

    [Parameter()]
    [string]$MachineName = $env:COMPUTERNAME,

    [Parameter(Mandatory)]
    [string]$ServicePrincipalClientId,

    [Parameter(Mandatory)]
    [string]$ServicePrincipalSecret,

    [Parameter(Mandatory)]
    [string]$WorkspaceId,

    [Parameter(Mandatory)]
    [string]$WorkspaceKey,

    [Parameter()]
    [string]$ProxyUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── Helper functions ────────────────────────────────────────────────────

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Assert-Elevated {
    $currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run as a local Administrator.'
    }
}

function Install-RequiredModules {
    # Ensure NuGet provider is available (required for PowerShellGet on older systems)
    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge '2.8.5.201' })) {
        Write-Host "  Installing NuGet package provider..." -ForegroundColor Yellow
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    }

    $modules = @('Az.Accounts', 'Az.ConnectedMachine', 'Az.Resources')

    foreach ($mod in $modules) {
        if (-not (Get-Module -ListAvailable -Name $mod)) {
            Write-Host "  Installing PowerShell module: $mod" -ForegroundColor Yellow
            Install-Module -Name $mod -Repository PSGallery -Force -AllowClobber -Scope CurrentUser
        }
        Import-Module -Name $mod -Force
    }
}

#endregion

#region ── Main ────────────────────────────────────────────────────────────────

Assert-Elevated

# ── Step 1: Install required PowerShell modules ──────────────────────────────
Write-Step 'Installing required PowerShell modules'
Install-RequiredModules

# ── Step 2: Authenticate to Azure ────────────────────────────────────────────
Write-Step 'Authenticating to Azure using the service principal'
$secureSecret = ConvertTo-SecureString $ServicePrincipalSecret -AsPlainText -Force
$credential   = New-Object System.Management.Automation.PSCredential($ServicePrincipalClientId, $secureSecret)
Connect-AzAccount -ServicePrincipal -Tenant $TenantId -Credential $credential -Subscription $SubscriptionId | Out-Null
Write-Host '  Authenticated successfully.' -ForegroundColor Green

# ── Step 3: Validate resource providers are registered ────────────────────────
Write-Step 'Validating required Azure resource providers'
$providers = @(
    'Microsoft.HybridCompute',
    'Microsoft.GuestConfiguration',
    'Microsoft.AzureArcData',
    'Microsoft.OperationalInsights'
)
$missingProviders = @()
foreach ($provider in $providers) {
    $state = (Get-AzResourceProvider -ProviderNamespace $provider).RegistrationState | Select-Object -First 1
    if ($state -ne 'Registered') {
        Write-Host "  NOT registered: $provider (state: $state)" -ForegroundColor Red
        $missingProviders += $provider
    } else {
        Write-Host "  Registered: $provider" -ForegroundColor Green
    }
}
if ($missingProviders.Count -gt 0) {
    Write-Warning "The following providers are not registered: $($missingProviders -join ', ')"
    Write-Warning "Register them before running this script, e.g.:"
    foreach ($p in $missingProviders) { Write-Warning "  az provider register --namespace $p --wait" }
    throw "Required resource providers are not registered."
}

# ── Step 4: Download and install the Azure Connected Machine Agent ────────────
Write-Step 'Downloading Azure Connected Machine Agent installer'
$installerUrl  = 'https://aka.ms/AzureConnectedMachineAgent'
$installerPath = "$env:TEMP\AzureConnectedMachineAgent.msi"
Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
Write-Host '  Installer downloaded.' -ForegroundColor Green

Write-Step 'Installing Azure Connected Machine Agent'
$msiArgs = '/i "{0}" /l*v "{1}" /qn ACCEPTEULA=1' -f $installerPath, "$env:TEMP\ArcAgentInstall.log"
$result  = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
if ($result.ExitCode -ne 0) {
    throw "MSI installation failed with exit code $($result.ExitCode). See $env:TEMP\ArcAgentInstall.log for details."
}
Write-Host '  Agent installed successfully.' -ForegroundColor Green

# ── Step 5: Connect machine to Azure Arc ─────────────────────────────────────
Write-Step 'Connecting machine to Azure Arc'
$azcmAgentPath = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
if (-not (Test-Path $azcmAgentPath)) {
    throw "azcmagent.exe not found at '$azcmAgentPath'. Installation may have failed."
}

$connectArgs = @(
    'connect',
    '--tenant-id',        $TenantId,
    '--subscription-id',  $SubscriptionId,
    '--resource-group',   $ResourceGroupName,
    '--location',         $Location,
    '--resource-name',    $MachineName,
    '--service-principal-id',     $ServicePrincipalClientId,
    '--service-principal-secret', $ServicePrincipalSecret
)
if ($ProxyUrl) {
    $connectArgs += @('--proxy', $ProxyUrl)
}

& $azcmAgentPath @connectArgs
if ($LASTEXITCODE -ne 0) {
    throw "azcmagent connect failed with exit code $LASTEXITCODE."
}
Write-Host '  Machine connected to Azure Arc.' -ForegroundColor Green

# ── Step 6: Wait for the SQL Server Arc extension to be provisioned ───────────
Write-Step 'Waiting for the SQL Server Azure Arc extension to be provisioned'
Write-Host '  Arc automatically deploys the SQL Server extension when SQL Server is detected.' -ForegroundColor Yellow
Write-Host '  Waiting up to 10 minutes for the extension to appear...' -ForegroundColor Yellow

$extensionName = 'WindowsAgent.SqlServer'
$maxWaitSeconds = 600
$pollIntervalSeconds = 30
$elapsed = 0
$extensionFound = $false

while ($elapsed -lt $maxWaitSeconds) {
    try {
        $ext = Get-AzConnectedMachineExtension `
            -ResourceGroupName $ResourceGroupName `
            -MachineName $MachineName `
            -Name $extensionName `
            -ErrorAction SilentlyContinue
        if ($ext -and $ext.ProvisioningState -eq 'Succeeded') {
            $extensionFound = $true
            break
        }
    } catch {
        # Extension not yet created – keep polling
    }
    Start-Sleep -Seconds $pollIntervalSeconds
    $elapsed += $pollIntervalSeconds
    Write-Host "  Still waiting... ($elapsed / $maxWaitSeconds seconds elapsed)"
}

if (-not $extensionFound) {
    Write-Warning "The SQL Server Arc extension was not detected within $maxWaitSeconds seconds."
    Write-Warning 'You may need to enable it manually from the Azure portal or check that SQL Server is running on this machine.'
} else {
    Write-Host '  SQL Server Arc extension is provisioned.' -ForegroundColor Green
}

# ── Step 6b: Set SQL Server license type to enable BPA ────────────────────────
Write-Step 'Setting SQL Server license type (required for BPA)'

# Use REST API to update the SQL Server Arc extension license type to "Paid"
# This is required for BPA — Developer edition with SA license type enables all features
$tokenObj = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
$tokenVal = if ($tokenObj.Token -is [System.Security.SecureString]) {
    [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenObj.Token))
} else { $tokenObj.Token }

$extHeaders = @{
    Authorization  = "Bearer $tokenVal"
    'Content-Type' = 'application/json'
}

$extUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName" +
    "/providers/Microsoft.HybridCompute/machines/$MachineName/extensions/WindowsAgent.SqlServer?api-version=2024-07-10"

try {
    $extInfo = Invoke-RestMethod -Uri $extUri -Headers $extHeaders -Method Get
    $currentLicense = $extInfo.properties.settings.LicenseType

    if ($currentLicense -ne 'Paid') {
        Write-Host "  Current license type: '$currentLicense'. Updating to 'Paid'..." -ForegroundColor Yellow
        $patchBody = @{
            properties = @{
                settings = @{ LicenseType = "Paid" }
            }
        } | ConvertTo-Json -Depth 5

        Invoke-RestMethod -Uri $extUri -Headers $extHeaders -Method Patch -Body $patchBody | Out-Null
        Write-Host "  License type set to 'Paid'." -ForegroundColor Green
    } else {
        Write-Host "  License type already set to 'Paid'." -ForegroundColor Green
    }
} catch {
    Write-Host "  Warning: Could not set license type: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  Set it manually: Azure Portal > Arc server > SQL Server configuration > License type" -ForegroundColor Yellow
}

# ── Step 7: Enable SQL Best Practices Assessment ──────────────────────────────
Write-Step 'Enabling SQL Best Practices Assessment on the Arc-enabled SQL Server'

# Enable assessment via REST API — no Az.ArcData module needed.
# The token handling supports both older (string) and newer (SecureString) Az modules.
$tokenObj = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
$token = if ($tokenObj.Token -is [System.Security.SecureString]) {
    [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenObj.Token))
} else { $tokenObj.Token }

$headers = @{
    Authorization  = "Bearer $token"
    'Content-Type' = 'application/json'
}

# Wait for the SQL Server Arc extension to register the SQL instance (may take a few minutes)
$sqlInstanceApiBase = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName" +
    "/providers/Microsoft.AzureArcData/sqlServerInstances"
$apiVersion = '2023-03-15-preview'

$maxWait = 300  # 5 minutes
$elapsed = 0
$sqlInstanceName = $null

Write-Host "  Waiting for SQL Server Arc instance to be discovered..." -ForegroundColor Yellow
while ($elapsed -lt $maxWait) {
    try {
        $instances = Invoke-RestMethod -Uri "$sqlInstanceApiBase`?api-version=$apiVersion" -Headers $headers -Method Get
        $match = $instances.value | Where-Object { $_.name -match $MachineName }
        if ($match) {
            $sqlInstanceName = $match.name
            Write-Host "  Found SQL instance: $sqlInstanceName" -ForegroundColor Green
            break
        }
    } catch { }
    Start-Sleep -Seconds 30
    $elapsed += 30
    Write-Host "  Still waiting... ($elapsed seconds)" -ForegroundColor Yellow
}

if ($sqlInstanceName) {
    $assessmentUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName" +
        "/providers/Microsoft.AzureArcData/sqlServerInstances/$sqlInstanceName/assessments/default" +
        "?api-version=$apiVersion"

    $body = @{
        properties = @{
            assessmentEnabled   = $true
            workspaceResourceId = $WorkspaceId
        }
    } | ConvertTo-Json -Depth 5

    try {
        Invoke-RestMethod -Uri $assessmentUri -Method Put -Headers $headers -Body $body | Out-Null
        Write-Host '  SQL Best Practices Assessment enabled successfully.' -ForegroundColor Green
        Write-Host "  Results will be sent to Log Analytics workspace: $WorkspaceId" -ForegroundColor Green
    } catch {
        Write-Host "  Warning: Could not enable assessment via REST API: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  Enable manually: Azure Portal > Arc-enabled SQL Server > Best Practices Assessment" -ForegroundColor Yellow
    }
} else {
    Write-Host "  Warning: SQL Server instance not discovered after $maxWait seconds." -ForegroundColor Yellow
    Write-Host "  The SQL extension may still be deploying. Check the Azure portal in a few minutes." -ForegroundColor Yellow
    Write-Host "  Enable BPA manually: Azure Portal > Arc-enabled SQL Server > Best Practices Assessment" -ForegroundColor Yellow
}

Write-Host "`n[DONE] Azure Arc agent installation and SQL Best Practices Assessment setup complete." -ForegroundColor Cyan

#endregion
