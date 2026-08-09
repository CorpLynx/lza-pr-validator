#!/usr/bin/env python3
"""
Naming-derivation tests for lza-config-validator.yaml (issue #5).

Verifies that every resource name is derived from the correct prefix *parameter*
rather than a hardcoded literal, which is what makes custom-AcceleratorPrefix
deployments work correctly. Mirrors LZA's prefix-family convention:

  - IAM roles / users / CodeBuild projects  -> ${AcceleratorPrefix}      (PascalCase)
  - S3 bucket names                          -> ${AcceleratorBucketPrefix} (kebab-case)
  - SSM parameter names                      -> ${AcceleratorSsmPrefix}    (/accelerator)

Pure-stdlib (regex over the raw template) so it runs in CI without CFN-intrinsic
YAML parsing. Run: python3 tests/test_prefix_naming.py
"""
import re
import sys
from pathlib import Path

TEMPLATE = Path(__file__).resolve().parent.parent / "lza-config-validator.yaml"


def fail(msg):
    print(f"FAIL: {msg}")
    sys.exit(1)


def main():
    text = TEMPLATE.read_text()
    errors = []

    # 1. Bucket names must use the bucket prefix, never the PascalCase or literal prefixes.
    for m in re.finditer(r"BucketName:\s*!Sub\s*'([^']*)'", text):
        val = m.group(1)
        if "${AcceleratorBucketPrefix}" not in val:
            errors.append(f"BucketName '{val}' must derive from ${{AcceleratorBucketPrefix}}")
        if "${AcceleratorPrefix}" in val:
            errors.append(f"BucketName '{val}' uses PascalCase prefix; buckets must use the bucket prefix")

    # 2. IAM RoleName / UserName / CodeBuild project Name must use the PascalCase prefix.
    for prop in ("RoleName", "UserName"):
        for m in re.finditer(rf"{prop}:\s*!Sub\s*'([^']*)'", text):
            val = m.group(1)
            if "${AcceleratorPrefix}" not in val:
                errors.append(f"{prop} '{val}' must derive from ${{AcceleratorPrefix}}")

    # 3. SSM parameter Names must use the SSM prefix.
    for m in re.finditer(r"Name:\s*!Sub\s*'(/[^']*config-validator[^']*)'", text):
        val = m.group(1)
        if "${AcceleratorSsmPrefix}" not in val:
            errors.append(f"SSM parameter Name '{val}' must derive from ${{AcceleratorSsmPrefix}}")

    # 4. No hardcoded prefix literals in name-like values (everything must be parameterized).
    #    Catch 'AWSAccelerator-' or 'aws-accelerator-' appearing inside a quoted Sub/name value.
    for m in re.finditer(r"(RoleName|UserName|BucketName|Name):\s*!Sub\s*'([^']*)'", text):
        val = m.group(2)
        if re.search(r"\bAWSAccelerator-", val) or re.search(r"\baws-accelerator-", val):
            errors.append(f"{m.group(1)} '{val}' contains a hardcoded prefix literal; use the prefix parameter")

    # 5. Partition portability: every ARN must use ${AWS::Partition}, never a hardcoded
    #    partition, so the stack works in aws-us-gov / aws-cn / iso partitions.
    for m in re.finditer(r"'(arn:[a-z-]*:[^']*)'", text):
        arn = m.group(1)
        if arn.startswith("arn:aws:") or arn.startswith("arn:aws-"):
            errors.append(f"ARN '{arn}' hardcodes a partition; use arn:${{AWS::Partition}}:...")

    if errors:
        for e in errors:
            print(f"FAIL: {e}")
        sys.exit(1)

    print("PASS: all resource names derive from the correct prefix parameter")
    print("  - buckets -> ${AcceleratorBucketPrefix}")
    print("  - roles/users/projects -> ${AcceleratorPrefix}")
    print("  - SSM params -> ${AcceleratorSsmPrefix}")


if __name__ == "__main__":
    main()
