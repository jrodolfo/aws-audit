#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="$ROOT_DIR/aws-s3-cloudwatch-report.sh"
MOCK_AWS="$ROOT_DIR/tests/mock-s3-cloudwatch-aws.sh"
JQ_BIN="${JQ_BIN:-jq}"

assert_file_exists() {
  if [ ! -f "$1" ]; then
    printf 'missing expected file: %s\n' "$1" >&2
    exit 1
  fi
}

assert_eq() {
  if [ "$1" != "$2" ]; then
    printf 'assertion failed: expected [%s], got [%s]\n' "$1" "$2" >&2
    exit 1
  fi
}

assert_dir_not_exists() {
  if [ -d "$1" ]; then
    printf 'directory should not exist: %s\n' "$1" >&2
    exit 1
  fi
}

assert_file_contains() {
  if ! grep -Fq -- "$2" "$1"; then
    printf 'expected file [%s] to contain [%s]\n' "$1" "$2" >&2
    exit 1
  fi
}

main() {
  local tmp_dir reports_dir outdir

  tmp_dir="$(mktemp -d)"
  reports_dir="$tmp_dir/reports"

  REPORTS_DIR="$reports_dir" \
  TIMESTAMP_OVERRIDE="2026-04-06_00-00-00" \
  AWS_BIN="$MOCK_AWS" \
  "$SCRIPT_PATH" --bucket example.com >/dev/null

  outdir="$reports_dir/s3-cloudwatch-2026-04-06_00-00-00"
  assert_file_exists "$outdir/report.txt"
  assert_file_exists "$outdir/summary.json"
  assert_file_exists "$outdir/json/sts_get_caller_identity.json"
  assert_file_exists "$outdir/json/bucket_location.json"
  assert_file_exists "$outdir/json/bucket_metrics_configurations.json"
  assert_file_exists "$outdir/json/request_website_traffic_allrequests.json"
  assert_file_exists "$outdir/json/storage_bucket_size_bytes_standardstorage.json"

  assert_eq "example.com" "$("$JQ_BIN" -r '.bucket' "$outdir/summary.json")"
  assert_eq "us-east-2" "$("$JQ_BIN" -r '.bucket_region' "$outdir/summary.json")"
  assert_eq "us-east-2" "$("$JQ_BIN" -r '.request_region' "$outdir/summary.json")"
  assert_eq "123456789012" "$("$JQ_BIN" -r '.account_id' "$outdir/summary.json")"
  assert_eq "arn:aws:iam::123456789012:user/test" "$("$JQ_BIN" -r '.caller_arn' "$outdir/summary.json")"
  assert_eq "test-user" "$("$JQ_BIN" -r '.caller_user_id' "$outdir/summary.json")"
  assert_eq "10" "$("$JQ_BIN" -r '.success_count' "$outdir/summary.json")"
  assert_eq "0" "$("$JQ_BIN" -r '.failure_count' "$outdir/summary.json")"
  assert_eq "website-traffic" "$("$JQ_BIN" -r '.request_metric_configurations[0].id' "$outdir/summary.json")"
  assert_eq "2" "$("$JQ_BIN" -r '.request_metric_configurations[0].published_metric_names | length' "$outdir/summary.json")"
  assert_eq "1" "$(find "$reports_dir" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')"
  assert_file_contains "$outdir/report.txt" "AWS account ID: 123456789012"
  assert_file_contains "$outdir/report.txt" "AWS caller ARN: arn:aws:iam::123456789012:user/test"
  assert_file_contains "$outdir/report.txt" "AWS caller user ID: test-user"
  assert_file_contains "$outdir/report.txt" "Most recent datapoint window: 2026-04-05T00:00:00Z to 2026-04-06T00:00:00Z"
  assert_file_contains "$outdir/report.txt" "Days queried from CloudWatch: 14"
  assert_file_contains "$outdir/report.txt" "Datapoint period for request metrics: 24 hours"
  assert_file_contains "$outdir/report.txt" "Count metrics are totals for the datapoint period. Latency metrics are averages in milliseconds."
  assert_file_contains "$outdir/report.txt" "Filter: website traffic"
  assert_file_contains "$outdir/report.txt" "- AllRequests: 25 total requests (all requests)"
  assert_file_contains "$outdir/report.txt" "- 4xxErrors: 1 client-error responses (HTTP 4xx)"

  if REPORTS_DIR="$reports_dir" TIMESTAMP_OVERRIDE="2026-04-06_00-10-00" "$SCRIPT_PATH" >/dev/null 2>&1; then
    printf 'expected missing bucket invocation to fail\n' >&2
    exit 1
  fi

  assert_dir_not_exists "$reports_dir/s3-cloudwatch-2026-04-06_00-10-00"

  rm -rf "$tmp_dir"
  printf 's3 cloudwatch tests passed\n'
}

main "$@"
