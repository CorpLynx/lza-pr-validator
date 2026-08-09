# Project 2: CFN Guard Rule Generation Agent

## Purpose

A Bedrock Agent that reads the organization's entire IaC codebase, infers coding patterns and conventions, and generates cfn-guard rules to enforce them. This turns implicit team standards into explicit, automated policy — catching deviations before they reach production.

## Problem Statement

Enterprise teams develop implicit coding conventions over time:
- Always use `${AWS::Partition}` instead of hardcoding `arn:aws:`
- Consistent naming: `${Prefix}-${Purpose}-${AccountId}-${Region}`
- Never use `Resource: '*'` with write actions
- Always set log retention
- Always enforce TLS on bucket policies

These conventions live in tribal knowledge. New team members, contractors, or fast-moving sprints introduce drift. By the time it's caught in code review (if ever), it's already deployed.

## Solution

An agent that **observes** your codebase and **infers** rules rather than requiring you to author them manually. The rules are validated against your existing known-good templates to ensure zero false positives before enforcement.

## Architecture

```
┌─ Data Ingestion ─────────────────────────────────────────────────────┐
│                                                                       │
│  Sources (S3):                                                        │
│  ├── LZA CDK Synth Output (*.template.json from cdk.out/)            │
│  │   → The "gold standard" — what LZA produces when config is valid  │
│  │                                                                    │
│  ├── Customization Templates (cloudformation-templates/*.yaml)        │
│  │   → Team-authored CFN that follows org conventions                │
│  │                                                                    │
│  ├── LZA Config Files (*.yaml)                                        │
│  │   → Declares security intent (encryption, access controls)        │
│  │                                                                    │
│  ├── LZA Source Constructs (packages/@aws-accelerator/constructs/)    │
│  │   → How LZA translates config → CFN (shows intended patterns)     │
│  │                                                                    │
│  └── External IaC Repos (optional, via CodeConnection)                │
│      → Other team CFN/CDK repos for broader pattern coverage         │
│                                                                       │
└──────────────────────────────────────┬───────────────────────────────┘
                                       │
                                       ▼
┌─ Bedrock Agent ──────────────────────────────────────────────────────┐
│                                                                       │
│  Foundation Model: Claude (Sonnet/Haiku via Bedrock)                  │
│                                                                       │
│  Action Groups:                                                       │
│                                                                       │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │  1. IngestTemplates                                              │ │
│  │     Lambda that:                                                 │ │
│  │     - Lists all CFN templates in configured S3 paths             │ │
│  │     - Parses each template (JSON/YAML → structured resources)    │ │
│  │     - Extracts resource properties by type                       │ │
│  │     - Returns structured inventory to agent                      │ │
│  └─────────────────────────────────────────────────────────────────┘ │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │  2. InferPatterns                                                │ │
│  │     Agent reasoning (no Lambda — model does this):               │ │
│  │     - Groups resources by type across all templates              │ │
│  │     - Identifies properties that are ALWAYS present              │ │
│  │     - Identifies value patterns (intrinsic functions, prefixes)  │ │
│  │     - Classifies by category:                                    │ │
│  │       • Naming conventions                                       │ │
│  │       • Partition/region handling                                 │ │
│  │       • Encryption at rest                                       │ │
│  │       • Encryption in transit                                    │ │
│  │       • IAM scope / least privilege                              │ │
│  │       • Logging and retention                                    │ │
│  │       • Tagging                                                  │ │
│  │       • Network segmentation                                     │ │
│  └─────────────────────────────────────────────────────────────────┘ │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │  3. GenerateRules                                                │ │
│  │     Lambda that:                                                 │ │
│  │     - Receives agent's inferred patterns                         │ │
│  │     - Produces cfn-guard DSL rules with:                         │ │
│  │       • Rule name (descriptive, categorized)                     │ │
│  │       • Condition (cfn-guard syntax)                             │ │
│  │       • Human-readable message on violation                      │ │
│  │       • Severity (error vs warning)                              │ │
│  │     - Writes rule files to S3 (organized by category)            │ │
│  └─────────────────────────────────────────────────────────────────┘ │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │  4. ValidateRules                                                │ │
│  │     Lambda that:                                                 │ │
│  │     - Runs cfn-guard validate on generated rules                 │ │
│  │     - Tests against ALL known-good templates in the codebase     │ │
│  │     - Flags false positives (violations on your own code)        │ │
│  │     - Returns pass/fail + violation details to agent             │ │
│  │     - Agent iterates: adjusts rules to eliminate false positives │ │
│  └─────────────────────────────────────────────────────────────────┘ │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │  5. PublishRules                                                 │ │
│  │     Lambda that:                                                 │ │
│  │     - Writes finalized rules to the rules S3 path               │ │
│  │     - Optionally creates a PR with new/updated rules             │ │
│  │     - Generates a changelog (what patterns were detected)        │ │
│  └─────────────────────────────────────────────────────────────────┘ │
│                                                                       │
│  Knowledge Base (supporting context):                                 │
│  - cfn-guard DSL reference + syntax examples                         │
│  - AWS CloudFormation Resource Specification (property schemas)       │
│  - AWS Guard Rules Registry (community rule examples)                │
│  - Org-specific style guide (if one exists)                          │
│                                                                       │
└───────────────────────────────────────────────────────────────────────┘
                                       │
                                       ▼
┌─ Output ─────────────────────────────────────────────────────────────┐
│                                                                       │
│  s3://<rules-bucket>/guard-rules/                                     │
│  ├── partition-usage.guard                                            │
│  ├── naming-conventions.guard                                         │
│  ├── encryption-at-rest.guard                                         │
│  ├── encryption-in-transit.guard                                      │
│  ├── iam-least-privilege.guard                                        │
│  ├── logging-retention.guard                                          │
│  ├── tagging-standards.guard                                          │
│  ├── network-security.guard                                           │
│  └── metadata.json (pattern inventory, coverage stats, last run)      │
│                                                                       │
└───────────────────────────────────────────────────────────────────────┘
```

