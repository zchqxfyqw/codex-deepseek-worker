# Verification

## Verified Matrix

| Component | Version / value |
| --- | --- |
| Codex CLI | `0.147.0` |
| Model | `deepseek-v4-flash` |
| Provider wire API | `responses` |
| Release candidate | `0.3.0-rc1` / runner contract `4` |
| Date | 2026-08-13 |
| Platform | Windows |

This is a community verification. It does not imply OpenAI or DeepSeek endorsement, and future CLI or API changes may require config updates.

DeepSeek's public changelog currently describes V4 Flash support through the OpenAI Chat Completions and Anthropic-compatible interfaces. This repository's Responses wire path is an observed Codex integration result, not a claim that every Responses API client is supported. See:

- https://api-docs.deepseek.com/updates
- https://api-docs.deepseek.com/api/list-models

## Offline Tests

All repository checks are offline and require no API key:

```powershell
pwsh ./tests/run-tests.ps1
```

The suite covers:

- PowerShell parser errors in `scripts/` and `tests/`
- JSON parseability for the model catalog and test fixtures
- Skill frontmatter and `agents/openai.yaml` shape
- Forbidden personal-path and common-secret patterns
- Installer `-WhatIf` behavior against temporary environment roots
- Transactional upgrade backup preservation and installed-file hash verification
- Strict installed-layout Doctor behavior, managed-file tamper detection, and CLI compatibility reporting
- Mode/sandbox mismatch rejection
- Real-sandbox workspace-probe success and failure handling through the fake CLI contract
- Windows Job Object cleanup of a deliberately surviving descendant process
- Fake-CLI validation that plain-text, Markdown, malformed, or missing summaries do not override Runner facts; plus nonzero exit, timeout, bounded command/usage evidence, prompt cleanup, and atomic terminal `-ResultFile` publication
- Skill package file whitelist
- CI workflow pinned-action and no-secrets checks
- Required README sections

## Historical Live 0.2.0-rc1 Smoke Test

The packaged ZIP generated from commit `e742f6b6e5fbe6a71d8251b514a86ad59c6e8128` was installed into a fresh temporary layout and exercised on 2026-08-11 against an isolated temporary Git repository using Codex CLI `0.147.0` and `deepseek-v4-flash`:

This evidence predates the v0.3-lite terminal-envelope design. It remains useful for provider, sandbox, key-isolation, and real-write compatibility, but its model-authored result-schema checks no longer define the current contract.

- `-Doctor` returned `install_ok=true` and `cli_supported=true` for Codex CLI `0.147.0`.
- A `read-only` structured run completed with exit code 0, read the exact fixture marker, and produced no Git changes.
- A `workspace-write` structured run completed with exit code 0 and created only `RESULT.md`; independent byte verification found exactly `public-worker-ok` plus one LF (`17` bytes).
- Both final results passed contract validation. The audit recorded 3,985 uncached input tokens; the write run recorded 4,429. Usage was returned as evidence, not used as a pass/fail budget.
- The 28 generated artifacts contained no key value and no `api.openai.com`, `chatgpt.com`, or `anthropic.com` destination strings.
- The prompt stdin file was removed after completion and no key value was written to the run directory.

During release testing, `codex exec --ignore-user-config` was rejected as a design choice because Codex CLI `0.147.0` reduced the requested `workspace-write` run to read-only and could ignore provider configuration depending on option placement. The verified design instead uses the dedicated profile plus CLI-priority pinning and MCP disables while sharing one Windows sandbox state.

## Release Checklist

- Run `pwsh ./tests/run-tests.ps1` and confirm exit code 0.
- Confirm no tracked file contains a machine-specific absolute path or secret.
- Confirm `skill/deepseek-worker` contains only `SKILL.md` and `agents/openai.yaml`.
- Confirm the installer dry-run creates no files.
- Review the pinned GitHub Action SHA before publishing the workflow.
- Perform one real read-only and one isolated temporary-repository write smoke test with DeepSeek V4 Flash; do not use a production repository.
- Update `CHANGELOG.md` for user-visible changes.
