# LOTUS8: перезагружает ВСЕ рабочие ПК домена (с предупреждением пользователям), дожидаясь, пока каждый ПК станет доступен для удалённого управления.
# Запуск на контроллере домена, PowerShell от администратора:   irm <ссылка> | iex
# ПК, который выключен или ещё не получил правило фаервола (GPO "LOTUS8 Firewall Remote Admin", см. fw-gpo.ps1), скрипт опрашивает раз в минуту и перезагружает, как только он станет доступен.
# Скрипт останавливается, когда все ПК обработаны или вышло время ожидания; в конце печатает итог по каждому ПК.
# Параметры (необязательно, перед запуском): $env:MINUTES=5 (предупреждение пользователям, минут)  $env:HOURS=3 (сколько ждать недоступные ПК)  $env:ONLY='RET1,Ret4' (только эти ПК)
# весь код в дочернем блоке, чтобы $ErrorActionPreference и функции не оставались в сессии после irm | iex
& {
$ErrorActionPreference = 'Continue'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Запустите PowerShell от имени администратора.' -ForegroundColor Red; return
}
Import-Module ActiveDirectory
$warn = 5; if ($env:MINUTES) { $warn = [int]$env:MINUTES }
$hours = 3; if ($env:HOURS) { $hours = [double]$env:HOURS }
$only = @(); if ($env:ONLY) { $only = $env:ONLY -split '[,; ]+' | Where-Object { $_ } }
function Port445($ip) {
    $c = New-Object Net.Sockets.TcpClient
    try { $t = $c.ConnectAsync($ip, 445); return ($t.Wait(1500) -and $c.Connected) } catch { return $false } finally { $c.Close() }
}
$pcs = @(Get-ADComputer -Filter * -Properties PrimaryGroupID, IPv4Address | Where-Object { $_.PrimaryGroupID -eq 515 -and $_.Enabled } | Sort-Object Name)
if ($only.Count) { $pcs = @($pcs | Where-Object { $only -contains $_.Name }) }
if (-not $pcs.Count) { Write-Host 'Нет подходящих ПК.' -ForegroundColor Red; return }
Write-Host "Будут перезагружены ($($pcs.Count)): $($pcs.Name -join ', ')" -ForegroundColor Cyan
Write-Host "Пользователям: предупреждение за $warn мин. Недоступные ПК ждём до $hours ч., опрос раз в минуту." -ForegroundColor Cyan
$ans = Read-Host 'Введите YES, чтобы начать'
if ($ans -cne 'YES') { Write-Host 'Отменено.' -ForegroundColor Yellow; return }

$done = @{}; $last = @{}
$deadline = (Get-Date).AddHours($hours)
while ($true) {
    foreach ($c in ($pcs | Where-Object { -not $done.ContainsKey($_.Name) })) {
        $ip = $c.IPv4Address
        if (-not $ip) { try { $ip = (Resolve-DnsName $c.Name -Type A -ErrorAction Stop | Select-Object -First 1).IPAddress } catch {} }
        if (-not $ip) { $last[$c.Name] = 'нет адреса в DNS/AD'; continue }
        if (-not (Port445 $ip)) { $last[$c.Name] = "порт 445 недоступен ($ip): ПК выключен или фаервол ещё не обновился"; continue }
        $o = (cmd /c "shutdown /m \\$($c.Name) /r /t $($warn * 60) /c ""Перезагрузка через $warn мин (применение политик). Сохраните работу."" 2>&1") -join ' '
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 1190) {
            $done[$c.Name] = (Get-Date).ToString('HH:mm'); Write-Host ("  [ OK ] {0,-16} {1}: перезагрузка запланирована через {2} мин" -f $c.Name, $ip, $warn) -ForegroundColor Green
        } else { $last[$c.Name] = "shutdown код ${LASTEXITCODE}: $o" }
    }
    if ($done.Count -ge $pcs.Count) { break }
    if ((Get-Date) -ge $deadline) { break }
    Write-Host ("  ждём: {0} из {1} готово, повтор через минуту ({2:HH:mm})" -f $done.Count, $pcs.Count, (Get-Date)) -ForegroundColor DarkGray
    Start-Sleep 60
}
Write-Host ''
Write-Host "== Итог: перезагрузка запланирована на $($done.Count) из $($pcs.Count) ПК" -ForegroundColor Cyan
foreach ($c in $pcs) {
    if ($done.ContainsKey($c.Name)) { continue }
    Write-Host ("  [ !! ] {0,-16} не перезагружен: {1}" -f $c.Name, $last[$c.Name]) -ForegroundColor Yellow
}
if ($done.Count -lt $pcs.Count) { Write-Host 'Эти ПК не получили команду: перезагрузите их вручную, либо запустите скрипт снова позже.' -ForegroundColor Yellow }
Write-Host "Отмена в течение $warn мин:  shutdown /a /m \\ИМЯ_ПК" -ForegroundColor Gray
}
