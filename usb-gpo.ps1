# LOTUS8: запрет флешек (USB-накопителей) на ПК домена через GPO. Запуск ОДИН раз на контроллере домена, PowerShell от администратора:
#   irm <ссылка> | iex
# Блокируется чтение и запись на съёмных дисках (флешки, внешние HDD) и на телефонах/плеерах (WPD). Клавиатуры, мыши, принтеры, сканеры, CD/DVD не затрагиваются.
# Исключения: ПК, добавленные в группу AD "LOTUS8-USB-Allowed" (компьютеры), эту политику не получают (после gpupdate /force и перезагрузки).
# Параметры (необязательно, перед запуском):
#   $env:ONLY='Ret4,PC8'   - только эти ПК (пилот)
#   $env:MODE='write'      - запретить только ЗАПИСЬ на флешку (читать с неё можно); по умолчанию 'all' - запрет и чтения, и записи
#   $env:REMOVE=1          - убрать GPO (и удалить группу-исключение, если она пустая)
# весь код в дочернем блоке, чтобы $ErrorActionPreference и функции не оставались в сессии после irm | iex
& {
$GpoName = 'LOTUS8 USB'; $ExcGroup = 'LOTUS8-USB-Allowed'
$ErrorActionPreference = 'Stop'
function Ok($t)   { Write-Host "  [ OK ] $t" -ForegroundColor Green }
function Warn($t) { Write-Host "  [ !! ] $t" -ForegroundColor Yellow }
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Запустите PowerShell от имени администратора.' -ForegroundColor Red; return
}
Import-Module GroupPolicy, ActiveDirectory
$dom = Get-ADDomain; $dn = $dom.DistinguishedName
$grp = Get-ADGroup -Identity "$($dom.DomainSID.Value)-515"          # Domain Computers (по SID, имя зависит от языка)

if ($env:REMOVE -eq '1') {
    if (Get-GPO -Name $GpoName -ErrorAction SilentlyContinue) { Remove-GPO -Name $GpoName; Ok "GPO '$GpoName' удалён" } else { Warn "GPO '$GpoName' не найден" }
    $x = Get-ADGroup -Filter "Name -eq '$ExcGroup'" -ErrorAction SilentlyContinue
    if ($x -and -not (Get-ADGroupMember $x)) { Remove-ADGroup $x -Confirm:$false; Ok "Группа $ExcGroup удалена (была пустой)" }
    Write-Host 'На ПК флешки заработают после gpupdate /force и перезагрузки.' -ForegroundColor Gray
    return
}

$mode = 'all'; if ($env:MODE -eq 'write') { $mode = 'write' }
$only = @(); if ($env:ONLY) { $only = $env:ONLY -split '[,; ]+' | Where-Object { $_ } }
$all = Get-ADComputer -Filter * -Properties PrimaryGroupID | Where-Object { $_.PrimaryGroupID -eq 515 -and $_.Enabled }
if ($only.Count) {
    $targets = @($all | Where-Object { $only -contains $_.Name })
    foreach ($n in $only) { if (-not ($targets.Name -contains $n)) { Warn "ПК '$n' не найден в AD" } }
} else { $targets = @($all) }
if (-not $targets.Count) { Write-Host 'Нет подходящих ПК.' -ForegroundColor Red; return }
Write-Host "== Запрет флешек: режим '$mode' ($(if ($mode -eq 'write') { 'запрещена запись' } else { 'запрещены чтение и запись' }))" -ForegroundColor Cyan
Write-Host "  ПК ($($targets.Count)): $((($targets | Sort-Object Name).Name) -join ', ')"
Write-Host "  Контроллер домена не затрагивается. Исключения: группа $ExcGroup" -ForegroundColor Gray
$ans = Read-Host 'Введите YES, чтобы создать GPO'
if ($ans -cne 'YES') { Write-Host 'Отменено, ничего не изменено.' -ForegroundColor Yellow; return }

$g = Get-GPO -Name $GpoName -ErrorAction SilentlyContinue
if (-not $g) { $g = New-GPO -Name $GpoName -Comment "LOTUS8: запрет USB-накопителей (режим $mode)"; Ok 'GPO создан' } else { Ok 'GPO уже есть, обновляю' }
if (-not ((Get-GPInheritance -Target $dn).GpoLinks | Where-Object DisplayName -eq $GpoName)) { New-GPLink -Name $GpoName -Target $dn -LinkEnabled Yes | Out-Null; Ok 'GPO привязан к домену' }

