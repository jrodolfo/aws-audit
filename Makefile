SHELL := /bin/bash

SCRIPT := ./aws-region-audit-report.sh
REPORTS_DIR := reports
REGIONS ?=
SERVICES ?=

.PHONY: help reports lint test audit

help:
	@printf '%s\n' \
		'Available targets:' \
		'  make help     Show this help text' \
		'  make reports  Create the reports directory' \
		'  make lint     Check Bash syntax for the audit script' \
		'  make test     Run local shell tests without AWS access' \
		'  make audit    Run the AWS regional audit report' \
		'                Optional: make audit REGIONS="us-east-2"' \
		'                Optional: make audit SERVICES="sagemaker ec2"'

reports:
	@mkdir -p "$(REPORTS_DIR)"

lint:
	@bash -n "$(SCRIPT)"

test:
	@bash ./tests/test.sh

audit: reports lint
	@"$(SCRIPT)" \
		$(if $(strip $(REGIONS)),--regions $(REGIONS),) \
		$(if $(strip $(SERVICES)),--services $(SERVICES),)
