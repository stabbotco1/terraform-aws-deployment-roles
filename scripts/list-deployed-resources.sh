#!/bin/bash
# scripts/list-deployed-resources.sh - List all deployed deployment role resources

set -euo pipefail

# Change to project root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

# Disable AWS CLI pager
export AWS_PAGER=""

echo "📋 LISTING DEPLOYED DEPLOYMENT ROLE RESOURCES 📋"
echo ""

# Set AWS region for deployment roles control plane
AWS_REGION=us-east-1

# Get GitHub repository info
GITHUB_REPO=$(git remote get-url origin 2>/dev/null | sed 's/.*github\.com[:/]\([^/]*\/[^/.]*\).*/\1/' || echo "unknown/unknown")

echo "Repository: $GITHUB_REPO"
echo "Control Plane Region: $AWS_REGION"
echo ""

# Check Terraform state
echo "=== TERRAFORM STATE ==="
STATE_BUCKET=$(aws ssm get-parameter --region us-east-1 --name "/terraform/foundation/s3-state-bucket" --query Parameter.Value --output text 2>/dev/null || echo "")
DYNAMODB_TABLE=$(aws ssm get-parameter --region us-east-1 --name "/terraform/foundation/dynamodb-lock-table" --query Parameter.Value --output text 2>/dev/null || echo "")

if [ -n "$STATE_BUCKET" ] && [ -n "$DYNAMODB_TABLE" ]; then
  BACKEND_KEY="deployment-roles/$(echo "$GITHUB_REPO" | tr '/' '-')/terraform.tfstate"
  
  echo "Backend Configuration:"
  echo "  Bucket: $STATE_BUCKET"
  echo "  Key: $BACKEND_KEY"
  echo "  DynamoDB: $DYNAMODB_TABLE"
  
  # Check if state file exists
  if aws s3 ls "s3://$STATE_BUCKET/$BACKEND_KEY" >/dev/null 2>&1; then
    echo "  Status: ✓ State file exists"
    
    # Try to show Terraform outputs if possible
    if [ -f "main.tf" ]; then
      echo ""
      echo "Initializing Terraform to read state..."
      if tofu init \
        -backend-config="bucket=$STATE_BUCKET" \
        -backend-config="key=$BACKEND_KEY" \
        -backend-config="region=us-east-1" \
        -backend-config="dynamodb_table=$DYNAMODB_TABLE" \
        -reconfigure >/dev/null 2>&1; then
        
        echo ""
        echo "=== TERRAFORM OUTPUTS ==="
        tofu output -json 2>/dev/null | jq -r '
          if . == {} then
            "No outputs available"
          else
            to_entries[] | 
            "Output: \(.key)\nValue: \(.value.value)\n"
          end
        ' || echo "No outputs available"
      fi
    fi
  else
    echo "  Status: ⚠️  State file not found"
  fi
else
  echo "❌ Foundation backend configuration not found"
fi

echo ""
echo "=== IAM ROLES ==="
ROLES_FOUND=false
aws iam list-roles --query 'Roles[?starts_with(RoleName, `gharole-`)].[RoleName,Arn,CreateDate]' --output table 2>/dev/null | grep -v "None" || echo "No deployment roles found"

# Check each role for project tags
aws iam list-roles --query 'Roles[?starts_with(RoleName, `gharole-`)].RoleName' --output text 2>/dev/null | tr '\t' '\n' | while read -r role_name; do
  if [ -n "$role_name" ]; then
    ROLES_FOUND=true
    echo ""
    echo "Role: $role_name"
    
    # Get role tags
    TAGS=$(aws iam list-role-tags --role-name "$role_name" --query 'Tags' --output json 2>/dev/null || echo "[]")
    if [ "$TAGS" != "[]" ]; then
      echo "  Tags:"
      echo "$TAGS" | jq -r '.[] | "    \(.Key): \(.Value)"'
    else
      echo "  Tags: None"
    fi
    
    # Get attached policies
    POLICIES=$(aws iam list-attached-role-policies --role-name "$role_name" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || echo "")
    if [ -n "$POLICIES" ]; then
      echo "  Attached Policies:"
      echo "$POLICIES" | tr '\t' '\n' | sed 's/^/    /'
    fi
  fi
done

echo ""
echo "=== IAM POLICIES ==="
aws iam list-policies --scope Local --query 'Policies[?starts_with(PolicyName, `ghpolicy-`)].[PolicyName,Arn,CreateDate]' --output table 2>/dev/null | grep -v "None" || echo "No deployment policies found"

echo ""
echo "=== SSM PARAMETERS ==="
PARAMS_FOUND=false
aws ssm get-parameters-by-path --region us-east-1 --path "/deployment-roles" --recursive --query 'Parameters[].[Name,Value]' --output text 2>/dev/null | while IFS=$'\t' read -r param_name param_value; do
  if [ -n "$param_name" ]; then
    PARAMS_FOUND=true
    echo "Parameter: $param_name"
    echo "  Value: $param_value"
    echo ""
  fi
done

if ! $PARAMS_FOUND; then
  echo "No deployment role parameters found"
fi

echo ""
echo "=== ORPHANED RESOURCE DETECTION ==="

# Check for resources not in Terraform state
echo "Checking for orphaned resources..."

# This would require parsing Terraform state, which is complex
# For now, just note that manual verification may be needed
echo "⚠️  Manual verification recommended:"
echo "  1. Compare AWS resources with Terraform state"
echo "  2. Check for resources created outside of this project"
echo "  3. Verify all SSM parameters match expected projects"

echo ""
echo "📋 RESOURCE LISTING COMPLETE 📋"
