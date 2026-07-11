#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# configure-claude-cli.sh
#
# Discovers Bedrock application inference profiles for a given project and
# configures ~/.claude/settings.json so Claude Code uses them with friendly
# display names in the /model picker.
#
# No hardcoded model list — profiles are discovered from Bedrock and matched
# to Claude Code tiers (opus/sonnet/haiku) by inspecting the underlying
# foundation model.
#
# Prerequisites:
#   - AWS CLI v2 with a valid SSO session (aws sso login)
#   - jq
#   - Inference profiles already created (see create-bedrock-profiles.sh)
#
# Usage:
#   ./configure-claude-cli.sh --project-id uncertainty_ts
###############################################################################

# ── Defaults ──────────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-us-west-2}"
PROJECT_ID=""
APP_ID=""
OUTPUT="settings"
ASSUME_YES=0

# ── Parse arguments ───────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Configures Claude Code CLI to use tagged Bedrock inference profiles.

Required:
  --project-id ID      wma:project_id to look up profiles for

Optional:
  --app-id ID          wma:application_id — narrows discovery to one application's
                       profiles (names match "<project>-<app>-..."). Omit to match
                       every application under the project.
  --region REGION      AWS region (default: us-west-2)
  --output MODE        Where to write config (default: settings)
                         settings  Write env vars to ~/.claude/settings.json.
                                   Bedrock becomes the global default for every
                                   Claude Code session.
                         launcher  Write a sourceable launcher env file and print a
                                   claude-bedrock wrapper. Leaves settings.json
                                   untouched so another backend (e.g. an Anthropic
                                   subscription) stays the default; Bedrock is
                                   opt-in per launch. The file is named
                                   ~/.claude/bedrock-<project>[-<app>].sh so the
                                   wrapper can switch between them.
  --yes, -y            Skip the settings-mode overwrite confirmation prompt.

Examples:
  $(basename "$0") --project-id uncertainty_ts
  $(basename "$0") --project-id uncertainty_ts --output launcher
  $(basename "$0") --project-id uncertainty_ts --app-id claude --output launcher
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)  PROJECT_ID="$2";  shift 2 ;;
    --app-id)      APP_ID="$2";      shift 2 ;;
    --region)      AWS_REGION="$2";  shift 2 ;;
    --output)      OUTPUT="$2";      shift 2 ;;
    --yes|-y)      ASSUME_YES=1;     shift   ;;
    -h|--help)     usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$PROJECT_ID" ]]; then
  echo "Error: --project-id is required."
  usage
fi

if [[ "$OUTPUT" != "settings" && "$OUTPUT" != "launcher" ]]; then
  echo "Error: --output must be 'settings' or 'launcher' (got '$OUTPUT')."
  usage
fi

# ── Preflight checks ─────────────────────────────────────────────────────────
for cmd in aws jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required but not found in PATH." >&2
    exit 1
  fi
done

aws sts get-caller-identity &>/dev/null || {
  echo "Error: unable to get AWS identity. Run 'aws sso login' first." >&2
  exit 1
}

# ── Discover application inference profiles for this project ──────────────────
# Profiles are named "<project>-<app>-<model>". Match on a delimiter-terminated
# prefix so project "uncertainty" does not also pull in "uncertainty_ts". When
# --app-id is given, narrow further to that one application's profiles.
PREFIX="${PROJECT_ID}-"
SCOPE="project '$PROJECT_ID'"
if [ -n "$APP_ID" ]; then
  PREFIX="${PROJECT_ID}-${APP_ID}-"
  SCOPE="project '$PROJECT_ID' / application '$APP_ID'"
fi

echo "Searching for inference profiles matching ${SCOPE}..."

ALL_PROFILES=$(aws bedrock list-inference-profiles \
  --type-equals APPLICATION \
  --region "$AWS_REGION" \
  --output json)

