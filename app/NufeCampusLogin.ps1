param(
    [switch]$Quiet,
    [switch]$ForceLogin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigPath = Join-Path $script:BaseDir 'config.json'
$script:CredentialPath = Join-Path $script:BaseDir 'credential.clixml'
$script:LogPath = Join-Path $script:BaseDir 'login.log'

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    if (-not $Quiet) {
        Write-Host $line
    }
}

function Load-Config {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        throw "Missing config file: $script:ConfigPath"
    }

    return Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-Config {
    param([psobject]$Config)

    $Config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
}

function Load-Credential {
    if (-not (Test-Path -LiteralPath $script:CredentialPath)) {
        throw "Missing credential file: $script:CredentialPath"
    }

    return Import-Clixml -LiteralPath $script:CredentialPath
}

function Get-PlainTextPassword {
    param([securestring]$SecurePassword)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Get-PropertySafely {
    param(
        [psobject]$Object,
        [string]$PropertyName,
        $DefaultValue = $null
    )

    if ($null -ne $Object -and $null -ne $Object.PSObject -and $Object.PSObject.Properties.Name -contains $PropertyName) {
        return $Object.$PropertyName
    }
    return $DefaultValue
}

function Get-ConnectedWifiSsid {
    param([string]$InterfaceName)

    try {
        $raw = & netsh.exe wlan show interfaces 2>&1
        $inTargetInterface = -not $InterfaceName
        $sawInterfaceName = $false

        foreach ($line in $raw) {
            if ($line -match '^\s*Name\s*:\s*(.+?)\s*$') {
                $sawInterfaceName = $true
                $inTargetInterface = (-not $InterfaceName) -or ($Matches[1].Trim() -eq $InterfaceName)
                continue
            }

            if ((-not $sawInterfaceName -or $inTargetInterface) -and
                $line -match '^\s*SSID\s*:\s*(.+?)\s*$' -and
                $line -notmatch '^\s*BSSID\s*:') {
                $ssid = $Matches[1].Trim()
                if ($ssid -and $ssid -ne 'N/A') {
                    return $ssid
                }
            }
        }
    }
    catch {
    }

    return ''
}

function Get-WifiSnapshotOnce {
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11' -or
            $_.Name -match '^WLAN$|Wi-?Fi|无线'
        } |
        Sort-Object ifIndex |
        Select-Object -First 1

    if (-not $adapter) {
        return $null
    }

    $profile = Get-NetConnectionProfile -InterfaceAlias $adapter.Name -ErrorAction SilentlyContinue
    $wifiSsid = Get-ConnectedWifiSsid -InterfaceName $adapter.Name
    $ipv4 = Get-NetIPAddress -InterfaceAlias $adapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -and $_.IPAddress -notmatch '^169\.254\.' } |
        Select-Object -First 1 -ExpandProperty IPAddress

    [pscustomobject]@{
        InterfaceName      = $adapter.Name
        State              = [string]$adapter.Status
        Ssid               = $wifiSsid
        NetworkProfileName = if ($profile) { [string]$profile.Name } else { '' }
        Mac                = (($adapter.MacAddress -replace '[:-]', '').ToLowerInvariant())
        IPv4               = $ipv4
    }
}

function Read-WifiContextOnce {
    $snapshot = Get-WifiSnapshotOnce
    if (-not $snapshot) {
        return $null
    }

    if ($snapshot.State -ne 'Up') {
        return $null
    }

    if (-not $snapshot.IPv4) {
        return $null
    }

    return $snapshot
}

function Get-WifiContext {
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $context = Read-WifiContextOnce
        if ($context) {
            return $context
        }

        if ($attempt -lt 5) {
            Start-Sleep -Seconds 2
        }
    }

    return $null
}

function Test-TargetWifiVisible {
    param([string]$Ssid)

    if (-not $Ssid) {
        return $false
    }

    try {
        $raw = & netsh.exe wlan show networks mode=bssid 2>&1
        foreach ($line in $raw) {
            if ($line -match '^\s*SSID\s+\d+\s*:\s*(.+?)\s*$' -and $Matches[1].Trim() -eq $Ssid) {
                return $true
            }
        }
    }
    catch {
        Write-Log -Level 'WARN' -Message ("Wi-Fi scan failed: {0}" -f $_.Exception.Message)
    }

    return $false
}

