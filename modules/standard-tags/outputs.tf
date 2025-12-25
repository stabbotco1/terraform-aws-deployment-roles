locals {
  base_tags = {
    Project      = var.project
    Repository   = var.repository
    Environment  = var.environment
    Owner        = var.owner
    ManagedBy    = var.managed_by
    DeploymentId = var.deployment_id  # Aligned with CFN standard (capital I, not ID)
  }

  deployed_by_tag = var.deployed_by != "" ? {
    DeployedBy = var.deployed_by
  } : {}

  all_tags = merge(
    local.base_tags,
    local.deployed_by_tag,
    var.additional_tags
  )
}

output "tags" {
  description = "Merged tags for resource tagging"
  value       = local.all_tags
}