PROJECT_PROFILES=$(echo "$ALL_PROFILES" | jq -c --arg prefix "$PREFIX" \
  '[.inferenceProfileSummaries[] | select(.inferenceProfileName | startswith($prefix))]')

PROFILE_COUNT=$(echo "$PROJECT_PROFILES" | jq length)
if [ "$PROFILE_COUNT" -eq 0 ]; then
  echo "Error: no inference profiles found for ${SCOPE}." >&2
  echo "Run create-bedrock-profiles.sh first to create them." >&2
  exit 1
fi
echo "Found $PROFILE_COUNT profile(s)."

# ── Map profiles to Claude Code tiers ─────────────────────────────────────────
# Use a jq object to accumulate tier -> {arn, friendly} mappings.
# For each profile, inspect the underlying foundation model to determine the
# tier (opus/sonnet/haiku) and derive a friendly display name.

CLASSIFIED=$(echo "$PROJECT_PROFILES" | jq -c '
  reduce .[] as $p ({tiers: {}, extras: [], matches: []};
    ($p.models[0].modelArn | split("/") | last) as $model_id |
    (if   ($model_id | test("opus-4-8"))   then {tier: "OPUS",   name: "Opus 4.8"}
     elif ($model_id | test("opus-4-7"))   then {tier: "OPUS",   name: "Opus 4.7"}
     elif ($model_id | test("opus-4-6"))   then {tier: "OPUS",   name: "Opus 4.6"}
     elif ($model_id | test("opus-4-5"))   then {tier: "OPUS",   name: "Opus 4.5"}
     elif ($model_id | test("opus-4-1"))   then {tier: "OPUS",   name: "Opus 4.1"}
     elif ($model_id | test("opus-4-"))    then {tier: "OPUS",   name: "Opus 4"}
     elif ($model_id | test("opus"))       then {tier: "OPUS",   name: "Opus"}
     elif ($model_id | test("sonnet-5"))   then {tier: "SONNET", name: "Sonnet 5"}
     elif ($model_id | test("sonnet-4-6")) then {tier: "SONNET", name: "Sonnet 4.6"}
     elif ($model_id | test("sonnet-4-5")) then {tier: "SONNET", name: "Sonnet 4.5"}
     elif ($model_id | test("sonnet-4-"))  then {tier: "SONNET", name: "Sonnet 4"}
     elif ($model_id | test("sonnet-3-7")) then {tier: "SONNET", name: "Sonnet 3.7"}
     elif ($model_id | test("sonnet"))     then {tier: "SONNET", name: "Sonnet"}
     elif ($model_id | test("haiku-4-5"))  then {tier: "HAIKU",  name: "Haiku 4.5"}
     elif ($model_id | test("haiku"))      then {tier: "HAIKU",  name: "Haiku"}
     else null
     end) as $match |
    if $match then
      (.tiers[$match.tier] = {arn: $p.inferenceProfileArn, name: $match.name})
      | .matches += [{tier: $match.tier, arn: $p.inferenceProfileArn}]
    else
      .extras += [{arn: $p.inferenceProfileArn, model: $model_id}]
    end
  )
')

# TIER_MAP keeps the shape the rest of the script expects; PROFILE_EXTRAS holds
# profiles (e.g. Fable) that matched no Claude Code tier. Both come from the same
# classification pass, so "extra" is exactly "matched no tier" and can't drift.
TIER_MAP=$(echo "$CLASSIFIED" | jq -c '.tiers')
PROFILE_EXTRAS=$(echo "$CLASSIFIED" | jq -c '.extras')

MATCHED=$(echo "$TIER_MAP" | jq 'length')
EXTRA_COUNT=$(echo "$PROFILE_EXTRAS" | jq 'length')
EXTRA_MODELS=$(echo "$PROFILE_EXTRAS" | jq -r '[.[].model] | join(", ")')

# Nothing usable at all → hard error. Extras alone are still usable in launcher
# mode, so only bail when there are no tiers AND no extras.
if [ "$MATCHED" -eq 0 ] && [ "$EXTRA_COUNT" -eq 0 ]; then
  echo "Error: no profiles could be mapped to Claude Code tiers." >&2
  exit 1
fi

# Warn when several profiles map to the same tier: only one wins (the fold keeps
# just one, in unspecified order), so a stale model version left over from an
# earlier run can silently shadow the intended one. Derived from the same
# classification pass, so it can't drift from the tier logic.
COLLISIONS=$(echo "$CLASSIFIED" | jq -r '
  .matches | group_by(.tier) | map(select(length > 1))[]
  | "  \(.[0].tier): \(length) profiles map here (one chosen arbitrarily) → \([.[].arn] | join(", "))"')
if [ -n "$COLLISIONS" ]; then
  echo "Warning: multiple profiles map to the same Claude Code tier:" >&2
  echo "$COLLISIONS" >&2
  echo "  Narrow with --app-id, or delete stale profiles, to make the choice unambiguous." >&2
fi

# Print what was found
for TIER in OPUS SONNET HAIKU; do
  ARN=$(echo "$TIER_MAP" | jq -r --arg t "$TIER" '.[$t].arn // empty')
  NAME=$(echo "$TIER_MAP" | jq -r --arg t "$TIER" '.[$t].name // empty')
  if [ -n "$ARN" ]; then
    echo "  ${TIER}  ${NAME} (${PROJECT_ID}) → $ARN"
  fi
done

# ── Build the Bedrock env vars (shared by both output modes) ──────────────────
ENV_JSON=$(echo "$TIER_MAP" | jq -c --arg pid "$PROJECT_ID" '
  {"CLAUDE_CODE_USE_BEDROCK": "1"} +
  (to_entries | reduce .[] as $e ({};
    . + {
      ("ANTHROPIC_DEFAULT_" + $e.key + "_MODEL"): $e.value.arn,
      ("ANTHROPIC_DEFAULT_" + $e.key + "_MODEL_NAME"): ($e.value.name + " (" + $pid + ")"),
      ("ANTHROPIC_DEFAULT_" + $e.key + "_MODEL_DESCRIPTION"): "Bedrock inference profile"
    }
  ))
')

# ── Launcher mode: write a sourceable env file, leave settings.json alone ─────
# Shell env vars take precedence over settings.json, so sourcing this file before
# launching Claude Code switches that one session to Bedrock without changing the
# global default. Useful when another backend (e.g. an Anthropic subscription)
# should stay the default and Bedrock is opt-in.
if [ "$OUTPUT" = "launcher" ]; then
  mkdir -p "$HOME/.claude"

  # One file per (project[, app]) so the wrapper can switch between them.
  # LAUNCHER_SLUG is exactly PREFIX without its trailing '-'.
  LAUNCHER_SLUG="${PREFIX%-}"
  LAUNCHER_FILE="$HOME/.claude/bedrock-${LAUNCHER_SLUG}.sh"

  echo ""
  echo "Writing launcher env file: $LAUNCHER_FILE"
  # Preserve any hand edits (e.g. an uncommented Fable line) recoverably.
  if [ -f "$LAUNCHER_FILE" ]; then
    cp "$LAUNCHER_FILE" "${LAUNCHER_FILE}.bak"
    echo "  (existing file backed up to ${LAUNCHER_FILE}.bak)"
  fi

  # Profiles with no Claude Code tier (e.g. Fable) — Claude Code has no slot for
  # them, so expose each as a commented main-model override the user can enable.
  # @sh shell-quotes each value safely, escaping any embedded quote — the same
  # quoting used for every export line below, including AWS_REGION.
  EXTRA_EXPORTS=$(echo "$PROFILE_EXTRAS" | jq -r \
    '.[] | "# export ANTHROPIC_MODEL=\(.arn|@sh)  # \(.model)"')

  {
    cat <<EOF
#!/usr/bin/env bash
# Bedrock backend for ${LAUNCHER_SLUG}.
# Generated by configure-claude-cli.sh — source before launching Claude Code.
# Requires an active AWS SSO session (aws sso login).

EOF
    jq -rn --arg r "$AWS_REGION" '"export AWS_REGION=\($r|@sh)"'
    echo "$ENV_JSON" | jq -r 'to_entries[] | "export \(.key)=\(.value|@sh)"'
    if [ -n "$EXTRA_EXPORTS" ]; then
      echo ""
      echo "# Profiles with no Claude Code tier (opus/sonnet/haiku). Uncomment ONE"
      echo "# to use it as this session's main model:"
      echo "$EXTRA_EXPORTS"
    fi
  } > "$LAUNCHER_FILE"
  echo "Wrote $LAUNCHER_FILE"

  # 'claude-bedrock' with no --project sources bedrock-default.sh. Point it at the
  # first project configured; leave an existing default alone (don't hijack it on
  # a later run) but show how to repoint. Only touch it if it's our symlink or absent.
  DEFAULT_LINK="$HOME/.claude/bedrock-default.sh"
  if [ ! -e "$DEFAULT_LINK" ] && [ ! -L "$DEFAULT_LINK" ]; then
    ln -s "bedrock-${LAUNCHER_SLUG}.sh" "$DEFAULT_LINK"
    echo "Set default for bare 'claude-bedrock' → ${LAUNCHER_SLUG}"
  elif [ -L "$DEFAULT_LINK" ]; then
    echo "Default for bare 'claude-bedrock' stays: $(readlink "$DEFAULT_LINK" | sed 's/^bedrock-//;s/\.sh$//')"
    echo "  Repoint it with: ln -sf bedrock-${LAUNCHER_SLUG}.sh \"$DEFAULT_LINK\""
  fi

  echo ""
  echo "Add this wrapper to your ~/.zshrc (or ~/.bashrc) once. It is the same every"
  echo "run and dispatches by --project/--application to your launcher files:"
  echo ""
  cat <<'EOF'
  claude-bedrock() {
    local proj="" app=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --project)      proj=$2; shift 2 ;;
        --application)  app=$2;  shift 2 ;;
        *) break ;;
      esac
    done
    local f="$HOME/.claude/bedrock-default.sh"
    [ -n "$proj" ] && f="$HOME/.claude/bedrock-${proj}${app:+-$app}.sh"
    if [ ! -f "$f" ]; then
      echo "No Bedrock launcher: $f" >&2
      echo "Available:" >&2; ls "$HOME"/.claude/bedrock-*.sh >&2 2>/dev/null
      return 1
    fi
    ( source "$f" && exec claude "$@" )
  }
