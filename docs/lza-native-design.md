# Making the Validator "LZA-Native": Design Recommendations

Goal: restructure the PR validator so it looks and behaves like a first-party LZA component — as if it shipped in an LZA 1.20 release. This document reviews how LZA actually structures permissioning, naming, and infrastructure (grounded in the v1.16 source under `lza-source/`), then maps each convention to a concrete recommendation.

---

## Part 1 — How LZA Does It (observed conventions)

### 1.1 Everything derives from one prefix, expanded into case variants
LZA never hardcodes resource names. A single raw prefix (`AWSAccelerator`, default) is expanded by `setResourcePrefixes()` (`accelerator/utils/app-utils.ts`) into a typed `AcceleratorResourcePrefixes` object with per-family casing:

| Variant | Value (default) | Used for |
|---------|-----------------|----------|
| `accelerator` | `AWSAccelerator` | IAM roles, CodeBuild, CodePipeline, DynamoDB, log groups (PascalCase) |
| `bucketName` | `aws-accelerator` | S3 buckets (kebab-case) |
| `kmsAlias` | `alias/accelerator` | KMS aliases |
| `ssmParamName` | `/accelerator` | SSM parameter paths |
| `snsTopicName`, `secretName`, `repoName`, `databaseName`, `trailLogName` | ... | respective services |

The installer validates the prefix via a `Custom::GetPrefixes` resource (`installer/lib/resource-name-prefixes.ts`): cannot start with `aws`/`ssm`, immutable after first deploy (persisted to SSM `/accelerator/lza-prefix`), max length 15.

### 1.2 A single naming registry
`AcceleratorResourceNames` (`accelerator/lib/accelerator-resource-names.ts`) is the canonical source for every role name, KMS alias, SSM path, and bucket prefix. Patterns:
- Roles: `${prefix}-<Purpose>-Role` (e.g. `AWSAccelerator-CrossAccount-SsmParameter-Role`)
- KMS aliases: `alias/accelerator/<domain>/<key>` (e.g. `alias/accelerator/kms/s3/key`)
- SSM: `/accelerator/<domain>/<resource>/<attr>` (e.g. `/accelerator/kms/key-arn`)
- Buckets: `aws-accelerator-<purpose>-<accountId>-<region>`

### 1.3 The least-privilege idiom: org-id + prefixed-role-ARN conditions
Where a resource ARN wildcard is unavoidable (KMS, `ssm:DescribeParameters`), LZA constrains with **conditions** rather than broad principals. The recurring pattern (`key-stack.ts`, `accelerator-stack.ts`):
```
conditions: {
  StringEquals: { 'aws:PrincipalOrgID': <orgId> },
  ArnLike:      { 'aws:PrincipalARN': ['arn:${partition}:iam::*:role/AWSAccelerator-*'] }
}
```
Two reusable helpers standardize this: `getPrincipalOrgIdCondition(orgId)` (falls back to `aws:PrincipalAccount` in aws-cn / orgs-disabled) and `getOrgPrincipals(orgId, withPrefixCondition)`.

### 1.4 Cross-account access via well-known named roles
- Runtime STS: assume `managementAccountAccessRole` (default `AWSControlTowerExecution`).
- CDK deploys: `${prefix}-Deployment-Role` (member) / `${prefix}-Management-Deployment-Role` (management), created in the bootstrap stack, trust = `AccountPrincipal(managementAccount)` + `cloudformation.amazonaws.com`.
- Trust policies for resource-sharing roles use `PrincipalWithConditions` restricting to org-id + prefixed-role ARNs.

### 1.5 Permission boundaries as an opt-in CDK Aspect
`PermissionsBoundaryAspect` (`accelerator/lib/accelerator-aspects.ts`) visits every `AWS::IAM::Role`, reads `process.env['ACCELERATOR_PERMISSION_BOUNDARY']`, applies the boundary only in the pipeline account, and won't overwrite an existing boundary. The installer has a parallel `installerPermissionBoundary` aspect.

