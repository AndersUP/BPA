locals {
  sql_alerts = {
    "SQL-BPA-01-PLE-Critical" = {
      description = "Page life expectancy below 300 seconds - severe memory pressure."
      severity    = 1, window = "PT5M", aggregation = "Average", operator = "LessThan", threshold = 300
      query       = "Perf | where CounterName == 'Page life expectancy' | summarize AggregatedValue = avg(CounterValue) by Computer"
    }
    "SQL-BPA-02-Deadlocks-Critical" = {
      description = "Deadlocks detected on SQL Server. Capture deadlock graphs and review transaction ordering."
      severity    = 1, window = "PT5M", aggregation = "Total", operator = "GreaterThan", threshold = 0
      query       = "Perf | where CounterName == 'Number of Deadlocks/sec' | summarize AggregatedValue = sum(CounterValue) by Computer"
    }
    "SQL-BPA-03-CPU-Critical" = {
      description = "CPU above 95% sustained. Check top CPU queries, MAXDOP, and missing indexes."
      severity    = 1, window = "PT10M", aggregation = "Average", operator = "GreaterThan", threshold = 95
      query       = "Perf | where CounterName == '% Processor Time' and InstanceName == '_Total' | summarize AggregatedValue = avg(CounterValue) by Computer"
    }
    "SQL-BPA-04-DiskLatency-Critical" = {
      description = "Disk latency above 25ms. Check disk queue length, IOPS limits, and storage tier."
      severity    = 1, window = "PT10M", aggregation = "Average", operator = "GreaterThan", threshold = 25
      query       = "Perf | where CounterName in ('Avg. Disk sec/Read', 'Avg. Disk sec/Write') | extend LatencyMs = CounterValue * 1000 | summarize AggregatedValue = avg(LatencyMs) by Computer, CounterName"
    }
    "SQL-BPA-05-OSMemory-Critical" = {
      description = "Available OS memory below 512 MB. Check SQL max server memory."
      severity    = 1, window = "PT10M", aggregation = "Average", operator = "LessThan", threshold = 512
      query       = "Perf | where CounterName == 'Available MBytes' | summarize AggregatedValue = avg(CounterValue) by Computer"
    }
    "SQL-BPA-06-AMA-Heartbeat-Missing" = {
      description = "No AMA heartbeat for 10+ minutes from a computer seen within the last 48 hours."
      severity    = 1, window = "P2D", aggregation = "Total", operator = "GreaterThan", threshold = 0
      query       = "Heartbeat | summarize LastBeat = max(TimeGenerated) by Computer | where LastBeat < ago(10m) | summarize AggregatedValue = count()"
    }
    "SQL-BPA-07-Arc-Disconnected" = {
      description = "No Arc heartbeat for 15+ minutes from a computer seen within the last 48 hours."
      severity    = 1, window = "P2D", aggregation = "Total", operator = "GreaterThan", threshold = 0
      query       = "Heartbeat | where ResourceProvider =~ 'Microsoft.HybridCompute' | summarize LastBeat = max(TimeGenerated) by Computer | where LastBeat < ago(15m) | summarize AggregatedValue = count()"
    }
    "SQL-BPA-08-CPU-Warning" = {
      description = "CPU above 80% sustained. Consider scaling or query optimization."
      severity    = 2, window = "PT15M", aggregation = "Average", operator = "GreaterThan", threshold = 80
      query       = "Perf | where CounterName == '% Processor Time' and InstanceName == '_Total' | summarize AggregatedValue = avg(CounterValue) by Computer"
    }
    "SQL-BPA-09-BufferCache-Warning" = {
      description = "Buffer cache hit ratio below 95%. Review max server memory and query memory grants."
      severity    = 2, window = "PT15M", aggregation = "Average", operator = "LessThan", threshold = 95
      query       = "Perf | where CounterName == 'Buffer cache hit ratio' | summarize AggregatedValue = avg(CounterValue) by Computer"
    }
    "SQL-BPA-10-DiskLatency-Warning" = {
      description = "Disk latency above 15ms. Storage may be a bottleneck."
      severity    = 2, window = "PT10M", aggregation = "Average", operator = "GreaterThan", threshold = 15
      query       = "Perf | where CounterName in ('Avg. Disk sec/Read', 'Avg. Disk sec/Write') | extend LatencyMs = CounterValue * 1000 | summarize AggregatedValue = avg(LatencyMs) by Computer, CounterName"
    }
    "SQL-BPA-11-Recompilations-Warning" = {
      description = "SQL recompilations above 50/sec. Check schema changes, statistics updates, and temp table reuse."
      severity    = 2, window = "PT15M", aggregation = "Average", operator = "GreaterThan", threshold = 50
      query       = "Perf | where CounterName == 'SQL Re-Compilations/sec' | summarize AggregatedValue = avg(CounterValue) by Computer"
    }
    "SQL-BPA-12-Blocking-Warning" = {
      description = "More than 3 blocked processes. Investigate blocking chains."
      severity    = 2, window = "PT10M", aggregation = "Average", operator = "GreaterThan", threshold = 3
      query       = "Perf | where CounterName == 'Processes blocked' | summarize AggregatedValue = avg(CounterValue) by Computer"
    }
    "SQL-BPA-13-LockWaits-Warning" = {
      description = "Lock waits above 10/sec. Review transaction isolation and query patterns."
      severity    = 2, window = "PT10M", aggregation = "Average", operator = "GreaterThan", threshold = 10
      query       = "Perf | where CounterName == 'Lock Waits/sec' | summarize AggregatedValue = avg(CounterValue) by Computer"
    }
    "SQL-BPA-14-FullScans-Warning" = {
      description = "Full table/index scans above 100/sec. Review execution plans and missing indexes."
      severity    = 2, window = "PT15M", aggregation = "Average", operator = "GreaterThan", threshold = 100
      query       = "Perf | where CounterName == 'Full Scans/sec' | summarize AggregatedValue = avg(CounterValue) by Computer"
    }
    "SQL-BPA-15-MemoryPressure-Warning" = {
      description = "Available OS memory below 1024 MB."
      severity    = 2, window = "PT15M", aggregation = "Average", operator = "LessThan", threshold = 1024
      query       = "Perf | where CounterName == 'Available MBytes' | summarize AggregatedValue = avg(CounterValue) by Computer"
    }
    "SQL-BPA-16-DiskQueue-Warning" = {
      description = "Average disk queue length above 2. I/O subsystem may be saturated."
      severity    = 2, window = "PT10M", aggregation = "Average", operator = "GreaterThan", threshold = 2
      query       = "Perf | where CounterName == 'Avg. Disk Queue Length' | summarize AggregatedValue = avg(CounterValue) by Computer, InstanceName"
    }
    "SQL-BPA-17-StaleAssessment" = {
      description = "DISABLED: 7-day assessment freshness requires a separate long-lookback solution; scheduled-query alerts only evaluate up to 48 hours."
      severity    = 2, window = "P1D", frequency = "P1D", aggregation = "Total", operator = "GreaterThan", threshold = 0
      enabled     = false
      query       = "SqlAssessment_CL | summarize LastSeen = max(TimeGenerated) by _ResourceId | where LastSeen < ago(7d) | summarize AggregatedValue = count()"
    }
    "SQL-BPA-18-PerfCounterGap" = {
      description = "No SQL performance counter data for 30+ minutes from a computer seen within the last 48 hours."
      severity    = 2, window = "P2D", frequency = "PT15M", aggregation = "Total", operator = "GreaterThan", threshold = 0
      query       = "Perf | where ObjectName startswith 'SQLServer:' | summarize LastSeen = max(TimeGenerated) by Computer | where LastSeen < ago(30m) | summarize AggregatedValue = count()"
    }
    "SQL-BPA-19-PageSplits-Info" = {
      description = "Page splits above 100/sec. Review index fill factors and fragmentation."
      severity    = 3, window = "PT15M", aggregation = "Average", operator = "GreaterThan", threshold = 100
      query       = "Perf | where CounterName == 'Page Splits/sec' | summarize AggregatedValue = avg(CounterValue) by Computer"
    }
    "SQL-BPA-20-MemoryPaging-Info" = {
      description = "Memory pages/sec above 50. Review SQL max server memory and total RAM."
      severity    = 3, window = "PT10M", aggregation = "Average", operator = "GreaterThan", threshold = 50
      query       = "Perf | where CounterName == 'Pages/sec' | summarize AggregatedValue = avg(CounterValue) by Computer"
    }
    "SQL-BPA-21-BPA-FindingsSpike" = {
      description = "More than 20 distinct non-passed BPA findings in a server's latest assessment ingested in the last day."
      severity    = 3, window = "P1D", frequency = "P1D", aggregation = "Maximum", operator = "GreaterThan", threshold = 20
      query       = <<-KQL
        let assessmentRows = SqlAssessment_CL
        | extend Assessment = parse_csv(RawData)
        | extend AssessmentId = tostring(Assessment[1]), CheckId = tostring(Assessment[2]),
                 TargetType = tostring(Assessment[6]), TargetName = tostring(Assessment[7]),
                 Severity = toint(Assessment[8]), InstanceName = tostring(Assessment[11])
        | where isnotempty(AssessmentId) and isnotnull(Severity);
        let latestAssessmentRuns = assessmentRows | summarize arg_max(TimeGenerated, AssessmentId) by _ResourceId, InstanceName;
        assessmentRows
        | join kind=inner latestAssessmentRuns on _ResourceId, InstanceName, AssessmentId
        | where Severity >= 0
        | distinct _ResourceId, InstanceName, CheckId, TargetType, TargetName
        | summarize AggregatedValue = count() by _ResourceId
      KQL
    }
    "SQL-BPA-22-HighConnections-Info" = {
      description = "More than 500 concurrent user connections. Check connection pools and leaks."
      severity    = 3, window = "PT15M", aggregation = "Maximum", operator = "GreaterThan", threshold = 500
      query       = "Perf | where CounterName == 'User Connections' | summarize AggregatedValue = avg(CounterValue) by Computer"
    }
  }
}

resource "azurerm_monitor_action_group" "sql_bpa" {
  name                = "SQL-BPA-Alerts"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "SQLBPA"
  tags                = var.tags

  email_receiver {
    name                    = "DBA Team"
    email_address           = var.alert_email_address
    use_common_alert_schema = true
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "sql_bpa" {
  for_each = local.sql_alerts

  name                 = each.key
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_log_analytics_workspace.bpa.location
  description          = each.value.description
  severity             = each.value.severity
  scopes               = [azurerm_log_analytics_workspace.bpa.id]
  evaluation_frequency = lookup(each.value, "frequency", "PT5M")
  window_duration      = each.value.window
  enabled              = lookup(each.value, "enabled", true)
  # Perf/Heartbeat tables may not exist until the first agent upload.
  skip_query_validation = true
  tags                  = var.tags

  criteria {
    query                   = each.value.query
    time_aggregation_method = each.value.aggregation
    metric_measure_column   = "AggregatedValue"
    operator                = each.value.operator
    threshold               = each.value.threshold

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.sql_bpa.id]
  }

  depends_on = [azapi_resource.sql_assessment_table]
}
