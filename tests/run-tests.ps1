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

function Push-WorkerTestEnvironment {
    param([Parameter(Mandatory = $true)][string]$BasePath)

    $previous = [ordered]@{}
    foreach ($name in @('LOCALAPPDATA', 'CODEX_HOME', 'CODEX_DEEPSEEK_WORKER_ROOT', 'CODEX_DEEPSEEK_CODEX_PATH', 'CODEX_DEEPSEEK_KEY_FILE', 'CODEX_DEEPSEEK_PWSH_PATH', 'DSW_FAKE_WORKSPACE_PROBE_FAIL', 'DSW_FAKE_DESCENDANT_PID', 'DSW_FAKE_DESCENDANT_LATE_FILE')) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    $env:LOCALAPPDATA = Join-Path $BasePath 'localappdata'
    $env:CODEX_HOME = Join-Path $BasePath 'codexhome'
    $env:CODEX_DEEPSEEK_WORKER_ROOT = Join-Path $BasePath 'workerroot'
    return $previous
}

function Pop-WorkerTestEnvironment {
    param([Parameter(Mandatory = $true)]$Previous)

    foreach ($name in $Previous.Keys) {
        [Environment]::SetEnvironmentVariable($name, $Previous[$name], 'Process')
    }
}

function New-FakeCodexScript {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Version = '0.147.0'
    )

    $template = @'
