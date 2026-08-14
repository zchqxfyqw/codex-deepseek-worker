# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.3.1-rc1] - 2026-08-14

### Fixed

- Pin Skill dispatch to the installed Runner under `LOCALAPPDATA` so an obsolete npm script cannot silently route a task to an older contract.
- During a transactional `-Force` upgrade, replace only a recognized product-owned legacy npm Runner with a thin compatibility forwarder; preserve unrelated user scripts and back up every replaced entry.

## [0.3.0-rc1] - 2026-08-13

### Changed

- Keep the existing `$deepseek-worker` invocation and `audit`, `implement`, and `quota-first` modes while simplifying the handoff to a facts-first Runner contract.
- Make Runner-observed process exit, timeout, cleanup, and Git hard boundaries authoritative for `runner_state`; keep command evidence for task acceptance without treating every intermediate failure as a failed run.
- Store the Worker's final prose as bounded `summary.txt`; plain text, Markdown, missing text, or malformed JSON no longer changes an otherwise valid process outcome.
- Write a Runner-generated terminal envelope atomically to `status.json` and optional `-ResultFile` for every terminal outcome.
- Record edits overlapping pre-existing dirty files as targeted-review warnings instead of automatically failing the run. Changed Git HEAD or index remains a hard boundary.
- Keep the compact default review set to `status.json`, `summary.txt`, `changed-files.txt`, `diff-stat.txt`, and `commands.json`; reserve event and stderr streams for diagnostics.

### Removed

- Remove the model-authored final JSON Schema and its parser/recovery layers.
- Remove `worker_claim`, `claimed_verification`, `final_schema_valid`, `final_parse_mode`, and model-authored `publishable` from the active result contract.

### Fixed

- Keep the per-worktree registration through terminal evidence collection, capture child identity before Job assignment, and guarantee Job disposal even when termination reports an error.
- Run the workspace write probe entirely inside the Codex sandbox with one root-level temporary file, avoiding a false access denial caused by a helper directory created before sandbox startup.
- Use Codex's elevated Windows workspace sandbox and make the write probe fail on its first filesystem error, instead of allowing the restricted unelevated token to retry writes that cannot succeed.
- Accept a clean Git repository with an empty index when capturing the baseline hash.
- Preserve packaged source identity during ZIP installs, transactionally retire the old result Schema, and keep API keys and historical runs untouched during upgrades.

## [0.2.4-rc1] - 2026-08-12

### Fixed

- Accept one schema-valid JSON object wrapped in a standard `json` Markdown fence, with at most one short prose prefix, while retaining all single-object, duplicate-field, exact-schema, and size checks.

## [0.2.3-rc1] - 2026-08-11

### Added

- Add an explicit `-WorkspaceProbe` that verifies a real sandboxed create/read/delete round trip without network access.

### Fixed

- Keep the complete Worker process tree in a Windows Job Object so descendants cannot outlive the runner or retain artifact handles.
- Read the event stream with bounded shared-file retries and always finalize failed evidence collection instead of leaving `status.json` at `running`.

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
