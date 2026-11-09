@echo off
rem DNS tray toggle with settings window. Double-click to run (asks for admin rights once).
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "$s=[IO.File]::ReadAllText('%~f0'); iex ($s.Substring($s.IndexOf('#PS'+'START')))"
exit /b
#PSSTART
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$m = New-Object System.Threading.Mutex($false, 'Global\DnsTrayToggle')
if (-not $m.WaitOne(0)) { exit }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# How it works: the selected SmartDNS is asked (over DoH, or UDP as fallback) for the AI domains,
# and its answers (SNI-proxy IPs) are written to the hosts file. System DNS is not touched,
# so the rest of the internet, WARP and any VPN keep working as before.

# ---------- config ----------
$cfgDir     = Join-Path $env:APPDATA 'DnsTray'
$cfgFile    = Join-Path $cfgDir 'config.json'
$CfgVersion = 3
$hostsFile  = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$markBegin  = '# >>> DnsTray (AI geoblock bypass) >>>'
$markEnd    = '# <<< DnsTray <<<'
$oldBuiltin = @('w.quic.best', 'DNS AI', 'Comss.one', 'GeoHide', 'NOT-A-DNS')
$oldIps     = @('2.26.124.29', '194.238.57.69', '192.144.59.14', '186.246.49.127', '83.220.169.155', '212.109.195.93', '159.194.200.33', '37.230.192.51')

$DefaultDomains = @(
    'gemini.google.com', 'gemini.google', 'bard.google.com',
    'generativelanguage.googleapis.com', 'cloudcode-pa.googleapis.com',
    'aistudio.google.com', 'makersuite.google.com', 'ai.google.dev',
    'alkalimakersuite-pa.clients6.google.com', 'alkalicore-pa.clients6.google.com',
    'webchannel-alkalimakersuite-pa.clients6.google.com', 'waa-pa.clients6.google.com',
    'proactivebackend-pa.googleapis.com', 'robinfrontend-pa.googleapis.com',
    'assistant-s3-pa.googleapis.com', 'geller-pa.googleapis.com',
    'notebooklm.google.com', 'notebooklm.google', 'labs.google', 'aitestkitchen.withgoogle.com'
)

function New-Preset($name, $ipv4, $doh) {
    [pscustomobject]@{ name = [string]$name; ipv4 = [string]$ipv4; doh = [string]$doh }
}

function Get-BuiltinPresets {
    @(
        (New-Preset 'Wlrus'       '95.85.240.254, 138.124.254.134' 'https://dns.wlrus.cfd/dns-query'),
        (New-Preset 'GeoHide US'  '37.230.192.51, 46.8.158.6'      'https://us.geohide.ru/dns-query'),
        (New-Preset 'Dagami'      '185.149.145.6'                  'https://dns.dagami.ru/dns-query'),
        (New-Preset 'w.quic.best' '194.238.57.69'                  'https://w.quic.best/dns-query'),
        (New-Preset 'GeoHide EU'  '45.155.204.190'                 'https://eu.geohide.ru/dns-query'),
        (New-Preset 'Bezmezhau'   '143.20.64.55, 31.58.216.201'    'https://dns.bezmezhau.com/dns-query'),
        (New-Preset 'DNS AI'      '192.144.59.14, 186.246.49.127'  '')
    )
}

function New-State { [pscustomobject]@{ on = $false; preset = ''; updated = '' } }

function Ensure-Prop($o, $n, $v) {
    if (-not ($o.PSObject.Properties.Name -contains $n)) { $o | Add-Member -NotePropertyName $n -NotePropertyValue $v }
}

function Split-List($t) { @(([string]$t) -split '[,;\s]+' | Where-Object { $_ }) }

