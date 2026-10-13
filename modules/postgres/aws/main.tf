resource "aws_db_instance" "this" {
  identifier        = var.identifier
  engine            = "postgres"
  engine_version    = var.engine_version
  instance_class    = var.instance_class
  allocated_storage = var.allocated_storage
  storage_encrypted = true
  db_name           = var.database_name

  # RDS generates the master password and stores it in Secrets Manager, so it
  # never appears in code or in Terraform state.
  username                            = var.master_username
  manage_master_user_password         = true
  iam_database_authentication_enabled = true

  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = var.vpc_security_group_ids
  publicly_accessible    = false

  # Recovery: automated backups plus transaction logs give point-in-time
  # restore to a new instance anywhere inside this window.
  backup_retention_period  = var.backup_retention_period
  copy_tags_to_snapshot    = true
  delete_automated_backups = false

  # Prevention: the API refuses DeleteDBInstance while this is true, for any
  # caller. Turning it off is a separate, logged ModifyDBInstance call.
  deletion_protection = true

  # If the instance is ever deleted on purpose, keep a final snapshot.
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.identifier}-final"

  tags = merge(var.tags, {
    environment = var.environment
    managed-by  = "terraform"
  })

  lifecycle {
    prevent_destroy = true
  }
}
