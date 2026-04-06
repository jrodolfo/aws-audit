#!/usr/bin/env bash
set -eu

service="${1:-}"
command="${2:-}"

if [ -n "${MOCK_FAIL_SERVICE:-}" ] && [ "$service" = "$MOCK_FAIL_SERVICE" ]; then
  printf 'mock failure for service: %s\n' "$service" >&2
  exit 42
fi

case "${service}:${command}" in
  "sts:get-caller-identity")
    printf '%s\n' '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/test","UserId":"test-user"}'
    ;;
  "configure:list")
    cat <<'EOF'
NAME       : VALUE                    : TYPE             : LOCATION
profile    : <not set>                : None             : None
access_key : ****************TEST     : shared-credentials-file :
secret_key : ****************TEST     : shared-credentials-file :
region     : us-east-2                : config-file      : ~/.aws/config
EOF
    ;;
  "s3api:list-buckets")
    printf '%s\n' '[{"Name":"example-bucket","CreationDate":"2026-04-06T00:00:00Z"}]'
    ;;
  "ec2:describe-instances")
    printf '%s\n' '[{"Id":"i-1234567890abcdef0","State":"running","Type":"t3.micro","Name":"example","LaunchTime":"2026-04-06T00:00:00Z"}]'
    ;;
  "ec2:describe-volumes")
    printf '%s\n' '[{"Id":"vol-1234567890abcdef0","Size":8,"State":"available","Type":"gp3","Encrypted":true}]'
    ;;
  "ec2:describe-addresses")
    printf '%s\n' '[]'
    ;;
  "ec2:describe-vpcs")
    printf '%s\n' '[{"VpcId":"vpc-12345678","CidrBlock":"10.0.0.0/16","IsDefault":true,"State":"available"}]'
    ;;
  "ec2:describe-subnets")
    printf '%s\n' '[{"SubnetId":"subnet-12345678","VpcId":"vpc-12345678","CidrBlock":"10.0.1.0/24","AvailableIpAddressCount":251}]'
    ;;
  "ec2:describe-security-groups")
    printf '%s\n' '[{"GroupId":"sg-12345678","GroupName":"default","VpcId":"vpc-12345678","Description":"default group"}]'
    ;;
  "elbv2:describe-load-balancers")
    printf '%s\n' '[]'
    ;;
  "rds:describe-db-instances")
    printf '%s\n' '[]'
    ;;
  "lambda:list-functions")
    printf '%s\n' '[{"Name":"example-function","Runtime":"python3.12","LastModified":"2026-04-06T00:00:00Z","MemorySize":128}]'
    ;;
  "ecs:list-clusters")
    printf '%s\n' '[]'
    ;;
  "eks:list-clusters")
    printf '%s\n' '[]'
    ;;
  "sagemaker:list-domains")
    printf '%s\n' '[{"DomainId":"d-1234567890ab","DomainName":"studio-domain","Status":"InService"}]'
    ;;
  "sagemaker:list-notebook-instances")
    printf '%s\n' '[]'
    ;;
  "opensearch:list-domain-names")
    printf '%s\n' '[]'
    ;;
  "secretsmanager:list-secrets")
    printf '%s\n' '[{"Name":"example-secret","LastChangedDate":"2026-04-06T00:00:00Z","PrimaryRegion":"us-east-2"}]'
    ;;
  "logs:describe-log-groups")
    printf '%s\n' '[{"Name":"/aws/lambda/example-function","StoredBytes":1024,"RetentionInDays":14}]'
    ;;
  "resourcegroupstaggingapi:get-resources")
    printf '%s\n' '{"ResourceTagMappingList":[]}'
    ;;
  *)
    printf '%s\n' '{}'
    ;;
esac
