# LOTUS8: проверяет ПК и чинит клиент FOG. Запуск один раз, в PowerShell от администратора. Ничего не оставляет после себя.
#   irm <ссылка> | iex
# 1) показывает, что есть на ПК (имя, домен, сеть, DNS, служба FOG, лог)
# 2) если клиента нет или он не работает - ставит/запускает его и включает автозапуск
# 3) если DNS не видит контроллер домена - исправляет DNS
# 4) в конце пишет, ПОЧЕМУ ПК не в домене
$FogIp = '192.168.8.3'; $DcIp = '192.168.8.2'; $Web = '/fog'; $Domain = 'lotus8.local'
$ErrorActionPreference = 'Continue'
$problems = New-Object System.Collections.ArrayList
$fixed    = New-Object System.Collections.ArrayList
function Ok($t)   { Write-Host "  [ OK ] $t" -ForegroundColor Green }
function Warn($t) { Write-Host "  [ !! ] $t" -ForegroundColor Yellow }
function Bad($t)  { Write-Host "  [FAIL] $t" -ForegroundColor Red }
function Head($t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }
function Port($ip, $p) { try { (Test-NetConnection $ip -Port $p -WarningAction SilentlyContinue).TcpTestSucceeded } catch { $false } }
function Srv()  { Get-Service FOGService -ErrorAction SilentlyContinue }
function LogFile() { foreach ($f in 'C:\fog.log', 'C:\Program Files (x86)\FOG\fog.log', 'C:\Program Files\FOG\fog.log') { if (Test-Path $f) { return $f } } return $null }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrator')) {
    Write-Host 'Запустите PowerShell от имени администратора.' -ForegroundColor Red; return
}

Head '1. ПК'
$cs = Get-CimInstance Win32_ComputerSystem
Write-Host "  Имя: $env:COMPUTERNAME    Домен/группа: $($cs.Domain)    В домене: $($cs.PartOfDomain)"
$nics = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Tailscale|WireGuard|Virtual|VPN|Loopback' }
$ips  = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^127|^169' }).IPAddress -join ', '
Write-Host "  IP: $ips"
if ($cs.PartOfDomain -and $cs.Domain -ieq $Domain) { Ok "ПК уже в домене $Domain" }

Head '2. Сеть и DNS'
if (Port $FogIp 80)  { Ok "FOG-сервер $FogIp:80 доступен" } else { Bad "FOG-сервер $FogIp:80 недоступен"; [void]$problems.Add("Нет связи с FOG-сервером $FogIp (порт 80): проверьте сеть/подсеть этого ПК.") }
if (Port $DcIp 389)  { Ok "Контроллер домена $DcIp:389 доступен" } else { Bad "Контроллер домена $DcIp:389 недоступен"; [void]$problems.Add("Нет связи с контроллером домена $DcIp (LDAP 389).") }
function DcVisible() { try { Resolve-DnsName -Type SRV "_ldap._tcp.dc._msdcs.$Domain" -ErrorAction Stop | Out-Null; $true } catch { $false } }
$dns = ((Get-DnsClientServerAddress -AddressFamily IPv4).ServerAddresses | Select-Object -Unique) -join ', '
Write-Host "  DNS: $dns"
if (DcVisible) { Ok "DNS видит домен $Domain" }
else {
    Warn "DNS не видит домен $Domain, исправляю"
    foreach ($n in $nics) { Set-DnsClientServerAddress -InterfaceIndex $n.ifIndex -ResetServerAddresses }
    ipconfig /renew | Out-Null; Start-Sleep 6
    if (-not (DcVisible)) { foreach ($n in $nics) { Set-DnsClientServerAddress -InterfaceIndex $n.ifIndex -ServerAddresses $DcIp, '192.168.8.1' }; Start-Sleep 2 }
    ipconfig /flushdns | Out-Null
    if (DcVisible) { Ok "DNS исправлен: $((Get-DnsClientServerAddress -AddressFamily IPv4).ServerAddresses -join ', ')"; [void]$fixed.Add('DNS переключён на контроллер домена') }
    else { Bad "DNS так и не видит $Domain"; [void]$problems.Add("DNS не находит домен $Domain даже после исправления: проверьте службу DNS на DC $DcIp.") }
}

