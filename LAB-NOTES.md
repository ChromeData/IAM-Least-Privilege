# Lab Notes, 06 IAM Least-Privilege

Running log. Errors, dead ends, fixes, surprises. Dated, newest at the bottom.

---

## Format

```
### YYYY-MM-DD, what I was trying to do

**Expected:**
**Got:**
**Cause:**
**Fix:**
```

---

## Finds and decisions

### Module argument name, caught by validate

Wrote `permissions_boundary_arn`; the iam-assumable-role module wants
`role_permissions_boundary_arn`. `terraform validate` failed with "argument not
expected here". Fixed both roles. This is exactly why every lab validates in CI. The wrong name looks plausible and fails only at plan.

### The boundary is a ceiling, not a grant

Easy to misread the top-level `Allow s3:* / secretsmanager:GetSecretValue` as
"these roles can do all that." They can't. The boundary caps what a role's own
policy is *allowed* to grant. Break-glass ships with ReadOnlyAccess, so despite
the boundary permitting s3:*, the role can only read. The two must intersect.

### Checkov skips are justified inline

CKV_AWS_289/290 flag the boundary's wildcards. Skipped with reasons in
`.checkov.yaml`. Anything below the boundary that trips a check is a real finding,
not a skip.

---

## Known traps (confirm on apply)

- **Prove the boundary, don't assume it.** Assume break-glass and run
  `aws iam create-user`. It must fail with "implicit deny in permissions
  boundary", if it fails for a different reason, the boundary isn't doing the
  work you think it is.
- **External ID on the broker.** Confirm assuming `lab06-db-broker` WITHOUT the
  external ID is denied. That's the whole control.
- **MFA on break-glass.** Confirm assume-role without MFA is refused.

---

## Open questions

- [ ] Does Access Analyzer flag anything on the deployed policies?
- [ ] Does the boundary deny reach IAM before the role's ReadOnly allow? (Order.)
- [ ] Screenshot the boundary-denied create-user for findings/.

---

## Log

### 2026-08-11, first validate on the broker roles

**Expected:** clean validate. The argument name looked obviously right.

**Got:**

```
Error: Unsupported argument
  51:   permissions_boundary_arn = aws_iam_policy.boundary.arn
An argument named "permissions_boundary_arn" is not expected here.
```

**Cause:** The `iam-assumable-role` module calls it `role_permissions_boundary_arn`.
I'd written the name the AWS API uses, not the name the module uses.

**Fix:** Renamed on both roles.

**Why this one matters:** without the boundary attached, both roles still create fine
and look correct in the console. The ceiling just isn't there. This is a silent
failure that only shows up the day someone tests whether break-glass can actually
reach IAM. It's the reason every lab in this set runs `validate` in CI rather than
trusting a read-through.

---

### 2026-08-12, first real apply, and the broker was quietly broken

Ran the configuration against LocalStack, which implements the real IAM API
locally. No AWS account, no cost, and a genuine `terraform apply`.

```
Apply complete! Resources: 4 added, 0 changed, 0 destroyed.
```

Then read every control back **from the API rather than from the config**,
which is the only reason I found this:

```
db-broker trust policy condition:
{
  "Bool":            { "aws:MultiFactorAuthPresent": "true" },
  "NumericLessThan": { "aws:MultiFactorAuthAge": "86400" },
  "StringEquals":    { "sts:ExternalId": "lab06-broker-external-id" }
}
```

The external id is there as intended. The **MFA condition is not** anything this
configuration asked for. `terraform-aws-modules/iam` defaults
`role_requires_mfa` to `true`.

**Why that is a real bug and not a harmless extra control.** Break-glass is
assumed by a human, so MFA belongs on it and is set deliberately. The broker is
assumed by a *service*. A service cannot present MFA. So the condition does not
harden the broker, it makes it unassumable by the only thing that is supposed to
assume it. The role deploys, looks correct in the console, passes
`terraform validate`, passes Checkov, and fails the first time anything tries to
use it.

Set `role_requires_mfa = false` explicitly, re-applied, and confirmed:

```
db-broker trust policy condition:
{ "StringEquals": { "sts:ExternalId": "lab06-broker-external-id" } }
```

**The lesson worth keeping:** a module default can add a control you never asked
for, and "extra security control" is not automatically safe. The config was
clean at every layer I had been checking. It only surfaced by inspecting the
deployed object.

Also confirmed working as intended: boundary attached to both roles, 3600 second
session cap against the 43200 default, and the boundary explicitly denying
`iam:*`, `organizations:*` and `account:*`.

**What this run does not prove:** enforcement. LocalStack creates IAM objects
faithfully but does not evaluate policy at request time, so it will not refuse a
call the boundary should block. `prove-denied` still needs real AWS. Full output
in `findings/localstack-apply-run.txt`.

---

### 2026-08-12, Checkov failing CI on the boundary

**Expected:** green, since I'd already skipped CKV_AWS_289/290 for the boundary's
intentional wildcards.

**Got:** 4 failures: `CKV_AWS_288`, `CKV_AWS_355`, and `CKV_TF_1` twice.

**Cause:** Two more checks flag the same intentional boundary wildcards from different
angles (data exfiltration, resource wildcard on write). `CKV_TF_1` is different: it
wants module sources pinned to a git commit hash, which isn't even valid syntax for a
Terraform Registry source pinned to `~> 5.0`.

**Fix:** Added all four to `.checkov.yaml`, each with its reason written next to it.
Local re-run: `Passed checks: 8, Failed checks: 0`.

**Rule I'm keeping:** a skip without a written justification is how "we scan our IaC"
turns into "we ignore our scanner." Every skip in that file says why.

### 2026-08-12, tried three ways to prove the boundary denies, without an account

LocalStack builds the objects and enforces nothing, so `prove-denied` had
nothing to run against. Three options, all dead ends, recorded so the next
person does not repeat them:

1. **`iam:SimulatePrincipalPolicy` via LocalStack.** Would have been the clean
   answer, since it is AWS's own evaluation logic exposed as an API call.
   LocalStack community returns 404. Tested against a role carrying an explicit
   `Deny` on `iam:*`, exactly the shape this lab needs.

2. **PMapper's offline authorization simulation.** Closest thing that exists.
   Dies on import: `cannot import name 'Mapping' from 'collections'`, removed in
   Python 3.10. PyPI's newest is 1.1.5 and nothing newer exists, so this is not
   a version-pin problem; the project has not shipped since 2021. It is a
   one-line shim and I did not apply it: citing a patched unmaintained library
   as evidence about IAM semantics is worse than admitting I have none. The
   patch fixes the import, not four years of untracked IAM behaviour.

3. **Write the evaluator.** No. Reimplementing AWS's evaluation and then using
   it to prove my own policy correct demonstrates only that two things I wrote
   agree. Every real subtlety lives exactly where a reimplementation goes wrong:
   boundary intersection, `NotAction`, condition-key ordering, resource-policy
   interaction. It would be the most confident wrong answer in the repo.

So: configuration verified, enforcement not, and `prove-denied` is now an
explicit `[REAL AWS ONLY]` make target rather than an aspiration in a Terraform
output string. Also added `make localstack` and `make verify-config` so the part
that *can* be checked locally is one command.

One free-tier account closes this, and it closes the identical gap in labs 02,
05 and 09 at the same time. They are one missing piece, not four problems.

Detail in `findings/enforcement-gap-investigation.txt`.

---
