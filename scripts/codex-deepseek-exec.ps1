#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$Workdir,
    [string]$Prompt,
    [string]$PromptFile,
    [string]$ResultFile,
    [switch]$StructuredResult,
    [switch]$Ephemeral = $true,
    [switch]$AllowNetwork,
    [switch]$SkipGitRepoCheck,
    [ValidateSet('read-only', 'workspace-write')]
    [string]$Sandbox = 'read-only',
    [ValidateSet('audit', 'implement', 'quota-first')]
    [string]$Mode,
    [ValidateRange(1, 86400)]
    [int]$TimeoutSeconds = 2700,
    [string]$RunRoot,
    [string]$CorrelationId,
    [switch]$DryRun,
    [switch]$Doctor,
    [switch]$WorkspaceProbe
)

$ErrorActionPreference = 'Stop'

function Get-CodexHome {
    if ($env:CODEX_HOME) {
        return [System.IO.Path]::GetFullPath($env:CODEX_HOME)
    }
    return Join-Path $env:USERPROFILE '.codex'
}

function Get-InstallRoot {
    if ($env:CODEX_DEEPSEEK_WORKER_ROOT) {
        return [System.IO.Path]::GetFullPath($env:CODEX_DEEPSEEK_WORKER_ROOT)
    }
    return Join-Path $env:LOCALAPPDATA 'CodexDeepSeekWorker'
}

function Get-WorkerPaths {
    $installRoot = Get-InstallRoot
    $codexHome = Get-CodexHome

    $launcherCandidates = @(
        (Join-Path $installRoot 'codex-deepseek.ps1'),
        (Join-Path $PSScriptRoot 'codex-deepseek.ps1')
    )
    $launcher = $launcherCandidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1

    $schemaCandidates = @(
        (Join-Path $installRoot 'assets\delegation-result.schema.json'),
        (Join-Path $codexHome 'skills\deepseek-worker\assets\delegation-result.schema.json'),
        (Join-Path $PSScriptRoot '..\skill\deepseek-worker\assets\delegation-result.schema.json')
    )
    $schema = $schemaCandidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1

    $profileCandidates = @(
        (Join-Path $codexHome 'deepseek-worker.config.toml'),
        (Join-Path $PSScriptRoot '..\config\deepseek-worker.config.toml.example')
    )
    $profilePath = $profileCandidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1

    return [pscustomobject]@{
        InstallRoot = $installRoot
        CodexHome = $codexHome
        Launcher = $launcher
        Schema = $schema
        ProfilePath = $profilePath
        KeyFile = if ($env:CODEX_DEEPSEEK_KEY_FILE) {
            [System.IO.Path]::GetFullPath($env:CODEX_DEEPSEEK_KEY_FILE)
        }
        else {
            Join-Path $installRoot 'deepseek-api-key.txt'
        }
        RunRoot = Join-Path $installRoot 'runs'
        RegistryRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'CodexDeepSeekWorkerLocks'
        InstalledManifest = Join-Path $installRoot 'installed-manifest.json'
        ReleaseManifest = @(
            (Join-Path $installRoot 'release-manifest.json'),
            (Join-Path $PSScriptRoot '..\release-manifest.json')
        ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        SkillPath = Join-Path $codexHome 'skills\deepseek-worker\SKILL.md'
        ModelCatalog = Join-Path $installRoot 'models.json'
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-PowerShell7Runtime {
    $candidates = New-Object System.Collections.Generic.List[object]
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_DEEPSEEK_PWSH_PATH)) {
        $candidates.Add([pscustomobject]@{ Path = $env:CODEX_DEEPSEEK_PWSH_PATH; Source = 'environment' })
    }
    else {
        $standardPath = if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe' } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($standardPath)) {
            $candidates.Add([pscustomobject]@{ Path = $standardPath; Source = 'standard-msi' })
        }
    }

    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in $candidates) {
        try {
            $candidatePath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$candidate.Path))
        }
        catch {
            $errors.Add("Invalid PowerShell 7 path from $($candidate.Source): $($candidate.Path)")
            continue
        }
        if ($candidatePath -match '(?i)\\WindowsApps\\') {
            $errors.Add("Rejected Store/MSIX PowerShell path because Codex sandbox identities may not execute it: $candidatePath")
            continue
        }
        if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) { continue }

        try {
            $probeScript = '[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false); Write-Output ($PSVersionTable.PSVersion.ToString()+"|DeepSeek-编码探针")'
            $probeOutput = @(& $candidatePath -NoLogo -NoProfile -NonInteractive -Command $probeScript 2>&1)
            $probeExitCode = $LASTEXITCODE
            $probeLine = ($probeOutput | Select-Object -Last 1).ToString().Trim()
            if ($probeExitCode -ne 0 -or $probeLine -notmatch '^(?<version>\d+\.\d+(?:\.\d+)?[^|]*)\|DeepSeek-编码探针$') {
                throw "PowerShell 7 UTF-8 probe failed (exit $probeExitCode): $probeLine"
            }
            $version = [version]$Matches.version
            if ($version.Major -lt 7) { throw "PowerShell version $version is below 7.0." }
            return [pscustomobject]@{
                Ok = $true
                Path = $candidatePath
                Version = $version.ToString()
                Source = [string]$candidate.Source
                ProbeOk = $true
                Error = $null
            }
        }
        catch {
            $errors.Add("PowerShell 7 candidate failed: $candidatePath ($($_.Exception.Message))")
        }
    }

    return [pscustomobject]@{
        Ok = $false
        Path = $null
        Version = $null
        Source = $null
        ProbeOk = $false
        Error = if ($errors.Count -gt 0) { $errors -join '; ' } else { 'PowerShell 7 was not found. Install the MSI or portable build, not only the Microsoft Store package.' }
    }
}

function Get-PackageMetadata {
    param([Parameter(Mandatory = $true)]$Paths)

    $manifestPath = if (Test-Path -LiteralPath $Paths.InstalledManifest -PathType Leaf) {
        $Paths.InstalledManifest
    }
    elseif ($null -ne $Paths.ReleaseManifest -and (Test-Path -LiteralPath $Paths.ReleaseManifest -PathType Leaf)) {
        $Paths.ReleaseManifest
    }
    else {
        $null
    }
    if ($null -eq $manifestPath) {
        return [pscustomobject]@{
            ManifestPath = $null
            Manifest = $null
            ManifestOk = $false
            HashesOk = $false
            HashErrors = @('Package manifest not found.')
        }
    }

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{
            ManifestPath = $manifestPath
            Manifest = $null
            ManifestOk = $false
            HashesOk = $false
            HashErrors = @("Package manifest is invalid JSON: $($_.Exception.Message)")
        }
    }

    $manifestErrors = New-Object System.Collections.Generic.List[string]
    foreach ($requiredName in @(
        'product', 'product_version', 'runner_contract_version', 'result_schema_version',
        'adapter_id', 'adapter_version', 'provider', 'model', 'supported_codex_cli_versions'
    )) {
        if ($manifest.PSObject.Properties.Name -notcontains $requiredName -or $null -eq $manifest.$requiredName) {
            $manifestErrors.Add("Package manifest is missing: $requiredName")
        }
    }
    if ($manifest.PSObject.Properties.Name -contains 'product' -and [string]$manifest.product -ne 'codex-deepseek-worker') {
        $manifestErrors.Add('Package manifest product id is not codex-deepseek-worker.')
    }
    if ($manifest.PSObject.Properties.Name -contains 'provider' -and [string]$manifest.provider -ne 'deepseek-worker-secure') {
        $manifestErrors.Add('Package manifest provider is not deepseek-worker-secure.')
    }
    if ($manifest.PSObject.Properties.Name -contains 'model' -and [string]$manifest.model -ne 'deepseek-v4-flash') {
        $manifestErrors.Add('Package manifest model is not deepseek-v4-flash.')
    }

    $hashErrors = New-Object System.Collections.Generic.List[string]
    $isInstalledManifest = [System.IO.Path]::GetFullPath($manifestPath) -eq [System.IO.Path]::GetFullPath($Paths.InstalledManifest)
    if ($isInstalledManifest -and ($manifest.PSObject.Properties.Name -notcontains 'installed_files' -or @($manifest.installed_files).Count -eq 0)) {
        $hashErrors.Add('Installed manifest has no managed file hashes.')
    }
    if ($manifest.PSObject.Properties.Name -contains 'installed_files' -and $null -ne $manifest.installed_files) {
        foreach ($entry in @($manifest.installed_files)) {
            if ($entry.PSObject.Properties.Name -notcontains 'path' -or $entry.PSObject.Properties.Name -notcontains 'sha256') {
                $hashErrors.Add('Installed manifest contains an incomplete file entry.')
                continue
            }
            $path = [string]$entry.path
            $expected = ([string]$entry.sha256).ToLowerInvariant()
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                $hashErrors.Add("Missing managed file: $path")
                continue
            }
            if ((Get-FileSha256 -Path $path) -ne $expected) {
                $hashErrors.Add("Managed file hash mismatch: $path")
            }
        }
    }

    return [pscustomobject]@{
        ManifestPath = $manifestPath
        Manifest = $manifest
        ManifestOk = ($manifestErrors.Count -eq 0)
        HashesOk = ($hashErrors.Count -eq 0)
        HashErrors = @($manifestErrors) + @($hashErrors)
    }
}

