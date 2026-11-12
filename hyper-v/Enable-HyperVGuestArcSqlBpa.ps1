<#
.SYNOPSIS
    Onboards named Hyper-V guests to Azure Arc and enables SQL BPA from the host.
.DESCRIPTION
    Run elevated on the Azure Hyper-V host, not inside a guest. Uses PowerShell
    Direct for guest operations and the service principal for Azure operations.
    Requires Windows PowerShell 5.1+ and Az.Accounts on the host.
    Uses the deployment template from Microsoft's built-in SQL BPA policy,
    without assigning a policy or changing other machines.

    Paid means an eligible Software Assurance/subscription entitlement.
    PAYG opts into SQL pay-as-you-go billing. Neither is inferred from edition.
    Existing Arc registrations must match the requested resource and tenant.
    Reruns preserve agent connections and extension settings.
.PARAMETER VMName
    Explicit guest VM names, for example arcsql-06 and arcsql-07.
.PARAMETER GuestCredential
    Local Administrator credential shared by the selected guests. Prompts if omitted.
.PARAMETER ServicePrincipalSecret
    Secure service principal secret. Prompts if omitted; no workspace key is needed.
.PARAMETER WorkspaceResourceId
    Existing Log Analytics workspace ARM resource ID in the target subscription.
.PARAMETER LicenseType
    Explicit licensing declaration: Paid (eligible existing entitlement) or PAYG
    (pay-as-you-go charges). Verify entitlement before selecting Paid.
