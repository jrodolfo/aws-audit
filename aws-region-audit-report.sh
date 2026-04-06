#!/usr/bin/env bash
set -uo pipefail

DEFAULT_REGIONS=("us-east-1" "us-east-2")
REGIONS=("${DEFAULT_REGIONS[@]}")
TIMESTAMP="$(date +"%Y-%m-%d_%H-%M-%S")"
REPORTS_DIR="reports"
BASE_OUTDIR="$REPORTS_DIR/aws-audit-$TIMESTAMP"
OUTDIR="$BASE_OUTDIR"
STATUS_DELIM=$'\034'

AWS_BIN="${AWS_BIN:-aws}"
JQ_BIN="${JQ_BIN:-jq}"
HAS_JQ=0
SUCCESS_COUNT=0
FAILURE_COUNT=0
RUN_SUFFIX=0

while [ -e "$OUTDIR" ]; do
  RUN_SUFFIX=$((RUN_SUFFIX + 1))
  OUTDIR="${BASE_OUTDIR}-${RUN_SUFFIX}"
done

TEXT_REPORT="$OUTDIR/report.txt"
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
  ./aws-region-audit-report.sh [--regions us-east-1,us-east-2]
  ./aws-region-audit-report.sh [--regions us-east-1 us-east-2]

Options:
  --regions  Override the default region list.
  -h, --help Show this help text.
EOF
}

parse_regions_flag() {
  local value
  local normalized

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --)
        shift
        break
        ;;
      --regions)
        shift
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
  local title="$2"
  local output_format="$3"
  local billable="$4"
  local status="$5"
  local exit_code="$6"
  local resource_count="$7"
  local stdout_path="$8"
  local stderr_path="$9"
  local command_string="${10}"

  printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
    "$scope" \
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
  local title="$2"
  local base_name="$3"
  local output_format="$4"
  local billable="$5"
  shift 5

  local stdout_path
  local stderr_path
  local exit_code=0
  local status="success"
  local resource_count="n/a"
  local command_string=""

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

  printf -v command_string '%q ' "$@"
  command_string="${command_string% }"

  log_console "Running: $title"

  if "$@" >"$stdout_path" 2>"$stderr_path"; then
    status="success"
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
    "STS caller identity" \
    "sts_get_caller_identity" \
    "json" \
    "no" \
    "$AWS_BIN" sts get-caller-identity --output json

  run_audit_cmd \
    "global" \
    "AWS CLI configuration list" \
    "aws_configure_list" \
    "text" \
    "no" \
    "$AWS_BIN" configure list

  run_audit_cmd \
    "global" \
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
    "ECS clusters - $region" \
    "${safe_region}_ecs_list_clusters" \
    "json" \
    "yes" \
    "$AWS_BIN" ecs list-clusters \
      --region "$region" \
      --output json

  run_audit_cmd \
    "$region" \
    "EKS clusters - $region" \
    "${safe_region}_eks_list_clusters" \
    "json" \
    "yes" \
    "$AWS_BIN" eks list-clusters \
      --region "$region" \
      --output json

  run_audit_cmd \
    "$region" \
    "SageMaker domains - $region" \
    "${safe_region}_sagemaker_list_domains" \
    "json" \
    "yes" \
    "$AWS_BIN" sagemaker list-domains \
      --region "$region" \
      --output json

  run_audit_cmd \
    "$region" \
    "SageMaker notebook instances - $region" \
    "${safe_region}_sagemaker_list_notebook_instances" \
    "json" \
    "yes" \
    "$AWS_BIN" sagemaker list-notebook-instances \
      --region "$region" \
      --output json

  run_audit_cmd \
    "$region" \
    "OpenSearch domains - $region" \
    "${safe_region}_opensearch_list_domain_names" \
    "json" \
    "yes" \
    "$AWS_BIN" opensearch list-domain-names \
      --region "$region" \
      --output json

  run_audit_cmd \
    "$region" \
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
  report_line "Regions: ${REGIONS[*]}"
  report_line "Output directory: $OUTDIR"
  report_line "JSON outputs: $JSON_DIR"
  report_line "Text outputs: $TEXT_DIR"
  report_line "Stderr outputs: $STDERR_DIR"
  report_line "Status file: $STATUS_TSV"
  report_line
}

