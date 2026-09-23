BeforeAll {
    Import-Module "$PSScriptRoot/../src/Artifact.psm1" -Force
    $repo = (Resolve-Path "$PSScriptRoot/..").Path
}

Describe 'Get-InstallerConfig' {
    It 'loads exact pinned versions and deployment values' {
        $config = Get-InstallerConfig -RepoRoot $repo
        $config.Artifacts.rustdesk.version | Should -Be '1.4.9'
        $config.Artifacts.tailscale.version | Should -Be '1.102.3'
        $config.Deployment.rustdesk.idServer | Should -Be '100.105.235.114'
        $config.Deployment.route.destinationPrefix | Should -Be '100.105.235.114/32'
    }

    It 'contains only HTTPS artifact URLs and 64-character hashes' {
        $config = Get-InstallerConfig -RepoRoot $repo
        foreach ($artifact in @($config.Artifacts.rustdesk, $config.Artifacts.tailscale)) {
            $artifact.url | Should -Match '^https://'
            $artifact.sha256 | Should -Match '^[a-f0-9]{64}$'
        }
    }
}

Describe 'Get-VerifiedArtifact' {
    It 'reports download progress while writing the artifact' {
        $progress = [Collections.Generic.List[object]]::new()
        Mock Invoke-ArtifactDownload -ModuleName Artifact {
            [IO.File]::WriteAllText($OutFile, 'fixture')
            & $ProgressAction 7 7
        }
        Mock Get-FileHash -ModuleName Artifact { [pscustomobject]@{ Hash = $Artifact.sha256 } }
        Mock Get-AuthenticodeSignature -ModuleName Artifact {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Fixture' } }
        }
        $artifact = [pscustomobject]@{ fileName = 'fixture.exe'; url = 'https://example.test/fixture'; sha256 = ('a' * 64); publisher = 'Fixture' }
        Get-VerifiedArtifact -Artifact $artifact -CacheRoot $TestDrive -ProgressAction { param($written, $total) $progress.Add([pscustomobject]@{ Written = $written; Total = $total }) } | Out-Null
        $progress | Should -HaveCount 1
        $progress[0].Written | Should -Be 7
    }
    It 'rejects a checksum mismatch before signature verification' {
        Mock Invoke-ArtifactDownload -ModuleName Artifact { Set-Content -LiteralPath $OutFile -Value 'tampered' -NoNewline }
        Mock Get-AuthenticodeSignature -ModuleName Artifact { throw 'signature check must not run' }
        $artifact = [pscustomobject]@{ name='x'; fileName='x.exe'; url='https://example.test/x.exe'; sha256=('0' * 64); publisher='Example' }
        { Get-VerifiedArtifact -Artifact $artifact -CacheRoot $TestDrive } | Should -Throw '*SHA-256*'
        Should -Invoke Get-AuthenticodeSignature -ModuleName Artifact -Times 0
    }

    It 'rejects invalid signatures and unexpected publishers' {
        # Use a fixture hash for the bytes emitted by the download mock.
        $bytes = [Text.Encoding]::UTF8.GetBytes('signed-fixture')
        $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
        Mock Invoke-ArtifactDownload -ModuleName Artifact { [IO.File]::WriteAllBytes($OutFile, $bytes) }
        $artifact = [pscustomobject]@{ name='x'; fileName='x.exe'; url='https://example.test/x.exe'; sha256=$hash; publisher='Expected Publisher' }
        Mock Get-AuthenticodeSignature -ModuleName Artifact { [pscustomobject]@{ Status='NotSigned'; SignerCertificate=$null } }
        { Get-VerifiedArtifact -Artifact $artifact -CacheRoot $TestDrive } | Should -Throw '*Authenticode*'
        Mock Get-AuthenticodeSignature -ModuleName Artifact { [pscustomobject]@{ Status='Valid'; SignerCertificate=[pscustomobject]@{ Subject='CN=Wrong Publisher' } } }
        { Get-VerifiedArtifact -Artifact $artifact -CacheRoot $TestDrive } | Should -Throw '*publisher*'
    }
}
