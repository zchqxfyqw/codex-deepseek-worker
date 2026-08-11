# Codex DeepSeek Worker

Codex DeepSeek Worker 是一个 Windows PowerShell 封装，让主 Codex 会话可以把边界清晰的子任务委托给独立的 DeepSeek V4 Flash 会话执行，并把结果整理成紧凑的结构化证据包。这是社区集成，不是 OpenAI 或 DeepSeek 的官方产品。

## 解决的问题

主 Codex 会话适合开放式工作，但每个回合都会消耗配额。像“审查某个模块”“实现一处小改动”“跑一遍离线测试并总结”这类有边界的任务，可以在独立的低成本会话中完成。本工具把这些任务交给 DeepSeek Worker，返回可复核的变更与验证摘要，避免主会话重复劳动。

本工具不会自动调用 DeepSeek，不修改主 Codex 的默认模型，也不会自动扩大权限。

## 信任边界

Worker 默认 `read-only`、无网络、`--ephemeral`。它与主 Codex 共享 `CODEX_HOME` 以复用同一套 Windows 沙箱状态，但使用独立的 `deepseek-worker` profile；Launcher 清除线程和权限环境钩子，在 CLI 最高优先级固定模型、provider 与权限，关闭插件、Hooks、记忆和多代理，并禁用 Desktop 内置及用户/项目配置中按常规 `[mcp_servers.<name>]` 声明的 MCP。`implement` 才允许写入工作树，网络仍需显式开启。生产写入、部署、数据库迁移、凭据、破坏性操作和重大安全决策仍由主代理直接授权和复核。

Runner 记录 Git 前后状态，把本次新增变更与运行前已存在的脏文件分开归因。`worker_claim` 和 `claimed_verification` 是模型声明；`runner_state`、命令证据和 Git 产物是运行器事实。

“无网络”约束的是 Worker 沙箱内启动的工具。任务 Prompt 与所选代码上下文仍会发送给配置的 DeepSeek API；不得委托策略禁止发送给该服务商的秘密或敏感数据。

## 兼容性说明

本仓库是社区集成，验证环境为 2026-08-11 的 Codex CLI 0.147.0 与 DeepSeek V4 Flash（Responses 兼容端点）。不声称官方背书，主 Codex 默认模型不会被修改。具体行为可能随版本变化。

DeepSeek 当前公开更新日志明确写到的是 OpenAI Chat Completions 与 Anthropic 兼容接口。因此，本项目的 `wire_api = "responses"` 应理解为经过本项目实测的 Codex 兼容路径，不应扩大解释为 DeepSeek 对通用 Responses API 的长期承诺。Codex CLI 或 DeepSeek API 更新后，需要重新做真实冒烟测试。

## 快速开始

前置条件：Windows、PowerShell、Git、`PATH` 中可用的 Codex CLI 0.147.0（或用 `CODEX_DEEPSEEK_CODEX_PATH` 指定）、DeepSeek API Key。

```powershell
pwsh ./scripts/Install-DeepSeekWorker.ps1 -WhatIf
pwsh ./scripts/Install-DeepSeekWorker.ps1
pwsh "$env:LOCALAPPDATA\CodexDeepSeekWorker\Set-DeepSeekKey.ps1"
```

安装器不联网、不接受明文 Key 参数。密钥脚本用 `Read-Host -AsSecureString` 掩码输入，并写入受限 ACL 文件。随后可运行 `-Doctor` 和 `-DryRun` 做离线检查。

需要可复现安装时，请从 [v0.2.0-rc1 Release](../../releases/tag/v0.2.0-rc1) 下载版本固定的 ZIP 与 `SHA256SUMS.txt`，校验后解压并运行同一安装器；不要依赖随时变化的分支。

如需使用企业托管或自定义位置的受限密钥文件，可设置 `CODEX_DEEPSEEK_KEY_FILE`；该变量只包含文件路径，不包含密钥值。

## 三种模式

`audit` 只读审查；`implement` 在 `workspace-write` 中完成有边界改动；`quota-first` 由 Worker 自主完成发现、实现、测试和自检，返回紧凑证据包供主会话复核。默认 `read-only` 对应 `audit`，`workspace-write` 对应 `implement`。

## 并发与限额

独立工作树可并行；同一工作树由命名互斥锁和“PID+进程启动时间”注册表约束。写模式与同工作树所有 Worker 互斥，只读模式与写模式冲突，且不提供同工作树绕过开关；需要并行写时使用独立 Git worktree。`-Doctor` 只报告过期注册，不修改；真实运行在协调锁内清理。45 分钟硬超时后终止整个子进程树，不自动重试，也不静默切换模型或 provider。

`quota-first` 下，Worker 对有边界任务负责检索、实现、相关测试、纠错和自审；主会话先读紧凑结果，不重复已有确定性证据支持的探索。低风险通常只读紧凑包，中风险补看针对性的 diff/测试，高风险生产、凭据、安全、迁移、部署和破坏性操作仍由主代理直接授权与验证。整个 Worker 运行失败后停止，不自动重派、换模型、降权限或由主代理重做；同一运行内可以修正并重跑失败检查。

这会主动多用一些 DeepSeek token 来换取完整性，但减少高价主模型的重复上下文。Runner 分别记录缓存输入、非缓存输入、输出、推理输出、时长和命令数量，避免把“总 token 更多”误判成“成本一定更高”。

## 限制

脚本面向 Windows；公开模板只在特定 Codex CLI 与模型版本上验证过；Worker 结果仍是模型声明，使用前应复核；MCP 禁用覆盖常规 section 声明和当前 Desktop 内置名称，但不是针对恶意或未来未知配置源的密码学隔离；安装器不会把安装目录加入 `PATH`。

## 升级与卸载

升级：在仓库内运行 `pwsh ./scripts/Install-DeepSeekWorker.ps1 -Force`。安装器先暂存和校验，再替换托管文件，并在安装目录的 `backups` 下保留带时间戳的回滚备份；Key 与历史运行证据不在替换范围内。

卸载：运行 `"$env:LOCALAPPDATA\CodexDeepSeekWorker\Uninstall-DeepSeekWorker.ps1"`。默认保留 Key 文件、profile 配置和运行证据；只有明确需要清理时，才添加 `-RemoveKeyFile -RemoveProfileConfig -RemoveRunArtifacts`。

## 免责声明

本项目按现状提供，不附带任何担保，与 OpenAI 和 DeepSeek 无隶属或背书关系。生产使用前请自行确认模型可用性、价格、数据处理与 API 条款。

维护者可在 [docs/publication-kit.md](docs/publication-kit.md) 查看拟发布的 GitHub 简介、topics、Release 文案、中文介绍与发布检查清单。
