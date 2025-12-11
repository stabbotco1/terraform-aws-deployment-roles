#!/bin/bash
# scripts/verify-prerequisites.sh - Validate all prerequisites before deployment

set -euo pipefail

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

FAILURES=()

echo "Verifying prerequisites for OpenTofu deployment roles..."
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
    echo -e "${RED}✗${NC} Detached HEAD state detected"
    echo "  Checkout a branch before deployment"
    FAILURES+=("Detached HEAD")
    return 1
  fi
}

check_git_upstream() {
  if git rev-parse --abbrev-ref @{u} &>/dev/null; then
    echo -e "${GREEN}✓${NC} Branch has upstream configured"
    return 0
  else
    echo -e "${RED}✗${NC} No upstream branch configured"
    echo "  Push branch and set upstream before deployment"
    FAILURES+=("No upstream branch")
    return 1
  fi
}

check_git_unpushed() {
  LOCAL=$(git rev-parse @ 2>/dev/null)
  REMOTE=$(git rev-parse @{u} 2>/dev/null || echo "")
  
  if [ -z "$REMOTE" ]; then
    # Already caught by check_git_upstream
    return 0
  fi
  
  if [ "$LOCAL" = "$REMOTE" ]; then
    echo -e "${GREEN}✓${NC} No unpushed commits"
    return 0
  else
    echo -e "${RED}✗${NC} Unpushed commits detected"
    echo "  Push commits before deployment"
    FAILURES+=("Unpushed commits")
    return 1
  fi
}

check_tofu() {
  if command -v tofu &>/dev/null; then
    TF_VERSION=$(tofu version -json | jq -r .terraform_version)
    echo -e "${GREEN}✓${NC} OpenTofu is installed (Version: $TF_VERSION)"
    return 0
  else
    echo -e "${RED}✗${NC} OpenTofu not found"
    echo "  Install: https://opentofu.org/docs/intro/install/"
    FAILURES+=("OpenTofu not installed")
    return 1
  fi
}

check_aws_cli() {
  if command -v aws &>/dev/null; then
    AWS_VERSION=$(aws --version 2>&1 | cut -d/ -f2 | cut -d' ' -f1)
    echo -e "${GREEN}✓${NC} AWS CLI is installed (Version: $AWS_VERSION)"
    return 0
  else
    echo -e "${RED}✗${NC} AWS CLI not found"
    echo "  Install: https://aws.amazon.com/cli/"
    FAILURES+=("AWS CLI not installed")
    return 1
  fi
}

check_aws_auth() {
  if aws sts get-caller-identity &>/dev/null; then
    CALLER_ARN=$(aws sts get-caller-identity --query 'Arn' --output text)
    ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
    echo -e "${GREEN}✓${NC} AWS authentication valid"
    echo "  Account: $ACCOUNT_ID"
    echo "  Identity: $CALLER_ARN"
    return 0
  else
    echo -e "${RED}✗${NC} AWS authentication failed"
    echo "  Run: aws configure"
    FAILURES+=("AWS authentication")
    return 1
  fi
}

check_aws_permissions() {
  echo "Checking AWS permissions..."
  
  # Test IAM permissions
  if aws iam list-roles --max-items 1 &>/dev/null; then
    echo -e "${GREEN}✓${NC} IAM permissions valid"
  else
    echo -e "${RED}✗${NC} IAM permissions insufficient"
    FAILURES+=("IAM permissions")
  fi
  
  # Test SSM permissions
  if aws ssm describe-parameters --max-items 1 &>/dev/null; then
    echo -e "${GREEN}✓${NC} SSM Parameter Store permissions valid"
  else
    echo -e "${RED}✗${NC} SSM Parameter Store permissions insufficient"
    FAILURES+=("SSM permissions")
  fi
}

check_jq() {
  if command -v jq &>/dev/null; then
    JQ_VERSION=$(jq --version)
    echo -e "${GREEN}✓${NC} jq is installed (Version: $JQ_VERSION)"
    return 0
  else
    echo -e "${RED}✗${NC} jq not found"
    echo "  Install: brew install jq (macOS) or apt-get install jq (Linux)"
    FAILURES+=("jq required")
    return 1
  fi
}

check_bash_version() {
  BASH_VERSION=${BASH_VERSION:-"unknown"}
  if [[ "$BASH_VERSION" =~ ^[4-9] ]]; then
    echo -e "${GREEN}✓${NC} Bash version compatible: $BASH_VERSION"
  else
    echo -e "${YELLOW}⚠${NC} Bash version may be incompatible: $BASH_VERSION"
    echo "  Recommended: Bash 4+ (macOS: brew install bash)"
  fi
}

check_policy_file() {
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
  POLICY_FILE="${PROJECT_ROOT}/policies/deployment-policy.json"
  
  if [[ -f "${POLICY_FILE}" ]]; then
    echo -e "${GREEN}✓${NC} Policy file found: deployment-policy.json"
    
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

check_env_file() {
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
  ENV_FILE="${PROJECT_ROOT}/.env"
  
  if [[ -f "${ENV_FILE}" ]]; then
    echo -e "${GREEN}✓${NC} Environment file found: .env"
    
    # Check required variables
    source "${ENV_FILE}"
    
    if [[ -n "${PROJECT_NAME:-}" ]]; then
      echo -e "${GREEN}✓${NC} PROJECT_NAME configured: ${PROJECT_NAME}"
    else
      echo -e "${RED}✗${NC} PROJECT_NAME not set in .env"
      FAILURES+=("Missing PROJECT_NAME")
    fi
    
    if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
      echo -e "${GREEN}✓${NC} GITHUB_REPOSITORY configured: ${GITHUB_REPOSITORY}"
    else
      echo -e "${RED}✗${NC} GITHUB_REPOSITORY not set in .env"
      FAILURES+=("Missing GITHUB_REPOSITORY")
    fi
  else
    echo -e "${RED}✗${NC} Environment file not found: ${ENV_FILE}"
    FAILURES+=("Missing .env file")
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
      echo "  Foundation infrastructure not deployed or accessible"
      FAILURES+=("Missing parameter: ${param}")
    fi
  done
}

# Run all checks
check_git_repo
check_git_uncommitted
check_git_untracked
check_git_detached_head
check_git_upstream
check_git_unpushed
check_bash_version
check_tofu
check_aws_cli
check_aws_auth
check_aws_permissions
check_jq
check_env_file
check_policy_file
check_foundation_parameters

# Report results
echo ""
if [ ${#FAILURES[@]} -eq 0 ]; then
  echo -e "${GREEN}✓ All prerequisites satisfied${NC}"
  echo ""
  exit 0
else
  echo -e "${RED}✗ Prerequisites check failed:${NC}"
  for failure in "${FAILURES[@]}"; do
    echo "  - $failure"
  done
  echo ""
  echo "Fix the above issues and try again."
  exit 1
fi
