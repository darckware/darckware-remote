$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../src/Installer.UI.psm1" -Force
Add-Type -AssemblyName System.Windows.Forms
function Get-Controls($Control) {
    $Control
    foreach ($child in $Control.Controls) { Get-Controls $child }
}
$script:failure = $null
$script:completed = $false
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({
    $window = @([System.Windows.Forms.Application]::OpenForms) | Select-Object -First 1
    if ($null -eq $window) { return }
    $timer.Stop()
    try {
        $controls = @(Get-Controls $window)
        $rustDesk = $controls | Where-Object { $_ -is [System.Windows.Forms.CheckBox] -and $_.Text -like 'RustDesk*' }
        $local = $controls | Where-Object { $_ -is [System.Windows.Forms.RadioButton] -and $_.Text -like 'Usar Tailscale*' }
        $next = $window.AcceptButton
        $back = $controls | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -eq 'Voltar' }
        $rustDesk.Checked = $true
        $next.PerformClick()
        if (-not $local.Visible) { throw 'Connectivity page was not displayed.' }
        $local.Checked = $true
        $next.PerformClick()
        $password = $controls | Where-Object { $_ -is [System.Windows.Forms.TextBox] -and $_.AccessibleName -eq 'Senha permanente do RustDesk' }
        if (-not $password.Visible) { throw 'Continue did not advance from local Tailscale to the access page.' }
        $back.PerformClick()
        if (-not $local.Visible) { throw 'Back did not return to connectivity.' }
        $next.PerformClick()
        if (-not $password.Visible) { throw 'Continue failed after going back.' }
        $next.PerformClick()
        if ($next.Text -ne 'Instalar') { throw 'Review page was not reached.' }
        # This invokes only the wizard; no installer operations are called.
        $next.PerformClick()
        $script:completed = $true
    }
    catch {
        $script:failure = $_
        $window.DialogResult = 'Cancel'
        $window.Close()
    }
})
try {
    $timer.Start()
    $result = Show-InstallerWizard -Config ([pscustomobject]@{})
    if ($null -ne $script:failure) { throw $script:failure }
    if (-not $script:completed) { throw 'Wizard flow did not complete.' }
    if ($null -eq $result -or -not $result.InstallRustDesk -or $result.InstallTailscale -or $result.ConnectivityMode -ne 'LocalTailscale') {
        throw 'Wizard did not return the selected installation request.'
    }
    'PASS: local Tailscale navigation, back, review and request return.'
}
finally { $timer.Stop(); $timer.Dispose() }
