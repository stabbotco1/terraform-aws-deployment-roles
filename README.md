# Foundation IAM Deploy Roles

## OpenTofu Infrastructure for GitHub Actions Deployment Roles

Creates IAM roles for GitHub Actions workflows to deploy AWS infrastructure without long-lived credentials. Uses OIDC trust policies scoped to specific repositories and publishes role ARNs to SSM Parameter Store for consuming project discovery.

Repository: [foundation-iam-deploy-roles](https://github.com/stephenabbot/foundation-iam-deploy-roles)

## What Problem This Project Solves

GitHub Actions workflows require AWS credentials to deploy infrastructure, but managing these credentials creates security risks and operational overhead. Traditional approaches use long-lived access keys stored as secrets, creating credential sprawl and rotation complexity.

- Managing long-lived access keys stored as GitHub secrets creates security vulnerabilities
- Credential rotation across multiple repositories becomes operationally complex
- Each project needs dedicated roles with appropriate permissions for deployment
- Consuming projects require service discovery without hardcoding role names or ARNs
- Traditional credential management approaches create sprawl and maintenance overhead

## What This Project Does

Eliminates credential management through OIDC trust relationships that allow GitHub repositories to assume AWS roles directly. Generates deployment policies from JSON files and publishes role ARNs to SSM Parameter Store for service discovery.

- Creates IAM roles with repository-scoped OIDC trust policies for secure authentication
- Generates deployment policies dynamically from JSON configuration files
- Publishes role ARNs to SSM Parameter Store for consuming project discovery
- Enables GitHub Actions workflows to assume AWS roles without long-lived credentials
- Provides automated prerequisite validation and backend configuration management
- Implements consistent tagging and naming conventions across deployment infrastructure

## What This Project Changes

Creates IAM roles with repository-scoped OIDC trust policies and publishes role ARNs to predictable SSM Parameter Store paths for consuming project discovery.

### Resources Created

- IAM roles with naming pattern `gharole-{project}-{environment}`
- IAM policies with naming pattern `ghpolicy-{project}-{environment}`
- Policy attachments linking deployment policies to roles
- SSM parameters at `/deployment-roles/{project-name}/role-arn` storing role ARNs
- Comprehensive resource tags for cost allocation and ownership tracking

### Functional Changes

- Enables GitHub Actions workflows to assume AWS roles without long-lived credentials
- Provides service discovery mechanism for consuming projects to find their deployment roles
- Establishes consistent tagging and naming conventions across deployment infrastructure
- Implements automated prerequisite validation and backend configuration management

## Quick Start

Basic deployment workflow:

```bash
# Create new project configuration
./scripts/create-project.sh my-project

# Edit deployment policy
# projects/my-project/prd/policies/deployment-policy.json

# Deploy all roles
./scripts/deploy.sh

# Verify deployment
./scripts/list-deployed-resources.sh
```

See [prerequisites documentation](https://github.com/stephenabbot/foundation-iam-deploy-roles/blob/main/docs/prerequisites.md) for detailed requirements, [troubleshooting guide](https://github.com/stephenabbot/foundation-iam-deploy-roles/blob/main/docs/troubleshooting.md) for common issues, [architecture documentation](https://github.com/stephenabbot/foundation-iam-deploy-roles/blob/main/docs/architecture.md) for system design and integration patterns, and [tagging documentation](https://github.com/stephenabbot/foundation-iam-deploy-roles/blob/main/docs/tags.md) for resource tagging strategy and cost allocation.

## AWS Well-Architected Framework

This project demonstrates alignment with the [AWS Well-Architected Framework](https://aws.amazon.com/blogs/apn/the-6-pillars-of-the-aws-well-architected-framework/):

### Security

- OIDC authentication eliminates long-lived credentials in GitHub Actions
- Trust policies scoped to specific repositories prevent unauthorized access
- IAM policies loaded from JSON files enable least-privilege access patterns
- Role ARNs published to SSM Parameter Store avoid hardcoded credentials

### Operational Excellence

- Automated prerequisite validation prevents deployment failures
- Comprehensive deployment scripts handle backend configuration and role assumption
- Resource listing capabilities enable infrastructure visibility and orphaned resource detection
- Git repository validation ensures deployment metadata accuracy

### Reliability

- Idempotent deployment operations support multiple execution attempts
- Backend state management through foundation infrastructure provides consistency
- Comprehensive error handling with detailed troubleshooting guidance
- Self-deployment prevention mechanisms avoid circular dependencies

### Cost Optimization

- Serverless IAM roles incur no ongoing compute costs
- SSM Parameter Store usage minimizes service discovery overhead
- Consistent resource tagging enables accurate cost allocation and tracking
- Dynamic project discovery eliminates unused role provisioning

## Technologies Used

| Technology | Purpose | Implementation |
|------------|---------|----------------|
| Kiro CLI with Claude | AI-assisted development, design, and implementation | Project architecture design and code generation |
| OpenTofu | Infrastructure as Code | Version 1.0+ with AWS provider ~5.0 for IAM resource management |
| AWS IAM | Role creation and policy management | Repository-scoped OIDC trust policies with least-privilege access |
| AWS SSM Parameter Store | Role ARN publishing and service discovery | Predictable parameter paths at `/deployment-roles/{project}/role-arn` |
| GitHub Actions OIDC | Secure authentication without long-lived credentials | Trust relationships for direct role assumption from GitHub workflows |
| Bash | Deployment automation and operational workflows | Scripts for project creation, deployment, and resource management |
| AWS CLI | Service interaction and credential management | Backend configuration, role assumption, and AWS service operations |
| Git | Repository metadata detection and validation | Automated resource naming and tagging from repository information |
| jq | JSON processing and parameter manipulation | Policy file processing, output parsing, and configuration handling |

## Copyright

© 2025 Stephen Abbot - MIT License
