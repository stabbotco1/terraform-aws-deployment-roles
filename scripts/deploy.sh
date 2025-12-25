#!/bin/bash
# scripts/deploy.sh - Deploy ALL deployment roles using single Terraform configuration

set -euo pipefail

# Change to project root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

# Disable AWS CLI pager
export AWS_PAGER=""

echo "🚀 DEPLOYING ALL DEPLOYMENT ROLES 🚀"
echo ""
echo "This will deploy deployment roles for all configured projects using a single Terraform configuration"
echo ""

# Verify prerequisites
echo "Step 1: Verifying prerequisites..."
./scripts/verify-prerequisites.sh || exit 1

# Step 2: Check for foundation deployment role and assume if available
echo ""
echo "Step 2: Checking for foundation deployment role..."
FOUNDATION_ROLE_ARN=$(aws ssm get-parameter --region us-east-1 --name "/terraform/foundation/deployment-roles-role-arn" --query Parameter.Value --output text 2>/dev/null || echo "")

if [ -n "$FOUNDATION_ROLE_ARN" ]; then
  echo "✓ Foundation deployment role found: $FOUNDATION_ROLE_ARN"
  echo "  Attempting to assume role for deployment..."
  
  if TEMP_CREDS=$(aws sts assume-role --role-arn "$FOUNDATION_ROLE_ARN" --role-session-name "deployment-roles-$(date +%s)" --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>/dev/null); then
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
  echo "  This is normal for local development with admin credentials"
fi

# Step 3: Configure Terraform backend
echo ""
echo "Step 3: Configuring Terraform backend..."

# Get backend configuration from foundation
STATE_BUCKET=$(aws ssm get-parameter --region us-east-1 --name "/terraform/foundation/s3-state-bucket" --query Parameter.Value --output text 2>/dev/null || echo "")
DYNAMODB_TABLE=$(aws ssm get-parameter --region us-east-1 --name "/terraform/foundation/dynamodb-lock-table" --query Parameter.Value --output text 2>/dev/null || echo "")

if [ -z "$STATE_BUCKET" ] || [ -z "$DYNAMODB_TABLE" ]; then
  echo "❌ Foundation backend configuration not found"
  echo "  Deploy terraform-aws-cfn-foundation first"
  exit 1
fi

# Get GitHub repository info for state key
GITHUB_REPO=$(git remote get-url origin 2>/dev/null | sed 's/.*github\.com[:/]\([^/]*\/[^/.]*\).*/\1/' || echo "unknown/unknown")
BACKEND_KEY="deployment-roles/$(echo "$GITHUB_REPO" | tr '/' '-')/terraform.tfstate"

echo "✓ Backend configuration:"
echo "  Bucket: $STATE_BUCKET"
echo "  DynamoDB: $DYNAMODB_TABLE"
echo "  Key: $BACKEND_KEY"

# Step 4: Initialize Terraform
echo ""
echo "Step 4: Initializing Terraform..."

# Clear any stale DynamoDB locks before initialization
aws dynamodb scan --table-name "$DYNAMODB_TABLE" --filter-expression "contains(LockID, :key)" --expression-attribute-values "{\":key\":{\"S\":\"$BACKEND_KEY\"}}" --query 'Items[].LockID.S' --output text 2>/dev/null | tr '\t' '\n' | while read -r lock_id; do
  if [ -n "$lock_id" ]; then
    echo "Clearing stale lock: $lock_id"
    aws dynamodb delete-item --table-name "$DYNAMODB_TABLE" --key "{\"LockID\":{\"S\":\"$lock_id\"}}" 2>/dev/null || true
  fi
done

tofu init \
  -backend-config="bucket=$STATE_BUCKET" \
  -backend-config="key=$BACKEND_KEY" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=$DYNAMODB_TABLE" \
  -reconfigure

# Step 5: Plan deployment
echo ""
echo "Step 5: Planning deployment..."
tofu plan -out=tfplan

# Step 6: Apply deployment
echo ""
echo "Step 6: Applying deployment..."
tofu apply tfplan

# Clean up plan file
rm -f tfplan

echo ""
echo "🚀 DEPLOYMENT COMPLETE 🚀"
echo ""
echo "Next steps:"
echo "  1. Run './scripts/list-deployed-resources.sh' to verify deployments"
echo "  2. Configure GitHub Actions workflows to use the deployment roles"
echo ""
echo "🚀 All deployment roles are ready for use 🚀"
