#!/bin/bash
# scripts/verify-prerequisites.sh - Validate all prerequisites before deployment

set -euo pipefail

# Change to project root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

FAILURES=()

echo "Verifying prerequisites for deployment roles..."
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
    echo "  Commit or stash changes before deployment"
    FAILURES+=("Uncommitted changes")
    return 1
  fi
}

check_git_untracked() {
  if [ -z "$(git ls-files --others --exclude-standard)" ]; then
    echo -e "${GREEN}✓${NC} No untracked files"
    return 0
  else
    echo -e "${RED}✗${NC} Untracked files detected"
    echo "  Add or ignore untracked files before deployment"
    git ls-files --others --exclude-standard | sed 's/^/    /'
    FAILURES+=("Untracked files")
    return 1
  fi
}

check_git_detached_head() {
  if git symbolic-ref -q HEAD &>/dev/null; then
    echo -e "${GREEN}✓${NC} Not in detached HEAD state"
    return 0
  else
    echo -e "${RED}✗${NC} In detached HEAD state"
    echo "  Switch to a proper branch before deployment"
    FAILURES+=("Detached HEAD")
    return 1
  fi
}

check_git_upstream() {
  if git rev-parse --abbrev-ref @{u} &>/dev/null; then
    echo -e "${GREEN}✓${NC} Branch has upstream configured"
    return 0
  else
    echo -e "${YELLOW}⚠${NC} Branch has no upstream configured"
    echo "  Consider setting upstream: git push -u origin $(git branch --show-current)"
    return 0
  fi
}

check_git_unpushed() {
  LOCAL=$(git rev-parse @ 2>/dev/null)
  REMOTE=$(git rev-parse @{u} 2>/dev/null || echo "")
  
  if [ -z "$REMOTE" ]; then
    return 0
  fi
  
  if [ "$LOCAL" = "$REMOTE" ]; then
    echo -e "${GREEN}✓${NC} No unpushed commits"
    return 0
  else
    echo -e "${RED}✗${NC} Unpushed commits detected"
    echo "  Push commits before deployment: git push"
    FAILURES+=("Unpushed commits")
    return 1
  fi
}

check_terraform() {
  if command -v tofu &>/dev/null; then
    TOFU_VERSION=$(tofu version | head -n1 | cut -d' ' -f2)
    echo -e "${GREEN}✓${NC} OpenTofu installed: $TOFU_VERSION"
    return 0
  elif command -v terraform &>/dev/null; then
    TF_VERSION=$(terraform version | head -n1 | cut -d' ' -f2)
    echo -e "${GREEN}✓${NC} Terraform installed: $TF_VERSION"
    return 0
  else
    echo -e "${RED}✗${NC} Neither OpenTofu nor Terraform found"
    echo "  Install OpenTofu: https://opentofu.org/docs/intro/install/"
    FAILURES+=("No Terraform/OpenTofu")
    return 1
  fi
}

check_aws_cli() {
  if command -v aws &>/dev/null; then
    AWS_VERSION=$(aws --version 2>&1 | cut -d/ -f2 | cut -d' ' -f1)
    echo -e "${GREEN}✓${NC} AWS CLI installed: $AWS_VERSION"
    return 0
  else
    echo -e "${RED}✗${NC} AWS CLI not found"
    echo "  Install AWS CLI: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    FAILURES+=("No AWS CLI")
    return 1
  fi
}

check_aws_auth() {
  if aws sts get-caller-identity &>/dev/null; then
    CALLER_ARN=$(aws sts get-caller-identity --query 'Arn' --output text)
    echo -e "${GREEN}✓${NC} AWS authenticated: $CALLER_ARN"
    return 0
  else
    echo -e "${RED}✗${NC} AWS authentication failed"
    echo "  Configure AWS credentials: aws configure"
    FAILURES+=("AWS authentication failed")
    return 1
  fi
}

