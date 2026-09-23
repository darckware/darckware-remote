Set-StrictMode -Version Latest

foreach ($moduleName in @('Artifact', 'Security', 'Network', 'Tailscale', 'RustDesk')) {
    # Forcing a nested reload removes the launcher's existing command bindings.
    Import-Module (Join-Path $PSScriptRoot "$moduleName.psm1")
}

function Get-ObjectValue {
    param($Object, [string]$Name, $Default = $null)

    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Test-InstallRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Request)

    $installTailscale = [bool](Get-ObjectValue $Request 'InstallTailscale' $false)
    $installRustDesk = [bool](Get-ObjectValue $Request 'InstallRustDesk' $false)
    if (-not $installTailscale -and -not $installRustDesk) {
        throw 'At least one component must be selected.'
    }

    if ($installTailscale) {
        $hostname = [string](Get-ObjectValue $Request 'TailscaleHostname' '')
        if (-not (Test-TailscaleHostname -Hostname $hostname)) {
            throw 'A valid Tailscale hostname is required.'
        }
        if ((Get-ObjectValue $Request 'TailscaleAuthKey') -isnot [System.Security.SecureString]) {
            throw 'A secure Tailscale auth key is required.'
        }
    }

    $password = Get-ObjectValue $Request 'RustDeskPassword'
    if ($null -ne $password -and $password -isnot [System.Security.SecureString]) {
        throw 'RustDesk password must be supplied as a SecureString.'
    }

    if ($installRustDesk -and -not $installTailscale) {
        $mode = [string](Get-ObjectValue $Request 'ConnectivityMode' '')
        if ($mode -notin @('LocalTailscale', 'Router')) {
            throw 'A supported RustDesk connectivity mode is required.'
        }
        if ($mode -eq 'Router') {
            $routerIp = [string](Get-ObjectValue $Request 'RouterIp' '')
            if (-not (Test-IPv4Address -Address $routerIp)) {
                throw 'A valid router IPv4 address is required.'
            }
        }
    }
}

function Copy-NormalizedRequest {
    param([pscustomobject]$Request)

    $installTailscale = [bool](Get-ObjectValue $Request 'InstallTailscale' $false)
    $installRustDesk = [bool](Get-ObjectValue $Request 'InstallRustDesk' $false)
    $mode = [string](Get-ObjectValue $Request 'ConnectivityMode' '')
    if ($installTailscale -and $installRustDesk) { $mode = 'LocalTailscale' }

    [pscustomobject]@{
        InstallTailscale = $installTailscale
        InstallRustDesk = $installRustDesk
        ConnectivityMode = $mode
        RouterIp = [string](Get-ObjectValue $Request 'RouterIp' '')
        TailscaleHostname = [string](Get-ObjectValue $Request 'TailscaleHostname' '')
        TailscaleAuthKey = Get-ObjectValue $Request 'TailscaleAuthKey'
        RustDeskPassword = Get-ObjectValue $Request 'RustDeskPassword'
        ConfirmRouteReplacement = [bool](Get-ObjectValue $Request 'ConfirmRouteReplacement' $false)
    }
}

function Resolve-InstallerStateRoot {
    param($Deployment)
    $configured = [string](Get-ObjectValue $Deployment 'stateRoot' '')
    if ([string]::IsNullOrWhiteSpace($configured)) { throw 'Installer state root is not configured.' }
    return [Environment]::ExpandEnvironmentVariables($configured)
}

function Write-InstallerLog {
    param([string]$Path, [string]$Text)
    $safe = Protect-LogText -Text $Text
    $line = '{0:o} {1}' -f [DateTime]::UtcNow, $safe
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Read-InstallerState {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{} }
    return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}

