# --- Storage account to host the configure-sql.ps1 script ---

resource "azurerm_storage_account" "scripts" {
  name                     = "${substr(lower(replace(var.prefix, "-", "")), 0, 9)}scripts${substr(sha256(lower(azurerm_resource_group.main.id)), 0, 8)}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  tags                     = var.tags
}

resource "azurerm_storage_container" "scripts" {
  name               = "scripts"
  storage_account_id = azurerm_storage_account.scripts.id
}

resource "azurerm_role_assignment" "scripts_blob_contributor" {
  scope                = azurerm_storage_account.scripts.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Grant each VM's managed identity read access to the scripts storage account
resource "azurerm_role_assignment" "vm_blob_reader" {
  for_each = local.sql_vms

  scope                = azurerm_storage_account.scripts.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_windows_virtual_machine.sql[each.key].identity[0].principal_id
}

resource "azurerm_storage_blob" "configure_sql" {
  name                 = "configure-sql.ps1"
  storage_container_id = azurerm_storage_container.scripts.id
  type                 = "Block"
  source               = "${path.module}/scripts/configure-sql.ps1"
  content_md5          = filemd5("${path.module}/scripts/configure-sql.ps1")

  depends_on = [azurerm_role_assignment.scripts_blob_contributor]
}

# --- CustomScriptExtension: downloads script from blob, runs with short commandToExecute ---

resource "azurerm_virtual_machine_extension" "configure_sql" {
  for_each = local.sql_vms

  name                       = "configure-sql"
  virtual_machine_id         = azurerm_windows_virtual_machine.sql[each.key].id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true
  tags                       = var.tags

  settings = jsonencode({
    fileUris  = [azurerm_storage_blob.configure_sql.url]
    timestamp = var.script_version
  })

  protected_settings = jsonencode({
    managedIdentity  = {}
    commandToExecute = "powershell -ExecutionPolicy Unrestricted -File configure-sql.ps1 -VmName ${each.key} -Databases ${each.value.databases} -Misconfigs ${each.value.misconfigs} -DiskCount ${length(each.value.data_disks)}"
  })

  depends_on = [
    azurerm_virtual_machine_data_disk_attachment.sql,
    azurerm_role_assignment.vm_blob_reader
  ]
}
