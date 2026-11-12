resource "azurerm_virtual_machine_extension" "azure_monitor" {
  for_each = local.sql_vms

  name                       = "AzureMonitorWindowsAgent"
  virtual_machine_id         = azurerm_windows_virtual_machine.sql[each.key].id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorWindowsAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = true
  tags                       = var.tags

  depends_on = [azurerm_virtual_machine_extension.configure_sql]
}

resource "azurerm_mssql_virtual_machine" "sql" {
  for_each = local.sql_vms

  virtual_machine_id = azurerm_windows_virtual_machine.sql[each.key].id
  sql_license_type   = "PAYG"
  tags               = var.tags

  assessment {
    enabled         = true
    run_immediately = false

    schedule {
      day_of_week     = "Sunday"
      start_time      = "09:00"
      weekly_interval = 1
    }
  }

  depends_on = [
    terraform_data.register_sql_vm_provider,
    azurerm_virtual_machine_extension.azure_monitor,
    azurerm_monitor_data_collection_rule_association.bpa_azure_vms,
    azurerm_monitor_data_collection_rule_association.bpa_dce_azure_vms,
    azurerm_monitor_data_collection_rule_association.sql_vms_perf
  ]
}
