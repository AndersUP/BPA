<#
.SYNOPSIS
    Creates Hyper-V VMs running SQL Server for Arc-enabled SQL BPA testing.

.DESCRIPTION
    Creates lightweight Hyper-V VMs on your local machine:
      Checks Hyper-V first and enables it if needed. If a restart is required,
      stops before creating VMs; restart the host and rerun the same command.
      1. Creates a VHDX from a Windows Server ISO (unattended install).
      2. Creates a Hyper-V VM with a small footprint.
      3. Installs SQL Server Developer edition unattended via PowerShell Direct.
      4. Restores sample databases and applies intentional misconfigurations.

    Azure-host guests can then be Arc-enabled from the host using
    Enable-HyperVGuestArcSqlBpa.ps1.

.PARAMETER VmConfigs
    Array of VM configuration hashtables. Each must contain:
      Name, WindowsIso, SqlIso, Databases, Misconfigs.
    Optional: MemoryGB (default 4), VCpus (default 2), DiskSizeGB (default 60),
      WindowsProductKey (MAK key for activation — omit for evaluation ISOs),
      SqlProductKey (SQL Server product key — omit for Developer edition).

.PARAMETER VmPath
    Base path for VM files. Default: C:\HyperVLab

.PARAMETER AdminPassword
    Local Administrator password. Default: P@ssw0rd!2026

.PARAMETER SwitchName
    Hyper-V switch name. Defaults to 'Default Switch'.

.PARAMETER AzureHost
    Add isolated ISO-based guests to an existing Arc Jumpstart Azure host.
    Reuses ArcSqlLabNAT without changing host networking. Requires explicit
    AdminPassword and an IPAddress in 10.241.0.111-120 for each new VmConfig.
    Defaults VmPath to F:\AdditionalSqlLab. Does not onboard guests to Arc.

.EXAMPLE
    $vms = @(@{
        Name = 'arcstd-01'; IPAddress = '10.241.0.111'
        WindowsIso = 'F:\ISO\WindowsServer2022.iso'
        SqlIso = 'F:\ISO\SQLServer2022.iso'
        MemoryGB = 4; VCpus = 2; DiskSizeGB = 80
        Databases = 'adventureworks,misconfigdemo'
        Misconfigs = 'maxdop_zero,auto_shrink,filegrowth_pct'
        # Supply SqlProductKey for your entitled edition when required by media.
    })
    .\Create-HyperVLab.ps1 -AzureHost -VmConfigs $vms -AdminPassword $password

.EXAMPLE
    $vms = @(
        @{
            Name       = "arc-sql-01"
            WindowsIso = "C:\ISOs\WindowsServer2022.iso"
            SqlIso     = "C:\ISOs\SQLServer2022-Dev.iso"
            Databases  = "adventureworks,misconfigdemo"
            Misconfigs = "maxmem_default,maxdop_zero,auto_shrink,no_adhoc_opt"
        },
        @{
            Name       = "arc-sql-02"
            WindowsIso = "C:\ISOs\WindowsServer2019.iso"
            SqlIso     = "C:\ISOs\SQLServer2019-Dev.iso"
            Databases  = "adventureworks,worldwideimporters"
            Misconfigs = "maxmem_default,ctp_default,page_verify_none,filegrowth_pct"
        }
    )
    .\Create-HyperVLab.ps1 -VmConfigs $vms

.NOTES
    Prerequisites:
      - x64 Windows 10/11 Pro/Enterprise or Windows Server with Hyper-V support
      - Hardware virtualization enabled in firmware
      - Run as Administrator
      - Windows Server ISO (2019 or 2022) and SQL Server Developer ISO
      - ISOs available from Visual Studio subscriptions or Evaluation Center
      - ~8GB free RAM and ~80GB free disk per VM
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable[]]$VmConfigs,

    [Parameter()]
    [string]$VmPath = "C:\HyperVLab",

    [Parameter()]
    [string]$AdminPassword = "P@ssw0rd!2026",

    [Parameter()]
    [string]$SwitchName,

    [switch]$AzureHost
)

$ErrorActionPreference = 'Stop'

#region ── Helpers ─────────────────────────────────────────────────────────────

function Write-Step { param([string]$Message); Write-Host "`n==> $Message" -ForegroundColor Cyan }

function Assert-Administrator {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator."
    }
}

