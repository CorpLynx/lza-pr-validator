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
#   - In dry-run each resource is listed as "would remove ..."; in --execute mode
#     deletions stream live with per-resource progress, a spinner, and timing.
#   - Set NO_COLOR=1 (or pipe/redirect the output) for plain, undecorated logs.
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

# Runtime globals (initialised for `set -u`).
PARTITION=""
MGMT_ACCOUNT_ID=""
START_TS=0

# Per-category tallies for the closing summary.
STAT_STACKS=0
STAT_BUCKETS=0
STAT_KMS=0
STAT_SSM=0
STAT_IAM=0
STAT_LOGS=0
STAT_CC=0
STAT_ORG=0
STAT_SEC=0
STAT_PRESERVED=0
STAT_FAILED=0

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
# Presentation layer: capability detection (color / unicode / TTY)
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
  TTY=1
  c_red=$'\033[31m';  c_grn=$'\033[32m'; c_yel=$'\033[33m'
  c_blu=$'\033[34m';  c_mag=$'\033[35m'; c_cyn=$'\033[36m'
  c_dim=$'\033[2m';   c_bold=$'\033[1m'; c_rst=$'\033[0m'
else
  TTY=0
  c_red=""; c_grn=""; c_yel=""; c_blu=""; c_mag=""; c_cyn=""
  c_dim=""; c_bold=""; c_rst=""
fi

case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf-8*|*UTF8*|*utf8*) UNI=1 ;;
  *) UNI=0 ;;
esac
[ "$TTY" = 1 ] || UNI=0   # keep redirected/CI output as plain ASCII

if [ "$UNI" = 1 ]; then
  G_OK="✔"; G_NO="✖"; G_ARROW="➜"; G_BULLET="●"; G_KEEP="◦"
  G_WARN="▲"; G_DRY="○"; G_INFO="›"
  BOX_H="═"; BAR="━"; DOT="┄"
  SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
else
  G_OK="[ok]"; G_NO="[XX]"; G_ARROW="->"; G_BULLET="*"; G_KEEP="[keep]"
  G_WARN="[!]"; G_DRY="~"; G_INFO=">"
  BOX_H="="; BAR="-"; DOT="."
  SPIN_FRAMES=('|' '/' '-' "\\")
fi

