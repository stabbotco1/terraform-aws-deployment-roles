#!/bin/bash
# scripts/create-project.sh - Create new project from template

set -euo pipefail

# Check if required arguments are provided
if [ $# -ne 2 ]; then
  echo "Usage: $0 <project-name> <github-repository>"
  echo ""
  echo "Examples:"
  echo "  $0 static-website stabbotco1/terraform-aws-static-website-infrastructure"
  echo "  $0 api-gateway myorg/terraform-aws-api-infrastructure"
  echo ""
  echo "Project name should be short (role name will be: gharole-{project-name}-prd)"
  exit 1
fi

PROJECT_NAME="$1"
GITHUB_REPOSITORY="$2"

# Validate project name length (role name will be gharole-{project}-prd)
ROLE_NAME="gharole-${PROJECT_NAME}-prd"
if [ ${#ROLE_NAME} -gt 64 ]; then
  echo "Error: Role name '${ROLE_NAME}' exceeds 64 characters (${#ROLE_NAME})"
  echo "Please use a shorter project name"
  exit 1
fi

# Validate GitHub repository format
if [[ ! "$GITHUB_REPOSITORY" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]]; then
  echo "Error: GitHub repository must be in format 'org/repo'"
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
echo "GitHub Repository: ${GITHUB_REPOSITORY}"
echo "Role Name: ${ROLE_NAME}"
echo "Target Directory: ${TARGET_DIR}"
echo ""

# Copy template to new project directory
cp -r "$TEMPLATE_DIR" "$TARGET_DIR"

# Process template files
cd "$TARGET_DIR/production"

# Generate backend key
GITHUB_ORG_REPO_NORMALIZED=$(echo "${GITHUB_REPOSITORY}" | tr '/' '-')
BACKEND_KEY="deployment-roles/${GITHUB_ORG_REPO_NORMALIZED}/terraform.tfstate"

# Update .env file
if [ -f ".env.template" ]; then
  sed -e "s/{{PROJECT_NAME}}/${PROJECT_NAME}/g" \
      -e "s|{{GITHUB_REPOSITORY}}|${GITHUB_REPOSITORY}|g" \
      -e "s|{{BACKEND_KEY}}|${BACKEND_KEY}|g" \
      ".env.template" > ".env"
  rm ".env.template"
fi

# Update main.tf file
if [ -f "main.tf.template" ]; then
  sed -e "s/{{PROJECT_NAME}}/${PROJECT_NAME}/g" \
      -e "s|{{GITHUB_REPOSITORY}}|${GITHUB_REPOSITORY}|g" \
      "main.tf.template" > "main.tf"
  rm "main.tf.template"
fi

# Update variables.tf file
if [ -f "variables.tf.template" ]; then
  sed -e "s/{{PROJECT_NAME}}/${PROJECT_NAME}/g" \
      "variables.tf.template" > "variables.tf"
  rm "variables.tf.template"
fi

# Process policy template
if [ -f "policies/deployment-policy.json.template" ]; then
  cp "policies/deployment-policy.json.template" "policies/deployment-policy.json"
  rm "policies/deployment-policy.json.template"
fi

# Make scripts executable
chmod +x scripts/*.sh

echo "✓ Project created successfully"
echo ""
echo "Next steps:"
echo "1. Review and customize the deployment policy:"
echo "   ${TARGET_DIR}/production/policies/deployment-policy.json"
echo ""
echo "2. Deploy the role:"
echo "   cd ${TARGET_DIR}/production"
echo "   ./scripts/deploy.sh"
echo ""
echo "3. The role ARN will be available at SSM parameter:"
echo "   /deployment-roles/${GITHUB_ORG_REPO_NORMALIZED}/role-arn"
