#!/usr/bin/env bash
# Bedrock cost-attribution badge for Claude Code.
#   GREEN  ⬢ = a project-tagged Bedrock application-inference-profile — billable
#             to a project (wma:project_id). Safe to run.
#   YELLOW ⚠ = on Bedrock, but the model is a raw *system* profile (e.g. Fable),
#             which carries NO project tag — usage bills to the account untagged.
#   DIM    ○ = not Bedrock (Anthropic subscription / API key).
#
# Installed by configure-claude-cli.sh (launcher mode) as ~/.claude/bedrock-statusline.sh
# and wired into the isolated Bedrock config's settings.json. The launcher exports
# CLAUDE_CODE_USE_BEDROCK=1 and CLAUDE_BEDROCK_PROJECT=<project>, both read below.
#
# Safety bias: we only show "subscription" when BOTH signals say not-Bedrock, so the
# badge can never falsely claim the subscription while a session is really on Bedrock.
input=$(cat)
# One jq pass for both fields (this runs on every statusline render).
IFS=$'\t' read -r name mid < <(printf '%s' "$input" | jq -r '[.model.display_name // "model?", .model.id // ""] | @tsv')

# An application-inference-profile id is the unambiguous "tagged Bedrock" signal; compute
# it once and reuse for both the Bedrock and tagged decisions below.
aip=0
case "$mid" in *application-inference-profile*) aip=1 ;; esac

# Bedrock session? Primary signal: the launcher/settings export CLAUDE_CODE_USE_BEDROCK=1
# (inherited by this script). Backstop: the resolved model id is a Bedrock resource — an
# ARN, an application-inference-profile, or a "<region>.anthropic.*" system profile (any
# region, not just us./global.). We deliberately do NOT infer Bedrock from a missing
# rate_limits field — it is also empty at subscription startup and flashed a false badge.
bedrock=0
if [ "${CLAUDE_CODE_USE_BEDROCK:-}" = "1" ] || [ "$aip" = 1 ]; then
  bedrock=1
else
  case "$mid" in arn:aws:bedrock:*|*.anthropic.*) bedrock=1 ;; esac
fi

# Tagged = an application-inference-profile ARN (which carries the wma:* tags). Belt-and-
# suspenders: also accept a display name ending in "(<project>)" — the launcher bakes the
# project into the tier model names (see configure-claude-cli.sh) and exports
# CLAUDE_BEDROCK_PROJECT. A raw "<region>.anthropic.*" system profile matches neither.
proj="${CLAUDE_BEDROCK_PROJECT:-}"
tagged=$aip
if [ "$tagged" = 0 ] && [ -n "$proj" ]; then
  case "$name" in *"($proj)") tagged=1 ;; esac
fi

if [ "$bedrock" = 1 ] && [ "$tagged" = 1 ]; then
  printf '\033[1;32m⬢ Bedrock · %s\033[0m · %s' "${proj:-tagged}" "$name"
elif [ "$bedrock" = 1 ]; then
  printf '\033[1;33m⚠ Bedrock · UNTAGGED\033[0m · %s' "$name"
else
  printf '\033[2m○ subscription · %s\033[0m' "$name"
fi