SPIN_I=0
spin() {
  SPIN_I=$(( (SPIN_I + 1) % ${#SPIN_FRAMES[@]} ))
  printf "%s" "${SPIN_FRAMES[$SPIN_I]}"
}

ts() { date "+%H:%M:%S"; }

# Build a horizontal rule string of width $1 using char $2 (no trailing newline).
rule() {
  local n="${1:-60}" ch="${2:-$BAR}" i=0 s=""
  while [ "$i" -lt "$n" ]; do s="$s$ch"; i=$((i + 1)); done
  printf "%s" "$s"
}

# ---------------------------------------------------------------------------
# Message helpers
# ---------------------------------------------------------------------------
log()  { printf "  %s%s%s %s\n"  "$c_cyn" "$G_BULLET" "$c_rst" "$*"; }
ok()   { printf "%s%s%s %s\n"    "$c_grn" "$G_OK"     "$c_rst" "$*"; }
warn() { printf "  %s%s%s %s%s%s\n" "$c_yel" "$G_WARN" "$c_rst" "$c_yel" "$*" "$c_rst"; }
err()  { printf "%s%s%s %s\n"    "$c_red" "$G_NO"     "$c_rst" "$*" >&2; }

# A category heading inside an account/region (e.g. "CloudFormation stacks").
category() {
  printf "\n  %s%s%s %s%s%s\n" "$c_cyn" "$G_BULLET" "$c_rst" "$c_bold" "$1" "$c_rst"
}

# Region sub-heading.
region_hdr() {
  printf "\n  %s%s %s region %s %s%s\n" \
    "$c_blu" "$DOT$DOT" "$c_bold" "$1" "$c_blu$DOT$DOT" "$c_rst"
}

# Account banner.
account_header() {
  local id="$1" name="$2" label
  if [ -n "$name" ] && [ "$name" != "None" ]; then
    label="ACCOUNT  $id   ($name)"
  else
    label="ACCOUNT  $id"
  fi
  printf "\n%s%s%s\n"   "$c_mag" "$(rule 62 "$BAR")" "$c_rst"
  printf "  %s%s%s%s\n" "$c_bold" "$c_mag" "$label" "$c_rst"
  printf "%s%s%s\n"     "$c_mag" "$(rule 62 "$BAR")" "$c_rst"
}

# A "preserved / skipped" line (validator, etc.).
preserved() {
  printf "    %s%s preserved%s %s%s%s\n" "$c_cyn" "$G_KEEP" "$c_rst" "$c_dim" "$1" "$c_rst"
  STAT_PRESERVED=$((STAT_PRESERVED + 1))
}

# A dry-run "would remove X" line (for flows not routed through run_del).
plan_line() {
  printf "    %s%s%s remove %s\n" "$c_yel" "$G_DRY" "$c_rst" "$1"
}

# ---------------------------------------------------------------------------
# Action runners
#   _run <plan-label> <do-label> <command...>
#     dry-run : prints "○ <plan-label>"
#     execute : prints "[ts] ➜ <do-label> ... ✔|✖" and returns the command status
# ---------------------------------------------------------------------------
_run() {
  local plan_label="$1" do_label="$2"; shift 2
  if [ "$EXECUTE" = true ]; then
    printf "    %s[%s]%s %s%s%s %s ... " \
      "$c_dim" "$(ts)" "$c_rst" "$c_yel" "$G_ARROW" "$c_rst" "$do_label"
    # Commands are pre-composed strings (single-quoted args); eval runs them.
    # shellcheck disable=SC2294
    if eval "$@" >/dev/null 2>&1; then
      printf "%s%s%s\n" "$c_grn" "$G_OK" "$c_rst"
      return 0
    fi
    printf "%s%s%s\n" "$c_red" "$G_NO" "$c_rst"
    return 1
  fi
  printf "    %s%s%s %s\n" "$c_yel" "$G_DRY" "$c_rst" "$plan_label"
  return 0
}
# Deletion helper: run_del "<noun>" "<command>"
run_del() { local n="$1"; shift; _run "remove $n" "removing $n" "$@"; }
# Setup/other action helper: run_act "<plan phrase>" "<do phrase>" "<command>"
run_act() { local p="$1" d="$2"; shift 2; _run "$p" "$d" "$@"; }

# Format seconds as e.g. "2m14s" / "9s".
fmt_elapsed() {
  local s="$1" m
  m=$((s / 60)); s=$((s % 60))
  if [ "$m" -gt 0 ]; then printf "%dm%ds" "$m" "$s"; else printf "%ds" "$s"; fi
}

# ---------------------------------------------------------------------------
# Credential handling - run AWS commands in a given account.
# For the management account we use the caller's credentials; for members we
# assume the management access role. Sets/uses AWS_* env vars per invocation.
# ---------------------------------------------------------------------------
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

# Best-effort friendly account name (uses management-account org read access).
acct_name() {
  aws organizations describe-account --account-id "$1" \
    --query "Account.Name" --output text 2>/dev/null || echo ""
}

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
  local trust='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"cloudformation.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  run_act "create temp CFN deletion role ${DELETION_ROLE_NAME}" \
          "create temp CFN deletion role ${DELETION_ROLE_NAME}" \
          "aws iam create-role --role-name '$DELETION_ROLE_NAME' --assume-role-policy-document '$trust'"
  run_act "attach AdministratorAccess to ${DELETION_ROLE_NAME}" \
          "attach AdministratorAccess to ${DELETION_ROLE_NAME}" \
          "aws iam attach-role-policy --role-name '$DELETION_ROLE_NAME' --policy-arn arn:${PARTITION}:iam::aws:policy/AdministratorAccess"
  if [ "$EXECUTE" = true ]; then sleep 8; fi   # IAM propagation
}
cleanup_deletion_role() {
  if aws iam get-role --role-name "$DELETION_ROLE_NAME" >/dev/null 2>&1; then
    run_act "remove temp CFN deletion role ${DELETION_ROLE_NAME}" \
            "remove temp CFN deletion role ${DELETION_ROLE_NAME}" \
            "aws iam detach-role-policy --role-name '$DELETION_ROLE_NAME' --policy-arn arn:${PARTITION}:iam::aws:policy/AdministratorAccess; aws iam delete-role --role-name '$DELETION_ROLE_NAME'"
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

# Issue (best-effort) deletion of a single stack: disable termination protection,
# then delete via the fallback deletion role, else a plain delete.
issue_stack_delete() {
  local region="$1" stack="$2"
  aws cloudformation update-termination-protection --no-enable-termination-protection \
    --stack-name "$stack" --region "$region" >/dev/null 2>&1 || true
  aws cloudformation delete-stack --stack-name "$stack" --region "$region" \
    --role-arn "$DELETION_ROLE_ARN" >/dev/null 2>&1 \
    || aws cloudformation delete-stack --stack-name "$stack" --region "$region" >/dev/null 2>&1 \
    || true
}

# Watch a single stack delete, streaming each resource as it is removed, with a
# live spinner + elapsed timer on a TTY (plain periodic output otherwise).
# Returns 0 on DELETE_COMPLETE/GONE, 1 on DELETE_FAILED/timeout.
watch_stack_deletion() {
  local region="$1" stack="$2"
  local start now elapsed status events lid rtype reported t
  start=$(date +%s)
  reported=" "
  printf "    %s%s%s deleting %s%s%s\n" "$c_yel" "$G_ARROW" "$c_rst" "$c_bold" "$stack" "$c_rst"
  while :; do
    status=$(aws cloudformation describe-stacks --stack-name "$stack" --region "$region" \
             --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "GONE")
    events=$(aws cloudformation describe-stack-events --stack-name "$stack" --region "$region" \
             --query "reverse(StackEvents[?ResourceStatus=='DELETE_COMPLETE'].[LogicalResourceId,ResourceType])" \
             --output text 2>/dev/null || echo "")

    [ "$TTY" = 1 ] && printf "\r\033[K"
    if [ -n "$events" ] && [ "$events" != "None" ]; then
      while IFS=$'\t' read -r lid rtype; do
        [ -z "$lid" ] && continue
        case "$reported" in
          *" ${lid}|${rtype} "*) : ;;
          *)
            reported="${reported}${lid}|${rtype} "
            printf "        %s%s%s %s%-38s%s %s%s%s\n" \
              "$c_grn" "$G_OK" "$c_rst" "$c_dim" "$rtype" "$c_rst" "" "$lid" ""
            ;;
        esac
      done <<< "$events"
    fi

    now=$(date +%s); elapsed=$((now - start))
    case "$status" in
      DELETE_COMPLETE|GONE)
        printf "      %s%s%s %s%s%s removed %s(%s)%s\n" \
          "$c_grn" "$G_OK" "$c_rst" "$c_bold" "$stack" "$c_rst" \
          "$c_dim" "$(fmt_elapsed "$elapsed")" "$c_rst"
        return 0 ;;
      DELETE_FAILED)
        printf "      %s%s%s %s%s%s DELETE_FAILED %s(%s)%s\n" \
          "$c_red" "$G_NO" "$c_rst" "$c_bold" "$stack" "$c_rst" \
          "$c_dim" "$(fmt_elapsed "$elapsed")" "$c_rst"
        return 1 ;;
    esac
    if [ "$elapsed" -gt 1800 ]; then
      warn "Timed out waiting on ${stack} after 30m."
      return 1
    fi

    # Idle animation: spin smoothly on a TTY without hammering the API.
    if [ "$TTY" = 1 ]; then
      t=0
      while [ "$t" -lt 10 ]; do
        now=$(date +%s); elapsed=$((now - start))
        printf "\r      %s%s%s %sdeleting %s%s %s(%s)%s " \
          "$c_yel" "$(spin)" "$c_rst" "$c_yel" "$stack" "$c_rst" \
          "$c_dim" "$(fmt_elapsed "$elapsed")" "$c_rst"
        sleep 0.3
        t=$((t + 1))
      done
    else
      sleep 3
    fi
  done
}

