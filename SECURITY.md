# Security

## Reporting a vulnerability

Do not open a public issue for security problems. Once the repository is published, report through the GitHub private security advisory flow, or contact the maintainers privately with a minimal reproduction. Include the affected version, the impact, and steps to reproduce. Do not include live credentials or API keys.

## Key handling

- The API key is read by the launcher from `%LOCALAPPDATA%\CodexDeepSeekWorker\deepseek-api-key.txt` and injected only through the `DEEPSEEK_API_KEY` environment variable for the child Codex process.
- The key never appears in argv, prompts, final messages, run artifacts, or logs.
- `Set-DeepSeekKey.ps1` accepts input only through a masked secure prompt and writes the file with a restricted ACL for the current user.
- The repository, CI, and installer never receive, store, or transmit a key.

## Trust model

- Worker runs are read-only and network-disabled by default.
- The worker shares `CODEX_HOME` so Windows reuses one sandbox account state. A dedicated profile plus CLI-priority overrides pin the DeepSeek provider/model, disable ordinary configured MCP servers and optional features, and strip the main session's thread and permission hooks. This is a practical boundary, not a cryptographic isolation boundary against deliberately unusual or future configuration sources.
- "Network disabled" applies to tools launched by the Worker. The task prompt and relevant code/context are still sent to the configured DeepSeek API because that is the model provider.
- Production writes, deployment, database changes, credentials, destructive actions, and material security decisions remain with the main agent and require direct authorization and review.
- A worker result is a model claim. Treat `runner_state`, command evidence, and Git artifacts as runner facts, and verify claims before acting on them.

## Release expectations

Public releases must pass the offline static checks in `tests/run-tests.ps1`, must not contain personal paths, secrets, logs, run artifacts, or user content, and must keep the skill package limited to `SKILL.md`, `agents/openai.yaml`, and `assets/`.