### 1.6 KMS keys: rotation, retain, org-scoped policies, ARN → SSM
`createAcceleratorKey` (`key-stack.ts`): `enableKeyRotation: true`, `removalPolicy: RETAIN_ON_UPDATE_OR_DELETE`, alias/description from the registry, an `AnyPrincipal` statement gated by the org-id + prefix condition (deliberate — scales to thousands of accounts), per-service-principal statements, then the key ARN is pushed to SSM for cross-stack consumption.

### 1.7 SSM parameters are the cross-stack/account sharing bus
Stacks defer parameter creation into a `this.ssmParameters` array, materialized later. Paths come from the registry or the typed `SsmParameterPath` / `SsmResourceType` helper. Cross-account reads flow through `CrossAccountAcceleratorSsmParamAccessRole`.

### 1.8 CodeBuild conventions (pipeline.ts, tester-pipeline.ts, installer-stack.ts)
- Image `LinuxBuildImage.STANDARD_7_0`, `ComputeType.LARGE` (tester uses `MEDIUM`), `privileged: false`.
- `cache: Cache.local(LocalCacheMode.SOURCE)`.
- Buildspec is **always inline** via `BuildSpec.fromObjectToYaml({ version: 0.2, phases: {...} })` — never a checked-in `buildspec.yml`.
- Install phase = a single `getNodeRuntimeActivationCommand()` (activates pre-baked Node via PATH instead of `runtime-versions`, saves ~60s/build).
- Heavy logic lives in checked-in `scripts/*.sh` (e.g. `prepare-stage.sh`) invoked from the build phase.
- `NODE_OPTIONS: '--max_old_space_size=12288 --no-warnings'`, `LOG_LEVEL`, and the full `ACCELERATOR_*` env-var set are passed in.

### 1.9 Config validation is a real, structured subsystem
`yarn validate-config` → `accelerator/lib/config-validator.ts`: loads all 8 configs (with `setExternalManagementAccountCredentials` so cross-reference checks hit real Organizations), runs one validator class per file from `config/validator/`, then `processErrors()` exits non-zero unless `globalConfig.cdkOptions.skipStaticValidation`. There is ALSO JSON-schema validation (ajv against schemas generated by `ts-json-schema-generator`).

### 1.10 CloudFormation parameter conventions
Installer params are **PascalCase with no Hungarian prefix** (`RepositorySource`, `AcceleratorPrefix`, `ControlTowerEnabled`). Human labels + grouping come from `AWS::CloudFormation::Interface` (`ParameterGroups`/`ParameterLabels`). Conditional requirements use `cdk.CfnRule` with `addAssertion`.

### 1.11 Stack naming, tagging, versioning
- Stacks: `AWSAccelerator-<Type>Stack-<accountId>-<region>` (from `AcceleratorStackNames`).
- Tagging: `addAcceleratorTags()` applies an `Accelerator=<prefix>` tag (plus `Accel-P` on security groups) to every resource, partition-aware.
- Version: single source of truth is `source/package.json` `version`, mirrored to SSM `SsmParamAcceleratorVersion` and stack outputs.

### 1.12 Precedent: the diagnostics-pack and tester are bundled auxiliary components
The `diagnostics-pack` stage deploys during the installer, and the `tester` package has its own `TesterPipeline` that mirrors the main pipeline exactly. Both are strong precedents for an auxiliary "validator" component shipping inside LZA.

---

## Part 2 — Gap Analysis (current validator vs LZA-native)

