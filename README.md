# Lab 06: IAM Least Privilege and Break Glass Broker Roles

<p align="center"><img src="assets/enforcement-proven.svg" alt="Boundary observed enforcing on real AWS" width="720"></p>


[![tests](https://github.com/ChromeData/IAM-Least-Privilege/actions/workflows/tests.yml/badge.svg)](https://github.com/ChromeData/IAM-Least-Privilege/actions/workflows/tests.yml)

**AWS roles built the way a PAM engineer thinks: a hard ceiling nothing can exceed, admin access that is read only until an incident, and a broker role with no standing credentials. Then proven minimal by two separate tools.**

| | |
|---|---|
| **Domains** | CyberArk/Idira, AWS |
| **Built on** | [terraform-aws-modules/iam](https://github.com/terraform-aws-modules/terraform-aws-iam) (Anton Babenko) |
| **Cost** | `$0` — IAM and STS only, nothing billable |
| **Status** | Enforcement PROVEN against real AWS: the boundary was observed denying iam:CreateUser and naming itself in the denial (findings/enforcement-proven-real-aws.txt). MFA and external-id conditions verified enforcing |

## Situation

A CyberArk engineer thinks in broker roles and break glass by default. AWS can express the same model, but most people build flat, over permissive roles and never verify.

## Task

Build the roles the PAM way, then prove they are minimal instead of claiming it.

## Action

Three pieces:

**The permission boundary, the ceiling.** No role beneath it can go past it, even if its own policy is broader. It allows a short list of services and flatly denies IAM, Organizations, and account actions, which is the escalation surface. This is the AWS version of a vault's outer control.

**Break glass admin, minimal until it is not.** Assumable only with MFA, one hour max session (not the twelve hour default), boundary applied. It starts with read only access. The point is that even admin break glass begins minimal and is raised only when a real incident needs it.

**DB broker, no standing credentials.** Assumable only with an external ID (a shared secret gate), one hour session, boundary applied. Access is brokered per use, never held.

## Result

**The controls were observed enforcing on real AWS**, not just configured. Assuming the broker and attempting an IAM write returned:

```
AccessDenied ... not authorized to perform: iam:CreateUser ... with an explicit
deny in a permissions boundary: arn:aws:iam::<ACCOUNT>:policy/lab06-permission-boundary
```

AWS names the boundary policy by ARN. That is the distinction the whole model is built around: not "the call was denied," but "denied **by the boundary**" — the ceiling holding regardless of what a role's own policy grants. All five checks passed: boundary denial, MFA required on break-glass, external ID required *and* accepted on the broker. Cost `$0`, IAM and STS only, torn down after. Full output in [findings/enforcement-proven-real-aws.txt](./findings/enforcement-proven-real-aws.txt).

To prove that rather than assume it, I wrote [`scripts/prove-enforcement.sh`](./scripts/prove-enforcement.sh) — a runbook that applies the model, exercises each control against live AWS, and tears down even if a check fails. Its verdict logic is unit-tested so a bare `AccessDenied` counts as a *failure*, not a pass: if the role's own policy did the blocking, the boundary was never exercised. Checkov and Access Analyzer guard the config in CI alongside it.

<sub>Building it this rigorously is what caught three bugs no static check would: a module default (`role_requires_mfa: true`) that quietly made the machine broker unassumable by any machine, an eventual-consistency race that made the runbook itself report a false failure, and a mistyped module argument that left the boundary silently unattached. Each is written up in [LAB-NOTES.md](./LAB-NOTES.md) — supporting evidence that the model is real, not the headline.</sub>

Two tools guard it in CI. Checkov fails the build on real findings, with two intentional boundary skips that each carry a written reason. The enforcement verdict logic is unit-tested (a bare `AccessDenied` is treated as a *failure*, since it does not prove the boundary did the work).

## What I did not build

The role module is Anton Babenko's. The boundary design, the break glass and broker models, the Checkov config, and the verification are mine.

## Run it

```bash
terraform -chdir=terraform init
terraform -chdir=terraform apply
checkov --config-file .checkov.yaml     # least privilege proof
terraform -chdir=terraform destroy
```

Needs Terraform 1.9+ and Python 3.

## Findings

[`findings/`](./findings/) holds the real run output, including the verbatim boundary denial from real AWS. [LAB-NOTES.md](./LAB-NOTES.md) is the running log of what broke and why.

## License

Lab code: MIT ([LICENSE](./LICENSE)). Upstream module stays Apache 2.0, credited above.
