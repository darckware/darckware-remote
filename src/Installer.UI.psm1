Set-StrictMode -Version Latest

function Get-WizardPageState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][bool]$InstallTailscale,
        [Parameter(Mandatory)][bool]$InstallRustDesk,
        [Parameter(Mandatory)][bool]$TailscaleConnected
    )

    $hasComponent = $InstallTailscale -or $InstallRustDesk
    $useLocalTailscale = $InstallTailscale -or $TailscaleConnected
    [pscustomobject]@{
        ShowTailscaleFields = $InstallTailscale
        ShowConnectivityFields = ($InstallRustDesk -and -not $useLocalTailscale)
        ShowPasswordFields = $InstallRustDesk
        EffectiveConnectivityMode = $(if ($InstallRustDesk -and $useLocalTailscale) { 'LocalTailscale' } else { 'Router' })
        CanContinue = $hasComponent
        ValidationMessage = $(if ($hasComponent) { '' } else { 'Selecione pelo menos um componente.' })
    }
}

function New-DarckwareLabel {
    param([string]$Text, [float]$Size = 10, [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular)
    $label = [System.Windows.Forms.Label]::new()
    $label.Text = $Text
    $label.Font = [System.Drawing.Font]::new('Segoe UI', $Size, $Style)
    $label.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#F2F4F7')
    $label.AutoSize = $true
    return $label
}

function New-DarckwareBrandImage {
    [CmdletBinding()]
    [OutputType([System.Windows.Forms.PictureBox])]
    param([Parameter(Mandatory)][string]$AssetRoot)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $assetPath = Join-Path $AssetRoot 'darckware-lockup-dark.png'
    if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
        throw "Official Darckware lockup not found: $assetPath"
    }

    $stream = [System.IO.File]::OpenRead($assetPath)
    try {
        $source = [System.Drawing.Image]::FromStream($stream)
        try { $image = [System.Drawing.Bitmap]::new($source) }
        finally { $source.Dispose() }
    }
    finally {
        $stream.Dispose()
    }

    $picture = [System.Windows.Forms.PictureBox]::new()
    $picture.Image = $image
    $picture.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $picture.AccessibleName = 'Darckware'
    return $picture
}

