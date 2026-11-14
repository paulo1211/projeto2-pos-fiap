provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# Autenticação via exec: o token do EKS vale só 15 min. Com o data source
# aws_eks_cluster_auth o token é gerado no plan e expira durante applies longos
# (RDS/EKS) ou quando o tfplan é aplicado depois -> "Error: Unauthorized".
# O exec gera um token novo a cada chamada, usando as mesmas credenciais AWS
# do terminal (no Academy, as de .academy/env). Requer o AWS CLI instalado.
locals {
  eks_exec_args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.eks_exec_args
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.eks_exec_args
    }
  }
}