function Get-NormalizedDirectoryPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -gt $root.Length) {
        $fullPath = $fullPath.TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        )
    }
    return $fullPath
}

function Get-PhysicalExistingPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $handle = [CodexDeepSeek.NativePath]::OpenForFinalPath($fullPath)
    if ($handle.IsInvalid) {
        $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        $handle.Dispose()
        throw (New-Object System.ComponentModel.Win32Exception($errorCode, "Could not resolve physical path: $fullPath"))
    }

    try {
        $builder = New-Object System.Text.StringBuilder 1024
        $length = [CodexDeepSeek.NativePath]::GetFinalPathNameByHandle($handle, $builder, [uint32]$builder.Capacity, 0)
        if ($length -eq 0) {
            $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw (New-Object System.ComponentModel.Win32Exception($errorCode, "Could not resolve physical path: $fullPath"))
        }
        if ($length -ge $builder.Capacity) {
            $builder = New-Object System.Text.StringBuilder ([int]$length + 1)
            $length = [CodexDeepSeek.NativePath]::GetFinalPathNameByHandle($handle, $builder, [uint32]$builder.Capacity, 0)
            if ($length -eq 0) {
                $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw (New-Object System.ComponentModel.Win32Exception($errorCode, "Could not resolve physical path: $fullPath"))
            }
        }
        $physicalPath = $builder.ToString()
    }
    finally {
        $handle.Dispose()
    }

    if ($physicalPath.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $physicalPath = '\\' + $physicalPath.Substring(8)
    }
    elseif ($physicalPath.StartsWith('\\?\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $physicalPath = $physicalPath.Substring(4)
    }

    if (Test-Path -LiteralPath $physicalPath -PathType Container) {
        return Get-NormalizedDirectoryPath -Path $physicalPath
    }
    return [System.IO.Path]::GetFullPath($physicalPath)
}

function Get-PhysicalPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $fullPath) {
        return Get-PhysicalExistingPath -Path $fullPath
    }
    $parent = [System.IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrWhiteSpace($parent) -or -not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Parent directory does not exist for physical path resolution: $fullPath"
    }
    $physicalParent = Get-PhysicalExistingPath -Path $parent
    return [System.IO.Path]::GetFullPath((Join-Path $physicalParent ([System.IO.Path]::GetFileName($fullPath))))
}

function Test-PathWithinBoundary {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Boundary
    )

    $normalizedPath = [System.IO.Path]::GetFullPath($Path)
    $normalizedBoundary = Get-NormalizedDirectoryPath -Path $Boundary
    if ($normalizedPath.Equals($normalizedBoundary, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $prefix = $normalizedBoundary
    if (-not $prefix.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $prefix += [System.IO.Path]::DirectorySeparatorChar
    }
    return $normalizedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-Sha256Text {
    param([Parameter(Mandatory = $true)][string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        return ([System.BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Write-Utf8Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Text
    )
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $temporaryPath = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    $json = ConvertTo-Json -InputObject $Value -Depth 12
    Write-Utf8Text -Path $temporaryPath -Text $json
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Enter-CoordinationGuard {
    param([Parameter(Mandatory = $true)][System.Threading.Mutex]$Mutex)

    try {
        return $Mutex.WaitOne([TimeSpan]::FromSeconds(5))
    }
    catch [System.Threading.AbandonedMutexException] {
        return $true
    }
}

function Get-LiveRegistrations {
    param(
        [Parameter(Mandatory = $true)][string]$RegistryRoot,
        [string]$Hash = '*',
        [switch]$CleanupStale
    )

    $live = @()
    $staleCount = 0
    if (-not (Test-Path -LiteralPath $RegistryRoot -PathType Container)) {
        return [pscustomobject]@{ Live = @(); StaleCount = 0 }
    }
    $filter = if ($Hash -eq '*') { '*.json' } else { "$Hash-*.json" }
    $files = Get-ChildItem -LiteralPath $RegistryRoot -Filter $filter -File -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        $registration = $null
        try {
            $registration = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            $process = Get-Process -Id ([int]$registration.ProcessId) -ErrorAction Stop
            $actualStartTicks = $process.StartTime.ToUniversalTime().Ticks.ToString()
            if ($actualStartTicks -ne $registration.ProcessStartTimeUtc.ToString()) {
                throw 'Process identity no longer matches registration.'
            }
        }
        catch {
            $staleCount++
            if ($CleanupStale) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            }
            continue
        }
        $live += $registration
    }
    return [pscustomobject]@{ Live = @($live); StaleCount = $staleCount }
}

function Get-GitLines {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = @(& git -C $Root -c core.quotepath=false @Arguments 2>$null)
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) { return @() }
        throw "Git command failed in ${Root}: git $($Arguments -join ' ')"
    }
    return @($output | ForEach-Object { $_.ToString() })
}

function Get-GitSnapshot {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) {
        return [pscustomobject]@{
            Branch = $null
            Head = $null
            StatusLines = @()
            ChangedFiles = @()
            IndexSemanticSha256 = $null
        }
    }
    $branchLines = @(Get-GitLines -Root $Root -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD') -AllowFailure)
    $branch = if ($branchLines.Count -gt 0) { $branchLines[0].Trim() } else { '(detached)' }
    $headLines = @(Get-GitLines -Root $Root -Arguments @('rev-parse', 'HEAD'))
    $head = if ($headLines.Count -gt 0) { $headLines[0].Trim() } else { $null }
    $statusLines = @(Get-GitLines -Root $Root -Arguments @('status', '--short', '--untracked-files=all'))
    $files = @()
    foreach ($line in $statusLines) {
        if ($line.Length -lt 4) { continue }
        $path = $line.Substring(3).Trim()
        if ($path.Contains(' -> ')) {
            $path = ($path -split ' -> ', 2)[1]
        }
        $files += $path.Trim('"')
    }
    $indexSemanticLines = @(Get-GitLines -Root $Root -Arguments @('ls-files', '--stage', '-v'))
    $indexSemanticText = $indexSemanticLines -join "`n"
    return [pscustomobject]@{
        Branch = $branch
        Head = $head
        StatusLines = @($statusLines)
        ChangedFiles = @($files | Sort-Object -Unique)
        IndexSemanticSha256 = Get-Sha256Text -Text $indexSemanticText
    }
}

function Get-FileFingerprints {
    param(
        [string]$Root,
        [string[]]$RelativePaths
    )

    $result = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Root)) { return $result }
    foreach ($relativePath in @($RelativePaths)) {
        $candidate = [System.IO.Path]::GetFullPath((Join-Path $Root $relativePath))
        if (-not (Test-PathWithinBoundary -Path $candidate -Boundary $Root)) {
            throw "Git status path escaped the worktree: $relativePath"
        }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $result[$relativePath] = [ordered]@{ exists = $true; sha256 = Get-FileSha256 -Path $candidate }
        }
        elseif (Test-Path -LiteralPath $candidate -PathType Container) {
            $result[$relativePath] = [ordered]@{ exists = $true; sha256 = '<directory>' }
        }
        else {
            $result[$relativePath] = [ordered]@{ exists = $false; sha256 = $null }
        }
    }
    return $result
}

function Read-SharedUtf8Lines {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Attempts = 25,
        [int]$DelayMilliseconds = 200
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $lastError = $null
    for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
        try {
            $stream = [System.IO.FileStream]::new(
                $Path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
            try {
                $reader = [System.IO.StreamReader]::new($stream, [System.Text.UTF8Encoding]::new($false), $true)
                try { $text = $reader.ReadToEnd() }
                finally { $reader.Dispose() }
            }
            finally { $stream.Dispose() }
            if ([string]::IsNullOrEmpty($text)) { return @() }
            return @($text -split '\r?\n')
        }
        catch [System.IO.IOException] {
            $lastError = $_.Exception
            if ($attempt + 1 -lt $Attempts) { Start-Sleep -Milliseconds $DelayMilliseconds }
        }
    }
    throw "Could not read event stream after a bounded retry: $($lastError.Message)"
}

