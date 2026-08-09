# LZA Pull Request Validation Engine

A concurrent, S3-backed validation pipeline for AWS Landing Zone Accelerator (LZA) configuration repositories. It catches config errors in Pull Requests **before** they reach the LZA deployment pipeline — shifting validation left from a 45+ minute pipeline run to a sub-minute PR check.

## Overview

GitHub Actions packages your LZA configuration and AWS CodeBuild executes the validation logic across four layers:

1. **YAML Linting** — Syntax verification via `yamllint`.
2. **Schema Validation** — Structural and cross-reference validation via LZA's `yarn validate-config` (checks account references, OU references, email uniqueness against the real AWS Organizations state).
3. **CDK Synthesis** — Concurrently synthesizes CloudFormation templates for the `prepare`, `security`, and `customizations` stages (dry-run, no deployment).
4. **CFN Guard (optional)** — Policy compliance against org coding standards (see `docs/project-2-guard-rule-agent.md`).

The engine is **read-only** — it never modifies your AWS environment.

## Architecture

```
GitHub PR ──▶ GitHub Actions ──▶ S3 (config zip) ──▶ CodeBuild ──▶ validate-lza.sh
                                                          │
                                                          ├─ L1: yamllint
                                                          ├─ Download pre-built LZA source (S3)
                                                          ├─ Assume Synth Role (scoped read-only)
                                                          ├─ L2: yarn validate-config
                                                          └─ L3: concurrent cdk synth
```

### Key design choices

- **Pre-built LZA source bundle** — A one-time `LZA-Source-Builder` CodeBuild project compiles the LZA source (128 packages) and stores a ready-to-run tarball in S3. Validation runs skip `yarn install`/`yarn build` entirely, cutting run time from ~7 min to ~48 sec.
- **Two-role separation** — The CodeBuild role is minimal (S3 read, logs, assume-role). Elevated AWS access (Orgs, DynamoDB, KMS, cross-account) lives in a separate `Synth Role` assumed only during validation.
- **Least-privilege Synth Role** — Scoped to `AWSAccelerator-*` DynamoDB tables, `/accelerator/*` SSM params, and `AWSControlTowerExecution` cross-account role only.
- **No idle cost** — Pure pay-per-use CodeBuild; ~$4/month at 200 PRs/month, near-zero when idle.

## Repository Layout

```
.
├── lza-validator-pipeline.yaml      # CloudFormation: infra for the validation engine
├── validate-lza.sh                  # 3-layer validation script run by CodeBuild
├── buildspec.yml                    # CodeBuild build specification
├── .github/workflows/validate-pr.yml # Example GitHub Actions workflow
├── docs/                            # Roadmap + interim AI prompt
└── example-config/                  # Sample LZA configuration repo layout
    ├── accounts-config.yaml
    ├── global-config.yaml
    ├── iam-config.yaml
    ├── network-config.yaml
    ├── organization-config.yaml
    ├── security-config.yaml
    ├── customizations-config.yaml
    ├── cloudformation-templates/
    ├── iam-policies/
    ├── kms/
    ├── resource-control-policies/
    └── service-control-policies/
```

The four files at the root (`lza-validator-pipeline.yaml`, `validate-lza.sh`, `buildspec.yml`, and the workflow) are the **distributable tooling**. Copy the script, buildspec, and workflow into your real LZA configuration repository (where the config files live at the root). `example-config/` shows what that consumer repo looks like.

## Components

| File | Purpose |
|------|---------|
| `lza-validator-pipeline.yaml` | CloudFormation: S3 buckets, CodeBuild projects, IAM roles, GitHub Actions user |
| `validate-lza.sh` | The 3-layer validation script run by CodeBuild (accepts config dir as `$1`) |
| `buildspec.yml` | CodeBuild build specification |
| `.github/workflows/validate-pr.yml` | Example GitHub Actions workflow triggered on PRs |
| `example-config/` | Reference LZA configuration used for testing/demonstration |

## Deployment Instructions

### Step 1: Deploy the CloudFormation Stack
Deploy `lza-validator-pipeline.yaml` in your AWS Management Account (or delegated admin) in your primary LZA region:

