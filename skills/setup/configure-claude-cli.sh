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
AWS_PROFILE_ARG=""     # --aws-profile: pin the SSO profile; else bridge at runtime
ISOLATE=1              # launcher mode: isolate Bedrock config; --shared-config disables

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
  --aws-profile NAME   AWS named profile Claude Code should use for Bedrock. Claude
                       Code's SDK reads AWS_PROFILE (not AWS_DEFAULT_PROFILE), so
                       without this the launcher bridges whatever profile your shell
                       already uses. Omit to auto-detect / bridge at runtime.
  --shared-config      Launcher mode only: DON'T isolate Bedrock's config directory.
                       By default the launcher sets CLAUDE_CODE_USE_BEDROCK's config
                       to ~/.claude-bedrock so a model pick in a Bedrock session can't
                       rewrite the subscription's default model. This opts out.
  --yes, -y            Skip the settings-mode overwrite confirmation prompt.

Examples:
  $(basename "$0") --project-id uncertainty_ts
  $(basename "$0") --project-id uncertainty_ts --output launcher
  $(basename "$0") --project-id uncertainty_ts --app-id claude --output launcher
EOF
  exit 1
}

# Value-taking flags read $2 via ${2:?...} so a flag given as the final token fails
# with a clear message instead of a cryptic `$2: unbound variable` under `set -u`.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)   PROJECT_ID="${2:?--project-id requires a value}";   shift 2 ;;
    --app-id)       APP_ID="${2:?--app-id requires a value}";           shift 2 ;;
    --region)       AWS_REGION="${2:?--region requires a value}";       shift 2 ;;
    --output)       OUTPUT="${2:?--output requires a value}";           shift 2 ;;
    --aws-profile)  AWS_PROFILE_ARG="${2:?--aws-profile requires a value}"; shift 2 ;;
    --shared-config) ISOLATE=0;      shift   ;;
    --yes|-y)       ASSUME_YES=1;    shift   ;;
    -h|--help)      usage ;;
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

# The profile Claude Code's SDK should use: explicit --aws-profile, else whatever the
# current shell already resolves (AWS_PROFILE, then AWS_DEFAULT_PROFILE). May be empty
# in launcher mode, where the launcher bridges it dynamically at source time.
RESOLVED_PROFILE="${AWS_PROFILE_ARG:-${AWS_PROFILE:-${AWS_DEFAULT_PROFILE:-}}}"

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

# A name prefix alone is ambiguous: '-' is the project/app delimiter AND a legal
# character inside a project or app id, so "myproj-claude-" also matches a sibling
# application's "myproj-claude-notebooks-..." profiles. Filter authoritatively by the
# wma:* TAGS instead. The name prefix is only a cheap pre-filter to bound how many
# per-profile tag lookups we do (profiles created by create-bedrock-profiles.sh always
# start with "<project>-").
CANDIDATES=$(echo "$ALL_PROFILES" | jq -c --arg p "${PROJECT_ID}-" \
  '[.inferenceProfileSummaries[] | select(.inferenceProfileName | startswith($p))]')

MATCHES=""
APP_PAIRS=""             # every (app<TAB>contact) this scope covers — a project-scoped
                         # launcher spans all the project's apps, each with its own contact.
while IFS= read -r PROF; do
  ARN=$(echo "$PROF" | jq -r '.inferenceProfileArn')
  TAGS=$(aws bedrock list-tags-for-resource --resource-arn "$ARN" --region "$AWS_REGION" \
    --query 'tags' --output json 2>/dev/null || echo '[]')
  # One jq pass pulls the tag values we need (empty string when a tag is absent).
  IFS=$'\t' read -r PID AID CID < <(echo "$TAGS" | jq -r \
    'from_entries as $t | "\($t["wma:project_id"] // "")\t\($t["wma:application_id"] // "")\t\($t["wma:contact"] // "")"')
  [ "$PID" = "$PROJECT_ID" ] || continue
  if [ -n "$APP_ID" ] && [ "$AID" != "$APP_ID" ]; then continue; fi
  MATCHES="${MATCHES}${PROF}"$'\n'
  APP_PAIRS="${APP_PAIRS}${AID}"$'\t'"${CID}"$'\n'
done < <(echo "$CANDIDATES" | jq -c '.[]')

# Dedup pairs by application, keeping the first contact seen for each (deterministic in
# API order). This is the authoritative per-app contact list `--update-profiles` re-tags with.
APP_PAIRS=$(printf '%s' "$APP_PAIRS" | awk -F'\t' 'NF && !seen[$1]++')

