# SQL Server Performance Counter Monitoring

This lab environment collects comprehensive performance counters from both Azure SQL VMs and Arc-enabled SQL Servers.

## Architecture

- **Data Collection Rule (DCR)**: `sql-bpa-perfcounters-dcr` (created by Terraform)
- **Collection Interval**: Every 60 seconds
- **Destination**: Log Analytics Workspace (`sql-bpa-law`)
- **Table**: `Perf` (standard Azure Monitor table)

## Performance Counters Collected

### SQL Server: General Statistics
- User Connections - Current number of user connections
- Processes blocked - Number of currently blocked processes
- Logins/sec - Rate of login attempts
- Logouts/sec - Rate of logout attempts

### SQL Server: Buffer Manager
- **Buffer cache hit ratio** - Critical metric: % of pages found in buffer cache without reading from disk (target: >95%)
- **Page life expectancy** - Critical metric: Average seconds a page stays in buffer pool (target: >300)
- Lazy writes/sec - Number of buffers written by lazy writer
- Checkpoint pages/sec - Pages flushed to disk by checkpoints

### SQL Server: SQL Statistics
- **Batch Requests/sec** - Key throughput metric: SQL batches received per second
- SQL Compilations/sec - New query plan compilations
- SQL Re-Compilations/sec - Query plan recompilations (high values indicate issues)

### SQL Server: Locks
- Lock Waits/sec - Lock requests that couldn't be granted immediately
- Average Wait Time (ms) - Average wait time for locks
- Lock Timeouts/sec - Lock requests that timed out
- **Number of Deadlocks/sec** - Deadlock occurrences (target: 0)

### SQL Server: Access Methods
- Full Scans/sec - Full index or table scans (high values may indicate missing indexes)
- Index Searches/sec - Index seek operations
- Page Splits/sec - Page splits during index inserts (high values indicate fill factor issues)

### SQL Server: Databases (_Total)
- Transactions/sec - Transaction rate across all databases
- Log Flushes/sec - Transaction log flush rate
- Log Flush Wait Time - Wait time for log flushes

### System: Processor
- % Processor Time - Overall CPU utilization (target: <80% sustained)
- % Privileged Time - CPU time spent in kernel mode

### System: Memory
- Available MBytes - Available physical memory
- Pages/sec - Memory paging rate (high values indicate memory pressure)

### System: LogicalDisk
- `\LogicalDisk(*)\Avg. Disk sec/Read` - Per-volume read latency
- `\LogicalDisk(*)\Avg. Disk sec/Write` - Per-volume write latency

These counters feed the workbook's disk latency panels through the `Perf` table.
Values are collected in seconds; the workbook converts them to milliseconds.
They use the existing performance DCR and its 60-second sampling interval.

### System: PhysicalDisk
- Avg. Disk sec/Read - Average disk read latency (target: <10ms)
- Avg. Disk sec/Write - Average disk write latency (target: <10ms)
- Disk Reads/sec - Disk read IOPS
- Disk Writes/sec - Disk write IOPS

### System: Network Interface
- Bytes Total/sec - Network throughput

## Sample KQL Queries

### 1. Buffer Cache Hit Ratio (Last Hour)
```kql
Perf
| where TimeGenerated > ago(1h)
| where CounterName == "Buffer cache hit ratio"
| summarize avg(CounterValue) by Computer, bin(TimeGenerated, 5m)
| render timechart
```

### 2. Page Life Expectancy Monitoring
```kql
Perf
| where TimeGenerated > ago(1h)
| where CounterName == "Page life expectancy"
| summarize avg(CounterValue) by Computer, bin(TimeGenerated, 5m)
| extend Status = iff(avg_CounterValue < 300, "Critical", "OK")
| render timechart
```

### 3. Batch Requests Per Second (Throughput)
```kql
Perf
| where TimeGenerated > ago(1h)
| where CounterName == "Batch Requests/sec"
| summarize avg(CounterValue) by Computer, bin(TimeGenerated, 1m)
| render timechart
```

### 4. CPU Utilization Across All Servers
```kql
Perf
| where TimeGenerated > ago(1h)
| where CounterName == "% Processor Time" and InstanceName == "_Total"
| summarize avg(CounterValue) by Computer, bin(TimeGenerated, 5m)
| render timechart
```

### 5. Deadlock Detection
```kql
Perf
| where TimeGenerated > ago(24h)
| where CounterName == "Number of Deadlocks/sec"
| where CounterValue > 0
| summarize DeadlockCount = sum(CounterValue) by Computer
| order by DeadlockCount desc
```

### 6. Memory Pressure Detection
```kql
Perf
| where TimeGenerated > ago(1h)
| where CounterName == "Available MBytes" or CounterName == "Pages/sec"
| summarize avg(CounterValue) by Computer, CounterName, bin(TimeGenerated, 5m)
| render timechart
```

