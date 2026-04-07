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
  assert_file_exists "$outdir/json/bucket_location.json"
  assert_file_exists "$outdir/json/bucket_metrics_configurations.json"
  assert_file_exists "$outdir/json/request_website_traffic_allrequests.json"
  assert_file_exists "$outdir/json/storage_bucket_size_bytes_standardstorage.json"

  assert_eq "example.com" "$("$JQ_BIN" -r '.bucket' "$outdir/summary.json")"
  assert_eq "us-east-2" "$("$JQ_BIN" -r '.bucket_region' "$outdir/summary.json")"
  assert_eq "us-east-2" "$("$JQ_BIN" -r '.request_region' "$outdir/summary.json")"
  assert_eq "9" "$("$JQ_BIN" -r '.success_count' "$outdir/summary.json")"
  assert_eq "0" "$("$JQ_BIN" -r '.failure_count' "$outdir/summary.json")"
  assert_eq "website-traffic" "$("$JQ_BIN" -r '.request_metric_configurations[0].id' "$outdir/summary.json")"
  assert_eq "2" "$("$JQ_BIN" -r '.request_metric_configurations[0].published_metric_names | length' "$outdir/summary.json")"
  assert_eq "1" "$(find "$reports_dir" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')"
  assert_file_contains "$outdir/report.txt" "These values come from the most recent CloudWatch datapoint returned for each metric."
  assert_file_contains "$outdir/report.txt" "AllRequests for filter \"website traffic\": 25 total requests at 2026-04-06T00:00:00Z (Sum). all requests handled by this bucket metric filter."
  assert_file_contains "$outdir/report.txt" "4xxErrors for filter \"website traffic\": 1 client-error responses at 2026-04-06T00:00:00Z (Sum). requests that returned an HTTP 4xx status code."

  if REPORTS_DIR="$reports_dir" TIMESTAMP_OVERRIDE="2026-04-06_00-10-00" "$SCRIPT_PATH" >/dev/null 2>&1; then
    printf 'expected missing bucket invocation to fail\n' >&2
    exit 1
  fi

  assert_dir_not_exists "$reports_dir/s3-cloudwatch-2026-04-06_00-10-00"

  rm -rf "$tmp_dir"
  printf 's3 cloudwatch tests passed\n'
}

main "$@"
