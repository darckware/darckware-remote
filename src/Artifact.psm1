function Get-InstallerConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $artifactsPath = Join-Path $RepoRoot 'config/artifacts.json'
    $deploymentPath = Join-Path $RepoRoot 'config/deployment.json'

    if (-not (Test-Path -LiteralPath $artifactsPath -PathType Leaf)) {
        throw "Artifact configuration not found: $artifactsPath"
    }
    if (-not (Test-Path -LiteralPath $deploymentPath -PathType Leaf)) {
        throw "Deployment configuration not found: $deploymentPath"
    }

    [pscustomobject]@{
        Artifacts = Get-Content -LiteralPath $artifactsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        Deployment = Get-Content -LiteralPath $deploymentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
}

function Invoke-ArtifactDownload {
    param([string]$Uri, [string]$OutFile, [scriptblock]$ProgressAction)
    $request = [Net.WebRequest]::Create($Uri)
    $response = $null
    $input = $null
    $output = $null
    try {
        $response = $request.GetResponse()
        $input = $response.GetResponseStream()
        $output = [IO.File]::Open($OutFile, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $total = [int64]$response.ContentLength
        $written = [int64]0
        $buffer = New-Object byte[] (64KB)
        do {
            $read = $input.Read($buffer, 0, $buffer.Length)
            if ($read -gt 0) {
                $output.Write($buffer, 0, $read)
                $written += $read
                if ($null -ne $ProgressAction) { & $ProgressAction $written $total }
                if ('System.Windows.Forms.Application' -as [type]) {
                    [System.Windows.Forms.Application]::DoEvents()
                }
            }
        } while ($read -gt 0)
        if ($null -ne $ProgressAction) {
            & $ProgressAction $written $(if ($total -gt 0) { $total } else { $written })
        }
    }
    finally {
        if ($null -ne $output) { $output.Dispose() }
        if ($null -ne $input) { $input.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
    }
}

function Get-VerifiedArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)][string]$CacheRoot,
        [scriptblock]$ProgressAction
    )

    $target = Join-Path $CacheRoot $Artifact.fileName
    New-Item -ItemType Directory -Force $CacheRoot | Out-Null
    Invoke-ArtifactDownload -Uri $Artifact.url -OutFile $target -ProgressAction $ProgressAction
    if ($null -ne $ProgressAction) { & $ProgressAction 0 0 "Validando o pacote $($Artifact.name)..." }
    $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Artifact.sha256.ToLowerInvariant()) {
        Remove-Item $target -Force
        throw "SHA-256 mismatch for $($Artifact.name)"
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $target
    if ($signature.Status -ne 'Valid') {
        Remove-Item $target -Force
        throw "Authenticode validation failed for $($Artifact.name)"
    }
    if ($signature.SignerCertificate.Subject -notlike "*$($Artifact.publisher)*") {
        Remove-Item $target -Force
        throw "Unexpected publisher for $($Artifact.name)"
    }

    return $target
}

Export-ModuleMember -Function Get-InstallerConfig, Get-VerifiedArtifact
