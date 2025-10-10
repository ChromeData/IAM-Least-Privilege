# Lab Notes — IAM Least-Privilege & Broker Roles

> Running log, newest first.

## Known traps (pre-seeded)

### Permission boundary vs. policy — the confusing interaction

A role's effective permissions are the INTERSECTION of its policy and its boundary.
If the break-glass role "can't do X" despite an allow in its policy, the boundary is
denying it. That's the boundary working. Document the first time this surprises you.

### External ID must match exactly

`db-broker` requires `lab06-broker-external-id` on assume. A confused-deputy test —
assuming without it — should fail. Try it, confirm the failure, record it.

### Checkov will flag the wildcards in the boundary

`s3:*` in the boundary is intentional (it's a ceiling, not a grant), but Checkov
flags it. This is the right kind of finding to document as an accepted exception
with reasoning, rather than suppress silently.

## YYYY-MM-DD — <first real entry>

**Goal:** · **What happened:** · **Why:** · **Fix:** · **Time lost:**

## Open questions
- [ ] Does Access Analyzer catch the confused-deputy risk, or only static issues?
- [ ] How does a session policy scope-down interact with the boundary?
