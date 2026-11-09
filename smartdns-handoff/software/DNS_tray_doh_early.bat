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

# ---------- config ----------
$cfgDir  = Join-Path $env:APPDATA 'DnsTray'
$cfgFile = Join-Path $cfgDir 'config.json'
$CfgVersion = 2
$global:dohSupported = [bool](Get-Command Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue)
$dohRoot = 'SYSTEM\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters'

function New-Preset($name, $p1, $p2, $doh, $v6) {
    [pscustomobject]@{ name = [string]$name; primary = [string]$p1; secondary = [string]$p2; ipv6 = [string]$v6; doh = [string]$doh }
}

function Get-BuiltinPresets {
    @(
        (New-Preset 'w.quic.best' '194.238.57.69'  ''               'https://w.quic.best/dns-query'    ''),
        (New-Preset 'DNS AI'      '192.144.59.14'  '186.246.49.127' 'https://dns.dns-ai.ru/dns-query'  '2a0d:8480:0:67c::14, 2a0a:2b41:0:500d::53'),
        (New-Preset 'Comss.one'   '83.220.169.155' '212.109.195.93' 'https://dns.comss.one/dns-query'  ''),
        (New-Preset 'GeoHide'     '159.194.200.33' '37.230.192.51'  'https://geohide.ru/dns-query'     ''),
        (New-Preset 'NOT-A-DNS'   '2.26.124.29'    ''               ''                                 '')
    )
}

function New-State { [pscustomobject]@{ on = $false; adapters = @(); servers4 = @(); doh = @(); added = @(); ipv6Off = @() } }

function Ensure-Prop($o, $n, $v) {
    if (-not ($o.PSObject.Properties.Name -contains $n)) { $o | Add-Member -NotePropertyName $n -NotePropertyValue $v }
}

function Load-Config {
    $c = $null
    if (Test-Path $cfgFile) {
        try { $c = Get-Content $cfgFile -Raw | ConvertFrom-Json } catch { $c = $null }
    }
    if (-not $c) { $c = [pscustomobject]@{ version = $CfgVersion; active = 'w.quic.best'; presets = @() } }
    Ensure-Prop $c 'version' 1
    Ensure-Prop $c 'active' 'w.quic.best'
    Ensure-Prop $c 'presets' @()
    Ensure-Prop $c 'allowFallback' $false
    Ensure-Prop $c 'disableIpv6' $true
    Ensure-Prop $c 'state' (New-State)
    $list = @()
    foreach ($p in @($c.presets)) { if ($p -and $p.name) { $list += (New-Preset $p.name $p.primary $p.secondary $p.doh $p.ipv6) } }
    if ([int]$c.version -lt $CfgVersion -or $list.Count -eq 0) {
        foreach ($b in Get-BuiltinPresets) {
            $ex = $list | Where-Object { $_.name -eq $b.name } | Select-Object -First 1
            if ($ex) { if (-not $ex.doh) { $ex.doh = $b.doh }; if (-not $ex.ipv6) { $ex.ipv6 = $b.ipv6 } }
            else { $list += $b }
        }
        $c.version = $CfgVersion
        $c.active = 'w.quic.best'
    }
    $c.presets = $list
    if (-not $c.state) { $c.state = New-State }
    foreach ($n in 'adapters', 'servers4', 'doh', 'added', 'ipv6Off') { Ensure-Prop $c.state $n @() }
    return $c
}

function Save-Config {
    if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir | Out-Null }
    $global:cfg | ConvertTo-Json -Depth 6 | Set-Content -Path $cfgFile -Encoding UTF8
}

$global:cfg = Load-Config
Save-Config

function Get-Active {
    $p = $global:cfg.presets | Where-Object { $_.name -eq $global:cfg.active } | Select-Object -First 1
    if (-not $p) { $p = @($global:cfg.presets)[0]; $global:cfg.active = $p.name }
    return $p
}

function Split-List($t) { @(([string]$t) -split '[,;\s]+' | Where-Object { $_ }) }

function Test-Ip($t, $v6) {
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($t, [ref]$ip)) { return $false }
    if ($v6) { return $ip.AddressFamily -eq 'InterNetworkV6' }
    return ($t -match '^\d{1,3}(\.\d{1,3}){3}$')
}