check_aws_permissions() {
  echo "Checking AWS permissions..."
  
  REQUIRED_ACTIONS=(
    "iam:CreateRole"
    "iam:CreatePolicy"
    "iam:AttachRolePolicy"
    "iam:GetRole"
    "iam:GetPolicy"
    "iam:ListRoles"
    "iam:ListPolicies"
    "iam:DeleteRole"
    "iam:DeletePolicy"
    "iam:DetachRolePolicy"
    "ssm:PutParameter"
    "ssm:GetParameter"
    "ssm:DeleteParameter"
    "ssm:GetParameters"
    "s3:GetObject"
    "s3:PutObject"
    "dynamodb:GetItem"
    "dynamodb:PutItem"
    "dynamodb:DeleteItem"
  )
  
  # Get caller ARN once
  CALLER_ARN=$(aws sts get-caller-identity --query 'Arn' --output text)
  
  # Check all permissions in single API call
  DENIED_ACTIONS=$(aws iam simulate-principal-policy \
    --policy-source-arn "$CALLER_ARN" \
    --action-names "${REQUIRED_ACTIONS[@]}" \
    --resource-arns "*" \
    --query 'EvaluationResults[?EvalDecision!=`allowed`].ActionName' \
    --output text 2>/dev/null)
  
  if [ -z "$DENIED_ACTIONS" ]; then
    echo -e "${GREEN}✓${NC} Required AWS permissions available"
    return 0
  else
    echo -e "${RED}✗${NC} Missing AWS permissions:"
    echo "$DENIED_ACTIONS" | tr '\t' '\n' | sed 's/^/    /'
    FAILURES+=("Missing AWS permissions")
    return 1
  fi
}

check_jq() {
  if command -v jq &>/dev/null; then
    JQ_VERSION=$(jq --version)
    echo -e "${GREEN}✓${NC} jq installed: $JQ_VERSION"
    return 0
  else
    echo -e "${RED}✗${NC} jq not found"
    echo "  Install jq: https://jqlang.github.io/jq/download/"
    FAILURES+=("No jq")
    return 1
  fi
}

check_required_files() {
  # Check for main.tf
  if [ -f "main.tf" ]; then
    echo -e "${GREEN}✓${NC} Terraform configuration found: main.tf"
  else
    echo -e "${RED}✗${NC} Terraform configuration missing: main.tf"
    FAILURES+=("Missing main.tf")
    return 1
  fi
  
  return 0
}

check_self_deployment_prevention() {
  # Get current project name from git remote
  REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
  if [[ "$REMOTE_URL" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
    CURRENT_PROJECT="${BASH_REMATCH[2]}"
    
    # Check if there's a project directory with the same name
    if [ -d "projects/$CURRENT_PROJECT" ]; then
      echo -e "${RED}✗${NC} Self-deployment detected: projects/$CURRENT_PROJECT"
      echo "  This project cannot create a deployment role for itself"
      echo "  Remove the projects/$CURRENT_PROJECT directory"
      FAILURES+=("Self-deployment prevention")
      return 1
    else
      echo -e "${GREEN}✓${NC} No self-deployment detected"
      return 0
    fi
  else
    echo -e "${YELLOW}⚠${NC} Could not determine project name from git remote"
    return 0
  fi
}

check_bash_version() {
  BASH_VERSION=${BASH_VERSION:-"unknown"}
  if [[ "$BASH_VERSION" =~ ^[4-9] ]]; then
    echo -e "${GREEN}✓${NC} Bash version: $BASH_VERSION"
    return 0
  else
    # On macOS, bash 3.2 is default but scripts should still work
    if [[ "$OSTYPE" == "darwin"* ]]; then
      echo -e "${YELLOW}⚠${NC} Bash version: $BASH_VERSION (macOS default, should work)"
      return 0
    else
      echo -e "${RED}✗${NC} Bash version too old: $BASH_VERSION"
      echo "  Requires Bash 4.0 or later"
      FAILURES+=("Old Bash version")
      return 1
    fi
  fi
}

# Run all checks
check_git_repo
check_git_uncommitted
check_git_untracked
check_git_detached_head
check_git_upstream
check_git_unpushed
check_bash_version
check_terraform
check_aws_cli
check_aws_auth
check_aws_permissions
check_jq
check_required_files
check_self_deployment_prevention

# Report results
echo ""
if [ ${#FAILURES[@]} -eq 0 ]; then
  echo -e "${GREEN}✓ All prerequisites satisfied${NC}"
  exit 0
else
  echo -e "${RED}✗ Prerequisites failed:${NC}"
  for failure in "${FAILURES[@]}"; do
    echo "  - $failure"
  done
  echo ""
  echo "Please resolve the above issues before proceeding."
  exit 1
fi
