# Trust Boundary

## What the Worker Can Do

The worker Codex session runs inside the same Codex sandbox model as the main session, with these defaults:

- `read-only` filesystem access
- no network access
- ephemeral session (no persisted session files)
- `approval_policy = "never"` so the worker cannot ask the user for approval

`-Sandbox workspace-write` grants write access to the worktree for bounded `implement` tasks. `-AllowNetwork` is required before any network access is configured. `-SkipGitRepoCheck` is available only for an intentional non-Git target.

The no-network setting applies to tools executed in the Worker sandbox. The prompt and selected repository context are sent to the configured DeepSeek API because it is the model provider. Do not delegate secrets or data that policy forbids sending to that provider.

## Inherited Configuration and Explicit Overrides

The worker intentionally shares `CODEX_HOME` with the main Codex installation so Windows uses one sandbox state instead of competing account/setup state. The dedicated profile and CLI overrides prevent this shared storage from selecting the main model. The launcher strips `CODEX_PERMISSION_PROFILE`, `CODEX_THREAD_ID`, and `CODEX_INTERNAL_ORIGINATOR_OVERRIDE`, and passes Codex flags that disable:

- apps
- plugins and remote plugin sharing
- hooks
- memories
- multi-agent mode

The launcher also disables the tested Desktop MCP server names and enumerates conventional `[mcp_servers.<name>]` sections from user and project config, adding `enabled=false` at CLI priority for each. This prevents ordinary configured MCPs, plugins, memories, hooks, and the main permission profile from being active in the worker. Project-local instructions and policies remain a workspace concern. This is a practical execution boundary, not a cryptographic defense against deliberately unusual or future configuration sources.

## What the Main Agent Retains

Production writes, deployment, database or schema migration, credentials, destructive operations, and material security decisions are intentionally outside the worker's granted scope. The main agent authorizes and reviews them directly. If a delegated prompt requires those actions, the correct response is to stop and escalate, not to silently grant more permission.

## Key Handling

`Set-DeepSeekKey.ps1` prompts with `Read-Host -AsSecureString`, writes the key to `%LOCALAPPDATA%\CodexDeepSeekWorker\deepseek-api-key.txt`, and replaces inherited ACLs with a rule for the current user only. The launcher reads the file into memory and sets `DEEPSEEK_API_KEY` for the child process. The key is never in argv, stdin prompt text, final messages, artifacts, or logs.
An operator may set `CODEX_DEEPSEEK_KEY_FILE` to another restricted file. This override contains a path only; it does not put the key value into argv or the parent environment.

## Evidence Semantics

- Process exit, timeout, cleanup, and Git hard boundaries determine `runner_state`. Command evidence and changed-file attribution are Runner facts used for task acceptance, but an intermediate failed command does not alone rewrite the process outcome.
- `summary.txt` is a non-authoritative model summary. It may be plain text or Markdown; its presence or formatting does not decide success.
- Touching a pre-existing dirty file is recorded as an overlap warning for targeted review. Changed HEAD or index remains a hard boundary.
- `status.json` and `-ResultFile` contain the Runner-generated terminal envelope for success, failure, or timeout, so the main session can review facts without re-executing routine work.
- Optional `-ResultFile` and `-RunRoot` paths must be outside the coordinated worktree; otherwise Runner artifacts could become project changes.

## No Silent Fallback

The launcher rejects caller attempts to override the profile, model, provider, approval policy, disabled features, or MCP settings. The profile supplies the full provider definition, Responses wire format, and model catalog; CLI-priority arguments pin that profile, model ID, safety settings, and MCP disables before the `exec` subcommand. The runner supplies only task-local options such as workdir, sandbox, network, summary, and result paths. Wrapper failures are returned as failures; the runner does not retry automatically or silently switch to another model or provider.