### 7. Disk Latency Analysis
```kql
Perf
| where TimeGenerated > ago(1h)
| where CounterName in ("Avg. Disk sec/Read", "Avg. Disk sec/Write")
| extend LatencyMs = CounterValue * 1000
| summarize avg(LatencyMs) by Computer, CounterName, bin(TimeGenerated, 5m)
| render timechart
```

### 8. Full Scan vs Index Seek Ratio
```kql
Perf
| where TimeGenerated > ago(1h)
| where CounterName in ("Full Scans/sec", "Index Searches/sec")
| summarize avg(CounterValue) by Computer, CounterName, bin(TimeGenerated, 5m)
| render timechart
```

### 9. Compilation vs Re-Compilation Rate
```kql
Perf
| where TimeGenerated > ago(1h)
| where CounterName in ("SQL Compilations/sec", "SQL Re-Compilations/sec")
| summarize avg(CounterValue) by Computer, CounterName, bin(TimeGenerated, 5m)
| render timechart
```

### 10. Overall SQL Server Health Dashboard
```kql
let BufferCacheHitRatio = Perf
| where TimeGenerated > ago(1h)
| where CounterName == "Buffer cache hit ratio"
| summarize AvgBufferCacheHitRatio = avg(CounterValue) by Computer;
let PageLifeExpectancy = Perf
| where TimeGenerated > ago(1h)
| where CounterName == "Page life expectancy"
| summarize AvgPageLifeExpectancy = avg(CounterValue) by Computer;
let BatchRequests = Perf
| where TimeGenerated > ago(1h)
| where CounterName == "Batch Requests/sec"
| summarize AvgBatchRequests = avg(CounterValue) by Computer;
let CPUUsage = Perf
| where TimeGenerated > ago(1h)
| where CounterName == "% Processor Time" and InstanceName == "_Total"
| summarize AvgCPU = avg(CounterValue) by Computer;
BufferCacheHitRatio
| join kind=inner (PageLifeExpectancy) on Computer
| join kind=inner (BatchRequests) on Computer
| join kind=inner (CPUUsage) on Computer
| project Computer, 
    BufferCacheHitRatio = round(AvgBufferCacheHitRatio, 2),
    PageLifeExpectancy = round(AvgPageLifeExpectancy, 0),
    BatchRequestsPerSec = round(AvgBatchRequests, 2),
    CPUPercent = round(AvgCPU, 2)
| order by Computer asc
```

## Alerting Recommendations

Create alerts for these critical conditions:

1. **Buffer Cache Hit Ratio < 95%** - Indicates memory pressure
2. **Page Life Expectancy < 300 seconds** - Memory pressure
3. **CPU > 80% for 10 minutes** - Performance degradation
4. **Deadlocks detected** - Application issues
5. **Disk latency > 20ms** - Storage performance issues
6. **Log Flush Wait Time > 10ms** - Transaction log bottleneck

## Deployment

The performance counter DCR is automatically created when you run:

```bash
cd terraform
terraform apply
```

Arc machine associations are configured separately as described in
[monitoring setup](MONITORING-SETUP.md). The lab creation script is Azure-only.

## Troubleshooting

### No data in Perf table

```kql
// Check if AMA is sending heartbeats
Heartbeat
| where Computer contains "sql-bpa" or Computer contains "arc-sql"
| summarize max(TimeGenerated) by Computer

// Check DCR associations
az monitor data-collection rule association list \
  --resource "/subscriptions/{subscription}/resourceGroups/sql-bpa-lab-rg/providers/Microsoft.Compute/virtualMachines/sql-bpa-01"
```

### Verify performance counter collection

```powershell
# Check AMA extension status on Azure VM
az vm extension show \
  --resource-group sql-bpa-lab-rg \
  --vm-name sql-bpa-01 \
  --name AzureMonitorWindowsAgent

# Check AMA extension status on Arc machine
az connectedmachine extension show \
  --resource-group sql-bpa-lab-rg \
  --machine-name {arc-machine-name} \
  --name AzureMonitorWindowsAgent
```

## Data Retention

Performance counter data in the `Perf` table follows your Log Analytics workspace retention policy (default: 30 days, configurable up to 730 days).

## Cost Considerations

- **Data Ingestion**: ~34 counters × 60-second interval = ~34 samples/minute per machine
- **Estimated**: ~50 MB/day per SQL Server
- **7 machines**: ~350 MB/day total (~10.5 GB/month)
- **Log Analytics Pricing**: First 5 GB/day included in many tiers

## Next Steps

1. Run `terraform apply` to create the DCR
2. Wait 5-10 minutes for data collection to begin
3. Query the `Perf` table using the KQL examples above
4. Create custom Workbooks for SQL Server monitoring dashboards
5. Set up alerts for critical metrics
