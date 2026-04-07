SHELL := /bin/bash

SCRIPT := ./aws-region-audit-report.sh
S3_CLOUDWATCH_SCRIPT := ./aws-s3-cloudwatch-report.sh
REPORTS_DIR := reports
REGIONS ?=
SERVICES ?=
BUCKET ?=
REGION ?=
DAYS ?=

.PHONY: help reports lint test audit s3-cloudwatch

help:
	@printf '%s\n' \
		'Available targets:' \
		'  make help     Show this help text' \
		'  make reports  Create the reports directory' \
		'  make lint     Check Bash syntax for the shell scripts' \
		'  make test     Run local shell tests without AWS access' \
		'  make audit    Run the AWS regional audit report' \
		'                Optional: make audit REGIONS="us-east-2"' \
		'                Optional: make audit SERVICES="sagemaker ec2"' \
		'  make s3-cloudwatch BUCKET=example.com' \
		'                Optional: make s3-cloudwatch BUCKET=example.com REGION=us-east-2' \
		'                Optional: make s3-cloudwatch BUCKET=example.com DAYS=30'

reports:
	@mkdir -p "$(REPORTS_DIR)"

lint:
	@bash -n "$(SCRIPT)"
	@bash -n "$(S3_CLOUDWATCH_SCRIPT)"

test:
	@bash ./tests/test.sh
	@bash ./tests/test-s3-cloudwatch.sh

audit: reports lint
	@"$(SCRIPT)" \
		$(if $(strip $(REGIONS)),--regions $(REGIONS),) \
		$(if $(strip $(SERVICES)),--services $(SERVICES),)

s3-cloudwatch: reports lint
	@if [ -z "$(strip $(BUCKET))" ]; then \
		printf '%s\n' 'Error: BUCKET is required. Example: make s3-cloudwatch BUCKET=example.com' >&2; \
		exit 1; \
	fi
	@"$(S3_CLOUDWATCH_SCRIPT)" \
		--bucket "$(BUCKET)" \
		$(if $(strip $(REGION)),--region $(REGION),) \
		$(if $(strip $(DAYS)),--days $(DAYS),)