function Save-InstallerState {
    param([string]$Path, $Config, $Network, $PreviousState)

    $state = [ordered]@{
        ComponentVersions = [ordered]@{
            Tailscale = [string]$Config.Artifacts.tailscale.version
            RustDesk = [string]$Config.Artifacts.rustdesk.version
        }
        UpdatedAt = [DateTime]::UtcNow.ToString('o')
    }
    if ($Network.Mode -eq 'Router' -and [bool](Get-ObjectValue $Network 'ManagedByInstaller' $false)) {
        $state.ManagedRouteDestination = [string]$Config.Deployment.route.destinationPrefix
        $state.ManagedRouteGateway = [string]$Network.Gateway
        $state.ManagedRouteInterfaceIndex = [int](Get-ObjectValue $Network 'InterfaceIndex' 0)
    }
    elseif ($Network.Mode -eq 'None') {
        $previousDestination = [string](Get-ObjectValue $PreviousState 'ManagedRouteDestination' '')
        $previousGateway = [string](Get-ObjectValue $PreviousState 'ManagedRouteGateway' '')
        $previousInterface = [int](Get-ObjectValue $PreviousState 'ManagedRouteInterfaceIndex' 0)
        if ($previousDestination -ceq [string]$Config.Deployment.route.destinationPrefix -and
            (Test-IPv4Address -Address $previousGateway)) {
            $state.ManagedRouteDestination = $previousDestination
            $state.ManagedRouteGateway = $previousGateway
            if ($previousInterface -gt 0) { $state.ManagedRouteInterfaceIndex = $previousInterface }
        }
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-TailscaleStage {
    param($Request, $Config, [string]$StateRoot, [scriptblock]$ProgressAction)

    try {
        $existingStatus = Get-TailscaleStatus
        if ($existingStatus.Connected) {
            return [pscustomobject]@{
                Requested = $true
                Installed = $true
                Connected = $true
                Reused = $true
                RebootRequired = $false
            }
        }
    }
    catch {
        # A missing or not-yet-functional client is handled by the verified installation below.
    }

    if ($null -ne $ProgressAction) { & $ProgressAction 0 0 'Baixando Tailscale...' }
    $artifact = Get-VerifiedArtifact -Artifact $Config.Artifacts.tailscale -CacheRoot (Join-Path $StateRoot 'downloads') -ProgressAction $ProgressAction
    if ($null -ne $ProgressAction) { & $ProgressAction 0 0 'Instalando Tailscale...' }
    $installation = Install-Tailscale -MsiPath $artifact
    if ($null -ne $ProgressAction) { & $ProgressAction 0 0 'Conectando Tailscale...' }
    $status = Connect-Tailscale -Hostname $Request.TailscaleHostname -AuthKey $Request.TailscaleAuthKey -SecretDirectory $StateRoot
    [pscustomobject]@{
        Requested = $true
        Installed = $true
        Connected = [bool]$status.Connected
        Reused = $false
        RebootRequired = [bool]$installation.RebootRequired
    }
}

function Remove-ManagedHostRoute {
    param($State, $Config)

    $destination = [string](Get-ObjectValue $State 'ManagedRouteDestination' '')
    $gateway = [string](Get-ObjectValue $State 'ManagedRouteGateway' '')
    $interfaceIndex = [int](Get-ObjectValue $State 'ManagedRouteInterfaceIndex' 0)
    $configuredDestination = [string]$Config.Deployment.route.destinationPrefix
    if ([string]::IsNullOrEmpty($destination) -or [string]::IsNullOrEmpty($gateway)) { return }
    if ($destination -cne $configuredDestination -or -not (Test-IPv4Address -Address $gateway)) {
        throw 'Saved managed route state is invalid.'
    }

    $managedRoutes = @(Get-NetRoute -DestinationPrefix $destination -ErrorAction SilentlyContinue | Where-Object {
        $_.DestinationPrefix -ceq $destination -and $_.NextHop -ceq $gateway -and
        ($interfaceIndex -le 0 -or $_.InterfaceIndex -eq $interfaceIndex)
    })
    if ($interfaceIndex -le 0 -and $managedRoutes.Count -gt 1) {
        throw 'Saved managed route is ambiguous and will not be removed.'
    }
    foreach ($route in $managedRoutes) {
        Remove-NetRoute -DestinationPrefix $destination -NextHop $gateway `
            -InterfaceIndex $route.InterfaceIndex -PolicyStore PersistentStore `
            -Confirm:$false -ErrorAction Stop | Out-Null
    }
}

function Invoke-ConnectivityStage {
    param($Request, $Config, $State, [string]$StatePath = '')

    if (-not $Request.InstallRustDesk) {
        return [pscustomobject]@{ Mode = 'None'; RouteAction = 'None'; ManagedByInstaller = $false; PortChecks = @() }
    }
    if ($Request.ConnectivityMode -eq 'LocalTailscale') {
        $status = Get-TailscaleStatus
        if (-not $status.Connected) { throw 'Local Tailscale is not connected.' }
        Remove-ManagedHostRoute -State $State -Config $Config
        $network = [pscustomobject]@{ Mode = 'LocalTailscale'; RouteAction = 'None'; ManagedByInstaller = $false; PortChecks = @() }
        if (-not [string]::IsNullOrEmpty($StatePath)) {
            Save-InstallerState -Path $StatePath -Config $Config -Network $network -PreviousState $State
        }
        $checks = @(Test-RustDeskPorts -Address $Config.Deployment.rustdesk.idServer -Ports $Config.Deployment.rustdesk.tcpPorts)
        if (@($checks | Where-Object { -not $_.Reachable }).Count -gt 0) {
            throw 'RustDesk server ports are not reachable through local Tailscale.'
        }
        $network.PortChecks = $checks
        return $network
    }

    $destination = [string]$Config.Deployment.route.destinationPrefix
    $currentRoutes = @(Get-NetRoute -DestinationPrefix $destination -ErrorAction SilentlyContinue)
    $managedGateway = [string](Get-ObjectValue $State 'ManagedRouteGateway' '')
    $plan = Get-RustDeskRoutePlan -DestinationPrefix $destination -Gateway $Request.RouterIp `
        -CurrentRoutes $currentRoutes -ManagedGateway $managedGateway
    if ($plan.Action -eq 'Conflict') { throw 'An unmanaged conflicting route already exists.' }
    if ($plan.Action -eq 'Replace') {
        if (-not $Request.ConfirmRouteReplacement) { throw 'Route replacement requires confirmation.' }
        $plan.Confirmed = $true
    }
    $routeResult = Set-RustDeskHostRoute -Plan $plan
    $managedByInstaller = ($plan.Action -in @('Create', 'Replace')) -or (
        $plan.Action -eq 'Reuse' -and
        [string](Get-ObjectValue $State 'ManagedRouteDestination' '') -ceq $destination -and
        $managedGateway -ceq [string]$Request.RouterIp
    )
    $network = [pscustomobject]@{
        Mode = 'Router'
        RouteAction = [string]$plan.Action
        ManagedByInstaller = $managedByInstaller
        Gateway = [string]$Request.RouterIp
        InterfaceIndex = [int](Get-ObjectValue $routeResult 'InterfaceIndex' (Get-ObjectValue $plan 'ExistingInterfaceIndex' 0))
        PortChecks = @()
    }
    if ($managedByInstaller -and -not [string]::IsNullOrEmpty($StatePath)) {
        Save-InstallerState -Path $StatePath -Config $Config -Network $network -PreviousState $State
    }

    $checks = @(Test-RustDeskPorts -Address $Config.Deployment.rustdesk.idServer -Ports $Config.Deployment.rustdesk.tcpPorts)
    if (@($checks | Where-Object { -not $_.Reachable }).Count -gt 0) {
        throw 'RustDesk server ports are not reachable through the router.'
    }
    $network.PortChecks = $checks
    return $network
}

function Invoke-RustDeskStage {
    param($Request, $Config, [string]$StateRoot, [scriptblock]$ProgressAction)

    if ($null -ne $ProgressAction) { & $ProgressAction 0 0 'Baixando RustDesk...' }
    $artifact = Get-VerifiedArtifact -Artifact $Config.Artifacts.rustdesk -CacheRoot (Join-Path $StateRoot 'downloads') -ProgressAction $ProgressAction
    if ($null -ne $ProgressAction) { & $ProgressAction 0 0 'Instalando RustDesk...' }
    $installation = Install-RustDesk -InstallerPath $artifact
    if ($null -ne $ProgressAction) { & $ProgressAction 0 0 'Configurando RustDesk...' }
    $token = New-RustDeskConfigToken -Host $Config.Deployment.rustdesk.idServer `
        -Key $Config.Deployment.rustdesk.publicKey -Relay $Config.Deployment.rustdesk.relayServer
    Set-RustDeskConfiguration -ExecutablePath $installation.ExecutablePath -ConfigToken $token -Password $Request.RustDeskPassword
    if ($null -ne $ProgressAction) { & $ProgressAction 0 0 'Verificando o ID do RustDesk...' }
    $id = Get-RustDeskId -ExecutablePath $installation.ExecutablePath
    [pscustomobject]@{
        Requested = $true
        Installed = $true
        Configured = $true
        Id = $id
    }
}

function Invoke-DarckwareInstall {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Request,
        [Parameter(Mandatory)][string]$RepoRoot,
        [scriptblock]$ProgressAction
    )

    if ($null -ne $ProgressAction) { & $ProgressAction 0 0 'Validando os componentes selecionados...' }
    Test-InstallRequest -Request $Request
    $effectiveRequest = Copy-NormalizedRequest -Request $Request
    $config = Get-InstallerConfig -RepoRoot $RepoRoot
    $stateRoot = Resolve-InstallerStateRoot -Deployment $config.Deployment
    New-Item -ItemType Directory -Path $stateRoot -Force -ErrorAction Stop | Out-Null
    $logPath = Join-Path $stateRoot 'installer.log'
    $statePath = Join-Path $stateRoot 'state.json'
    $state = Read-InstallerState -Path $statePath

    try {
        Write-InstallerLog -Path $logPath -Text 'Installation started.'
        $tailscale = [pscustomobject]@{ Requested = $false; Installed = $false; Connected = $false; RebootRequired = $false }
        if ($effectiveRequest.InstallTailscale) {
            if ($null -ne $ProgressAction) { & $ProgressAction 0 0 'Verificando Tailscale...' }
            $tailscale = Invoke-TailscaleStage -Request $effectiveRequest -Config $config -StateRoot $stateRoot -ProgressAction $ProgressAction
        }

        if ($null -ne $ProgressAction) { & $ProgressAction 0 0 'Verificando a conectividade...' }
        $network = Invoke-ConnectivityStage -Request $effectiveRequest -Config $config -State $state -StatePath $statePath
        if ($network.Mode -eq 'LocalTailscale') {
            # Local Tailscale may be reused without being selected for installation.
            $tailscale.Connected = $true
        }
        $rustDesk = [pscustomobject]@{ Requested = $false; Installed = $false; Configured = $false; Id = '' }
        if ($effectiveRequest.InstallRustDesk) {
            if ($null -ne $ProgressAction) { & $ProgressAction 0 0 'Preparando RustDesk...' }
            $rustDesk = Invoke-RustDeskStage -Request $effectiveRequest -Config $config -StateRoot $stateRoot -ProgressAction $ProgressAction
        }

        if ($null -ne $ProgressAction) { & $ProgressAction 0 0 'Salvando o resultado da instalacao...' }
        Save-InstallerState -Path $statePath -Config $config -Network $network -PreviousState $state
        Write-InstallerLog -Path $logPath -Text 'Installation completed.'
        if ($null -ne $ProgressAction) { & $ProgressAction 100 100 'Instalacao concluida.' }
        [pscustomobject]@{
            Success = $true
            Tailscale = $tailscale
            RustDesk = $rustDesk
            Network = $network
            LogPath = $logPath
        }
    }
    catch {
        $safeMessage = Protect-LogText -Text $_.Exception.Message
        Write-InstallerLog -Path $logPath -Text "Installation failed: $safeMessage"
        throw $safeMessage
    }
}

Export-ModuleMember -Function Test-InstallRequest, Invoke-DarckwareInstall
