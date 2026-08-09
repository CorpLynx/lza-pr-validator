# Migration: v1 (LZA-PR-Validator) → v2 (LZA-native Config Validator)

This document captures everything that changed when the validator was revamped to align with Landing Zone Accelerator's own conventions (see `lza-native-design.md` for the rationale). It doubles as a changelog and an operator migration runbook.

## Summary

The validator was re-based on LZA's conventions so it reads like a first-party component: prefix-driven resource names, PascalCase CloudFormation parameters, `ACCELERATOR_*` environment vocabulary, the `aws:PrincipalOrgID` + prefixed-ARN IAM idiom, an optional permission boundary, SSM self-advertisement, and resource tagging. Functionality is unchanged — same three validation layers — but everything is renamed and restructured.

## File-level changes

| v1 | v2 | Notes |
|----|----|-------|
| `lza-validator-pipeline.yaml` | `lza-config-validator.yaml` | Renamed + fully revamped template |
| `validate-lza.sh` (root) | `scripts/validate-config-pr.sh` | Moved into `scripts/`, mirrors LZA's `prepare-stage.sh` |
| `buildspec.yml` | `buildspec.yml` | Slimmed to delegate to the script |
| `.github/workflows/validate-pr.yml` | (same path) | Configurable project name, updated path filters |

## CloudFormation parameter changes

v1 used Hungarian `p`-prefixed parameters. v2 uses PascalCase with no prefix (LZA convention) plus `AWS::CloudFormation::Interface` labels/groups.

| v1 parameter | v2 parameter | Change |
|--------------|--------------|--------|
| `pLZAVersion` | `LzaVersion` | Renamed |
| `pAcceleratorResourcePrefix` | `AcceleratorPrefix` | Renamed; now drives all resource names |
| `pAcceleratorSsmPrefix` | `AcceleratorSsmPrefix` | Renamed |
| (n/a) | `AcceleratorBucketPrefix` | New — kebab-case bucket prefix |
| `pCrossAccountRoleName` | `ManagementAccountAccessRole` | Renamed to LZA's term |
| `pValidationBucketName` / `pSourceBucketName` | (removed) | Bucket names now derived from prefix, not overridable |
| `pValidationProjectName` / `pSourceBuilderProjectName` | (removed) | Project names now derived from prefix |
| `pCodeBuildRoleName` / `pSynthRoleName` / `pSourceBuilderRoleName` | (removed) | Role names now derived from prefix |
| `pGitHubActionsUserName` / `pCredentialsSecretName` | (removed) | Derived from prefix |
| `pValidationComputeType` | `ValidationComputeType` | Renamed |
| `pSourceBuilderComputeType` | `SourceBuilderComputeType` | Renamed |
| `pPRZipRetentionDays` | `PRZipRetentionDays` | Renamed |
| (n/a) | `OrganizationId` | New — optional; enables `aws:PrincipalOrgID` trust condition |
| (n/a) | `PermissionBoundaryPolicyName` | New — optional boundary on all roles |

## Resource name changes

All names now derive from `AcceleratorPrefix` (default `AWSAccelerator`) / `AcceleratorBucketPrefix` (default `aws-accelerator`).

| Resource | v1 name | v2 name |
|----------|---------|---------|
| CloudFormation stack | `LZA-PR-Validator` | `AWSAccelerator-ConfigValidator` |
| CodeBuild (validation) | `LZA-PR-Validator` | `AWSAccelerator-ConfigValidator` |
| CodeBuild (source builder) | `LZA-Source-Builder` | `AWSAccelerator-ConfigValidatorSourceBuilder` |
| CodeBuild role | `LZA-PR-Validator-CodeBuild-Role` | `AWSAccelerator-ConfigValidator-Role` |
| Synth role | `LZA-PR-Validator-Synth-Role` | `AWSAccelerator-ConfigValidator-Synth-Role` |
| Source builder role | `LZA-Source-Builder-Role` | `AWSAccelerator-ConfigValidator-SourceBuilder-Role` |
| GitHub Actions user | `GHA-LZA-PR-Validator-User` | `AWSAccelerator-ConfigValidator-GitHubActions-User` |
| Credentials secret | `lza-pr-validator/github-actions-credentials` | `AWSAccelerator-ConfigValidator-GitHubActions` |
| Validation bucket | `lza-pr-validator-prvalidationbucket-<hash>` | `aws-accelerator-config-validator-<account>-<region>` |
| Source bucket | `lza-pr-validator-lzasourcebucket-<hash>` | `aws-accelerator-config-validator-source-<account>-<region>` |

Buckets moved from CloudFormation auto-generated names to LZA's deterministic `<prefix>-<purpose>-<account>-<region>` pattern.

