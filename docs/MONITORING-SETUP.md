# Configure agents, DCRs, and alerts

[Back to the dashboard README](../README.md)

This guide connects the [Azure Terraform lab](AZURE-TERRAFORM-LAB.md) and
[Hyper-V lab](HYPER-V-LAB.md) to the dashboard's monitoring data.
Run workstation commands from the repository root. For Azure-hosted Hyper-V
guests, use the host-run onboarding script below; it executes guest installation
through PowerShell Direct and never installs Arc on the outer Azure VM.

## 1. Prepare Azure access and the workspace

You need Azure CLI, PowerShell, an Azure resource group, and a Log Analytics
workspace. The Terraform lab creates the latter two; for a Hyper-V-only
deployment, provision them separately first.

```powershell
$tenantId = "<tenant-id>"
$subscriptionId = "<subscription-id>"
$resourceGroup = "sql-bpa-lab-rg"
$workspaceName = "sql-bpa-lab-law"
$location = "swedencentral"

az login --tenant $tenantId
az account set --subscription $subscriptionId
$workspaceId = az monitor log-analytics workspace show `
    -g $resourceGroup -n $workspaceName --query id -o tsv
```

Check commands succeed and the workspace ID is correct. Use its actual region.
Permissions must cover extension/SQL VM updates, workspace access, collection
rules/associations, and alerts. Role assignments require additional RBAC
administration rights. The scripts install missing Az PowerShell modules;
the SQL IaaS script also calls Azure CLI.

## 2. Enable Arc management on Hyper-V guests

Skip this section for native Azure VMs; use the SQL IaaS path below instead.

Register `Microsoft.HybridCompute`, `Microsoft.GuestConfiguration`,
`Microsoft.AzureArcData`, `Microsoft.OperationalInsights`, and `Microsoft.Insights` in the subscription
using an appropriately privileged deployment identity before onboarding.

Create a dedicated, short-lived onboarding service principal with **Azure
Connected Machine Onboarding** at the target resource group. Onboarding alone
does not grant permission to configure SQL assessments or monitoring. Have an
administrator perform those operations or grant the additional permissions
documented in [Arc BPA prerequisites](ENABLE-ARC-SQL-BPA.md#prerequisites).
Do not grant subscription-wide Owner merely to simplify onboarding.

### Onboard from the Azure Hyper-V host

Copy [Enable-HyperVGuestArcSqlBpa.ps1](../hyper-v/Enable-HyperVGuestArcSqlBpa.ps1)
to `C:\LabScripts` on `arcsql-host`. Run it in elevated Windows PowerShell
**on that host**, after the guest provisioning script has completed.
It is a standalone script; the older guest installer is not required.

Prerequisites:

- The explicitly selected guests are running, each with one adapter on
  `ArcSqlLabNAT`. Use their Hyper-V VM names, for example `arcsql-06` and
  `arcsql-07`; the Azure resource names will match.
- The default `MSSQLSERVER` service is running in each guest. SQL TCP/IP must be
  enabled and `NT AUTHORITY\SYSTEM` must be a SQL sysadmin. The guest credential
  must be a local Administrator with permission to query SQL.
- The guests share the supplied local Administrator credential. Run separate
  commands if their credentials differ. PowerShell Direct does not require
  opening WinRM ports.
- The existing workspace is in the target subscription. Use its full ARM
  resource ID, not its customer GUID. No workspace key is required.
- The host can reach Azure Resource Manager and authenticate to Microsoft Entra
  ID; the guests can download the Arc agent and reach the Arc/SQL/AMA endpoints.
  This script targets Azure public cloud with direct connectivity; it does not
  configure proxies, private-link networking, or sovereign-cloud endpoints.
- The service principal needs more than the onboarding role. Grant the
  [Arc BPA prerequisite roles](ENABLE-ARC-SQL-BPA.md#prerequisites) at the
  appropriate resource-group scopes, including permissions to deploy resources
  in the Arc group and create the table in the workspace group. For a dedicated
  lab, **Contributor on those two resource groups** (one assignment if they are
  the same group) covers the resource deployments. The identity must also be
  allowed to read subscription provider registration metadata and the built-in
  policy definition; grant the required read access if your RBAC restricts these.
  Do not grant subscription Owner. The script does not create role assignments
  or register providers.
- Confirm SQL licensing eligibility before running. **`-LicenseType Paid`**
  declares an eligible existing Software Assurance/subscription entitlement;
  **`-LicenseType PAYG`** opts into pay-as-you-go SQL billing. A Developer/Enterprise
  filename, VM name, or installed edition is not evidence of entitlement.
  If neither choice is valid for your lab, stop rather than misstate licensing.

Install the required host module once if it is missing:

```powershell
Install-Module Az.Accounts -Scope AllUsers -Repository PSGallery
```

Then run from the host:

```powershell
Set-Location 'C:\LabScripts'
.\Enable-HyperVGuestArcSqlBpa.ps1 `
    -VMName 'arcsql-06','arcsql-07' `
    -TenantId "<tenant-id>" `
    -SubscriptionId "<subscription-id>" `
    -ResourceGroupName "sql-bpa-lab-rg" `
    -Location "swedencentral" `
    -ServicePrincipalClientId "<service-principal-client-id>" `
    -WorkspaceResourceId "/subscriptions/<subscription-id>/resourceGroups/sql-bpa-lab-rg/providers/Microsoft.OperationalInsights/workspaces/sql-bpa-lab-law" `
    -LicenseType Paid
