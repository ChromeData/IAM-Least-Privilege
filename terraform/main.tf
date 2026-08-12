# Built on terraform-aws-modules/terraform-aws-iam (Anton Babenko).
# This is the lab's configuration; the module is upstream.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.60" }
  }
}

variable "use_localstack" {
  description = <<-EOT
    Point the provider at a local LocalStack endpoint instead of real AWS.

    LocalStack creates the IAM objects faithfully, so this proves the
    configuration applies cleanly at zero cost. It does NOT evaluate policy at
    request time, so the boundary-denies-IAM test still has to run against real
    AWS to mean anything. See localstack.tfvars.example.
  EOT
  type        = bool
  default     = false
}

provider "aws" {
  default_tags {
    tags = { Purpose = "pam-cloud-lab", Lab = "06-iam-least-privilege" }
  }

  # LocalStack only. Skips the credential and account checks the provider
  # normally performs, and routes every call to the local endpoint.
  skip_credentials_validation = var.use_localstack
  skip_requesting_account_id  = var.use_localstack
  skip_metadata_api_check     = var.use_localstack

  dynamic "endpoints" {
    for_each = var.use_localstack ? [1] : []
    content {
      iam = "http://localhost:4566"
      sts = "http://localhost:4566"
      kms = "http://localhost:4566"
    }
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

  create_role                   = true
  role_name                     = "lab06-break-glass-admin"
  role_requires_mfa             = true
  max_session_duration          = 3600 # 1h, not the 12h default
  role_permissions_boundary_arn = aws_iam_policy.boundary.arn

  trusted_role_arns = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]

  custom_role_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
  # Deliberately ReadOnly + boundary: prove that even "admin" break-glass starts
  # minimal and is scoped up only when a real incident requires it.
}

# DB broker: brokered access with an external ID, no standing credentials.
module "db_broker" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role"
  version = "~> 5.0"

  create_role         = true
  role_name           = "lab06-db-broker"
  role_sts_externalid = ["lab06-broker-external-id"] # shared-secret gate

  # Explicitly false, and this is not a relaxation.
  #
  # The module defaults role_requires_mfa to TRUE. Reading the deployed trust
  # policy back from the IAM API showed an aws:MultiFactorAuthPresent condition
  # that this configuration never asked for.
  #
  # Break-glass is assumed by a human, so MFA belongs there. The broker is
  # assumed by a service, and a service cannot present MFA, so that condition
  # does not harden the role: it makes the role unassumable by the only thing
  # meant to assume it. The correct gate for a machine role is the external id,
  # which is set above.
  #
  # Found by inspecting the deployed object rather than trusting the config.
  # See findings/localstack-apply-run.txt.
  role_requires_mfa = false

  max_session_duration          = 3600
  role_permissions_boundary_arn = aws_iam_policy.boundary.arn

  trusted_role_arns       = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
  custom_role_policy_arns = []
}
