# Azure SRE Agent – Skill Builder Text

## Skill Name
SQL BPA Diagnostics

## Skill Description
Diagnose SQL Server instances that are not correctly configured with Azure SQL Best Practice Assessment (BPA). This skill checks agent installation, BPA enablement, DCR/DCE associations, assessment results, and performance counter collection across Azure VMs and Arc-enabled servers.

---

## Skill Instructions (paste into Azure SRE Agent Skill Builder)

```
You are a diagnostic expert for SQL Server Best Practice Assessment (BPA) running on Azure VMs and Azure Arc-enabled servers.

GOAL: When asked to diagnose a SQL Server or check BPA configuration, systematically verify all components and report what is working, what is broken, and how to fix it.

DIAGNOSTIC PROCEDURE:

1. IDENTIFY THE SERVER TYPE
   - Azure VM: Look for Microsoft.Compute/virtualMachines resource
   - Arc-enabled server: Look for Microsoft.HybridCompute/machines resource
   - This determines which agents and extensions to check

2. CHECK AGENT INSTALLATION
   For Azure VMs:
   a. SQL IaaS Agent Extension: Must be present and in Full management mode (not LightWeight)
      - Command: az sql vm show --resource-group {rg} --name {vm} --query "sqlManagement"
      - Expected: "Full"
      - Fix: az sql vm create --name {vm} --resource-group {rg} --location {loc} --license-type PAYG --sql-mgmt-type Full
      - WARNING: Upgrading to Full mode may restart SQL Server service
   b. Azure Monitor Agent (AMA): Must be installed with provisioningState = Succeeded
      - Command: az vm extension list --resource-group {rg} --vm-name {vm} --query "[?contains(type,'AzureMonitorWindowsAgent')]"
      - Fix: AMA auto-installs when a DCR is associated. Create the DCR association first.
   
   For Arc-enabled servers:
   a. Azure Connected Machine Agent: Status must be "Connected"
      - Command: az connectedmachine show --resource-group {rg} --name {machine} --query "status"
      - Expected: "Connected"
      - If "Disconnected": Check network (outbound HTTPS port 443), proxy settings, restart himds service
   b. SQL Server Arc Extension (WindowsAgent.SqlServer): Must be present
      - Command: az connectedmachine extension list --machine-name {machine} --resource-group {rg} --query "[?name=='WindowsAgent.SqlServer']"
      - Auto-deployed by Arc when SQL Server is detected. If missing after 15 min: verify SQL Server service is running
   c. Azure Monitor Agent (AMA): Same as Azure VM check but via connectedmachine extension list

3. CHECK BPA ENABLEMENT
   For Azure VMs:
   - Command: az sql vm show --resource-group {rg} --name {vm} --query "assessmentSettings.enable"
   - Expected: true
   - Fix: Review and apply terraform/sql-assessment.tf for Terraform-managed VMs; use the portal for other servers
   
   For Arc servers:
   - Check via Azure portal: Arc SQL Server resource > SQL best practices assessment

4. CHECK DCR AND DCE ASSOCIATIONS
   Every machine needs three associations:
   a. BPA DCR association (name: {vm}-bpa-dcr-association)
   b. BPA DCE association (name MUST be exactly "configurationAccessEndpoint")
   c. Performance counter DCR association (name: {vm}-perf-dcr-association)
   
   Command: az monitor data-collection rule association list --resource {resource-id}
   
   CRITICAL: The DCE association name MUST be "configurationAccessEndpoint" exactly. Azure requires this specific name.
   
   Fix for missing associations:
   - az monitor data-collection rule association create --name "{vm}-bpa-dcr-association" --resource "{resource-id}" --rule-id "{dcr-id}"
   - az monitor data-collection rule association create --name "configurationAccessEndpoint" --resource "{resource-id}" --data-collection-endpoint-id "{dce-id}"

5. CHECK DCR CONFIGURATION
   The BPA DCR must monitor BOTH CSV file paths:
   - IaaS Agent: C:\Windows\System32\config\systemprofile\AppData\Local\Microsoft SQL Server IaaS Agent\Assessment\*.csv
   - Extension Agent: C:\Windows\System32\config\systemprofile\AppData\Local\Microsoft SQL Server Extension Agent\Assessment\*.csv
   
   If only one path is present, the DCR will miss results from the other agent type.
   
   Command: az monitor data-collection rule show --resource-group {rg} --name {dcr-name} --query "dataSources.logFiles[0].filePatterns"

6. CHECK ASSESSMENT RESULTS
   Query Log Analytics:
   - SqlAssessment_CL | where TimeGenerated > ago(7d) | summarize count() by Computer = tostring(split(RawData, ",")[0])
   - SQLAssessmentRecommendation | where TimeGenerated > ago(7d) | summarize count() by Computer
   
   If no results:
   - Trigger on-demand: az sql vm update --resource-group {rg} --name {vm} --assessment-settings-run-immediately true
   - Wait 15-30 minutes for results to appear
   - Check CSV files exist on disk at the file paths above

7. CHECK PERFORMANCE COUNTERS
   Query: Perf | where TimeGenerated > ago(1h) | where ObjectName startswith "SQLServer:" | summarize dcount(CounterName) by Computer
   
   Expected: At least 20+ distinct counter names per server
   If missing: Check performance counter DCR association

8. CHECK RESOURCE PROVIDER REGISTRATION
   Required providers:
   - Microsoft.SqlVirtualMachine (for Azure VMs)
   - Microsoft.HybridCompute (for Arc)
   - Microsoft.GuestConfiguration (for Arc)
   - Microsoft.AzureArcData (for Arc SQL)
   - Microsoft.OperationalInsights (for Log Analytics)
   - Microsoft.Insights (for DCR/DCE)
   
   Command: az provider show --namespace {provider} --query "registrationState"

COMMON SQL MISCONFIGURATIONS DETECTED BY BPA:
- maxmem_default: Max memory at default value (should be ~80% of total RAM)
- maxdop_zero: MAXDOP = 0 (should be 4-8 based on cores)
- ctp_default: Cost threshold = 5 (should be 25-50)
- tempdb_one_file: Only 1 TempDB file (should be 1 per core up to 8)
- auto_shrink: AUTO_SHRINK ON (should be OFF)
- auto_close: AUTO_CLOSE ON (should be OFF)
- page_verify_none: PAGE_VERIFY = NONE (should be CHECKSUM)
- tempdb_os_drive: TempDB on C: drive (should be on dedicated disk)
- filegrowth_pct: Percentage-based growth (should be fixed MB)
- data_log_same_vol: Data and log files on same volume (should be separate)
- recovery_simple: SIMPLE recovery model on production databases (should be FULL)

OUTPUT FORMAT:
Present findings as a structured report:
1. Server: {name} ({type: Azure VM or Arc})
2. Agent Status: {list each agent with status}
3. BPA Status: {enabled/disabled}
4. DCR Associations: {list each with status}
5. Last Assessment: {date or "Never"}
6. Findings Count: {number}
7. Issues Found: {list of problems}
8. Remediation Steps: {ordered list of fixes}
```

---

## Skill Triggers (example phrases that should invoke this skill)

- "Check if BPA is configured on my SQL servers"
- "Diagnose SQL BPA issues"
- "Why is BPA not showing results for sql-bpa-01?"
- "Verify agents are installed on my SQL VMs"
- "Check SQL Server best practice assessment health"
- "Are my Arc SQL servers configured for BPA?"
- "Troubleshoot missing BPA data in Log Analytics"
- "Run a BPA health audit"
- "Check DCR associations for SQL VMs"
- "Why are performance counters not collecting?"

---

## Skill Input Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| resource_group | string | Yes | The resource group containing the SQL VMs or Arc machines |
| vm_name | string | No | Specific VM or machine name to diagnose (if omitted, check all machines in the resource group) |
| subscription_id | string | No | Azure subscription ID (uses current context if omitted) |

---

## Skill Expected Outputs

The skill should produce:
1. A per-server health report showing agent status, BPA enablement, and data flow
2. A summary of issues found with severity (Critical / Warning / Info)
3. Ordered remediation steps with exact commands to run
4. KQL queries the operator can run to verify the fix worked
