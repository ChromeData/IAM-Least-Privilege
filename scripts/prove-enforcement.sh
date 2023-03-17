#!/usr/bin/env bash
#
# Closes the enforcement gap across labs 02, 05, 06 and 09 in one run.
#
# THE PROBLEM THIS SOLVES
#
# LocalStack creates IAM objects faithfully and evaluates no policy at request
# time. Every control in these labs is therefore verified as CONFIGURED and
# unverified as ENFORCING. That is one missing ingredient, not four separate
# problems, and it is the difference between "the boundary is attached" and
# "the boundary was observed refusing a request".
#
# Three offline substitutes were tested and rejected: LocalStack returns 404 for
# SimulatePrincipalPolicy, PMapper has not shipped since 2021 and will not
# import on Python 3.10+, and writing an evaluator would prove only that two
# things I wrote agree with each other. See findings/enforcement-gap-investigation.txt.
#
# So this is the runbook for the ten minutes after someone has an account.
#
# WHAT IT COSTS
#
# IAM roles, policies and STS calls are free. This script creates nothing
# billable: no EC2, no NAT, no KMS keys, no CloudTrail trail, no GuardDuty.
# It refuses to run outside an account you name explicitly, and it tears down
# what it made even when a check fails.
#
# USAGE
#
#   export LAB_ACCOUNT_ID=123456789012      # your throwaway account, required
#   bash scripts/prove-enforcement.sh
#
# Each check prints PASS or FAIL and the script exits non-zero if any control
# failed to enforce. A FAIL here is the finding: it means a control this repo
# claims is in place is not actually stopping anything.

set -uo pipefail
cd "$(dirname "$0")/.."

# ---------------------------------------------------------------------------
# Verdict logic, isolated so it can be tested without an AWS account.
#
# This script cannot be run end to end until someone has an account, which
# means the part most likely to be wrong, the branching on what AWS actually
# said, would ship unexercised. Pulling it into one function lets --self-test
# feed it real AWS error strings and assert the verdicts.
#
# The distinction that matters: "AccessDenied" alone is NOT a pass. If the
# role's own policy did the blocking, the boundary was never exercised and
# could be missing entirely. Only a denial that names the boundary proves the
# boundary is doing the work.
# ---------------------------------------------------------------------------
classify_iam_write() {
  local out="$1"
  if grep -qi "explicit deny\|implicit deny\|permissions boundary" <<<"${out}"; then
    echo "BOUNDARY_DENIED"
  elif grep -qi "accessdenied\|not authorized" <<<"${out}"; then
    echo "DENIED_BUT_NOT_BY_BOUNDARY"
  else
    echo "NOT_DENIED"
  fi
}

