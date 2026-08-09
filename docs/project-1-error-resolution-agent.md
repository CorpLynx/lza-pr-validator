# Project 1: LZA Error Resolution Agent

## Purpose

Automatically diagnose LZA validator and pipeline failures using RAG over LZA source code, documentation, and historical resolutions. Posts fix suggestions as PR comments or SNS notifications — reducing MTTR from hours to seconds.

## Problem Statement

LZA errors are opaque:
- "NoStack: CloudFormationStack object does not hold a stack" — means a ROLLBACK_COMPLETE stack exists
- "Disabling useV2Stacks after it has been enabled" — means stale SSM parameter from a failed run
- "Validation failed with 3 error(s)" — CFN gives no detail on what properties are wrong
- "InvalidInputException: No organization accounts found" — means Prepare stage didn't populate DynamoDB

Engineers spend hours reading LZA source code, CloudFormation docs, and GitHub issues to find root causes. The knowledge exists — it just isn't accessible at the point of failure.

## Architecture

```
┌─ Trigger ────────────────────────────────────────────────────────────┐
│                                                                       │
│  EventBridge Rule:                                                    │
│  - Source: aws.codebuild                                              │
│  - Detail: build-status = FAILED                                      │
│  - Project: AWSAccelerator-ToolkitProject OR AWSAccelerator-ConfigValidator │
│                                                                       │
└──────────────────────────────────────┬───────────────────────────────┘
                                       │
                                       ▼
┌─ Error Extraction Lambda ────────────────────────────────────────────┐
│                                                                       │
│  Input: CodeBuild state change event (build ID, project name)         │
│                                                                       │
│  Steps:                                                               │
│  1. Get build details (stage, config source location)                 │
│  2. Pull last 100 lines from CloudWatch Logs                          │
│  3. Extract error chain:                                              │
│     - Filter for lines with error/fail/exception/denied               │
│     - Capture 3 lines before each error for context                   │
│     - Identify the resource/stack that failed                         │
│  4. Pull relevant config section from S3 (if identifiable)            │
│  5. Build structured query:                                           │
│     {                                                                 │
│       "error_message": "...",                                         │
│       "error_type": "CFN_VALIDATION|CDK_SYNTH|IAM_DENIED|...",       │
│       "stage": "Prepare|Logging|SecurityAudit|...",                   │
│       "account": "236292170987",                                      │
│       "region": "us-east-1",                                          │
│       "resource": "AWSAccelerator-LoggingStack-...",                  │
│       "config_context": "relevant yaml section",                      │
│       "lza_version": "v1.16.0"                                        │
│     }                                                                 │
│  6. Invoke Bedrock Agent with query                                   │
│  7. Post response:                                                    │
│     - If triggered by ConfigValidator → GitHub PR comment             │
│     - If triggered by AWSAccelerator pipeline → SNS notification      │
│                                                                       │
└──────────────────────────────────────┬───────────────────────────────┘
                                       │
                                       ▼
┌─ Bedrock Agent ──────────────────────────────────────────────────────┐
│                                                                       │
│  Foundation Model: Claude Sonnet (via Bedrock)                        │
│                                                                       │
│  System Prompt:                                                       │
│  "You are an LZA troubleshooting expert. Given an error from an LZA  │
│   pipeline or validation run, identify the root cause, explain why    │
│   it happened, and provide the exact fix (commands or config changes).│
│   Reference specific LZA source files when relevant. Be concise."    │
│                                                                       │
│  Knowledge Base (RAG):                                                │
│  Retrieves relevant context before generating response                │
│                                                                       │
└──────────────────────────────────────┬───────────────────────────────┘
                                       │
                                       ▼
┌─ Knowledge Base ─────────────────────────────────────────────────────┐
│                                                                       │
│  Vector Store: OpenSearch Serverless                                  │
│  Embedding Model: Titan Embeddings V2                                 │
│  Chunking: Hierarchical (file → function level, 1000 token chunks)   │
│                                                                       │
│  Data Sources (S3):                                                   │
│                                                                       │
│  ┌─ lza-source/ ──────────────────────────────────────────────────┐  │
│  │  Priority files (most relevant to error diagnosis):             │  │
│  │  - packages/@aws-accelerator/config/lib/*.ts (validators)      │  │
│  │  - packages/@aws-accelerator/accelerator/lib/stacks/*.ts       │  │
│  │  - packages/@aws-accelerator/constructs/lib/**/*.ts            │  │
│  │  - packages/@aws-accelerator/utils/lib/*.ts                    │  │
│  │  - CHANGELOG.md (breaking changes per version)                 │  │
│  │  - FAQ.md                                                      │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                       │
│  ┌─ docs/ ────────────────────────────────────────────────────────┐  │
│  │  - LZA Implementation Guide (PDF/HTML scraped)                 │  │
│  │  - Config file reference                                       │  │
│  │  - AWS CDK troubleshooting guide                               │  │
│  │  - CloudFormation error reference                              │  │
│  │  - Control Tower known issues                                  │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                       │
│  ┌─ resolutions/ ────────────────────────────────────────────────┐   │
│  │  Historical error→fix pairs (JSON, grows over time):           │  │
│  │                                                                │  │
│  │  {                                                             │  │
│  │    "id": "res-001",                                            │  │
│  │    "error": "Disabling useV2Stacks after it has been...",      │  │
│  │    "stage": "Prepare",                                         │  │
│  │    "root_cause": "SSM param persisted from failed rollback",   │  │
│  │    "fix": [                                                    │  │
│  │      "aws ssm delete-parameter --name /accelerator/...",       │  │
│  │      "Add useV2Stacks: true to global-config.yaml"             │  │
│  │    ],                                                          │  │
│  │    "prevention": "Always set useV2Stacks explicitly",          │  │
│  │    "lza_version": "v1.16.0"                                    │  │
│  │  }                                                             │  │
│  │                                                                │  │
│  │  {                                                             │  │
│  │    "id": "res-002",                                            │  │
│  │    "error": "NoStack: CloudFormationStack object...",           │  │
│  │    "stage": "Logging",                                         │  │
│  │    "root_cause": "Stack in ROLLBACK_COMPLETE state",           │  │
│  │    "fix": [                                                    │  │
│  │      "Delete the ROLLBACK_COMPLETE stack manually",            │  │
│  │      "Retry the pipeline stage"                                │  │
│  │    ],                                                          │  │
│  │    "prevention": "Pipeline should auto-delete failed stacks"   │  │
│  │  }                                                             │  │
│  │                                                                │  │
│  │  {                                                             │  │
│  │    "id": "res-003",                                            │  │
│  │    "error": "InvalidCloudWatchLogsLogGroupArnException",       │  │
│  │    "stage": "Control Tower Setup",                             │  │
│  │    "root_cause": "CloudTrailRole policy uses old log group     │  │
│  │     name pattern, CT v4.0 uses randomized suffixes",           │  │
│  │    "fix": [                                                    │  │
│  │      "Update AWSControlTowerCloudTrailRolePolicy to use        │  │
│  │       wildcard: aws-controltower/CloudTrailLogs*"              │  │
│  │    ]                                                           │  │
│  │  }                                                             │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                       │
└───────────────────────────────────────────────────────────────────────┘
```

