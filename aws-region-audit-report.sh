#!/usr/bin/env bash
set -uo pipefail

DEFAULT_REGIONS=("us-east-1" "us-east-2")
ALL_SERVICES=(
  "sts"
  "aws-config"
  "s3"
  "ec2"
  "elbv2"
  "rds"
  "lambda"
  "ecs"
  "eks"
  "sagemaker"
  "opensearch"
  "secretsmanager"
  "logs"
  "tagging"
)

REGIONS=("${DEFAULT_REGIONS[@]}")
SELECTED_SERVICES=()
SERVICE_FILTER_ENABLED=0

TIMESTAMP="${TIMESTAMP_OVERRIDE:-$(date +"%Y-%m-%d_%H-%M-%S")}"
REPORTS_DIR="${REPORTS_DIR:-reports/audit}"
BASE_OUTDIR="$REPORTS_DIR/aws-audit-$TIMESTAMP"
OUTDIR="$BASE_OUTDIR"
STATUS_DELIM=$'\034'

AWS_BIN="${AWS_BIN:-aws}"
JQ_BIN="${JQ_BIN:-jq}"
HAS_JQ=0
SUCCESS_COUNT=0
FAILURE_COUNT=0
SKIPPED_COUNT=0
RUN_SUFFIX=0
ACCOUNT_ID="n/a"
CALLER_ARN="n/a"
CALLER_USER_ID="n/a"

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
: > "$TEXT_REPORT"
: > "$STATUS_TSV"

if command -v "$JQ_BIN" >/dev/null 2>&1; then
  HAS_JQ=1
fi

export AWS_PAGER=""

usage() {
  cat <<'EOF'
Usage:
  ./aws-region-audit-report.sh [--regions us-east-1,us-east-2] [--services sagemaker,ec2]
  ./aws-region-audit-report.sh [--regions us-east-1 us-east-2] [--services sagemaker ec2]

Options:
  --regions   Override the default region list.
  --services  Limit the audit to specific service groups.
              Available values: all, sts, aws-config, s3, ec2, elbv2, rds, lambda,
              ecs, eks, sagemaker, opensearch, secretsmanager, logs, tagging
  -h, --help  Show this help text.
EOF
}

service_key_is_known() {
  local candidate="$1"
  local service

  for service in "${ALL_SERVICES[@]}"; do
    if [ "$service" = "$candidate" ]; then
      return 0
    fi
  done

  return 1
}

service_is_selected() {
  local candidate="$1"
  local service

  if [ "$SERVICE_FILTER_ENABLED" -ne 1 ]; then
    return 0
  fi

  if [ "${#SELECTED_SERVICES[@]}" -eq 0 ]; then
    return 1
  fi

  for service in "${SELECTED_SERVICES[@]}"; do
    if [ "$service" = "$candidate" ]; then
      return 0
    fi
  done

  return 1
}

parse_regions_values() {
  local value
  local normalized

  REGIONS=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --*)
        break
        ;;
      *)
        normalized="${1//,/ }"
        for value in $normalized; do
          if [ -n "$value" ]; then
            REGIONS+=("$value")
          fi
        done
        shift
        ;;
    esac
  done

  if [ "${#REGIONS[@]}" -eq 0 ]; then
    printf 'Error: --regions requires at least one region value.\n' >&2
    usage >&2
    exit 1
  fi
}

parse_services_values() {
  local value
  local normalized
  local lowered

  SELECTED_SERVICES=()
  SERVICE_FILTER_ENABLED=1

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --*)
        break
        ;;
      *)
        normalized="${1//,/ }"
        for value in $normalized; do
          lowered="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
          if [ -z "$lowered" ]; then
            continue
          fi
          if [ "$lowered" = "all" ]; then
            SERVICE_FILTER_ENABLED=0
            SELECTED_SERVICES=("${ALL_SERVICES[@]}")
            return 0
          fi
          if ! service_key_is_known "$lowered"; then
            printf 'Error: unknown service key: %s\n' "$value" >&2
            usage >&2
            exit 1
          fi
          if ! service_is_selected_parse_only "$lowered"; then
            SELECTED_SERVICES+=("$lowered")
          fi
        done
        shift
        ;;
    esac
  done

  if [ "${#SELECTED_SERVICES[@]}" -eq 0 ]; then
    printf 'Error: --services requires at least one service value.\n' >&2
    usage >&2
    exit 1
  fi
}

