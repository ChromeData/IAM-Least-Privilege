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
