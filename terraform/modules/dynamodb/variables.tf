variable "table_name" {
  type    = string
  default = "ToggleMasterAnalytics"
}

variable "hash_key" {
  type    = string
  default = "event_id"
}

variable "tags" {
  type    = map(string)
  default = {}
}
