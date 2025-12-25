terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Retrieve OIDC provider ARN from SSM Parameter Store
data "aws_ssm_parameter" "oidc_provider_arn" {
  name = "/terraform/foundation/oidc-provider"
}

# Extract OIDC provider URL from ARN
locals {
  oidc_provider_arn = data.aws_ssm_parameter.oidc_provider_arn.value
  oidc_provider_url = replace(local.oidc_provider_arn, "/^arn:aws:iam::\\d+:oidc-provider\\//", "")
}

# IAM Role with OIDC trust policy
resource "aws_iam_role" "deployment" {
  name               = "gharole-${var.project_name}-${var.environment}"
  description        = "Deployment role for ${var.project_name} ${var.environment} via GitHub Actions"
  assume_role_policy = data.aws_iam_policy_document.trust_policy.json
  tags               = var.tags
}

# Trust policy allowing GitHub Actions to assume role
data "aws_iam_policy_document" "trust_policy" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["repo:${var.github_repository}:*"]
    }
  }
}

# Managed policy from JSON file
resource "aws_iam_policy" "deployment" {
  name        = "ghpolicy-${var.project_name}-${var.environment}"
  description = "Deployment permissions for ${var.project_name} ${var.environment}"
  policy      = file(var.policy_file_path)
  tags        = var.tags
}

# Attach policy to role
resource "aws_iam_role_policy_attachment" "deployment" {
  role       = aws_iam_role.deployment.name
  policy_arn = aws_iam_policy.deployment.arn
}

# Store role ARN in SSM Parameter Store for consuming projects
resource "aws_ssm_parameter" "role_arn" {
  name        = "/deployment-roles/${var.project_name}/role-arn"
  type        = "String"
  value       = aws_iam_role.deployment.arn
  description = "Deployment role ARN for ${var.project_name}"
  tags        = var.tags
}
