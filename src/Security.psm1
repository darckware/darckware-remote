function Protect-LogText {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    $safe = $Text -replace 'tskey-[A-Za-z0-9_-]+', '[REDACTED]'
    $safe = $safe -replace '(?i)(password|authkey|rustdeskPassword)\s*[=:]\s*(?:"[^"]*"|''[^'']*''|\S+)', '$1=[REDACTED]'
    return $safe
}

function Set-SecretFileAcl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $systemSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $administratorsSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $fileSecurity = New-Object System.Security.AccessControl.FileSecurity
    $fileSecurity.SetAccessRuleProtection($true, $false)

    foreach ($sid in @($systemSid, $administratorsSid)) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $fileSecurity.AddAccessRule($rule)
    }

    Set-Acl -LiteralPath $Path -AclObject $fileSecurity -ErrorAction Stop
}

function New-ProtectedSecretFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Security.SecureString]$Secret,
        [Parameter(Mandatory)][string]$Directory
    )

    New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop | Out-Null
    $path = Join-Path $Directory (('{0}.secret' -f [guid]::NewGuid().ToString('N')))
    $bstr = [IntPtr]::Zero

    try {
        New-Item -ItemType File -Path $path -ErrorAction Stop | Out-Null
        Set-SecretFileAcl -Path $path
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
        $plainText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        [System.IO.File]::WriteAllText($path, $plainText, [System.Text.UTF8Encoding]::new($false))
        return $path
    }
    catch {
        Remove-SecretFile -Path $path
        throw
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        $plainText = $null
    }
}

function Remove-SecretFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function Protect-LogText, New-ProtectedSecretFile, Remove-SecretFile