## Pattern Categories & Example Rules

### 1. Partition Usage
**Observation:** Every ARN reference uses `!Sub` with `${AWS::Partition}`, never hardcoded `arn:aws:`.

```guard
# partition-usage.guard
rule no_hardcoded_partition {
    Resources.*[ Type in [
        /AWS::IAM::*/,
        /AWS::S3::*/,
        /AWS::KMS::*/,
        /AWS::Lambda::*/
    ]] {
        Properties.* not contains "arn:aws:"
            << VIOLATION: Hardcoded partition detected. Use ${AWS::Partition} for GovCloud/China compatibility. >>
    }
}
```

### 2. Naming Conventions
**Observation:** All resource names follow `${Prefix}-${Purpose}-${AccountId}-${Region}` or use Fn::Sub with predictable patterns.

```guard
# naming-conventions.guard
rule s3_bucket_naming {
    Resources.*[ Type == "AWS::S3::Bucket" ] {
        Properties.BucketName exists
        Properties.BucketName is_struct  # Must use intrinsic function, not hardcoded
            << VIOLATION: Bucket name must use Fn::Sub with AccountId and Region for uniqueness. >>
    }
}

rule iam_role_naming {
    Resources.*[ Type == "AWS::IAM::Role" ] {
        Properties.RoleName exists
            << VIOLATION: IAM roles must have an explicit RoleName (no auto-generated names). >>
    }
}
```

### 3. Encryption at Rest
**Observation:** All S3 buckets have SSE, all EBS volumes are encrypted, all DynamoDB tables use KMS.

```guard
# encryption-at-rest.guard
rule s3_bucket_encryption {
    Resources.*[ Type == "AWS::S3::Bucket" ] {
        Properties.BucketEncryption exists
        Properties.BucketEncryption.ServerSideEncryptionConfiguration[*] {
            ServerSideEncryptionByDefault.SSEAlgorithm in ["AES256", "aws:kms"]
        }
            << VIOLATION: S3 buckets must have server-side encryption configured. >>
    }
}

rule dynamodb_encryption {
    Resources.*[ Type == "AWS::DynamoDB::Table" ] {
        Properties.SSESpecification exists
        Properties.SSESpecification.SSEEnabled == true
            << VIOLATION: DynamoDB tables must have SSE enabled with KMS. >>
    }
}
```

