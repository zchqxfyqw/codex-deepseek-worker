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

    $secureKey = Read-Host 'Enter DeepSeek API key' -AsSecureString
    if ($null -eq $secureKey -or $secureKey.Length -eq 0) {
        throw 'No API key was entered.'
    }

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    try {
        $plainKey = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        [System.IO.File]::WriteAllText($keyFile, $plainKey.Trim(), (New-Object System.Text.UTF8Encoding($false)))
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetOwner($identity.User)
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $identity.User,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow)
    [void]$acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $keyFile -AclObject $acl

    Write-Host "Key file configured with restricted ACL: $keyFile"
}