function Show-InstallerWizard {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Config)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $canvas = [System.Drawing.ColorTranslator]::FromHtml('#0B0D10')
    $surface = [System.Drawing.ColorTranslator]::FromHtml('#12151A')
    $mint = [System.Drawing.ColorTranslator]::FromHtml('#5CF2C4')
    $blue = [System.Drawing.ColorTranslator]::FromHtml('#3DAEFF')
    $text = [System.Drawing.ColorTranslator]::FromHtml('#F2F4F7')
    $muted = [System.Drawing.ColorTranslator]::FromHtml('#7C8794')
    $errorColor = [System.Drawing.ColorTranslator]::FromHtml('#FF6B7A')

    $form = [System.Windows.Forms.Form]::new()
    $form.Text = 'Darckware Remoto — Instalação'
    $form.ClientSize = [System.Drawing.Size]::new(820, 560)
    $form.MinimumSize = [System.Drawing.Size]::new(820, 560)
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = $canvas
    $form.ForeColor = $text
    $form.Font = [System.Drawing.Font]::new('Segoe UI', 10)
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $iconPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets/darckware-icon-32.png'
    if (Test-Path -LiteralPath $iconPath) {
        $bitmap = [System.Drawing.Bitmap]::FromFile($iconPath)
        $form.Icon = [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
    }

    $rail = [System.Windows.Forms.Panel]::new()
    $rail.Dock = 'Left'; $rail.Width = 220; $rail.BackColor = $surface
    $form.Controls.Add($rail)
    $assetRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets'
    $brand = New-DarckwareBrandImage -AssetRoot $assetRoot
    $brand.Location = [System.Drawing.Point]::new(18, 22)
    $brand.Size = [System.Drawing.Size]::new(184, 51)
    $brand.BackColor = $surface
    $rail.Controls.Add($brand)
    $steps = @('1  Componentes', '2  Conectividade', '3  Acesso', '4  Revisão')
    $stepLabels = @()
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $label = New-DarckwareLabel -Text $steps[$i] -Size 10
        $label.Location = [System.Drawing.Point]::new(28, 112 + (52 * $i))
        $label.ForeColor = $(if ($i -eq 0) { $mint } else { $muted })
        $rail.Controls.Add($label); $stepLabels += $label
    }

    $content = [System.Windows.Forms.Panel]::new()
    $content.Location = [System.Drawing.Point]::new(220, 0); $content.Size = [System.Drawing.Size]::new(600, 470)
    $content.BackColor = $canvas; $form.Controls.Add($content)
    $pages = @()
    for ($i = 0; $i -lt 4; $i++) {
        $page = [System.Windows.Forms.Panel]::new(); $page.Dock = 'Fill'; $page.Visible = ($i -eq 0)
        $content.Controls.Add($page); $pages += $page
    }

    $title0 = New-DarckwareLabel 'O que será instalado?' 20 Bold
    $title0.Location = [System.Drawing.Point]::new(40, 42); $pages[0].Controls.Add($title0)
    $hint0 = New-DarckwareLabel 'Selecione um ou os dois componentes.' 10
    $hint0.ForeColor = $muted; $hint0.Location = [System.Drawing.Point]::new(42, 82); $pages[0].Controls.Add($hint0)
    $tailscaleCheck = [System.Windows.Forms.CheckBox]::new()
    $tailscaleCheck.Text = 'Tailscale — conexão segura à tailnet'; $tailscaleCheck.Location = [System.Drawing.Point]::new(44, 142)
    $tailscaleCheck.Size = [System.Drawing.Size]::new(460, 36); $tailscaleCheck.ForeColor = $text; $pages[0].Controls.Add($tailscaleCheck)
    $rustDeskCheck = [System.Windows.Forms.CheckBox]::new()
    $rustDeskCheck.Text = 'RustDesk — acesso remoto Darckware'; $rustDeskCheck.Location = [System.Drawing.Point]::new(44, 194)
    $rustDeskCheck.Size = [System.Drawing.Size]::new(460, 36); $rustDeskCheck.ForeColor = $text; $pages[0].Controls.Add($rustDeskCheck)

    $title1 = New-DarckwareLabel 'Conectividade' 20 Bold
    $title1.Location = [System.Drawing.Point]::new(40, 42); $pages[1].Controls.Add($title1)
    $hostnameLabel = New-DarckwareLabel 'Nome deste computador no Tailscale' 10
    $hostnameLabel.Location = [System.Drawing.Point]::new(42, 100); $pages[1].Controls.Add($hostnameLabel)
    $hostnameBox = [System.Windows.Forms.TextBox]::new(); $hostnameBox.Location = [System.Drawing.Point]::new(44, 128); $hostnameBox.Width = 470
    $hostnameBox.AccessibleName = 'Nome deste computador no Tailscale'
    $pages[1].Controls.Add($hostnameBox)
    $authLabel = New-DarckwareLabel 'Chave de autenticação Tailscale' 10
    $authLabel.Location = [System.Drawing.Point]::new(42, 178); $pages[1].Controls.Add($authLabel)
    $authBox = [System.Windows.Forms.TextBox]::new(); $authBox.Location = [System.Drawing.Point]::new(44, 206); $authBox.Width = 470; $authBox.UseSystemPasswordChar = $true
    $authBox.AccessibleName = 'Chave de autenticação Tailscale'
    $pages[1].Controls.Add($authBox)
    $showAuth = [System.Windows.Forms.CheckBox]::new(); $showAuth.Text = 'Mostrar chave'; $showAuth.Location = [System.Drawing.Point]::new(44, 238); $showAuth.Width = 180; $showAuth.ForeColor = $muted
    $showAuth.Add_CheckedChanged({ $authBox.UseSystemPasswordChar = -not $showAuth.Checked })
    $pages[1].Controls.Add($showAuth)
    $localRadio = [System.Windows.Forms.RadioButton]::new(); $localRadio.Text = 'Usar Tailscale já conectado neste computador'; $localRadio.Location = [System.Drawing.Point]::new(44, 286); $localRadio.Width = 470; $localRadio.ForeColor = $text; $localRadio.Checked = $true
    $pages[1].Controls.Add($localRadio)
    $routerRadio = [System.Windows.Forms.RadioButton]::new(); $routerRadio.Text = 'Usar uma estação roteadora Tailscale'; $routerRadio.Location = [System.Drawing.Point]::new(44, 324); $routerRadio.Width = 470; $routerRadio.ForeColor = $text
    $pages[1].Controls.Add($routerRadio)
    $routerBox = [System.Windows.Forms.TextBox]::new(); $routerBox.Location = [System.Drawing.Point]::new(64, 362); $routerBox.Width = 450; $routerBox.Enabled = $false
    $routerBox.AccessibleName = 'Endereço IPv4 da estação roteadora'
    $pages[1].Controls.Add($routerBox)
    $routerRadio.Add_CheckedChanged({ $routerBox.Enabled = $routerRadio.Checked; if ($null -ne $updateNext) { & $updateNext } })

    $title2 = New-DarckwareLabel 'Acesso não assistido' 20 Bold
    $title2.Location = [System.Drawing.Point]::new(40, 42); $pages[2].Controls.Add($title2)
    $passwordLabel = New-DarckwareLabel 'Senha permanente do RustDesk (opcional)' 10
    $passwordLabel.Location = [System.Drawing.Point]::new(42, 112); $pages[2].Controls.Add($passwordLabel)
    $passwordBox = [System.Windows.Forms.TextBox]::new(); $passwordBox.Location = [System.Drawing.Point]::new(44, 142); $passwordBox.Width = 470; $passwordBox.UseSystemPasswordChar = $true
    $passwordBox.AccessibleName = 'Senha permanente do RustDesk'
    $pages[2].Controls.Add($passwordBox)
    $confirmLabel = New-DarckwareLabel 'Confirme a senha' 10
    $confirmLabel.Location = [System.Drawing.Point]::new(42, 198); $pages[2].Controls.Add($confirmLabel)
    $confirmBox = [System.Windows.Forms.TextBox]::new(); $confirmBox.Location = [System.Drawing.Point]::new(44, 228); $confirmBox.Width = 470; $confirmBox.UseSystemPasswordChar = $true
    $confirmBox.AccessibleName = 'Confirmação da senha permanente do RustDesk'
    $pages[2].Controls.Add($confirmBox)
    $showPassword = [System.Windows.Forms.CheckBox]::new(); $showPassword.Text = 'Mostrar senha'; $showPassword.Location = [System.Drawing.Point]::new(44, 262); $showPassword.Width = 180; $showPassword.ForeColor = $muted
    $showPassword.Add_CheckedChanged({
        $masked = -not $showPassword.Checked
        $passwordBox.UseSystemPasswordChar = $masked
        $confirmBox.UseSystemPasswordChar = $masked
    })
    $pages[2].Controls.Add($showPassword)

    $title3 = New-DarckwareLabel 'Revisar instalação' 20 Bold
    $title3.Location = [System.Drawing.Point]::new(40, 42); $pages[3].Controls.Add($title3)
    $review = New-DarckwareLabel '' 11
    $review.Location = [System.Drawing.Point]::new(44, 108); $review.MaximumSize = [System.Drawing.Size]::new(480, 260)
    $pages[3].Controls.Add($review)
    $routeConfirm = [System.Windows.Forms.CheckBox]::new(); $routeConfirm.Text = 'Confirmo a substituição da rota gerenciada, se necessária.'
    $routeConfirm.Location = [System.Drawing.Point]::new(44, 320); $routeConfirm.Width = 500; $routeConfirm.ForeColor = $text; $pages[3].Controls.Add($routeConfirm)

    $errorLabel = New-DarckwareLabel '' 9
    $errorLabel.ForeColor = $errorColor; $errorLabel.Location = [System.Drawing.Point]::new(264, 474); $errorLabel.Size = [System.Drawing.Size]::new(520, 24); $errorLabel.AutoSize = $false
    $form.Controls.Add($errorLabel)
    $back = [System.Windows.Forms.Button]::new(); $back.Text = 'Voltar'; $back.Location = [System.Drawing.Point]::new(532, 510); $back.Size = [System.Drawing.Size]::new(110, 34); $back.Enabled = $false
    $next = [System.Windows.Forms.Button]::new(); $next.Text = 'Continuar'; $next.Location = [System.Drawing.Point]::new(654, 510); $next.Size = [System.Drawing.Size]::new(130, 34); $next.BackColor = $mint; $next.FlatStyle = 'Flat'; $next.Enabled = $false
    $form.Controls.Add($back); $form.Controls.Add($next); $form.AcceptButton = $next
    $cancel = [System.Windows.Forms.Button]::new(); $cancel.Text = 'Cancelar'; $cancel.DialogResult = 'Cancel'; $cancel.Location = [System.Drawing.Point]::new(244, 510); $cancel.Size = [System.Drawing.Size]::new(100, 34)
    $form.Controls.Add($cancel); $form.CancelButton = $cancel

    $pageIndex = 0; $request = $null; $updateNext = $null
    $updateNext = {
        $valid = $true
        if ($pageIndex -eq 0) {
            $valid = $tailscaleCheck.Checked -or $rustDeskCheck.Checked
        }
        elseif ($pageIndex -eq 1) {
            if ($tailscaleCheck.Checked) {
                $valid = -not [string]::IsNullOrWhiteSpace($hostnameBox.Text) -and -not [string]::IsNullOrWhiteSpace($authBox.Text)
            }
            elseif ($rustDeskCheck.Checked -and $routerRadio.Checked) {
                $valid = -not [string]::IsNullOrWhiteSpace($routerBox.Text)
            }
        }
        elseif ($pageIndex -eq 2) {
            $valid = $passwordBox.Text -ceq $confirmBox.Text
        }
        $next.Enabled = $valid
    }
    $showPage = {
        param([int]$Index)
        if ($Index -eq 1) {
            $showTailscale = $tailscaleCheck.Checked
            $showConnectivity = $rustDeskCheck.Checked -and -not $tailscaleCheck.Checked
            foreach ($control in @($hostnameLabel, $hostnameBox, $authLabel, $authBox)) { $control.Visible = $showTailscale }
            foreach ($control in @($localRadio, $routerRadio, $routerBox)) { $control.Visible = $showConnectivity }
        }
        for ($j = 0; $j -lt $pages.Count; $j++) { $pages[$j].Visible = ($j -eq $Index); $stepLabels[$j].ForeColor = $(if ($j -eq $Index) { $mint } elseif ($j -lt $Index) { $blue } else { $muted }) }
        $back.Enabled = $Index -gt 0; $next.Text = $(if ($Index -eq 3) { 'Instalar' } else { 'Continuar' }); $errorLabel.Text = ''; & $updateNext
    }
    foreach ($control in @($tailscaleCheck, $rustDeskCheck, $localRadio, $hostnameBox, $authBox, $routerBox, $passwordBox, $confirmBox)) {
        $control.Add_TextChanged({ & $updateNext })
        if ($control -is [System.Windows.Forms.CheckBox] -or $control -is [System.Windows.Forms.RadioButton]) { $control.Add_CheckedChanged({ & $updateNext }) }
    }
    $back.Add_Click({
        if ($pageIndex -gt 0) {
            if ($pageIndex -eq 3 -and -not $rustDeskCheck.Checked) { $pageIndex = 1 } else { $pageIndex-- }
            & $showPage $pageIndex
        }
    })
    $next.Add_Click({
        $state = Get-WizardPageState -InstallTailscale $tailscaleCheck.Checked -InstallRustDesk $rustDeskCheck.Checked -TailscaleConnected $localRadio.Checked
        if ($pageIndex -eq 0 -and -not $state.CanContinue) { $errorLabel.Text = $state.ValidationMessage; $tailscaleCheck.Focus(); return }
        if ($pageIndex -eq 1) {
            if ($tailscaleCheck.Checked -and [string]::IsNullOrWhiteSpace($hostnameBox.Text)) { $errorLabel.Text = 'Informe o nome deste computador no Tailscale.'; $hostnameBox.Focus(); return }
            if ($tailscaleCheck.Checked -and [string]::IsNullOrWhiteSpace($authBox.Text)) { $errorLabel.Text = 'Informe a chave de autenticação Tailscale.'; $authBox.Focus(); return }
            if ($rustDeskCheck.Checked -and -not $tailscaleCheck.Checked -and $routerRadio.Checked -and [string]::IsNullOrWhiteSpace($routerBox.Text)) { $errorLabel.Text = 'Informe o IPv4 da estação roteadora.'; $routerBox.Focus(); return }
        }
        if ($pageIndex -eq 2 -and $passwordBox.Text -cne $confirmBox.Text) { $errorLabel.Text = 'As senhas do RustDesk não coincidem.'; $confirmBox.Focus(); return }
        if ($pageIndex -lt 3) {
            if ($pageIndex -eq 1 -and -not $rustDeskCheck.Checked) { $pageIndex = 3 } else { $pageIndex++ }
            if ($pageIndex -eq 3) {
                $mode = $(if ($tailscaleCheck.Checked -or $localRadio.Checked) { 'LocalTailscale' } else { 'Router' })
                $review.Text = "Componentes: $(if ($tailscaleCheck.Checked) { 'Tailscale ' })$(if ($rustDeskCheck.Checked) { 'RustDesk' })`r`nConectividade: $mode`r`nChave Tailscale: $(if ($authBox.TextLength) { 'fornecida' } else { 'não fornecida' })`r`nSenha RustDesk: $(if ($passwordBox.TextLength) { 'fornecida' } else { 'não fornecida' })"
                $routeConfirm.Visible = ($mode -eq 'Router')
            }
            & $showPage $pageIndex; return
        }
        $request = [pscustomobject]@{
            InstallTailscale = $tailscaleCheck.Checked; InstallRustDesk = $rustDeskCheck.Checked
            ConnectivityMode = $(if ($tailscaleCheck.Checked -or $localRadio.Checked) { 'LocalTailscale' } else { 'Router' })
            RouterIp = $routerBox.Text; TailscaleHostname = $hostnameBox.Text
            TailscaleAuthKey = $(if ($authBox.TextLength) { ConvertTo-SecureString $authBox.Text -AsPlainText -Force } else { $null })
            RustDeskPassword = $(if ($passwordBox.TextLength) { ConvertTo-SecureString $passwordBox.Text -AsPlainText -Force } else { $null })
            ConfirmRouteReplacement = $routeConfirm.Checked
        }
        $authBox.Clear(); $passwordBox.Clear(); $confirmBox.Clear(); $form.DialogResult = 'OK'; $form.Close()
    })

    try { if ($form.ShowDialog() -eq 'OK') { return $request }; return $null }
    finally {
        $authBox.Clear(); $passwordBox.Clear(); $confirmBox.Clear()
        if ($null -ne $brand.Image) { $brand.Image.Dispose() }
        $form.Dispose()
    }
}

