output "vpc_id" {
  value = module.networking.vpc_id
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_update_kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

output "rds_endpoints" {
  value = module.rds.endpoints
}

output "rds_secret_arns" {
  description = "Secrets Manager ARNs holding each database's connection string (see terraform/scripts/sync-secrets.sh)."
  value       = module.rds.secret_arns
}

output "redis_primary_endpoint" {
  value = module.elasticache.primary_endpoint
}

output "dynamodb_table_name" {
  value = module.dynamodb.table_name
}

output "sqs_queue_url" {
  value = module.sqs.queue_url
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "workload_irsa_role_arn" {
  value = module.eks.workload_irsa_role_arn
}

output "argocd_namespace" {
  value = module.argocd.namespace
}
