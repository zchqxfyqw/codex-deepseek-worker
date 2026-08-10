[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

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

$skillSource = Join-Path $repoRoot 'skill\deepseek-worker'
$skillDest = Join-Path $codexHome 'skills\deepseek-worker'
$profileTemplate = Join-Path $repoRoot 'config\deepseek-worker.config.toml.example'
$profilePath = Join-Path $codexHome 'deepseek-worker.config.toml'
$modelCatalogSource = Join-Path $repoRoot 'config\deepseek-v4-flash.models.json.example'
$modelCatalogPath = Join-Path $installRoot 'models.json'

$installFiles = @(
    [pscustomobject]@{
        Source = Join-Path $repoRoot 'scripts\codex-deepseek.ps1'
        Destination = Join-Path $installRoot 'codex-deepseek.ps1'
    },
    [pscustomobject]@{
        Source = Join-Path $repoRoot 'scripts\codex-deepseek-exec.ps1'
        Destination = Join-Path $installRoot 'codex-deepseek-exec.ps1'
    },
    [pscustomobject]@{
        Source = Join-Path $repoRoot 'scripts\Set-DeepSeekKey.ps1'
        Destination = Join-Path $installRoot 'Set-DeepSeekKey.ps1'
    },
    [pscustomobject]@{
        Source = Join-Path $repoRoot 'scripts\Uninstall-DeepSeekWorker.ps1'
        Destination = Join-Path $installRoot 'Uninstall-DeepSeekWorker.ps1'
    },
    [pscustomobject]@{
        Source = Join-Path $repoRoot 'skill\deepseek-worker\assets\delegation-result.schema.json'
        Destination = Join-Path $installRoot 'assets\delegation-result.schema.json'
    }
)

foreach ($installFile in $installFiles) {
    if (-not (Test-Path -LiteralPath $installFile.Source -PathType Leaf)) {
        throw "Installer source file not found: $($installFile.Source)"
    }
    if (Test-Path -LiteralPath $installFile.Destination -PathType Leaf) {
        if (-not $Force) {
            Write-Warning "Skipping existing file (use -Force to update): $($installFile.Destination)"
            continue
        }
    }
    if ($PSCmdlet.ShouldProcess($installFile.Destination, 'Copy file')) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $installFile.Destination) -Force | Out-Null
        Copy-Item -LiteralPath $installFile.Source -Destination $installFile.Destination -Force
    }
}

if (-not (Test-Path -LiteralPath $skillSource -PathType Container)) {
    throw "Skill source not found: $skillSource"
}
if (Test-Path -LiteralPath $skillDest -PathType Container) {
    if (-not $Force) {
        Write-Warning "Skipping existing skill (use -Force to update): $skillDest"
    }
    elseif ($PSCmdlet.ShouldProcess($skillDest, 'Update skill')) {
        Copy-Item -LiteralPath $skillSource -Destination (Split-Path -Parent $skillDest) -Recurse -Force
    }
}
elseif ($PSCmdlet.ShouldProcess($skillDest, 'Install skill')) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $skillDest) -Force | Out-Null
    Copy-Item -LiteralPath $skillSource -Destination (Split-Path -Parent $skillDest) -Recurse -Force
}

if (-not (Test-Path -LiteralPath $profileTemplate -PathType Leaf)) {
    throw "Profile template not found: $profileTemplate"
}
if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
    if (-not $Force) {
        Write-Warning "Skipping existing profile (use -Force to update): $profilePath"
    }
    elseif ($PSCmdlet.ShouldProcess($profilePath, 'Update profile config')) {
        $profileText = Get-Content -LiteralPath $profileTemplate -Raw
        $profileText = $profileText.Replace('{{MODEL_CATALOG_PATH}}', $modelCatalogPath.Replace('\', '/'))
        [System.IO.File]::WriteAllText($profilePath, $profileText, (New-Object System.Text.UTF8Encoding($false)))
    }
}
elseif ($PSCmdlet.ShouldProcess($profilePath, 'Create profile config')) {
    $profileText = Get-Content -LiteralPath $profileTemplate -Raw
    $profileText = $profileText.Replace('{{MODEL_CATALOG_PATH}}', $modelCatalogPath.Replace('\', '/'))
    [System.IO.File]::WriteAllText($profilePath, $profileText, (New-Object System.Text.UTF8Encoding($false)))
}

if (-not (Test-Path -LiteralPath $modelCatalogSource -PathType Leaf)) {
    throw "Model catalog template not found: $modelCatalogSource"
}
if (Test-Path -LiteralPath $modelCatalogPath -PathType Leaf) {
    if (-not $Force) {
        Write-Warning "Skipping existing model catalog (use -Force to update): $modelCatalogPath"
    }
    elseif ($PSCmdlet.ShouldProcess($modelCatalogPath, 'Update model catalog')) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $modelCatalogPath) -Force | Out-Null
        Copy-Item -LiteralPath $modelCatalogSource -Destination $modelCatalogPath -Force
    }
}
elseif ($PSCmdlet.ShouldProcess($modelCatalogPath, 'Create model catalog')) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $modelCatalogPath) -Force | Out-Null
    Copy-Item -LiteralPath $modelCatalogSource -Destination $modelCatalogPath -Force
}

Write-Host "DeepSeek Worker installed to: $installRoot"
Write-Host "Skill installed to: $skillDest"
Write-Host "Profile config installed to: $profilePath"
Write-Host "Next: run $installRoot\Set-DeepSeekKey.ps1 to configure the API key."
