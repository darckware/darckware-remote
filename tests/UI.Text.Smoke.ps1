$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../src/Installer.UI.psm1" -Force
Add-Type -AssemblyName System.Windows.Forms

# ASCII source keeps the expected Unicode independent of this script's encoding.
$expectedTitle = 'Darckware Remoto ' + [char]0x2014 + ' Instala' + [char]0x00E7 + [char]0x00E3 + 'o'
$expectedHeading = 'O que ser' + [char]0x00E1 + ' instalado?'
$expectedTailscale = 'Tailscale ' + [char]0x2014 + ' conex' + [char]0x00E3 + 'o segura ' + [char]0x00E0 + ' tailnet'
$script:capturedTitle = $null
$script:capturedText = @()
function Read-ControlText($Control) {
    $Control.Text
    foreach ($child in $Control.Controls) { Read-ControlText $child }
}
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({
    foreach ($window in @([System.Windows.Forms.Application]::OpenForms)) {
        if ($window.Visible -and $window.Text -like 'Darckware Remoto*') {
            $timer.Stop()
            $script:capturedTitle = $window.Text
            $script:capturedText = @(Read-ControlText $window)
            $window.DialogResult = 'Cancel'
            $window.Close()
        }
    }
})
try {
    $timer.Start()
    $result = Show-InstallerWizard -Config ([pscustomobject]@{})
    if ($script:capturedTitle -cne $expectedTitle) { throw 'Wizard title has incorrect Unicode text.' }
    if ($script:capturedText -cnotcontains $expectedHeading) { throw 'Wizard heading has incorrect accents.' }
    if ($script:capturedText -cnotcontains $expectedTailscale) { throw 'Tailscale label has incorrect accents.' }
    if ($null -ne $result) { throw 'Cancelling the wizard returned an installation request.' }
    'PASS: wizard displays Portuguese accents and punctuation correctly.'
}
finally { $timer.Stop(); $timer.Dispose() }