```

Replace the example IDs, groups, region, and licensing choice. The command
prompts for the **guest Administrator credential** and then the **service
principal secret** securely. Do not put either password in command history,
files, or transcripts. The Arc CLI briefly needs the decrypted service-principal
secret as a process argument inside the guest; run only on a trusted lab host.
Optional `-GuestCredential` and `-ServicePrincipalSecret` accept an existing
`PSCredential` and `SecureString`, respectively.

The script:

1. Validates host targets, Azure providers, workspace, and all guest identities
   before onboarding any selected guest.
2. Ensures the guest blocks outbound Azure IMDS, installs a Microsoft-signed
   Arc agent if needed, and connects it using the service principal.
3. Preserves matching existing Arc connections; refuses conflicting registrations
   or Azure resource names instead of disconnecting/overwriting another server.
4. Creates or updates `WindowsAgent.SqlServer`, preserving existing settings and
   applying the explicitly selected license type. Waits for SQL discovery using
   the exact parent Arc resource ID, not a name substring.
5. Deploys the template from Microsoft's
   [built-in SQL BPA policy](https://github.com/Azure/azure-policy/blob/master/built-in-policies/policyDefinitions/SQL%20Server/ArcEnabledSQLServer_EnableBestPracticesAssessment.json)
   **for each selected machine only**. It does not assign an Azure Policy or
   onboard every VM on the host. This deploys AMA, a workspace table, a DCR/DCE,
   an association, and the extension's assessment settings.
6. Waits for successful deployment and AMA provisioning, verifies BPA settings,
   and returns one result per completed guest. Failures stop the command with an
   error; open guest sessions are closed.

The Microsoft template controls the assessment schedule (currently weekly on
Sunday) and resource naming. It creates per-machine `sql-bpa-*` collection
resources rather than adopting an arbitrary Terraform DCR. Review existing
collection rules first to avoid duplicate ingestion, and review the table
schema if reusing a workspace that already contains `SqlAssessment_CL`.
This path provisions public collection endpoints; it does not set up private
monitoring connectivity or the separate performance-counter DCR.

### Resume and verify

After resolving a failure, rerun the same command with the same names, Azure
destination, and licensing choice. Matching agents are not reconnected or
reinstalled, existing SQL extension settings are preserved, and incremental
assessment deployment is retried. The built-in template reapplies its BPA
schedule. If agent installation requests a restart, restart only the affected
guest, then rerun. Do not delete the guests or disconnect working Arc agents.
`-TimeoutMinutes` defaults to 30 **per readiness/deployment stage**, not for the
whole batch.

If an older copy fails SQL discovery with `InvalidResourceType` for API version
`2023-03-15-preview`, replace the host script with the latest copy and rerun.
Discovery now uses the supported stable `2024-01-01` API. Preserve the existing
guest Arc registration and SQL extension; no disconnect or VM rebuild is needed.

Verify the Arc machine is connected and the SQL extension is healthy. Then use
[the detailed Arc BPA guide](ENABLE-ARC-SQL-BPA.md) to select the workspace,
confirm licensing eligibility and SQL permissions, enable BPA, and run an
assessment. Do not set `LicenseType = Paid` without confirming entitlement.
Migration readiness requires migration assessment data separately; BPA does
not generate it. Script success verifies configuration, not ingestion: wait for
the scheduled assessment or start one from the portal, then check workspace
results using section 5.

The older [Install-AzureArcAgent-SqlBPA.ps1](../hyper-v/Install-AzureArcAgent-SqlBPA.ps1)
is a guest-local script, not a host orchestrator. It currently has placeholder
REST authorization headers and must not be used as the reliable BPA path.

### Enable migration assessment on arcsql-01 through arcsql-08

Migration assessment is separate from BPA, free for all SQL editions, and does
not require selecting Paid/PAYG or a Log Analytics workspace. Copy
[Enable-HyperVGuestMigrationAssessment.ps1](../hyper-v/Enable-HyperVGuestMigrationAssessment.ps1)
to `C:\LabScripts` on the Azure Hyper-V host and run elevated there.

Prerequisites: the eight guests must be running, their Arc resources and SQL
instances must be in the specified resource group with matching VM/machine
names, and SQL extension `WindowsAgent.SqlServer` must be successfully provisioned
at version **1.1.2594.118 or later**. The script supports all SQL instances
discovered under each exact parent Arc machine. The supplied guest Administrator
credential must work on all selected guests; otherwise run separate batches
with `-VMName`. The SQL extension service account must have the
[documented SQL permissions](https://learn.microsoft.com/en-us/sql/sql-server/azure-arc/migration-assessment#permissions).

The host requires `Az.Accounts`. Use an existing `Connect-AzAccount` public-cloud
session, or pass tenant/application IDs to prompt for a service principal secret.
The Azure identity needs machine/extension/SQL instance read, SQL instance write,
and `Microsoft.AzureArcData/sqlServerInstances/runMigrationAssessment/action`
for immediate runs. Contributor at the dedicated resource group covers these;
the onboarding-only role is insufficient.

```powershell
Set-Location 'C:\LabScripts'
.\Enable-HyperVGuestMigrationAssessment.ps1 `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName 'sql-bpa-lab-rg' `
    -TenantId '<tenant-id>' `
    -ServicePrincipalClientId '<application-client-id>' `
    -CheckOnly
