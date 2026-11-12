terraform {
  required_version = ">= 1.5.0"

  backend "azurerm" {
    use_azuread_auth = true
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
  }
}

provider "azapi" {
  subscription_id = var.subscription_id
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
  subscription_id = var.subscription_id

  # Use Azure AD auth for Storage data-plane operations (required when shared key auth is disabled).
  storage_use_azuread = true
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "main" {
  name     = "${var.prefix}-rg"
  location = var.location
  tags     = var.tags
}

# Query the Microsoft.SqlVirtualMachine provider registration status
data "external" "sql_vm_provider_status" {
  program = ["powershell", "-NoProfile", "-Command", "az provider show --namespace Microsoft.SqlVirtualMachine --subscription ${var.subscription_id} --query '{state: registrationState}' -o json"]
}

# Register only if not already registered
resource "terraform_data" "register_sql_vm_provider" {
  count = data.external.sql_vm_provider_status.result.state != "Registered" ? 1 : 0

  provisioner "local-exec" {
    command = "az provider register --namespace Microsoft.SqlVirtualMachine --subscription ${var.subscription_id} --wait"
  }
}

resource "terraform_data" "sql_vm_automatic_registration" {
  triggers_replace = [var.subscription_id]

  provisioner "local-exec" {
    interpreter = ["powershell", "-NoProfile", "-NonInteractive", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = 'Stop'
      az feature register --namespace Microsoft.SqlVirtualMachine --name BulkRegistration --subscription '${var.subscription_id}'
      if ($LASTEXITCODE -ne 0) { throw 'Failed to enable SQL VM automatic registration.' }

      $deadline = (Get-Date).AddMinutes(30)
      do {
        $state = az feature show --namespace Microsoft.SqlVirtualMachine --name BulkRegistration --subscription '${var.subscription_id}' --query properties.state -o tsv
        if ($LASTEXITCODE -ne 0) { throw 'Failed to read SQL VM automatic registration status.' }
        if ($state -eq 'Registered') { break }
        if ($state -in @('Failed', 'Unregistered')) { throw "SQL VM automatic registration entered state: $state" }
        if ((Get-Date) -ge $deadline) { throw "Timed out waiting for SQL VM automatic registration. Last state: $state" }
        Start-Sleep -Seconds 15
      } while ($true)

      az provider register --namespace Microsoft.SqlVirtualMachine --subscription '${var.subscription_id}' --wait
      if ($LASTEXITCODE -ne 0) { throw 'Failed to refresh the SQL VM resource provider registration.' }
    EOT
  }

  depends_on = [
    terraform_data.register_sql_vm_provider,
    azurerm_mssql_virtual_machine.sql
  ]
}

resource "azurerm_log_analytics_workspace" "bpa" {
  name                = "${var.prefix}-law"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_role_assignment" "law_contributor" {
  scope                = azurerm_log_analytics_workspace.bpa.id
  role_definition_name = "Log Analytics Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "random_password" "admin" {
  length           = 20
  special          = true
  override_special = "!@#$%&*()-_=+"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}