# ---------- DNS control ----------
function Get-Adapters { @(Get-NetAdapter -Physical | Where-Object Status -eq 'Up') }

function Notify($text, $icon) {
    if (-not $icon) { $icon = 'Info' }
    $tray.ShowBalloonTip(5000, 'DNS', $text, $icon)
}

function Test-On {
    $st = $global:cfg.state
    if (-not $st.on) { return $false }
    $first = @($st.servers4)[0]
    if (-not $first) { return $false }
    foreach ($a in Get-Adapters) {
        if ((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4).ServerAddresses -contains $first) { return $true }
    }
    return $false
}

# Resolve the DoH host to get the IPs that really serve DoH for this template.
function Resolve-DohEndpoint($url) {
    $r = [pscustomobject]@{ v4 = @(); v6 = @() }
    try { $h = ([uri]$url).Host } catch { return $r }
    foreach ($srv in @('', '77.88.8.8', '1.1.1.1')) {
        $q = @{ Name = $h; DnsOnly = $true; QuickTimeout = $true; ErrorAction = 'Stop' }
        if ($srv) { $q.Server = $srv }
        try {
            $a = @(Resolve-DnsName @q -Type A | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress } | Select-Object -Unique -First 2)
            if ($a.Count -gt 0) {
                $r.v4 = $a
                try { $r.v6 = @(Resolve-DnsName @q -Type AAAA | Where-Object { $_.Type -eq 'AAAA' } | ForEach-Object { $_.IPAddress } | Select-Object -Unique -First 2) } catch {}
                break
            }
        } catch {}
    }
    return $r
}

function Set-DohFlag($guid, $fam, $ip) {
    $k = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey("$dohRoot\$guid\DohInterfaceSettings\$fam\$ip")
    $k.SetValue('DohFlags', [long]1, [Microsoft.Win32.RegistryValueKind]::QWord)
    $k.Close()
}

