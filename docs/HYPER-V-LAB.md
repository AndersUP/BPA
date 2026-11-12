# Build the Hyper-V lab

[Back to the dashboard README](../README.md)

Use [Create-HyperVLab.ps1](../hyper-v/Create-HyperVLab.ps1) to create local SQL
Server machines for Azure Arc testing. This is an alternative or complement to
[the Azure VM lab](AZURE-TERRAFORM-LAB.md); Azure VMs are not required to build
the local machines.

> Use isolated lab VMs only. The scripts intentionally weaken SQL configuration,
> use privileged service accounts, and enable SQL authentication. Never use
> production data or reuse a production password.

## Prerequisites

- An **x64 (Intel/AMD) host** running Windows 10/11 Pro or Enterprise, or Windows Server, with hardware
  virtualization available and enabled in firmware. The script checks Hyper-V
  and enables it if missing, including management tools. Windows Home is not
  supported.
- ARM64 hosts cannot run this lab's x64 Windows Server/SQL Server guests under
  Hyper-V. The script stops before enabling features on an unsupported host.
  Use an x64 Hyper-V host or the [Azure Terraform lab](AZURE-TERRAFORM-LAB.md).
- An elevated Windows PowerShell session on the Hyper-V host.
- Windows Server 2019/2022 installation media and corresponding SQL Server
  Developer media from an authorized source, such as a Visual Studio
  subscription or Microsoft evaluation downloads.
- Valid licensing/product keys where required. Omit product keys only when
  the selected media supports doing so (for example evaluation Windows media
  and SQL Developer).
- Capacity for each VM: defaults are **4 GB maximum dynamic RAM**, **2 vCPUs**,
  and a **60 GB dynamic VHDX**. Allow extra host RAM and disk space for media,
  databases, and setup; the script recommends about 8 GB free RAM and 80 GB
  free disk per VM.
- A Hyper-V switch with guest networking, DNS, and outbound HTTPS for downloads
  and later Azure Arc/AMA connectivity. An internal switch alone does not
  provide internet access without additional routing/NAT.
- Drive letter `S:` available on the host: the disk preparation script uses it
  temporarily for the EFI partition.

Inspect the available switches:

```powershell
Get-VMSwitch
```

On a host without Hyper-V, run the lab command below first. If enabling Hyper-V
requires a restart, the script stops before creating any VMs and asks you to
restart the host yourself. After restarting, reopen an elevated Windows
PowerShell session and rerun the same command (recreating `$vms` and `$password`
if needed). The script never restarts the host automatically. Installation
errors, including unsupported hardware or Windows editions, stop lab creation.

The script selects `Default Switch` when available, otherwise the first switch.
Pass `-SwitchName` explicitly to avoid choosing the wrong network.

## 1. Define and build the machines

Run from the repository root. Update the ISO paths to your actual media.
Enter a unique lab password when prompted:

```powershell
$password = Read-Host "Unique lab Administrator and SQL sa password"
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

.\hyper-v\Create-HyperVLab.ps1 `
    -VmConfigs $vms `
    -VmPath "C:\HyperVLab" `
    -AdminPassword $password `
    -SwitchName "Default Switch"
```

The password is a string because that is the script's interface. It is not
printed at completion. Run privately, avoid session transcription, and do not
use its built-in default password.

Each configuration can also include `MemoryGB`, `VCpus`, `DiskSizeGB`,
`WindowsProductKey`, and `SqlProductKey`. Do not commit keys or passwords.
No local license-key file is needed when using the example with suitable media.

## Add ISO-based guests on the existing Azure Jumpstart host

The workflow is: **obtain authorized media -> upload to private Blob storage ->
download onto `arcsql-host` -> create additional SQL guests**. Downloading an ISO
does not grant a Windows or SQL Server license.

### A. Obtain the ISOs and upload them to a storage account

Perform these steps on your workstation:

1. Download Windows Server and SQL Server ISOs from your authorized source,
   such as your Visual Studio subscription, your organization's licensing portal,
   or the Microsoft Evaluation Center. Use media and product keys that match
   your entitlement and intended SQL edition. Do not use a webpage/download
   landing-page URL as an ISO URL.
