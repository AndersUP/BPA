resource "random_uuid" "workbook" {}

resource "azurerm_application_insights_workbook" "sql_dashboard" {
  name                = random_uuid.workbook.result
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  display_name        = "Azure Arc SQL Dashboard"
  source_id           = lower(azurerm_log_analytics_workspace.bpa.id)
  category            = "workbook"
  data_json           = file("${path.module}/../AzureBPAWorkbook/Azure Arc SQL Dasbboard w cpu and io and assessment.json")
  tags                = var.tags
}
