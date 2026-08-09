#!/usr/bin/env bash
set -eo pipefail

CONFIG_DIR="${1:-$CODEBUILD_SRC_DIR}"
LZA_VERSION="${LZA_VERSION:-v1.16.0}"
AWS_PARTITION="${AWS_PARTITION:-aws}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
LZA_SOURCE_BUCKET="${LZA_SOURCE_BUCKET:-}"
WORK_DIR="/tmp/lza-validation"
START_TIME=$(date +%s)

trap 'echo "ERROR: Validation failed at line $LINENO. See logs above for details." >&2' ERR

print_time() {
  local END_TIME=$(date +%s)
  local ELAPSED=$((END_TIME - START_TIME))
  echo "--> Elapsed time: ${ELAPSED}s"
}

echo "=========================================================="
echo "LAYER 1: YAML Syntax Validation (yamllint)"
echo "=========================================================="
yamllint -d "{extends: default, rules: {line-length: disable, document-start: disable}}" "${CONFIG_DIR}/"
echo "PASS: YAML syntax validation succeeded."
print_time

echo "=========================================================="
echo "LAYER 2: LZA Schema & Cross-Reference Validation"
echo "=========================================================="

# Assume the LZA Validator Synth Role for AWS API access (validate-config and CDK synth)
if [ -n "${LZA_SYNTH_ROLE_ARN}" ]; then
  echo "Assuming synth role: ${LZA_SYNTH_ROLE_ARN}"
  CREDS=$(aws sts assume-role --role-arn "${LZA_SYNTH_ROLE_ARN}" --role-session-name lza-validator-synth --output json)
  export AWS_ACCESS_KEY_ID=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['AccessKeyId'])")
  export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['SecretAccessKey'])")
  export AWS_SESSION_TOKEN=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['SessionToken'])")
fi

mkdir -p "${WORK_DIR}"

if [ -f "${WORK_DIR}/lza-source/source/package.json" ]; then
  echo "Removing stale LZA source to ensure clean build..."
  rm -rf "${WORK_DIR}/lza-source"
fi

rm -rf "${WORK_DIR}/lza-source"
if [ -n "${LZA_SOURCE_BUCKET}" ]; then
  echo "Downloading LZA source bundle from s3://${LZA_SOURCE_BUCKET}/lza-${LZA_VERSION}.tar.gz..."
  mkdir -p "${WORK_DIR}/lza-source"
  aws s3 cp "s3://${LZA_SOURCE_BUCKET}/lza-${LZA_VERSION}.tar.gz" - | tar -xz -C "${WORK_DIR}/lza-source" --warning=no-unknown-keyword 2>/dev/null
else
  echo "LZA_SOURCE_BUCKET not set, falling back to git clone (${LZA_VERSION})..."
  git clone --depth 1 --branch "${LZA_VERSION}" https://github.com/awslabs/landing-zone-accelerator-on-aws.git "${WORK_DIR}/lza-source"
fi

cd "${WORK_DIR}/lza-source/source"

# Skip install/build if pre-built (dist/ directories exist)
if [ -d "packages/@aws-accelerator/accelerator/dist" ]; then
  echo "Pre-built bundle detected — skipping install and build."
else
  echo "Installing dependencies and compiling core packages..."
  yarn install --frozen-lockfile --silent
  yarn build
fi

echo "Executing yarn validate-config against: ${CONFIG_DIR}"
yarn validate-config "${CONFIG_DIR}"
echo "PASS: Schema and cross-reference validation succeeded."
print_time

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
    --partition "${AWS_PARTITION}" \
    --account "${AWS_ACCOUNT_ID}" \
    --region "${AWS_DEFAULT_REGION}" &
    
  PIDS+=($!)
done

echo "Waiting for all stages to complete..."

for i in "${!PIDS[@]}"; do
  wait "${PIDS[$i]}"
  EXIT_CODE=$?
  if [ $EXIT_CODE -ne 0 ]; then
    echo "ERROR: Synthesis failed for stage: [ ${STAGES[$i]} ]"
    STAGE_STATUS=1
  else
    echo "PASS: Synthesis succeeded for stage: [ ${STAGES[$i]} ]"
  fi
done

if [ $STAGE_STATUS -ne 0 ]; then
  echo "Validation failed due to one or more synthesis errors."
  exit 1
fi

echo "=========================================================="
echo "SUCCESS: All LZA configurations validated and synthesized."
print_time
echo "=========================================================="