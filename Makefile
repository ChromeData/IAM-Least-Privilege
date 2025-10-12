.PHONY: help init plan apply analyze checkov destroy
.DEFAULT_GOAL := help
TF := terraform -chdir=terraform

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

init: ## terraform init
	$(TF) init -upgrade

plan: ## terraform plan
	$(TF) plan

apply: ## terraform apply
	$(TF) apply

localstack: ## Apply against LocalStack, no AWS account, no cost
	@# Creates every object faithfully and enforces NOTHING. Proves the
	@# configuration applies and the controls are present; cannot prove the
	@# boundary blocks anything. See findings/enforcement-gap-investigation.txt
	docker run -d --name localstack -p 4566:4566 -e SERVICES=iam,sts,kms localstack/localstack:3 || true
	@until curl -s http://localhost:4566/_localstack/health | grep -q '"iam": "available"'; do sleep 3; done
	cd terraform && AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_REGION=us-east-1 terraform apply -auto-approve -var use_localstack=true

verify-config: ## Read every control back from the IAM API (works on LocalStack)
	@echo "break-glass boundary:"
	@aws iam get-role --role-name lab06-break-glass-admin --query 'Role.PermissionsBoundary.PermissionsBoundaryArn' --output text
	@echo "break-glass max session (AWS default is 43200):"
	@aws iam get-role --role-name lab06-break-glass-admin --query 'Role.MaxSessionDuration' --output text
	@echo "db-broker trust condition (external id, and NO MFA, it is a machine role):"
	@aws iam get-role --role-name lab06-db-broker --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition' --output json

prove-denied: ## [REAL AWS ONLY] Prove the boundary actually BLOCKS an IAM write
	@# This is the one thing LocalStack cannot do. It creates IAM objects but
	@# runs no authorization engine, so it will never refuse a call. Three
	@# offline alternatives were tested and all failed; the reasoning is in
	@# findings/enforcement-gap-investigation.txt.
	@#
	@# Configuration correctness is verified. Enforcement is not, until this runs.
	@echo "Assuming break-glass, then attempting an IAM write."
	@echo "SUCCESS means AccessDenied citing the permissions boundary."
	aws sts assume-role --role-arn $$(cd terraform && terraform output -raw break_glass_role_arn) --role-session-name prove-denied > /tmp/bg.json
	@AWS_ACCESS_KEY_ID=$$(jq -r .Credentials.AccessKeyId /tmp/bg.json) AWS_SECRET_ACCESS_KEY=$$(jq -r .Credentials.SecretAccessKey /tmp/bg.json) AWS_SESSION_TOKEN=$$(jq -r .Credentials.SessionToken /tmp/bg.json) aws iam create-user --user-name should-be-denied 2>&1 | tee /tmp/denied.txt; grep -qi "accessdenied\|permissions boundary" /tmp/denied.txt && echo "PASS: the boundary blocked it" || { echo "FAIL: the IAM write was NOT blocked"; exit 1; }

analyze: ## IAM Access Analyzer policy validation on the boundary policy
	@echo "Validating the permission-boundary document with access-analyzer..."
	@$(TF) show -json > /tmp/lab06-state.json
	@python3 -c "import json; s=json.load(open('/tmp/lab06-state.json')); \
[open('/tmp/lab06-%d.json'%i,'w').write(r['values']['policy']) \
 for i,r in enumerate(s.get('values',{}).get('root_module',{}).get('resources',[])) \
 if r.get('type')=='aws_iam_policy']" 2>/dev/null || echo "(apply first)"
	@for f in /tmp/lab06-*.json; do \
		[ -f "$$f" ] || continue; \
		aws accessanalyzer validate-policy --policy-type IDENTITY_POLICY \
			--policy-document "file://$$f" \
			--query 'findings[].{type:findingType,issue:issueCode}' --output table || true; \
	done

checkov: ## Checkov scan of the Terraform
	checkov -d terraform --compact --output cli | tee docs/checkov-report.txt

destroy: ## terraform destroy
	$(TF) destroy
