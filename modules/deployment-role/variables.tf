variable "project_name" {
  description = "Project name (e.g., website-foundation)"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., production, staging)"
  type        = string
}

variable "github_repository" {
  description = "GitHub repository in format org/repo (e.g., myorg/myrepo)"
  type        = string
}

variable "policy_file_path" {
  description = "Path to IAM policy JSON file"
  type        = string
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