# Delete all LZA stacks in a region using a dependency-resolving retry loop.
teardown_stacks_in_region() {
  local region="$1"
  local pass line stacks s
  for pass in 1 2 3 4 5 6; do
    # Populate the stacks array portably (macOS bash 3.2 has no mapfile).
    stacks=()
    while IFS= read -r line; do
      [ -n "$line" ] && stacks+=("$line")
    done < <(list_lza_stacks "$region")
    if [ "${#stacks[@]}" -eq 0 ]; then break; fi
    printf "    %s%s%s pass %d %s%d stack(s)%s\n" \
      "$c_dim" "$G_INFO" "$c_rst" "$pass" "$c_dim" "${#stacks[@]}" "$c_rst"

    if [ "$EXECUTE" = true ]; then
      # Fire all deletions in this pass (they run in parallel), then watch each.
      for s in "${stacks[@]}"; do issue_stack_delete "$region" "$s"; done
      for s in "${stacks[@]}"; do
        if watch_stack_deletion "$region" "$s"; then
          STAT_STACKS=$((STAT_STACKS + 1))
        else
          # DELETE_FAILED - retry retaining the resources that could not delete.
          local retain retain_ids
          retain=$(aws cloudformation describe-stack-events --stack-name "$s" --region "$region" \
                    --query "StackEvents[?ResourceStatus=='DELETE_FAILED'].LogicalResourceId" \
                    --output text 2>/dev/null | tr '\t' ' ')
          if [ -n "$retain" ]; then
            warn "Stack $s DELETE_FAILED; retrying while retaining: $retain"
            read -ra retain_ids <<< "$retain"
            aws cloudformation delete-stack --stack-name "$s" --region "$region" \
              --role-arn "$DELETION_ROLE_ARN" --retain-resources "${retain_ids[@]}" >/dev/null 2>&1 || true
            if watch_stack_deletion "$region" "$s"; then
              STAT_STACKS=$((STAT_STACKS + 1))
            else
              STAT_FAILED=$((STAT_FAILED + 1))
            fi
          else
            STAT_FAILED=$((STAT_FAILED + 1))
          fi
        fi
      done
    else
      # Dry-run: list what would be deleted; one pass is meaningful.
      for s in "${stacks[@]}"; do
        plan_line "stack $s"
        STAT_STACKS=$((STAT_STACKS + 1))
      done
      break
    fi
  done

  # Finally delete the CDKToolkit bootstrap stack (last - others depend on it).
  local cdktoolkit="${PREFIX}-CDKToolkit"
  if aws cloudformation describe-stacks --stack-name "$cdktoolkit" --region "$region" >/dev/null 2>&1; then
    if [ "$EXECUTE" = true ]; then
      issue_stack_delete "$region" "$cdktoolkit"
      if watch_stack_deletion "$region" "$cdktoolkit"; then
        STAT_STACKS=$((STAT_STACKS + 1))
      else
        STAT_FAILED=$((STAT_FAILED + 1))
      fi
    else
      plan_line "bootstrap stack $cdktoolkit"
      STAT_STACKS=$((STAT_STACKS + 1))
    fi
  fi
}

