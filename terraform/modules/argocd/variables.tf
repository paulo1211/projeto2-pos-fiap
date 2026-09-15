variable "namespace" {
  type    = string
  default = "argocd"
}

variable "chart_version" {
  description = "Version of the argo-cd Helm chart from the argoproj repo."
  type        = string
  default     = "7.7.11"
}
