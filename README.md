# Azure Arc SQL Dashboard

An Azure Workbook for exploring SQL Server inventory, CPU utilization, storage
I/O, best practices assessment results, and Azure migration readiness.

The primary workbook is
[Azure Arc SQL Dasbboard w cpu and io and assessment.json](AzureBPAWorkbook/Azure%20Arc%20SQL%20Dasbboard%20w%20cpu%20and%20io%20and%20assessment.json).
The filename is retained as it exists in the repository.

## What the workbook shows

| Area | Views |
|---|---|
| SQL Server inventory | Instance editions and versions, database counts, instance details, and Arc machines with SQL Server installed |
| CPU utilization | Machine-level summary and a trend chart for the selected machine |
| Storage I/O | Disk latency summary and a trend chart for the selected machine |
| Storage & I/O Analysis | Azure VM disk configuration and storage checklist; latency, IOPS, queue length and SQL buffer I/O drill-downs; storage-related BPA findings |
| Best practices assessment (BPA) | Assessment runs, issues by severity, server and database, check summaries, and check details |
| Migration assessment | Readiness for Azure SQL Database, Azure SQL Managed Instance, and SQL Server on Azure VMs; server and database drill-downs, blockers, features requiring planning, and shared dependencies |
| Azure Advisor | All Advisor categories for Arc SQL hosts and registered Azure SQL VMs; estate totals, category/impact/coverage pies, machine totals, and selectable recommendation details |
| Azure Updates | Update Manager assessment coverage, missing patch/reboot totals, three pies, host summaries, affected-machine patch totals, and selectable missing-patch details |
| Windows Health | All Windows Arc machines (not only SQL hosts): OS end-of-support, Update Manager assessment and missing patches, Machine Configuration and Azure Policy compliance, and installed software from Defender and Change Tracking, with per-machine drill-down |
| Assessment coverage | SQL IaaS BPA assessment coverage in the BPA Enterprise Dashboard; migration views require actual uploaded assessment results |

Use the subscription and resource-group selectors to scope inventory. Select
the appropriate Log Analytics workspace(s) and time range for performance data,
and the assessment workspace for BPA results. Click a machine row in a
performance summary to display its trend. BPA includes severity and tag filters.

The primary workbook includes eight tabs, preserving all five from the four versions: **Azure Arc
SQL Resources**, **BPA Enterprise Dashboard**, **Custom Monitoring**, **Storage &
I/O Analysis**, **Migration Assessment**, **Azure Advisor**, **Azure Updates**, and **Windows Health**. Storage & I/O Analysis has its own
workspace and time selectors; select a machine in its I/O summary for the charts.
Its performance panels require the corresponding `Perf` counters, and its Azure
VM disk inventory does not enumerate VHDX disks inside nested Hyper-V guests.

Migration readiness is an assessment result, not a guarantee of application
compatibility or a substitute for migration testing.
The three readiness charts filter the comparison and server grids when selected;
before selection, their filters are explicitly initialized to `All` so both grids
run unfiltered. Clearing a chart selection also exports `All`; empty export
defaults alone do not initialize these dependencies reliably.

