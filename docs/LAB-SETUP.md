# Lab setup guide

[Back to the dashboard README](../README.md)

The lab deliberately introduces SQL Server misconfigurations to produce
assessment findings. Use isolated, non-production environments only.

| Guide | Purpose |
|---|---|
| [Build the Azure Terraform lab](AZURE-TERRAFORM-LAB.md) | Provision five Azure SQL Server VMs, networking, Bastion, Key Vault, and Log Analytics |
| [Build the Hyper-V lab](HYPER-V-LAB.md) | Create local Windows/SQL Server VMs ready for Azure Arc onboarding |
| [Build the Azure-hosted Arc SQL Jumpstart lab](ARC-JUMPSTART-LAB.md) | Create five nested Arc SQL guests on one Azure x64 Hyper-V host, including from an ARM64 laptop |
| [Configure agents, DCRs, and alerts](MONITORING-SETUP.md) | Enable Arc or SQL IaaS management, configure collection, verify data, and deploy alerts |

For the Azure lab, create your local tfvars from the example and run
[Create-LabEnvironment.ps1](../Create-LabEnvironment.ps1). It bootstraps remote
state and uses Terraform to deploy the lab, monitoring, alerts, and this workbook.

Supporting references:

- [Arc SQL BPA enablement](ENABLE-ARC-SQL-BPA.md)
- [Performance counter reference](PERFORMANCE-COUNTERS.md)
- [Alert rule reference](CREATING-ALERTS.md)
- [DCR/DCE migration](DCR-DCE-MIGRATION.md)
- [SRE knowledge and troubleshooting](../SRE-Knowledge)

## Add sample data and SQL misconfigurations to Hyper-V guests

Use this after the Arc Jumpstart bootstrap has finished creating and configuring
all five guests. Run the commands **on the Hyper-V host (`arcsql-host`)**, not on
your laptop or inside an individual guest. The SQL changes are made inside the
guests, not on the host itself.

**Disposable labs only.** Instance settings affect the whole default SQL instance;
the database flags below affect **all user databases**, including existing ones.
These settings are intentionally unsuitable for production. Record original
settings or take appropriate backups before changing a lab you need to preserve.
The script's `baseline` option is not a full undo of every change.

### 1. Copy the configuration script to the host

The bootstrap does not copy this script automatically. Connect to the host over
your approved RDP/private access path and open an elevated Windows PowerShell
session. Create a destination:

```powershell
New-Item -ItemType Directory -Path 'C:\LabScripts' -Force | Out-Null
```

Using RDP file sharing or another approved transfer method, copy
[hyper-v\configure-sql-hyperv.ps1](../hyper-v/configure-sql-hyperv.ps1)
from your local repository to
`C:\LabScripts\configure-sql-hyperv.ps1` on the host.
Confirm the copy and the guest names:

```powershell
Get-Item 'C:\LabScripts\configure-sql-hyperv.ps1' -ErrorAction Stop
Get-VM | Select-Object Name, State
```

### 2. Configure all five guests using PowerShell Direct

Use the guests' **current Administrator password**, which the completed bootstrap
sets to `LabCredential.Password`. Do not use the outer host's `arcadmin` username
or the image's initial demo password.

The guest account needs SQL `sysadmin` access to the default instance
(`localhost`). Guests need outbound HTTPS for sample database downloads and,
if it is not already installed, installation of the `SqlServer` PowerShell module.
Keep the bootstrap and other configuration jobs from running concurrently.

```powershell
$ErrorActionPreference = 'Stop'
$guestCredential = Get-Credential -UserName 'Administrator' `
    -Message 'Current guest Administrator credentials (rotated lab password)'
$scriptText = Get-Content 'C:\LabScripts\configure-sql-hyperv.ps1' -Raw
$guestNames = 1..5 | ForEach-Object { 'arcsql-{0:00}' -f $_ }