2. Record the original filenames and SHA256 hashes. Compare against
   publisher-provided hashes when available:

   ```powershell
   Get-ChildItem 'C:\ISOs' -Filter '*.iso' |
       Get-FileHash -Algorithm SHA256 |
       Format-Table Path, Hash -AutoSize
   ```

3. In the Azure portal, select the correct subscription and create or select a
   **StorageV2** storage account. For a new lab-only account, Standard performance,
   LRS redundancy, and the Hot access tier are sufficient. Keep secure transfer
   required and anonymous blob access disabled. Use a dedicated media container,
   not a Terraform state container.
4. Under **Data storage > Containers**, create a container named `lab-isos`.
   Set its anonymous access level to **Private (no anonymous access)**.
5. Open that container, select **Upload**, and upload your local `.iso` files
   as block blobs. Use simple, distinct filenames with letters, digits, hyphens,
   underscores, and periods; the download script rejects spaces and other
   characters. For example:

   | Media | Example blob filename |
   |------|-----------------------|
   | Windows Server 2022 | `WindowsServer2022.iso` |
   | Windows Server 2025 | `WindowsServer2025.iso` |
   | SQL Server 2022 | `SQLServer2022.iso` |
   | SQL Server 2025 | `SQLServer2025.iso` |

   These names are examples, not edition selectors. Wait for every upload to
   complete and confirm the blob sizes match the original files.
6. Your upload identity needs appropriate blob data permissions, typically
   **Storage Blob Data Contributor**. A subscription/resource Contributor role
   alone does not grant blob data access. For user-delegation SAS creation, the
   identity also needs delegation-key permission at storage-account scope or
   above; Storage Blob Data Contributor at account scope includes this.
7. Ensure both the uploading workstation and `arcsql-host` can reach the blob
   endpoint over HTTPS. A SAS does not bypass storage firewall rules. For a
   restricted account, allow the relevant network paths or use an approved
   private endpoint with working host DNS. Do not enable anonymous access or
   open the account to all networks just to resolve a transfer failure.

This is a two-stage transfer: first download the licensed media to the
workstation, then upload it to Blob storage. The lab scripts do not sign in to
media licensing portals or copy their download links directly into storage.

### B. Generate temporary read-only download links

In the Azure portal, open **each ISO blob** and use **Generate SAS**:

1. Prefer a **User delegation key** signing method (Microsoft Entra credentials)
   where available and permitted by your organization.
2. Grant **Read** only, require **HTTPS**, and choose an expiry long enough for
   all downloads, with a small allowance for clock skew at the start. User
   delegation SAS validity is limited to seven days; use a shorter window when
   possible.
3. Generate and copy the full **Blob SAS URL**, not just the token or container
   URL. It must identify one `.iso` blob and include its SAS query string.
4. Treat each URL as a temporary credential. Do not paste it into Git, chat,
   shell history, screenshots, or a session transcript. Do not grant write or
   delete permission to the download links.

### C. Download the ISOs onto the Azure Hyper-V host

Connect to `arcsql-host` using your approved RDP/Bastion access method and open
an elevated **Windows PowerShell** session there, not on your workstation.
Copy the following scripts from this repository into `C:\LabScripts`:

- [Download-LabIsos.ps1](../Download-LabIsos.ps1)
- [Create-HyperVLab.ps1](../hyper-v/Create-HyperVLab.ps1)
- [configure-sql-hyperv.ps1](../hyper-v/configure-sql-hyperv.ps1)

The two provisioning scripts must remain in the same folder. Use the latest
copies when resuming a failed VM.

For private Blob-hosted installation media, run on the host:

```powershell
Set-Location 'C:\LabScripts'
Get-PSDrive -Name F
.\Download-LabIsos.ps1 -DestinationDirectory 'F:\ISO'
```

Confirm `F:` is persistent storage on your host and has enough free space for
the ISOs **and** the additional guest disks. Do not use a temporary Azure VM
disk for media or VHDX files that must survive host maintenance.

