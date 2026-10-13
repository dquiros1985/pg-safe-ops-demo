# Dev: 7-day PITR window, no geo copy. The pipelines reach this server through
# a temporary firewall rule, so the lock sits on the database (see lock_scope).

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = "00000000-0000-0000-0000-000000000000"
}

module "postgres" {
  source = "../../modules/postgres/azure"

  name                = "pgdemo-dev-psql"
  resource_group_name = "rg-pgdemo-dev"
  location            = "eastus2"
  environment         = "dev"

  backup_retention_days        = 7
  geo_redundant_backup_enabled = false
  lock_scope                   = "database"

  tenant_id             = "00000000-0000-0000-0000-000000000000"
  entra_admin_object_id = "00000000-0000-0000-0000-000000000000"
  entra_admin_name      = "grp-pgdemo-dev-dbadmins"
}

output "fqdn" {
  value = module.postgres.fqdn
}
