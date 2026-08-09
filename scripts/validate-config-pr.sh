#!/usr/bin/env bash
#
# LZA Config Validator - pre-merge configuration validation
#
# Mirrors the Landing Zone Accelerator pipeline's `prepare-stage.sh`: it runs the
# accelerator's own `yarn validate-config` against a configuration directory, wrapped
# with additional YAML linting and concurrent CDK synthesis for defense in depth.
#
# Invoked from buildspec.yml. Environment variables use the ACCELERATOR_* vocabulary
# to match LZA's conventions.
#
set -eo pipefail

# ---------------------------------------------------------------------------
# Inputs (ACCELERATOR_* env vars, aligned with LZA)
# ---------------------------------------------------------------------------
CONFIG_DIR="${1:-${CODEBUILD_SRC_DIR}}"
ACCELERATOR_VERSION="${ACCELERATOR_VERSION:-v1.16.0}"
ACCELERATOR_SOURCE_BUCKET="${ACCELERATOR_SOURCE_BUCKET:-}"
ACCELERATOR_SYNTH_ROLE_ARN="${ACCELERATOR_SYNTH_ROLE_ARN:-}"
ACCELERATOR_PIPELINE_VERSION="${ACCELERATOR_PIPELINE_VERSION:-}"
PARTITION="${PARTITION:-aws}"
AWS_DEFAULT_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
WORK_DIR="/tmp/lza-validation"
START_TIME=$(date +%s)

trap 'echo "ERROR: Validation failed at line $LINENO. See logs above for details." >&2' ERR

print_time() {
  local END_TIME
  END_TIME=$(date +%s)
  echo "--> Elapsed time: $((END_TIME - START_TIME))s"
}

# ---------------------------------------------------------------------------
# Version gate (mirrors prepare-stage.sh): fail fast if the validator's target
# LZA version does not match the version installed in the environment.
# ---------------------------------------------------------------------------
if [ -n "${ACCELERATOR_PIPELINE_VERSION}" ]; then
  INSTALLED_VERSION="v${ACCELERATOR_PIPELINE_VERSION#v}"
  TARGET_VERSION="v${ACCELERATOR_VERSION#v}"
  if [ "${TARGET_VERSION}" != "${INSTALLED_VERSION}" ]; then
    echo "ERROR: Validator target LZA version (${TARGET_VERSION}) does not match the installed LZA version (${INSTALLED_VERSION})."
    echo "Update the validator's LzaVersion parameter and rebuild the source bundle before validating."
    exit 1
  fi
  echo "Version check passed: validating against LZA ${TARGET_VERSION}"
fi

# ---------------------------------------------------------------------------
# LAYER 1: YAML Syntax Validation (yamllint)
# ---------------------------------------------------------------------------
echo "=========================================================="
echo "LAYER 1: YAML Syntax Validation (yamllint)"
echo "=========================================================="
yamllint -d "{extends: default, rules: {line-length: disable, document-start: disable}}" "${CONFIG_DIR}/"
echo "PASS: YAML syntax validation succeeded."
print_time

# ---------------------------------------------------------------------------
# Fetch the pre-built LZA source bundle
# ---------------------------------------------------------------------------
echo "=========================================================="
echo "LAYER 2: LZA Schema & Cross-Reference Validation"
echo "=========================================================="

rm -rf "${WORK_DIR}/lza-source"
mkdir -p "${WORK_DIR}/lza-source"

if [ -n "${ACCELERATOR_SOURCE_BUCKET}" ]; then
  echo "Downloading LZA source bundle from s3://${ACCELERATOR_SOURCE_BUCKET}/lza-${ACCELERATOR_VERSION}.tar.gz..."
  aws s3 cp "s3://${ACCELERATOR_SOURCE_BUCKET}/lza-${ACCELERATOR_VERSION}.tar.gz" - \
    | tar -xz -C "${WORK_DIR}/lza-source" --warning=no-unknown-keyword 2>/dev/null
else
  echo "ACCELERATOR_SOURCE_BUCKET not set, falling back to git clone (${ACCELERATOR_VERSION})..."
  git clone --depth 1 --branch "${ACCELERATOR_VERSION}" \
    https://github.com/awslabs/landing-zone-accelerator-on-aws.git "${WORK_DIR}/lza-source"
fi

