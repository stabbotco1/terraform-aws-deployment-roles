terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    # Configuration loaded dynamically by deploy script
  }
}

provider "aws" {
  region = "us-east-1"
}

# Get current caller identity and region
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Get git remote URL for project identification
data "external" "git_info" {
  program = ["bash", "-c", <<-EOT
    REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
    if [[ "$REMOTE_URL" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
      PROJECT_NAME="$${BASH_REMATCH[2]}"
      REPO_URL="$REMOTE_URL"
      GITHUB_REPO="$${BASH_REMATCH[1]}/$${BASH_REMATCH[2]}"
    else
      PROJECT_NAME="unknown"
      REPO_URL="unknown"
      GITHUB_REPO="unknown/unknown"
    fi
    echo "{\"project_name\":\"$PROJECT_NAME\",\"repository\":\"$REPO_URL\",\"github_repository\":\"$GITHUB_REPO\"}"
  EOT
  ]
}

# Discover all project directories
locals {
  # Find all project/environment combinations
  project_paths = fileset("${path.module}/projects", "**/*/policies/deployment-policy.json")
  
  # Parse project structure: projects/{project}/{environment}/policies/deployment-policy.json
  projects = {
    for file_path in local.project_paths :
    "${split("/", file_path)[0]}-${split("/", file_path)[1]}" => {
      project_name = split("/", file_path)[0]
      environment  = split("/", file_path)[1]
      policy_path  = "${path.root}/projects/${file_path}"
    }
  }

  # Git information
  git_project_name    = data.external.git_info.result.project_name
  git_repository      = data.external.git_info.result.repository
  git_github_repo     = data.external.git_info.result.github_repository
}

# Standard tags for all resources
module "standard_tags" {
  for_each = local.projects

  source = "./modules/standard-tags"

  project       = local.git_project_name
  repository    = local.git_repository
  environment   = each.value.environment
  owner         = "StephenAbbot"
  deployed_by   = data.aws_caller_identity.current.arn
  managed_by    = "OpenTofu"
  deployment_id = "Default"
}

# Deploy role for each project/environment
module "deployment_roles" {
  for_each = local.projects

  source = "./modules/deployment-role"

  project_name      = each.value.project_name
  environment       = each.value.environment
  github_repository = "${split("/", local.git_github_repo)[0]}/${each.value.project_name}"
  policy_file_path  = each.value.policy_path

  tags = module.standard_tags[each.key].tags
}

# Outputs
output "deployed_roles" {
  description = "Information about all deployed roles"
  value = {
    for key, role in module.deployment_roles : key => {
      role_arn           = role.role_arn
      role_name          = role.role_name
      policy_arn         = role.policy_arn
      ssm_parameter_name = role.ssm_parameter_name
      project_name       = local.projects[key].project_name
      environment        = local.projects[key].environment
    }
  }
}

output "git_info" {
  description = "Git repository information"
  value = {
    project_name    = local.git_project_name
    repository      = local.git_repository
    github_repo     = local.git_github_repo
  }
}
