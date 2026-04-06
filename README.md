# AWS Region Audit

Shell-based AWS audit helper for checking common resources across AWS regions, defaulting to `us-east-1` and `us-east-2`.

It is designed for a practical cleanup workflow:
- compare resources across one or more regions
- spot likely billable resources first
- keep raw command output for later inspection
- continue running even when some AWS services, permissions, or endpoints fail

## What It Produces

Each run writes a timestamped folder under `reports/`, for example:

```text
reports/aws-audit-2026-04-06_16-34-25/
```

That folder contains:
- `report.txt`: human-readable summary and detailed results
- `summary.json`: machine-readable run summary with counts and failed/skipped commands
- `json/`: raw JSON outputs for successful JSON commands
- `text/`: raw text outputs for text-based commands
- `stderr/`: stderr captured from failed commands
- `meta/status.tsv`: machine-readable command status metadata

The `reports/` directory is ignored by Git so audit output does not get committed.

## Requirements

- macOS or another Bash-compatible environment
- AWS CLI v2
- `jq`
- valid AWS credentials

## Usage

Run the audit:

```bash
make audit
```

Run the audit for specific regions through `make`:

```bash
make audit REGIONS="us-east-2"
```

Or:

```bash
make audit REGIONS="us-east-1 us-east-2"
```

Limit the audit to specific service groups:

```bash
make audit SERVICES="sagemaker ec2"
```

Run the script directly with the default regions:

```bash
./aws-region-audit-report.sh
```

Override the regions:

```bash
./aws-region-audit-report.sh --regions us-east-1 us-east-2
```

Or:

```bash
./aws-region-audit-report.sh --regions us-east-1,us-east-2
```

Filter by service groups:

```bash
./aws-region-audit-report.sh --services sagemaker,ec2
```

Run local tests:

```bash
make test
```

Check script syntax:

```bash
make lint
```

Show available targets:

```bash
make help
```

## AWS Services Covered

The script currently checks:
- STS
- S3
- EC2 instances
- EBS volumes
- Elastic IPs
- VPCs
- subnets
- security groups
- ELBv2
- RDS
- Lambda
- ECS
- EKS
- SageMaker domains
- SageMaker notebook instances
- OpenSearch
- Secrets Manager
- CloudWatch Logs
- Resource Groups Tagging API

Service filter keys:
- `sts`
- `aws-config`
- `s3`
- `ec2`
- `elbv2`
- `rds`
- `lambda`
- `ecs`
- `eks`
- `sagemaker`
- `opensearch`
- `secretsmanager`
- `logs`
- `tagging`

## Notes

- Regional commands use explicit `--region` values.
- The default regions are `us-east-1` and `us-east-2`, but you can override them with `--regions`.
- `make audit` also accepts `REGIONS="..."` and `SERVICES="..."` and passes them through to the script.
- Skipped commands are recorded explicitly when you use `--services`.
- The script is intentionally defensive and continues after individual command failures.
- If AWS permissions are missing or a service is unavailable, the failure is recorded in the report and under `stderr/`.
