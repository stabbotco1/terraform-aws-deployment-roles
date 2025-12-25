# Terraform AWS Deployment Roles

https://github.com/stephenabbot/terraform-aws-deployment-roles

IAM role management for GitHub Actions deployments with OIDC authentication and SSM parameter publishing for consuming projects.

## Table of Contents

- [Why](#why)
- [How](#how)
  - [Architecture](#architecture)
  - [Script-Based Deployment](#script-based-deployment)
- [Resources Deployed](#resources-deployed)
- [Prerequisites](#prerequisites)
  - [Foundation Infrastructure](#foundation-infrastructure)
  - [Required Tools](#required-tools)
  - [Git Repository Setup](#git-repository-setup)
- [Quick Start](#quick-start)
- [Troubleshooting](#troubleshooting)
  - [Role Assumption Failures](#role-assumption-failures)
  - [Policy Attachment Issues](#policy-attachment-issues)
  - [SSM Parameter Access](#ssm-parameter-access)
- [Technologies and Services](#technologies-and-services)
  - [Infrastructure as Code](#infrastructure-as-code)
  - [AWS Services](#aws-services)
  - [Development Tools](#development-tools)
- [Copyright](#copyright)

## Why

GitHub Actions workflows need IAM roles to deploy AWS infrastructure, but managing these roles manually creates security risks and operational overhead. Each project requires dedicated roles with appropriate permissions that can be discovered by consuming projects without hardcoding role names or ARNs.

This project solves deployment authentication by creating project-specific IAM roles with OIDC trust policies scoped to specific GitHub repositories. Roles start with broad permissions for CloudTrail analysis and policy refinement, then evolve to least-privilege access. Role ARNs are published to SSM Parameter Store at predictable paths, enabling consuming projects to discover their deployment roles without tight coupling.

The project is designed for GitHub Actions integration with OIDC authentication, eliminating the need for long-lived credentials. GitHub Actions workflow implementation is planned for future releases.

This project depends on [terraform-aws-cfn-foundation](https://github.com/stephenabbot/terraform-aws-cfn-foundation), which provides the S3 backend, DynamoDB locking, and OIDC provider that deployment roles consume. The foundation must be deployed first to establish the shared infrastructure that this project requires.

## How

### Architecture

The project uses OpenTofu to create IAM roles with OIDC trust policies that allow GitHub Actions to assume roles without long-lived credentials. Each role is scoped to a specific GitHub repository using StringLike conditions in the trust policy. The OIDC provider ARN is retrieved from SSM Parameter Store where the foundation project published it.

Role naming uses the pattern gharole-{project}-{environment} with abbreviated environments like prd for production. This keeps role names within AWS IAM limits while maintaining readability.

The project structure supports multiple project-environment combinations through dynamic discovery. OpenTofu scans the projects directory for deployment-policy.json files and creates roles for each discovered combination. This enables adding new projects by copying templates without modifying the root configuration.

All role ARNs are published to SSM Parameter Store at /deployment-roles/{github-org-repo}/role-arn, enabling consuming projects to construct parameter paths from their own repository names. This decouples consuming projects from deployment role naming decisions and enables clean multi-region deployments.

### Script-Based Deployment

Deployment scripts handle all operational complexity including prerequisite validation, backend configuration, role assumption, and OpenTofu execution. The scripts validate git repository state, check for foundation infrastructure, and assume the foundation deployment role when available.

Backend configuration is retrieved dynamically from SSM parameters published by the foundation project. This eliminates hardcoded bucket names and ensures deployment roles use the same backend infrastructure as other projects. State keys incorporate git repository information for uniqueness and organization.

Idempotent operations allow running deployment scripts multiple times safely. The scripts detect existing infrastructure and perform updates rather than failing. Resource listing scripts identify orphaned resources that exist in AWS but are not managed by the current OpenTofu state, helping maintain clean infrastructure.

## Resources Deployed

For each project-environment combination, the following resources are created:

- IAM role with OIDC trust policy scoped to specific GitHub repository
- IAM policy containing deployment permissions loaded from JSON file
- Policy attachment linking the policy to the role
- SSM parameter storing the role ARN for consuming project discovery

Role names follow the pattern gharole-{project}-{environment} where environment uses abbreviated forms like prd for production. Policy names follow ghpolicy-{project}-{environment} for consistency. SSM parameters use the path /deployment-roles/{github-org-repo}/role-arn for predictable discovery.

All resources include comprehensive tags aligned with foundation standards for cost allocation, ownership tracking, and resource management. Tags include project name, repository URL, environment, owner, deployment principal, and management tool.

## Prerequisites

### Foundation Infrastructure

This project requires [terraform-aws-cfn-foundation](https://github.com/stephenabbot/terraform-aws-cfn-foundation) to be deployed first. The foundation provides:

- S3 bucket for OpenTofu state storage with the name published to SSM Parameter Store
- DynamoDB table for state locking with the name published to SSM Parameter Store  
- OIDC provider for GitHub Actions authentication with the ARN published to SSM Parameter Store
- Foundation deployment role that this project assumes for secure operations

Deploy the foundation project before attempting to use deployment roles. The deployment scripts will automatically discover and use foundation infrastructure through SSM parameter lookup.

### Required Tools

The following tools must be installed and available in your PATH:

- OpenTofu version 1.0 or higher for infrastructure deployment and state management
- AWS CLI version 2.x for AWS service interaction and credential management
- Bash version 4.x or higher for script execution and automation
- jq for JSON processing in deployment scripts and parameter handling
- Git for repository information detection and version control

### Git Repository Setup

The repository must be:

- Initialized as a git repository with a remote origin configured pointing to GitHub
- Working directory must be clean with no uncommitted changes, untracked files, or unpushed commits
- Remote origin URL must match the target repository for the deployment role being created

These requirements ensure deployment metadata is accurate and prevent deploying roles with incorrect repository scoping in the OIDC trust policies.

## Quick Start

Clone the repository and navigate to the project directory:

```bash
git clone https://github.com/stephenabbot/terraform-aws-deployment-roles.git
cd terraform-aws-deployment-roles
```

Create a new project configuration:

```bash
./scripts/create-project.sh my-project
```

This creates a new directory at projects/my-project/prd with template files. Edit the generated files:

- Modify projects/my-project/prd/.env with your target repository and tags
- Update projects/my-project/prd/policies/deployment-policy.json with required permissions

Deploy the deployment role:

```bash
./scripts/deploy.sh
```

The deployment script will validate prerequisites, assume the foundation deployment role, configure the backend, and create the IAM role. After successful deployment, the role ARN will be available in SSM Parameter Store for consuming projects.

Verify the deployment:

```bash
./scripts/list-deployed-resources.sh
```

## Troubleshooting

### Role Assumption Failures

If GitHub Actions cannot assume the deployment role when implemented, verify:

- The OIDC provider exists and has correct thumbprints for GitHub
- The role trust policy includes the correct repository name in StringLike conditions
- The GitHub repository name matches exactly what was configured during role creation
- The GitHub Actions workflow has id-token write permissions

Check the IAM role trust policy in the AWS console to confirm the repository name and OIDC provider ARN are correct. The trust policy should include conditions for both the audience and the repository subject.

### Policy Attachment Issues

If the deployment role lacks necessary permissions, check:

- The deployment-policy.json file contains valid JSON with required permissions
- The policy document does not exceed AWS size limits for IAM policies
- The policy actions and resources are correctly formatted for the target services
- The policy is attached to the role and not just created

Use the AWS CLI to test role permissions by assuming the role and attempting the operations your deployment requires. Start with broad permissions and refine based on CloudTrail analysis.

### SSM Parameter Access

If consuming projects cannot find the role ARN, verify:

- The SSM parameter exists at /deployment-roles/{github-org-repo}/role-arn
- The parameter is in the us-east-1 region where all deployment roles are created
- The consuming project has permissions to read SSM parameters
- The parameter path construction matches your GitHub organization and repository name

Use the AWS CLI to directly query the SSM parameter and confirm it contains the expected role ARN. Check that the parameter name exactly matches what the consuming project is looking for.

## Technologies and Services

### Infrastructure as Code

- OpenTofu for infrastructure deployment and state management with provider compatibility
- Terraform modules for reusable role creation and consistent tagging patterns
- Bash scripting for deployment automation and operational workflows

### AWS Services

- IAM for role creation, policy management, and OIDC trust relationships
- SSM Parameter Store for role ARN publishing and service discovery
- S3 for OpenTofu state storage provided by foundation infrastructure
- DynamoDB for distributed state locking provided by foundation infrastructure

### Development Tools

- AWS CLI for service interaction and role assumption testing
- Git for version control and repository metadata detection
- jq for JSON processing and parameter manipulation
- GitHub Actions for CI/CD integration with OIDC authentication (implementation planned)

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

© 2025 Stephen Abbot - MIT License
