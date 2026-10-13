# Prod: 35-day PITR window (the Azure maximum) with backups copied to the
# paired region. The pipelines reach it over a private network, so the lock
# can sit on the server itself.

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

  name                = "pgdemo-prod-psql"
  resource_group_name = "rg-pgdemo-prod"
  location            = "eastus2"
  environment         = "prod"
  sku_name            = "GP_Standard_D2ds_v5"

  backup_retention_days        = 35
  geo_redundant_backup_enabled = true
  lock_scope                   = "server"

  tenant_id             = "00000000-0000-0000-0000-000000000000"
  entra_admin_object_id = "00000000-0000-0000-0000-000000000000"
  entra_admin_name      = "grp-pgdemo-prod-dbadmins"
}

output "fqdn" {
  value = module.postgres.fqdn
}
