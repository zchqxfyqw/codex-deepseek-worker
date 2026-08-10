[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]
$passCount = 0

function Add-Pass {
    param([string]$Name)
    $script:passCount++
    Write-Host "PASS $Name"
}

function Add-Fail {
    param([string]$Name, [string]$Detail)
    $script:failures.Add("$Name : $Detail")
    Write-Host "FAIL $Name : $Detail"
}

function Invoke-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Check
    )
    try {
        & $Check
        Add-Pass -Name $Name
    }
    catch {
        Add-Fail -Name $Name -Detail $_.Exception.Message
    }
}

Invoke-Check -Name 'PowerShell syntax' -Check {
    $scriptFiles = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'scripts') -Filter '*.ps1' -File)
    $scriptFiles += @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tests') -Filter '*.ps1' -File)
    foreach ($scriptFile in $scriptFiles) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        if ($null -ne $errors -and $errors.Count -gt 0) {
            throw "$($scriptFile.FullName): $($errors[0].Message)"
        }
    }
}

Invoke-Check -Name 'JSON parse' -Check {
    $jsonFiles = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter '*.json' |
        Where-Object { $_.FullName -notmatch '\\\.git\\' })
    foreach ($jsonFile in $jsonFiles) {
        Get-Content -LiteralPath $jsonFile.FullName -Raw | ConvertFrom-Json | Out-Null
    }
}

Invoke-Check -Name 'Skill frontmatter' -Check {
    $skillText = Get-Content -LiteralPath (Join-Path $repoRoot 'skill\deepseek-worker\SKILL.md') -Raw
    if ($skillText -notmatch '(?s)^---\r?\nname:\s*deepseek-worker\r?\ndescription:\s*.+?\r?\n---') {
        throw 'SKILL.md frontmatter is missing name or description.'
    }
    if ($skillText -notmatch '\$deepseek-worker') {
        throw 'SKILL.md does not reference $deepseek-worker.'
    }
}

Invoke-Check -Name 'Skill openai.yaml' -Check {
    $yamlText = Get-Content -LiteralPath (Join-Path $repoRoot 'skill\deepseek-worker\agents\openai.yaml') -Raw
    if ($yamlText -notmatch '(?m)^interface:\s*$') { throw 'agents/openai.yaml is missing interface.' }
    if ($yamlText -notmatch '(?m)^\s*display_name:\s*".+"\s*$') { throw 'agents/openai.yaml is missing display_name.' }
    if ($yamlText -notmatch '(?m)^\s*short_description:\s*".+"\s*$') { throw 'agents/openai.yaml is missing short_description.' }
    if ($yamlText -notmatch '(?m)^\s*default_prompt:\s*".+"\s*$') { throw 'agents/openai.yaml is missing default_prompt.' }
    if ($yamlText -notmatch '(?m)^policy:\s*$') { throw 'agents/openai.yaml is missing policy.' }
    if ($yamlText -notmatch '(?m)^\s*allow_implicit_invocation:\s*false\s*$') { throw 'agents/openai.yaml must set allow_implicit_invocation: false.' }
}

Invoke-Check -Name 'Output schema shape' -Check {
    $schema = Get-Content -LiteralPath (Join-Path $repoRoot 'skill\deepseek-worker\assets\delegation-result.schema.json') -Raw | ConvertFrom-Json
    $required = @('status', 'summary', 'changed_files', 'claimed_verification', 'risks_or_followups')
    foreach ($field in $required) {
        if ($schema.required -notcontains $field) {
            throw "Schema is missing required field: $field"
        }
    }
}

Invoke-Check -Name 'Forbidden paths and secrets' -Check {
    $userNamePattern = [string]([char]104 + [char]113 + [char]120 + [char]102 + [char]121)
    $patterns = @(
        "(?i)$userNamePattern",
        '(?i)[A-Za-z]:\\codex[\\/]',
        '(?i)[A-Za-z]:/codex',
        '(?i)[A-Za-z]:\\Users\\',
        '(?i)[A-Za-z]:/Users/',
        'sk-[A-Za-z0-9]{16,}',
        'ghp_[A-Za-z0-9]{20,}',
        'github_pat_[A-Za-z0-9_]{20,}',
        'AKIA[0-9A-Z]{16}',
        'xox[baprs]-[A-Za-z0-9-]{10,}',
        '-----BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY-----',
        'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
    )
    $trackedFiles = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File |
        Where-Object { $_.FullName -notmatch '\\\.git\\' })
    foreach ($file in $trackedFiles) {
        $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
        foreach ($pattern in $patterns) {
            if ($text -match $pattern) {
                throw "Forbidden pattern in $($file.FullName): $pattern"
            }
        }
    }
}

