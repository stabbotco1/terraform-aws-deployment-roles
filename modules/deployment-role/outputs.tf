output "role_arn" {
  description = "ARN of the deployment role"
  value       = aws_iam_role.deployment.arn
}

output "role_name" {
  description = "Name of the deployment role"
  value       = aws_iam_role.deployment.name
}

output "policy_arn" {
  description = "ARN of the deployment policy"
  value       = aws_iam_policy.deployment.arn
}

output "ssm_parameter_name" {
  description = "SSM parameter name storing the role ARN"
  value       = aws_ssm_parameter.role_arn.name
}