# ---------------------------------------------------------------------------
# Assume the synth role for AWS API access (validate-config + cdk synth).
# LZA reads real AWS Organizations / DynamoDB / SSM state during validation.
# ---------------------------------------------------------------------------
if [ -n "${ACCELERATOR_SYNTH_ROLE_ARN}" ]; then
  echo "Assuming synth role: ${ACCELERATOR_SYNTH_ROLE_ARN}"
  CREDS=$(aws sts assume-role --role-arn "${ACCELERATOR_SYNTH_ROLE_ARN}" --role-session-name config-validator-synth --output json)
  AWS_ACCESS_KEY_ID=$(echo "${CREDS}" | jq -r '.Credentials.AccessKeyId')
  AWS_SECRET_ACCESS_KEY=$(echo "${CREDS}" | jq -r '.Credentials.SecretAccessKey')
  AWS_SESSION_TOKEN=$(echo "${CREDS}" | jq -r '.Credentials.SessionToken')
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export ACCOUNT_ID
export AWS_DEFAULT_REGION

cd "${WORK_DIR}/lza-source/source"

# Skip install/build if the bundle is pre-built (dist/ present)
if [ -d "packages/@aws-accelerator/accelerator/dist" ]; then
  echo "Pre-built bundle detected - skipping install and build."
else
  echo "Installing dependencies and compiling packages..."
  yarn install --frozen-lockfile --silent
  yarn build
fi

# Run LZA's own validator exactly as the pipeline's prepare stage does.
# ACCELERATOR_STAGE=prepare makes validate-config take the same code path as the
# real pipeline (including config-table lookups against the deployed environment).
echo "Executing yarn validate-config against: ${CONFIG_DIR}"
ACCELERATOR_STAGE=prepare LOG_LEVEL=info yarn validate-config "${CONFIG_DIR}"
echo "PASS: Schema and cross-reference validation succeeded."
print_time

# ---------------------------------------------------------------------------
# LAYER 3: Concurrent Dry-Run CDK Synthesis
# ---------------------------------------------------------------------------
echo "=========================================================="
echo "LAYER 3: Concurrent Dry-Run CDK Synthesis"
echo "=========================================================="

cd "${WORK_DIR}/lza-source/source/packages/@aws-accelerator/accelerator"

STAGES=("prepare" "security" "customizations")
PIDS=()
STAGE_STATUS=0

for STAGE in "${STAGES[@]}"; do
  echo "Starting background synthesis for stage: [ ${STAGE} ]"
  yarn run ts-node --transpile-only cdk.ts synth \
    --stage "${STAGE}" \
    --config-dir "${CONFIG_DIR}" \
    --partition "${PARTITION}" \
    --account "${ACCOUNT_ID}" \
    --region "${AWS_DEFAULT_REGION}" &
  PIDS+=($!)
done

echo "Waiting for all stages to complete..."
for i in "${!PIDS[@]}"; do
  if wait "${PIDS[$i]}"; then
    echo "PASS: Synthesis succeeded for stage: [ ${STAGES[$i]} ]"
  else
    echo "ERROR: Synthesis failed for stage: [ ${STAGES[$i]} ]"
    STAGE_STATUS=1
  fi
done

if [ ${STAGE_STATUS} -ne 0 ]; then
  echo "Validation failed due to one or more synthesis errors."
  exit 1
fi

SYNTH_OUT="$(pwd)/cdk.out"

# ---------------------------------------------------------------------------
# LAYER 4 (optional): cfn-guard policy compliance
# Runs only when cfn-guard is available AND the config repo ships guard rules.
# Fully opt-in: absent tooling or rules => skipped, never blocks existing flow.
# ---------------------------------------------------------------------------
echo "=========================================================="
echo "LAYER 4: CFN Guard Policy Compliance (optional)"
echo "=========================================================="

GUARD_RULES_DIR="${CONFIG_DIR}/guard-rules"

if ! command -v cfn-guard >/dev/null 2>&1; then
  echo "SKIP: cfn-guard not installed - skipping policy compliance layer."
elif [ ! -d "${GUARD_RULES_DIR}" ] || [ -z "$(ls -A "${GUARD_RULES_DIR}"/*.guard 2>/dev/null)" ]; then
  echo "SKIP: no ${GUARD_RULES_DIR}/*.guard rules found - skipping policy compliance layer."
elif [ ! -d "${SYNTH_OUT}" ]; then
  echo "SKIP: no synth output at ${SYNTH_OUT} - skipping policy compliance layer."
else
  echo "Running cfn-guard against ${SYNTH_OUT} with rules in ${GUARD_RULES_DIR}"
  if cfn-guard validate --data "${SYNTH_OUT}" --rules "${GUARD_RULES_DIR}" --show-summary fail; then
    echo "PASS: All CFN Guard rules satisfied."
  else
    echo "ERROR: CFN Guard policy violations detected."
    exit 1
  fi
fi
print_time

echo "=========================================================="
echo "SUCCESS: All LZA configurations validated and synthesized."
print_time
echo "=========================================================="
