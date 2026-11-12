# Azure SRE Agent – Indexable Content for SQL BPA Repository

This file is designed to be indexed by the Azure SRE agent as a single consolidated reference for the SQL Best Practice Assessment (BPA) deployment.

---

## Repository Purpose

This repository automates the deployment and management of **SQL Server Best Practice Assessment (BPA)** for:
- **Azure VMs** running SQL Server (managed via SQL IaaS Agent Extension)
- **On-premises / multi-cloud servers** running SQL Server (managed via Azure Arc)

The environment collects BPA assessment results and SQL Server performance counters into a Log Analytics workspace and visualises them via Azure Workbook dashboards.

---

## Key Scripts

### Install-AzureArcAgent-SqlBPA.ps1
Installs the Azure Connected Machine Agent on a non-Azure server, connects it to Azure Arc, and enables SQL BPA. Requires: TenantId, SubscriptionId, ResourceGroupName, Location, ServicePrincipalClientId, ServicePrincipalSecret, WorkspaceId, WorkspaceKey. The service principal needs "Azure Connected Machine Onboarding" role.

### Azure VM assessment and alerts
[sql-assessment.tf](../terraform/sql-assessment.tf) manages SQL IaaS registration,
BPA scheduling, and AMA. [alerts.tf](../terraform/alerts.tf) manages alert rules
and the email action group.

### Create-LabEnvironment.ps1
Azure-only lab deployment: reads tfvars, bootstraps remote state and blob RBAC,
then runs Terraform for VMs, BPA, monitoring, alerts, and the workbook.
Hyper-V provisioning and Arc onboarding are separate workflows.

### Remove-OldDcrAssociations.ps1
Removes legacy DCR and DCE associations that were auto-created by Azure CLI before Terraform migration. Run before `terraform apply` if migrating.

### Import existing resources
Use explicit `terraform import` commands with verified resource IDs as described
in [DCR/DCE migration](../docs/DCR-DCE-MIGRATION.md).

---

## Infrastructure (Terraform)

All infrastructure is managed via Terraform in the `terraform/` directory:

- **main.tf**: Resource group, Log Analytics workspace, resource providers
- **sql-vms.tf**: 5 SQL Server VMs with varying sizes, SQL versions, and intentional misconfigurations
- **network.tf**: VNet, subnet, NSG
- **bastion.tf**: Azure Bastion for secure VM access
- **keyvault.tf**: Key Vault for credential storage
- **extensions.tf**: CustomScriptExtension for SQL configuration, storage account for scripts
- **bpa-assessment-dcr.tf**: Data Collection Endpoint and Rule for BPA CSV ingestion
- **performance-counters-dcr.tf**: DCR for 34 SQL Server performance counters
- **variables.tf**: Configuration variables (prefix, location, admin username, etc.)

---

## Required Agents by VM Type

### Azure VMs
1. **SQL IaaS Agent Extension** (Full mode) – manages SQL Server, enables BPA
2. **Azure Monitor Agent (AMA)** – collects BPA CSVs and perf counters
3. **CustomScriptExtension** – initial SQL configuration (lab only)

### Arc-enabled Servers
1. **Azure Connected Machine Agent** – connects to Azure Arc (status must be "Connected")
2. **WindowsAgent.SqlServer** – Arc SQL extension (auto-deployed when Arc detects SQL Server)
3. **Azure Monitor Agent (AMA)** – collects BPA CSVs and perf counters

---

## Data Collection Rules

### BPA Assessment DCR
- **Name**: `{prefix}-bpa-dcr`
- **Type**: Log file collection (text/CSV)
- **File patterns monitored**:
  - `C:\Windows\System32\config\systemprofile\AppData\Local\Microsoft SQL Server IaaS Agent\Assessment\*.csv`
  - `C:\Windows\System32\config\systemprofile\AppData\Local\Microsoft SQL Server Extension Agent\Assessment\*.csv`
- **Destination**: Log Analytics workspace → `SqlAssessment_CL` custom table
- **Transform**: `source` (pass-through)

### Performance Counters DCR
- **Name**: `{prefix}-sql-perfcounters-dcr`
- **Collection interval**: 60 seconds
- **Destination**: Log Analytics workspace → `Perf` table
- **Counters** (34 total): Buffer cache hit ratio, Page life expectancy, Batch Requests/sec, Deadlocks/sec, Full Scans/sec, % Processor Time, Available MBytes, Avg Disk sec/Read, Avg Disk sec/Write, and more.

---

## DCR/DCE Associations Required Per Machine

| Association | Name | Type |
|-------------|------|------|
| BPA DCR | `{vm}-bpa-dcr-association` | Data Collection Rule |
| BPA DCE | `configurationAccessEndpoint` | Data Collection Endpoint (exact name required) |
| Perf DCR | `{vm}-perf-dcr-association` | Data Collection Rule |

---

## SQL Misconfigurations Tested

The lab injects these misconfigurations to generate BPA findings:

| Code | Description | Impact |
|------|-------------|--------|
| maxmem_default | Max memory at default (unlimited) | OS memory starvation |
| maxdop_zero | MAXDOP = 0 (use all CPUs) | CXPACKET waits |
| ctp_default | Cost threshold = 5 (too low) | Unnecessary parallelism |
| tempdb_one_file | Single TempDB data file | Allocation contention |
| auto_shrink | AUTO_SHRINK enabled | Fragmentation, I/O overhead |
| auto_close | AUTO_CLOSE enabled | Connection overhead |
| page_verify_none | PAGE_VERIFY = NONE | Silent data corruption risk |
| tempdb_os_drive | TempDB on C: drive | I/O competition with OS |
| no_adhoc_opt | Optimize for ad hoc disabled | Plan cache bloat |
| filegrowth_pct | Percentage-based file growth | VLF fragmentation |
| data_log_same_vol | Data and log on same volume | I/O contention |
| recovery_simple | SIMPLE recovery model | No point-in-time restore |

---

## Verification Commands

### Check SQL VM BPA status
```powershell
az sql vm show --resource-group <rg> --name <vm> --query "assessmentSettings" -o json
```

### Check Arc machine status
```powershell
az connectedmachine show --resource-group <rg> --name <machine> --query "{status:status}" -o table
```

### Check extensions on Azure VM
```powershell
az vm extension list --resource-group <rg> --vm-name <vm> --query "[].{name:name, state:provisioningState, type:type}" -o table
```

### Check extensions on Arc machine
```powershell
az connectedmachine extension list --machine-name <machine> --resource-group <rg> --query "[].{name:name, state:provisioningState}" -o table
```

### Check DCR associations
```powershell
az monitor data-collection rule association list --resource "<resource-id>" -o table
```

### Query BPA results in Log Analytics
```kql
SqlAssessment_CL | where TimeGenerated > ago(7d) | summarize count() by Computer = tostring(split(RawData, ",")[0])
```

### Query performance counters
```kql
Perf | where TimeGenerated > ago(1h) | where ObjectName startswith "SQLServer:" | summarize dcount(CounterName) by Computer
```
