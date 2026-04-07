#!/usr/bin/env bash
set -uo pipefail

BUCKET=""
REQUEST_REGION=""
BUCKET_REGION=""
STORAGE_METRICS_REGION="us-east-1"
DAYS=14

TIMESTAMP="${TIMESTAMP_OVERRIDE:-$(date +"%Y-%m-%d_%H-%M-%S")}"
REPORTS_DIR="${REPORTS_DIR:-reports/s3-cloudwatch}"
BASE_OUTDIR="$REPORTS_DIR/s3-cloudwatch-$TIMESTAMP"
OUTDIR="$BASE_OUTDIR"
STATUS_DELIM=$'\034'

AWS_BIN="${AWS_BIN:-aws}"
JQ_BIN="${JQ_BIN:-jq}"
HAS_JQ=0
SUCCESS_COUNT=0
FAILURE_COUNT=0
SKIPPED_COUNT=0
RUN_SUFFIX=0
TEXT_REPORT=""
SUMMARY_JSON=""
JSON_DIR=""
TEXT_DIR=""
STDERR_DIR=""
META_DIR=""
STATUS_TSV=""
OUTPUT_INITIALIZED=0

if command -v "$JQ_BIN" >/dev/null 2>&1; then
  HAS_JQ=1
fi

export AWS_PAGER=""

usage() {
  cat <<'EOF'
Usage:
  ./aws-s3-cloudwatch-report.sh --bucket example.com [--region us-east-2] [--days 14]

Options:
  --bucket   S3 bucket name to inspect. Required.
  --region   Region for request metrics. Defaults to the detected bucket region.
  --days     Number of days of CloudWatch history to query. Default: 14
  -h, --help Show this help text.
EOF
}

init_output() {
  OUTDIR="$BASE_OUTDIR"
  RUN_SUFFIX=0

  while [ -e "$OUTDIR" ]; do
    RUN_SUFFIX=$((RUN_SUFFIX + 1))
    OUTDIR="${BASE_OUTDIR}-${RUN_SUFFIX}"
  done

  TEXT_REPORT="$OUTDIR/report.txt"
  SUMMARY_JSON="$OUTDIR/summary.json"
  JSON_DIR="$OUTDIR/json"
  TEXT_DIR="$OUTDIR/text"
  STDERR_DIR="$OUTDIR/stderr"
  META_DIR="$OUTDIR/meta"
  STATUS_TSV="$META_DIR/status.tsv"

  mkdir -p "$OUTDIR" "$JSON_DIR" "$TEXT_DIR" "$STDERR_DIR" "$META_DIR"
  : > "$STATUS_TSV"
  OUTPUT_INITIALIZED=1
}

cleanup_empty_output_on_error() {
  local exit_code=$?
  local non_empty_file_count

  if [ "$exit_code" -eq 0 ] || [ "$OUTPUT_INITIALIZED" -ne 1 ] || [ ! -d "$OUTDIR" ]; then
    return "$exit_code"
  fi

  non_empty_file_count="$(find "$OUTDIR" -type f -size +0c | wc -l | tr -d '[:space:]')"
  if [ "${non_empty_file_count:-0}" = "0" ]; then
    rm -rf "$OUTDIR"
  fi

  return "$exit_code"
}

trap cleanup_empty_output_on_error EXIT

log_console() {
  printf '%s\n' "$*"
}

report_line() {
  printf '%s\n' "$*" >> "$TEXT_REPORT"
}

write_section_separator() {
  report_line
  report_line "============================================================"
  report_line "$1"
  report_line "============================================================"
}

normalize_bucket_region() {
  local value="$1"

  case "$value" in
    ""|"null"|"None")
      printf 'us-east-1'
      ;;
    "EU")
      printf 'eu-west-1'
      ;;
    *)
      printf '%s' "$value"
      ;;
  esac
}

date_now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

date_days_ago_utc() {
  local days="$1"

  if date -u -v-"${days}"d +"%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
    date -u -v-"${days}"d +"%Y-%m-%dT%H:%M:%SZ"
  else
    date -u -d "${days} days ago" +"%Y-%m-%dT%H:%M:%SZ"
  fi
}

