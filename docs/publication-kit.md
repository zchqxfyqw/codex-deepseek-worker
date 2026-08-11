# Publication Kit

This file prepares the repository for maintainer review. It does not authorize creating a remote repository, pushing commits, or publishing a release.

## Proposed GitHub Repository

- Owner: `<github-owner>`
- Name: `codex-deepseek-worker`
- Visibility: public
- Default branch: `main`
- License: MIT
- Current release tag: `v0.2.3-rc1`

Proposed description:

> A Windows PowerShell runner and explicit Codex skill for delegating bounded tasks to DeepSeek V4 Flash with compact evidence, sandbox controls, Git attribution, and no silent model fallback.

Proposed topics:

`codex`, `deepseek`, `powershell`, `windows`, `coding-agent`, `ai-agents`, `llm`, `developer-tools`

## Positioning

This is a small orchestration and evidence layer, not a replacement for Codex and not a general multi-model gateway. Its useful distinction is the combination of:

- explicit Skill invocation instead of automatic delegation;
- a pinned DeepSeek worker profile with no silent fallback;
- conservative read-only, no-network, ephemeral defaults;
- compact results with runner facts separated from model claims;
- dirty-worktree attribution and same-worktree coordination;
- local, restricted key handling with no key in argv or artifacts.

Do not market the project as official, perfectly isolated, universally compatible, or guaranteed to save a fixed percentage of quota.

## Release Title and Notes

Title:

> Codex DeepSeek Worker v0.2.3-rc1 — Windows reliability hardening candidate

Release notes:

> This candidate makes GitHub the reproducible source for the local Worker: versioned contracts and hashes, transactional upgrades with rollback backups, strict Doctor checks, final-schema enforcement, bounded token/command evidence, and a concise quota-first collaboration policy. It keeps the DeepSeek-only product boundary and does not bundle OpenCode Go.
>
> Verified locally on Windows with Codex CLI 0.147.0 and DeepSeek V4 Flash on 2026-08-11. This is a community integration, not an OpenAI or DeepSeek product. Review the trust boundary and run the isolated smoke tests before relying on it.

## 中文介绍稿

### 标题

> 用一个 Skill 调度另一套 Codex CLI：把 DeepSeek V4 Flash 变成可审计的执行 Worker

### 简介

这个项目源于一个很实际的问题：主 Codex 适合规划、判断和最终验收，但大量边界清晰的读取、修改与测试工作未必都需要消耗主模型配额。

Codex DeepSeek Worker 将 DeepSeek V4 Flash 配置成独立 Codex CLI Worker，通过显式 `$deepseek-worker` Skill 调用。Worker 在独立进程中完成限定任务，Runner 只向主会话返回紧凑结果，并保留命令证据、Git 前后状态、变更文件和风险说明。

它没有尝试做一个庞大的多模型平台，而是重点解决几个具体问题：默认只读和断网、模型与 Provider 不静默回退、API Key 不进入命令行和结果包、脏工作区变更不被错误归因、同一工作树写任务受到协调、超时后终止整个子进程树。

项目面向 Windows PowerShell，首个候选版在 Codex CLI 0.147.0 与 DeepSeek V4 Flash 上完成验证。它是社区集成，不代表 OpenAI 或 DeepSeek 官方支持；涉及生产写入、数据库、部署、凭据和破坏性操作时，仍应由主代理直接授权和复核。

### 推荐示例

```text
使用 $deepseek-worker，以 quota-first 模式完整完成这个有边界的任务：
自行调查、修改、运行相关测试并自检；主 Codex 只审查紧凑证据和高风险边界，
不要重复已有命令证据支持的工作。
```

## English Announcement

> Codex DeepSeek Worker is a Windows PowerShell runner plus an explicit Codex skill for delegating bounded tasks to a DeepSeek V4 Flash Codex CLI session. It returns compact evidence instead of raw event streams, separates runner facts from model claims, preserves dirty-worktree attribution, validates versioned result contracts, and performs backed-up transactional upgrades. This is an unofficial community integration.

## Maintainer Review Checklist

- [ ] Confirm the repository owner and final name.
- [ ] Review every tracked file and the initial commit diff.
- [ ] Run `pwsh ./tests/run-tests.ps1` successfully.
- [ ] Run the Skill validator successfully.
- [ ] Confirm no username, absolute personal path, API key, run artifact, or session data is tracked.
- [ ] Confirm the pinned `actions/checkout` SHA against the upstream tag.
- [ ] Perform one real read-only smoke test in an isolated temporary Git repository.
- [ ] Perform one real workspace-write smoke test in the same disposable repository.
- [ ] Confirm completed runs retain no `prompt.stdin` and no key appears in artifacts.
- [ ] Review MIT license, security policy, contribution guide, issue templates, and disclaimer.
- [ ] Create the public repository only after explicit approval.
- [ ] Push `main`, confirm private vulnerability reporting, and create `v0.2.3-rc1` only after explicit approval.

## Planned Publish Commands

These commands are a review preview only. Do not run them until publication is explicitly approved.

```powershell
gh repo create <github-owner>/codex-deepseek-worker --public --source . --remote origin --description "A Windows PowerShell runner and explicit Codex skill for delegating bounded tasks to DeepSeek V4 Flash with compact evidence and sandbox controls."
git push -u origin main
gh release create v0.2.3-rc1 --prerelease --title "Codex DeepSeek Worker v0.2.3-rc1 — Windows reliability hardening candidate" --notes-file RELEASE_NOTES.md
```

Before publication, either create `RELEASE_NOTES.md` from the reviewed release text above or pass the text directly to `gh release create`.
