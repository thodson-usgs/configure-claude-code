# bedrock-profiles

A [Claude Code plugin](https://code.claude.com/docs/en/plugins) that sets up tagged AWS Bedrock inference profiles for cost attribution.

## Prerequisites

- [Claude Code](https://claude.ai/install.sh)
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) with a valid SSO session
- [jq](https://jqlang.github.io/jq/download/)

Install them per platform:

**Ubuntu / Debian**

```bash
curl -fsSL https://claude.ai/install.sh | bash        # Claude Code
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" \
  && unzip -qo awscliv2.zip && sudo ./aws/install --update && rm -rf awscliv2.zip aws
sudo apt-get install -y jq
```

**macOS (Homebrew)**

```bash
curl -fsSL https://claude.ai/install.sh | bash        # Claude Code
brew install awscli jq
```

**Windows**

```powershell
winget install Anthropic.ClaudeCode Amazon.AWSCLI jqlang.jq
```

## Install

```
/plugin marketplace add thodson-usgs/configure-claude-code
/plugin install bedrock-profiles
```

## Usage

```
/bedrock-profiles:setup
```

The skill walks you through the full setup interactively: checks prerequisites, prompts for your project tags, creates Bedrock inference profiles if needed, and writes the configuration. It asks whether Bedrock should be your global default or a switchable launcher (see below), then tells you how to activate it.

You can also pass arguments directly:

```
/bedrock-profiles:setup --project-id my_project --app-id claude --contact user@example.com
```

## Basic usage

After setup, start Claude Code as usual — which backend a session uses depends on how you configured it:

```bash
claude                         # your default backend (Anthropic subscription, unless Bedrock is the global default)
claude-bedrock                 # Bedrock, default project — launcher mode only (run `aws sso login` first)
claude-bedrock --project foo   # Bedrock, a specific project's tagged profiles
```

- **Global-default mode** (writes `settings.json`): every `claude` session uses Bedrock — restart Claude Code after setup.
- **Launcher mode** (writes a `claude-bedrock` wrapper): plain `claude` stays on your subscription; `claude-bedrock` opts into Bedrock per launch.

Either way, pick a model with `/model` — tagged profiles show up with friendly names like "Opus 4.8 (my_project)". See [Using Bedrock alongside an Anthropic subscription](#using-bedrock-alongside-an-anthropic-subscription) below for switching backends and projects on the fly.

## Using Bedrock alongside an Anthropic subscription

A Claude Code session uses **one** backend: when `CLAUDE_CODE_USE_BEDROCK=1` is set it goes to Bedrock, otherwise it falls back to your Anthropic subscription login (`/login`). The two auth methods don't collide (Bedrock uses your AWS credentials; the subscription uses OAuth).

By default the setup writes Bedrock into `~/.claude/settings.json`, making it the global default for every session. To instead keep your subscription as the default and opt into Bedrock per launch, use **launcher mode**:

```bash
bash skills/setup/configure-claude-cli.sh --project-id my_project --output launcher
```

This writes `~/.claude/bedrock-my_project.sh` (the Bedrock env vars) and prints a `claude-bedrock` shell wrapper to add to your `~/.zshrc` or `~/.bashrc` (add it once). Then:

- `claude` → your Anthropic subscription (settings.json is left untouched)
- `claude-bedrock` → tagged Bedrock profiles (run `aws sso login` first)

The subshell in the wrapper keeps the env vars out of your normal shell, so plain `claude` is unaffected (shell environment variables take precedence over `settings.json`). Three things the launcher sets up for you:

- **`AWS_PROFILE` bridge.** Claude Code's AWS SDK reads `AWS_PROFILE` (not the `AWS_DEFAULT_PROFILE` the AWS CLI often uses); without it, Bedrock calls hang ~60s on the default credential chain and fail. The launcher bridges whatever profile your shell resolves — override with `--aws-profile NAME` or by exporting `AWS_PROFILE` first.
- **Isolated config** (`CLAUDE_CONFIG_DIR=~/.claude-bedrock`). This keeps a `/model` pick in a Bedrock session from rewriting your subscription's default model — otherwise selecting a Bedrock-only model (whose id is invalid on the Anthropic API) would break plain `claude`. Bedrock uses AWS auth, so this needs no separate `/login`. Pass `--shared-config` to opt out and share `~/.claude` instead.
- **A cost-attribution badge** in the statusline: green ⬢ = a project-tagged profile (safe to bill), yellow ⚠ = on Bedrock but an untagged model, dim ○ = your subscription. It never claims "subscription" while a session is really on Bedrock.

> **Preview/promo models (e.g. Fable):** these are often blocked by AWS org policies on Bedrock — an SCP may deny creating a tagged profile and/or your identity policy may deny invoking the raw system profile — so they can be unusable on Bedrock regardless of tagging. They still work on your Anthropic subscription (plain `claude`).

### Switching project / application at launch

Each launcher file is named `~/.claude/bedrock-<project>[-<app>].sh`. The wrapper is the **same every run** (add it once) and dispatches to those files by flag, so one wrapper covers every project/application you set up:

```bash
claude-bedrock                          # default project (~/.claude/bedrock-default.sh)
claude-bedrock --project other_proj     # sources ~/.claude/bedrock-other_proj.sh
claude-bedrock --application notebooks  # sources ~/.claude/bedrock-<project>-notebooks.sh
claude-bedrock --update-profiles        # recreate tagged profiles for the latest models + rewire
```

Bare `claude-bedrock` follows `~/.claude/bedrock-default.sh`, a symlink configure points at your first-configured project (so there's always a billable default). Repoint it any time with `ln -sf bedrock-<slug>.sh ~/.claude/bedrock-default.sh`.

**Updating to newer models:** bump the `MODELS` list in `create-bedrock-profiles.sh` (or just pull a newer plugin version), then run `claude-bedrock --update-profiles`. It recreates the tagged profiles for the current models and rewires the launcher; `configure` auto-prefers the newest version per tier, so a leftover old-version profile is ignored rather than blocking the upgrade (delete it separately if you want it gone).

Put `--project`/`--application` **before** any regular `claude` arguments. Each override needs its own launcher first — generate it by re-running configure with the matching `--project-id`/`--app-id`:

```bash
bash skills/setup/configure-claude-cli.sh --project-id other_proj --app-id notebooks --output launcher
```

Cost-attribution rides on *which inference profile ARN* the session uses — the tags on that profile resource (`wma:project_id` / `wma:application_id` / `wma:contact`) flow to Cost Explorer / CUR, aggregated (Bedrock has no per-request billing tag). So `--project`/`--application` switch attribution by selecting among **pre-created, differently-tagged** profiles; each combination needs its profiles created first. `wma:contact` is a **fixed owner/POC tag** recorded when the profile is created — not a launch-time switch (it isn't part of the profile name). If you ever need per-person usage, that comes from each user's AWS/IAM caller identity in Cost Explorer, not from the profile tag.

## Advanced: standalone scripts

The same scripts the skill uses can be run directly for automation or CI:

```bash
aws sso login

# 1. Create inference profiles (once per project)
bash skills/setup/create-bedrock-profiles.sh \
    --project-id my_project --app-id claude --contact user@example.com

# 2. Configure Claude Code (each user)
bash skills/setup/configure-claude-cli.sh \
    --project-id my_project
#   add --output launcher to opt into Bedrock per-launch instead of globally
```

Both scripts accept `--region` (default: `us-west-2`). Run either with `--help` for full usage.

## Updating models

Edit the `MODELS` array at the top of `skills/setup/create-bedrock-profiles.sh`, then re-run the skill or both scripts.
