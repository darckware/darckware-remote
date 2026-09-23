BeforeAll {
    Import-Module "$PSScriptRoot/../src/Installer.Core.psm1" -Force

    function New-CoreTestConfig([string]$StateRoot) {
        [pscustomobject]@{
            Artifacts = [pscustomobject]@{
                tailscale = [pscustomobject]@{ version = '1.102.3' }
                rustdesk = [pscustomobject]@{ version = '1.4.9' }
            }
            Deployment = [pscustomobject]@{
                stateRoot = $StateRoot
                route = [pscustomobject]@{ destinationPrefix = '100.105.235.114/32' }
                rustdesk = [pscustomobject]@{
                    idServer = '100.105.235.114'
                    relayServer = '100.105.235.114:21117'
                    publicKey = 'public-key='
                    tcpPorts = @(21116, 21117)
                }
            }
        }
    }

    function New-CoreRequest {
        [pscustomobject]@{
            InstallTailscale = $true
            InstallRustDesk = $true
            ConnectivityMode = 'LocalTailscale'
            RouterIp = ''
            TailscaleHostname = 'pc-01'
            TailscaleAuthKey = ConvertTo-SecureString 'tskey-auth-fixture' -AsPlainText -Force
            RustDeskPassword = ConvertTo-SecureString 'password-fixture' -AsPlainText -Force
            ConfirmRouteReplacement = $false
        }
    }
}

Describe 'Test-InstallRequest' {
    It 'rejects a request with no selected component' {
        $request = [pscustomobject]@{ InstallTailscale = $false; InstallRustDesk = $false }
        { Test-InstallRequest -Request $request } | Should -Throw '*component*'
    }

    It 'rejects missing and injection-shaped Tailscale fields' {
        $request = New-CoreRequest
        $request.TailscaleHostname = 'pc;whoami'
        { Test-InstallRequest -Request $request } | Should -Throw '*hostname*'

        $request.TailscaleHostname = 'pc-01'
        $request.TailscaleAuthKey = $null
        { Test-InstallRequest -Request $request } | Should -Throw '*auth key*'
    }

    It 'rejects missing or unsafe router addresses' {
        $request = New-CoreRequest
        $request.InstallTailscale = $false
        $request.ConnectivityMode = 'Router'
        $request.RouterIp = '192.168.1.1; whoami'
        { Test-InstallRequest -Request $request } | Should -Throw '*router*'
    }
}

Describe 'Invoke-DarckwareInstall ordering and secrecy' {
    BeforeEach {
        $config = New-CoreTestConfig $TestDrive
        Mock Get-InstallerConfig -ModuleName Installer.Core { $config }
        Mock Invoke-TailscaleStage -ModuleName Installer.Core {
            [pscustomobject]@{ Requested = $true; Installed = $true; Connected = $true; RebootRequired = $false }
        }
        Mock Invoke-ConnectivityStage -ModuleName Installer.Core {
            [pscustomobject]@{ Mode = 'LocalTailscale'; RouteAction = 'None'; PortChecks = @() }
        }
        Mock Invoke-RustDeskStage -ModuleName Installer.Core {
            [pscustomobject]@{ Requested = $true; Installed = $true; Configured = $true; Id = '123456789' }
        }
    }

    It 'stops before RustDesk when combined Tailscale enrollment fails' {
        Mock Invoke-TailscaleStage -ModuleName Installer.Core { throw 'enrollment failed' }
        $request = New-CoreRequest

        { Invoke-DarckwareInstall -Request $request -RepoRoot $TestDrive } | Should -Throw '*enrollment failed*'

        Should -Invoke Invoke-RustDeskStage -ModuleName Installer.Core -Times 0
    }

    It 'forces combined mode to local Tailscale before connectivity and RustDesk' {
        $request = New-CoreRequest
        $request.ConnectivityMode = 'Router'
        $request.RouterIp = '192.168.1.10'

        $result = Invoke-DarckwareInstall -Request $request -RepoRoot $TestDrive

        $result.Success | Should -BeTrue
        $result.Network.Mode | Should -Be 'LocalTailscale'
        Should -Invoke Invoke-ConnectivityStage -ModuleName Installer.Core -Times 1 -ParameterFilter {
            $Request.ConnectivityMode -eq 'LocalTailscale'
        }
    }

    It 'persists no auth key or RustDesk password in state, result, or log' {
        $request = New-CoreRequest

        $result = Invoke-DarckwareInstall -Request $request -RepoRoot $TestDrive
        $serialized = @(
            $result | ConvertTo-Json -Depth 8 -Compress
            Get-Content -LiteralPath (Join-Path $TestDrive 'state.json') -Raw
            Get-Content -LiteralPath $result.LogPath -Raw
        ) -join "`n"

        $serialized | Should -Not -Match 'tskey-|password-fixture'
        $serialized | Should -Match '1.102.3|1.4.9'
    }

    It 'redacts secret-shaped exception text in both the log and rethrown error' {
        Mock Invoke-TailscaleStage -ModuleName Installer.Core { throw ('bad tskey-' + 'auth-never-log-this') }
        $request = New-CoreRequest
        $message = $null

        try { Invoke-DarckwareInstall -Request $request -RepoRoot $TestDrive }
        catch { $message = $_.Exception.Message }

        $message | Should -Match '\[REDACTED\]'
        $message | Should -Not -Match 'tskey-'
        (Get-Content -LiteralPath (Join-Path $TestDrive 'installer.log') -Raw) | Should -Not -Match 'tskey-'
    }
}

