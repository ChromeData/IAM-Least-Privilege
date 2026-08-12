# Lab Notes — 06 IAM Least-Privilege

Running log. Errors, dead ends, fixes, surprises. Dated, newest at the bottom.

---

## Format

```
### YYYY-MM-DD — what I was trying to do

**Expected:**
**Got:**
**Cause:**
**Fix:**
```

---

## Finds and decisions

### Module argument name — caught by validate

Wrote `permissions_boundary_arn`; the iam-assumable-role module wants
`role_permissions_boundary_arn`. `terraform validate` failed with "argument not
expected here". Fixed both roles. This is exactly why every lab validates in CI —
the wrong name looks plausible and fails only at plan.

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
  boundary" — if it fails for a different reason, the boundary isn't doing the
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

_(first entry goes here on the first real apply)_
