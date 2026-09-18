# Architecture

## Components

`codex-deepseek-exec.ps1` is the runner. It validates the workdir, resolves physical paths, checks Git state, acquires a per-worktree coordination lock, starts a child Codex CLI process, waits with a hard timeout, and writes run artifacts plus a Runner-generated terminal envelope.

`codex-deepseek.ps1` is the launcher invoked by the runner's child process. It selects the dedicated `deepseek-worker` profile and pins `deepseek-flash`, the provider, approval policy, disabled features, telemetry settings, and MCP disables at CLI priority. It reads the API key from a file and exposes it to the child only through `DEEPSEEK_API_KEY`.

The skill at `skill/deepseek-worker` gives the main Codex agent a concise invocation and review contract. The installed model catalog and full provider definition live in `$CODEX_HOME\deepseek-worker.config.toml`; the launcher pins the profile and all critical runtime choices so project configuration cannot silently select another model or provider.

## Run Flow

1. The caller invokes the runner with a workdir, prompt, mode, sandbox, and optional result file.
2. The runner resolves the physical workdir and Git root, and snapshots Git state before the run.
3. It acquires a named mutex for the coordination root and registers the parent Runner using PID plus process start time; that registration remains live through terminal evidence collection.
4. It writes the prompt to a temporary stdin file and launches the child Codex CLI through the launcher.
5. The child writes a concise natural-language final message to `summary.txt` and emits JSONL events. The summary may be plain text or Markdown and does not determine success.
6. On completion, timeout, or failure, the runner cleans up temporary prompt/argument files, snapshots Git state again, and writes bounded change/command evidence.
7. Runner-observed process exit, timeout, cleanup, and Git hard boundaries determine the terminal state. Command evidence supports task acceptance without independently rewriting that state. After evidence collection it removes its coordination registration, then atomically writes the same terminal envelope to `status.json` and, when requested, to an external `-ResultFile`.

## Run Artifacts

Artifacts are external to the worktree, under `%LOCALAPPDATA%\CodexDeepSeekWorker\runs\<run-id>\`:

| File | Content |
| --- | --- |
| `status.json` | Authoritative Runner terminal envelope: state, process/Git facts, evidence completeness, warnings, and artifact paths |
| `summary.txt` | Non-authoritative Worker summary in plain text or Markdown |
| `events.jsonl` | Diagnostic Codex CLI JSONL event stream; not part of the default review set |
| `commands.json` | Bounded command evidence extracted from events |
| `changed-files.txt` | Files attributed to or observed during this run |
| `diff-stat.txt` | Compact diff summary for the observed files |
| `stderr.log` | Diagnostic child stderr |

The temporary prompt and child-argument files are deleted after the run. The prompt body is not written into status or diagnostic artifacts. A malformed, fenced, or missing summary can produce a warning but cannot turn an otherwise successful process into a failed run. Likewise, overlap with a pre-existing dirty file is recorded for targeted review rather than treated as an automatic execution failure; changed HEAD or index remains a hard boundary.

## Coordination

The coordination root is the Git root when present, otherwise the resolved workdir when `-SkipGitRepoCheck` is used. A SHA-256 prefix of the normalized root names a named mutex and the registration files. Registration files are keyed by PID plus process start time, so recycled-PID entries are detected. Doctor reports stale entries without mutation; a real run removes them while holding the guard. Writes to one worktree are serialized, with no bypass; parallel writers use separate Git worktrees.

## Process Isolation

The runner resolves and probes a non-Store PowerShell 7 runtime, prepends its directory to the child `PATH`, and starts a hidden PowerShell 7 process that invokes the launcher with `codex exec`. The launcher removes the inherited permission profile, thread ID, and originator override; keeps the shared `CODEX_HOME` for one Windows sandbox state; disables apps/plugins/hooks/memories/multi-agent features at CLI priority; disables the tested Desktop MCP names; scans conventional user/project MCP sections and adds a CLI disable for each; and injects the key only as an environment variable. No key value appears on any command line.
