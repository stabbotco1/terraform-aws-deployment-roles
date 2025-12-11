# Terraform AWS Deployment Roles

IAM role management for GitHub Actions deployments with SSM parameter publishing for consuming projects.

## Overview

This repository manages IAM roles that GitHub Actions workflows assume via OIDC to deploy AWS infrastructure. Each project-environment combination receives a dedicated role with appropriate permissions. Role ARNs are automatically published to SSM Parameter Store for consuming projects to discover.

## Prerequisites

- AWS CLI installed and configured
- OpenTofu >= 1.0 installed
- jq installed
- Git repository with clean state (no uncommitted changes, untracked files, or unpushed commits)
- Foundation infrastructure deployed (terraform-aws-cfn-foundation)

## Quick Start

Create a new project:

```bash
./scripts/create-project.sh static-website stabbotco1/terraform-aws-static-website-infrastructure
```

Deploy the role:

```bash
cd projects/static-website/production
./scripts/deploy.sh
```

## Architecture

This project follows the same patterns as the CloudFormation foundation:

- **Comprehensive Prerequisites**: Git state validation, tool checks, AWS permissions
- **Metadata Collection**: Automatic detection of repository, account, and deployment context  
- **Role Assumption**: Uses foundation deployment role for secure operations
- **Step-by-step Deployment**: Clear progress indication with numbered steps
- **Resource Tracking**: Complete inventory and status reporting
- **SSM Parameter Publishing**: Role ARNs stored in predictable SSM parameters for consuming projects
- **Multi-Region Support**: Fixed us-east-1 control plane region for consistent role discovery

## Project Structure

```
projects/
  <project-name>/
    <environment>/
      .env                    # Configuration
      main.tf                 # Terraform root
      policies/
        deployment-policy.json  # IAM permissions
      scripts/
        deploy.sh             # Deploy role
        destroy.sh            # Destroy role
```

## Configuration

Each project-environment has an .env file:

```bash
PROJECT_NAME=static-website
ENVIRONMENT=Production
GITHUB_REPOSITORY=stabbotco1/terraform-aws-static-website-infrastructure
AWS_REGION=us-east-1  # Fixed control plane region
```

## Multi-Region Support

**Control Plane Region**: All deployment roles are created in `us-east-1` regardless of where consuming projects deploy.

**SSM Parameter Discovery**: Consuming projects can discover their deployment role ARN from any region by querying the predictable SSM parameter in `us-east-1`:

```hcl
# In consuming project (any region)
provider "aws" {
  alias  = "control_plane"
  region = "us-east-1"
}

data "aws_ssm_parameter" "deployment_role_arn" {
  provider = aws.control_plane
  name     = "/deployment-roles/stabbotco1-terraform-aws-static-website-infrastructure/role-arn"
}

# Use the role ARN for assumption
provider "aws" {
  assume_role {
    role_arn = data.aws_ssm_parameter.deployment_role_arn.value
  }
}
```

## SSM Parameter Convention

Role ARNs are published to SSM Parameter Store with predictable paths:

**Pattern**: `/deployment-roles/{github-org-repo}/role-arn`

**Example**: `/deployment-roles/stabbotco1-terraform-aws-static-website-infrastructure/role-arn`

This enables consuming projects to construct the parameter path from their own repository name without hardcoding role names.

## Shortened Naming Convention

To stay within AWS IAM limits while maintaining readability:

- **IAM Roles**: `gharole-{project}-prd` (GitHub Actions Role)
- **IAM Policies**: `ghpolicy-{project}-prd` (GitHub Actions Policy)
- **Environment Abbreviations**: Production → `prd`, Development → `dev`, etc.

This approach reduces role names from 60+ characters to ~40 characters while maintaining clarity.

## Policy Evolution

1. Start with broad permissions (policies/deployment-policy.json)
2. Deploy infrastructure using the role
3. Analyze CloudTrail logs with IAM Access Analyzer
4. Update policy with refined permissions
5. Redeploy: `./scripts/deploy.sh`

## Orphaned Resource Detection

The `list-deployed-resources.sh` script automatically detects orphaned resources that exist in AWS but aren't managed by the current Terraform state:

- **IAM Roles**: GitHub Actions deployment roles with project tags not in state
- **IAM Policies**: Deployment policies with project tags not in state  
- **SSM Parameters**: Parameters in `/deployment-roles` path not in state

Orphaned resources typically result from:
- Failed deployments that left partial infrastructure
- Manual resource deletion from Terraform state
- Resources created outside of Terraform
- Previous deployments not properly cleaned up

Use this detection to identify resources that may need manual cleanup or state import.

## Commands

Deploy role:

```bash
cd projects/<project>/<environment>
./scripts/deploy.sh
```

List resources and check for orphans:

```bash
./scripts/list-deployed-resources.sh
```

Destroy role:

```bash
./scripts/destroy.sh
```

## GitHub Actions Integration

Configure workflow to assume the role:

```yaml
permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/gharole-static-website-prd
          aws-region: us-east-1
      
      - name: Deploy infrastructure
        run: terraform apply -auto-approve
```

## Foundation-Aligned Tagging

All resources are tagged with foundation-standard tags:

- **Project**: Project name
- **Repository**: Full repository URL
- **Environment**: Environment name (e.g., Production, Development)
- **Owner**: Resource owner
- **DeployedBy**: IAM principal that deployed the stack
- **ManagedBy**: Management tool (Terraform)
- **DeploymentID**: Deployment identifier

