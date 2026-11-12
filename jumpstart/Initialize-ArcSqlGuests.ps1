param(
    [Parameter(Mandatory)]
    [string]$ConfigurationJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$config = $ConfigurationJson | ConvertFrom-Json
$ConfigurationJson = $null
Import-Module Hyper-V -ErrorAction Stop

function Write-GuestProgress {
    param([string]$Message)
    Write-Host "ARC_SQL_PROGRESS|$Message"
}

function Wait-GuestSession {
    param([string]$Name, [PSCredential[]]$Credentials)
    $deadline = (Get-Date).AddMinutes(25)
    $lastError = ''
    do {
        for ($credentialIndex = 0; $credentialIndex -lt $Credentials.Count; $credentialIndex++) {
            try {
                $session = New-PSSession -VMName $Name -Credential $Credentials[$credentialIndex] -ErrorAction Stop
                Add-Member -InputObject $session -NotePropertyName CredentialIndex -NotePropertyValue $credentialIndex -Force
                return $session
            } catch [System.Management.Automation.Remoting.PSRemotingTransportException],
                    [System.Management.Automation.Remoting.PSRemotingDataStructureException],
                    [System.Management.Automation.Remoting.PSDirectException] {
                $lastError = $_.Exception.Message
                Write-GuestProgress "PowerShell Direct on $Name is not ready (credential option $($credentialIndex + 1), $($_.Exception.GetType().Name)); retrying until the session deadline."
            }
        }
        Write-GuestProgress "Waiting for PowerShell Direct on $Name."
        Start-Sleep -Seconds 20
    } while ((Get-Date) -lt $deadline)
    throw "PowerShell Direct timed out on ${Name} after trying all supplied credentials. Verify the published image credentials and the current guest Administrator password. Last error: $lastError"
}

Write-GuestProgress 'Preparing or reusing the host data disk.'
$volume = Get-Volume -DriveLetter F -ErrorAction SilentlyContinue
if ($volume) {
    if ($volume.FileSystemLabel -ne 'ArcSqlLab') { throw 'F: is already in use by a different volume.' }
} else {
    $rawDisks = @(Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' -and -not $_.IsBoot -and -not $_.IsSystem })
    if ($rawDisks.Count -ne 1) { throw 'Expected exactly one new, empty lab data disk.' }
    $rawDisks[0] | Initialize-Disk -PartitionStyle GPT -PassThru |
        New-Partition -UseMaximumSize -DriveLetter F |
        Format-Volume -FileSystem NTFS -NewFileSystemLabel ArcSqlLab -Confirm:$false | Out-Null
}

$root = 'F:\ArcSqlLab'
New-Item -ItemType Directory -Path $root -Force | Out-Null
$baseDisk = Join-Path $root 'JSSQL19Base.vhdx'
if (-not (Test-Path -LiteralPath $baseDisk -PathType Leaf)) {
    Write-GuestProgress 'Downloading the Jumpstart SQL Server 2019 Developer image (approximately 53 GB).'
    $downloadPath = Join-Path $root 'JSSQL19Base.downloading.vhdx'
    Start-BitsTransfer -Source 'https://jumpstartprodsg.blob.core.windows.net/scenarios/prod/JSSQL19Base.vhdx' -Destination $downloadPath -ErrorAction Stop
    Get-VHD -Path $downloadPath -ErrorAction Stop | Out-Null
    Move-Item -LiteralPath $downloadPath -Destination $baseDisk
    Write-GuestProgress 'Base image download and VHD validation completed.'
} else {
    Write-GuestProgress 'Reusing the existing base image; no download needed.'
}
if ((Get-VHD -Path $baseDisk).VhdType -eq 'Differencing') { throw 'The downloaded base image must not be a differencing disk.' }
(Get-Item -LiteralPath $baseDisk).IsReadOnly = $true

$switchName = 'ArcSqlLabNAT'
Write-GuestProgress 'Preparing or reusing the nested NAT network.'
$natName = 'ArcSqlLabNAT'
$switch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
if (-not $switch) { $switch = New-VMSwitch -Name $switchName -SwitchType Internal }
if ($switch.SwitchType -ne 'Internal') { throw 'The lab switch exists but is not an internal switch.' }
$adapter = Get-NetAdapter -Name "vEthernet ($switchName)"
if (-not (Get-NetIPAddress -ErrorAction Stop | Where-Object {
    $_.InterfaceIndex -eq $adapter.ifIndex -and $_.AddressFamily -eq 'IPv4' -and $_.IPAddress -eq '10.241.0.1'
})) {
    New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress 10.241.0.1 -PrefixLength 24 | Out-Null
}
$nat = Get-NetNat -Name $natName -ErrorAction SilentlyContinue
if ($nat -and $nat.InternalIPInterfaceAddressPrefix -ne '10.241.0.0/24') { throw 'The lab NAT exists with an unexpected address range.' }
if (-not $nat) { New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix '10.241.0.0/24' | Out-Null }

$initialCredential = [PSCredential]::new(
    $config.ImageUsername, (ConvertTo-SecureString $config.ImagePassword -AsPlainText -Force))
$guestPassword = ConvertTo-SecureString $config.LabPassword -AsPlainText -Force
$guestCredential = [PSCredential]::new('Administrator', $guestPassword)

for ($index = 1; $index -le $config.MachineCount; $index++) {
    $name = '{0}-{1:00}' -f $config.MachinePrefix, $index
    Write-GuestProgress "Guest $index/$($config.MachineCount): preparing $name."
    $vmDirectory = Join-Path $root $name
    $diskPath = Join-Path $vmDirectory "$name.vhdx"
    $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-GuestProgress "$name - creating a new isolated guest and reusing/creating its differencing disk."
        New-Item -ItemType Directory -Path $vmDirectory -Force | Out-Null
        if (-not (Test-Path -LiteralPath $diskPath)) {
            New-VHD -Path $diskPath -ParentPath $baseDisk -Differencing | Out-Null
        }
        # Keep the published image isolated until its initial password has been replaced.
        $vm = New-VM -Name $name -Generation 2 -MemoryStartupBytes 8GB -VHDPath $diskPath -Path $vmDirectory
        Set-VMProcessor -VMName $name -Count 2
        Set-VM -Name $name -AutomaticStartAction Start -AutomaticStopAction ShutDown -AutomaticCheckpointsEnabled $false
    } else {
        Write-GuestProgress "$name - reusing the existing VM and validating its disk."
        $drives = @(Get-VMHardDiskDrive -VMName $name)
        if ($drives.Count -ne 1 -or $drives[0].Path -ne $diskPath) {
            throw "$name already exists but does not use this lab's expected disk."
        }
    }
    if ($vm.State -ne 'Running') {
        Write-GuestProgress "$name - starting the VM."
        Start-VM -Name $name
    }
    $session = Wait-GuestSession -Name $name -Credentials @($guestCredential, $initialCredential)
    try {
        $rotatePassword = $session.CredentialIndex -ne 0
        if ($rotatePassword) {
            Write-GuestProgress "$name - replacing the initial image password before network attachment."
        } else {
            Write-GuestProgress "$name - lab credentials already work; preserving the existing password."
        }
        $needsRestart = Invoke-Command -Session $session -ScriptBlock {
            param($password, $name, $rotatePassword)
            $ErrorActionPreference = 'Stop'
            $admin = Get-LocalUser | Where-Object { $_.SID.Value -match '-500$' }
            if ($admin.Name -ne 'Administrator') { throw 'The base image has an unexpected administrator account name.' }
            if ($rotatePassword) { $admin | Set-LocalUser -Password $password }
            Set-TimeZone -Id UTC
            if ($env:COMPUTERNAME -ne $name) {
                Rename-Computer -NewName $name -Force | Out-Null
                return $true
            }
            return $false
        } -ArgumentList $guestPassword, $name, $rotatePassword
    } finally { Remove-PSSession $session }
    if ($needsRestart) {
        Write-GuestProgress "$name - restarting after computer rename."
        Restart-VM -Name $name -Force
    }
    Write-GuestProgress "$name - configuring networking, SQL Server, and Arc onboarding."
    Get-VMNetworkAdapter -VMName $name | Connect-VMNetworkAdapter -SwitchName $switchName
    $session = Wait-GuestSession -Name $name -Credentials @($guestCredential)
    try {
        Invoke-Command -Session $session -ScriptBlock {
            param($ip, $tenant, $subscription, $resourceGroup, $location, $name, $clientId, $clientSecret)
            $ErrorActionPreference = 'Stop'
            $adapters = @(Get-NetAdapter)
            if ($adapters.Count -ne 1) { throw 'Expected one network adapter in the nested guest.' }
            $interface = $adapters[0].ifIndex
            $existing = @(Get-NetIPAddress -ErrorAction Stop | Where-Object {
                $_.InterfaceIndex -eq $interface -and $_.AddressFamily -eq 'IPv4'
            })
            if (-not ($existing | Where-Object { $_.IPAddress -eq $ip })) {
                Set-NetIPInterface -InterfaceIndex $interface -AddressFamily IPv4 -Dhcp Disabled
                $existing | Remove-NetIPAddress -Confirm:$false
                Get-NetRoute -InterfaceIndex $interface -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                    Remove-NetRoute -Confirm:$false
                New-NetIPAddress -InterfaceIndex $interface -IPAddress $ip -PrefixLength 24 -DefaultGateway 10.241.0.1 | Out-Null
            }
            Set-DnsClientServerAddress -InterfaceIndex $interface -ServerAddresses 168.63.129.16
            if (-not (Get-NetFirewallRule -Name ArcSqlLabBlockIMDS -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -Name ArcSqlLabBlockIMDS -DisplayName 'Arc SQL lab: block Azure IMDS' `
                    -Direction Outbound -Action Block -RemoteAddress 169.254.169.254 -Profile Any | Out-Null
            }
            # Only the nested guest is treated as non-Azure; keep the outer host agent running.
            $azureAgent = Get-Service -Name WindowsAzureGuestAgent -ErrorAction SilentlyContinue
            if ($azureAgent) {
                Stop-Service -Name WindowsAzureGuestAgent -Force
                Set-Service -Name WindowsAzureGuestAgent -StartupType Disabled
            }
            Set-Service -Name MSSQLSERVER -StartupType Automatic
            Start-Service -Name MSSQLSERVER
            if ((Get-Service MSSQLSERVER).Status -ne 'Running') { throw 'SQL Server is not running.' }

            $agent = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
            if (-not (Test-Path -LiteralPath $agent)) {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $msi = Join-Path $env:TEMP 'ArcSqlLabAgent.msi'
                Invoke-WebRequest -Uri 'https://aka.ms/AzureConnectedMachineAgent' -OutFile $msi -UseBasicParsing
                try {
                    $installer = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart', 'ACCEPTEULA=1') -Wait -PassThru
                    if ($installer.ExitCode -notin @(0, 3010)) { throw "Arc agent installation failed: $($installer.ExitCode)." }
                } finally { Remove-Item -LiteralPath $msi -Force }
            }
            $agentOutput = & $agent show --json
            if ($LASTEXITCODE -ne 0) { throw 'Cannot read Arc agent status.' }
            $status = $agentOutput | ConvertFrom-Json
            $expectedId = "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.HybridCompute/machines/$name"
            if ($status.resourceId) {
                if ($status.resourceId -ne $expectedId) { throw 'Guest is already registered to another Arc resource; refusing to disconnect it.' }
                Write-Host "ARC_SQL_PROGRESS|$name - reusing the existing Arc registration."
            } else {
                $connected = $false
                for ($attempt = 1; $attempt -le 10; $attempt++) {
                    $connectOutput = & $agent connect --tenant-id $tenant --subscription-id $subscription `
                        --resource-group $resourceGroup --location $location --resource-name $name `
                        --service-principal-id $clientId --service-principal-secret $clientSecret 2>&1
                    if ($LASTEXITCODE -eq 0) { $connected = $true; break }
                    Write-Output "Arc onboarding attempt $attempt failed for $name (exit $LASTEXITCODE); waiting for access propagation."
                    Start-Sleep -Seconds 30
                }
                if (-not $connected) { throw "Arc onboarding failed for $name. Check onboarding credentials, role assignment, and outbound connectivity." }
            }
            Write-Host "ARC_SQL_PROGRESS|$name - SQL Server is running and Arc onboarding is complete."
        } -ArgumentList "10.241.0.$(100 + $index)", $config.TenantId, $config.SubscriptionId, `
            $config.ResourceGroupName, $config.Location, $name, $config.ClientId, $config.ClientSecret
    } finally { Remove-PSSession $session }
    Write-GuestProgress "Guest $index/$($config.MachineCount) ready: $name."
}
Write-Output "ARC_SQL_GUESTS_READY:$($config.MachineCount)"
