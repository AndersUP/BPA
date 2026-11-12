#requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$bootstrap = Join-Path $root 'Create-ArcJumpstartLab.ps1'

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

foreach ($path in @($bootstrap, (Join-Path $PSScriptRoot 'Initialize-ArcSqlGuests.ps1'), $PSCommandPath)) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-Test ($errors.Count -eq 0) "Syntax error in ${path}: $errors"
}
$hostTemplate = Get-Content (Join-Path $PSScriptRoot 'host.json') -Raw | ConvertFrom-Json
$guestTemplate = Get-Content (Join-Path $PSScriptRoot 'guests.json') -Raw | ConvertFrom-Json
Assert-Test ($hostTemplate.parameters.adminPassword.type -eq 'securestring') 'Host password is not secure.'
foreach ($hostName in @('a', 'arcsql-host', 'arcsql-host-001')) {
    & $bootstrap -SubscriptionId '00000000-0000-0000-0000-000000000001' -HostName $hostName 6>$null
}
foreach ($hostName in @('arcsql-host-00001', 'arcsql-host-', '1arcsql', 'arcsql_host')) {
    $failure = $null
    try {
        & $bootstrap -SubscriptionId '00000000-0000-0000-0000-000000000001' -HostName $hostName 6>$null
    } catch { $failure = $_ }
    Assert-Test ($null -ne $failure -and $failure.Exception.Message -like "*HostName*") "Accepted invalid host name: $hostName"
}
Assert-Test ($guestTemplate.parameters.configuration.type -eq 'secureObject') 'Guest configuration is not secure.'
$nic = @($hostTemplate.resources | Where-Object type -eq 'Microsoft.Network/networkInterfaces')[0]
Assert-Test (-not $nic.properties.ipConfigurations[0].properties.PSObject.Properties['publicIPAddress']) 'Host NIC must not expose a public IP.'
$vm = @($hostTemplate.resources | Where-Object type -eq 'Microsoft.Compute/virtualMachines')[0]
Assert-Test (-not $vm.properties.PSObject.Properties['securityProfile']) 'This API uses the default Standard VM security profile for nested virtualization.'
Assert-Test ($vm.properties.storageProfile.dataDisks[0].diskSizeGB -eq 512) 'Unexpected lab disk size.'
Assert-Test ($guestTemplate.resources[0].properties.protectedParameters[0].name -eq 'ConfigurationJson') 'Guest secrets are not protected.'
Assert-Test ($guestTemplate.resources[0].properties.asyncExecution -eq $true) 'Guest bootstrap must run asynchronously.'
Assert-Test ($guestTemplate.resources[0].properties.timeoutInSeconds -eq 14400) 'Unexpected guest bootstrap timeout.'
Write-Output 'PASS: syntax and template safety invariants'

