---
name: deepseek-worker
description: Explicitly delegate a bounded coding, analysis, review, or implementation task to the configured DeepSeek V4.1 Flash Codex CLI worker. Invoke only when the user names `$deepseek-worker` or explicitly requests the configured DeepSeek worker; never invoke it automatically merely to save quota.
---

# DeepSeek Worker

Resolve PowerShell 7 from `CODEX_DEEPSEEK_PWSH_PATH` or `C:\Program Files\PowerShell\7\pwsh.exe`, then invoke exactly `$env:LOCALAPPDATA\CodexDeepSeekWorker\codex-deepseek-exec.ps1` with `pwsh -NoLogo -NoProfile -File` and an explicit worktree. Never resolve the Runner from `PATH` or `%APPDATA%\npm`, use a `WindowsApps` alias or Windows PowerShell 5.1, or silently substitute another CLI, model, or provider. If launch fails before a run starts because the current tool context cannot access the Runner, PowerShell, run root, or managed key, stop and retry only through a user-approved host PowerShell 7 invocation; never repair ACLs or expose/copy the key.

- Give the Worker a task-local objective, allowed scope, material constraints, and acceptance checks. Preserve the user's intent and leave implementation choices to the Worker.
- Choose `audit`, `implement`, or `quota-first` from task risk. In `quota-first`, dispatch once and let the Worker own relevant discovery, edits, tests, correction, and self-review within scope.
- Keep the default 2700-second task timeout unless the user or a concrete task constraint requires otherwise. Launch asynchronously and poll the same process/session; an outer wait returning is not task completion. If the outer executor has a hard timeout, allow the task timeout plus cleanup time. Do not terminate or redispatch solely because the final summary is not yet available; inspect process state and recent run evidence when progress is unclear.
- Consume `status.json`, `summary.txt`, `changed-files.txt`, `diff-stat.txt`, and `commands.json` first. Process exit, timeout, cleanup, and Git hard boundaries determine `runner_state`; `completed` means execution completed, not that the task passed acceptance. For a write task, no expected changes or missing acceptance-command evidence is an unmet task, not success. `summary.txt` is non-authoritative plain text or Markdown. Treat overlap with pre-existing dirty files as a review warning, not automatic failure.
- Grant only required write and network access. Serialize writes in one worktree, use separate worktrees for parallel writes, leave staging/commits/pushes to the main Codex, and keep production, credentials, migrations, deployment, destructive actions, and material security decisions under its direct authorization. If the run fails or times out, stop and report its terminal envelope unless the user requests fallback.
