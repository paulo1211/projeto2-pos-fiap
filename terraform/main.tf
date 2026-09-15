module "networking" {
  source = "./modules/networking"

  project_name         = var.project_name
  vpc_cidr             = var.vpc_cidr
  azs                  = var.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  tags                 = local.common_tags
}

module "eks" {
  source = "./modules/eks"

  project_name        = var.project_name
  cluster_version     = var.eks_cluster_version
  vpc_id              = module.networking.vpc_id
  private_subnet_ids  = module.networking.private_subnet_ids
  public_subnet_ids   = module.networking.public_subnet_ids
  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  tags                = local.common_tags
}

module "rds" {
  source = "./modules/rds"

  project_name               = var.project_name
  databases                  = var.rds_databases
  instance_class             = var.rds_instance_class
  vpc_id                     = module.networking.vpc_id
  private_subnet_ids         = module.networking.private_subnet_ids
  allowed_security_group_ids = [module.eks.cluster_security_group_id]
  tags                       = local.common_tags
}

module "elasticache" {
  source = "./modules/elasticache"

  project_name               = var.project_name
  node_type                  = var.redis_node_type
  vpc_id                     = module.networking.vpc_id
  private_subnet_ids         = module.networking.private_subnet_ids
  allowed_security_group_ids = [module.eks.cluster_security_group_id]
  tags                       = local.common_tags
}

module "dynamodb" {
  source = "./modules/dynamodb"

  table_name = var.dynamodb_table_name
  tags       = local.common_tags
}

module "sqs" {
  source = "./modules/sqs"

  queue_name = var.sqs_queue_name
  tags       = local.common_tags
}

module "ecr" {
  source = "./modules/ecr"

  repository_names = var.ecr_repository_names
  tags             = local.common_tags
}

module "argocd" {
  source = "./modules/argocd"

  depends_on = [module.eks]
}

# --- IRSA permissions for the workload service account ---------------------
# Grants the ServiceAccount used by evaluation-service/analytics-service
# (system:serviceaccount:togglemaster:togglemaster-workload, see
# terraform/modules/eks) just enough access to SQS + DynamoDB, replacing the
# long-lived AWS_ACCESS_KEY_ID/SECRET_ACCESS_KEY env vars from Phase 2.

resource "aws_iam_role_policy" "workload_permissions" {
  name = "${var.project_name}-workload-permissions"
  role = module.eks.workload_irsa_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SQSAccess"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = module.sqs.queue_arn
      },
      {
        Sid    = "DynamoDBAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:Scan",
        ]
        Resource = module.dynamodb.table_arn
      },
    ]
  })
}