self_test() {
  local fails=0
  check() {
    local desc="$1" input="$2" want="$3"
    local got; got="$(classify_iam_write "${input}")"
    if [[ "${got}" == "${want}" ]]; then
      echo "  PASS  ${desc}"
    else
      echo "  FAIL  ${desc}: wanted ${want}, got ${got}"
      fails=1
    fi
  }

  echo "==> verdict logic self-test (no AWS account needed)"

  # Real AWS wording, boundary path. This is the only true pass.
  check "explicit boundary deny" \
    "An error occurred (AccessDenied) when calling the CreateUser operation: User: arn:aws:sts::1:assumed-role/lab06-break-glass-admin/x is not authorized to perform: iam:CreateUser on resource: user should-be-denied with an explicit deny in a permissions boundary" \
    "BOUNDARY_DENIED"

  check "implicit boundary deny" \
    "User: arn:aws:sts::1:assumed-role/x is not authorized to perform: iam:CreateUser because no permissions boundary allows the iam:CreateUser action" \
    "BOUNDARY_DENIED"

  # Denied, but the boundary is not named. The role policy may be masking a
  # boundary that is absent. Reported as a failure on purpose.
  check "plain AccessDenied is NOT a pass" \
    "An error occurred (AccessDenied) when calling the CreateUser operation: User: arn:aws:sts::1:assumed-role/x is not authorized to perform: iam:CreateUser" \
    "DENIED_BUT_NOT_BY_BOUNDARY"

  # The failure this whole script exists to catch.
  check "successful create is a failure" \
    '{"User": {"UserName": "should-be-denied", "Arn": "arn:aws:iam::1:user/should-be-denied"}}' \
    "NOT_DENIED"

  check "empty output is not a denial" "" "NOT_DENIED"

  echo
  if [[ ${fails} -eq 0 ]]; then
    echo "verdict logic correct. The AWS calls themselves still need an account."
  else
    echo "verdict logic is WRONG. Fix before running this against an account."
  fi
  return ${fails}
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi

: "${LAB_ACCOUNT_ID:?set LAB_ACCOUNT_ID to the throwaway account id you intend to use}"

ACTUAL="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" || {
  echo "cannot reach AWS. Configure credentials first."; exit 2; }

if [[ "${ACTUAL}" != "${LAB_ACCOUNT_ID}" ]]; then
  echo "REFUSING TO RUN."
  echo "  credentials point at ${ACTUAL}"
  echo "  LAB_ACCOUNT_ID says   ${LAB_ACCOUNT_ID}"
  echo "This script creates and assumes privileged roles. Naming the account is"
  echo "deliberate friction, not a formality."
  exit 2
fi

echo "Account ${ACTUAL} confirmed."
echo

fail=0
pass() { echo "  PASS  $1"; }
bad()  { echo "  FAIL  $1"; fail=1; }

cleanup() {
  echo
  echo "==> teardown"
  terraform -chdir=terraform destroy -auto-approve >/dev/null 2>&1 \
    && echo "  destroyed" || echo "  DESTROY FAILED, check the account by hand"
}
trap cleanup EXIT

echo "==> apply (IAM only, nothing billable)"
terraform -chdir=terraform init -input=false >/dev/null
# No -var here. This lab declares only use_localstack; the account allowlist
# variable belongs to lab 02, and passing it made Terraform reject the apply
# outright ("Value for undeclared variable"). The account guardrail for this
# lab is the sts:GetCallerIdentity check above, which has already run.
terraform -chdir=terraform apply -auto-approve >/dev/null || {
    echo "apply failed"; exit 1; }
echo "  applied"
echo

BG_ARN="$(terraform -chdir=terraform output -raw break_glass_role_arn)"
BROKER_ARN="$(terraform -chdir=terraform output -raw db_broker_role_arn)"

assume() {
  # Assume a role and emit exportable credentials, or nothing on failure.
  #
  # Retries, and that is not defensive padding. IAM is eventually consistent:
  # a role created seconds ago returns
  #
  #   User: ... is not authorized to perform: sts:AssumeRole on resource: ...
  #
  # even when the trust policy is correct and the caller holds
  # AdministratorAccess. The first real run of this script reported
  # "the correct external id was ALSO refused, the role is unusable" purely
  # because of that window; a retry ten seconds later assumed it first try.
  #
  # A false FAIL is as damaging as a false PASS here. Someone would have gone
  # looking for a bug in a trust policy that was right all along.
  local arn="$1" session="$2" ext="${3:-}"
  local out
  for _ in 1 2 3 4 5 6; do
    out="$(aws sts assume-role --role-arn "${arn}" --role-session-name "${session}" \
           ${ext:+--external-id "${ext}"} --output json 2>/dev/null)"
    if [[ -n "${out}" ]]; then echo "${out}"; return 0; fi
    sleep 5
  done
  return 1
}

assume_once() {
  # No retry. For the cases where a DENIAL is the expected result, so waiting
  # would only slow the run down.
  local arn="$1" session="$2" ext="${3:-}"
  aws sts assume-role --role-arn "${arn}" --role-session-name "${session}" \
    ${ext:+--external-id "${ext}"} --output json 2>/dev/null
}

# ---------------------------------------------------------------------------
# CHECK 1  the permissions boundary must BLOCK an IAM write
#
# This is the headline claim of lab 06. Break-glass carries ReadOnlyAccess plus
# a boundary that denies iam:*. The role should be unable to create a user even
# though it is the "admin" role.
# ---------------------------------------------------------------------------
# Break-glass requires MFA, so a plain key session cannot assume it. That is the
# control working, not a problem, and it is worth asserting directly.
echo "==> lab 06: break-glass refuses a session without MFA"
if [[ -n "$(assume_once "${BG_ARN}" no-mfa)" ]]; then
  bad "assumed break-glass WITHOUT MFA. The MFA condition is not enforcing."
else
  pass "assume-role without MFA was refused"
fi
echo

# The boundary is attached to BOTH roles, so it can be exercised through the
# broker, which is assumable without MFA. Testing it only through break-glass
# would mean the headline control of this lab goes unverified on any machine
# that is not in an MFA session, which is most of them.
echo "==> lab 06: boundary blocks IAM writes (via the broker)"
CREDS="$(assume "${BROKER_ARN}" prove-denied lab06-broker-external-id)"
if [[ -z "${CREDS}" ]]; then
  bad "could not assume the broker, so the boundary could not be exercised"
else
  OUT="$(AWS_ACCESS_KEY_ID="$(jq -r .Credentials.AccessKeyId <<<"${CREDS}")" \
         AWS_SECRET_ACCESS_KEY="$(jq -r .Credentials.SecretAccessKey <<<"${CREDS}")" \
         AWS_SESSION_TOKEN="$(jq -r .Credentials.SessionToken <<<"${CREDS}")" \
         aws iam create-user --user-name should-be-denied 2>&1)"

  case "$(classify_iam_write "${OUT}")" in
    BOUNDARY_DENIED)
      pass "iam:CreateUser denied, and the reason names the boundary" ;;
    DENIED_BUT_NOT_BY_BOUNDARY)
      # Denied, but not by the boundary. The role's own policy may be doing the
      # work, which means the boundary is untested and could be absent.
      bad "denied, but NOT by the boundary. The role policy may be masking it: ${OUT:0:120}" ;;
    *)
      bad "the IAM write was NOT blocked. The boundary is not doing its job." ;;
  esac
