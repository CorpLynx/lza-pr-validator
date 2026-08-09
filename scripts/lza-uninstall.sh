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
#   - Output follows a Homebrew-style format: "==>" step headers and a single
#     clean line per resource ("Removing <x>... (n resources)" / "ok").
#   - Output auto-scales to the terminal width; long names are shortened and
#     middle-truncated to fit. Set NO_COLOR=1 (or pipe/redirect) for plain
#     logs, and LZA_COLS=<n> to force a specific width.
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
#     --verbose | -v            Print the underlying AWS error when a delete fails
#     --skip-verify             Skip the post-teardown verification re-scan
#     -h | --help               Show this help
#
# After an --execute run the script re-scans every account/region and reports
# any AWSAccelerator resources that survived (e.g. Object Lock buckets), so a
# reported "complete" is backed by verification rather than attempt counts.
#
set -uo pipefail

# Relies on bash features (arrays, ${var:off:len}); a non-bash shell (e.g. zsh)
# mangles these (word-splitting, the ':r' modifier), so require bash.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "lza-uninstall.sh must be run with bash, e.g. 'bash scripts/lza-uninstall.sh'." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Defaults / arg parsing
# ---------------------------------------------------------------------------
EXECUTE=false
VERBOSE=false
VERIFY=true
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
    --verbose|-v) VERBOSE=true ;;
    --skip-verify) VERIFY=false ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Presentation layer (Homebrew-style): color detection + helpers
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
  c_red=$'\033[31m';  c_grn=$'\033[32m'; c_yel=$'\033[33m'
  c_blu=$'\033[34m';  c_dim=$'\033[2m';  c_bold=$'\033[1m'; c_rst=$'\033[0m'
else
  c_red=""; c_grn=""; c_yel=""; c_blu=""; c_dim=""; c_bold=""; c_rst=""
fi

# Detect usable terminal columns. Prefer the live tty window size (works even
# when $TERM is unset), then tput, then $COLUMNS, then a sane default.
detect_cols() {
  local c
  c=$( (tput cols) 2>/dev/null || true )
  case "$c" in ''|*[!0-9]*) c=$( stty size </dev/tty 2>/dev/null | awk '{print $2}' ) ;; esac
  case "$c" in ''|*[!0-9]*) c=${COLUMNS:-80} ;; esac
  case "$c" in ''|*[!0-9]*) c=80 ;; esac
  printf "%s" "$c"
}

# Terminal width, for auto-scaling output to the window. 0 = unbounded, used
# when output is not a TTY (pipe/redirect/CI) so logs keep full resource names.
# Precedence: explicit LZA_COLS override, else the live TTY width (refreshed on
# resize via SIGWINCH), else unbounded.
if [ -n "${LZA_COLS:-}" ]; then
  TERM_COLS="$LZA_COLS"
elif [ -t 1 ]; then
  TERM_COLS=$(detect_cols)
  trap 'TERM_COLS=$(detect_cols)' WINCH
else
  TERM_COLS=0
fi
case "$TERM_COLS" in ''|*[!0-9]*) TERM_COLS=80 ;; esac

