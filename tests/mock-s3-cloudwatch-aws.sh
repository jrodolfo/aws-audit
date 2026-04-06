#!/usr/bin/env bash
set -eu

service="${1:-}"
command="${2:-}"
metric_name=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --metric-name)
      shift
      metric_name="${1:-}"
      ;;
  esac
  shift || true
done

case "${service}:${command}:${metric_name}" in
  "s3api:get-bucket-location:")
    printf '%s\n' '{"LocationConstraint":"us-east-2"}'
    ;;
  "s3api:get-bucket-website:")
    printf '%s\n' '{"IndexDocument":{"Suffix":"index.html"},"ErrorDocument":{"Key":"404.html"}}'
    ;;
  "cloudwatch:list-metrics:")
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
        {"Name":"FilterId","Value":"EntireBucket"}
      ]
    },
    {
      "Namespace": "AWS/S3",
      "MetricName": "4xxErrors",
      "Dimensions": [
        {"Name":"BucketName","Value":"example.com"},
        {"Name":"FilterId","Value":"EntireBucket"}
      ]
    }
  ]
}
EOF
    ;;
  "cloudwatch:get-metric-statistics:BucketSizeBytes")
    printf '%s\n' '{"Datapoints":[{"Timestamp":"2026-04-06T00:00:00Z","Average":4096}],"Label":"BucketSizeBytes"}'
    ;;
  "cloudwatch:get-metric-statistics:NumberOfObjects")
    printf '%s\n' '{"Datapoints":[{"Timestamp":"2026-04-06T00:00:00Z","Average":12}],"Label":"NumberOfObjects"}'
    ;;
  "cloudwatch:get-metric-statistics:AllRequests")
    printf '%s\n' '{"Datapoints":[{"Timestamp":"2026-04-06T00:00:00Z","Sum":25}],"Label":"AllRequests"}'
    ;;
  "cloudwatch:get-metric-statistics:4xxErrors")
    printf '%s\n' '{"Datapoints":[{"Timestamp":"2026-04-06T00:00:00Z","Sum":1}],"Label":"4xxErrors"}'
    ;;
  *)
    printf '%s\n' '{}'
    ;;
esac
