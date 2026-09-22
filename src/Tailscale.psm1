Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Security.psm1') -Force

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
    }
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