function Repair-LightNetwork {
    param([string]$InterfaceName)

    try {
        & ipconfig.exe /flushdns | Out-Null
        Write-Log -Message 'Flushed local DNS cache.'
    }
    catch {
        Write-Log -Level 'WARN' -Message ("DNS cache flush failed: {0}" -f $_.Exception.Message)
    }

    if ($InterfaceName) {
        try {
            $renewJob = Start-Job -ScriptBlock {
                param([string]$Name)
                & ipconfig.exe /renew $Name | Out-Null
            } -ArgumentList $InterfaceName

            try {
                if (-not (Wait-Job -Job $renewJob -Timeout 20)) {
                    Stop-Job -Job $renewJob -Force -ErrorAction SilentlyContinue
                    throw "DHCP renew timed out after 20 seconds."
                }

                Receive-Job -Job $renewJob | Out-Null
            }
            finally {
                Remove-Job -Job $renewJob -Force -ErrorAction SilentlyContinue
            }

            Write-Log -Message ("Requested DHCP renew for interface '{0}'." -f $InterfaceName)
        }
        catch {
            Write-Log -Level 'WARN' -Message ("DHCP renew failed: {0}" -f $_.Exception.Message)
        }
    }
}

function Connect-TargetWifi {
    param([psobject]$Config)

    $profileName = if ($Config.PSObject.Properties.Name -contains 'profileName' -and $Config.profileName) {
        [string]$Config.profileName
    }
    else {
        [string]$Config.ssid
    }

    $snapshot = Get-WifiSnapshotOnce
    $interfaceName = if ($snapshot) { $snapshot.InterfaceName } else { '' }
    Write-Log -Message ("Attempting to connect to Wi-Fi profile '{0}'." -f $profileName)

    if ($interfaceName) {
        $connectOutput = & netsh.exe wlan connect name="$profileName" interface="$interfaceName" 2>&1 | Out-String
    }
    else {
        $connectOutput = & netsh.exe wlan connect name="$profileName" 2>&1 | Out-String
    }

    $connectOutput = $connectOutput.Trim()
    if ($connectOutput) {
        Write-Log -Message $connectOutput
    }

    Write-Log -Message ("Waiting for Wi-Fi context on '{0}'." -f $Config.ssid)

    for ($attempt = 1; $attempt -le 20; $attempt++) {
        Start-Sleep -Seconds 2
        $context = Read-WifiContextOnce
        if ($context -and $context.Ssid -eq $Config.ssid) {
            return $context
        }
    }

    $latest = Get-WifiSnapshotOnce
    if ($latest) {
        Write-Log -Level 'WARN' -Message ("Wi-Fi did not become ready as '{0}' after waiting. Latest state: '{1}', SSID: '{2}', network profile: '{3}', IPv4: '{4}'." -f $Config.ssid, $latest.State, $latest.Ssid, $latest.NetworkProfileName, $latest.IPv4)
    }

    Repair-LightNetwork -InterfaceName $interfaceName
    return Get-WifiContext
}

function Invoke-DirectJsonp {
    param(
        [string]$Url,
        [string]$InterfaceIp
    )

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        $args = @(
            '--noproxy', '*',
            '--silent',
            '--show-error',
            '--max-time', '20'
        )

        if ($InterfaceIp) {
            $args += @('--interface', $InterfaceIp)
        }

        $args += $Url
        $raw = & curl.exe @args 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "curl failed: $($raw | Out-String)"
        }
        $text = ($raw | Out-String).Trim()
    }
    else {
        $client = New-Object System.Net.WebClient
        $client.Proxy = $null
        $client.Encoding = [Text.Encoding]::UTF8
        $text = $client.DownloadString($Url).Trim()
    }

    if ($text -match '^[^(]+\((.*)\)\s*$') {
        $text = $Matches[1]
    }

    if ($text -notmatch '^\s*[\{\[]') {
        $preview = if ($text.Length -gt 200) { $text.Substring(0, 200) } else { $text }
        throw "Unexpected response: $preview"
    }

    return $text | ConvertFrom-Json
}

