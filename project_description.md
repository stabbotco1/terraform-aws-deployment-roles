# Terraform AWS Deployment Roles - Project Blueprint

## Project Overview

Repository for managing IAM deployment roles used by GitHub Actions to deploy Terraform-managed AWS infrastructure. Each role represents deployment permissions for a specific project and environment.

Repository: terraform-aws-deployment-roles
Purpose: Create and manage IAM roles with OIDC authentication for CI/CD deployments
Dependencies: terraform-aws-cfn-foundation (provides S3 state bucket, DynamoDB lock table, OIDC provider)

## Architecture Principles

1. One IAM role per project-environment combination
2. Roles assumed by GitHub Actions via OIDC (no long-lived credentials)
3. Policies start broad, refined to least-privilege using IAM Access Analyzer
4. Modular structure supporting copy-paste project creation
5. Shared tagging standards across all projects
6. Idempotent bash scripts enforce deployment contracts

## Directory Structure

```
terraform-aws-deployment-roles/
├── .env                              # Environment configuration (committed)
├── .gitignore
├── README.md
├── modules/
│   ├── deployment-role/              # Reusable role module
│   │   ├── main.tf                   # Role + trust policy resources
│   │   ├── policies.tf               # Policy attachment logic
│   │   ├── variables.tf              # Module inputs
│   │   └── outputs.tf                # Role ARN, name outputs
│   └── standard-tags/                # Tag defaults + merging
│       ├── variables.tf              # Tag inputs with defaults
│       └── outputs.tf                # Merged tag map
├── projects/
│   ├── website-foundation/
│   │   └── production/
│   │       ├── .env                  # Project-environment config
│   │       ├── main.tf               # Terraform root
│   │       ├── variables.tf          # Input variables
│   │       ├── backend.tfbackend     # Backend configuration
│   │       ├── tags.tf               # Tag overrides
│   │       ├── policies/
│   │       │   └── deployment-policy.json  # IAM policy document
│   │       └── scripts/
│   │           ├── deploy.sh         # Deploy Terraform
│   │           ├── destroy.sh        # Destroy resources
│   │           ├── list-deployed-resources.sh
│   │           └── verify-prerequisites.sh
│   ├── website-static/
│   │   └── production/
│   │       └── [same structure]
│   └── governance/
│       └── production/
│           └── [same structure]
├── templates/
│   └── new-project/
│       └── production/
│           ├── .env.template
│           ├── main.tf.template
│           ├── variables.tf.template
│           ├── backend.tfbackend.template
│           ├── tags.tf.template
│           ├── policies/
│           │   └── deployment-policy.json.template
│           └── scripts/
│               ├── deploy.sh
│               ├── destroy.sh
│               ├── list-deployed-resources.sh
│               └── verify-prerequisites.sh
└── scripts/
    └── create-project.sh             # Template instantiation helper
```

## Module Specifications

### modules/deployment-role

Purpose: Create IAM role with OIDC trust policy and attach managed policy

main.tf:

```hcl
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
  name               = "github-actions-${var.project_name}-${var.environment}-deployment-role"
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
  name        = "github-actions-${var.project_name}-${var.environment}-deployment-policy"
  description = "Deployment permissions for ${var.project_name} ${var.environment}"
  policy      = file(var.policy_file_path)
  tags        = var.tags
}

# Attach policy to role
resource "aws_iam_role_policy_attachment" "deployment" {
  role       = aws_iam_role.deployment.name
  policy_arn = aws_iam_policy.deployment.arn
}
```

policies.tf:

```hcl
# Policy attachment handled in main.tf
# This file reserved for future policy management logic
```

variables.tf:

```hcl
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
```

outputs.tf:

```hcl
output "role_arn" {
  description = "ARN of the deployment role"
  value       = aws_iam_role.deployment.arn
}

output "role_name" {
  description = "Name of the deployment role"
  value       = aws_iam_role.deployment.name
}

output "policy_arn" {
  description = "ARN of the deployment policy"
  value       = aws_iam_policy.deployment.arn
}
```

### modules/standard-tags

Purpose: Provide consistent tagging across all resources with project-level overrides

variables.tf:

