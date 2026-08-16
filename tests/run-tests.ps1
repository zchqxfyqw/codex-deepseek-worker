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
    $names = @(
        'LOCALAPPDATA',
        'APPDATA',
        'CODEX_HOME',
        'CODEX_DEEPSEEK_WORKER_ROOT',
        'CODEX_DEEPSEEK_CODEX_PATH',
        'CODEX_DEEPSEEK_KEY_FILE',
        'CODEX_DEEPSEEK_PWSH_PATH',
        'DSW_FAKE_WORKSPACE_PROBE_FAIL',
        'DSW_FAKE_DESCENDANT_PID',
        'DSW_FAKE_DESCENDANT_LATE_FILE',
        'DSW_FAKE_FINAL_KIND',
        'DSW_FAKE_RUNTIME_CAPTURE',
        'DSW_FAKE_PROMPT_CAPTURE',
        'DSW_FAKE_GIT_MUTATION',
        'DSW_FAKE_TOUCH_RELATIVE',
        'DSW_FAKE_COMMAND_COUNT',
        'DSW_FAKE_EVENTS_KIND',
        'DSW_FAKE_PROBE_REQUIRE_ABSENT'
    )
    foreach ($name in $names) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ($name.StartsWith('DSW_FAKE_', [System.StringComparison]::Ordinal)) {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
    }
    $env:LOCALAPPDATA = Join-Path $BasePath 'localappdata'
    $env:APPDATA = Join-Path $BasePath 'appdata'
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
$probePathMatch = [regex]::Match($stdinPrompt, '\.deepseek-worker-probe-[0-9a-f]+\.txt')
if ($probeTokenMatch.Success -and $probePathMatch.Success -and -not [string]::IsNullOrWhiteSpace($workdir)) {
    $probeToken = $probeTokenMatch.Value
    $probeRelativePath = $probePathMatch.Value
    $probePath = Join-Path $workdir $probeRelativePath
    $probeExitCode = 0
    $probeOutput = $probeToken
    if ($env:DSW_FAKE_PROBE_REQUIRE_ABSENT -eq '1' -and (Test-Path -LiteralPath $probePath)) {
        $probeExitCode = 1
        $probeOutput = 'Runner pre-created the probe file outside the sandbox.'
    }
    elseif ($env:DSW_FAKE_WORKSPACE_PROBE_FAIL -eq '1') {
        $probeOutput = 'Access denied'
        if ($stdinPrompt -match '\$ErrorActionPreference\s*=\s*''Stop''') {
            $probeExitCode = 1
        }
        else {
            $probeOutput = "$probeOutput`n$probeToken"
        }
    }
    else {
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
    if (@('index', 'worktree', 'head', 'branch') -contains $env:DSW_FAKE_GIT_MUTATION -and -not [string]::IsNullOrWhiteSpace($workdir)) {
        [System.IO.File]::WriteAllText((Join-Path $workdir 'worker-index-change.txt'), 'index changed', [System.Text.UTF8Encoding]::new($false))
        if ($env:DSW_FAKE_GIT_MUTATION -eq 'index') { & git -C $workdir add worker-index-change.txt }
        if ($env:DSW_FAKE_GIT_MUTATION -eq 'head') {
            & git -C $workdir add worker-index-change.txt
            & git -C $workdir commit -q -m worker-head-change
        }
        if ($env:DSW_FAKE_GIT_MUTATION -eq 'branch') {
            Remove-Item -LiteralPath (Join-Path $workdir 'worker-index-change.txt') -Force
            & git -C $workdir switch -q -c worker-branch-change
        }
}
if (-not [string]::IsNullOrWhiteSpace($env:DSW_FAKE_TOUCH_RELATIVE) -and -not [string]::IsNullOrWhiteSpace($workdir)) {
    Add-Content -LiteralPath (Join-Path $workdir $env:DSW_FAKE_TOUCH_RELATIVE) -Value 'worker edit'
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
$fence = ([char]96).ToString() * 3
$summary = switch ($env:DSW_FAKE_FINAL_KIND) {
    'missing' { $null }
    'markdown' { "# Completed`n`n- Tests passed.`n- No publish was attempted." }
    'fenced' { "${fence}json`n{`"status`":`"completed`"}`n$fence" }
    'invalid' { '{}' }
    'oversized' { 'x' * 70000 }
    default { 'Fake worker completed.' }
}
if ($null -ne $summary) {
    [System.IO.File]::WriteAllText($finalPath, $summary, [System.Text.UTF8Encoding]::new($false))
}
if ($env:DSW_FAKE_EVENTS_KIND -eq 'empty') { exit 0 }
if ($env:DSW_FAKE_EVENTS_KIND -eq 'malformed') {
    Write-Output 'not-json'
    exit 0
}
$commandCount = 1
if (-not [string]::IsNullOrWhiteSpace($env:DSW_FAKE_COMMAND_COUNT)) {
    $commandCount = [int]$env:DSW_FAKE_COMMAND_COUNT
}
for ($i = 1; $i -le $commandCount; $i++) {
    $commandExit = if ($i % 4 -eq 0) { 9 } else { 0 }
    [ordered]@{
        type = 'item.completed'
        item = [ordered]@{
            type = 'command_execution'
            command = "fake-check-$i"
            exit_code = $commandExit
            status = 'completed'
        }
    } | ConvertTo-Json -Compress -Depth 5 | Write-Output
}
Write-Output '{"type":"turn.completed","usage":{"input_tokens":120,"cached_input_tokens":100,"output_tokens":30,"reasoning_output_tokens":5}}'
if ($env:DSW_FAKE_FINAL_KIND -eq 'nonzero') { exit 7 }
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
    if ($skillText -notmatch 'completed.*not that the task passed acceptance') {
        throw 'SKILL.md does not distinguish runner completion from task acceptance.'
    }
    if ($skillText -notmatch 'never repair ACLs') {
        throw 'SKILL.md does not forbid ACL repair after a pre-run access failure.'
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

Invoke-Check -Name 'Release manifest contract' -Check {
    $manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'release-manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.product -ne 'codex-deepseek-worker') { throw 'Unexpected release product id.' }
    if ($manifest.product_version -ne '0.3.1-rc1') { throw 'Unexpected release version.' }
    if ([int]$manifest.runner_contract_version -ne 4) {
        throw 'Release runner contract is not pinned to v4.'
    }
    if ($manifest.PSObject.Properties.Name -contains 'result_schema_version') {
        throw 'Release manifest still exposes the removed model-result schema.'
    }
    if (($manifest.managed_files -join '|') -match 'delegation-result\.schema\.json') {
        throw 'Release manifest still manages the removed model-result schema.'
    }
    if (@($manifest.managed_files) -notcontains 'scripts/codex-deepseek-legacy-shim.ps1') {
        throw 'Release manifest does not include the legacy compatibility shim source.'
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
    $previousAppData = $env:APPDATA
    $previousCodexHome = $env:CODEX_HOME
    $previousWorkerRoot = $env:CODEX_DEEPSEEK_WORKER_ROOT
    $previousPowerShell7 = $env:CODEX_DEEPSEEK_PWSH_PATH
    try {
        $env:LOCALAPPDATA = Join-Path $tempBase 'localappdata'
        $env:APPDATA = Join-Path $tempBase 'appdata'
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
        if ($null -eq $previousAppData) { Remove-Item Env:APPDATA -ErrorAction SilentlyContinue } else { $env:APPDATA = $previousAppData }
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
    $previousAppData = $env:APPDATA
    $previousCodexHome = $env:CODEX_HOME
    $previousWorkerRoot = $env:CODEX_DEEPSEEK_WORKER_ROOT
    try {
        $env:LOCALAPPDATA = Join-Path $tempBase 'localappdata'
        $env:APPDATA = Join-Path $tempBase 'appdata'
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
            (Join-Path $installRoot 'models.json'),
            (Join-Path $tempBase 'codexhome\deepseek-worker.config.toml'),
            (Join-Path $skillRoot 'SKILL.md'),
            (Join-Path $skillRoot 'agents\openai.yaml')
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
        if ($null -eq $previousAppData) { Remove-Item Env:APPDATA -ErrorAction SilentlyContinue } else { $env:APPDATA = $previousAppData }
        if ($null -eq $previousCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $previousCodexHome }
        if ($null -eq $previousWorkerRoot) { Remove-Item Env:CODEX_DEEPSEEK_WORKER_ROOT -ErrorAction SilentlyContinue } else { $env:CODEX_DEEPSEEK_WORKER_ROOT = $previousWorkerRoot }
        Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Check -Name 'Installer trusts packaged source commit outside Git' -Check {
    $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ('dsw-package-install-' + [Guid]::NewGuid().ToString('N'))
    $packageRoot = Join-Path $tempBase 'outer-repo\release'
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    $previous = Push-WorkerTestEnvironment -BasePath (Join-Path $tempBase 'target')
    try {
        $outerRoot = Split-Path -Parent $packageRoot
        & git -C $outerRoot init -q
        & git -C $outerRoot config user.email 'offline-test@example.invalid'
        & git -C $outerRoot config user.name 'Offline Test'
        [System.IO.File]::WriteAllText((Join-Path $outerRoot 'outer.txt'), 'unrelated repository')
        & git -C $outerRoot add outer.txt
        & git -C $outerRoot commit -q -m outer-fixture
        foreach ($relativePath in @('scripts', 'config', 'skill', 'release-manifest.json')) {
            Copy-Item -LiteralPath (Join-Path $repoRoot $relativePath) -Destination (Join-Path $packageRoot $relativePath) -Recurse
        }
        $packageManifestPath = Join-Path $packageRoot 'release-manifest.json'
        $packageManifest = Get-Content -LiteralPath $packageManifestPath -Raw | ConvertFrom-Json
        $packageCommit = '0123456789abcdef0123456789abcdef01234567'
        $packageManifest | Add-Member -NotePropertyName source_commit -NotePropertyValue $packageCommit -Force
        [System.IO.File]::WriteAllText($packageManifestPath, ($packageManifest | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))

        & (Join-Path $packageRoot 'scripts\Install-DeepSeekWorker.ps1') *> $null
        $installed = Get-Content -LiteralPath (Join-Path $env:CODEX_DEEPSEEK_WORKER_ROOT 'installed-manifest.json') -Raw | ConvertFrom-Json
        if ($installed.source_commit -ne $packageCommit) {
            throw 'Installer replaced the packaged source commit with an enclosing Git repository commit.'
        }
    }
    finally {
        Pop-WorkerTestEnvironment -Previous $previous
        Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Check -Name 'Installer preserves an unrecognized npm script' -Check {
    $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ('dsw-custom-npm-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempBase | Out-Null
    $previous = Push-WorkerTestEnvironment -BasePath $tempBase
    try {
        $legacyRunner = Join-Path $env:APPDATA 'npm\codex-deepseek-exec.ps1'
        New-Item -ItemType Directory -Path (Split-Path -Parent $legacyRunner) -Force | Out-Null
        $customText = 'Write-Output custom-user-script'
        [System.IO.File]::WriteAllText($legacyRunner, $customText)
        & (Join-Path $repoRoot 'scripts\Install-DeepSeekWorker.ps1') *> $null
        if ((Get-Content -LiteralPath $legacyRunner -Raw) -ne $customText) {
            throw 'Installer overwrote an unrecognized npm script.'
        }
        $installed = Get-Content -LiteralPath (Join-Path $env:CODEX_DEEPSEEK_WORKER_ROOT 'installed-manifest.json') -Raw | ConvertFrom-Json
        if (@($installed.installed_files.path) -contains $legacyRunner) {
            throw 'Installer claimed an unrecognized npm script as managed.'
        }
    }
    finally {
        Pop-WorkerTestEnvironment -Previous $previous
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
        $legacyRunner = Join-Path $env:APPDATA 'npm\codex-deepseek-exec.ps1'
        $obsoleteInstallSchema = Join-Path $env:CODEX_DEEPSEEK_WORKER_ROOT 'assets\delegation-result.schema.json'
        $obsoleteSkillSchema = Join-Path $env:CODEX_HOME 'skills\deepseek-worker\assets\delegation-result.schema.json'
        $keyPath = Join-Path $env:CODEX_DEEPSEEK_WORKER_ROOT 'deepseek-api-key.txt'
        $runMarker = Join-Path $env:CODEX_DEEPSEEK_WORKER_ROOT 'runs\upgrade-preserve.marker'
        Add-Content -LiteralPath $launcher -Value '# local-upgrade-marker'
        New-Item -ItemType Directory -Path (Split-Path -Parent $legacyRunner) -Force | Out-Null
        [System.IO.File]::WriteAllText($legacyRunner, 'CodexDeepSeekWorkerLocks codex-deepseek.ps1 delegation-result.schema.json --output-schema')
        New-Item -ItemType Directory -Path (Split-Path -Parent $obsoleteInstallSchema) -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path -Parent $obsoleteSkillSchema) -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path -Parent $runMarker) -Force | Out-Null
        [System.IO.File]::WriteAllText($obsoleteInstallSchema, '{"legacy":true}')
        [System.IO.File]::WriteAllText($obsoleteSkillSchema, '{"legacy":true}')
        [System.IO.File]::WriteAllText($keyPath, 'test-placeholder-not-a-real-key')
        [System.IO.File]::WriteAllText($runMarker, 'preserve-run-history')
        $keyHashBefore = (Get-FileHash -LiteralPath $keyPath -Algorithm SHA256).Hash
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
        $legacyBackup = @($restoreMap | Where-Object { $_.destination -eq $legacyRunner }) | Select-Object -First 1
        if ($null -eq $legacyBackup) { throw 'Upgrade backup omitted the recognized legacy npm runner.' }
        $legacyShimText = Get-Content -LiteralPath $legacyRunner -Raw
        if ($legacyShimText -notmatch 'CodexDeepSeekWorker' -or $legacyShimText -match 'delegation-result\.schema\.json') {
            throw 'Upgrade did not replace the legacy npm runner with the compatibility shim.'
        }
        $installedLegacy = @($installed.installed_files | Where-Object { $_.path -eq $legacyRunner }) | Select-Object -First 1
        if ($null -eq $installedLegacy) { throw 'Installed manifest omitted the managed legacy compatibility entry.' }
        if ((Test-Path -LiteralPath $obsoleteInstallSchema) -or (Test-Path -LiteralPath $obsoleteSkillSchema)) {
            throw 'Upgrade did not remove the obsolete model-result schema.'
        }
        foreach ($obsoletePath in @($obsoleteInstallSchema, $obsoleteSkillSchema)) {
            if (-not (@($restoreMap.destination) -contains $obsoletePath)) {
                throw "Upgrade backup omitted retired managed file: $obsoletePath"
            }
        }
        if ((Get-FileHash -LiteralPath $keyPath -Algorithm SHA256).Hash -ne $keyHashBefore) {
            throw 'Upgrade changed the existing key file.'
        }
        if ((Get-Content -LiteralPath $runMarker -Raw) -ne 'preserve-run-history') {
            throw 'Upgrade changed existing run history.'
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
    $previousAppData = $env:APPDATA
    $previousCodexHome = $env:CODEX_HOME
    $previousWorkerRoot = $env:CODEX_DEEPSEEK_WORKER_ROOT
    try {
        $env:LOCALAPPDATA = Join-Path $tempBase 'localappdata'
        $env:APPDATA = Join-Path $tempBase 'appdata'
        $env:CODEX_HOME = Join-Path $tempBase 'codexhome'
        $env:CODEX_DEEPSEEK_WORKER_ROOT = Join-Path $tempBase 'workerroot'
        $legacyRunner = Join-Path $env:APPDATA 'npm\codex-deepseek-exec.ps1'
        New-Item -ItemType Directory -Path (Split-Path -Parent $legacyRunner) -Force | Out-Null
        [System.IO.File]::WriteAllText($legacyRunner, 'CodexDeepSeekWorkerLocks codex-deepseek.ps1 delegation-result.schema.json --output-schema')
        & (Join-Path $repoRoot 'scripts\Install-DeepSeekWorker.ps1') -Force *> $null

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
        if (Test-Path -LiteralPath $legacyRunner -PathType Leaf) {
            throw 'Default uninstall did not remove the managed legacy compatibility entry.'
        }
    }
    finally {
        if ($null -eq $previousLocal) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $previousLocal }
        if ($null -eq $previousAppData) { Remove-Item Env:APPDATA -ErrorAction SilentlyContinue } else { $env:APPDATA = $previousAppData }
        if ($null -eq $previousCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $previousCodexHome }
        if ($null -eq $previousWorkerRoot) { Remove-Item Env:CODEX_DEEPSEEK_WORKER_ROOT -ErrorAction SilentlyContinue } else { $env:CODEX_DEEPSEEK_WORKER_ROOT = $previousWorkerRoot }
        Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Check -Name 'Skill package whitelist' -Check {
    $skillRoot = Join-Path $repoRoot 'skill\deepseek-worker'
    $expected = @(
        'SKILL.md',
        'agents\openai.yaml'
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
    if ($configText -notmatch '(?ms)^\[windows\]\s*\r?\nsandbox\s*=\s*"elevated"') {
        throw 'Profile template does not use the Windows elevated sandbox required for workspace writes.'
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
        if ([int]$doctor.runner_contract_version -ne 4) {
            throw 'Doctor did not report the installed v4 runner contract.'
        }
        if ($doctor.PSObject.Properties.Name -contains 'result_schema_version') {
            throw 'Doctor still exposes the removed model-result schema.'
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
        if ($unsupported.cli_supported -or -not $unsupported.install_ok -or [string]::IsNullOrWhiteSpace([string]$unsupported.cli_version_warning)) {
            throw 'Doctor did not report an unverified CLI version as a non-blocking warning.'
        }
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

    $emptyRepo = Join-Path ([System.IO.Path]::GetTempPath()) ('dsw-empty-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $emptyRepo | Out-Null
    try {
        & git -C $emptyRepo init -q
        & git -C $emptyRepo config user.email 'offline-test@example.invalid'
        & git -C $emptyRepo config user.name 'Offline Test'
        & git -C $emptyRepo commit --allow-empty -q -m fixture
        $emptyDry = & (Join-Path $repoRoot 'scripts\codex-deepseek-exec.ps1') -Workdir $emptyRepo -Prompt 'x' -Mode audit -DryRun | ConvertFrom-Json
        if (-not $emptyDry.dry_run) { throw 'Runner rejected a clean repository with an empty index.' }
    }
    finally {
        Remove-Item -LiteralPath $emptyRepo -Recurse -Force -ErrorAction SilentlyContinue
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

    $quota = & (Join-Path $repoRoot 'scripts\codex-deepseek-exec.ps1') -Workdir $repoRoot -Prompt 'x' -Mode quota-first -Sandbox workspace-write -TimeoutSeconds 900 -DryRun | ConvertFrom-Json
    if ($quota.mode -ne 'quota-first' -or $quota.timeout_seconds -ne 900) {
        throw 'Runner did not preserve the caller-selected quota-first timeout.'
    }

    $insideResultRejected = $false
    try {
        & (Join-Path $repoRoot 'scripts\codex-deepseek-exec.ps1') -Workdir $repoRoot -Prompt 'x' -Mode audit -ResultFile (Join-Path $repoRoot '.runner-envelope.json') -DryRun *> $null
    }
    catch { $insideResultRejected = $true }
    if (-not $insideResultRejected) { throw 'Runner allowed ResultFile inside the coordinated worktree.' }

    $insideRunRootRejected = $false
    try {
        & (Join-Path $repoRoot 'scripts\codex-deepseek-exec.ps1') -Workdir $repoRoot -Prompt 'x' -Mode audit -RunRoot (Join-Path $repoRoot '.runner-artifacts') *> $null
    }
    catch { $insideRunRootRejected = $true }
    if (-not $insideRunRootRejected) { throw 'Runner allowed RunRoot inside the coordinated worktree.' }
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
        $env:DSW_FAKE_PROBE_REQUIRE_ABSENT = '1'
        $probeOutput = & $runner -Workdir $workdir -WorkspaceProbe 2>$null
        $probeExit = $LASTEXITCODE
        $probe = $probeOutput | Select-Object -Last 1 | ConvertFrom-Json
        if ($probeExit -ne 0 -or $probe.runner_state -ne 'completed' -or -not $probe.workspace_probe_ok) {
            $probeEvents = Get-Content -LiteralPath $probe.events_path -Raw
            throw "Workspace probe did not accept a successful create/read/delete round trip: $($probe | ConvertTo-Json -Depth 5 -Compress); events=$probeEvents"
        }
        if (Get-ChildItem -LiteralPath $workdir -Filter '.deepseek-worker-probe-*' -ErrorAction SilentlyContinue) {
            throw 'Workspace probe left its temporary file behind.'
        }
        Remove-Item Env:DSW_FAKE_PROBE_REQUIRE_ABSENT -ErrorAction SilentlyContinue

        $existingProbeDirectory = Join-Path $workdir '.codex_tmp'
        New-Item -ItemType Directory -Path $existingProbeDirectory | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $existingProbeDirectory 'keep.txt'), 'keep')
        $existingOutput = & $runner -Workdir $workdir -WorkspaceProbe 2>$null
        $existing = $existingOutput | Select-Object -Last 1 | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $existing.runner_state -ne 'completed' -or -not $existing.workspace_probe_ok) {
            throw 'Workspace probe failed when its temporary directory already existed.'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $existingProbeDirectory 'keep.txt') -PathType Leaf)) {
            throw 'Workspace probe removed an unrelated pre-existing temporary directory.'
        }
        Remove-Item -LiteralPath $existingProbeDirectory -Recurse -Force

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

Invoke-Check -Name 'Runner treats model output as a non-authoritative summary' -Check {
    $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ('dsw-runner-' + [Guid]::NewGuid().ToString('N'))
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
        $resultPath = Join-Path $tempBase 'free-form-result.json'
        $env:DSW_FAKE_FINAL_KIND = 'free-form'
        $env:DSW_FAKE_COMMAND_COUNT = '100'
        $runtimeCapturePath = Join-Path $tempBase 'runtime-capture.json'
        $promptCapturePath = Join-Path $tempBase 'prompt-capture.txt'
        $descendantPidPath = Join-Path $tempBase 'descendant.pid'
        $descendantLatePath = Join-Path $tempBase 'descendant-late.txt'
        $env:DSW_FAKE_RUNTIME_CAPTURE = $runtimeCapturePath
        $env:DSW_FAKE_PROMPT_CAPTURE = $promptCapturePath
        $env:DSW_FAKE_DESCENDANT_PID = $descendantPidPath
        $env:DSW_FAKE_DESCENDANT_LATE_FILE = $descendantLatePath
        $pathBefore = $env:PATH
        $freeFormOutput = & $runner -Workdir $workdir -Prompt 'fake free-form summary' -Mode implement -Sandbox workspace-write -ResultFile $resultPath 2>$null
        $freeFormExit = $LASTEXITCODE
        $freeForm = $freeFormOutput | Select-Object -Last 1 | ConvertFrom-Json
        if ($freeFormExit -ne 0 -or $freeForm.runner_state -ne 'completed' -or -not $freeForm.summary_present) {
            throw 'Runner did not accept a free-form worker summary.'
        }
        if ($freeForm.command_total -ne 100 -or $freeForm.command_failed -ne 25) { throw 'Runner command evidence counts are incorrect.' }
        if (-not $freeForm.commands_truncated) { throw 'Runner did not mark bounded command evidence as truncated.' }
        $commandEvidence = Get-Content -LiteralPath (Join-Path $freeForm.artifact_path 'commands.json') -Raw | ConvertFrom-Json
        if ($commandEvidence.total -ne 100 -or $commandEvidence.failed -ne 25 -or -not $commandEvidence.truncated) {
            throw 'Bounded command artifact lost its aggregate facts.'
        }
        if (@($commandEvidence.commands).Count -gt 70) { throw 'Runner persisted an unbounded command evidence list.' }
        if ($freeForm.usage.uncached_input_tokens -ne 20) { throw 'Runner usage evidence is incorrect.' }
        if (-not $freeForm.prompt_deleted) { throw 'Runner did not confirm prompt deletion.' }
        if (Test-Path -LiteralPath (Join-Path $freeForm.artifact_path 'child-arguments.json')) { throw 'Runner left child arguments behind.' }
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
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw 'Runner did not publish its terminal ResultFile envelope.' }
        $envelope = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if ($envelope.runner_state -ne 'completed' -or [int]$envelope.runner_contract_version -ne 4) {
            throw 'ResultFile is not the v4 Runner terminal envelope.'
        }
        $artifactStatus = Get-Content -LiteralPath (Join-Path $freeForm.artifact_path 'status.json') -Raw | ConvertFrom-Json
        if ($envelope.run_id -ne $artifactStatus.run_id -or $envelope.runner_state -ne $artifactStatus.runner_state -or [int]$envelope.exit_code -ne [int]$artifactStatus.exit_code) {
            throw 'ResultFile and status.json do not contain the same terminal envelope.'
        }
        foreach ($removedField in @('worker_claim', 'claimed_verification', 'final_schema_valid', 'final_parse_mode', 'publishable', 'result_schema_version')) {
            if ($envelope.PSObject.Properties.Name -contains $removedField) {
                throw "ResultFile still exposes removed model-authority field: $removedField"
            }
        }
        if (Get-ChildItem -LiteralPath $tempBase -Filter 'free-form-result.json.*.tmp' -ErrorAction SilentlyContinue) {
            throw 'Runner left a temporary ResultFile behind.'
        }
        $capturedPrompt = Get-Content -LiteralPath $promptCapturePath -Raw
        if ($capturedPrompt -notmatch 'Do not stage, commit, push' -or $capturedPrompt -notmatch 'Do not hide a failing exit code') {
            throw 'Runner did not inject the Git ownership and exit-code rules.'
        }
        if ($capturedPrompt -match 'strict JSON|output schema') {
            throw 'Runner still asks the model to satisfy the removed result schema.'
        }
        Remove-Item Env:DSW_FAKE_DESCENDANT_PID -ErrorAction SilentlyContinue
        Remove-Item Env:DSW_FAKE_DESCENDANT_LATE_FILE -ErrorAction SilentlyContinue
        Remove-Item Env:DSW_FAKE_COMMAND_COUNT -ErrorAction SilentlyContinue

        foreach ($summaryKind in @('markdown', 'fenced', 'invalid', 'missing')) {
            $caseResultPath = Join-Path $tempBase "$summaryKind-result.json"
            $env:DSW_FAKE_FINAL_KIND = $summaryKind
            $caseOutput = & $runner -Workdir $workdir -Prompt "fake $summaryKind summary" -Mode audit -ResultFile $caseResultPath 2>$null
            $caseExit = $LASTEXITCODE
            $case = $caseOutput | Select-Object -Last 1 | ConvertFrom-Json
            if ($caseExit -ne 0 -or $case.runner_state -ne 'completed') {
                throw "Runner let summary formatting control execution success: $summaryKind"
            }
            if ($summaryKind -eq 'missing' -and $case.summary_present) {
                throw 'Runner reported a missing summary as present.'
            }
            if ($summaryKind -ne 'missing' -and -not $case.summary_present) {
                throw "Runner lost a present summary: $summaryKind"
            }
            $caseEnvelope = Get-Content -LiteralPath $caseResultPath -Raw | ConvertFrom-Json
            if ($caseEnvelope.runner_state -ne 'completed') {
                throw "Runner did not write a completed terminal envelope: $summaryKind"
            }
        }

        $env:DSW_FAKE_FINAL_KIND = 'oversized'
        $oversizedOutput = & $runner -Workdir $workdir -Prompt 'fake oversized summary' -Mode audit 2>$null
        $oversized = $oversizedOutput | Select-Object -Last 1 | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $oversized.runner_state -ne 'completed' -or -not $oversized.summary_truncated) {
            throw 'Runner did not bound an oversized summary without changing success.'
        }

        foreach ($eventsKind in @('empty', 'malformed')) {
            $env:DSW_FAKE_FINAL_KIND = 'free-form'
            $env:DSW_FAKE_EVENTS_KIND = $eventsKind
            $eventsOutput = & $runner -Workdir $workdir -Prompt "fake $eventsKind events" -Mode audit 2>$null
            $eventsResult = $eventsOutput | Select-Object -Last 1 | ConvertFrom-Json
            if ($LASTEXITCODE -ne 0 -or $eventsResult.runner_state -ne 'completed' -or $eventsResult.evidence_complete) {
                throw "Runner did not degrade unavailable event evidence without changing process success: $eventsKind"
            }
            if ($eventsKind -eq 'malformed' -and [int]$eventsResult.event_parse_errors -lt 1) {
                throw 'Runner did not record malformed event evidence.'
            }
        }
        Remove-Item Env:DSW_FAKE_EVENTS_KIND -ErrorAction SilentlyContinue

        $env:DSW_FAKE_FINAL_KIND = 'nonzero'
        $nonzeroResultPath = Join-Path $tempBase 'nonzero-result.json'
        $nonzeroOutput = & $runner -Workdir $workdir -Prompt 'fake nonzero' -Mode audit -ResultFile $nonzeroResultPath 2>$null
        $nonzeroExit = $LASTEXITCODE
        $nonzero = $nonzeroOutput | Select-Object -Last 1 | ConvertFrom-Json
        if ($nonzeroExit -eq 0 -or $nonzero.runner_state -ne 'failed') {
            throw 'Runner ignored the Worker process nonzero exit.'
        }
        if ((Get-Content -LiteralPath $nonzeroResultPath -Raw | ConvertFrom-Json).runner_state -ne 'failed') {
            throw 'Runner did not write a failure terminal envelope.'
        }

        [System.IO.File]::WriteAllText((Join-Path $workdir 'overlap.txt'), "baseline`n", [System.Text.UTF8Encoding]::new($false))
        & git -C $workdir add overlap.txt
        & git -C $workdir commit -q -m overlap-fixture
        Add-Content -LiteralPath (Join-Path $workdir 'overlap.txt') -Value 'user edit'
        $env:DSW_FAKE_FINAL_KIND = 'free-form'
        $env:DSW_FAKE_TOUCH_RELATIVE = 'overlap.txt'
        $overlapOutput = & $runner -Workdir $workdir -Prompt 'continue a pre-existing dirty file' -Mode implement -Sandbox workspace-write 2>$null
        $overlap = $overlapOutput | Select-Object -Last 1 | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $overlap.runner_state -ne 'completed' -or (@($overlap.overlap_with_preexisting) -notcontains 'overlap.txt')) {
            throw 'Runner treated a pre-existing dirty-file overlap as a hard failure.'
        }
        Remove-Item Env:DSW_FAKE_TOUCH_RELATIVE -ErrorAction SilentlyContinue

        $env:DSW_FAKE_GIT_MUTATION = 'worktree'
        $unstagedOutput = & $runner -Workdir $workdir -Prompt 'fake untracked worktree mutation' -Mode implement -Sandbox workspace-write 2>$null
        $unstagedResult = $unstagedOutput | Select-Object -Last 1 | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $unstagedResult.runner_state -ne 'completed' -or $unstagedResult.git_index_changed) {
            throw 'Runner rejected an ordinary unstaged worktree change.'
        }
        Remove-Item -LiteralPath (Join-Path $workdir 'worker-index-change.txt') -Force

        $env:DSW_FAKE_GIT_MUTATION = 'index'
        $indexResultPath = Join-Path $tempBase 'index-result.json'
        $indexOutput = & $runner -Workdir $workdir -Prompt 'fake index mutation' -Mode implement -Sandbox workspace-write -ResultFile $indexResultPath 2>$null
        $indexResult = $indexOutput | Select-Object -Last 1 | ConvertFrom-Json
        if ($LASTEXITCODE -eq 0 -or $indexResult.runner_state -ne 'failed' -or -not $indexResult.git_index_changed) {
            throw 'Runner did not reject a Worker change to the Git index.'
        }
        if ((Get-Content -LiteralPath $indexResultPath -Raw | ConvertFrom-Json).runner_state -ne 'failed') {
            throw 'Runner omitted the terminal envelope after an index violation.'
        }
        & git -C $workdir reset -q HEAD
        Remove-Item -LiteralPath (Join-Path $workdir 'worker-index-change.txt') -Force

        $env:DSW_FAKE_GIT_MUTATION = 'head'
        $headResultPath = Join-Path $tempBase 'head-result.json'
        $headOutput = & $runner -Workdir $workdir -Prompt 'fake HEAD mutation' -Mode implement -Sandbox workspace-write -ResultFile $headResultPath 2>$null
        $headResult = $headOutput | Select-Object -Last 1 | ConvertFrom-Json
        if ($LASTEXITCODE -eq 0 -or $headResult.runner_state -ne 'failed' -or $headResult.head_before -eq $headResult.head_after) {
            throw 'Runner did not reject a Worker change to Git HEAD.'
        }
        if ((Get-Content -LiteralPath $headResultPath -Raw | ConvertFrom-Json).runner_state -ne 'failed') {
            throw 'Runner omitted the terminal envelope after a HEAD violation.'
        }

        & git -C $workdir reset -q --hard HEAD~1
        $env:DSW_FAKE_GIT_MUTATION = 'branch'
        $branchOutput = & $runner -Workdir $workdir -Prompt 'fake branch mutation' -Mode implement -Sandbox workspace-write 2>$null
        $branchResult = $branchOutput | Select-Object -Last 1 | ConvertFrom-Json
        if ($LASTEXITCODE -eq 0 -or $branchResult.runner_state -ne 'failed' -or $branchResult.branch -eq $branchResult.branch_after) {
            throw 'Runner did not reject a checked-out branch change.'
        }
    }
    finally {
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
    if ($runnerText -match 'ConvertFrom-WorkerFinalText|Test-WorkerFinal|--output-schema|delegation-result\.schema\.json') {
        throw 'Runner still contains the removed model-result parser or schema path.'
    }
    if ($runnerText -notmatch 'summary\.txt') {
        throw 'Runner does not persist the non-authoritative natural-language summary.'
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
        $resultPath = Join-Path $tempBase 'published-result.json'
        $timeoutOutput = & $runner -Workdir $workdir -Prompt 'write then wait' -Mode implement -Sandbox workspace-write -TimeoutSeconds 1 -ResultFile $resultPath 2>$null
        $timeoutExit = $LASTEXITCODE
        $timeout = $timeoutOutput | Select-Object -Last 1 | ConvertFrom-Json
        if ($timeoutExit -ne 124 -or $timeout.runner_state -ne 'timed_out') { throw 'Runner did not preserve timed_out/124.' }
        if (-not $timeout.unverified_partial_changes) { throw 'Runner did not mark timed-out workspace changes as unverified.' }
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            throw 'Runner did not write a terminal envelope for the timeout.'
        }
        $timeoutEnvelope = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if ($timeoutEnvelope.runner_state -ne 'timed_out' -or $timeoutEnvelope.exit_code -ne 124) {
            throw 'Timeout ResultFile did not preserve the Runner timed_out/124 facts.'
        }
        if (-not $timeout.prompt_deleted) { throw 'Runner did not remove the prompt after timeout.' }
        $status = Get-Content -LiteralPath (Join-Path $timeout.artifact_path 'status.json') -Raw | ConvertFrom-Json
        if ($status.runner_state -ne 'timed_out' -or -not $status.unverified_partial_changes) {
            throw 'Persistent status lost timeout recovery evidence.'
        }
        if (@($status.changed_files) -notcontains 'worker-中文-partial.txt') { throw 'Timeout evidence omitted the untracked partial file.' }
    }
    finally {
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
