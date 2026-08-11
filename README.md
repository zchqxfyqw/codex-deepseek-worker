# Codex DeepSeek Worker

Codex DeepSeek Worker is a Windows PowerShell wrapper that lets a main Codex CLI instance delegate bounded, well-scoped tasks to a separate DeepSeek V4 Flash worker session. It is a community integration for [Codex CLI](https://github.com/openai/codex), not an OpenAI or DeepSeek product.

## 中文简介

`$deepseek-worker` 是一个显式调用的 Codex Skill：主 Codex 负责理解目标、划定权限和最终验收，DeepSeek V4 Flash 通过独立 Codex CLI 进程完成边界明确的检索、编码、测试和自审，再返回紧凑、可核验的证据包。它适合把大量常规执行交给成本较低的模型，同时保留 Codex 的工作区、沙箱、Git 归因和质量把关能力。

它不会修改 Codex Desktop 的默认模型，也不会静默回退到 OpenAI 或其他 Provider。默认只读、工具禁网、会话不持久化；写入和联网必须按任务明确授权。生产写入、数据库迁移、部署、凭据和重大安全决策仍由主 Codex 直接处理。

常用调用：

```text
$deepseek-worker 使用 quota-first 完整完成这个有边界的任务：自行检索、实现、测试、纠错和自审；主 Codex 只验收紧凑证据。范围：……；验收：……。
```

### v0.2.0-rc1 更新摘要

- 强化 `quota-first`：Worker 主做，Codex 按风险验收，避免重复探索。
- 增加版本、源码 SHA、结果契约和托管文件哈希，Doctor 可识别篡改与不兼容 CLI。
- 支持带备份的事务升级；保留 API Key、历史 runs 和独立 Worker。
- 严格校验最终结果、Prompt 清理、Git HEAD、脏文件重叠与命令证据，失败不误报成功。
- 记录耗时、缓存/非缓存 token、命令成败和变更摘要；不自动重试、换模型或降低权限。
- 同一 Git worktree 禁止并行写入；需要并行时使用独立 worktree。

完整中文说明见 [README.zh-CN.md](README.zh-CN.md)，全部版本记录见 [CHANGELOG.md](CHANGELOG.md)，固定安装包见 [v0.2.0-rc1 Release](../../releases/tag/v0.2.0-rc1)。

## Problem

Main Codex sessions are convenient for open-ended work, but every turn consumes model quota. A bounded task such as "read this module and list the risks", "implement this one change", or "run the offline tests and summarize" does not need to consume premium main-model context. This project runs those tasks in a separate, cheaper worker session and returns a compact, structured evidence bundle that the main session can verify instead of repeating the work.

The runner is intentionally not a general-purpose remote agent. It does not call DeepSeek automatically, does not change the main Codex default model, and does not widen permissions.

## Architecture

```text
main Codex CLI
  |
  +-- skill/deepseek-worker (instructions + JSON output schema)
  |
  +-- codex-deepseek-exec.ps1  (runner: coordination, artifacts, timeout, diff)
        |
        +-- codex-deepseek.ps1 (launcher: fixed profile/model/provider, key via env)
              |
              +-- codex exec (separate child Codex CLI process)
```

The install layout is:

```text
%LOCALAPPDATA%\CodexDeepSeekWorker\     runner scripts, key file, model catalog, run artifacts
$CODEX_HOME\skills\deepseek-worker\     SKILL.md, agents/openai.yaml, output schema
$CODEX_HOME\deepseek-worker.config.toml transparent reference profile (does not touch config.toml)
```

`CODEX_HOME` defaults to `%USERPROFILE%\.codex` when unset. `CODEX_DEEPSEEK_WORKER_ROOT` can override the install root for testing or custom layouts.
`CODEX_DEEPSEEK_KEY_FILE` can point to an existing restricted key file without placing the key value in an environment variable or command line.

## Trust Boundary

- The worker session defaults to `read-only`, no network, and `--ephemeral`. `implement` tasks opt into `workspace-write`; network stays off unless the caller explicitly passes `-AllowNetwork`.
- The worker shares `CODEX_HOME` so Codex reuses one Windows sandbox state, but runs through a dedicated `deepseek-worker` profile. The launcher strips thread and permission environment hooks; pins the provider, model, approvals, and disabled features at CLI priority; disables the Desktop-bundled MCP names; and discovers conventional `[mcp_servers.<name>]` declarations in user/project config so those servers are disabled for the child invocation.
- The runner records Git before/after state and attributes newly changed files separately from files that were already dirty.
- Production writes, deployments, database or schema migrations, credentials, destructive operations, and material security decisions remain under the main Codex agent's direct authorization and review.
- `worker_claim` and `claimed_verification` in the final bundle are model claims. `runner_state`, command evidence, and Git artifacts are runner facts.

"No network" controls tools started inside the Worker sandbox. The prompt and selected repository context are necessarily sent to the configured DeepSeek API; do not delegate secrets or data that policy forbids sending to that provider.

## Verified Compatibility

This repository is a community integration verified on:

- 2026-08-11
- Codex CLI `0.147.0`
- DeepSeek V4 Flash (`deepseek-v4-flash`) through the DeepSeek Responses-compatible endpoint

It is not an official OpenAI or DeepSeek integration, and OpenAI does not endorse this project. The profile and model catalog ship as templates, so behavior may change with future Codex CLI or DeepSeek API changes. See [docs/verification.md](docs/verification.md) for the offline checks.

DeepSeek's public changelog currently documents V4 Flash through its OpenAI Chat Completions and Anthropic-compatible interfaces. The `wire_api = "responses"` path in this project is therefore described as observed, tested Codex compatibility rather than a promise of general Responses API support. Re-run the release smoke test whenever Codex CLI or the DeepSeek API changes.

## Quick Start

Prerequisites:

- Windows with PowerShell 5.1 or PowerShell 7
- Git available on `PATH`
- Codex CLI `0.147.0` available as `codex` on `PATH` (or `CODEX_DEEPSEEK_CODEX_PATH` set to the `codex.cmd`/`codex.exe` you want to use)
- A DeepSeek API key

Install from a local clone:

```powershell
pwsh ./scripts/Install-DeepSeekWorker.ps1 -WhatIf
pwsh ./scripts/Install-DeepSeekWorker.ps1
pwsh "$env:LOCALAPPDATA\CodexDeepSeekWorker\Set-DeepSeekKey.ps1"
```

The installer does not call the network and never accepts a key on the command line. `Set-DeepSeekKey.ps1` prompts with a masked `Read-Host -AsSecureString` and writes a restricted-ACL key file.

For a reproducible install, download the versioned ZIP and `SHA256SUMS.txt` from the [v0.2.0-rc1 release](../../releases/tag/v0.2.0-rc1), verify the checksum, extract it, and run the same installer commands from the extracted directory. Avoid installing from a floating branch when reproducibility matters.

Check health and plan a run:

```powershell
pwsh "$env:LOCALAPPDATA\CodexDeepSeekWorker\codex-deepseek-exec.ps1" -Doctor
pwsh "$env:LOCALAPPDATA\CodexDeepSeekWorker\codex-deepseek-exec.ps1" -Workdir . -Prompt "Review src for error handling gaps." -Mode audit -DryRun
```

The skill is installed at `$CODEX_HOME\skills\deepseek-worker` and triggers only when explicitly named as `$deepseek-worker` or when the user explicitly asks for the configured DeepSeek worker.

## Typical Prompts

Audit:

```text
Use $deepseek-worker for this bounded review. Workdir: the current repo.
Audit src/worker.go for unhandled errors and unsafe path handling.
Return a compact findings list; do not edit files.
```

Implement:

```text
Use $deepseek-worker for this bounded change. Workdir: the current repo.
Implement the retry removal described in issue #42, keep changes within src/,
and run the offline unit tests for that package.
```

Quota-first:

```text
Use $deepseek-worker for this bounded task in quota-first mode. Workdir: the current repo.
Discover the relevant code, implement the small API change, run the offline tests,
and return the compact evidence bundle so the main session can review instead of redoing it.
```

## Modes

| Mode | Sandbox | Purpose |
| --- | --- | --- |
| `audit` | `read-only` (default) | Inspect, analyze, review. No file changes. |
| `implement` | `workspace-write` | Complete a bounded change and its relevant verification. |
| `quota-first` | caller-chosen | Own discovery, implementation, tests, and self-review; return a compact evidence bundle. |

Mode defaults from sandbox: `read-only` implies `audit`; `workspace-write` implies `implement` unless `-Mode` is given.

## Concurrency Boundary

Independent worktrees can run in parallel. The runner uses a per-Git-root named mutex plus a process registration keyed by PID and process start time. A `workspace-write` run excludes every other Worker run in the same worktree; a `read-only` run conflicts with an active `workspace-write` run. There is no same-worktree bypass. Use separate Git worktrees when parallel writes are intentional.

The registration registry lives under the system temp directory. `-Doctor` reports stale registrations without mutating them; a real run removes stale entries while holding the coordination guard.

## Quota Saving Rationale

In `quota-first`, the Worker owns discovery, implementation, relevant tests, correction, and self-review for the bounded task. The main session reads the compact bundle first and does not repeat evidence-backed exploration. Low-risk work normally needs only the compact result; medium-risk work adds targeted diff/test review; production, security, credentials, migrations, deployments, and destructive work remain under direct main-agent authorization and verification.

This saves premium-model context only when the main session does not redo the same work. It may intentionally spend more DeepSeek tokens to finish and self-correct within one run. Usage evidence separates cached input, uncached input, output, reasoning output, duration, and command counts so cost and speed can be evaluated independently rather than by raw token totals alone.

## Hard Limits and Failure Behavior

- Default timeout is 45 minutes (2700 seconds); on timeout the runner kills the child process tree and marks the run `timed_out`.
- There is no automatic retry.
- Failed checks may be diagnosed and rerun inside the same Worker session. A failed whole run stops: the skill does not automatically redispatch, switch provider, weaken permissions, or make the main agent redo the task.
- There is no silent model or provider fallback: the dedicated profile supplies the complete DeepSeek provider, Responses wire format, and model catalog, while the launcher pins the profile, model ID, approval policy, disabled feature settings, and discovered MCP disables at CLI priority. It rejects caller attempts to override those boundaries.
- The prompt is passed via stdin, is not persisted after the run, and never contains the API key.
- Key material is read from a file and injected through the `DEEPSEEK_API_KEY` environment variable, never through argv, prompts, artifacts, or logs.

## Limitations

- The runner scripts are Windows-focused (PowerShell process launch, `taskkill` process-tree termination, NTFS ACL handling).
- The public templates are verified against a specific Codex CLI and DeepSeek model version; later versions may change config or protocol behavior.
- The worker has no automatic quota budgeting; users control how much work is delegated.
- A worker result is a model claim; the main session should review the evidence before relying on it.
- The launcher disables conventional section-based MCP declarations, including the Desktop-bundled names tested here. A deliberately unusual or future configuration source is not a cryptographic isolation boundary; review `-DryRun`, `-Doctor`, and release smoke-test logs after changing Codex configuration or version.
- The installer does not add the install directory to `PATH`; call scripts by full path.

## Upgrade and Uninstall

Upgrade from a newer clone:

```powershell
pwsh ./scripts/Install-DeepSeekWorker.ps1 -Force
```

`-Force` performs a staged upgrade, records hashes in `installed-manifest.json`, and preserves the replaced managed files in a timestamped rollback backup under the install root. The key and run history are not part of the managed-file replacement set.

Uninstall:

```powershell
pwsh "$env:LOCALAPPDATA\CodexDeepSeekWorker\Uninstall-DeepSeekWorker.ps1" -WhatIf
pwsh "$env:LOCALAPPDATA\CodexDeepSeekWorker\Uninstall-DeepSeekWorker.ps1" -RemoveKeyFile -RemoveProfileConfig -RemoveRunArtifacts
```

By default the key file, per-profile config, and run artifacts are kept. Use the corresponding switches only when you intentionally want to delete them.

## Security

See [SECURITY.md](SECURITY.md) for reporting and the trust model. See [docs/trust-boundary.md](docs/trust-boundary.md) for a detailed boundary walkthrough.
For maintainers, [docs/publication-kit.md](docs/publication-kit.md) contains the proposed GitHub description, topics, release notes, announcement copy, and publication checklist.

## Repository Layout

```text
scripts/                 launcher, runner, installer, key config, uninstaller
config/                  per-profile TOML template and model catalog template
skill/deepseek-worker/   skill package (SKILL.md, agents/openai.yaml, schema)
docs/                    architecture, trust boundary, verification details
tests/                   offline static tests and CI entry point
.github/                 CI workflow, issue templates, PR template
```

## Disclaimer

This project is provided as-is, without warranty, and is not affiliated with, endorsed by, or sponsored by OpenAI or DeepSeek. Use at your own risk. Verify model availability, pricing, data handling, and API terms before production use.
