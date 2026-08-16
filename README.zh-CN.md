# Codex DeepSeek Worker

Codex DeepSeek Worker 是一个 Windows PowerShell 封装，让主 Codex 会话可以把边界清晰的子任务委托给独立的 DeepSeek V4 Flash 会话执行，并返回紧凑的 Runner 证据与模型摘要。这是社区集成，不是 OpenAI 或 DeepSeek 的官方产品。

## 解决的问题

主 Codex 会话适合开放式工作，但每个回合都会消耗配额。像“审查某个模块”“实现一处小改动”“跑一遍离线测试并总结”这类有边界的任务，可以在独立的低成本会话中完成。本工具把这些任务交给 DeepSeek Worker，返回可复核的变更与验证摘要，避免主会话重复劳动。

本工具不会自动调用 DeepSeek，不修改主 Codex 的默认模型，也不会自动扩大权限。若手工指定 `-ResultFile` 或 `-RunRoot`，路径必须位于受协调工作树之外，避免 Runner 制品成为项目变更。

## v0.3.1-rc1 的取舍

`v0.3.1-rc1` 固定从安装目录调用当前 Runner，不再从 `PATH` 或旧 `%APPDATA%\npm` 入口解析。升级时只会识别并备份本项目旧 Runner，再替换成薄兼容转发器；其他用户脚本不会被覆盖。

它继续保留 `$deepseek-worker` 调用方式和 `audit`、`implement`、`quota-first` 三种模式，并沿用 v0.3 的精简终态契约。`runner_state` 由进程退出、超时、清理与 Git 硬边界判定；`completed` 只表示执行完成，不等于业务验收通过。命令证据用于主 Codex 业务验收，中途某条命令失败不会单独改写最终进程状态。`summary.txt` 只是普通文本或 Markdown 摘要，缺失或格式变化不会把成功执行误拒绝。`-ResultFile` 在所有终态写入 Runner 生成的终态信封。

Worker 若触碰运行前已有脏文件，Runner 会记录重叠警告并交由主 Codex 针对性复核，不再仅因重叠强制失败。PowerShell 7、Job Object、硬超时、进程树清理、Git HEAD/index 门禁、同工作树协调、Key 隔离和默认禁网仍保留。

## 信任边界

Worker 默认 `read-only`、无网络、`--ephemeral`。它与主 Codex 共享 `CODEX_HOME` 以复用同一套 Windows 沙箱状态，但使用独立的 `deepseek-worker` profile；Launcher 清除线程和权限环境钩子，在 CLI 最高优先级固定模型、provider 与权限，关闭插件、Hooks、记忆和多代理，并禁用 Desktop 内置及用户/项目配置中按常规 `[mcp_servers.<name>]` 声明的 MCP。`implement` 才允许写入工作树，网络仍需显式开启。生产写入、部署、数据库迁移、凭据、破坏性操作和重大安全决策仍由主代理直接授权和复核。

Runner 记录 Git 前后状态，把本次新增变更与运行前已存在的脏文件分开归因。进程与 Git 事实决定 `runner_state`；命令证据用于主 Codex 判断任务是否达到验收标准。`summary.txt` 是不具权威性的模型摘要。

“无网络”约束的是 Worker 沙箱内启动的工具。任务 Prompt 与所选代码上下文仍会发送给配置的 DeepSeek API；不得委托策略禁止发送给该服务商的秘密或敏感数据。

## 兼容性说明

本仓库是社区集成，验证环境为 2026-08-11 的 Codex CLI 0.147.0 与 DeepSeek V4 Flash（Responses 兼容端点）。不声称官方背书，主 Codex 默认模型不会被修改。具体行为可能随版本变化。

DeepSeek 当前公开更新日志明确写到的是 OpenAI Chat Completions 与 Anthropic 兼容接口。因此，本项目的 `wire_api = "responses"` 应理解为经过本项目实测的 Codex 兼容路径，不应扩大解释为 DeepSeek 对通用 Responses API 的长期承诺。Codex CLI 或 DeepSeek API 更新后，需要重新做真实冒烟测试。

## 快速开始

前置条件：Windows、Git、非 Store 安装的 PowerShell 7（推荐 MSI；便携版可用 `CODEX_DEEPSEEK_PWSH_PATH` 指定）、`PATH` 中可用的 Codex CLI（已验证 0.147.0；其他版本会提示警告，应先运行 `-WorkspaceProbe`，也可用 `CODEX_DEEPSEEK_CODEX_PATH` 指定）、DeepSeek API Key。Worker 不再回退到 Windows PowerShell 5.1。

```powershell
pwsh ./scripts/Install-DeepSeekWorker.ps1 -WhatIf
pwsh ./scripts/Install-DeepSeekWorker.ps1
pwsh "$env:LOCALAPPDATA\CodexDeepSeekWorker\Set-DeepSeekKey.ps1"
```

