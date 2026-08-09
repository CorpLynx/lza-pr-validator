#!/usr/bin/env bash
#
# lza-uninstall.sh - Thorough Landing Zone Accelerator (LZA) teardown.
#
# Deprovisions ALL AWSAccelerator / aws-accelerator resources across every account
# in the organization and the specified regions, so the org stops incurring LZA cost.
# A fresh `AWSAccelerator-InstallerStack` deploy can then be re-run quickly.
#
# WHAT IT PRESERVES (never touched):
#   - AWS Control Tower (landing zone, controls, AWSControlTower* stacks/StackSets/hooks)
#   - aws-controltower-* buckets, CT-managed Config/CloudTrail, CT IAM roles
#   - IAM Identity Center (SSO)
#   - The org accounts themselves (kept enrolled in Control Tower)
#   - The LZA Config Validator tooling (AWSAccelerator-ConfigValidator*,
#     aws-accelerator-config-validator*) unless --include-validator is passed
#
# WHAT IT REMOVES:
#   - All AWSAccelerator-* CloudFormation stacks (incl. CDKToolkit bootstrap) in every
#     account/region, in dependency-safe order
#   - aws-accelerator-* S3 buckets (all object versions + delete markers)
#   - alias/accelerator/* KMS keys (scheduled for deletion)
#   - /accelerator/* and /cdk-bootstrap/accel/* SSM parameters
#   - AWSAccelerator-* and cdk-accel-* IAM roles
#   - /aws/codebuild/AWSAccelerator-*, /aws/lambda/AWSAccelerator-*, and
#     AWSAccelerator-Module-Verbose-Logs CloudWatch log groups
#   - The aws-accelerator-config CodeCommit repo (if present)
#   - OPTIONAL (--include-org-policies): LZA-created SCPs/RCPs (detached + deleted)
#   - OPTIONAL (--include-security-services): GuardDuty/SecurityHub/Macie org config
#
# SAFETY:
#   - DRY-RUN by default. Nothing is deleted unless you pass --execute.
#   - --execute additionally requires typing the confirmation phrase.
#   - Every destructive action is echoed; in dry-run it is prefixed with "[DRY-RUN]".
#
# USAGE:
#   ./scripts/lza-uninstall.sh [options]
#     --execute                 Actually perform deletions (default: dry-run)
#     --regions "r1 r2"         Space-separated regions (default: us-east-1 us-west-2)
#     --management-role NAME    Cross-account role to assume (default: AWSControlTowerExecution)
#     --prefix NAME             Accelerator prefix (default: AWSAccelerator)
#     --bucket-prefix NAME      Bucket prefix (default: aws-accelerator)
#     --ssm-prefix PATH         SSM prefix (default: /accelerator)
#     --accounts "id1 id2"      Restrict to these account IDs (default: all org accounts)
#     --include-validator       Also remove the Config Validator tooling (default: keep)
#     --include-org-policies    Detach + delete LZA SCPs/RCPs from the org
#     --include-security-services  Disable GuardDuty/SecurityHub/Macie org config
#     --kms-window DAYS         KMS deletion window 7-30 (default: 7)
#     -h | --help               Show this help
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Defaults / arg parsing
# ---------------------------------------------------------------------------
EXECUTE=false
REGIONS="us-east-1 us-west-2"
MGMT_ROLE="AWSControlTowerExecution"
PREFIX="AWSAccelerator"
BUCKET_PREFIX="aws-accelerator"
SSM_PREFIX="/accelerator"
ACCOUNTS_OVERRIDE=""
INCLUDE_VALIDATOR=false
INCLUDE_ORG_POLICIES=false
INCLUDE_SECURITY_SERVICES=false
KMS_WINDOW=7
CONFIRM_PHRASE="DELETE LZA"

# Names that identify the Config Validator tooling (preserved by default).
VALIDATOR_STACK_MATCH="ConfigValidator"
VALIDATOR_BUCKET_MATCH="config-validator"

while [ $# -gt 0 ]; do
  case "$1" in
    --execute) EXECUTE=true ;;
    --regions) REGIONS="$2"; shift ;;
    --management-role) MGMT_ROLE="$2"; shift ;;
    --prefix) PREFIX="$2"; shift ;;
    --bucket-prefix) BUCKET_PREFIX="$2"; shift ;;
    --ssm-prefix) SSM_PREFIX="$2"; shift ;;
    --accounts) ACCOUNTS_OVERRIDE="$2"; shift ;;
    --include-validator) INCLUDE_VALIDATOR=true ;;
    --include-org-policies) INCLUDE_ORG_POLICIES=true ;;
    --include-security-services) INCLUDE_SECURITY_SERVICES=true ;;
    --kms-window) KMS_WINDOW="$2"; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_blu=$'\033[34m'; c_rst=$'\033[0m'
