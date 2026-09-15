variable "namespace" {
  type    = string
  default = "keda"
}

variable "chart_version" {
  description = "Version of the keda Helm chart from the kedacore repo."
  type        = string
  default     = "2.16.1"
}

variable "operator_role_arn" {
  description = "IRSA role ARN annotated onto the keda-operator ServiceAccount so scalers (e.g. aws-sqs-queue) can authenticate to AWS without relying on the target workload's pod identity."
  type        = string
}
