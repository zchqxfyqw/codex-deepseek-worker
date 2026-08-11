[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param()

$ErrorActionPreference = 'Stop'

$installRoot = if ($env:CODEX_DEEPSEEK_WORKER_ROOT) {
    [System.IO.Path]::GetFullPath($env:CODEX_DEEPSEEK_WORKER_ROOT)
}
else {
    Join-Path $env:LOCALAPPDATA 'CodexDeepSeekWorker'
}
$keyFile = Join-Path $installRoot 'deepseek-api-key.txt'

if ($PSCmdlet.ShouldProcess($keyFile, 'Write restricted key file')) {
    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetOwner($identity.User)
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $identity.User,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow)
    [void]$acl.AddAccessRule($rule)

    $secureKey = Read-Host 'Enter DeepSeek API key' -AsSecureString
    if ($null -eq $secureKey -or $secureKey.Length -eq 0) {
        throw 'No API key was entered.'
    }

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    $temporaryKeyFile = Join-Path $installRoot ".deepseek-api-key.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $plainKey = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        [System.IO.File]::WriteAllText($temporaryKeyFile, '', (New-Object System.Text.UTF8Encoding($false)))
        Set-Acl -LiteralPath $temporaryKeyFile -AclObject $acl
        [System.IO.File]::WriteAllText($temporaryKeyFile, $plainKey.Trim(), (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporaryKeyFile -Destination $keyFile -Force
        Set-Acl -LiteralPath $keyFile -AclObject $acl
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        if (Test-Path -LiteralPath $temporaryKeyFile -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryKeyFile -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "Key file configured with restricted ACL: $keyFile"
}
