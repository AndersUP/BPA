# Creating Alerts for SQL BPA Environment

This guide defines all Azure Monitor alerts for the SQL Best Practice Assessment environment.
Alerts cover five categories: SQL performance (critical), SQL performance (warning),
BPA assessment health, agent & data pipeline health, and capacity.

All alerts are implemented as Azure Monitor Scheduled Query Rules against the Log Analytics
workspace. The Terraform lab deploys them natively through
[alerts.tf](../terraform/alerts.tf). The redundant PowerShell deployment script
has been removed; use Terraform to manage these resources.

## Terraform deployment

Set `alert_email_address` in your local Terraform variable file, then review
`terraform plan` and apply it. Terraform manages the `SQL-BPA-Alerts` action
group and 22 rules, scoped to the workspace created by the lab. Alerting and
log scans can incur costs. Destroying these Terraform resources removes the
rules and action group.

Query validation is skipped at creation so a new workspace without `Perf` or
`Heartbeat` data can be deployed. This does not verify queries at runtime:
after agents upload data, run the queries in Logs, inspect alert health, and
test the action group's email delivery.

### Differences from the PowerShell definitions

- The 7-day stale-assessment rule (#17) is included **disabled**, as agreed.
  The original 1-day query window cannot find records older than 7 days, and
  scheduled-query alerts have a maximum 48-hour evaluation lookback. Do not
  enable it unchanged; it needs a separate long-lookback monitoring solution.
- Heartbeat and performance-gap rules (#6, #7, #18) look back 48 hours while
  retaining their 10/15/30-minute absence thresholds and evaluation frequencies.
  Their aggregate is measured with `Total`, not a count of the single summary
  row (which could alert even when the summary value is zero).
  They only detect machines seen in that lookback: never-seen machines and
  machines absent for more than 48 hours require inventory-based monitoring.
- Findings spike (#21) reads the lab's `SqlAssessment_CL` CSV records instead
  of the legacy `SQLAssessmentRecommendation` table. It counts distinct
  non-passed checks from the latest ingested assessment per instance within the
  last day, using the workbook's severity convention (`Severity >= 0`).
  It is an absolute threshold of 20 findings, not a comparison with a prior run.
- Other names, severities, thresholds, windows, and evaluation frequencies are
  retained. Notification emails use the common alert schema.

Expected shutdowns can trigger the health rules. Review thresholds and alert
processing/suppression for your lab's shutdown schedule.

With Terraform 1.15 or later, run the offline provider-mocked regression checks
from the Terraform directory using `terraform test`. They verify the rule
count, enabled state, email routing, and collection-table/query configuration;
they do not execute KQL or deploy resources to Azure.

### Import existing script-created resources

No Azure state import is performed by editing configuration. If these
resources already exist, import them before applying, from the Terraform
directory, using their actual resource IDs:

```powershell
terraform import azurerm_monitor_action_group.sql_bpa `
    "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Insights/actionGroups/SQL-BPA-Alerts"

terraform import 'azurerm_monitor_scheduled_query_rules_alert_v2.sql_bpa[\"SQL-BPA-01-PLE-Critical\"]' `
    "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Insights/scheduledQueryRules/SQL-BPA-01-PLE-Critical"
```

Repeat the second command for every existing rule, using the exact names from
[alerts.tf](../terraform/alerts.tf). If a custom action-group name was used,
reconcile it with the configuration before importing. Review the plan for the
intentional query changes above and the disabled stale-assessment rule.

The remaining reference describes the original script's rules. For the
Terraform deployment, the differences above take precedence.

---

## Alert Summary

| # | Alert Name | Category | Sev | Threshold | Window | Eval |
|---|------------|----------|-----|-----------|--------|------|
| 1 | Page Life Expectancy Critical | SQL Perf | 1 | < 300s | 5m | 5m |
| 2 | Deadlocks Detected | SQL Perf | 1 | > 0 | 5m | 5m |
| 3 | CPU Critical | SQL Perf | 1 | > 95% | 10m | 5m |
| 4 | Disk Latency Critical | SQL Perf | 1 | > 25ms | 10m | 5m |
| 5 | OS Memory Exhaustion | SQL Perf | 1 | < 512 MB | 10m | 5m |
| 6 | AMA Heartbeat Missing | Agent Health | 1 | No beat in 10m | 10m | 5m |
| 7 | Arc Agent Disconnected | Agent Health | 1 | No beat in 15m | 15m | 5m |
| 8 | High CPU | SQL Perf | 2 | > 80% | 15m | 5m |
| 9 | Buffer Cache Hit Ratio Low | SQL Perf | 2 | < 95% | 15m | 5m |
| 10 | High Disk Latency | SQL Perf | 2 | > 15ms | 10m | 5m |
| 11 | Excessive Recompilations | SQL Perf | 2 | > 50/sec | 15m | 5m |
| 12 | Blocking Detected | SQL Perf | 2 | > 3 blocked | 10m | 5m |
| 13 | Lock Waits High | SQL Perf | 2 | > 10/sec | 10m | 5m |
| 14 | Full Table Scans High | SQL Perf | 2 | > 100/sec | 15m | 5m |
| 15 | Memory Pressure | SQL Perf | 2 | < 1024 MB | 15m | 5m |
| 16 | Disk Queue Building | SQL Perf | 2 | > 2 | 10m | 5m |
| 17 | BPA Stale Assessment | BPA Health | 2 | No run in 7d | 1d | 1d |
| 18 | Perf Counter Data Gap | Agent Health | 2 | No data in 30m | 30m | 15m |
| 19 | High Page Splits | SQL Perf | 3 | > 100/sec | 15m | 5m |
| 20 | Memory Paging | SQL Perf | 3 | > 50/sec | 10m | 5m |
| 21 | BPA Critical Findings Spike | BPA Health | 3 | > 20 findings | 1d | 1d |
| 22 | High User Connections | Capacity | 3 | > 500 | 15m | 5m |

---

## Category 1: SQL Performance – Critical (Severity 1)

### 1. Page Life Expectancy Critical
```kql
Perf
| where CounterName == "Page life expectancy"
| summarize AggregatedValue = avg(CounterValue) by Computer
| where AggregatedValue < 300
```
**Threshold:** < 300 seconds | **Window:** 5 minutes  
**Action:** Immediate investigation – SQL Server is actively evicting pages from the buffer pool. Check for memory-hungry queries and whether `max server memory` is configured.

### 2. Deadlocks Detected
```kql
Perf
| where CounterName == "Number of Deadlocks/sec"
| summarize AggregatedValue = sum(CounterValue) by Computer
| where AggregatedValue > 0
```
**Threshold:** > 0 | **Window:** 5 minutes  
**Action:** Capture deadlock graphs via Extended Events. Review application transaction ordering and lock hints.

### 3. CPU Critical
```kql
Perf
| where CounterName == "% Processor Time" and InstanceName == "_Total"
| summarize AggregatedValue = avg(CounterValue) by Computer
| where AggregatedValue > 95
```
**Threshold:** > 95% sustained | **Window:** 10 minutes  
**Action:** Identify top CPU queries via `sys.dm_exec_query_stats`. Check for runaway queries, parallelism issues (MAXDOP), or missing indexes.

### 4. Disk Latency Critical
```kql
Perf
| where CounterName in ("Avg. Disk sec/Read", "Avg. Disk sec/Write")
| extend LatencyMs = CounterValue * 1000
| summarize AggregatedValue = avg(LatencyMs) by Computer, CounterName
| where AggregatedValue > 25
```
**Threshold:** > 25ms | **Window:** 10 minutes  
**Action:** Check disk queue length, IOPS limits, and storage tier. Consider upgrading to Premium SSD or enabling read caching.

### 5. OS Memory Exhaustion
```kql
Perf
| where CounterName == "Available MBytes"
| summarize AggregatedValue = avg(CounterValue) by Computer
| where AggregatedValue < 512
```
**Threshold:** < 512 MB | **Window:** 10 minutes  
**Action:** Check if SQL Server `max server memory` is set correctly (leave at least 4 GB for OS). Review for memory leaks.

---

## Category 2: SQL Performance – Warning (Severity 2)

### 8. High CPU
```kql
Perf
| where CounterName == "% Processor Time" and InstanceName == "_Total"
| summarize AggregatedValue = avg(CounterValue) by Computer
| where AggregatedValue > 80
```
**Threshold:** > 80% | **Window:** 15 minutes

### 9. Buffer Cache Hit Ratio Low
```kql
Perf
| where CounterName == "Buffer cache hit ratio"
| summarize AggregatedValue = avg(CounterValue) by Computer
| where AggregatedValue < 95
```
**Threshold:** < 95% | **Window:** 15 minutes

### 10. High Disk Latency
```kql
Perf
| where CounterName in ("Avg. Disk sec/Read", "Avg. Disk sec/Write")
| extend LatencyMs = CounterValue * 1000
| summarize AggregatedValue = avg(LatencyMs) by Computer, CounterName
| where AggregatedValue > 15
```
**Threshold:** > 15ms | **Window:** 10 minutes

### 11. Excessive Recompilations
```kql
Perf
| where CounterName == "SQL Re-Compilations/sec"
| summarize AggregatedValue = avg(CounterValue) by Computer
| where AggregatedValue > 50
```
**Threshold:** > 50 per second | **Window:** 15 minutes

### 12. Blocking Detected
```kql
Perf
| where CounterName == "Processes blocked"
| summarize AggregatedValue = avg(CounterValue) by Computer
| where AggregatedValue > 3
```
**Threshold:** > 3 blocked processes | **Window:** 10 minutes

### 13. Lock Waits High
```kql
Perf
| where CounterName == "Lock Waits/sec"
| summarize AggregatedValue = avg(CounterValue) by Computer
| where AggregatedValue > 10
```
**Threshold:** > 10 per second | **Window:** 10 minutes

### 14. Full Table Scans High
```kql
Perf
| where CounterName == "Full Scans/sec"
| summarize AggregatedValue = avg(CounterValue) by Computer
| where AggregatedValue > 100
```
**Threshold:** > 100 per second | **Window:** 15 minutes

### 15. Memory Pressure
```kql
Perf
| where CounterName == "Available MBytes"
| summarize AggregatedValue = avg(CounterValue) by Computer
| where AggregatedValue < 1024
```
**Threshold:** < 1024 MB | **Window:** 15 minutes

### 16. Disk Queue Building
```kql
Perf
| where CounterName == "Avg. Disk Queue Length"
| summarize AggregatedValue = avg(CounterValue) by Computer, InstanceName
| where AggregatedValue > 2
```
**Threshold:** > 2 average queue depth | **Window:** 10 minutes

---

## Category 3: BPA Assessment Health (Severity 2–3)

### 17. BPA Stale Assessment
```kql
SqlAssessment_CL
| summarize LastSeen = max(TimeGenerated) by Computer = tostring(split(RawData, ",")[0])
| where LastSeen < ago(7d)
| project Computer, LastSeen, DaysStale = datetime_diff("day", now(), LastSeen)
```
**Threshold:** Any server with no BPA run in 7 days | **Window:** 1 day | **Eval:** 1 day  
**Action:** Check that the BPA assessment schedule is enabled, the DCR association exists, and AMA is healthy.

### 21. BPA Critical Findings Spike
```kql
SQLAssessmentRecommendation
| where TimeGenerated > ago(1d)
| where RecommendationResult == "Failed"
| summarize AggregatedValue = count() by Computer
| where AggregatedValue > 20
```
**Threshold:** > 20 failed recommendations per server in 24 hours | **Window:** 1 day | **Eval:** 1 day  
**Action:** Review the new BPA findings. A spike usually means a configuration change regressed SQL Server settings.

---

## Category 4: Agent & Data Pipeline Health (Severity 1–2)

### 6. AMA Heartbeat Missing
```kql
Heartbeat
| summarize LastBeat = max(TimeGenerated) by Computer
| where LastBeat < ago(10m)
| project Computer, LastBeat, MinutesSilent = datetime_diff("minute", now(), LastBeat)
```
**Threshold:** No heartbeat in 10 minutes | **Window:** 10 minutes  
**Action:** Check if the VM is running. Verify AMA extension status. Restart the AMA service if needed.

### 7. Arc Agent Disconnected
```kql
Heartbeat
| where ResourceProvider == "Microsoft.HybridCompute"
| summarize LastBeat = max(TimeGenerated) by Computer
| where LastBeat < ago(15m)
| project Computer, LastBeat, MinutesSilent = datetime_diff("minute", now(), LastBeat)
```
**Threshold:** No heartbeat in 15 minutes | **Window:** 15 minutes  
**Action:** Check network connectivity (outbound HTTPS 443), proxy settings, and the `himds` service on the server.

### 18. Performance Counter Data Gap
```kql
Perf
| where ObjectName startswith "SQLServer:"
| summarize LastSeen = max(TimeGenerated) by Computer
| where LastSeen < ago(30m)
| project Computer, LastSeen, MinutesSilent = datetime_diff("minute", now(), LastSeen)
```
**Threshold:** No SQL perf counters in 30 minutes | **Window:** 30 minutes | **Eval:** 15 minutes  
**Action:** Check perf DCR association and AMA health. Verify the performance counter DCR is associated with the machine.

---

## Category 5: Capacity (Severity 3)

### 19. High Page Splits
```kql
Perf
| where CounterName == "Page Splits/sec"
| summarize AggregatedValue = avg(CounterValue) by Computer
| where AggregatedValue > 100
```
**Threshold:** > 100 per second | **Window:** 15 minutes  
**Action:** Review index fill factors. Rebuild fragmented indexes.

### 20. Memory Paging
```kql
Perf
| where CounterName == "Pages/sec"
| summarize AggregatedValue = avg(CounterValue) by Computer
| where AggregatedValue > 50
```
**Threshold:** > 50 per second | **Window:** 10 minutes  
**Action:** Indicates OS-level memory pressure. Review SQL `max server memory` and total RAM.

### 22. High User Connections
```kql
Perf
| where CounterName == "User Connections"
| summarize AggregatedValue = max(CounterValue) by Computer
| where AggregatedValue > 500
```
**Threshold:** > 500 concurrent connections | **Window:** 15 minutes  
**Action:** Check for connection pool exhaustion or connection leaks in applications.

---

## Deploying All Alerts

Set `alert_email_address` in your local tfvars, then run from the repository root:

```powershell
Push-Location .\terraform
terraform plan -out=lab.tfplan
terraform apply lab.tfplan
Pop-Location
```

Initialize Terraform first as described in [the lab guide](AZURE-TERRAFORM-LAB.md).
Terraform deploys the action group and all 22 definitions, with rule #17 disabled.
Import existing resources before applying; see the migration instructions above.

---

## Testing Alerts

```powershell
# List all alert rules
az monitor scheduled-query list --resource-group sql-bpa-lab-rg --output table

# View alert rule details
az monitor scheduled-query show --name "SQL-BPA-01-PLE-Critical" --resource-group sql-bpa-lab-rg

# View fired alerts
az monitor alert list --resource-group sql-bpa-lab-rg --output table
```

## Azure Portal Steps

For those who prefer the portal:

1. Navigate to your Log Analytics workspace
2. Click **Alerts** in the left menu
3. Click **+ Create** → **Alert rule**
4. **Scope**: Select your Log Analytics workspace
5. **Condition**: Click **Add condition** → **Custom log search**
   - Paste one of the KQL queries above
   - Set threshold and evaluation frequency
6. **Actions**: Select or create an action group
7. **Details**: Name, severity, description
8. Click **Create alert rule**

## Implementation Order

Deploy alerts in this order for maximum safety:

1. **Agent Health alerts first** (#6, #7, #18) — if agents die, all other alerts go blind
2. **Critical SQL Performance** (#1–#5) — immediate service impact
3. **BPA Assessment Health** (#17, #21) — ensures the assessment system itself is working
4. **Warning SQL Performance** (#8–#16) — tune thresholds after 1–2 weeks of baselining
5. **Capacity & Informational** (#19, #20, #22) — cost protection and long-term trends

## Best Practices

1. **Start with agent health**: If AMA or Arc agent stops, all other alerts go blind
2. **Baseline before tuning**: Run for 1–2 weeks with warning alerts before adjusting thresholds
3. **Use action groups**: Separate critical (pager) and warning (email) action groups
4. **Set proper severity**: Reserve Sev 1 for issues needing immediate human response
5. **Include runbook links**: Add remediation steps in alert descriptions
6. **Review weekly**: Check for false positives and adjust thresholds
7. **Don't alert on everything**: The informational (Sev 3) alerts can feed dashboards instead of paging

## Cost Estimate

| Item | Count | Approx. Monthly Cost |
|------|-------|---------------------|
| Scheduled Query Rules (5m eval) | 18 | ~$1.80 |
| Scheduled Query Rules (1d eval) | 2 | ~$0.01 |
| Scheduled Query Rules (15m eval) | 2 | ~$0.07 |
| Action Group (email) | 1 | Free |
| **Total** | **22 rules** | **~$2/month** |

## Viewing Active Alerts

```kql
// Alert history in Log Analytics
AlertEvidence
| where TimeGenerated > ago(7d)
| summarize count() by AlertName, AlertSeverity
| order by count_ desc
```

```kql
// Alert health overview - which alerts fired most
AlertInfo
| where TimeGenerated > ago(30d)
| summarize FireCount = count() by AlertName, Severity
| order by FireCount desc
```

## Integration with Azure Workbooks

The Azure Workbook dashboards in `AzureBPAWorkbook/` can display alert data alongside performance metrics.
See `PERFORMANCE-COUNTERS.md` for KQL query examples used in dashboards.