log()  { echo "${c_blu}[*]${c_rst} $*"; }
ok()   { echo "${c_grn}[+]${c_rst} $*"; }
warn() { echo "${c_yel}[!]${c_rst} $*"; }
err()  { echo "${c_red}[x]${c_rst} $*" >&2; }

# Run a mutating command, or print it in dry-run mode.
do_cmd() {
  if [ "$EXECUTE" = true ]; then
    # Commands are pre-composed strings that embed redirections and `||`
    # fallbacks (e.g. role-arn delete with a plain-delete fallback), so eval
    # is required here; array execution would treat the operators as literals.
    # shellcheck disable=SC2294
    eval "$@"
  else
    echo "    ${c_yel}[DRY-RUN]${c_rst} $*"
  fi
}

# ---------------------------------------------------------------------------
# Credential handling - run AWS commands in a given account.
# For the management account we use the caller's credentials; for members we
# assume the management access role. Sets/uses AWS_* env vars per invocation.
# ---------------------------------------------------------------------------
MGMT_ACCOUNT_ID=""
assume_into() {
  # $1 = account id. Exports temp creds unless it's the management account.
  local acct="$1"
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  if [ "$acct" = "$MGMT_ACCOUNT_ID" ]; then
    return 0
  fi
  local creds
  creds=$(aws sts assume-role \
    --role-arn "arn:${PARTITION}:iam::${acct}:role/${MGMT_ROLE}" \
    --role-session-name lza-uninstall --output json 2>/dev/null)
  if [ -z "$creds" ] || ! echo "$creds" | jq -e '.Credentials' >/dev/null 2>&1; then
    err "Could not assume ${MGMT_ROLE} in ${acct}; skipping account."
    return 1
  fi
  AWS_ACCESS_KEY_ID=$(echo "$creds" | jq -r '.Credentials.AccessKeyId')
  AWS_SECRET_ACCESS_KEY=$(echo "$creds" | jq -r '.Credentials.SecretAccessKey')
  AWS_SESSION_TOKEN=$(echo "$creds" | jq -r '.Credentials.SessionToken')
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  return 0
}
clear_creds() { unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; }