```

Default targets are `arcsql-01` through `arcsql-08`; use
`-VMName 'arcsql-06','arcsql-07','arcsql-08'` to narrow the batch. The script
prompts for the service principal secret and local guest Administrator credential
securely. After successful checks, rerun with **`-RunAssessment` instead of
`-CheckOnly`** to enable migration assessment and request an immediate run.
Omit both switches to enable scheduled assessment without triggering a run.

Checks run **inside each guest**: running SQL engine service, telemetry endpoint
DNS resolution, TCP 443, and a TLS 1.2 handshake with normal certificate and
revocation validation. The endpoint uses the actual Arc machine region:
`telemetry.<region>.arcdataservices.com`. This checks direct connectivity, not
an authenticated telemetry upload or the extension service's proxy settings.
Proxy-only/private-network environments require separate network configuration.
All selected guests must pass preflight before any instance is modified.

The script uses stable Arc SQL API **2026-01-01**, patches only
`properties.migration.assessment.enabled`, and preserves licensing, BPA, and
migration pricing/strategy settings. It verifies enablement and reports the
immediate run's returned status; `NotStarted`/`InProgress` means requested,
**not completed**. A failed action prints its ARM/job diagnostics instead of
the portal's generic error. Earlier successful changes are retained on failure;
rerun after fixing the error (explicit immediate runs may be requested again).
It does not install agents, upgrade extensions, grant permissions, or restart VMs.

Confirm completion under **SQL Server - Azure Arc > Migration > Assessments**.
Scheduled assessments normally run Sunday at 23:00 server-local time.
Report viewing requires the `getTelemetry` permission described in
[Microsoft's migration assessment guide](https://learn.microsoft.com/en-us/sql/sql-server/azure-arc/migration-assessment).

## 3. Enable SQL IaaS management on Azure VMs

Terraform manages the lab VMs'
SQL IaaS resources, BPA schedule (Sunday 09:00 UTC), AMA, custom table, and
DCR/DCE associations. Use the queries in section 5 to verify data and the
on-demand command below to test a run. Do not manage their schedule through
both Terraform and PowerShell.

See [the Azure lab guide](AZURE-TERRAFORM-LAB.md) for deployment and importing
existing SQL VM resources. For VMs outside this lab, use
[Microsoft's SQL VM assessment instructions](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/sql-assessment-for-sql-vm)
or extend your own Terraform configuration; there is no separate IaaS
enablement script in this repository.

For an initial run:

```powershell
az sql vm start-assessment -g $resourceGroup -n "sql-bpa-01"
```

Repeat for other VMs and confirm successful completion in the portal.

### Native Azure VM modernization versus Arc assessment

The workbook's **Migration Assessment** tab reads actual uploaded assessment
results from AzureArcData. Native Azure VM BPA/inventory/Modernization Advisor
proxy sections and their queries, selectors, and merge have been removed:
inventory and successful BPA runs do not answer whether a workload can migrate
to Azure SQL Database or Managed Instance. BPA results remain in the
**BPA Enterprise Dashboard**.

Do not treat these signals as interchangeable:

| Signal | Source | Meaning |
|---|---|---|
| BPA enablement/schedule | SQL VM `properties.assessmentSettings.enable` and `schedule.enable` | Declared configuration, not proof of guest execution or migration compatibility |
| BPA runs and findings | Log Analytics `SqlAssessment_CL` in the BPA tab | Retained results can remain after BPA settings change |
| Unified inventory | AzureArcData instance `containerResourceId` matched to the Compute VM ID | Discovered instances, not proof of assessment capability or completion |
| Migration upload coverage | `properties.migration.assessment.assessmentUploadTime` | A reported upload, not a successful compatibility result or the Modernization Advisor comparison |
| Modernization Advisor (preview) | SQL VM portal comparison | VM configuration/operational telemetry compared with Managed Instance; not Arc's SQL database compatibility assessment |
| Arc migration assessment | AzureArcData migration assessment results | Instance/database readiness, blockers, and performance-based target sizing |

[Modernization Advisor](https://learn.microsoft.com/azure/azure-sql/virtual-machines/modernization-advisor)
uses vCores, memory per vCore, storage size, and storage type to identify a suitable
Managed Instance configuration and cost benefits. It requires SQL IaaS Agent
registration, not BPA or Connected Machine agent installation. The public
documentation does not identify a results API/Resource Graph field for this
preview comparison. View it under **SQL virtual machine > Settings >
Modernization Advisor (preview) > Compare**; it is not the Arc compatibility
assessment and is not ingested by this workbook.

For an actual SQL Database / Managed Instance compatibility assessment of a
non-Arc SQL instance, use the
[SSMS migration component](https://learn.microsoft.com/ssms/migrate/migrate-sql-server-azure-sql):

1. Install SSMS 22 or later with the **Hybrid and Migration** workload.
2. Connect to the source SQL instance on the Azure VM.
3. Right-click the instance in Object Explorer and select **Migrate SQL Server**.
4. Select **Run Assessment**, then open the generated HTML report.
5. Review readiness, compatibility findings, affected objects, and available
   target/sizing/cost recommendations for Azure SQL Database, Managed Instance,
   and SQL Server on Azure VMs.

Follow the linked assessment-only permission requirements; do not assume the
migration workflow's sysadmin requirement applies to every assessment operation.
SSMS uses Arc's precomputed assessment when the instance is Arc-enabled; otherwise
it runs an assessment. A generated HTML report is not an automatically exposed
ARG dataset. Integrating such results into the workbook requires a separately
verified machine-readable output contract and explicit collection pipeline;
this repository does not currently implement that ingestion.

If the portal says BPA is disabled despite previous runs, compare the SQL VM
resource's assessment settings with your intended configuration. Historical
findings alone cannot distinguish current enablement from retained results.
For Terraform-managed VMs, review a scoped plan for configuration drift rather
than immediately applying the entire lab or managing the same settings through
two tools. Missing migration data must not be interpreted as a queued assessment
or a requirement to install Arc on a native Azure VM.

### Azure Advisor tab

The **Azure Advisor** workbook tab is independent of these collection rules.
It reads `advisorresources` and SQL host inventory from Azure Resource Graph in
the selected subscriptions and resource groups. Use an identity with read access
to those resources and Advisor recommendations. It needs no assessment run or
Log Analytics workspace. Totals and category/impact/coverage pie charts cover
the selected estate; selecting a machine restricts only the recommendation list.
Use **Show recommendations for all SQL hosts** to reset.

Hosts come from SQL VM registrations, SQL instance container IDs, or Arc SQL
discovery. Physical host and SQL resource aliases are normalized and deduplicated
before matching Advisor targets; recommendation IDs are deduplicated per host.
The list includes problem, suggested action, category, impact, returned state,
update time, affected resource, and a resource link. Category `HighAvailability`
is labelled **Reliability**. Advisor only shows published recommendations; an
empty list is not proof of health or a migration assessment. Attached disk/network
recommendations and subscription/resource-group recommendations are not mapped
to individual hosts by this tab.

## 4. Create and associate data collection rules

### Azure Updates tab prerequisites

The **Azure Updates** tab reads Azure Update Manager assessment data directly
from Resource Graph, independently of AMA/DCRs and Log Analytics. Run or enable
assessment for the Arc SQL hosts and native Azure SQL VMs in **Azure Update
Manager**; importing the workbook does not enable assessment or install patches.
Use read permissions for the machine inventory and patch assessment resources.
See [Update Manager query data](https://learn.microsoft.com/azure/update-manager/query-logs).

The tab includes:

- Estate totals for SQL hosts, assessment coverage, returned missing patches,
  Critical/Security patch records, reported pending reboots, and truncated detail.
- Pie charts for assessment freshness/coverage, primary patch classification,
  and latest reported reboot status.
- Every SQL host, including those with no assessment or an unsuccessful one.
- An estate patch catalogue with affected-machine totals and a selectable
  machine-level missing-patch list. **Show missing patches for all SQL hosts**
  resets the detail selection without changing the estate charts.

Fresh means a successful assessment updated within 24 hours. Stale results are
not discarded or represented as current compliance. Resource Graph retains
assessment results for about seven days, unlike installation history (30 days).
The query correlates summary and patch rows by full host/assessment resource IDs
and requires each patch timestamp to fall within the selected latest assessment
window. It does not reuse older patch rows after a newer/failed assessment.

Totals count returned patch records per host, not unique KB numbers across the
estate. A patch with multiple classifications is assigned once, preferring
Critical then Security then its first classification; details show all reported
classifications. Missing/failed assessments, unknown timestamps, incomplete
detail ingestion, and zero returned patches do not establish that a machine is
fully patched. The machine list exposes summary classification counts/errors.
If **Hosts With Truncated Details** is nonzero, patch totals are incomplete;
the query explicitly reports expansion/aggregation truncation rather than
silently treating capped results as complete.

SQL updates appear only when the OS update source (Microsoft Update, WSUS,
or Linux package manager) reports them. This is not a full SQL CU/release/EOS
catalogue and does not replace SQL-specific servicing checks.

### Collection resources in this repository

| Resource | Purpose |
|---|---|
| `<prefix>-dce` | Shared data collection endpoint |
| `<prefix>-bpa-dcr` | Collects assessment CSV files into `SqlAssessment_CL` as text records |
| `<prefix>-sql-perfcounters-dcr` | Collects Windows/SQL counters every 60 seconds into `Perf` |

These are defined in [bpa-assessment-dcr.tf](../terraform/bpa-assessment-dcr.tf)
and [performance-counters-dcr.tf](../terraform/performance-counters-dcr.tf).
The Terraform lab creates them and associates both DCRs plus the DCE with its
five Azure VMs. It does **not** create Arc machine associations.

For a deployment without Terraform, create the equivalent rules in Azure
Monitor's **Data Collection Rules** experience using those files as the source
for counter paths, sampling interval, CSV file paths, destination, and stream
schema. Do not apply the entire Terraform lab merely to create monitoring
resources if you do not want its five Azure VMs.

The assessment rule uses both IaaS Agent and SQL Extension Agent assessment
directories. Its output stream is `Custom-SqlAssessment_CL`, with
`TimeGenerated` and `RawData` declared on the input stream. Confirm the
destination table exists with a compatible schema before deployment/ingestion.
The Terraform lab creates this table through AzAPI; for a non-Terraform setup,
use the assessment-managed setup or configure a compatible custom text table
through Log Analytics.

### Assessment-managed rules versus custom rules

Enabling assessment can create/reuse `sqlbpa-*` rules and endpoints. Selecting
an existing workspace does not automatically make assessment adopt the
Terraform-named custom DCR. Choose one intentional assessment collection path,
verify its destination/schema, and avoid overlapping CSV collection that
duplicates ingestion.

See [Arc DCR reuse](ENABLE-ARC-SQL-BPA.md) and
[DCR/DCE migration](DCR-DCE-MIGRATION.md) before changing an existing pipeline.
Use explicit `terraform import` commands with verified resource IDs.
Importing does not reconcile configuration; review
the next plan for replacements and import existing associations where needed.

### Install AMA and associate Arc machines

Verify **AzureMonitorWindowsAgent** is installed and healthy on every machine.
Assessment enablement may install/configure AMA, but the performance DCR still
needs association. The Terraform lab explicitly deploys AMA on its Azure VMs; Arc machines still
need separate installation and associations.

For an Arc guest using the repository's custom collection rules, run from the
authenticated workstation after verifying the rule IDs:

```powershell
$machineName = "arc-sql-01"
$machineId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.HybridCompute/machines/$machineName"
$bpaDcrId = az monitor data-collection rule show `
    -g $resourceGroup -n "sql-bpa-lab-bpa-dcr" --query id -o tsv
$perfDcrId = az monitor data-collection rule show `
    -g $resourceGroup -n "sql-bpa-lab-sql-perfcounters-dcr" --query id -o tsv
