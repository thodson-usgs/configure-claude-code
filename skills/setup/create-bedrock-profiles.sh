#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# create-bedrock-profiles.sh
#
# Creates tagged Bedrock application inference profiles for Claude Code models.
# Run once per project (or re-run when models are added/updated — existing
# profiles are skipped).
#
# Prerequisites:
#   - AWS CLI v2 with a valid SSO session (aws sso login)
#   - jq
#
# Usage:
#   ./create-bedrock-profiles.sh \
#       --project-id  uncertainty_ts \
#       --app-id      claude \
#       --contact     thodson@usgs.gov
###############################################################################

# ── Models to create profiles for ─────────────────────────────────────────────
# Edit this list when new Claude models are released or old ones are retired.
# Each entry is a Bedrock system inference profile ID (us.anthropic.claude-*).
# To see what's available in your account:
#   aws bedrock list-inference-profiles --type-equals SYSTEM_DEFINED \
#     | jq -r '.inferenceProfileSummaries[].inferenceProfileId' | grep anthropic
#
# Note: Claude Code has three tiers (opus/sonnet/haiku). Fable has no tier, so a
# profile is still created (and tagged) for it, but configure-claude-cli.sh
# exposes it as an optional main-model override rather than a tier default.
MODELS=(
  us.anthropic.claude-opus-4-8
  us.anthropic.claude-sonnet-5
  us.anthropic.claude-haiku-4-5-20251001-v1:0
  us.anthropic.claude-fable-5
)

# ── Defaults ──────────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-us-west-2}"
PROJECT_ID=""
APP_ID=""
CONTACT=""

# ── Parse arguments ───────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Creates tagged Bedrock inference profiles for Claude Code models.

Required:
  --project-id ID      wma:project_id tag value
  --app-id ID          wma:application_id tag value
  --contact EMAIL      wma:contact tag value

Optional:
  --region REGION      AWS region (default: us-west-2)

Examples:
  $(basename "$0") --project-id uncertainty_ts --app-id claude --contact thodson@usgs.gov
EOF
  exit 1
}

# Each value-taking flag reads $2 via ${2:?...} so a flag passed as the final token
# fails with a clear "requires a value" message instead of a cryptic `$2: unbound
# variable` abort under `set -u`.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)  PROJECT_ID="${2:?--project-id requires a value}";  shift 2 ;;
    --app-id)      APP_ID="${2:?--app-id requires a value}";          shift 2 ;;
    --contact)     CONTACT="${2:?--contact requires a value}";        shift 2 ;;
    --region)      AWS_REGION="${2:?--region requires a value}";      shift 2 ;;
    -h|--help)     usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$PROJECT_ID" || -z "$APP_ID" || -z "$CONTACT" ]]; then
  echo "Error: --project-id, --app-id, and --contact are required."
  usage
fi

# ── Preflight checks ─────────────────────────────────────────────────────────
for cmd in aws jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required but not found in PATH." >&2
    exit 1
  fi
done

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
  echo "Error: unable to get AWS identity. Run 'aws sso login' first." >&2
  exit 1
}
echo "AWS Account: $ACCOUNT_ID  Region: $AWS_REGION"

# ── Validate selected models exist ────────────────────────────────────────────
# Skip (with a warning) any model that has no system inference profile in this
# account/region rather than aborting the whole run — one unavailable model (a
# newer release not yet enabled, or one absent in this region) shouldn't block
# creating profiles for the models that are available.
#
# One list call + a jq membership check per model, rather than a get-inference-profile
# round-trip per model (fewer requests, less throttling exposure as MODELS grows).
echo ""
echo "Validating ${#MODELS[@]} model(s)..."

ACCOUNT_ARN_PREFIX="arn:aws:bedrock:${AWS_REGION}:${ACCOUNT_ID}"

AVAILABLE_MODELS=$(aws bedrock list-inference-profiles \
  --type-equals SYSTEM_DEFINED \
  --region "$AWS_REGION" \
  --query 'inferenceProfileSummaries[].inferenceProfileId' \
  --output json)

VALID_MODELS=()
for SYSTEM_ID in "${MODELS[@]}"; do
  if echo "$AVAILABLE_MODELS" | jq -e --arg id "$SYSTEM_ID" 'index($id) != null' &>/dev/null; then
    VALID_MODELS+=("$SYSTEM_ID")
  else
    echo "  SKIP  $SYSTEM_ID (no system inference profile in $AWS_REGION)" >&2
  fi
done

if [ "${#VALID_MODELS[@]}" -eq 0 ]; then
  echo "Error: none of the configured models are available in $AWS_REGION." >&2
  echo "Run: aws bedrock list-inference-profiles --type-equals SYSTEM_DEFINED" >&2
  echo "to see available profiles, then update the MODELS array in this script." >&2
  exit 1
fi
echo "Validated ${#VALID_MODELS[@]} of ${#MODELS[@]} model(s)."

# ── Discover existing application profiles ────────────────────────────────────
EXISTING_PROFILES=$(aws bedrock list-inference-profiles \
  --type-equals APPLICATION \
  --region "$AWS_REGION" \
  --query 'inferenceProfileSummaries[].inferenceProfileName' \
  --output json)

# ── Create application inference profiles ─────────────────────────────────────
echo ""
TAGS=$(jq -nc \
  --arg pid "$PROJECT_ID" \
  --arg aid "$APP_ID" \
  --arg con "$CONTACT" \
  '[{key:"wma:project_id",value:$pid},{key:"wma:application_id",value:$aid},{key:"wma:contact",value:$con}]')

for SYSTEM_ID in "${VALID_MODELS[@]}"; do
  SYSTEM_ARN="${ACCOUNT_ARN_PREFIX}:inference-profile/${SYSTEM_ID}"

  # Strip the "us.anthropic." prefix and replace '.'/':' with '-' using bash
  # parameter expansion — no subprocess, and portable (GNU `tr '.:' '--'` treats the
  # '--' set as end-of-options and errors).
  MODEL_SLUG="${SYSTEM_ID#us.anthropic.}"
  MODEL_SLUG="${MODEL_SLUG//[.:]/-}"
  PROFILE_NAME="${PROJECT_ID}-${APP_ID}-${MODEL_SLUG}"

  if echo "$EXISTING_PROFILES" | jq -e --arg name "$PROFILE_NAME" 'index($name) != null' &>/dev/null; then
    echo "  SKIP  $PROFILE_NAME (already exists)"
    continue
  fi

  RESULT=$(aws bedrock create-inference-profile \
    --inference-profile-name "$PROFILE_NAME" \
    --description "${PROJECT_ID} ${APP_ID}" \
    --model-source "{\"copyFrom\": \"$SYSTEM_ARN\"}" \
    --tags "$TAGS" \
    --region "$AWS_REGION" \
    --output json 2>&1) || {
      echo "  FAIL  $PROFILE_NAME: $RESULT"
      continue
    }

  ARN=$(echo "$RESULT" | jq -r '.inferenceProfileArn')
  echo "  OK    $PROFILE_NAME → $ARN"
done

echo ""
echo "Done. Profiles are tagged with:"
echo "  wma:project_id=$PROJECT_ID"
echo "  wma:application_id=$APP_ID"
echo "  wma:contact=$CONTACT"
echo ""
echo "Users can now run: ./configure-claude-cli.sh --project-id $PROJECT_ID"