# Should this named resource be preserved because it's the validator tooling?
is_validator() {
  [ "$INCLUDE_VALIDATOR" = true ] && return 1   # not preserved when including validator
  case "$1" in
    *"$VALIDATOR_STACK_MATCH"*|*"$VALIDATOR_BUCKET_MATCH"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ===========================================================================
# Resource teardown functions (operate in the currently-assumed account/region)
# ===========================================================================

# --- Ensure a CloudFormation deletion role exists (fallback for stacks whose
#     original cdk-accel-cfn-exec-role was already removed). ---
DELETION_ROLE_NAME="lza-uninstall-cfn-deletion-role"
DELETION_ROLE_ARN=""
ensure_deletion_role() {
  local acct="$1"
  DELETION_ROLE_ARN="arn:${PARTITION}:iam::${acct}:role/${DELETION_ROLE_NAME}"
  if aws iam get-role --role-name "$DELETION_ROLE_NAME" >/dev/null 2>&1; then
    return 0
  fi
  log "Creating temporary CFN deletion role ${DELETION_ROLE_NAME} in ${acct}"
  local trust='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"cloudformation.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  do_cmd "aws iam create-role --role-name '$DELETION_ROLE_NAME' --assume-role-policy-document '$trust' >/dev/null"
  do_cmd "aws iam attach-role-policy --role-name '$DELETION_ROLE_NAME' --policy-arn arn:${PARTITION}:iam::aws:policy/AdministratorAccess"
  [ "$EXECUTE" = true ] && sleep 8   # IAM propagation
}
cleanup_deletion_role() {
  if aws iam get-role --role-name "$DELETION_ROLE_NAME" >/dev/null 2>&1; then
    log "Removing temporary CFN deletion role ${DELETION_ROLE_NAME}"
    do_cmd "aws iam detach-role-policy --role-name '$DELETION_ROLE_NAME' --policy-arn arn:${PARTITION}:iam::aws:policy/AdministratorAccess"
    do_cmd "aws iam delete-role --role-name '$DELETION_ROLE_NAME'"
  fi
}

# List AWSAccelerator-* stacks in a region, excluding CDKToolkit and (optionally) the validator.
list_lza_stacks() {
  local region="$1"
  aws cloudformation list-stacks --region "$region" \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
      ROLLBACK_COMPLETE IMPORT_COMPLETE UPDATE_ROLLBACK_FAILED CREATE_FAILED DELETE_FAILED \
    --query "StackSummaries[?starts_with(StackName, '${PREFIX}-')].StackName" \
    --output text 2>/dev/null | tr '\t' '\n' | while read -r s; do
      [ -z "$s" ] && continue
      [ "$s" = "${PREFIX}-CDKToolkit" ] && continue
      if is_validator "$s"; then continue; fi
      echo "$s"
  done
}

delete_stack() {
  local region="$1" stack="$2"
  # Disable termination protection (best-effort)
  do_cmd "aws cloudformation update-termination-protection --no-enable-termination-protection --stack-name '$stack' --region '$region' >/dev/null 2>&1 || true"
  # Try a normal delete first; fall back to the deletion role if the stored role is gone.
  do_cmd "aws cloudformation delete-stack --stack-name '$stack' --region '$region' --role-arn '$DELETION_ROLE_ARN' 2>/dev/null || aws cloudformation delete-stack --stack-name '$stack' --region '$region'"
}

# Delete all LZA stacks in a region using a dependency-resolving retry loop.
teardown_stacks_in_region() {
  local region="$1"
  local pass line
  local stacks
  for pass in 1 2 3 4 5 6; do
    # Populate the stacks array portably (macOS bash 3.2 has no mapfile).
    stacks=()
    while IFS= read -r line; do
      [ -n "$line" ] && stacks+=("$line")
    done < <(list_lza_stacks "$region")
    if [ "${#stacks[@]}" -eq 0 ]; then break; fi
    log "Region ${region}: pass ${pass} - ${#stacks[@]} ${PREFIX} stack(s) to delete"
    for s in "${stacks[@]}"; do
      echo "  - deleting stack: $s"
      delete_stack "$region" "$s"
    done
    if [ "$EXECUTE" = true ]; then
      # Wait for this pass's deletions to settle; retry DELETE_FAILED with retain-resources.
      for s in "${stacks[@]}"; do
        aws cloudformation wait stack-delete-complete --stack-name "$s" --region "$region" 2>/dev/null
        local status
        status=$(aws cloudformation describe-stacks --stack-name "$s" --region "$region" \
                  --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "GONE")
        if [ "$status" = "DELETE_FAILED" ]; then
          local retain
          retain=$(aws cloudformation describe-stack-events --stack-name "$s" --region "$region" \
                    --query "StackEvents[?ResourceStatus=='DELETE_FAILED'].LogicalResourceId" \
                    --output text 2>/dev/null | tr '\t' ' ')
          if [ -n "$retain" ]; then
            warn "Stack $s DELETE_FAILED; retrying while retaining: $retain"
            local retain_ids
            read -ra retain_ids <<< "$retain"
            aws cloudformation delete-stack --stack-name "$s" --region "$region" \
              --role-arn "$DELETION_ROLE_ARN" --retain-resources "${retain_ids[@]}" 2>/dev/null || true
            aws cloudformation wait stack-delete-complete --stack-name "$s" --region "$region" 2>/dev/null
          fi
        fi
      done
    else
      # Dry-run: only one pass is meaningful.
      break
    fi
  done

  # Finally delete the CDKToolkit bootstrap stack (last - others depend on it).
  local cdktoolkit="${PREFIX}-CDKToolkit"
  if aws cloudformation describe-stacks --stack-name "$cdktoolkit" --region "$region" >/dev/null 2>&1; then
    echo "  - deleting bootstrap stack: $cdktoolkit"
    delete_stack "$region" "$cdktoolkit"
    [ "$EXECUTE" = true ] && aws cloudformation wait stack-delete-complete --stack-name "$cdktoolkit" --region "$region" 2>/dev/null
  fi
}

# Empty (all versions + delete markers) and delete aws-accelerator-* buckets.
teardown_buckets() {
  local buckets
  buckets=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, '${BUCKET_PREFIX}-')].Name" --output text 2>/dev/null | tr '\t' '\n')
  for b in $buckets; do
    [ -z "$b" ] && continue
    if is_validator "$b"; then log "Preserving validator bucket: $b"; continue; fi
    echo "  - emptying + deleting bucket: $b"
    if [ "$EXECUTE" = true ]; then
      # delete all object versions
      local vers
      vers=$(aws s3api list-object-versions --bucket "$b" --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null)
      if [ -n "$vers" ] && [ "$(echo "$vers" | jq -r '.Objects')" != "null" ]; then
        aws s3api delete-objects --bucket "$b" --delete "$vers" >/dev/null 2>&1 || true
      fi
      # delete all delete-markers
      local marks
      marks=$(aws s3api list-object-versions --bucket "$b" --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null)
      if [ -n "$marks" ] && [ "$(echo "$marks" | jq -r '.Objects')" != "null" ]; then
        aws s3api delete-objects --bucket "$b" --delete "$marks" >/dev/null 2>&1 || true
      fi
      aws s3 rm "s3://$b" --recursive >/dev/null 2>&1 || true
      aws s3api delete-bucket --bucket "$b" 2>/dev/null || warn "Could not delete bucket $b (may have a retain policy or remaining objects)"
    else
      echo "    ${c_yel}[DRY-RUN]${c_rst} would empty all versions and delete s3://$b"
    fi
  done
}