### 4. Encryption in Transit
**Observation:** All bucket policies include SecureTransport deny condition.

```guard
# encryption-in-transit.guard
rule s3_enforce_tls {
    Resources.*[ Type == "AWS::S3::BucketPolicy" ] {
        Properties.PolicyDocument.Statement[*] {
            some Condition.Bool exists
            when Condition.Bool exists {
                Condition.Bool."aws:SecureTransport" == "false"
            }
        }
            << VIOLATION: Bucket policies must include a Deny statement for non-TLS requests. >>
    }
}
```

### 5. IAM Least Privilege
**Observation:** No policies use `Resource: '*'` with write/modify actions. Always scoped to specific ARNs.

```guard
# iam-least-privilege.guard
rule no_wildcard_resource_with_write {
    Resources.*[ Type == "AWS::IAM::Policy" ] {
        Properties.PolicyDocument.Statement[*] {
            when Effect == "Allow" {
                when Action[*] not in [
                    "sts:GetCallerIdentity",
                    "ec2:Describe*",
                    "organizations:List*",
                    "organizations:Describe*"
                ] {
                    Resource != "*"
                        << VIOLATION: IAM policies must scope Resource to specific ARNs for non-read actions. >>
                }
            }
        }
    }
}
```

### 6. Logging and Retention
**Observation:** All log groups have RetentionInDays set (never indefinite).

```guard
# logging-retention.guard
rule log_group_retention {
    Resources.*[ Type == "AWS::Logs::LogGroup" ] {
        Properties.RetentionInDays exists
        Properties.RetentionInDays >= 1
            << VIOLATION: CloudWatch Log Groups must have a retention period set. >>
    }
}
```

### 7. Tagging Standards
**Observation:** All taggable resources include Environment and ManagedBy tags.

```guard
# tagging-standards.guard
rule required_tags {
    Resources.*[ Type in [
        /AWS::S3::Bucket/,
        /AWS::IAM::Role/,
        /AWS::KMS::Key/,
        /AWS::Lambda::Function/,
        /AWS::DynamoDB::Table/
    ]] {
        Properties.Tags exists
        Properties.Tags[*].Key == "Environment"
        Properties.Tags[*].Key == "ManagedBy"
            << VIOLATION: Resources must include 'Environment' and 'ManagedBy' tags. >>
    }
}
```

### 8. Network Security
**Observation:** No security groups allow 0.0.0.0/0 ingress except on port 443.

```guard
# network-security.guard
rule no_unrestricted_ingress {
    Resources.*[ Type == "AWS::EC2::SecurityGroup" ] {
        Properties.SecurityGroupIngress[*] {
            when CidrIp == "0.0.0.0/0" OR CidrIpv6 == "::/0" {
                FromPort == 443
                ToPort == 443
                    << VIOLATION: Unrestricted ingress (0.0.0.0/0) is only permitted on port 443. >>
            }
        }
    }
}
```

## Agent Invocation Modes

### Mode 1: Full Scan (scheduled or on-demand)
Reads entire codebase, regenerates all rules, validates against templates.
```bash
aws bedrock-agent invoke-agent \
  --agent-id <id> \
  --session-id "full-scan-$(date +%Y%m%d)" \
  --input-text "Scan all CloudFormation templates in the codebase. Infer coding patterns and generate cfn-guard rules. Validate rules produce zero false positives against existing templates."
```

### Mode 2: Incremental (triggered by new template)
Reads a new/changed template, checks against existing rules, suggests new rules if it introduces a novel pattern.
```bash
aws bedrock-agent invoke-agent \
  --agent-id <id> \
  --session-id "pr-check-${PR_NUMBER}" \
  --input-text "A new template was added: s3://bucket/templates/new-stack.yaml. Check if it follows existing patterns. If it introduces a new consistent pattern not yet covered by rules, suggest a new rule."
```

