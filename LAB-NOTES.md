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

### 2026-08-12, wrote the runbook for the ten minutes after someone has an account

The enforcement gap is not four problems, it is one missing ingredient shared by
labs 02, 05, 06 and 09. So rather than leave four READMEs each saying "needs a
real account", `scripts/prove-enforcement.sh` closes all of it in one run.

Four checks, all of which are invisible to every offline tool:

1. the boundary **blocks** `iam:CreateUser`, and the denial names the boundary.
   A plain AccessDenied is reported as a FAILURE, not a pass: if the role's own
   policy is doing the work, the boundary is untested and could be absent
   entirely.
2. the broker **refuses** assumption without the external id. A trust policy can
   carry `sts:ExternalId` and still be assumable without it if the condition is
   written wrong.
3. the broker **accepts** the correct external id, because a control that denies
   everything is not a working control.
4. the broker carries **no MFA condition**, the module default that would make a
   machine role unassumable by any machine.

Cost is zero: IAM roles, policies and STS calls only. No EC2, no KMS, no trail.

Three guards, and I tested each rather than trusting them:

```
no LAB_ACCOUNT_ID        -> exit 1
cannot reach AWS         -> exit 2
credentials point at a
  different account      -> exit 2, refuses before touching anything
```

Teardown is on a trap, so it runs even when a check fails. That matters more
than it sounds: the run most likely to leave privileged roles lying around is
the one that errored halfway.

A FAIL from this script is the useful outcome, not the bad one. A control that
is present in the config and does nothing at request time is exactly what these
labs exist to find, and it is precisely what no offline check can see.

---

### 2026-08-12, testing the runbook I cannot run

`prove-enforcement.sh` needs an AWS account, so the part most likely to be
wrong, the branching on what AWS actually said, would have shipped completely
unexercised. Writing a check I have never seen execute is the same mistake as
trusting a green I have never seen fail.

Pulled the verdict logic into `classify_iam_write()` and added `--self-test`,
which feeds it real AWS error wording:

```
PASS  explicit boundary deny
PASS  implicit boundary deny
PASS  plain AccessDenied is NOT a pass
PASS  successful create is a failure
PASS  empty output is not a denial
```

The third case is the one that matters. A bare `AccessDenied` is treated as a
**failure**, not a pass: if the role's own policy did the blocking, the boundary
was never exercised and could be absent entirely. A check that accepts any
denial would report success on a lab with no boundary at all.

Runs in CI. What is still untested is the AWS calls themselves, and that stays
true until someone runs it against an account.

---

### 2026-08-12, the boundary was observed blocking a request

Ran `prove-enforcement.sh` against a real throwaway account. Cost: nothing, IAM
and STS only.

```
break-glass refuses a session without MFA          PASS
boundary blocks IAM writes (via the broker)        PASS
broker refuses assumption without the external id  PASS
broker accepts the correct external id             PASS
broker trust policy carries no MFA condition       PASS

ALL CONTROLS ENFORCED.
```

The evidence, verbatim:

```
An error occurred (AccessDenied) when calling the CreateUser operation:
User: arn:aws:sts::<ACCOUNT>:assumed-role/lab06-db-broker/evidence is not
authorized to perform: iam:CreateUser on resource:
arn:aws:iam::<ACCOUNT>:user/should-be-denied with an explicit deny in a
permissions boundary: arn:aws:iam::<ACCOUNT>:policy/lab06-permission-boundary
```

AWS names the boundary policy by ARN. That is the whole distinction: not "the
call was denied" but "the call was denied **by the boundary**". A denial from
the role's own policy would read almost identically and prove nothing about the
ceiling, which is why the script treats a bare `AccessDenied` as a failure.

**Two bugs, both mine, both only findable by running it.**

**IAM is eventually consistent.** The first run reported `the correct external
id was ALSO refused. The role is unusable.` The trust policy was correct, the
caller held AdministratorAccess, and the role was four seconds old. A retry ten
seconds later assumed it first try. A false FAIL is as damaging as a false PASS:
someone would have spent an afternoon debugging a trust policy that was right
the whole time. `assume()` now retries, and the checks that *expect* a denial
use `assume_once()` so a legitimate refusal is not slowed by pointless waiting.

**The boundary was only testable from an MFA session.** The script exercised it
through break-glass, which requires MFA, so from an ordinary key session the
headline control of this lab could not be verified at all. It now runs through
the broker, which is assumable without MFA and carries the same boundary.
Break-glass keeps its own check, and it is a better one: assuming it *without*
MFA must be refused, which asserts the condition instead of working around it.

Teardown confirmed clean: 4 resources destroyed, no lab06 roles, policies, or
leftover `should-be-denied` user.

Full output in `findings/enforcement-proven-real-aws.txt`. Labs 02, 05 and 09
share this class of claim and have not been run this way yet.

---
