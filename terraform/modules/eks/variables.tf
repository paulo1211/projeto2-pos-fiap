variable "project_name" {
  type = string
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS control plane."
  type        = string
  default     = "1.30"
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  description = "Subnets used by the managed node group (private, so worker nodes are not directly internet-facing)."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Subnets registered with the EKS control plane for API access; kept public here to avoid a NAT-only setup during a portfolio/study deployment."
  type        = list(string)
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
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

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT."
  type        = string
  default     = "ON_DEMAND"
}

variable "node_ami_type" {
  description = "AL2 is EOL for recent Kubernetes minor versions; AL2023 is the current AWS-recommended default and avoids 'Requested AMI for this version is not supported' errors."
  type        = string
  default     = "AL2023_x86_64_STANDARD"
}

variable "use_lab_role" {
  description = "AWS Academy: usa a LabRole existente em vez de criar roles/OIDC (IAM bloqueado no Learner Lab)."
  type        = bool
  default     = true
}

variable "lab_role_name" {
  description = "Nome da role pré-criada pelo AWS Academy, usada pelo cluster e pelos nós quando use_lab_role = true."
  type        = string
  default     = "LabRole"
}

variable "tags" {
  type    = map(string)
  default = {}
}