### Mode 3: Explain (team education)
Given a rule violation, explain why the rule exists based on codebase evidence.
```bash
aws bedrock-agent invoke-agent \
  --agent-id <id> \
  --session-id "explain" \
  --input-text "Rule 'no_hardcoded_partition' was violated in templates/my-stack.yaml line 42. Explain why this rule exists and how to fix the violation."
```

## Integration with Validator Pipeline

Add Layer 4 to `scripts/validate-config-pr.sh`:

```bash
echo "=========================================================="
echo "LAYER 4: CFN Guard Policy Compliance"
echo "=========================================================="

# Download guard rules from S3
aws s3 sync s3://${GUARD_RULES_BUCKET}/guard-rules/ /tmp/guard-rules/

# Run against CDK synth output
if [ -d "cdk.out" ]; then
  cfn-guard validate \
    --data cdk.out/ \
    --rules /tmp/guard-rules/ \
    --show-summary fail \
    --output-format json > /tmp/guard-results.json

  VIOLATIONS=$(jq '.not_compliant | length' /tmp/guard-results.json)
  if [ "$VIOLATIONS" -gt 0 ]; then
    echo "FAIL: $VIOLATIONS guard rule violation(s) detected."
    jq -r '.not_compliant[] | "\(.rule): \(.message)"' /tmp/guard-results.json
    exit 1
  fi
fi

echo "PASS: All CFN Guard rules satisfied."
```

## Infrastructure Requirements

| Resource | Purpose |
|----------|---------|
| Bedrock Agent | Orchestrates pattern inference and rule generation |
| Lambda x4 | IngestTemplates, GenerateRules, ValidateRules, PublishRules |
| S3 Bucket (rules) | Stores generated guard rule files |
| S3 Bucket (templates) | Stores CFN templates for analysis (can reuse existing) |
| Bedrock KB | cfn-guard docs, CFN resource specs, community rules |
| OpenSearch Serverless | Vector store for KB |
| EventBridge (optional) | Schedule weekly full scans |
| IAM Roles | Agent execution, Lambda execution, S3 access |

## Iteration Loop

```
┌─────────────────────────────────────────────────────────┐
│  1. Agent scans codebase → infers patterns              │
│  2. Agent generates guard rules                         │
│  3. Agent validates rules against known-good templates  │
│  4. If false positives → agent adjusts rules → goto 3   │
│  5. Rules published to S3                               │
│  6. Validator pipeline uses rules on next PR            │
│  7. Team merges new templates (patterns evolve)         │
│  8. goto 1 (on schedule or trigger)                     │
└─────────────────────────────────────────────────────────┘
```

## Estimated Effort

| Phase | Duration | Deliverable |
|-------|----------|-------------|
| Agent setup + action groups | 3 days | Working agent with Lambda integrations |
| Knowledge base (cfn-guard docs, CFN specs) | 1 day | Populated KB for syntax reference |
| Initial rule generation run | 1 day | First set of guard rules from current codebase |
| Validator integration (Layer 4) | 0.5 days | Guard rules running in PR pipeline |
| False positive tuning | 1-2 days | Rules refined to zero false positives |
| Scheduling + incremental mode | 1 day | EventBridge trigger, PR-level checks |
| **Total** | **7-9 days** | Production-ready rule generation system |

## Key Design Decisions

1. **Inference over prescription** — Agent discovers patterns from code, not from a policy document you maintain manually
2. **Zero false positives before publish** — Rules are never active until validated against your own codebase
3. **Categorized output** — Rules organized by concern, not by resource type (easier for teams to understand)
4. **Severity levels** — Some patterns are hard errors (partition usage), others are warnings (naming conventions)
5. **Self-improving** — As the team writes more code, the agent detects new patterns and proposes new rules
6. **Explainable** — Every rule can be traced back to "we do this because every template in the codebase does it this way"