EOF
  echo ""
  echo "Usage (put any --project/--application before other claude args):"
  echo "  claude                                 → default backend (settings.json unchanged)"
  echo "  claude-bedrock                         → default project (bedrock-default.sh)"
  echo "  claude-bedrock --project other         → sources ~/.claude/bedrock-other.sh"
  echo "  claude-bedrock --application notebooks  → sources ~/.claude/bedrock-${PROJECT_ID}-notebooks.sh"
  echo "  Each override needs its own launcher — re-run this script with the matching"
  echo "  --project-id/--app-id to generate it first."
  echo ""
  echo "Note: --project and --application are your on-the-fly billing switches."
  echo "wma:contact is a fixed owner/POC tag set when the profile is created (not a"
  echo "launch switch); per-person usage, if ever needed, comes from your AWS identity."
  echo ""
  echo "The subshell keeps these vars out of your normal shell, so plain 'claude'"
  echo "is unaffected. No changes were made to ~/.claude/settings.json."

  # If a prior settings-mode run already made Bedrock the global default, plain
  # 'claude' will NOT fall back to a subscription — say so rather than imply it.
  if [ -f "$HOME/.claude/settings.json" ] &&
     [ "$(jq -r '.env.CLAUDE_CODE_USE_BEDROCK // empty' "$HOME/.claude/settings.json" 2>/dev/null)" = "1" ]; then
    echo ""
    echo "Heads up: ~/.claude/settings.json already sets CLAUDE_CODE_USE_BEDROCK=1,"
    echo "so plain 'claude' also uses Bedrock. Remove that env block if you want"
    echo "plain 'claude' to use your subscription."
  fi
  exit 0
