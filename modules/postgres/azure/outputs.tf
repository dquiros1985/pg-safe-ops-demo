output "server_id" {
  description = "Resource ID of the server."
  value       = azurerm_postgresql_flexible_server.this.id
}

output "server_name" {
  description = "Server name, as pinned in the workflows."
  value       = azurerm_postgresql_flexible_server.this.name
}

output "fqdn" {
  description = "Host name clients connect to."
  value       = azurerm_postgresql_flexible_server.this.fqdn
}

output "database_name" {
  description = "Application database."
  value       = azurerm_postgresql_flexible_server_database.this.name
}

output "backup_retention_days" {
  description = "Effective PITR window."
  value       = azurerm_postgresql_flexible_server.this.backup_retention_days
}