# Empty (all versions + delete markers) and delete aws-accelerator-* buckets.
teardown_buckets() {
  local buckets b
  buckets=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, '${BUCKET_PREFIX}-')].Name" --output text 2>/dev/null | tr '\t' '\n')
  for b in $buckets; do
    [ -z "$b" ] && continue
    if is_validator "$b"; then preserved "bucket $b"; continue; fi
    if [ "$EXECUTE" = true ]; then
      printf "    %s[%s]%s %s%s%s emptying + removing bucket %s%s%s ... " \
        "$c_dim" "$(ts)" "$c_rst" "$c_yel" "$G_ARROW" "$c_rst" "$c_bold" "$b" "$c_rst"
      # delete all object versions
      local vers marks
      vers=$(aws s3api list-object-versions --bucket "$b" --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null)
      if [ -n "$vers" ] && [ "$(echo "$vers" | jq -r '.Objects')" != "null" ]; then
        aws s3api delete-objects --bucket "$b" --delete "$vers" >/dev/null 2>&1 || true
      fi
      # delete all delete-markers
      marks=$(aws s3api list-object-versions --bucket "$b" --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null)
      if [ -n "$marks" ] && [ "$(echo "$marks" | jq -r '.Objects')" != "null" ]; then
        aws s3api delete-objects --bucket "$b" --delete "$marks" >/dev/null 2>&1 || true
      fi
      aws s3 rm "s3://$b" --recursive >/dev/null 2>&1 || true
      if aws s3api delete-bucket --bucket "$b" >/dev/null 2>&1; then
        printf "%s%s%s\n" "$c_grn" "$G_OK" "$c_rst"
        STAT_BUCKETS=$((STAT_BUCKETS + 1))
      else
        printf "%s%s%s\n" "$c_red" "$G_NO" "$c_rst"
        warn "Could not delete bucket $b (retain policy or remaining objects)."
        STAT_FAILED=$((STAT_FAILED + 1))
      fi
    else
      plan_line "bucket $b (empty all versions + delete)"
      STAT_BUCKETS=$((STAT_BUCKETS + 1))
    fi
  done
}

