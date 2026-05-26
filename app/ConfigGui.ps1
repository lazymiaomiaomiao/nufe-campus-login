param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'NufeCampusLogin'),
    [switch]$CreateStartup,
    [switch]$StartMonitorAfterSave
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$configPath = Join-Path $InstallDir 'config.json'
$credentialPath = Join-Path $InstallDir 'credential.clixml'
$providerDefaults = @{
    '电信' = '@njxy'
    '移动' = '@xyw'
}

function Get-ExistingConfig {
    if (Test-Path -LiteralPath $configPath) {
        return Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    return [pscustomobject]@{
        ssid                  = 'NUFE-STU'
        profileName           = 'NUFE-STU'
        portalHost            = '10.200.253.5'
        eportalHost           = '10.200.253.5'
        jsVersion             = '3.3.2'
        loginMethod           = 1
        provider              = '电信'
        preferredSuffix       = '@njxy'
        preferLastKnownSuffix = $true
        lastKnownSuffix       = '@njxy'
        lastKnownAccount      = ''
        lastSeenAt            = ''
    }
}

function Get-ExistingUsername {
    if (Test-Path -LiteralPath $credentialPath) {
        try {
            return (Import-Clixml -LiteralPath $credentialPath).UserName
        }
        catch {
            return ''
        }
    }

    return ''
}

function Write-StartupLauncher {
    param([string]$InstallDir)

    $monitorPath = Join-Path $InstallDir 'NufeCampusMonitor.ps1'
    $launcherPath = Join-Path $InstallDir 'Launch-NufeCampusMonitor.vbs'
    $startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    $startupLauncher = Join-Path $startupDir 'NufeCampusMonitor.vbs'

    New-Item -ItemType Directory -Force -LiteralPath $startupDir | Out-Null
    $escapedMonitor = $monitorPath.Replace('"', '""')
    $content = @(
        'Set shell = CreateObject("WScript.Shell")'
        ('shell.Run "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{0}""", 0, False' -f $escapedMonitor)
    )
    $content | Set-Content -LiteralPath $launcherPath -Encoding ASCII
    Copy-Item -LiteralPath $launcherPath -Destination $startupLauncher -Force
}

function Start-Monitor {
    param([string]$InstallDir)

    $launcherPath = Join-Path $InstallDir 'Launch-NufeCampusMonitor.vbs'
    if (Test-Path -LiteralPath $launcherPath) {
        Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$launcherPath`"" -WindowStyle Hidden | Out-Null
    }
}

function Save-Settings {
    param(
        [string]$Provider,
        [string]$Username,
        [string]$Password,
        [string]$Suffix
    )

    New-Item -ItemType Directory -Force -LiteralPath $InstallDir | Out-Null

    $cleanUsername = $Username.Trim()
    $cleanSuffix = $Suffix.Trim()
    if ($cleanUsername -match '^(.+?)(@[^@]+)$') {
        $cleanUsername = $Matches[1]
        $cleanSuffix = $Matches[2]
    }

    $existingPassword = Test-Path -LiteralPath $credentialPath
    if (-not $cleanUsername) {
        throw '请填写账号。'
    }

    if (-not $Password -and -not $existingPassword) {
        throw '首次部署需要填写密码。'
    }

    if ($Password) {
        $securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
        [pscredential]::new($cleanUsername, $securePassword) | Export-Clixml -LiteralPath $credentialPath
    }
    elseif ($existingPassword) {
        $oldCredential = Import-Clixml -LiteralPath $credentialPath
        [pscredential]::new($cleanUsername, $oldCredential.Password) | Export-Clixml -LiteralPath $credentialPath
    }

    $config = [pscustomobject]@{
        ssid                  = 'NUFE-STU'
        profileName           = 'NUFE-STU'
        portalHost            = '10.200.253.5'
        eportalHost           = '10.200.253.5'
        jsVersion             = '3.3.2'
        loginMethod           = 1
        provider              = $Provider
        preferredSuffix       = $cleanSuffix
        preferLastKnownSuffix = $true
        lastKnownSuffix       = $cleanSuffix
        lastKnownAccount      = "$cleanUsername$cleanSuffix"
        lastSeenAt            = ''
    }

    $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding UTF8

    if ($CreateStartup) {
        Write-StartupLauncher -InstallDir $InstallDir
    }

    if ($StartMonitorAfterSave) {
        Start-Monitor -InstallDir $InstallDir
    }
}

$config = Get-ExistingConfig
$existingUsername = Get-ExistingUsername

$form = New-Object System.Windows.Forms.Form
$form.Text = 'NUFE 校园网登录配置'
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.ClientSize = New-Object System.Drawing.Size(430, 310)
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'NUFE 校园网登录'
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(22, 18)
$title.Size = New-Object System.Drawing.Size(360, 28)
$form.Controls.Add($title)

$providerLabel = New-Object System.Windows.Forms.Label
$providerLabel.Text = '运营商'
$providerLabel.Location = New-Object System.Drawing.Point(24, 65)
$providerLabel.Size = New-Object System.Drawing.Size(90, 24)
$form.Controls.Add($providerLabel)

$providerCombo = New-Object System.Windows.Forms.ComboBox
$providerCombo.DropDownStyle = 'DropDownList'
[void]$providerCombo.Items.Add('电信')
[void]$providerCombo.Items.Add('移动')
$providerCombo.Location = New-Object System.Drawing.Point(120, 62)
$providerCombo.Size = New-Object System.Drawing.Size(260, 28)
$selectedProvider = '电信'
if (($config.PSObject.Properties.Name -contains 'provider') -and $config.provider -and $providerDefaults.ContainsKey([string]$config.provider)) {
    $selectedProvider = [string]$config.provider
}
$providerCombo.SelectedItem = $selectedProvider
$form.Controls.Add($providerCombo)

$accountLabel = New-Object System.Windows.Forms.Label
$accountLabel.Text = '账号'
$accountLabel.Location = New-Object System.Drawing.Point(24, 105)
$accountLabel.Size = New-Object System.Drawing.Size(90, 24)
$form.Controls.Add($accountLabel)

$accountBox = New-Object System.Windows.Forms.TextBox
$accountBox.Location = New-Object System.Drawing.Point(120, 102)
$accountBox.Size = New-Object System.Drawing.Size(260, 28)
$accountBox.Text = $existingUsername
$form.Controls.Add($accountBox)

$passwordLabel = New-Object System.Windows.Forms.Label
$passwordLabel.Text = '密码'
$passwordLabel.Location = New-Object System.Drawing.Point(24, 145)
$passwordLabel.Size = New-Object System.Drawing.Size(90, 24)
$form.Controls.Add($passwordLabel)

$passwordBox = New-Object System.Windows.Forms.TextBox
$passwordBox.Location = New-Object System.Drawing.Point(120, 142)
$passwordBox.Size = New-Object System.Drawing.Size(260, 28)
$passwordBox.UseSystemPasswordChar = $true
$form.Controls.Add($passwordBox)

$suffixLabel = New-Object System.Windows.Forms.Label
$suffixLabel.Text = '账号后缀'
$suffixLabel.Location = New-Object System.Drawing.Point(24, 185)
$suffixLabel.Size = New-Object System.Drawing.Size(90, 24)
$form.Controls.Add($suffixLabel)

$suffixBox = New-Object System.Windows.Forms.TextBox
$suffixBox.Location = New-Object System.Drawing.Point(120, 182)
$suffixBox.Size = New-Object System.Drawing.Size(260, 28)
$selectedSuffix = '@njxy'
if (($config.PSObject.Properties.Name -contains 'preferredSuffix') -and $config.preferredSuffix) {
    $selectedSuffix = [string]$config.preferredSuffix
}
$suffixBox.Text = $selectedSuffix
$form.Controls.Add($suffixBox)

$showPassword = New-Object System.Windows.Forms.CheckBox
$showPassword.Text = '显示密码'
$showPassword.Location = New-Object System.Drawing.Point(120, 218)
$showPassword.Size = New-Object System.Drawing.Size(110, 24)
$showPassword.Add_CheckedChanged({
    $passwordBox.UseSystemPasswordChar = -not $showPassword.Checked
})
$form.Controls.Add($showPassword)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = if (Test-Path -LiteralPath $credentialPath) { '已检测到现有配置。密码留空会继续使用原密码。' } else { '首次部署需要填写账号和密码。' }
$statusLabel.Location = New-Object System.Drawing.Point(24, 248)
$statusLabel.Size = New-Object System.Drawing.Size(380, 24)
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(88, 88, 88)
$form.Controls.Add($statusLabel)

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = '保存并部署'
$saveButton.Location = New-Object System.Drawing.Point(194, 275)
$saveButton.Size = New-Object System.Drawing.Size(100, 28)
$saveButton.DialogResult = [System.Windows.Forms.DialogResult]::None
$form.Controls.Add($saveButton)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = '取消'
$cancelButton.Location = New-Object System.Drawing.Point(306, 275)
$cancelButton.Size = New-Object System.Drawing.Size(74, 28)
$cancelButton.Add_Click({ $form.Close() })
$form.Controls.Add($cancelButton)

$providerCombo.Add_SelectedIndexChanged({
    $name = [string]$providerCombo.SelectedItem
    if ($providerDefaults.ContainsKey($name)) {
        $suffixBox.Text = $providerDefaults[$name]
    }
})

$saveButton.Add_Click({
    try {
        Save-Settings -Provider ([string]$providerCombo.SelectedItem) -Username $accountBox.Text -Password $passwordBox.Text -Suffix $suffixBox.Text
        [System.Windows.Forms.MessageBox]::Show('部署完成。后台自动检查已开启。', 'NUFE 校园网登录', 'OK', 'Information') | Out-Null
        $form.Close()
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '配置错误', 'OK', 'Warning') | Out-Null
    }
})

[void]$form.ShowDialog()
