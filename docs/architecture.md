# Architecture

## Components

`codex-deepseek-exec.ps1` is the runner. It validates the workdir, resolves physical paths, checks Git state, acquires a per-worktree coordination lock, starts a child Codex CLI process, waits with a hard timeout, and writes run artifacts plus a compact final result.

`codex-deepseek.ps1` is the launcher invoked by the runner's child process. It selects the dedicated `deepseek-worker` profile and pins `deepseek-v4-flash`, the provider, approval policy, disabled features, telemetry settings, and MCP disables at CLI priority. It reads the API key from a file and exposes it to the child only through `DEEPSEEK_API_KEY`.

The skill at `skill/deepseek-worker` gives the main Codex agent the invocation contract and the output schema. The installed model catalog and full provider definition live in `$CODEX_HOME\deepseek-worker.config.toml`; the launcher pins the profile and all critical runtime choices so project configuration cannot silently select another model or provider.

## Run Flow

1. The caller invokes the runner with a workdir, prompt, mode, sandbox, and optional result file.
2. The runner resolves the physical workdir and Git root, and snapshots Git state before the run.
3. It acquires a named mutex for the coordination root and registers a live worker using PID plus process start time.
4. It writes the prompt to a temporary stdin file, launches the child Codex CLI through the launcher, and updates the registration to the child process identity.
5. The child runs with the output schema, writes its final JSON message, and emits JSONL events.
6. On completion, timeout, or failure, the runner cleans up the prompt file and registration, snapshots Git state again, and writes diff/command evidence.
7. It validates the final JSON contract, copies the final message to `-ResultFile` only for a valid completed result, and returns a compact JSON bundle.

## Run Artifacts

Artifacts are external to the worktree, under `%LOCALAPPDATA%\CodexDeepSeekWorker\runs\<run-id>\`:

| File | Content |
| --- | --- |
| `invocation.json` | Run metadata, including prompt length and SHA-256, not the prompt body |
| `status.json` | Runner state, process identity, Git before/after, changed files |
| `final.json` | The worker's structured final message |
| `events.jsonl` | Codex CLI JSONL events |
| `commands.json` | Extracted command evidence from events |
| `before-status.txt` / `after-status.txt` | Git status snapshots |
| `changed-files.txt` | Changed file list |
| `diff-stat.txt` / `diff.patch` | Diff summary and patch |
| `stderr.log` | Child stderr |

The prompt stdin file is deleted after the run. The prompt body is not written into invocation or status artifacts.

## Coordination

The coordination root is the Git root when present, otherwise the resolved workdir when `-SkipGitRepoCheck` is used. A SHA-256 prefix of the normalized root names a named mutex and the registration files. Registration files are keyed by PID plus process start time, so recycled-PID entries are detected. Doctor reports stale entries without mutation; a real run removes them while holding the guard. Writes to one worktree are serialized, with no bypass; parallel writers use separate Git worktrees.

## Process Isolation

The runner resolves and probes a non-Store PowerShell 7 runtime, prepends its directory to the child `PATH`, and starts a hidden PowerShell 7 process that invokes the launcher with `codex exec`. The launcher removes the inherited permission profile, thread ID, and originator override; keeps the shared `CODEX_HOME` for one Windows sandbox state; disables apps/plugins/hooks/memories/multi-agent features at CLI priority; disables the tested Desktop MCP names; scans conventional user/project MCP sections and adds a CLI disable for each; and injects the key only as an environment variable. No key value appears on any command line.
