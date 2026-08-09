# LZA Config Validator

A concurrent, S3-backed validation engine for AWS Landing Zone Accelerator (LZA) configuration repositories. It catches config errors in Pull Requests **before** they reach the LZA deployment pipeline — shifting validation left from a 45+ minute pipeline run to a sub-minute PR check.

The engine deliberately mirrors LZA's own conventions (prefix-driven naming, `ACCELERATOR_*` env vocabulary, `yarn validate-config`, permission-boundary support) so it feels like a first-party LZA component. See `docs/lza-native-design.md` for the design rationale.

## Overview

GitHub Actions packages your LZA configuration and AWS CodeBuild executes the validation logic across three layers, wrapping LZA's own validator:

1. **YAML Linting** — Syntax verification via `yamllint`.
2. **Schema & Cross-Reference Validation** — LZA's own `yarn validate-config` run with `ACCELERATOR_STAGE=prepare`, exactly as the deployment pipeline's prepare stage does (checks account/OU references, email uniqueness against real AWS Organizations state).
3. **CDK Synthesis** — Concurrently synthesizes CloudFormation templates for the `prepare`, `security`, and `customizations` stages (dry-run, no deployment).

The engine is **read-only** — it never modifies your AWS environment.

## Architecture

```
GitHub PR ──▶ GitHub Actions ──▶ S3 (config zip) ──▶ CodeBuild ──▶ scripts/validate-config-pr.sh
                                                          │
                                                          ├─ version gate (target vs installed LZA)
                                                          ├─ L1: yamllint
                                                          ├─ Download pre-built LZA source (S3)
                                                          ├─ Assume Synth Role (scoped read-only)
                                                          ├─ L2: yarn validate-config (ACCELERATOR_STAGE=prepare)
                                                          └─ L3: concurrent cdk synth
```

### LZA-native design choices

- **Prefix-driven naming** — Every resource derives from `AcceleratorPrefix` (PascalCase, e.g. `AWSAccelerator-ConfigValidator-Role`), `AcceleratorBucketPrefix` (kebab, e.g. `aws-accelerator-config-validator-<acct>-<region>`), and `AcceleratorSsmPrefix` (`/accelerator/config-validator/*`) — matching `AcceleratorResourceNames`.
- **Pre-built LZA source bundle** — A one-time source-builder CodeBuild project compiles the LZA source and stores a ready-to-run tarball in S3. Validation runs skip `yarn install`/`yarn build`, cutting run time from ~7 min to ~48 sec.
- **Two-role separation** — The CodeBuild role is minimal (S3 read, logs, assume-role). Elevated read-only access (Orgs, DynamoDB, KMS, cross-account) lives in a separate Synth Role, assumed only during validation. Synth-role trust uses LZA's prefixed-ARN / `aws:PrincipalOrgID` condition idiom.
- **Least-privilege Synth Role** — Scoped to `${AcceleratorPrefix}-*` DynamoDB tables, `${AcceleratorSsmPrefix}/*` SSM params, and the `ManagementAccountAccessRole` cross-account role only.
- **Optional permission boundary** — `PermissionBoundaryPolicyName` applies a boundary to every role the stack creates, mirroring LZA's opt-in boundary.
- **SSM advertisement & tagging** — Publishes `${AcceleratorSsmPrefix}/config-validator/{version,validation-project,source-bucket}` and tags every resource `Accelerator=<prefix>`, like every LZA stack.
- **No idle cost** — Pure pay-per-use CodeBuild; ~$4/month at 200 PRs/month, near-zero when idle.

## Repository Layout

```
.
├── lza-config-validator.yaml         # CloudFormation: infra for the validation engine
├── buildspec.yml                     # Thin CodeBuild spec (delegates to the script)
├── scripts/
│   └── validate-config-pr.sh         # 3-layer validation script (mirrors LZA prepare-stage.sh)
├── .github/workflows/validate-pr.yml # Example GitHub Actions workflow
├── docs/                             # Design rationale, roadmap, interim AI prompt
└── example-config/                   # Sample LZA configuration repo layout
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

`lza-config-validator.yaml` is deployed once by the platform team. `buildspec.yml`, `scripts/`, and the workflow are the **distributable tooling** you copy into your real LZA configuration repository (where the config files live at the root). `example-config/` shows what that consumer repo looks like.

## Components

| File | Purpose |
|------|---------|
| `lza-config-validator.yaml` | CloudFormation: S3 buckets, CodeBuild projects, IAM roles, GitHub Actions user, SSM params |
| `scripts/validate-config-pr.sh` | The 3-layer validation script run by CodeBuild (accepts config dir as `$1`) |
| `buildspec.yml` | Thin CodeBuild spec that delegates to the script |
| `.github/workflows/validate-pr.yml` | Example GitHub Actions workflow triggered on PRs |
| `example-config/` | Reference LZA configuration used for testing/demonstration |

## Deployment Instructions

### Step 1: Deploy the CloudFormation Stack
Deploy `lza-config-validator.yaml` in your AWS Management Account (or delegated admin) in your primary LZA region:

```bash
aws cloudformation deploy \
  --stack-name AWSAccelerator-ConfigValidator \
  --template-file lza-config-validator.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      AcceleratorPrefix=AWSAccelerator \
      LzaVersion=v1.16.0 \
      ManagementAccountAccessRole=AWSControlTowerExecution \
  --region us-east-1
