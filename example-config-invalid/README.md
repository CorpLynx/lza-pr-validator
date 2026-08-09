# example-config-invalid

An intentionally **broken** LZA configuration used to demonstrate that the validator
catches errors. This directory is a copy of `example-config/` with one deliberate,
documented defect. It is **not** validated by this repo's own CI (only `example-config/`
is), so the repo stays green while this fixture stays red-on-purpose.

## The seeded defect

`organization-config.yaml` → the `DenyRootUser` SCP lists `NonExistentOU` as a
deployment target, but that OU is **not** declared under `organizationalUnits`.

This is a semantic cross-reference error (valid YAML, invalid meaning) that only LZA's
own schema/cross-reference validation catches — exactly the class of bug this tool
exists to stop before it reaches the deployment pipeline.

## Expected result

Validation **fails at Layer 2** (`yarn validate-config`) with an invalid-OU-reference
error. Layer 1 (yamllint) passes because the YAML is syntactically valid.

## How to test

Point the validator at this directory instead of a real config repo:

```bash
# Locally against a checkout of the LZA source
yarn validate-config /path/to/example-config-invalid

# Or via the deployed pipeline: open a PR whose config is this directory
# (set repo variable PR_CONFIG_DIR=example-config-invalid) and confirm the
# "Validate LZA Configuration PR" check goes RED.
```

To confirm the validator also passes on good input, run the same against
`example-config/` (the known-good sample) and confirm it goes green.
