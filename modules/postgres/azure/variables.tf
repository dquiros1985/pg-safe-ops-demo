variable "name" {
  description = "Server name. Becomes <name>.postgres.database.azure.com."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that holds the server."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "environment" {
  description = "Environment label (dev, prod). Used in tags and in the identity row the guards check."
  type        = string
}

variable "postgres_version" {
  description = "Major PostgreSQL version."
  type        = string
  default     = "16"
}

variable "sku_name" {
  description = "Compute SKU."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "storage_mb" {
  description = "Allocated storage in MB."
  type        = number
  default     = 32768
}

variable "database_name" {
  description = "Application database created on the server."
  type        = string
  default     = "appdb"
}

variable "backup_retention_days" {
  description = "Point-in-time restore window in days. Azure allows 7 to 35. Suggested: 7 for dev, 35 for prod."
  type        = number

  validation {
    condition     = var.backup_retention_days >= 7 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 7 and 35."
  }
}

variable "geo_redundant_backup_enabled" {
  description = "Copy backups to the paired region. Can only be set when the server is created."
  type        = bool
  default     = false
}

variable "tenant_id" {
  description = "Entra ID tenant for database authentication."
  type        = string
}

variable "entra_admin_object_id" {
  description = "Object ID of the Entra group that administers the server."
  type        = string
}

variable "entra_admin_name" {
  description = "Display name of that Entra group, as it appears as a PostgreSQL role."
  type        = string
}

variable "lock_scope" {
  description = <<-EOT
    Where the CanNotDelete lock goes: "server" or "database".
    A lock is inherited by child resources, and firewall rules are children of the server,
    so with "server" a workflow cannot delete a temporary firewall rule. Use "server" when
    the pipelines reach the database over a private network, "database" when they open a
    temporary firewall rule.
  EOT
  type        = string
  default     = "server"

  validation {
    condition     = contains(["server", "database"], var.lock_scope)
    error_message = "lock_scope must be \"server\" or \"database\"."
  }
}

variable "tags" {
  description = "Extra tags."
  type        = map(string)
  default     = {}
}