```hcl
variable "environment" {
  description = "Environment name"
  type        = string
}

variable "project_name" {
  description = "Project name"
  type        = string
}

variable "owner" {
  description = "Resource owner"
  type        = string
  default     = "Platform Team"
}

variable "managed_by" {
  description = "Management tool"
  type        = string
  default     = "Terraform"
}

variable "cost_center" {
  description = "Cost center code"
  type        = string
  default     = ""
}

variable "additional_tags" {
  description = "Additional tags to merge"
  type        = map(string)
  default     = {}
}
```

outputs.tf:

```hcl
locals {
  base_tags = {
    Environment = var.environment
    Project     = var.project_name
    Owner       = var.owner
    ManagedBy   = var.managed_by
  }

  cost_center_tag = var.cost_center != "" ? {
    CostCenter = var.cost_center
  } : {}

  all_tags = merge(
    local.base_tags,
    local.cost_center_tag,
    var.additional_tags
  )
}

output "tags" {
  description = "Merged tags for resource tagging"
  value       = local.all_tags
}
```

## Project Template Structure

### templates/new-project/production/.env.template

```bash
# Project Configuration
PROJECT_NAME=__PROJECT_NAME__
ENVIRONMENT=production
GITHUB_REPOSITORY=__GITHUB_ORG__/__GITHUB_REPO__

# AWS Configuration
AWS_REGION=us-east-1

# Tags
TAG_OWNER=Platform Team
TAG_COST_CENTER=

# Backend Configuration
BACKEND_KEY=deployment-roles/__PROJECT_NAME__/production/terraform.tfstate
```

### templates/new-project/production/main.tf.template

```hcl
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

# Retrieve foundation parameters
data "aws_ssm_parameter" "deployment_roles_role_arn" {
  name = "/terraform/foundation/deployment-roles-role-arn"
}

# Standard tags module
module "tags" {
  source = "../../../modules/standard-tags"

  environment  = var.environment
  project_name = var.project_name
  owner        = var.owner
  cost_center  = var.cost_center

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
```

### templates/new-project/production/variables.tf.template

```hcl
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "github_repository" {
  description = "GitHub repository (org/repo)"
  type        = string
}

variable "owner" {
  description = "Resource owner"
  type        = string
  default     = "Platform Team"
}

variable "cost_center" {
  description = "Cost center code"
  type        = string
  default     = ""
}

variable "additional_tags" {
  description = "Additional resource tags"
  type        = map(string)
  default     = {}
}
```

### templates/new-project/production/backend.tfbackend.template

```hcl
# Backend configuration
# Values retrieved from SSM parameters by deploy.sh
```

### templates/new-project/production/tags.tf.template

```hcl
# Project-specific tag overrides
# Modify additional_tags variable in main.tf or pass via terraform.tfvars
```

### templates/new-project/production/policies/deployment-policy.json.template

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "*",
      "Resource": "*"
    }
  ]
}
```

## Script Implementation Patterns

Scripts follow CloudFormation foundation patterns with Terraform-specific adaptations.

### Common Script Behaviors

1. Set strict error handling: `set -euo pipefail`
2. Disable AWS CLI pager: `export AWS_PAGER=""`
3. Load .env file if present
4. Support parameter overrides via environment variables
5. Validate prerequisites before operations
6. Provide clear step-by-step output
7. Handle idempotent operations gracefully
8. Return meaningful exit codes

### Environment Variable Precedence

1. Environment variables (highest priority)
2. Command-line parameters
3. .env file values (lowest priority)

### scripts/deploy.sh Implementation

Located at: projects/{project-name}/{environment}/scripts/deploy.sh

Purpose: Deploy or update Terraform-managed IAM role

Key responsibilities:

1. Verify prerequisites (git state, AWS authentication, Terraform installed)
2. Load configuration from .env with parameter overrides
3. Retrieve backend configuration from SSM parameters
4. Assume deployment-roles-role if not using admin credentials
5. Initialize Terraform backend
6. Plan and apply Terraform changes
7. Output role ARN and next steps

Implementation pattern:

```bash
#!/usr/bin/env bash
set -euo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Verify prerequisites
echo "Step 1: Verifying prerequisites..."
"${SCRIPT_DIR}/verify-prerequisites.sh" || exit 1

# Load .env file
if [[ -f "${PROJECT_ROOT}/.env" ]]; then
  set -a
  source "${PROJECT_ROOT}/.env"
  set +a