service_is_selected_parse_only() {
  local candidate="$1"
  local service

  if [ "${#SELECTED_SERVICES[@]}" -eq 0 ]; then
    return 1
  fi

  for service in "${SELECTED_SERVICES[@]}"; do
    if [ "$service" = "$candidate" ]; then
      return 0
    fi
  done

  return 1
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --regions)
        shift
        parse_regions_values "$@"
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --*)
              break
              ;;
            *)
              shift
              ;;
          esac
        done
        ;;
      --services)
        shift
        parse_services_values "$@"
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --*)
              break
              ;;
            *)
              shift
              ;;
          esac
        done
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
  done

  if [ "$SERVICE_FILTER_ENABLED" -ne 1 ]; then
    SELECTED_SERVICES=("${ALL_SERVICES[@]}")
  fi
}

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

json_count() {
  local path="$1"

  if [ "$HAS_JQ" -ne 1 ] || [ ! -s "$path" ]; then
    printf 'n/a'
    return 0
  fi

  "$JQ_BIN" -r '
    if type == "array" then
      length
    elif type == "object" then
      [to_entries[] | .value | if type == "array" then length else empty end] | add // 0
    else
      0
    end
  ' "$path" 2>/dev/null || printf 'n/a'
}

load_account_identity() {
  local caller_identity_json="$JSON_DIR/sts_get_caller_identity.json"

  if [ "$HAS_JQ" -ne 1 ] || [ ! -s "$caller_identity_json" ]; then
    return 0
  fi

  ACCOUNT_ID="$("$JQ_BIN" -r '.Account // "n/a"' "$caller_identity_json" 2>/dev/null || printf 'n/a')"
  CALLER_ARN="$("$JQ_BIN" -r '.Arn // "n/a"' "$caller_identity_json" 2>/dev/null || printf 'n/a')"
  CALLER_USER_ID="$("$JQ_BIN" -r '.UserId // "n/a"' "$caller_identity_json" 2>/dev/null || printf 'n/a')"
}

render_stdout_to_report() {
  local output_format="$1"
  local stdout_path="$2"

  if [ ! -s "$stdout_path" ]; then
    report_line "(no stdout)"
    return 0
  fi

  case "$output_format" in
    json)
      if [ "$HAS_JQ" -eq 1 ]; then
        "$JQ_BIN" . "$stdout_path" >> "$TEXT_REPORT" 2>/dev/null || cat "$stdout_path" >> "$TEXT_REPORT"
      else
        cat "$stdout_path" >> "$TEXT_REPORT"
      fi
      ;;
    *)
      cat "$stdout_path" >> "$TEXT_REPORT"
      ;;
  esac
}

record_status() {
  local scope="$1"
  local service_key="$2"
  local title="$3"
  local output_format="$4"
  local billable="$5"
  local status="$6"
  local exit_code="$7"
  local resource_count="$8"
  local stdout_path="$9"
  local stderr_path="${10}"
  local command_string="${11}"

  printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
    "$scope" \
    "$STATUS_DELIM" \
    "$service_key" \
    "$STATUS_DELIM" \
    "$title" \
    "$STATUS_DELIM" \
    "$output_format" \
    "$STATUS_DELIM" \
    "$billable" \
    "$STATUS_DELIM" \
    "$status" \
    "$STATUS_DELIM" \
    "$exit_code" \
    "$STATUS_DELIM" \
    "$resource_count" \
    "$STATUS_DELIM" \
    "$stdout_path" \
    "$STATUS_DELIM" \
    "$stderr_path" \
    "$STATUS_DELIM" \
    "$command_string" >> "$STATUS_TSV"
}