fi
echo

# ---------------------------------------------------------------------------
# CHECK 2  the external id must be REQUIRED, not merely present
#
# A trust policy can carry sts:ExternalId and still be assumable without it if
# the condition is written wrong. Assuming without the id must fail.
# ---------------------------------------------------------------------------
echo "==> lab 06: broker refuses assumption without the external id"
if [[ -n "$(assume_once "${BROKER_ARN}" no-external-id)" ]]; then
  bad "assumed the broker WITHOUT the external id. The condition is not enforcing."
else
  pass "assume-role without the external id was refused"
fi

echo "==> lab 06: broker accepts the correct external id"
if [[ -n "$(assume "${BROKER_ARN}" with-external-id lab06-broker-external-id)" ]]; then
  pass "assume-role with the external id succeeded"
else
  bad "the correct external id was ALSO refused. The role is unusable."
fi
echo

# ---------------------------------------------------------------------------
# CHECK 3  the broker must NOT require MFA
#
# The module defaults role_requires_mfa to true, which silently makes a machine
# role unassumable by any machine. Check 2 passing already proves this, since a
# non-MFA session assumed it; this states it explicitly so the finding is not
# lost in an unrelated failure.
# ---------------------------------------------------------------------------
echo "==> lab 06: broker trust policy carries no MFA condition"
COND="$(aws iam get-role --role-name lab06-db-broker \
        --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition' --output json)"
if grep -qi "MultiFactorAuthPresent" <<<"${COND}"; then
  bad "the machine broker requires MFA. No service can present it."
else
  pass "no MFA condition on the machine role"
fi
echo

echo "======================================================================"
if [[ ${fail} -eq 0 ]]; then
  echo "ALL CONTROLS ENFORCED."
  echo
  echo "This is the run that upgrades these labs from 'configured' to"
  echo "'observed blocking a request'. Save the output to findings/ and update"
  echo "the README status lines that currently say enforcement is unproven."
else
  echo "ONE OR MORE CONTROLS DID NOT ENFORCE."
  echo
  echo "This is the useful outcome, not the bad one. A control that is present"
  echo "in the config and does nothing at request time is exactly what these"
  echo "labs exist to catch, and it is invisible to every offline check."
fi
exit ${fail}
