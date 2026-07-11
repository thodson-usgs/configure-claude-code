---
name: setup
description: Set up Claude Code with tagged AWS Bedrock inference profiles for cost attribution. Creates profiles if needed, then configures ~/.claude/settings.json.
argument-hint: "[--project-id ID] [--app-id ID] [--contact EMAIL] [--region REGION]"
disable-model-invocation: true
allowed-tools: Bash(aws *) Bash(bash *) Bash(command -v *) Bash(jq *) Read Write
---

## Set Up AWS Bedrock Inference Profiles

You are helping the user set up Claude Code with tagged AWS Bedrock inference profiles.

**Arguments:** `$ARGUMENTS` — optional flags: `--project-id ID`, `--app-id ID`, `--contact EMAIL`, `--region REGION`

Follow these steps in order. If any step fails, explain the problem clearly and stop.

### Step 1 — Preflight checks

Check that `aws` and `jq` are installed using `command -v`. If either is missing, tell the user how to install it (brew on macOS, apt on Ubuntu, winget on Windows) and stop.

Then run `aws sts get-caller-identity` to confirm an active AWS session. If it fails, tell the user to run `aws sso login` and stop.

### Step 2 — Gather project ID

Parse `$ARGUMENTS` for `--project-id`. If not provided, ask the user:

> What is your project ID? This is the `wma:project_id` tag used for cost attribution (e.g., `uncertainty_ts`).

Also parse `--region` from arguments. Default to `us-west-2` if not provided.

### Step 3 — Discover existing profiles

Run:

```bash
aws bedrock list-inference-profiles --type-equals APPLICATION --region REGION --output json
```

Filter the results for profiles whose `inferenceProfileName` starts with the project ID. Report how many were found.

### Step 4 — Create or update profiles

Always run the create script — it is idempotent (it `SKIP`s profiles that already exist and only creates missing ones), so running it also picks up any models added since a previous run. Tell the user whether you found existing profiles (Step 3) and that you'll now create any that are missing.

Parse `--app-id` and `--contact` from `$ARGUMENTS`. If profiles were found in Step 3, reuse the app-id/contact from their names/tags where possible; otherwise, for any not provided, ask the user:

- **app-id**: "What application ID should be used? (`wma:application_id` tag, e.g., `claude`)"
- **contact**: "What contact email should be used? (`wma:contact` tag, e.g., `user@usgs.gov`)"

Then run the create script:

```bash
bash "${CLAUDE_SKILL_DIR}/create-bedrock-profiles.sh" \
    --project-id PROJECT_ID \
    --app-id APP_ID \
    --contact CONTACT \
    --region REGION
```

Report the results (`OK` = created, `SKIP` = already existed). A model the account can't access is skipped with a warning rather than aborting the run. If the whole script fails, show the error and stop.

### Step 5 — Choose how to apply the config

Ask the user which they want (default to **launcher** if they mention using an Anthropic subscription/Pro account or any non-Bedrock backend):

> Should Bedrock be the **global default** for every Claude Code session, or a **switchable launcher** you opt into per-run? Choose *launcher* if you also sign in with an Anthropic subscription — it keeps that as your default and adds a `claude-bedrock` command for Bedrock.

- **Global default** → run with no `--output` flag (writes `~/.claude/settings.json`).
- **Switchable launcher** → run with `--output launcher` (writes `~/.claude/bedrock-PROJECT_ID.sh` and prints a shell wrapper; leaves `settings.json` untouched).

Run the configure script. Pass `--yes` so the settings-mode overwrite prompt (which would hit EOF non-interactively and abort) is skipped — you have already surfaced the choice to the user. Pass `--app-id` too if the user is scoping to one application:

```bash
bash "${CLAUDE_SKILL_DIR}/configure-claude-cli.sh" \
    --project-id PROJECT_ID \
    --region REGION \
    --yes \
    [--app-id APP_ID] \
    [--output launcher]
```

Report what was written.

### Step 6 — Summary

Tell the user:
- Which profiles are now configured
- That the `/model` picker will show friendly names like "Opus 4.8 (project_id)"
- **Global-default mode:** they need to **restart Claude Code** for changes to take effect
- **Launcher mode:** add the printed `claude-bedrock` wrapper to their shell rc, then use `claude` for their default backend and `claude-bedrock` for Bedrock (after `aws sso login`)