run_audit_cmd() {
  local scope="$1"
  local service_key="$2"
  local title="$3"
  local base_name="$4"
  local output_format="$5"
  local billable="$6"
  shift 6

  local stdout_path=""
  local stderr_path=""
  local exit_code=0
  local status="success"
  local resource_count="n/a"
  local command_string=""

  printf -v command_string '%q ' "$@"
  command_string="${command_string% }"

  if ! service_is_selected "$service_key"; then
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    log_console "Skipping: $title"
    record_status \
      "$scope" \
      "$service_key" \
      "$title" \
      "$output_format" \
      "$billable" \
      "skipped" \
      "0" \
      "n/a" \
      "" \
      "" \
      "$command_string"
    return 0
  fi

  case "$output_format" in
    json)
      stdout_path="$JSON_DIR/${base_name}.json"
      ;;
    text)
      stdout_path="$TEXT_DIR/${base_name}.txt"
      ;;
    *)
      stdout_path="$TEXT_DIR/${base_name}.out"
      ;;
  esac

  stderr_path="$STDERR_DIR/${base_name}.stderr"
  : > "$stdout_path"
  : > "$stderr_path"

  log_console "Running: $title"

  if "$@" >"$stdout_path" 2>"$stderr_path"; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    if [ "$output_format" = "json" ]; then
      resource_count="$(json_count "$stdout_path")"
    fi
  else
    exit_code=$?
    status="failed"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
  fi

  if [ "$status" = "success" ] && [ ! -s "$stderr_path" ]; then
    rm -f "$stderr_path"
    stderr_path=""
  fi

  record_status \
    "$scope" \
    "$service_key" \
    "$title" \
    "$output_format" \
    "$billable" \
    "$status" \
    "$exit_code" \
    "$resource_count" \
    "$stdout_path" \
    "$stderr_path" \
    "$command_string"
}

collect_global_audits() {
  run_audit_cmd \
    "global" \
    "sts" \
    "STS caller identity" \
    "sts_get_caller_identity" \
    "json" \
    "no" \
    "$AWS_BIN" sts get-caller-identity --output json

  run_audit_cmd \
    "global" \
    "aws-config" \
    "AWS CLI configuration list" \
    "aws_configure_list" \
    "text" \
    "no" \
    "$AWS_BIN" configure list

  run_audit_cmd \
    "global" \
    "s3" \
    "S3 buckets" \
    "s3_list_buckets" \
    "json" \
    "yes" \
    "$AWS_BIN" s3api list-buckets --output json \
      --query 'Buckets[].{Name:Name,CreationDate:CreationDate}'
}