function Remove-DohFlags($guid, $ips) {
    foreach ($ip in $ips) {
        foreach ($fam in 'Doh', 'Doh6') {
            try { [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKeyTree("$dohRoot\$guid\DohInterfaceSettings\$fam\$ip", $false) } catch {}
        }
    }
}

function Disable-Dns {
    $st = $global:cfg.state
    $idx = @(Get-Adapters | ForEach-Object { $_.ifIndex }) + @($st.adapters) | Select-Object -Unique
    foreach ($i in $idx) {
        $a = Get-NetAdapter -InterfaceIndex $i -ErrorAction SilentlyContinue
        if (-not $a) { continue }
        try { Set-DnsClientServerAddress -InterfaceIndex $i -ResetServerAddresses -ErrorAction Stop } catch {}
        Remove-DohFlags $a.InterfaceGuid @($st.doh)
    }
    foreach ($n in @($st.ipv6Off)) {
        try { Enable-NetAdapterBinding -Name $n -ComponentID ms_tcpip6 -ErrorAction Stop } catch {}
    }
    foreach ($ip in @($st.added)) {
        try { Remove-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction Stop } catch {}
    }
    $global:cfg.state = New-State
    Save-Config
    Clear-DnsClientCache
}

function Test-Resolve {
    for ($i = 0; $i -lt 4; $i++) {
        try {
            $r = @(Resolve-DnsName 'gemini.google.com' -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' })
            if ($r.Count -gt 0) { return $true }
        } catch {}
        Start-Sleep -Milliseconds 1500
    }
    return $false
}

function Enable-Dns {
    Disable-Dns
    $p  = Get-Active
    $v4 = @(Split-List "$($p.primary) $($p.secondary)")
    $v6 = @(Split-List $p.ipv6)
    $useDoh = [bool]$p.doh
    if ($useDoh -and -not $global:dohSupported) {
        Notify 'В этой версии Windows нет DNS-over-HTTPS (нужна Windows 11). Используется обычный DNS.' 'Warning'
        $useDoh = $false
    }
    $dohIps = @(); $added = @()
    if ($useDoh) {
        $e = Resolve-DohEndpoint $p.doh
        if ($e.v4.Count -gt 0) { $v4 = @($e.v4); $v6 = @($e.v6) }
        $dohIps = @($v4 + $v6)
        foreach ($ip in $dohIps) {
            $ex = Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue
            if ($ex) { Set-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $p.doh -AllowFallbackToUdp ([bool]$global:cfg.allowFallback) -AutoUpgrade $true -ErrorAction Stop | Out-Null }
            else {
                Add-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $p.doh -AllowFallbackToUdp ([bool]$global:cfg.allowFallback) -AutoUpgrade $true -ErrorAction Stop | Out-Null
                $added += $ip
            }
        }
    }
    if ($v4.Count -eq 0) { throw 'В профиле нет IPv4-адреса.' }
    $adapters = Get-Adapters
    if ($adapters.Count -eq 0) { throw 'Нет активных сетевых адаптеров.' }
    # save state before touching adapters, so a failure can always be rolled back
    $global:cfg.state = [pscustomobject]@{
        on = $true; adapters = @($adapters | ForEach-Object { $_.ifIndex }); servers4 = $v4
        doh = $dohIps; added = $added; ipv6Off = @()
    }
    Save-Config
    foreach ($a in $adapters) {
        if ($useDoh) {
            foreach ($ip in $v4) { Set-DohFlag $a.InterfaceGuid 'Doh'  $ip }
            foreach ($ip in $v6) { Set-DohFlag $a.InterfaceGuid 'Doh6' $ip }
        }
        Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses @($v4 + $v6) -ErrorAction Stop
        if ($v6.Count -eq 0 -and $global:cfg.disableIpv6) {
            $b = Get-NetAdapterBinding -Name $a.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
            if ($b -and $b.Enabled) {
                try {
                    Disable-NetAdapterBinding -Name $a.Name -ComponentID ms_tcpip6 -ErrorAction Stop
                    $global:cfg.state.ipv6Off = @($global:cfg.state.ipv6Off) + $a.Name
                    Save-Config
                } catch {}
            }
        }
    }
    Clear-DnsClientCache
    return $useDoh
}

function Set-Dns($on) {
    $name = (Get-Active).name
    try {
        if ($on) {
            $tray.Text = "Подключение: $name".Substring(0, [Math]::Min(63, "Подключение: $name".Length))
            $doh = Enable-Dns
            if (Test-Resolve) {
                $mode = if ($doh) { 'DoH' } else { 'порт 53' }
                Notify "Включён $name ($mode)."
            } else {
                Disable-Dns
                Notify "$name не отвечает. DNS выключен, связь восстановлена. Попробуйте другой профиль." 'Warning'
            }
        } else {
            Disable-Dns
            Notify 'DNS выключен (автоматически от провайдера).'
        }
    } catch {
        try { Disable-Dns } catch {}
        Notify ("Ошибка: " + $_.Exception.Message) 'Error'
    }
    Update-Tray
}

function Toggle-Dns { Set-Dns (-not (Test-On)) }

function Select-Preset($n) {
    $wasOn = Test-On
    $global:cfg.active = $n
    Save-Config
    if ($wasOn) { Set-Dns $true } else { Update-Tray }
}

function Show-Check {
    $lines = @()
    $lines += "Профиль: " + (Get-Active).name + "   Состояние: " + $(if (Test-On) { 'ВКЛ' } else { 'ВЫКЛ' })
    foreach ($a in Get-Adapters) {
        $s = (Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex | ForEach-Object { $_.ServerAddresses }) -join ', '
        $lines += "$($a.Name): $s"
    }
    foreach ($ip in @($global:cfg.state.doh)) {
        $d = Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue
        if ($d) { $lines += "DoH $ip -> $($d.DohTemplate) (откат на 53: $($d.AllowFallbackToUdp))" }
    }
    try {
        $r = @(Resolve-DnsName 'gemini.google.com' -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress })
        $lines += "gemini.google.com -> " + ($r -join ', ')
    } catch { $lines += "gemini.google.com -> ошибка: $($_.Exception.Message)" }
    [void][System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n"), 'Проверка DNS')
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

$iconOn  = New-Icon ([System.Drawing.Color]::LimeGreen)
$iconOff = New-Icon ([System.Drawing.Color]::Gray)

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Visible = $true

function Update-Tray {
    $p = Get-Active
    $mode = if ($p.doh -and $global:dohSupported) { ' (DoH)' } else { '' }
    if (Test-On) { $tray.Icon = $iconOn;  $t = "DNS ВКЛ: $($p.name)$mode" }
    else         { $tray.Icon = $iconOff; $t = "DNS ВЫКЛ: $($p.name)$mode" }
    if ($t.Length -gt 63) { $t = $t.Substring(0, 63) }
    $tray.Text = $t
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
    $f.Text = 'Настройки DNS'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.StartPosition = 'CenterScreen'
    $f.ClientSize = New-Object System.Drawing.Size(420, 385)
    $f.TopMost = $true
    $global:sf = $f

    $L = 'System.Windows.Forms.Label'
    $f.Controls.Add((New-Ctl $L 15 18  130 'Профиль:'))
    $f.Controls.Add((New-Ctl $L 15 53  130 'Название:'))
    $f.Controls.Add((New-Ctl $L 15 88  130 'IPv4 основной:'))
    $f.Controls.Add((New-Ctl $L 15 123 130 'IPv4 доп.:'))
    $f.Controls.Add((New-Ctl $L 15 158 130 'IPv6 (через ,):'))
    $f.Controls.Add((New-Ctl $L 15 193 130 'DoH URL:'))
    $hint = New-Ctl $L 15 222 390 'С DoH запросы идут по HTTPS (порт 443) — провайдер не может их подменить. Без DoH — обычный DNS на порт 53.'
    $hint.Size = New-Object System.Drawing.Size(390, 32)
    $hint.ForeColor = [System.Drawing.Color]::Gray
    $f.Controls.Add($hint)

    $cmb = New-Ctl 'System.Windows.Forms.ComboBox' 150 15 255 $null
    $cmb.DropDownStyle = 'DropDownList'
    $txtName = New-Ctl 'System.Windows.Forms.TextBox' 150 50  255 $null
    $txtP    = New-Ctl 'System.Windows.Forms.TextBox' 150 85  255 $null
    $txtS    = New-Ctl 'System.Windows.Forms.TextBox' 150 120 255 $null
    $txt6    = New-Ctl 'System.Windows.Forms.TextBox' 150 155 255 $null
    $txtD    = New-Ctl 'System.Windows.Forms.TextBox' 150 190 255 $null
    $chkFb   = New-Ctl 'System.Windows.Forms.CheckBox' 15 260 390 'Разрешить откат DoH на обычный DNS (порт 53)'
    $chkV6   = New-Ctl 'System.Windows.Forms.CheckBox' 15 285 390 'Отключать IPv6, пока DNS включён (если у профиля нет IPv6)'
    $chkFb.Checked = [bool]$global:cfg.allowFallback
    $chkV6.Checked = [bool]$global:cfg.disableIpv6
    $bSave   = New-Ctl 'System.Windows.Forms.Button' 15  315 125 'Сохранить'
    $bDel    = New-Ctl 'System.Windows.Forms.Button' 147 315 125 'Удалить'
    $bClose  = New-Ctl 'System.Windows.Forms.Button' 280 315 125 'Закрыть'
    $bApply  = New-Ctl 'System.Windows.Forms.Button' 15  348 390 'Применить и включить'
    foreach ($c in @($cmb, $txtName, $txtP, $txtS, $txt6, $txtD, $chkFb, $chkV6, $bSave, $bDel, $bClose, $bApply)) { $f.Controls.Add($c) }

    $refresh = {
        param($sel)
        $cmb.Items.Clear()
        foreach ($p in $global:cfg.presets) { [void]$cmb.Items.Add($p.name) }
        $cmb.SelectedItem = $sel
    }.GetNewClosure()

    $readInput = {
        $n = $txtName.Text.Trim(); $p1 = $txtP.Text.Trim(); $p2 = $txtS.Text.Trim(); $v6 = $txt6.Text.Trim(); $d = $txtD.Text.Trim()
        $err = $null
        if (-not $n) { $err = 'Введите название.' }
        elseif (-not (Test-Ip $p1 $false)) { $err = 'Основной DNS должен быть IPv4-адресом.' }
        elseif ($p2 -and -not (Test-Ip $p2 $false)) { $err = 'Дополнительный DNS должен быть IPv4-адресом или пустым.' }
        elseif (@(Split-List $v6 | Where-Object { -not (Test-Ip $_ $true) }).Count -gt 0) { $err = 'IPv6: укажите IPv6-адреса через запятую или оставьте пустым.' }
        elseif ($d -and $d -notmatch '^https://[^/\s]+/\S*$') { $err = 'DoH URL должен начинаться с https:// (например https://w.quic.best/dns-query).' }
        if ($err) { [void][System.Windows.Forms.MessageBox]::Show($f, $err, 'Настройки DNS'); return $null }
        return (New-Preset $n $p1 $p2 $d ((Split-List $v6) -join ', '))
    }.GetNewClosure()

    $upsert = {
        param($preset)
        $found = $false
        $new = @()
        foreach ($x in $global:cfg.presets) {
            if ($x.name -eq $preset.name) { $new += $preset; $found = $true } else { $new += $x }
        }
        if (-not $found) { $new += $preset }
        $global:cfg.presets = $new
    }.GetNewClosure()

    $cmb.add_SelectedIndexChanged({
        $p = $global:cfg.presets | Where-Object { $_.name -eq $cmb.SelectedItem } | Select-Object -First 1
        if ($p) { $txtName.Text = $p.name; $txtP.Text = $p.primary; $txtS.Text = $p.secondary; $txt6.Text = $p.ipv6; $txtD.Text = $p.doh }
    }.GetNewClosure())

    $chkFb.add_CheckedChanged({ $global:cfg.allowFallback = $chkFb.Checked; Save-Config }.GetNewClosure())
    $chkV6.add_CheckedChanged({ $global:cfg.disableIpv6 = $chkV6.Checked; Save-Config }.GetNewClosure())

    $bSave.add_Click({
        $p = & $readInput
        if (-not $p) { return }
        $wasOn = Test-On
        & $upsert $p
        Save-Config
        if ($wasOn -and $p.name -eq $global:cfg.active) { Set-Dns $true }
        & $refresh $p.name
    }.GetNewClosure())

    $bApply.add_Click({
        $p = & $readInput
        if (-not $p) { return }
        & $upsert $p
        $global:cfg.active = $p.name
        Save-Config
        Set-Dns $true
        & $refresh $p.name
    }.GetNewClosure())

    $bDel.add_Click({
        $n = $cmb.SelectedItem
        if (-not $n) { return }
        if (@($global:cfg.presets).Count -le 1) {
            [void][System.Windows.Forms.MessageBox]::Show($f, 'Нельзя удалить последний профиль.', 'Настройки DNS')
            return
        }
        if ($n -eq $global:cfg.active -and (Test-On)) { Set-Dns $false }
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
$null = $menu.Items.Add('Вкл / выкл DNS', $null, { Toggle-Dns })
$global:presetMenu = New-Object System.Windows.Forms.ToolStripMenuItem 'Профиль'
$null = $menu.Items.Add($global:presetMenu)
$null = $menu.Items.Add('Проверить', $null, { Show-Check })
$null = $menu.Items.Add('Настройки...', $null, { Show-Settings })
$null = $menu.Items.Add('Выход', $null, { $tray.Visible = $false; [System.Windows.Forms.Application]::Exit() })

function Build-PresetMenu {
    $global:presetMenu.DropDownItems.Clear()
    foreach ($p in $global:cfg.presets) {
        $it = New-Object System.Windows.Forms.ToolStripMenuItem $p.name
        $it.Checked = ($p.name -eq $global:cfg.active)
        $it.add_Click({ Select-Preset $this.Text })
        [void]$global:presetMenu.DropDownItems.Add($it)
    }
}
$menu.add_Opening({ Build-PresetMenu })
Build-PresetMenu

$tray.ContextMenuStrip = $menu
$tray.add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Toggle-Dns } })

Update-Tray
[System.Windows.Forms.Application]::Run()