fi

# ── Update ~/.claude/settings.json ────────────────────────────────────────────
# Settings mode makes Bedrock the global default via env vars. With no tier
# profiles there is nothing to configure here (extras can't be tier defaults), so
# steer the user to launcher mode instead of writing a modelless Bedrock config.
if [ "$MATCHED" -eq 0 ]; then
  echo ""
  echo "No profiles map to a Claude Code tier (opus/sonnet/haiku); nothing to write"
  echo "to settings.json. Re-run with --output launcher to use the non-tier profile(s):"
  echo "  $EXTRA_MODELS"
  exit 0
fi

SETTINGS_FILE="$HOME/.claude/settings.json"
echo ""

mkdir -p "$HOME/.claude"
if [ ! -f "$SETTINGS_FILE" ]; then
  echo "Creating $SETTINGS_FILE..."
  echo '{}' > "$SETTINGS_FILE"
fi

# Check for existing model env vars that would be overwritten
EXISTING_ENV=$(jq -r '.env // {} | keys[]' "$SETTINGS_FILE" 2>/dev/null)
CONFLICTS=""
for KEY in $(echo "$ENV_JSON" | jq -r 'keys[]'); do
  if echo "$EXISTING_ENV" | grep -qx "$KEY"; then
    OLD_VAL=$(jq -r --arg k "$KEY" '.env[$k]' "$SETTINGS_FILE")
    NEW_VAL=$(echo "$ENV_JSON" | jq -r --arg k "$KEY" '.[$k]')
    if [ "$OLD_VAL" != "$NEW_VAL" ]; then
      CONFLICTS="${CONFLICTS}  ${KEY}\n    old: ${OLD_VAL}\n    new: ${NEW_VAL}\n"
    fi
  fi
