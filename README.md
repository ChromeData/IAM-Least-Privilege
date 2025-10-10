# Lab 06 — IAM Least-Privilege & Break-Glass Broker Roles

**Build a set of assumable IAM roles with MFA, external-id, and permission-boundary
conditions — the AWS-native expression of privileged-session brokering — then prove
they're minimal with IAM Access Analyzer and Checkov.**

| | |
|---|---|
| **Domains** | CyberArk/Idira · AWS |
| **Built on** | [terraform-aws-modules/terraform-aws-iam](https://github.com/terraform-aws-modules/terraform-aws-iam) (Apache-2.0, by Anton Babenko / terraform-aws-modules) |
| **Runtime** | ~4 hours · < $1 |
| **Status** | 🟡 In progress |

---

## Why this lab exists

A CyberArk engineer thinks in broker roles and break-glass by default. AWS IAM can
express the same model — assumable roles gated by MFA and external ID, permission
boundaries as a hard ceiling, session policies for scope-down — but most people
build flat, over-permissive roles and never verify. This lab builds the roles the
way a PAM person would, then **proves** they're least-privilege with two independent
tools rather than asserting it.

## What I built

- **Broker roles** via the `iam-assumable-role` and `iam-assumable-role-with-oidc`
  submodules: MFA required, external ID enforced, session duration capped.
- A **permission boundary** applied to every human-adjacent role, so even a
  mis-scoped policy can't exceed the ceiling.
- An **IRSA role** (`iam-role-for-service-accounts`) to demonstrate credential-less
  workload identity vs. long-lived keys — the thing PAM exists to eliminate.
- **Verification:** IAM Access Analyzer policy validation + Checkov, with every
  finding either fixed or documented as an accepted exception.

## What I did not build

The IAM module is Anton Babenko's / the terraform-aws-modules org's. My work is the
role design, the boundary and condition logic, and the verification harness.

---

## Running it

```bash
make init
make plan
make apply
make analyze     # IAM Access Analyzer validation on the generated policies
make checkov     # Checkov scan, output to docs/checkov-report.txt
make destroy
```

## The deliverable

`docs/least-privilege-report.md` — for each role: what it can do, why each
permission is needed, what Access Analyzer/Checkov flagged, and how you resolved it.

| Role | Purpose (PAM framing) | Findings | Resolution |
|------|----------------------|----------|------------|
| break-glass-admin | Emergency access, MFA + boundary | | |
| db-broker | Brokered DB access, no standing creds | | |
| irsa-app | Workload identity, no keys | | |

## What broke

See [LAB-NOTES.md](./LAB-NOTES.md).