function Get-EventEvidence {
    param([Parameter(Mandatory = $true)][string]$EventsPath)

    $commands = @()
    $probeCommands = @()
    $usage = $null
    foreach ($line in @(Read-SharedUtf8Lines -Path $EventsPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $event = $line | ConvertFrom-Json
            if ($event.type -eq 'item.completed' -and $null -ne $event.item -and $event.item.type -eq 'command_execution') {
                $commandText = $event.item.command
                if ($commandText -is [System.Array]) { $commandText = $commandText -join ' ' }
                $commands += [ordered]@{
                    command = [string]$commandText
                    exit_code = if ($null -ne $event.item.exit_code) { [int]$event.item.exit_code } else { $null }
                    status = [string]$event.item.status
                }
                $probeCommands += [ordered]@{
                    command = [string]$commandText
                    output = [string]$event.item.aggregated_output
                    exit_code = if ($null -ne $event.item.exit_code) { [int]$event.item.exit_code } else { $null }
                }
            }
            if ($event.type -eq 'turn.completed' -and $null -ne $event.usage) {
                $usage = [ordered]@{
                    input_tokens = [long]$event.usage.input_tokens
                    cached_input_tokens = [long]$event.usage.cached_input_tokens
                    uncached_input_tokens = [long]$event.usage.input_tokens - [long]$event.usage.cached_input_tokens
                    output_tokens = [long]$event.usage.output_tokens
                    reasoning_output_tokens = [long]$event.usage.reasoning_output_tokens
                }
            }
        }
        catch { continue }
    }
    return [pscustomobject]@{
        Commands = @($commands)
        Usage = $usage
        ProbeCommands = @($probeCommands)
    }
}

function Test-WorkerFinal {
    param([Parameter(Mandatory = $true)]$Value)

    $required = @('status', 'summary', 'changed_files', 'claimed_verification', 'risks_or_followups')
    $actual = @($Value.PSObject.Properties.Name)
    if (@($actual | Where-Object { $required -notcontains $_ }).Count -gt 0) {
        return [pscustomobject]@{ Valid = $false; Error = 'Final result contains unsupported fields.' }
    }
    foreach ($name in $required) {
        if ($Value.PSObject.Properties.Name -notcontains $name) {
            return [pscustomobject]@{ Valid = $false; Error = "Missing final field: $name" }
        }
    }
    if (@('completed', 'partial', 'blocked') -notcontains [string]$Value.status) {
        return [pscustomobject]@{ Valid = $false; Error = 'Invalid final status.' }
    }
    if ($Value.summary -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value.summary)) {
        return [pscustomobject]@{ Valid = $false; Error = 'Final summary must be a non-empty string.' }
    }
    foreach ($name in @('changed_files', 'claimed_verification', 'risks_or_followups')) {
        if ($null -eq $Value.$name -or $Value.$name -isnot [System.Array]) {
            return [pscustomobject]@{ Valid = $false; Error = "Final field must be an array: $name" }
        }
        if (@($Value.$name | Where-Object { $_ -isnot [string] }).Count -gt 0) {
            return [pscustomobject]@{ Valid = $false; Error = "Final array values must be strings: $name" }
        }
    }
    return [pscustomobject]@{ Valid = $true; Error = $null }
}

function ConvertFrom-WorkerFinalText {
    param([Parameter(Mandatory = $true)][string]$Text)

    if ($Text.Length -gt 262144) {
        throw 'Worker final message exceeds the 256 KiB limit.'
    }
    $trimmed = $Text.Trim()
    $candidate = $trimmed
    $parseMode = 'exact'
    try {
        $document = [System.Text.Json.JsonDocument]::Parse($candidate)
    }
    catch [System.Text.Json.JsonException] {
        $firstObject = $trimmed.IndexOf('{')
        if ($firstObject -le 0) { throw }
        $prefix = $trimmed.Substring(0, $firstObject).Trim()
        if ($prefix.Length -gt 256 -or $prefix -match '[\r\n{}\[\]\x00]' -or $prefix.Contains('```')) {
            throw 'Worker final message has an unsupported wrapper around JSON.'
        }
        $prefixIsJson = $false
        $prefixDocument = $null
        try {
            $prefixDocument = [System.Text.Json.JsonDocument]::Parse($prefix)
            $prefixIsJson = $true
        }
        catch [System.Text.Json.JsonException] { }
        finally {
            if ($null -ne $prefixDocument) { $prefixDocument.Dispose() }
        }
        if ($prefixIsJson) {
            throw 'Worker final message contains multiple JSON values.'
        }
        $candidate = $trimmed.Substring($firstObject).Trim()
        $parseMode = 'prefix_recovered'
        $document = [System.Text.Json.JsonDocument]::Parse($candidate)
    }
    try {
        if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            throw 'Worker final JSON must be an object.'
        }
        $names = @($document.RootElement.EnumerateObject() | ForEach-Object { $_.Name })
        if (@($names | Group-Object | Where-Object Count -gt 1).Count -gt 0) {
            throw 'Worker final JSON contains duplicate top-level fields.'
        }
    }
    finally {
        $document.Dispose()
    }
    return [pscustomobject]@{
        Value = ($candidate | ConvertFrom-Json -ErrorAction Stop)
        ParseMode = $parseMode
    }
}

function Stop-ProcessTree {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [Parameter(Mandatory = $true)][string]$StartTicks
    )

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        if ($process.StartTime.ToUniversalTime().Ticks.ToString() -ne $StartTicks) {
            return
        }
        & taskkill.exe /PID $ProcessId /T /F *> $null
    }
    catch {
        return
    }
}

function Stop-WorkerExecution {
    param(
        $Job,
        $Child,
        [string]$StartTicks,
        [uint32]$ExitCode
    )

    if ($null -ne $Job) {
        try {
            $Job.Terminate($ExitCode)
            return
        }
        catch { }
    }
    if ($null -ne $Child -and $null -ne $StartTicks) {
        Stop-ProcessTree -ProcessId $Child.Id -StartTicks $StartTicks
    }
}

function Get-DoctorResult {
    $paths = Get-WorkerPaths
    $package = Get-PackageMetadata -Paths $paths
    $manifest = $package.Manifest
    $powerShell7 = Get-PowerShell7Runtime
    $profileText = if ($null -ne $paths.ProfilePath -and (Test-Path -LiteralPath $paths.ProfilePath -PathType Leaf)) {
        Get-Content -LiteralPath $paths.ProfilePath -Raw
    }
    else {
        ''
    }
    $launcherText = if ($null -ne $paths.Launcher -and (Test-Path -LiteralPath $paths.Launcher -PathType Leaf)) {
        Get-Content -LiteralPath $paths.Launcher -Raw
    }
    else {
        ''
    }
    $registrationScan = Get-LiveRegistrations -RegistryRoot $paths.RegistryRoot
    $version = $null
    if ($null -ne $paths.Launcher) {
        try {
            $version = (& $paths.Launcher --version 2>$null | Select-Object -First 1).ToString().Trim()
        }
        catch {
            $version = $null
        }
    }

    $launcherExists = $null -ne $paths.Launcher -and (Test-Path -LiteralPath $paths.Launcher -PathType Leaf)
    $schemaExists = $null -ne $paths.Schema -and (Test-Path -LiteralPath $paths.Schema -PathType Leaf)
    $profileExists = $null -ne $paths.ProfilePath -and (Test-Path -LiteralPath $paths.ProfilePath -PathType Leaf)
    $keyFileExists = Test-Path -LiteralPath $paths.KeyFile -PathType Leaf
    $skillExists = Test-Path -LiteralPath $paths.SkillPath -PathType Leaf
    $modelCatalogExists = Test-Path -LiteralPath $paths.ModelCatalog -PathType Leaf
    $modelPinned = [bool]($profileText -match '(?m)^model\s*=\s*"deepseek-v4-flash"')
    $responsesApi = [bool]($profileText -match '(?m)^wire_api\s*=\s*"responses"')
    $envKeyProvider = [bool]($profileText -match '(?m)^env_key\s*=\s*"DEEPSEEK_API_KEY"')
    $cliVersionNumber = if ($version -match '(\d+\.\d+\.\d+)') { $Matches[1] } else { $null }
    $supportedVersions = if ($null -ne $manifest) { @($manifest.supported_codex_cli_versions) } else { @() }
    $cliSupported = $null -ne $cliVersionNumber -and $supportedVersions -contains $cliVersionNumber
    $keyAclRestricted = $false
    $keyAclError = $null
    if ($keyFileExists) {
        try {
            $unsafeAllow = @(Get-Acl -LiteralPath $paths.KeyFile).Access | Where-Object {
                $_.AccessControlType -eq 'Allow' -and
                $_.IdentityReference.Value -match '(CodexSandbox|Everyone|BUILTIN\\Users|Authenticated Users)'
            }
            $keyAclRestricted = $unsafeAllow.Count -eq 0
        }
        catch {
            $keyAclError = $_.Exception.Message
        }
    }
    $installOk = [bool](
        $launcherExists -and $schemaExists -and $profileExists -and $skillExists -and
        $modelCatalogExists -and $package.ManifestOk -and $package.HashesOk -and
        $modelPinned -and $responsesApi -and $envKeyProvider -and $cliSupported -and $powerShell7.Ok
    )

    return [ordered]@{
        ok = $installOk
        install_ok = $installOk
        ready_for_api_call = [bool]($installOk -and $keyFileExists -and $keyAclRestricted)
        codex_home = $paths.CodexHome
        install_root = $paths.InstallRoot
        package_version = if ($null -ne $manifest) { $manifest.product_version } else { $null }
        source_commit = if ($null -ne $manifest) { $manifest.source_commit } else { $null }
        runner_contract_version = if ($null -ne $manifest) { $manifest.runner_contract_version } else { $null }
        result_schema_version = if ($null -ne $manifest) { $manifest.result_schema_version } else { $null }
        manifest_path = $package.ManifestPath
        manifest_ok = $package.ManifestOk
        managed_hashes_ok = $package.HashesOk
        manifest_errors = @($package.HashErrors)
        launcher = $paths.Launcher
        launcher_exists = $launcherExists
        schema_exists = $schemaExists
        profile_exists = $profileExists
        skill_exists = $skillExists
        model_catalog_exists = $modelCatalogExists
        key_file_exists = $keyFileExists
        key_acl_restricted = $keyAclRestricted
        key_acl_error = $keyAclError
        cli_version = $version
        cli_version_number = $cliVersionNumber
        cli_supported = $cliSupported
        supported_cli_versions = @($supportedVersions)
        powershell7_ok = [bool]$powerShell7.Ok
        powershell7_path = $powerShell7.Path
        powershell7_version = $powerShell7.Version
        powershell7_source = $powerShell7.Source
        powershell7_probe_ok = [bool]$powerShell7.ProbeOk
        powershell7_error = $powerShell7.Error
        model_pinned = $modelPinned
        responses_api = $responsesApi
        env_key_provider = $envKeyProvider
        launcher_key_file = [bool]($launcherText -match 'deepseek-api-key\.txt')
        live_registrations = @($registrationScan.Live).Count
        stale_registrations = [int]$registrationScan.StaleCount
        run_root = $paths.RunRoot
        note = 'Strict read-only offline diagnostic. It does not call the model, mutate stale registrations, or reveal credentials.'
    }
}