# классы устройств: съёмные диски и WPD (телефоны, плееры)
$base = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices'
$classes = '{53f5630d-b6bf-11d0-94f2-00a0c91efb8b}', '{6AC27878-A6FA-4155-BA85-F98F491D4F33}', '{F33FDC04-D1AC-4E8E-9A30-19BBD4B108AE}'
foreach ($c in $classes) {
    Set-GPRegistryValue -Name $GpoName -Key "$base\$c" -ValueName Deny_Write -Type DWord -Value 1 | Out-Null
    $r = 1; if ($mode -eq 'write') { $r = 0 }
    Set-GPRegistryValue -Name $GpoName -Key "$base\$c" -ValueName Deny_Read -Type DWord -Value $r | Out-Null
}
Ok "Политика записана ($($classes.Count) класса устройств)"

# кому применять
$au = ((New-Object Security.Principal.SecurityIdentifier 'S-1-5-11').Translate([Security.Principal.NTAccount]).Value -split '\\')[-1]
Set-GPPermission -Name $GpoName -TargetName $au -TargetType Group -PermissionLevel GpoRead -Replace | Out-Null
if ($only.Count) {
    Set-GPPermission -Name $GpoName -TargetName $grp.Name -TargetType Group -PermissionLevel GpoRead -Replace | Out-Null
    foreach ($t in $targets) { Set-GPPermission -Name $GpoName -TargetName $t.Name -TargetType Computer -PermissionLevel GpoApply -Replace | Out-Null }
    Ok "Применяется только к: $($targets.Name -join ', ')"
} else {
    Set-GPPermission -Name $GpoName -TargetName $grp.Name -TargetType Group -PermissionLevel GpoApply -Replace | Out-Null
    Ok "Применяется ко всем ПК ($($grp.Name))"
}

# группа-исключение: запрет "Применять групповую политику" для неё
$x = Get-ADGroup -Filter "Name -eq '$ExcGroup'" -ErrorAction SilentlyContinue
if (-not $x) { $x = New-ADGroup -Name $ExcGroup -GroupScope Global -GroupCategory Security -Path "CN=Users,$dn" -Description 'ПК в этой группе НЕ получают запрет флешек (GPO LOTUS8 USB)' -PassThru; Ok "Группа $ExcGroup создана" }
$gdn = "CN={$($g.Id.ToString().ToUpper())},CN=Policies,CN=System,$dn"
$acl = Get-Acl "AD:$gdn"
$applyGuid = [Guid]'edacfd8f-ffb3-11d1-b41d-00a0c9a06d32'    # право "Применять групповую политику"
$has = $acl.Access | Where-Object { $_.AccessControlType -eq 'Deny' -and $_.ObjectType -eq $applyGuid -and $_.IdentityReference -like "*\$ExcGroup" }
if (-not $has) {
    $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($x.SID, 'ExtendedRight', 'Deny', $applyGuid)
    $acl.AddAccessRule($rule); Set-Acl "AD:$gdn" $acl; Ok "Группе $ExcGroup запрещено применять эту политику"
}

Write-Host ''
Write-Host "Проверка: значений в GPO: $((Get-GPRegistryValue -Name $GpoName -Key "$base\$($classes[0])").Count) (ожидается 2 для первого класса)   привязка: $([bool]((Get-GPInheritance -Target $dn).GpoLinks | Where-Object DisplayName -eq $GpoName))" -ForegroundColor Cyan
Write-Host 'Дальше, на каждом ПК: gpupdate /force и перезагрузка (вставленную до этого флешку вынуть и вставить заново).' -ForegroundColor Green
Write-Host "ПК, которому флешки нужны:  Add-ADGroupMember '$ExcGroup' -Members (Get-ADComputer ИМЯ_ПК)   (+ gpupdate /force и перезагрузка на нём)" -ForegroundColor Green
Write-Host 'Откат: $env:REMOVE=1 перед запуском.' -ForegroundColor Gray
}
