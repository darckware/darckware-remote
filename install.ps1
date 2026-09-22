[CmdletBinding()]
param(
    [switch]$InstallTailscale,
    [switch]$InstallRustDesk,
    [ValidateSet('Auto', 'LocalTailscale', 'Router')][string]$ConnectivityMode = 'Auto',
    [string]$RouterIp,
    [string]$TailscaleHostname,
    [string]$TailscaleAuthKeyFile,
    [string]$RustDeskPasswordFile,
    [switch]$NonInteractive,
    [switch]$ConfirmRouteReplacement
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-SecretFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Secret file not found: $Path" }
    $value = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path).TrimEnd([char[]]"`r`n")
    if ([string]::IsNullOrEmpty($value)) { throw "Secret file is empty: $Path" }
    try { return ConvertTo-SecureString $value -AsPlainText -Force }
    finally { $value = $null }
}

function Add-ForwardedArgument {
    param([Collections.Generic.List[string]]$List, [string]$Name, $Value, [switch]$Switch)
    if ($Switch) { if ([bool]$Value) { $List.Add("-$Name") }; return }
    if (-not [string]::IsNullOrEmpty([string]$Value)) { $List.Add("-$Name"); $List.Add([string]$Value) }
}

try {
    foreach ($module in @('Artifact', 'Security', 'Network', 'Tailscale', 'RustDesk', 'Installer.Core', 'Installer.UI')) {
        Import-Module (Join-Path $PSScriptRoot "src/$module.psm1") -Force
    }

    if (-not (Test-IsAdministrator)) {
        $arguments = [Collections.Generic.List[string]]::new()
        $arguments.Add('-NoLogo'); $arguments.Add('-NoProfile'); $arguments.Add('-ExecutionPolicy'); $arguments.Add('Bypass'); $arguments.Add('-File'); $arguments.Add($PSCommandPath)
        Add-ForwardedArgument $arguments 'InstallTailscale' $InstallTailscale -Switch
        Add-ForwardedArgument $arguments 'InstallRustDesk' $InstallRustDesk -Switch
        Add-ForwardedArgument $arguments 'ConnectivityMode' $ConnectivityMode
        Add-ForwardedArgument $arguments 'RouterIp' $RouterIp
        Add-ForwardedArgument $arguments 'TailscaleHostname' $TailscaleHostname
        Add-ForwardedArgument $arguments 'TailscaleAuthKeyFile' $TailscaleAuthKeyFile
        Add-ForwardedArgument $arguments 'RustDeskPasswordFile' $RustDeskPasswordFile
        Add-ForwardedArgument $arguments 'NonInteractive' $NonInteractive -Switch
        Add-ForwardedArgument $arguments 'ConfirmRouteReplacement' $ConfirmRouteReplacement -Switch
        try {
            $elevated = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments.ToArray() -Verb RunAs -Wait -PassThru
            exit $elevated.ExitCode
        }
        catch [ComponentModel.Win32Exception] {
            if ($_.Exception.NativeErrorCode -eq 1223) { exit 1223 }
            throw
        }
    }

    $config = Get-InstallerConfig -RepoRoot $PSScriptRoot
    if ($NonInteractive) {
        $mode = $(if ($ConnectivityMode -eq 'Auto') { 'LocalTailscale' } else { $ConnectivityMode })
        $request = [pscustomobject]@{
            InstallTailscale = [bool]$InstallTailscale; InstallRustDesk = [bool]$InstallRustDesk
            ConnectivityMode = $mode; RouterIp = $RouterIp; TailscaleHostname = $TailscaleHostname
            TailscaleAuthKey = Read-SecretFile $TailscaleAuthKeyFile
            RustDeskPassword = Read-SecretFile $RustDeskPasswordFile
            ConfirmRouteReplacement = [bool]$ConfirmRouteReplacement
        }
    }
    else {
        $request = Show-InstallerWizard -Config $config
        if ($null -eq $request) { exit 1223 }
    }

    try { Test-InstallRequest -Request $request }
    catch { [Console]::Error.WriteLine((Protect-LogText $_.Exception.Message)); exit 2 }
    $result = Invoke-DarckwareInstall -Request $request -RepoRoot $PSScriptRoot
    if (-not $NonInteractive) { Show-InstallResult -Result $result }
    exit 0
}
catch {
    $safe = Protect-LogText $_.Exception.Message
    [Console]::Error.WriteLine($safe)
    exit 1
}
