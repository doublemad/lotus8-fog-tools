# LOTUS8: allows this PC to be switched on by Wake-on-LAN (Windows side). Run once, PowerShell as administrator:  irm <link> | iex
# 1) network card: 'Wake on Magic Packet' ON, 'Only allow a magic packet to wake' ON
# 2) turns off Fast Startup and hibernation (they stop wake-up and leave NTFS 'dirty' for image capture)
# BIOS 'Wake on LAN' cannot be set from Windows: enable it once in the BIOS (Power/Advanced > Wake on LAN = Enabled, deep sleep/ErP = Off).
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Запустите PowerShell от имени администратора.' -ForegroundColor Red; return
}
$nics = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Wireless|Wi-?Fi|Bluetooth|Virtual|VPN|Tailscale' }
if (-not $nics) { Write-Host 'Не найдена рабочая проводная сетевая карта.' -ForegroundColor Red; return }
foreach ($n in $nics) {
    Write-Host "Сетевая карта: $($n.Name) ($($n.InterfaceDescription)), MAC $($n.MacAddress)"
    try {
        Set-NetAdapterPowerManagement -Name $n.Name -WakeOnMagicPacket Enabled -WakeOnPattern Disabled -ErrorAction Stop
        Write-Host '  [ OK ] Wake on Magic Packet включён' -ForegroundColor Green
    } catch { Write-Host "  [ !! ] Не удалось: $($_.Exception.Message). Включите вручную: Диспетчер устройств > карта > Электропитание." -ForegroundColor Yellow }
    # driver's own switch (vendor name differs, so only set it when it exists)
    foreach ($kw in 'Wake on Magic Packet', 'Shutdown Wake-On-Lan', 'Shutdown Wake Up', 'Energy Efficient Ethernet', 'Green Ethernet') {
        $p = Get-NetAdapterAdvancedProperty -Name $n.Name -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*$kw*" }
        foreach ($x in $p) {
            if ($kw -match 'Energy|Green') { $want = 'Disabled' } else { $want = 'Enabled' }
            try { Set-NetAdapterAdvancedProperty -Name $n.Name -DisplayName $x.DisplayName -DisplayValue $want -ErrorAction Stop; Write-Host "  [ OK ] $($x.DisplayName) = $want" -ForegroundColor Green } catch { }
        }
    }
}
powercfg /h off | Out-Null
Write-Host '[ OK ] Быстрый запуск и гибернация выключены' -ForegroundColor Green
Write-Host ''
Write-Host 'Проверка: карта в списке пробуждающих устройств?' -ForegroundColor Cyan
powercfg /devicequery wake_armed
Write-Host ''
Write-Host 'Осталось один раз включить Wake on LAN в BIOS (Power > Wake on LAN = Enabled; режимы Deep Sleep / ErP / EuP отключить).' -ForegroundColor Yellow
