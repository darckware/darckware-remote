Set-StrictMode -Version Latest

function New-RustDeskConfigToken {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Host,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Relay
    )

    $configuration = [ordered]@{
        key = $Key
        host = $Host
        api = ''
        relay = $Relay
    }
    $json = $configuration | ConvertTo-Json -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $base64Url = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return -join $base64Url.ToCharArray()[($base64Url.Length - 1)..0]
}

function Invoke-RustDeskCommand {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][ValidateNotNull()][string[]]$Arguments
    )

    $output = & $ExecutablePath @Arguments 2>&1
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($output | Out-String).Trim()
    }
}

function Wait-RustDeskService {
    [CmdletBinding()]
    param()

    $service = Get-Service -Name 'RustDesk' -ErrorAction Stop
    if ($service.Status -ne 'Running') {
        Start-Service -Name 'RustDesk' -ErrorAction Stop
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $service = Get-Service -Name 'RustDesk' -ErrorAction Stop
        if ($service.Status -eq 'Running') {
            return
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    throw 'RustDesk service did not reach Running state.'
}

function Install-RustDesk {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$InstallerPath)

    if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
        throw 'A verified RustDesk installer path is required.'
    }
    if ([string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        throw 'Program Files could not be located.'
    }

    $executablePath = Join-Path $env:ProgramFiles 'RustDesk\rustdesk.exe'
    $alreadyInstalled = Test-Path -LiteralPath $executablePath -PathType Leaf
    if (-not $alreadyInstalled) {
        $process = Start-Process -FilePath $InstallerPath -ArgumentList @('--silent-install') `
            -Wait -PassThru -NoNewWindow -ErrorAction Stop
        if ([int]$process.ExitCode -ne 0) {
            throw "RustDesk installer failed with exit code $($process.ExitCode)."
        }
        if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
            throw 'RustDesk executable was not found after installation.'
        }
    }

    Wait-RustDeskService
    [pscustomobject]@{
        ExecutablePath = $executablePath
        Installed = -not $alreadyInstalled
        ServiceRunning = $true
    }
}

function Set-RustDeskConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$ConfigToken,
        [System.Security.SecureString]$Password
    )

    $configResult = Invoke-RustDeskCommand -ExecutablePath $ExecutablePath -Arguments @('--config', $ConfigToken)
    if ($configResult.ExitCode -ne 0) {
        throw 'RustDesk server configuration failed.'
    }

    if ($null -eq $Password) {
        return
    }

    $bstr = [IntPtr]::Zero
    $plainText = $null
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $plainText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $passwordResult = Invoke-RustDeskCommand -ExecutablePath $ExecutablePath -Arguments @('--password', $plainText)
        if ($passwordResult.ExitCode -ne 0) {
            throw 'RustDesk password configuration failed.'
        }
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        $plainText = $null
    }
}

function Get-RustDeskId {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$ExecutablePath)

    $result = Invoke-RustDeskCommand -ExecutablePath $ExecutablePath -Arguments @('--get-id')
    if ($result.ExitCode -ne 0) {
        throw 'RustDesk ID query failed.'
    }

    $id = ([string]$result.Output).Trim()
    if ($id -notmatch '^\d+$') {
        throw 'RustDesk returned an invalid ID.'
    }
    return $id
}

Export-ModuleMember -Function @(
    'New-RustDeskConfigToken',
    'Install-RustDesk',
    'Set-RustDeskConfiguration',
    'Get-RustDeskId'
)
