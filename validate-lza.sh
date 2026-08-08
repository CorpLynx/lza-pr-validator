#!/usr/bin/env bash
set -eo pipefail

CONFIG_DIR="${1:-$CODEBUILD_SRC_DIR}"
LZA_VERSION="${LZA_VERSION:-v1.16.0}"
AWS_PARTITION="${AWS_PARTITION:-aws}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
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
mkdir -p "${WORK_DIR}"

if [ -d "${WORK_DIR}/lza-source/.git" ] && [ "$(cd "${WORK_DIR}/lza-source" && git describe --tags --always)" = "${LZA_VERSION}" ]; then
  echo "Using cached LZA source code (${LZA_VERSION})..."
else
  echo "Cloning AWS LZA repository (${LZA_VERSION})..."
  rm -rf "${WORK_DIR}/lza-source"
  git clone --depth 1 --branch "${LZA_VERSION}" https://github.com/awslabs/landing-zone-accelerator-on-aws.git "${WORK_DIR}/lza-source"
fi

cd "${WORK_DIR}/lza-source/source"
echo "Installing dependencies and compiling core packages..."
yarn install --frozen-lockfile --silent
yarn build

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