write_summary_section() {
  local total_commands=$((SUCCESS_COUNT + FAILURE_COUNT))
  local status title output_format billable exit_code resource_count stdout_path stderr_path command_string

  write_section_separator "Summary"
  report_line "Total commands: $total_commands"
  report_line "Successful commands: $SUCCESS_COUNT"
  report_line "Failed commands: $FAILURE_COUNT"
  report_line
  report_line "Likely billable resources with non-zero counts:"

  while IFS="$STATUS_DELIM" read -r scope title output_format billable status exit_code resource_count stdout_path stderr_path command_string; do
    if [ "$billable" = "yes" ] && [ "$status" = "success" ] && [ "$resource_count" != "0" ] && [ "$resource_count" != "n/a" ]; then
      report_line "- [$scope] $title: $resource_count"
    fi
  done < "$STATUS_TSV"

  report_line
  report_line "Failed commands:"
  while IFS="$STATUS_DELIM" read -r scope title output_format billable status exit_code resource_count stdout_path stderr_path command_string; do
    if [ "$status" = "failed" ]; then
      report_line "- [$scope] $title (exit $exit_code)"
      if [ -n "$stderr_path" ] && [ -s "$stderr_path" ]; then
        report_line "  stderr file: $stderr_path"
      fi
    fi
  done < "$STATUS_TSV"
}

write_region_overview_section() {
  local region
  local title output_format billable status exit_code resource_count stdout_path stderr_path command_string
  local failure_marker

  write_section_separator "Regional Overview"

  for region in "${REGIONS[@]}"; do
    report_line "$region"
    report_line "------------------------------------------------------------"

    while IFS="$STATUS_DELIM" read -r scope title output_format billable status exit_code resource_count stdout_path stderr_path command_string; do
      if [ "$scope" = "$region" ]; then
        failure_marker=""
        if [ "$status" = "failed" ]; then
          failure_marker=" (failed, exit $exit_code)"
        elif [ "$resource_count" != "n/a" ]; then
          failure_marker=" (count: $resource_count)"
        fi
        report_line "- $title$failure_marker"
      fi
    done < "$STATUS_TSV"

    report_line
  done
}

write_detailed_results_section() {
  local scope title output_format billable status exit_code resource_count stdout_path stderr_path command_string

  write_section_separator "Detailed Results"

  while IFS="$STATUS_DELIM" read -r scope title output_format billable status exit_code resource_count stdout_path stderr_path command_string; do
    report_line
    report_line "------------------------------------------------------------"
    report_line "$title"
    report_line "Scope: $scope"
    report_line "Billable focus: $billable"
    report_line "Status: $status"
    report_line "Exit code: $exit_code"
    report_line "Resource count: $resource_count"
    report_line "Command: $command_string"
    report_line "Stdout: $stdout_path"
    if [ -n "$stderr_path" ]; then
      report_line "Stderr: $stderr_path"
    else
      report_line "Stderr: (empty)"
    fi
    report_line

    if [ "$status" = "success" ]; then
      render_stdout_to_report "$output_format" "$stdout_path"
    else
      report_line "stderr contents:"
      if [ -n "$stderr_path" ] && [ -s "$stderr_path" ]; then
        cat "$stderr_path" >> "$TEXT_REPORT"
      else
        report_line "(no stderr captured)"
      fi
    fi

    report_line
  done < "$STATUS_TSV"
}

main() {
  parse_regions_flag "$@"
  log_console "Writing audit output to: $OUTDIR"
  log_console "Regions: ${REGIONS[*]}"
  collect_global_audits

  local region
  for region in "${REGIONS[@]}"; do
    log_console "Auditing region: $region"
    collect_region_audits "$region"
  done

  write_report_header
  write_summary_section
  write_region_overview_section
  write_detailed_results_section

  log_console "Finished."
  log_console "Text report: $TEXT_REPORT"
  log_console "JSON directory: $JSON_DIR"
  log_console "Text directory: $TEXT_DIR"
  log_console "Stderr directory: $STDERR_DIR"
}

main "$@"