function Load-Config {
    $c = $null
    if (Test-Path $cfgFile) { try { $c = Get-Content $cfgFile -Raw | ConvertFrom-Json } catch { $c = $null } }
    if (-not $c) { $c = [pscustomobject]@{ version = 0; active = ''; presets = @() } }
    foreach ($kv in @(@('version', 0), @('active', ''), @('presets', @()), @('domains', $DefaultDomains), @('state', $null))) { Ensure-Prop $c $kv[0] $kv[1] }
    $global:legacyState = $null
    $global:migrated = $false
    if ([int]$c.version -lt $CfgVersion) {
        $global:migrated = $true
        if ($c.state -and $c.state.on) { $global:legacyState = $c.state }
        $keep = @()
        foreach ($p in @($c.presets)) {
            if (-not $p -or -not $p.name -or ($oldBuiltin -contains $p.name)) { continue }
            $ip = (@($p.primary, $p.secondary) | Where-Object { $_ }) -join ', '
            $keep += (New-Preset $p.name $ip $p.doh)
        }
        $c.presets = @(Get-BuiltinPresets) + $keep
        $c.active  = 'Wlrus'
        $c.domains = $DefaultDomains
        $c.version = $CfgVersion
        $c.state   = $null
    } else {
        $c.presets = @(@($c.presets) | Where-Object { $_ -and $_.name } | ForEach-Object { New-Preset $_.name $_.ipv4 $_.doh })
        if (@($c.presets).Count -eq 0) { $c.presets = @(Get-BuiltinPresets) }
    }
    $c.domains = @(@($c.domains) | ForEach-Object { ([string]$_).Trim().ToLower() } | Where-Object { $_ })
    if (-not $c.state) { $c.state = New-State }
    return $c
}

function Save-Config {
    if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir | Out-Null }
    $global:cfg | ConvertTo-Json -Depth 6 | Set-Content -Path $cfgFile -Encoding UTF8
}

# Undo system-DNS changes made by previous versions of this script.
function Undo-LegacyDns($st) {
    $root = 'SYSTEM\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters'
    $idx = @()
    if ($st) { $idx += @($st.adapters) }
    foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
        $srv = @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
        if (@($srv | Where-Object { $oldIps -contains $_ }).Count -gt 0) { $idx += $a.ifIndex }
    }
    foreach ($i in ($idx | Where-Object { $_ } | Select-Object -Unique)) {
        $a = Get-NetAdapter -InterfaceIndex $i -ErrorAction SilentlyContinue
        if (-not $a) { continue }
        try { Set-DnsClientServerAddress -InterfaceIndex $i -ResetServerAddresses -ErrorAction Stop } catch {}
        if ($st) {
            foreach ($ip in @($st.doh)) {
                foreach ($fam in 'Doh', 'Doh6') {
                    try { [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKeyTree("$root\$($a.InterfaceGuid)\DohInterfaceSettings\$fam\$ip", $false) } catch {}
                }
            }
        }
    }
    if ($st) {
        foreach ($n in @($st.ipv6Off)) { try { Enable-NetAdapterBinding -Name $n -ComponentID ms_tcpip6 -ErrorAction Stop } catch {} }
        foreach ($ip in @($st.added)) { try { Remove-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction Stop } catch {} }
    }
    try { Clear-DnsClientCache } catch {}
}

$global:cfg = Load-Config
if ($global:migrated) { Undo-LegacyDns $global:legacyState }
Save-Config

function Get-Active {
    $p = $global:cfg.presets | Where-Object { $_.name -eq $global:cfg.active } | Select-Object -First 1
    if (-not $p) { $p = @($global:cfg.presets)[0]; $global:cfg.active = $p.name }
    return $p
}

function Test-Ipv4($t) {
    $ip = $null
    return ($t -match '^\d{1,3}(\.\d{1,3}){3}$') -and [System.Net.IPAddress]::TryParse($t, [ref]$ip)
}

# ---------- DNS wire format / DoH ----------
function New-DnsQuery($name) {
    $ms = New-Object System.IO.MemoryStream
    $hdr = [byte[]](0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0)
    $ms.Write($hdr, 0, 12)
    foreach ($l in $name.TrimEnd('.').Split('.')) {
        $b = [System.Text.Encoding]::ASCII.GetBytes($l)
        $ms.WriteByte($b.Length); $ms.Write($b, 0, $b.Length)
    }
    $ms.WriteByte(0)
    $tail = [byte[]](0, 1, 0, 1)
    $ms.Write($tail, 0, 4)
    return , $ms.ToArray()
}