trim_carriage_return() {
  printf '%s' "$1" | tr -d '\r'
}

bytes_human() {
  local bytes="$1"

  if [ "$bytes" = "n/a" ] || [ -z "$bytes" ]; then
    printf 'n/a'
    return 0
  fi

  awk -v bytes="$bytes" '
    function human(x) {
      split("B KB MB GB TB PB", units, " ")
      i = 1
      while (x >= 1024 && i < 6) {
        x /= 1024
        i++
      }
      return sprintf("%.2f %s", x, units[i])
    }
    BEGIN { print human(bytes) }
  '
}

record_status() {
  local step="$1"
  local scope="$2"
  local status="$3"
  local exit_code="$4"
  local stdout_path="$5"
  local stderr_path="$6"
  local note="$7"

  printf '%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
    "$step" \
    "$STATUS_DELIM" \
    "$scope" \
    "$STATUS_DELIM" \
    "$status" \
    "$STATUS_DELIM" \
    "$exit_code" \
    "$STATUS_DELIM" \
    "$stdout_path" \
    "$STATUS_DELIM" \
    "$stderr_path" \
    "$STATUS_DELIM" \
    "$note" >> "$STATUS_TSV"
}

run_cmd() {
  local step="$1"
  local scope="$2"
  local stdout_path="$3"
  shift 3

  local stderr_path="$STDERR_DIR/${step}.stderr"
  local note=""
  local exit_code=0
  local status="success"

  : > "$stdout_path"
  : > "$stderr_path"

  if "$@" >"$stdout_path" 2>"$stderr_path"; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    exit_code=$?
    status="failed"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
  fi

  if [ "$status" = "success" ] && [ ! -s "$stderr_path" ]; then
    rm -f "$stderr_path"
    stderr_path=""
  fi

  record_status "$step" "$scope" "$status" "$exit_code" "$stdout_path" "$stderr_path" "$note"
  [ "$status" = "success" ]
}

record_skipped() {
  local step="$1"
  local scope="$2"
  local note="$3"

  SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
  record_status "$step" "$scope" "skipped" "0" "" "" "$note"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --bucket)
        shift
        BUCKET="${1:-}"
        ;;
      --region)
        shift
        REQUEST_REGION="${1:-}"
        ;;
      --days)
        shift
        DAYS="${1:-}"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf 'Error: unknown argument: %s\n' "$1" >&2
        usage >&2
        exit 1
        ;;
    esac
    shift || true
  done

  if [ -z "$BUCKET" ]; then
    printf 'Error: --bucket is required.\n' >&2
    usage >&2
    exit 1
  fi

  case "$DAYS" in
    ''|*[!0-9]*)
      printf 'Error: --days must be a positive integer.\n' >&2
      exit 1
      ;;
  esac

  if [ "$DAYS" -le 0 ]; then
    printf 'Error: --days must be greater than zero.\n' >&2
    exit 1
  fi
}

latest_datapoint_value() {
  local path="$1"

  if [ "$HAS_JQ" -ne 1 ] || [ ! -s "$path" ]; then
    printf 'n/a'
    return 0
  fi

  "$JQ_BIN" -r '
    .Datapoints
    | sort_by(.Timestamp)
    | last
    | .Average // .Sum // .Maximum // .Minimum // "n/a"
  ' "$path" 2>/dev/null || printf 'n/a'
}

count_lines() {
  local value=0
  local line

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    value=$((value + 1))
  done

  printf '%s' "$value"
}

json_has_datapoints() {
  local path="$1"

  if [ "$HAS_JQ" -ne 1 ] || [ ! -s "$path" ]; then
    return 1
  fi

  [ "$("$JQ_BIN" -r '(.Datapoints // []) | length' "$path" 2>/dev/null || printf '0')" -gt 0 ]
}

discover_storage_type_values() {
  local path="$1"
  local metric_name="$2"

  if [ "$HAS_JQ" -ne 1 ] || [ ! -s "$path" ]; then
    return 0
  fi

  "$JQ_BIN" -r --arg metric_name "$metric_name" '
    .Metrics[]
    | select(.MetricName == $metric_name)
    | .Dimensions[]
    | select(.Name == "StorageType")
    | .Value
  ' "$path" 2>/dev/null | sort -u
}