function Assert-LabHostArchitecture {
    $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
    if ($processors.Count -eq 0 -or @($processors | Where-Object { $_.Architecture -ne 9 }).Count -gt 0) {
        throw "This lab requires an x64 (Intel/AMD) Hyper-V host. ARM64 Hyper-V hosts cannot run this lab's x64 Windows Server/SQL Server guests. Use an x64 host or the Azure Terraform lab."
    }
}

function Get-HyperVFeatureState {
    $output = & dism.exe /Online /Get-FeatureInfo /FeatureName:Microsoft-Hyper-V-All /English 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "DISM failed to query Hyper-V (exit code $LASTEXITCODE):`n$($output -join "`n")"
    }
    $stateMatch = [regex]::Match(($output -join "`n"), '(?m)^\s*State\s*:\s*([^\r\n]+)')
    if (-not $stateMatch.Success) {
        throw "DISM did not return a Hyper-V feature state:`n$($output -join "`n")"
    }
    return $stateMatch.Groups[1].Value.Trim()
}

function Ensure-HyperV {
    Write-Step "Checking Hyper-V"

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    if ($os.ProductType -eq 1) {
        $state = Get-HyperVFeatureState
        if ($state -in @('Enable Pending', 'Disable Pending')) {
            throw "Hyper-V has a pending feature change. Restart the host, then rerun the same lab command."
        }
        if ($state -ne 'Enabled') {
            Write-Step "Enabling Hyper-V and management tools"
            $output = & dism.exe /Online /Enable-Feature /FeatureName:Microsoft-Hyper-V-All /All /NoRestart /English 2>&1
            if ($LASTEXITCODE -eq 3010) {
                throw "Hyper-V was enabled and requires a restart. Restart the host, then rerun the same lab command. No VMs have been created."
            }
            if ($LASTEXITCODE -ne 0) {
                throw "DISM failed to enable Hyper-V (exit code $LASTEXITCODE):`n$($output -join "`n")"
            }
            $state = Get-HyperVFeatureState
            if ($state -ne 'Enabled') {
                throw "Hyper-V is not ready (feature state: $state). Check Windows feature servicing and any pending restart before rerunning."
            }
        }
    } else {
        $feature = Get-WindowsFeature -Name Hyper-V -ErrorAction Stop
        if (-not $feature.Installed) {
            Write-Step "Installing the Hyper-V role and management tools"
            $result = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -ErrorAction Stop
            if (-not $result.Success) {
                throw "Hyper-V installation failed (exit code: $($result.ExitCode)). Check the Windows Server role installation logs before rerunning."
            }
            if ($result.RestartNeeded -eq 'Yes') {
                throw "Hyper-V was installed and requires a restart. Restart the host, then rerun the same lab command. No VMs have been created."
            }
            $feature = Get-WindowsFeature -Name Hyper-V -ErrorAction Stop
            if (-not $feature.Installed) {
                throw "Hyper-V is not installed. Check the Windows Server role installation logs before rerunning."
            }
        }
    }

    Import-Module Hyper-V -ErrorAction Stop
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        throw "The Hyper-V PowerShell tools are unavailable. Install the Hyper-V management tools, then rerun the same lab command."
    }
}

function Wait-VMReady {
    param([string]$VMName, [PSCredential]$Credential, [int]$TimeoutMinutes = 25)
    Write-Host "    Waiting for $VMName to be ready (up to $TimeoutMinutes min)..." -ForegroundColor Yellow
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock { hostname } -ErrorAction Stop | Out-Null
            Write-Host "    $VMName is ready." -ForegroundColor Green
            return
        } catch [System.Management.Automation.Remoting.PSRemotingTransportException],
                [System.Management.Automation.Remoting.PSRemotingDataStructureException],
                [System.Management.Automation.Remoting.PSDirectException] {
            Write-Warning "PowerShell Direct is not ready on ${VMName}: $($_.Exception.Message)"
            Start-Sleep -Seconds 15
        }
    }
    throw "Timed out waiting for $VMName."
}

function Assert-LabVMIdentity {
    param([string]$Name, [string]$Path)
    $vm = Get-VM -Name $Name -ErrorAction Stop
    $expected = [IO.Path]::GetFullPath((Join-Path (Join-Path $Path $Name) "$Name.vhdx"))
    $disks = @(Get-VMHardDiskDrive -VMName $Name -ErrorAction Stop)
    if ($vm.Generation -ne 2 -or $disks.Count -ne 1 -or
        [IO.Path]::GetFullPath($disks[0].Path) -ne $expected) {
        throw "Refusing to resume $Name`: expected a Generation 2 VM with only disk $expected."
    }
}

