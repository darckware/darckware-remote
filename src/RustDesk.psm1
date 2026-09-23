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

    # Windows PowerShell does not reliably wait for GUI executables invoked with &.
    # Redirect both streams explicitly and quote each native Windows argument.
    $quotedArguments = foreach ($argument in $Arguments) {
        $escaped = [regex]::Replace($argument, '(\\*)"', '$1$1\"')
        $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
        '"' + $escaped + '"'
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ExecutablePath
    $startInfo.Arguments = $quotedArguments -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            throw 'RustDesk command did not exit within 30 seconds.'
        }
        if (-not $stdout.Wait(5000) -or -not $stderr.Wait(5000)) {
            throw 'RustDesk command output did not close within the deadline.'
        }
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = $stdout.Result.Trim()
        }
    }
    finally { $process.Dispose() }
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
            -PassThru -WindowStyle Hidden -ErrorAction Stop
        try {
            # Start-Process -Wait also waits for the persistent RustDesk children.
            # Wait only for the installer itself, with a bounded deadline.
            if (-not $process.WaitForExit(120000)) {
                throw 'RustDesk installer did not exit within 120 seconds. Check its status before retrying.'
            }
            if ($null -eq $process.ExitCode -or [int]$process.ExitCode -ne 0) {
                throw "RustDesk installer failed with exit code $($process.ExitCode)."
            }
        }
        finally { $process.Dispose() }
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