function Show-InstallResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Result)
    Add-Type -AssemblyName System.Windows.Forms
    $portSummary = @($Result.Network.PortChecks | ForEach-Object { "TCP $($_.Port): $(if ($_.Reachable) { 'OK' } else { 'falha' })" }) -join ', '
    if ([string]::IsNullOrEmpty($portSummary)) { $portSummary = 'não aplicável' }
    $message = "Instalação concluída.`r`n`r`nTailscale conectado: $($Result.Tailscale.Connected)`r`nRustDesk ID: $($Result.RustDesk.Id)`r`nRede: $($Result.Network.Mode)`r`nConectividade: $portSummary`r`nLog: $($Result.LogPath)`r`n`r`nAjuda: docs\troubleshooting.md"
    [System.Windows.Forms.MessageBox]::Show($message, 'Darckware Remoto — Resultado', 'OK', 'Information') | Out-Null
}

function Show-InstallProgress {
    [CmdletBinding()]
    [OutputType([System.Windows.Forms.Form])]
    param()

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = [System.Windows.Forms.Form]::new()
    $form.Text = 'Darckware Remoto — Instalando'
    $form.ClientSize = [System.Drawing.Size]::new(520, 190)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.ControlBox = $false
    $form.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#0B0D10')
    $title = New-DarckwareLabel 'Preparando o acesso remoto' 18 Bold
    $title.Location = [System.Drawing.Point]::new(34, 32)
    $detail = New-DarckwareLabel 'Validando, instalando e configurando os componentes selecionados…' 10
    $detail.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#7C8794')
    $detail.Location = [System.Drawing.Point]::new(36, 78)
    $progress = [System.Windows.Forms.ProgressBar]::new()
    $progress.Location = [System.Drawing.Point]::new(38, 124)
    $progress.Size = [System.Drawing.Size]::new(444, 12)
    $progress.Style = 'Marquee'
    $progress.MarqueeAnimationSpeed = 28
    $form.Controls.AddRange(@($title, $detail, $progress))
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    return $form
}

function Close-InstallProgress {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Windows.Forms.Form]$Form)
    if (-not $Form.IsDisposed) { $Form.Close(); $Form.Dispose() }
}

function Show-InstallFailure {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Add-Type -AssemblyName System.Windows.Forms
    $safeMessage = if ([string]::IsNullOrWhiteSpace($Message)) { 'A instalação não pôde ser concluída.' } else { $Message }
    [System.Windows.Forms.MessageBox]::Show(
        "A instalação não pôde ser concluída.`r`n`r`n$safeMessage`r`n`r`nConsulte docs\troubleshooting.md e o log em %ProgramData%\Darckware\RustDeskInstaller\installer.log.",
        'Darckware Remoto — Falha',
        'OK',
        'Error'
    ) | Out-Null
}

Export-ModuleMember -Function Get-WizardPageState, New-DarckwareBrandImage, Show-InstallerWizard, Show-InstallProgress, Close-InstallProgress, Show-InstallResult, Show-InstallFailure
