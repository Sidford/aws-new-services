variable "email_recipients" {
  description = "Email addresses for SCP change alerts"
  type        = list(string)
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
}
