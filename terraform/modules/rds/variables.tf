variable "project_name" {
  type = string
}

variable "databases" {
  description = "One RDS PostgreSQL instance is created per entry. Key is a short name (auth, flag, targeting)."
  type = map(object({
    db_name = string
  }))
}

variable "engine_version" {
  description = "Major-version only on purpose: AWS periodically deprecates exact minor versions (e.g. 15.7), so pinning one causes 'Cannot find version X for postgres' at apply time. Specifying just the major version lets RDS pick the latest supported minor automatically."
  type        = string
  default     = "15"
}

variable "instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "master_username" {
  type    = string
  default = "postgres"
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security groups (e.g. EKS node group SG) allowed to reach Postgres on 5432."
  type        = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}
