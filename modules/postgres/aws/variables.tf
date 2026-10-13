variable "identifier" {
  description = "RDS instance identifier."
  type        = string
}

variable "environment" {
  description = "Environment label (dev, prod)."
  type        = string
}

variable "engine_version" {
  description = "PostgreSQL engine version."
  type        = string
  default     = "16"
}

variable "instance_class" {
  description = "Instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Storage in GiB."
  type        = number
  default     = 20
}

variable "database_name" {
  description = "Application database."
  type        = string
  default     = "appdb"
}

variable "master_username" {
  description = "Master user. Its password is generated and kept in Secrets Manager by RDS."
  type        = string
  default     = "dbadmin"
}

variable "backup_retention_period" {
  description = "Point-in-time restore window in days. RDS allows 1 to 35 (0 disables backups, which this module refuses)."
  type        = number

  validation {
    condition     = var.backup_retention_period >= 1 && var.backup_retention_period <= 35
    error_message = "backup_retention_period must be between 1 and 35."
  }
}

variable "db_subnet_group_name" {
  description = "Subnet group with private subnets only."
  type        = string
}

variable "vpc_security_group_ids" {
  description = "Security groups attached to the instance."
  type        = list(string)
}

variable "tags" {
  description = "Extra tags."
  type        = map(string)
  default     = {}
}