# Mock the executable boundary so even the full deployment path cannot reach Azure.
& {
    $script:subscription = '00000000-0000-0000-0000-000000000001'
    $script:groupId = "/subscriptions/$script:subscription/resourceGroups/arc-sql-jumpstart-rg"
    $script:workspaceId = "/subscriptions/$script:subscription/resourceGroups/monitoring/providers/Microsoft.OperationalInsights/workspaces/lab-law"
    $script:dceId = "/subscriptions/$script:subscription/resourceGroups/monitoring/providers/Microsoft.Insights/dataCollectionEndpoints/lab-dce"
    $script:assessmentId = "/subscriptions/$script:subscription/resourceGroups/monitoring/providers/Microsoft.Insights/dataCollectionRules/lab-bpa-dcr"
    $script:performanceId = "/subscriptions/$script:subscription/resourceGroups/monitoring/providers/Microsoft.Insights/dataCollectionRules/lab-sql-perfcounters-dcr"
    $script:calls = [Collections.Generic.List[object]]::new()
    $script:scenario = 'success'
    $script:count = 5
    $testState = @{
        Subscription = $script:subscription; GroupId = $script:groupId; WorkspaceId = $script:workspaceId
        DceId = $script:dceId; AssessmentId = $script:assessmentId; PerformanceId = $script:performanceId
        Calls = $script:calls; Scenario = 'success'; Count = 5; RunReads = 0; Sleeps = 0
    }

    function Start-Sleep { $testState.Sleeps++ }

    function az {
        $arguments = @($args)
        $testState.Calls.Add($arguments)
        $global:LASTEXITCODE = 0
        $command = $arguments[0..1] -join ' '
        $result = switch ($command) {
            'account show' { @{ id = $testState.Subscription; tenantId = $testState.Subscription }; break }
            'group exists' { $testState.Scenario -in @('unowned-group', 'rerun', 'active-run', 'completed-run', 'resume-failure'); break }
            'group show' {
                if ($testState.Scenario -eq 'unowned-group') {
                    @{ tags = @{ Other = 'another-deployment' } }
                } else {
                    @{ tags = @{ Purpose='ArcSqlJumpstartLab'; HostName='arcsql-host'; MachinePrefix='arcsql'; MachineCount="$($testState.Count)" } }
                }
                break
            }
            'ad sp' {
                Assert-Test ($arguments -notcontains '--subscription') 'Tenant-scoped service principal lookup must not receive --subscription.'
                @{ id = $testState.Subscription }; break
            }
            'vm list-skus' { ,@(@{ name = 'Standard_D16s_v5'; resourceType = 'virtualMachines'; restrictions = @() }); break }
            'vm list' { ,@(@{ name='arcsql-host' }); break }
            'vm start' { @{ status='Succeeded' }; break }
            'vm run-command' { @{ value = @(@{ message = 'ARC_SQL_ROLE_READY' }) }; break }
            'resource list' {
                $type = $arguments[[array]::IndexOf($arguments, '--resource-type') + 1]
                switch ($type) {
                    'Microsoft.OperationalInsights/workspaces' {
                        if ($testState.Scenario -eq 'ambiguous-workspace') {
                            ,@(@{ name='one'; id=$testState.WorkspaceId }, @{ name='two'; id=$testState.WorkspaceId })
                        } else { ,@(@{ name='lab-law'; id=$testState.WorkspaceId }) }
                    }
                    'Microsoft.Insights/dataCollectionRules' { ,@(@{ name='lab-bpa-dcr'; id=$testState.AssessmentId }, @{ name='lab-sql-perfcounters-dcr'; id=$testState.PerformanceId }) }
                    'Microsoft.Insights/dataCollectionEndpoints' { ,@(@{ name='lab-dce'; id=$testState.DceId }) }
                    'Microsoft.AzureArcData/sqlServerInstances' {
                        ,@(1..$testState.Count | ForEach-Object { @{ id="/mock/arcsql-{0:00}" -f $_ } })
                    }
                    default { throw "Unexpected resource list type: $type" }
                }
                break
            }
            'resource show' {
                $id = $arguments[[array]::IndexOf($arguments, '--ids') + 1]
                @{ properties = @{ containerResourceId = "$($testState.GroupId)/providers/Microsoft.HybridCompute/machines/$(Split-Path $id -Leaf)" } }
                break
            }
            'rest --method' {
                $method = $arguments[[array]::IndexOf($arguments, '--method') + 1]
                $url = $arguments[[array]::IndexOf($arguments, '--url') + 1]
                Assert-Test ($url -notmatch '[&?]') 'REST URL must not contain shell-sensitive query separators.'
                Assert-Test ($arguments -contains '--url-parameters') 'Missing REST query parameters.'
                $id = ([uri]$url).AbsolutePath
                if ($method -eq 'PUT') {
                    $bodyPath = $arguments[[array]::IndexOf($arguments, '--body') + 1].Substring(1)
                    Get-Content -LiteralPath $bodyPath -Raw | ConvertFrom-Json
                } elseif ($id -eq $testState.WorkspaceId) {
                    @{ id=$id; name='lab-law'; location='swedencentral' }
                } elseif ($id -in @($testState.AssessmentId, $testState.PerformanceId)) {
                    $destination = if ($testState.Scenario -eq 'wrong-workspace') { '/wrong/workspace' } else { $testState.WorkspaceId }
                    @{ id=$id; name='lab-dcr'; location='swedencentral'; properties=@{
                        dataCollectionEndpointId=$testState.DceId; destinations=@{ logAnalytics=@(@{ workspaceResourceId=$destination }) }
                        dataFlows=@(@{ outputStream='Custom-SqlAssessment_CL'; streams=@('Microsoft-Perf') })
                    } }
                } elseif ($id -eq $testState.DceId) {
                    @{ id=$id; location='swedencentral' }
                } elseif ($id -like '*/tables/SqlAssessment_CL') {
                    @{ id=$id; properties=@{ schema=@{ columns=@(@{name='TimeGenerated';type='datetime'},@{name='RawData';type='string'}) } } }
                } elseif ($id -like '*/runCommands') {
                    if ($testState.Scenario -in @('active-run', 'completed-run', 'resume-failure')) {
                        @{ value=@(@{ id="$($testState.GroupId)/providers/Microsoft.Compute/virtualMachines/arcsql-host/runCommands/arc-sql-old-run" }) }
                    } else { @{ value=@() } }
                } elseif ($id -like '*/runCommands/*') {
                    Assert-Test ($arguments -contains 'api-version=2024-07-01') 'Incorrect Run Command API version.'
                    Assert-Test ($arguments -contains '$expand=instanceView') 'Missing Run Command instance-view expansion.'
                    $testState.RunReads++
                    $state = if ($testState.Scenario -eq 'guest-failure' -or ($testState.Scenario -eq 'resume-failure' -and $testState.RunReads -gt 2)) { 'Failed' }
                        elseif (($testState.Scenario -in @('active-run', 'resume-failure') -and $testState.RunReads -le 2) -or ($testState.Scenario -eq 'progress' -and $testState.RunReads -eq 1)) { 'Running' }
                        else { 'Succeeded' }
                    $output = if ($state -eq 'Running') { 'ARC_SQL_PROGRESS|Guest 1/5 ready: arcsql-01.' } else { "ARC_SQL_GUESTS_READY:$($testState.Count)" }
                    @{ properties=@{ instanceView=@{ executionState=$state; exitCode=0; output=$output; error='Mock guest error' } } }
                } elseif ($id -like '*/Microsoft.HybridCompute/machines') {
                    @{ value=@(
                        for ($i=1; $i -lt $testState.Count; $i++) {
                            @{ name=('arcsql-{0:00}' -f $i); properties=@{ status='Connected' } }
                        }
                        @{ name=('arcsql-{0:00}' -f $testState.Count); properties=@{} }
                    ) }
                } elseif ($id -like '*/extensions/*') {
                    if ($testState.Scenario -in @('extension-not-visible', 'extension-forbidden') -and -not $testState.ExtensionReads.ContainsKey($id)) {
                        $testState.ExtensionReads[$id] = 1
                        $global:LASTEXITCODE = 1
                        if ($testState.Scenario -eq 'extension-forbidden') {
                            Write-Output 'ERROR: Forbidden({"error":{"code":"AuthorizationFailed"}})'
                        } else {
                            Write-Output 'ERROR: Not Found({"error":{"code":"HCRP404","message":"The requested resource was not found."}})'
                        }
                        return
                    }
                    $state = if ($testState.Scenario -eq 'extension-failure') { 'Failed' } else { 'Succeeded' }
                    @{ properties=@{ provisioningState=$state } }
                } elseif ($id -like '*/machines/*') {
                    @{ properties=@{ status='Connected' } }
                } else { throw "Unexpected REST GET: $id" }
                break
            }
            'provider show' {
                @{ registrationState = $(if ($testState.Scenario -eq 'rerun') { 'Registered' } else { 'NotRegistered' }) }
                break
            }
            'deployment group' {
                $parameterPath = $arguments[[array]::IndexOf($arguments, '--parameters') + 1].Substring(1)
                $parameters = Get-Content -LiteralPath $parameterPath -Raw | ConvertFrom-Json
                Assert-Test ($parameters.parameters.location.value -eq 'swedencentral') 'Deployment location mismatch.'
                @{ properties=@{ provisioningState='Succeeded' } }
                break
            }
            'provider register' { @{ registrationState='Registered' }; break }
            'group create' { @{ id=$testState.GroupId }; break }
            'role assignment' {
                if ($arguments -contains 'list') {
                    Assert-Test ($arguments -notcontains '--all') 'Scoped role assignment lookup must not receive --all.'
                    $scopeIndex = [array]::IndexOf($arguments, '--scope')
                    Assert-Test ($scopeIndex -ge 0 -and $arguments[$scopeIndex + 1] -eq $testState.GroupId) 'Role assignment lookup must target the lab resource group.'
                    if ($testState.Scenario -eq 'rerun') {
                        ,@(@{ principalId=$testState.Subscription; scope=$testState.GroupId; roleDefinitionName='Azure Connected Machine Onboarding' })
                    } else { ,@() }
                } else {
                    Assert-Test ($arguments -contains 'Azure Connected Machine Onboarding') 'Unexpected role grant.'
                    @{ id='/mock/role-assignment' }
                }
                break
            }
            default { throw "Unexpected Azure CLI command: $command" }
        }
        ConvertTo-Json -InputObject $result -Depth 30 -Compress
    }

    & $bootstrap -SubscriptionId $script:subscription 6>$null
    & $bootstrap -SubscriptionId $script:subscription -Deploy -WhatIf 6>$null
    Assert-Test ($script:calls.Count -eq 0) 'Preview/WhatIf invoked Azure.'
    Write-Output 'PASS: preview and WhatIf make no Azure calls'
    foreach ($missingCredential in @('LabCredential', 'ImageCredential', 'OnboardingCredential')) {
        $suppliedCredentials = @{}
        foreach ($credentialName in @('LabCredential', 'ImageCredential', 'OnboardingCredential')) {
            if ($credentialName -ne $missingCredential) {
                $suppliedCredentials[$credentialName] = [PSCredential]::new(
                    'test', (ConvertTo-SecureString 'Test-only-password!' -AsPlainText -Force))
            }
        }
        $failure = $null
        try {
            & $bootstrap -SubscriptionId $script:subscription -Deploy -NonInteractive -Confirm:$false @suppliedCredentials 6>$null
        } catch { $failure = $_ }
        Assert-Test ($null -ne $failure -and $failure.Exception.Message -like "*requires -$missingCredential.*") "Did not reject missing $missingCredential."
        Assert-Test ($script:calls.Count -eq 0) 'Missing noninteractive credentials invoked Azure.'
    }
    Write-Output 'PASS: noninteractive deployment rejects each missing credential before Azure calls'

    $password = ConvertTo-SecureString "$([guid]::NewGuid())!aA9" -AsPlainText -Force
    $imagePassword = ConvertTo-SecureString "$([guid]::NewGuid())!bB8" -AsPlainText -Force
    $credentials = @{
        LabCredential = [PSCredential]::new('arcadmin', $password)
        ImageCredential = [PSCredential]::new('Administrator', $imagePassword)
        OnboardingCredential = [PSCredential]::new($script:subscription, $password)
    }
    foreach ($count in @(1, 5)) {
        $script:count = $count
        $testState.Count = $count
        $script:calls.Clear()
        $consoleText = & $bootstrap -SubscriptionId $script:subscription -Deploy -NonInteractive -MachineCount $count -Confirm:$false @credentials 6>&1 | Out-String
        foreach ($step in 1..8) {
            Assert-Test ($consoleText -match "\[Step $step/8; elapsed \d{2}:\d{2}:\d{2}\]") "Missing timestamped progress phase $step."
        }
        Assert-Test ($consoleText -notmatch [regex]::Escape($credentials.LabCredential.GetNetworkCredential().Password)) 'Console leaked lab credentials.'
        foreach ($call in $script:calls) {
            if ($call[0] -eq 'ad') { continue }
            $subscriptionIndex = [array]::IndexOf($call, '--subscription')
            Assert-Test ($subscriptionIndex -ge 0 -and $call[$subscriptionIndex + 1] -eq $script:subscription) 'Non-directory Azure CLI call lost its subscription scope.'
        }
        $associations = @($script:calls | Where-Object { $_ -contains 'PUT' -and ($_ -join ' ') -match 'dataCollectionRuleAssociations/' })
        $extensions = @($script:calls | Where-Object { $_ -contains 'PUT' -and ($_ -join ' ') -match '/extensions/' })
        Assert-Test ($associations.Count -eq 3 * $count) 'Incorrect DCR/DCE association count.'
        Assert-Test ($extensions.Count -eq 2 * $count) 'Incorrect SQL/AMA extension count.'
        Assert-Test (@($script:calls | Where-Object { $_ -contains 'PUT' -and ($_ -join ' ') -match 'Microsoft.Security|/workspaces/' }).Count -eq 0) 'Modified shared workspace or Defender.'
        Write-Output "PASS: full mocked deployment and verification for $count guest(s)"
    }
    $publishedCredentials = @{
        LabCredential = $credentials.LabCredential
        OnboardingCredential = $credentials.OnboardingCredential
    }
    $consoleText = & $bootstrap -SubscriptionId $script:subscription -Deploy -NonInteractive -UsePublishedImageCredential -Confirm:$false @publishedCredentials 6>&1 | Out-String
    Assert-Test ($consoleText -like '*Step 8/8*') 'Published image option did not complete without prompting.'
    $failure = $null
    try {
        & $bootstrap -SubscriptionId $script:subscription -Deploy -UsePublishedImageCredential -Confirm:$false @credentials 6>$null
    } catch { $failure = $_ }
    Assert-Test ($null -ne $failure -and $failure.Exception.Message -like '*not both*') 'Conflicting image credentials were accepted.'
    Write-Output 'PASS: published image credentials support noninteractive deployment and reject conflicting input'
    $testState.Scenario = 'progress'; $testState.RunReads = 0; $testState.Sleeps = 0
    $consoleText = & $bootstrap -SubscriptionId $script:subscription -Deploy -Confirm:$false @credentials 6>&1 | Out-String
    Assert-Test ($consoleText -like '*Arc connected: 4/5*') 'Missing observed Arc connection count.'
    Assert-Test ($consoleText -like '*Arc status not yet reported for 1 server(s)*') 'Missing Arc status must be reported without failing or counting it as connected.'
    Assert-Test ($consoleText -like '*Host: Guest 1/5 ready: arcsql-01.*') 'Missing forwarded host progress.'
    Assert-Test ($testState.Sleeps -eq 1) 'Guest progress polling did not wait exactly once.'
    Write-Output 'PASS: long-running guest polling reports host progress and observed counts'

    $testState.Scenario = 'rerun'; $script:calls.Clear()
    $consoleText = & $bootstrap -SubscriptionId $script:subscription -Deploy -Confirm:$false @credentials 6>&1 | Out-String
    Assert-Test (@($script:calls | Where-Object { ($_ -join ' ') -match '^provider register|^role assignment create|^group create' }).Count -eq 0) 'Rerun recreated existing registration/role/group.'
    Assert-Test ($consoleText -like '*role assignment already exists; reusing*') 'Rerun did not report role reuse.'
    Write-Output 'PASS: rerun reuses the owned group, registered providers, and onboarding role'
    $testState.Scenario = 'extension-not-visible'; $testState.ExtensionReads = @{}; $testState.Sleeps = 0
    $consoleText = & $bootstrap -SubscriptionId $script:subscription -Deploy -Confirm:$false @credentials 6>&1 | Out-String
    Assert-Test ($consoleText -like '*not yet visible (HCRP404)*' -and $consoleText -like '*Step 8/8*') 'Transient extension HCRP404 did not recover.'
    Assert-Test ($testState.Sleeps -eq 10) 'Each initially missing extension should retry once.'
    $testState.Scenario = 'extension-forbidden'; $testState.ExtensionReads = @{}; $testState.Sleeps = 0
    $failure = $null
    try { & $bootstrap -SubscriptionId $script:subscription -Deploy -Confirm:$false @credentials 6>$null } catch { $failure = $_ }
    Assert-Test ($null -ne $failure -and $failure.Exception.Message -like '*AuthorizationFailed*' -and $testState.Sleeps -eq 0) 'Extension authorization error must fail without retries.'
    Write-Output 'PASS: extension HCRP404 retries; authorization failures propagate'
    foreach ($scenario in @('active-run', 'completed-run')) {
        $testState.Scenario = $scenario; $testState.RunReads = 0; $testState.Sleeps = 0; $script:calls.Clear()
        $consoleText = & $bootstrap -SubscriptionId $script:subscription -Deploy -Confirm:$false @credentials 6>&1 | Out-String
        Assert-Test ($consoleText -like '*Reusing verified guest setup*') 'Did not reuse the existing guest run.'
        Assert-Test (@($script:calls | Where-Object { ($_ -join ' ') -match 'deployment group create.*arc-sql-guests' }).Count -eq 0) 'Resume created another guest run.'
        if ($scenario -eq 'active-run') {
            Assert-Test ($testState.Sleeps -eq 1) 'Resume did not wait for the existing run.'
        }
        Write-Output "PASS: resumes $scenario without a new guest deployment"
    }
    $testState.Scenario = 'resume-failure'; $testState.RunReads = 0; $script:calls.Clear()
    $failure = $null
    try { & $bootstrap -SubscriptionId $script:subscription -Deploy -Confirm:$false @credentials 6>$null } catch { $failure = $_ }
    Assert-Test ($null -ne $failure -and $failure.Exception.Message -like '*Existing guest setup did not confirm success*') 'Did not surface resumed run failure.'
    Assert-Test (@($script:calls | Where-Object { $_ -contains 'create' -or $_ -contains 'PUT' -or $_ -contains 'register' }).Count -eq 0) 'Modified resources after resumed run failure.'
    Write-Output 'PASS: resumed failure stops before resource writes'
    foreach ($scenario in @{
        'ambiguous-workspace' = '*Expected one*'
        'wrong-workspace' = '*must target only*'
        'unowned-group' = '*not marked Purpose*'
    }.GetEnumerator()) {
        $testState.Scenario = $scenario.Key
        $script:calls.Clear()
        $failure = $null
        try { & $bootstrap -SubscriptionId $script:subscription -Deploy -Confirm:$false @credentials 6>$null } catch { $failure = $_ }
        Assert-Test ($null -ne $failure -and $failure.Exception.Message -like $scenario.Value) "Did not correctly reject $($scenario.Key): $failure"
        Assert-Test (@($script:calls | Where-Object { $_ -contains 'create' -or $_ -contains 'PUT' -or $_ -contains 'register' }).Count -eq 0) "Made changes before rejecting $scenario."
        Write-Output "PASS: rejects $($scenario.Key) before writes"
    }
    foreach ($scenario in @{ 'guest-failure' = '*Guest bootstrap failed*'; 'extension-failure' = '*Provisioning failed*' }.GetEnumerator()) {
        $testState.Scenario = $scenario.Key
        $failure = $null
        try { & $bootstrap -SubscriptionId $script:subscription -Deploy -Confirm:$false @credentials 6>$null } catch { $failure = $_ }
        Assert-Test ($null -ne $failure -and $failure.Exception.Message -like $scenario.Value) "Did not surface $($scenario.Key): $failure"
        Write-Output "PASS: surfaces $($scenario.Key) without reporting success"
    }
}
& {
    $tokens = $null; $errors = $null
    $guestAst = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'Initialize-ArcSqlGuests.ps1'), [ref]$tokens, [ref]$errors)
    foreach ($name in @('Write-GuestProgress', 'Wait-GuestSession')) {
        $node = $guestAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        . ([scriptblock]::Create($node.Extent.Text))
    }
    $password = ConvertTo-SecureString ([guid]::NewGuid().ToString()) -AsPlainText -Force
    $lab = [PSCredential]::new('lab', $password)
    $image = [PSCredential]::new('image', $password)
    $sessionState = @{ AcceptedUser='lab'; Attempts=0; StartupFailures=0; Sleeps=0; UnexpectedFailure=$false; DirectCredentialError=$false }
    function Start-Sleep { $sessionState.Sleeps++ }
    function New-PSSession {
        param($VMName, $Credential)
        $sessionState.Attempts++
        if ($sessionState.UnexpectedFailure) { throw [InvalidOperationException]::new('Mock unexpected failure') }
        if ($sessionState.StartupFailures -gt 0) {
            $sessionState.StartupFailures--
            throw [System.Management.Automation.Remoting.PSRemotingDataStructureException]::new('Mock guest startup failure')
        }
        if ($Credential.UserName -ne $sessionState.AcceptedUser) {
            if ($sessionState.DirectCredentialError) {
                throw [System.Management.Automation.Remoting.PSDirectException]::new('The credential is invalid.')
            }
            throw [System.Management.Automation.Remoting.PSRemotingTransportException]::new('Mock credential rejected')
        }
        [pscustomobject]@{ Name=$VMName }
    }
    $session = Wait-GuestSession -Name test -Credentials @($lab, $image)
    Assert-Test ($session.CredentialIndex -eq 0 -and $sessionState.Attempts -eq 1) 'Existing lab credential was not preferred.'
    $sessionState.AcceptedUser='image'; $sessionState.Attempts=0
    $session = Wait-GuestSession -Name test -Credentials @($lab, $image)
    Assert-Test ($session.CredentialIndex -eq 1 -and $sessionState.Attempts -eq 2) 'Initial-image credential fallback did not work.'
    $sessionState.DirectCredentialError=$true; $sessionState.Attempts=0
    $session = Wait-GuestSession -Name test -Credentials @($lab, $image)
    Assert-Test ($session.CredentialIndex -eq 1 -and $sessionState.Attempts -eq 2) 'PowerShell Direct credential rejection prevented image credential fallback.'
    Write-Output 'PASS: PSDirectException credential rejection falls back to image credentials'
    $sessionState.AcceptedUser='lab'; $sessionState.Attempts=0; $sessionState.StartupFailures=2
    $session = Wait-GuestSession -Name test -Credentials @($lab, $image)
    Assert-Test ($session.CredentialIndex -eq 0 -and $sessionState.Attempts -eq 3 -and $sessionState.Sleeps -eq 1) 'Guest startup remoting errors did not retry after waiting.'
    $sessionState.UnexpectedFailure=$true; $sessionState.Attempts=0
    $failure = $null
    try { Wait-GuestSession -Name test -Credentials @($lab, $image) } catch { $failure = $_ }
    Assert-Test ($null -ne $failure -and $failure.Exception.Message -eq 'Mock unexpected failure' -and $sessionState.Attempts -eq 1) 'Unexpected session errors must fail immediately.'
    Write-Output 'PASS: startup remoting errors retry with a wait; unexpected errors propagate'

    $networkNode = $guestAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text -like '*Get-NetIPAddress*' -and
        $node.Extent.Text -like '*$adapter.ifIndex*'
    }, $true)
    Assert-Test ($null -ne $networkNode) 'Host NAT address setup not found.'
    $networkBlock = [scriptblock]::Create($networkNode.Extent.Text)
    $adapter = [pscustomobject]@{ ifIndex=13 }
    $networkState = @{ HasAddress=$false; Creates=0 }
    function Get-NetIPAddress {
        param($InterfaceIndex, $AddressFamily, $ErrorAction)
        Assert-Test (-not $PSBoundParameters.ContainsKey('InterfaceIndex') -and -not $PSBoundParameters.ContainsKey('AddressFamily')) 'Address enumeration must allow an adapter with no IPv4 address.'
        [pscustomobject]@{ InterfaceIndex=13; AddressFamily='IPv6'; IPAddress='fe80::1' }
        [pscustomobject]@{ InterfaceIndex=99; AddressFamily='IPv4'; IPAddress='10.241.0.1' }
        if ($networkState.HasAddress) {
            [pscustomobject]@{ InterfaceIndex=13; AddressFamily='IPv4'; IPAddress='10.241.0.1' }
        }
    }
    function New-NetIPAddress { $networkState.Creates++ }
    & $networkBlock
    Assert-Test ($networkState.Creates -eq 1) 'Missing host IPv4 address was not created.'
    $networkState.HasAddress = $true
    & $networkBlock
    Assert-Test ($networkState.Creates -eq 1) 'Existing host IPv4 address was recreated.'
    Write-Output 'PASS: host NAT creates a missing IPv4 address and preserves an existing one'

    $identityNode = $guestAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
        $node.ScriptBlock.ParamBlock -and $node.ScriptBlock.ParamBlock.Parameters.Count -eq 3 -and
        $node.ScriptBlock.ParamBlock.Parameters[2].Name.VariablePath.UserPath -eq 'rotatePassword'
    }, $true)
    Assert-Test ($null -ne $identityNode) 'Guest identity setup block not found.'
    $identityBlock = $identityNode.ScriptBlock.GetScriptBlock()
    $identityState = @{ PasswordChanges=0; Renames=0 }
    function Get-LocalUser { [pscustomobject]@{ SID=[pscustomobject]@{ Value='S-1-5-21-500' }; Name='Administrator' } }
    function Set-LocalUser { $identityState.PasswordChanges++ }
    function Set-TimeZone { }
    function Rename-Computer { $identityState.Renames++ }

    $needsRestart = & $identityBlock $password $env:COMPUTERNAME $false
    Assert-Test (-not $needsRestart -and $identityState.PasswordChanges -eq 0 -and $identityState.Renames -eq 0) 'Rerun changed an existing password or hostname.'
    $needsRestart = & $identityBlock $password 'mock-new-guest' $true
    Assert-Test ($needsRestart -and $identityState.PasswordChanges -eq 1 -and $identityState.Renames -eq 1) 'New guest did not rotate its initial password and request a rename restart.'
    Write-Output 'PASS: guest credential fallback, initial password rotation, and no password reset/rename on rerun'
}
Write-Output 'All local Arc Jumpstart checks passed. No Azure resources were deployed.'
