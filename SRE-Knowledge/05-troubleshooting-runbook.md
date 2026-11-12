# Troubleshooting SQL BPA Issues

This document provides structured troubleshooting procedures for the Azure SRE agent to follow when diagnosing SQL Server Best Practice Assessment problems.

---

## Troubleshooting Decision Tree

```
Problem: BPA not working
│
├─ Are agents installed?
│   ├─ Azure VM: Check SQL IaaS Extension (Full mode) + AMA
│   └─ Arc Server: Check Arc Agent (Connected) + SQL Extension + AMA
│       └─ NO → Install missing agents (see 02-agent-verification-checklist.md)
│
├─ Is BPA enabled?
│   ├─ Check assessmentSettings.enable = true
│   └─ NO → Enable BPA via script or portal
│
├─ Are DCR/DCE associations in place?
│   ├─ BPA DCR association
│   ├─ BPA DCE association (name must be "configurationAccessEndpoint")
│   ├─ Perf DCR association (for performance counters)
│   └─ NO → Create missing associations
│
├─ Has assessment run?
│   ├─ Check for CSV files on disk
│   └─ NO → Trigger on-demand assessment
│
├─ Are results in Log Analytics?
│   ├─ Query SqlAssessment_CL or SQLAssessmentRecommendation
│   └─ NO → Check AMA health, DCR filePatterns, DCE connectivity
│
└─ Are performance counters collecting?
    ├─ Query Perf table
    └─ NO → Check perf DCR association and counter configuration
```

---

## Common Error Messages and Solutions

### "The SQL virtual machine resource was not found"
**Cause**: VM is not registered with the SQL IaaS Extension.
**Fix**: `az sql vm create --name <vm> --resource-group <rg> --location <loc> --license-type PAYG --sql-mgmt-type Full`

### "Assessment feature is not enabled"
**Cause**: BPA was never turned on for this SQL VM.
**Fix**: Review and apply the assessment settings in [sql-assessment.tf](../terraform/sql-assessment.tf) for lab VMs. Use the portal for servers outside Terraform management.

### "No data in SqlAssessment_CL table"
**Causes** (check in order):
1. Assessment hasn't run yet → trigger on-demand run
2. AMA not installed → verify AMA extension
3. DCR not associated → create association
4. DCR file_patterns wrong → verify both IaaS Agent and Extension Agent paths are included
5. DCE not associated → create DCE association with name `configurationAccessEndpoint`

### "Resource provider not registered"
**Cause**: Required provider (Microsoft.SqlVirtualMachine, Microsoft.HybridCompute, etc.) not registered.
**Fix**: `az provider register --namespace <provider> --wait`

### "Arc agent status: Disconnected"
**Causes**:
1. Network connectivity issue → check outbound HTTPS on port 443
2. Proxy misconfiguration → verify proxy settings with `azcmagent show`
3. Service not running → `Restart-Service himds`
4. Certificate expired → re-connect the agent

### "Terraform plan shows destroy/recreate for DCR"
**Cause**: Existing DCR was created by PowerShell and doesn't match Terraform config.
**Fix**: Use explicit Terraform imports as described in [the migration guide](../docs/DCR-DCE-MIGRATION.md), then review `terraform plan`.

---

## KQL Queries for Diagnostics

### Check BPA assessment health across all servers
```kql
SqlAssessment_CL
| where TimeGenerated > ago(7d)
| extend Computer = tostring(split(RawData, ",")[0])
| summarize
    TotalFindings = count(),
    LastAssessment = max(TimeGenerated),
    DaysSinceLastRun = datetime_diff('day', now(), max(TimeGenerated))
by Computer
| order by DaysSinceLastRun desc
```

### Identify servers with stale assessments (no run in 7+ days)
```kql
SqlAssessment_CL
| summarize LastSeen = max(TimeGenerated) by Computer = tostring(split(RawData, ",")[0])
| where LastSeen < ago(7d)
| project Computer, LastSeen, DaysStale = datetime_diff('day', now(), LastSeen)
| order by DaysStale desc
```

### Performance counter health check
```kql
Perf
| where TimeGenerated > ago(1h)
| where ObjectName startswith "SQLServer:"
| summarize CounterCount = dcount(CounterName), LastSeen = max(TimeGenerated) by Computer
| extend HealthStatus = iff(CounterCount < 10, "Degraded", "Healthy")
| order by HealthStatus asc, Computer
```

### AMA heartbeat check
```kql
Heartbeat
| where TimeGenerated > ago(1h)
| summarize LastHeartbeat = max(TimeGenerated) by Computer
| extend Status = iff(LastHeartbeat < ago(10m), "Stale", "Healthy")
| order by Status asc
```

---

## Runbook: Full BPA Health Audit

Execute these steps in order to perform a complete health audit:

1. **List all target machines**: Identify all Azure VMs and Arc machines in the resource group.
2. **Check agent status**: For each machine, verify the correct agents are installed and healthy.
3. **Verify BPA enablement**: Confirm BPA is enabled on each SQL VM / Arc SQL Server.
4. **Verify DCR/DCE associations**: Ensure all required associations exist.
5. **Check Log Analytics data**: Query for recent assessment results and performance counters.
6. **Identify gaps**: Report any machines missing agents, associations, or data.
7. **Remediate**: Apply fixes for any issues found.
8. **Trigger assessment**: Run on-demand assessment on remediated machines.
9. **Verify results**: After 30 minutes, confirm data appears in Log Analytics.
