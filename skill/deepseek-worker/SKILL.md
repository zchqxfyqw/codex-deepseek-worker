---
name: deepseek-worker
description: Explicitly delegate a bounded coding, analysis, review, or implementation task to the configured DeepSeek V4 Flash Codex CLI worker. Invoke only when the user names `$deepseek-worker` or explicitly requests the configured DeepSeek worker; never invoke it automatically merely to save quota.
---

# DeepSeek Worker

Invoke `& (Join-Path $env:LOCALAPPDATA 'CodexDeepSeekWorker\codex-deepseek-exec.ps1')` with an explicit worktree. If `CODEX_DEEPSEEK_WORKER_ROOT` is set, use that install root instead. Never silently substitute another CLI, model, or provider.

- Give the Worker a task-local objective, allowed scope, material constraints, and acceptance checks. Preserve the user's intent and leave implementation choices to the Worker.
- Choose `audit`, `implement`, or `quota-first` from the request and task risk. In `quota-first`, let the Worker perform discovery, edits, tests, and self-review; inspect its deterministic result bundle and do not repeat verified work without a concrete risk reason.
- Grant only the required write, network, non-Git, and concurrency capabilities. Parallelize independent worktrees freely. Permit same-worktree concurrency only for intentionally isolated files, outputs, and shared resources.
- Preserve unrelated work. Keep production writes, credentials, data or schema migration, deployment, destructive actions, and material security decisions under the main Codex's direct authorization and verification.
- Treat `runner_state`, command evidence, and Git artifacts as runner facts; treat `worker_claim` and `claimed_verification` as model claims. Report wrapper failures as-is without weakening permissions or silently falling back.
