# cfn-guard rules

Policy-as-code rules enforced by **Layer 4** of the validator against the CDK synth
output (`cdk.out/*.template.json`).

## How Layer 4 works

`scripts/validate-config-pr.sh` runs Layer 4 only when **both** are true:
1. `cfn-guard` is available on PATH (installed by `buildspec.yml`), and
2. this `guard-rules/` directory exists in the configuration repo with `*.guard` files.

If either is missing, Layer 4 is skipped with a notice — so the layer is fully
opt-in and never destabilizes existing validation.

```bash
cfn-guard validate --data cdk.out/ --rules guard-rules/ --show-summary fail
```

## Authoring rules

Follow LZA's "infer from the codebase" approach (see `docs/project-2-guard-rule-agent.md`
and `docs/codex-prompt-guard-rule-generation.md`): only encode patterns your synthesized
templates already satisfy, and validate that new rules produce **zero violations** against
known-good synth output before enabling them. This keeps the layer false-positive free.

## Included starter rules

| File | Enforces |
|------|----------|
| `s3-security.guard` | All S3 buckets have SSE (AES256/aws:kms) and block all public access |

Extend with `naming-conventions.guard`, `encryption-in-transit.guard`,
`iam-least-privilege.guard`, `tagging-standards.guard`, etc. as your standards solidify.