function Skip-Name([byte[]]$r, [int]$i) {
    while ($true) {
        $l = $r[$i]
        if ($l -eq 0) { return $i + 1 }
        if (($l -band 0xC0) -eq 0xC0) { return $i + 2 }
        $i += $l + 1
    }
}

function Read-DnsAnswer([byte[]]$r) {
    $qd = $r[4] * 256 + $r[5]; $an = $r[6] * 256 + $r[7]; $i = 12
    for ($k = 0; $k -lt $qd; $k++) { $i = (Skip-Name $r $i) + 4 }
    $out = @()
    for ($k = 0; $k -lt $an; $k++) {
        $i = Skip-Name $r $i
        $t = $r[$i] * 256 + $r[$i + 1]; $len = $r[$i + 8] * 256 + $r[$i + 9]; $i += 10
        if ($t -eq 1 -and $len -eq 4) { $out += ('{0}.{1}.{2}.{3}' -f $r[$i], $r[$i + 1], $r[$i + 2], $r[$i + 3]) }
        $i += $len
    }
    return , $out
}

function Invoke-Doh($url, $name) {
    $body = New-DnsQuery $name
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method = 'POST'; $req.ContentType = 'application/dns-message'; $req.Accept = 'application/dns-message'
    $req.UserAgent = 'DnsTray'; $req.Timeout = 6000; $req.ReadWriteTimeout = 6000
    $req.ContentLength = $body.Length
    $s = $req.GetRequestStream(); $s.Write($body, 0, $body.Length); $s.Close()
    $resp = $req.GetResponse()
    try {
        $ms = New-Object System.IO.MemoryStream
        $resp.GetResponseStream().CopyTo($ms)
        return , (Read-DnsAnswer $ms.ToArray())
    } finally { $resp.Close() }
}

function Invoke-Udp($server, $name) {
    return , @(Resolve-DnsName -Name $name -Type A -Server $server -DnsOnly -QuickTimeout -ErrorAction Stop |
        Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress })
}

function Clean-Ips($ips) { @($ips | Where-Object { $_ -and $_ -ne '0.0.0.0' -and $_ -notlike '127.*' } | Select-Object -Unique) }

# Ask the preset's resolver directly: DoH first, then plain UDP to each IPv4.
function Resolve-Preset($p, $name) {
    if ($p.doh) {
        try { return [pscustomobject]@{ ips = (Clean-Ips (Invoke-Doh $p.doh $name)); via = 'DoH' } } catch {}
    }
    foreach ($srv in (Split-List $p.ipv4)) {
        try { return [pscustomobject]@{ ips = (Clean-Ips (Invoke-Udp $srv $name)); via = "UDP $srv" } } catch {}
    }
    throw 'DNS не отвечает'
}

# ---------- checks ----------
$googleNets = '142.250.0.0/15', '172.217.0.0/16', '172.253.0.0/16', '173.194.0.0/16', '74.125.0.0/16', '64.233.160.0/19',
    '66.102.0.0/20', '66.249.64.0/19', '108.177.0.0/17', '209.85.128.0/17', '216.58.192.0/19', '216.239.32.0/19', '192.178.0.0/15'

function ConvertTo-UInt($ip) { $b = [System.Net.IPAddress]::Parse($ip).GetAddressBytes(); [Array]::Reverse($b); [BitConverter]::ToUInt32($b, 0) }

function Test-GoogleIp($ip) {
    $a = ConvertTo-UInt $ip
    foreach ($n in $googleNets) {
        $p = $n.Split('/'); $bits = [int]$p[1]
        $mask = [uint32](([uint64]4294967295 -shl (32 - $bits)) -band [uint64]4294967295)
        if (($a -band $mask) -eq ((ConvertTo-UInt $p[0]) -band $mask)) { return $true }
    }
    return $false
}

