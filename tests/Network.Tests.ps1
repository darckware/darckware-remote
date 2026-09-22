BeforeAll {
    Import-Module "$PSScriptRoot/../src/Network.psm1" -Force
}

Describe 'Test-IPv4Address' {
    It 'accepts a normal private address and rejects command-shaped input' {
        Test-IPv4Address '192.168.1.10' | Should -BeTrue
        Test-IPv4Address '192.168.1.10; Remove-Item C:\' | Should -BeFalse
        Test-IPv4Address '999.1.1.1' | Should -BeFalse
        Test-IPv4Address '::1' | Should -BeFalse
    }

    It 'rejects non-canonical IPv4 text' {
        Test-IPv4Address '192.168.001.010' | Should -BeFalse
        Test-IPv4Address ' 192.168.1.10' | Should -BeFalse
        Test-IPv4Address '192.168.1.10 ' | Should -BeFalse
    }
}

Describe 'Get-RustDeskRoutePlan' {
    It 'creates, reuses, and explicitly replaces routes' {
        (Get-RustDeskRoutePlan '100.105.235.114/32' '192.168.1.10' @() '').Action | Should -Be 'Create'

        $same = [pscustomobject]@{
            DestinationPrefix = '100.105.235.114/32'
            NextHop = '192.168.1.10'
            InterfaceIndex = 7
        }
        (Get-RustDeskRoutePlan '100.105.235.114/32' '192.168.1.10' @($same) '192.168.1.10').Action | Should -Be 'Reuse'

        $other = [pscustomobject]@{
            DestinationPrefix = '100.105.235.114/32'
            NextHop = '192.168.1.9'
            InterfaceIndex = 7
        }
        $plan = Get-RustDeskRoutePlan '100.105.235.114/32' '192.168.1.10' @($other) '192.168.1.9'
        $plan.Action | Should -Be 'Replace'
        $plan.RequiresConfirmation | Should -BeTrue
        $plan.ManagedGateway | Should -Be '192.168.1.9'
    }

    It 'preserves an unmanaged conflicting route' {
        $route = [pscustomobject]@{
            DestinationPrefix = '100.105.235.114/32'
            NextHop = '192.168.1.9'
            InterfaceIndex = 7
        }
        $plan = Get-RustDeskRoutePlan '100.105.235.114/32' '192.168.1.10' @($route) ''

        $plan.Action | Should -Be 'Conflict'
        $plan.RequiresConfirmation | Should -BeFalse
    }

    It 'reuses an unmanaged route that already has the requested gateway' {
        $route = [pscustomobject]@{
            DestinationPrefix = '100.105.235.114/32'
            NextHop = '192.168.1.10'
            InterfaceIndex = 7
        }

        $plan = Get-RustDeskRoutePlan '100.105.235.114/32' '192.168.1.10' @($route) ''

        $plan.Action | Should -Be 'Reuse'
        $plan.RequiresConfirmation | Should -BeFalse
    }

    It 'treats a route as managed only when its gateway matches saved state' {
        $managed = [pscustomobject]@{
            DestinationPrefix = '100.105.235.114/32'
            NextHop = '192.168.1.9'
            InterfaceIndex = 7
        }
        $unmanaged = [pscustomobject]@{
            DestinationPrefix = '100.105.235.114/32'
            NextHop = '192.168.1.8'
            InterfaceIndex = 8
        }

        $plan = Get-RustDeskRoutePlan '100.105.235.114/32' '192.168.1.10' @($managed, $unmanaged) '192.168.1.9'
        $plan.Action | Should -Be 'Conflict'
    }

    It 'rejects invalid gateways and non-host destination prefixes' {
        { Get-RustDeskRoutePlan '100.105.235.114/32' '192.168.1.10; Remove-Item C:\' @() '' } | Should -Throw '*valid canonical IPv4*'
        { Get-RustDeskRoutePlan '100.64.0.0/10' '192.168.1.10' @() '' } | Should -Throw '*host /32*'
    }
}

Describe 'Set-RustDeskHostRoute' {
    BeforeEach {
        Mock Find-NetRoute -ModuleName Network {
            [pscustomobject]@{ InterfaceIndex = 11 }
        }
        Mock Remove-NetRoute -ModuleName Network {}
        Mock New-NetRoute -ModuleName Network {}
    }

    It 'creates only the requested host route on the interface resolved for the gateway' {
        $plan = [pscustomobject]@{
            Action = 'Create'
            DestinationPrefix = '100.105.235.114/32'
            Gateway = '192.168.1.10'
            InterfaceIndex = 7
            Confirmed = $true
        }

        Set-RustDeskHostRoute -Plan $plan

        Should -Invoke Find-NetRoute -ModuleName Network -Times 1 -Exactly -ParameterFilter {
            $RemoteIPAddress -eq '192.168.1.10' -and $ErrorAction -eq 'Stop'
        }
        Should -Invoke Remove-NetRoute -ModuleName Network -Times 0
        Should -Invoke New-NetRoute -ModuleName Network -Times 1 -Exactly -ParameterFilter {
            $DestinationPrefix -eq '100.105.235.114/32' -and
            $InterfaceIndex -eq 11 -and
            $NextHop -eq '192.168.1.10' -and
            $RouteMetric -eq 5 -and
            $PolicyStore -eq 'PersistentStore' -and
            $ErrorAction -eq 'Stop'
        }
    }

    It 'does not mutate the route table for Reuse or Conflict plans' -ForEach @(
        @{ RouteAction = 'Reuse' }
        @{ RouteAction = 'Conflict' }
    ) {
        $plan = [pscustomobject]@{
            Action = $RouteAction
            DestinationPrefix = '100.105.235.114/32'
            Gateway = '192.168.1.10'
            InterfaceIndex = 7
            Confirmed = $true
        }

        Set-RustDeskHostRoute -Plan $plan

        Should -Invoke Find-NetRoute -ModuleName Network -Times 0
        Should -Invoke Remove-NetRoute -ModuleName Network -Times 0
        Should -Invoke New-NetRoute -ModuleName Network -Times 0
    }

    It 'replaces only the exact confirmed route recorded as managed' {
        $plan = [pscustomobject]@{
            Action = 'Replace'
            DestinationPrefix = '100.105.235.114/32'
            Gateway = '192.168.1.10'
            ManagedGateway = '192.168.1.9'
            ExistingInterfaceIndex = 7
            RequiresConfirmation = $true
            Confirmed = $true
        }

        Set-RustDeskHostRoute -Plan $plan

        Should -Invoke Remove-NetRoute -ModuleName Network -Times 1 -Exactly -ParameterFilter {
            $DestinationPrefix -eq '100.105.235.114/32' -and
            $InterfaceIndex -eq 7 -and
            $NextHop -eq '192.168.1.9' -and
            $PolicyStore -eq 'PersistentStore' -and
            $Confirm -eq $false -and
            $ErrorAction -eq 'Stop'
        }
        Should -Invoke New-NetRoute -ModuleName Network -Times 1 -Exactly -ParameterFilter {
            $DestinationPrefix -eq '100.105.235.114/32' -and
            $InterfaceIndex -eq 11 -and
            $NextHop -eq '192.168.1.10'
        }
    }

    It 'refuses an unconfirmed or incompletely identified replacement' {
        $unconfirmed = [pscustomobject]@{
            Action = 'Replace'
            DestinationPrefix = '100.105.235.114/32'
            Gateway = '192.168.1.10'
            ManagedGateway = '192.168.1.9'
            ExistingInterfaceIndex = 7
            RequiresConfirmation = $true
            Confirmed = $false
        }
        { Set-RustDeskHostRoute -Plan $unconfirmed } | Should -Throw '*confirmation*'

        $unidentified = $unconfirmed.PSObject.Copy()
        $unidentified.Confirmed = $true
        $unidentified.ManagedGateway = ''
        { Set-RustDeskHostRoute -Plan $unidentified } | Should -Throw '*managed gateway*'

        Should -Invoke Find-NetRoute -ModuleName Network -Times 0
        Should -Invoke Remove-NetRoute -ModuleName Network -Times 0
        Should -Invoke New-NetRoute -ModuleName Network -Times 0
    }

    It 'rejects a non-host destination before calling Windows networking cmdlets' {
        $plan = [pscustomobject]@{
            Action = 'Create'
            DestinationPrefix = '100.64.0.0/10'
            Gateway = '192.168.1.10'
            Confirmed = $true
        }

        { Set-RustDeskHostRoute -Plan $plan } | Should -Throw '*host /32*'
        Should -Invoke Find-NetRoute -ModuleName Network -Times 0
        Should -Invoke Remove-NetRoute -ModuleName Network -Times 0
        Should -Invoke New-NetRoute -ModuleName Network -Times 0
    }
}

Describe 'Test-RustDeskPorts' {
    It 'returns one structured TCP result for each configured port' {
        Mock Test-NetConnection -ModuleName Network {
            return $Port -eq 21116
        }

        $results = @(Test-RustDeskPorts -Address '100.105.235.114' -Ports @(21116, 21117))

        $results | Should -HaveCount 2
        $results[0].Address | Should -Be '100.105.235.114'
        $results[0].Port | Should -Be 21116
        $results[0].Protocol | Should -Be 'TCP'
        $results[0].Reachable | Should -BeTrue
        $results[1].Port | Should -Be 21117
        $results[1].Reachable | Should -BeFalse
        Should -Invoke Test-NetConnection -ModuleName Network -Times 2 -Exactly -ParameterFilter {
            $ComputerName -eq '100.105.235.114' -and
            $Port -in @(21116, 21117) -and
            $InformationLevel -eq 'Quiet'
        }
    }

    It 'rejects invalid addresses and ports before probing' {
        Mock Test-NetConnection -ModuleName Network {}

        { Test-RustDeskPorts -Address '100.105.235.114; whoami' -Ports @(21116) } | Should -Throw '*valid canonical IPv4*'
        { Test-RustDeskPorts -Address '100.105.235.114' -Ports @(0) } | Should -Throw '*between 1 and 65535*'

        Should -Invoke Test-NetConnection -ModuleName Network -Times 0
    }
}