fi

# Parameter overrides
PROJECT_NAME="${1:-${PROJECT_NAME:-}}"
ENVIRONMENT="${2:-${ENVIRONMENT:-production}}"

# Validation
if [[ -z "${PROJECT_NAME}" ]]; then
  echo "Error: PROJECT_NAME required (set in .env or pass as argument)"
  exit 1
fi

# Retrieve foundation parameters from SSM
echo "Step 2: Retrieving foundation configuration..."
STATE_BUCKET=$(aws ssm get-parameter \
  --name /terraform/foundation/s3-state-bucket \
  --query Parameter.Value --output text)

LOCK_TABLE=$(aws ssm get-parameter \
  --name /terraform/foundation/dynamodb-lock-table \
  --query Parameter.Value --output text)

DEPLOYMENT_ROLE_ARN=$(aws ssm get-parameter \
  --name /terraform/foundation/deployment-roles-role-arn \
  --query Parameter.Value --output text)

echo "  State Bucket: ${STATE_BUCKET}"
echo "  Lock Table: ${LOCK_TABLE}"
echo "  Deployment Role: ${DEPLOYMENT_ROLE_ARN}"

# Assume deployment role if needed
# (Skip if already using admin or if role assumption fails)
CALLER_IDENTITY=$(aws sts get-caller-identity --query Arn --output text)
if [[ ! "${CALLER_IDENTITY}" =~ assumed-role/.*deployment-roles-role ]]; then
  echo ""
  echo "Step 3: Assuming deployment role..."
  
  TEMP_CREDS=$(aws sts assume-role \
    --role-arn "${DEPLOYMENT_ROLE_ARN}" \
    --role-session-name "terraform-deploy-${PROJECT_NAME}-${ENVIRONMENT}" \
    --query 'Credentials' --output json) || {
    echo "Warning: Could not assume deployment role, continuing with current credentials"
  }
  
  if [[ -n "${TEMP_CREDS}" ]]; then
    export AWS_ACCESS_KEY_ID=$(echo "${TEMP_CREDS}" | jq -r .AccessKeyId)
    export AWS_SECRET_ACCESS_KEY=$(echo "${TEMP_CREDS}" | jq -r .SecretAccessKey)
    export AWS_SESSION_TOKEN=$(echo "${TEMP_CREDS}" | jq -r .SessionToken)
    echo "  Role assumed successfully"
  fi
fi

# Initialize Terraform backend
echo ""
echo "Step 4: Initializing Terraform..."
terraform init \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="dynamodb_table=${LOCK_TABLE}" \
  -backend-config="key=${BACKEND_KEY}" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="encrypt=true" \
  -reconfigure

# Plan changes
echo ""
echo "Step 5: Planning Terraform changes..."
terraform plan \
  -var="project_name=${PROJECT_NAME}" \
  -var="environment=${ENVIRONMENT}" \
  -var="github_repository=${GITHUB_REPOSITORY}" \
  -var="aws_region=${AWS_REGION}" \
  -out=tfplan

# Apply changes
echo ""
echo "Step 6: Applying Terraform changes..."
terraform apply tfplan

# Get outputs
echo ""
echo "Step 7: Retrieving deployment outputs..."
ROLE_ARN=$(terraform output -raw role_arn)
ROLE_NAME=$(terraform output -raw role_name)

echo ""
echo "Deployment complete"
echo ""
echo "Created resources:"
echo "  Role ARN: ${ROLE_ARN}"
echo "  Role Name: ${ROLE_NAME}"
echo ""
echo "Next steps:"
echo "  1. Configure GitHub Actions to use this role"
echo "  2. Test deployment from CI/CD pipeline"
echo "  3. Analyze CloudTrail logs and refine permissions"
echo ""

rm -f tfplan
```

### scripts/destroy.sh Implementation

Located at: projects/{project-name}/{environment}/scripts/destroy.sh

Purpose: Destroy Terraform-managed resources with safety confirmations

Key responsibilities:

1. Verify prerequisites
2. Load configuration
3. Require typed confirmation ("DESTROY")
4. Assume deployment role
5. Initialize backend and destroy resources
6. Clean up local state files

Implementation pattern:

```bash
#!/usr/bin/env bash
set -euo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env
if [[ -f "${PROJECT_ROOT}/.env" ]]; then
  set -a
  source "${PROJECT_ROOT}/.env"
  set +a
