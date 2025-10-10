output "boundary_arn" {
  description = "The permission boundary — the hard ceiling every role inherits."
  value       = aws_iam_policy.boundary.arn
}

output "break_glass_role_arn" {
  description = "Break-glass admin role. Assumable only with MFA, 1h max session."
  value       = module.break_glass.iam_role_arn
}

output "db_broker_role_arn" {
  description = "DB broker role. Requires the external ID to assume."
  value       = module.db_broker.iam_role_arn
}

output "verify_boundary_blocks_iam" {
  description = "Command that proves the boundary denies IAM even to an admin-policy'd role."
  value       = <<-EOT
    # Assume break-glass, then try an IAM write. It must be denied by the boundary,
    # not by the role's own policy:
    aws iam create-user --user-name should-be-denied
    # Expected: AccessDenied with reason 'implicit deny in permissions boundary'
  EOT
}
