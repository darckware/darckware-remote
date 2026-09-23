param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))

# Run in a fresh Windows PowerShell process, as install.cmd does.
$ErrorActionPreference = 'Stop'
$tokens = $null
$parseErrors = $null
$entry = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $RepoRoot 'install.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'The installer entry point could not be parsed.' }
$startup = $entry.EndBlock.Statements |
    Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] } |
    Select-Object -First 1
$rootLiteral = "'" + $RepoRoot.Replace("'", "''") + "'"
$imports = [scriptblock]::Create(
    $startup.Body.Statements[0].Extent.Text.Replace('$PSScriptRoot', $rootLiteral))

& {
    param($Root, $Imports)
    . $Imports
    $config = Get-InstallerConfig -RepoRoot $Root
    if ($null -eq $config) { throw 'Startup did not load the configuration.' }
    if ((Protect-LogText 'startup check') -ne 'startup check') {
        throw 'Startup error reporting is unavailable.'
    }
    Get-Command Show-InstallerWizard -ErrorAction Stop | Out-Null
    Write-Output 'PASS: startup configuration and error reporting are available.'
} $RepoRoot $imports