collect_region_audits() {
  local region="$1"
  local safe_region="${region//-/_}"

  run_audit_cmd \
    "$region" \
    "ec2" \
    "EC2 instances - $region" \
    "${safe_region}_ec2_describe_instances" \
    "json" \
    "yes" \
    "$AWS_BIN" ec2 describe-instances \
      --region "$region" \
      --output json \
      --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Type:InstanceType,Name:Tags[?Key==`Name`]|[0].Value,LaunchTime:LaunchTime}'

  run_audit_cmd \
    "$region" \
    "ec2" \
    "EBS volumes - $region" \
    "${safe_region}_ec2_describe_volumes" \
    "json" \
    "yes" \
    "$AWS_BIN" ec2 describe-volumes \
      --region "$region" \
      --output json \
      --query 'Volumes[].{Id:VolumeId,Size:Size,State:State,Type:VolumeType,Encrypted:Encrypted}'

  run_audit_cmd \
    "$region" \
    "ec2" \
    "Elastic IPs - $region" \
    "${safe_region}_ec2_describe_addresses" \
    "json" \
    "yes" \
    "$AWS_BIN" ec2 describe-addresses \
      --region "$region" \
      --output json \
      --query 'Addresses[].{PublicIp:PublicIp,AllocationId:AllocationId,AssociationId:AssociationId,InstanceId:InstanceId}'

  run_audit_cmd \
    "$region" \
    "elbv2" \
    "Load balancers v2 - $region" \
    "${safe_region}_elbv2_describe_load_balancers" \
    "json" \
    "yes" \
    "$AWS_BIN" elbv2 describe-load-balancers \
      --region "$region" \
      --output json \
      --query 'LoadBalancers[].{Name:LoadBalancerName,Type:Type,State:State.Code,Scheme:Scheme,DNS:DNSName}'

  run_audit_cmd \
    "$region" \
    "rds" \
    "RDS DB instances - $region" \
    "${safe_region}_rds_describe_db_instances" \
    "json" \
    "yes" \
    "$AWS_BIN" rds describe-db-instances \
      --region "$region" \
      --output json \
      --query 'DBInstances[].{Id:DBInstanceIdentifier,Engine:Engine,Class:DBInstanceClass,Status:DBInstanceStatus,MultiAZ:MultiAZ}'

  run_audit_cmd \
    "$region" \
    "lambda" \
    "Lambda functions - $region" \
    "${safe_region}_lambda_list_functions" \
    "json" \
    "yes" \
    "$AWS_BIN" lambda list-functions \
      --region "$region" \
      --output json \
      --query 'Functions[].{Name:FunctionName,Runtime:Runtime,LastModified:LastModified,MemorySize:MemorySize}'

  run_audit_cmd \
    "$region" \
    "ecs" \
    "ECS clusters - $region" \
    "${safe_region}_ecs_list_clusters" \
    "json" \
    "yes" \
    "$AWS_BIN" ecs list-clusters \
      --region "$region" \
      --output json

  run_audit_cmd \
    "$region" \
    "eks" \
    "EKS clusters - $region" \
    "${safe_region}_eks_list_clusters" \
    "json" \
    "yes" \
    "$AWS_BIN" eks list-clusters \
      --region "$region" \
      --output json

  run_audit_cmd \
    "$region" \
    "sagemaker" \
    "SageMaker domains - $region" \
    "${safe_region}_sagemaker_list_domains" \
    "json" \
    "yes" \
    "$AWS_BIN" sagemaker list-domains \
      --region "$region" \
      --output json

  run_audit_cmd \
    "$region" \
    "sagemaker" \
    "SageMaker notebook instances - $region" \
    "${safe_region}_sagemaker_list_notebook_instances" \
    "json" \
    "yes" \
    "$AWS_BIN" sagemaker list-notebook-instances \
      --region "$region" \
      --output json

  run_audit_cmd \
    "$region" \
    "opensearch" \
    "OpenSearch domains - $region" \
    "${safe_region}_opensearch_list_domain_names" \
    "json" \
    "yes" \
    "$AWS_BIN" opensearch list-domain-names \
      --region "$region" \
      --output json

  run_audit_cmd \
    "$region" \
    "secretsmanager" \
    "Secrets Manager secrets - $region" \
    "${safe_region}_secretsmanager_list_secrets" \
    "json" \
    "yes" \
    "$AWS_BIN" secretsmanager list-secrets \
      --region "$region" \
      --output json \
      --query 'SecretList[].{Name:Name,LastChangedDate:LastChangedDate,PrimaryRegion:PrimaryRegion}'

  run_audit_cmd \
    "$region" \
    "logs" \
    "CloudWatch log groups - $region" \
    "${safe_region}_logs_describe_log_groups" \
    "json" \
    "yes" \
    "$AWS_BIN" logs describe-log-groups \
      --region "$region" \
      --output json \
      --query 'logGroups[].{Name:logGroupName,StoredBytes:storedBytes,RetentionInDays:retentionInDays}'

  run_audit_cmd \
    "$region" \
    "ec2" \
    "VPCs - $region" \
    "${safe_region}_ec2_describe_vpcs" \
    "json" \
    "no" \
    "$AWS_BIN" ec2 describe-vpcs \
      --region "$region" \
      --output json \
      --query 'Vpcs[].{VpcId:VpcId,CidrBlock:CidrBlock,IsDefault:IsDefault,State:State}'

  run_audit_cmd \
    "$region" \
    "ec2" \
    "Subnets - $region" \
    "${safe_region}_ec2_describe_subnets" \
    "json" \
    "no" \
    "$AWS_BIN" ec2 describe-subnets \
      --region "$region" \
      --output json \
      --query 'Subnets[].{SubnetId:SubnetId,VpcId:VpcId,CidrBlock:CidrBlock,AvailableIpAddressCount:AvailableIpAddressCount}'

  run_audit_cmd \
    "$region" \
    "ec2" \
    "Security groups - $region" \
    "${safe_region}_ec2_describe_security_groups" \
    "json" \
    "no" \
    "$AWS_BIN" ec2 describe-security-groups \
      --region "$region" \
      --output json \
      --query 'SecurityGroups[].{GroupId:GroupId,GroupName:GroupName,VpcId:VpcId,Description:Description}'

  run_audit_cmd \
    "$region" \
    "tagging" \
    "Tagged resources via Resource Groups Tagging API - $region" \
    "${safe_region}_tagging_get_resources" \
    "json" \
    "no" \
    "$AWS_BIN" resourcegroupstaggingapi get-resources \
      --region "$region" \
      --output json
}

