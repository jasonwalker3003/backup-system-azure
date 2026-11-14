variable "prefix" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9]{3,11}$", var.prefix))
    error_message = "Use 3-11 lowercase letters or digits."
  }
}

variable "alert_email" {
  type      = string
  sensitive = true
}

variable "retention_days" {
  description = "How long each saved version is locked. 1 day in the lab; a real firm might use 30."
  type        = number
  default     = 1
}

variable "missed_backup_window" {
  description = "How long without a heartbeat before alerting. P1D = 1 day; PT1H is for testing."
  type        = string
  default     = "P1D"
}
