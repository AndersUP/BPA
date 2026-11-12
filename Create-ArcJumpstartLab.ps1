<#
.SYNOPSIS
    Builds an Azure-hosted, Jumpstart-inspired lab with five nested Arc SQL servers.
.DESCRIPTION
    Defaults to a local preview. Add -Deploy to create the dedicated Azure lab.
    Reuses existing workspace/DCR/DCE resources; does not change Defender plans
    or claim paid SQL entitlement. See docs/ARC-JUMPSTART-LAB.md.
.EXAMPLE
    # One-time setup: save each credential outside the repository.
    # Windows encrypts these passwords for this Windows user on this computer.
    $credentialDirectory = Join-Path $env:LOCALAPPDATA 'ArcSqlLab'
    New-Item -ItemType Directory -Path $credentialDirectory -Force | Out-Null
    Get-Credential -UserName arcadmin -Message 'New lab credentials' |
        Export-Clixml -LiteralPath (Join-Path $credentialDirectory 'lab.xml')
    Get-Credential -UserName Administrator -Message 'Published image credentials' |
        Export-Clixml -LiteralPath (Join-Path $credentialDirectory 'image.xml')
    Get-Credential -Message 'Client ID as username; client secret as password' |
        Export-Clixml -LiteralPath (Join-Path $credentialDirectory 'onboarding.xml')
.EXAMPLE
    # Subsequent runs: no password prompts. Replace the resource ID placeholders.
    $credentialDirectory = Join-Path $env:LOCALAPPDATA 'ArcSqlLab'
    $parameters = @{
        SubscriptionId = '<subscription-id>'
        ResourceGroupName = 'arc-sql-jumpstart-rg'
        MonitoringResourceGroupName = 'sql-bpa-lab-rg'
        Location = 'swedencentral'
        HostName = 'arcsql-host'
        MachinePrefix = 'arcsql'
        MachineCount = 5
        VmSize = 'Standard_D16s_v5'
        WorkspaceResourceId = '<workspace-resource-id>'
        AssessmentDcrResourceId = '<assessment-dcr-resource-id>'
        PerformanceDcrResourceId = '<performance-dcr-resource-id>'
        DataCollectionEndpointResourceId = '<dce-resource-id>'
        LabCredential = Import-Clixml -LiteralPath (Join-Path $credentialDirectory 'lab.xml')
        ImageCredential = Import-Clixml -LiteralPath (Join-Path $credentialDirectory 'image.xml')
        OnboardingCredential = Import-Clixml -LiteralPath (Join-Path $credentialDirectory 'onboarding.xml')
        NonInteractive = $true
        Deploy = $true
        Confirm = $false
    }
    .\Create-ArcJumpstartLab.ps1 @parameters
    # Omit the four monitoring resource IDs to use automatic discovery.
.EXAMPLE
    # Use the upstream image's public demo credentials for initial login only.
    # Keep LabCredential and OnboardingCredential in your existing hashtable.
    $parameters.Remove('ImageCredential')
    $parameters.UsePublishedImageCredential = $true
    .\Create-ArcJumpstartLab.ps1 @parameters
    # Each isolated guest is switched to LabCredential.Password before networking.
#>
#requires -Version 7.2
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [guid]$SubscriptionId,
    [string]$ResourceGroupName = 'arc-sql-jumpstart-rg',
    [string]$MonitoringResourceGroupName = 'sql-bpa-lab-rg',
    [string]$Location = 'swedencentral',
    [ValidatePattern('^[a-z](?:[a-z0-9-]{0,13}[a-z0-9])?$')]
    [string]$HostName = 'arcsql-host',
    [ValidatePattern('^[a-z][a-z0-9]{0,7}$')]
    [string]$MachinePrefix = 'arcsql',
    [ValidateRange(1, 5)]
    [int]$MachineCount = 5,
    [ValidateSet('Standard_D16s_v5', 'Standard_D16s_v4', 'Standard_D16s_v3')]
    [string]$VmSize = 'Standard_D16s_v5',
    [string]$WorkspaceResourceId,
    [string]$AssessmentDcrResourceId,
    [string]$PerformanceDcrResourceId,
    [string]$DataCollectionEndpointResourceId,
    [PSCredential]$LabCredential,
    [PSCredential]$ImageCredential,
    [switch]$UsePublishedImageCredential,
    [PSCredential]$OnboardingCredential,
    [switch]$NonInteractive,
    [switch]$Deploy
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-LabProgress {
    param([string]$Message, [int]$Step = $script:progressStep)
    $script:progressStep = $Step
    $elapsed = $script:labTimer.Elapsed.ToString('hh\:mm\:ss')
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [Step $Step/8; elapsed $elapsed] $Message"
}