function Build-QueryString {
    param([hashtable]$Parameters)

    return ($Parameters.GetEnumerator() | ForEach-Object {
            '{0}={1}' -f [uri]::EscapeDataString([string]$_.Key), [uri]::EscapeDataString([string]$_.Value)
        }) -join '&'
}

function Get-DrcomStatus {
    param(
        [psobject]$Context,
        [psobject]$Config
    )

    $callback = 'cb{0}' -f [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    $url = 'http://{0}/drcom/chkstatus?callback={1}' -f $Config.portalHost, $callback
    return Invoke-DirectJsonp -Url $url -InterfaceIp $Context.IPv4
}

function Update-ConfigFromStatus {
    param(
        [psobject]$Config,
        [psobject]$Status
    )

    $uid = Get-PropertySafely -Object $Status -PropertyName 'uid'
    $ac = Get-PropertySafely -Object $Status -PropertyName 'AC'
    $account = @($uid, $ac) | Where-Object { $_ } | Select-Object -First 1
    if ($account -and $account -match '(@[^@]+)$') {
        $Config.lastKnownAccount = $account
        $Config.lastKnownSuffix = $Matches[1]
        $Config.lastSeenAt = (Get-Date).ToString('s')
        Save-Config -Config $Config
    }
}

function Get-LoginSuffix {
    param([psobject]$Config)

    if ($Config.preferLastKnownSuffix -and $Config.lastKnownSuffix) {
        return [string]$Config.lastKnownSuffix
    }

    return [string]$Config.preferredSuffix
}

function Build-LoginAccount {
    param(
        [pscredential]$Credential,
        [psobject]$Config
    )

    if ($Credential.UserName -match '@') {
        return $Credential.UserName
    }

    return '{0}{1}' -f $Credential.UserName, (Get-LoginSuffix -Config $Config)
}

function Invoke-PortalLogin {
    param(
        [psobject]$Context,
        [psobject]$Config,
        [pscredential]$Credential
    )

    $callback = 'cb{0}' -f [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    $account = Build-LoginAccount -Credential $Credential -Config $Config
    $plainPassword = Get-PlainTextPassword -SecurePassword $Credential.Password

    $query = Build-QueryString -Parameters @{
        callback       = $callback
        login_method   = [string]$Config.loginMethod
        user_account   = $account
        user_password  = $plainPassword
        wlan_user_ip   = $Context.IPv4
        wlan_user_ipv6 = ''
        wlan_user_mac  = $Context.Mac
        wlan_ac_ip     = ''
        wlan_ac_name   = ''
        jsVersion      = [string]$Config.jsVersion
    }

    $url = 'http://{0}:801/eportal/?c=Portal&a=login&{1}' -f $Config.eportalHost, $query
    $result = Invoke-DirectJsonp -Url $url -InterfaceIp $Context.IPv4

    [pscustomobject]@{
        Account = $account
        Result  = $result
    }
}

function Test-IsOnlineResult {
    param([psobject]$Status)

    $result = Get-PropertySafely -Object $Status -PropertyName 'result'
    return ($null -ne $result) -and (([string]$result -eq '1') -or ([string]$result -eq 'ok'))
}

try {
    $config = Load-Config
    $snapshot = Get-WifiSnapshotOnce

    if (-not $snapshot) {
        Write-Log -Message 'No Wi-Fi adapter was detected for this run.'
        exit 0
    }

    if ($snapshot.State -eq 'Up' -and $snapshot.Ssid -and $snapshot.Ssid -ne $config.ssid -and -not $ForceLogin) {
        Write-Log -Message ("Connected to '{0}', not '{1}'. Background monitor will not switch Wi-Fi." -f $snapshot.Ssid, $config.ssid)
        exit 0
    }

    $context = Get-WifiContext
    if (-not $context) {
        if (Test-TargetWifiVisible -Ssid $config.ssid) {
            Write-Log -Message ("Current Wi-Fi state is '{0}' on SSID '{1}'. Trying to connect to '{2}' first." -f $snapshot.State, $snapshot.Ssid, $config.ssid)
            $context = Connect-TargetWifi -Config $config
        }
        else {
            Write-Log -Message ("Target SSID '{0}' is not visible. Skipping this run." -f $config.ssid)
            exit 0
        }
    }

    if (-not $context) {
        Write-Log -Message ("Could not get a connected '{0}' Wi-Fi context in this run." -f $config.ssid)
        exit 0
    }

    if ($context.Ssid -ne $config.ssid) {
        if (-not $ForceLogin) {
            Write-Log -Message ("Connected to '{0}', not '{1}'. Background monitor will not switch Wi-Fi." -f $context.Ssid, $config.ssid)
            exit 0
        }

        if (-not (Test-TargetWifiVisible -Ssid $config.ssid)) {
            Write-Log -Message ("Target SSID '{0}' is not visible. Cannot switch Wi-Fi." -f $config.ssid)
            exit 0
        }

        Write-Log -Message ("Manual run requested. Switching from '{0}' to '{1}'." -f $context.Ssid, $config.ssid)
        $context = Connect-TargetWifi -Config $config
    }

    if (-not $context -or $context.Ssid -ne $config.ssid) {
        Write-Log -Message ("Could not switch to '{0}' in this run." -f $config.ssid)
        exit 0
    }

    $status = $null
    try {
        $status = Get-DrcomStatus -Context $context -Config $config
    }
    catch {
        Write-Log -Level 'WARN' -Message ("Status check failed: {0}" -f $_.Exception.Message)
        Repair-LightNetwork -InterfaceName $context.InterfaceName
    }

    if ((-not $ForceLogin) -and (Test-IsOnlineResult -Status $status)) {
        Update-ConfigFromStatus -Config $config -Status $status
        $uid = Get-PropertySafely -Object $status -PropertyName 'uid'
        $ac = Get-PropertySafely -Object $status -PropertyName 'AC'
        $account = @($uid, $ac) | Where-Object { $_ } | Select-Object -First 1
        Write-Log -Message ("Already online on '{0}' as '{1}'." -f $context.Ssid, $account)
        exit 0
    }

    $credential = Load-Credential
    $loginAttempt = Invoke-PortalLogin -Context $context -Config $config -Credential $credential
    $loginResult = $loginAttempt.Result

    $resVal = Get-PropertySafely -Object $loginResult -PropertyName 'result'
    if (([string]$resVal -ne '1') -and ([string]$resVal -ne 'ok')) {
        $msgVal = Get-PropertySafely -Object $loginResult -PropertyName 'msg'
        $messageVal = Get-PropertySafely -Object $loginResult -PropertyName 'message'
        $message = @($msgVal, $messageVal) | Where-Object { $_ } | Select-Object -First 1
        if (-not $message) {
            $message = 'Unknown login failure'
        }
        throw "Portal login failed for '$($loginAttempt.Account)': $message"
    }

    Start-Sleep -Seconds 1
    $statusAfter = Get-DrcomStatus -Context $context -Config $config
    if (Test-IsOnlineResult -Status $statusAfter) {
        Update-ConfigFromStatus -Config $config -Status $statusAfter
        $uidAfter = Get-PropertySafely -Object $statusAfter -PropertyName 'uid'
        $acAfter = Get-PropertySafely -Object $statusAfter -PropertyName 'AC'
        $account = @($uidAfter, $acAfter) | Where-Object { $_ } | Select-Object -First 1
        Write-Log -Message ("Portal login succeeded on '{0}' as '{1}'." -f $context.Ssid, $account)
        exit 0
    }

    Write-Log -Level 'WARN' -Message 'Portal login reported success, but the follow-up status check was inconclusive.'
    exit 0
}
catch {
    $errMessage = if ($_.Exception) { $_.Exception.Message } else { $_.ToString() }
    Write-Log -Level 'ERROR' -Message $errMessage
    exit 1
}