## Output Format (PR Comment)

When the validator fails, the agent posts a comment like:

```markdown
## LZA Validation Failed — Automated Diagnosis

**Error:** `Config file validation failed: OU 'NonExistentOU' not found`

**Root Cause:** The `organization-config.yaml` references an OU named `NonExistentOU`
in the `DenyRootUser` SCP deployment targets, but this OU is not defined in the
`organizationalUnits` list and does not exist in AWS Organizations.

**Fix:**
Either add the OU to `organizationalUnits` in `organization-config.yaml`:
```yaml
organizationalUnits:
  - name: Security
  - name: Infrastructure
  - name: NonExistentOU  # add this
```

Or remove it from the SCP deployment targets:
```yaml
deploymentTargets:
  organizationalUnits:
    - Security
    - Infrastructure
    # remove NonExistentOU
```

**Source:** `packages/@aws-accelerator/config/lib/organization-config-validator.ts:142`
validates OU references against the defined list.

---
*Diagnosed by LZA Error Resolution Agent v1.0*
```

## Feedback Loop

After a human resolves an issue, they can add it to the resolutions corpus:

```bash
# Quick-add a resolution
aws s3 cp - s3://<kb-bucket>/resolutions/res-004.json << 'EOF'
{
  "id": "res-004",
  "error": "AccessDeniedException: kms:Decrypt on resource...",
  "stage": "CDK Synth (validator)",
  "root_cause": "Synth role missing KMS decrypt permission for DynamoDB config table encryption key",
  "fix": ["Add kms:Decrypt to the synth role policy for the accelerator KMS key"],
  "prevention": "Synth role should have KMS decrypt scoped to accelerator keys"
}
EOF
```

The KB automatically re-indexes and the agent's next response will incorporate this knowledge.

## Infrastructure (CloudFormation)

| Resource | Purpose |
|----------|---------|
| Bedrock Knowledge Base | RAG over LZA source + docs + resolutions |
| OpenSearch Serverless Collection | Vector store |
| Bedrock Agent | Orchestrates diagnosis |
| Lambda (ErrorExtractor) | Pulls logs, builds query, posts response |
| EventBridge Rule | Triggers on CodeBuild FAILED state |
| S3 Bucket (KB data) | Stores source, docs, resolutions |
| Secrets Manager | GitHub PAT for PR comments |
| SNS Topic | Pipeline failure notifications with diagnosis |
| IAM Roles | Lambda exec, Bedrock invoke, CW Logs read |

## Estimated Effort

| Phase | Duration | Deliverable |
|-------|----------|-------------|
| KB setup (OpenSearch + data ingestion) | 1.5 days | Indexed LZA source + docs |
| Bedrock Agent config | 0.5 days | Agent with KB attached |
| Error extraction Lambda | 1 day | Log parsing + structured query building |
| EventBridge + routing | 0.5 days | Auto-trigger on failures |
| GitHub PR comment integration | 0.5 days | Posts diagnosis on validator failures |
| Seed resolutions from today's session | 0.5 days | 5-10 resolution pairs from known issues |
| Testing + prompt tuning | 1 day | Accurate diagnoses on known errors |
| **Total** | **5-6 days** | Production-ready error diagnosis system |