storage_catalog_has_metrics() {
  local path="$1"

  if [ "$HAS_JQ" -ne 1 ] || [ ! -s "$path" ]; then
    return 1
  fi

  [ "$("$JQ_BIN" -r '(.Metrics // []) | length' "$path" 2>/dev/null || printf '0')" -gt 0 ]
}

discover_request_metric_names() {
  local path="$1"
  local filter_id="$2"

  if [ "$HAS_JQ" -ne 1 ] || [ ! -s "$path" ]; then
    return 0
  fi

  "$JQ_BIN" -r --arg filter_id "$filter_id" '
    .Metrics[]
    | select(any(.Dimensions[]; .Name == "FilterId" and .Value == $filter_id))
    | .MetricName
  ' "$path" 2>/dev/null | sort -u
}

discover_request_filter_ids() {
  local path="$1"

  if [ "$HAS_JQ" -ne 1 ] || [ ! -s "$path" ]; then
    return 0
  fi

  "$JQ_BIN" -r '
    .MetricsConfigurationList[]
    | .Id
  ' "$path" 2>/dev/null | sort -u
}

request_metric_statistic() {
  local metric_name="$1"

  case "$metric_name" in
    FirstByteLatency|TotalRequestLatency)
      printf 'Average'
      ;;
    *)
      printf 'Sum'
      ;;
  esac
}

collect_bucket_metadata() {
  local location_json="$JSON_DIR/bucket_location.json"
  local website_json="$JSON_DIR/bucket_website.json"

  log_console "Resolving S3 bucket region for: $BUCKET"
  if run_cmd \
    "bucket-location" \
    "bucket" \
    "$location_json" \
    "$AWS_BIN" s3api get-bucket-location --bucket "$BUCKET" --output json; then
    if [ "$HAS_JQ" -eq 1 ]; then
      BUCKET_REGION="$(normalize_bucket_region "$("$JQ_BIN" -r '.LocationConstraint // "us-east-1"' "$location_json")")"
    fi
  fi

  if [ -z "$BUCKET_REGION" ]; then
    BUCKET_REGION="us-east-1"
  fi

  if [ -z "$REQUEST_REGION" ]; then
    REQUEST_REGION="$BUCKET_REGION"
  fi

  log_console "Bucket region: $BUCKET_REGION"
  log_console "Request metrics region: $REQUEST_REGION"
  log_console "Storage metrics region: $STORAGE_METRICS_REGION"

  run_cmd \
    "bucket-website" \
    "bucket" \
    "$website_json" \
    "$AWS_BIN" s3api get-bucket-website --bucket "$BUCKET" --output json || true
}

