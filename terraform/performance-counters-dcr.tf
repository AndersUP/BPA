# Data Collection Rule for SQL Server Performance Counters
# This DCR collects Windows Performance Counters from both Azure VMs and Arc-enabled machines
# Note: This DCR uses the shared BPA DCE (no need for a separate DCE for performance counters)

resource "azurerm_monitor_data_collection_rule" "sql_perf_counters" {
  name                = "${var.prefix}-sql-perfcounters-dcr"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location

  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.bpa_assessment.id

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.bpa.id
      name                  = "sql-bpa-law-dest"
    }
  }

  # SQL Server-specific Performance Counters
  data_flow {
    streams      = ["Microsoft-Perf"]
    destinations = ["sql-bpa-law-dest"]
  }

  data_sources {
    performance_counter {
      streams                       = ["Microsoft-Perf"]
      sampling_frequency_in_seconds = 60
      counter_specifiers = [
        # SQL Server: General Statistics
        "\\SQLServer:General Statistics\\User Connections",
        "\\SQLServer:General Statistics\\Processes blocked",
        "\\SQLServer:General Statistics\\Logins/sec",
        "\\SQLServer:General Statistics\\Logouts/sec",

        # SQL Server: Buffer Manager
        "\\SQLServer:Buffer Manager\\Buffer cache hit ratio",
        "\\SQLServer:Buffer Manager\\Page life expectancy",
        "\\SQLServer:Buffer Manager\\Lazy writes/sec",
        "\\SQLServer:Buffer Manager\\Checkpoint pages/sec",

        # SQL Server: SQL Statistics
        "\\SQLServer:SQL Statistics\\Batch Requests/sec",
        "\\SQLServer:SQL Statistics\\SQL Compilations/sec",
        "\\SQLServer:SQL Statistics\\SQL Re-Compilations/sec",

        # SQL Server: Locks (_Total)
        "\\SQLServer:Locks(_Total)\\Lock Waits/sec",
        "\\SQLServer:Locks(_Total)\\Average Wait Time (ms)",
        "\\SQLServer:Locks(_Total)\\Lock Timeouts/sec",
        "\\SQLServer:Locks(_Total)\\Number of Deadlocks/sec",

        # SQL Server: Access Methods
        "\\SQLServer:Access Methods\\Full Scans/sec",
        "\\SQLServer:Access Methods\\Index Searches/sec",
        "\\SQLServer:Access Methods\\Page Splits/sec",

        # SQL Server: Databases (_Total)
        "\\SQLServer:Databases(_Total)\\Transactions/sec",
        "\\SQLServer:Databases(_Total)\\Log Flushes/sec",
        "\\SQLServer:Databases(_Total)\\Log Flush Wait Time",

        # System: Processor
        "\\Processor(_Total)\\% Processor Time",
        "\\Processor(_Total)\\% Privileged Time",

        # System: Memory
        "\\Memory\\Available MBytes",
        "\\Memory\\Pages/sec",

        # System: LogicalDisk (workbook disk latency panels)
        "\\LogicalDisk(*)\\Avg. Disk sec/Read",
        "\\LogicalDisk(*)\\Avg. Disk sec/Write",

        # System: PhysicalDisk (_Total)
        "\\PhysicalDisk(_Total)\\Avg. Disk sec/Read",
        "\\PhysicalDisk(_Total)\\Avg. Disk sec/Write",
        "\\PhysicalDisk(_Total)\\Disk Reads/sec",
        "\\PhysicalDisk(_Total)\\Disk Writes/sec",

        # System: PhysicalDisk (per-disk for Storage I/O Analysis)
        "\\PhysicalDisk(*)\\Avg. Disk Queue Length",
        "\\PhysicalDisk(*)\\% Disk Time",
        "\\PhysicalDisk(*)\\Avg. Disk Bytes/Read",
        "\\PhysicalDisk(*)\\Avg. Disk Bytes/Write",
        "\\PhysicalDisk(*)\\Current Disk Queue Length",
        "\\PhysicalDisk(*)\\Disk Bytes/sec",

        # SQL Server: Buffer Manager (I/O related)
        "\\SQLServer:Buffer Manager\\Page reads/sec",
        "\\SQLServer:Buffer Manager\\Page writes/sec",
        "\\SQLServer:Buffer Manager\\Readahead pages/sec",

        # System: Network Interface
        "\\Network Interface(*)\\Bytes Total/sec"
      ]
      name = "sql-perfCounterDataSource"
    }
  }

  description = "Data Collection Rule for SQL Server Performance Counters - both Azure VMs and Arc machines"

  depends_on = [
    azurerm_log_analytics_workspace.bpa,
    azurerm_monitor_data_collection_endpoint.bpa_assessment
  ]
}

# Associate Performance Counter DCR with Azure VMs
resource "azurerm_monitor_data_collection_rule_association" "sql_vms_perf" {
  for_each = local.sql_vms

  name                    = "${each.key}-perf-dcr-association"
  target_resource_id      = azurerm_windows_virtual_machine.sql[each.key].id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.sql_perf_counters.id

  description = "Associates performance counter DCR with ${each.key}"
}

# Note: DCE association is handled by bpa-assessment-dcr.tf (shared DCE for all data collection)
# Arc machine associations are configured separately; see docs/MONITORING-SETUP.md.
