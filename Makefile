# LZA Config Validator - local dev checks (mirror .github/workflows/ci.yml)
#
# Usage:
#   make lint      # run all checks
#   make cfn-lint  # CloudFormation lint
#   make yaml      # yamllint
#   make shell     # shellcheck + bash syntax
#   make cfn-nag   # security scan (requires Ruby >= 2.7 + cfn-nag gem)

TEMPLATE := lza-config-validator.yaml
SCRIPTS  := scripts/*.sh

.PHONY: lint cfn-lint yaml shell cfn-nag

lint: cfn-lint yaml shell

cfn-lint:
	@echo "==> cfn-lint"
	cfn-lint $(TEMPLATE)

yaml:
	@echo "==> yamllint"
	yamllint -c .yamllint.yml example-config/ buildspec.yml $(TEMPLATE)

shell:
	@echo "==> shellcheck + bash -n"
	shellcheck $(SCRIPTS)
	@for f in $(SCRIPTS); do bash -n "$$f"; done

cfn-nag:
	@echo "==> cfn_nag_scan"
	cfn_nag_scan --input-path $(TEMPLATE)
