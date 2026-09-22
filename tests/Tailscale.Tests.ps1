BeforeAll {
    Import-Module "$PSScriptRoot/../src/Security.psm1" -Force
    Import-Module "$PSScriptRoot/../src/Tailscale.psm1" -Force
}

Describe 'Test-TailscaleHostname' {
    It 'accepts DNS-safe names and rejects injection-shaped names' {
        Test-TailscaleHostname 'cliente-loja-01' | Should -BeTrue
        Test-TailscaleHostname '-bad' | Should -BeFalse
        Test-TailscaleHostname 'bad;whoami' | Should -BeFalse
        Test-TailscaleHostname ('a' * 64) | Should -BeFalse
    }

    It 'rejects empty, dotted, and non-ASCII hostnames' {
        Test-TailscaleHostname '' | Should -BeFalse
        Test-TailscaleHostname 'cliente.loja' | Should -BeFalse
        Test-TailscaleHostname 'clienté-01' | Should -BeFalse
    }
}

Describe 'Install-Tailscale' {
    BeforeEach {
        Mock Start-Process -ModuleName Tailscale {
            [pscustomobject]@{ ExitCode = 0 }
        }
    }

    It 'runs the verified MSI silently with unattended mode enabled' {
        $result = Install-Tailscale -MsiPath 'C:\cache\tailscale.msi'

        $result.RebootRequired | Should -BeFalse
        $result.ExitCode | Should -Be 0
        Should -Invoke Start-Process -ModuleName Tailscale -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'msiexec.exe' -and
            $ArgumentList.Count -eq 6 -and
            $ArgumentList[0] -eq '/i' -and
            $ArgumentList[1] -eq 'C:\cache\tailscale.msi' -and
            $ArgumentList[2] -eq '/qn' -and
            $ArgumentList[3] -eq '/norestart' -and
            $ArgumentList[4] -eq 'TS_UNATTENDEDMODE=always' -and
            $ArgumentList[5] -eq 'TS_NOLAUNCH=1' -and
            $Wait -eq $true -and
            $PassThru -eq $true
        }
    }

    It 'accepts reboot-required success codes without treating them as failures' -ForEach @(
        @{ InstallerExitCode = 1641 }
        @{ InstallerExitCode = 3010 }
    ) {
        Mock Start-Process -ModuleName Tailscale {
            [pscustomobject]@{ ExitCode = $InstallerExitCode }
        }

        $result = Install-Tailscale -MsiPath 'C:\cache\tailscale.msi'

        $result.ExitCode | Should -Be $InstallerExitCode
        $result.RebootRequired | Should -BeTrue
    }

    It 'rejects every other MSI exit code' {
        Mock Start-Process -ModuleName Tailscale {
            [pscustomobject]@{ ExitCode = 1603 }
        }

        { Install-Tailscale -MsiPath 'C:\cache\tailscale.msi' } | Should -Throw '*1603*'
    }
}

Describe 'Get-TailscaleStatus' {
    It 'reports connected only for Running state with at least one tailnet IP' {
        Mock Invoke-TailscaleCommand -ModuleName Tailscale {
            [pscustomobject]@{
                ExitCode = 0
                Output = '{"BackendState":"Running","TailscaleIPs":["100.64.1.2"]}'
            }
        }

        $status = Get-TailscaleStatus

        $status.Connected | Should -BeTrue
        $status.BackendState | Should -Be 'Running'
        $status.TailscaleIPs | Should -HaveCount 1
        $status.TailscaleIPs[0] | Should -Be '100.64.1.2'
    }

    It 'reports disconnected when Running has no assigned IP' {
        Mock Invoke-TailscaleCommand -ModuleName Tailscale {
            [pscustomobject]@{
                ExitCode = 0
                Output = '{"BackendState":"Running","TailscaleIPs":[]}'
            }
        }

        (Get-TailscaleStatus).Connected | Should -BeFalse
    }

    It 'fails closed when the status command fails or emits invalid JSON' {
        Mock Invoke-TailscaleCommand -ModuleName Tailscale {
            [pscustomobject]@{ ExitCode = 1; Output = 'not logged in' }
        }
        { Get-TailscaleStatus } | Should -Throw '*status command failed*'

        Mock Invoke-TailscaleCommand -ModuleName Tailscale {
            [pscustomobject]@{ ExitCode = 0; Output = 'not json' }
        }
        { Get-TailscaleStatus } | Should -Throw '*invalid JSON*'
    }
}