if (-not ('CodexDeepSeekRunner.WorkerJob' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace CodexDeepSeekRunner
{
    public sealed class WorkerJob : IDisposable
    {
        private const uint KillOnJobClose = 0x00002000;
        private IntPtr handle;

        [StructLayout(LayoutKind.Sequential)]
        private struct BasicLimitInformation
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ExtendedLimitInformation
        {
            public BasicLimitInformation BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr securityAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr job, int informationClass, IntPtr information, uint length);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        public WorkerJob()
        {
            handle = CreateJobObject(IntPtr.Zero, null);
            if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject failed.");

            var information = new ExtendedLimitInformation();
            information.BasicLimitInformation.LimitFlags = KillOnJobClose;
            int size = Marshal.SizeOf(information);
            IntPtr pointer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(information, pointer, false);
                if (!SetInformationJobObject(handle, 9, pointer, (uint)size))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "SetInformationJobObject failed.");
            }
            catch
            {
                CloseHandle(handle);
                handle = IntPtr.Zero;
                throw;
            }
            finally { Marshal.FreeHGlobal(pointer); }
        }

        public void Assign(Process process)
        {
            if (handle == IntPtr.Zero) throw new ObjectDisposedException(nameof(WorkerJob));
            if (!AssignProcessToJobObject(handle, process.Handle))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "AssignProcessToJobObject failed.");
        }

        public void Terminate(uint exitCode)
        {
            if (handle != IntPtr.Zero && !TerminateJobObject(handle, exitCode))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "TerminateJobObject failed.");
        }

        public void Dispose()
        {
            if (handle == IntPtr.Zero) return;
            CloseHandle(handle);
            handle = IntPtr.Zero;
            GC.SuppressFinalize(this);
        }

        ~WorkerJob() { Dispose(); }
    }

}
'@
}