Describe 'Tailscale stage idempotency' {
    It 'reuses an already connected client without downloading or reinstalling it' {
        Mock Get-TailscaleStatus -ModuleName Installer.Core {
            [pscustomobject]@{ Connected = $true; BackendState = 'Running'; TailscaleIPs = @('100.64.1.2') }
        }
        Mock Get-VerifiedArtifact -ModuleName Installer.Core {}
        Mock Install-Tailscale -ModuleName Installer.Core {}
        Mock Connect-Tailscale -ModuleName Installer.Core {}
        $request = New-CoreRequest
        $config = New-CoreTestConfig $TestDrive

        $result = InModuleScope Installer.Core -Parameters @{ Request = $request; Config = $config; StateRoot = $TestDrive } {
            Invoke-TailscaleStage -Request $Request -Config $Config -StateRoot $StateRoot
        }

        $result.Connected | Should -BeTrue
        $result.Reused | Should -BeTrue
        Should -Invoke Get-VerifiedArtifact -ModuleName Installer.Core -Times 0
        Should -Invoke Install-Tailscale -ModuleName Installer.Core -Times 0
        Should -Invoke Connect-Tailscale -ModuleName Installer.Core -Times 0
    }
}

Describe 'existing local Tailscale in the installation summary' {
    BeforeEach {
        $config = New-CoreTestConfig $TestDrive
        Mock Get-InstallerConfig -ModuleName Installer.Core { $config }
        Mock Get-TailscaleStatus -ModuleName Installer.Core {
            [pscustomobject]@{ Connected = $true }
        }
        Mock Test-RustDeskPorts -ModuleName Installer.Core {
            @([pscustomobject]@{ Port = 21116; Reachable = $true },
              [pscustomobject]@{ Port = 21117; Reachable = $true })
        }
        Mock Invoke-RustDeskStage -ModuleName Installer.Core {
            [pscustomobject]@{ Requested = $true; Installed = $true; Configured = $true; Id = '123456789' }
        }
    }

    It 'reports the connection verified by the connectivity stage without claiming a Tailscale installation' {
        $request = New-CoreRequest
        $request.InstallTailscale = $false
        $result = Invoke-DarckwareInstall -Request $request -RepoRoot $TestDrive
        $result.Tailscale.Connected | Should -BeTrue
        $result.Tailscale.Requested | Should -BeFalse
        $result.Tailscale.Installed | Should -BeFalse
        $result.Network.Mode | Should -Be 'LocalTailscale'
    }

    It 'still fails when the existing local Tailscale is disconnected' {
        Mock Get-TailscaleStatus -ModuleName Installer.Core { [pscustomobject]@{ Connected = $false } }
        $request = New-CoreRequest
        $request.InstallTailscale = $false
        { Invoke-DarckwareInstall -Request $request -RepoRoot $TestDrive } | Should -Throw '*Local Tailscale is not connected*'
        Should -Invoke Invoke-RustDeskStage -ModuleName Installer.Core -Times 0
    }
}

