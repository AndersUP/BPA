# BPA Configuration Validation Guide

This document explains how to verify that SQL Best Practice Assessment is correctly configured and producing results.

---

## What "Correctly Configured" Means

A SQL Server is correctly configured for BPA when ALL of the following are true:

1. **Agent installed**: SQL IaaS Extension (Azure VMs) or Azure Arc + SQL Arc Extension (on-premises/multi-cloud).
2. **Assessment enabled**: The BPA assessment feature is turned on.
3. **Log Analytics linked**: A Log Analytics workspace is associated for result storage.
4. **DCR/DCE associations in place**: Data Collection Rule and Endpoint are associated with the machine.
5. **AMA installed**: Azure Monitor Agent is present and healthy.
6. **Assessment has run**: At least one assessment has completed successfully.
7. **Results are flowing**: Data appears in the `SqlAssessment_CL` and/or `SQLAssessmentRecommendation` tables.

---

## Step-by-Step Validation

### Step 1: Check BPA Is Enabled

**For Azure VMs**:
```powershell
az sql vm show --resource-group <rg> --name <vm-name> --query "assessmentSettings" -o json
```

Expected output should show:
```json
{
  "enable": true,
  "runImmediately": false,
  "schedule": {
    "dayOfWeek": "Sunday",
    "enable": true,
    "startTime": "09:00",
    "weeklyInterval": 1
  }
}
```

**If `enable` is `false` or `assessmentSettings` is null**:
```powershell
terraform -chdir=terraform plan
terraform -chdir=terraform apply
```

**For Arc-enabled SQL Servers**:
```powershell
# Check via the Arc SQL Server resource
az resource show --ids "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.HybridCompute/machines/<machine>/providers/Microsoft.AzureArcData/sqlServerInstances/MSSQLSERVER" --query "properties.settings.assessmentSettings" -o json
```

### Step 2: Check Log Analytics Workspace Linkage

```powershell
# Verify the workspace exists and is accessible
az monitor log-analytics workspace show --resource-group <rg> --workspace-name <workspace-name> --query "{name:name, retentionDays:retentionInDays, sku:sku.name}" -o table
```

### Step 3: Verify DCR Configuration

```powershell
# Show the BPA DCR details
az monitor data-collection rule show --resource-group <rg> --name "<prefix>-bpa-dcr" --query "{name:name, filePatterns:dataSources.logFiles[0].filePatterns, destinations:destinations.logAnalytics[0].workspaceResourceId}" -o json
```

**Critical check**: Ensure `filePatterns` includes BOTH paths:
- `C:\Windows\System32\config\systemprofile\AppData\Local\Microsoft SQL Server IaaS Agent\Assessment\*.csv`
- `C:\Windows\System32\config\systemprofile\AppData\Local\Microsoft SQL Server Extension Agent\Assessment\*.csv`

If either path is missing, the DCR will not collect assessment results from that agent type.

### Step 4: Check Assessment Results in Log Analytics

```kql
-- Check if BPA results are flowing (run in Log Analytics)
SqlAssessment_CL
| where TimeGenerated > ago(7d)
| summarize Count=count(), LastSeen=max(TimeGenerated) by Computer=tostring(split(RawData, ",")[0])
| order by LastSeen desc
```

```kql
-- Alternative: check the built-in table
SQLAssessmentRecommendation
| where TimeGenerated > ago(7d)
| summarize Count=count(), LastSeen=max(TimeGenerated) by Computer
| order by LastSeen desc
```

**If no results**: The assessment may not have run yet, or the DCR is not correctly associated.

### Step 5: Trigger an On-Demand Assessment

**For Azure VMs**:
```powershell
# Trigger immediate assessment
az sql vm update --resource-group <rg> --name <vm-name> --assessment-settings-run-immediately true
```

**For Arc SQL Servers**: Assessment is triggered via the Azure portal under the Arc SQL Server resource > SQL best practices assessment > Run assessment.

### Step 6: Check Assessment Run Status

Assessment results typically take 15-30 minutes to appear in Log Analytics after a run completes. Check the local CSV files on the VM to verify the assessment ran:

```powershell
# RDP or run via CustomScriptExtension
# Check IaaS Agent path
Get-ChildItem "C:\Windows\System32\config\systemprofile\AppData\Local\Microsoft SQL Server IaaS Agent\Assessment\*.csv" -ErrorAction SilentlyContinue

# Check Extension Agent path (Arc)
Get-ChildItem "C:\Windows\System32\config\systemprofile\AppData\Local\Microsoft SQL Server Extension Agent\Assessment\*.csv" -ErrorAction SilentlyContinue
```

---

## Common Misconfiguration Scenarios

### Scenario 1: BPA enabled but no results in Log Analytics

**Root cause**: DCR association is missing or AMA is not installed.

**Fix**:
1. Verify DCR association exists (see Agent Verification Checklist).
2. Verify AMA is installed and healthy.
3. Verify the DCR `filePatterns` match the correct CSV path for the agent type.

### Scenario 2: Assessment runs but results are incomplete

**Root cause**: SQL service account lacks sysadmin permissions.

**Fix**: Add the SQL service account to the sysadmin role:
```sql
ALTER SERVER ROLE [sysadmin] ADD MEMBER [NT Service\MSSQLSERVER];
```

### Scenario 3: Old DCR associations blocking Terraform

**Root cause**: Previously auto-created DCRs conflict with Terraform-managed ones.

**Fix**: Run `Remove-OldDcrAssociations.ps1` to clean up legacy associations, then run `terraform apply`.

### Scenario 4: Arc SQL Extension not appearing

**Root cause**: SQL Server service not running, or Arc agent not fully connected.

**Fix**:
1. Verify SQL Server service is running: `Get-Service MSSQLSERVER`
2. Verify Arc agent: `azcmagent show` – status must be `Connected`
3. Wait 15 minutes for auto-provisioning
4. Check Arc agent logs: `C:\ProgramData\AzureConnectedMachineAgent\Log\azcmagent.log`

### Scenario 5: Performance counters not collecting

**Root cause**: Performance counter DCR not associated with the VM.

**Fix**: Verify the perf DCR association exists. For Azure VMs, Terraform manages this. For Arc machines, create the association:
```powershell
az monitor data-collection rule association create --name "<machine>-perf-dcr-association" --resource "<machine-resource-id>" --rule-id "<perf-dcr-resource-id>"
```

---

## Resource Provider Registration

The following resource providers must be registered in the subscription:

| Provider | Required For |
|----------|-------------|
| `Microsoft.SqlVirtualMachine` | SQL IaaS Extension on Azure VMs |
| `Microsoft.HybridCompute` | Azure Arc connected machines |
| `Microsoft.GuestConfiguration` | Azure Arc guest configuration |
| `Microsoft.AzureArcData` | Arc-enabled SQL Server |
| `Microsoft.OperationalInsights` | Log Analytics workspaces |
| `Microsoft.Insights` | Data Collection Rules and Endpoints |

**Verify registration**:
```powershell
az provider show --namespace Microsoft.SqlVirtualMachine --query "registrationState" -o tsv
az provider show --namespace Microsoft.HybridCompute --query "registrationState" -o tsv
az provider show --namespace Microsoft.Insights --query "registrationState" -o tsv
```
