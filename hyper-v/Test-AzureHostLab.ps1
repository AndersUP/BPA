#requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$path = Join-Path $PSScriptRoot 'Create-HyperVLab.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Syntax errors: $errors" }
$startup = @($ast.EndBlock.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.IfStatementAst] -and
    $_.Clauses[0].Item1.Extent.Text -eq '$AzureHost' -and
    $_.Extent.Text -match 'Assert-AzureHostLabPlan'
})
if ($startup.Count -ne 1) { throw 'Expected one top-level AzureHost startup block.' }
& {
    $AzureHost = $true
    $SwitchName = $null
    $VmPath = $null
    $VmConfigs = @(@{ Name='arcsql-06' })
    function Import-Module {}
    function Join-Path { param($Path, $ChildPath) return $ChildPath }
    function Test-Path { return $true }
    function Get-VMNetworkAdapter { throw 'Guest adapters must not be accessed during startup.' }
    function Assert-AzureHostLabPlan {
        param($Configs, $Path, $Switch)
        if ($Configs[0].Name -ne 'arcsql-06' -or $Path -ne 'F:\AdditionalSqlLab' -or $Switch -ne 'ArcSqlLabNAT') {
            throw 'AzureHost startup did not initialize preflight arguments.'
        }
    }
    $startupScript = [scriptblock]::Create("param([string]`$AdminPassword)`n" + $startup[0].Extent.Text)
    & $startupScript -AdminPassword 'Test-Only-Password123!'
}
$config = @{}
$optionalAssignments = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -in @('$memoryGB', '$vCpus', '$diskSizeGB', '$windowsProductKey', '$sqlProductKey')
}, $true)
foreach ($assignment in $optionalAssignments) { . ([scriptblock]::Create($assignment.Extent.Text)) }
if ($memoryGB -ne 4 -or $vCpus -ne 2 -or $diskSizeGB -ne 60 -or
    $null -ne $windowsProductKey -or $null -ne $sqlProductKey) {
    throw 'Optional configuration defaults failed under StrictMode.'
}
$node = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-AzureHostLabPlan'
}, $true)
. ([scriptblock]::Create($node.Extent.Text))
$identityNode = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-LabVMIdentity'
}, $true)
. ([scriptblock]::Create($identityNode.Extent.Text))
$state = @{ FreeMemoryGB=20; FreeDiskGB=300; ExistingDirectory=$false; Ping=$false; SDrive=$false }
function Join-Path { param($Path, $ChildPath) [IO.Path]::Combine($Path, $ChildPath) }
function Get-VMSwitch { [pscustomobject]@{ SwitchType='Internal' } }
function Get-NetNat { [pscustomobject]@{ InternalIPInterfaceAddressPrefix='10.241.0.0/24' } }
function Get-NetAdapter { [pscustomobject]@{ ifIndex=13 } }
function Get-NetIPAddress { [pscustomobject]@{ InterfaceIndex=13; AddressFamily='IPv4'; IPAddress='10.241.0.1'; PrefixLength=24 } }
function Get-VM {
    param($Name)
    if (-not $Name -or $Name -eq 'arcsql-01') {
        [pscustomobject]@{ Name='arcsql-01'; Generation=2; DynamicMemoryEnabled=$false; MemoryStartup=40GB }
    }
    if ($state.ContainsKey('Resume') -and $state.Resume -and (-not $Name -or $Name -eq 'arcstd-01')) {
        [pscustomobject]@{ Name='arcstd-01'; Generation=2; DynamicMemoryEnabled=$false; MemoryStartup=4GB }
    }
}
function Get-VMHardDiskDrive {
    param($VMName)
    $diskPath = if ($VMName -eq 'arcstd-01') { 'F:\AdditionalSqlLab\arcstd-01\arcstd-01.vhdx' }
        else { 'F:\ArcSqlLab\arcsql-01\arcsql-01.vhdx' }
    [pscustomobject]@{ Path=$diskPath }
}
function Get-VMNetworkAdapter { [pscustomobject]@{ IPAddresses=@('10.241.0.101') } }
function Get-PSDrive {
    param($Name)
    if ($Name -eq 'S') {
        if ($state.SDrive) { [pscustomobject]@{ Name='S' } }
    } else { [pscustomobject]@{ Free=([int64]$state.FreeDiskGB * 1GB) } }
}
function Get-CimInstance {
    [pscustomobject]@{ TotalVisibleMemorySize=(64GB / 1KB); FreePhysicalMemory=($state.FreeMemoryGB * 1GB / 1KB) }
}
function Test-Connection { return $state.Ping }
function Test-Path {
    param($LiteralPath, $PathType)
    if ($PathType -eq 'Leaf') { return $LiteralPath -notlike '*windows-image-ready.txt' }
    return $state.ExistingDirectory
}
function New-TestConfig {
    @{Name='arcstd-01'; IPAddress='10.241.0.111'; WindowsIso='F:\ISO\windows.iso';
        SqlIso='F:\ISO\sql.iso'; Databases='misconfigdemo'; Misconfigs='auto_shrink';
        MemoryGB=4; VCpus=2; DiskSizeGB=80}
}
Assert-AzureHostLabPlan -Configs @((New-TestConfig)) -Path 'F:\AdditionalSqlLab' -Switch ArcSqlLabNAT
foreach ($scenario in @('name', 'duplicate-ip', 'reserved-ip', 'storage', 'directory', 'ram', 'disk', 'ping', 'efi', 'switch')) {
    $config = New-TestConfig
    $configs = @($config)
    $destination = 'F:\AdditionalSqlLab'
    $networkSwitch = 'ArcSqlLabNAT'
    switch ($scenario) {
        'name' { $config.Name='arcsql-01' }
        'duplicate-ip' { $other=New-TestConfig; $other.Name='arcent-01'; $configs += $other }
        'reserved-ip' { $config.IPAddress='10.241.0.101' }
        'storage' { $destination='F:\ArcSqlLab\new' }
        'directory' { $state.ExistingDirectory=$true }
        'ram' { $state.FreeMemoryGB=6 }
        'disk' { $state.FreeDiskGB=50 }
        'ping' { $state.Ping=$true }
        'efi' { $state.SDrive=$true }
        'switch' { $networkSwitch='Default Switch' }
    }
    $failure=$null
    try { Assert-AzureHostLabPlan -Configs $configs -Path $destination -Switch $networkSwitch } catch { $failure=$_ }
    if (-not $failure) { throw "Did not reject unsafe plan: $scenario" }
    $state.FreeMemoryGB=20; $state.FreeDiskGB=300; $state.ExistingDirectory=$false
    $state.Ping=$false; $state.SDrive=$false
}
$text = $ast.Extent.Text
if ($text -match 'Write-Host\s+"[^"]*\$AdminPassword') { throw 'Password is printed.' }
if ($text.IndexOf('New-NetFirewallRule -Name ArcSqlLabBlockIMDS') -gt $text.IndexOf('Connect-VMNetworkAdapter -SwitchName')) {
    throw 'Guest must block IMDS before network attachment.'
}
$networkBlock = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
    $node.Extent.Text -match 'source=static'
}, $true)
if ($null -eq $networkBlock) { throw 'Guest network configuration block not found.' }
$networkState = @{
    ActiveStore = 'Enabled'
    PersistentStore = 'Enabled'
    Firewall = $false
    Address = $null
    Dns = $null
}
function New-NetFirewallRule { $networkState.Firewall = $true }
function Get-NetFirewallRule {
    if ($networkState.Firewall) { [pscustomobject]@{ Name='ArcSqlLabBlockIMDS'; DisplayName='Arc SQL lab: block Azure IMDS' } }
}
function Get-NetRoute { [pscustomobject]@{ DestinationPrefix='0.0.0.0/0'; NextHop='10.241.0.1' } }
function Get-NetAdapter { [pscustomobject]@{ ifIndex=13; Status='Up' } }
function Set-NetFirewallRule { $networkState.Firewall = $true }
$firewallBlock = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
    $node.Extent.Text -match 'New-NetFirewallRule -Name ArcSqlLabBlockIMDS'
}, $true)
& $firewallBlock.ScriptBlock.GetScriptBlock()
if ($text.IndexOf('Connect-VMNetworkAdapter -SwitchName') -gt $networkBlock.Extent.StartOffset) {
    throw 'Guest must be connected before static networking is applied.'
}
function Set-DnsClientServerAddress {
    param($InterfaceIndex, $ServerAddresses)
    if ($InterfaceIndex -ne 13) { throw 'Unexpected DNS interface.' }
    $networkState.Dns = $ServerAddresses
}
function Set-NetIPInterface { throw 'Do not split DHCP and address changes through NetTCPIP.' }
function New-NetIPAddress { throw 'Do not use the failing New-NetIPAddress path.' }
function netsh.exe {
    if ($networkState.ContainsKey('ExitCode') -and $networkState.ExitCode) {
        $global:LASTEXITCODE = $networkState.ExitCode
        return 'Simulated netsh failure'
    }
    if (($args -join ' ') -notmatch '^interface ipv4 set address name=13 source=static address=10\.241\.0\.111 mask=255\.255\.255\.0 gateway=10\.241\.0\.1 store=(persistent|active)$') {
        throw "Unexpected netsh arguments: $args"
    }
    if (-not $networkState.Firewall) { throw 'IMDS must be blocked before static IP configuration.' }
    $store = if ($args[-1] -eq 'store=persistent') { 'PersistentStore' } else { 'ActiveStore' }
    $networkState[$store] = 'Disabled'
    $networkState.Address = '10.241.0.111'
    $global:LASTEXITCODE = 0
}
function Get-NetIPInterface {
    param($InterfaceIndex, $AddressFamily, $PolicyStore)
    if ($PolicyStore -eq 'PersistentStore') { throw 'PersistentStore DHCP is not a valid verification source.' }
    [pscustomobject]@{ Dhcp=$networkState[$PolicyStore] }
}
function Get-NetIPAddress {
    param($InterfaceIndex, $AddressFamily, $PolicyStore)
    if ($PolicyStore) { [pscustomobject]@{ IPAddress=$networkState.Address; PrefixLength=24 } }
    else { [pscustomobject]@{ InterfaceIndex=13; AddressFamily='IPv4'; IPAddress='10.241.0.1'; PrefixLength=24 } }
}
& $networkBlock.ScriptBlock.GetScriptBlock() '10.241.0.111'
& $networkBlock.ScriptBlock.GetScriptBlock() '10.241.0.111'
if ($networkState.Address -ne '10.241.0.111' -or $networkState.Dns -ne '168.63.129.16') {
    throw 'Guest static IP or DNS configuration failed.'
}
$networkState.ExitCode = 87
$failure = $null
try { & $networkBlock.ScriptBlock.GetScriptBlock() '10.241.0.111' } catch { $failure = $_ }
if (-not $failure -or "$failure" -notlike '*Simulated netsh failure*') {
    throw 'Native network configuration failures must include diagnostics.'
}
$networkState.ExitCode = 0
function Get-NetIPInterface { [pscustomobject]@{ Dhcp='Enabled' } }
$failure = $null
try { & $networkBlock.ScriptBlock.GetScriptBlock() '10.241.0.111' } catch { $failure = $_ }
if (-not $failure -or "$failure" -notlike '*IPv4 verification failed*') {
    throw 'A successful native exit code must not hide a DHCP state mismatch.'
}
$state.Resume = $true
$state.Ping = $true
$state.ExistingDirectory = $true
Assert-AzureHostLabPlan -Configs @((New-TestConfig)) -Path 'F:\AdditionalSqlLab' -Switch ArcSqlLabNAT
Assert-LabVMIdentity -Name arcstd-01 -Path 'F:\AdditionalSqlLab'
$failure = $null
try { Assert-LabVMIdentity -Name arcstd-01 -Path 'F:\WrongPath' } catch { $failure = $_ }
if (-not $failure) { throw 'Resume accepted an unrelated VM disk.' }
$sqlBlock = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
    $node.Extent.Text -match 'param\(\$sqlKey\)'
}, $true)
$sqlState = @{ Starts=0; Installs=0 }
function Get-Service { [pscustomobject]@{ Name='MSSQLSERVER' } }
function Start-Service { param($Name) $sqlState.Starts++ }
function Start-Process { throw 'Existing SQL must not be reinstalled.' }
& $sqlBlock.ScriptBlock.GetScriptBlock() $null
& $sqlBlock.ScriptBlock.GetScriptBlock() $null
if ($sqlState.Starts -ne 2) { throw 'Resume did not ensure SQL is running.' }