```bash
aws cloudformation deploy \
  --stack-name LZA-PR-Validator \
  --template-file lza-validator-pipeline.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides LZAVersion=v1.16.0 \
  --region us-east-1
```

The stack is parameterized — override any of the resource names, compute sizes, LZA version, accelerator prefix, or cross-account role name at deploy time (all parameters are prefixed `p`). Leave bucket-name parameters blank to auto-generate.

Note the stack outputs:
- `ValidationS3BucketName`
- `LZASourceBucketName`
- `CodeBuildProjectName`
- `SourceBuilderProjectName`
- `CredentialsSecretArn` / `CredentialsSecretName` — GitHub Actions credentials are stored in **Secrets Manager**, not in plaintext outputs
- `RetrieveCredentialsCommand` — ready-to-run CLI command to fetch the credentials

### Step 2: Build the Pre-Built LZA Source Bundle
Upload the raw LZA source (no `node_modules`/`dist`) to the source bucket, then run the builder:

```bash
# Upload raw source
tar -czf lza-v1.16.0-src.tar.gz --exclude='.git' --exclude='node_modules' --exclude='dist' -C /path/to/lza-source .
aws s3 cp lza-v1.16.0-src.tar.gz s3://<LZASourceBucketName>/lza-v1.16.0-src.tar.gz

# Build the pre-compiled bundle (compiles + uploads lza-v1.16.0.tar.gz)
aws codebuild start-build --project-name LZA-Source-Builder --region us-east-1
```

### Step 3: Add Files to Your Configuration Repository
Copy these into the **root** of your LZA config repo:
- `validate-lza.sh` (ensure executable: `chmod +x validate-lza.sh`)
- `buildspec.yml`
- `.github/workflows/validate-pr.yml`

### Step 4: Configure GitHub Secrets
Retrieve the GitHub Actions credentials from Secrets Manager (the stack stores them there instead of exposing them as plaintext outputs):

```bash
CREDS=$(aws secretsmanager get-secret-value \
  --secret-id lza-pr-validator/github-actions-credentials \
  --query SecretString --output text)

ACCESS_KEY_ID=$(echo "$CREDS" | jq -r '.AWS_ACCESS_KEY_ID')
SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.AWS_SECRET_ACCESS_KEY')

gh secret set AWS_ACCESS_KEY_ID --body "$ACCESS_KEY_ID"
gh secret set AWS_SECRET_ACCESS_KEY --body "$SECRET_ACCESS_KEY"
gh secret set AWS_REGION --body "us-east-1"
gh secret set S3_BUCKET --body "<ValidationS3BucketName>"
```

### Step 5: Commit and Open a PR
Any PR against `main` that touches `*.yaml`, `*.yml`, `*.json`, `validate-lza.sh`, or `buildspec.yml` triggers the validation workflow automatically.

## Upgrading LZA Versions

1. Update the `LZAVersion` parameter on the CloudFormation stack.
2. Upload the new raw source: `s3://<bucket>/lza-<version>-src.tar.gz`.
3. Run the source builder: `aws codebuild start-build --project-name LZA-Source-Builder`.
4. Validation runs automatically pick up the new pre-built bundle.

## Cost

Pay-per-use, no always-on infrastructure:

| PR Volume | Approx. Monthly Cost |
|-----------|----------------------|
| 50 PRs | ~$1.50 |
| 200 PRs | ~$4 |
| 1,000 PRs | ~$15 |

Idle cost (no PRs) is ~$0.05/month for S3 storage. The validation project runs on `BUILD_GENERAL1_MEDIUM`; the source builder uses `BUILD_GENERAL1_LARGE` (runs only on version bumps).

## Roadmap

Future enhancements documented in `docs/`:
- **Project 1** (`project-1-error-resolution-agent.md`) — Bedrock-powered automated failure diagnosis with PR-comment fix suggestions.
- **Project 2** (`project-2-guard-rule-agent.md`) — Bedrock agent that infers coding patterns from your codebase and generates cfn-guard rules.
- **Interim** (`codex-prompt-guard-rule-generation.md`) — A ready-to-use AI prompt for generating cfn-guard rules without building infrastructure.
