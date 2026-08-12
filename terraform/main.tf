# Built on terraform-aws-modules/terraform-aws-iam (Anton Babenko).
# This is the lab's configuration; the module is upstream.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.60" }
  }
}

provider "aws" {
  default_tags {
    tags = { Purpose = "pam-cloud-lab", Lab = "06-iam-least-privilege" }
  }
}

data "aws_caller_identity" "current" {}

# Permission boundary: the hard ceiling. No role below can exceed this, even if its
# own policy is broader. This is the IAM equivalent of a vault's outer control.
resource "aws_iam_policy" "boundary" {
  name = "lab06-permission-boundary"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowedServices"
        Effect   = "Allow"
        Action   = ["s3:*", "ec2:Describe*", "rds:Describe*", "secretsmanager:GetSecretValue"]
        Resource = "*"
      },
      {
        Sid      = "DenyIamEscalation"
        Effect   = "Deny"
        Action   = ["iam:*", "organizations:*", "account:*"]
        Resource = "*"
      },
    ]
  })
}

# Break-glass admin: assumable only with MFA, capped session, boundary applied.
module "break_glass" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role"
  version = "~> 5.0"

  create_role           = true
  role_name             = "lab06-break-glass-admin"
  role_requires_mfa     = true
  max_session_duration  = 3600            # 1h, not the 12h default
  permissions_boundary_arn = aws_iam_policy.boundary.arn

  trusted_role_arns = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]

  custom_role_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
  # Deliberately ReadOnly + boundary: prove that even "admin" break-glass starts
  # minimal and is scoped up only when a real incident requires it.
}

# DB broker: brokered access with an external ID, no standing credentials.
module "db_broker" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role"
  version = "~> 5.0"

  create_role          = true
  role_name            = "lab06-db-broker"
  role_sts_externalid  = ["lab06-broker-external-id"]   # shared-secret gate
  max_session_duration = 3600
  permissions_boundary_arn = aws_iam_policy.boundary.arn

  trusted_role_arns = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
  custom_role_policy_arns = []
}
