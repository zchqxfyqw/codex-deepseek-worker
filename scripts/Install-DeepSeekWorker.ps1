[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Utf8Text {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$installRoot = if ($env:CODEX_DEEPSEEK_WORKER_ROOT) {
    [System.IO.Path]::GetFullPath($env:CODEX_DEEPSEEK_WORKER_ROOT)
}
else {
    Join-Path $env:LOCALAPPDATA 'CodexDeepSeekWorker'
}
$codexHome = if ($env:CODEX_HOME) {
    [System.IO.Path]::GetFullPath($env:CODEX_HOME)
}
else {
    Join-Path $env:USERPROFILE '.codex'
}

$releaseManifestSource = Join-Path $repoRoot 'release-manifest.json'
if (-not (Test-Path -LiteralPath $releaseManifestSource -PathType Leaf)) {
    throw "Release manifest not found: $releaseManifestSource"
}
$releaseManifest = Get-Content -LiteralPath $releaseManifestSource -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace([string]$releaseManifest.product_version)) {
    throw 'Release manifest does not declare product_version.'
}

$modelCatalogPath = Join-Path $installRoot 'models.json'
$profilePath = Join-Path $codexHome 'deepseek-worker.config.toml'
$skillDest = Join-Path $codexHome 'skills\deepseek-worker'
$installedManifestPath = Join-Path $installRoot 'installed-manifest.json'

$fileSpecs = @(
    @{ Source = Join-Path $repoRoot 'scripts\codex-deepseek.ps1'; Destination = Join-Path $installRoot 'codex-deepseek.ps1' },
    @{ Source = Join-Path $repoRoot 'scripts\codex-deepseek-exec.ps1'; Destination = Join-Path $installRoot 'codex-deepseek-exec.ps1' },
    @{ Source = Join-Path $repoRoot 'scripts\Set-DeepSeekKey.ps1'; Destination = Join-Path $installRoot 'Set-DeepSeekKey.ps1' },
    @{ Source = Join-Path $repoRoot 'scripts\Uninstall-DeepSeekWorker.ps1'; Destination = Join-Path $installRoot 'Uninstall-DeepSeekWorker.ps1' },
    @{ Source = Join-Path $repoRoot 'skill\deepseek-worker\assets\delegation-result.schema.json'; Destination = Join-Path $installRoot 'assets\delegation-result.schema.json' },
    @{ Source = Join-Path $repoRoot 'config\deepseek-v4-flash.models.json.example'; Destination = $modelCatalogPath },
    @{ Source = $releaseManifestSource; Destination = Join-Path $installRoot 'release-manifest.json' }
)
$profileTemplate = Join-Path $repoRoot 'config\deepseek-worker.config.toml.example'
$skillSource = Join-Path $repoRoot 'skill\deepseek-worker'

foreach ($spec in $fileSpecs) {
    if (-not (Test-Path -LiteralPath $spec.Source -PathType Leaf)) {
        throw "Installer source file not found: $($spec.Source)"
    }
}
if (-not (Test-Path -LiteralPath $profileTemplate -PathType Leaf)) { throw "Profile template not found: $profileTemplate" }
if (-not (Test-Path -LiteralPath $skillSource -PathType Container)) { throw "Skill source not found: $skillSource" }

$managedDestinations = @($fileSpecs.Destination + $profilePath + $skillDest + $installedManifestPath)
$existing = @($managedDestinations | Where-Object { Test-Path -LiteralPath $_ })
if ($existing.Count -gt 0 -and -not $Force) {
    throw "DeepSeek Worker managed files already exist. Re-run with -Force for a backed-up transactional upgrade. First existing path: $($existing[0])"
}

$sourceCommit = $null
try {
    $candidateCommit = (& git -C $repoRoot rev-parse HEAD 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($candidateCommit)) {
        $sourceCommit = $candidateCommit.Trim()
    }
}
catch { $sourceCommit = $null }
if ([string]::IsNullOrWhiteSpace($sourceCommit) -and -not [string]::IsNullOrWhiteSpace($env:CODEX_DEEPSEEK_SOURCE_COMMIT)) {
    $sourceCommit = $env:CODEX_DEEPSEEK_SOURCE_COMMIT.Trim()
}

$action = if ($existing.Count -gt 0) { 'Upgrade with backup and rollback' } else { 'Install transactionally' }
if (-not $PSCmdlet.ShouldProcess($installRoot, "$action DeepSeek Worker $($releaseManifest.product_version)")) {
    Write-Host "WhatIf: $action DeepSeek Worker $($releaseManifest.product_version) to $installRoot"
    Write-Host "WhatIf: install Skill to $skillDest and profile to $profilePath"
    return
}

$transactionId = "{0}-{1}" -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')), ([Guid]::NewGuid().ToString('N').Substring(0, 8))
$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) "CodexDeepSeekWorker-install-$transactionId"
$backupRoot = Join-Path $installRoot "backups\$transactionId"
$createdDestinations = New-Object System.Collections.Generic.List[string]
$backupEntries = New-Object System.Collections.Generic.List[object]
$installSucceeded = $false