[CmdletBinding(PositionalBinding = $false)]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
$ErrorActionPreference = 'Stop'
if ($Rest -contains '--version') {
    Write-Output 'codex-cli __VERSION__'
    exit 0
}
if (-not [string]::IsNullOrWhiteSpace($env:DSW_FAKE_RUNTIME_CAPTURE)) {
    $runtimeCapture = [ordered]@{
        version = $PSVersionTable.PSVersion.ToString()
        pshome = $PSHOME
        path_first = @($env:PATH -split ';')[0]
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($env:DSW_FAKE_RUNTIME_CAPTURE, $runtimeCapture, [System.Text.UTF8Encoding]::new($false))
}
$stdinPrompt = [Console]::In.ReadToEnd()
if (-not [string]::IsNullOrWhiteSpace($env:DSW_FAKE_PROMPT_CAPTURE)) {
    [System.IO.File]::WriteAllText($env:DSW_FAKE_PROMPT_CAPTURE, $stdinPrompt, [System.Text.UTF8Encoding]::new($false))
}
$workdirIndex = [Array]::IndexOf([string[]]$Rest, '-C')
$workdir = if ($workdirIndex -ge 0 -and $workdirIndex + 1 -lt $Rest.Count) { $Rest[$workdirIndex + 1] } else { $null }
$probeTokenMatch = [regex]::Match($stdinPrompt, 'DSW_WORKSPACE_PROBE_OK_[0-9a-f]+')
$probePathMatch = [regex]::Match($stdinPrompt, '\.codex_tmp/deepseek-worker-probe-[0-9a-f]+\.txt')
if ($probeTokenMatch.Success -and $probePathMatch.Success -and -not [string]::IsNullOrWhiteSpace($workdir)) {
    $probeToken = $probeTokenMatch.Value
    $probeRelativePath = $probePathMatch.Value
    $probeExitCode = 0
    $probeOutput = $probeToken
    if ($env:DSW_FAKE_WORKSPACE_PROBE_FAIL -eq '1') {
        $probeExitCode = 1
        $probeOutput = 'Access denied'
    }
    else {
        $probePath = Join-Path $workdir $probeRelativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $probePath) -Force | Out-Null
        [System.IO.File]::WriteAllText($probePath, $probeToken, [System.Text.UTF8Encoding]::new($false))
        if ([System.IO.File]::ReadAllText($probePath) -ne $probeToken) { throw 'Fake probe readback mismatch.' }
        Remove-Item -LiteralPath $probePath -Force
    }
    [ordered]@{
        type = 'item.completed'
        item = [ordered]@{
            type = 'command_execution'
            command = "probe $probeRelativePath $probeToken"
            aggregated_output = $probeOutput
            exit_code = $probeExitCode
            status = 'completed'
        }
    } | ConvertTo-Json -Compress -Depth 5 | Write-Output
}
if (-not [string]::IsNullOrWhiteSpace($env:DSW_FAKE_DESCENDANT_PID) -and -not [string]::IsNullOrWhiteSpace($env:DSW_FAKE_DESCENDANT_LATE_FILE)) {
    $lateCommand = "Start-Sleep -Seconds 3; [System.IO.File]::WriteAllText('$($env:DSW_FAKE_DESCENDANT_LATE_FILE.Replace("'", "''"))', 'orphaned')"
    $descendant = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $lateCommand) -WindowStyle Hidden -PassThru
    [System.IO.File]::WriteAllText($env:DSW_FAKE_DESCENDANT_PID, [string]$descendant.Id, [System.Text.UTF8Encoding]::new($false))
}
if (@('index', 'worktree') -contains $env:DSW_FAKE_GIT_MUTATION -and -not [string]::IsNullOrWhiteSpace($workdir)) {
    [System.IO.File]::WriteAllText((Join-Path $workdir 'worker-index-change.txt'), 'index changed', [System.Text.UTF8Encoding]::new($false))
    if ($env:DSW_FAKE_GIT_MUTATION -eq 'index') { & git -C $workdir add worker-index-change.txt }
}
if ($env:DSW_FAKE_FINAL_KIND -eq 'timeout') {
    if (-not [string]::IsNullOrWhiteSpace($workdir)) {
        [System.IO.File]::WriteAllText((Join-Path $workdir 'worker-中文-partial.txt'), '未验证半成品', [System.Text.UTF8Encoding]::new($false))
    }
    Write-Output '{"type":"item.completed","item":{"type":"command_execution","command":"fake-partial-write","exit_code":0,"status":"completed"}}'
    Start-Sleep -Seconds 5
    exit 0
}
$finalIndex = [Array]::IndexOf([string[]]$Rest, '--output-last-message')
if ($finalIndex -lt 0 -or $finalIndex + 1 -ge $Rest.Count) { throw 'Missing --output-last-message.' }
$finalPath = $Rest[$finalIndex + 1]
if ($env:DSW_FAKE_FINAL_KIND -eq 'invalid') {
    [System.IO.File]::WriteAllText($finalPath, '{}', [System.Text.UTF8Encoding]::new($false))
}
else {
    $final = [ordered]@{
        status = if (@('partial', 'prefix-partial') -contains $env:DSW_FAKE_FINAL_KIND) { 'partial' } else { 'completed' }
        summary = 'Fake worker completed.'
        changed_files = @()
        claimed_verification = @('fake-check')
        risks_or_followups = @()
    }
    if ($env:DSW_FAKE_FINAL_KIND -eq 'extra-field') { $final.extra = 'rejected' }
    if ($env:DSW_FAKE_FINAL_KIND -eq 'non-string-array') { $final.claimed_verification = @('fake-check', 1) }
    $final = $final | ConvertTo-Json -Compress
    if (@('prefix', 'prefix-partial') -contains $env:DSW_FAKE_FINAL_KIND) { $final = "Brief result follows.`n`n$final" }
    if ($env:DSW_FAKE_FINAL_KIND -eq 'multiple') { $final = "$final`n$final" }
    if ($env:DSW_FAKE_FINAL_KIND -eq 'json-prefix') { $final = "[] $final" }
    if ($env:DSW_FAKE_FINAL_KIND -eq 'duplicate-field') { $final = $final.Insert(1, '"status":"completed",') }
    if ($env:DSW_FAKE_FINAL_KIND -eq 'trailing') { $final = "$final trailing" }
    if ($env:DSW_FAKE_FINAL_KIND -eq 'oversized') { $final = 'x' * 262145 }
    [System.IO.File]::WriteAllText($finalPath, $final, [System.Text.UTF8Encoding]::new($false))
}
Write-Output '{"type":"item.completed","item":{"type":"command_execution","command":"fake-check","exit_code":0,"status":"completed"}}'
Write-Output '{"type":"turn.completed","usage":{"input_tokens":120,"cached_input_tokens":100,"output_tokens":30,"reasoning_output_tokens":5}}'
exit 0
'@
    [System.IO.File]::WriteAllText($Path, $template.Replace('__VERSION__', $Version), [System.Text.UTF8Encoding]::new($false))
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