fi

PROJECT_NAME="${1:-${PROJECT_NAME:-}}"
ENVIRONMENT="${2:-${ENVIRONMENT:-production}}"

if [[ -z "${PROJECT_NAME}" ]]; then
  echo "Error: PROJECT_NAME required"
  exit 1
fi

# Check if resources exist
echo "Checking for deployed resources..."
STATE_BUCKET=$(aws ssm get-parameter \
  --name /terraform/foundation/s3-state-bucket \
  --query Parameter.Value --output text)

LOCK_TABLE=$(aws ssm get-parameter \
  --name /terraform/foundation/dynamodb-lock-table \
  --query Parameter.Value --output text)

# Initialize to check state
terraform init \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="dynamodb_table=${LOCK_TABLE}" \
  -backend-config="key=${BACKEND_KEY}" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="encrypt=true" \
  -reconfigure &>/dev/null || true

# Check if state has resources
RESOURCE_COUNT=$(terraform state list 2>/dev/null | wc -l || echo "0")

if [[ "${RESOURCE_COUNT}" -eq 0 ]]; then
  echo "No resources found to destroy"
  exit 0
fi

# Show what will be destroyed
echo ""
echo "=========================================="
echo "DEPLOYMENT ROLE DESTRUCTION"
echo "=========================================="
echo ""
echo "Project: ${PROJECT_NAME}"
echo "Environment: ${ENVIRONMENT}"
echo ""
echo "This will permanently delete:"
terraform state list | sed 's/^/  - /'
echo ""
echo "This action is IRREVERSIBLE."
echo ""

# Require confirmation
read -p "Type 'DESTROY' to confirm: " confirmation

if [[ "${confirmation}" != "DESTROY" ]]; then
  echo "Destruction cancelled"
  exit 0
fi

# Assume deployment role
DEPLOYMENT_ROLE_ARN=$(aws ssm get-parameter \
  --name /terraform/foundation/deployment-roles-role-arn \
  --query Parameter.Value --output text)

CALLER_IDENTITY=$(aws sts get-caller-identity --query Arn --output text)
if [[ ! "${CALLER_IDENTITY}" =~ assumed-role/.*deployment-roles-role ]]; then
  echo ""
  echo "Assuming deployment role..."
  
  TEMP_CREDS=$(aws sts assume-role \
    --role-arn "${DEPLOYMENT_ROLE_ARN}" \
    --role-session-name "terraform-destroy-${PROJECT_NAME}-${ENVIRONMENT}" \
    --query 'Credentials' --output json) || {
    echo "Warning: Could not assume deployment role, continuing with current credentials"
  }
  
  if [[ -n "${TEMP_CREDS}" ]]; then
    export AWS_ACCESS_KEY_ID=$(echo "${TEMP_CREDS}" | jq -r .AccessKeyId)
    export AWS_SECRET_ACCESS_KEY=$(echo "${TEMP_CREDS}" | jq -r .SecretAccessKey)
    export AWS_SESSION_TOKEN=$(echo "${TEMP_CREDS}" | jq -r .SessionToken)
  fi
fi

# Destroy resources
echo ""
echo "Destroying resources..."
terraform destroy \
  -var="project_name=${PROJECT_NAME}" \
  -var="environment=${ENVIRONMENT}" \
  -var="github_repository=${GITHUB_REPOSITORY}" \
  -var="aws_region=${AWS_REGION}" \
  -auto-approve

echo ""
echo "=========================================="
echo "DESTRUCTION COMPLETE"
echo "=========================================="
echo ""
echo "All deployment role resources have been destroyed."
echo ""

# Clean up local files
rm -f tfplan .terraform.lock.hcl
```

### scripts/list-deployed-resources.sh Implementation

Located at: projects/{project-name}/{environment}/scripts/list-deployed-resources.sh

Purpose: Display comprehensive inventory of deployed resources

Key responsibilities:

1. Load configuration
2. Initialize Terraform backend
3. Display Terraform state resources
4. Show IAM role details from AWS
5. Display policy details
6. Show trust policy configuration

Implementation pattern:

```bash
#!/usr/bin/env bash
set -euo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env
if [[ -f "${PROJECT_ROOT}/.env" ]]; then
  set -a
  source "${PROJECT_ROOT}/.env"
  set +a
