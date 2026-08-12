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