function Test-Tcp($ip, $port, $ms) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($ip, $port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($ms) -and $c.Connected) { $c.EndConnect($ar); return $true }
        return $false
    } catch { return $false } finally { $c.Close() }
}

function Test-Preset($p) {
    $r = [pscustomobject]@{ ok = $false; msg = '' }
    try { $x = Resolve-Preset $p 'gemini.google.com' } catch { $r.msg = 'DNS не отвечает'; return $r }
    if (@($x.ips).Count -eq 0) { $r.msg = "пустой ответ ($($x.via))"; return $r }
    $ip = @($x.ips)[0]
    if (Test-GoogleIp $ip) { $r.msg = "не подменяет Gemini, отдаёт реальный IP Google ($($x.via))"; return $r }
    if (-not (Test-Tcp $ip 443 4000)) { $r.msg = "прокси $ip недоступен ($($x.via))"; return $r }
    $r.ok = $true; $r.msg = "прокси $ip, $($x.via)"
    return $r
}

# ---------- hosts ----------
function Read-Hosts { if (Test-Path $hostsFile) { @(Get-Content $hostsFile -Encoding Default) } else { @() } }

function Write-HostsBlock($entries) {
    $out = @(); $skip = $false
    foreach ($l in Read-Hosts) {
        if ($l -eq $markBegin) { $skip = $true; continue }
        if ($l -eq $markEnd) { $skip = $false; continue }
        if (-not $skip) { $out += $l }
    }
    $n = $out.Count
    while ($n -gt 0 -and $out[$n - 1] -eq '') { $n-- }
    if ($n -gt 0) { $out = @($out[0..($n - 1)]) } else { $out = @() }
    if (@($entries).Count -gt 0) { $out += ''; $out += $markBegin; $out += @($entries); $out += $markEnd }
    $fi = Get-Item $hostsFile -ErrorAction SilentlyContinue
    if ($fi -and $fi.IsReadOnly) { $fi.IsReadOnly = $false }
    [System.IO.File]::WriteAllLines($hostsFile, [string[]]$out, [System.Text.Encoding]::Default)
    Clear-DnsClientCache
}

function Test-On { [bool]$global:cfg.state.on -and ((Read-Hosts) -contains $markBegin) }

# Checks the preset and, if it works, writes its answers for all domains to hosts.
function Enable-Bypass($p) {
    Set-TrayState 'yellow' "Проверка: $($p.name)"
    $t = Test-Preset $p
    if (-not $t.ok) { return $t }
    $entries = @()
    foreach ($d in $global:cfg.domains) {
        [System.Windows.Forms.Application]::DoEvents()
        try { foreach ($ip in (@((Resolve-Preset $p $d).ips) | Select-Object -First 2)) { $entries += "$ip`t$d" } } catch {}
    }
    if ($entries.Count -eq 0) { $t.ok = $false; $t.msg = 'не удалось получить адреса'; return $t }
    Write-HostsBlock $entries
    $global:cfg.active = $p.name
    $global:cfg.state = [pscustomobject]@{ on = $true; preset = $p.name; updated = (Get-Date).ToString('s') }
    Save-Config
    return $t
}

function Disable-Bypass {
    Write-HostsBlock @()
    $global:cfg.state = New-State
    Save-Config
}

# ---------- tray ----------
function New-Icon($color) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $color), 3, 3, 26, 26)
    $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$icons = @{
    green  = New-Icon ([System.Drawing.Color]::LimeGreen)
    yellow = New-Icon ([System.Drawing.Color]::Gold)
    red    = New-Icon ([System.Drawing.Color]::Red)
}

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Visible = $true

function Set-TrayState($color, $text) {
    $tray.Icon = $icons[$color]
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
    $tray.Text = $text
    [System.Windows.Forms.Application]::DoEvents()
}

