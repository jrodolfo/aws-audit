#!/usr/bin/env bash
set -eu

service="${1:-}"
command="${2:-}"
metric_name=""
bucket_name=""
filter_id=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --metric-name)
      shift
      metric_name="${1:-}"
      ;;
    --bucket)
      shift
      bucket_name="${1:-}"
      ;;
    --dimensions)
      shift
      while [ "$#" -gt 0 ] && [[ "${1:-}" != --* ]]; do
        case "$1" in
          Name=FilterId,Value=*)
            filter_id="${1#Name=FilterId,Value=}"
            ;;
        esac
        shift || true
      done
      continue
      ;;
  esac
  shift || true
done

case "${service}:${command}:${metric_name}:${filter_id}" in
  "sts:get-caller-identity::")
    printf '%s\n' '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/test","UserId":"test-user"}'
    ;;
  "s3api:get-bucket-location::")
    printf '%s\n' '{"LocationConstraint":"us-east-2"}'
    ;;
  "s3api:get-bucket-website::")
    printf '%s\n' '{"IndexDocument":{"Suffix":"index.html"},"ErrorDocument":{"Key":"404.html"}}'
    ;;
  "s3api:list-bucket-metrics-configurations::")
    printf '%s\n' '{"MetricsConfigurationList":[{"Id":"website-traffic"}]}'
    ;;
  "cloudwatch:list-metrics::")
    cat <<'EOF'
{
  "Metrics": [
    {
      "Namespace": "AWS/S3",
      "MetricName": "BucketSizeBytes",
      "Dimensions": [
        {"Name":"BucketName","Value":"example.com"},
        {"Name":"StorageType","Value":"StandardStorage"}
      ]
    },
    {
      "Namespace": "AWS/S3",
      "MetricName": "NumberOfObjects",
      "Dimensions": [
        {"Name":"BucketName","Value":"example.com"},
        {"Name":"StorageType","Value":"AllStorageTypes"}
      ]
    },
    {
      "Namespace": "AWS/S3",
      "MetricName": "AllRequests",
      "Dimensions": [
        {"Name":"BucketName","Value":"example.com"},
        {"Name":"FilterId","Value":"website-traffic"}
      ]
    },
    {
      "Namespace": "AWS/S3",
      "MetricName": "4xxErrors",
      "Dimensions": [
        {"Name":"BucketName","Value":"example.com"},
        {"Name":"FilterId","Value":"website-traffic"}
      ]
    }
  ]
}
EOF
    ;;
  "cloudwatch:get-metric-statistics:BucketSizeBytes:")
    printf '%s\n' '{"Datapoints":[{"Timestamp":"2026-04-06T00:00:00Z","Average":4096}],"Label":"BucketSizeBytes"}'
    ;;
  "cloudwatch:get-metric-statistics:NumberOfObjects:")
    printf '%s\n' '{"Datapoints":[{"Timestamp":"2026-04-06T00:00:00Z","Average":12}],"Label":"NumberOfObjects"}'
    ;;
  "cloudwatch:get-metric-statistics:AllRequests:website-traffic")
    printf '%s\n' '{"Datapoints":[{"Timestamp":"2026-04-06T00:00:00Z","Sum":25}],"Label":"AllRequests"}'
    ;;
  "cloudwatch:get-metric-statistics:4xxErrors:website-traffic")
    printf '%s\n' '{"Datapoints":[{"Timestamp":"2026-04-06T00:00:00Z","Sum":1}],"Label":"4xxErrors"}'
    ;;
  *)
    printf '%s\n' '{}'
    ;;
esac
