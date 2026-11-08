variable "project_name" {
  description = "Prefix applied to every resource name."
  type        = string
  default     = "togglemaster"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "eks_cluster_version" {
  type    = string
  default = "1.31"
}

variable "node_instance_types" {
  # Fase 4: t3.medium (4 GiB, máx. 17 pods/nó por limite de ENI/IP do VPC
  # CNI) não comporta a stack de observabilidade (Prometheus, Grafana, Loki,
  # OTel Collector agent+gateway) junto com os 5 serviços, ArgoCD e KEDA.
  # t3.large dá 8 GiB e até 35 pods por nó.
  type    = list(string)
  default = ["t3.large"]
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "rds_databases" {
  description = "One RDS PostgreSQL instance per ToggleMaster service that owns data."
  type = map(object({
    db_name = string
  }))
  default = {
    auth = {
      db_name = "auth_db"
    }
    flag = {
      db_name = "flags_db"
    }
    targeting = {
      db_name = "targeting_db"
    }
  }
}

variable "rds_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "redis_node_type" {
  type    = string
  default = "cache.t3.micro"
}

variable "dynamodb_table_name" {
  type    = string
  default = "ToggleMasterAnalytics"
}

variable "sqs_queue_name" {
  type    = string
  default = "evaluation-analytics"
}

variable "ecr_repository_names" {
  type = list(string)
  default = [
    "auth-service",
    "flag-service",
    "targeting-service",
    "evaluation-service",
    "analytics-service",
  ]
}

locals {
  common_tags = {
    Project     = var.project_name
    ManagedBy   = "terraform"
    Environment = "tech-challenge-fase-3"
  }
}