write_report_header() {
  report_line "AWS regional audit"
  report_line "Generated at: $(date)"
  report_line "AWS account ID: $ACCOUNT_ID"
  report_line "AWS caller ARN: $CALLER_ARN"
  report_line "AWS caller user ID: $CALLER_USER_ID"
  report_line "Regions: ${REGIONS[*]}"
  report_line "Services: ${SELECTED_SERVICES[*]}"
  report_line "Service filter applied: $( [ "$SERVICE_FILTER_ENABLED" -eq 1 ] && printf 'yes' || printf 'no' )"
  report_line "Output directory: $OUTDIR"
  report_line "Summary JSON: $SUMMARY_JSON"
  report_line "JSON outputs: $JSON_DIR"
  report_line "Text outputs: $TEXT_DIR"
  report_line "Stderr outputs: $STDERR_DIR"
  report_line "Status file: $STATUS_TSV"
  report_line
}

write_summary_section() {
  local total_commands=$((SUCCESS_COUNT + FAILURE_COUNT + SKIPPED_COUNT))
  local scope service_key title output_format billable status exit_code resource_count stdout_path stderr_path command_string

  write_section_separator "Summary"
  report_line "Total commands: $total_commands"
  report_line "Successful commands: $SUCCESS_COUNT"
  report_line "Failed commands: $FAILURE_COUNT"
  report_line "Skipped commands: $SKIPPED_COUNT"
  report_line
  report_line "Likely billable resources with non-zero counts:"

  while IFS="$STATUS_DELIM" read -r scope service_key title output_format billable status exit_code resource_count stdout_path stderr_path command_string; do
    if [ "$billable" = "yes" ] && [ "$status" = "success" ] && [ "$resource_count" != "0" ] && [ "$resource_count" != "n/a" ]; then
      report_line "- [$scope] $title: $resource_count"
    fi
  done < "$STATUS_TSV"

  report_line
  report_line "Failed commands:"
  while IFS="$STATUS_DELIM" read -r scope service_key title output_format billable status exit_code resource_count stdout_path stderr_path command_string; do
    if [ "$status" = "failed" ]; then
      report_line "- [$scope] $title (exit $exit_code)"
      if [ -n "$stderr_path" ] && [ -s "$stderr_path" ]; then
        report_line "  stderr file: $stderr_path"
      fi
    fi
  done < "$STATUS_TSV"

  report_line
  report_line "Skipped commands:"
  while IFS="$STATUS_DELIM" read -r scope service_key title output_format billable status exit_code resource_count stdout_path stderr_path command_string; do
    if [ "$status" = "skipped" ]; then
      report_line "- [$scope] $title"
    fi
  done < "$STATUS_TSV"
}

write_region_overview_section() {
  local region
  local scope service_key title output_format billable status exit_code resource_count stdout_path stderr_path command_string
  local suffix

  write_section_separator "Regional Overview"

  for region in "${REGIONS[@]}"; do
    report_line "$region"
    report_line "------------------------------------------------------------"

    while IFS="$STATUS_DELIM" read -r scope service_key title output_format billable status exit_code resource_count stdout_path stderr_path command_string; do
      if [ "$scope" = "$region" ]; then
        suffix=""
        if [ "$status" = "failed" ]; then
          suffix=" (failed, exit $exit_code)"
        elif [ "$status" = "skipped" ]; then
          suffix=" (skipped)"
        elif [ "$resource_count" != "n/a" ]; then
          suffix=" (count: $resource_count)"
        fi
        report_line "- $title$suffix"
      fi
    done < "$STATUS_TSV"

    report_line
  done
}

write_detailed_results_section() {
  local scope service_key title output_format billable status exit_code resource_count stdout_path stderr_path command_string

  write_section_separator "Detailed Results"

  while IFS="$STATUS_DELIM" read -r scope service_key title output_format billable status exit_code resource_count stdout_path stderr_path command_string; do
    report_line
    report_line "------------------------------------------------------------"
    report_line "$title"
    report_line "Scope: $scope"
    report_line "Service key: $service_key"
    report_line "Billable focus: $billable"
    report_line "Status: $status"
    report_line "Exit code: $exit_code"
    report_line "Resource count: $resource_count"
    report_line "Command: $command_string"
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
        render_stdout_to_report "$output_format" "$stdout_path"
        ;;
      failed)
        report_line "stderr contents:"
        if [ -n "$stderr_path" ] && [ -s "$stderr_path" ]; then
          cat "$stderr_path" >> "$TEXT_REPORT"
        else
          report_line "(no stderr captured)"
        fi
        ;;
      skipped)
        report_line "(skipped by service filter)"
        ;;
    esac

    report_line
  done < "$STATUS_TSV"
}