Describe 'router connectivity decisions' {
    BeforeEach {
        Mock Get-NetRoute -ModuleName Installer.Core { @() }
        Mock Get-RustDeskRoutePlan -ModuleName Installer.Core {
            [pscustomobject]@{
                Action = 'Create'; DestinationPrefix = '100.105.235.114/32'; Gateway = '192.168.1.10'
                ManagedGateway = ''; ExistingInterfaceIndex = $null; RequiresConfirmation = $false; Confirmed = $false
            }
        }
        Mock Set-RustDeskHostRoute -ModuleName Installer.Core {}
        Mock Test-RustDeskPorts -ModuleName Installer.Core {
            @(
                [pscustomobject]@{ Port = 21116; Reachable = $true },
                [pscustomobject]@{ Port = 21117; Reachable = $true }
            )
        }
    }

    It 'removes only the previously managed route when local Tailscale is selected' {
        Mock Get-TailscaleStatus -ModuleName Installer.Core {
            [pscustomobject]@{ Connected = $true; BackendState = 'Running'; TailscaleIPs = @('100.64.1.2') }
        }
        Mock Get-NetRoute -ModuleName Installer.Core {
            @(
                [pscustomobject]@{ DestinationPrefix = '100.105.235.114/32'; NextHop = '192.168.1.9'; InterfaceIndex = 7 },
                [pscustomobject]@{ DestinationPrefix = '100.105.235.114/32'; NextHop = '192.168.1.8'; InterfaceIndex = 8 }
            )
        }
        Mock Remove-NetRoute -ModuleName Installer.Core {}
        $request = New-CoreRequest
        $config = New-CoreTestConfig $TestDrive
        $state = @{
            ManagedRouteDestination = '100.105.235.114/32'
            ManagedRouteGateway = '192.168.1.9'
        }

        InModuleScope Installer.Core -Parameters @{ Request = $request; Config = $config; State = $state } {
            Invoke-ConnectivityStage -Request $Request -Config $Config -State $State
        }

        Should -Invoke Remove-NetRoute -ModuleName Installer.Core -Times 1 -Exactly -ParameterFilter {
            $DestinationPrefix -eq '100.105.235.114/32' -and $NextHop -eq '192.168.1.9' -and
            $InterfaceIndex -eq 7 -and $PolicyStore -eq 'PersistentStore' -and $Confirm -eq $false
        }
        Should -Invoke Test-RustDeskPorts -ModuleName Installer.Core -Times 1
    }

    It 'refuses an unmanaged route conflict without mutating routes' {
        Mock Get-RustDeskRoutePlan -ModuleName Installer.Core {
            [pscustomobject]@{ Action = 'Conflict'; RequiresConfirmation = $false; Confirmed = $false }
        }
        $request = New-CoreRequest
        $request.InstallTailscale = $false
        $request.ConnectivityMode = 'Router'
        $request.RouterIp = '192.168.1.10'
        $config = New-CoreTestConfig $TestDrive

        { InModuleScope Installer.Core -Parameters @{ Request = $request; Config = $config; State = @{} } {
            Invoke-ConnectivityStage -Request $Request -Config $Config -State $State
        } } | Should -Throw '*conflicting route*'

        Should -Invoke Set-RustDeskHostRoute -ModuleName Installer.Core -Times 0
    }

    It 'requires explicit confirmation before replacing a managed route' {
        Mock Get-RustDeskRoutePlan -ModuleName Installer.Core {
            [pscustomobject]@{ Action = 'Replace'; RequiresConfirmation = $true; Confirmed = $false }
        }
        $request = New-CoreRequest
        $request.InstallTailscale = $false
        $request.ConnectivityMode = 'Router'
        $request.RouterIp = '192.168.1.10'
        $config = New-CoreTestConfig $TestDrive
        $state = @{ ManagedRouteGateway = '192.168.1.9' }

        { InModuleScope Installer.Core -Parameters @{ Request = $request; Config = $config; State = $state } {
            Invoke-ConnectivityStage -Request $Request -Config $Config -State $State
        } } | Should -Throw '*confirmation*'

        Should -Invoke Set-RustDeskHostRoute -ModuleName Installer.Core -Times 0
    }

    It 'confirms a managed replacement and verifies both configured TCP ports' {
        Mock Get-RustDeskRoutePlan -ModuleName Installer.Core {
            [pscustomobject]@{
                Action = 'Replace'; DestinationPrefix = '100.105.235.114/32'; Gateway = '192.168.1.10'
                ManagedGateway = '192.168.1.9'; ExistingInterfaceIndex = 7
                RequiresConfirmation = $true; Confirmed = $false
            }
        }
        $request = New-CoreRequest
        $request.InstallTailscale = $false
        $request.ConnectivityMode = 'Router'
        $request.RouterIp = '192.168.1.10'
        $request.ConfirmRouteReplacement = $true
        $config = New-CoreTestConfig $TestDrive
        $state = @{ ManagedRouteGateway = '192.168.1.9' }

        $result = InModuleScope Installer.Core -Parameters @{ Request = $request; Config = $config; State = $state } {
            Invoke-ConnectivityStage -Request $Request -Config $Config -State $State
        }

        $result.RouteAction | Should -Be 'Replace'
        Should -Invoke Set-RustDeskHostRoute -ModuleName Installer.Core -Times 1 -ParameterFilter { $Plan.Confirmed }
        Should -Invoke Test-RustDeskPorts -ModuleName Installer.Core -Times 1 -ParameterFilter {
            $Address -eq '100.105.235.114' -and $Ports.Count -eq 2 -and
            $Ports[0] -eq 21116 -and $Ports[1] -eq 21117
        }
    }

    It 'does not claim ownership of a matching route created outside the installer' {
        Mock Get-RustDeskRoutePlan -ModuleName Installer.Core {
            [pscustomobject]@{
                Action = 'Reuse'; DestinationPrefix = '100.105.235.114/32'; Gateway = '192.168.1.10'
                ManagedGateway = ''; ExistingInterfaceIndex = 7; RequiresConfirmation = $false; Confirmed = $false
            }
        }
        $request = New-CoreRequest
        $request.InstallTailscale = $false
        $request.ConnectivityMode = 'Router'
        $request.RouterIp = '192.168.1.10'
        $config = New-CoreTestConfig $TestDrive

        $result = InModuleScope Installer.Core -Parameters @{ Request = $request; Config = $config } {
            Invoke-ConnectivityStage -Request $Request -Config $Config -State @{}
        }

        $result.RouteAction | Should -Be 'Reuse'
        $result.ManagedByInstaller | Should -BeFalse
    }

    It 'records a newly created route before a later connectivity check fails' {
        Mock Get-InstallerConfig -ModuleName Installer.Core { New-CoreTestConfig $TestDrive }
        Mock Invoke-RustDeskStage -ModuleName Installer.Core {}
        Mock Get-NetRoute -ModuleName Installer.Core { @() }
        Mock Get-RustDeskRoutePlan -ModuleName Installer.Core {
            [pscustomobject]@{
                Action = 'Create'; DestinationPrefix = '100.105.235.114/32'; Gateway = '192.168.1.10'
                ManagedGateway = ''; ExistingInterfaceIndex = $null; RequiresConfirmation = $false; Confirmed = $false
            }
        }
        Mock Set-RustDeskHostRoute -ModuleName Installer.Core {
            [pscustomobject]@{ InterfaceIndex = 11 }
        }
        Mock Test-RustDeskPorts -ModuleName Installer.Core {
            @([pscustomobject]@{ Port = 21116; Reachable = $false })
        }
        $request = New-CoreRequest
        $request.InstallTailscale = $false
        $request.ConnectivityMode = 'Router'
        $request.RouterIp = '192.168.1.10'

        { Invoke-DarckwareInstall -Request $request -RepoRoot $TestDrive } | Should -Throw '*not reachable*'

        $state = Get-Content -LiteralPath (Join-Path $TestDrive 'state.json') -Raw | ConvertFrom-Json
        $state.ManagedRouteGateway | Should -Be '192.168.1.10'
        $state.ManagedRouteInterfaceIndex | Should -Be 11
    }
}
