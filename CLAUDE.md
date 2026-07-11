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
    statusline.sh        # Bedrock cost-attribution badge (installed by launcher mode)
```

- **`SKILL.md`** instructs Claude to run preflight checks, gather project tags interactively, discover or create Bedrock profiles, and configure `~/.claude/settings.json`. It invokes the helper scripts via `"${CLAUDE_SKILL_DIR}/..."` (the documented substitution for a plugin skill's own directory).
- **`create-bedrock-profiles.sh`** creates tagged Bedrock application inference profiles. Idempotent (skips existing). Maintains the canonical model list in the `MODELS` array at the top. Validation is skip-and-warn (one `list-inference-profiles` call + a jq membership check per model): a model with no system profile in the account/region is skipped (not fatal); the run only aborts if *no* models are available. A model that exists but is denied by an org policy (SCP/identity) still fails at `create-inference-profile` and is reported as `FAIL` while the run continues.
- **`configure-claude-cli.sh`** discovers profiles for a project by **wma:\* tags** (a `"<project>-"` name prefix is only a cheap pre-filter; the authoritative match reads `wma:project_id` / `wma:application_id` via `list-tags-for-resource`, because hyphen-delimited names are ambiguous — a project or app id can itself contain hyphens). It maps profiles to Claude Code tiers (opus/sonnet/haiku) via regex on the foundation model ID and emits env vars. `--output settings` (default) writes them to `~/.claude/settings.json` (Bedrock becomes the global default; includes `AWS_REGION` and a resolved `AWS_PROFILE`; prompts before overwriting existing env vars, unless `--yes` or a non-tty stdin, in which case it proceeds — a bare `read` would otherwise abort under `set -e` when the setup skill runs it non-interactively). `--output launcher` instead writes a sourceable `~/.claude/bedrock-<project>[-<app>].sh` (backing up any prior copy to `.bak`) and prints a static `claude-bedrock` wrapper (identical every run) that dispatches by `--project`/`--application` to the matching launcher file — bare `claude-bedrock` follows a `bedrock-default.sh` symlink that configure points at the first-configured project (recorded in `~/.claude/bedrock-default-project` so `--application X` alone resolves to `<default-project>-X` rather than silently billing the default). Launcher mode leaves `settings.json` untouched so another backend (e.g. an Anthropic subscription) stays the default and Bedrock is opt-in per launch. Profiles with no Claude Code tier (e.g. Fable) are added to the launcher as commented `ANTHROPIC_MODEL` overrides pointing at the **tagged** profile ARN. Exported values are shell-quoted via jq `@sh`. When multiple profiles map to one tier, it warns (the fold keeps only one).

Both scripts follow the same structure: argument parsing, preflight checks (`aws`, `jq`), AWS API calls, and output. There is no shared code between them.

**Key design decisions:**
- **`AWS_PROFILE`, not `AWS_DEFAULT_PROFILE`.** Claude Code's AWS SDK resolves credentials from `AWS_PROFILE` only; if a user has just `AWS_DEFAULT_PROFILE` set (common with the AWS CLI), Bedrock calls hang ~60s on the default credential chain then fail. Launcher mode bridges it (`: "${AWS_PROFILE:=${AWS_DEFAULT_PROFILE:-}}"; [ -n … ] && export AWS_PROFILE`) or pins `--aws-profile`; settings mode bakes a resolved value in.
- **Config isolation (launcher mode default).** The launcher exports `CLAUDE_CONFIG_DIR="$HOME/.claude-bedrock"` so a `/model` pick in a Bedrock session persists there, not in `~/.claude/settings.json` — otherwise selecting a Bedrock-only model (e.g. Fable's `us.anthropic.*` id) rewrites the shared global default and breaks plain `claude` on the subscription. Bedrock auth is AWS-based, so the separate config needs no extra `/login`. `--shared-config` opts out. The isolated config is seeded with `model: "opus"` and the statusline.
- **`statusline.sh` cost-attribution badge.** Installed to `~/.claude/bedrock-statusline.sh` (a distinct path so it never clobbers a user's own statusline) and wired into the isolated config. Green ⬢ = tagged application-inference-profile (billable to a project); yellow ⚠ = on Bedrock but an untagged system profile; dim ○ = subscription. Detects Bedrock via `CLAUDE_CODE_USE_BEDROCK` (exported by the launcher, plus `CLAUDE_BEDROCK_PROJECT` for the label) and the model id shape — never from a missing `rate_limits` field, which is also absent at subscription startup and would flash a false badge. It only shows "subscription" when *both* signals say not-Bedrock, so it can't falsely claim the subscription while on Bedrock.
- Claude Code has three model tiers (opus/sonnet/haiku). Models outside those tiers (e.g. Fable) still get a tagged profile from `create-bedrock-profiles.sh`, but `configure-claude-cli.sh` can't map them to a tier — in launcher mode it surfaces them as commented `ANTHROPIC_MODEL` overrides (pointing at the tagged ARN) instead. Note: preview/promo models like Fable are frequently blocked by org SCPs (deny on the foundation model) and/or identity policies (deny invoking the raw system profile), so they may be unusable on Bedrock regardless of tagging — they still work on an Anthropic subscription.
- `configure-claude-cli.sh` has no hardcoded model list; it dynamically discovers profiles from Bedrock.
- Tags use `wma:` prefix (`wma:project_id`, `wma:application_id`, `wma:contact`) for cost attribution.
- Profile naming convention: `{project_id}-{app_id}-{model_slug}` where the slug is derived from the system profile ID with `us.anthropic.` stripped and `.`/`:` replaced with `-` (via bash parameter expansion — portable, unlike GNU `tr '.:' '--'`).
- Neither script clobbers existing state: `create-bedrock-profiles.sh` skips profiles that already exist, and `configure-claude-cli.sh` warns before overwriting env vars.

## Prerequisites

- AWS CLI v2 with a valid SSO session (`aws sso login`)
- `jq`
- An `AWS_PROFILE` (or `AWS_DEFAULT_PROFILE`, which the launcher bridges) pointing at your SSO profile — Claude Code's SDK reads `AWS_PROFILE`.

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

A `MODELS` entry may be written bare (`us.anthropic.claude-opus-4-8`) even though Bedrock lists the system profile with a date/version suffix (`…-4-8-20260101-v1:0`): `create-bedrock-profiles.sh` resolves each entry to an exact match if present, otherwise the newest profile whose id starts with the entry followed by a `-`/`:` delimiter (so `…-sonnet-5` can't match `…-sonnet-50`), and uses the resolved id for both the `copyFrom` ARN and the profile slug. Keep the `MODELS` entries bare so they survive routine version bumps.

When adding a new model version, also add a matching `test(...)` case to the tier-mapping regex in `configure-claude-cli.sh` **with a `rank`** (higher = newer within a tier). On a tier collision `configure` wires the highest-ranked profile, breaking a rank *tie* by smallest ARN so the choice is deterministic (independent of API listing order) and the printed "using …" note always matches the profile actually wired. A leftover old-version profile is ignored rather than forcing a manual delete — creating a new-version profile and re-running `configure` is enough to upgrade.

Launcher users can do the whole update in one command: `claude-bedrock --update-profiles` re-runs `create-bedrock-profiles.sh` + `configure-claude-cli.sh` for that launcher's project/region and rewires it — no session is launched. A **project-scoped** launcher (created without `--app-id`) spans every application under the project, so `configure` bakes the full per-app `(app, contact)` set into the launcher as `CLAUDE_BEDROCK_APP_PAIRS` (a JSON array); `--update-profiles` recreates each app's profiles with that app's own `wma:contact`, so a newly-added model reaches all of them, not just the representative `CLAUDE_BEDROCK_APP`. An app whose recorded `wma:contact` is empty is skipped with a warning (create requires `--contact`) rather than aborting the whole update and stranding the other apps. Launchers written before `CLAUDE_BEDROCK_APP_PAIRS` existed fall back to the single baked `CLAUDE_BEDROCK_APP`/`_CONTACT`. It degrades gracefully with a clear message if `CLAUDE_BEDROCK_SETUP_DIR` no longer points at the scripts (e.g. the plugin moved); re-running the setup skill refreshes it.

A dangling `bedrock-default.sh` symlink (its target launcher was deleted/renamed) is repointed at the launcher being written rather than left broken, so bare `claude-bedrock` keeps working.

## Testing

No test suite exists. To verify changes, test against a real AWS account with `aws sso login` active. Check idempotency by running `create-bedrock-profiles.sh` twice -- the second run should show `SKIP` for all profiles.