# Schedule deletion of alias/accelerator/* customer KMS keys in a region.
teardown_kms() {
  local region="$1"
  local aliases
  aliases=$(aws kms list-aliases --region "$region" \
    --query "Aliases[?starts_with(AliasName, 'alias/${SSM_PREFIX#/}/') || starts_with(AliasName, 'alias/accelerator/')].[AliasName,TargetKeyId]" \
    --output text 2>/dev/null)
  echo "$aliases" | while read -r alias keyid; do
    [ -z "${keyid:-}" ] && continue
    # skip keys with no target or already pending deletion
    local state
    state=$(aws kms describe-key --key-id "$keyid" --region "$region" --query "KeyMetadata.KeyState" --output text 2>/dev/null || echo "")
    if [ "$state" = "PendingDeletion" ] || [ -z "$state" ]; then continue; fi
    echo "  - scheduling KMS key deletion: $alias ($keyid) [${KMS_WINDOW}d]"
    do_cmd "aws kms schedule-key-deletion --key-id '$keyid' --pending-window-in-days '$KMS_WINDOW' --region '$region' >/dev/null 2>&1 || true"
    do_cmd "aws kms delete-alias --alias-name '$alias' --region '$region' 2>/dev/null || true"
  done
}

# Delete /accelerator/* and /cdk-bootstrap/accel/* SSM parameters in a region.
teardown_ssm() {
  local region="$1"
  local params
  params=$(aws ssm get-parameters-by-path --path "$SSM_PREFIX" --recursive --region "$region" \
            --query "Parameters[].Name" --output text 2>/dev/null | tr '\t' '\n')
  # add cdk-bootstrap accel version param
  params="$params
/cdk-bootstrap/accel/version"
  for p in $params; do
    [ -z "$p" ] && continue
    if is_validator "$p"; then log "Preserving validator SSM param: $p"; continue; fi
    echo "  - deleting SSM parameter: $p"
    do_cmd "aws ssm delete-parameter --name '$p' --region '$region' 2>/dev/null || true"
  done
}

# Delete AWSAccelerator-* and cdk-accel-* IAM roles (global; run once per account).
teardown_iam_roles() {
  local roles
  roles=$(aws iam list-roles --query "Roles[?starts_with(RoleName, '${PREFIX}-') || starts_with(RoleName, 'cdk-accel-')].RoleName" --output text 2>/dev/null | tr '\t' '\n')
  for r in $roles; do
    [ -z "$r" ] && continue
    if is_validator "$r"; then log "Preserving validator role: $r"; continue; fi
    echo "  - deleting IAM role: $r"
    if [ "$EXECUTE" = true ]; then
      # detach managed policies
      for arn in $(aws iam list-attached-role-policies --role-name "$r" --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null); do
        aws iam detach-role-policy --role-name "$r" --policy-arn "$arn" 2>/dev/null || true
      done
      # delete inline policies
      for pol in $(aws iam list-role-policies --role-name "$r" --query "PolicyNames[]" --output text 2>/dev/null); do
        aws iam delete-role-policy --role-name "$r" --policy-name "$pol" 2>/dev/null || true
      done
      # remove instance profiles
      for ip in $(aws iam list-instance-profiles-for-role --role-name "$r" --query "InstanceProfiles[].InstanceProfileName" --output text 2>/dev/null); do
        aws iam remove-role-from-instance-profile --instance-profile-name "$ip" --role-name "$r" 2>/dev/null || true
      done
      aws iam delete-role --role-name "$r" 2>/dev/null || warn "Could not delete role $r"
    else
      echo "    ${c_yel}[DRY-RUN]${c_rst} would detach policies and delete role $r"
    fi
  done
}

