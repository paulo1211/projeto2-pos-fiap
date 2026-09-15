variable "namespace" {
  type    = string
  default = "keda"
}

variable "chart_version" {
  description = "Version of the keda Helm chart from the kedacore repo."
  type        = string
  default     = "2.16.1"
}