if (-not ('CodexDeepSeek.NativePath' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace CodexDeepSeek
{
    public static class NativePath
    {
        private const uint FileFlagBackupSemantics = 0x02000000;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            FileShare shareMode,
            IntPtr securityAttributes,
            FileMode creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern uint GetFinalPathNameByHandle(
            SafeFileHandle file,
            StringBuilder filePath,
            uint filePathLength,
            uint flags);

        public static SafeFileHandle OpenForFinalPath(string path)
        {
            return CreateFile(
                path,
                0,
                FileShare.Read | FileShare.Write | FileShare.Delete,
                IntPtr.Zero,
                FileMode.Open,
                FileFlagBackupSemantics,
                IntPtr.Zero);
        }
    }
}
'@
}

if ($Doctor) {
    if ($WorkspaceProbe) { throw 'Use either -Doctor or -WorkspaceProbe, not both.' }
    (Get-DoctorResult | ConvertTo-Json -Depth 6 -Compress) | Write-Output
    exit 0
}

$workspaceProbeToken = $null
$workspaceProbeRelativePath = $null
$workspaceProbeScriptRelativePath = $null
$workspaceProbeScriptPath = $null
$workspaceProbeScriptText = $null
$workspaceProbeDirectoryPath = $null
$workspaceProbeDirectoryExisted = $false
if ($WorkspaceProbe) {
    if ([string]::IsNullOrWhiteSpace($Workdir)) { throw '-WorkspaceProbe requires an explicit -Workdir.' }
    if (-not [string]::IsNullOrWhiteSpace($Prompt) -or -not [string]::IsNullOrWhiteSpace($PromptFile) -or -not [string]::IsNullOrWhiteSpace($ResultFile)) {
        throw '-WorkspaceProbe does not accept Prompt, PromptFile, or ResultFile.'
    }
    if ($AllowNetwork) { throw '-WorkspaceProbe never enables network access.' }
    $probeId = [Guid]::NewGuid().ToString('N')
    $workspaceProbeToken = "DSW_WORKSPACE_PROBE_OK_$probeId"
    $workspaceProbeRelativePath = ".codex_tmp/deepseek-worker-probe-$probeId.txt"
    $workspaceProbeScriptRelativePath = ".codex_tmp/deepseek-worker-probe-$probeId.ps1"
    $workspaceProbeScriptText = @"
`$ErrorActionPreference = 'Stop'
`$target = Join-Path `$PSScriptRoot 'deepseek-worker-probe-$probeId.txt'
[IO.File]::WriteAllText(`$target, '$workspaceProbeToken', [Text.UTF8Encoding]::new(`$false))
if ([IO.File]::ReadAllText(`$target) -ne '$workspaceProbeToken') { throw 'probe readback mismatch' }
[IO.File]::Delete(`$target)
Write-Output '$workspaceProbeToken'
"@
    $Prompt = "Workspace permission probe only. Do not inspect unrelated files. Run exactly one PowerShell 7 command and no other tool command: & (Join-Path (Get-Location) '$workspaceProbeScriptRelativePath'). The script tests $workspaceProbeRelativePath and must output $workspaceProbeToken. Then return the required final JSON."
    $Mode = 'implement'
    $Sandbox = 'workspace-write'
    $TimeoutSeconds = 300
}

$paths = Get-WorkerPaths
$launcher = $paths.Launcher
$schema = $paths.Schema
if ($null -eq $launcher -or -not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    throw "DeepSeek Codex launcher not found in: $($paths.InstallRoot)"
}
if ($null -eq $schema -or -not (Test-Path -LiteralPath $schema -PathType Leaf)) {
    throw "DeepSeek Worker result schema not found. Re-run the installer or install the skill."
}

if ([string]::IsNullOrWhiteSpace($Workdir)) {
    $currentLocation = Get-Location
    if ($currentLocation.Provider.Name -ne 'FileSystem' -or [string]::IsNullOrWhiteSpace($currentLocation.ProviderPath)) {
        throw 'Workdir was not provided and the current location is not a filesystem directory.'
    }
    $Workdir = $currentLocation.ProviderPath
}
$resolvedWorkdir = Get-PhysicalExistingPath -Path (Resolve-Path -LiteralPath $Workdir -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $resolvedWorkdir -PathType Container)) {
    throw "Workdir is not a directory: $resolvedWorkdir"
}

if (-not [string]::IsNullOrWhiteSpace($PromptFile)) {
    if (-not [string]::IsNullOrWhiteSpace($Prompt)) {
        throw 'Use either -Prompt or -PromptFile, not both.'
    }
    $resolvedPromptFile = (Resolve-Path -LiteralPath $PromptFile -ErrorAction Stop).Path
    $Prompt = Get-Content -LiteralPath $resolvedPromptFile -Raw
}
if ([string]::IsNullOrWhiteSpace($Prompt)) {
    throw 'Prompt must not be empty.'
}
$Prompt = $Prompt.Trim()

if ([string]::IsNullOrWhiteSpace($Mode)) {
    $Mode = if ($Sandbox -eq 'read-only') { 'audit' } else { 'implement' }
}
if ($Mode -eq 'audit' -and $Sandbox -ne 'read-only') {
    throw 'Mode audit requires Sandbox read-only.'
}
if ($Mode -eq 'implement' -and $Sandbox -ne 'workspace-write') {
    throw 'Mode implement requires Sandbox workspace-write.'
}
if ($Mode -eq 'quota-first' -and $TimeoutSeconds -lt 1800) {
    throw 'Mode quota-first requires TimeoutSeconds of at least 1800. Use implement for a shorter bounded task.'
}

$powerShell7 = Get-PowerShell7Runtime
if (-not $powerShell7.Ok) {
    throw "DeepSeek Worker requires an executable PowerShell 7 MSI or portable installation. $($powerShell7.Error)"
}

$gitRoot = $null
try {
    $gitRootOutput = & git -C $resolvedWorkdir rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($gitRootOutput | Select-Object -First 1))) {
        $gitRoot = Get-PhysicalExistingPath -Path (($gitRootOutput | Select-Object -First 1).Trim())
    }
}
catch {
    $gitRoot = $null
}
if ($null -ne $gitRoot) {
    $coordinationRoot = $gitRoot
}
elseif ($SkipGitRepoCheck) {
    $coordinationRoot = $resolvedWorkdir
}
else {
    throw "Workdir is not inside a Git worktree: $resolvedWorkdir. Use -SkipGitRepoCheck only for an intentional non-Git target."
}

$resolvedResultFile = $null
if (-not [string]::IsNullOrWhiteSpace($ResultFile)) {
    $resolvedResultFile = if ([System.IO.Path]::IsPathRooted($ResultFile)) {
        [System.IO.Path]::GetFullPath($ResultFile)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $resolvedWorkdir $ResultFile))
    }
    $resultParent = Split-Path -Parent $resolvedResultFile
    if ([string]::IsNullOrWhiteSpace($resultParent) -or -not (Test-Path -LiteralPath $resultParent -PathType Container)) {
        throw "ResultFile parent directory does not exist: $resultParent"
    }
    $resolvedResultFile = Get-PhysicalPath -Path $resolvedResultFile
}

$coordinationMode = $Sandbox
if ($null -ne $resolvedResultFile -and (Test-PathWithinBoundary -Path $resolvedResultFile -Boundary $coordinationRoot)) {
    $coordinationMode = 'workspace-write'
}

$normalizedCoordinationKey = $coordinationRoot.ToLowerInvariant()
$hash = (Get-Sha256Text -Text $normalizedCoordinationKey).Substring(0, 24).ToUpperInvariant()
$registryRoot = $paths.RegistryRoot
$defaultRunRoot = $paths.RunRoot
$package = Get-PackageMetadata -Paths $paths
$manifest = $package.Manifest
$productVersion = if ($null -ne $manifest) { [string]$manifest.product_version } else { $null }
$sourceCommit = if ($null -ne $manifest) { [string]$manifest.source_commit } else { $null }
$runnerContractVersion = if ($null -ne $manifest) { $manifest.runner_contract_version } else { $null }
$resultSchemaVersion = if ($null -ne $manifest) { $manifest.result_schema_version } else { $null }
$gitPreflight = Get-GitSnapshot -Root $gitRoot

if ($DryRun) {
    [ordered]@{
        dry_run = $true
        workspace_probe = [bool]$WorkspaceProbe
        physical_workdir = $resolvedWorkdir
        git_root = $gitRoot
        coordination_root = $coordinationRoot
        coordination_mode = $coordinationMode
        sandbox = $Sandbox
        mode = $Mode
        network = [bool]$AllowNetwork
        timeout_seconds = $TimeoutSeconds
        powershell7_path = $powerShell7.Path
        powershell7_version = $powerShell7.Version
        ephemeral = [bool]$Ephemeral
        prompt_length = $Prompt.Length
        prompt_sha256 = Get-Sha256Text -Text $Prompt
        correlation_id = $CorrelationId
        model = 'deepseek-v4-flash'
        provider = 'deepseek-worker-secure'
        product_version = $productVersion
        source_commit = $sourceCommit
        runner_contract_version = $runnerContractVersion
        result_schema_version = $resultSchemaVersion
        note = 'No API call was made and the prompt body is not displayed.'
    } | ConvertTo-Json -Depth 6 -Compress | Write-Output
    exit 0
}

if ([string]::IsNullOrWhiteSpace($RunRoot)) {
    $RunRoot = $defaultRunRoot
}
$resolvedRunRoot = [System.IO.Path]::GetFullPath($RunRoot)
New-Item -ItemType Directory -Path $resolvedRunRoot -Force | Out-Null

$runId = "{0}-{1}" -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')), ([Guid]::NewGuid().ToString('N').Substring(0, 8))
$runDir = Join-Path $resolvedRunRoot $runId
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

$statusPath = Join-Path $runDir 'status.json'
$invocationPath = Join-Path $runDir 'invocation.json'
$finalPath = Join-Path $runDir 'final.json'
$eventsPath = Join-Path $runDir 'events.jsonl'
$stderrPath = Join-Path $runDir 'stderr.log'
$commandsPath = Join-Path $runDir 'commands.json'
$beforeStatusPath = Join-Path $runDir 'before-status.txt'
$afterStatusPath = Join-Path $runDir 'after-status.txt'
$changedFilesPath = Join-Path $runDir 'changed-files.txt'
$diffStatPath = Join-Path $runDir 'diff-stat.txt'
$diffPatchPath = Join-Path $runDir 'diff.patch'
$beforeFingerprintsPath = Join-Path $runDir 'before-fingerprints.json'
$afterFingerprintsPath = Join-Path $runDir 'after-fingerprints.json'
$promptStdinPath = Join-Path $runDir 'prompt.stdin'
$jobReadyPath = Join-Path $runDir 'job.ready'

$before = $gitPreflight
$beforeFingerprints = Get-FileFingerprints -Root $gitRoot -RelativePaths $before.ChangedFiles
Write-Utf8Text -Path $beforeStatusPath -Text (($before.StatusLines -join [Environment]::NewLine) + $(if ($before.StatusLines.Count -gt 0) { [Environment]::NewLine } else { '' }))
Write-JsonAtomic -Path $beforeFingerprintsPath -Value $beforeFingerprints

$invocation = [ordered]@{
    run_id = $runId
    workspace_probe = [bool]$WorkspaceProbe
    correlation_id = $CorrelationId
    product_version = $productVersion
    source_commit = $sourceCommit
    runner_contract_version = $runnerContractVersion
    result_schema_version = $resultSchemaVersion
    physical_workdir = $resolvedWorkdir
    git_root = $gitRoot
    coordination_root = $coordinationRoot
    sandbox = $Sandbox
    coordination_mode = $coordinationMode
    mode = $Mode
    network = [bool]$AllowNetwork
    timeout_seconds = $TimeoutSeconds
    powershell7_path = $powerShell7.Path
    powershell7_version = $powerShell7.Version
    ephemeral = [bool]$Ephemeral
    provider = 'deepseek-worker-secure'
    model = 'deepseek-v4-flash'
    prompt_length = $Prompt.Length
    prompt_sha256 = Get-Sha256Text -Text $Prompt
    prompt_persisted = $false
    created_at_utc = [DateTime]::UtcNow.ToString('o')
}
Write-JsonAtomic -Path $invocationPath -Value $invocation

$status = [ordered]@{
    run_id = $runId
    correlation_id = $CorrelationId
    product_version = $productVersion
    source_commit = $sourceCommit
    runner_contract_version = $runnerContractVersion
    result_schema_version = $resultSchemaVersion
    runner_state = 'planned'
    workspace_probe = [bool]$WorkspaceProbe
    workspace_probe_ok = $null
    worker_claim = $null
    physical_workdir = $resolvedWorkdir
    git_root = $gitRoot
    git_index_changed = $false
    branch = $before.Branch
    head_before = $before.Head
    head_after = $null
    sandbox = $Sandbox
    network = [bool]$AllowNetwork
    powershell7_path = $powerShell7.Path
    powershell7_version = $powerShell7.Version
    provider = 'deepseek-worker-secure'
    model = 'deepseek-v4-flash'
    started_at_utc = $null
    ended_at_utc = $null
    process_id = $null
    process_start_ticks = $null
    exit_code = $null
    preexisting_changed_files = @($before.ChangedFiles)
    newly_changed_files = @()
    overlap_with_preexisting = @()
    changed_files = @()
    claimed_verification = @()
    final_schema_valid = $false
    final_parse_mode = $null
    duration_seconds = $null
    usage = $null
    command_total = 0
    command_succeeded = 0
    command_failed = 0
    failure_reason = $null
    unverified_partial_changes = $false
    prompt_deleted = $false
    command_evidence_path = $commandsPath
    final_path = $finalPath
    events_path = $eventsPath
    diff_stat_path = $diffStatPath
    diff_patch_path = $diffPatchPath
    note = 'Git artifacts describe repository state. Files already dirty before the run are not attributed solely to the Worker.'
}
Write-JsonAtomic -Path $statusPath -Value $status

if (-not (Test-Path -LiteralPath $registryRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $registryRoot -Force | Out-Null
}
$guard = New-Object System.Threading.Mutex($false, "Local\CodexDeepSeek_Guard_$hash")
$registrationPath = $null
$registrationCreated = $false
$child = $null
$childStartTicks = $null
$workerJob = $null
$exitCode = 1
$runnerState = 'failed'
$startedAtUtc = [DateTime]::UtcNow
$endedAtUtc = $null
$caughtError = $null

try {
    $guardAcquired = Enter-CoordinationGuard -Mutex $guard
    if (-not $guardAcquired) {
        throw "Could not acquire the DeepSeek worker coordination guard for: $coordinationRoot"
    }
    try {
        $registrationScan = Get-LiveRegistrations -RegistryRoot $registryRoot -Hash $hash -CleanupStale
        $liveRegistrations = @($registrationScan.Live)
        $conflicts = if ($coordinationMode -eq 'read-only') {
            @($liveRegistrations | Where-Object { $_.Mode -eq 'workspace-write' })
        }
        else {
            @($liveRegistrations)
        }
        if ($conflicts.Count -gt 0) {
            $activeModes = (($conflicts | ForEach-Object { $_.Mode }) | Sort-Object -Unique) -join ', '
            throw "Another DeepSeek Codex task conflicts with this $coordinationMode invocation in: $coordinationRoot (active: $activeModes)"
        }

        $parentStartTicks = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks.ToString()
        $registrationPath = Join-Path $registryRoot "$hash-$([Guid]::NewGuid().ToString('N')).json"
        $registration = [ordered]@{
            ProcessId = $PID
            ProcessStartTimeUtc = $parentStartTicks
            Mode = $coordinationMode
            Sandbox = $Sandbox
            CoordinationRoot = $coordinationRoot
            RunId = $runId
            StartedAtUtc = $startedAtUtc.ToString('o')
        }
        Write-JsonAtomic -Path $registrationPath -Value $registration
        $registrationCreated = $true
    }
    finally {
        $guard.ReleaseMutex()
    }

    if ($WorkspaceProbe) {
        $workspaceProbeScriptPath = [System.IO.Path]::GetFullPath((Join-Path $resolvedWorkdir $workspaceProbeScriptRelativePath))
        $workspaceProbeDirectoryPath = Split-Path -Parent $workspaceProbeScriptPath
        $workspaceProbeDirectoryExisted = Test-Path -LiteralPath $workspaceProbeDirectoryPath -PathType Container
        New-Item -ItemType Directory -Path $workspaceProbeDirectoryPath -Force | Out-Null
        Write-Utf8Text -Path $workspaceProbeScriptPath -Text $workspaceProbeScriptText
    }

    $modeInstruction = switch ($Mode) {
        'audit' { 'Mode: audit. Inspect and reason within the stated scope. Do not modify files.' }
        'implement' { 'Mode: implement. Complete the bounded change and its relevant verification within the granted sandbox.' }
        'quota-first' { 'Mode: quota-first. Own discovery, implementation, relevant tests, and self-review within scope so the orchestrating Codex can rely on the compact evidence bundle instead of repeating routine work.' }
    }
    $runtimeInstruction = 'Windows runtime: use PowerShell 7 semantics. For non-ASCII text, prefer apply_patch or an explicit UTF-8 writer; never use Windows PowerShell 5.1 text pipelines or heredoc-style workarounds.'
    $gitInstruction = 'Git boundary: use Git only for read-only inspection. Do not stage, commit, push, reset, checkout, switch, stash, clean, merge, rebase, or otherwise change the Git index, HEAD, refs, or shared metadata. Leave edits unstaged for the orchestrating Codex. Do not hide a failing exit code behind a pipeline or trailing output.'
    $timeInstruction = if ($Mode -eq 'quota-first') {
        $softDeadlineUtc = $startedAtUtc.AddSeconds($TimeoutSeconds - 300).ToString('o')
        $hardDeadlineUtc = $startedAtUtc.AddSeconds($TimeoutSeconds).ToString('o')
        "Time budget: hard deadline $hardDeadlineUtc UTC. At $softDeadlineUtc UTC, stop new discovery, optional polish, and nonessential retries. Use the remaining five minutes for critical verification and the final JSON. If work remains, return status partial with precise follow-ups instead of running past the deadline."
    }
    else { $null }
    $Prompt = @($Prompt.TrimEnd(), '', $modeInstruction, $runtimeInstruction, $gitInstruction, $timeInstruction, 'Final output requirement: return exactly one JSON object conforming to the provided output schema. Put only claimed checks in claimed_verification; the runner records command evidence separately. Do not add Markdown fences or prose outside the JSON object.') |
        Where-Object { $null -ne $_ } |
        Join-String -Separator "`n"
    Write-Utf8Text -Path $promptStdinPath -Text $Prompt

    $arguments = @('exec', '-C', $resolvedWorkdir, '--sandbox', $Sandbox, '--color', 'never', '--json')
    $networkAccess = if ($AllowNetwork) { 'true' } else { 'false' }
    $arguments += @('-c', "sandbox_workspace_write.network_access=$networkAccess")
    if ($SkipGitRepoCheck) { $arguments += '--skip-git-repo-check' }
    if ($Ephemeral) { $arguments += '--ephemeral' }
    $arguments += @('--output-schema', $schema, '--output-last-message', $finalPath, '-')

    $argumentJsonPath = Join-Path $runDir 'child-arguments.json'
    Write-Utf8Text -Path $argumentJsonPath -Text ($arguments | ConvertTo-Json -Compress)
$childCommand = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$jobReady = $env:CODEX_DEEPSEEK_JOB_READY
$jobDeadline = [DateTime]::UtcNow.AddSeconds(30)
while (-not (Test-Path -LiteralPath $jobReady -PathType Leaf)) {
    if ([DateTime]::UtcNow -ge $jobDeadline) { throw 'Runner did not arm the Worker process job within 30 seconds.' }
    Start-Sleep -Milliseconds 50
}
$parsedArgs = Get-Content -LiteralPath $env:CODEX_DEEPSEEK_CHILD_ARGS -Raw | ConvertFrom-Json
$childArgs = New-Object System.Collections.Generic.List[string]
foreach ($value in $parsedArgs) {
    $childArgs.Add([string]$value)
}
$argumentArray = [string[]]$childArgs.ToArray()
& $env:CODEX_DEEPSEEK_CHILD_LAUNCHER @argumentArray
exit $LASTEXITCODE
'@
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))
    $powershellExe = $powerShell7.Path
    $previousChildLauncher = $env:CODEX_DEEPSEEK_CHILD_LAUNCHER
    $previousChildArgs = $env:CODEX_DEEPSEEK_CHILD_ARGS
    $previousJobReady = $env:CODEX_DEEPSEEK_JOB_READY
    $previousPath = $env:PATH
    try {
        $powerShell7Directory = Split-Path -Parent $powerShell7.Path
        $env:PATH = if ([string]::IsNullOrWhiteSpace($previousPath)) { $powerShell7Directory } else { "$powerShell7Directory;$previousPath" }
        $env:CODEX_DEEPSEEK_CHILD_LAUNCHER = $launcher
        $env:CODEX_DEEPSEEK_CHILD_ARGS = $argumentJsonPath
        $env:CODEX_DEEPSEEK_JOB_READY = $jobReadyPath
        $child = Start-Process -FilePath $powershellExe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-OutputFormat', 'Text', '-EncodedCommand', $encodedCommand) -RedirectStandardInput $promptStdinPath -RedirectStandardOutput $eventsPath -RedirectStandardError $stderrPath -WindowStyle Hidden -PassThru
        $workerJob = [CodexDeepSeekRunner.WorkerJob]::new()
        $workerJob.Assign($child)
        Write-Utf8Text -Path $jobReadyPath -Text 'ready'
    }
    finally {
        $env:CODEX_DEEPSEEK_CHILD_LAUNCHER = $previousChildLauncher
        $env:CODEX_DEEPSEEK_CHILD_ARGS = $previousChildArgs
        $env:CODEX_DEEPSEEK_JOB_READY = $previousJobReady
        $env:PATH = $previousPath
    }

    $childStartTicks = $child.StartTime.ToUniversalTime().Ticks.ToString()
    $guardAcquired = Enter-CoordinationGuard -Mutex $guard
    if (-not $guardAcquired) {
        Stop-WorkerExecution -Job $workerJob -Child $child -StartTicks $childStartTicks -ExitCode 1
        throw "Could not update the DeepSeek worker registration for: $coordinationRoot"
    }
    try {
        $registration.ProcessId = $child.Id
        $registration.ProcessStartTimeUtc = $childStartTicks
        Write-JsonAtomic -Path $registrationPath -Value $registration
    }
    finally {
        $guard.ReleaseMutex()
    }

    $status.runner_state = 'running'
    $status.started_at_utc = $startedAtUtc.ToString('o')
    $status.process_id = $child.Id
    $status.process_start_ticks = $childStartTicks
    Write-JsonAtomic -Path $statusPath -Value $status

    $completed = $child.WaitForExit($TimeoutSeconds * 1000)
    if (-not $completed) {
        Stop-WorkerExecution -Job $workerJob -Child $child -StartTicks $childStartTicks -ExitCode 124
        $child.WaitForExit(10000) | Out-Null
        if ($child.HasExited) { $child.WaitForExit() }
        $exitCode = 124
        $runnerState = 'timed_out'
    }
    else {
        $child.WaitForExit()
        $exitCode = $child.ExitCode
        $runnerState = if ($exitCode -eq 0) { 'completed' } else { 'failed' }
    }
}
catch [System.Management.Automation.PipelineStoppedException] {
    $runnerState = 'interrupted'
    $exitCode = 130
    $caughtError = $_.Exception.Message
    Stop-WorkerExecution -Job $workerJob -Child $child -StartTicks $childStartTicks -ExitCode 130
}
catch {
    $runnerState = 'failed'
    $exitCode = 1
    $caughtError = $_.Exception.Message
    Stop-WorkerExecution -Job $workerJob -Child $child -StartTicks $childStartTicks -ExitCode 1
}
finally {
    $endedAtUtc = [DateTime]::UtcNow
    if ($null -ne $workerJob) {
        try { $workerJob.Dispose() }
        catch {
            $runnerState = 'failed'
            if ($exitCode -eq 0) { $exitCode = 1 }
            $jobMessage = "Worker process job cleanup failed: $($_.Exception.Message)"
            $caughtError = if ([string]::IsNullOrWhiteSpace($caughtError)) { $jobMessage } else { "$caughtError; $jobMessage" }
        }
        $workerJob = $null
    }
    Remove-Item -LiteralPath $jobReadyPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $workspaceProbeScriptPath -and (Test-Path -LiteralPath $workspaceProbeScriptPath -PathType Leaf)) {
        try { [System.IO.File]::Delete($workspaceProbeScriptPath) }
        catch {
            $runnerState = 'failed'
            if ($exitCode -eq 0) { $exitCode = 1 }
            $cleanupMessage = "Workspace probe helper cleanup failed: $workspaceProbeScriptPath"
            $caughtError = if ([string]::IsNullOrWhiteSpace($caughtError)) { $cleanupMessage } else { "$caughtError; $cleanupMessage" }
        }
    }
    if ($WorkspaceProbe -and -not $workspaceProbeDirectoryExisted -and $null -ne $workspaceProbeDirectoryPath -and (Test-Path -LiteralPath $workspaceProbeDirectoryPath -PathType Container)) {
        try {
            if (@(Get-ChildItem -LiteralPath $workspaceProbeDirectoryPath -Force).Count -eq 0) {
                [System.IO.Directory]::Delete($workspaceProbeDirectoryPath)
            }
        }
        catch {
            $runnerState = 'failed'
            if ($exitCode -eq 0) { $exitCode = 1 }
            $cleanupMessage = "Workspace probe directory cleanup failed: $workspaceProbeDirectoryPath"
            $caughtError = if ([string]::IsNullOrWhiteSpace($caughtError)) { $cleanupMessage } else { "$caughtError; $cleanupMessage" }
        }
    }
    if (Test-Path -LiteralPath $promptStdinPath -PathType Leaf) {
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            try {
                Remove-Item -LiteralPath $promptStdinPath -Force -ErrorAction Stop
                break
            }
            catch {
                Start-Sleep -Milliseconds 250
            }
        }
    }
    $promptDeleted = -not (Test-Path -LiteralPath $promptStdinPath -PathType Leaf)
    if (-not $promptDeleted) {
        $runnerState = 'failed'
        if ($exitCode -eq 0) { $exitCode = 1 }
        $cleanupMessage = "Prompt cleanup failed: $promptStdinPath"
        $caughtError = if ([string]::IsNullOrWhiteSpace($caughtError)) { $cleanupMessage } else { "$caughtError; $cleanupMessage" }
    }
    if ($registrationCreated -and $null -ne $registrationPath) {
        try {
            $cleanupGuardAcquired = Enter-CoordinationGuard -Mutex $guard
            if ($cleanupGuardAcquired) {
                try {
                    Remove-Item -LiteralPath $registrationPath -Force -ErrorAction SilentlyContinue
                }
                finally {
                    $guard.ReleaseMutex()
                }
            }
        }
        catch {
            $cleanupMessage = "Worker registration cleanup failed: $($_.Exception.Message)"
            $caughtError = if ([string]::IsNullOrWhiteSpace($caughtError)) { $cleanupMessage } else { "$caughtError; $cleanupMessage" }
        }
    }
    if ($null -ne $guard) {
        try { $guard.Dispose() }
        catch { }
    }
}