write_summary_json() {
  local total_commands=$((SUCCESS_COUNT + FAILURE_COUNT + SKIPPED_COUNT))
  local regions_json
  local services_json
  local failed_json
  local skipped_json

  if [ "$HAS_JQ" -ne 1 ]; then
    return 0
  fi

  regions_json="$("$JQ_BIN" -n '$ARGS.positional' --args "${REGIONS[@]}")"
  services_json="$("$JQ_BIN" -n '$ARGS.positional' --args "${SELECTED_SERVICES[@]}")"
  failed_json="$("$JQ_BIN" -Rn --arg delim "$STATUS_DELIM" '
    [inputs
     | select(length > 0)
     | split($delim)
     | {
         scope: .[0],
         service: .[1],
         title: .[2],
         status: .[5],
         exit_code: (.[6] | tonumber? // 0),
         stderr_path: .[9]
       }
     | select(.status == "failed")]
  ' < "$STATUS_TSV")"
  skipped_json="$("$JQ_BIN" -Rn --arg delim "$STATUS_DELIM" '
    [inputs
     | select(length > 0)
     | split($delim)
     | {
         scope: .[0],
         service: .[1],
         title: .[2],
         status: .[5]
       }
     | select(.status == "skipped")]
  ' < "$STATUS_TSV")"

  "$JQ_BIN" -n \
    --arg timestamp "$TIMESTAMP" \
    --arg generated_at "$(date)" \
    --arg output_directory "$OUTDIR" \
    --arg report_path "$TEXT_REPORT" \
    --arg status_path "$STATUS_TSV" \
    --arg summary_path "$SUMMARY_JSON" \
    --arg account_id "$ACCOUNT_ID" \
    --arg caller_arn "$CALLER_ARN" \
    --arg caller_user_id "$CALLER_USER_ID" \
    --argjson selected_regions "$regions_json" \
    --argjson selected_services "$services_json" \
    --argjson service_filter_applied "$( [ "$SERVICE_FILTER_ENABLED" -eq 1 ] && printf 'true' || printf 'false' )" \
    --argjson total_commands "$total_commands" \
    --argjson success_count "$SUCCESS_COUNT" \
    --argjson failure_count "$FAILURE_COUNT" \
    --argjson skipped_count "$SKIPPED_COUNT" \
    --argjson failed_commands "$failed_json" \
    --argjson skipped_commands "$skipped_json" \
    '{
      timestamp: $timestamp,
      generated_at: $generated_at,
      output_directory: $output_directory,
      report_path: $report_path,
      summary_path: $summary_path,
      status_path: $status_path,
      account_id: $account_id,
      caller_arn: $caller_arn,
      caller_user_id: $caller_user_id,
      selected_regions: $selected_regions,
      selected_services: $selected_services,
      service_filter_applied: $service_filter_applied,
      total_commands: $total_commands,
      success_count: $success_count,
      failure_count: $failure_count,
      skipped_count: $skipped_count,
      failed_commands: $failed_commands,
      skipped_commands: $skipped_commands
    }' > "$SUMMARY_JSON"
}

main() {
  parse_args "$@"
  log_console "Writing audit output to: $OUTDIR"
  log_console "Regions: ${REGIONS[*]}"
  log_console "Services: ${SELECTED_SERVICES[*]}"
  collect_global_audits

  local region
  for region in "${REGIONS[@]}"; do
    log_console "Auditing region: $region"
    collect_region_audits "$region"
  done

  load_account_identity
  write_report_header
  write_summary_section
  write_region_overview_section
  write_detailed_results_section
  write_summary_json

  log_console "Finished."
  log_console "Text report: $TEXT_REPORT"
  log_console "Summary JSON: $SUMMARY_JSON"
  log_console "JSON directory: $JSON_DIR"
  log_console "Text directory: $TEXT_DIR"
  log_console "Stderr directory: $STDERR_DIR"
}

main "$@"
