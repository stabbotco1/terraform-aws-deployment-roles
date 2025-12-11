#!/bin/bash
# scripts/list-deployed-resources.sh - List deployed resources

set -euo pipefail

# Disable AWS CLI pager
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load environment variables from .env file
if [ -f "${PROJECT_ROOT}/.env" ]; then
  export $(grep -v '^#' "${PROJECT_ROOT}/.env" | xargs)
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

echo "Backend Configuration:"
echo "  State Bucket: ${STATE_BUCKET}"
echo "  Lock Table: ${LOCK_TABLE}"
echo "  State Key: ${BACKEND_KEY}"
echo ""

# Initialize backend
tofu init \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="dynamodb_table=${LOCK_TABLE}" \
  -backend-config="key=${BACKEND_KEY}" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="encrypt=true" \
  -reconfigure &>/dev/null || {
  echo "Error: Failed to initialize OpenTofu backend"
  exit 1
}

# Get state resources
echo "=== OpenTofu State Resources ==="
RESOURCE_COUNT=$(tofu state list 2>/dev/null | wc -l || echo "0")

if [[ "${RESOURCE_COUNT}" -eq 0 ]]; then
  echo "No resources found in state"
  exit 0
fi

tofu state list

# Get outputs
echo ""
echo "=== OpenTofu Outputs ==="
if tofu output &>/dev/null; then
  tofu output
else
  echo "No outputs defined"
fi

# Get role details from AWS
echo ""
echo "=== IAM Role Details ==="
ROLE_ARN=$(tofu output -raw role_arn 2>/dev/null || echo "")

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
  echo "Role not found in OpenTofu outputs"
fi

# Get SSM parameter details from AWS
echo ""
echo "=== SSM Parameter Details ==="
SSM_PARAMETER_NAME=$(tofu output -raw ssm_parameter_name 2>/dev/null || echo "")

if [[ -n "${SSM_PARAMETER_NAME}" ]]; then
  echo "Parameter Name: ${SSM_PARAMETER_NAME}"
  
  # Parameter details
  PARAMETER_INFO=$(aws ssm get-parameter --name "${SSM_PARAMETER_NAME}" --query 'Parameter' --output json 2>/dev/null || echo "{}")
  
  if [[ "${PARAMETER_INFO}" != "{}" ]]; then
    echo "Parameter Value: $(echo "${PARAMETER_INFO}" | jq -r .Value)"
    echo "Parameter Type: $(echo "${PARAMETER_INFO}" | jq -r .Type)"
    echo "Last Modified: $(echo "${PARAMETER_INFO}" | jq -r .LastModifiedDate)"
    echo "Version: $(echo "${PARAMETER_INFO}" | jq -r .Version)"
    
    # Parameter tags
    echo ""
    echo "Parameter Tags:"
    aws ssm list-tags-for-resource \
      --resource-type "Parameter" \
      --resource-id "${SSM_PARAMETER_NAME}" \
      --query 'TagList[].{Key:Key,Value:Value}' \
      --output table 2>/dev/null || echo "No tags found"
  else
    echo "Parameter not found in AWS"
  fi
else
  echo "SSM parameter not found in OpenTofu outputs"
fi

echo ""
echo "✓ Resource listing complete"

# Check for orphaned resources
echo ""
echo "=== Orphaned Resources (Not Managed by Terraform) ==="

# Get account and region
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CURRENT_REGION=$(aws configure get region || echo "us-east-1")

# Get GitHub org/repo from environment
GITHUB_ORG_REPO="${GITHUB_REPOSITORY:-}"
if [[ -n "${GITHUB_ORG_REPO}" ]]; then
  GITHUB_ORG_REPO_NORMALIZED=$(echo "${GITHUB_ORG_REPO}" | tr '/' '-')
fi

ORPHANS_FOUND=false

# Get current state resources to exclude from orphan detection
CURRENT_STATE_RESOURCES=$(tofu state list 2>/dev/null || echo "")

# Check if we have deployment role resources in current state
HAS_DEPLOYMENT_ROLE=$(echo "${CURRENT_STATE_RESOURCES}" | grep -c "deployment_role.aws_iam_role" || echo "0")
HAS_DEPLOYMENT_POLICY=$(echo "${CURRENT_STATE_RESOURCES}" | grep -c "deployment_role.aws_iam_policy" || echo "0")
HAS_SSM_PARAMETER=$(echo "${CURRENT_STATE_RESOURCES}" | grep -c "deployment_role.aws_ssm_parameter" || echo "0")

# Check for IAM roles with project naming pattern not in state
echo "Checking for orphaned IAM roles..."
ORPHANED_ROLES=$(aws iam list-roles --query 'Roles[?contains(RoleName, `gharole-`)].RoleName' --output text | tr '\t' '\n')

