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
    [switch]$AllowConcurrentSameWorkspace,
    [ValidateSet('read-only', 'workspace-write')]
    [string]$Sandbox = 'read-only',
    [ValidateSet('audit', 'implement', 'quota-first')]
    [string]$Mode,
    [ValidateRange(1, 86400)]
    [int]$TimeoutSeconds = 2700,
    [string]$RunRoot,
    [switch]$DryRun,
    [switch]$Doctor
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
        [string]$Hash = '*'
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
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            continue
        }
        $live += $registration
    }
    return [pscustomobject]@{ Live = @($live); StaleCount = $staleCount }
}

function Get-GitLines {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = @(& git -C $Root -c core.quotepath=false @Arguments 2>$null)
    if ($LASTEXITCODE -ne 0) {
        return @()
    }
    return @($output | ForEach-Object { $_.ToString() })
}

function Get-GitSnapshot {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) {
        return [pscustomobject]@{ Branch = $null; Head = $null; StatusLines = @(); ChangedFiles = @() }
    }
    $branchLines = @(Get-GitLines -Root $Root -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD'))
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
    return [pscustomobject]@{
        Branch = $branch
        Head = $head
        StatusLines = @($statusLines)
        ChangedFiles = @($files | Sort-Object -Unique)
    }
}

function Get-CommandEvidence {
    param([Parameter(Mandatory = $true)][string]$EventsPath)

    $commands = @()
    if (-not (Test-Path -LiteralPath $EventsPath -PathType Leaf)) {
        return @()
    }
    foreach ($line in [System.IO.File]::ReadLines($EventsPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $event = $line | ConvertFrom-Json
            if ($event.type -eq 'item.completed' -and $null -ne $event.item -and $event.item.type -eq 'command_execution') {
                $commandText = $event.item.command
                if ($commandText -is [System.Array]) {
                    $commandText = $commandText -join ' '
                }
                $commands += [ordered]@{
                    command = [string]$commandText
                    exit_code = if ($null -ne $event.item.exit_code) { [int]$event.item.exit_code } else { $null }
                    status = [string]$event.item.status
                }
            }
        }
        catch {
            continue
        }
    }
    return @($commands)
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

function Get-DoctorResult {
    $paths = Get-WorkerPaths
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

    return [ordered]@{
        ok = [bool]($launcherExists -and $schemaExists -and $version -and $profileExists)
        codex_home = $paths.CodexHome
        install_root = $paths.InstallRoot
        launcher = $paths.Launcher
        launcher_exists = $launcherExists
        schema_exists = $schemaExists
        profile_exists = $profileExists
        key_file_exists = $keyFileExists
        cli_version = $version
        model_pinned = [bool]($profileText -match '(?m)^model\s*=\s*"deepseek-v4-flash"')
        responses_api = [bool]($profileText -match '(?m)^wire_api\s*=\s*"responses"')
        env_key_provider = [bool]($profileText -match '(?m)^env_key\s*=\s*"DEEPSEEK_API_KEY"')
        launcher_key_file = [bool]($launcherText -match 'deepseek-api-key\.txt')
        live_registrations = @($registrationScan.Live).Count
        stale_registrations_removed = [int]$registrationScan.StaleCount
        run_root = $paths.RunRoot
        note = 'Read-only offline diagnostic. It does not call the model or reveal credentials.'
    }
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
    (Get-DoctorResult | ConvertTo-Json -Depth 6 -Compress) | Write-Output
    exit 0
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

if ($DryRun) {
    [ordered]@{
        dry_run = $true
        physical_workdir = $resolvedWorkdir
        git_root = $gitRoot
        coordination_root = $coordinationRoot
        coordination_mode = $coordinationMode
        sandbox = $Sandbox
        mode = $Mode
        network = [bool]$AllowNetwork
        timeout_seconds = $TimeoutSeconds
        ephemeral = [bool]$Ephemeral
        prompt_length = $Prompt.Length
        prompt_sha256 = Get-Sha256Text -Text $Prompt
        model = 'deepseek-v4-flash'
        provider = 'deepseek-worker-secure'
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
$promptStdinPath = Join-Path $runDir 'prompt.stdin'

$before = Get-GitSnapshot -Root $gitRoot
Write-Utf8Text -Path $beforeStatusPath -Text (($before.StatusLines -join [Environment]::NewLine) + $(if ($before.StatusLines.Count -gt 0) { [Environment]::NewLine } else { '' }))

$invocation = [ordered]@{
    run_id = $runId
    physical_workdir = $resolvedWorkdir
    git_root = $gitRoot
    coordination_root = $coordinationRoot
    sandbox = $Sandbox
    coordination_mode = $coordinationMode
    mode = $Mode
    network = [bool]$AllowNetwork
    timeout_seconds = $TimeoutSeconds
    ephemeral = [bool]$Ephemeral
    provider = 'deepseek-worker-secure'
    model = 'deepseek-v4-flash'
    prompt_length = $Prompt.Length
    prompt_sha256 = Get-Sha256Text -Text $Prompt
    prompt_persisted = $false
    allow_concurrent_same_workspace = [bool]$AllowConcurrentSameWorkspace
    created_at_utc = [DateTime]::UtcNow.ToString('o')
}
Write-JsonAtomic -Path $invocationPath -Value $invocation

$status = [ordered]@{
    run_id = $runId
    runner_state = 'planned'
    worker_claim = $null
    physical_workdir = $resolvedWorkdir
    git_root = $gitRoot
    branch = $before.Branch
    head_before = $before.Head
    head_after = $null
    sandbox = $Sandbox
    network = [bool]$AllowNetwork
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
        $registrationScan = Get-LiveRegistrations -RegistryRoot $registryRoot -Hash $hash
        $liveRegistrations = @($registrationScan.Live)
        if (-not $AllowConcurrentSameWorkspace) {
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
        }

        $parentStartTicks = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks.ToString()
        $registrationPath = Join-Path $registryRoot "$hash-$([Guid]::NewGuid().ToString('N')).json"
        $registration = [ordered]@{
            ProcessId = $PID
            ProcessStartTimeUtc = $parentStartTicks
            Mode = $coordinationMode
            Sandbox = $Sandbox
            Bypass = [bool]$AllowConcurrentSameWorkspace
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

    $modeInstruction = switch ($Mode) {
        'audit' { 'Mode: audit. Inspect and reason within the stated scope. Do not modify files.' }
        'implement' { 'Mode: implement. Complete the bounded change and its relevant verification within the granted sandbox.' }
        'quota-first' { 'Mode: quota-first. Own discovery, implementation, relevant tests, and self-review within scope so the orchestrating Codex can rely on the compact evidence bundle instead of repeating routine work.' }
    }
    $Prompt = $Prompt.TrimEnd() + "`n`n$modeInstruction`nFinal output requirement: return exactly one JSON object conforming to the provided output schema. Put only claimed checks in claimed_verification; the runner records command evidence separately. Do not add Markdown fences or prose outside the JSON object."
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
    $powershellExe = (Get-Command powershell.exe -ErrorAction Stop).Source
    $previousChildLauncher = $env:CODEX_DEEPSEEK_CHILD_LAUNCHER
    $previousChildArgs = $env:CODEX_DEEPSEEK_CHILD_ARGS
    try {
        $env:CODEX_DEEPSEEK_CHILD_LAUNCHER = $launcher
        $env:CODEX_DEEPSEEK_CHILD_ARGS = $argumentJsonPath
        $child = Start-Process -FilePath $powershellExe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-OutputFormat', 'Text', '-EncodedCommand', $encodedCommand) -RedirectStandardInput $promptStdinPath -RedirectStandardOutput $eventsPath -RedirectStandardError $stderrPath -WindowStyle Hidden -PassThru
    }
    finally {
        $env:CODEX_DEEPSEEK_CHILD_LAUNCHER = $previousChildLauncher
        $env:CODEX_DEEPSEEK_CHILD_ARGS = $previousChildArgs
    }

    $childStartTicks = $child.StartTime.ToUniversalTime().Ticks.ToString()
    $guardAcquired = Enter-CoordinationGuard -Mutex $guard
    if (-not $guardAcquired) {
        Stop-ProcessTree -ProcessId $child.Id -StartTicks $childStartTicks
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
        Stop-ProcessTree -ProcessId $child.Id -StartTicks $childStartTicks
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
    if ($null -ne $child -and -not $child.HasExited -and $null -ne $childStartTicks) {
        Stop-ProcessTree -ProcessId $child.Id -StartTicks $childStartTicks
    }
}
catch {
    $runnerState = 'failed'
    $exitCode = 1
    $caughtError = $_.Exception.Message
    if ($null -ne $child -and -not $child.HasExited -and $null -ne $childStartTicks) {
        Stop-ProcessTree -ProcessId $child.Id -StartTicks $childStartTicks
    }
}
finally {
    $endedAtUtc = [DateTime]::UtcNow
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
    if ($registrationCreated -and $null -ne $registrationPath) {
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
    if ($null -ne $guard) { $guard.Dispose() }
}

if ($null -ne $resolvedResultFile -and (Test-Path -LiteralPath $finalPath -PathType Leaf)) {
    Copy-Item -LiteralPath $finalPath -Destination $resolvedResultFile -Force
}

$after = Get-GitSnapshot -Root $gitRoot
Write-Utf8Text -Path $afterStatusPath -Text (($after.StatusLines -join [Environment]::NewLine) + $(if ($after.StatusLines.Count -gt 0) { [Environment]::NewLine } else { '' }))

$preexistingFiles = @($before.ChangedFiles)
$changedFiles = @($after.ChangedFiles)
$newlyChanged = @($changedFiles | Where-Object { $preexistingFiles -notcontains $_ } | Sort-Object -Unique)
$overlap = @($changedFiles | Where-Object { $preexistingFiles -contains $_ } | Sort-Object -Unique)
Write-Utf8Text -Path $changedFilesPath -Text (($changedFiles -join [Environment]::NewLine) + $(if ($changedFiles.Count -gt 0) { [Environment]::NewLine } else { '' }))

$diffStatLines = @()
$diffPatchLines = @()
if ($null -ne $gitRoot) {
    $diffStatLines = @(Get-GitLines -Root $gitRoot -Arguments @('diff', '--stat', 'HEAD'))
    $diffPatchLines = @(Get-GitLines -Root $gitRoot -Arguments @('diff', '--binary', 'HEAD'))
    foreach ($line in $after.StatusLines) {
        if ($line.StartsWith('?? ')) {
            $diffStatLines += "untracked: $($line.Substring(3).Trim())"
        }
    }
}
Write-Utf8Text -Path $diffStatPath -Text (($diffStatLines -join [Environment]::NewLine) + $(if ($diffStatLines.Count -gt 0) { [Environment]::NewLine } else { '' }))
Write-Utf8Text -Path $diffPatchPath -Text (($diffPatchLines -join [Environment]::NewLine) + $(if ($diffPatchLines.Count -gt 0) { [Environment]::NewLine } else { '' }))

$commands = @(Get-CommandEvidence -EventsPath $eventsPath)
Write-JsonAtomic -Path $commandsPath -Value $commands

$workerClaim = $null
$claimedVerification = @()
$workerSummary = $null
$workerRisks = @()
if (Test-Path -LiteralPath $finalPath -PathType Leaf) {
    try {
        $workerFinal = Get-Content -LiteralPath $finalPath -Raw | ConvertFrom-Json
        $workerClaim = [string]$workerFinal.status
        $workerSummary = [string]$workerFinal.summary
        $claimedVerification = @($workerFinal.claimed_verification)
        $workerRisks = @($workerFinal.risks_or_followups)
    }
    catch {
        $workerRisks += 'The worker final message was not valid against the expected JSON contract.'
    }
}
else {
    $workerRisks += 'The worker did not produce a final result file.'
}
if (-not [string]::IsNullOrWhiteSpace($caughtError)) {
    $workerRisks += $caughtError
}

$status.runner_state = $runnerState
$status.worker_claim = $workerClaim
$status.head_after = $after.Head
$status.ended_at_utc = $endedAtUtc.ToString('o')
$status.exit_code = $exitCode
$status.preexisting_changed_files = @($preexistingFiles)
$status.newly_changed_files = @($newlyChanged)
$status.overlap_with_preexisting = @($overlap)
$status.changed_files = @($changedFiles)
$status.claimed_verification = @($claimedVerification)
Write-JsonAtomic -Path $statusPath -Value $status

$verifiedCommands = @($commands | Where-Object { $_.exit_code -eq 0 } | Select-Object -First 12 | ForEach-Object {
    $text = [string]$_.command
    if ($text.Length -gt 240) { $text = $text.Substring(0, 237) + '...' }
    [ordered]@{ command = $text; exit_code = $_.exit_code }
})

$compactResult = [ordered]@{
    run_id = $runId
    runner_state = $runnerState
    worker_claim = $workerClaim
    exit_code = $exitCode
    summary = $workerSummary
    changed_files = @($changedFiles)
    newly_changed_files = @($newlyChanged)
    overlap_with_preexisting = @($overlap)
    diff_stat = @($diffStatLines)
    verified_commands = @($verifiedCommands)
    claimed_verification = @($claimedVerification)
    risks = @($workerRisks)
    artifact_path = $runDir
}
$compactResult | ConvertTo-Json -Depth 8 -Compress | Write-Output
exit $exitCode
