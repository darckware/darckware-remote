Set-StrictMode -Version Latest

function Test-IPv4Address {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Address
    )

    if ([string]::IsNullOrEmpty($Address)) {
        return $false
    }

    $parsedAddress = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsedAddress)) {
        return $false
    }

    return (
        $parsedAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
        $parsedAddress.IPAddressToString -ceq $Address
    )
}

function Assert-HostRouteInputs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DestinationPrefix,

        [Parameter(Mandatory)]
        [string]$Gateway
    )

    if ($DestinationPrefix -notmatch '^(?<Address>[^/]+)/32$' -or
        -not (Test-IPv4Address -Address $Matches.Address)) {
        throw "DestinationPrefix must be a canonical IPv4 host /32 prefix."
    }

    if (-not (Test-IPv4Address -Address $Gateway)) {
        throw "Gateway must be a valid canonical IPv4 address."
    }
}

function Get-RustDeskRoutePlan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$DestinationPrefix,

        [Parameter(Mandatory, Position = 1)]
        [string]$Gateway,

        [Parameter(Mandatory, Position = 2)]
        [AllowEmptyCollection()]
        [object[]]$CurrentRoutes,

        [Parameter(Mandatory, Position = 3)]
        [AllowEmptyString()]
        [string]$ManagedGateway
    )

    Assert-HostRouteInputs -DestinationPrefix $DestinationPrefix -Gateway $Gateway

    if (-not [string]::IsNullOrEmpty($ManagedGateway) -and
        -not (Test-IPv4Address -Address $ManagedGateway)) {
        throw "ManagedGateway must be empty or a valid canonical IPv4 address."
    }

    $destinationRoutes = @($CurrentRoutes | Where-Object {
        $_.DestinationPrefix -ceq $DestinationPrefix
    })

    $action = 'Create'
    $requiresConfirmation = $false
    $existingInterfaceIndex = $null

    if ($destinationRoutes.Count -gt 0) {
        $requestedGatewayRoutes = @($destinationRoutes | Where-Object {
            $_.NextHop -ceq $Gateway
        })

        if ($requestedGatewayRoutes.Count -eq $destinationRoutes.Count) {
            $action = 'Reuse'
            $existingInterfaceIndex = $requestedGatewayRoutes[0].InterfaceIndex
        }
        elseif ($destinationRoutes.Count -eq 1 -and
            -not [string]::IsNullOrEmpty($ManagedGateway) -and
            $destinationRoutes[0].NextHop -ceq $ManagedGateway) {
            $action = 'Replace'
            $requiresConfirmation = $true
            $existingInterfaceIndex = $destinationRoutes[0].InterfaceIndex
        }
        else {
            $action = 'Conflict'
        }
    }

    [pscustomobject]@{
        Action = $action
        DestinationPrefix = $DestinationPrefix
        Gateway = $Gateway
        ManagedGateway = $ManagedGateway
        InterfaceIndex = $existingInterfaceIndex
        ExistingInterfaceIndex = $existingInterfaceIndex
        RequiresConfirmation = $requiresConfirmation
        Confirmed = $false
    }
}

function Set-RustDeskHostRoute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [pscustomobject]$Plan
    )

    if ($null -eq $Plan.PSObject.Properties['Action']) {
        throw 'Route plan is missing an action.'
    }
    if ($Plan.Action -notin @('Create', 'Reuse', 'Replace', 'Conflict')) {
        throw "Unsupported route-plan action: $($Plan.Action)"
    }

    if ($Plan.Action -in @('Reuse', 'Conflict')) {
        $knownInterfaceIndex = $null
        if ($null -ne $Plan.PSObject.Properties['ExistingInterfaceIndex']) {
            $knownInterfaceIndex = $Plan.ExistingInterfaceIndex
        }
        elseif ($null -ne $Plan.PSObject.Properties['InterfaceIndex']) {
            $knownInterfaceIndex = $Plan.InterfaceIndex
        }
        return [pscustomobject]@{
            Action = $Plan.Action
            InterfaceIndex = $knownInterfaceIndex
        }
    }

    if ($null -eq $Plan.PSObject.Properties['DestinationPrefix'] -or
        $null -eq $Plan.PSObject.Properties['Gateway']) {
        throw 'Route plan is missing its destination prefix or gateway.'
    }
    Assert-HostRouteInputs -DestinationPrefix $Plan.DestinationPrefix -Gateway $Plan.Gateway

    $existingInterfaceIndex = 0
    if ($Plan.Action -eq 'Replace') {
        if ($null -eq $Plan.PSObject.Properties['Confirmed'] -or -not $Plan.Confirmed) {
            throw 'Route replacement requires explicit confirmation.'
        }
        if ($null -eq $Plan.PSObject.Properties['ManagedGateway'] -or
            [string]::IsNullOrEmpty([string]$Plan.ManagedGateway) -or
            -not (Test-IPv4Address -Address $Plan.ManagedGateway)) {
            throw 'Route replacement requires a valid managed gateway.'
        }
        if ($null -eq $Plan.PSObject.Properties['ExistingInterfaceIndex'] -or
            -not [int]::TryParse([string]$Plan.ExistingInterfaceIndex, [ref]$existingInterfaceIndex) -or
            $existingInterfaceIndex -lt 1) {
            throw 'Route replacement requires the existing managed interface index.'
        }
    }

    $gatewayRoutes = @(Find-NetRoute -RemoteIPAddress $Plan.Gateway -ErrorAction Stop)
    if ($gatewayRoutes.Count -eq 0 -or
        $null -eq $gatewayRoutes[0].PSObject.Properties['InterfaceIndex']) {
        throw "No active interface can reach gateway $($Plan.Gateway)."
    }

    $gatewayInterfaceIndex = 0
    if (-not [int]::TryParse([string]$gatewayRoutes[0].InterfaceIndex, [ref]$gatewayInterfaceIndex) -or
        $gatewayInterfaceIndex -lt 1) {
        throw "The route to gateway $($Plan.Gateway) has an invalid interface index."
    }

    if ($Plan.Action -eq 'Replace') {
        Remove-NetRoute -DestinationPrefix $Plan.DestinationPrefix `
            -InterfaceIndex $existingInterfaceIndex -NextHop $Plan.ManagedGateway `
            -PolicyStore PersistentStore -Confirm:$false -ErrorAction Stop | Out-Null
    }

    New-NetRoute -DestinationPrefix $Plan.DestinationPrefix `
        -InterfaceIndex $gatewayInterfaceIndex -NextHop $Plan.Gateway `
        -RouteMetric 5 -PolicyStore PersistentStore -ErrorAction Stop | Out-Null

    [pscustomobject]@{
        Action = $Plan.Action
        InterfaceIndex = $gatewayInterfaceIndex
    }
}

function Test-RustDeskPorts {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Address,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNull()]
        [int[]]$Ports
    )

    if (-not (Test-IPv4Address -Address $Address)) {
        throw 'Address must be a valid canonical IPv4 address.'
    }

    foreach ($port in $Ports) {
        if ($port -lt 1 -or $port -gt 65535) {
            throw 'Each TCP port must be between 1 and 65535.'
        }
    }

    foreach ($port in $Ports) {
        $reachable = Test-NetConnection -ComputerName $Address -Port $port `
            -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

        [pscustomobject]@{
            Address = $Address
            Port = $port
            Protocol = 'TCP'
            Reachable = [bool]$reachable
        }
    }
}

Export-ModuleMember -Function @(
    'Test-IPv4Address',
    'Get-RustDeskRoutePlan',
    'Set-RustDeskHostRoute',
    'Test-RustDeskPorts'
)