```

Parameters (PascalCase, LZA-style, with console labels via `AWS::CloudFormation::Interface`):

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `AcceleratorPrefix` | `AWSAccelerator` | PascalCase prefix for roles/projects (match your installer) |
| `AcceleratorBucketPrefix` | `aws-accelerator` | Lowercase prefix for bucket names |
| `AcceleratorSsmPrefix` | `/accelerator` | SSM path prefix for params + IAM scoping |
| `LzaVersion` | `v1.16.0` | LZA release to validate against |
| `ManagementAccountAccessRole` | `AWSControlTowerExecution` | Cross-account role assumed during synth |
| `OrganizationId` | `''` | Optional; adds `aws:PrincipalOrgID` trust condition |
| `PermissionBoundaryPolicyName` | `''` | Optional boundary applied to all roles |
| `ValidationComputeType` | `BUILD_GENERAL1_MEDIUM` | Validation compute size |
| `SourceBuilderComputeType` | `BUILD_GENERAL1_LARGE` | Source builder compute size |
| `PRZipRetentionDays` | `7` | PR archive retention |

Note the stack outputs:
- `ValidationS3BucketName`
- `SourceS3BucketName`
- `ConfigValidatorProjectName`
- `SourceBuilderProjectName`
- `CredentialsSecretArn` / `CredentialsSecretName` — GitHub Actions credentials are stored in **Secrets Manager**, not in plaintext outputs
- `RetrieveCredentialsCommand` — ready-to-run CLI command to fetch the credentials

### Step 2: Build the Pre-Built LZA Source Bundle
Upload the raw LZA source (no `node_modules`/`dist`) to the source bucket, then run the builder:

```bash
# Upload raw source
tar -czf lza-v1.16.0-src.tar.gz --exclude='.git' --exclude='node_modules' --exclude='dist' -C /path/to/lza-source .
aws s3 cp lza-v1.16.0-src.tar.gz s3://<SourceS3BucketName>/lza-v1.16.0-src.tar.gz

# Build the pre-compiled bundle (compiles + uploads lza-v1.16.0.tar.gz)
aws codebuild start-build --project-name AWSAccelerator-ConfigValidatorSourceBuilder --region us-east-1
```

### Step 3: Add Files to Your Configuration Repository
Copy these into your LZA config repo (preserving the `scripts/` path):
- `scripts/validate-config-pr.sh` (ensure executable: `chmod +x scripts/validate-config-pr.sh`)
- `buildspec.yml`
- `.github/workflows/validate-pr.yml`

### Step 4: Configure GitHub Secrets
Retrieve the GitHub Actions credentials from Secrets Manager (the stack stores them there instead of exposing them as plaintext outputs):

```bash
CREDS=$(aws secretsmanager get-secret-value \
  --secret-id AWSAccelerator-ConfigValidator-GitHubActions \
  --query SecretString --output text)

gh secret set AWS_ACCESS_KEY_ID  --body "$(echo "$CREDS" | jq -r '.AWS_ACCESS_KEY_ID')"
gh secret set AWS_SECRET_ACCESS_KEY --body "$(echo "$CREDS" | jq -r '.AWS_SECRET_ACCESS_KEY')"
gh secret set AWS_REGION --body "us-east-1"
gh secret set S3_BUCKET --body "<ValidationS3BucketName>"
# Only needed if you deployed with a custom AcceleratorPrefix:
# gh secret set CODEBUILD_PROJECT --body "<YourPrefix>-ConfigValidator"
```

### Step 5: Commit and Open a PR
Any PR against `main` that touches `*.yaml`, `*.yml`, `*.json`, `scripts/validate-config-pr.sh`, or `buildspec.yml` triggers the validation workflow automatically.

## Upgrading LZA Versions

1. Update the `LzaVersion` parameter on the CloudFormation stack (this also updates the `${AcceleratorSsmPrefix}/config-validator/version` SSM parameter used by the version gate).
2. Upload the new raw source: `s3://<SourceS3BucketName>/lza-<version>-src.tar.gz`.
3. Run the source builder: `aws codebuild start-build --project-name AWSAccelerator-ConfigValidatorSourceBuilder`.
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
- **LZA-native design** (`lza-native-design.md`) — How this project maps to LZA's own permissioning, naming, and infrastructure conventions; roadmap toward an upstream `@aws-accelerator/config-validator` package.
- **Project 1** (`project-1-error-resolution-agent.md`) — Bedrock-powered automated failure diagnosis with PR-comment fix suggestions.
- **Project 2** (`project-2-guard-rule-agent.md`) — Bedrock agent that infers coding patterns from your codebase and generates cfn-guard rules.
- **Interim** (`codex-prompt-guard-rule-generation.md`) — A ready-to-use AI prompt for generating cfn-guard rules without building infrastructure.
