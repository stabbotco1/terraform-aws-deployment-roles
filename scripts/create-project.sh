#!/bin/bash
# scripts/create-project.sh - Create new project from template

set -euo pipefail

# Change to project root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

# Check if required arguments are provided
if [ $# -ne 1 ]; then
  echo "Usage: $0 <project-name>"
  echo ""
  echo "Examples:"
  echo "  $0 static-website-infrastructure"
  echo "  $0 api-gateway"
  echo ""
  echo "Project name should be short (role name will be: gharole-{project-name}-prd)"
  echo "GitHub repository will be auto-detected from git remote"
  exit 1
fi

PROJECT_NAME="$1"

# Prevent self-deployment
REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
if [[ "$REMOTE_URL" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
  CURRENT_PROJECT="${BASH_REMATCH[2]}"
  if [ "$PROJECT_NAME" = "$CURRENT_PROJECT" ]; then
    echo "Error: Cannot create deployment role for this project itself"
    echo "Current project: $CURRENT_PROJECT"
    echo "Requested project: $PROJECT_NAME"
    echo "This would create a circular dependency"
    exit 1
  fi
fi

# Validate project name length (role name will be gharole-{project}-prd)
ROLE_NAME="gharole-${PROJECT_NAME}-prd"
if [ ${#ROLE_NAME} -gt 64 ]; then
  echo "Error: Role name '${ROLE_NAME}' exceeds 64 characters (${#ROLE_NAME})"
  echo "Please use a shorter project name"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE_DIR="${PROJECT_ROOT}/templates/new-project"
TARGET_DIR="${PROJECT_ROOT}/projects/${PROJECT_NAME}"

# Check if project already exists
if [ -d "$TARGET_DIR" ]; then
  echo "Error: Project '${PROJECT_NAME}' already exists at ${TARGET_DIR}"
  exit 1
fi

# Check if template exists
if [ ! -d "$TEMPLATE_DIR" ]; then
  echo "Error: Template directory not found at ${TEMPLATE_DIR}"
  exit 1
fi

echo "Creating new project: ${PROJECT_NAME}"
echo "Role Name: ${ROLE_NAME}"
echo "Target Directory: ${TARGET_DIR}"
echo ""
echo "Note: GitHub repository and other metadata will be auto-detected from git remote"
echo ""

# Copy template to new project directory
cp -r "$TEMPLATE_DIR" "$TARGET_DIR"

# Process template files
cd "$TARGET_DIR/prd"

# Process policy template
if [ -f "policies/deployment-policy.json.template" ]; then
  mv "policies/deployment-policy.json.template" "policies/deployment-policy.json"
fi

echo "✓ Project created successfully"
echo ""
echo "Next steps:"
echo "1. Review and customize the deployment policy:"
echo "   ${TARGET_DIR}/prd/policies/deployment-policy.json"
echo ""
echo "2. Deploy all roles:"
echo "   ./scripts/deploy.sh"
echo ""
echo "3. The role ARN will be available at SSM parameter:"
echo "   /deployment-roles/{org-${PROJECT_NAME}}/role-arn"