The interactive download prompts request four URLs in this order: Windows
Server 2022, Windows Server 2025, SQL Server 2022 Enterprise, SQL Server 2025
Enterprise. These are prompt labels, not checks of the media edition.
If you only need one Windows ISO and one SQL ISO, use the URL-file option below
with exactly those two URLs instead.

For provisioning, copy both
[Create-HyperVLab.ps1](../hyper-v/Create-HyperVLab.ps1) and
[configure-sql-hyperv.ps1](../hyper-v/configure-sql-hyperv.ps1) to the same folder
on the host; the ISO files can remain in `F:\ISO`.
Use **`-AzureHost`**; the local-host defaults are not appropriate for this network.
Stop other provisioning/configuration jobs first.

Paste each full SAS URL at the hidden prompt (Windows Server 2022/2025, then
SQL Server 2022/2025 Enterprise). The script uses Windows BITS, retains the blob
filenames, rejects existing destinations, and reports file sizes and SHA256
hashes. Compare hashes against your trusted media source if available. Ensure
enough disk space and valid read-only SAS tokens for the entire transfer.
Do not put SAS URLs in source control, transcripts, or command history.
Use `-BlobUrls $urls` to download a different set of ISO files.
To avoid prompts entirely, save the full URLs (one per line, no quotes or
PowerShell code) in `iso-urls.txt` alongside the script on the host. Running
`.\Download-LabIsos.ps1` loads that file automatically. Alternatively pass
`-UrlFile 'C:\LabSecrets\iso-urls.txt'`. Keep URL files private and delete them
after downloading; the repository ignores files named `iso-urls.txt`.

For example, create `C:\LabSecrets\iso-urls.txt` privately using a text editor
and paste one complete SAS URL per line. Then run:

```powershell
.\Download-LabIsos.ps1 -UrlFile 'C:\LabSecrets\iso-urls.txt' `
    -DestinationDirectory 'F:\ISO'
Get-ChildItem 'F:\ISO' -Filter '*.iso' |
    Select-Object Name, Length
Get-ChildItem 'F:\ISO' -Filter '*.iso' |
    Get-FileHash -Algorithm SHA256 |
    Format-Table Path, Hash -AutoSize
```

Compare these hashes with the workstation hashes before creating guests. A hash
printed by the script alone does not establish publisher authenticity. Restrict
access to the URL file and remove it when finished. If files already exist,
the download script stops rather than overwriting them: reuse verified local
ISOs, or inspect the specific failed destination before retrying. Do not delete
all media to retry a single failed download.

### D. Create extra SQL Server VMs

Remain in the elevated host session at `C:\LabScripts`. Check the existing
network and guests before choosing names and addresses:

```powershell
Get-VMSwitch -Name 'ArcSqlLabNAT'
Get-NetNat -Name 'ArcSqlLabNAT'
Get-VM | Select-Object Name, State, MemoryAssigned
Get-VM | Get-VMNetworkAdapter |
    Select-Object VMName, SwitchName, IPAddresses
```

Choose unique names and reserve unused addresses in `10.241.0.111-120`.
Reported IPs do not account for every powered-off or unreported device. Replace
the example ISO paths below with the **actual downloaded filenames**. Start with
one or two additional guests rather than exhausting the outer host's capacity.

```powershell
# Run in an elevated PowerShell session on arcsql-host.
$securePassword = Read-Host 'Unique password for the NEW guests' -AsSecureString
$password = [PSCredential]::new('Administrator', $securePassword).GetNetworkCredential().Password
$vms = @(
    @{
        Name = 'arcstd-01'
        IPAddress = '10.241.0.111'
        WindowsIso = 'F:\ISO\WindowsServer2022.iso'
        SqlIso = 'F:\ISO\SQLServer2022.iso'
        MemoryGB = 4
        VCpus = 2
        DiskSizeGB = 80
        Databases = 'adventureworks,misconfigdemo'
        Misconfigs = 'maxdop_zero,ctp_default,auto_shrink,filegrowth_pct'
        # SqlProductKey = $standardProductKey
    },
    @{
        Name = 'arcent-01'
        IPAddress = '10.241.0.112'
        WindowsIso = 'F:\ISO\WindowsServer2022.iso'
        SqlIso = 'F:\ISO\SQLServer2022.iso'
        MemoryGB = 4
        VCpus = 2
        DiskSizeGB = 80
        Databases = 'adventureworks,misconfigdemo'
        Misconfigs = 'maxdop_zero,ctp_default,auto_shrink,filegrowth_pct'
        # SqlProductKey = $enterpriseProductKey
    }
)

