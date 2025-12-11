#!/bin/bash
# scripts/deploy.sh - Deploy OpenTofu deployment role

set -euo pipefail

# Disable AWS CLI pager
export AWS_PAGER=""

echo "Deploying OpenTofu deployment role..."

# Verify prerequisites (includes git state checks)
echo ""
echo "Step 1: Verifying prerequisites..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/verify-prerequisites.sh" || exit 1

# Load environment variables from .env file
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [ -f "${PROJECT_ROOT}/.env" ]; then
  export $(grep -v '^#' "${PROJECT_ROOT}/.env" | xargs)
fi

# Parameter overrides from command line
PROJECT_NAME="${1:-${PROJECT_NAME:-}}"
ENVIRONMENT="${2:-${ENVIRONMENT:-production}}"

# Validation
if [[ -z "${PROJECT_NAME}" ]]; then
  echo "Error: PROJECT_NAME required (set in .env or pass as argument)"
  exit 1
fi

# Collect deployment metadata
echo ""
echo "Step 2: Collecting deployment metadata..."

# Get repository URL (normalize to HTTPS, keep .git)
REPOSITORY=$(git remote get-url origin | sed 's|git@github.com:|https://github.com/|')
echo "  Repository: $REPOSITORY"

# Get AWS Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "  Account ID: $ACCOUNT_ID"

# Get AWS Region from .env or AWS CLI config
REGION=${AWS_REGION:-$(aws configure get region || echo "us-east-1")}
echo "  Region: $REGION"

# Get deployer ARN
DEPLOYED_BY=$(aws sts get-caller-identity --query Arn --output text)
echo "  Deployed By: $DEPLOYED_BY"

# Project details
echo "  Project: $PROJECT_NAME"
echo "  Environment: $ENVIRONMENT"
echo "  GitHub Repository: ${GITHUB_REPOSITORY}"

# Retrieve foundation parameters from SSM
echo ""
echo "Step 3: Retrieving foundation configuration..."
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
CALLER_IDENTITY=$(aws sts get-caller-identity --query Arn --output text)
if [[ ! "${CALLER_IDENTITY}" =~ assumed-role/.*deployment-roles-role ]]; then
  echo ""
  echo "Step 4: Assuming deployment role..."
  
  TEMP_CREDS=$(aws sts assume-role \
    --role-arn "${DEPLOYMENT_ROLE_ARN}" \
    --role-session-name "tofu-deploy-${PROJECT_NAME}-${ENVIRONMENT}" \
    --query 'Credentials' --output json) || {
    echo "Warning: Could not assume deployment role, continuing with current credentials"
    TEMP_CREDS=""
  }
  
  if [[ -n "${TEMP_CREDS}" ]]; then
    export AWS_ACCESS_KEY_ID=$(echo "${TEMP_CREDS}" | jq -r .AccessKeyId)
    export AWS_SECRET_ACCESS_KEY=$(echo "${TEMP_CREDS}" | jq -r .SecretAccessKey)
    export AWS_SESSION_TOKEN=$(echo "${TEMP_CREDS}" | jq -r .SessionToken)
    echo "  Role assumed successfully"
    
    # Verify new identity
    NEW_IDENTITY=$(aws sts get-caller-identity --query Arn --output text)
    echo "  New Identity: ${NEW_IDENTITY}"
  fi
else
  echo ""
  echo "Step 4: Already using deployment role"
  echo "  Current Identity: ${CALLER_IDENTITY}"
fi

# Initialize OpenTofu backend
echo ""
echo "Step 5: Initializing OpenTofu..."
tofu init \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="dynamodb_table=${LOCK_TABLE}" \
  -backend-config="key=${BACKEND_KEY}" \
  -backend-config="region=${REGION}" \
  -backend-config="encrypt=true" \
  -reconfigure

# Plan changes
echo ""
echo "Step 6: Planning OpenTofu changes..."
tofu plan \
  -var="project_name=${PROJECT_NAME}" \
  -var="environment=${ENVIRONMENT}" \
  -var="github_repository=${GITHUB_REPOSITORY}" \
  -var="aws_region=${REGION}" \
  -out=tfplan

# Apply changes
echo ""
echo "Step 7: Applying OpenTofu changes..."
tofu apply tfplan

# Get outputs
echo ""
echo "Step 8: Retrieving deployment outputs..."
ROLE_ARN=$(tofu output -raw role_arn)
ROLE_NAME=$(tofu output -raw role_name)
POLICY_ARN=$(tofu output -raw policy_arn)

echo ""
echo "=========================================="
echo "DEPLOYMENT COMPLETE"
echo "=========================================="
echo ""
echo "Created resources:"
echo "  Role ARN: ${ROLE_ARN}"
echo "  Role Name: ${ROLE_NAME}"
echo "  Policy ARN: ${POLICY_ARN}"
echo ""
echo "GitHub Actions configuration:"
echo "  role-to-assume: ${ROLE_ARN}"
echo "  aws-region: ${REGION}"
echo ""
echo "Next steps:"
echo "  1. Configure GitHub Actions to use this role"
echo "  2. Test deployment from CI/CD pipeline"
echo "  3. Analyze CloudTrail logs and refine permissions"
echo "  4. Update policy file and redeploy: ./scripts/deploy.sh"
echo ""

# Clean up
rm -f tfplan