try {
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    $stageFilesRoot = Join-Path $stagingRoot 'files'
    $stageSkill = Join-Path $stagingRoot 'skill'
    New-Item -ItemType Directory -Path $stageFilesRoot -Force | Out-Null

    $stagedSpecs = New-Object System.Collections.Generic.List[object]
    foreach ($spec in $fileSpecs) {
        $stagePath = Join-Path $stageFilesRoot ([Guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $spec.Source -Destination $stagePath
        $stagedSpecs.Add([pscustomobject]@{ Stage = $stagePath; Destination = $spec.Destination })
    }

    $stagedProfile = Join-Path $stageFilesRoot 'profile.toml'
    $profileText = (Get-Content -LiteralPath $profileTemplate -Raw).Replace('{{MODEL_CATALOG_PATH}}', $modelCatalogPath.Replace('\', '/'))
    Write-Utf8Text -Path $stagedProfile -Text $profileText
    $stagedSpecs.Add([pscustomobject]@{ Stage = $stagedProfile; Destination = $profilePath })
    Copy-Item -LiteralPath $skillSource -Destination $stageSkill -Recurse

    if ($existing.Count -gt 0) {
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        foreach ($destination in $managedDestinations) {
            if (-not (Test-Path -LiteralPath $destination)) { continue }
            $backupPath = Join-Path $backupRoot ([Guid]::NewGuid().ToString('N'))
            Copy-Item -LiteralPath $destination -Destination $backupPath -Recurse
            $backupEntries.Add([pscustomobject]@{
                destination = $destination
                backup = $backupPath
                is_directory = [bool](Test-Path -LiteralPath $destination -PathType Container)
            })
        }
        $backupEntries | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backupRoot 'restore-map.json') -Encoding utf8NoBOM
    }

    foreach ($staged in $stagedSpecs) {
        if (-not (Test-Path -LiteralPath $staged.Destination)) { $createdDestinations.Add($staged.Destination) }
        New-Item -ItemType Directory -Path (Split-Path -Parent $staged.Destination) -Force | Out-Null
        $temporaryDestination = "$($staged.Destination).$transactionId.tmp"
        Copy-Item -LiteralPath $staged.Stage -Destination $temporaryDestination -Force
        Move-Item -LiteralPath $temporaryDestination -Destination $staged.Destination -Force
    }

    if (-not (Test-Path -LiteralPath $skillDest)) { $createdDestinations.Add($skillDest) }
    $temporarySkill = "$skillDest.$transactionId.tmp"
    if (Test-Path -LiteralPath $temporarySkill) { Remove-Item -LiteralPath $temporarySkill -Recurse -Force }
    Copy-Item -LiteralPath $stageSkill -Destination $temporarySkill -Recurse
    if (Test-Path -LiteralPath $skillDest) { Remove-Item -LiteralPath $skillDest -Recurse -Force }
    Move-Item -LiteralPath $temporarySkill -Destination $skillDest

    $installedFiles = New-Object System.Collections.Generic.List[object]
    foreach ($staged in $stagedSpecs) {
        $installedFiles.Add([ordered]@{ path = $staged.Destination; sha256 = Get-Sha256 -Path $staged.Destination })
    }
    foreach ($skillFile in Get-ChildItem -LiteralPath $skillDest -File -Recurse) {
        $installedFiles.Add([ordered]@{ path = $skillFile.FullName; sha256 = Get-Sha256 -Path $skillFile.FullName })
    }

    $installedManifest = [ordered]@{
        product = $releaseManifest.product
        product_version = $releaseManifest.product_version
        source_commit = $sourceCommit
        runner_contract_version = $releaseManifest.runner_contract_version
        result_schema_version = $releaseManifest.result_schema_version
        adapter_id = $releaseManifest.adapter_id
        adapter_version = $releaseManifest.adapter_version
        provider = $releaseManifest.provider
        model = $releaseManifest.model
        supported_codex_cli_versions = @($releaseManifest.supported_codex_cli_versions)
        installed_at_utc = [DateTime]::UtcNow.ToString('o')
        transaction_id = $transactionId
        backup_path = if ($existing.Count -gt 0) { $backupRoot } else { $null }
        installed_files = $installedFiles.ToArray()
    }
    if (-not (Test-Path -LiteralPath $installedManifestPath)) { $createdDestinations.Add($installedManifestPath) }
    $manifestTemp = "$installedManifestPath.$transactionId.tmp"
    Write-Utf8Text -Path $manifestTemp -Text ($installedManifest | ConvertTo-Json -Depth 8)
    Move-Item -LiteralPath $manifestTemp -Destination $installedManifestPath -Force

    foreach ($entry in $installedFiles) {
        if ((Get-Sha256 -Path $entry.path) -ne $entry.sha256) {
            throw "Post-install hash verification failed: $($entry.path)"
        }
    }
    $installSucceeded = $true
}
catch {
    $failure = $_
    foreach ($destination in @($createdDestinations | Sort-Object Length -Descending)) {
        if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue }
    }
    foreach ($entry in $backupEntries) {
        if (Test-Path -LiteralPath $entry.destination) { Remove-Item -LiteralPath $entry.destination -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path (Split-Path -Parent $entry.destination) -Force | Out-Null
        Copy-Item -LiteralPath $entry.backup -Destination $entry.destination -Recurse -Force
    }
    throw "DeepSeek Worker installation failed and rollback was attempted: $($failure.Exception.Message)"
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

if (-not $installSucceeded) { throw 'DeepSeek Worker installation did not complete.' }
Write-Host "DeepSeek Worker $($releaseManifest.product_version) installed to: $installRoot"
Write-Host "Skill installed to: $skillDest"
Write-Host "Profile config installed to: $profilePath"
if ($existing.Count -gt 0) { Write-Host "Rollback backup: $backupRoot" }
Write-Host "Next: run $installRoot\Set-DeepSeekKey.ps1, then -Doctor and -DryRun."
