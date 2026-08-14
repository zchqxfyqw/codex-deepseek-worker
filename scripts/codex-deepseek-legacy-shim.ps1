#Requires -Version 7.0

$ErrorActionPreference = 'Stop'

$installRoot = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_DEEPSEEK_WORKER_ROOT)) {
    [System.IO.Path]::GetFullPath($env:CODEX_DEEPSEEK_WORKER_ROOT)
}
else {
    Join-Path $env:LOCALAPPDATA 'CodexDeepSeekWorker'
}
$runner = Join-Path $installRoot 'codex-deepseek-exec.ps1'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    throw "DeepSeek Worker is not installed at the current managed path: $runner"
}

$powerShell7 = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_DEEPSEEK_PWSH_PATH)) {
    [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($env:CODEX_DEEPSEEK_PWSH_PATH))
}
else {
    Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
}
if ($powerShell7 -match '(?i)\\WindowsApps\\' -or -not (Test-Path -LiteralPath $powerShell7 -PathType Leaf)) {
    throw 'DeepSeek Worker requires a non-Store PowerShell 7 MSI or portable installation.'
}

& $powerShell7 -NoLogo -NoProfile -File $runner @args
exit $LASTEXITCODE
