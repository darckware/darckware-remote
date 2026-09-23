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
    $client = [Net.WebClient]::new()
    try {
        if ($null -ne $ProgressAction) {
            $client.add_DownloadProgressChanged({
                param($sender, $event)
                & $ProgressAction ([int64]$event.BytesReceived) ([int64]$event.TotalBytesToReceive)
            })
        }
        $client.DownloadFile($Uri, $OutFile)
        if ($null -ne $ProgressAction) { & $ProgressAction ([int64](Get-Item $OutFile).Length) ([int64](Get-Item $OutFile).Length) }
    }
    finally { $client.Dispose() }
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