Invoke-Check -Name 'Release manifest contract' -Check {
    $manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'release-manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.product -ne 'codex-deepseek-worker') { throw 'Unexpected release product id.' }
    if ($manifest.product_version -ne '0.2.3-rc1') { throw 'Unexpected release version.' }
    if ([int]$manifest.runner_contract_version -ne 3 -or [int]$manifest.result_schema_version -ne 2) {
        throw 'Release contract versions are not pinned to v2.'
    }
    if (@($manifest.supported_codex_cli_versions) -notcontains '0.147.0') {
        throw 'Release manifest does not declare the verified Codex CLI version.'
    }
    if (($manifest.managed_files -join '|') -match '(?i)opencode') {
        throw 'The DeepSeek release manifest unexpectedly includes OpenCode files.'
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
    $previousPowerShell7 = $env:CODEX_DEEPSEEK_PWSH_PATH
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
        $env:CODEX_DEEPSEEK_PWSH_PATH = 'C:\Program Files\WindowsApps\pwsh.exe'
        $invalidRuntimeRejected = $false
        try { & (Join-Path $repoRoot 'scripts\Install-DeepSeekWorker.ps1') -WhatIf *> $null } catch { $invalidRuntimeRejected = $true }
        if (-not $invalidRuntimeRejected) { throw 'Installer accepted a Store/MSIX PowerShell runtime override.' }
    }
    finally {
        if ($null -eq $previousLocal) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $previousLocal }
        if ($null -eq $previousCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $previousCodexHome }
        if ($null -eq $previousWorkerRoot) { Remove-Item Env:CODEX_DEEPSEEK_WORKER_ROOT -ErrorAction SilentlyContinue } else { $env:CODEX_DEEPSEEK_WORKER_ROOT = $previousWorkerRoot }
        if ($null -eq $previousPowerShell7) { Remove-Item Env:CODEX_DEEPSEEK_PWSH_PATH -ErrorAction SilentlyContinue } else { $env:CODEX_DEEPSEEK_PWSH_PATH = $previousPowerShell7 }
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
        $installedManifest = Get-Content -LiteralPath (Join-Path $installRoot 'installed-manifest.json') -Raw | ConvertFrom-Json
        $expectedCommit = (& git -C $repoRoot rev-parse HEAD | Select-Object -First 1).Trim()
        if ($installedManifest.source_commit -ne $expectedCommit) {
            throw 'Installer did not record the source Git commit.'
        }
    }
    finally {
        if ($null -eq $previousLocal) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $previousLocal }
        if ($null -eq $previousCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $previousCodexHome }
        if ($null -eq $previousWorkerRoot) { Remove-Item Env:CODEX_DEEPSEEK_WORKER_ROOT -ErrorAction SilentlyContinue } else { $env:CODEX_DEEPSEEK_WORKER_ROOT = $previousWorkerRoot }
        Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Check -Name 'Installer transactional upgrade backup' -Check {
    $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ('dsw-upgrade-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempBase | Out-Null
    $previous = Push-WorkerTestEnvironment -BasePath $tempBase
    try {
        & (Join-Path $repoRoot 'scripts\Install-DeepSeekWorker.ps1') *> $null
        $launcher = Join-Path $env:CODEX_DEEPSEEK_WORKER_ROOT 'codex-deepseek.ps1'
        Add-Content -LiteralPath $launcher -Value '# local-upgrade-marker'
        & (Join-Path $repoRoot 'scripts\Install-DeepSeekWorker.ps1') -Force *> $null

        $installed = Get-Content -LiteralPath (Join-Path $env:CODEX_DEEPSEEK_WORKER_ROOT 'installed-manifest.json') -Raw | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace([string]$installed.backup_path)) { throw 'Upgrade did not record a rollback backup.' }
        $restoreMap = Get-Content -LiteralPath (Join-Path $installed.backup_path 'restore-map.json') -Raw | ConvertFrom-Json
        $launcherBackup = @($restoreMap | Where-Object { $_.destination -eq $launcher }) | Select-Object -First 1
        if ($null -eq $launcherBackup) { throw 'Upgrade backup does not include the previous launcher.' }
        if ((Get-Content -LiteralPath $launcherBackup.backup -Raw) -notmatch 'local-upgrade-marker') {
            throw 'Upgrade backup did not preserve the previous managed file content.'
        }
        if ((Get-Content -LiteralPath $launcher -Raw) -match 'local-upgrade-marker') {
            throw 'Upgrade did not install the staged release launcher.'
        }
    }
    finally {
        Pop-WorkerTestEnvironment -Previous $previous
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
    if ($readme -notmatch '2026-08-11') { throw 'README does not mention the verification date.' }
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

Invoke-Check -Name 'Runner doctor is strict and installed-layout based' -Check {
    $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ('dsw-doctor-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempBase | Out-Null
    $previous = Push-WorkerTestEnvironment -BasePath $tempBase
    try {
        $fakeCodex = Join-Path $tempBase 'fake-codex.ps1'
        New-FakeCodexScript -Path $fakeCodex
        $env:CODEX_DEEPSEEK_CODEX_PATH = $fakeCodex
        & (Join-Path $repoRoot 'scripts\Install-DeepSeekWorker.ps1') *> $null
        $runner = Join-Path $env:CODEX_DEEPSEEK_WORKER_ROOT 'codex-deepseek-exec.ps1'
        $doctor = & $runner -Doctor | ConvertFrom-Json
        if (-not $doctor.install_ok) { throw "Doctor reported install failure: $($doctor.manifest_errors -join '; ')" }
        if ($doctor.ready_for_api_call) { throw 'Doctor reported API readiness without a key file.' }
        if ($doctor.cli_version -ne 'codex-cli 0.147.0') { throw 'Doctor did not report the isolated fake Codex CLI version.' }
        if ($doctor.model_pinned -ne $true) { throw 'Doctor did not confirm the pinned model.' }
        if ($doctor.responses_api -ne $true) { throw 'Doctor did not confirm the Responses wire API.' }
        if (-not $doctor.powershell7_ok -or -not $doctor.powershell7_probe_ok) {
            throw "Doctor did not confirm an executable UTF-8 PowerShell 7 runtime: $($doctor.powershell7_error)"
        }
        if ([version]$doctor.powershell7_version -lt [version]'7.0') { throw 'Doctor accepted a PowerShell version below 7.0.' }
        if ([string]$doctor.powershell7_path -match '(?i)\\WindowsApps\\') { throw 'Doctor selected a Store/MSIX PowerShell path.' }
        if ([int]$doctor.runner_contract_version -ne 3 -or [int]$doctor.result_schema_version -ne 2) {
            throw 'Doctor did not report the installed v2 contracts.'
        }

        $env:CODEX_DEEPSEEK_PWSH_PATH = 'C:\Program Files\WindowsApps\pwsh.exe'
        $invalidPowerShell = & $runner -Doctor | ConvertFrom-Json
        if ($invalidPowerShell.install_ok -or $invalidPowerShell.powershell7_ok) {
            throw 'Doctor silently ignored an invalid explicit PowerShell 7 override.'
        }
        Remove-Item Env:CODEX_DEEPSEEK_PWSH_PATH -ErrorAction SilentlyContinue

        Add-Content -LiteralPath (Join-Path $env:CODEX_DEEPSEEK_WORKER_ROOT 'codex-deepseek.ps1') -Value '# tamper'
        $tampered = & $runner -Doctor | ConvertFrom-Json
        if ($tampered.install_ok -or $tampered.managed_hashes_ok) { throw 'Doctor did not detect a managed-file hash mismatch.' }

        & (Join-Path $repoRoot 'scripts\Install-DeepSeekWorker.ps1') -Force *> $null
        New-FakeCodexScript -Path $fakeCodex -Version '0.999.0'
        $unsupported = & $runner -Doctor | ConvertFrom-Json
        if ($unsupported.cli_supported -or $unsupported.install_ok) { throw 'Doctor accepted an unsupported Codex CLI version.' }
    }
    finally {
        Pop-WorkerTestEnvironment -Previous $previous
        Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
    }
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
    if ([version]$dry.powershell7_version -lt [version]'7.0' -or [string]$dry.powershell7_path -match '(?i)\\WindowsApps\\') {
        throw 'Dry-run did not select a non-Store PowerShell 7 runtime.'
    }
}

Invoke-Check -Name 'Runner rejects mode and sandbox mismatches' -Check {
    $auditRejected = $false
    try {
        & (Join-Path $repoRoot 'scripts\codex-deepseek-exec.ps1') -Workdir $repoRoot -Prompt 'x' -Mode audit -Sandbox workspace-write -DryRun *> $null
    }
    catch { $auditRejected = $true }
    if (-not $auditRejected) { throw 'Runner accepted audit with workspace-write.' }

    $implementRejected = $false
    try {
        & (Join-Path $repoRoot 'scripts\codex-deepseek-exec.ps1') -Workdir $repoRoot -Prompt 'x' -Mode implement -Sandbox read-only -DryRun *> $null
    }
    catch { $implementRejected = $true }
    if (-not $implementRejected) { throw 'Runner accepted implement with read-only.' }

    $shortQuotaRejected = $false
    try {
        & (Join-Path $repoRoot 'scripts\codex-deepseek-exec.ps1') -Workdir $repoRoot -Prompt 'x' -Mode quota-first -Sandbox workspace-write -TimeoutSeconds 900 -DryRun *> $null
    }
    catch { $shortQuotaRejected = $true }
    if (-not $shortQuotaRejected) { throw 'Runner accepted quota-first with a timeout below 1800 seconds.' }
}

Invoke-Check -Name 'Runner workspace probe uses the real sandbox contract' -Check {
    $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ('dsw-probe-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempBase | Out-Null
    $previous = Push-WorkerTestEnvironment -BasePath $tempBase
    try {
        $fakeCodex = Join-Path $tempBase 'fake-codex.ps1'
        New-FakeCodexScript -Path $fakeCodex
        $env:CODEX_DEEPSEEK_CODEX_PATH = $fakeCodex
        & (Join-Path $repoRoot 'scripts\Install-DeepSeekWorker.ps1') *> $null
        [System.IO.File]::WriteAllText((Join-Path $env:CODEX_DEEPSEEK_WORKER_ROOT 'deepseek-api-key.txt'), 'test-placeholder-not-a-real-key')

        $workdir = Join-Path $tempBase 'repo'
        New-Item -ItemType Directory -Path $workdir | Out-Null
        & git -C $workdir init -q
        & git -C $workdir config user.email 'offline-test@example.invalid'
        & git -C $workdir config user.name 'Offline Test'
        [System.IO.File]::WriteAllText((Join-Path $workdir 'README.md'), "fixture`n")
        & git -C $workdir add README.md
        & git -C $workdir commit -q -m fixture

        $runner = Join-Path $env:CODEX_DEEPSEEK_WORKER_ROOT 'codex-deepseek-exec.ps1'
        $dry = & $runner -Workdir $workdir -WorkspaceProbe -DryRun | ConvertFrom-Json
        if (-not $dry.workspace_probe -or $dry.mode -ne 'implement' -or $dry.sandbox -ne 'workspace-write' -or $dry.network) {
            throw 'Workspace probe dry-run did not pin its minimal write/no-network contract.'
        }

        $env:DSW_FAKE_FINAL_KIND = 'invalid'
        $probeOutput = & $runner -Workdir $workdir -WorkspaceProbe 2>$null
        $probeExit = $LASTEXITCODE
        $probe = $probeOutput | Select-Object -Last 1 | ConvertFrom-Json
        if ($probeExit -ne 0 -or $probe.runner_state -ne 'completed' -or -not $probe.workspace_probe_ok) {
            throw 'Workspace probe did not accept a successful create/read/delete round trip.'
        }
        if (Get-ChildItem -LiteralPath (Join-Path $workdir '.codex_tmp') -Filter 'deepseek-worker-probe-*' -ErrorAction SilentlyContinue) {
            throw 'Workspace probe left its temporary file behind.'
        }
        if (Test-Path -LiteralPath (Join-Path $workdir '.codex_tmp')) {
            throw 'Workspace probe left its newly-created temporary directory behind.'
        }

        $env:DSW_FAKE_WORKSPACE_PROBE_FAIL = '1'
        $failedOutput = & $runner -Workdir $workdir -WorkspaceProbe 2>$null
        $failedExit = $LASTEXITCODE
        $failed = $failedOutput | Select-Object -Last 1 | ConvertFrom-Json
        if ($failedExit -eq 0 -or $failed.runner_state -ne 'failed' -or $failed.workspace_probe_ok) {
            throw 'Workspace probe accepted a failed sandbox write command.'
        }
    }
    finally {
        Pop-WorkerTestEnvironment -Previous $previous
        Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Check -Name 'Runner validates final contract and emits bounded evidence' -Check {
    $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ('dsw-runner-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempBase | Out-Null
    $previous = Push-WorkerTestEnvironment -BasePath $tempBase
    $previousFakeKind = $env:DSW_FAKE_FINAL_KIND
    $previousRuntimeCapture = $env:DSW_FAKE_RUNTIME_CAPTURE
    $previousPromptCapture = $env:DSW_FAKE_PROMPT_CAPTURE
    $previousGitMutation = $env:DSW_FAKE_GIT_MUTATION
    try {
        $fakeCodex = Join-Path $tempBase 'fake-codex.ps1'
        New-FakeCodexScript -Path $fakeCodex
        $env:CODEX_DEEPSEEK_CODEX_PATH = $fakeCodex
        & (Join-Path $repoRoot 'scripts\Install-DeepSeekWorker.ps1') *> $null
        [System.IO.File]::WriteAllText((Join-Path $env:CODEX_DEEPSEEK_WORKER_ROOT 'deepseek-api-key.txt'), 'test-placeholder-not-a-real-key')

        $workdir = Join-Path $tempBase 'repo'
        New-Item -ItemType Directory -Path $workdir | Out-Null
        & git -C $workdir init -q
        & git -C $workdir config user.email 'offline-test@example.invalid'
        & git -C $workdir config user.name 'Offline Test'
        [System.IO.File]::WriteAllText((Join-Path $workdir 'README.md'), "fixture`n")
        & git -C $workdir add README.md
        & git -C $workdir commit -q -m fixture

        $runner = Join-Path $env:CODEX_DEEPSEEK_WORKER_ROOT 'codex-deepseek-exec.ps1'
        $resultPath = Join-Path $workdir 'published-result.json'
        $env:DSW_FAKE_FINAL_KIND = 'invalid'
        $invalidOutput = & $runner -Workdir $workdir -Prompt 'fake invalid' -Mode audit -ResultFile $resultPath 2>$null
        $invalidExit = $LASTEXITCODE
        $invalid = $invalidOutput | Select-Object -Last 1 | ConvertFrom-Json
        if ($invalidExit -eq 0 -or $invalid.runner_state -ne 'failed' -or $invalid.final_schema_valid) {
            throw 'Runner did not fail a malformed worker final.'
        }
        if (Test-Path -LiteralPath $resultPath) { throw 'Runner published ResultFile for an invalid final.' }

        $env:DSW_FAKE_FINAL_KIND = 'valid'
        $runtimeCapturePath = Join-Path $tempBase 'runtime-capture.json'
        $promptCapturePath = Join-Path $tempBase 'prompt-capture.txt'
        $descendantPidPath = Join-Path $tempBase 'descendant.pid'
        $descendantLatePath = Join-Path $tempBase 'descendant-late.txt'
        $env:DSW_FAKE_RUNTIME_CAPTURE = $runtimeCapturePath
        $env:DSW_FAKE_PROMPT_CAPTURE = $promptCapturePath
        $env:DSW_FAKE_DESCENDANT_PID = $descendantPidPath
        $env:DSW_FAKE_DESCENDANT_LATE_FILE = $descendantLatePath
        $pathBefore = $env:PATH
        $validOutput = & $runner -Workdir $workdir -Prompt 'fake valid' -Mode audit -ResultFile $resultPath 2>$null
        $validExit = $LASTEXITCODE
        $valid = $validOutput | Select-Object -Last 1 | ConvertFrom-Json
        if ($validExit -ne 0 -or $valid.runner_state -ne 'completed' -or -not $valid.final_schema_valid) {
            throw 'Runner rejected a valid worker final.'
        }
        if ($valid.command_total -ne 1 -or $valid.command_failed -ne 0) { throw 'Runner command evidence counts are incorrect.' }
        if ($valid.usage.uncached_input_tokens -ne 20) { throw 'Runner usage evidence is incorrect.' }
        if (-not $valid.prompt_deleted) { throw 'Runner did not confirm prompt deletion.' }
        $descendantPid = [int](Get-Content -LiteralPath $descendantPidPath -Raw)
        Start-Sleep -Seconds 4
        if (Get-Process -Id $descendantPid -ErrorAction SilentlyContinue) { throw 'Runner left a descendant process alive after completion.' }
        if (Test-Path -LiteralPath $descendantLatePath) { throw 'Runner descendant escaped the Windows Job Object.' }
        Remove-Item Env:DSW_FAKE_DESCENDANT_PID -ErrorAction SilentlyContinue
        Remove-Item Env:DSW_FAKE_DESCENDANT_LATE_FILE -ErrorAction SilentlyContinue
        $runtimeCapture = Get-Content -LiteralPath $runtimeCapturePath -Raw | ConvertFrom-Json
        if ([version]$runtimeCapture.version -lt [version]'7.0') { throw 'Fake Codex did not run under PowerShell 7.' }
        if ([System.IO.Path]::GetFullPath($runtimeCapture.path_first) -ne [System.IO.Path]::GetFullPath($runtimeCapture.pshome)) { throw 'PowerShell 7 directory was not first in the child PATH.' }
        if ($env:PATH -ne $pathBefore) { throw 'Runner did not restore the parent PATH.' }
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw 'Runner did not atomically publish a valid ResultFile.' }
        $capturedPrompt = Get-Content -LiteralPath $promptCapturePath -Raw
        if ($capturedPrompt -notmatch 'Do not stage, commit, push' -or $capturedPrompt -notmatch 'Do not hide a failing exit code') {
            throw 'Runner did not inject the Git ownership and exit-code rules.'
        }

        $env:DSW_FAKE_FINAL_KIND = 'prefix'
        $prefixOutput = & $runner -Workdir $workdir -Prompt 'fake prefixed final' -Mode audit -ResultFile $resultPath 2>$null
        $prefix = $prefixOutput | Select-Object -Last 1 | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $prefix.final_parse_mode -ne 'prefix_recovered' -or -not $prefix.final_schema_valid) {
            throw 'Runner did not recover a single short prefix before valid JSON.'
        }
        Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json | Out-Null
        if ((Get-Content -LiteralPath $resultPath -Raw).TrimStart().StartsWith('Brief')) {
            throw 'Runner published wrapper prose instead of normalized JSON.'
        }
        $rawPrefixFinal = Get-Content -LiteralPath (Join-Path $prefix.artifact_path 'final.json') -Raw
        if (-not $rawPrefixFinal.TrimStart().StartsWith('Brief')) {
            throw 'Runner did not preserve the original prefixed final artifact.'
        }

        $partialResultPath = Join-Path $workdir 'partial-result.json'
        $env:DSW_FAKE_FINAL_KIND = 'prefix-partial'
        $partialOutput = & $runner -Workdir $workdir -Prompt 'fake prefixed partial' -Mode audit -ResultFile $partialResultPath 2>$null
        $partial = $partialOutput | Select-Object -Last 1 | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $partial.runner_state -ne 'completed' -or $partial.worker_claim -ne 'partial' -or -not $partial.final_schema_valid -or $partial.final_parse_mode -ne 'prefix_recovered') {
            throw 'Runner did not preserve a valid partial claim recovered from a short prefix.'
        }
        if (Test-Path -LiteralPath $partialResultPath) { throw 'Runner published a partial claim as a completed ResultFile.' }

        foreach ($invalidKind in @('multiple', 'json-prefix', 'duplicate-field', 'trailing', 'extra-field', 'non-string-array', 'oversized')) {
            $env:DSW_FAKE_FINAL_KIND = $invalidKind
            $rejectedOutput = & $runner -Workdir $workdir -Prompt "fake $invalidKind" -Mode audit 2>$null
            $rejected = $rejectedOutput | Select-Object -Last 1 | ConvertFrom-Json
            if ($LASTEXITCODE -eq 0 -or $rejected.runner_state -ne 'failed' -or $rejected.final_schema_valid) {
                throw "Runner accepted invalid final kind: $invalidKind"
            }
        }

        [System.IO.File]::WriteAllText((Join-Path $workdir 'staged-baseline.txt'), 'staged baseline', [System.Text.UTF8Encoding]::new($false))
        & git -C $workdir add staged-baseline.txt
        $env:DSW_FAKE_FINAL_KIND = 'valid'
        $env:DSW_FAKE_GIT_MUTATION = 'worktree'
        $unstagedOutput = & $runner -Workdir $workdir -Prompt 'fake unstaged mutation with staged baseline' -Mode implement -Sandbox workspace-write 2>$null
        $unstagedResult = $unstagedOutput | Select-Object -Last 1 | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $unstagedResult.runner_state -ne 'completed' -or $unstagedResult.git_index_changed) {
            throw 'Runner falsely reported a change to a pre-existing staged baseline.'
        }
        Remove-Item -LiteralPath (Join-Path $workdir 'worker-index-change.txt') -Force

        $env:DSW_FAKE_GIT_MUTATION = 'index'
        $indexOutput = & $runner -Workdir $workdir -Prompt 'fake index mutation' -Mode implement -Sandbox workspace-write 2>$null
        $indexResult = $indexOutput | Select-Object -Last 1 | ConvertFrom-Json
        if ($LASTEXITCODE -eq 0 -or $indexResult.runner_state -ne 'failed' -or -not $indexResult.git_index_changed) {
            throw 'Runner did not reject a Worker change to the Git index.'
        }
        & git -C $workdir reset -q HEAD
        Remove-Item -LiteralPath (Join-Path $workdir 'worker-index-change.txt') -Force
        Remove-Item Env:DSW_FAKE_GIT_MUTATION -ErrorAction SilentlyContinue
    }
    finally {
        if ($null -eq $previousFakeKind) { Remove-Item Env:DSW_FAKE_FINAL_KIND -ErrorAction SilentlyContinue } else { $env:DSW_FAKE_FINAL_KIND = $previousFakeKind }
        if ($null -eq $previousRuntimeCapture) { Remove-Item Env:DSW_FAKE_RUNTIME_CAPTURE -ErrorAction SilentlyContinue } else { $env:DSW_FAKE_RUNTIME_CAPTURE = $previousRuntimeCapture }
        if ($null -eq $previousPromptCapture) { Remove-Item Env:DSW_FAKE_PROMPT_CAPTURE -ErrorAction SilentlyContinue } else { $env:DSW_FAKE_PROMPT_CAPTURE = $previousPromptCapture }
        if ($null -eq $previousGitMutation) { Remove-Item Env:DSW_FAKE_GIT_MUTATION -ErrorAction SilentlyContinue } else { $env:DSW_FAKE_GIT_MUTATION = $previousGitMutation }
        Pop-WorkerTestEnvironment -Previous $previous
        Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Check -Name 'Runner uses pinned shared-home profile' -Check {
    $runnerText = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts\codex-deepseek-exec.ps1') -Raw
    $launcherText = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts\codex-deepseek.ps1') -Raw
    if ($runnerText -match '--ignore-user-config') {
        throw 'Runner still uses --ignore-user-config, which breaks workspace-write in the verified CLI.'
    }
    if ($runnerText -match 'AllowConcurrentSameWorkspace') {
        throw 'Runner still exposes a same-worktree coordination bypass.'
    }
    if ($runnerText -match 'Get-Command powershell\.exe' -or $runnerText -match 'Start-Process\s+-FilePath\s+[^\r\n]*powershell\.exe') {
        throw 'Runner still launches its child through Windows PowerShell 5.1.'
    }
    if ($runnerText -notmatch 'Time budget: hard deadline' -or $runnerText -notmatch 'unverified_partial_changes') {
        throw 'Runner is missing the bounded quota-first finalization or partial-change contract.'
    }
    if ($launcherText -notmatch "'--profile',\s*'deepseek-worker'" -or
        $launcherText -notmatch 'mcp_servers\.node_repl\.enabled=false' -or
        $launcherText -notmatch 'mcp_servers\.openaiDeveloperDocs\.enabled=false' -or
        $launcherText -notmatch '\$configCandidates' -or
        $launcherText -notmatch '\$mcpNames') {
        throw 'Launcher does not pin the profile and MCP disable boundary.'
    }
}

Invoke-Check -Name 'Runner preserves timeout state and partial evidence' -Check {
    $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ('dsw-timeout-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempBase | Out-Null
    $previous = Push-WorkerTestEnvironment -BasePath $tempBase
    $previousFakeKind = $env:DSW_FAKE_FINAL_KIND
    try {
        $fakeCodex = Join-Path $tempBase 'fake-codex.ps1'
        New-FakeCodexScript -Path $fakeCodex
        $env:CODEX_DEEPSEEK_CODEX_PATH = $fakeCodex
        & (Join-Path $repoRoot 'scripts\Install-DeepSeekWorker.ps1') *> $null
        [System.IO.File]::WriteAllText((Join-Path $env:CODEX_DEEPSEEK_WORKER_ROOT 'deepseek-api-key.txt'), 'test-placeholder-not-a-real-key')

        $workdir = Join-Path $tempBase 'repo'
        New-Item -ItemType Directory -Path $workdir | Out-Null
        & git -C $workdir init -q
        & git -C $workdir config user.email 'offline-test@example.invalid'
        & git -C $workdir config user.name 'Offline Test'
        [System.IO.File]::WriteAllText((Join-Path $workdir 'README.md'), "fixture`n")
        & git -C $workdir add README.md
        & git -C $workdir commit -q -m fixture

        $env:DSW_FAKE_FINAL_KIND = 'timeout'
        $runner = Join-Path $env:CODEX_DEEPSEEK_WORKER_ROOT 'codex-deepseek-exec.ps1'
        $resultPath = Join-Path $workdir 'published-result.json'
        $timeoutOutput = & $runner -Workdir $workdir -Prompt 'write then wait' -Mode implement -Sandbox workspace-write -TimeoutSeconds 1 -ResultFile $resultPath 2>$null
        $timeoutExit = $LASTEXITCODE
        $timeout = $timeoutOutput | Select-Object -Last 1 | ConvertFrom-Json
        if ($timeoutExit -ne 124 -or $timeout.runner_state -ne 'timed_out') { throw 'Runner did not preserve timed_out/124.' }
        if (-not $timeout.unverified_partial_changes) { throw 'Runner did not mark timed-out workspace changes as unverified.' }
        if ($timeout.final_schema_valid -or (Test-Path -LiteralPath $resultPath)) {
            throw 'Runner published or trusted a timed-out partial result.'
        }
        if (-not $timeout.prompt_deleted) { throw 'Runner did not remove the prompt after timeout.' }
        $status = Get-Content -LiteralPath (Join-Path $timeout.artifact_path 'status.json') -Raw | ConvertFrom-Json
        if ($status.runner_state -ne 'timed_out' -or -not $status.unverified_partial_changes) {
            throw 'Persistent status lost timeout recovery evidence.'
        }
        if (@($status.changed_files) -notcontains 'worker-中文-partial.txt') { throw 'Timeout evidence omitted the untracked partial file.' }
    }
    finally {
        if ($null -eq $previousFakeKind) { Remove-Item Env:DSW_FAKE_FINAL_KIND -ErrorAction SilentlyContinue } else { $env:DSW_FAKE_FINAL_KIND = $previousFakeKind }
        Pop-WorkerTestEnvironment -Previous $previous
        Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
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