# Schedule deletion of alias/accelerator/* customer KMS keys in a region.
teardown_kms() {
  local region="$1" aliases alias keyid state
  aliases=$(aws kms list-aliases --region "$region" \
    --query "Aliases[?starts_with(AliasName, 'alias/${SSM_PREFIX#/}/') || starts_with(AliasName, 'alias/accelerator/')].[AliasName,TargetKeyId]" \
    --output text 2>/dev/null)
  while IFS=$'\t' read -r alias keyid; do
    [ -z "${keyid:-}" ] && continue
    # skip keys with no target or already pending deletion
    state=$(aws kms describe-key --key-id "$keyid" --region "$region" --query "KeyMetadata.KeyState" --output text 2>/dev/null || echo "")
    if [ "$state" = "PendingDeletion" ] || [ -z "$state" ]; then continue; fi
    if run_del "KMS key $alias ($keyid) [${KMS_WINDOW}d window]" \
         "aws kms schedule-key-deletion --key-id '$keyid' --pending-window-in-days '$KMS_WINDOW' --region '$region'"; then
      STAT_KMS=$((STAT_KMS + 1))
    else
      STAT_FAILED=$((STAT_FAILED + 1))
    fi
    if [ "$EXECUTE" = true ]; then
      aws kms delete-alias --alias-name "$alias" --region "$region" >/dev/null 2>&1 || true
    fi
  done <<< "$aliases"
}

# Delete /accelerator/* and /cdk-bootstrap/accel/* SSM parameters in a region.
teardown_ssm() {
  local region="$1" params p
  params=$(aws ssm get-parameters-by-path --path "$SSM_PREFIX" --recursive --region "$region" \
            --query "Parameters[].Name" --output text 2>/dev/null | tr '\t' '\n')
  # add cdk-bootstrap accel version param
  params="$params
/cdk-bootstrap/accel/version"
  for p in $params; do
    [ -z "$p" ] && continue
    if is_validator "$p"; then preserved "SSM param $p"; continue; fi
    if run_del "SSM parameter $p" \
         "aws ssm delete-parameter --name '$p' --region '$region'"; then
      STAT_SSM=$((STAT_SSM + 1))
    else
      STAT_FAILED=$((STAT_FAILED + 1))
    fi
  done
}

# Delete AWSAccelerator-* and cdk-accel-* IAM roles (global; run once per account).
teardown_iam_roles() {
  local roles r arn pol ip
  roles=$(aws iam list-roles --query "Roles[?starts_with(RoleName, '${PREFIX}-') || starts_with(RoleName, 'cdk-accel-')].RoleName" --output text 2>/dev/null | tr '\t' '\n')
  for r in $roles; do
    [ -z "$r" ] && continue
    if is_validator "$r"; then preserved "IAM role $r"; continue; fi
    if [ "$EXECUTE" = true ]; then
      printf "    %s[%s]%s %s%s%s removing IAM role %s%s%s ... " \
        "$c_dim" "$(ts)" "$c_rst" "$c_yel" "$G_ARROW" "$c_rst" "$c_bold" "$r" "$c_rst"
      # detach managed policies
      for arn in $(aws iam list-attached-role-policies --role-name "$r" --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null); do
        aws iam detach-role-policy --role-name "$r" --policy-arn "$arn" >/dev/null 2>&1 || true
      done
      # delete inline policies
      for pol in $(aws iam list-role-policies --role-name "$r" --query "PolicyNames[]" --output text 2>/dev/null); do
        aws iam delete-role-policy --role-name "$r" --policy-name "$pol" >/dev/null 2>&1 || true
      done
      # remove from instance profiles
      for ip in $(aws iam list-instance-profiles-for-role --role-name "$r" --query "InstanceProfiles[].InstanceProfileName" --output text 2>/dev/null); do
        aws iam remove-role-from-instance-profile --instance-profile-name "$ip" --role-name "$r" >/dev/null 2>&1 || true
      done
      if aws iam delete-role --role-name "$r" >/dev/null 2>&1; then
        printf "%s%s%s\n" "$c_grn" "$G_OK" "$c_rst"
        STAT_IAM=$((STAT_IAM + 1))
      else
        printf "%s%s%s\n" "$c_red" "$G_NO" "$c_rst"
        warn "Could not delete role $r"
        STAT_FAILED=$((STAT_FAILED + 1))
      fi
    else
      plan_line "IAM role $r (detach policies + delete)"
      STAT_IAM=$((STAT_IAM + 1))
    fi
  done
}