fi

PROJECT_NAME="${PROJECT_NAME:-}"
ENVIRONMENT="${ENVIRONMENT:-production}"

echo "Listing deployed resources for ${PROJECT_NAME} ${ENVIRONMENT}..."
echo ""

# Retrieve backend config
STATE_BUCKET=$(aws ssm get-parameter \
  --name /terraform/foundation/s3-state-bucket \
  --query Parameter.Value --output text)

LOCK_TABLE=$(aws ssm get-parameter \
  --name /terraform/foundation/dynamodb-lock-table \
  --query Parameter.Value --output text)

# Initialize backend
terraform init \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="dynamodb_table=${LOCK_TABLE}" \
  -backend-config="key=${BACKEND_KEY}" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="encrypt=true" \
  -reconfigure &>/dev/null || {
  echo "Error: Failed to initialize Terraform backend"
  exit 1
}

# Get state resources
echo "=== Terraform State Resources ==="
RESOURCE_COUNT=$(terraform state list 2>/dev/null | wc -l || echo "0")

if [[ "${RESOURCE_COUNT}" -eq 0 ]]; then
  echo "No resources found in state"
  exit 0
fi

terraform state list

# Get outputs
echo ""
echo "=== Terraform Outputs ==="
if terraform output &>/dev/null; then
  terraform output
else
  echo "No outputs defined"
fi

# Get role details from AWS
echo ""
echo "=== IAM Role Details ==="
ROLE_ARN=$(terraform output -raw role_arn 2>/dev/null || echo "")

if [[ -n "${ROLE_ARN}" ]]; then
  ROLE_NAME=$(echo "${ROLE_ARN}" | cut -d'/' -f2)
  
  echo "Role ARN: ${ROLE_ARN}"
  echo "Role Name: ${ROLE_NAME}"
  
  # Role creation date
  CREATION_DATE=$(aws iam get-role --role-name "${ROLE_NAME}" \
    --query 'Role.CreateDate' --output text)
  echo "Created: ${CREATION_DATE}"
  
  # Attached policies
  echo ""
  echo "Attached Policies:"
  aws iam list-attached-role-policies --role-name "${ROLE_NAME}" \
    --query 'AttachedPolicies[].{Name:PolicyName,ARN:PolicyArn}' \
    --output table
  
  # Trust policy
  echo ""
  echo "Trust Policy:"
  aws iam get-role --role-name "${ROLE_NAME}" \
    --query 'Role.AssumeRolePolicyDocument' \
    --output json | jq .
  
  # Tags
  echo ""
  echo "Tags:"
  aws iam list-role-tags --role-name "${ROLE_NAME}" \
    --query 'Tags[].{Key:Key,Value:Value}' \
    --output table
else
  echo "Role not found in Terraform outputs"
fi

echo ""
echo "Resource listing complete"
```

### scripts/verify-prerequisites.sh Implementation

Located at: projects/{project-name}/{environment}/scripts/verify-prerequisites.sh

Purpose: Validate all prerequisites before deployment operations

Key responsibilities:

1. Check git repository state (clean, committed, pushed)
2. Verify AWS CLI installation and authentication
3. Check Terraform installation and version
4. Validate required tools (jq)
5. Verify AWS permissions (IAM, SSM)
6. Check for required files (policies, configuration)

Implementation pattern:

```bash
#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

FAILURES=()

echo "Verifying prerequisites for Terraform deployment..."
echo ""

check_git_repo() {
  if git rev-parse --git-dir &>/dev/null; then
    echo -e "${GREEN}✓${NC} Inside git repository"
    return 0
  else
    echo -e "${RED}✗${NC} Not in a git repository"
    FAILURES+=("Not in git repository")
    return 1
  fi
}

check_git_uncommitted() {
  if git diff-index --quiet HEAD -- 2>/dev/null; then
    echo -e "${GREEN}✓${NC} No uncommitted changes"
    return 0
  else
    echo -e "${RED}✗${NC} Uncommitted changes detected"
    FAILURES+=("Uncommitted changes")
    return 1
  fi
}

