# Enable SQL Best Practices Assessment on an Arc-enabled SQL Server (Reusing an Existing Log Analytics Workspace & DCR)

This guide walks through connecting a SQL Server machine to **Azure Arc** and enabling the
**SQL best practices assessment** feature, while **reusing** a Log Analytics workspace (LAW)
and Data Collection Rule (DCR) you already have.

> **Read this first — how DCR "reuse" actually works**
>
> The best practices assessment feature **manages its own DCR/DCE**. When you enable it against a
> Log Analytics workspace, Azure creates (or reuses) a DCR and DCE named with a
> `sqlbpa-` prefix in the **resource group of that workspace**. It does **not** adopt an
> arbitrary custom-named DCR (for example a Terraform-created `myprefix-bpa-dcr`).
>
> Practically, this means:
> - **Log Analytics workspace** — fully reusable. Just select your existing workspace when enabling.
> - **DCR/DCE** — reusable only when it is the assessment-managed `sqlbpa-*` DCR. Point every
>   Arc SQL Server at the **same workspace** and Azure reuses the **same** `sqlbpa-*` DCR/DCE for all of them.
>
> See [Options for reusing your existing DCR](#step-5--reuse-your-existing-dcr) below for the
> supported patterns (shared reuse, import into IaC, or manual re-pointing).

---

## Prerequisites

Reference: [Configure best practices assessment for SQL Server enabled by Azure Arc — Prerequisites](https://learn.microsoft.com/sql/sql-server/azure-arc/assess?view=sql-server-ver17#prerequisites)

- **OS:** SQL Server running on **Windows** (assessment is not available for SQL Server on Linux).
- **Local admin** rights on the target machine, and outbound **HTTPS (TCP 443)** connectivity.
- **Azure extension for SQL Server** (`WindowsAgent.SqlServer`) version:
  - `1.1.2202.47` or later for a single instance, or
  - later than `1.1.2231.59` if multiple SQL Server instances are on the machine.
  See [Upgrade extensions](https://learn.microsoft.com/azure/azure-arc/servers/manage-vm-extensions-portal#upgrade-extensions).
- **Named instances:** the [SQL Server Browser service](https://learn.microsoft.com/sql/database-engine/configure-windows/sql-server-browser-service-database-engine-and-ssas?view=sql-server-ver17) must be running.
- **TCP/IP** must be [enabled](https://learn.microsoft.com/sql/database-engine/configure-windows/enable-or-disable-a-server-network-protocol?view=sql-server-ver17) for the SQL Server instance.
- **Existing Log Analytics workspace** must be **in the same subscription** as the Arc-enabled SQL Server resource.
- The SQL Server built-in login **`NT AUTHORITY\SYSTEM`** must be a member of the **`sysadmin`** server role on every instance.
- **License type:** must be **Software Assurance (Paid)** or **pay-as-you-go** (not *License only*).
- **Permissions** for the user enabling assessment:
  - **Log Analytics Contributor** on the workspace's resource group/subscription.
  - **Azure Connected Machine Resource Administrator** on the Arc SQL Server's resource group/subscription.
  - **Monitoring Contributor** on both the workspace and the Arc machine resource group/subscription.
  - (Built-in **Contributor** or **Owner** also satisfies the above.)
- If a firewall/proxy restricts outbound traffic, allow these endpoints over TCP 443:
  - `global.handler.control.monitor.azure.com`
  - `*.handler.control.monitor.azure.com`
  - `<log-analytics-workspace-id>.ods.opinsights.azure.com`
  - `*.ingest.monitor.azure.com`

---

## Step 1 — Connect the SQL Server machine to Azure Arc

Azure Arc automatically installs the **Azure extension for SQL Server** whenever an Arc-connected
machine has SQL Server installed, and projects each instance as a `SQL Server - Azure Arc` resource.

Reference: [Connect your SQL Server to Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/connect?view=sql-server-ver17)
· [Automatically connect your SQL Server to Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/automatically-connect?view=sql-server-ver17)

### Option A — Portal-generated onboarding script (recommended for a single server)

1. In the [Azure portal](https://portal.azure.com/), go to **Azure Arc** > **SQL Server instances** (under **Data services**) and select **+ Add**.
2. Select **Connect SQL Server instances** and select **Next: Server details**.
3. Specify **Subscription**, **Resource group**, **Region**, **Operating system**, and (if needed) proxy.
   > If the machine is **already Arc-connected**, choose the **same resource group** that contains its existing **Server - Azure Arc** resource.
4. Choose the SQL Server **edition** and **license type** (must be *Paid*/PAYG for assessment).
5. Select **Run script**, then **Download** the generated `RegisterSqlServerArc.ps1`.
6. On the **target machine**, open an elevated PowerShell, sign in with `Connect-AzAccount`, and run:

   ```powershell
   & '.\RegisterSqlServerArc.ps1'
   ```

### Option B — Unattended install with the Connected Machine Agent (scripted)

For guests on the Azure Hyper-V lab host, use
[Enable-HyperVGuestArcSqlBpa.ps1](../hyper-v/Enable-HyperVGuestArcSqlBpa.ps1)
**on the host** with explicit guest names. It installs/connects the agent inside
each guest through PowerShell Direct and configures SQL BPA using Microsoft's
built-in deployment template. See the
[host-run workflow and permissions](MONITORING-SETUP.md#onboard-from-the-azure-hyper-v-host).
It requires an explicit eligible license type and does not change the outer
Azure VM into an Arc server.

For reference, the core guest-local agent commands are (see
[Connect hybrid machines using PowerShell](https://learn.microsoft.com/azure/azure-arc/servers/onboard-powershell)):

```powershell
# Download & install the agent
Invoke-WebRequest -Uri 'https://aka.ms/AzureConnectedMachineAgent' -OutFile "$env:TEMP\AzureConnectedMachineAgent.msi" -UseBasicParsing
msiexec /i "$env:TEMP\AzureConnectedMachineAgent.msi" /qn ACCEPTEULA=1

# Connect the machine to Azure Arc
& "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe" connect `
    --tenant-id       "<tenantId>" `
    --subscription-id "<subscriptionId>" `
    --resource-group  "<resourceGroup>" `
    --location        "<region>" `
    --resource-name   "<machineName>"
```

For onboarding many servers, use [Connect at scale](https://learn.microsoft.com/sql/sql-server/azure-arc/connect-at-scale?view=sql-server-ver17).

---

## Step 2 — Verify the Azure extension for SQL Server

Arc deploys `WindowsAgent.SqlServer` automatically. Confirm it is present and at a supported version.

Reference: [Upgrade extensions](https://learn.microsoft.com/azure/azure-arc/servers/manage-vm-extensions-portal#upgrade-extensions)

```powershell
Get-AzConnectedMachineExtension `
    -ResourceGroupName "<resourceGroup>" `
    -MachineName       "<machineName>" `
    -Name              "WindowsAgent.SqlServer" |
    Select-Object Name, ProvisioningState, TypeHandlerVersion
```

- `ProvisioningState` should be **`Succeeded`**.
- If the version is below the minimum in [Prerequisites](#prerequisites), upgrade it (Portal:
  **Machine - Azure Arc** > **Extensions** > check `WindowsAgent.SqlServer` > **Update**).

---

## Step 3 — (Recommended) Pre-verify your existing Log Analytics workspace

The assessment DCR/DCE are created in the **resource group of the workspace**, and they must be in the
**same region** as the workspace. Confirm the workspace exists, is in the target subscription, and note its
resource group and location.

```powershell
Get-AzOperationalInsightsWorkspace `
    -ResourceGroupName "<workspaceResourceGroup>" `
    -Name              "<workspaceName>" |
    Select-Object Name, Location, ResourceGroupName, CustomerId
```

> **Known issue:** the workspace **location must not contain white spaces**, or enablement fails preflight
> validation. See [Known issues](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/sql-assessment-for-sql-vm?view=azuresql#known-issues).

---

## Step 4 — Enable best practices assessment (select your existing workspace)

Reference: [Enable best practices assessment](https://learn.microsoft.com/sql/sql-server/azure-arc/assess?view=sql-server-ver17#enable-best-practices-assessment)

1. In the [Azure portal](https://portal.azure.com/), open your **SQL Server - Azure Arc** resource.
2. On the left pane, select **Best practices assessment** (or **Overview** > **Capabilities** tab > **Best practices assessment**).
3. In the **Log Analytics Workspace** dropdown, **select your existing workspace**.
4. Select **Enable assessment**. Setup takes a few minutes; the Azure Monitor Agent (AMA) is installed if not already present.
5. Confirm the feature shows as enabled. By default the assessment runs **every Sunday at 12:00 AM** (VM-local time). Adjust via **Configuration** > **Schedule assessment**.

### Enable at scale (many servers) — Azure Policy

To enable across many Arc SQL Servers pointed at the **same** workspace (which also drives DCR reuse),
assign the built-in policy **"Configure Arc-enabled Servers with SQL Server extension installed to enable
or disable SQL best practices assessment"**.

Reference: [Enable at scale by using Azure Policy](https://learn.microsoft.com/sql/sql-server/azure-arc/assess?view=sql-server-ver17#enable-best-practices-assessment-at-scale-by-using-azure-policy)

```powershell
$rg = Get-AzResourceGroup -Name "<ResourceGroupName>"
$policyDefinition = Get-AzPolicyDefinition |
  Where-Object { $_.Properties.DisplayName -eq 'Configure Arc-enabled Servers with SQL Server extension installed to enable or disable SQL best practices assessment.' }

$policyParameterObj = @{
    "effect"              = "DeployIfNotExists"
    "laWorkspaceId"       = "<Log Analytics Workspace Resource ID>"
    "laWorkspaceLocation" = "<Log Analytics Workspace Location>"
    "isEnabled"           = $true
}

New-AzPolicyAssignment -Name "SQLBestPracticesAssessmentAssignment" `
    -DisplayName "Configure Arc-enabled Servers ... SQL best practices assessment." `
    -PolicyDefinition $policyDefinition `
    -Scope $rg.ResourceId `
    -PolicyParameterObject $policyParameterObj `
    -IdentityType 'SystemAssigned' `
    -Location $rg.Location
```

> If the workspace is in a **different resource group** than the SQL Server resource, the policy scope
> must be the **whole subscription**.

---

## Step 5 — Reuse your existing DCR

Because the feature owns the `sqlbpa-*` DCR/DCE, choose the option that matches your goal:

### Option 1 — Shared reuse across servers (fully supported, simplest)

Enable assessment on the first Arc SQL Server against your workspace. Azure creates one `sqlbpa-*`
DCR + DCE in the workspace's resource group. For **every other** Arc SQL Server, enable assessment
against the **same workspace** — Azure **reuses the same** `sqlbpa-*` DCR/DCE and simply adds the new
machine to the DCR's **Resources** list. This is the intended "one DCR, many servers" model.

### Option 2 — Bring the auto-created DCR under IaC (import)

If your goal is version control, let the feature create the `sqlbpa-*` DCR once, then **import** it into
Terraform/Bicep rather than pre-creating a custom-named DCR (which the feature will not adopt).
[DCR/DCE migration](DCR-DCE-MIGRATION.md) describes explicit Terraform imports.

```powershell
# Example: import the assessment-created DCR into Terraform state
terraform import azurerm_monitor_data_collection_rule.bpa_assessment `
  "/subscriptions/<subId>/resourceGroups/<workspaceRg>/providers/Microsoft.Insights/dataCollectionRules/<sqlbpa-dcr-name>"
```

### Option 3 — Manually re-point to a self-managed DCR (advanced, portal status caveat)

Any DCR associated with the machine that has a **Custom Text Logs** data source watching the assessment
CSV path and writing to the `SqlAssessment_CL` table will ingest the data. **However**, the portal
**Best practices assessment** blade reads status from the specifically named assessment DCR/association,
so after re-pointing the portal may show the feature as *not enabled* even though data still flows to the
workspace. Only use this if you don't depend on the portal blade for status.

Required DCR data source configuration (see verification below):

- **Table:** `SqlAssessment_CL`
- **Log path (Arc):** `C:\Windows\System32\config\systemprofile\AppData\Local\Microsoft SQL Server Extension Agent\Assessment\*.csv`

---

## Step 6 — Verify the DCR configuration

Reference: [Troubleshoot best practices assessment — Assessment run failed](https://learn.microsoft.com/sql/sql-server/azure-arc/troubleshoot-assessment?view=sql-server-ver17#assessment-run-failed)

In the workspace's resource group, open the `sqlbpa-*` **DCR** and confirm:

1. **Resources** tab — your Arc machine name is listed.
2. **Data Sources** tab > **Custom Text Logs**:
   - Table name is **`SqlAssessment_CL`**.
   - Log collection path is
     `C:\Windows\System32\config\systemprofile\AppData\Local\Microsoft SQL Server Extension Agent\Assessment\*.csv`.
3. **Destination** tab — your Log Analytics workspace is listed.
4. The **DCR and DCE are in the same region** as the workspace.

If any component is missing: **Configuration** > **Disable assessment**, confirm permissions, then
**Enable assessment** again.

---

## Step 7 — Run the assessment and view results

Reference: [Manage best practices assessment](https://learn.microsoft.com/sql/sql-server/azure-arc/assess?view=sql-server-ver17#manage-best-practices-assessment)

1. On the **Best practices assessment** pane, select **Run assessment** to run on demand.
2. After the run, select **View assessment results**. Results can take **up to two hours** to appear in
   the workspace after the data files are processed on the machine.
3. Explore results by severity (**High/Medium/Low/Information**), export to Excel, or open in Logs.

You can also query the workspace directly:

```kusto
SqlAssessment_CL
| order by TimeGenerated desc
```

---

## Troubleshooting quick reference

| Symptom | Likely cause / fix |
| --- | --- |
| Portal shows assessment **not enabled** after automation/policy | DCR / association name must follow the case-sensitive convention the feature expects. Re-enable from the portal, or don't re-point to a custom DCR (see Step 5, Option 3). |
| **Preflight validation failed** | Workspace **location contains white spaces** — recreate the workspace in a region without spaces. |
| **Assessment run failed** | Verify DCR data source path, table `SqlAssessment_CL`, destination workspace, and that DCR/DCE region matches the workspace (Step 6). |
| **View results** greyed out | Results can take up to 2 hours to land in the workspace after processing. |
| Can't change workspace later | Once linked, the workspace can't be changed from the SQL VM/Arc resource; disconnect via the Log Analytics tab first. |

Full guide: [Troubleshoot best practices assessment on SQL Server](https://learn.microsoft.com/sql/sql-server/azure-arc/troubleshoot-assessment?view=sql-server-ver17)

---

## Microsoft Learn references

- [Connect your SQL Server to Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/connect?view=sql-server-ver17)
- [Automatically connect your SQL Server to Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/automatically-connect?view=sql-server-ver17)
- [Connect SQL Server to Azure Arc at scale](https://learn.microsoft.com/sql/sql-server/azure-arc/connect-at-scale?view=sql-server-ver17)
- [Connect hybrid machines using PowerShell (Connected Machine agent)](https://learn.microsoft.com/azure/azure-arc/servers/onboard-powershell)
- [Configure best practices assessment for SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/assess?view=sql-server-ver17)
- [Troubleshoot best practices assessment on SQL Server](https://learn.microsoft.com/sql/sql-server/azure-arc/troubleshoot-assessment?view=sql-server-ver17)
- [Manage Azure Arc VM extensions (upgrade)](https://learn.microsoft.com/azure/azure-arc/servers/manage-vm-extensions-portal#upgrade-extensions)
- [Data collection rule overview](https://learn.microsoft.com/azure/azure-monitor/essentials/data-collection-rule-overview)
- [Best practices for data collection rule creation and management](https://learn.microsoft.com/azure/azure-monitor/data-collection/data-collection-rule-best-practices)
- [Create a Log Analytics workspace](https://learn.microsoft.com/azure/azure-monitor/logs/quick-create-workspace)

## Related files in this repo

- [Install-AzureArcAgent-SqlBPA.ps1](../Install-AzureArcAgent-SqlBPA.ps1) — scripted Arc onboarding + BPA enablement
- [docs/DCR-DCE-MIGRATION.md](DCR-DCE-MIGRATION.md) — DCR/DCE migration to IaC