Head '3. Клиент FOG'
$svc = Srv
if (-not $svc) {
    Bad 'Клиента FOG нет (служба FOGService не найдена)'
    [void]$problems.Add('На ПК не было клиента FOG, поэтому он не мог войти в домен.')
    $m = "$env:TEMP\FOGService.msi"; Remove-Item $m -Force -ErrorAction SilentlyContinue
    try { Invoke-WebRequest "http://$FogIp$Web/client/download.php?newclient" -OutFile $m -UseBasicParsing -ErrorAction Stop } catch { Bad "Скачивание не удалось: $($_.Exception.Message)" }
    $size = 0; if (Test-Path $m) { $size = (Get-Item $m).Length }
    $magic = ''; if ($size -gt 8) { $magic = ([IO.File]::ReadAllBytes($m)[0..3] | ForEach-Object { $_.ToString('x2') }) -join '' }
    if ($size -lt 1MB -or $magic -ne 'd0cf11e0') {
        Bad "Скачанный файл не похож на установщик (размер $size байт)"
        [void]$problems.Add('Установщик клиента не скачался с сервера FOG (файл повреждён или неполный).')
    } else {
        Ok "Установщик скачан ($([math]::Round($size/1MB,1)) МБ)"
        $log = "$env:TEMP\fogmsi.log"; $rc = $null
        for ($i = 1; $i -le 5; $i++) {
            $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList "/i `"$m`" /quiet /norestart /l*v `"$log`" USETRAY=1 HTTPS=0 WEBADDRESS=$FogIp WEBROOT=$Web ROOTLOG=1"
            $rc = $p.ExitCode
            if ($rc -ne 1618) { break }
            Warn 'Идёт другая установка, жду 30 с'; Start-Sleep 30
        }
        if ($rc -eq 0 -or $rc -eq 3010 -or $rc -eq 1641) { Ok "Клиент установлен (код $rc)"; [void]$fixed.Add('Клиент FOG установлен') }
        else {
            Bad "Установка не удалась, код msiexec: $rc"
            [void]$problems.Add("msiexec вернул код $rc. Строки из лога: " + ((Select-String -Path $log -Pattern 'Error|return value 3' -ErrorAction SilentlyContinue | Select-Object -First 3 | ForEach-Object { $_.Line.Trim() }) -join ' | '))
        }
    }
    Remove-Item $m -Force -ErrorAction SilentlyContinue
    $svc = Srv
}
if ($svc) {
    sc.exe config FOGService start= auto | Out-Null
    sc.exe failure FOGService reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
    $svc = Srv
    if ($svc.Status -ne 'Running') { Start-Service FOGService -ErrorAction SilentlyContinue; Start-Sleep 5; $svc = Srv; if ($svc.Status -eq 'Running') { [void]$fixed.Add('Служба FOGService запущена и поставлена на автозапуск') } }
    if ($svc.Status -eq 'Running') { Ok "FOGService работает ($($svc.StartType))" } else { Bad "FOGService не запускается: $($svc.Status)"; [void]$problems.Add('Служба FOGService установлена, но не запускается.') }
}

Head '4. Что видит клиент (лог)'
$lf = LogFile
if ($lf -and $svc -and $svc.Status -eq 'Running') {
    Start-Sleep 8
    Write-Host "  Лог: $lf"
    Get-Content $lf -Tail 400 -ErrorAction SilentlyContinue | Select-String 'Middleware|HostnameChanger|Domain|Error|Fail|Unable|Success|Reboot|Shutdown|Invalid|not registered' | Select-Object -Last 12 | ForEach-Object { Write-Host "    $($_.Line.Trim())" }
    $txt = (Get-Content $lf -Tail 400 -ErrorAction SilentlyContinue) -join "`n"
    $codes = @{ '1355' = 'DNS не видит контроллер домена'; '1326' = 'неверный логин или пароль доменной учётки в FOG'; '1331' = 'учётка FOG-пользователя отключена/заблокирована'; '5' = 'нет прав добавлять компьютеры в домен'; '1909' = 'учётка заблокирована'; '2224' = 'учётная запись компьютера уже существует' }
    foreach ($k in $codes.Keys) { if ($txt -match "(?i)(error code|code|ret(urn)?)\D{0,4}$k\b") { [void]$problems.Add("В логе клиента ошибка ${k}: $($codes[$k]).") } }
    if ($txt -match '(?i)invalid host|not registered|#!ih') { [void]$problems.Add('Сервер FOG не знает этот ПК (не зарегистрирован по MAC-адресу). Зарегистрируйте его через PXE-меню или в веб-интерфейсе FOG.') }
} else { Warn 'Лога пока нет (служба не запущена или клиент ещё не связался с сервером)' }

Head '5. Известен ли ПК серверу FOG (по MAC)'
$known = $false
foreach ($n in $nics) {
    $mac = ($n.MacAddress -replace '-', ':').ToLower()
    try { $r = (Invoke-WebRequest "http://$FogIp$Web/management/index.php?sub=requestClientInfo&mac=$mac&newService&json" -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop).Content } catch { $r = '' }
    $short = if ($r.Length -gt 60) { $r.Substring(0, 60) } else { $r }
    Write-Host "  $mac -> $short"
    if ($r -and $r -notmatch '#!ih|invalid') { $known = $true }
}
if (-not $known) { [void]$problems.Add('Сервер FOG не отвечает по MAC этого ПК как по зарегистрированному хосту. Проверьте, что ПК есть в списке хостов FOG (Hosts) и что MAC совпадает.') }

Head 'ИТОГ'
if ($fixed.Count)    { Write-Host '  Сделано:' -ForegroundColor Green; $fixed | ForEach-Object { Write-Host "   + $_" } }
$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.PartOfDomain -and $cs.Domain -ieq $Domain) { Write-Host "  ПК в домене $Domain. Всё в порядке." -ForegroundColor Green }
elseif ($problems.Count) { Write-Host '  Почему ПК не в домене:' -ForegroundColor Red; $problems | ForEach-Object { Write-Host "   - $_" -ForegroundColor Red } }
else { Write-Host "  Проблем не найдено. Клиент работает: вход в $Domain произойдёт сам в течение 1-5 минут, потом ПК перезагрузится." -ForegroundColor Green }
Write-Host ''