collect_storage_metrics() {
  local catalog_json="$JSON_DIR/storage_metrics_catalog.json"
  local catalog_bucket_region_json="$JSON_DIR/storage_metrics_catalog_bucket_region.json"
  local selected_catalog_json="$catalog_json"
  local end_time start_time storage_type metric_safe output_json
  local found_any=0

  start_time="$(date_days_ago_utc "$DAYS")"
  end_time="$(date_now_utc)"

  log_console "Discovering storage metrics"
  if ! run_cmd \
    "storage-metrics-catalog" \
    "cloudwatch-storage" \
    "$catalog_json" \
    "$AWS_BIN" cloudwatch list-metrics \
      --namespace AWS/S3 \
      --dimensions Name=BucketName,Value="$BUCKET" \
      --region "$STORAGE_METRICS_REGION" \
      --output json; then
    return 0
  fi

  if ! storage_catalog_has_metrics "$catalog_json" && [ "$BUCKET_REGION" != "$STORAGE_METRICS_REGION" ]; then
    log_console "No storage metrics found in $STORAGE_METRICS_REGION, retrying bucket region: $BUCKET_REGION"
    if run_cmd \
      "storage-metrics-catalog-bucket-region" \
      "cloudwatch-storage" \
      "$catalog_bucket_region_json" \
      "$AWS_BIN" cloudwatch list-metrics \
        --namespace AWS/S3 \
        --dimensions Name=BucketName,Value="$BUCKET" \
        --region "$BUCKET_REGION" \
        --output json; then
      if storage_catalog_has_metrics "$catalog_bucket_region_json"; then
        selected_catalog_json="$catalog_bucket_region_json"
      fi
    fi
  fi

  while IFS= read -r storage_type; do
    storage_type="$(trim_carriage_return "$storage_type")"
    [ -n "$storage_type" ] || continue
    found_any=1
    metric_safe="$(printf '%s' "$storage_type" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_')"
    output_json="$JSON_DIR/storage_bucket_size_bytes_${metric_safe}.json"
    run_cmd \
      "storage-bucket-size-bytes-${metric_safe}" \
      "cloudwatch-storage" \
      "$output_json" \
      "$AWS_BIN" cloudwatch get-metric-statistics \
        --namespace AWS/S3 \
        --metric-name BucketSizeBytes \
        --dimensions Name=BucketName,Value="$BUCKET" Name=StorageType,Value="$storage_type" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --period 86400 \
        --statistics Average \
        --region "$STORAGE_METRICS_REGION" \
        --output json
  done < <(discover_storage_type_values "$selected_catalog_json" "BucketSizeBytes")

  while IFS= read -r storage_type; do
    storage_type="$(trim_carriage_return "$storage_type")"
    [ -n "$storage_type" ] || continue
    found_any=1
    metric_safe="$(printf '%s' "$storage_type" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_')"
    output_json="$JSON_DIR/storage_number_of_objects_${metric_safe}.json"
    run_cmd \
      "storage-number-of-objects-${metric_safe}" \
      "cloudwatch-storage" \
      "$output_json" \
      "$AWS_BIN" cloudwatch get-metric-statistics \
        --namespace AWS/S3 \
        --metric-name NumberOfObjects \
        --dimensions Name=BucketName,Value="$BUCKET" Name=StorageType,Value="$storage_type" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --period 86400 \
        --statistics Average \
        --region "$STORAGE_METRICS_REGION" \
        --output json
  done < <(discover_storage_type_values "$selected_catalog_json" "NumberOfObjects")

  if [ "$found_any" -eq 0 ]; then
    record_skipped "storage-metrics-discovery-empty" "cloudwatch-storage" "No storage metric dimensions were discovered for this bucket."
  fi
}

