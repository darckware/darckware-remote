BeforeAll { Import-Module "$PSScriptRoot/../src/Installer.UI.psm1" -Force }

Describe 'Get-WizardPageState' {
    It 'shows Tailscale fields only when Tailscale is selected' {
        $state = Get-WizardPageState -InstallTailscale $true -InstallRustDesk $false -TailscaleConnected $false
        $state.ShowTailscaleFields | Should -BeTrue
        $state.ShowConnectivityFields | Should -BeFalse
        $state.ShowPasswordFields | Should -BeFalse
        $state.CanContinue | Should -BeTrue
    }

    It 'asks for connectivity only for RustDesk without local Tailscale' {
        $state = Get-WizardPageState -InstallTailscale $false -InstallRustDesk $true -TailscaleConnected $false
        $state.ShowTailscaleFields | Should -BeFalse
        $state.ShowConnectivityFields | Should -BeTrue
        $state.ShowPasswordFields | Should -BeTrue
    }

    It 'uses local Tailscale for combined installation without routing fields' {
        $state = Get-WizardPageState -InstallTailscale $true -InstallRustDesk $true -TailscaleConnected $false
        $state.ShowConnectivityFields | Should -BeFalse
        $state.EffectiveConnectivityMode | Should -Be 'LocalTailscale'
    }

    It 'blocks progression when no component is selected' {
        $state = Get-WizardPageState -InstallTailscale $false -InstallRustDesk $false -TailscaleConnected $false
        $state.CanContinue | Should -BeFalse
        $state.ValidationMessage | Should -Match 'componente'
    }
}

Describe 'Show-InstallerWizard contract' {
    It 'exports the wizard and result interfaces' {
        Get-Command Show-InstallerWizard -Module Installer.UI | Should -Not -BeNullOrEmpty
        Get-Command Show-InstallProgress -Module Installer.UI | Should -Not -BeNullOrEmpty
        Get-Command Close-InstallProgress -Module Installer.UI | Should -Not -BeNullOrEmpty
        Get-Command Show-InstallResult -Module Installer.UI | Should -Not -BeNullOrEmpty
        Get-Command Show-InstallFailure -Module Installer.UI | Should -Not -BeNullOrEmpty
    }

    It 'uses the Darckware Remoto product name and masks all secret fields' {
        $content = Get-Content "$PSScriptRoot/../src/Installer.UI.psm1" -Raw
        $content | Should -Match 'Darckware Remoto'
        ([regex]::Matches($content, 'UseSystemPasswordChar\s*=\s*\$true')).Count | Should -BeGreaterOrEqual 3
        $content | Should -Match 'Mostrar chave'
        $content | Should -Match 'Mostrar senha'
        $content | Should -Match '\$updateNext'
        $content | Should -Match '\$next\.Enabled'
        $content | Should -Match 'ProgressBar'
        $content | Should -Match 'troubleshooting\.md'
    }
}
