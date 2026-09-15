output "endpoints" {
  description = "Map of db key -> host:port"
  value       = { for k, v in aws_db_instance.this : k => "${v.address}:${v.port}" }
}

output "secret_arns" {
  description = "Map of db key -> Secrets Manager ARN holding the connection string."
  value       = { for k, v in aws_secretsmanager_secret.db_credentials : k => v.arn }
}

output "security_group_ids" {
  value = { for k, v in aws_security_group.rds : k => v.id }
}