collect_request_metrics() {
  local catalog_json="$JSON_DIR/request_metrics_catalog.json"
  local metrics_config_json="$JSON_DIR/bucket_metrics_configurations.json"
  local end_time start_time metric_name statistic metric_safe output_json found_any=0
  local filter_id filter_safe
  local filter_count=0

  start_time="$(date_days_ago_utc "$DAYS")"
  end_time="$(date_now_utc)"

  log_console "Discovering S3 bucket metrics configurations"
  if ! run_cmd \
    "bucket-metrics-configurations" \
    "bucket" \
    "$metrics_config_json" \
    "$AWS_BIN" s3api list-bucket-metrics-configurations \
      --bucket "$BUCKET" \
      --output json; then
    return 0
  fi

  while IFS= read -r filter_id; do
    filter_id="$(trim_carriage_return "$filter_id")"
    [ -n "$filter_id" ] || continue
    filter_count=$((filter_count + 1))
  done < <(discover_request_filter_ids "$metrics_config_json")

  if [ "$filter_count" -eq 0 ]; then
    record_skipped \
      "request-metrics-not-configured" \
      "cloudwatch-request" \
      "No S3 bucket metrics configurations were found. Enable request metrics on the bucket before expecting request-level CloudWatch metrics."
    return 0
  fi

  log_console "Discovering request metrics from CloudWatch"
  if ! run_cmd \
    "request-metrics-catalog" \
    "cloudwatch-request" \
    "$catalog_json" \
    "$AWS_BIN" cloudwatch list-metrics \
      --namespace AWS/S3 \
      --dimensions Name=BucketName,Value="$BUCKET" \
      --region "$REQUEST_REGION" \
      --output json; then
    return 0
  fi

  while IFS= read -r filter_id; do
    filter_id="$(trim_carriage_return "$filter_id")"
    [ -n "$filter_id" ] || continue
    filter_safe="$(printf '%s' "$filter_id" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_')"
    while IFS= read -r metric_name; do
      metric_name="$(trim_carriage_return "$metric_name")"
      [ -n "$metric_name" ] || continue
      found_any=1
      statistic="$(request_metric_statistic "$metric_name")"
      metric_safe="$(printf '%s' "$metric_name" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_')"
      output_json="$JSON_DIR/request_${filter_safe}_${metric_safe}.json"
      run_cmd \
        "request-${filter_safe}-${metric_safe}" \
        "cloudwatch-request" \
        "$output_json" \
        "$AWS_BIN" cloudwatch get-metric-statistics \
          --namespace AWS/S3 \
          --metric-name "$metric_name" \
          --dimensions Name=BucketName,Value="$BUCKET" Name=FilterId,Value="$filter_id" \
          --start-time "$start_time" \
          --end-time "$end_time" \
          --period 86400 \
          --statistics "$statistic" \
          --region "$REQUEST_REGION" \
          --output json
    done < <(discover_request_metric_names "$catalog_json" "$filter_id")
  done < <(discover_request_filter_ids "$metrics_config_json")

  if [ "$found_any" -eq 0 ]; then
    record_skipped \
      "request-metrics-discovery-empty" \
      "cloudwatch-request" \
      "S3 bucket metrics configurations exist, but CloudWatch did not return request metrics yet. This can happen if metrics were enabled recently or there has not been recent traffic."
  fi
}

write_report_header() {
  report_line "S3 CloudWatch bucket report"
  report_line "Generated at: $(date)"
  report_line "Bucket: $BUCKET"
  report_line "Bucket region: $BUCKET_REGION"
  report_line "Request metrics region: $REQUEST_REGION"
  report_line "Storage metrics region: $STORAGE_METRICS_REGION"
  report_line "Days queried: $DAYS"
  report_line "Output directory: $OUTDIR"
  report_line "Summary JSON: $SUMMARY_JSON"
  report_line
}

