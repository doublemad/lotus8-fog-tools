# LOTUS8: разрешает контроллеру домена удалённое управление ПК (перезагрузка/выключение командой shutdown /m, ping) через GPO для фаервола Windows.
# Запуск ОДИН раз на контроллере домена, PowerShell от администратора:
#   irm <ссылка> | iex
# Создаёт GPO "LOTUS8 Firewall Remote Admin" на весь домен с входящими правилами ТОЛЬКО с адреса контроллера домена (по умолчанию 192.168.8.2):
#   TCP 445 (SMB, нужен shutdown /m), TCP 135 + динамический RPC 49152-65535, ICMP echo (ping). Других адресов правила не пускают.
# Параметры (необязательно, перед запуском): $env:FROM='192.168.8.2,192.168.8.3'  - с каких адресов разрешить (по умолчанию только DC);  $env:REMOVE=1 - убрать GPO
# На ПК вступает в силу при следующем обновлении политики (до ~2 часов) или после перезагрузки; перезагрузка не обязательна.
# весь код в дочернем блоке, чтобы $ErrorActionPreference и функции не оставались в сессии после irm | iex
& {
$GpoName = 'LOTUS8 Firewall Remote Admin'
$ErrorActionPreference = 'Stop'
function Ok($t) { Write-Host "  [ OK ] $t" -ForegroundColor Green }
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Запустите PowerShell от имени администратора.' -ForegroundColor Red; return
}
Import-Module GroupPolicy, ActiveDirectory, NetSecurity
$dom = Get-ADDomain; $dn = $dom.DistinguishedName; $dns = $dom.DNSRoot
if ($env:REMOVE -eq '1') {
    if (Get-GPO -Name $GpoName -ErrorAction SilentlyContinue) { Remove-GPO -Name $GpoName; Ok "GPO '$GpoName' удалён" } else { Write-Host "GPO '$GpoName' не найден" -ForegroundColor Yellow }
    return
}
$from = @('192.168.8.2'); if ($env:FROM) { $from = $env:FROM -split '[,; ]+' | Where-Object { $_ } }
foreach ($a in $from) { if ($a -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Write-Host "Неверный адрес в FROM: $a" -ForegroundColor Red; return } }
Write-Host "Разрешаю входящие TCP 445, TCP 135, RPC 49152-65535 и ping ТОЛЬКО с: $($from -join ', ') (на всех ПК домена)." -ForegroundColor Cyan
$ans = Read-Host 'Введите YES, чтобы создать GPO'
if ($ans -cne 'YES') { Write-Host 'Отменено, ничего не изменено.' -ForegroundColor Yellow; return }

$g = Get-GPO -Name $GpoName -ErrorAction SilentlyContinue
if (-not $g) { $g = New-GPO -Name $GpoName -Comment 'LOTUS8: удалённое управление ПК с контроллера домена (SMB, RPC, ping)'; Ok 'GPO создан' } else { Ok 'GPO уже есть, обновляю правила' }
if (-not ((Get-GPInheritance -Target $dn).GpoLinks | Where-Object DisplayName -eq $GpoName)) { New-GPLink -Name $GpoName -Target $dn -LinkEnabled Yes | Out-Null; Ok 'GPO привязан к домену' }

$store = "$dns\$GpoName"
$s = Open-NetGPO -PolicyStore $store
Remove-NetFirewallRule -GPOSession $s -DisplayName 'LOTUS8*' -ErrorAction SilentlyContinue
$common = @{ GPOSession = $s; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Any'; RemoteAddress = $from; Enabled = 'True' }
New-NetFirewallRule @common -DisplayName 'LOTUS8 SMB-In (shutdown /m) from admin' -Protocol TCP -LocalPort 445 | Out-Null
New-NetFirewallRule @common -DisplayName 'LOTUS8 RPC-EPMAP-In from admin' -Protocol TCP -LocalPort 135 | Out-Null
New-NetFirewallRule @common -DisplayName 'LOTUS8 RPC-Dynamic-In from admin' -Protocol TCP -LocalPort 49152-65535 | Out-Null
New-NetFirewallRule @common -DisplayName 'LOTUS8 ICMPv4-Echo-In from admin' -Protocol ICMPv4 -IcmpType 8 | Out-Null
Save-NetGPO -GPOSession $s
Ok 'Правила фаервола записаны в GPO'

Write-Host ''
Write-Host 'Проверка (правила в GPO):' -ForegroundColor Cyan
Get-NetFirewallRule -PolicyStore $store | ForEach-Object { $a = $_ | Get-NetFirewallAddressFilter; $p = $_ | Get-NetFirewallPortFilter; "  {0,-45} {1,-8} {2,-6} {3,-12} от {4}" -f $_.DisplayName, $_.Action, $p.Protocol, $p.LocalPort, ($a.RemoteAddress -join ',') }
Write-Host 'На ПК правила появятся при следующем обновлении политики (до ~2 часов) или после перезагрузки. Проверка с DC:  Test-NetConnection ИМЯ_ПК -Port 445' -ForegroundColor Green
Write-Host 'Откат: $env:REMOVE=1 перед запуском.' -ForegroundColor Gray
}
