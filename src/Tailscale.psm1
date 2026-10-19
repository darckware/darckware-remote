Set-StrictMode -Version Latest

# Reuse the dependency so commands already imported by the launcher stay available.
Import-Module (Join-Path $PSScriptRoot 'Security.psm1')

function Test-TailscaleHostname {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Hostname
    )

    if ([string]::IsNullOrEmpty($Hostname) -or $Hostname.Length -gt 63) {
        return $false
    }

    return $Hostname -cmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
}

function Get-TailscaleExecutable {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $command = Get-Command 'tailscale.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    if (-not [string]::IsNullOrEmpty($env:ProgramFiles)) {
        $installedPath = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
        if (Test-Path -LiteralPath $installedPath -PathType Leaf) {
            return $installedPath
        }
    }

    throw 'tailscale.exe was not found.'
}

function Invoke-TailscaleCommand {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [string[]]$Arguments
    )

    $executable = Get-TailscaleExecutable
    $output = & $executable @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    [pscustomobject]@{
        ExitCode = $exitCode
        Output = ($output | Out-String).Trim()
    }
}

function Get-TailscaleStatus {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $command = Invoke-TailscaleCommand -Arguments @('status', '--json')
    if ($command.ExitCode -ne 0) {
        # A client signed in through the tray icon is owned by that Windows user, and
        # tailscaled answers every other account with "already in use by <user>" -- the
        # tailnet is up, only the CLI is closed to us. The adapter's address shows that.
        if ($command.Output -match 'already in use by') {
            $adapterIPs = @(Get-TailscaleAdapterAddress)
            if ($adapterIPs.Count -gt 0) {
                return [pscustomobject]@{
                    Connected = $true
                    BackendState = 'Running'
                    TailscaleIPs = $adapterIPs
                    Source = 'Adapter'
                }
            }
        }
        throw 'Tailscale status command failed.'
    }

    try {
        $status = $command.Output | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw 'Tailscale status returned invalid JSON.'
    }

    $backendState = [string]$status.BackendState
    $tailscaleIPs = @($status.TailscaleIPs | Where-Object {
        -not [string]::IsNullOrEmpty([string]$_)
    })

    [pscustomobject]@{
        Connected = ($backendState -ceq 'Running' -and $tailscaleIPs.Count -gt 0)
        BackendState = $backendState
        TailscaleIPs = $tailscaleIPs
        Source = 'Cli'
    }
}

function Test-TailscaleAddress {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Address
    )

    # Tailscale assigns IPv4 addresses from the CGNAT range 100.64.0.0/10.
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) { return $false }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $bytes = $parsed.GetAddressBytes()
    return ($bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127)
}

function Get-TailscaleAdapterAddress {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
        $_.InterfaceAlias -like 'Tailscale*' -and
        [string]$_.AddressState -eq 'Preferred' -and
        (Test-TailscaleAddress -Address ([string]$_.IPAddress))
    })
    return @($addresses | ForEach-Object { [string]$_.IPAddress })
}

function Install-Tailscale {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$MsiPath
    )

    if ([string]::IsNullOrWhiteSpace($MsiPath)) {
        throw 'A verified Tailscale MSI path is required.'
    }

    $arguments = @(
        '/i',
        $MsiPath,
        '/qn',
        '/norestart',
        'TS_UNATTENDEDMODE=always',
        'TS_NOLAUNCH=1'
    )
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments `
        -Wait -PassThru -NoNewWindow -ErrorAction Stop
    $exitCode = [int]$process.ExitCode

    if ($exitCode -notin @(0, 1641, 3010)) {
        throw "Tailscale MSI failed with exit code $exitCode."
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        RebootRequired = ($exitCode -in @(1641, 3010))
    }
}

function Connect-Tailscale {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Hostname,

        [Parameter(Mandatory)]
        [System.Security.SecureString]$AuthKey,

        [Parameter(Mandatory)]
        [string]$SecretDirectory
    )

    if (-not (Test-TailscaleHostname -Hostname $Hostname)) {
        throw 'Tailscale hostname must be a DNS-safe label of at most 63 characters.'
    }

    $currentStatus = Get-TailscaleStatus
    if ($currentStatus.Connected) {
        return $currentStatus
    }

    $secretPath = New-ProtectedSecretFile -Secret $AuthKey -Directory $SecretDirectory
    try {
        $arguments = @(
            'up',
            "--auth-key=file:$secretPath",
            "--hostname=$Hostname",
            '--unattended=true'
        )
        $command = Invoke-TailscaleCommand -Arguments $arguments
        if ($command.ExitCode -ne 0) {
            throw 'Tailscale enrollment failed.'
        }

        $status = Get-TailscaleStatus
        if (-not $status.Connected) {
            throw 'Tailscale did not reach Running state.'
        }

        return $status
    }
    finally {
        Remove-SecretFile -Path $secretPath
    }
}

Export-ModuleMember -Function @(
    'Test-TailscaleHostname',
    'Get-TailscaleStatus',
    'Install-Tailscale',
    'Connect-Tailscale'
)