# fit <string> <max-cols> : shorten to fit max-cols using a middle ellipsis.
# max-cols <= 0 means "no limit" (return unchanged).
fit() {
  local s="$1" avail="$2" n keep_l keep_r
  n=${#s}
  if [ "$avail" -le 0 ] || [ "$n" -le "$avail" ]; then printf "%s" "$s"; return; fi
  if [ "$avail" -le 4 ]; then printf "%s" "${s:0:avail}"; return; fi
  keep_l=$(( (avail - 2) / 2 ))
  keep_r=$(( avail - 2 - keep_l ))
  printf "%s..%s" "${s:0:keep_l}" "${s:n-keep_r}"
}

# avail_for <reserve> : columns left for a name after fixed prefix/suffix text.
# Returns 0 (no limit) when not attached to a TTY.
avail_for() {
  local a
  if [ "$TERM_COLS" -le 0 ]; then printf "0"; return; fi
  a=$(( TERM_COLS - $1 ))
  [ "$a" -lt 12 ] && a=12
  printf "%d" "$a"
}

# "==> Header" - the Homebrew step marker (blue arrow, bold title).
step() { printf "\n%s==>%s %s%s%s\n" "$c_blu$c_bold" "$c_rst" "$c_bold" "$*" "$c_rst"; }
# A label:value row used by the banner/summary (value truncated to the window).
row()  { printf "%s%-19s%s %s\n" "$c_dim" "$1" "$c_rst" "$(fit "$2" "$(avail_for 21)")"; }
# Homebrew-style Warning:/Error: lines.
warn() { printf "%sWarning:%s %s\n" "$c_yel" "$c_rst" "$*"; }
err()  { printf "%sError:%s %s\n"   "$c_red" "$c_rst" "$*" >&2; }
ok()   { printf "%s%s%s\n"          "$c_grn" "$*" "$c_rst"; }
# A preserved/skipped resource.
preserved() {
  printf "%sSkipping %s (preserved)%s\n" "$c_dim" "$(fit "$1" "$(avail_for 21)")" "$c_rst"
  STAT_PRESERVED=$((STAT_PRESERVED + 1))
}

# Format seconds as e.g. "2m14s" / "9s".
fmt_elapsed() {
  local s="$1" m
  m=$((s / 60)); s=$((s % 60))
  if [ "$m" -gt 0 ]; then printf "%dm%ds" "$m" "$s"; else printf "%ds" "$s"; fi
}

# True if an AWS error message indicates the resource is already absent, so a
# re-run reports "already gone" instead of a misleading "failed".
is_absent_error() {
  case "$1" in
    *NoSuchEntity*|*NoSuchBucket*|*NoSuchKey*|*NotFound*|*"does not exist"*|*"not found"*|*"(404)"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Print an AWS error (trimmed to one line, fit to the window) when --verbose.
show_error() {
  [ "$VERBOSE" = true ] || return 0
  local msg
  msg=$(printf '%s' "$1" | tr '\n' ' ' | sed 's/  */ /g')
  [ -n "$msg" ] && printf "  %s%s%s\n" "$c_dim" "$(fit "$msg" "$(avail_for 4)")" "$c_rst"
}

# Filter a newline-separated list on stdin, dropping preserved validator names.
drop_validator() {
  local name
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    is_validator "$name" && continue
    printf '%s\n' "$name"
  done
}

# ---------------------------------------------------------------------------
# Action runner (quick, fire-and-forget deletions)
#   run_del "<noun>" "<command...>"
#     dry-run : "Would remove <noun>"
#     execute : "Removing <noun>... ok | already gone | failed" (+error if -v)
# ---------------------------------------------------------------------------
run_del() {
  local noun="$1"; shift
  if [ "$EXECUTE" != true ]; then
    printf "Would remove %s\n" "$(fit "$noun" "$(avail_for 13)")"
    return 0
  fi
  printf "Removing %s... " "$(fit "$noun" "$(avail_for 29)")"
  local out rc
  # Commands are pre-composed strings (single-quoted args); eval runs them.
  # shellcheck disable=SC2294
  out=$(eval "$@" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    printf "%sok%s\n" "$c_grn" "$c_rst"
    return 0
  fi
  if is_absent_error "$out"; then
    printf "%salready gone%s\n" "$c_dim" "$c_rst"
    return 0
  fi
  printf "%sfailed%s\n" "$c_red" "$c_rst"
  show_error "$out"
  return 1
}
# Like run_del but for non-deletion setup actions (create/attach/detach).
run_act() {
  local dry="$1" doing="$2"; shift 2
  if [ "$EXECUTE" = true ]; then
    printf "%s... " "$(fit "$doing" "$(avail_for 12)")"
    # shellcheck disable=SC2294
    if eval "$@" >/dev/null 2>&1; then
      printf "%sok%s\n" "$c_grn" "$c_rst"
      return 0
    fi
    printf "%sfailed%s\n" "$c_red" "$c_rst"
    return 1
  fi
  printf "%s\n" "$(fit "$dry" "$(avail_for 2)")"
  return 0
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
  run_act "Would create temp deletion role ${DELETION_ROLE_NAME}" \
          "Creating temp deletion role ${DELETION_ROLE_NAME}" \
          "aws iam create-role --role-name '$DELETION_ROLE_NAME' --assume-role-policy-document '$trust'"
  run_act "Would attach AdministratorAccess to ${DELETION_ROLE_NAME}" \
          "Attaching AdministratorAccess to ${DELETION_ROLE_NAME}" \
          "aws iam attach-role-policy --role-name '$DELETION_ROLE_NAME' --policy-arn arn:${PARTITION}:iam::aws:policy/AdministratorAccess"
  if [ "$EXECUTE" = true ]; then sleep 8; fi   # IAM propagation
}
cleanup_deletion_role() {
  if aws iam get-role --role-name "$DELETION_ROLE_NAME" >/dev/null 2>&1; then
    run_act "Would remove temp deletion role ${DELETION_ROLE_NAME}" \
            "Removing temp deletion role ${DELETION_ROLE_NAME}" \
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

# Count the resources in a stack (for the Homebrew-style "(n resources)" note).
stack_resource_count() {
  aws cloudformation list-stack-resources --stack-name "$1" --region "$2" \
    --query "length(StackResourceSummaries)" --output text 2>/dev/null || echo "?"
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

# Wait quietly for a stack to finish deleting. Returns 0 on gone, 1 on failure/timeout.
wait_stack_gone() {
  local region="$1" stack="$2" status start now
  start=$(date +%s)
  while :; do
    status=$(aws cloudformation describe-stacks --stack-name "$stack" --region "$region" \
             --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "GONE")
    case "$status" in
      DELETE_COMPLETE|GONE) return 0 ;;
      DELETE_FAILED) return 1 ;;
    esac
    now=$(date +%s)
    if [ "$((now - start))" -gt 1800 ]; then return 1; fi
    sleep 5
  done
}

# Shorten a stack name for display: drop the "<PREFIX>-" prefix and the
# trailing "-<account>-<region>" (both are already shown in the step headers).
short_stack() {
  local d="${1#"${PREFIX}"-}"
  d="${d%-"$2"}"      # strip -<region>
  d="${d%-[0-9]*}"    # strip -<account-id>
  printf "%s" "$d"
}

# Delete all LZA stacks in a region using a dependency-resolving retry loop.
teardown_stacks_in_region() {
  local region="$1"
  local attempts=0 line stacks s i rc retain retain_ids counts disp
  # Re-list and retry (dependency-safe) up to 6 times until nothing remains.
  while [ "$attempts" -lt 6 ]; do
    attempts=$((attempts + 1))
    # Populate the stacks array portably (macOS bash 3.2 has no mapfile).
    stacks=()
    while IFS= read -r line; do
      [ -n "$line" ] && stacks+=("$line")
    done < <(list_lza_stacks "$region")
    if [ "${#stacks[@]}" -eq 0 ]; then break; fi

    if [ "$EXECUTE" = true ]; then
      # Capture resource counts, then fire all deletions in this pass (parallel).
      counts=()
      for i in "${!stacks[@]}"; do
        counts[i]=$(stack_resource_count "${stacks[$i]}" "$region")
        issue_stack_delete "$region" "${stacks[$i]}"
      done
      # Report each stack as it finishes.
      for i in "${!stacks[@]}"; do
        s="${stacks[$i]}"
        disp="$(short_stack "$s" "$region")"
        printf "Removing %s... " "$(fit "$disp" "$(avail_for 29)")"
        if wait_stack_gone "$region" "$s"; then
          printf "(%s resources)\n" "${counts[$i]}"
          STAT_STACKS=$((STAT_STACKS + 1))
        else
          printf "%sDELETE_FAILED%s\n" "$c_red" "$c_rst"
          # Retry retaining the resources that could not delete.
          retain=$(aws cloudformation describe-stack-events --stack-name "$s" --region "$region" \
                    --query "StackEvents[?ResourceStatus=='DELETE_FAILED'].LogicalResourceId" \
                    --output text 2>/dev/null | tr '\t' ' ')
          if [ -n "$retain" ]; then
            warn "retrying $s while retaining: $retain"
            read -ra retain_ids <<< "$retain"
            aws cloudformation delete-stack --stack-name "$s" --region "$region" \
              --role-arn "$DELETION_ROLE_ARN" --retain-resources "${retain_ids[@]}" >/dev/null 2>&1 || true
            printf "Removing %s (retry)... " "$(fit "$disp" "$(avail_for 37)")"
            if wait_stack_gone "$region" "$s"; then
              printf "(retained %d resources)\n" "${#retain_ids[@]}"
              STAT_STACKS=$((STAT_STACKS + 1))
            else
              printf "%sfailed%s\n" "$c_red" "$c_rst"
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
        rc=$(stack_resource_count "$s" "$region")
        disp="$(short_stack "$s" "$region")"
        printf "Would remove %s (%s resources)\n" "$(fit "$disp" "$(avail_for 30)")" "$rc"
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
      printf "Removing %s (bootstrap)... " "$(fit "$(short_stack "$cdktoolkit" "$region")" "$(avail_for 40)")"
      if wait_stack_gone "$region" "$cdktoolkit"; then
        printf "%sok%s\n" "$c_grn" "$c_rst"
        STAT_STACKS=$((STAT_STACKS + 1))
      else
        printf "%sfailed%s\n" "$c_red" "$c_rst"
        STAT_FAILED=$((STAT_FAILED + 1))
      fi
    else
      printf "Would remove %s (bootstrap)\n" "$(fit "$(short_stack "$cdktoolkit" "$region")" "$(avail_for 30)")"
      STAT_STACKS=$((STAT_STACKS + 1))
    fi
  fi
}

# Fully empty a versioned bucket: delete every object version and delete marker
# in pages of <=1000 (the delete-objects limit), looping until nothing remains.
empty_bucket() {
  local b="$1" prop all total i end chunk attempts remaining
  # A few passes catch objects written while we work (log buckets keep arriving).
  attempts=0
  while [ "$attempts" -lt 3 ]; do
    attempts=$((attempts + 1))
    remaining=0
    for prop in Versions DeleteMarkers; do
      all=$(aws s3api list-object-versions --bucket "$b" \
            --query "${prop}[].{Key:Key,VersionId:VersionId}" --output json 2>/dev/null)
      [ -z "$all" ] && continue
      total=$(echo "$all" | jq 'length' 2>/dev/null || echo 0)
      [ "${total:-0}" = "0" ] && continue
      remaining=$((remaining + total))
      # delete-objects accepts at most 1000 keys per call: slice into batches.
      i=0
      while [ "$i" -lt "$total" ]; do
        end=$((i + 1000))
        chunk=$(echo "$all" | jq -c --argjson s "$i" --argjson e "$end" '{Objects: .[$s:$e]}')
        aws s3api delete-objects --bucket "$b" --delete "$chunk" >/dev/null 2>&1 || true
        i=$end
      done
    done
    [ "$remaining" = "0" ] && break
  done
  # sweep any remaining current (non-versioned) objects
  aws s3 rm "s3://$b" --recursive >/dev/null 2>&1 || true
}

# Empty (all versions + delete markers) and delete aws-accelerator-* buckets.
teardown_buckets() {
  local buckets b disp derr lock
  buckets=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, '${BUCKET_PREFIX}-')].Name" --output text 2>/dev/null | tr '\t' '\n')
  for b in $buckets; do
    [ -z "$b" ] && continue
    disp="${b#"${BUCKET_PREFIX}"-}"
    if is_validator "$b"; then preserved "bucket $disp"; continue; fi
    if [ "$EXECUTE" = true ]; then
      printf "Removing bucket %s... " "$(fit "$disp" "$(avail_for 28)")"
      # drop any deny bucket-policy first (it may block object/bucket deletion)
      aws s3api delete-bucket-policy --bucket "$b" >/dev/null 2>&1 || true
      empty_bucket "$b"
      if derr=$(aws s3api delete-bucket --bucket "$b" 2>&1); then
        printf "%sok%s\n" "$c_grn" "$c_rst"
        STAT_BUCKETS=$((STAT_BUCKETS + 1))
      else
        printf "%sfailed%s\n" "$c_red" "$c_rst"
        # Distinguish the un-fixable case (Object Lock) from generic failures.
        lock=$(aws s3api get-object-lock-configuration --bucket "$b" \
               --query "ObjectLockConfiguration.ObjectLockEnabled" --output text 2>/dev/null || echo "")
        if [ "$lock" = "Enabled" ]; then
          warn "bucket $disp has S3 Object Lock; objects cannot be deleted until retention expires"
        else
          warn "could not delete bucket $disp"
          show_error "$derr"
        fi
        STAT_FAILED=$((STAT_FAILED + 1))
      fi
    else
      printf "Would remove bucket %s\n" "$(fit "$disp" "$(avail_for 20)")"
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
    if run_del "KMS key $alias (${KMS_WINDOW}-day window)" \
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
  # add the cdk-bootstrap accel version param only if it still exists (so a
  # re-run doesn't report an already-deleted parameter as "failed").
  if aws ssm get-parameter --name "/cdk-bootstrap/accel/version" --region "$region" >/dev/null 2>&1; then
    params="$params
/cdk-bootstrap/accel/version"
  fi
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
  local roles r arn pol ip disp derr
  roles=$(aws iam list-roles --query "Roles[?starts_with(RoleName, '${PREFIX}-') || starts_with(RoleName, 'cdk-accel-')].RoleName" --output text 2>/dev/null | tr '\t' '\n')
  for r in $roles; do
    [ -z "$r" ] && continue
    disp="${r#"${PREFIX}"-}"
    if is_validator "$r"; then preserved "IAM role $disp"; continue; fi
    if [ "$EXECUTE" = true ]; then
      printf "Removing IAM role %s... " "$(fit "$disp" "$(avail_for 30)")"
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
      if derr=$(aws iam delete-role --role-name "$r" 2>&1); then
        printf "%sok%s\n" "$c_grn" "$c_rst"
        STAT_IAM=$((STAT_IAM + 1))
      else
        printf "%sfailed%s\n" "$c_red" "$c_rst"
        warn "could not delete role $disp"
        show_error "$derr"
        STAT_FAILED=$((STAT_FAILED + 1))
      fi
    else
      printf "Would remove IAM role %s\n" "$(fit "$disp" "$(avail_for 22)")"
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
    step "Org policies: $ptype"
    pols=$(aws organizations list-policies --filter "$ptype" \
            --query "Policies[?!contains(['FullAWSAccess'], Name)].[Id,Name]" --output text 2>/dev/null)
    while IFS=$'\t' read -r pid pname; do
      [ -z "${pid:-}" ] && continue
      # Only remove customer-managed LZA policies (skip AWS-managed FullAWSAccess).
      [ "$pname" = "FullAWSAccess" ] && continue
      if [ "$EXECUTE" = true ]; then
        printf "Removing %s %s... " "$ptype" "$pname"
        for tgt in $(aws organizations list-targets-for-policy --policy-id "$pid" --query "Targets[].TargetId" --output text 2>/dev/null); do
          aws organizations detach-policy --policy-id "$pid" --target-id "$tgt" >/dev/null 2>&1 || true
        done
        if aws organizations delete-policy --policy-id "$pid" >/dev/null 2>&1; then
          printf "%sok%s\n" "$c_grn" "$c_rst"
          STAT_ORG=$((STAT_ORG + 1))
        else
          printf "%sfailed%s\n" "$c_red" "$c_rst"
          warn "could not delete policy $pid"
          STAT_FAILED=$((STAT_FAILED + 1))
        fi
      else
        printf "Would remove %s %s (%s)\n" "$ptype" "$pname" "$pid"
        STAT_ORG=$((STAT_ORG + 1))
      fi
    done <<< "$pols"
  done
  warn "this removes ALL customer-managed SCPs/RCPs. If some are not LZA's, narrow the filter."
}

# OPTIONAL: disable GuardDuty / SecurityHub / Macie org config in a region.
teardown_security_services() {
  local region="$1" det macie_status
  warn "Control Tower may re-enable some security services; review CT controls afterward."

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
# Verification - re-scan after teardown and report anything left behind
# ===========================================================================
VERIFY_RESIDUAL=0
note_residual() {   # $1 = label, $2 = newline-separated names
  local label="$1" name
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    printf "  %s%-14s%s %s\n" "$c_yel" "$label" "$c_rst" "$(fit "$name" "$(avail_for 18)")"
    VERIFY_RESIDUAL=$((VERIFY_RESIDUAL + 1))
  done <<< "$2"
}

verify_teardown() {
  local accounts="$1" acct region names
  step "Verification (re-scanning for anything left behind)"
  for acct in $accounts; do
    if ! assume_into "$acct"; then warn "cannot assume into $acct to verify"; continue; fi
    for region in $REGIONS; do
      names=$(list_lza_stacks "$region")
      if aws cloudformation describe-stacks --stack-name "${PREFIX}-CDKToolkit" --region "$region" >/dev/null 2>&1; then
        names="${names}
${PREFIX}-CDKToolkit"
      fi
      note_residual "stack/$region" "$names"
      names=$(aws ssm get-parameters-by-path --path "$SSM_PREFIX" --recursive --region "$region" \
              --query "Parameters[].Name" --output text 2>/dev/null | tr '\t' '\n' | drop_validator)
      note_residual "ssm/$region" "$names"
      names=$(aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/${PREFIX}-" --region "$region" \
              --query "logGroups[].logGroupName" --output text 2>/dev/null | tr '\t' '\n' | drop_validator)
      note_residual "log/$region" "$names"
    done
    names=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, '${BUCKET_PREFIX}-')].Name" \
            --output text 2>/dev/null | tr '\t' '\n' | drop_validator)
    note_residual "bucket" "$names"
    names=$(aws iam list-roles --query "Roles[?starts_with(RoleName, '${PREFIX}-') || starts_with(RoleName, 'cdk-accel-')].RoleName" \
            --output text 2>/dev/null | tr '\t' '\n' | drop_validator)
    note_residual "iam-role" "$names"
    clear_creds
  done
  if [ "$VERIFY_RESIDUAL" -eq 0 ]; then
    ok "Verified clean: no AWSAccelerator resources remain (validator + Control Tower preserved)."
  else
    warn "$VERIFY_RESIDUAL AWSAccelerator resource(s) still present (listed above)."
    warn "Re-run to retry; Object Lock buckets can't be removed until their retention expires."
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
  step "LZA Uninstaller"
  row "Mode"               "$mode_txt"
  row "Management account" "$MGMT_ACCOUNT_ID ($PARTITION)"
  row "Regions"            "$REGIONS"
  row "Accounts"           "$accounts"
  row "Cross-account role" "$MGMT_ROLE"
  row "Prefixes"           "$PREFIX / $BUCKET_PREFIX / $SSM_PREFIX"
  row "Keep validator"     "$([ "$INCLUDE_VALIDATOR" = true ] && echo no || echo yes)"
  row "Org policies"       "$INCLUDE_ORG_POLICIES"
  row "Security services"  "$INCLUDE_SECURITY_SERVICES"
  row "Preserving"         "Control Tower, IAM Identity Center, org accounts"
}

print_summary() {
  local now elapsed fail_color
  now=$(date +%s); elapsed=$((now - START_TS))
  fail_color="$c_grn"; [ "$STAT_FAILED" -gt 0 ] && fail_color="$c_red"

  step "Summary ($([ "$EXECUTE" = true ] && echo "executed" || echo "dry-run"))"
  row "CloudFormation stacks" "$STAT_STACKS"
  row "S3 buckets"            "$STAT_BUCKETS"
  row "KMS keys"              "$STAT_KMS"
  row "SSM parameters"        "$STAT_SSM"
  row "IAM roles"             "$STAT_IAM"
  row "CloudWatch log groups" "$STAT_LOGS"
  row "CodeCommit repos"      "$STAT_CC"
  [ "$INCLUDE_ORG_POLICIES" = true ]      && row "Org policies"      "$STAT_ORG"
  [ "$INCLUDE_SECURITY_SERVICES" = true ] && row "Security services" "$STAT_SEC"
  row "Preserved"             "$STAT_PRESERVED"
  printf "%s%-19s%s %s%s%s\n" "$c_dim" "Failed" "$c_rst" "$fail_color" "$STAT_FAILED" "$c_rst"
  row "Elapsed"               "$(fmt_elapsed "$elapsed")"
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
    printf "Type '%s%s%s' to proceed: " "$c_bold" "$CONFIRM_PHRASE" "$c_rst"
    read -r reply
    [ "$reply" = "$CONFIRM_PHRASE" ] || { err "Confirmation mismatch; aborting."; exit 1; }
  fi

  # Per-account teardown
  local acct aname region
  for acct in $accounts; do
    aname=$(acct_name "$acct")
    if [ -n "$aname" ] && [ "$aname" != "None" ]; then
      step "Account $acct ($aname)"
    else
      step "Account $acct"
    fi
    if ! assume_into "$acct"; then continue; fi

    ensure_deletion_role "$acct"

    # Regional resources: stacks, KMS, SSM, logs, (codecommit), (security services)
    for region in $REGIONS; do
      step "CloudFormation stacks ($region)"; teardown_stacks_in_region "$region"
      step "KMS keys ($region)";              teardown_kms "$region"
      step "SSM parameters ($region)";        teardown_ssm "$region"
      step "CloudWatch log groups ($region)"; teardown_log_groups "$region"
      if [ "$acct" = "$MGMT_ACCOUNT_ID" ]; then
        step "CodeCommit ($region)";          teardown_codecommit "$region"
      fi
      if [ "$INCLUDE_SECURITY_SERVICES" = true ]; then
        step "Security services ($region)";   teardown_security_services "$region"
      fi
    done

    # Global resources: S3 buckets, IAM roles
    step "S3 buckets"; teardown_buckets
    step "IAM roles";  teardown_iam_roles

    cleanup_deletion_role
    clear_creds
  done

  # Org-level (management account, once)
  if [ "$INCLUDE_ORG_POLICIES" = true ]; then
    step "Org-level policies (management account)"
    assume_into "$MGMT_ACCOUNT_ID"
    teardown_org_policies
    clear_creds
  fi

  print_summary

  # Verify the teardown actually removed everything (post-run re-scan).
  if [ "$EXECUTE" = true ] && [ "$VERIFY" = true ]; then
    verify_teardown "$accounts"
  fi

  step "LZA uninstall $([ "$EXECUTE" = true ] && echo "complete" || echo "dry-run complete (no changes made)")"
  printf "%sControl Tower, IAM Identity Center, and org accounts were preserved.%s\n" "$c_dim" "$c_rst"
  if [ "$INCLUDE_VALIDATOR" = false ]; then
    printf "%sThe Config Validator tooling was preserved (pass --include-validator to remove it).%s\n" "$c_dim" "$c_rst"
  fi
  printf "%sKMS keys are scheduled for deletion (%s-day window) and can be cancelled before then.%s\n" "$c_dim" "$KMS_WINDOW" "$c_rst"
}

main "$@"