# The representative app/contact baked into the launcher (app-scoped reconfigure path and
# legacy fallback) is just the first deduped pair — one source of truth (APP_PAIRS), so the
# two can't come from different applications. --app-id, when given, pins the app explicitly.
RESOLVED_APP="${APP_ID:-$(printf '%s\n' "$APP_PAIRS" | head -n1 | cut -f1)}"
RESOLVED_CONTACT=$(printf '%s\n' "$APP_PAIRS" | head -n1 | cut -f2)

# Slurp the matched objects once rather than rebuilding a growing array each iteration.
PROJECT_PROFILES=$(printf '%s' "$MATCHES" | jq -sc '.')
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

# `rank` orders versions WITHIN a tier (higher = newer). When several profiles map to
# the same tier (e.g. a leftover Opus 4.6 alongside a new Opus 4.8), the highest rank
# wins deterministically — so upgrading models is just "create the new profile + re-run
# configure", with no need to delete the old one first.
CLASSIFIED=$(echo "$PROJECT_PROFILES" | jq -c '
  reduce .[] as $p ({tiers: {}, extras: [], matches: []};
    ($p.models[0].modelArn | split("/") | last) as $model_id |
    (if   ($model_id | test("opus-4-8"))   then {tier: "OPUS",   name: "Opus 4.8",   rank: 48}
     elif ($model_id | test("opus-4-7"))   then {tier: "OPUS",   name: "Opus 4.7",   rank: 47}
     elif ($model_id | test("opus-4-6"))   then {tier: "OPUS",   name: "Opus 4.6",   rank: 46}
     elif ($model_id | test("opus-4-5"))   then {tier: "OPUS",   name: "Opus 4.5",   rank: 45}
     elif ($model_id | test("opus-4-1"))   then {tier: "OPUS",   name: "Opus 4.1",   rank: 41}
     elif ($model_id | test("opus-4-"))    then {tier: "OPUS",   name: "Opus 4",     rank: 40}
     elif ($model_id | test("opus"))       then {tier: "OPUS",   name: "Opus",       rank: 10}
     elif ($model_id | test("sonnet-5"))   then {tier: "SONNET", name: "Sonnet 5",   rank: 50}
     elif ($model_id | test("sonnet-4-6")) then {tier: "SONNET", name: "Sonnet 4.6", rank: 46}
     elif ($model_id | test("sonnet-4-5")) then {tier: "SONNET", name: "Sonnet 4.5", rank: 45}
     elif ($model_id | test("sonnet-4-"))  then {tier: "SONNET", name: "Sonnet 4",   rank: 40}
     elif ($model_id | test("3-7-sonnet")) then {tier: "SONNET", name: "Sonnet 3.7", rank: 37}
     elif ($model_id | test("sonnet"))     then {tier: "SONNET", name: "Sonnet",     rank: 10}
     elif ($model_id | test("haiku-4-5"))  then {tier: "HAIKU",  name: "Haiku 4.5",  rank: 45}
     elif ($model_id | test("haiku"))      then {tier: "HAIKU",  name: "Haiku",      rank: 10}
     else null
     end) as $match |
    if $match then
      ($p.inferenceProfileArn) as $arn |
      # Winner = highest rank; on a rank TIE break by smallest ARN so the choice is
      # deterministic (independent of API listing order) and matches the COLLISIONS report.
      (if (.tiers[$match.tier] == null)
          or ($match.rank > .tiers[$match.tier].rank)
          or ($match.rank == .tiers[$match.tier].rank and $arn < .tiers[$match.tier].arn)
       then .tiers[$match.tier] = {arn: $arn, name: $match.name, rank: $match.rank}
       else . end)
      | .matches += [{tier: $match.tier, name: $match.name, arn: $arn, rank: $match.rank}]
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

# When several profiles map to one tier, the newest (highest rank) is wired; note which
# older ones are being ignored so a leftover version isn't a surprise. Derived from the
# same classification pass, so it can't drift from the tier logic.
COLLISIONS=$(echo "$CLASSIFIED" | jq -r '
  # Read the winner the reduce already picked (.tiers) rather than re-deriving the
  # ordering here — one source of truth, so the note can never disagree with what is wired.
  . as $root | .matches | group_by(.tier) | map(select(length > 1))[]
  | .[0].tier as $tier | $root.tiers[$tier] as $keep
  | "  \($tier): using \($keep.name); ignoring older \([.[] | select(.arn != $keep.arn) | .name] | unique | join(", "))"')
if [ -n "$COLLISIONS" ]; then
  echo "Note: multiple versions map to the same tier — using the newest:" >&2
  echo "$COLLISIONS" >&2
  echo "  (Delete the older profiles if you want them gone; they're otherwise ignored.)" >&2
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
# Note: the "<name> (<project>)" display-name format below is parsed by statusline.sh
# (it treats a name ending in "(<project>)" as a tagged/billable session) — keep the two
# in sync if you change the suffix.
ENV_JSON=$(echo "$TIER_MAP" | jq -c --arg pid "$PROJECT_ID" --arg region "$AWS_REGION" '
  {"CLAUDE_CODE_USE_BEDROCK": "1", "AWS_REGION": $region} +
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
  # .arn is the TAGGED application-inference-profile ARN, so enabling one keeps the
  # session billed to this project. @sh shell-quotes each value safely.
  EXTRA_EXPORTS=$(echo "$PROFILE_EXTRAS" | jq -r \
    '.[] | "# export ANTHROPIC_MODEL=\(.arn|@sh)  # \(.model) — tagged to this project"')

  # AWS_PROFILE line: Claude Code's SDK reads AWS_PROFILE (NOT AWS_DEFAULT_PROFILE), so
  # without it SSO credentials don't resolve and Bedrock calls hang ~60s then fail. Pin
  # it when --aws-profile was given; otherwise bridge from whatever the shell resolves.
  if [ -n "$AWS_PROFILE_ARG" ]; then
    AWS_PROFILE_LINE=$(jq -rn --arg p "$AWS_PROFILE_ARG" '"export AWS_PROFILE=\($p|@sh)"')
  else
    AWS_PROFILE_LINE=': "${AWS_PROFILE:=${AWS_DEFAULT_PROFILE:-}}"; [ -n "${AWS_PROFILE:-}" ] && export AWS_PROFILE'
  fi

  # Isolated config dir keeps a model pick in a Bedrock session from rewriting the
  # subscription's default model (they otherwise share ~/.claude/settings.json's model).
  CONFIG_DIR="$HOME/.claude-bedrock"
  if [ "$ISOLATE" -eq 1 ]; then
    CONFIG_DIR_LINE='export CLAUDE_CONFIG_DIR="$HOME/.claude-bedrock"'
  else
    CONFIG_DIR_LINE='# config isolation disabled (--shared-config): shares ~/.claude'
  fi

  # Absolute path to these scripts, baked so `claude-bedrock --update-profiles` can find
  # create/configure later (falls back gracefully in the wrapper if it ever moves).
  SETUP_DIR=$(cd "$(dirname "$0")" && pwd)
  # Whether this launcher is app-scoped (name is bedrock-<project>-<app>.sh). --update
  # must reconfigure the SAME way (with/without --app-id) so it rewrites this same file.
  if [ -n "$APP_ID" ]; then APP_SCOPED=1; else APP_SCOPED=0; fi

  # Every (app, contact) pair this launcher covers, as a compact JSON array. A project-scoped
  # launcher spans all the project's apps, so `--update-profiles` must recreate profiles for
  # EACH — not just the representative CLAUDE_BEDROCK_APP — using each app's own contact.
  APP_PAIRS_JSON=$(printf '%s' "$APP_PAIRS" | jq -Rsc '
    split("\n") | map(select(length > 0) | split("\t") | {app: .[0], contact: .[1]})')

  {
    cat <<EOF
#!/usr/bin/env bash
# Bedrock backend for ${LAUNCHER_SLUG}.
# Generated by configure-claude-cli.sh — source before launching Claude Code.
# Requires an active AWS SSO session (aws sso login).

# Claude Code's AWS SDK reads AWS_PROFILE (not AWS_DEFAULT_PROFILE). Override by
# exporting AWS_PROFILE before launching.
${AWS_PROFILE_LINE}
EOF
    echo "$ENV_JSON" | jq -r 'to_entries[] | "export \(.key)=\(.value|@sh)"'
    jq -rn --arg p "$PROJECT_ID" '"export CLAUDE_BEDROCK_PROJECT=\($p|@sh)  # statusline cost-attribution badge"'
    echo "$CONFIG_DIR_LINE"
    # Baked so `claude-bedrock --update-profiles` can re-run create + configure unattended.
    jq -rn --arg a "$RESOLVED_APP" --arg c "$RESOLVED_CONTACT" --arg d "$SETUP_DIR" \
      '"export CLAUDE_BEDROCK_APP=\($a|@sh)", "export CLAUDE_BEDROCK_CONTACT=\($c|@sh)", "export CLAUDE_BEDROCK_SETUP_DIR=\($d|@sh)"'
    echo "export CLAUDE_BEDROCK_APP_SCOPED='$APP_SCOPED'"
    # Full per-app (app, contact) coverage for --update-profiles (see wrapper). A project-scoped
    # launcher recreates every app's profiles with that app's own contact; an app-scoped one
    # holds a single entry. @sh-quoted so it survives sourcing intact.
    jq -rn --argjson pairs "$APP_PAIRS_JSON" '"export CLAUDE_BEDROCK_APP_PAIRS=\($pairs|tojson|@sh)"'
    if [ -n "$EXTRA_EXPORTS" ]; then
      echo ""
      echo "# Profiles with no Claude Code tier (opus/sonnet/haiku). Uncomment ONE to"
      echo "# use it as this session's main model (stays tagged to this project):"
      echo "$EXTRA_EXPORTS"
    fi
  } > "$LAUNCHER_FILE"
  echo "Wrote $LAUNCHER_FILE"

  # Install the cost-attribution statusline badge and, when isolating, seed the Bedrock
  # config dir to use it with a Bedrock-safe default model. The badge lives at a distinct
  # path so it never clobbers a statusline the user already set in ~/.claude/settings.json.
  STATUSLINE_SRC="$(dirname "$0")/statusline.sh"
  STATUSLINE_DST="$HOME/.claude/bedrock-statusline.sh"
  if [ -f "$STATUSLINE_SRC" ]; then
    cp "$STATUSLINE_SRC" "$STATUSLINE_DST" && chmod +x "$STATUSLINE_DST"
    echo "Installed statusline badge → $STATUSLINE_DST"
  fi
  if [ "$ISOLATE" -eq 1 ]; then
    mkdir -p "$CONFIG_DIR"
    SEED="$CONFIG_DIR/settings.json"
    if [ ! -f "$SEED" ]; then
      jq -n --arg sl "$STATUSLINE_DST" \
        '{model:"opus", statusLine:{type:"command", command:$sl}}' > "$SEED"
      echo "Seeded isolated Bedrock config → $SEED"
    fi
  fi

  # 'claude-bedrock' with no --project sources bedrock-default.sh. Point it at the
  # first project configured; leave an existing default alone (don't hijack it on
  # a later run) but show how to repoint. Only touch it if it's our symlink or absent.
  DEFAULT_LINK="$HOME/.claude/bedrock-default.sh"
  # `! -e` is true when the link is absent OR dangling (a broken symlink fails -e but
  # passes -L). Either way, (re)point it at this launcher; -f handles the dangling case.
  # Note whether it was a dangling link *before* creating it (afterwards -L is always true).
  if [ ! -e "$DEFAULT_LINK" ]; then
    [ -L "$DEFAULT_LINK" ] && WAS_DANGLING=1 || WAS_DANGLING=0
    ln -sf "bedrock-${LAUNCHER_SLUG}.sh" "$DEFAULT_LINK"
    if [ "$WAS_DANGLING" -eq 1 ]; then
      echo "Default for bare 'claude-bedrock' was dangling → repointed to ${LAUNCHER_SLUG}"
    else
      echo "Set default for bare 'claude-bedrock' → ${LAUNCHER_SLUG}"
    fi
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
    local proj="" app="" update=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --project)
          [ $# -ge 2 ] || { echo "claude-bedrock: --project needs a value" >&2; return 1; }
          proj=$2; shift 2 ;;
        --application)
          [ $# -ge 2 ] || { echo "claude-bedrock: --application needs a value" >&2; return 1; }
          app=$2; shift 2 ;;
        --update-profiles) update=1; shift ;;
        *) break ;;
      esac
    done
    # --application without --project means "the default project's <app>". Read the
    # default project from the default launcher itself (its exported CLAUDE_BEDROCK_PROJECT
    # is the single source of truth), so repointing the default can't desync it.
    if [ -z "$proj" ] && [ -n "$app" ]; then
      proj=$( . "$HOME/.claude/bedrock-default.sh" >/dev/null 2>&1; printf %s "${CLAUDE_BEDROCK_PROJECT:-}" )
      [ -n "$proj" ] || { echo "claude-bedrock: pass --project with --application (couldn't resolve the default project)" >&2; return 1; }
    fi
    local f="$HOME/.claude/bedrock-default.sh"
    [ -n "$proj" ] && f="$HOME/.claude/bedrock-${proj}${app:+-$app}.sh"
    if [ ! -f "$f" ]; then
      echo "No Bedrock launcher: $f" >&2
      echo "Available:" >&2; ls "$HOME"/.claude/bedrock-*.sh >&2 2>/dev/null
      return 1
    fi
    # --update-profiles: (re)create tagged profiles for the current model list and rewire
    # this launcher — no session is launched. Uses values baked into the launcher file.
    if [ "$update" = 1 ]; then
      ( source "$f" >/dev/null 2>&1
        d="${CLAUDE_BEDROCK_SETUP_DIR:-}"
        if [ -z "$d" ] || [ ! -f "$d/create-bedrock-profiles.sh" ]; then
          echo "claude-bedrock: setup scripts not found (CLAUDE_BEDROCK_SETUP_DIR='$d')." >&2
          echo "Re-run /bedrock-profiles:setup (or configure-claude-cli.sh) to refresh the launcher." >&2
          exit 1
        fi
        # A project-scoped launcher covers every app under the project; recreate profiles
        # for EACH (using that app's own contact) so a newly-added model reaches all of
        # them, not just the representative CLAUDE_BEDROCK_APP. CLAUDE_BEDROCK_APP_PAIRS is a
        # JSON array baked by configure; fall back to the single APP/CONTACT for launchers
        # written before it existed.
        pairs="${CLAUDE_BEDROCK_APP_PAIRS:-}"
        [ -n "$pairs" ] || pairs=$(printf '[{"app":%s,"contact":%s}]' \
          "$(printf %s "$CLAUDE_BEDROCK_APP" | jq -R .)" \
          "$(printf %s "$CLAUDE_BEDROCK_CONTACT" | jq -R .)")
        while IFS=$'\t' read -r a c; do
          [ -n "$a" ] || continue
          if [ -z "$c" ]; then
            # create-bedrock-profiles.sh requires --contact; skip this app with a warning
            # instead of aborting the whole update (which would strand the other apps too).
            echo "claude-bedrock: skipping app '$a' (no wma:contact recorded); re-run setup to add one." >&2
            continue
          fi
          bash "$d/create-bedrock-profiles.sh" --project-id "$CLAUDE_BEDROCK_PROJECT" \
            --app-id "$a" --contact "$c" --region "$AWS_REGION" || exit $?
        done < <(printf %s "$pairs" | jq -r '.[] | [.app, .contact] | @tsv')
        # Reconfigure the same way this launcher was created (app-scoped or not) so the
        # same file is rewritten rather than a differently-named one.
        if [ "${CLAUDE_BEDROCK_APP_SCOPED:-0}" = 1 ]; then
          bash "$d/configure-claude-cli.sh" --project-id "$CLAUDE_BEDROCK_PROJECT" \
            --app-id "$CLAUDE_BEDROCK_APP" --region "$AWS_REGION" --output launcher --yes
        else
          bash "$d/configure-claude-cli.sh" --project-id "$CLAUDE_BEDROCK_PROJECT" \
            --region "$AWS_REGION" --output launcher --yes
        fi )
      return $?
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
  echo "  claude-bedrock --update-profiles        → recreate tagged profiles for the latest"
  echo "                                            models and rewire (no session launched)"
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

# Fail clearly on a pre-existing but malformed settings.json instead of letting the
# first jq call fail with stderr suppressed and abort the script silently under set -e.
if ! jq -e . "$SETTINGS_FILE" >/dev/null 2>&1; then
  echo "Error: $SETTINGS_FILE is not valid JSON. Fix or remove it, then re-run." >&2
  exit 1
fi

# Settings mode bakes AWS_PROFILE in (settings.json can't bridge at runtime like the
# launcher does). Claude Code's SDK ignores AWS_DEFAULT_PROFILE, so without this a
# global-default Bedrock config can't resolve SSO credentials.
if [ -n "$RESOLVED_PROFILE" ]; then
  ENV_JSON=$(echo "$ENV_JSON" | jq -c --arg p "$RESOLVED_PROFILE" '. + {AWS_PROFILE: $p}')
else
  echo "Note: no AWS profile detected. Pass --aws-profile NAME (or export AWS_PROFILE)" >&2
  echo "  so Claude Code can resolve SSO credentials — it does not read AWS_DEFAULT_PROFILE." >&2
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
  # %b interprets the \n escapes in CONFLICTS without treating the embedded old/new
  # values (which may contain %) as printf format directives.
  printf '%b' "$CONFLICTS"
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
