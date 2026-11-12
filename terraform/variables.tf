variable "tenant_id" {
  description = "Azure AD tenant ID (used by Create-LabEnvironment.ps1 for az login)"
  type        = string
}

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "backend_resource_group_name" {
  description = "Resource group containing the Terraform state storage account"
  type        = string
}

variable "backend_storage_account_name" {
  description = "Storage account name for Terraform state"
  type        = string
}

variable "backend_storage_container_name" {
  description = "Storage container name for Terraform state"
  type        = string
}

variable "prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "sql-bpa-lab"
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "swedencentral"
}

variable "admin_username" {
  description = "Admin username for all VMs (also SQL sysadmin)"
  type        = string
  default     = "sqladmin"
}

variable "vm_size_overrides" {
  description = "Optional per-VM Azure size overrides for regional capacity restrictions"
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for name, size in var.vm_size_overrides :
      contains(["sql-bpa-01", "sql-bpa-02", "sql-bpa-03", "sql-bpa-04", "sql-bpa-05"], name) &&
      length(trimspace(size)) > 0
    ])
    error_message = "Use lab VM names sql-bpa-01 through sql-bpa-05 and non-empty size values."
  }
}

variable "shutdown_time" {
  description = "Daily auto-shutdown time in HHMM format (UTC)"
  type        = string
  default     = "1900"
}

variable "script_version" {
  description = "Increment to force the SQL configuration script to re-run on all VMs"
  type        = number
  default     = 1
}

variable "alert_email_address" {
  description = "Email address for SQL BPA alert notifications"
  type        = string

  validation {
    condition     = can(regex("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", var.alert_email_address))
    error_message = "Set alert_email_address to a valid notification email address."
  }
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    environment = "lab"
    project     = "sql-bpa"
  }
}