## Created Resources

For each deployment role project, the following resources are created:

1. **IAM Role**: `gharole-{project}-{environment}-deployment-role`
2. **IAM Policy**: `ghpolicy-{project}-{environment}-deployment-policy`
3. **Policy Attachment**: Links policy to role
4. **SSM Parameter**: `/deployment-roles/{github-org-repo}/role-arn` (stores role ARN)

## Consuming Project Integration

Projects that need to use deployment roles can discover them via SSM parameters:

```bash
# Get role ARN for your project
aws ssm get-parameter \
  --region us-east-1 \
  --name "/deployment-roles/stabbotco1-terraform-aws-static-website-infrastructure/role-arn" \
  --query Parameter.Value --output text
```

This decouples consuming projects from deployment role naming decisions and enables clean multi-region deployments.

## Lessons Learned

### **Script Development & Testing**

**Issue**: Scripts initially lacked executable permissions when generated from templates.
**Solution**: Added `chmod +x scripts/*.sh` to the create-project script.
**Lesson**: Always ensure generated scripts have proper permissions in automation workflows.

**Issue**: Orphan detection incorrectly flagged current project resources as orphaned due to subshell variable scoping.
**Solution**: Refactored to avoid subshells and use proper variable scoping with explicit state resource checking.
**Lesson**: Bash subshells create separate variable contexts - avoid them when sharing state between operations.

**Issue**: Template processing failed with sed when GitHub repository names contained forward slashes.
**Solution**: Used proper sed delimiters (`|` instead of `/`) for paths containing slashes.
**Lesson**: Always escape special characters in sed operations, especially when processing user input.

### **Naming Conventions & AWS Limits**

**Issue**: Initial role naming (`github-actions-{project}-{environment}-deployment-role`) exceeded AWS 64-character limit for longer project names.
**Solution**: Implemented shortened naming convention (`gharole-{project}-prd`) reducing typical names from 60+ to ~40 characters.
**Lesson**: Design naming conventions with AWS service limits in mind from the start, not as an afterthought.

**Issue**: Environment names like "Production" consumed unnecessary characters in resource names.
**Solution**: Used abbreviations (Production → prd, Development → dev) while maintaining readability.
**Lesson**: Optimize for both human readability and system constraints through thoughtful abbreviations.

### **State Management & Idempotency**

**Issue**: Scripts weren't properly idempotent - running deploy twice could cause issues.
**Solution**: Implemented proper state checking and "No changes" detection in deployment workflows.
**Lesson**: Infrastructure scripts must be idempotent by design - running them multiple times should be safe.

**Issue**: Git state validation was too strict, preventing legitimate deployments.
**Solution**: Balanced git cleanliness requirements with practical workflow needs.
**Lesson**: Validation should prevent errors without blocking legitimate use cases.

### **Foundation Integration Patterns**

**Issue**: Inconsistent tagging between this project and the CloudFormation foundation.
**Solution**: Aligned all tagging to use foundation standards with proper TF_VAR_ environment variable mapping.
**Lesson**: Establish and maintain consistent patterns across all infrastructure projects for operational clarity.

**Issue**: Backend configuration was hardcoded instead of using foundation-provided parameters.
**Solution**: Used SSM parameter lookup to retrieve foundation-managed S3 bucket and DynamoDB table names.
**Lesson**: Avoid hardcoding infrastructure dependencies - use service discovery patterns instead.

### **Error Handling & User Experience**

**Issue**: Error messages were unclear when prerequisites failed.
**Solution**: Implemented comprehensive prerequisite checking with clear, actionable error messages.
**Lesson**: Good error messages should tell users exactly what's wrong and how to fix it.

**Issue**: Deployment failures left partial infrastructure without clear cleanup guidance.
**Solution**: Added orphan detection to identify and help clean up partial deployments.
**Lesson**: Always provide mechanisms to detect and clean up failed deployments.

### **Security & Access Patterns**

**Issue**: Role assumption logic was complex and error-prone.
**Solution**: Simplified to use foundation deployment role with clear fallback to current credentials.
**Lesson**: Security patterns should be simple and predictable - complexity breeds vulnerabilities.

**Issue**: OIDC trust policies were too broad initially.
**Solution**: Scoped trust policies to specific GitHub repositories using StringLike conditions.
**Lesson**: Apply principle of least privilege from the start, especially for cross-service authentication.

### **Testing & Validation Strategies**

**Issue**: Manual testing was time-consuming and error-prone.
**Solution**: Developed systematic testing approach: create → deploy → list → destroy → recreate cycle.
**Lesson**: Establish repeatable testing patterns early to catch regressions quickly.

**Issue**: Template changes weren't validated against existing projects.
**Solution**: Implemented full workflow testing including project recreation from templates.
**Lesson**: Test the entire user journey, not just individual components.

### **Documentation & Maintenance**

**Issue**: README didn't reflect actual implementation details after multiple iterations.
**Solution**: Comprehensive review and update of all documentation to match current implementation.
**Lesson**: Keep documentation synchronized with code changes - outdated docs are worse than no docs.

**Issue**: Lessons learned weren't captured during development.
**Solution**: Added this comprehensive lessons learned section covering all major challenges encountered.
**Lesson**: Document lessons learned immediately while context is fresh - they're invaluable for future projects.