function Assert-AzureHostLabPlan {
    param([hashtable[]]$Configs, [string]$Path, [string]$Switch)
    if ($Configs.Count -eq 0) { throw 'Supply at least one VM configuration.' }
    if ($Switch -ne 'ArcSqlLabNAT') { throw 'AzureHost mode requires the existing ArcSqlLabNAT switch.' }
    $network = Get-VMSwitch -Name $Switch -ErrorAction Stop
    if ($network.SwitchType -ne 'Internal') { throw 'ArcSqlLabNAT must be an internal switch.' }
    $nat = Get-NetNat -Name ArcSqlLabNAT -ErrorAction Stop
    if ($nat.InternalIPInterfaceAddressPrefix -ne '10.241.0.0/24') { throw 'Unexpected ArcSqlLabNAT subnet.' }
    $adapter = Get-NetAdapter -Name "vEthernet ($Switch)" -ErrorAction Stop
    if (-not (Get-NetIPAddress -ErrorAction Stop | Where-Object {
        $_.InterfaceIndex -eq $adapter.ifIndex -and $_.IPAddress -eq '10.241.0.1' -and $_.PrefixLength -eq 24
    })) { throw 'The existing host NAT gateway must be 10.241.0.1/24.' }
    if ($Path -notmatch '^[A-Za-z]:\\') { throw 'VmPath must be an absolute local drive path.' }
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($fullPath -eq [IO.Path]::GetPathRoot($fullPath).TrimEnd('\')) { throw 'VmPath must not be a drive root.' }
    $existingVMs = @(Get-VM)
    $protectedPaths = @('F:\ArcSqlLab')
    foreach ($vm in $existingVMs) {
        foreach ($disk in @(Get-VMHardDiskDrive -VMName $vm.Name)) {
            if ($disk.Path) { $protectedPaths += Split-Path $disk.Path -Parent }
        }
    }
    foreach ($protected in $protectedPaths) {
        $protected = [IO.Path]::GetFullPath($protected).TrimEnd('\')
        if ($fullPath -eq $protected -or $fullPath.StartsWith("$protected\", [StringComparison]::OrdinalIgnoreCase)) {
            throw "VmPath overlaps existing lab storage: $protected"
        }
    }
    if (Get-PSDrive -Name S -ErrorAction SilentlyContinue) { throw 'S: must be free for temporary EFI disk preparation.' }
    $names = @{}
    $addresses = @{}
    $newMemory = 0L
    $newDisk = 0L
    foreach ($config in $Configs) {
        foreach ($required in @('Name', 'WindowsIso', 'SqlIso', 'Databases', 'Misconfigs', 'IPAddress')) {
            if (-not $config[$required]) { throw "Each AzureHost VM requires $required." }
        }
        $name = [string]$config.Name
        if ($name -notmatch '^[a-zA-Z][a-zA-Z0-9-]{0,13}[a-zA-Z0-9]$') { throw "Use a 2-15 character Windows computer name: $name" }
        if ($names.ContainsKey($name)) { throw "Duplicated VM name: $name." }
        $existing = @($existingVMs | Where-Object { $_.Name -eq $name })
        if ($existing.Count) { Assert-LabVMIdentity -Name $name -Path $fullPath }
        $names[$name] = $true
        $candidatePath = Join-Path $fullPath $name
        foreach ($protected in $protectedPaths) {
            $protected = [IO.Path]::GetFullPath($protected).TrimEnd('\')
            if (-not $existing.Count -and ($protected -eq $candidatePath -or $protected.StartsWith("$candidatePath\", [StringComparison]::OrdinalIgnoreCase))) {
                throw "New VM directory overlaps existing lab storage: $candidatePath"
            }
        }
        $ip = [string]$config.IPAddress
        if ($ip -notmatch '^10\.241\.0\.(11[1-9]|120)$') { throw "IPAddress must be in 10.241.0.111-120: $ip" }
        $reportedAddresses = @($existingVMs | Where-Object { $_.Name -ne $name } |
            Get-VMNetworkAdapter | ForEach-Object { $_.IPAddresses })
        if ($addresses.ContainsKey($ip) -or $ip -in $reportedAddresses -or
            (-not $existing.Count -and (Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue))) {
            throw "IPAddress is duplicated, reported by an existing VM, or responds to ping: $ip"
        }
        $addresses[$ip] = $true
        if (-not $existing.Count -and (Test-Path -LiteralPath $candidatePath) -and
            -not (Test-Path -LiteralPath (Join-Path $candidatePath 'windows-image-ready.txt') -PathType Leaf)) {
            throw "Incomplete VM directory: $candidatePath. Inspect it manually; no files will be deleted."
        }
        foreach ($iso in @($config.WindowsIso, $config.SqlIso)) {
            if (-not (Test-Path -LiteralPath $iso -PathType Leaf)) { throw "ISO not found: $iso" }
        }
        foreach ($sizing in @{ MemoryGB=4; VCpus=2; DiskSizeGB=60 }.GetEnumerator()) {
            $value = if ($config.ContainsKey($sizing.Key)) { $config[$sizing.Key] } else { $sizing.Value }
            $number = 0
            if (-not [int]::TryParse([string]$value, [ref]$number) -or $number -lt 1) { throw "Invalid $($sizing.Key) for $name." }
            $config[$sizing.Key] = $number
        }
        if ($config.MemoryGB -lt 4 -or $config.DiskSizeGB -lt 60) { throw "Allow at least 4 GB RAM and a 60 GB disk for $name." }
        if (-not $existing.Count) {
            $newMemory += [int64]$config.MemoryGB * 1GB
            $newDisk += [int64]$config.DiskSizeGB * 1GB
        }
    }
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $reservedMemory = 0L
    foreach ($vm in $existingVMs) {
        $reservedMemory += if ($vm.DynamicMemoryEnabled) { $vm.MemoryMaximum } else { $vm.MemoryStartup }
    }
    if ($reservedMemory + $newMemory + 8GB -gt [int64]$os.TotalVisibleMemorySize * 1KB -or
        $newMemory + 4GB -gt [int64]$os.FreePhysicalMemory * 1KB) {
        throw 'Insufficient host RAM: preserve 8 GB beyond existing/new VM reservations and 4 GB currently available. Reduce the new guest count/sizing or resize the Azure host.'
    }
    $drive = Get-PSDrive -Name $fullPath.Substring(0, 1) -ErrorAction Stop
    if ($drive.Free -lt $newDisk + 20GB) { throw 'Insufficient disk space for full new VHDX capacities plus a 20 GB reserve.' }
    Write-Host 'AzureHost preflight passed. IP checks cannot detect powered-off/unreported devices; confirm the selected addresses are reserved for these guests.'
}

#endregion

#region ── Main ────────────────────────────────────────────────────────────────

Assert-Administrator
Assert-LabHostArchitecture
if ($AzureHost) {
    if (-not $PSBoundParameters.ContainsKey('AdminPassword') -or $AdminPassword.Length -lt 12 -or $AdminPassword -match '["\r\n]') {
        throw 'AzureHost requires an explicit unique AdminPassword of at least 12 characters, without double quotes or newlines.'
    }
    if (-not $PSBoundParameters.ContainsKey('VmPath')) { $VmPath = 'F:\AdditionalSqlLab' }
    if (-not $SwitchName) { $SwitchName = 'ArcSqlLabNAT' }
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'configure-sql-hyperv.ps1') -PathType Leaf)) {
        throw 'Copy configure-sql-hyperv.ps1 alongside this script before creating guests.'
    }
    Import-Module Hyper-V -ErrorAction Stop
    Assert-AzureHostLabPlan -Configs $VmConfigs -Path $VmPath -Switch $SwitchName
} else {
    Ensure-HyperV
}

if (-not $SwitchName) {
    $sw = Get-VMSwitch | Where-Object { $_.Name -eq 'Default Switch' } | Select-Object -First 1
    if (-not $sw) { $sw = Get-VMSwitch | Select-Object -First 1 }
    if (-not $sw) { throw "No Hyper-V switch found. Create one: New-VMSwitch -Name 'LabSwitch' -SwitchType Internal" }
    $SwitchName = $sw.Name
}
Write-Host "Using Hyper-V switch: $SwitchName" -ForegroundColor Green

$securePassword = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
$credential = [PSCredential]::new("Administrator", $securePassword)
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }

foreach ($config in $VmConfigs) {
    $vmName     = $config.Name
    $windowsIso = $config.WindowsIso
    $sqlIso     = $config.SqlIso
    $databases  = $config.Databases
    $misconfigs = $config.Misconfigs
    $memoryGB          = if ($config.ContainsKey('MemoryGB')) { $config['MemoryGB'] } else { 4 }
    $vCpus             = if ($config.ContainsKey('VCpus')) { $config['VCpus'] } else { 2 }
    $diskSizeGB        = if ($config.ContainsKey('DiskSizeGB')) { $config['DiskSizeGB'] } else { 60 }
    $windowsProductKey = if ($config.ContainsKey('WindowsProductKey')) { $config['WindowsProductKey'] } else { $null }
    $sqlProductKey     = if ($config.ContainsKey('SqlProductKey')) { $config['SqlProductKey'] } else { $null }

    Write-Step "Provisioning VM: $vmName"

    if (-not (Test-Path $windowsIso)) { throw "Windows ISO not found: $windowsIso" }
    if (-not (Test-Path $sqlIso))     { throw "SQL Server ISO not found: $sqlIso" }

    $vmDir = Join-Path $VmPath $vmName
    $vhdx  = Join-Path $vmDir "$vmName.vhdx"
    $existingVM = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($existingVM) {
        Assert-LabVMIdentity -Name $vmName -Path $VmPath
        Write-Host "  Resuming existing VM; preserving its OS disk." -ForegroundColor Yellow
    } else {

    $preparedMarker = Join-Path $vmDir 'windows-image-ready.txt'
    if ((Test-Path $vhdx) -and -not (Test-Path $preparedMarker)) {
        throw "Incomplete Windows image at $vhdx. No files were deleted. Inspect the disk before manually rebuilding this VM."
    }
    if (-not (Test-Path $vmDir)) { New-Item -ItemType Directory -Path $vmDir -Force | Out-Null }

    if (-not (Test-Path $vhdx)) {
    # ── Create VHDX from Windows ISO ─────────────────────────────────────
    Write-Host "  Creating VHDX from Windows ISO..." -ForegroundColor Yellow

    $isoMounted = $false
    $vhdMounted = $false
    try {
    $mountResult = Mount-DiskImage -ImagePath $windowsIso -PassThru
    $isoMounted = $true
    $isoDrive = ($mountResult | Get-Volume).DriveLetter
    $wimPath = "${isoDrive}:\sources\install.wim"
    if (-not (Test-Path $wimPath)) {
        $wimPath = "${isoDrive}:\sources\install.esd"
        if (-not (Test-Path $wimPath)) {
            throw "Cannot find install.wim or install.esd in the ISO."
        }
    }

    $images = Get-WindowsImage -ImagePath $wimPath
    $targetImage = $images | Where-Object { $_.ImageName -match 'Standard.*Desktop|Datacenter.*Desktop' } | Select-Object -First 1
    if (-not $targetImage) { $targetImage = $images | Where-Object { $_.ImageIndex -eq 2 } }
    if (-not $targetImage) { $targetImage = $images | Select-Object -First 1 }
    Write-Host "  Image: $($targetImage.ImageName) (Index $($targetImage.ImageIndex))" -ForegroundColor Yellow

    New-VHD -Path $vhdx -SizeBytes ([int64]$diskSizeGB * 1GB) -Dynamic | Out-Null
    $mountedVhd = Mount-VHD -Path $vhdx -Passthru
    $vhdMounted = $true
    $diskNum = $mountedVhd.DiskNumber

    Initialize-Disk -Number $diskNum -PartitionStyle GPT | Out-Null
    $efiPart = New-Partition -DiskNumber $diskNum -Size 100MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    Format-Volume -Partition $efiPart -FileSystem FAT32 -NewFileSystemLabel "EFI" -Confirm:$false | Out-Null
    $efiPart | Add-PartitionAccessPath -AccessPath "S:"

    New-Partition -DiskNumber $diskNum -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null

    $osPart = New-Partition -DiskNumber $diskNum -UseMaximumSize -AssignDriveLetter
    $osDrive = $osPart.DriveLetter
    Format-Volume -Partition $osPart -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false | Out-Null

    Write-Host "  Applying Windows image to ${osDrive}:\ ..." -ForegroundColor Yellow
    Expand-WindowsImage -ImagePath $wimPath -Index $targetImage.ImageIndex -ApplyPath "${osDrive}:\" | Out-Null

    # ── Inject unattend.xml ──────────────────────────────────────────────
    $pantherDir = "${osDrive}:\Windows\Panther"
    if (-not (Test-Path $pantherDir)) { New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null }

    # Build specialize pass for product key if provided
    $specializeXml = ""
    if ($windowsProductKey) {
        $specializeXml = @"

  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <ProductKey>$windowsProductKey</ProductKey>
    </component>
  </settings>
"@
    }

    $xmlPassword = [Security.SecurityElement]::Escape($AdminPassword)
    $unattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">$specializeXml
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>$xmlPassword</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
      <TimeZone>UTC</TimeZone>
      <ComputerName>$vmName</ComputerName>
    </component>
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
  </settings>
</unattend>
"@
    # Write without BOM — Windows Setup can choke on UTF-8 BOM
    [System.IO.File]::WriteAllText("${osDrive}:\Windows\Panther\unattend.xml", $unattend)
    [System.IO.File]::WriteAllText("${osDrive}:\unattend.xml", $unattend)

    # Inject SetupComplete.cmd — runs once after setup, enables PSRemoting and RDP
    $setupDir = "${osDrive}:\Windows\Setup\Scripts"
    if (-not (Test-Path $setupDir)) { New-Item -ItemType Directory -Path $setupDir -Force | Out-Null }
    $setupComplete = @"
@echo off
powershell -Command "Enable-PSRemoting -Force -SkipNetworkProfileCheck" >C:\setup-psremoting.log 2>&1
powershell -Command "Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0" >>C:\setup-psremoting.log 2>&1
netsh advfirewall firewall set rule group="Remote Desktop" new enable=yes >>C:\setup-psremoting.log 2>&1
netsh advfirewall firewall add rule name="WinRM-HTTP" dir=in localport=5985 protocol=tcp action=allow >>C:\setup-psremoting.log 2>&1
"@
    [System.IO.File]::WriteAllText("${setupDir}\SetupComplete.cmd", $setupComplete)

    # ── Boot config ──────────────────────────────────────────────────────
    & bcdboot "${osDrive}:\Windows" /s S: /f UEFI | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "bcdboot failed for $vmName (exit $LASTEXITCODE)." }

    Dismount-VHD -Path $vhdx
    $vhdMounted = $false
    Dismount-DiskImage -ImagePath $windowsIso | Out-Null
    $isoMounted = $false
    } finally {
        if ($vhdMounted) { Dismount-VHD -Path $vhdx -ErrorAction Stop }
        if ($isoMounted) { Dismount-DiskImage -ImagePath $windowsIso -ErrorAction Stop | Out-Null }
    }
    Set-Content -LiteralPath $preparedMarker -Value 'Windows image and boot configuration complete.' -ErrorAction Stop
    }

    # ── Create VM ────────────────────────────────────────────────────────
    Write-Host "  Creating VM ($vCpus vCPUs, ${memoryGB}GB RAM)..." -ForegroundColor Yellow

    $vmParameters = @{
        Name=$vmName; MemoryStartupBytes=([int64]$memoryGB * 1GB)
        VHDPath=$vhdx; Generation=2; Path=$VmPath
    }
    if (-not $AzureHost) { $vmParameters.SwitchName = $SwitchName }
    New-VM @vmParameters | Out-Null

    Set-VM -Name $vmName -ProcessorCount $vCpus -DynamicMemory `
           -MemoryMinimumBytes 1GB -MemoryMaximumBytes ([int64]$memoryGB * 1GB) `
           -AutomaticCheckpointsEnabled $false -CheckpointType Disabled

    Set-VMFirmware -VMName $vmName -EnableSecureBoot Off
    Add-VMDvdDrive -VMName $vmName -Path $sqlIso
    }

    # ── Start and wait ───────────────────────────────────────────────────
    if ((Get-VM -Name $vmName).State -eq 'Off') { Start-VM -Name $vmName }
    Write-Host "  Waiting for Windows setup (10-15 min)..." -ForegroundColor Yellow
    Wait-VMReady -VMName $vmName -Credential $credential -TimeoutMinutes 25

    if ($AzureHost) {
        $guestAdapters = @(Get-VMNetworkAdapter -VMName $vmName -ErrorAction Stop)
        if ($guestAdapters.Count -ne 1 -or
            ($guestAdapters[0].SwitchName -and $guestAdapters[0].SwitchName -ne $SwitchName)) {
            throw "Refusing to change networking for $vmName`: expected one adapter disconnected or on $SwitchName."
        }
        $guestAdapters[0] | Disconnect-VMNetworkAdapter -ErrorAction Stop
        Invoke-Command -VMName $vmName -Credential $credential -ErrorAction Stop -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            if (-not (Get-NetFirewallRule -PolicyStore ActiveStore | Where-Object { $_.Name -eq 'ArcSqlLabBlockIMDS' })) {
                New-NetFirewallRule -Name ArcSqlLabBlockIMDS -DisplayName 'Arc SQL lab: block Azure IMDS' `
                -Direction Outbound -Action Block -RemoteAddress 169.254.169.254 -Profile Any | Out-Null
            }
            Set-NetFirewallRule -Name ArcSqlLabBlockIMDS -Enabled True -Direction Outbound `
                -Action Block -Profile Any -RemoteAddress 169.254.169.254 -ErrorAction Stop
        }
        Get-VMNetworkAdapter -VMName $vmName | Connect-VMNetworkAdapter -SwitchName $SwitchName -ErrorAction Stop
        Invoke-Command -VMName $vmName -Credential $credential -ErrorAction Stop -ScriptBlock {
            param($ip)
            $ErrorActionPreference = 'Stop'
            $deadline = (Get-Date).AddSeconds(30)
            do {
                $adapters = @(Get-NetAdapter -ErrorAction Stop)
                if ($adapters.Count -ne 1) { throw 'Expected one network adapter in the guest.' }
                if ($adapters[0].Status -eq 'Up') { break }
                if ((Get-Date) -ge $deadline) { throw 'Guest network adapter did not become connected within 30 seconds.' }
                Start-Sleep -Seconds 1
            } while ($true)
            $interface = $adapters[0].ifIndex
            # Set DHCP mode and the static address together, including the saved configuration.
            foreach ($store in @('persistent', 'active')) {
                $output = & netsh.exe interface ipv4 set address "name=$interface" source=static `
                    "address=$ip" mask=255.255.255.0 gateway=10.241.0.1 "store=$store" 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Guest IPv4 configuration failed for $store (exit $LASTEXITCODE): $($output -join ' ')"
                }
            }
            foreach ($store in @('PersistentStore', 'ActiveStore')) {
                $addresses = @(Get-NetIPAddress -InterfaceIndex $interface -AddressFamily IPv4 -PolicyStore $store -ErrorAction Stop)
                $gateways = @(Get-NetRoute -InterfaceIndex $interface -AddressFamily IPv4 -PolicyStore $store -ErrorAction Stop |
                    Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and $_.NextHop -eq '10.241.0.1' })
                if (-not ($addresses | Where-Object { $_.IPAddress -eq $ip -and $_.PrefixLength -eq 24 }) -or
                    $gateways.Count -eq 0) {
                    throw "Guest IPv4 verification failed for $store on interface $interface. Expected $ip/24 and gateway 10.241.0.1. Addresses: $($addresses.IPAddress -join ', ')."
                }
            }
            # PersistentStore does not expose a usable Dhcp value on all Windows versions.
            $ipInterface = @(Get-NetIPInterface -InterfaceIndex $interface -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction Stop)
            if ($ipInterface.Count -ne 1 -or $ipInterface[0].Dhcp -ne 'Disabled') {
                throw "Guest IPv4 verification failed: active DHCP is not Disabled on connected interface $interface."
            }
            Set-DnsClientServerAddress -InterfaceIndex $interface -ServerAddresses 168.63.129.16
        } -ArgumentList $config.IPAddress
    }

    # ── Install SQL Server ───────────────────────────────────────────────
    Write-Host "  Installing SQL Server..." -ForegroundColor Yellow

    $dvdDrives = @(Get-VMDvdDrive -VMName $vmName)
    if ($dvdDrives.Count) { $dvdDrives[0] | Set-VMDvdDrive -Path $sqlIso }
    else { Add-VMDvdDrive -VMName $vmName -Path $sqlIso }

    Invoke-Command -VMName $vmName -Credential $credential -ErrorAction Stop -ScriptBlock {
        param($sqlKey)
        $ErrorActionPreference = 'Stop'
        if (-not (Get-Service | Where-Object { $_.Name -eq 'MSSQLSERVER' })) {
        $dvd = Get-Volume | Where-Object { $_.DriveType -eq 'CD-ROM' } |
            ForEach-Object { "$($_.DriveLetter):" } |
            Where-Object { Test-Path "$_\setup.exe" } | Select-Object -First 1

        if (-not $dvd) { throw "SQL Server ISO not found on DVD drive." }

        foreach ($d in @("C:\SQLData","C:\SQLLog","C:\SQLTempDB")) {
            if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        }

        $setupArgs = @(
            "/Q", "/ACTION=Install", "/FEATURES=SQLENGINE",
            "/INSTANCENAME=MSSQLSERVER",
            "/SQLSVCACCOUNT=`"NT AUTHORITY\SYSTEM`"",
            "/SQLSYSADMINACCOUNTS=`"BUILTIN\Administrators`"",
            "/AGTSVCACCOUNT=`"NT AUTHORITY\SYSTEM`"",
            "/AGTSVCSTARTUPTYPE=Automatic",
            "/SQLUSERDBDIR=`"C:\SQLData`"",
            "/SQLUSERDBLOGDIR=`"C:\SQLLog`"",
            "/SQLTEMPDBDIR=`"C:\SQLTempDB`"",
            "/SQLTEMPDBLOGDIR=`"C:\SQLTempDB`"",
            "/SECURITYMODE=SQL",
            "/SAPWD=`"$using:AdminPassword`"",
            "/TCPENABLED=1",
            "/IACCEPTSQLSERVERLICENSETERMS",
            "/UpdateEnabled=False"
        )

        # Add product key if provided (Developer edition doesn't need one)
        if ($sqlKey) { $setupArgs += "/PID=`"$sqlKey`"" }

        $proc = Start-Process "$dvd\setup.exe" -ArgumentList $setupArgs -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -notin @(0, 3010)) { throw "SQL setup failed with exit code $($proc.ExitCode)" }
        if ($proc.ExitCode -eq 3010) { throw 'SQL setup requires a guest restart. Restart this VM, then rerun the same command.' }
        }
        Start-Service -Name MSSQLSERVER -ErrorAction Stop

        if (-not (Get-NetFirewallRule | Where-Object { $_.DisplayName -eq 'SQL Server (TCP 1433)' })) {
            New-NetFirewallRule -DisplayName 'SQL Server (TCP 1433)' -Direction Inbound -Protocol TCP `
                -LocalPort 1433 -Action Allow -Profile Any | Out-Null
        }
    } -ArgumentList $sqlProductKey

    Write-Host "  SQL Server installed." -ForegroundColor Green

    # ── Configure databases ──────────────────────────────────────────────
    Write-Host "  Configuring databases..." -ForegroundColor Yellow

    $configScript = Get-Content (Join-Path $scriptDir "configure-sql-hyperv.ps1") -Raw

    Invoke-Command -VMName $vmName -Credential $credential -ErrorAction Stop -ScriptBlock {
        param($script, $db, $mc)
        $ErrorActionPreference = 'Stop'
        $hash = [Security.Cryptography.SHA256]::Create()
        try {
            $signature = [Convert]::ToBase64String($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes("$db`n$mc`n$script")))
        } finally { $hash.Dispose() }
        $marker = 'C:\sql-lab-configuration.sha256'
        if ((Test-Path -LiteralPath $marker) -and (Get-Content -LiteralPath $marker -Raw).Trim() -eq $signature) {
            Write-Host '  Requested SQL configuration already completed; skipping.'
            return
        }
        $script | Out-File -FilePath "C:\configure-sql-hyperv.ps1" -Encoding utf8
        & powershell -ExecutionPolicy Unrestricted -File "C:\configure-sql-hyperv.ps1" -Databases $db -Misconfigs $mc
        if ($LASTEXITCODE -ne 0) { throw "SQL configuration failed with exit code $LASTEXITCODE. Inspect C:\configure-sql-log.txt." }
        Set-Content -LiteralPath $marker -Value $signature -ErrorAction Stop
    } -ArgumentList $configScript, $databases, $misconfigs

    Write-Host "  Databases configured." -ForegroundColor Green

    Get-VMDvdDrive -VMName $vmName | Set-VMDvdDrive -Path $null

    Write-Host "`n  VM '$vmName' ready for Arc enablement!" -ForegroundColor Green
    Write-Host "  Connect: vmconnect localhost $vmName" -ForegroundColor DarkCyan
}

Write-Host "`n================================================================" -ForegroundColor Cyan
Write-Host "[DONE] $($VmConfigs.Count) VM(s) provisioned." -ForegroundColor Green
if ($AzureHost) {
    Write-Host "Next: Run Enable-HyperVGuestArcSqlBpa.ps1 on this host with the guest VM names, Azure destination, workspace and explicit license type." -ForegroundColor Green
} else {
    Write-Host "Next: Follow docs\MONITORING-SETUP.md to onboard the guests and enable SQL BPA." -ForegroundColor Green
}

#endregion
