#!/bin/bash
# scripts/destroy.sh - Destroy OpenTofu deployment role

set -euo pipefail

# Disable AWS CLI pager
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load environment variables from .env file
if [ -f "${PROJECT_ROOT}/.env" ]; then
  export $(grep -v '^#' "${PROJECT_ROOT}/.env" | xargs)
fi

PROJECT_NAME="${1:-${PROJECT_NAME:-}}"
ENVIRONMENT="${2:-${ENVIRONMENT:-production}}"

if [[ -z "${PROJECT_NAME}" ]]; then
  echo "Error: PROJECT_NAME required"
  exit 1
fi

echo "Checking for deployed resources..."

# Retrieve backend config
STATE_BUCKET=$(aws ssm get-parameter \
  --name /terraform/foundation/s3-state-bucket \
  --query Parameter.Value --output text)

LOCK_TABLE=$(aws ssm get-parameter \
  --name /terraform/foundation/dynamodb-lock-table \
  --query Parameter.Value --output text)

# Initialize to check state
tofu init \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="dynamodb_table=${LOCK_TABLE}" \
  -backend-config="key=${BACKEND_KEY}" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="encrypt=true" \
  -reconfigure &>/dev/null || true

# Check if state has resources
RESOURCE_COUNT=$(tofu state list 2>/dev/null | wc -l || echo "0")

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
echo "Repository: ${GITHUB_REPOSITORY}"
echo ""
echo "This will permanently delete:"
tofu state list | sed 's/^/  - /'
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
    --role-session-name "tofu-destroy-${PROJECT_NAME}-${ENVIRONMENT}" \
    --query 'Credentials' --output json) || {
    echo "Warning: Could not assume deployment role, continuing with current credentials"
    TEMP_CREDS=""
  }
  
  if [[ -n "${TEMP_CREDS}" ]]; then
    export AWS_ACCESS_KEY_ID=$(echo "${TEMP_CREDS}" | jq -r .AccessKeyId)
    export AWS_SECRET_ACCESS_KEY=$(echo "${TEMP_CREDS}" | jq -r .SecretAccessKey)
    export AWS_SESSION_TOKEN=$(echo "${TEMP_CREDS}" | jq -r .SessionToken)
    echo "  Role assumed successfully"
  fi
fi

# Destroy resources
echo ""
echo "Destroying resources..."
tofu destroy \
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
