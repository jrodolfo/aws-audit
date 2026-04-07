#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="$ROOT_DIR/aws-region-audit-report.sh"
MOCK_AWS="$ROOT_DIR/tests/mock-aws.sh"
JQ_BIN="${JQ_BIN:-jq}"

assert_file_exists() {
  if [ ! -f "$1" ]; then
    printf 'missing expected file: %s\n' "$1" >&2
    exit 1
  fi
}

assert_dir_exists() {
  if [ ! -d "$1" ]; then
    printf 'missing expected directory: %s\n' "$1" >&2
    exit 1
  fi
}

assert_eq() {
  if [ "$1" != "$2" ]; then
    printf 'assertion failed: expected [%s], got [%s]\n' "$1" "$2" >&2
    exit 1
  fi
}

assert_file_contains() {
  if ! grep -Fq -- "$2" "$1"; then
    printf 'expected file [%s] to contain [%s]\n' "$1" "$2" >&2
    exit 1
  fi
}

run_audit() {
  local reports_dir="$1"
  shift
  REPORTS_DIR="$reports_dir" \
  TIMESTAMP_OVERRIDE="2026-04-06_00-00-00" \
  AWS_BIN="$MOCK_AWS" \
  "$SCRIPT_PATH" "$@" >/dev/null
}

test_default_run_creates_outputs() {
  local tmp_dir reports_dir outdir

  tmp_dir="$(mktemp -d)"
  reports_dir="$tmp_dir/reports"

  run_audit "$reports_dir"

  outdir="$reports_dir/aws-audit-2026-04-06_00-00-00"
  assert_dir_exists "$outdir"
  assert_file_exists "$outdir/report.txt"
  assert_file_exists "$outdir/summary.json"
  assert_file_exists "$outdir/meta/status.tsv"

  assert_eq "123456789012" "$("$JQ_BIN" -r '.account_id' "$outdir/summary.json")"
  assert_eq "arn:aws:iam::123456789012:user/test" "$("$JQ_BIN" -r '.caller_arn' "$outdir/summary.json")"
  assert_eq "test-user" "$("$JQ_BIN" -r '.caller_user_id' "$outdir/summary.json")"
  assert_eq "us-east-1 us-east-2" "$("$JQ_BIN" -r '.selected_regions | join(" ")' "$outdir/summary.json")"
  assert_eq "37" "$("$JQ_BIN" -r '.success_count' "$outdir/summary.json")"
  assert_eq "0" "$("$JQ_BIN" -r '.failure_count' "$outdir/summary.json")"
  assert_eq "0" "$("$JQ_BIN" -r '.skipped_count' "$outdir/summary.json")"
  assert_file_contains "$outdir/report.txt" "AWS account ID: 123456789012"
  assert_file_contains "$outdir/report.txt" "AWS caller ARN: arn:aws:iam::123456789012:user/test"
  assert_file_contains "$outdir/report.txt" "AWS caller user ID: test-user"
  rm -rf "$tmp_dir"
}

test_service_filter_records_skips() {
  local tmp_dir reports_dir outdir

  tmp_dir="$(mktemp -d)"
  reports_dir="$tmp_dir/reports"

  run_audit "$reports_dir" --regions us-east-2 --services sagemaker

  outdir="$reports_dir/aws-audit-2026-04-06_00-00-00"
  assert_eq "us-east-2" "$("$JQ_BIN" -r '.selected_regions | join(" ")' "$outdir/summary.json")"
  assert_eq "sagemaker" "$("$JQ_BIN" -r '.selected_services | join(" ")' "$outdir/summary.json")"
  assert_eq "2" "$("$JQ_BIN" -r '.success_count' "$outdir/summary.json")"
  assert_eq "18" "$("$JQ_BIN" -r '.skipped_count' "$outdir/summary.json")"
  assert_eq "0" "$("$JQ_BIN" -r '.failure_count' "$outdir/summary.json")"
  rm -rf "$tmp_dir"
}

test_unique_output_directories() {
  local tmp_dir reports_dir

  tmp_dir="$(mktemp -d)"
  reports_dir="$tmp_dir/reports"

  run_audit "$reports_dir" --services s3
  run_audit "$reports_dir" --services s3

  assert_dir_exists "$reports_dir/aws-audit-2026-04-06_00-00-00"
  assert_dir_exists "$reports_dir/aws-audit-2026-04-06_00-00-00-1"
  rm -rf "$tmp_dir"
}

test_failed_service_is_recorded() {
  local tmp_dir reports_dir outdir

  tmp_dir="$(mktemp -d)"
  reports_dir="$tmp_dir/reports"

  REPORTS_DIR="$reports_dir" \
  TIMESTAMP_OVERRIDE="2026-04-06_00-00-00" \
  AWS_BIN="$MOCK_AWS" \
  MOCK_FAIL_SERVICE="opensearch" \
  "$SCRIPT_PATH" --regions us-east-2 --services opensearch >/dev/null

  outdir="$reports_dir/aws-audit-2026-04-06_00-00-00"
  assert_eq "1" "$("$JQ_BIN" -r '.failure_count' "$outdir/summary.json")"
  assert_eq "mock failure for service: opensearch" "$(tr -d '\n' < "$outdir/stderr/us_east_2_opensearch_list_domain_names.stderr")"
  rm -rf "$tmp_dir"
}

main() {
  test_default_run_creates_outputs
  test_service_filter_records_skips
  test_unique_output_directories
  test_failed_service_is_recorded
  printf 'all tests passed\n'
}

main "$@"
