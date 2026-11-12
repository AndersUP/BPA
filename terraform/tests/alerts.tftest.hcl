mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000001"
      subscription_id = "00000000-0000-0000-0000-000000000002"
      object_id       = "00000000-0000-0000-0000-000000000003"
    }
  }
}

run "deployment_regressions" {
  command = plan

  override_resource {
    target          = azurerm_resource_group.main
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/SQL-BPA-LAB-RG"
    }
  }

  override_resource {
    target          = azurerm_log_analytics_workspace.bpa
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/SQL-BPA-LAB-RG/providers/Microsoft.OperationalInsights/workspaces/test-law"
    }
  }

  assert {
    condition     = azurerm_application_insights_workbook.sql_dashboard.source_id == lower(azurerm_log_analytics_workspace.bpa.id)
    error_message = "Workbook source IDs must be lowercase even when Azure returns mixed-case resource IDs."
  }

  assert {
    condition     = can(regex("^[a-z0-9]{3,24}$", azurerm_storage_account.scripts.name)) && endswith(azurerm_storage_account.scripts.name, substr(sha256(lower(azurerm_resource_group.main.id)), 0, 8))
    error_message = "Script storage must have a valid name with a resource-group-specific suffix."
  }

  assert {
    condition     = azurerm_windows_virtual_machine.sql["sql-bpa-01"].size == "Standard_D2s_v5" && azurerm_windows_virtual_machine.sql["sql-bpa-05"].size == "Standard_D4s_v5"
    error_message = "The lab must not default to the B-series SKUs rejected in Sweden Central."
  }

  assert {
    condition     = !strcontains(local.sql_alerts["SQL-BPA-21-BPA-FindingsSpike"].query, "let latest =")
    error_message = "The findings query must not use the reserved KQL name latest."
  }
}

run "vm_size_override" {
  command = plan

  variables {
    vm_size_overrides = {
      sql-bpa-01 = "Standard_E2s_v5"
    }
  }

  assert {
    condition     = azurerm_windows_virtual_machine.sql["sql-bpa-01"].size == "Standard_E2s_v5" && azurerm_windows_virtual_machine.sql["sql-bpa-02"].size == "Standard_D2s_v5"
    error_message = "A VM size override must affect only the selected machine."
  }
}

mock_provider "azapi" {}
mock_provider "random" {}
mock_provider "external" {}

override_data {
  target = data.external.sql_vm_provider_status
  values = {
    result = { state = "Registered" }
  }
}

variables {
  tenant_id                      = "00000000-0000-0000-0000-000000000001"
  subscription_id                = "00000000-0000-0000-0000-000000000002"
  backend_resource_group_name    = "test-state-rg"
  backend_storage_account_name   = "teststate"
  backend_storage_container_name = "tfstate"
  alert_email_address            = "test@example.com"
}

run "alert_definitions" {
  command = plan

  assert {
    condition     = length(azurerm_monitor_scheduled_query_rules_alert_v2.sql_bpa) == 22
    error_message = "All 22 SQL BPA alert definitions must be managed."
  }

  assert {
    condition = tolist([
      for name in sort(keys(local.sql_alerts)) : local.sql_alerts[name].threshold
    ]) == tolist([300, 0, 95, 25, 512, 0, 0, 80, 95, 15, 50, 3, 10, 100, 1024, 2, 0, 0, 100, 50, 20, 500])
    error_message = "All 22 thresholds must match the source alert script."
  }

  assert {
    condition = tolist([
      for name in sort(keys(local.sql_alerts)) : local.sql_alerts[name].severity
    ]) == tolist([1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3])
    error_message = "All 22 severities must match the source alert script."
  }

  assert {
    condition     = length([for rule in azurerm_monitor_scheduled_query_rules_alert_v2.sql_bpa : rule if rule.enabled]) == 21 && !azurerm_monitor_scheduled_query_rules_alert_v2.sql_bpa["SQL-BPA-17-StaleAssessment"].enabled
    error_message = "Only the unsupported 7-day stale-assessment alert must be disabled."
  }

  assert {
    condition     = azurerm_monitor_action_group.sql_bpa.email_receiver[0].email_address == var.alert_email_address
    error_message = "Alert email must use the configured notification address."
  }

  assert {
    condition = alltrue([
      for name in ["SQL-BPA-06-AMA-Heartbeat-Missing", "SQL-BPA-07-Arc-Disconnected", "SQL-BPA-18-PerfCounterGap"] :
      azurerm_monitor_scheduled_query_rules_alert_v2.sql_bpa[name].window_duration == "P2D" &&
      one(azurerm_monitor_scheduled_query_rules_alert_v2.sql_bpa[name].criteria).time_aggregation_method == "Total"
    ])
    error_message = "Absence alerts must measure the summary value over a 48-hour lookback."
  }

  assert {
    condition     = strcontains(local.sql_alerts["SQL-BPA-21-BPA-FindingsSpike"].query, "SqlAssessment_CL") && !strcontains(local.sql_alerts["SQL-BPA-21-BPA-FindingsSpike"].query, "SQLAssessmentRecommendation")
    error_message = "The findings alert must use the lab's custom assessment table."
  }

  assert {
    condition     = alltrue([for rule in azurerm_monitor_scheduled_query_rules_alert_v2.sql_bpa : rule.skip_query_validation])
    error_message = "A fresh workspace without performance tables must be deployable."
  }

  assert {
    condition     = azurerm_application_insights_workbook.sql_dashboard.display_name == "Azure Arc SQL Dashboard" && azurerm_application_insights_workbook.sql_dashboard.data_json == file("${path.module}/../AzureBPAWorkbook/Azure Arc SQL Dasbboard w cpu and io and assessment.json")
    error_message = "The lab must deploy the primary workbook JSON, not an older dashboard."
  }
}
