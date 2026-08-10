# Verification

## Verified Matrix

| Component | Version / value |
| --- | --- |
| Codex CLI | `0.147.0` |
| Model | `deepseek-v4-flash` |
| Provider wire API | `responses` |
| Date | 2026-08-10 |
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
- JSON parseability for schema, model catalog, and test fixtures
- Skill frontmatter and `agents/openai.yaml` shape
- Forbidden personal-path and common-secret patterns
- Installer `-WhatIf` behavior against temporary environment roots
- Skill package file whitelist
- CI workflow pinned-action and no-secrets checks
- Required README sections

## Live Release-Candidate Smoke Test

The 2026-08-10 release candidate was installed into a fresh temporary layout and exercised against a temporary Git repository using Codex CLI `0.147.0` and `deepseek-v4-flash`:

- `-Doctor` returned `ok=true`, detected Codex CLI `0.147.0`, the installed profile/model catalog, launcher, schema, and external key-file path.
- A `read-only` structured run completed with exit code 0, read the exact fixture marker, and produced no Git changes.
- A `workspace-write` structured run completed with exit code 0 and created only `RESULT.md`; independent byte verification found exactly `public-worker-ok` plus one LF (`17` bytes).
- The successful runs' stderr/artifact scan contained no `api.openai.com`, `chatgpt.com`, `anthropic.com`, GitHub plugin-sync, or plugin destination strings.
- The prompt stdin file was removed after completion and no key value was written to the run directory.

During release testing, `codex exec --ignore-user-config` was rejected as a design choice because Codex CLI `0.147.0` reduced the requested `workspace-write` run to read-only and could ignore provider configuration depending on option placement. The verified design instead uses the dedicated profile plus CLI-priority pinning and MCP disables while sharing one Windows sandbox state.

## Release Checklist

- Run `pwsh ./tests/run-tests.ps1` and confirm exit code 0.
- Confirm no tracked file contains a machine-specific absolute path or secret.
- Confirm `skill/deepseek-worker` contains only `SKILL.md`, `agents/openai.yaml`, and `assets/delegation-result.schema.json`.
- Confirm the installer dry-run creates no files.
- Review the pinned GitHub Action SHA before publishing the workflow.
- Perform one real read-only and one isolated temporary-repository write smoke test with DeepSeek V4 Flash; do not use a production repository.
- Update `CHANGELOG.md` for user-visible changes.
