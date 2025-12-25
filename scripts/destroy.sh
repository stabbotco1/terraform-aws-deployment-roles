#!/bin/bash
# scripts/destroy.sh - Destroy ALL deployment roles (scorched earth)

set -euo pipefail

# Change to project root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

# Disable AWS CLI pager
export AWS_PAGER=""

echo "🔥 DESTROYING ALL DEPLOYMENT ROLES 🔥"
echo ""
echo "⚠️  WARNING: This will destroy ALL deployment roles managed by this project:"
echo "  - All IAM roles and policies"
echo "  - All SSM parameters (/deployment-roles/*)"
echo "  - Terraform state file"
echo ""

# Verify prerequisites (skip self-deployment check for destroy)
echo "Step 1: Verifying prerequisites..."
./scripts/verify-prerequisites.sh || exit 1

# Step 2: Check for foundation deployment role and assume if available
echo ""
echo "Step 2: Checking for foundation deployment role..."
FOUNDATION_ROLE_ARN=$(aws ssm get-parameter --region us-east-1 --name "/terraform/foundation/deployment-roles-role-arn" --query Parameter.Value --output text 2>/dev/null || echo "")

if [ -n "$FOUNDATION_ROLE_ARN" ]; then
  echo "✓ Foundation deployment role found: $FOUNDATION_ROLE_ARN"
  echo "  Attempting to assume role for destruction..."
  
  if TEMP_CREDS=$(aws sts assume-role --role-arn "$FOUNDATION_ROLE_ARN" --role-session-name "deployment-roles-destroy-$(date +%s)" --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>/dev/null); then
    export AWS_ACCESS_KEY_ID=$(echo "$TEMP_CREDS" | cut -f1)
    export AWS_SECRET_ACCESS_KEY=$(echo "$TEMP_CREDS" | cut -f2)
    export AWS_SESSION_TOKEN=$(echo "$TEMP_CREDS" | cut -f3)
    echo "✓ Successfully assumed foundation deployment role"
  else
    echo "⚠️  Failed to assume foundation role, using current credentials"
    echo "  This is normal for local development with admin credentials"
  fi
else
  echo "ℹ️  Foundation deployment role not found, using current credentials"
fi

# Step 3: Configure Terraform backend
echo ""
echo "Step 3: Configuring Terraform backend..."

# Get backend configuration from foundation
STATE_BUCKET=$(aws ssm get-parameter --region us-east-1 --name "/terraform/foundation/s3-state-bucket" --query Parameter.Value --output text 2>/dev/null || echo "")
DYNAMODB_TABLE=$(aws ssm get-parameter --region us-east-1 --name "/terraform/foundation/dynamodb-lock-table" --query Parameter.Value --output text 2>/dev/null || echo "")

if [ -z "$STATE_BUCKET" ] || [ -z "$DYNAMODB_TABLE" ]; then
  echo "❌ Foundation backend configuration not found"
  echo "  Proceeding with manual cleanup..."
else
  # Get GitHub repository info for state key
  GITHUB_REPO=$(git remote get-url origin 2>/dev/null | sed 's/.*github\.com[:/]\([^/]*\/[^/.]*\).*/\1/' || echo "unknown/unknown")
  BACKEND_KEY="deployment-roles/$(echo "$GITHUB_REPO" | tr '/' '-')/terraform.tfstate"

  echo "✓ Backend configuration:"
  echo "  Bucket: $STATE_BUCKET"
  echo "  Key: $BACKEND_KEY"

  # Step 4: Initialize and destroy via Terraform
  echo ""
  echo "Step 4: Destroying via Terraform..."
  
  if tofu init \
    -backend-config="bucket=$STATE_BUCKET" \
    -backend-config="key=$BACKEND_KEY" \
    -backend-config="region=us-east-1" \
    -backend-config="dynamodb_table=$DYNAMODB_TABLE" \
    -reconfigure 2>/dev/null; then
    
    echo "✓ Terraform initialized, destroying resources..."
    tofu destroy -auto-approve || echo "⚠️  Terraform destroy had issues, continuing with manual cleanup..."
    
    # Remove state file and clear DynamoDB locks
    echo "✓ Removing Terraform state file and clearing locks..."
    aws s3 rm "s3://$STATE_BUCKET/$BACKEND_KEY" 2>/dev/null || echo "⚠️  State file not found or already removed"
    
    # Clear all DynamoDB locks for this state file
    aws dynamodb scan --table-name "$DYNAMODB_TABLE" --filter-expression "contains(LockID, :key)" --expression-attribute-values "{\":key\":{\"S\":\"$BACKEND_KEY\"}}" --query 'Items[].LockID.S' --output text 2>/dev/null | tr '\t' '\n' | while read -r lock_id; do
      if [ -n "$lock_id" ]; then
        echo "  Clearing lock: $lock_id"
        aws dynamodb delete-item --table-name "$DYNAMODB_TABLE" --key "{\"LockID\":{\"S\":\"$lock_id\"}}" 2>/dev/null || true
      fi
    done
  else
    echo "⚠️  Terraform init failed, proceeding with manual cleanup..."
  fi
fi

# Step 5: Manual cleanup of any remaining resources
echo ""
echo "Step 5: Manual cleanup of remaining resources..."

# Clean up SSM parameters
echo "Cleaning up SSM parameters..."
aws ssm get-parameters-by-path --region us-east-1 --path "/deployment-roles" --recursive --query 'Parameters[].Name' --output text 2>/dev/null | tr '\t' '\n' | while read -r param_name; do
  if [ -n "$param_name" ]; then
    echo "  Deleting SSM parameter: $param_name"
    aws ssm delete-parameter --region us-east-1 --name "$param_name" 2>/dev/null || echo "    ⚠️  Failed to delete $param_name"
  fi
done

# Clean up IAM roles (GitHub Actions deployment roles)
echo "Cleaning up IAM roles..."
aws iam list-roles --query 'Roles[?starts_with(RoleName, `gharole-`)].RoleName' --output text 2>/dev/null | tr '\t' '\n' | while read -r role_name; do
  if [ -n "$role_name" ]; then
    echo "  Processing role: $role_name"
    
    # Detach policies
    aws iam list-attached-role-policies --role-name "$role_name" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null | tr '\t' '\n' | while read -r policy_arn; do
      if [ -n "$policy_arn" ]; then
        echo "    Detaching policy: $policy_arn"
        aws iam detach-role-policy --role-name "$role_name" --policy-arn "$policy_arn" 2>/dev/null || echo "      ⚠️  Failed to detach $policy_arn"
      fi
    done
    
    # Delete role
    echo "    Deleting role: $role_name"
    aws iam delete-role --role-name "$role_name" 2>/dev/null || echo "      ⚠️  Failed to delete $role_name"
  fi
done

# Clean up IAM policies (GitHub Actions deployment policies)
echo "Cleaning up IAM policies..."
aws iam list-policies --scope Local --query 'Policies[?starts_with(PolicyName, `ghpolicy-`)].Arn' --output text 2>/dev/null | tr '\t' '\n' | while read -r policy_arn; do
  if [ -n "$policy_arn" ]; then
    echo "  Deleting policy: $policy_arn"
    aws iam delete-policy --policy-arn "$policy_arn" 2>/dev/null || echo "    ⚠️  Failed to delete $policy_arn"
  fi
done

echo ""
echo "🔥 DESTRUCTION COMPLETE 🔥"
echo ""
echo "All deployment roles and associated resources have been destroyed."
echo "You can now recreate projects and redeploy as needed."