Invoke-Check -Name 'Installer dry-run' -Check {
    $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ('dsw-dryrun-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempBase | Out-Null
    $previousLocal = $env:LOCALAPPDATA
    $previousCodexHome = $env:CODEX_HOME
    $previousWorkerRoot = $env:CODEX_DEEPSEEK_WORKER_ROOT
    try {
        $env:LOCALAPPDATA = Join-Path $tempBase 'localappdata'
        $env:CODEX_HOME = Join-Path $tempBase 'codexhome'
        $env:CODEX_DEEPSEEK_WORKER_ROOT = Join-Path $tempBase 'workerroot'
        & (Join-Path $repoRoot 'scripts\Install-DeepSeekWorker.ps1') -WhatIf *> $null
        if (Test-Path -LiteralPath (Join-Path $tempBase 'workerroot')) {
            throw 'Installer dry-run created the install root.'
        }
        if (Test-Path -LiteralPath (Join-Path $tempBase 'codexhome')) {
            throw 'Installer dry-run created the Codex home.'
        }
    }
    finally {
        if ($null -eq $previousLocal) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $previousLocal }
        if ($null -eq $previousCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $previousCodexHome }
        if ($null -eq $previousWorkerRoot) { Remove-Item Env:CODEX_DEEPSEEK_WORKER_ROOT -ErrorAction SilentlyContinue } else { $env:CODEX_DEEPSEEK_WORKER_ROOT = $previousWorkerRoot }
        Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Check -Name 'Installer temp install' -Check {
    $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ('dsw-install-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempBase | Out-Null
    $previousLocal = $env:LOCALAPPDATA
    $previousCodexHome = $env:CODEX_HOME
    $previousWorkerRoot = $env:CODEX_DEEPSEEK_WORKER_ROOT
    try {
        $env:LOCALAPPDATA = Join-Path $tempBase 'localappdata'
        $env:CODEX_HOME = Join-Path $tempBase 'codexhome'
        $env:CODEX_DEEPSEEK_WORKER_ROOT = Join-Path $tempBase 'workerroot'
        & (Join-Path $repoRoot 'scripts\Install-DeepSeekWorker.ps1') *> $null
        $installRoot = Join-Path $tempBase 'workerroot'
        $skillRoot = Join-Path $tempBase 'codexhome\skills\deepseek-worker'
        foreach ($expected in @(
            (Join-Path $installRoot 'codex-deepseek.ps1'),
            (Join-Path $installRoot 'codex-deepseek-exec.ps1'),
            (Join-Path $installRoot 'Set-DeepSeekKey.ps1'),
            (Join-Path $installRoot 'Uninstall-DeepSeekWorker.ps1'),
            (Join-Path $installRoot 'assets\delegation-result.schema.json'),
            (Join-Path $installRoot 'models.json'),
            (Join-Path $tempBase 'codexhome\deepseek-worker.config.toml'),
            (Join-Path $skillRoot 'SKILL.md'),
            (Join-Path $skillRoot 'agents\openai.yaml'),
            (Join-Path $skillRoot 'assets\delegation-result.schema.json')
        )) {
            if (-not (Test-Path -LiteralPath $expected -PathType Leaf)) {
                throw "Installer did not create $expected"
            }
        }
        if (Test-Path -LiteralPath (Join-Path $installRoot 'deepseek-api-key.txt')) {
            throw 'Installer must not create a key file.'
        }
        $profileText = Get-Content -LiteralPath (Join-Path $tempBase 'codexhome\deepseek-worker.config.toml') -Raw
        if ($profileText -match '\{\{MODEL_CATALOG_PATH\}\}') {
            throw 'Installer did not substitute the model catalog path.'
        }
    }
    finally {
        if ($null -eq $previousLocal) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $previousLocal }
        if ($null -eq $previousCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $previousCodexHome }
        if ($null -eq $previousWorkerRoot) { Remove-Item Env:CODEX_DEEPSEEK_WORKER_ROOT -ErrorAction SilentlyContinue } else { $env:CODEX_DEEPSEEK_WORKER_ROOT = $previousWorkerRoot }
        Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Check -Name 'Uninstaller preserves sensitive state by default' -Check {
    $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ('dsw-uninstall-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempBase | Out-Null
    $previousLocal = $env:LOCALAPPDATA
    $previousCodexHome = $env:CODEX_HOME
    $previousWorkerRoot = $env:CODEX_DEEPSEEK_WORKER_ROOT
    try {
        $env:LOCALAPPDATA = Join-Path $tempBase 'localappdata'
        $env:CODEX_HOME = Join-Path $tempBase 'codexhome'
        $env:CODEX_DEEPSEEK_WORKER_ROOT = Join-Path $tempBase 'workerroot'
        & (Join-Path $repoRoot 'scripts\Install-DeepSeekWorker.ps1') *> $null

        $keyPath = Join-Path $env:CODEX_DEEPSEEK_WORKER_ROOT 'deepseek-api-key.txt'
        $runMarker = Join-Path $env:CODEX_DEEPSEEK_WORKER_ROOT 'runs\preserve.marker'
        New-Item -ItemType Directory -Path (Split-Path -Parent $runMarker) -Force | Out-Null
        [System.IO.File]::WriteAllText($keyPath, 'test-placeholder-not-a-real-key')
        [System.IO.File]::WriteAllText($runMarker, 'preserve')

        & (Join-Path $repoRoot 'scripts\Uninstall-DeepSeekWorker.ps1') -Confirm:$false *> $null

        if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) {
            throw 'Default uninstall removed the key file.'
        }
        if (-not (Test-Path -LiteralPath $runMarker -PathType Leaf)) {
            throw 'Default uninstall removed run artifacts.'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'deepseek-worker.config.toml') -PathType Leaf)) {
            throw 'Default uninstall removed the profile config.'
        }
        if (Test-Path -LiteralPath (Join-Path $env:CODEX_DEEPSEEK_WORKER_ROOT 'codex-deepseek-exec.ps1') -PathType Leaf) {
            throw 'Default uninstall did not remove the installed runner.'
        }
        if (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'skills\deepseek-worker') -PathType Container) {
            throw 'Default uninstall did not remove the installed skill.'
        }
    }
    finally {
        if ($null -eq $previousLocal) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $previousLocal }
        if ($null -eq $previousCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $previousCodexHome }
        if ($null -eq $previousWorkerRoot) { Remove-Item Env:CODEX_DEEPSEEK_WORKER_ROOT -ErrorAction SilentlyContinue } else { $env:CODEX_DEEPSEEK_WORKER_ROOT = $previousWorkerRoot }
        Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Check -Name 'Skill package whitelist' -Check {
    $skillRoot = Join-Path $repoRoot 'skill\deepseek-worker'
    $expected = @(
        'SKILL.md',
        'agents\openai.yaml',
        'assets\delegation-result.schema.json'
    )
    $actual = @(Get-ChildItem -LiteralPath $skillRoot -Recurse -File | ForEach-Object {
        $_.FullName.Substring($skillRoot.Length + 1)
    })
    $actual = @($actual | Sort-Object)
    $actualJoined = $actual -join '|'
    $expectedJoined = (@($expected | Sort-Object)) -join '|'
    if ($actualJoined -ne $expectedJoined) {
        throw "Skill package contains unexpected files: $($actual -join ', ')"
    }
}

Invoke-Check -Name 'Installer and key script safety' -Check {
    $installerText = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts\Install-DeepSeekWorker.ps1') -Raw
    $keyText = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts\Set-DeepSeekKey.ps1') -Raw
    $launcherText = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts\codex-deepseek.ps1') -Raw
    foreach ($text in @($installerText, $keyText)) {
        if ($text -match '(?is)param\s*\([^)]*(api[_-]?key|secret|token)') {
            throw 'A key parameter is exposed on the command line.'
        }
        if ($text -match '(?im)^\s*\[Parameter[^\]]*\]\s*[^\r\n]*(api[_-]?key|secret|token)') {
            throw 'A key parameter is exposed on the command line.'
        }
    }
    if ($installerText -notmatch 'SupportsShouldProcess') { throw 'Installer is missing SupportsShouldProcess.' }
    if ($keyText -notmatch 'SupportsShouldProcess') { throw 'Key script is missing SupportsShouldProcess.' }
    if ($keyText -notmatch 'Read-Host.*-AsSecureString') { throw 'Key script does not use a masked secure prompt.' }
    if ($keyText -notmatch 'WindowsIdentity.*GetCurrent' -or $keyText -notmatch '\.User' -or $keyText -notmatch 'SetAccessRuleProtection\(\$true,\s*\$false\)') {
        throw 'Key script does not construct an inheritance-protected SID-based ACL.'
    }
    if ($launcherText -notmatch '\$effectiveArguments\s*=\s*@\(\$globalFixedArguments\)\s*\+\s*@\(\$execFixedArguments\)\s*\+\s*@\(\$CodexArguments\)') {
        throw 'Launcher does not place fixed global options before caller subcommand arguments.'
    }
    if ($launcherText -notmatch 'Caller override is not allowed') {
        throw 'Launcher does not reject pinned configuration overrides.'
    }
    if ($launcherText -notmatch 'CODEX_DEEPSEEK_KEY_FILE') {
        throw 'Launcher does not support a path-only key-file override.'
    }
    foreach ($requiredOverride in @(
        'model_providers.deepseek-worker-secure.base_url',
        'model_providers.deepseek-worker-secure.wire_api',
        'model_providers.deepseek-worker-secure.env_key',
        'model_catalog_json'
    )) {
        if ($launcherText -notmatch [regex]::Escape($requiredOverride)) {
            throw "Launcher is missing isolated provider override: $requiredOverride"
        }
    }
}

Invoke-Check -Name 'CI workflow' -Check {
    $ciText = Get-Content -LiteralPath (Join-Path $repoRoot '.github\workflows\ci.yml') -Raw
    if ($ciText -notmatch 'uses:\s*[^\s@]+@[0-9a-f]{40}') {
        throw 'CI does not pin an external action to a full commit SHA.'
    }
    if ($ciText -match '\$\{\{\s*secrets') {
        throw 'CI must not reference secrets.'
    }
    if ($ciText -notmatch 'run-tests\.ps1') {
        throw 'CI does not run the offline test suite.'
    }
}

Invoke-Check -Name 'README requirements' -Check {
    $readme = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw
    foreach ($heading in @(
        '## Problem',
        '## Architecture',
        '## Trust Boundary',
        '## Quick Start',
        '## Typical Prompts',
        '## Modes',
        '## Concurrency Boundary',
        '## Quota Saving Rationale',
        '## Hard Limits',
        '## Upgrade and Uninstall',
        '## Disclaimer'
    )) {
        if ($readme -notmatch [regex]::Escape($heading)) {
            throw "README is missing required section: $heading"
        }
    }
    if ($readme -notmatch '0\.147\.0') { throw 'README does not mention Codex CLI 0.147.0.' }
    if ($readme -notmatch '2026-08-10') { throw 'README does not mention the verification date.' }
}

Invoke-Check -Name 'Config template placeholder' -Check {
    $configText = Get-Content -LiteralPath (Join-Path $repoRoot 'config\deepseek-worker.config.toml.example') -Raw
    if ($configText -notmatch '\{\{MODEL_CATALOG_PATH\}\}') {
        throw 'Profile template is missing the model catalog path placeholder.'
    }
    if ($configText -notmatch '(?m)^model\s*=\s*"deepseek-v4-flash"') {
        throw 'Profile template does not pin deepseek-v4-flash.'
    }
    if ($configText -match '(?m)^\[mcp_servers\.') {
        throw 'Profile template must not create incomplete MCP server tables.'
    }
}

Invoke-Check -Name 'Runner doctor' -Check {
    $doctor = & (Join-Path $repoRoot 'scripts\codex-deepseek-exec.ps1') -Doctor | ConvertFrom-Json
    if (-not $doctor.ok) {
        throw "Doctor reported not ok: launcher=$($doctor.launcher_exists), schema=$($doctor.schema_exists), version=$($doctor.cli_version), profile=$($doctor.profile_exists)"
    }
    if ($doctor.model_pinned -ne $true) { throw 'Doctor did not confirm the pinned model.' }
    if ($doctor.responses_api -ne $true) { throw 'Doctor did not confirm the Responses wire API.' }
}

Invoke-Check -Name 'Runner dry-run' -Check {
    $dry = & (Join-Path $repoRoot 'scripts\codex-deepseek-exec.ps1') `
        -Workdir $repoRoot `
        -Prompt 'Offline dry-run test.' `
        -Mode audit `
        -DryRun | ConvertFrom-Json
    if ($dry.dry_run -ne $true) { throw 'Dry-run did not return dry_run=true.' }
    if ($dry.model -ne 'deepseek-v4-flash') { throw 'Dry-run did not pin deepseek-v4-flash.' }
    if ($dry.provider -ne 'deepseek-worker-secure') { throw 'Dry-run did not pin the provider.' }
    if ($dry.network -ne $false) { throw 'Dry-run did not default network to false.' }
}

Invoke-Check -Name 'Runner uses pinned shared-home profile' -Check {
    $runnerText = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts\codex-deepseek-exec.ps1') -Raw
    $launcherText = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts\codex-deepseek.ps1') -Raw
    if ($runnerText -match '--ignore-user-config') {
        throw 'Runner still uses --ignore-user-config, which breaks workspace-write in the verified CLI.'
    }
    if ($launcherText -notmatch "'--profile',\s*'deepseek-worker'" -or
        $launcherText -notmatch 'mcp_servers\.node_repl\.enabled=false' -or
        $launcherText -notmatch 'mcp_servers\.openaiDeveloperDocs\.enabled=false' -or
        $launcherText -notmatch '\$configCandidates' -or
        $launcherText -notmatch '\$mcpNames') {
        throw 'Launcher does not pin the profile and MCP disable boundary.'
    }
}

if ($failures.Count -gt 0) {
    Write-Host "Tests failed: $($failures.Count)"
    foreach ($failure in $failures) {
        Write-Host "  - $failure"
    }
    exit 1
}

Write-Host "All offline checks passed ($passCount)."
exit 0
