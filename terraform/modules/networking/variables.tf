variable "project_name" {
  description = "Prefix used to name every networking resource."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability zones to spread subnets across."
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets (one per AZ)."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the private subnets (one per AZ)."
  type        = list(string)
}

variable "single_nat_gateway" {
  description = "If true, provisions a single NAT Gateway shared by all private subnets instead of one per AZ (cheaper for a study/portfolio environment)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default     = {}
}