$after = [pscustomobject]@{
    Branch = $before.Branch
    Head = $null
    StatusLines = @()
    ChangedFiles = @()
    IndexSemanticSha256 = $before.IndexSemanticSha256
}
try {
    $after = Get-GitSnapshot -Root $gitRoot
}
catch {
    $runnerState = 'failed'
    if ($exitCode -eq 0) { $exitCode = 1 }
    $evidenceMessage = "Git evidence collection failed: $($_.Exception.Message)"
    $caughtError = if ([string]::IsNullOrWhiteSpace($caughtError)) { $evidenceMessage } else { "$caughtError; $evidenceMessage" }
}
$preexistingFiles = @($before.ChangedFiles)
$changedFiles = @($after.ChangedFiles)
$newlyChanged = @($changedFiles | Where-Object { $preexistingFiles -notcontains $_ } | Sort-Object -Unique)
$overlap = @()
$gitIndexChanged = [bool]([string]$before.IndexSemanticSha256 -ne [string]$after.IndexSemanticSha256)
try {
    Write-Utf8Text -Path $afterStatusPath -Text (($after.StatusLines -join [Environment]::NewLine) + $(if ($after.StatusLines.Count -gt 0) { [Environment]::NewLine } else { '' }))
    $fingerprintPaths = @($preexistingFiles + $changedFiles | Sort-Object -Unique)
    $afterFingerprints = Get-FileFingerprints -Root $gitRoot -RelativePaths $fingerprintPaths
    Write-JsonAtomic -Path $afterFingerprintsPath -Value $afterFingerprints
    $overlap = @($preexistingFiles | Where-Object {
        $beforeValue = $beforeFingerprints[$_]
        $afterValue = $afterFingerprints[$_]
        $null -eq $beforeValue -or $null -eq $afterValue -or
        [bool]$beforeValue.exists -ne [bool]$afterValue.exists -or
        [string]$beforeValue.sha256 -ne [string]$afterValue.sha256
    } | Sort-Object -Unique)
    Write-Utf8Text -Path $changedFilesPath -Text (($changedFiles -join [Environment]::NewLine) + $(if ($changedFiles.Count -gt 0) { [Environment]::NewLine } else { '' }))
}
catch {
    $runnerState = 'failed'
    if ($exitCode -eq 0) { $exitCode = 1 }
    $evidenceMessage = "Post-run file evidence collection failed: $($_.Exception.Message)"
    $caughtError = if ([string]::IsNullOrWhiteSpace($caughtError)) { $evidenceMessage } else { "$caughtError; $evidenceMessage" }
}