.\Create-HyperVLab.ps1 -AzureHost -VmConfigs $vms `
    -VmPath 'F:\AdditionalSqlLab' -AdminPassword $password
```

Names do **not** select SQL editions: supply the correct licensed installation
media and `SqlProductKey` when required. Provide `WindowsProductKey` when required
by the Windows media. Do not commit keys or passwords. The new password must have
at least 12 characters, satisfy Windows and SQL complexity requirements, and not
contain double quotes or newlines.

### E. Resume and verify

If provisioning fails, keep the VM and its VHDX. After resolving the reported
error, rerun the same provisioning command with the same `$vms`, `VmPath`, and
original Administrator password. If you opened a new session, recreate `$vms`
and enter the same password again. Do not run the ISO downloader again when
the verified files are already present.

For example, to inspect the first new guest:

```powershell
$credential = [PSCredential]::new(
    'Administrator', (ConvertTo-SecureString $password -AsPlainText -Force)
)
Get-VM -Name $vms.Name
Invoke-Command -VMName $vms[0].Name -Credential $credential -ScriptBlock {
    Get-Service -Name 'MSSQLSERVER'
    Get-NetIPConfiguration
    Import-Module SqlServer
    Invoke-Sqlcmd -ServerInstance localhost -TrustServerCertificate `
        -Query 'SELECT name, state_desc FROM sys.databases;'
}
```

Confirm SQL is running, the intended databases are online, and the guest has its
reserved IP and outbound connectivity. Then follow
[host-run Arc and BPA onboarding](MONITORING-SETUP.md#onboard-from-the-azure-hyper-v-host)
using [Enable-HyperVGuestArcSqlBpa.ps1](../hyper-v/Enable-HyperVGuestArcSqlBpa.ps1).
Run that script on `arcsql-host` with `-VMName 'arcsql-06','arcsql-07'` (or your
actual new names), the Azure destination, existing workspace resource ID, and
an explicit eligible SQL license type. It prompts securely for guest and service
principal credentials; it does not run the Arc installer on the outer Azure VM.
VM creation alone does not onboard the guests.

Azure-host mode:

- Requires the existing internal `ArcSqlLabNAT` switch, `10.241.0.0/24` NAT,
  and gateway `10.241.0.1/24`; it does not create/change host networking or roles.
- Requires unique explicit IPs within **10.241.0.111-120**. Checks reported guest
  addresses and ping responses, but cannot detect powered-off, unreported, or
  nonresponsive devices. Reserve these addresses and verify they are unused.
- Blocks outbound Azure IMDS (`169.254.169.254`) while disconnected, then
  connects the guest and waits for link-up before configuring static networking
  and Azure DNS (`168.63.129.16`). Static configuration on a disconnected adapter
  can leave active DHCP enabled even when the address has been saved.
- Uses `netsh interface ipv4 set address source=static` to set the guest address,
  DHCP mode, and gateway together in the persistent and active stores. This
  replaces the `New-NetIPAddress` path that can fail with `Inconsistent parameters
  PolicyStore PersistentStore and Dhcp Enabled` on disconnected adapters.
  Checks native exit codes, verifies address/prefix and gateway in both stores,
  and verifies DHCP is disabled in `ActiveStore`. The persistent interface object
  does not expose a usable DHCP value on all Windows versions.
- Resumes existing Generation 2 VMs only when their sole disk matches
  `<VmPath>\<Name>\<Name>.vhdx`. Rerun the same command with the same configuration
  and Administrator password after a failure, including failures from older
  script versions. Other disk locations and duplicate names are rejected.
  Keep the original media, edition, sizing, and keys: resume is not an edition
  upgrade or resize operation.
- Reconciles guest networking/firewall rules, starts SQL if already installed,
  and skips successful database configuration when its script and inputs match
  the persisted guest checkpoint. Failed configuration is retried; existing
  databases are preserved. Removing a requested misconfiguration from the input
  does not undo a previously applied setting.
- Never deletes partial disks. A completed offline Windows image has a host
  checkpoint so VM registration can be retried. An interrupted image application
  without that checkpoint stops for manual inspection instead of overwriting it.
- Checks full provisioned disk capacity plus 20 GB free reserve, existing/new
  maximum memory reservations plus 8 GB for the host, and currently free memory.
  Five existing 8 GB guests already reserve 40 GB. Add a small number first;
  resize the outer Azure VM if checks fail. CPU contention still needs monitoring.
- Requires `S:` to be free for temporary disk preparation and unmounts its media
  and VHDX on preparation failure. Partial VHDX files are retained for inspection.
- Does **not** install Arc, AMA, or SQL Arc extensions or enable BPA. Follow
  [monitoring setup](MONITORING-SETUP.md) separately, with the appropriate
  licensing prerequisites and existing DCR/DCE associations.

## 2. What the script does

1. Checks Hyper-V and installs/enables it if missing; stops if a restart is needed.
2. Mounts Windows media, creates/partitions a VHDX, applies a Windows image,
   and configures unattended setup.
3. Creates and starts a Generation 2 VM and waits for PowerShell Direct.
4. Installs the default SQL instance (`MSSQLSERVER`) from the SQL ISO.
5. Configures SQL data/log/tempdb directories and an inbound TCP 1433 firewall rule.
6. Runs [configure-sql-hyperv.ps1](../hyper-v/configure-sql-hyperv.ps1) to
   configure sample databases and requested misconfigurations.
7. Ejects the SQL ISO.

Windows setup can take 10-15 minutes per machine; the readiness wait allows
25 minutes. PowerShell Direct works through the host without guest WinRM
network configuration.

## 3. Verify and onboard to Azure Arc

```powershell
Get-VM -Name "arc-sql-01","arc-sql-02"
$credential = Get-Credential -UserName "Administrator"
Invoke-Command -VMName "arc-sql-01" -Credential $credential -ScriptBlock {
    Get-Service -Name MSSQLSERVER
    Get-NetIPConfiguration
}
```

Confirm SQL is running, the expected databases exist, and each guest has
outbound connectivity. Use `vmconnect localhost arc-sql-01` for console access.

Next, follow [the Arc onboarding and monitoring guide](MONITORING-SETUP.md#2-enable-arc-management-on-hyper-v-guests).
You need an Azure resource group and Log Analytics workspace even for a
Hyper-V-only lab. Importing the workbook or creating these VMs alone does not
connect them to Azure or enable assessments.

## Troubleshooting and cleanup

- **`Get-WindowsOptionalFeature: Class not registered`:** the Windows-client
  prerequisite check now uses `dism.exe` instead of the DISM PowerShell cmdlets.
  This avoids that cmdlet dependency; it does not make x64 guests compatible
  with ARM64 hosts. Run from an elevated session on a supported x64 host.
- For a partial VM (for example `arcsql-06`), copy the updated scripts to the host
  and rerun the original command. Leave the VM and its VHDX intact. If SQL setup
  requests a restart, restart only that guest and rerun. Installation failures
  that require SQL repair still need inspection of the SQL setup logs.
- Confirm ISO paths, image edition, product-key compatibility, host capacity,
  and switch connectivity when setup fails.
- Incomplete offline Windows images require manual inspection; the script never
  automatically removes the VM directory or its disk.
- To retire a machine, stop it and remove its VM registration using Hyper-V
  Manager. After confirming the exact VHDX/folder is no longer needed, delete
  only that machine's files. Do not remove the whole host storage directory.
- Also retire its Azure Arc resource and review DCR associations, alerts, and
  retained Log Analytics data. Removing the local VM does not remove Azure resources.