$dceId = az monitor data-collection endpoint show `
    -g $resourceGroup -n "sql-bpa-lab-dce" --query id -o tsv

az connectedmachine extension create `
    --machine-name $machineName --resource-group $resourceGroup `
    --name AzureMonitorWindowsAgent --publisher Microsoft.Azure.Monitor `
    --type AzureMonitorWindowsAgent --location $location `
    --enable-auto-upgrade true

az monitor data-collection rule association create `
    --name "arc-bpa-dcr-$machineName" --resource $machineId --rule-id $bpaDcrId
az monitor data-collection rule association create `
    --name "arc-perf-dcr-$machineName" --resource $machineId --rule-id $perfDcrId
az monitor data-collection rule association create `
    --name configurationAccessEndpoint --resource $machineId --endpoint-id $dceId
```

Substitute your prefix and repeat per machine. Stop if ID lookups or extension
installation fail. If using assessment-managed collection, retain its working
BPA/DCE configuration rather than blindly replacing it with these examples;
only add the required performance collection.

For an Azure VM missing AMA, install it with the VM's system-assigned identity:

```powershell
az vm extension set -g $resourceGroup --vm-name "sql-bpa-01" `
    --name AzureMonitorWindowsAgent --publisher Microsoft.Azure.Monitor `
    --enable-auto-upgrade true
