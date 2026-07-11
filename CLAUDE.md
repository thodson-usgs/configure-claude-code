# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Purpose

This repo is a Claude Code plugin (`bedrock-profiles`) that sets up tagged AWS Bedrock inference profiles for cost attribution. Users install it via `/plugin marketplace add`, then run `/bedrock-profiles:setup` to interactively create profiles and configure their CLI.

## Architecture

This is a single-plugin marketplace. The plugin structure:

```
.claude-plugin/
  plugin.json            # plugin manifest (name, version, etc.)
  marketplace.json       # marketplace catalog listing this plugin
skills/
  setup/
    SKILL.md             # skill definition (interactive setup flow)
    create-bedrock-profiles.sh
    configure-claude-cli.sh
```

- **`SKILL.md`** instructs Claude to run preflight checks, gather project tags interactively, discover or create Bedrock profiles, and configure `~/.claude/settings.json`.
- **`create-bedrock-profiles.sh`** creates tagged Bedrock application inference profiles. Idempotent (skips existing). Maintains the canonical model list in the `MODELS` array at the top. Validation is skip-and-warn: a model with no system profile in the account/region is skipped (not fatal); the run only aborts if *no* models are available.
- **`configure-claude-cli.sh`** discovers profiles by project ID (delimiter-anchored `"<project>-"` prefix, or `"<project>-<app>-"` when `--app-id` is given), maps them to Claude Code tiers (opus/sonnet/haiku) via regex on the foundation model ID, and emits env vars. `--output settings` (default) writes them to `~/.claude/settings.json` (Bedrock becomes the global default; prompts before overwriting existing env vars, unless `--yes` or a non-tty stdin, in which case it proceeds — a bare `read` would otherwise abort under `set -e` when the setup skill runs it non-interactively). `--output launcher` instead writes a sourceable `~/.claude/bedrock-<project>[-<app>].sh` (backing up any prior copy to `.bak`) and prints a static `claude-bedrock` wrapper (identical every run) that dispatches by `--project`/`--application` to the matching launcher file — bare `claude-bedrock` follows a `bedrock-default.sh` symlink that configure points at the first-configured project — leaving `settings.json` untouched so another backend (e.g. an Anthropic subscription) stays the default and Bedrock is opt-in per launch. Profiles with no Claude Code tier (e.g. Fable) are added to the launcher as commented `ANTHROPIC_MODEL` overrides. Exported values are shell-quoted via jq `@sh`. When multiple profiles map to one tier, it warns (the fold keeps only one).

Both scripts follow the same structure: argument parsing, preflight checks (`aws`, `jq`), AWS API calls, and output. There is no shared code between them.

**Key design decisions:**
- Claude Code has three model tiers (opus/sonnet/haiku). Models outside those tiers (e.g. Fable) still get a tagged profile from `create-bedrock-profiles.sh`, but `configure-claude-cli.sh` can't map them to a tier — in launcher mode it surfaces them as commented `ANTHROPIC_MODEL` overrides instead.
- `configure-claude-cli.sh` has no hardcoded model list; it dynamically discovers profiles from Bedrock.
- Tags use `wma:` prefix (`wma:project_id`, `wma:application_id`, `wma:contact`) for cost attribution.
- Profile naming convention: `{project_id}-{app_id}-{model_slug}` where the slug is derived from the system profile ID with `us.anthropic.` stripped and `.:` replaced with `-`.
- Neither script clobbers existing state: `create-bedrock-profiles.sh` skips profiles that already exist, and `configure-claude-cli.sh` warns before overwriting env vars.

## Prerequisites

- AWS CLI v2 with a valid SSO session (`aws sso login`)
- `jq`

## Running

```bash
# Install the plugin
/plugin marketplace add thodson-usgs/configure-claude-code
/plugin install bedrock-profiles

# Run the skill
/bedrock-profiles:setup

# Or with arguments
/bedrock-profiles:setup --project-id my_project --app-id claude --contact user@example.com
```

Scripts can also be run standalone:
```bash
bash skills/setup/create-bedrock-profiles.sh --help
bash skills/setup/configure-claude-cli.sh --help
```

Both accept `--region` (default: `us-west-2`).

## Updating models

Edit the `MODELS` array at the top of `skills/setup/create-bedrock-profiles.sh`, then re-run the skill or both scripts. To see what's available in the account:

```bash
aws bedrock list-inference-profiles --type-equals SYSTEM_DEFINED \
  | jq -r '.inferenceProfileSummaries[].inferenceProfileId' | grep anthropic
```

When adding a new model version, also add a matching `test(...)` case to the tier-mapping regex in `configure-claude-cli.sh` so the `/model` picker shows a correct friendly name (e.g. "Opus 4.8" rather than the generic "Opus 4").

## Testing

No test suite exists. To verify changes, test against a real AWS account with `aws sso login` active. Check idempotency by running `create-bedrock-profiles.sh` twice -- the second run should show `SKIP` for all profiles.
