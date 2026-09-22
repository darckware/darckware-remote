Describe 'install.ps1 contract' {
    BeforeAll { $script:Content = Get-Content "$PSScriptRoot/../install.ps1" -Raw }

    It 'does not define plain-text secret parameters' {
        $script:Content | Should -Not -Match '\[string\]\s*\$(TailscaleAuthKey|RustDeskPassword)\b'
        $script:Content | Should -Match '\[string\]\s*\$TailscaleAuthKeyFile\b'
        $script:Content | Should -Match '\[string\]\s*\$RustDeskPasswordFile\b'
    }

    It 'defines stable success, failure, invalid-input, and UAC-cancel exit codes' {
        $script:Content | Should -Match 'exit\s+0\b'
        $script:Content | Should -Match 'exit\s+1\b'
        $script:Content | Should -Match 'exit\s+2\b'
        $script:Content | Should -Match '1223'
    }

    It 'reads secret files into SecureString values and removes no caller-owned file' {
        $script:Content | Should -Match 'ConvertTo-SecureString'
        $script:Content | Should -Match 'TrimEnd\(\[char\[\]\]'
        $script:Content | Should -Not -Match 'Remove-Item[^\r\n]+(TailscaleAuthKeyFile|RustDeskPasswordFile)'
    }
}

Describe 'install.cmd contract' {
    It 'is the stable PowerShell launcher' {
        $lines = @(Get-Content "$PSScriptRoot/../install.cmd")
        $lines | Should -HaveCount 4
        $lines[0] | Should -Be '@echo off'
        $lines[1] | Should -Be 'setlocal'
        $lines[2] | Should -Be 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*'
        $lines[3] | Should -Be 'exit /b %ERRORLEVEL%'
    }
}