done

if [ -n "$CONFLICTS" ]; then
  echo "The following env vars in $SETTINGS_FILE will be overwritten:"
  echo ""
  printf "$CONFLICTS"
  echo ""
  if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
    # Non-interactive (e.g. run by the setup skill via a non-tty) or --yes:
    # proceed. These keys are ones this tool owns, so overwriting them on an
    # upgrade is the intent. A bare `read` here would hit EOF and, under
    # `set -e`, abort the whole script before the merge (settings never updated).
    echo "(--yes or non-interactive input: proceeding with the overwrite.)"
  else
    REPLY=""
    read -r -p "Continue? [y/N] " REPLY || REPLY=""
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 0
    fi
  fi
fi

# Merge into existing settings, preserving other fields
TEMP_FILE=$(mktemp)
jq --argjson new_env "$ENV_JSON" '.env = ((.env // {}) + $new_env)' "$SETTINGS_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$SETTINGS_FILE"

echo "Updated $SETTINGS_FILE"
echo ""
echo "The /model picker will show:"
for TIER in OPUS SONNET HAIKU; do
  NAME=$(echo "$TIER_MAP" | jq -r --arg t "$TIER" '.[$t].name // empty')
  if [ -n "$NAME" ]; then
    echo "  ${NAME} (${PROJECT_ID})"
  fi
done
echo ""
echo "Restart Claude Code for changes to take effect."

# Acknowledge profiles that have no Claude Code tier (e.g. Fable) so they aren't
# silently dropped in settings mode — they can only be surfaced via a launcher.
if [ "$EXTRA_COUNT" -gt 0 ]; then
  echo ""
  echo "Note: these profile(s) have no Claude Code tier and were not configured:"
  echo "  $EXTRA_MODELS"
  echo "  Re-run with --output launcher to expose them as optional main-model overrides."
fi
