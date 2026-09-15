variable "queue_name" {
  type    = string
  default = "evaluation-analytics"
}

variable "visibility_timeout_seconds" {
  type    = number
  default = 30
}

variable "message_retention_seconds" {
  type    = number
  default = 345600 # 4 days
}

variable "max_receive_count" {
  description = "Number of deliveries before a message goes to the DLQ."
  type        = number
  default     = 5
}

variable "tags" {
  type    = map(string)
  default = {}
}