write_summary_section() {
  local total_commands=$((SUCCESS_COUNT + FAILURE_COUNT + SKIPPED_COUNT))
  local step scope status exit_code stdout_path stderr_path note
  local path latest_value filter_id metric_name
  local metrics_config_json="$JSON_DIR/bucket_metrics_configurations.json"
  local request_catalog_json="$JSON_DIR/request_metrics_catalog.json"

  write_section_separator "Summary"
  report_line "Total steps: $total_commands"
  report_line "Successful steps: $SUCCESS_COUNT"
  report_line "Failed steps: $FAILURE_COUNT"
  report_line "Skipped steps: $SKIPPED_COUNT"
  report_line
  report_line "Request metrics discovery summary:"

  if [ -f "$metrics_config_json" ] && [ -s "$metrics_config_json" ]; then
    report_line "- Bucket metrics configuration IDs: $(discover_request_filter_ids "$metrics_config_json" | count_lines)"
    while IFS= read -r filter_id; do
      filter_id="$(trim_carriage_return "$filter_id")"
      [ -n "$filter_id" ] || continue
      report_line "  - $filter_id"
      if [ -f "$request_catalog_json" ] && [ -s "$request_catalog_json" ]; then
        report_line "    published request metrics: $(discover_request_metric_names "$request_catalog_json" "$filter_id" | count_lines)"
        while IFS= read -r metric_name; do
          [ -n "$metric_name" ] || continue
          report_line "    - $metric_name"
        done < <(discover_request_metric_names "$request_catalog_json" "$filter_id")
      else
        report_line "    published request metrics: 0"
      fi
    done < <(discover_request_filter_ids "$metrics_config_json")
  else
    report_line "- Bucket metrics configuration IDs: 0"
  fi

  report_line
  report_line "Latest storage metric datapoints:"

  for path in "$JSON_DIR"/storage_bucket_size_bytes_*.json; do
    [ -f "$path" ] || continue
    latest_value="$(latest_datapoint_value "$path")"
    if json_has_datapoints "$path"; then
      report_line "- $(basename "$path" .json): $latest_value bytes ($(bytes_human "$latest_value"))"
    else
      report_line "- $(basename "$path" .json): metric definition found, but CloudWatch returned no datapoints"
    fi
  done

  for path in "$JSON_DIR"/storage_number_of_objects_*.json; do
    [ -f "$path" ] || continue
    latest_value="$(latest_datapoint_value "$path")"
    if json_has_datapoints "$path"; then
      report_line "- $(basename "$path" .json): $latest_value objects"
    else
      report_line "- $(basename "$path" .json): metric definition found, but CloudWatch returned no datapoints"
    fi
  done

  report_line
  report_line "Latest request metric datapoints:"
  for path in "$JSON_DIR"/request_*.json; do
    [ -f "$path" ] || continue
    if [ "$(basename "$path")" = "request_metrics_catalog.json" ]; then
      continue
    fi
    latest_value="$(latest_datapoint_value "$path")"
    report_line "- $(basename "$path" .json): $latest_value"
  done

  report_line
  report_line "Failed steps:"
  while IFS="$STATUS_DELIM" read -r step scope status exit_code stdout_path stderr_path note; do
    if [ "$status" = "failed" ]; then
      report_line "- [$scope] $step (exit $exit_code)"
      if [ -n "$stderr_path" ] && [ -s "$stderr_path" ]; then
        report_line "  stderr file: $stderr_path"
      fi
    fi
  done < "$STATUS_TSV"

  report_line
  report_line "Skipped steps:"
  while IFS="$STATUS_DELIM" read -r step scope status exit_code stdout_path stderr_path note; do
    if [ "$status" = "skipped" ]; then
      report_line "- [$scope] $step: $note"
    fi
  done < "$STATUS_TSV"
}

write_details_section() {
  local step scope status exit_code stdout_path stderr_path note

  write_section_separator "Detailed Results"

  while IFS="$STATUS_DELIM" read -r step scope status exit_code stdout_path stderr_path note; do
    report_line
    report_line "------------------------------------------------------------"
    report_line "Step: $step"
    report_line "Scope: $scope"
    report_line "Status: $status"
    report_line "Exit code: $exit_code"
    if [ -n "$note" ]; then
      report_line "Note: $note"
    fi
    if [ -n "$stdout_path" ]; then
      report_line "Stdout: $stdout_path"
    else
      report_line "Stdout: (empty)"
    fi
    if [ -n "$stderr_path" ]; then
      report_line "Stderr: $stderr_path"
    else
      report_line "Stderr: (empty)"
    fi
    report_line

    case "$status" in
      success)
        if [ "$HAS_JQ" -eq 1 ] && [ -s "$stdout_path" ]; then
          "$JQ_BIN" . "$stdout_path" >> "$TEXT_REPORT" 2>/dev/null || cat "$stdout_path" >> "$TEXT_REPORT"
        elif [ -n "$stdout_path" ] && [ -s "$stdout_path" ]; then
          cat "$stdout_path" >> "$TEXT_REPORT"
        else
          report_line "(no stdout)"
        fi
        ;;
      failed)
        if [ -n "$stderr_path" ] && [ -s "$stderr_path" ]; then
          cat "$stderr_path" >> "$TEXT_REPORT"
        else
          report_line "(no stderr)"
        fi
        ;;
      skipped)
        report_line "(skipped)"
        ;;
    esac
  done < "$STATUS_TSV"
}

