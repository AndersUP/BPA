locals {
  sql_vms = {
    "sql-bpa-01" = {
      vm_size    = "Standard_D2s_v5"
      sql_image  = { publisher = "MicrosoftSQLServer", offer = "sql2022-ws2022", sku = "sqldev-gen2" }
      data_disks = [{ size = 128, lun = 0 }]
      databases  = "adventureworks,misconfigdemo"
      misconfigs = "maxmem_default,maxdop_zero,ctp_default,tempdb_one_file,auto_shrink,tempdb_os_drive,no_adhoc_opt,filegrowth_pct,data_log_same_vol"
    }
    "sql-bpa-02" = {
      vm_size    = "Standard_D2s_v5"
      sql_image  = { publisher = "MicrosoftSQLServer", offer = "sql2022-ws2022", sku = "sqldev-gen2" }
      data_disks = [{ size = 64, lun = 0 }, { size = 64, lun = 1 }]
      databases  = "worldwideimporters"
      misconfigs = "maxmem_default,maxdop_zero,ctp_default,tempdb_one_file,filegrowth_pct,data_log_same_vol,no_adhoc_opt"
    }
    "sql-bpa-03" = {
      vm_size    = "Standard_E2s_v5"
      sql_image  = { publisher = "MicrosoftSQLServer", offer = "sql2019-ws2022", sku = "sqldev-gen2" }
      data_disks = [{ size = 256, lun = 0 }]
      databases  = "adventureworks,misconfigdemo"
      misconfigs = "maxmem_default,maxdop_zero,ctp_default,tempdb_one_file,auto_close,page_verify_none,tempdb_os_drive,no_adhoc_opt"
    }
    "sql-bpa-04" = {
      vm_size    = "Standard_D4s_v5"
      sql_image  = { publisher = "MicrosoftSQLServer", offer = "sql2019-ws2022", sku = "sqldev-gen2" }
      data_disks = [{ size = 128, lun = 0 }, { size = 128, lun = 1 }, { size = 128, lun = 2 }]
      databases  = "adventureworks,worldwideimporters"
      misconfigs = "baseline"
    }
    "sql-bpa-05" = {
      vm_size    = "Standard_D4s_v5"
      sql_image  = { publisher = "MicrosoftSQLServer", offer = "sql2022-ws2022", sku = "sqldev-gen2" }
      data_disks = [{ size = 128, lun = 0 }, { size = 128, lun = 1 }]
      databases  = "adventureworks,misconfigdemo"
      misconfigs = "maxmem_default,maxdop_zero,ctp_default,tempdb_one_file,auto_shrink,recovery_simple,filegrowth_pct,data_log_same_vol,no_adhoc_opt"
    }
  }

  # Flatten disks into a map keyed by "vmname-data-lun" for for_each
  all_disks = { for item in flatten([
    for vm_name, vm in local.sql_vms : [
      for disk in vm.data_disks : {
        key     = "${vm_name}-data-${disk.lun}"
        vm_name = vm_name
        size    = disk.size
        lun     = disk.lun
      }
    ]
  ]) : item.key => item }
}

# --- Network Interfaces (no public IP) ---

resource "azurerm_network_interface" "sql" {
  for_each            = local.sql_vms
  name                = "${each.key}-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.sql.id
    private_ip_address_allocation = "Dynamic"
  }
}

# --- Windows VMs from SQL Server marketplace images ---

resource "azurerm_windows_virtual_machine" "sql" {
  for_each            = local.sql_vms
  name                = each.key
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  size                = lookup(var.vm_size_overrides, each.key, each.value.vm_size)
  admin_username      = var.admin_username
  admin_password      = random_password.admin.result
  timezone            = "UTC"
  tags                = var.tags

  network_interface_ids = [azurerm_network_interface.sql[each.key].id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 128
  }

  source_image_reference {
    publisher = each.value.sql_image.publisher
    offer     = each.value.sql_image.offer
    sku       = each.value.sql_image.sku
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }
}

# --- Managed Data Disks ---

resource "azurerm_managed_disk" "sql" {
  for_each = local.all_disks

  name                 = each.key
  location             = azurerm_resource_group.main.location
  resource_group_name  = azurerm_resource_group.main.name
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = each.value.size
  tags                 = var.tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "sql" {
  for_each = local.all_disks

  managed_disk_id    = azurerm_managed_disk.sql[each.key].id
  virtual_machine_id = azurerm_windows_virtual_machine.sql[each.value.vm_name].id
  lun                = each.value.lun
  caching            = "ReadOnly"
}

# --- Auto-shutdown at 19:00 UTC ---

resource "azurerm_dev_test_global_vm_shutdown_schedule" "sql" {
  for_each = local.sql_vms

  virtual_machine_id    = azurerm_windows_virtual_machine.sql[each.key].id
  location              = azurerm_resource_group.main.location
  enabled               = true
  daily_recurrence_time = var.shutdown_time
  timezone              = "UTC"
  tags                  = var.tags

  notification_settings {
    enabled = false
  }
}