check_terraform() {
  if command -v terraform &>/dev/null; then
    TF_VERSION=$(terraform version -json | jq -r .terraform_version)
    echo -e "${GREEN}✓${NC} Terraform installed (Version: ${TF_VERSION})"
    return 0
  else
    echo -e "${RED}✗${NC} Terraform not found"
    FAILURES+=("Terraform not installed")
    return 1
  fi
}

check_aws_cli() {
  if command -v aws &>/dev/null; then
    AWS_VERSION=$(aws --version 2>&1 | cut -d/ -f2 | cut -d' ' -f1)
    echo -e "${GREEN}✓${NC} AWS CLI installed (Version: ${AWS_VERSION})"
    return 0
  else
    echo -e "${RED}✗${NC} AWS CLI not found"
    FAILURES+=("AWS CLI not installed")
    return 1
  fi
}

check_aws_auth() {
  if aws sts get-caller-identity &>/dev/null; then
    CALLER_ARN=$(aws sts get-caller-identity --query 'Arn' --output text)
    ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
    echo -e "${GREEN}✓${NC} AWS authentication valid"
    echo "  Account: ${ACCOUNT_ID}"
    echo "  Identity: ${CALLER_ARN}"
    return 0
  else
    echo -e "${RED}✗${NC} AWS authentication failed"
    FAILURES+=("AWS authentication")
    return 1
  fi
}

check_aws_permissions() {
  echo "Checking AWS permissions..."
  
  if aws iam list-roles --max-items 1 &>/dev/null; then
    echo -e "${GREEN}✓${NC} IAM permissions valid"
  else
    echo -e "${RED}✗${NC} IAM permissions insufficient"
    FAILURES+=("IAM permissions")
  fi
  
  if aws ssm describe-parameters --max-items 1 &>/dev/null; then
    echo -e "${GREEN}✓${NC} SSM permissions valid"
  else
    echo -e "${RED}✗${NC} SSM permissions insufficient"
    FAILURES+=("SSM permissions")
  fi
}

check_jq() {
  if command -v jq &>/dev/null; then
    JQ_VERSION=$(jq --version)
    echo -e "${GREEN}✓${NC} jq installed (Version: ${JQ_VERSION})"
    return 0
  else
    echo -e "${RED}✗${NC} jq not found"
    FAILURES+=("jq required")
    return 1
  fi
}

check_policy_file() {
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
  POLICY_FILE="${PROJECT_ROOT}/policies/deployment-policy.json"
  
  if [[ -f "${POLICY_FILE}" ]]; then
    echo -e "${GREEN}✓${NC} Policy file found"
    
    # Validate JSON
    if jq empty "${POLICY_FILE}" &>/dev/null; then
      echo -e "${GREEN}✓${NC} Policy file is valid JSON"
    else
      echo -e "${RED}✗${NC} Policy file contains invalid JSON"
      FAILURES+=("Invalid policy JSON")
    fi
  else
    echo -e "${RED}✗${NC} Policy file not found: ${POLICY_FILE}"
    FAILURES+=("Missing policy file")
  fi
}

check_foundation_parameters() {
  echo "Checking foundation parameters..."
  
  PARAMS=(
    "/terraform/foundation/s3-state-bucket"
    "/terraform/foundation/dynamodb-lock-table"
    "/terraform/foundation/oidc-provider"
    "/terraform/foundation/deployment-roles-role-arn"
  )
  
  for param in "${PARAMS[@]}"; do
    if aws ssm get-parameter --name "${param}" &>/dev/null; then
      echo -e "${GREEN}✓${NC} ${param}"
    else
      echo -e "${RED}✗${NC} ${param} (missing)"
      FAILURES+=("Missing parameter: ${param}")
    fi
  done
}

# Run checks
check_git_repo
check_git_uncommitted
check_terraform
check_aws_cli
check_aws_auth
check_aws_permissions
check_jq
check_policy_file
check_foundation_parameters

