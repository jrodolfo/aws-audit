SHELL := /bin/bash

SCRIPT := ./aws-region-audit-report.sh
REPORTS_DIR := reports

.PHONY: help reports lint audit

help:
	@printf '%s\n' \
		'Available targets:' \
		'  make help     Show this help text' \
		'  make reports  Create the reports directory' \
		'  make lint     Check Bash syntax for the audit script' \
		'  make audit    Run the AWS regional audit report'

reports:
	@mkdir -p "$(REPORTS_DIR)"

lint:
	@bash -n "$(SCRIPT)"

audit: reports lint
	@"$(SCRIPT)"