foreach ($guestName in $guestNames) {
    Write-Host "Configuring SQL sample data and misconfigurations on $guestName"
    Invoke-Command -VMName $guestName -Credential $guestCredential -ErrorAction Stop -ScriptBlock {
        param($configurationScript)
        $ErrorActionPreference = 'Stop'
        & ([scriptblock]::Create($configurationScript)) `
            -Databases 'adventureworks,misconfigdemo' `
            -Misconfigs 'maxdop_zero,ctp_default,no_adhoc_opt,auto_shrink,filegrowth_pct'
    } -ArgumentList $scriptText
}
```

Change the guest-name list if you used a different machine prefix or count.
The example restores AdventureWorks when absent and creates `MisconfigDemo`
with sample customers and orders when absent. It sets MAXDOP to 0, cost threshold
for parallelism to 5, disables optimization for ad hoc workloads, enables
AUTO_SHRINK, and sets percentage file growth. These can produce assessment
findings, but exact findings depend on the assessment rules and SQL environment.

The loop stops on a terminating error. Review the output and
`C:\configure-sql-log.txt` **inside the affected guest** before retrying.
Existing databases are skipped rather than reseeded, so a partially created
database may need inspection if a previous attempt failed.

### 3. Verify the SQL settings

Run on the host, using the same variables from the previous step:

```powershell
foreach ($guestName in $guestNames) {
    Write-Host "Verifying $guestName"
    Invoke-Command -VMName $guestName -Credential $guestCredential -ErrorAction Stop -ScriptBlock {
        Import-Module SqlServer -ErrorAction Stop
        Invoke-Sqlcmd -ServerInstance localhost -TrustServerCertificate -AbortOnError -ErrorAction Stop -Query @'
SELECT name, value_in_use
FROM sys.configurations
WHERE name IN ('max degree of parallelism', 'cost threshold for parallelism',
               'optimize for ad hoc workloads');
SELECT name, is_auto_shrink_on
FROM sys.databases WHERE database_id > 4;
SELECT DB_NAME(database_id) AS DatabaseName, name, growth, is_percent_growth
FROM sys.master_files WHERE database_id > 4;
SELECT COUNT(*) AS CustomerCount FROM MisconfigDemo.dbo.Customers;
SELECT COUNT(*) AS OrderCount FROM MisconfigDemo.dbo.Orders;
'@
    }
}
```

For a newly seeded `MisconfigDemo`, expect 1,000 customers and 5,000 orders.
The selected instance values should be 0, 5, and 0 respectively; user databases
should have AUTO_SHRINK enabled and data/log files should use 10% growth.

### 4. Populate the dashboard

SQL configuration changes do not upload assessment results by themselves.
Enable BPA and trigger or wait for an assessment using the
[Arc SQL BPA guide](ENABLE-ARC-SQL-BPA.md). Verify ingestion into
`SqlAssessment_CL`, then select the correct assessment workspace and time range
in the workbook. Extension installation and DCR association alone do not enable
BPA; check the guide's licensing prerequisites.

Sample rows are not a sustained workload. CPU and I/O charts also require
performance collection and activity against the databases; see
[monitoring setup](MONITORING-SETUP.md).

## Add SQL misconfigurations to the five Azure IaaS lab VMs

Run [Invoke-AzureSqlLabMisconfigurations.ps1](../Invoke-AzureSqlLabMisconfigurations.ps1)
locally in PowerShell 7.2+ with Azure CLI installed and signed in to the correct
tenant. It uses VM Run Command, not PowerShell Direct; no RDP, inbound SQL access,
or guest password is needed. Your Azure identity needs VM read and Run Command
execution permissions. The Windows VM agent must be healthy, the VM running,
and Run Command's SYSTEM account must have SQL sysadmin access. Do not run
concurrently with Terraform configuration or another Run Command on these VMs.

```powershell
az login --tenant '<tenant-id>'

# Preview: no Azure calls or SQL changes.
.\Invoke-AzureSqlLabMisconfigurations.ps1 `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName 'sql-bpa-lab-rg'

# Execute; asks for confirmation before modifying the five VMs.
.\Invoke-AzureSqlLabMisconfigurations.ps1 `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName 'sql-bpa-lab-rg' `
    -Apply
```

Default targets are `sql-bpa-01` through `sql-bpa-05`. Override `-VMNames`,
`-Databases`, and `-Misconfigs` with arrays as needed; use `Get-Help
.\Invoke-AzureSqlLabMisconfigurations.ps1 -Examples` for examples.
**This also misconfigures `sql-bpa-04`, which Terraform originally sets up as
a baseline.** Exclude it using `-VMNames` if you want to preserve that baseline.
The same lab-only warnings, guest download requirements, all-user-database
scope, and assessment prerequisites from the Hyper-V instructions apply.

The runner stops at the first unconfirmed result and checks a remote completion
marker instead of assuming CLI success means SQL success. Review the VM's
`C:\configure-sql-log.txt` and Run Command output before retrying a failed or
interrupted execution; a disconnected local runner does not necessarily stop
remote work. Completed VMs are not rolled back. BPA results still require a
separate assessment; see [monitoring setup](MONITORING-SETUP.md).

