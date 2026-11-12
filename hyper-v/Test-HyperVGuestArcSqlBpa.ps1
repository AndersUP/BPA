#requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$path = Join-Path $PSScriptRoot 'Enable-HyperVGuestArcSqlBpa.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Syntax errors: $errors" }

# Exercise the real orchestration, omitting only the Windows elevation API.
$statements = @($ast.EndBlock.Statements | Where-Object {
    $_.Extent.Text -notmatch '^\$principal =' -and $_.Extent.Text -notmatch '^if \(-not \$principal\.'
})
$script = [scriptblock]::Create($ast.ParamBlock.Extent.Text + "`n" + (($statements | ForEach-Object { $_.Extent.Text }) -join "`n"))
$subscription = '11111111-1111-1111-1111-111111111111'
$groupPath = "/subscriptions/$subscription/resourceGroups/lab"
$workspace = "$groupPath/providers/Microsoft.OperationalInsights/workspaces/law"
$parameters = @{
    VMName=@('arcsql-06', 'arcsql-07'); TenantId='22222222-2222-2222-2222-222222222222'
    SubscriptionId=$subscription; ResourceGroupName='lab'; Location='swedencentral'
    ServicePrincipalClientId='33333333-3333-3333-3333-333333333333'
    WorkspaceResourceId=$workspace; LicenseType='Paid'
    GuestCredential=[PSCredential]::new('Administrator', (ConvertTo-SecureString 'Test-only-password!' -AsPlainText -Force))
    ServicePrincipalSecret=(ConvertTo-SecureString 'Test-only-secret!' -AsPlainText -Force)
}
$state = @{
    Machines=@{}; Extensions=@{}; Preflights=0; Onboards=0; Removed=0; Deployments=0
    FailPreflight=$false; FailDeployment=$false; FailAuthorization=$false
}
& {
    function Import-Module {}
    function Get-Module { [pscustomobject]@{ Name='Available' } }
    function Get-VM { [pscustomobject]@{ State='Running' } }
    function Get-VMNetworkAdapter { [pscustomobject]@{ SwitchName='ArcSqlLabNAT' } }
    function Disable-AzContextAutosave {}
    function Connect-AzAccount {}
    function New-PSSession { param($VMName) [pscustomobject]@{ VMName=$VMName } }
    function Remove-PSSession { $state.Removed++ }
    function Start-Sleep { throw 'Unexpected polling: a readiness check did not match the mocked response.' }
    function Invoke-Command {
        param($Session, $ScriptBlock, $ArgumentList)
        if ($ScriptBlock.ToString() -match 'param\(\$ExpectedId, \$ExpectedTenant, \$CloudResourceExists\)') {
            $state.Preflights++
            if ($state.FailPreflight -and $Session.VMName -eq 'arcsql-07') { throw 'Simulated guest registration conflict' }
        } elseif ($ScriptBlock.ToString() -match '\$agent connect') {
            if ($state.Preflights -lt 2) { throw 'All guests must pass preflight before onboarding.' }
            if ($ArgumentList[-1] -isnot [Security.SecureString]) { throw 'Guest must receive a SecureString, not a plaintext secret.' }
            $state.Onboards++
            $state.Machines[$ArgumentList[0]] = @{ properties=@{status='Connected'}; location='swedencentral' }
        } else { throw 'Unexpected guest invocation.' }
    }
    function Invoke-AzRestMethod {
        param($Path, $Method, $Payload)
        $status = 200
        $body = $null
        $request = if ($Payload) { $Payload | ConvertFrom-Json } else { $null }
        $id = ($Path -split '\?')[0]
        if ($state.FailAuthorization) {
            return [pscustomobject]@{ StatusCode=403; Content='Simulated RBAC failure' }
        }
        if ($id -match '/policyDefinitions/') {
            $templateParameters = @{}
            foreach ($key in @('extensionName', 'laWorkspaceId', 'laWorkspaceLocation', 'vmLocation', 'agentName', 'existingSettings', 'isEnabled')) {
                $templateParameters[$key] = @{ type='string' }
            }
            $body = @{properties=@{policyRule=@{then=@{details=@{deployment=@{properties=@{template=@{parameters=$templateParameters}}}}}}}}
        } elseif ($id -eq $groupPath) {
            $body = @{id=$id}
        } elseif ($id -eq $workspace) {
            $body = @{location='swedencentral'}
        } elseif ($id -match '/providers/Microsoft\.[^/]+$') {
            $body = @{registrationState='Registered'}
        } elseif ($id -match '/sqlServerInstances$') {
            if ($Path -notmatch '\?api-version=2024-01-01$') {
                throw "SQL discovery must use the supported stable 2024-01-01 API: $Path"
            }
            $body = @{ value=@(
                @{name='unrelated'; properties=@{containerResourceId='wrong-machine'}}
                foreach ($machineId in $state.Machines.Keys) {
                    @{ name=($machineId.Split('/')[-1] + '_MSSQLSERVER'); properties=@{containerResourceId=$machineId} }
                }
            ) }
        } elseif ($id -match '/deployments/') {
            if ($Method -eq 'PUT') {
                $state.Deployments++
                if ($request.properties.mode -ne 'Incremental') { throw 'BPA must not use a destructive deployment mode.' }
                $p = $request.properties.parameters
                $machineId = "$groupPath/providers/Microsoft.HybridCompute/machines/" + ($p.extensionName.value.Split('/')[0])
                $extensionId = "$machineId/extensions/WindowsAgent.SqlServer"
                if ($p.existingSettings.value.CustomSetting -ne 'preserve-me') { throw 'Existing extension settings were lost.' }
                $state.Extensions[$extensionId].properties.settings.AssessmentSettings = @{
                    Enable=$p.isEnabled.value; WorkspaceResourceId=$p.laWorkspaceId.value
                }
            }
            $provisioning = if ($state.FailDeployment) { 'Failed' } else { 'Succeeded' }
            $body = @{properties=@{provisioningState=$provisioning}}
        } elseif ($id -match '/extensions/AzureMonitorWindowsAgent$') {
            $body = @{properties=@{provisioningState='Succeeded'}}
        } elseif ($id -match '/extensions/WindowsAgent.SqlServer$') {
            if ($Method -in @('PUT', 'PATCH')) {
                if ($Method -eq 'PATCH' -and $request.properties.settings.CustomSetting -ne 'preserve-me') {
                    throw 'PATCH must preserve existing extension settings.'
                }
                $settings = @{}
                foreach ($p in $request.properties.settings.PSObject.Properties) { $settings[$p.Name]=$p.Value }
                $settings.CustomSetting = 'preserve-me'
                $state.Extensions[$id] = @{properties=@{provisioningState='Succeeded'; settings=$settings}}
            }
            if ($state.Extensions.ContainsKey($id)) { $body=$state.Extensions[$id] } else { $status=404 }
        } elseif ($id -match '/machines/[^/]+$') {
            if ($state.Machines.ContainsKey($id)) { $body=$state.Machines[$id] } else { $status=404 }
        } else { throw "Unexpected ARM request: $Method $Path" }
        [pscustomobject]@{StatusCode=$status; Content=($body | ConvertTo-Json -Depth 50)}
    }
    $results = @(& $script @parameters)
    if ($results.Count -ne 2 -or @($results | Where-Object { -not $_.BPAEnabled }).Count) {
        throw 'Expected two verified success results.'
    }
    foreach ($result in $results) {
        if ($result.SqlInstances -ne "$($result.VMName)_MSSQLSERVER") { throw 'Discovery matched an unrelated SQL instance.' }
    }
    if ($state.Removed -ne 2 -or $state.Deployments -ne 2) { throw 'Missing deployment or session cleanup.' }
    $state.Preflights=0
    $results = @(& $script @parameters)
    if ($results.Count -ne 2 -or $state.Removed -ne 4) { throw 'Rerun failed.' }
    $state.FailPreflight=$true; $state.Preflights=0
    $previousOnboards=$state.Onboards
    $failure=$null
    try { & $script @parameters | Out-Null } catch { $failure=$_ }
    if (-not $failure -or $state.Onboards -ne $previousOnboards -or $state.Removed -ne 6) {
        throw 'Preflight must stop all mutations and clean up both sessions.'
    }
    $state.FailPreflight=$false; $state.FailDeployment=$true; $state.Preflights=0
    $failure=$null
    try { & $script @parameters | Out-Null } catch { $failure=$_ }
    if (-not $failure -or "$failure" -notlike '*BPA deployment failed*' -or $state.Removed -ne 8) {
        throw 'Failed assessment deployment must stop with an error and clean up.'
    }
    $state.FailDeployment=$false; $state.FailAuthorization=$true
    $failure=$null
    try { & $script @parameters | Out-Null } catch { $failure=$_ }
    if (-not $failure -or "$failure" -notlike '*HTTP 403*') { throw 'ARM authorization failures must not be hidden as polling.' }
}
& {
    $guestAssignment = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$guestOnboard'
    }, $true)
    . ([scriptblock]::Create($guestAssignment.Extent.Text))
    $machineId = "$groupPath/providers/Microsoft.HybridCompute/machines/arcsql-06"
    $guestState = @{
        Id=$null; Installed=$false; Connected=0; Started=0; Removed=0; ExitCode=0; MsiExit=0
    }
    function Join-Path {
        param($Path, $ChildPath)
        if ($ChildPath -like '*azcmagent.exe') { return 'Test-ArcAgent' }
        return 'Test-Installer.msi'
    }
    function Test-Path { param($LiteralPath) return $LiteralPath -ne 'Test-ArcAgent' -or $guestState.Installed }
    function Get-NetFirewallRule {}
    function New-NetFirewallRule {}
    function Set-NetFirewallRule {}
    function Start-Service { $guestState.Started++ }
    function Invoke-WebRequest {}
    function Get-AuthenticodeSignature {
        [pscustomobject]@{ Status='Valid'; SignerCertificate=[pscustomobject]@{ Subject='CN=Microsoft Corporation, O=Microsoft Corporation, C=US' } }
    }
    function Start-Process {
        $guestState.Installed=$true
        [pscustomobject]@{ ExitCode=$guestState.MsiExit }
    }
    function Remove-Item { $guestState.Removed++ }
    function Test-ArcAgent {
        if ($args[0] -eq 'show') {
            $global:LASTEXITCODE=0
            return (@{resourceId=$guestState.Id; tenantId=$parameters.TenantId; status='Connected'} | ConvertTo-Json)
        }
        if ($args[0] -ne 'connect') { throw 'Unexpected agent command.' }
        if ($args[-1] -ne 'Test-only-secret!') { throw 'Guest did not receive the correct secret.' }
        $guestState.Connected++
        $global:LASTEXITCODE=$guestState.ExitCode
        if ($guestState.ExitCode -eq 0) { $guestState.Id=$machineId }
        return 'Test-only-secret!'
    }
    $arguments = @(
        $machineId, $parameters.TenantId, $subscription, 'lab', 'swedencentral', 'arcsql-06',
        $parameters.ServicePrincipalClientId, $parameters.ServicePrincipalSecret
    )
    $result = @(& $guestOnboard @arguments)
    if ($result.Count -or $guestState.Connected -ne 1 -or $guestState.Removed -ne 1) {
        throw 'Fresh agent onboarding must succeed without exposing native output and must clean up the installer.'
    }
    & $guestOnboard @arguments
    if ($guestState.Connected -ne 1 -or $guestState.Started -ne 1) { throw 'Rerun reconnected an already registered agent.' }
    $guestState.Id='another-machine'
    $failure=$null
    try { & $guestOnboard @arguments } catch { $failure=$_ }
    if (-not $failure -or "$failure" -notlike '*identity changed*') { throw 'Guest identity mismatch was not rejected.' }
    $guestState.Id=$null; $guestState.ExitCode=23
    $failure=$null
    try { & $guestOnboard @arguments } catch { $failure=$_ }
    if (-not $failure -or "$failure" -like '*Test-only-secret!*' -or "$failure" -notlike '*exit 23*') {
        throw 'Native failure must propagate without exposing the secret.'
    }
    $guestState.Installed=$false; $guestState.MsiExit=3010
    $failure=$null
    try { & $guestOnboard @arguments } catch { $failure=$_ }
    if (-not $failure -or "$failure" -notlike '*guest restart*' -or $guestState.Removed -ne 2) {
        throw 'MSI restart requirement must propagate and clean up.'
    }
    $preflightAssignment = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$guestPreflight'
    }, $true)
    . ([scriptblock]::Create($preflightAssignment.Extent.Text))
    $agentChecks = @($guestPreflight.Ast.EndBlock.Statements | Select-Object -Last 3)
    if ($agentChecks[0].Extent.Text -notmatch '^\$agent =') { throw 'Agent registration preflight structure changed.' }
    $agentPreflight = [scriptblock]::Create(
        'param($ExpectedId, $ExpectedTenant, $CloudResourceExists)' + "`n" +
        (($agentChecks | ForEach-Object { $_.Extent.Text }) -join "`n")
    )
    $guestState.Id=$machineId
    & $agentPreflight $machineId $parameters.TenantId $true
    foreach ($scenario in @('wrong-resource', 'stale-registration', 'cloud-collision')) {
        $guestState.Id = if ($scenario -eq 'wrong-resource') { 'another-machine' }
            elseif ($scenario -eq 'stale-registration') { $machineId } else { $null }
        $failure=$null
        try { & $agentPreflight $machineId $parameters.TenantId ($scenario -ne 'stale-registration') } catch { $failure=$_ }
        if (-not $failure) { throw "Guest registration preflight did not reject $scenario." }
    }
}
Write-Output 'PASS: syntax; two-guest orchestration; secure secret forwarding; exact SQL discovery; rerun; settings preservation; preflight/deployment/RBAC errors; cleanup; guest install/connect/identity/restart paths.'