$configurationBlock = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
    $node.Extent.Text -match 'param\(\$script, \$db, \$mc\)'
}, $true)
$configurationState = @{ Marker=$null; Runs=0; ExitCode=0 }
function Test-Path { param($LiteralPath) return $null -ne $configurationState.Marker }
function Get-Content { param($LiteralPath, [switch]$Raw) return $configurationState.Marker }
function Set-Content { param($LiteralPath, $Value) $configurationState.Marker = $Value }
function Out-File { param($FilePath, $Encoding) }
function powershell {
    $configurationState.Runs++
    $global:LASTEXITCODE = $configurationState.ExitCode
}
$configure = $configurationBlock.ScriptBlock.GetScriptBlock()
& $configure 'test-script' 'misconfigdemo' 'auto_shrink'
& $configure 'test-script' 'misconfigdemo' 'auto_shrink'
if ($configurationState.Runs -ne 1) { throw 'Completed database configuration was not skipped.' }
$configurationState.ExitCode = 1
$previousMarker = $configurationState.Marker
$failure = $null
try { & $configure 'updated-script' 'misconfigdemo' 'auto_shrink' } catch { $failure = $_ }
if (-not $failure -or $configurationState.Marker -ne $previousMarker) {
    throw 'Failed configuration must propagate its error and preserve the last successful checkpoint.'
}
$configurationState.ExitCode = 0
& $configure 'updated-script' 'misconfigdemo' 'auto_shrink'
if ($configurationState.Runs -ne 3 -or $configurationState.Marker -eq $previousMarker) {
    throw 'Failed configuration was not retried and checkpointed.'
}
Write-Output 'PASS: syntax; safe Azure plan; collision/capacity guards; repeatable networking; DHCP stores; validated VM resume; SQL install skipped; configuration checkpoints and failure retry.'
