BeforeAll { Import-Module "$PSScriptRoot/../src/Installer.UI.psm1" -Force }

Describe 'Interactive installation progress' {
    It 'switches between measurable downloads and installation stages' {
        $output = & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "$PSScriptRoot/UI.Progress.Smoke.ps1" 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
    }

    BeforeEach {
        New-Item -ItemType Directory -Path "$TestDrive/src" -Force | Out-Null
        # Substitute only the installer boundary: no software or network changes.
        @'
function Invoke-DarckwareInstall {
    param($Request, $RepoRoot, $ProgressAction)
    & $ProgressAction 50 100 'Download: RustDesk'
    Start-Sleep -Milliseconds 500
    & $ProgressAction 0 0 'Instalando RustDesk...'
    Start-Sleep -Milliseconds 500
    if ($Request.Fail) { throw 'simulated installation failure' }
    & $ProgressAction 100 100 'Concluido'
    [pscustomobject]@{ Success = $true; SecretIsSecure = $Request.Secret -is [Security.SecureString] }
}
Export-ModuleMember -Function Invoke-DarckwareInstall
'@ | Set-Content -LiteralPath "$TestDrive/src/Installer.Core.psm1" -Encoding UTF8
    }

    It 'keeps the window responsive during blocking work and returns the result' {
        $form = Show-InstallProgress
        $seen = [Collections.Generic.List[string]]::new()
        $timer = [System.Windows.Forms.Timer]::new()
        $timer.Interval = 50
        $timer.Add_Tick({ $seen.Add($form.Controls[1].Text) }.GetNewClosure())
        try {
            $timer.Start()
            $request = [pscustomobject]@{ Fail = $false; Secret = ConvertTo-SecureString 'fixture' -AsPlainText -Force }
            $result = Invoke-InstallWithProgress -Request $request -RepoRoot $TestDrive -Form $form
            $result.Success | Should -BeTrue
            $result.SecretIsSecure | Should -BeTrue
            ($seen -join '|') | Should -Match 'Download: RustDesk \(50%\)'
            ($seen -join '|') | Should -Match 'Instalando RustDesk'
            $form.Controls[2].Value | Should -Be 100
        }
        finally { $timer.Stop(); $timer.Dispose(); Close-InstallProgress $form }
        $form.IsDisposed | Should -BeTrue
    }

    It 'propagates worker failure without displaying success' {
        $form = Show-InstallProgress
        try {
            { Invoke-InstallWithProgress -Request ([pscustomobject]@{ Fail = $true }) -RepoRoot $TestDrive -Form $form } | Should -Throw '*simulated installation failure*'
            $form.Controls[1].Text | Should -Not -Match 'Concluido'
        }
        finally { Close-InstallProgress $form }
        $form.IsDisposed | Should -BeTrue
    }
}
