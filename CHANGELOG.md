# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.2.2-rc1] - 2026-08-11

### Fixed

- Keep Git index, HEAD, and refs under the main Codex's ownership; detect staged-content changes without automatically undoing them.
- Recover one short prose prefix before a single valid result object, while rejecting multiple objects, extra fields, invalid array values, and oversized output.
- Publish only normalized JSON to `ResultFile` while preserving the raw worker final in the run artifacts.

## [0.2.1-rc1] - 2026-08-11

### Changed

- Require a verified non-Store PowerShell 7 runtime and prefer it for Codex child shell discovery.
- Prevent `quota-first` runs shorter than 30 minutes and reserve the last five minutes for structured finalization.
- Preserve `timed_out` state and mark unverified partial workspace changes without automatic retry or recovery automation.

## [0.2.0-rc1] - 2026-08-11

### Added

- Versioned release, runner, result-schema, adapter, source-commit, and installed-file hash metadata.
- Transactional staged install/upgrade with timestamped backups, rollback on failure, and strict read-only Doctor checks.
- Bounded usage and command evidence: duration, cached/uncached input, output/reasoning tokens, command totals, recent successful commands, and failed commands.
- Reproducible ZIP packaging with a SHA-256 checksum file.

### Changed

- `quota-first` now makes the Worker own bounded discovery, implementation, correction, relevant tests, and self-review; the main agent consumes compact evidence first and scales review by risk.
- Invalid final JSON, prompt-cleanup failure, Git evidence failure, changed HEAD, or edits overlapping pre-existing dirty files now fail the run and prevent `-ResultFile` publication.
- Same-worktree coordination no longer has a bypass. Independent write concurrency uses separate Git worktrees.
- Doctor reports stale registrations without deleting them and rejects unsupported Codex CLI or changed managed-file hashes.

### Security

- Key replacement now writes atomically with a restrictive ACL applied before key material is stored.
- Documentation now distinguishes tool-network isolation from model-provider data transmission and accurately describes the shared-home profile boundary.

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