# Delete LZA CloudWatch log groups in a region.
teardown_log_groups() {
  local region="$1" lp lg
  local prefixes=("/aws/codebuild/${PREFIX}-" "/aws/lambda/${PREFIX}-" "${PREFIX}-Module")
  for lp in "${prefixes[@]}"; do
    for lg in $(aws logs describe-log-groups --log-group-name-prefix "$lp" --region "$region" --query "logGroups[].logGroupName" --output text 2>/dev/null | tr '\t' '\n'); do
      [ -z "$lg" ] && continue
      if is_validator "$lg"; then preserved "log group $lg"; continue; fi
      if run_del "log group $lg" \
           "aws logs delete-log-group --log-group-name '$lg' --region '$region'"; then
        STAT_LOGS=$((STAT_LOGS + 1))
      else
        STAT_FAILED=$((STAT_FAILED + 1))
      fi
    done
  done
}

# Delete the LZA config CodeCommit repo if present (management account).
teardown_codecommit() {
  local region="$1" repo="${BUCKET_PREFIX}-config"
  if aws codecommit get-repository --repository-name "$repo" --region "$region" >/dev/null 2>&1; then
    if run_del "CodeCommit repo $repo" \
         "aws codecommit delete-repository --repository-name '$repo' --region '$region'"; then
      STAT_CC=$((STAT_CC + 1))
    else
      STAT_FAILED=$((STAT_FAILED + 1))
    fi
  fi
}

# OPTIONAL: detach + delete LZA-created SCPs/RCPs (management account, org level).
teardown_org_policies() {
  local ptype pols pid pname tgt
  for ptype in SERVICE_CONTROL_POLICY RESOURCE_CONTROL_POLICY; do
    category "Org policies: $ptype"
    pols=$(aws organizations list-policies --filter "$ptype" \
            --query "Policies[?!contains(['FullAWSAccess'], Name)].[Id,Name]" --output text 2>/dev/null)
    while IFS=$'\t' read -r pid pname; do
      [ -z "${pid:-}" ] && continue
      # Only remove customer-managed LZA policies (skip AWS-managed FullAWSAccess).
      [ "$pname" = "FullAWSAccess" ] && continue
      if [ "$EXECUTE" = true ]; then
        printf "    %s[%s]%s %s%s%s removing %s %s%s%s ... " \
          "$c_dim" "$(ts)" "$c_rst" "$c_yel" "$G_ARROW" "$c_rst" "$ptype" "$c_bold" "$pname" "$c_rst"
        for tgt in $(aws organizations list-targets-for-policy --policy-id "$pid" --query "Targets[].TargetId" --output text 2>/dev/null); do
          aws organizations detach-policy --policy-id "$pid" --target-id "$tgt" >/dev/null 2>&1 || true
        done
        if aws organizations delete-policy --policy-id "$pid" >/dev/null 2>&1; then
          printf "%s%s%s\n" "$c_grn" "$G_OK" "$c_rst"
          STAT_ORG=$((STAT_ORG + 1))
        else
          printf "%s%s%s\n" "$c_red" "$G_NO" "$c_rst"
          warn "Could not delete policy $pid"
          STAT_FAILED=$((STAT_FAILED + 1))
        fi
      else
        plan_line "$ptype $pname ($pid) - detach from all targets + delete"
        STAT_ORG=$((STAT_ORG + 1))
      fi
    done <<< "$pols"
  done
  warn "This removes ALL customer-managed SCPs/RCPs. If some are not LZA's, narrow the filter."
}