function Update-Tray {
    if (Test-On) { Set-TrayState 'green' "AI-обход ВКЛ: $($global:cfg.state.preset)" }
    else         { Set-TrayState 'red'   "AI-обход ВЫКЛ ($((Get-Active).name))" }
}

function Notify($text, $icon) {
    if (-not $icon) { $icon = 'Info' }
    $tray.ShowBalloonTip(6000, 'AI-обход DNS', $text, $icon)
}

# Try the given preset first, then all others in order.
function Connect-Best($first, [bool]$quiet) {
    $order = @($first) + @($global:cfg.presets | Where-Object { $_.name -ne $first.name })
    $fails = @()
    foreach ($p in $order) {
        $r = $null
        try { $r = Enable-Bypass $p } catch { $r = [pscustomobject]@{ ok = $false; msg = $_.Exception.Message } }
        if ($r.ok) {
            Update-Tray
            if (-not $quiet -or $p.name -ne $first.name) {
                $extra = if ($p.name -ne $first.name) { "$($first.name) не работает, выбран другой профиль. " } else { '' }
                Notify "$($extra)Включено: $($p.name) ($($r.msg)). Если Gemini был открыт — перезапустите браузер."
            }
            return $true
        }
        $fails += "$($p.name): $($r.msg)"
    }
    Update-Tray
    Notify ("Ни один профиль не сработал. Подробности: «Проверить профили». " + ((@($fails) | Select-Object -First 2) -join '; ')) 'Warning'
    return $false
}

function Connect-Only($p) {
    $r = $null
    try { $r = Enable-Bypass $p } catch { $r = [pscustomobject]@{ ok = $false; msg = $_.Exception.Message } }
    Update-Tray
    if ($r.ok) { Notify "Включено: $($p.name) ($($r.msg)). Если Gemini был открыт — перезапустите браузер." }
    else { Notify "$($p.name) не работает: $($r.msg)." 'Warning' }
    return $r.ok
}

function Toggle-Bypass {
    if (Test-On) { Disable-Bypass; Update-Tray; Notify 'AI-обход выключен, записи удалены из hosts.' }
    else { [void](Connect-Best (Get-Active) $false) }
}

function Select-Preset($n) {
    $p = $global:cfg.presets | Where-Object { $_.name -eq $n } | Select-Object -First 1
    if ($p) { [void](Connect-Only $p) }
}

