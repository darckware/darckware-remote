BeforeAll { Import-Module "$PSScriptRoot/../src/RustDesk.psm1" -Force }

BeforeAll {
    function New-InstallerProcessStub([int]$ExitCode = 0, [bool]$Completed = $true) {
        $process = [pscustomobject]@{ ExitCode = $ExitCode; Completed = $Completed }
        $process | Add-Member ScriptMethod WaitForExit { param($Timeout) return $this.Completed }
        $process | Add-Member ScriptMethod Dispose {}
        return $process
    }
}

Describe 'New-RustDeskConfigToken' {
    It 'serializes the exact fixed fields in the format consumed by RustDesk' {
        $token = New-RustDeskConfigToken -Host '100.105.235.114' -Key 'public-key=' -Relay '100.105.235.114:21117'

        $token | Should -Be '9JyNxETMyoDNxEjL1MjMuUDMx4CMwEjI6ISehxWZyJCLiIiOikGchJCLiQTMx4SNzIjL1ATMuADMxIiOiQ3cvhmIsISP5V2atMWasJWdwJiOikXZrJye'
        $forward = -join $token.ToCharArray()[($token.Length - 1)..0]
        $base64 = ($forward -replace '-', '+' -replace '_', '/') + ('=' * ((4 - $forward.Length % 4) % 4))
        $parsed = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($base64)) | ConvertFrom-Json
        $parsed.key | Should -Be 'public-key='
        $parsed.host | Should -Be '100.105.235.114'
        $parsed.api | Should -Be ''
        $parsed.relay | Should -Be '100.105.235.114:21117'
    }
}

Describe 'Install-RustDesk' {
    BeforeEach {
        Mock Start-Process -ModuleName RustDesk { New-InstallerProcessStub }
        Mock Wait-RustDeskService -ModuleName RustDesk {}
    }

    It 'uses the documented silent installer and returns the installed executable' {
        $pathChecks = [System.Collections.Queue]::new()
        $pathChecks.Enqueue($false)
        $pathChecks.Enqueue($true)
        Mock Test-Path -ModuleName RustDesk { $pathChecks.Dequeue() }

        $result = Install-RustDesk -InstallerPath 'C:\cache\rustdesk.exe'

        $result.Installed | Should -BeTrue
        $result.ExecutablePath | Should -Be (Join-Path $env:ProgramFiles 'RustDesk\rustdesk.exe')
        Should -Invoke Start-Process -ModuleName RustDesk -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\cache\rustdesk.exe' -and
            $ArgumentList.Count -eq 1 -and
            $ArgumentList[0] -eq '--silent-install' -and
            -not $Wait -and $PassThru -eq $true
        }
        Should -Invoke Wait-RustDeskService -ModuleName RustDesk -Times 1
    }

    It 'rejects a nonzero installer exit code before waiting for the service' {
        Mock Test-Path -ModuleName RustDesk { $false }
        Mock Start-Process -ModuleName RustDesk { New-InstallerProcessStub -ExitCode 7 }

        { Install-RustDesk -InstallerPath 'C:\cache\rustdesk.exe' } | Should -Throw '*exit code 7*'

        Should -Invoke Wait-RustDeskService -ModuleName RustDesk -Times 0
    }

    It 'reuses an existing installation without running the downloaded EXE' {
        Mock Test-Path -ModuleName RustDesk { $true }

        $result = Install-RustDesk -InstallerPath 'C:\cache\rustdesk.exe'

        $result.Installed | Should -BeFalse
        Should -Invoke Start-Process -ModuleName RustDesk -Times 0
        Should -Invoke Wait-RustDeskService -ModuleName RustDesk -Times 1
    }

    It 'stops before configuration when the installer does not exit by its deadline' {
        Mock Test-Path -ModuleName RustDesk { $false }
        Mock Start-Process -ModuleName RustDesk { New-InstallerProcessStub -Completed $false }
        { Install-RustDesk -InstallerPath 'C:\cache\rustdesk.exe' } | Should -Throw '*120 seconds*'
        Should -Invoke Wait-RustDeskService -ModuleName RustDesk -Times 0
    }
}

Describe 'Set-RustDeskConfiguration' {
    BeforeEach {
        Mock Invoke-RustDeskCommand -ModuleName RustDesk {
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }
    }

    It 'applies the fixed config token on every call' {
        $result = Set-RustDeskConfiguration -ExecutablePath 'C:\Program Files\RustDesk\rustdesk.exe' -ConfigToken 'fixed-token'

        $result | Should -BeNullOrEmpty
        Should -Invoke Invoke-RustDeskCommand -ModuleName RustDesk -Times 1 -Exactly -ParameterFilter {
            $ExecutablePath -eq 'C:\Program Files\RustDesk\rustdesk.exe' -and
            $Arguments.Count -eq 2 -and $Arguments[0] -eq '--config' -and $Arguments[1] -eq 'fixed-token'
        }
    }

    It 'applies an optional secure password without returning or logging its value' {
        $secret = ConvertTo-SecureString 'PermanentSecret42' -AsPlainText -Force

        $result = Set-RustDeskConfiguration -ExecutablePath 'C:\Program Files\RustDesk\rustdesk.exe' -ConfigToken 'fixed-token' -Password $secret

        $result | Should -BeNullOrEmpty
        Should -Invoke Invoke-RustDeskCommand -ModuleName RustDesk -Times 1 -Exactly -ParameterFilter {
            $Arguments.Count -eq 2 -and $Arguments[0] -eq '--password' -and $Arguments[1] -eq 'PermanentSecret42'
        }
        ($result | ConvertTo-Json -Compress) | Should -Not -Match 'PermanentSecret42'
    }

    It 'fails with a generic message that omits a rejected password' {
        Mock Invoke-RustDeskCommand -ModuleName RustDesk {
            if ($Arguments[0] -eq '--password') {
                return [pscustomobject]@{ ExitCode = 1; Output = 'PermanentSecret42' }
            }
            return [pscustomobject]@{ ExitCode = 0; Output = '' }
        }
        $secret = ConvertTo-SecureString 'PermanentSecret42' -AsPlainText -Force

        $message = $null
        try {
            Set-RustDeskConfiguration -ExecutablePath 'C:\Program Files\RustDesk\rustdesk.exe' -ConfigToken 'fixed-token' -Password $secret
        }
        catch {
            $message = $_.Exception.Message
        }

        $message | Should -Be 'RustDesk password configuration failed.'
        $message | Should -Not -Match 'PermanentSecret42'
    }
}

Describe 'Get-RustDeskId' {
    It 'trims and returns a numeric RustDesk ID' {
        Mock Invoke-RustDeskCommand -ModuleName RustDesk {
            [pscustomobject]@{ ExitCode = 0; Output = " 123456789 `r`n" }
        }

        Get-RustDeskId -ExecutablePath 'C:\Program Files\RustDesk\rustdesk.exe' | Should -Be '123456789'
    }

    It 'rejects command failure and nonnumeric output' {
        Mock Invoke-RustDeskCommand -ModuleName RustDesk {
            [pscustomobject]@{ ExitCode = 1; Output = '' }
        }
        { Get-RustDeskId -ExecutablePath 'C:\Program Files\RustDesk\rustdesk.exe' } | Should -Throw '*ID query failed*'

        Mock Invoke-RustDeskCommand -ModuleName RustDesk {
            [pscustomobject]@{ ExitCode = 0; Output = 'not-an-id' }
        }
        { Get-RustDeskId -ExecutablePath 'C:\Program Files\RustDesk\rustdesk.exe' } | Should -Throw '*invalid ID*'
    }
}
