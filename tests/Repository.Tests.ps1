BeforeAll { $script:RepoRoot = (Resolve-Path "$PSScriptRoot/..").Path }

Describe 'public repository contract' {
    It 'contains required operator documentation, workflow, and assets' {
        @(
            'README.md',
            'LICENSE',
            'THIRD_PARTY_NOTICES.md',
            'docs/router-prerequisites.md',
            'docs/troubleshooting.md',
            '.github/workflows/windows-tests.yml',
            'assets/darckware-icon-512.png',
            'assets/darckware-lockup-dark.png'
        ) | ForEach-Object {
            Test-Path (Join-Path $script:RepoRoot $_) | Should -BeTrue -Because "$_ is part of the public release"
        }
    }

    It 'documents the exact primary installation workflow' {
        $readme = Get-Content (Join-Path $script:RepoRoot 'README.md') -Raw
        $readme | Should -Match ([regex]::Escape('git clone https://github.com/marcelodarckferreira/rustdesk-darckware.git'))
        $readme | Should -Match ([regex]::Escape('cd rustdesk-darckware'))
        $readme | Should -Match ([regex]::Escape('.\install.cmd'))
    }

    It 'selects a high-contrast Darckware lockup for each GitHub color scheme' {
        $readme = Get-Content (Join-Path $script:RepoRoot 'README.md') -Raw
        $readme | Should -Match '<picture>'
        $readme | Should -Match '<source media="\(prefers-color-scheme: dark\)" srcset="assets/darckware-lockup-dark\.svg">'
        $readme | Should -Match '<source media="\(prefers-color-scheme: light\)" srcset="assets/darckware-lockup-light\.svg">'
    }

    It 'pins Windows CI to Pester 5.7.1 and runs the complete suite' {
        $workflow = Get-Content (Join-Path $script:RepoRoot '.github/workflows/windows-tests.yml') -Raw
        $workflow | Should -Match 'RequiredVersion\s+5\.7\.1'
        $workflow | Should -Match 'Invoke-Pester\s+tests\s+-CI'
        $workflow | Should -Match 'windows-latest'
    }

    It 'contains no committed Tailscale auth key' {
        $matches = @(git -C $script:RepoRoot grep -n -E 'tskey-(auth|client)-[A-Za-z0-9_-]{10,}' -- . ':(exclude)docs/superpowers/plans/*')
        $matches | Should -BeNullOrEmpty
    }
}