## IAM changes

- **Least-privilege retained**, plus LZA's condition idiom: the synth role's trust policy now restricts assumption to `${AcceleratorPrefix}-*` principal ARNs (`ArnLike` on `aws:PrincipalArn`), and — when `OrganizationId` is supplied — adds `StringEquals` on `aws:PrincipalOrgID`.
- **Optional permission boundary**: `PermissionBoundaryPolicyName`, when set, attaches `arn:${Partition}:iam::${Account}:policy/<name>` to every role (and the GitHub Actions user) the stack creates.
- **Scoping now prefix-parameterized**: DynamoDB scoped to `${AcceleratorPrefix}-*` tables; SSM scoped to `${AcceleratorSsmPrefix}/*`; cross-account assume scoped to `${ManagementAccountAccessRole}`.
- **New grant**: the CodeBuild service role got `ssm:GetParameter(s)` on `${AcceleratorSsmPrefix}/config-validator/version` — required because that parameter is consumed as a `PARAMETER_STORE` CodeBuild env var (resolved by the service role, not the synth role).

## Environment variable changes (buildspec / script)

| v1 | v2 |
|----|----|
| `LZA_VERSION` | `ACCELERATOR_VERSION` |
| `LZA_SOURCE_BUCKET` | `ACCELERATOR_SOURCE_BUCKET` |
| `LZA_SYNTH_ROLE_ARN` | `ACCELERATOR_SYNTH_ROLE_ARN` |
| `AWS_PARTITION` | `PARTITION` |
| (n/a) | `ACCELERATOR_PREFIX` |
| (n/a) | `ACCELERATOR_SSM_PARAM_NAME_PREFIX` |
| (n/a) | `ACCELERATOR_PIPELINE_VERSION` (from Parameter Store) |

## Behavioral changes (validation script)

- **Version gate added**: fails fast if the validator's target LZA version doesn't match the installed version (`ACCELERATOR_PIPELINE_VERSION` from SSM) — mirrors `prepare-stage.sh`.
- **`ACCELERATOR_STAGE=prepare`** is now set when invoking `yarn validate-config`, so validation runs the identical code path as the real pipeline's prepare stage (including DynamoDB config-table lookups against the deployed environment).
- **`LOG_LEVEL=info`** on the validate-config call, matching LZA.
- Logic moved out of the root script into `scripts/validate-config-pr.sh`; `buildspec.yml` now just calls it (LZA factors logic into `scripts/*.sh`).

## New: SSM self-advertisement & tagging

- Publishes `${AcceleratorSsmPrefix}/config-validator/{version, validation-project, source-bucket}` so the validator is discoverable like every LZA stack.
- Tags every resource `Accelerator=<AcceleratorPrefix>`.

## New: Secrets Manager for credentials

(Carried over from late v1.) GitHub Actions credentials are stored in a Secrets Manager secret (`AWSAccelerator-ConfigValidator-GitHubActions`) rather than exposed as plaintext stack outputs. Outputs expose only the secret ARN/name and a retrieval command.

## Deployment fixes discovered during cutover

1. **`DependsOn: ConfigValidatorRole`** added to the synth role — its trust policy names the CodeBuild role by ARN, so the CodeBuild role must exist first or IAM rejects the principal ("Invalid principal in policy"). v1 worked by luck of resource ordering.
2. **CodeBuild role `ssm:GetParameters`** on the version param — the `PARAMETER_STORE` env var is resolved by the CodeBuild service role during `DOWNLOAD_SOURCE`, before the synth role is assumed.

## Operator migration runbook (what was executed)

1. Deployed `AWSAccelerator-ConfigValidator` from `lza-config-validator.yaml` alongside the old stack (no name collisions — all resources renamed).
2. Server-side copied both LZA source bundles (`lza-v1.16.0.tar.gz`, `lza-v1.16.0-src.tar.gz`) from the old source bucket to the new one.
3. Updated GitHub repo secrets:
   - `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` — from the new Secrets Manager secret
   - `S3_BUCKET` → `aws-accelerator-config-validator-<account>-<region>`
   - `CODEBUILD_PROJECT` → `AWSAccelerator-ConfigValidator` (new secret consumed by the workflow)
4. Ran a parity build on the new project against `example-config` — all three layers passed (version gate, yamllint, validate-config with live DynamoDB/Orgs lookups, concurrent synth).
5. Retired the old stack: emptied both versioned buckets (all versions + delete markers), then `delete-stack`.

## Rollback

If needed, redeploy the old template from git history (commit prior to the LZA-native revamp), re-upload source bundles to the recreated source bucket, and restore the prior GitHub secrets. The new and old stacks use disjoint resource names, so they can coexist during a rollback window.
