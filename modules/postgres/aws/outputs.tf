output "instance_identifier" {
  description = "RDS instance identifier."
  value       = aws_db_instance.this.identifier
}

output "endpoint" {
  description = "Host and port clients connect to."
  value       = aws_db_instance.this.endpoint
}

output "master_user_secret_arn" {
  description = "Secrets Manager ARN holding the generated master password."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "backup_retention_period" {
  description = "Effective PITR window."
  value       = aws_db_instance.this.backup_retention_period
}