echo ""
if [[ ${#FAILURES[@]} -eq 0 ]]; then
  echo -e "${GREEN}✓ All prerequisites satisfied${NC}"
  exit 0
else
  echo -e "${RED}✗ Prerequisites check failed:${NC}"
  for failure in "${FAILURES[@]}"; do
    echo "  - ${failure}"
  done
  echo ""
  echo "Fix the above issues and try again."
  exit 1
fi
```

## Helper Script: scripts/create-project.sh

Located at repository root: scripts/create-project.sh

Purpose: Instantiate new project from template with automated find-replace

Usage:

```bash
./scripts/create-project.sh <project-name> <github-org>/<github-repo>
```

Implementation:

```bash
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <project-name> <github-org>/<github-repo>"
  echo ""
  echo "Example: $0 website-foundation myorg/website-foundation-infra"
  exit 1
fi

PROJECT_NAME="$1"
GITHUB_REPOSITORY="$2"
GITHUB_ORG=$(echo "${GITHUB_REPOSITORY}" | cut -d'/' -f1)
GITHUB_REPO=$(echo "${GITHUB_REPOSITORY}" | cut -d'/' -f2)

# Validate project name format
if [[ ! "${PROJECT_NAME}" =~ ^[a-z0-9-]+$ ]]; then
  echo "Error: Project name must contain only lowercase letters, numbers, and hyphens"
  exit 1
fi

# Check if project already exists
TARGET_DIR="projects/${PROJECT_NAME}/production"
if [[ -d "${TARGET_DIR}" ]]; then
  echo "Error: Project already exists: ${TARGET_DIR}"
  exit 1
fi

echo "Creating new project: ${PROJECT_NAME}"
echo "GitHub repository: ${GITHUB_REPOSITORY}"
echo ""

# Copy template
echo "Copying template files..."
mkdir -p "${TARGET_DIR}"
cp -r templates/new-project/production/* "${TARGET_DIR}/"

# Remove .template extensions and perform replacements
echo "Configuring project files..."
cd "${TARGET_DIR}"

for file in $(find . -name "*.template"); do
  target="${file%.template}"
  sed -e "s|__PROJECT_NAME__|${PROJECT_NAME}|g" \
      -e "s|__GITHUB_ORG__|${GITHUB_ORG}|g" \
      -e "s|__GITHUB_REPO__|${GITHUB_REPO}|g" \
      -e "s|__GITHUB_REPOSITORY__|${GITHUB_REPOSITORY}|g" \
      "${file}" > "${target}"
  rm "${file}"
done

# Make scripts executable
chmod +x scripts/*.sh

echo ""
echo "Project created successfully"
echo ""
echo "Next steps:"
echo "  1. Review and customize: ${TARGET_DIR}/.env"
echo "  2. Review and customize: ${TARGET_DIR}/policies/deployment-policy.json"
echo "  3. Review tags in: ${TARGET_DIR}/tags.tf"
echo "  4. Deploy: cd ${TARGET_DIR} && ./scripts/deploy.sh"
echo ""
```

## Root .env Configuration

```bash
# Global configuration for all projects
# Override in project-specific .env files

# AWS Configuration
AWS_REGION=us-east-1

# Default Tags
TAG_OWNER=Platform Team
TAG_MANAGED_BY=Terraform
```

## Root .gitignore

```
# Terraform
.terraform/
.terraform.lock.hcl
*.tfstate
*.tfstate.backup
*.tfplan
terraform.tfvars

# IDE
.vscode/
.idea/
*.swp
*.swo

# OS
.DS_Store
Thumbs.db

# Temporary files
*.tmp
*.log

# Do NOT ignore .env files (they contain non-sensitive config)
```

## Root README.md Content

```markdown
# Terraform AWS Deployment Roles

IAM role management for GitHub Actions deployments.

## Overview

This repository manages IAM roles that GitHub Actions workflows assume via OIDC to deploy AWS infrastructure. Each project-environment combination receives a dedicated role with appropriate permissions.

## Prerequisites

- AWS CLI installed and configured
- Terraform >= 1.0 installed
- jq installed
- Git repository with clean state
- Foundation infrastructure deployed (terraform-aws-cfn-foundation)

## Quick Start

Create a new project:

```bash
./scripts/create-project.sh website-foundation myorg/website-foundation-infra
```

Deploy the role:

```bash
cd projects/website-foundation/production
./scripts/deploy.sh
```

## Project Structure

```
projects/
  <project-name>/
    <environment>/
      .env                    # Configuration
      main.tf                 # Terraform root
      policies/
        deployment-policy.json  # IAM permissions
      scripts/
        deploy.sh             # Deploy role
        destroy.sh            # Destroy role
```

## Configuration

Each project-environment has an .env file:

```bash
PROJECT_NAME=website-foundation
ENVIRONMENT=production
GITHUB_REPOSITORY=myorg/website-foundation-infra
AWS_REGION=us-east-1
```

## Policy Evolution

1. Start with broad permissions (policies/deployment-policy.json)
2. Deploy infrastructure using the role
3. Analyze CloudTrail logs with IAM Access Analyzer
4. Update policy with refined permissions
5. Redeploy: `./scripts/deploy.sh`

## Commands

Deploy role:

```bash
cd projects/<project>/<environment>
./scripts/deploy.sh
```

List resources:

```bash
./scripts/list-deployed-resources.sh
```

Destroy role:

```bash
./scripts/destroy.sh
```

## GitHub Actions Integration

Configure workflow to assume the role:

```yaml
permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/github-actions-website-foundation-production-deployment-role
          aws-region: us-east-1
      
      - name: Deploy infrastructure
        run: terraform apply -auto-approve
```

## Tags

All roles are tagged with:

- Project
- Environment
- Owner
- ManagedBy
- CostCenter (optional)

Customize tags in project-specific tags.tf files.

```

## Initial Projects

### projects/website-foundation/production

Purpose: Deploy domain-specific SSL certificates, CloudFront distributions, S3 buckets

.env:
```bash
PROJECT_NAME=website-foundation
ENVIRONMENT=production
GITHUB_REPOSITORY=stabbotco1/website-foundation-infra
AWS_REGION=us-east-1
TAG_OWNER=Platform Team
TAG_COST_CENTER=Engineering
BACKEND_KEY=deployment-roles/website-foundation/production/terraform.tfstate
```

policies/deployment-policy.json:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "*",
      "Resource": "*"
    }
  ]
}
```

### projects/website-static/production

Purpose: Deploy static website content to S3 with CloudFront invalidation

.env:

```bash
PROJECT_NAME=website-static
ENVIRONMENT=production
GITHUB_REPOSITORY=stabbotco1/website-static-content
AWS_REGION=us-east-1
TAG_OWNER=Content Team
TAG_COST_CENTER=Marketing
BACKEND_KEY=deployment-roles/website-static/production/terraform.tfstate
```

policies/deployment-policy.json:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "*",
      "Resource": "*"
    }
  ]
}
```

### projects/governance/production

Purpose: Deploy CloudTrail, IAM Access Analyzer for permission refinement

.env:

```bash
PROJECT_NAME=governance
ENVIRONMENT=production
GITHUB_REPOSITORY=stabbotco1/governance-infra
AWS_REGION=us-east-1
TAG_OWNER=Security Team
TAG_COST_CENTER=Security
BACKEND_KEY=deployment-roles/governance/production/terraform.tfstate
```

policies/deployment-policy.json:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "*",
      "Resource": "*"
    }
  ]
}
```

## Implementation Checklist

1. Create repository structure
2. Implement modules/deployment-role
3. Implement modules/standard-tags
4. Create templates/new-project
5. Implement scripts/create-project.sh
6. Create initial projects (website-foundation, website-static, governance)
7. Implement project scripts (deploy.sh, destroy.sh, list-deployed-resources.sh, verify-prerequisites.sh)
8. Test local deployment
9. Configure GitHub Actions
10. Test CI/CD deployment
11. Deploy CloudTrail for access analysis
12. Refine policies based on Access Analyzer findings
13. Document policy refinement workflow

## Policy Refinement Workflow

1. Deploy role with broad permissions
2. Deploy target infrastructure using the role
3. Operate infrastructure for 7-14 days
4. Deploy governance project (CloudTrail)
5. Analyze CloudTrail logs with IAM Access Analyzer
6. Generate refined policy from Access Analyzer findings
7. Replace policies/deployment-policy.json with refined version
8. Test deployment with refined policy
9. If successful, commit refined policy
10. If failures occur, adjust policy and repeat
11. Once stable, destroy CloudTrail (optional)

## Notes

- OpenTofu compatible (Terraform replacement)
- Scripts enforce idempotent operations
- State stored in foundation S3 bucket
- Locking via foundation DynamoDB table
- OIDC provider configured by foundation
- Deployment role created by foundation
- No long-lived credentials required
- All configuration versioned in git
- Policy evolution tracked via git history
- Tags enable cost allocation and resource tracking