# OPTIONAL: disable GuardDuty / SecurityHub / Macie org config in a region.
teardown_security_services() {
  local region="$1" det macie_status
  warn "Security-service teardown in ${region}; Control Tower may re-enable some. Review CT controls afterward."

  # GuardDuty: delete detectors in this account/region.
  for det in $(aws guardduty list-detectors --region "$region" --query "DetectorIds[]" --output text 2>/dev/null | tr '\t' '\n'); do
    [ -z "$det" ] && continue
    if run_del "GuardDuty detector $det" \
         "aws guardduty delete-detector --detector-id '$det' --region '$region'"; then
      STAT_SEC=$((STAT_SEC + 1))
    else
      STAT_FAILED=$((STAT_FAILED + 1))
    fi
  done

  # SecurityHub: disable in this account/region.
  if aws securityhub get-enabled-standards --region "$region" >/dev/null 2>&1; then
    if run_del "SecurityHub (this account/region)" \
         "aws securityhub disable-security-hub --region '$region'"; then
      STAT_SEC=$((STAT_SEC + 1))
    else
      STAT_FAILED=$((STAT_FAILED + 1))
    fi
  fi

  # Macie: disable in this account/region.
  macie_status=$(aws macie2 get-macie-session --region "$region" --query "status" --output text 2>/dev/null || echo "")
  if [ -n "$macie_status" ] && [ "$macie_status" != "None" ]; then
    if run_del "Macie (this account/region)" \
         "aws macie2 disable-macie --region '$region'"; then
      STAT_SEC=$((STAT_SEC + 1))
    else
      STAT_FAILED=$((STAT_FAILED + 1))
    fi
  fi
}

# ===========================================================================
# Banner + summary
# ===========================================================================
print_banner() {
  local accounts="$1" mode_txt
  if [ "$EXECUTE" = true ]; then
    mode_txt="${c_red}${c_bold}EXECUTE (destructive)${c_rst}"
  else
    mode_txt="${c_grn}${c_bold}DRY-RUN${c_rst}"
  fi
  printf "\n%s%s%s\n" "$c_cyn" "$(rule 62 "$BOX_H")" "$c_rst"
  printf "  %s%sLANDING ZONE ACCELERATOR  %s  UNINSTALLER%s\n" "$c_bold" "$c_cyn" "$G_BULLET" "$c_rst"
  printf "%s%s%s\n" "$c_cyn" "$(rule 62 "$BOX_H")" "$c_rst"
  printf "  %-18s %s\n" "Mode"               "$mode_txt"
  printf "  %-18s %s   %spartition %s%s\n" "Management acct"    "$MGMT_ACCOUNT_ID" "$c_dim" "$PARTITION" "$c_rst"
  printf "  %-18s %s\n" "Regions"            "$REGIONS"
  printf "  %-18s %s\n" "Accounts"           "$accounts"
  printf "  %-18s %s\n" "Cross-acct role"    "$MGMT_ROLE"
  printf "  %-18s %s / %s / %s\n" "Prefixes" "$PREFIX" "$BUCKET_PREFIX" "$SSM_PREFIX"
  printf "  %-18s %s\n" "Keep validator"     "$([ "$INCLUDE_VALIDATOR" = true ] && echo no || echo yes)"
  printf "  %-18s org-policies=%s  security-services=%s\n" "Optional" "$INCLUDE_ORG_POLICIES" "$INCLUDE_SECURITY_SERVICES"
  printf "  %-18s %sControl Tower, IAM Identity Center, org accounts%s\n" "Preserves" "$c_dim" "$c_rst"
  printf "%s%s%s\n" "$c_cyn" "$(rule 62 "$BOX_H")" "$c_rst"
  printf "  %sLegend%s  %s%s planned%s   %s%s in-progress%s   %s%s done%s   %s%s failed%s   %s%s preserved%s\n" \
    "$c_dim" "$c_rst" \
    "$c_yel" "$G_DRY" "$c_rst" "$c_yel" "$G_ARROW" "$c_rst" \
    "$c_grn" "$G_OK" "$c_rst" "$c_red" "$G_NO" "$c_rst" "$c_cyn" "$G_KEEP" "$c_rst"
}

summary_row() {
  local label="$1" val="$2" color="${3:-$c_bold}"
  printf "  %s%-28s%s %s%s%s\n" "$c_dim" "$label" "$c_rst" "$color" "$val" "$c_rst"
}

