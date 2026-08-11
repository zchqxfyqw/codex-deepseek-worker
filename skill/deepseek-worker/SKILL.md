---
name: deepseek-worker
description: Explicitly delegate a bounded coding, analysis, review, or implementation task to the configured DeepSeek V4 Flash Codex CLI worker. Invoke only when the user names `$deepseek-worker` or explicitly requests the configured DeepSeek worker; never invoke it automatically merely to save quota.
---

# DeepSeek Worker

Resolve PowerShell 7 from `CODEX_DEEPSEEK_PWSH_PATH` or `C:\Program Files\PowerShell\7\pwsh.exe`, then invoke the installed `codex-deepseek-exec.ps1` with `pwsh -NoLogo -NoProfile -File` and an explicit worktree. Never use a `WindowsApps` alias, Windows PowerShell 5.1, or a silent CLI/model/provider substitute.

- Give the Worker a task-local objective, allowed scope, material constraints, and acceptance checks. Preserve the user's intent and leave implementation choices to the Worker.
- Choose `audit`, `implement`, or `quota-first` from task risk. In `quota-first`, dispatch once, keep the default 2700-second budget, and let the Worker own relevant discovery, edits, tests, correction, and self-review within scope.
- Consume the compact result first. Do not repeat work backed by deterministic evidence unless evidence is missing, contradictory, out of scope, overlaps prior dirty work, or is high risk. Read full events or patches only for those exceptions.
- Let failed checks be diagnosed and rerun inside the same Worker run. If the run fails or times out, stop and report the compact result; when `unverified_partial_changes=true`, preserve the workspace for an explicitly authorized review. Do not redispatch, take over locally, weaken permissions, or switch provider unless the user requests fallback.
- Grant only required write and network access. Serialize writes in one worktree and use separate worktrees for parallel writes. Keep production writes, credentials, migrations, deployment, destructive actions, and material security decisions under the main Codex's direct authorization and verification.
- Treat `runner_state`, command/Git evidence, and version metadata as runner facts; treat `worker_claim` and `claimed_verification` as model claims.