function Invoke-LabAz {
    param([string[]]$Arguments, [switch]$TenantScope)
    $scopeArguments = if ($TenantScope) { @() } else { @('--subscription', "$SubscriptionId") }
    $output = & az @Arguments @scopeArguments --only-show-errors --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed during '$($Arguments[0..([Math]::Min(2, $Arguments.Count - 1))] -join ' ')':`n$($output -join "`n")"
    }
    if ($output) { return ($output -join "`n") | ConvertFrom-Json }
}

function Get-LabArcStatus {
    param([object]$Machine)
    $properties = $Machine.PSObject.Properties['properties']
    if ($properties -and $properties.Value) {
        $status = $properties.Value.PSObject.Properties['status']
        if ($status -and $status.Value) { return $status.Value }
    }
    return 'NotReported'
}

function Write-LabJson {
    param([object]$Value)
    $path = Join-Path $script:tempDirectory "$([guid]::NewGuid().ToString('N')).json"
    $Value | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

function Invoke-LabRest {
    param([string]$Method, [string]$Id, [string]$ApiVersion, [object]$Body, [switch]$ExpandInstanceView)
    $arguments = @('rest', '--method', $Method, '--url', "https://management.azure.com${Id}",
        '--url-parameters', "api-version=$ApiVersion")
    if ($ExpandInstanceView) { $arguments += '$expand=instanceView' }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $arguments += @('--body', "@$(Write-LabJson $Body)")
    }
    Invoke-LabAz $arguments
}

function Resolve-MonitoringResource {
    param([string]$Id, [string]$Type, [string]$NamePattern, [string]$ApiVersion)
    if (-not $Id) {
        $resources = @(Invoke-LabAz @('resource', 'list', '--resource-group', $MonitoringResourceGroupName, '--resource-type', $Type))
        $matches = @($resources | Where-Object { $_.name -like $NamePattern })
        if ($matches.Count -ne 1) {
            throw "Expected one $Type matching '$NamePattern' in $MonitoringResourceGroupName; found $($matches.Count). Supply its resource ID explicitly."
        }
        $Id = $matches[0].id
    }
    if ($Id -notmatch "^/subscriptions/$SubscriptionId/resourceGroups/[^/]+/providers/$([regex]::Escape($Type))/[^/]+$") {
        throw "Monitoring resource must be a $Type in subscription $SubscriptionId."
    }
    Invoke-LabRest -Method GET -Id $Id -ApiVersion $ApiVersion
}

function Wait-ArmProvisioning {
    param([string]$Id, [string]$ApiVersion)
    $deadline = (Get-Date).AddMinutes(30)
    do {
        try {
            $resource = Invoke-LabRest -Method GET -Id $Id -ApiVersion $ApiVersion
        } catch {
            if ($Id -notmatch '/providers/Microsoft\.HybridCompute/machines/[^/]+/extensions/[^/]+$' -or
                $_.Exception.Message -notmatch '"code"\s*:\s*"HCRP404"') { throw }
            if ((Get-Date) -ge $deadline) { throw "Extension did not become readable within 30 minutes: $Id. Last error: $($_.Exception.Message)" }
            Write-LabProgress "$(Split-Path $Id -Leaf): not yet visible (HCRP404); retrying in 20 seconds."
            Start-Sleep -Seconds 20
            continue
        }
        $state = $resource.properties.provisioningState
        Write-LabProgress "$(Split-Path $Id -Leaf): $state"
        if ($state -eq 'Succeeded') { return }
        if ($state -in @('Failed', 'Canceled')) { throw "Provisioning failed for ${Id}: $state. Inspect its extension status in Azure." }
        if ((Get-Date) -ge $deadline) { throw "Provisioning timed out for ${Id}: $state." }
        Start-Sleep -Seconds 20
    } while ($true)
}

