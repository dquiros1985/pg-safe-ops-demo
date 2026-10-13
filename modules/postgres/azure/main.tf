locals {
  tags = merge(var.tags, {
    environment = var.environment
    managed-by  = "terraform"
  })
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  version             = var.postgres_version
  sku_name            = var.sku_name
  storage_mb          = var.storage_mb

  # Recovery: every committed transaction inside this window can be restored
  # to a new server (point-in-time restore).
  backup_retention_days        = var.backup_retention_days
  geo_redundant_backup_enabled = var.geo_redundant_backup_enabled

  # No passwords in Terraform state: people and pipelines sign in with Entra ID
  # tokens. The three database roles in sql/roles.sql are created by the
  # Entra admin group after the server exists.
  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = false
    tenant_id                     = var.tenant_id
  }

  tags = local.tags

  lifecycle {
    # Terraform refuses any plan that would destroy this resource, including
    # a replacement caused by changing an attribute that forces a new server.
    prevent_destroy = true

    # Azure picks the zone when none is given; ignoring it avoids a diff on
    # every plan.
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_active_directory_administrator" "this" {
  server_name         = azurerm_postgresql_flexible_server.this.name
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id
  object_id           = var.entra_admin_object_id
  principal_name      = var.entra_admin_name
  principal_type      = "Group"
}

resource "azurerm_postgresql_flexible_server_database" "this" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"

  lifecycle {
    prevent_destroy = true
  }
}

# prevent_destroy only stops Terraform. The lock stops everyone else too: the
# portal, the CLI, a script with Owner rights. Removing it is a separate,
# audited action that needs Microsoft.Authorization/locks/delete.
resource "azurerm_management_lock" "this" {
  name       = "${var.name}-cannot-delete"
  scope      = var.lock_scope == "server" ? azurerm_postgresql_flexible_server.this.id : azurerm_postgresql_flexible_server_database.this.id
  lock_level = "CanNotDelete"
  notes      = "Deleting this ${var.lock_scope} requires removing this lock first. Restore from PITR instead of recreating."
}
