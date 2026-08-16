# Contributing

Thanks for helping improve the DeepSeek Worker. This project is a public candidate repository, so every contribution must be safe to publish.

## Ground rules

- Do not commit personal usernames, absolute local paths, API keys, tokens, logs, run artifacts, session data, or other user content.
- Keep the skill package lean: `skill/deepseek-worker` contains only `SKILL.md` and `agents/openai.yaml`. User-facing docs live in the repository root or `docs/`.
- Preserve the runner invariants: default read-only/no-network/ephemeral, audit/implement/quota-first, Git before/after attribution, same-worktree locking, PID+start-time identity, 45-minute timeout with process-tree termination, no automatic retries, no silent model/provider fallback, Runner-authoritative terminal envelopes, and compact evidence bundling.
- Do not add an abstraction, state, protocol, fallback, or recovery path without a demonstrated failure or acceptance requirement. Prefer deleting or simplifying an existing mechanism, and report the net change in states, branches, managed files, and rollback paths.
- Do not add network calls to the installer or CI. CI must be offline static checks without API keys.

## Development workflow

1. Create a feature branch from `main`.
2. Make focused changes and add or update offline tests in `tests/`.
3. Run the full test suite:

```powershell
pwsh ./tests/run-tests.ps1
```

4. Update `CHANGELOG.md` and, when behavior changes, the affected docs.
5. Open a pull request using the repository PR template.

## Review checklist

- PowerShell scripts parse without errors.
- JSON and YAML assets parse, and Skill frontmatter remains valid.
- No forbidden path or secret patterns appear in tracked text files.
- Installer dry-run does not create files or directories.
- CI pins external GitHub Actions to full commit SHAs and does not reference secrets.