# Delete LZA CloudWatch log groups in a region.
teardown_log_groups() {
  local region="$1"
  local prefixes=("/aws/codebuild/${PREFIX}-" "/aws/lambda/${PREFIX}-" "${PREFIX}-Module")
  for lp in "${prefixes[@]}"; do
    for lg in $(aws logs describe-log-groups --log-group-name-prefix "$lp" --region "$region" --query "logGroups[].logGroupName" --output text 2>/dev/null | tr '\t' '\n'); do
      [ -z "$lg" ] && continue
      if is_validator "$lg"; then continue; fi
      echo "  - deleting log group: $lg"
      do_cmd "aws logs delete-log-group --log-group-name '$lg' --region '$region' 2>/dev/null || true"
    done
  done
}

# Delete the LZA config CodeCommit repo if present (management account).
teardown_codecommit() {
  local region="$1"
  local repo="${BUCKET_PREFIX}-config"
  if aws codecommit get-repository --repository-name "$repo" --region "$region" >/dev/null 2>&1; then
    echo "  - deleting CodeCommit repo: $repo"
    do_cmd "aws codecommit delete-repository --repository-name '$repo' --region '$region' >/dev/null 2>&1 || true"
  fi
}

# OPTIONAL: detach + delete LZA-created SCPs/RCPs (management account, org level).
teardown_org_policies() {
  log "Org policy teardown (SCPs/RCPs)"
  for ptype in SERVICE_CONTROL_POLICY RESOURCE_CONTROL_POLICY; do
    local pols
    pols=$(aws organizations list-policies --filter "$ptype" \
            --query "Policies[?!contains(['FullAWSAccess'], Name)].[Id,Name]" --output text 2>/dev/null)
    echo "$pols" | while read -r pid pname; do
      [ -z "${pid:-}" ] && continue
      # Only remove customer-managed LZA policies (skip AWS-managed FullAWSAccess).
      [ "$pname" = "FullAWSAccess" ] && continue
      echo "  - $ptype $pname ($pid): detaching from all targets, then deleting"
      if [ "$EXECUTE" = true ]; then
        for tgt in $(aws organizations list-targets-for-policy --policy-id "$pid" --query "Targets[].TargetId" --output text 2>/dev/null); do
          aws organizations detach-policy --policy-id "$pid" --target-id "$tgt" 2>/dev/null || true
        done
        aws organizations delete-policy --policy-id "$pid" 2>/dev/null || warn "Could not delete policy $pid"
      else
        echo "    ${c_yel}[DRY-RUN]${c_rst} would detach + delete $ptype $pname"
      fi
    done
  done
  warn "Note: this removes ALL customer-managed SCPs/RCPs. If some are not LZA's, narrow the filter."
}

# OPTIONAL: disable GuardDuty / SecurityHub / Macie org config in a region.
teardown_security_services() {
  local region="$1"
  warn "Security-service teardown in ${region} (GuardDuty/SecurityHub/Macie)."
  warn "Control Tower may re-enable some of these; review CT controls afterward."

  # GuardDuty: delete detectors in this account/region.
  for det in $(aws guardduty list-detectors --region "$region" --query "DetectorIds[]" --output text 2>/dev/null | tr '\t' '\n'); do
    [ -z "$det" ] && continue
    echo "  - GuardDuty: deleting detector $det"
    do_cmd "aws guardduty delete-detector --detector-id '$det' --region '$region' 2>/dev/null || true"
  done

  # SecurityHub: disable in this account/region.
  if aws securityhub get-enabled-standards --region "$region" >/dev/null 2>&1; then
    echo "  - SecurityHub: disabling"
    do_cmd "aws securityhub disable-security-hub --region '$region' 2>/dev/null || true"
  fi

  # Macie: disable in this account/region.
  local macie_status
  macie_status=$(aws macie2 get-macie-session --region "$region" --query "status" --output text 2>/dev/null || echo "")
  if [ -n "$macie_status" ] && [ "$macie_status" != "None" ]; then
    echo "  - Macie: disabling"
    do_cmd "aws macie2 disable-macie --region '$region' 2>/dev/null || true"
  fi
}

