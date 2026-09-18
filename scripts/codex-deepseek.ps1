#Requires -Version 7.0

[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromPipeline = $true)]
    [AllowEmptyString()]
    [string]$StdinText,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CodexArguments
)

begin {
    $stdinBuffer = New-Object System.Collections.Generic.List[string]
}

process {
    if ($PSBoundParameters.ContainsKey('StdinText')) {
        $stdinBuffer.Add($StdinText)
    }
}

end {
    $ErrorActionPreference = 'Stop'

    $codexHome = if ($env:CODEX_HOME) {
        [System.IO.Path]::GetFullPath($env:CODEX_HOME)
    }
    else {
        Join-Path $env:USERPROFILE '.codex'
    }

    $installRoot = if ($env:CODEX_DEEPSEEK_WORKER_ROOT) {
        [System.IO.Path]::GetFullPath($env:CODEX_DEEPSEEK_WORKER_ROOT)
    }
    else {
        Join-Path $env:LOCALAPPDATA 'CodexDeepSeekWorker'
    }

    $keyFile = if ($env:CODEX_DEEPSEEK_KEY_FILE) {
        [System.IO.Path]::GetFullPath($env:CODEX_DEEPSEEK_KEY_FILE)
    }
    else {
        Join-Path $installRoot 'deepseek-api-key.txt'
    }

    $releaseManifestPath = Join-Path $installRoot 'release-manifest.json'
    $supportedCliVersions = @()
    if (Test-Path -LiteralPath $releaseManifestPath -PathType Leaf) {
        try {
            $releaseManifest = Get-Content -LiteralPath $releaseManifestPath -Raw | ConvertFrom-Json
            $supportedCliVersions = @($releaseManifest.supported_codex_cli_versions | ForEach-Object { [string]$_ })
        }
        catch { throw "DeepSeek Worker release manifest is invalid: $releaseManifestPath" }
    }

    $codexCommand = $null
    $codexVersion = $null
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_DEEPSEEK_CODEX_PATH)) {
        $codexCommand = [System.IO.Path]::GetFullPath($env:CODEX_DEEPSEEK_CODEX_PATH)
    }
    else {
        $candidateCommands = New-Object System.Collections.Generic.List[string]
        $npmCodex = if ($env:APPDATA) { Join-Path $env:APPDATA 'npm\codex.cmd' } else { $null }
        if ($null -ne $npmCodex -and (Test-Path -LiteralPath $npmCodex -PathType Leaf)) {
            $candidateCommands.Add($npmCodex)
        }
        foreach ($command in @(Get-Command codex -All -ErrorAction SilentlyContinue)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$command.Source) -and $command.Source -match 'codex(\.cmd|\.exe|\.ps1)?$') {
                if (-not $candidateCommands.Contains([string]$command.Source)) { $candidateCommands.Add([string]$command.Source) }
            }
        }
        foreach ($candidate in $candidateCommands) {
            try {
                $candidateVersionText = (& $candidate --version 2>$null | Select-Object -First 1).ToString().Trim()
                $candidateVersion = if ($candidateVersionText -match '(\d+\.\d+\.\d+)') { $Matches[1] } else { $null }
                if ($null -eq $codexCommand) {
                    $codexCommand = $candidate
                    $codexVersion = $candidateVersion
                }
                if ($supportedCliVersions.Count -gt 0 -and $supportedCliVersions -contains $candidateVersion) {
                    $codexCommand = $candidate
                    $codexVersion = $candidateVersion
                    break
                }
            }
            catch { continue }
        }
    }
    if ([string]::IsNullOrWhiteSpace($codexCommand)) {
        throw 'Codex CLI (codex) was not found on PATH. Set CODEX_DEEPSEEK_CODEX_PATH if codex is installed in a non-standard location.'
    }

    if ($CodexArguments.Count -eq 1 -and $CodexArguments[0] -eq '--version') {
        & $codexCommand --version
        exit $LASTEXITCODE
    }

    if ($null -eq $codexVersion) {
        $versionText = (& $codexCommand --version 2>$null | Select-Object -First 1).ToString().Trim()
        $codexVersion = if ($versionText -match '(\d+\.\d+\.\d+)') { $Matches[1] } else { $null }
    }
    if ($supportedCliVersions.Count -gt 0 -and $supportedCliVersions -notcontains $codexVersion) {
        $reportedVersion = if ([string]::IsNullOrWhiteSpace($codexVersion)) { '<unparsed>' } else { $codexVersion }
        Write-Warning "Codex CLI $reportedVersion is outside the verified matrix ($($supportedCliVersions -join ', ')). Run the Worker -WorkspaceProbe after CLI upgrades."
    }

    for ($index = 0; $index -lt $CodexArguments.Count; $index++) {
        $argument = $CodexArguments[$index]
        if ($argument -in @('--profile', '-p', '--model', '-m', '--ask-for-approval', '-a', '--enable', '--disable')) {
            throw "Caller override is not allowed for the pinned DeepSeek Worker launcher: $argument"
        }
        if ($argument -in @('-c', '--config') -and $index + 1 -lt $CodexArguments.Count) {
            $configOverride = $CodexArguments[$index + 1].Trim('"')
            if ($configOverride -match '^(model|model_provider|approval_policy|web_search|shell_environment_policy\.|features\.|mcp_servers\.)') {
                throw "Caller config override is not allowed for the pinned DeepSeek Worker launcher: $configOverride"
            }
        }
    }
    if (-not (Test-Path -LiteralPath $keyFile -PathType Leaf)) {
        throw "DeepSeek Worker key file not found: $keyFile"
    }

    $deepSeekApiKey = [System.IO.File]::ReadAllText($keyFile).Trim()
    if ([string]::IsNullOrWhiteSpace($deepSeekApiKey)) {
        throw "DeepSeek Worker key file is empty: $keyFile"
    }

    $modelCatalogPath = Join-Path $installRoot 'models.json'
    if (-not (Test-Path -LiteralPath $modelCatalogPath -PathType Leaf)) {
        throw "DeepSeek Worker model catalog not found: $modelCatalogPath"
    }
    $modelCatalogTomlPath = $modelCatalogPath.Replace('\', '/')

    $globalFixedArguments = @(
        '--profile', 'deepseek-worker',
        '--ask-for-approval', 'never'
    )
    $execFixedArguments = @(
        '--model', 'deepseek-flash',
        '-c', 'model_reasoning_effort="max"',
        '-c', 'model_provider="deepseek-worker-secure"',
        '-c', 'model_providers.deepseek-worker-secure.name="deepseek"',
        '-c', 'model_providers.deepseek-worker-secure.base_url="https://api.deepseek.com/"',
        '-c', 'model_providers.deepseek-worker-secure.wire_api="responses"',
        '-c', 'model_providers.deepseek-worker-secure.env_key="DEEPSEEK_API_KEY"',
        '-c', ('model_catalog_json="' + $modelCatalogTomlPath + '"'),
        '-c', 'model_context_window=1000000',
        '-c', 'model_auto_compact_token_limit=900000',
        '-c', 'model_auto_compact_token_limit_scope="body_after_prefix"',
        '-c', 'web_search="disabled"',
        '-c', 'notify=[]',
        '-c', 'analytics.enabled=false',
        '-c', 'feedback.enabled=false',
        '-c', 'otel.exporter="none"',
        '-c', 'otel.metrics_exporter="none"',
        '-c', 'otel.trace_exporter="none"',
        '-c', 'otel.log_user_prompt=false',
        '-c', 'shell_environment_policy.ignore_default_excludes=false',
        '-c', 'features.apps=false',
        '-c', 'features.plugins=false',
        '-c', 'features.remote_plugin=false',
        '-c', 'features.plugin_sharing=false',
        '-c', 'features.recommended_plugins=false',
        '-c', 'features.memories=false',
        '-c', 'features.multi_agent=false',
        '-c', 'features.hooks=false',
        '-c', 'mcp_servers.node_repl.enabled=false',
        '-c', 'mcp_servers.openaiDeveloperDocs.enabled=false'
    )

    # A shared CODEX_HOME avoids competing Windows sandbox account state. Disable
    # every conventionally declared MCP server at CLI priority so user MCPs are
    # not started in the worker process. No values or credentials are read.
    $configCandidates = New-Object System.Collections.Generic.List[string]
    $userConfig = Join-Path $codexHome 'config.toml'
    if (Test-Path -LiteralPath $userConfig -PathType Leaf) {
        $configCandidates.Add($userConfig)
    }
    $workdirIndex = [Array]::IndexOf([string[]]$CodexArguments, '-C')
    if ($workdirIndex -lt 0) {
        $workdirIndex = [Array]::IndexOf([string[]]$CodexArguments, '--cd')
    }
    if ($workdirIndex -ge 0 -and $workdirIndex + 1 -lt $CodexArguments.Count) {
        $cursor = [System.IO.DirectoryInfo]::new([System.IO.Path]::GetFullPath($CodexArguments[$workdirIndex + 1]))
        while ($null -ne $cursor) {
            $projectConfig = Join-Path $cursor.FullName '.codex\config.toml'
            if (Test-Path -LiteralPath $projectConfig -PathType Leaf) {
                $configCandidates.Add($projectConfig)
            }
            $cursor = $cursor.Parent
        }
    }
    $mcpNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($configFile in $configCandidates) {
        foreach ($line in [System.IO.File]::ReadLines($configFile)) {
            if ($line -match '^\s*\[\s*mcp_servers\.(?:"((?:\\.|[^"])*)"|([A-Za-z0-9_-]+))\s*\]\s*(?:#.*)?$') {
                $name = if ($Matches[1]) { $Matches[1] -replace '\\"', '"' -replace '\\\\', '\' } else { $Matches[2] }
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    [void]$mcpNames.Add($name)
                }
            }
        }
    }
    foreach ($name in $mcpNames) {
        $escapedName = $name.Replace('\', '\\').Replace('"', '\"')
        $execFixedArguments += @('-c', ('mcp_servers."' + $escapedName + '".enabled=false'))
    }
    # Keep all critical overrides in the top-level CLI layer. This is the same
    # precedence level used by the working local launcher and it is evaluated
    # before configured MCP transports are initialized.
    $effectiveArguments = @($globalFixedArguments) + @($execFixedArguments) + @($CodexArguments)

    $previousCodexHome = $env:CODEX_HOME
    $previousPermissionProfile = $env:CODEX_PERMISSION_PROFILE
    $previousThreadId = $env:CODEX_THREAD_ID
    $previousOriginator = $env:CODEX_INTERNAL_ORIGINATOR_OVERRIDE
    $previousDeepSeekApiKey = $env:DEEPSEEK_API_KEY

    try {
        $env:CODEX_HOME = $codexHome
        $env:DEEPSEEK_API_KEY = $deepSeekApiKey
        Remove-Item Env:CODEX_PERMISSION_PROFILE -ErrorAction SilentlyContinue
        Remove-Item Env:CODEX_THREAD_ID -ErrorAction SilentlyContinue
        Remove-Item Env:CODEX_INTERNAL_ORIGINATOR_OVERRIDE -ErrorAction SilentlyContinue

        if ($stdinBuffer.Count -gt 0) {
            $payload = $stdinBuffer -join [Environment]::NewLine
            Write-Output -NoEnumerate $payload | & $codexCommand @effectiveArguments
        }
        else {
            & $codexCommand @effectiveArguments
        }
        $exitCode = $LASTEXITCODE
    }
    finally {
        if ($null -eq $previousCodexHome) {
            Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
        }
        else {
            $env:CODEX_HOME = $previousCodexHome
        }

        if ($null -eq $previousPermissionProfile) {
            Remove-Item Env:CODEX_PERMISSION_PROFILE -ErrorAction SilentlyContinue
        }
        else {
            $env:CODEX_PERMISSION_PROFILE = $previousPermissionProfile
        }

        if ($null -eq $previousThreadId) {
            Remove-Item Env:CODEX_THREAD_ID -ErrorAction SilentlyContinue
        }
        else {
            $env:CODEX_THREAD_ID = $previousThreadId
        }

        if ($null -eq $previousOriginator) {
            Remove-Item Env:CODEX_INTERNAL_ORIGINATOR_OVERRIDE -ErrorAction SilentlyContinue
        }
        else {
            $env:CODEX_INTERNAL_ORIGINATOR_OVERRIDE = $previousOriginator
        }

        if ($null -eq $previousDeepSeekApiKey) {
            Remove-Item Env:DEEPSEEK_API_KEY -ErrorAction SilentlyContinue
        }
        else {
            $env:DEEPSEEK_API_KEY = $previousDeepSeekApiKey
        }
    }

    exit $exitCode
}