print_summary() {
  local now elapsed fail_color
  now=$(date +%s); elapsed=$((now - START_TS))
  fail_color="$c_grn"; [ "$STAT_FAILED" -gt 0 ] && fail_color="$c_red"

  printf "\n%s%s%s\n" "$c_cyn" "$(rule 62 "$BOX_H")" "$c_rst"
  printf "  %s%sSUMMARY%s  %s(%s)%s\n" "$c_bold" "$c_cyn" "$c_rst" "$c_dim" \
    "$([ "$EXECUTE" = true ] && echo "executed - resources removed" || echo "dry-run - nothing changed")" "$c_rst"
  printf "%s%s%s\n" "$c_cyn" "$(rule 62 "$BOX_H")" "$c_rst"
  summary_row "CloudFormation stacks"     "$STAT_STACKS"
  summary_row "S3 buckets"                "$STAT_BUCKETS"
  summary_row "KMS keys"                  "$STAT_KMS"
  summary_row "SSM parameters"            "$STAT_SSM"
  summary_row "IAM roles"                 "$STAT_IAM"
  summary_row "CloudWatch log groups"     "$STAT_LOGS"
  summary_row "CodeCommit repos"          "$STAT_CC"
  [ "$INCLUDE_ORG_POLICIES" = true ]      && summary_row "Org policies"      "$STAT_ORG"
  [ "$INCLUDE_SECURITY_SERVICES" = true ] && summary_row "Security services" "$STAT_SEC"
  summary_row "Preserved (validator/skip)" "$STAT_PRESERVED" "$c_cyn"
  summary_row "Failed"                     "$STAT_FAILED" "$fail_color"
  summary_row "Elapsed"                    "$(fmt_elapsed "$elapsed")" "$c_dim"
  printf "%s%s%s\n" "$c_cyn" "$(rule 62 "$BOX_H")" "$c_rst"
}

# ===========================================================================
# Main
# ===========================================================================
main() {
  command -v jq >/dev/null 2>&1 || { err "jq is required"; exit 1; }
  START_TS=$(date +%s)

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

  print_banner "$accounts"

  if [ "$EXECUTE" = true ]; then
    printf "\n"
    warn "This will PERMANENTLY delete LZA resources across the organization."
    printf "  %sType '%s%s%s' to proceed:%s " "$c_yel" "$c_bold" "$CONFIRM_PHRASE" "$c_rst$c_yel" "$c_rst"
    read -r reply
    [ "$reply" = "$CONFIRM_PHRASE" ] || { err "Confirmation mismatch; aborting."; exit 1; }
  fi

  # Per-account teardown
  local acct aname region
  for acct in $accounts; do
    aname=$(acct_name "$acct")
    account_header "$acct" "$aname"
    if ! assume_into "$acct"; then continue; fi

    ensure_deletion_role "$acct"

    # Regional resources: stacks, KMS, SSM, logs, (codecommit), (security services)
    for region in $REGIONS; do
      region_hdr "$region"
      category "CloudFormation stacks";   teardown_stacks_in_region "$region"
      category "KMS keys";                teardown_kms "$region"
      category "SSM parameters";          teardown_ssm "$region"
      category "CloudWatch log groups";   teardown_log_groups "$region"
      if [ "$acct" = "$MGMT_ACCOUNT_ID" ]; then
        category "CodeCommit";            teardown_codecommit "$region"
      fi
      if [ "$INCLUDE_SECURITY_SERVICES" = true ]; then
        category "Security services";     teardown_security_services "$region"
      fi
    done

    # Global resources: S3 buckets, IAM roles
    category "S3 buckets (account-global)"; teardown_buckets
    category "IAM roles (account-global)";  teardown_iam_roles

    cleanup_deletion_role
    clear_creds
  done

  # Org-level (management account, once)
  if [ "$INCLUDE_ORG_POLICIES" = true ]; then
    account_header "$MGMT_ACCOUNT_ID" "org-level policies"
    assume_into "$MGMT_ACCOUNT_ID"
    teardown_org_policies
    clear_creds
  fi

  print_summary

  printf "\n"
  ok "LZA uninstall $([ "$EXECUTE" = true ] && echo "complete" || echo "dry-run complete (no changes made)")."
  printf "  %sControl Tower, IAM Identity Center, and org accounts were preserved.%s\n" "$c_dim" "$c_rst"
  if [ "$INCLUDE_VALIDATOR" = false ]; then
    printf "  %sThe Config Validator tooling was preserved (pass --include-validator to remove it).%s\n" "$c_dim" "$c_rst"
  fi
  printf "  %sKMS keys are scheduled for deletion (%s-day window) and can be cancelled before then.%s\n" "$c_dim" "$KMS_WINDOW" "$c_rst"
}

main "$@"
