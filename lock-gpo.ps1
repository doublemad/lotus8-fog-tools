# LOTUS8: автоблокировка Windows при бездействии на всех ПК домена через GPO. Запуск ОДИН раз на контроллере домена, PowerShell от администратора:
#   irm <ссылка> | iex
# Политика компьютера "Интерактивный вход: предел простоя компьютера" (InactivityTimeoutSecs). После блокировки вход только паролем доменной учётки.
# Параметры (необязательно, перед запуском): $env:MINUTES=20 (по умолчанию 20);  $env:REMOVE=1 - убрать GPO
# На ПК действует после gpupdate /force и перезагрузки.
# весь код в дочернем блоке, чтобы $ErrorActionPreference и функции не оставались в сессии после irm | iex
& {
$GpoName = 'LOTUS8 Lock'
$ErrorActionPreference = 'Stop'
function Ok($t) { Write-Host "  [ OK ] $t" -ForegroundColor Green }
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Запустите PowerShell от имени администратора.' -ForegroundColor Red; return
}
Import-Module GroupPolicy, ActiveDirectory
$dn = (Get-ADDomain).DistinguishedName
if ($env:REMOVE -eq '1') {
    if (Get-GPO -Name $GpoName -ErrorAction SilentlyContinue) { Remove-GPO -Name $GpoName; Ok "GPO '$GpoName' удалён" } else { Write-Host "GPO '$GpoName' не найден" -ForegroundColor Yellow }
    return
}
$min = 20; if ($env:MINUTES) { $min = [int]$env:MINUTES }
if ($min -lt 1 -or $min -gt 1440) { Write-Host 'MINUTES должно быть от 1 до 1440.' -ForegroundColor Red; return }
Write-Host "Блокировка при бездействии: $min мин. Применяется ко всем ПК домена (и к DC)." -ForegroundColor Cyan
$ans = Read-Host 'Введите YES, чтобы создать GPO'
if ($ans -cne 'YES') { Write-Host 'Отменено, ничего не изменено.' -ForegroundColor Yellow; return }
$g = Get-GPO -Name $GpoName -ErrorAction SilentlyContinue
if (-not $g) { $g = New-GPO -Name $GpoName -Comment "LOTUS8: блокировка при бездействии $min мин"; Ok 'GPO создан' } else { Ok 'GPO уже есть, обновляю' }
if (-not ((Get-GPInheritance -Target $dn).GpoLinks | Where-Object DisplayName -eq $GpoName)) { New-GPLink -Name $GpoName -Target $dn -LinkEnabled Yes | Out-Null; Ok 'GPO привязан к домену' }
Set-GPRegistryValue -Name $GpoName -Key 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ValueName InactivityTimeoutSecs -Type DWord -Value ($min * 60) | Out-Null
$v = (Get-GPRegistryValue -Name $GpoName -Key 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ValueName InactivityTimeoutSecs).Value
Ok "InactivityTimeoutSecs = $v сек ($($v / 60) мин)"
Write-Host 'Дальше, на каждом ПК: gpupdate /force и перезагрузка. Проверка на ПК:  reg query HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v InactivityTimeoutSecs' -ForegroundColor Green
Write-Host 'Откат: $env:REMOVE=1 перед запуском.' -ForegroundColor Gray
}
