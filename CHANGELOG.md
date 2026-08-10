# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-08-10

### Added

- Public release candidate packaging for the validated DeepSeek Worker Runner v2.
- Dynamic-path PowerShell launcher and runner with no machine-specific paths.
- `audit`, `implement`, and `quota-first` modes with structured final JSON and compact evidence bundling.
- Read-only/no-network/ephemeral defaults, Git before/after attribution, same-worktree locking, PID+start-time registrations, 45-minute timeout, and process-tree termination.
- Installer, masked key configuration script, and uninstaller with `-WhatIf` support.
- Per-profile Codex config template and DeepSeek V4 Flash model catalog template.
- Skill package at `skill/deepseek-worker` with `SKILL.md`, `agents/openai.yaml`, and output schema.
- English and Chinese README, security policy, contributing guide, docs, CI workflow, and issue/PR templates.
- Publication kit with proposed GitHub metadata, release notes, bilingual announcement copy, and review checklist.

### Fixed

- Place pinned global Codex options before the `exec` subcommand and reject caller attempts to override the model, provider, approval policy, disabled features, or MCP settings.
- Preserve the API key, profile config, and run artifacts during default uninstall; add explicit removal switches for each sensitive state category.
- Build the key-file ACL from the current Windows SID with inheritance disabled.
- Support a path-only `CODEX_DEEPSEEK_KEY_FILE` override for isolated testing and managed credential-file locations.
- Pin the dedicated profile before `exec`, while keeping task-local sandbox selection on the `exec` layer; this preserves `workspace-write` on Codex CLI 0.147.0.
- Disable the tested Desktop MCP names plus conventional user/project `[mcp_servers.<name>]` declarations at CLI priority, while sharing one `CODEX_HOME` Windows sandbox state.
- Supply the complete provider definition and model catalog through the installed profile and pin the model/provider at CLI priority, preventing fallback to OpenAI endpoints.
