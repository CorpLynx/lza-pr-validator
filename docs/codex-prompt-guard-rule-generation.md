# Codex/AI Prompt: Generate CFN Guard Rules from Codebase

Use this prompt with Codex, Claude, or any code-generation AI to produce cfn-guard rules from your CloudFormation templates. Feed it your templates and it will infer patterns and output rules.

---

## Prompt

```
You are a CloudFormation security and standards expert. I'm going to give you a collection of CloudFormation templates from my organization's codebase. Your job is to:

1. Analyze ALL templates and identify recurring patterns — things that are consistently done the same way across every template.

2. Categorize patterns into:
   - PARTITION USAGE: How ARNs are constructed (intrinsic functions vs hardcoded)
   - NAMING CONVENTIONS: How resources are named (prefixes, suffixes, dynamic components)
   - ENCRYPTION AT REST: What encryption settings are always present
   - ENCRYPTION IN TRANSIT: TLS enforcement patterns
   - IAM LEAST PRIVILEGE: How policies scope their Resource and Action fields
   - LOGGING & RETENTION: What logging/retention is always configured
   - TAGGING: What tags are always present
   - NETWORK SECURITY: Security group and network ACL patterns
   - GENERAL HYGIENE: Anything else that's consistently done (DeletionPolicy, UpdateReplacePolicy, etc.)

3. For each pattern you identify, generate a cfn-guard rule in valid cfn-guard DSL syntax that enforces it. Each rule must include:
   - A descriptive rule name (snake_case)
   - The guard condition
   - A human-readable violation message in << >> delimiters
   - A comment explaining what pattern you observed that led to this rule

4. Validate your rules mentally against the templates I provided — they should produce ZERO violations on the templates I give you (since I'm giving you known-good code).

5. Output the rules organized into separate files by category.

IMPORTANT CONSTRAINTS:
- Only generate rules for patterns you observe in AT LEAST 2 templates (not one-offs)
- Prefer specific rules over broad ones (rule per resource type, not one catch-all)
- If a pattern uses CloudFormation intrinsic functions (Fn::Sub, Ref, etc.), the rule should check for the presence of the intrinsic, not a specific value
- Rules should work for both JSON and YAML CloudFormation templates
- Use cfn-guard 3.x syntax

Here is the cfn-guard DSL reference for syntax:

- `rule <name> when <condition> { <clauses> }` — named rule with filter
- `Resources.*[ Type == "AWS::S3::Bucket" ]` — filter resources by type
- `Properties.X exists` — property must be present
- `Properties.X == "value"` — exact match
- `Properties.X in ["a", "b"]` — value in set
- `Properties.X not contains "substring"` — absence check
- `Properties.X is_struct` — value is an object/intrinsic function (not a plain string)
- `some Properties.X[*].Y == "value"` — at least one array element matches
- `<< MESSAGE >>` — violation message

Now analyze these templates and generate guard rules:

---
TEMPLATE 1: [paste template]
---
TEMPLATE 2: [paste template]
---
TEMPLATE 3: [paste template]
---
(include as many as you have)
```

---

## How to Use

### Option A: Feed individual templates

Copy-paste your CloudFormation templates directly into the prompt. Good for 2-5 templates.

### Option B: Feed CDK synth output

```bash
# Generate synth output from your LZA config
cd lza-source/source/packages/@aws-accelerator/accelerator
yarn run ts-node --transpile-only cdk.ts synth \
  --stage prepare --config-dir /path/to/config \
  --partition aws --account 123456789012 --region us-east-1

# Collect the generated templates
find cdk.out -name "*.template.json" -exec echo "--- TEMPLATE: {} ---" \; -exec cat {} \;
```

Feed the output into the prompt.

### Option C: Feed from your repo

```bash
# Collect all CFN templates in your repo
find . -name "*.yaml" -path "*/cloudformation-templates/*" -exec echo "--- TEMPLATE: {} ---" \; -exec cat {} \;
find . -name "*.template.json" -exec echo "--- TEMPLATE: {} ---" \; -exec cat {} \;
```

---

## Follow-up Prompts

After initial rule generation, use these to refine:

### Validate rules against a new template
```
Here's a new CloudFormation template someone on my team wrote. Run the guard rules you generated against it and tell me what violations it has:

[paste new template]
```

### Add rules for a specific concern
```
I also want rules that enforce:
- All Lambda functions must have a DLQ configured
- All API Gateway stages must have access logging enabled
- No security group should reference itself as a source

Generate additional guard rules for these requirements.
```

### Reduce false positives
```
Rule X is triggering on this template but it's actually valid because [reason]. 
Adjust the rule to account for this exception without making it too broad.

[paste the template section causing the false positive]
```

### Generate test cases
```
For each rule you generated, create a PASSING and FAILING CloudFormation template snippet that I can use to test the rule with `cfn-guard test`.
```

---

## Example Output

Given templates that consistently use `${AWS::Partition}` and always encrypt S3 buckets, the AI should produce something like:

```guard
# File: partition-usage.guard

# Observed: Every ARN in the codebase uses Fn::Sub with ${AWS::Partition}
# rather than hardcoding "arn:aws:". This ensures GovCloud/China compatibility.
rule no_hardcoded_aws_partition {
    Resources.* {
        when Properties exists {
            Properties.* not contains "arn:aws:"
                << Do not hardcode 'arn:aws:' in ARNs. Use Fn::Sub with ${AWS::Partition} for partition-agnostic templates. >>
        }
    }
}
```

```guard
# File: encryption-at-rest.guard

# Observed: Every AWS::S3::Bucket in the codebase has BucketEncryption
# configured with either AES256 or aws:kms.
rule s3_must_have_encryption {
    Resources.*[ Type == "AWS::S3::Bucket" ] {
        Properties.BucketEncryption exists
        Properties.BucketEncryption.ServerSideEncryptionConfiguration exists
        Properties.BucketEncryption.ServerSideEncryptionConfiguration[*] {
            ServerSideEncryptionByDefault exists
            ServerSideEncryptionByDefault.SSEAlgorithm in ["AES256", "aws:kms"]
        }
            << S3 buckets must have server-side encryption configured (AES256 or aws:kms). >>
    }
}
```

---

## Tips

- More templates = better pattern inference. Feed it at least 5-10 for reliable results.
- Include both your "gold standard" templates (LZA output) AND team-authored ones.
- If the AI generates a rule you disagree with, tell it to drop it — not every pattern should be enforced.
- Re-run this when you upgrade LZA versions or significantly change your architecture.
- Store the generated rules in your repo under `guard-rules/` and add them to CI.