.EXAMPLE
    .\Enable-HyperVGuestArcSqlBpa.ps1 -VMName arcsql-06,arcsql-07 `
        -TenantId '<tenant-guid>' -SubscriptionId '<subscription-guid>' `
        -ResourceGroupName 'sql-bpa-lab-rg' -Location 'swedencentral' `
        -ServicePrincipalClientId '<application-guid>' `
        -WorkspaceResourceId '/subscriptions/<subscription-guid>/resourceGroups/sql-bpa-lab-rg/providers/Microsoft.OperationalInsights/workspaces/sql-bpa-lab-law' `
        -LicenseType Paid
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string[]]$VMName,
    [Parameter(Mandatory)] [guid]$TenantId,
    [Parameter(Mandatory)] [guid]$SubscriptionId,
    [Parameter(Mandatory)] [ValidatePattern('^[\w().-]+$')] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9]+$')] [string]$Location,
    [Parameter(Mandatory)] [guid]$ServicePrincipalClientId,
    [Parameter(Mandatory)] [string]$WorkspaceResourceId,
    [Parameter(Mandatory)] [ValidateSet('Paid', 'PAYG')] [string]$LicenseType,
    [PSCredential]$GuestCredential,
    [Security.SecureString]$ServicePrincipalSecret,
    [ValidateRange(5, 120)] [int]$TimeoutMinutes = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-ArcArm {
    param([string]$Path, [string]$Method = 'GET', [object]$Body, [switch]$AllowNotFound)
    $arguments = @{ Path=$Path; Method=$Method; ErrorAction='Stop' }
    if ($null -ne $Body) { $arguments.Payload = $Body | ConvertTo-Json -Depth 100 -Compress }
    try {
        $response = Invoke-AzRestMethod @arguments
    } catch {
        if ($AllowNotFound -and $_.Exception.PSObject.Properties['Response'] -and
            $_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
            return $null
        }
        throw
    }
    if ($AllowNotFound -and $response.StatusCode -eq 404) { return $null }
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "ARM $Method $Path failed (HTTP $($response.StatusCode)): $($response.Content)"
    }
    if ($response.Content) { return $response.Content | ConvertFrom-Json }
}

function Wait-ArcArm {
    param([string]$Path, [scriptblock]$Ready, [string]$Description, [int]$Minutes)
    $deadline = (Get-Date).AddMinutes($Minutes)
    do {
        $resource = Invoke-ArcArm -Path $Path -AllowNotFound
        if ($null -ne $resource) {
            if ($resource.properties.PSObject.Properties['provisioningState'] -and
                $resource.properties.provisioningState -in @('Failed', 'Canceled')) {
                throw "$Description failed: $($resource | ConvertTo-Json -Depth 20 -Compress)"
            }
            if (& $Ready $resource) { return $resource }
        }
        if ((Get-Date) -ge $deadline) { throw "Timed out after $Minutes minutes: $Description. Rerun after resolving the Azure/guest error." }
        Start-Sleep -Seconds 15
    } while ($true)
}

function Get-ArcSqlExtensionBody {
    param([object]$Existing, [string]$License, [string]$Region)
    $settings = @{}
    if ($null -ne $Existing -and $Existing.properties.PSObject.Properties['settings'] -and $Existing.properties.settings) {
        foreach ($property in $Existing.properties.settings.PSObject.Properties) { $settings[$property.Name] = $property.Value }
    }
    $settings.LicenseType = $License
    $properties = @{
        settings=$settings; autoUpgradeMinorVersion=$true; enableAutomaticUpgrade=$true
    }
    if ($null -eq $Existing) {
        $properties.publisher = 'Microsoft.AzureData'
        $properties.type = 'WindowsAgent.SqlServer'
        $properties.typeHandlerVersion = '1.1'
    }
    return @{ location=$Region; properties=$properties }
}

function Wait-ArcSqlInstance {
    param([string]$GroupPath, [string]$MachineId, [int]$Minutes)
    $deadline = (Get-Date).AddMinutes($Minutes)
    do {
        $path = "$GroupPath/providers/Microsoft.AzureArcData/sqlServerInstances?api-version=2024-01-01"
        $matches = @()
        do {
            $page = Invoke-ArcArm -Path $path
            $matches += @($page.value | Where-Object { $_.properties.containerResourceId -eq $MachineId })
            $path = $null
            if ($page.PSObject.Properties['nextLink'] -and $page.nextLink) {
                $next = [uri]$page.nextLink
                if ($next.Scheme -ne 'https' -or $next.Host -ne 'management.azure.com') { throw 'Unexpected SQL discovery pagination URL.' }
                $path = $next.PathAndQuery
            }
        } while ($path)
        if ($matches.Count) { return $matches }
        if ((Get-Date) -ge $deadline) { throw "No Arc SQL instance discovered for $MachineId after $Minutes minutes." }
        Start-Sleep -Seconds 15
    } while ($true)
}

$guestPreflight = {
    param($ExpectedId, $ExpectedTenant, $CloudResourceExists)
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'PowerShell Direct requires an elevated guest Administrator.'
    }
    $service = Get-Service -Name MSSQLSERVER -ErrorAction Stop
    if ($service.Status -ne 'Running') { throw 'Start the default MSSQLSERVER instance before onboarding.' }
    $connection = [Data.SqlClient.SqlConnection]::new('Server=localhost;Integrated Security=True;TrustServerCertificate=True;Connection Timeout=30')
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = "SELECT IS_SRVROLEMEMBER('sysadmin', 'NT AUTHORITY\SYSTEM')"
        if ($command.ExecuteScalar() -ne 1) { throw 'SQL BPA requires NT AUTHORITY\SYSTEM to be a SQL sysadmin.' }
    } finally { $connection.Dispose() }

    $agent = Join-Path $env:ProgramFiles 'AzureConnectedMachineAgent\azcmagent.exe'
    if (Test-Path -LiteralPath $agent) {
        $json = & $agent show --json
        if ($LASTEXITCODE -ne 0) { throw "azcmagent show failed (exit $LASTEXITCODE)." }
        $state = ($json -join "`n") | ConvertFrom-Json
        if ($state.PSObject.Properties['resourceId'] -and $state.resourceId) {
            if ($state.resourceId.TrimEnd('/') -ne $ExpectedId -or $state.tenantId -ne $ExpectedTenant) {
                throw 'Guest is already registered to another Arc resource or tenant. No disconnect was performed.'
            }
            if (-not $CloudResourceExists) { throw 'Guest registration exists but its Azure resource is missing. Resolve the stale registration manually.' }
            return
        }
    }
    if ($CloudResourceExists) { throw 'The target Arc resource already exists but this guest is not registered to it. Refusing to overwrite another machine.' }
}