$machineNames = @(1..$MachineCount | ForEach-Object { '{0}-{1:00}' -f $MachinePrefix, $_ })
Write-Host "Dedicated Azure resource group: $ResourceGroupName"
Write-Host "Host: $HostName ($VmSize, 64 GB RAM); nested SQL Developer servers: $($machineNames -join ', ')"
Write-Host 'Includes a 512 GB Premium SSD, OS disk, NAT Gateway, and outbound public IP. Azure charges apply.'
Write-Host 'No inbound public IP, Bastion, new workspace, Defender plan changes, or paid SQL license declaration.'
if (-not $Deploy) {
    Write-Host 'Preview only. Review docs\ARC-JUMPSTART-LAB.md, then add -Deploy to provision.'
    return
}
if (-not $PSCmdlet.ShouldProcess($ResourceGroupName, "Provision $MachineCount nested Arc SQL servers on an Azure Hyper-V host")) { return }
if ($UsePublishedImageCredential) {
    if ($ImageCredential) { throw 'Specify either -ImageCredential or -UsePublishedImageCredential, not both.' }
    # Public demo credential documented in the pinned upstream ArcServersLogonScript.
    $ImageCredential = [PSCredential]::new(
        'Administrator', (ConvertTo-SecureString 'JS123!!' -AsPlainText -Force))
}
if ($NonInteractive) {
    foreach ($credentialName in @('LabCredential', 'ImageCredential', 'OnboardingCredential')) {
        if (-not (Get-Variable -Name $credentialName -ValueOnly)) {
            throw "-NonInteractive requires -$credentialName. Supply all three PSCredential objects to deploy without password prompts."
        }
    }
}
$script:labTimer = [Diagnostics.Stopwatch]::StartNew()
Write-LabProgress -Step 1 'Validating Azure account, existing monitoring resources, and lab layout.'
if (-not $IsWindows) { throw 'Run this bootstrap from Windows PowerShell 7.2+; it uses Windows ACLs to protect temporary credentials.' }
Get-Command az -ErrorAction Stop | Out-Null
if ($ResourceGroupName -eq $MonitoringResourceGroupName) { throw 'Use a separate lab resource group; never place this deployment in the existing monitoring group.' }
if ($ResourceGroupName -notmatch '^[a-zA-Z0-9_-]+$') { throw 'Use letters, digits, hyphens, and underscores for the lab resource group.' }

$account = Invoke-LabAz @('account', 'show')
if ($account.id -ne "$SubscriptionId") { throw 'The Azure CLI account does not match the requested subscription.' }
$workspace = Resolve-MonitoringResource $WorkspaceResourceId 'Microsoft.OperationalInsights/workspaces' '*' '2022-10-01'
$assessmentDcr = Resolve-MonitoringResource $AssessmentDcrResourceId 'Microsoft.Insights/dataCollectionRules' '*-bpa-dcr' '2023-03-11'
$performanceDcr = Resolve-MonitoringResource $PerformanceDcrResourceId 'Microsoft.Insights/dataCollectionRules' '*-sql-perfcounters-dcr' '2023-03-11'
$dce = Resolve-MonitoringResource $DataCollectionEndpointResourceId 'Microsoft.Insights/dataCollectionEndpoints' '*-dce' '2023-03-11'
foreach ($rule in @($assessmentDcr, $performanceDcr)) {
    $destinations = @($rule.properties.destinations.logAnalytics)
    if ($destinations.Count -ne 1 -or $destinations[0].workspaceResourceId -ne $workspace.id) {
        throw "$($rule.name) must target only the selected workspace."
    }
    if ($rule.location -ne $workspace.location -or $rule.properties.dataCollectionEndpointId -ne $dce.id) {
        throw "$($rule.name) must use the selected workspace region and DCE."
    }
}
if ($dce.location -ne $workspace.location) { throw 'The DCE and workspace must have the same location.' }
$table = Invoke-LabRest -Method GET -Id "$($workspace.id)/tables/SqlAssessment_CL" -ApiVersion '2022-10-01'
foreach ($column in @{ TimeGenerated = 'datetime'; RawData = 'string' }.GetEnumerator()) {
    if (-not @($table.properties.schema.columns | Where-Object { $_.name -eq $column.Key -and $_.type -eq $column.Value }).Count) {
        throw "SqlAssessment_CL is missing the required $($column.Key) column/type."
    }
}
if (-not @($assessmentDcr.properties.dataFlows | Where-Object { $_.outputStream -eq 'Custom-SqlAssessment_CL' }).Count) {
    throw 'The assessment DCR does not output to Custom-SqlAssessment_CL.'
}
if (-not @($performanceDcr.properties.dataFlows | Where-Object { $_.streams -contains 'Microsoft-Perf' }).Count) {
    throw 'The performance DCR does not collect Microsoft-Perf.'
}

