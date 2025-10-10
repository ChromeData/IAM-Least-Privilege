# Lab 06 — IAM Least-Privilege & Break-Glass Broker Roles

[![tests](https://github.com/ChromeData/IAM-Least-Privilege/actions/workflows/tests.yml/badge.svg)](https://github.com/ChromeData/IAM-Least-Privilege/actions/workflows/tests.yml)

**AWS roles built the way a PAM engineer thinks: a hard ceiling nothing can
exceed, admin access that's read-only until an incident, and a broker role with
no standing credentials. Then proven minimal by two independent tools.**

| | |
|---|---|
| **Domains** | CyberArk/Idira · AWS |
| **Built on** | [terraform-aws-modules/iam](https://github.com/terraform-aws-modules/terraform-aws-iam) (Apache-2.0, Anton Babenko) |
| **Cost** | < $1 (IAM objects are free) · **Runtime** ~4 hours |
| **Status** | 🟡 Built, validated, not yet applied |

---

## The point

A CyberArk engineer thinks in broker roles and break-glass by default. AWS IAM can
express the same model — but most people build flat, over-permissive roles and
never verify. This builds them the PAM way, then **proves** least-privilege with
two tools instead of claiming it.

## The three pieces

**The permission boundary — the ceiling.** No role beneath it can exceed it, even
if its own policy is broader. It allows a short list of services and *explicitly
denies* `iam:*`, `organizations:*`, `account:*` — the escalation surface. This is
the IAM equivalent of a vault's outer control.

**Break-glass admin — minimal until it isn't.** Assumable only with MFA, 1-hour
max session (not the 12-hour default), boundary applied. Starts with
**ReadOnlyAccess** — the point being that even "admin" break-glass begins minimal
and is scoped up only when a real incident requires it.

**DB broker — no standing credentials.** Assumable only with an external ID (a
shared-secret gate), 1-hour session, boundary applied. Access is brokered per-use,
never held.

## Proven, not asserted

Two independent tools, both in CI:

- **Checkov** scans the Terraform. [`.checkov.yaml`](./.checkov.yaml) fails the
  build on a real finding. Two checks are skipped — both on the boundary's
  intentional top-level allow — and **each skip carries its reason**, because a
  skip without justification is how "we scan our IaC" becomes "we ignore our
  scanner."
- **IAM Access Analyzer** validates the deployed policies (the
  `verify_boundary_blocks_iam` output shows the manual proof: assume break-glass,
  try an IAM write, watch the *boundary* deny it).

Building it caught a real bug: the module argument is
`role_permissions_boundary_arn`, not `permissions_boundary_arn`. `terraform
validate` flagged it. Left in the history because "it validates in CI" is the
claim, and this is what backs it.

## What I didn't build

The assumable-role module is Anton Babenko's. The boundary design, the
break-glass and broker models, the Checkov policy, and the verification are mine.

---

## Running it

```bash
terraform -chdir=terraform init
terraform -chdir=terraform apply
checkov --config-file .checkov.yaml     # least-privilege proof
terraform -chdir=terraform destroy
```

Needs Terraform ≥ 1.9 and (for the Checkov step) Python 3.

## Findings

`findings/` fills in on the first apply + Access Analyzer run.
[LAB-NOTES.md](./LAB-NOTES.md) is the log.

## License

Lab code: MIT ([LICENSE](./LICENSE)). Upstream module stays Apache-2.0, credited
above.