The Migration Assessment tab uses actual uploaded readiness results, not native
Azure VM inventory or BPA runs as a proxy for modernizability. The IaaS
inventory/BPA/Modernization Advisor sections have been removed: no documented
public results feed has been verified for native SQL VM Advisor integration.
For non-Arc SQL instances, SSMS 22+ can generate a separate assessment comparing
Azure SQL Database, Managed Instance, and SQL VM targets; the workbook does not
ingest those reports. BPA findings remain in the BPA Enterprise Dashboard.
See [the monitoring guide](docs/MONITORING-SETUP.md#native-azure-vm-modernization-versus-arc-assessment).

## Data and access requirements

The workbook visualizes existing data; importing it does **not** install agents,
enable assessments, or create data collection rules.

| Data | Source / prerequisite |
|---|---|
| Inventory and migration readiness | Azure Resource Graph; SQL Server instances connected to Azure Arc, with migration assessment data populated for readiness views |
| CPU and disk latency | Log Analytics performance data collected through Azure Monitor Agent (AMA); queries support `Perf` and relevant `InsightsMetrics` data |
| BPA findings | `SqlAssessment_CL`, including CSV assessment records in `RawData` and the originating machine's `_ResourceId` |
| Azure Advisor | Resource Graph `advisorresources` joined by full resource IDs to SQL VM registrations, Arc SQL instance parents, or Arc machine SQL discovery; no Log Analytics workspace required |
| Azure Updates | Resource Graph `patchassessmentresources`; Update Manager assessments must have run on the SQL hosts; no Log Analytics workspace required |
| Windows Health | Resource Graph for Windows Arc machines (all, not only SQL hosts): `patchassessmentresources` (Update Manager assessments), `guestconfigurationresources` (Machine Configuration), `policyresources` and `securityresources` (Defender software inventory). Change Tracking software inventory and changes use a Log Analytics workspace (`ConfigurationData`, `ConfigurationChange`). Anything not enabled is shown as **Not enabled** or with a message naming what to enable |

The Advisor tab counts each returned recommendation once per host, includes
machines without returned recommendations, and retains all returned
category/state values. `HighAvailability` is displayed as **Reliability**.
Click a machine to filter the details, or choose **Show recommendations for all
SQL hosts** to reset; summary charts remain estate-wide. Recommendations on
machine descendants and their SQL inventory resources are included. Standalone
disk/network and subscription/resource-group recommendations are not attributed
to hosts. No returned recommendations is not proof of health, SQL compatibility,
or complete Arc Advisor coverage. The resource-group picker also includes groups
with native SQL VM or SQL instance resources, not just groups with Arc machines.

The Updates tab uses the same SQL host inventory and keeps machines with missing,
failed, or stale assessments visible. Successful assessments updated within 24
hours are labelled fresh. Only returned patch records matching the latest
successful assessment's ID and time window count; stale assessments remain
labelled, and zero returned patch rows does not certify that a host is patched.
Patch counts are per-machine records; the catalogue separately totals affected
machines per patch. The classification pie assigns a patch once (Critical,
Security, otherwise first classification), while details retain all classifications.
Root classification counts/errors and a truncation flag help identify incomplete
detail data. Assessment data is retained in Resource Graph for about seven days.
SQL patches appear only when reported by the OS update source, not as a complete
SQL CU catalogue. The tab neither installs updates nor enables assessments.

Storage section tables and Advisor panels use compact heights; the single-row
Advisor/Updates totals use minimal height to avoid unused vertical space. Large
result sets remain scrollable/exportable. Advisor and Updates headers show only
their titles; source, coverage, and freshness caveats are documented here and in
the [monitoring guide](docs/MONITORING-SETUP.md).

You need read access to the selected Azure resources and permission to query
the selected Log Analytics workspaces. Saving a shared workbook also requires
permission to create/update Azure Workbooks in the destination resource group.

The repository's lab setup collects Windows performance counters every
60 seconds. BPA collection is separate from performance collection, and migration
assessment is separate from BPA. Enabling one does not populate all views.
The workbook does not use the legacy `SQLAssessmentRecommendation` table for
its BPA panels.

## Import the workbook

1. Download or clone this repository.
2. In the Azure portal, open **Azure Monitor > Workbooks** and create a new workbook.
3. Enter **Edit** mode and open the **Advanced Editor** (`</>`).
4. Choose the workbook/gallery JSON editing mode rather than an ARM template,
   if the editor offers that choice.
5. Replace the editor contents with the full contents of
   [the primary workbook JSON](AzureBPAWorkbook/Azure%20Arc%20SQL%20Dasbboard%20w%20cpu%20and%20io%20and%20assessment.json),
   then select **Apply**.
6. Select your subscriptions, resource groups, and Log Analytics workspaces.
7. Save the workbook with a descriptive name in your chosen subscription,
   resource group, and region.

This file is serialized workbook content, not a standalone ARM deployment
template. Files in [olderVersions](AzureBPAWorkbook/olderVersions) are historical
variants, not the primary dashboard.

## Screenshots

Screenshots will be added after the lab has been built. Suggested views to
capture are inventory, CPU and disk latency drill-downs, BPA findings, and
migration readiness.

## Lab and setup guides

The lab deliberately introduces SQL Server misconfigurations to produce
assessment findings. Use isolated, non-production environments only.

| Guide | Purpose |
|---|---|
| [Build the Azure Terraform lab](docs/AZURE-TERRAFORM-LAB.md) | Provision five Azure SQL Server VMs, networking, Bastion, Key Vault, and Log Analytics |
| [Build the Hyper-V lab](docs/HYPER-V-LAB.md) | Create local Windows/SQL Server VMs ready for Azure Arc onboarding |
| [Build the Azure-hosted Arc SQL Jumpstart lab](docs/ARC-JUMPSTART-LAB.md) | Create five nested Arc SQL guests on one Azure x64 Hyper-V host, including from an ARM64 laptop |
| [Configure agents, DCRs, and alerts](docs/MONITORING-SETUP.md) | Enable Arc or SQL IaaS management, configure collection, verify data, and deploy alerts |

For the Azure lab, create your local tfvars from the example and run
[Create-LabEnvironment.ps1](Create-LabEnvironment.ps1). It bootstraps remote
state and uses Terraform to deploy the lab, monitoring, alerts, and this workbook.

Supporting references:

- [Arc SQL BPA enablement](docs/ENABLE-ARC-SQL-BPA.md)
- [Performance counter reference](docs/PERFORMANCE-COUNTERS.md)
- [Alert rule reference](docs/CREATING-ALERTS.md)
- [DCR/DCE migration](docs/DCR-DCE-MIGRATION.md)
- [SRE knowledge and troubleshooting](SRE-Knowledge)

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
[hyper-v\configure-sql-hyperv.ps1](hyper-v/configure-sql-hyperv.ps1)
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
[Arc SQL BPA guide](docs/ENABLE-ARC-SQL-BPA.md). Verify ingestion into
`SqlAssessment_CL`, then select the correct assessment workspace and time range
in the workbook. Extension installation and DCR association alone do not enable
BPA; check the guide's licensing prerequisites.

Sample rows are not a sustained workload. CPU and I/O charts also require
performance collection and activity against the databases; see
[monitoring setup](docs/MONITORING-SETUP.md).

## Add SQL misconfigurations to the five Azure IaaS lab VMs

Run [Invoke-AzureSqlLabMisconfigurations.ps1](Invoke-AzureSqlLabMisconfigurations.ps1)
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
separate assessment; see [monitoring setup](docs/MONITORING-SETUP.md).

## Microsoft documentation

- [Azure Workbooks](https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-overview)
- [SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/overview)
- [Arc SQL best practices assessment](https://learn.microsoft.com/sql/sql-server/azure-arc/assess)
- [SQL VM best practices assessment](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/sql-assessment-for-sql-vm)