if ($null -ne $gitRoot -and $null -ne $before.Head -and $before.Head -ne $after.Head) {
    $runnerState = 'failed'
    if ($exitCode -eq 0) { $exitCode = 1 }
    $commitMessage = 'Worker changed Git HEAD; commits are not allowed.'
    $caughtError = if ([string]::IsNullOrWhiteSpace($caughtError)) { $commitMessage } else { "$caughtError; $commitMessage" }
}
if ($null -ne $gitRoot -and $gitIndexChanged) {
    $runnerState = 'failed'
    if ($exitCode -eq 0) { $exitCode = 1 }
    $indexMessage = 'The Git index changed during the Worker interval; staging is not allowed.'
    $caughtError = if ([string]::IsNullOrWhiteSpace($caughtError)) { $indexMessage } else { "$caughtError; $indexMessage" }
}
if ($Sandbox -eq 'workspace-write' -and $overlap.Count -gt 0) {
    $runnerState = 'failed'
    if ($exitCode -eq 0) { $exitCode = 1 }
    $overlapMessage = "Worker modified files that were already dirty before the run: $($overlap -join ', ')"
    $caughtError = if ([string]::IsNullOrWhiteSpace($caughtError)) { $overlapMessage } else { "$caughtError; $overlapMessage" }
}

