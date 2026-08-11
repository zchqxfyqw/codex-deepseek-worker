[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$OutputDirectory,
    [switch]$AllowDirty
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $repoRoot 'release-manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$version = [string]$manifest.product_version
if ([string]::IsNullOrWhiteSpace($version)) { throw 'release-manifest.json has no product_version.' }

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot 'dist'
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

$status = @(& git -C $repoRoot status --porcelain --untracked-files=no)
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect Git status.' }
if ($status.Count -gt 0 -and -not $AllowDirty) {
    throw 'The tracked worktree is dirty. Commit and verify the release sources before packaging, or use -AllowDirty only for a local preview.'
}
$sourceCommit = (& git -C $repoRoot rev-parse HEAD | Select-Object -First 1).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceCommit)) { throw 'Unable to resolve the source commit.' }

$packageName = "codex-deepseek-worker-$version"
$zipPath = Join-Path $OutputDirectory "$packageName.zip"
$checksumPath = Join-Path $OutputDirectory 'SHA256SUMS.txt'
if (-not $PSCmdlet.ShouldProcess($zipPath, "Create release package from commit $sourceCommit")) { return }

$stageParent = Join-Path ([System.IO.Path]::GetTempPath()) ("CodexDeepSeekWorker-package-" + [Guid]::NewGuid().ToString('N'))
$stageRoot = Join-Path $stageParent $packageName
try {
    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
    $trackedFiles = @(& git -C $repoRoot ls-files)
    if ($LASTEXITCODE -ne 0 -or $trackedFiles.Count -eq 0) { throw 'Unable to enumerate tracked release files.' }
    foreach ($relativePath in $trackedFiles) {
        if ($relativePath -like 'dist/*') { continue }
        $source = Join-Path $repoRoot $relativePath
        $destination = Join-Path $stageRoot $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination
    }

    $packageManifestPath = Join-Path $stageRoot 'release-manifest.json'
    $packageManifest = Get-Content -LiteralPath $packageManifestPath -Raw | ConvertFrom-Json
    $packageManifest | Add-Member -NotePropertyName source_commit -NotePropertyValue $sourceCommit -Force
    [System.IO.File]::WriteAllText(
        $packageManifestPath,
        ($packageManifest | ConvertTo-Json -Depth 8),
        [System.Text.UTF8Encoding]::new($false)
    )

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Compress-Archive -LiteralPath $stageRoot -DestinationPath $zipPath -CompressionLevel Optimal
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText(
        $checksumPath,
        "$hash  $([System.IO.Path]::GetFileName($zipPath))`n",
        [System.Text.UTF8Encoding]::new($false)
    )
}
finally {
    if (Test-Path -LiteralPath $stageParent) {
        Remove-Item -LiteralPath $stageParent -Recurse -Force -ErrorAction SilentlyContinue
    }
}

[ordered]@{
    product_version = $version
    source_commit = $sourceCommit
    package = $zipPath
    checksums = $checksumPath
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
} | ConvertTo-Json -Compress
