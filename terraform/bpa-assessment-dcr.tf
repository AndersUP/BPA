# Data Collection Endpoint and Rule for SQL Best Practices Assessment
# This DCR/DCE handles CSV file ingestion for BPA results from both Azure VMs and Arc machines

# Data Collection Endpoint for BPA Assessment
resource "azurerm_monitor_data_collection_endpoint" "bpa_assessment" {
  name                = "${var.prefix}-dce"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  description         = "Data Collection Endpoint for SQL Best Practices Assessment"
}

# Data Collection Rule for BPA Assessment CSV Files
resource "azapi_resource" "sql_assessment_table" {
  type      = "Microsoft.OperationalInsights/workspaces/tables@2022-10-01"
  name      = "SqlAssessment_CL"
  parent_id = azurerm_log_analytics_workspace.bpa.id

  body = {
    properties = {
      plan            = "Analytics"
      retentionInDays = 30
      schema = {
        name = "SqlAssessment_CL"
        columns = [
          { name = "TimeGenerated", type = "datetime" },
          { name = "RawData", type = "string" }
        ]
      }
    }
  }
}

resource "azurerm_monitor_data_collection_rule" "bpa_assessment" {
  name                = "${var.prefix}-bpa-dcr"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location

  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.bpa_assessment.id

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.bpa.id
      name                  = "workspaceDest"
    }
  }

  data_flow {
    streams       = ["Custom-Text-SqlAssessment"]
    destinations  = ["workspaceDest"]
    transform_kql = "source"
    output_stream = "Custom-SqlAssessment_CL"
  }

  data_sources {
    log_file {
      name    = "SqlAssessmentLogFiles"
      format  = "text"
      streams = ["Custom-Text-SqlAssessment"]

      # Both Azure VM (IaaS Agent) and Arc machine (Extension Agent) CSV paths
      file_patterns = [
        "C:\\Windows\\System32\\config\\systemprofile\\AppData\\Local\\Microsoft SQL Server IaaS Agent\\Assessment\\*.csv",
        "C:\\Windows\\System32\\config\\systemprofile\\AppData\\Local\\Microsoft SQL Server Extension Agent\\Assessment\\*.csv"
      ]

      settings {
        text {
          record_start_timestamp_format = "ISO 8601"
        }
      }
    }
  }

  stream_declaration {
    stream_name = "Custom-Text-SqlAssessment"

    column {
      name = "TimeGenerated"
      type = "datetime"
    }

    column {
      name = "RawData"
      type = "string"
    }
  }

  description = "Data Collection Rule for SQL Best Practices Assessment - CSV file ingestion"

  depends_on = [
    azapi_resource.sql_assessment_table,
    azurerm_log_analytics_workspace.bpa,
    azurerm_monitor_data_collection_endpoint.bpa_assessment
  ]
}

# Associate BPA Assessment DCR with Azure VMs
resource "azurerm_monitor_data_collection_rule_association" "bpa_azure_vms" {
  for_each = local.sql_vms

  name                    = "${each.key}-bpa-dcr-association"
  target_resource_id      = azurerm_windows_virtual_machine.sql[each.key].id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.bpa_assessment.id

  description = "Associates BPA assessment DCR with ${each.key}"
}

# Associate BPA Assessment DCE with Azure VMs
# Note: Azure requires the exact name "configurationAccessEndpoint" for DCE associations
resource "azurerm_monitor_data_collection_rule_association" "bpa_dce_azure_vms" {
  for_each = local.sql_vms

  name                        = "configurationAccessEndpoint"
  target_resource_id          = azurerm_windows_virtual_machine.sql[each.key].id
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.bpa_assessment.id

  description = "Associates BPA DCE with ${each.key}"
}

# Arc machine associations are configured separately; see docs/MONITORING-SETUP.md.