$diffStatLines = @()
$diffPatchLines = @()
if ($null -ne $gitRoot) {
    try {
        $diffStatLines = @(Get-GitLines -Root $gitRoot -Arguments @('diff', '--stat', 'HEAD'))
        $diffPatchLines = @(Get-GitLines -Root $gitRoot -Arguments @('diff', '--binary', 'HEAD'))
        foreach ($line in $after.StatusLines) {
            if ($line.StartsWith('?? ')) {
                $diffStatLines += "untracked: $($line.Substring(3).Trim())"
            }
        }
    }
    catch {
        $runnerState = 'failed'
        if ($exitCode -eq 0) { $exitCode = 1 }
        $diffMessage = "Git diff collection failed: $($_.Exception.Message)"
        $caughtError = if ([string]::IsNullOrWhiteSpace($caughtError)) { $diffMessage } else { "$caughtError; $diffMessage" }
    }
}
try {
    Write-Utf8Text -Path $diffStatPath -Text (($diffStatLines -join [Environment]::NewLine) + $(if ($diffStatLines.Count -gt 0) { [Environment]::NewLine } else { '' }))
    Write-Utf8Text -Path $diffPatchPath -Text (($diffPatchLines -join [Environment]::NewLine) + $(if ($diffPatchLines.Count -gt 0) { [Environment]::NewLine } else { '' }))
}
catch {
    $runnerState = 'failed'
    if ($exitCode -eq 0) { $exitCode = 1 }
    $diffMessage = "Git artifact write failed: $($_.Exception.Message)"
    $caughtError = if ([string]::IsNullOrWhiteSpace($caughtError)) { $diffMessage } else { "$caughtError; $diffMessage" }
}

$commands = @()
$usage = $null
$probeCommands = @()
try {
    $eventEvidence = Get-EventEvidence -EventsPath $eventsPath
    $commands = @($eventEvidence.Commands)
    $usage = $eventEvidence.Usage
    $probeCommands = @($eventEvidence.ProbeCommands)
    Write-JsonAtomic -Path $commandsPath -Value $commands
}
catch {
    $runnerState = 'failed'
    if ($exitCode -eq 0) { $exitCode = 1 }
    $eventMessage = "Event evidence collection failed: $($_.Exception.Message)"
    $caughtError = if ([string]::IsNullOrWhiteSpace($caughtError)) { $eventMessage } else { "$caughtError; $eventMessage" }
    try { Write-JsonAtomic -Path $commandsPath -Value @() }
    catch { }
}
$commandSucceeded = @($commands | Where-Object { $_.exit_code -eq 0 }).Count
$commandFailed = @($commands | Where-Object { $null -ne $_.exit_code -and $_.exit_code -ne 0 }).Count

$workerClaim = $null
$claimedVerification = @()
$workerSummary = $null
$workerRisks = @()
$finalSchemaValid = $false
$finalParseMode = $null
if (Test-Path -LiteralPath $finalPath -PathType Leaf) {
    try {
        if ((Get-Item -LiteralPath $finalPath).Length -gt 262144) {
            throw 'Worker final message exceeds the 256 KiB limit.'
        }
        $parsedFinal = ConvertFrom-WorkerFinalText -Text (Get-Content -LiteralPath $finalPath -Raw)
        $workerFinal = $parsedFinal.Value
        $finalParseMode = $parsedFinal.ParseMode
        $finalCheck = Test-WorkerFinal -Value $workerFinal
        if (-not $finalCheck.Valid) { throw $finalCheck.Error }
        $finalSchemaValid = $true
        $workerClaim = [string]$workerFinal.status
        $workerSummary = [string]$workerFinal.summary
        $claimedVerification = @($workerFinal.claimed_verification)
        $workerRisks = @($workerFinal.risks_or_followups)
    }
    catch {
        $workerRisks += "The worker final message was not valid against the expected JSON contract: $($_.Exception.Message)"
    }
}
else {
    $workerRisks += 'The worker did not produce a final result file.'
}
if (-not [string]::IsNullOrWhiteSpace($caughtError)) {
    $workerRisks += $caughtError
}
if (-not $finalSchemaValid -and $runnerState -eq 'completed' -and -not $WorkspaceProbe) {
    $runnerState = 'failed'
    if ($exitCode -eq 0) { $exitCode = 1 }
}

$workspaceProbeOk = $null
if ($WorkspaceProbe) {
    $probeAbsolutePath = [System.IO.Path]::GetFullPath((Join-Path $resolvedWorkdir $workspaceProbeRelativePath))
    $probeCommandSucceeded = @($probeCommands | Where-Object {
        $_.exit_code -eq 0 -and
        ([string]$_.output).Contains($workspaceProbeToken)
    }).Count -gt 0
    $workspaceProbeOk = [bool](
        $probeCommandSucceeded -and
        -not (Test-Path -LiteralPath $probeAbsolutePath) -and
        -not (Test-Path -LiteralPath $workspaceProbeScriptPath) -and
        $newlyChanged.Count -eq 0 -and
        $overlap.Count -eq 0 -and
        -not $gitIndexChanged)
    if (-not $workspaceProbeOk) {
        $runnerState = 'failed'
        if ($exitCode -eq 0) { $exitCode = 1 }
        $workerRisks += 'Workspace probe failed: the sandbox did not complete the create/read/delete round trip.'
    }
}

$durationSeconds = if ($null -ne $endedAtUtc) { [math]::Round(($endedAtUtc - $startedAtUtc).TotalSeconds, 3) } else { $null }
$publishable = [bool]($runnerState -eq 'completed' -and $finalSchemaValid -and $workerClaim -eq 'completed')
$unverifiedPartialChanges = [bool](-not $publishable -and $changedFiles.Count -gt 0)

$status.runner_state = $runnerState
$status.workspace_probe_ok = $workspaceProbeOk
$status.worker_claim = $workerClaim
$status.head_after = $after.Head
$status.ended_at_utc = $endedAtUtc.ToString('o')
$status.exit_code = $exitCode
$status.preexisting_changed_files = @($preexistingFiles)
$status.newly_changed_files = @($newlyChanged)
$status.overlap_with_preexisting = @($overlap)
$status.changed_files = @($changedFiles)
$status.git_index_changed = $gitIndexChanged
$status.claimed_verification = @($claimedVerification)
$status.final_schema_valid = $finalSchemaValid
$status.final_parse_mode = $finalParseMode
$status.duration_seconds = $durationSeconds
$status.usage = $usage
$status.command_total = $commands.Count
$status.command_succeeded = $commandSucceeded
$status.command_failed = $commandFailed
$status.failure_reason = if ($runnerState -eq 'completed') { $null } else { ($workerRisks -join '; ') }
$status.unverified_partial_changes = $unverifiedPartialChanges
$status.prompt_deleted = $promptDeleted
Write-JsonAtomic -Path $statusPath -Value $status

$verifiedCommands = @($commands | Where-Object { $_.exit_code -eq 0 } | Select-Object -Last 12 | ForEach-Object {
    $text = [string]$_.command
    if ($text.Length -gt 240) { $text = $text.Substring(0, 237) + '...' }
    [ordered]@{ command = $text; exit_code = $_.exit_code }
})
$failedCommands = @($commands | Where-Object { $null -ne $_.exit_code -and $_.exit_code -ne 0 } | Select-Object -Last 12 | ForEach-Object {
    $text = [string]$_.command
    if ($text.Length -gt 240) { $text = $text.Substring(0, 237) + '...' }
    [ordered]@{ command = $text; exit_code = $_.exit_code }
})

if ($null -ne $resolvedResultFile -and $publishable) {
    $temporaryResultFile = "$resolvedResultFile.$([Guid]::NewGuid().ToString('N')).tmp"
    Write-Utf8Text -Path $temporaryResultFile -Text ($workerFinal | ConvertTo-Json -Depth 20 -Compress)
    Move-Item -LiteralPath $temporaryResultFile -Destination $resolvedResultFile -Force
}

$compactResult = [ordered]@{
    run_id = $runId
    correlation_id = $CorrelationId
    product_version = $productVersion
    source_commit = $sourceCommit
    runner_contract_version = $runnerContractVersion
    result_schema_version = $resultSchemaVersion
    runner_state = $runnerState
    workspace_probe = [bool]$WorkspaceProbe
    workspace_probe_ok = $workspaceProbeOk
    worker_claim = $workerClaim
    final_schema_valid = $finalSchemaValid
    final_parse_mode = $finalParseMode
    exit_code = $exitCode
    duration_seconds = $durationSeconds
    usage = $usage
    summary = $workerSummary
    changed_files = @($changedFiles)
    newly_changed_files = @($newlyChanged)
    overlap_with_preexisting = @($overlap)
    git_index_changed = $gitIndexChanged
    diff_stat = @($diffStatLines)
    command_total = $commands.Count
    command_succeeded = $commandSucceeded
    command_failed = $commandFailed
    verified_commands = @($verifiedCommands)
    failed_commands = @($failedCommands)
    commands_truncated = [bool]($commands.Count -gt ($verifiedCommands.Count + $failedCommands.Count))
    claimed_verification = @($claimedVerification)
    risks = @($workerRisks)
    failure_reason = if ($runnerState -eq 'completed') { $null } else { ($workerRisks -join '; ') }
    unverified_partial_changes = $unverifiedPartialChanges
    powershell7_path = $powerShell7.Path
    powershell7_version = $powerShell7.Version
    prompt_deleted = $promptDeleted
    artifact_path = $runDir
}
$compactResult | ConvertTo-Json -Depth 8 -Compress | Write-Output
exit $exitCode