```

Ensure non-Terraform Azure VMs also have the required DCR/DCE associations,
using their `Microsoft.Compute/virtualMachines` resource IDs.
The SQL counter paths assume a default instance; adapt them for named instances.

## 5. Verify the pipeline before importing the workbook

In the destination workspace's **Logs**, run these queries separately:

```kql
Heartbeat
| where TimeGenerated > ago(1h)
| summarize LastSeen = max(TimeGenerated) by Computer, _ResourceId
```

```kql
Perf
| where TimeGenerated > ago(1h)
| summarize Samples = count(), LastSeen = max(TimeGenerated)
    by Computer, ObjectName, CounterName
```

```kql
SqlAssessment_CL
| where TimeGenerated > ago(24h)
| project TimeGenerated, _ResourceId, RawData
| take 20
```

Allow time for assessment completion and ingestion. Confirm the assessment
records contain CSV data and a machine `_ResourceId`. A missing table is not
the same as an assessment with no findings. Check extension health, CSV output,
DCR associations, endpoint configuration, table schema, and outbound connectivity.
Do not treat a successful script exit as proof that data is arriving.

Import [the primary workbook](../README.md#import-the-workbook). Test inventory,
CPU/disk row selection, BPA findings, and migration readiness independently.
Empty readiness panels require checking Arc migration assessment status, not
changing the BPA DCR.

## 6. Create alerts

**Terraform lab:** set `alert_email_address` in your local variable file and
apply Terraform. It creates the email action group and all 22 alert definitions,
with the 7-day stale-assessment rule intentionally disabled. Existing script-created alerts and the
action group must first be imported; see
[Terraform deployment](CREATING-ALERTS.md#terraform-deployment).

Review thresholds against the actual workload and confirm delivery with an
action-group test. See [the alert reference](CREATING-ALERTS.md) for rule details
and troubleshooting. Azure Monitor alerting can incur additional charges.

Terraform removes managed alerts during destroy. Arc associations and other
resources created outside Terraform still need separate cleanup.