| Area | Current validator | LZA-native target | Gap |
|------|-------------------|-------------------|-----|
| Authoring | Raw CloudFormation YAML | CDK TypeScript in `@aws-accelerator/*` | Large — but raw CFN is acceptable for an installer-style entry stack |
| Naming | Hardcoded `LZA-PR-Validator-*` | Prefix-driven from `AcceleratorResourceNames` | Adopt `${prefix}-ConfigValidator-*` |
| CFN params | `p`-prefixed (pValidationBucketName) | PascalCase, no prefix + Interface labels | **Rename** — drop the `p` prefix |
| IAM scoping | Resource ARNs + account-scoped | Add org-id + prefixed-role-ARN conditions | Add the org-id/`ArnLike` condition idiom |
| Cross-account role | Param `pCrossAccountRoleName` | `managementAccountAccessRole` semantics | Rename/align to LZA's term |
| Permission boundary | None | Opt-in aspect / CFN param `PermissionBoundaryPolicyName` | Add optional boundary |
| KMS | AES256 SSE only | Accelerator CMK + rotation + org policy | Optionally use a validator CMK |
| SSM | None | Publish version + resource ARNs to `/accelerator/...` | Add SSM outputs |
| Buildspec | Checked-in `buildspec.yml` | Inline `fromObjectToYaml` + `scripts/*.sh` | Move logic into scripts; keep buildspec thin |
| Node setup | `runtime-versions: nodejs: 22` | `getNodeRuntimeActivationCommand()` (PATH) | Match to save ~60s |
| Validation logic | Custom `validate-lza.sh` (yamllint + validate-config + synth) | Reuse `yarn validate-config` directly | Already aligned in L2; L1/L3 are additive extensions |
| Env vars | `LZA_*` custom names | `ACCELERATOR_*` names | Rename to LZA's env-var vocabulary |
| Tagging | None | `Accelerator=<prefix>` tag on all resources | Add tags |
| Versioning | `pLZAVersion` param | package.json → SSM param pattern | Align |
| Credentials | Secrets Manager (GHA user) | GitHub via CodeConnection like installer | Prefer CodeConnection over long-lived keys |

---

## Part 3 — Recommendations

### R1. Reframe as an LZA "config-validation" stage/component
Position the validator as the pre-merge counterpart to LZA's in-pipeline `prepare` validation. Two packaging options:
- **(a) Native CDK package** `@aws-accelerator/config-validator` with its own `ConfigValidatorPipeline` construct modeled on `tester-pipeline.ts`. Highest fidelity; feels like it belongs in 1.20.
- **(b) Installer-style CFN template** (what we have) but aligned to LZA's naming/IAM/param conventions. Lower effort, still native-feeling.

Recommend (b) now, with (a) as the "upstream contribution" target.

### R2. Adopt prefix-driven naming
Introduce an `AcceleratorPrefix` parameter (default `AWSAccelerator`, same constraints: no `aws`/`ssm` start, maxLength 15). Derive all names:
- Roles: `${prefix}-ConfigValidator-Role`, `${prefix}-ConfigValidator-Synth-Role`, `${prefix}-ConfigValidator-SourceBuilder-Role`
- Project: `${prefix}-ConfigValidator` / `${prefix}-ConfigValidatorSourceBuilder`
- Buckets: `<lowerPrefix>-config-validator-<accountId>-<region>`, `<lowerPrefix>-config-validator-source-<accountId>-<region>`
- SSM: `/accelerator/config-validator/...`
- KMS alias (if used): `alias/accelerator/config-validator/key`

### R3. Match CloudFormation parameter conventions — drop the `p` prefix
This directly reverses the earlier `p`-prefix change. LZA uses **PascalCase with no Hungarian prefix** everywhere (`RepositorySource`, `AcceleratorPrefix`, `ControlTowerEnabled`) and supplies friendly names via `AWS::CloudFormation::Interface` `ParameterLabels`. To be native: `pValidationBucketName` → `ValidationBucketName`, etc. Keep the `ParameterGroups` (LZA uses them too) and add `ParameterLabels`. Use `CfnRule`/assertions for conditional-required params (as the installer does for CodeConnection/S3 config sources).

> Note: this is a deliberate reversal of the convention we adopted earlier in the project. LZA's own templates are the authority for "native," and they do not use the `p` prefix.

