# The same protections on Amazon RDS: 35-day PITR window, deletion
# protection, a final snapshot, and prevent_destroy.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

module "postgres" {
  source = "../../modules/postgres/aws"

  identifier  = "pgdemo-prod"
  environment = "prod"

  backup_retention_period = 35

  db_subnet_group_name   = "pgdemo-prod-private"
  vpc_security_group_ids = ["sg-00000000000000000"]
}

output "endpoint" {
  value = module.postgres.endpoint
}
