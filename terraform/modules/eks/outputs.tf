output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_arn" {
  value = aws_eks_cluster.this.arn
}

output "cluster_security_group_id" {
  description = "Security group EKS attaches to the cluster ENIs and worker nodes; used to authorize DB/cache access."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  value = aws_iam_openid_connect_provider.eks.url
}

output "workload_irsa_role_name" {
  value = aws_iam_role.workload_irsa.name
}

output "workload_irsa_role_arn" {
  value = aws_iam_role.workload_irsa.arn
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}