### R4. Apply the org-id + prefixed-role IAM idiom
For the synth role and any cross-account access, add LZA's condition pattern so the policies read like LZA's:
```yaml
Condition:
  StringEquals: { 'aws:PrincipalOrgID': !Ref OrganizationId }
  ArnLike:      { 'aws:PrincipalArn': !Sub 'arn:${AWS::Partition}:iam::*:role/${AcceleratorPrefix}-*' }
```
Take `OrganizationId` as a parameter (or look it up). Keep resource-ARN scoping where possible; use conditions only where a wildcard is unavoidable — exactly LZA's split.

### R5. Rename cross-account assumption to LZA's vocabulary
Replace `pCrossAccountRoleName` with `ManagementAccountAccessRole` (default `AWSControlTowerExecution`) to match `globalConfig.managementAccountAccessRole`. This is the term LZA operators already know.

### R6. Add an optional permission boundary
Add a `PermissionBoundaryPolicyName` parameter (empty = none). When set, attach `arn:${AWS::Partition}:iam::${AWS::AccountId}:policy/${PermissionBoundaryPolicyName}` to every role the stack creates. Mirrors `installerPermissionBoundary`.

### R7. Align env-var vocabulary
Rename the CodeBuild/script env vars to LZA's names so `validate-config` and any shared scripts behave identically:
- `LZA_VERSION` → keep `ACCELERATOR_PIPELINE_VERSION` semantics (version-check gate)
- add `ACCELERATOR_PREFIX`, `ACCELERATOR_SSM_PARAM_NAME_PREFIX`, `PARTITION`, `PIPELINE_ACCOUNT_ID`, `ACCELERATOR_STAGE=prepare` (so `validate-config` takes the same code paths, incl. DynamoDB lookups), `ACCELERATOR_ENABLE_SINGLE_ACCOUNT_MODE`
- `LZA_SYNTH_ROLE_ARN` can stay (it's validator-specific) but prefix it `ACCELERATOR_` for consistency

### R8. Restructure the buildspec like LZA
- Keep the CodeBuild buildspec thin; move the 3-layer logic into `scripts/validate-config-pr.sh` (mirrors `prepare-stage.sh`), invoked from the build phase.
- Use `getNodeRuntimeActivationCommand()`-style PATH activation instead of `runtime-versions`.
- Call `LOG_LEVEL=info yarn validate-config "$CODEBUILD_SRC_DIR_Config"` exactly as `prepare-stage.sh` does. Our L1 (yamllint) and L3 (concurrent synth) become additive pre/post steps around LZA's own validator.
- Add the same package-version-vs-installed-version gate `prepare-stage.sh` uses.

### R9. Publish version + resource identifiers to SSM
On deploy, write `/accelerator/config-validator/version` (from package.json) and the project/bucket names to `/accelerator/config-validator/...`, matching how every LZA stack advertises itself. Enables discovery and drift checks.

### R10. Tag everything
Apply `Accelerator=<AcceleratorPrefix>` to every resource (and any user `globalConfig.tags` if you later read the config). Trivial in CFN via a shared `Tags` block or in CDK via `addAcceleratorTags`.

### R11. Prefer CodeConnection over long-lived keys
LZA's GitHub integration uses a CodeConnection / `accelerator/github-token` secret, not a long-lived IAM user access key. For native feel (and better security posture), offer a CodeConnection-based trigger path for GitHub in addition to the current GHA IAM user. Keep the Secrets Manager storage we added as the fallback.

### R12. Version + manifest parity
Track the validator's version in a `package.json` and expose it the way LZA does (SSM + stack output). If contributing upstream, add a `solution-manifest.yaml`-style descriptor and slot the template name as `AWSAccelerator-ConfigValidatorStack.template`.

---

## Part 4 — Proposed Target Shape (option b, CFN-aligned)

```
AWSAccelerator-ConfigValidatorStack        (was LZA-PR-Validator)
├── Parameters (PascalCase, Interface labels + CfnRules)
│   ├── AcceleratorPrefix            (default AWSAccelerator, maxLength 15, no aws/ssm)
│   ├── ManagementAccountAccessRole  (default AWSControlTowerExecution)
│   ├── OrganizationId               (for org-scoped IAM conditions)
│   ├── PermissionBoundaryPolicyName (optional)
│   ├── LzaVersion / AcceleratorPipelineVersion
│   ├── ValidationComputeType / SourceBuilderComputeType
│   └── (bucket/name overrides, all PascalCase)
├── IAM
│   ├── ${prefix}-ConfigValidator-Role          (CodeBuild; S3+logs+assume synth)
│   ├── ${prefix}-ConfigValidator-Synth-Role    (org-id + prefixed-ARN conditions)
│   └── ${prefix}-ConfigValidator-SourceBuilder-Role
│   └── [optional] PermissionsBoundary on all roles
├── S3
│   ├── <lowerPrefix>-config-validator-<acct>-<region>
│   └── <lowerPrefix>-config-validator-source-<acct>-<region>
├── CodeBuild
│   ├── ${prefix}-ConfigValidator          (inline buildspec → scripts/validate-config-pr.sh)
│   └── ${prefix}-ConfigValidatorSourceBuilder
├── SSM  /accelerator/config-validator/{version,project,bucket,...}
├── Tags Accelerator=${prefix} on all resources
└── Outputs (+ CredentialsSecretArn or CodeConnection guidance)
```

`scripts/validate-config-pr.sh` (mirrors `prepare-stage.sh`):
1. `yamllint` (additive L1)
2. `LOG_LEVEL=info yarn validate-config "$CODEBUILD_SRC_DIR_Config"` (LZA's own validator, L2)
3. concurrent `cdk.ts synth --stage {prepare,security,customizations}` (additive L3)
4. package-version gate

---

## Part 5 — Prioritized Roadmap

**Quick wins (low effort, high native-feel):**
1. R3 — drop `p` prefix, add `ParameterLabels` (reverses earlier change)
2. R5 — rename to `ManagementAccountAccessRole`
3. R7 — align env-var names; set `ACCELERATOR_STAGE=prepare`
4. R10 — tag all resources `Accelerator=<prefix>`
5. R2 — prefix-driven resource names

**Medium:**
6. R4 — org-id + prefixed-ARN IAM conditions
7. R8 — thin buildspec + `scripts/*.sh` + Node PATH activation
8. R9 — publish version/identifiers to SSM
9. R6 — optional permission boundary

**Larger / upstream:**
10. R1(a) — reauthor as a CDK `@aws-accelerator/config-validator` package with a `ConfigValidatorPipeline` modeled on `tester-pipeline.ts`
11. R11 — CodeConnection-based GitHub path
12. R12 — package.json version + solution-manifest descriptor; propose as a 1.20 contribution

---

## Key source references
- `accelerator/utils/app-utils.ts` — `setResourcePrefixes()` prefix expansion
- `accelerator/lib/accelerator-resource-names.ts` — canonical naming registry
- `accelerator/lib/stacks/accelerator-stack.ts` — `getPrincipalOrgIdCondition`, `getOrgPrincipals`, `getSsmPath`, `addSsmParameter`
- `accelerator/lib/stacks/key-stack.ts` — KMS + cross-account SSM role + IAM condition idiom + NagSuppressions
- `accelerator/lib/accelerator-aspects.ts` — `PermissionsBoundaryAspect`
- `accelerator/lib/pipeline.ts` — `ToolkitProject` CodeBuild conventions, per-stage `CodeBuildAction`
- `accelerator/lib/tester-pipeline.ts` — closest template for a standalone native pipeline
- `accelerator/lib/config-validator.ts` — the real `validate-config` subsystem
- `accelerator/scripts/prepare-stage.sh` — buildspec-invoked validation script pattern
- `installer/lib/installer-stack.ts` — CFN param conventions, `CfnRule` assertions, GlobalRegionMap, prefix-derived names
- `installer/lib/resource-name-prefixes.ts` — prefix validation custom resource