$groupExists = Invoke-LabAz @('group', 'exists', '--name', $ResourceGroupName)
$existingGuestRunId = $null
if ($groupExists) {
    Write-LabProgress "Checking existing lab resource group $ResourceGroupName for safe reuse."
    $group = Invoke-LabAz @('group', 'show', '--name', $ResourceGroupName)
    if (-not $group.tags -or -not $group.tags.PSObject.Properties['Purpose'] -or $group.tags.Purpose -ne 'ArcSqlJumpstartLab') {
        throw 'The target group is not marked Purpose=ArcSqlJumpstartLab. Refusing to modify a group owned by another deployment.'
    }
    $existingVms = @(Invoke-LabAz @('vm', 'list', '--resource-group', $ResourceGroupName))
    if (@($existingVms | Where-Object { $_.name -ne $HostName }).Count) {
        throw 'The target group contains another VM. Use a dedicated resource group.'
    }
    foreach ($tag in @{ HostName = $HostName; MachinePrefix = $MachinePrefix; MachineCount = "$MachineCount" }.GetEnumerator()) {
        if (-not $group.tags.PSObject.Properties[$tag.Key] -or $group.tags.($tag.Key) -ne $tag.Value) {
            throw "Existing lab layout differs ($($tag.Key)). Use the original layout or a new dedicated group."
        }
    }
    if ($existingVms.Count -eq 1) {
        $existingHostId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/virtualMachines/$HostName"
        $commands = Invoke-LabRest -Method GET -Id "$existingHostId/runCommands" -ApiVersion '2024-07-01'
        $guestRuns = @()
        foreach ($command in $commands.value) {
            $details = Invoke-LabRest -Method GET -Id $command.id -ApiVersion '2024-07-01' -ExpandInstanceView
            $instanceView = $details.properties.PSObject.Properties['instanceView']
            if (-not $instanceView -or -not $instanceView.Value -or
                $instanceView.Value.executionState -in @('Pending', 'Running', 'Unknown')) {
                $guestRuns += [PSCustomObject]@{ Id = $command.id; Active = $true; Details = $details }
            } elseif ((Split-Path $command.id -Leaf) -like 'arc-sql-*' -and $instanceView.Value.executionState -eq 'Succeeded') {
                $guestRuns += [PSCustomObject]@{ Id = $command.id; Active = $false; Details = $details }
            }
        }
        $activeRuns = @($guestRuns | Where-Object Active)
        if ($activeRuns.Count -gt 1 -or ($activeRuns.Count -eq 1 -and (Split-Path $activeRuns[0].Id -Leaf) -notlike 'arc-sql-*')) {
            throw 'Multiple or unrelated host Run Commands may still be executing. Inspect them before resuming.'
        }
        if ($activeRuns.Count -eq 1) {
            $candidate = $activeRuns[0]
            Write-LabProgress "Resuming guest setup: $($candidate.Id). Waiting before changing the host."
            $resumeDeadline = (Get-Date).AddHours(4)
            do {
                $details = Invoke-LabRest -Method GET -Id $candidate.Id -ApiVersion '2024-07-01' -ExpandInstanceView
                $instanceView = $details.properties.PSObject.Properties['instanceView']
                if ($instanceView -and $instanceView.Value -and
                    $instanceView.Value.executionState -in @('Succeeded', 'Failed', 'Canceled', 'TimedOut')) { break }
                if ((Get-Date) -ge $resumeDeadline) { throw "Timed out waiting for $($candidate.Id). Rerun to resume monitoring; do not start a concurrent guest setup." }
                Write-LabProgress 'Existing guest setup is still running; checking again in 30 seconds.'
                Start-Sleep -Seconds 30
            } while ($true)
            $view = $instanceView.Value
            $outputProperty = $view.PSObject.Properties['output']
            if ($view.executionState -ne 'Succeeded' -or $view.exitCode -ne 0 -or
                -not $outputProperty -or $outputProperty.Value -notmatch "(?m)^ARC_SQL_GUESTS_READY:$MachineCount\s*$") {
                throw "Existing guest setup did not confirm success. Inspect $($candidate.Id): $($view | ConvertTo-Json -Depth 10 -Compress)"
            }
            $existingGuestRunId = $candidate.Id
        } else {
            foreach ($candidate in $guestRuns) {
                $view = $candidate.Details.properties.instanceView
                $outputProperty = $view.PSObject.Properties['output']
                if ($view.exitCode -eq 0 -and $outputProperty -and
                    $outputProperty.Value -match "(?m)^ARC_SQL_GUESTS_READY:$MachineCount\s*$") {
                    $existingGuestRunId = $candidate.Id
                    break
                }
            }
        }
    }
}
$skus = @(Invoke-LabAz @('vm', 'list-skus', '--location', $Location, '--size', $VmSize, '--all'))
$sku = @($skus | Where-Object { $_.name -eq $VmSize -and $_.resourceType -eq 'virtualMachines' })
if ($sku.Count -ne 1 -or @($sku[0].restrictions | Where-Object { $_.type -eq 'Location' }).Count) {
    throw "$VmSize is not available to this subscription in $Location. Select another supported size/region."
}