安装器不联网、不接受明文 Key 参数。密钥脚本用 `Read-Host -AsSecureString` 掩码输入，并写入受限 ACL 文件。随后可运行 `-Doctor` 和 `-DryRun` 做离线检查。若升级 Codex 或遇到 `Access denied`，可在目标工作区运行一次真实、无网络的写入探针：

```powershell
pwsh "$env:LOCALAPPDATA\CodexDeepSeekWorker\codex-deepseek-exec.ps1" -Workdir . -WorkspaceProbe
```

安装后的 Worker profile 使用 Codex 首选的 `elevated` Windows 沙箱，以可靠写入工作区；首次使用可能需要完成一次原生沙箱初始化，但这不等于用管理员身份运行 Codex。探针只会在工作树根创建、读回并删除一个随机命名的临时文件；失败即停止，不会自动修改 ACL。

需要可复现安装时，请从 [v0.3.1-rc1 Release](../../releases/tag/v0.3.1-rc1) 下载版本固定的 ZIP 与 `SHA256SUMS.txt`；不要把开发分支当作固定安装包。

如需使用企业托管或自定义位置的受限密钥文件，可设置 `CODEX_DEEPSEEK_KEY_FILE`；该变量只包含文件路径，不包含密钥值。

## 三种模式

`audit` 只读审查；`implement` 在 `workspace-write` 中完成有边界改动；`quota-first` 由 Worker 自主完成发现、实现、测试和自检，返回紧凑证据包供主会话复核。默认 `read-only` 对应 `audit`，`workspace-write` 对应 `implement`。

## 并发与限额

独立工作树可并行；同一工作树由命名互斥锁和“PID+进程启动时间”注册表约束。写模式与同工作树所有 Worker 互斥，只读模式与写模式冲突，且不提供同工作树绕过开关；需要并行写时使用独立 Git worktree。`-Doctor` 只报告过期注册，不修改；真实运行在协调锁内清理。Worker 进程树由 Windows Job Object 托管，默认 45 分钟硬超时或 Runner 结束时统一终止后代；默认时限会预留最后五分钟收尾，主动设置较短时限时按比例缩短收尾窗口。不自动重试，也不静默切换模型或 provider。

`quota-first` 下，Worker 对有边界任务负责检索、实现、相关测试、纠错和自审；主会话先读 `status.json`、`summary.txt`、`changed-files.txt`、`diff-stat.txt` 与 `commands.json`，不重复已有确定性证据支持的探索。低风险通常只读紧凑包，中风险补看针对性的 diff/测试，高风险生产、凭据、安全、迁移、部署和破坏性操作仍由主代理直接授权与验证。整个 Worker 运行失败后停止，不自动重派、换模型、降权限或由主代理重做；同一运行内可以修正并重跑失败检查。Worker 不暂存或提交，Git 集成统一由主 Codex 完成。

这会主动多用一些 DeepSeek token 来换取完整性，但减少高价主模型的重复上下文。Runner 分别记录缓存输入、非缓存输入、输出、推理输出、时长和命令数量，避免把“总 token 更多”误判成“成本一定更高”。

## 限制

脚本面向 Windows；公开模板只在特定 Codex CLI 与模型版本上验证过；`summary.txt` 仍是模型陈述，使用时应以 Runner 事实和风险相关证据为准；失败或超时若留下变更，会标记 `unverified_partial_changes`，但 `-ResultFile` 仍写入终态信封；MCP 禁用覆盖常规 section 声明和当前 Desktop 内置名称，但不是针对恶意或未来未知配置源的密码学隔离；安装器不会把安装目录加入 `PATH`。

## 升级与卸载

升级：在仓库内运行 `pwsh ./scripts/Install-DeepSeekWorker.ps1 -Force`。安装器先暂存和校验，再替换托管文件，并在安装目录的 `backups` 下保留带时间戳、供人工恢复的备份；安装事务失败时才自动尝试回滚。Key 与历史运行证据不在替换范围内。若使用自定义 `CODEX_HOME`、Worker 根目录或便携 PowerShell，升级和卸载时应设置相同环境变量。

卸载：运行 `"$env:LOCALAPPDATA\CodexDeepSeekWorker\Uninstall-DeepSeekWorker.ps1"`。默认保留 Key 文件、profile 配置、备份和运行证据；只有明确需要清理时，才添加 `-RemoveKeyFile -RemoveProfileConfig -RemoveRunArtifacts`。默认卸载后若重新安装，因 profile 仍在，应使用 `-Force`；若要干净重装，卸载时加 `-RemoveProfileConfig`。

## 免责声明

本项目按现状提供，不附带任何担保，与 OpenAI 和 DeepSeek 无隶属或背书关系。生产使用前请自行确认模型可用性、价格、数据处理与 API 条款。

维护者可在 [docs/publication-kit.md](docs/publication-kit.md) 查看拟发布的 GitHub 简介、topics、Release 文案、中文介绍与发布检查清单。
