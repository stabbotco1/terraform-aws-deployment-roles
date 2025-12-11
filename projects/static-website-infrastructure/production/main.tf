terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    # Configuration loaded from backend.tfbackend
  }
}

provider "aws" {
  region = var.aws_region
}

# Get repository URL (normalize to HTTPS, keep .git)
data "external" "git_remote" {
  program = ["bash", "-c", "echo '{\"repository\":\"'$(git remote get-url origin | sed 's|git@github.com:|https://github.com/|')'\"}'"]
}

# Get deployer ARN
data "aws_caller_identity" "current" {}

# Retrieve foundation parameters
data "aws_ssm_parameter" "deployment_roles_role_arn" {
  name = "/terraform/foundation/deployment-roles-role-arn"
}

# Standard tags module
module "tags" {
  source = "../../../modules/standard-tags"

  project       = var.project_name
  repository    = data.external.git_remote.result.repository
  environment   = var.environment
  owner         = var.owner
  deployed_by   = data.aws_caller_identity.current.arn
  managed_by    = var.managed_by
  deployment_id = var.deployment_id

  additional_tags = var.additional_tags
}

# Deployment role module
module "deployment_role" {
  source = "../../../modules/deployment-role"

  project_name      = var.project_name
  environment       = var.environment
  github_repository = var.github_repository
  policy_file_path  = "${path.module}/policies/deployment-policy.json"

  tags = module.tags.tags
}

# Outputs
output "role_arn" {
  description = "ARN of the deployment role"
  value       = module.deployment_role.role_arn
}

output "role_name" {
  description = "Name of the deployment role"
  value       = module.deployment_role.role_name
}

output "policy_arn" {
  description = "ARN of the deployment policy"
  value       = module.deployment_role.policy_arn
}

output "ssm_parameter_name" {
  description = "SSM parameter name storing the role ARN for consuming projects"
  value       = module.deployment_role.ssm_parameter_name
}