Write-LabProgress -Step 2 'Preparing credentials, resource providers, resource group, and onboarding permissions.'
if (-not $LabCredential) { $LabCredential = Get-Credential -UserName arcadmin -Message 'New host admin credentials; the password also replaces the nested guests Administrator password' }
if (-not $ImageCredential) { $ImageCredential = Get-Credential -UserName Administrator -Message 'Initial credentials for the published Jumpstart SQL Developer image (see upstream source linked in the guide)' }
if (-not $OnboardingCredential) { $OnboardingCredential = Get-Credential -Message 'Existing Arc onboarding service principal: application/client ID as username, client secret as password' }
if ($LabCredential.Password.Length -lt 12) { throw 'The new lab password must contain at least 12 characters and satisfy Windows complexity requirements.' }
if ($LabCredential.GetNetworkCredential().Password -eq $ImageCredential.GetNetworkCredential().Password) {
    throw 'Choose a new, unique lab password, not the published image password.'
}
$clientId = [guid]::Parse($OnboardingCredential.UserName)
$principal = Invoke-LabAz -Arguments @('ad', 'sp', 'show', '--id', "$clientId") -TenantScope

$script:tempDirectory = Join-Path ([IO.Path]::GetTempPath()) "arc-sql-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $script:tempDirectory | Out-Null
try {
    $acl = Get-Acl -LiteralPath $script:tempDirectory
    $acl.SetAccessRuleProtection($true, $false)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $identity, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
    Set-Acl -LiteralPath $script:tempDirectory -AclObject $acl

    foreach ($namespace in @('Microsoft.Compute', 'Microsoft.Network', 'Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.AzureArcData', 'Microsoft.Insights')) {
        $provider = Invoke-LabAz @('provider', 'show', '--namespace', $namespace)
        if ($provider.registrationState -eq 'Registered') {
            Write-LabProgress "Resource provider $namespace is already registered; reusing."
        } else {
            Write-LabProgress "Registering resource provider $namespace; waiting for Azure."
            Invoke-LabAz @('provider', 'register', '--namespace', $namespace, '--wait') | Out-Null
        }
    }
    if (-not $groupExists) {
        Write-LabProgress "Creating dedicated resource group $ResourceGroupName."
        Invoke-LabAz @('group', 'create', '--name', $ResourceGroupName, '--location', $Location, '--tags',
            'Purpose=ArcSqlJumpstartLab', "HostName=$HostName", "MachinePrefix=$MachinePrefix", "MachineCount=$MachineCount") | Out-Null
    }
    $groupId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
    $assignments = @(Invoke-LabAz @('role', 'assignment', 'list', '--scope', $groupId))
    $onboardingAssignments = @($assignments | Where-Object {
        $_.principalId -eq $principal.id -and $_.scope -eq $groupId -and
        $_.roleDefinitionName -eq 'Azure Connected Machine Onboarding'
    })
    if ($onboardingAssignments.Count) {
        Write-LabProgress 'The onboarding role assignment already exists; reusing.'
    } else {
        Write-LabProgress 'Creating the resource-group-scoped Arc onboarding role assignment.'
        Invoke-LabAz @('role', 'assignment', 'create', '--assignee-object-id', $principal.id, '--assignee-principal-type', 'ServicePrincipal',
            '--role', 'Azure Connected Machine Onboarding', '--scope', $groupId) | Out-Null
    }

    Write-LabProgress -Step 3 "Reconciling Azure host $HostName, networking, and disks. This Azure deployment can take several minutes."
    $parameters = @{
        location = @{ value = $Location }; hostName = @{ value = $HostName }; vmSize = @{ value = $VmSize }
        adminUsername = @{ value = $LabCredential.UserName }; adminPassword = @{ value = $LabCredential.GetNetworkCredential().Password }
    }
    $parameterPath = Write-LabJson @{ parameters = $parameters }
    Invoke-LabAz @('deployment', 'group', 'create', '--resource-group', $ResourceGroupName, '--name', 'arc-sql-host',
        '--template-file', (Join-Path $PSScriptRoot 'jumpstart\host.json'), '--parameters', "@$parameterPath") | Out-Null

    Write-LabProgress -Step 4 "Ensuring $HostName is running, then checking/installing Hyper-V."
    Invoke-LabAz @('vm', 'start', '--resource-group', $ResourceGroupName, '--name', $HostName) | Out-Null
    $roleScript = @'
$ErrorActionPreference = 'Stop'
$feature = Get-WindowsFeature Hyper-V
if (-not $feature.Installed) {
    $result = Install-WindowsFeature Hyper-V -IncludeManagementTools
    if (-not $result.Success) { throw "Hyper-V installation failed: $($result.ExitCode)" }
    if ($result.RestartNeeded -eq 'Yes') { Write-Output 'ARC_SQL_REBOOT_REQUIRED'; exit 0 }
}
Write-Output 'ARC_SQL_ROLE_READY'
'@
    $roleScriptPath = Join-Path $script:tempDirectory 'enable-hyperv.ps1'
    Set-Content -LiteralPath $roleScriptPath -Value $roleScript -Encoding utf8
    $roleResult = Invoke-LabAz @('vm', 'run-command', 'invoke', '--resource-group', $ResourceGroupName, '--name', $HostName,
        '--command-id', 'RunPowerShellScript', '--scripts', "@$roleScriptPath")
    $roleOutput = $roleResult.value.message -join "`n"
    if ($roleOutput -match 'ARC_SQL_REBOOT_REQUIRED') {
        Write-LabProgress "Hyper-V requires a restart; restarting Azure host $HostName and waiting for completion."
        Invoke-LabAz @('vm', 'restart', '--resource-group', $ResourceGroupName, '--name', $HostName) | Out-Null
    } elseif ($roleOutput -notmatch 'ARC_SQL_ROLE_READY') {
        throw "The host did not report Hyper-V readiness:`n$roleOutput"
    }
    Write-LabProgress 'Hyper-V is ready.'

    Write-LabProgress -Step 5 "Starting resumable guest setup for $MachineCount SQL servers. The initial image download is approximately 53 GB."
    if ($existingGuestRunId) {
        $runName = Split-Path $existingGuestRunId -Leaf
        Write-LabProgress "Reusing verified guest setup $runName; no new guest Run Command will be created."
    } else {
    $configuration = @{
        TenantId = $account.tenantId; SubscriptionId = "$SubscriptionId"; ResourceGroupName = $ResourceGroupName
        Location = $Location; MachineCount = $MachineCount; MachinePrefix = $MachinePrefix
        LabPassword = $LabCredential.GetNetworkCredential().Password
        ImageUsername = $ImageCredential.UserName; ImagePassword = $ImageCredential.GetNetworkCredential().Password
        ClientId = "$clientId"; ClientSecret = $OnboardingCredential.GetNetworkCredential().Password
    }
    $runName = "arc-sql-$([guid]::NewGuid().ToString('N'))"
    $parameterPath = Write-LabJson @{ parameters = @{
        location = @{ value = $Location }; hostName = @{ value = $HostName }; runName = @{ value = $runName }
        script = @{ value = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'jumpstart\Initialize-ArcSqlGuests.ps1') -Raw }
        configuration = @{ value = $configuration }
    } }
    Invoke-LabAz @('deployment', 'group', 'create', '--resource-group', $ResourceGroupName, '--name', 'arc-sql-guests',
        '--template-file', (Join-Path $PSScriptRoot 'jumpstart\guests.json'), '--parameters', "@$parameterPath") | Out-Null
    }
    $hostId = "$groupId/providers/Microsoft.Compute/virtualMachines/$HostName"
    $deadline = (Get-Date).AddHours(4)
    $lastGuestProgress = ''
    do {
        $run = Invoke-LabRest -Method GET -Id "$hostId/runCommands/$runName" -ApiVersion '2024-07-01' -ExpandInstanceView
        $provisioningState = $run.properties.PSObject.Properties['provisioningState']
        if ($provisioningState -and $provisioningState.Value -in @('Failed', 'Canceled')) {
            throw "Guest Run Command provisioning failed: $($provisioningState.Value). Inspect $runName on $HostName."
        }
        $viewProperty = $run.properties.PSObject.Properties['instanceView']
        if ($viewProperty -and $viewProperty.Value) {
            $view = $viewProperty.Value
            $outputProperty = $view.PSObject.Properties['output']
            if ($outputProperty -and $outputProperty.Value) {
                $markers = [regex]::Matches($outputProperty.Value, '(?m)^ARC_SQL_PROGRESS\|([^\r\n]+)')
                if ($markers.Count) {
                    $latestProgress = $markers[$markers.Count - 1].Groups[1].Value
                    if ($latestProgress -ne $lastGuestProgress) {
                        Write-LabProgress "Host: $latestProgress"
                        $lastGuestProgress = $latestProgress
                    }
                }
            }
            if ($view.executionState -in @('Failed', 'Canceled', 'TimedOut')) {
                throw "Guest bootstrap failed: $($view.error)`n$($view.output)"
            }
            if ($view.executionState -eq 'Succeeded') {
                if ($view.exitCode -ne 0 -or $view.output -notmatch "ARC_SQL_GUESTS_READY:$MachineCount") {
                    throw "Guest bootstrap did not confirm success: $($view.error)`n$($view.output)"
                }
                break
            }
        }
        if ((Get-Date) -ge $deadline) { throw "Guest bootstrap timed out. Inspect managed Run Command $runName on $HostName; do not start a second concurrent run." }
        $arcMachines = Invoke-LabRest -Method GET -Id "$groupId/providers/Microsoft.HybridCompute/machines" -ApiVersion '2024-07-10'
        $connectedCount = @($arcMachines.value | Where-Object {
            $_.name -in $machineNames -and (Get-LabArcStatus $_) -eq 'Connected'
        }).Count
        $unreportedCount = @($arcMachines.value | Where-Object {
            $_.name -in $machineNames -and (Get-LabArcStatus $_) -eq 'NotReported'
        }).Count
        if ($unreportedCount) { Write-LabProgress "Arc status not yet reported for $unreportedCount server(s); not counted as connected." }
        Write-LabProgress "Guest setup still running; Arc connected: $connectedCount/$MachineCount. Checking again in 30 seconds."
        Start-Sleep -Seconds 30
    } while ($true)
    Write-LabProgress "Guest bootstrap completed for all $MachineCount servers."

    Write-LabProgress -Step 6 'Configuring and verifying Arc connectivity, SQL/AMA extensions, and monitoring associations.'
    $machineIndex = 0
    foreach ($name in $machineNames) {
        $machineIndex++
        Write-LabProgress "Server $machineIndex/${MachineCount}: $name - verifying Arc connectivity."
        $machineId = "$groupId/providers/Microsoft.HybridCompute/machines/$name"
        $connectionDeadline = (Get-Date).AddMinutes(5)
        do {
            $machine = Invoke-LabRest -Method GET -Id $machineId -ApiVersion '2024-07-10'
            $connectionStatus = Get-LabArcStatus $machine
            if ($connectionStatus -eq 'Connected') { break }
            if ((Get-Date) -ge $connectionDeadline) { throw "$name is registered but is not Connected." }
            Write-LabProgress "$name is $connectionStatus; waiting for Connected."
            Start-Sleep -Seconds 20
        } while ($true)
        foreach ($extension in @(
            @{ name = 'AzureMonitorWindowsAgent'; publisher = 'Microsoft.Azure.Monitor'; type = 'AzureMonitorWindowsAgent'; settings = @{} },
            @{ name = 'WindowsAgent.SqlServer'; publisher = 'Microsoft.AzureData'; type = 'WindowsAgent.SqlServer';
                settings = @{ LicenseType = 'LicenseOnly'; SqlManagement = @{ IsEnabled = $true }; ExcludedSqlInstances = @() } }
        )) {
            $extensionId = "$machineId/extensions/$($extension.name)"
            Write-LabProgress "$name - reconciling extension $($extension.name)."
            Invoke-LabRest -Method PUT -Id $extensionId -ApiVersion '2024-07-10' -Body @{
                location = $Location
                properties = @{
                    publisher = $extension.publisher; type = $extension.type; settings = $extension.settings
                    enableAutomaticUpgrade = $true; autoUpgradeMinorVersion = $true
                }
            } | Out-Null
            Wait-ArmProvisioning -Id $extensionId -ApiVersion '2024-07-10'
        }
        foreach ($association in @(
            @{ name = 'sql-bpa-assessment'; properties = @{ dataCollectionRuleId = $assessmentDcr.id } },
            @{ name = 'sql-performance'; properties = @{ dataCollectionRuleId = $performanceDcr.id } },
            @{ name = 'configurationAccessEndpoint'; properties = @{ dataCollectionEndpointId = $dce.id } }
        )) {
            $associationId = "$machineId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$($association.name)"
            Write-LabProgress "$name - reconciling monitoring association $($association.name)."
            $saved = Invoke-LabRest -Method PUT -Id $associationId -ApiVersion '2023-03-11' -Body @{ properties = $association.properties }
            foreach ($key in $association.properties.Keys) {
                if ($saved.properties.$key -ne $association.properties[$key]) { throw "Association verification failed for $name/$($association.name)." }
            }
            Write-LabProgress "Server $machineIndex/$MachineCount verified: $name."
        }
        Write-LabProgress -Step 7 'Waiting for discovered SQL Server inventory.'
    }
    $deadline = (Get-Date).AddMinutes(30)
    do {
        $instances = @(Invoke-LabAz @('resource', 'list', '--resource-group', $ResourceGroupName, '--resource-type', 'Microsoft.AzureArcData/sqlServerInstances'))
        $discoveredMachines = @(
            foreach ($instance in $instances) {
                $details = Invoke-LabAz @('resource', 'show', '--ids', $instance.id)
                $details.properties.containerResourceId
            }
        )
        $missing = @($machineNames | Where-Object {
            $discoveredMachines -notcontains "$groupId/providers/Microsoft.HybridCompute/machines/$_"
        })
        Write-LabProgress "SQL inventory discovered for $($MachineCount - $missing.Count)/$MachineCount servers."
        if ($missing.Count -eq 0) { break }
        if ((Get-Date) -ge $deadline) { throw "SQL inventory was not discovered for: $($missing -join ', '). Check the SQL extension and guest SQL service." }
        Start-Sleep -Seconds 30
    } while ($true)
    Write-LabProgress -Step 8 "Complete: verified $MachineCount connected Arc machines, healthy SQL/AMA extensions, SQL inventory, and existing DCR/DCE associations."
    Write-Host "Workspace: $($workspace.id)"
    Write-Host 'BPA is not enabled by this bootstrap. See the guide for licensing prerequisites; a DCR association alone does not run an assessment.'
} finally {
    Get-ChildItem -LiteralPath $script:tempDirectory -File | Remove-Item -Force
    Remove-Item -LiteralPath $script:tempDirectory
}