function Show-Check {
    Set-TrayState 'yellow' 'Проверка профилей...'
    $lines = @()
    foreach ($p in $global:cfg.presets) {
        [System.Windows.Forms.Application]::DoEvents()
        $r = Test-Preset $p
        $lines += $(if ($r.ok) { '[OK]   ' } else { '[--]   ' }) + "$($p.name): $($r.msg)"
    }
    $lines += ''
    $lines += 'Сейчас: ' + $(if (Test-On) { "ВКЛ, профиль $($global:cfg.state.preset), обновлено $($global:cfg.state.updated)" } else { 'ВЫКЛ' })
    try { $sys = ([System.Net.Dns]::GetHostAddresses('gemini.google.com') | ForEach-Object { $_.IPAddressToString }) -join ', ' } catch { $sys = 'ошибка' }
    $lines += "gemini.google.com в системе -> $sys"
    Update-Tray
    [void][System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n"), 'Проверка профилей')
}

# ---------- settings window ----------
function New-Ctl($type, $x, $y, $w, $text) {
    $c = New-Object $type
    $c.Location = New-Object System.Drawing.Point($x, $y)
    if ($w) { $c.Width = $w }
    if ($text) { $c.Text = $text }
    return $c
}

function Show-Settings {
    if ($global:sf -and -not $global:sf.IsDisposed) { $global:sf.Activate(); return }

    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Настройки AI-обхода'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.StartPosition = 'CenterScreen'
    $f.ClientSize = New-Object System.Drawing.Size(440, 470)
    $f.TopMost = $true
    $global:sf = $f

    $L = 'System.Windows.Forms.Label'
    $f.Controls.Add((New-Ctl $L 15 18  120 'Профиль:'))
    $f.Controls.Add((New-Ctl $L 15 53  120 'Название:'))
    $f.Controls.Add((New-Ctl $L 15 88  120 'IPv4 (через ,):'))
    $f.Controls.Add((New-Ctl $L 15 123 120 'DoH URL:'))
    $lblD = New-Ctl $L 15 155 410 'Домены для обхода (по одному в строке, общие для всех профилей):'
    $lblD.AutoSize = $true
    $f.Controls.Add($lblD)

    $cmb = New-Ctl 'System.Windows.Forms.ComboBox' 140 15 285 $null
    $cmb.DropDownStyle = 'DropDownList'
    $txtName = New-Ctl 'System.Windows.Forms.TextBox' 140 50  285 $null
    $txtIp   = New-Ctl 'System.Windows.Forms.TextBox' 140 85  285 $null
    $txtD    = New-Ctl 'System.Windows.Forms.TextBox' 140 120 285 $null
    $txtDom  = New-Ctl 'System.Windows.Forms.TextBox' 15  175 410 $null
    $txtDom.Multiline = $true; $txtDom.ScrollBars = 'Vertical'; $txtDom.Height = 200
    $txtDom.Text = ($global:cfg.domains -join "`r`n")
    $bSave   = New-Ctl 'System.Windows.Forms.Button' 15  390 95 'Сохранить'
    $bTest   = New-Ctl 'System.Windows.Forms.Button' 120 390 95 'Проверить'
    $bDel    = New-Ctl 'System.Windows.Forms.Button' 225 390 95 'Удалить'
    $bClose  = New-Ctl 'System.Windows.Forms.Button' 330 390 95 'Закрыть'
    $bApply  = New-Ctl 'System.Windows.Forms.Button' 15  425 410 'Применить и включить'
    foreach ($c in @($cmb, $txtName, $txtIp, $txtD, $txtDom, $bSave, $bTest, $bDel, $bClose, $bApply)) { $f.Controls.Add($c) }

    $refresh = {
        param($sel)
        $cmb.Items.Clear()
        foreach ($p in $global:cfg.presets) { [void]$cmb.Items.Add($p.name) }
        $cmb.SelectedItem = $sel
    }.GetNewClosure()

    $readInput = {
        $n = $txtName.Text.Trim(); $ips = @(Split-List $txtIp.Text); $d = $txtD.Text.Trim()
        $doms = @($txtDom.Text -split "[\r\n,\s]+" | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
        $err = $null
        if (-not $n) { $err = 'Введите название.' }
        elseif (@($ips | Where-Object { -not (Test-Ipv4 $_) }).Count -gt 0) { $err = 'IPv4: укажите адреса через запятую.' }
        elseif ($d -and $d -notmatch '^https://[^/\s]+/\S*$') { $err = 'DoH URL должен начинаться с https://' }
        elseif (-not $d -and $ips.Count -eq 0) { $err = 'Укажите DoH URL или хотя бы один IPv4.' }
        elseif ($doms.Count -eq 0) { $err = 'Список доменов пуст.' }
        elseif (@($doms | Where-Object { $_ -notmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' }).Count -gt 0) { $err = 'В списке доменов есть некорректная строка.' }
        if ($err) { [void][System.Windows.Forms.MessageBox]::Show($f, $err, 'Настройки'); return $null }
        $global:cfg.domains = $doms
        return (New-Preset $n ($ips -join ', ') $d)
    }.GetNewClosure()

    $upsert = {
        param($preset)
        $found = $false; $new = @()
        foreach ($x in $global:cfg.presets) {
            if ($x.name -eq $preset.name) { $new += $preset; $found = $true } else { $new += $x }
        }
        if (-not $found) { $new += $preset }
        $global:cfg.presets = $new
    }.GetNewClosure()

    $cmb.add_SelectedIndexChanged({
        $p = $global:cfg.presets | Where-Object { $_.name -eq $cmb.SelectedItem } | Select-Object -First 1
        if ($p) { $txtName.Text = $p.name; $txtIp.Text = $p.ipv4; $txtD.Text = $p.doh }
    }.GetNewClosure())

    $bSave.add_Click({
        $p = & $readInput
        if (-not $p) { return }
        & $upsert $p
        Save-Config
        if ((Test-On) -and $global:cfg.state.preset -eq $p.name) { [void](Connect-Only $p) }
        & $refresh $p.name
    }.GetNewClosure())

    $bTest.add_Click({
        $p = & $readInput
        if (-not $p) { return }
        $f.UseWaitCursor = $true
        $r = Test-Preset $p
        $f.UseWaitCursor = $false
        $msg = if ($r.ok) { "Работает: $($r.msg)" } else { "Не работает: $($r.msg)" }
        [void][System.Windows.Forms.MessageBox]::Show($f, $msg, $p.name)
    }.GetNewClosure())

    $bApply.add_Click({
        $p = & $readInput
        if (-not $p) { return }
        & $upsert $p
        Save-Config
        [void](Connect-Only $p)
        & $refresh $p.name
    }.GetNewClosure())

    $bDel.add_Click({
        $n = $cmb.SelectedItem
        if (-not $n) { return }
        if (@($global:cfg.presets).Count -le 1) {
            [void][System.Windows.Forms.MessageBox]::Show($f, 'Нельзя удалить последний профиль.', 'Настройки')
            return
        }
        if ((Test-On) -and $global:cfg.state.preset -eq $n) { Disable-Bypass }
        $global:cfg.presets = @($global:cfg.presets | Where-Object { $_.name -ne $n })
        if ($global:cfg.active -eq $n) { $global:cfg.active = @($global:cfg.presets)[0].name }
        Save-Config
        Update-Tray
        & $refresh $global:cfg.active
    }.GetNewClosure())

    $bClose.add_Click({ $f.Close() }.GetNewClosure())
    $f.add_FormClosed({ $global:sf = $null })

    & $refresh $global:cfg.active
    $f.Show()
}

# ---------- menu ----------
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$null = $menu.Items.Add('Вкл / выкл', $null, { Toggle-Bypass })
$null = $menu.Items.Add('Подобрать рабочий профиль', $null, { [void](Connect-Best (@($global:cfg.presets)[0]) $false) })
$global:presetMenu = New-Object System.Windows.Forms.ToolStripMenuItem 'Профиль'
$null = $menu.Items.Add($global:presetMenu)
$null = $menu.Items.Add('Проверить профили', $null, { Show-Check })
$null = $menu.Items.Add('Настройки...', $null, { Show-Settings })
$null = $menu.Items.Add('Выход (обход остаётся как есть)', $null, { $tray.Visible = $false; [System.Windows.Forms.Application]::Exit() })

function Build-PresetMenu {
    $global:presetMenu.DropDownItems.Clear()
    $cur = if (Test-On) { $global:cfg.state.preset } else { $global:cfg.active }
    foreach ($p in $global:cfg.presets) {
        $it = New-Object System.Windows.Forms.ToolStripMenuItem $p.name
        $it.Checked = ($p.name -eq $cur)
        $it.add_Click({ Select-Preset $this.Text })
        [void]$global:presetMenu.DropDownItems.Add($it)
    }
}
$menu.add_Opening({ Build-PresetMenu })

$tray.ContextMenuStrip = $menu
$tray.add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Toggle-Bypass } })

# Refresh proxy IPs every 30 minutes while enabled (and once shortly after start).
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.add_Tick({
    $timer.Interval = 30 * 60 * 1000
    if (Test-On) {
        $p = $global:cfg.presets | Where-Object { $_.name -eq $global:cfg.state.preset } | Select-Object -First 1
        if (-not $p) { $p = Get-Active }
        [void](Connect-Best $p $true)
    }
})
$timer.Start()

Update-Tray
if ($global:migrated) { Notify 'Новая версия: обход работает через файл hosts и не меняет системный DNS (совместимо с WARP). Нажмите на значок, чтобы включить.' }
[System.Windows.Forms.Application]::Run()