write_summary_json() {
  local total_steps=$((SUCCESS_COUNT + FAILURE_COUNT + SKIPPED_COUNT))
  local failed_json skipped_json request_configs_json

  if [ "$HAS_JQ" -ne 1 ]; then
    return 0
  fi

  failed_json="$("$JQ_BIN" -Rn --arg delim "$STATUS_DELIM" '
    [inputs
     | select(length > 0)
     | split($delim)
     | {
         step: .[0],
         scope: .[1],
         status: .[2],
         exit_code: (.[3] | tonumber? // 0),
         stderr_path: .[5]
       }
     | select(.status == "failed")]
  ' < "$STATUS_TSV")"

  skipped_json="$("$JQ_BIN" -Rn --arg delim "$STATUS_DELIM" '
    [inputs
     | select(length > 0)
     | split($delim)
     | {
         step: .[0],
         scope: .[1],
         status: .[2],
         note: .[6]
       }
     | select(.status == "skipped")]
  ' < "$STATUS_TSV")"

  if [ -f "$JSON_DIR/bucket_metrics_configurations.json" ] && [ -s "$JSON_DIR/bucket_metrics_configurations.json" ] && [ -f "$JSON_DIR/request_metrics_catalog.json" ] && [ -s "$JSON_DIR/request_metrics_catalog.json" ]; then
    request_configs_json="$("$JQ_BIN" -n \
      --slurpfile metrics "$JSON_DIR/bucket_metrics_configurations.json" \
      --slurpfile catalog "$JSON_DIR/request_metrics_catalog.json" '
      (($metrics[0].MetricsConfigurationList) // []) as $configs
      | (($catalog[0].Metrics) // []) as $catalog_metrics
      | [
          $configs[]
          | .Id as $id
          | {
              id: $id,
              published_metric_names: [
                $catalog_metrics[]
                | select(any(.Dimensions[]?; .Name == "FilterId" and .Value == $id))
                | .MetricName
              ] | unique | sort
            }
        ]
    ' 2>/dev/null || printf '[]')"
  elif [ -f "$JSON_DIR/bucket_metrics_configurations.json" ] && [ -s "$JSON_DIR/bucket_metrics_configurations.json" ]; then
    request_configs_json="$("$JQ_BIN" -n \
      --slurpfile metrics "$JSON_DIR/bucket_metrics_configurations.json" '
      (($metrics[0].MetricsConfigurationList) // []) as $configs
      | [
          $configs[]
          | {
              id: .Id,
              published_metric_names: []
            }
        ]
    ' 2>/dev/null || printf '[]')"
  else
    request_configs_json='[]'
  fi

  "$JQ_BIN" -n \
    --arg bucket "$BUCKET" \
    --arg bucket_region "$BUCKET_REGION" \
    --arg request_region "$REQUEST_REGION" \
    --arg storage_metrics_region "$STORAGE_METRICS_REGION" \
    --arg generated_at "$(date)" \
    --arg output_directory "$OUTDIR" \
    --arg report_path "$TEXT_REPORT" \
    --arg summary_path "$SUMMARY_JSON" \
    --argjson days "$DAYS" \
    --argjson total_steps "$total_steps" \
    --argjson success_count "$SUCCESS_COUNT" \
    --argjson failure_count "$FAILURE_COUNT" \
    --argjson skipped_count "$SKIPPED_COUNT" \
    --argjson request_metric_configurations "$request_configs_json" \
    --argjson failed_steps "$failed_json" \
    --argjson skipped_steps "$skipped_json" \
    '{
      bucket: $bucket,
      bucket_region: $bucket_region,
      request_region: $request_region,
      storage_metrics_region: $storage_metrics_region,
      generated_at: $generated_at,
      days: $days,
      output_directory: $output_directory,
      report_path: $report_path,
      summary_path: $summary_path,
      total_steps: $total_steps,
      success_count: $success_count,
      failure_count: $failure_count,
      skipped_count: $skipped_count,
      request_metric_configurations: $request_metric_configurations,
      failed_steps: $failed_steps,
      skipped_steps: $skipped_steps
    }' > "$SUMMARY_JSON"
}

main() {
  parse_args "$@"
  init_output

  log_console "Writing S3 CloudWatch output to: $OUTDIR"
  log_console "Bucket: $BUCKET"

  collect_bucket_metadata
  collect_storage_metrics
  collect_request_metrics

  write_report_header
  write_summary_section
  write_details_section
  write_summary_json

  log_console "Finished."
  log_console "Text report: $TEXT_REPORT"
  log_console "Summary JSON: $SUMMARY_JSON"
}

main "$@"
