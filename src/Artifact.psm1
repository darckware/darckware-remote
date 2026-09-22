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

function Get-VerifiedArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)][string]$CacheRoot
    )

    $target = Join-Path $CacheRoot $Artifact.fileName
    New-Item -ItemType Directory -Force $CacheRoot | Out-Null
    Invoke-WebRequest -Uri $Artifact.url -OutFile $target -UseBasicParsing
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
