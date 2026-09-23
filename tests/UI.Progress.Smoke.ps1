$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../src/Installer.UI.psm1" -Force
Add-Type -AssemblyName System.Windows.Forms
$form = Show-InstallProgress
try {
    $form.UpdateProgress(50, 100, 'Download: RustDesk')
    $bar = $form.Controls | Where-Object { $_ -is [System.Windows.Forms.ProgressBar] }
    if ($bar.Value -ne 50) { throw 'Download percentage is incorrect.' }
    $form.UpdateProgress(0, 0, 'Instalando RustDesk...')
    if ($bar.Style -ne 'Marquee') { throw 'Installation still shows the previous download percentage.' }
    if ($form.Controls[1].Text -notlike 'Instalando RustDesk*') { throw 'Current installation stage is missing.' }
    $form.UpdateProgress(1, -1, 'Download: Tailscale')
    if ($bar.Style -ne 'Marquee') { throw 'Unknown download length must remain indeterminate.' }
    $form.UpdateProgress(200, 100, 'Concluido')
    if ($bar.Value -ne 100 -or $bar.Style -ne 'Continuous') { throw 'Determinate progress did not recover.' }
    'PASS: progress follows downloads and installation stages.'
}
finally { Close-InstallProgress -Form $form }