for role_name in $ORPHANED_ROLES; do
  if [[ -n "${role_name}" ]]; then
    # Skip if this is our current deployment role
    if [[ "${HAS_DEPLOYMENT_ROLE}" -gt 0 ]]; then
      # Check if this role matches our current project
      PROJECT_TAG=$(aws iam list-role-tags --role-name "${role_name}" \
        --query 'Tags[?Key==`Project`].Value' --output text 2>/dev/null || echo "")
      
      if [[ "${PROJECT_TAG}" == "${PROJECT_NAME}" ]]; then
        continue  # Skip our own role
      fi
    fi
    
    # Check if role has project tags (indicating it's a deployment role)
    PROJECT_TAG=$(aws iam list-role-tags --role-name "${role_name}" \
      --query 'Tags[?Key==`Project`].Value' --output text 2>/dev/null || echo "")
    
    REPO_TAG=$(aws iam list-role-tags --role-name "${role_name}" \
      --query 'Tags[?Key==`Repository`].Value' --output text 2>/dev/null || echo "")
    
    if [[ -n "${PROJECT_TAG}" ]] || [[ "${REPO_TAG}" == *"deployment-roles"* ]]; then
      if [ "$ORPHANS_FOUND" = false ]; then
        echo "Found resources with project attributes not in Terraform state:"
        echo ""
        ORPHANS_FOUND=true
      fi
      echo "IAM Role: ${role_name}"
      echo "  Type: IAM Role"
      echo "  Pattern: GitHub Actions deployment role naming (gharole-*) + tags"
      echo "  Status: Orphaned"
      echo ""
    fi
  fi
done

# Check for IAM policies with project naming pattern not in state
echo "Checking for orphaned IAM policies..."
ORPHANED_POLICIES=$(aws iam list-policies --scope Local --query 'Policies[?contains(PolicyName, `ghpolicy-`)].PolicyName' --output text | tr '\t' '\n')

for policy_name in $ORPHANED_POLICIES; do
  if [[ -n "${policy_name}" ]]; then
    # Skip if this is our current deployment policy
    if [[ "${HAS_DEPLOYMENT_POLICY}" -gt 0 ]]; then
      # Get policy ARN for tag checking
      POLICY_ARN=$(aws iam list-policies --scope Local \
        --query "Policies[?PolicyName=='${policy_name}'].Arn" --output text)
      
      if [[ -n "${POLICY_ARN}" ]]; then
        PROJECT_TAG=$(aws iam list-policy-tags --policy-arn "${POLICY_ARN}" \
          --query 'Tags[?Key==`Project`].Value' --output text 2>/dev/null || echo "")
        
        if [[ "${PROJECT_TAG}" == "${PROJECT_NAME}" ]]; then
          continue  # Skip our own policy
        fi
        
        if [[ -n "${PROJECT_TAG}" ]]; then
          if [ "$ORPHANS_FOUND" = false ]; then
            echo "Found resources with project attributes not in Terraform state:"
            echo ""
            ORPHANS_FOUND=true
          fi
          echo "IAM Policy: ${policy_name}"
          echo "  Type: IAM Policy"
          echo "  Pattern: GitHub Actions deployment policy naming (ghpolicy-*) + tags"
          echo "  Status: Orphaned"
          echo ""
        fi
      fi
    fi
  fi
done

# Check for SSM parameters with deployment-roles pattern not in state
echo "Checking for orphaned SSM parameters..."
ORPHANED_PARAMS=$(aws ssm get-parameters-by-path --path "/deployment-roles" --recursive --query 'Parameters[].Name' --output text 2>/dev/null | tr '\t' '\n')

for param_name in $ORPHANED_PARAMS; do
  if [[ -n "${param_name}" ]]; then
    # Skip if this is our current SSM parameter
    if [[ "${HAS_SSM_PARAMETER}" -gt 0 ]]; then
      if [[ "${param_name}" == *"${GITHUB_ORG_REPO_NORMALIZED}"* ]]; then
        continue  # Skip our own parameter
      fi
    fi
    
    # Check parameter tags
    PROJECT_TAG=$(aws ssm list-tags-for-resource \
      --resource-type "Parameter" \
      --resource-id "${param_name}" \
      --query 'TagList[?Key==`Project`].Value' --output text 2>/dev/null || echo "")
    
    if [[ -n "${PROJECT_TAG}" ]] || [[ "${param_name}" == */deployment-roles/* ]]; then
      if [ "$ORPHANS_FOUND" = false ]; then
        echo "Found resources with project attributes not in Terraform state:"
        echo ""
        ORPHANS_FOUND=true
      fi
      echo "SSM Parameter: ${param_name}"
      echo "  Type: SSM Parameter"
      echo "  Pattern: Deployment roles parameter path + tags/naming"
      echo "  Status: Orphaned"
      echo ""
    fi
  fi
done

if [ "$ORPHANS_FOUND" = false ]; then
  echo "No orphaned resources detected"
fi

echo ""