$guestOnboard = {
    param($ExpectedId, $Tenant, $Subscription, $Group, $Region, $Name, $ClientId, [Security.SecureString]$Secret)
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if (-not (Get-NetFirewallRule | Where-Object { $_.Name -eq 'ArcSqlLabBlockIMDS' })) {
        New-NetFirewallRule -Name ArcSqlLabBlockIMDS -DisplayName 'Arc SQL lab: block Azure IMDS' `
            -Direction Outbound -Action Block -RemoteAddress 169.254.169.254 -Profile Any | Out-Null
    }
    Set-NetFirewallRule -Name ArcSqlLabBlockIMDS -Enabled True -Direction Outbound -Action Block `
        -RemoteAddress 169.254.169.254 -Profile Any
    $agent = Join-Path $env:ProgramFiles 'AzureConnectedMachineAgent\azcmagent.exe'
    if (-not (Test-Path -LiteralPath $agent)) {
        $installer = Join-Path $env:TEMP 'ArcSqlLabAgent.msi'
        try {
            Invoke-WebRequest -Uri 'https://aka.ms/AzureConnectedMachineAgent' -OutFile $installer -UseBasicParsing
            $signature = Get-AuthenticodeSignature -FilePath $installer
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {
                throw 'Arc installer does not have a valid Microsoft Authenticode signature.'
            }
            $process = Start-Process msiexec.exe -ArgumentList "/i `"$installer`" /qn /norestart ACCEPTEULA=1" -Wait -PassThru
            if ($process.ExitCode -notin @(0, 3010)) { throw "Arc MSI installation failed (exit $($process.ExitCode))." }
            if ($process.ExitCode -eq 3010) { throw 'Arc installation requires a guest restart. Restart this guest, then rerun.' }
        } finally {
            if (Test-Path -LiteralPath $installer) { Remove-Item -LiteralPath $installer -Force }
        }
    }
    $json = & $agent show --json
    if ($LASTEXITCODE -ne 0) { throw "azcmagent show failed (exit $LASTEXITCODE)." }
    $state = ($json -join "`n") | ConvertFrom-Json
    if ($state.PSObject.Properties['resourceId'] -and $state.resourceId) {
        if ($state.resourceId.TrimEnd('/') -ne $ExpectedId -or $state.tenantId -ne $Tenant) {
            throw 'Guest Arc identity changed after preflight. Refusing to reconnect.'
        }
        Start-Service -Name himds
        return
    }
    $plainSecret = [PSCredential]::new($ClientId, $Secret).GetNetworkCredential().Password
    try {
        # Capture native output so a failing command cannot echo credentials into the host transcript.
        try {
            $connectOutput = & $agent connect --tenant-id $Tenant --subscription-id $Subscription `
                --resource-group $Group --location $Region --resource-name $Name `
                --service-principal-id $ClientId --service-principal-secret $plainSecret 2>&1
        } catch {
            throw 'Arc onboarding invocation failed. Native diagnostics are omitted to protect credentials; inspect guest azcmagent logs privately.'
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Arc onboarding failed (exit $LASTEXITCODE). Inspect guest azcmagent logs privately; native output is omitted to protect credentials."
        }
    } finally { $plainSecret = $null; $connectOutput = $null }
}

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run elevated on the Hyper-V host.' }
if ($WorkspaceResourceId -notmatch "^/subscriptions/$SubscriptionId/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$") {
    throw 'WorkspaceResourceId must be a Log Analytics workspace resource ID in the target subscription.'
}
if (@($VMName | Select-Object -Unique).Count -ne $VMName.Count) { throw 'Duplicate VM names are not allowed.' }
Import-Module Hyper-V -ErrorAction Stop
foreach ($name in $VMName) {
    if ($name -notmatch '^[a-zA-Z][a-zA-Z0-9-]{0,13}[a-zA-Z0-9]$' -or $name -eq $env:COMPUTERNAME) {
        throw "Invalid guest VM name: $name. Never target the Azure host itself."
    }
    $vm = Get-VM -Name $name -ErrorAction Stop
    $adapters = @(Get-VMNetworkAdapter -VMName $name)
    if ($vm.State -ne 'Running' -or $adapters.Count -ne 1 -or $adapters[0].SwitchName -ne 'ArcSqlLabNAT') {
        throw "$name must be running with one adapter connected to ArcSqlLabNAT. Complete guest provisioning first."
    }
}
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    throw 'Install the required host module, then rerun: Install-Module Az.Accounts -Scope AllUsers -Repository PSGallery'
}
Import-Module Az.Accounts -ErrorAction Stop
if (-not $GuestCredential) { $GuestCredential = Get-Credential -UserName Administrator -Message 'Local Administrator for the selected Hyper-V guests' }
if (-not $ServicePrincipalSecret) { $ServicePrincipalSecret = Read-Host 'Azure service principal secret' -AsSecureString }
if (-not $GuestCredential -or $ServicePrincipalSecret.Length -eq 0) { throw 'Guest credentials and a nonempty service principal secret are required.' }
Disable-AzContextAutosave -Scope Process | Out-Null
$spCredential = [PSCredential]::new($ServicePrincipalClientId.ToString(), $ServicePrincipalSecret)
Connect-AzAccount -ServicePrincipal -Tenant $TenantId -Subscription $SubscriptionId -Credential $spCredential `
    -Environment AzureCloud -Scope Process | Out-Null

$subscriptionPath = "/subscriptions/$SubscriptionId"
$groupPath = "$subscriptionPath/resourceGroups/$ResourceGroupName"
Invoke-ArcArm -Path "$groupPath`?api-version=2021-04-01" | Out-Null
foreach ($provider in @('Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.AzureArcData', 'Microsoft.OperationalInsights', 'Microsoft.Insights')) {
    $registration = Invoke-ArcArm -Path "$subscriptionPath/providers/$provider`?api-version=2021-04-01"
    if ($registration.registrationState -ne 'Registered') { throw "Register $provider in the target subscription before rerunning." }
}
$workspace = Invoke-ArcArm -Path "$WorkspaceResourceId`?api-version=2022-10-01"
$policy = Invoke-ArcArm -Path '/providers/Microsoft.Authorization/policyDefinitions/f36de009-cacb-47b3-b936-9c4c9120d064?api-version=2023-04-01'
$template = $policy.properties.policyRule.then.details.deployment.properties.template
foreach ($parameter in @('extensionName', 'laWorkspaceId', 'laWorkspaceLocation', 'vmLocation', 'agentName', 'existingSettings', 'isEnabled')) {
    if (-not $template.parameters.PSObject.Properties[$parameter]) {
        throw "Microsoft's BPA deployment template changed (missing $parameter). Review it before proceeding."
    }
}

$sessions = @{}
try {
    # Validate every target before installing agents or changing Azure resources.
    foreach ($name in $VMName) {
        $machineId = "$groupPath/providers/Microsoft.HybridCompute/machines/$name"
        $machine = Invoke-ArcArm -Path "$machineId`?api-version=2024-07-10" -AllowNotFound
        if ($machine -and $machine.location -ne $Location) { throw "Existing Arc location differs for $name." }
        $sessions[$name] = New-PSSession -VMName $name -Credential $GuestCredential -ErrorAction Stop
        Invoke-Command -Session $sessions[$name] -ScriptBlock $guestPreflight `
            -ArgumentList $machineId, $TenantId.ToString(), ($null -ne $machine) -ErrorAction Stop
    }
    foreach ($name in $VMName) {
        Write-Host "`n==> Enabling Arc SQL BPA: $name" -ForegroundColor Cyan
        $machineId = "$groupPath/providers/Microsoft.HybridCompute/machines/$name"
        Invoke-Command -Session $sessions[$name] -ScriptBlock $guestOnboard -ErrorAction Stop -ArgumentList `
            $machineId, $TenantId.ToString(), $SubscriptionId.ToString(), $ResourceGroupName, $Location, $name, $ServicePrincipalClientId.ToString(), $ServicePrincipalSecret
        Wait-ArcArm -Path "$machineId`?api-version=2024-07-10" -Minutes $TimeoutMinutes -Description "$name Arc connection" `
            -Ready { param($r) $r.properties.status -eq 'Connected' } | Out-Null

        $extensionId = "$machineId/extensions/WindowsAgent.SqlServer"
        $extensionPath = "$extensionId`?api-version=2024-07-10"
        $extension = Invoke-ArcArm -Path $extensionPath -AllowNotFound
        if ($extension -and $extension.properties.provisioningState -notin @('Succeeded', 'Failed', 'Canceled')) {
            $extension = Wait-ArcArm -Path $extensionPath -Minutes $TimeoutMinutes -Description "$name SQL extension auto-deployment" `
                -Ready { param($r) $r.properties.provisioningState -eq 'Succeeded' }
        }
        $body = Get-ArcSqlExtensionBody -Existing $extension -License $LicenseType -Region $Location
        $method = if ($null -eq $extension) { 'PUT' } else { 'PATCH' }
        Invoke-ArcArm -Path $extensionPath -Method $method -Body $body | Out-Null
        $extension = Wait-ArcArm -Path $extensionPath -Minutes $TimeoutMinutes -Description "$name SQL extension" `
            -Ready { param($r) $r.properties.provisioningState -eq 'Succeeded' }
        $instances = @(Wait-ArcSqlInstance -GroupPath $groupPath -MachineId $machineId -Minutes $TimeoutMinutes)

        $deploymentName = "arc-sql-bpa-$name"
        $deploymentPath = "$groupPath/providers/Microsoft.Resources/deployments/$deploymentName`?api-version=2022-09-01"
        $parameters = @{
            extensionName=@{value="$name/WindowsAgent.SqlServer"}; agentName=@{value='WindowsAgent.SqlServer'}
            laWorkspaceId=@{value=$WorkspaceResourceId}; laWorkspaceLocation=@{value=$workspace.location}
            vmLocation=@{value=$Location}; existingSettings=@{value=$extension.properties.settings}; isEnabled=@{value=$true}
        }
        Invoke-ArcArm -Path $deploymentPath -Method PUT -Body @{
            properties=@{ mode='Incremental'; template=$template; parameters=$parameters }
        } | Out-Null
        Wait-ArcArm -Path $deploymentPath -Minutes $TimeoutMinutes -Description "$name BPA deployment" `
            -Ready { param($r) $r.properties.provisioningState -eq 'Succeeded' } | Out-Null
        $extension = Invoke-ArcArm -Path $extensionPath
        $assessment = $extension.properties.settings.AssessmentSettings
            if ($extension.properties.provisioningState -ne 'Succeeded' -or
                $extension.properties.settings.LicenseType -ne $LicenseType -or
                $assessment.Enable -ne $true -or $assessment.WorkspaceResourceId -ne $WorkspaceResourceId) {
            throw "$name BPA deployment completed but the extension does not have the requested assessment settings."
        }
        Wait-ArcArm -Path "$machineId/extensions/AzureMonitorWindowsAgent?api-version=2024-07-10" `
            -Minutes $TimeoutMinutes -Description "$name Azure Monitor Agent" `
            -Ready { param($r) $r.properties.provisioningState -eq 'Succeeded' } | Out-Null
        [pscustomobject]@{
            VMName=$name; ArcResourceId=$machineId; SqlInstances=($instances.name -join ', ')
            BPAEnabled=$true; WorkspaceResourceId=$WorkspaceResourceId
        }
    }
} finally {
    foreach ($session in $sessions.Values) { Remove-PSSession -Session $session }
}
Write-Host 'Selected guests are Arc-connected with SQL BPA enabled. Assessment results arrive after a scheduled run; ingestion has not been verified.' -ForegroundColor Green