Describe 'Connect-Tailscale' {
    BeforeEach {
        Mock New-ProtectedSecretFile -ModuleName Tailscale {
            Join-Path $TestDrive 'auth.key'
        }
        Mock Remove-SecretFile -ModuleName Tailscale {}
        Mock Invoke-TailscaleCommand -ModuleName Tailscale {
            [pscustomobject]@{ ExitCode = 0; Output = 'ok' }
        }
    }

    It 'uses an auth-key file, removes it, and never returns the key' {
        $statusQueue = [System.Collections.Queue]::new()
        $statusQueue.Enqueue([pscustomobject]@{
            Connected = $false
            BackendState = 'Stopped'
            TailscaleIPs = @()
        })
        $statusQueue.Enqueue([pscustomobject]@{
            Connected = $true
            BackendState = 'Running'
            TailscaleIPs = @('100.64.1.2')
        })
        Mock Get-TailscaleStatus -ModuleName Tailscale {
            $statusQueue.Dequeue()
        }
        $secret = ConvertTo-SecureString 'tskey-auth-secret' -AsPlainText -Force

        $result = Connect-Tailscale -Hostname 'cliente-01' -AuthKey $secret -SecretDirectory $TestDrive

        Should -Invoke Invoke-TailscaleCommand -ModuleName Tailscale -Times 1 -Exactly -ParameterFilter {
            $Arguments.Count -eq 4 -and
            $Arguments[0] -eq 'up' -and
            $Arguments[1] -eq ('--auth-key=file:' + (Join-Path $TestDrive 'auth.key')) -and
            $Arguments[2] -eq '--hostname=cliente-01' -and
            $Arguments[3] -eq '--unattended=true'
        }
        Should -Invoke Remove-SecretFile -ModuleName Tailscale -Times 1 -Exactly -ParameterFilter {
            $Path -eq (Join-Path $TestDrive 'auth.key')
        }
        $result.Connected | Should -BeTrue
        ($result | ConvertTo-Json -Compress) | Should -Not -Match 'tskey-'
    }

    It 'reuses a connected installation without creating or exposing a secret file' {
        Mock Get-TailscaleStatus -ModuleName Tailscale {
            [pscustomobject]@{
                Connected = $true
                BackendState = 'Running'
                TailscaleIPs = @('100.64.1.2')
            }
        }
        $secret = ConvertTo-SecureString 'tskey-auth-secret' -AsPlainText -Force

        $result = Connect-Tailscale -Hostname 'cliente-01' -AuthKey $secret -SecretDirectory $TestDrive

        $result.Connected | Should -BeTrue
        Should -Invoke New-ProtectedSecretFile -ModuleName Tailscale -Times 0
        Should -Invoke Invoke-TailscaleCommand -ModuleName Tailscale -Times 0
        Should -Invoke Remove-SecretFile -ModuleName Tailscale -Times 0
    }

    It 'removes the secret file when enrollment throws' {
        Mock Get-TailscaleStatus -ModuleName Tailscale {
            [pscustomobject]@{ Connected = $false; BackendState = 'Stopped'; TailscaleIPs = @() }
        }
        Mock Invoke-TailscaleCommand -ModuleName Tailscale { throw 'process failed' }
        $secret = ConvertTo-SecureString 'tskey-auth-secret' -AsPlainText -Force

        { Connect-Tailscale -Hostname 'cliente-01' -AuthKey $secret -SecretDirectory $TestDrive } | Should -Throw '*process failed*'

        Should -Invoke Remove-SecretFile -ModuleName Tailscale -Times 1 -Exactly -ParameterFilter {
            $Path -eq (Join-Path $TestDrive 'auth.key')
        }
    }

    It 'fails closed and cleans up when enrollment does not reach Running state' {
        Mock Get-TailscaleStatus -ModuleName Tailscale {
            [pscustomobject]@{ Connected = $false; BackendState = 'Stopped'; TailscaleIPs = @() }
        }
        $secret = ConvertTo-SecureString 'tskey-auth-secret' -AsPlainText -Force

        { Connect-Tailscale -Hostname 'cliente-01' -AuthKey $secret -SecretDirectory $TestDrive } | Should -Throw '*Running state*'

        Should -Invoke Invoke-TailscaleCommand -ModuleName Tailscale -Times 1
        Should -Invoke Remove-SecretFile -ModuleName Tailscale -Times 1
    }

    It 'rejects an unsafe hostname before touching the auth key' {
        Mock Get-TailscaleStatus -ModuleName Tailscale {
            [pscustomobject]@{ Connected = $false; BackendState = 'Stopped'; TailscaleIPs = @() }
        }
        $secret = ConvertTo-SecureString 'tskey-auth-secret' -AsPlainText -Force

        { Connect-Tailscale -Hostname 'bad;whoami' -AuthKey $secret -SecretDirectory $TestDrive } | Should -Throw '*hostname*'

        Should -Invoke New-ProtectedSecretFile -ModuleName Tailscale -Times 0
        Should -Invoke Invoke-TailscaleCommand -ModuleName Tailscale -Times 0
    }
}
