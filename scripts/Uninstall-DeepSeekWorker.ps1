[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch]$RemoveKeyFile,
    [switch]$RemoveProfileConfig,
    [switch]$RemoveRunArtifacts
)

$ErrorActionPreference = 'Stop'

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
$skillDest = Join-Path $codexHome 'skills\deepseek-worker'
$profilePath = Join-Path $codexHome 'deepseek-worker.config.toml'
$keyFile = Join-Path $installRoot 'deepseek-api-key.txt'
$runRoot = Join-Path $installRoot 'runs'

function Assert-SafeTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [string]$Boundary
    )

    $resolved = [System.IO.Path]::GetFullPath($Target)
    $root = [System.IO.Path]::GetPathRoot($resolved)
    if ([string]::IsNullOrWhiteSpace($resolved) -or $resolved.TrimEnd('\') -eq $root.TrimEnd('\')) {
        throw "Refusing to remove a filesystem root: $resolved"
    }
    if (-not [string]::IsNullOrWhiteSpace($Boundary)) {
        $resolvedBoundary = [System.IO.Path]::GetFullPath($Boundary).TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($resolvedBoundary, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove a path outside its expected boundary: $resolved"
        }
    }
    return $resolved
}

$installedFiles = @(
    (Join-Path $installRoot 'codex-deepseek.ps1'),
    (Join-Path $installRoot 'codex-deepseek-exec.ps1'),
    (Join-Path $installRoot 'Set-DeepSeekKey.ps1'),
    (Join-Path $installRoot 'Uninstall-DeepSeekWorker.ps1'),
    (Join-Path $installRoot 'models.json'),
    (Join-Path $installRoot 'release-manifest.json'),
    (Join-Path $installRoot 'installed-manifest.json'),
    (Join-Path $installRoot 'assets\delegation-result.schema.json')
)

foreach ($target in $installedFiles) {
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $resolved = Assert-SafeTarget -Target $target -Boundary $installRoot
        if ($PSCmdlet.ShouldProcess($resolved, 'Remove installed file')) {
            Remove-Item -LiteralPath $resolved -Force
        }
    }
}

if (Test-Path -LiteralPath $skillDest -PathType Container) {
    $resolvedSkill = Assert-SafeTarget -Target $skillDest -Boundary (Join-Path $codexHome 'skills')
    if ($PSCmdlet.ShouldProcess($resolvedSkill, 'Remove installed skill')) {
        Remove-Item -LiteralPath $resolvedSkill -Recurse -Force
    }
}

if ($RemoveProfileConfig -and (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
    $resolvedProfile = Assert-SafeTarget -Target $profilePath -Boundary $codexHome
    if ($PSCmdlet.ShouldProcess($resolvedProfile, 'Remove profile config')) {
        Remove-Item -LiteralPath $resolvedProfile -Force
    }
}

if ($RemoveKeyFile -and (Test-Path -LiteralPath $keyFile -PathType Leaf)) {
    $resolvedKey = Assert-SafeTarget -Target $keyFile -Boundary $installRoot
    if ($PSCmdlet.ShouldProcess($resolvedKey, 'Remove key file')) {
        Remove-Item -LiteralPath $resolvedKey -Force
    }
}

if ($RemoveRunArtifacts -and (Test-Path -LiteralPath $runRoot -PathType Container)) {
    $resolvedRuns = Assert-SafeTarget -Target $runRoot -Boundary $installRoot
    if ($PSCmdlet.ShouldProcess($resolvedRuns, 'Remove run artifacts')) {
        Remove-Item -LiteralPath $resolvedRuns -Recurse -Force
    }
}

foreach ($directory in @((Join-Path $installRoot 'assets'), $installRoot)) {
    if (Test-Path -LiteralPath $directory -PathType Container) {
        $remaining = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) {
            $resolvedDirectory = Assert-SafeTarget -Target $directory
            if ($PSCmdlet.ShouldProcess($resolvedDirectory, 'Remove empty directory')) {
                Remove-Item -LiteralPath $resolvedDirectory -Force
            }
        }
    }
}

if (-not $RemoveKeyFile -and (Test-Path -LiteralPath $keyFile -PathType Leaf)) {
    Write-Warning "Key file was preserved: $keyFile. Re-run with -RemoveKeyFile to delete it."
}
if (-not $RemoveProfileConfig -and (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
    Write-Warning "Profile config was preserved: $profilePath. Re-run with -RemoveProfileConfig to delete it."
}
if (-not $RemoveRunArtifacts -and (Test-Path -LiteralPath $runRoot -PathType Container)) {
    Write-Warning "Run artifacts were preserved: $runRoot. Re-run with -RemoveRunArtifacts to delete them."
}
