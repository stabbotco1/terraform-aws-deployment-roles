variable "project" {
  description = "Project name from git remote"
  type        = string
}

variable "repository" {
  description = "Full repository URL"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., Production, Development)"
  type        = string
}

variable "owner" {
  description = "Resource owner"
  type        = string
  default     = "StephenAbbot"
}

variable "deployed_by" {
  description = "IAM principal that deployed the stack"
  type        = string
  default     = ""
}

variable "managed_by" {
  description = "Management tool"
  type        = string
  default     = "OpenTofu"
}

variable "deployment_id" {
  description = "Deployment identifier"
  type        = string
  default     = "Default"
}

variable "additional_tags" {
  description = "Additional tags to merge"
  type        = map(string)
  default     = {}
}