# ===========================================================================
# Main
# ===========================================================================
main() {
  command -v jq >/dev/null 2>&1 || { err "jq is required"; exit 1; }

  # Identity + partition
  local ident
  ident=$(aws sts get-caller-identity --output json 2>/dev/null) || { err "Unable to call sts:GetCallerIdentity - check credentials"; exit 1; }
  MGMT_ACCOUNT_ID=$(echo "$ident" | jq -r '.Account')
  PARTITION=$(echo "$ident" | jq -r '.Arn' | cut -d: -f2)
  export PARTITION

  # Account list
  local accounts
  if [ -n "$ACCOUNTS_OVERRIDE" ]; then
    accounts="$ACCOUNTS_OVERRIDE"
  else
    accounts=$(aws organizations list-accounts --query "Accounts[?Status=='ACTIVE'].Id" --output text 2>/dev/null | tr '\t' ' ')
    [ -z "$accounts" ] && accounts="$MGMT_ACCOUNT_ID"
  fi

  # Banner
  echo "============================================================"
  echo " LZA UNINSTALLER"
  echo "============================================================"
  echo " Mode              : $([ "$EXECUTE" = true ] && echo "${c_red}EXECUTE (destructive)${c_rst}" || echo "${c_grn}DRY-RUN${c_rst}")"
  echo " Management account: $MGMT_ACCOUNT_ID   partition: $PARTITION"
  echo " Regions           : $REGIONS"
  echo " Accounts          : $accounts"
  echo " Cross-account role: $MGMT_ROLE"
  echo " Prefixes          : $PREFIX / $BUCKET_PREFIX / $SSM_PREFIX"
  echo " Keep validator    : $([ "$INCLUDE_VALIDATOR" = true ] && echo no || echo yes)"
  echo " Org policies       : $INCLUDE_ORG_POLICIES    Security services: $INCLUDE_SECURITY_SERVICES"
  echo " Preserves         : Control Tower, IAM Identity Center, org accounts"
  echo "============================================================"

  if [ "$EXECUTE" = true ]; then
    warn "This will PERMANENTLY delete LZA resources across the org."
    printf "Type '%s' to proceed: " "$CONFIRM_PHRASE"
    read -r reply
    [ "$reply" = "$CONFIRM_PHRASE" ] || { err "Confirmation mismatch; aborting."; exit 1; }
  fi

  # Per-account teardown
  for acct in $accounts; do
    echo ""
    echo "------------------------------------------------------------"
    echo " ACCOUNT: $acct"
    echo "------------------------------------------------------------"
    if ! assume_into "$acct"; then continue; fi

    ensure_deletion_role "$acct"

    # Regional resources: stacks, KMS, SSM, logs, (security services)
    for region in $REGIONS; do
      log "[$acct/$region] CloudFormation stacks"
      teardown_stacks_in_region "$region"
      log "[$acct/$region] KMS keys"
      teardown_kms "$region"
      log "[$acct/$region] SSM parameters"
      teardown_ssm "$region"
      log "[$acct/$region] CloudWatch log groups"
      teardown_log_groups "$region"
      if [ "$acct" = "$MGMT_ACCOUNT_ID" ]; then
        teardown_codecommit "$region"
      fi
      if [ "$INCLUDE_SECURITY_SERVICES" = true ]; then
        teardown_security_services "$region"
      fi
    done

    # Global resources: S3 buckets, IAM roles
    log "[$acct] S3 buckets"
    teardown_buckets
    log "[$acct] IAM roles"
    teardown_iam_roles

    cleanup_deletion_role
    clear_creds
  done

  # Org-level (management account, once)
  if [ "$INCLUDE_ORG_POLICIES" = true ]; then
    echo ""
    echo "------------------------------------------------------------"
    echo " ORG-LEVEL POLICIES (management account)"
    echo "------------------------------------------------------------"
    assume_into "$MGMT_ACCOUNT_ID"
    teardown_org_policies
    clear_creds
  fi

  echo ""
  ok "LZA uninstall $([ "$EXECUTE" = true ] && echo "complete" || echo "dry-run complete (no changes made)")."
  echo "Control Tower, IAM Identity Center, and org accounts were preserved."
  [ "$INCLUDE_VALIDATOR" = false ] && echo "The Config Validator tooling was preserved (pass --include-validator to remove it)."
  echo "KMS keys are scheduled for deletion (${KMS_WINDOW}-day window) and can be cancelled before then."
}

main "$@"
