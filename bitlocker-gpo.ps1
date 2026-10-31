# LOTUS8: BitLocker на всех рабочих ПК домена через GPO. Запуск ОДИН раз на контроллере домена, PowerShell от администратора:
#   irm <ссылка> | iex
# Что делает:
#  1) создаёт GPO "LOTUS8 BitLocker" на весь домен (только "Domain Computers", контроллер домена не затрагивается)
#  2) политика: XTS-AES 128, только занятое место, защита TPM без ПИН-кода (ПК грузится сам - работает с Wake-on-LAN и выключением в 21:00),
#     ПК без TPM не шифруются, ключ восстановления ОБЯЗАТЕЛЬНО сохраняется в AD (если AD недоступен - шифрование не начинается)
#  3) загрузочный скрипт на ПК включает шифрование диска C: (лог на ПК: C:\Windows\Temp\lotus8-bitlocker.log)
# Параметры (необязательно, перед запуском): $env:ONLY='Ret4,PC8'  - только эти ПК (пилот);  $env:REMOVE=1 - убрать GPO (диски НЕ расшифровываются)
# На ПК шифрование начнётся после применения политики и перезагрузки (gpupdate /force + перезагрузка; иногда нужно 2 перезагрузки).
# ПК для снятия образа в FOG НЕ шифруйте: положите на ПК пустой файл C:\lotus8-bitlocker.skip (до первой перезагрузки с политикой).
$GpoName = 'LOTUS8 BitLocker'
$ErrorActionPreference = 'Stop'
function Ok($t)   { Write-Host "  [ OK ] $t" -ForegroundColor Green }
function Warn($t) { Write-Host "  [ !! ] $t" -ForegroundColor Yellow }
function Head($t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Запустите PowerShell от имени администратора.' -ForegroundColor Red; return
}
Import-Module GroupPolicy, ActiveDirectory
$dom = Get-ADDomain
$dn = $dom.DistinguishedName; $dns = $dom.DNSRoot
$grp = Get-ADGroup -Identity "$($dom.DomainSID.Value)-515"          # Domain Computers (по SID, имя зависит от языка)
$only = @(); if ($env:ONLY) { $only = $env:ONLY -split '[,; ]+' | Where-Object { $_ } }

if ($env:REMOVE -eq '1') {
    Head 'Удаление GPO'
    if (Get-GPO -Name $GpoName -ErrorAction SilentlyContinue) { Remove-GPO -Name $GpoName; Ok "GPO '$GpoName' удалён. Уже зашифрованные диски остаются зашифрованными: на ПК 'manage-bde -off C:' расшифрует." }
    else { Warn "GPO '$GpoName' не найден" }
    return
}

Head '1. Какие ПК получат BitLocker'
$all = Get-ADComputer -Filter * -Properties PrimaryGroupID, OperatingSystem | Where-Object { $_.PrimaryGroupID -eq 515 -and $_.Enabled }
if ($only.Count) {
    $targets = @($all | Where-Object { $only -contains $_.Name })
    foreach ($n in $only) { if (-not ($targets.Name -contains $n)) { Warn "ПК '$n' не найден в AD" } }
} else { $targets = @($all) }
if (-not $targets.Count) { Write-Host 'Нет подходящих ПК.' -ForegroundColor Red; return }
$targets | Sort-Object Name | ForEach-Object { Write-Host ("  {0,-16} {1}" -f $_.Name, $_.OperatingSystem) }
Write-Host "  Контроллер домена в список не входит. Без TPM ПК шифроваться не будет." -ForegroundColor Gray
$ans = Read-Host 'Введите YES, чтобы создать GPO (диски начнут шифроваться после перезагрузки ПК)'
if ($ans -cne 'YES') { Write-Host 'Отменено, ничего не изменено.' -ForegroundColor Yellow; return }

Head '2. GPO и политика'
$g = Get-GPO -Name $GpoName -ErrorAction SilentlyContinue
if (-not $g) { $g = New-GPO -Name $GpoName -Comment 'LOTUS8: BitLocker, TPM, ключ в AD'; Ok "GPO создан" } else { Ok 'GPO уже есть, обновляю' }
if (-not ((Get-GPInheritance -Target $dn).GpoLinks | Where-Object DisplayName -eq $GpoName)) { New-GPLink -Name $GpoName -Target $dn -LinkEnabled Yes | Out-Null; Ok "GPO привязан к домену $dns" }
$fve = 'HKLM\SOFTWARE\Policies\Microsoft\FVE'
$vals = [ordered]@{
    EncryptionMethodWithXtsOs = 6; EncryptionMethodWithXtsFdv = 6; EncryptionMethodWithXtsRdv = 6   # XTS-AES 128
    OSEncryptionType = 2                                                                              # только занятое место
    UseAdvancedStartup = 1; EnableBDEWithNoTPM = 0; UseTPM = 2; UseTPMPIN = 0; UseTPMKey = 0; UseTPMKeyPIN = 0   # только TPM, без ПИН
    OSRecovery = 1; OSManageDRA = 0; OSRecoveryPassword = 1; OSRecoveryKey = 0; OSHideRecoveryPage = 1
    OSActiveDirectoryBackup = 1; OSActiveDirectoryInfoToStore = 1; OSRequireActiveDirectoryBackup = 1     # ключ в AD обязателен
}
foreach ($k in $vals.Keys) { Set-GPRegistryValue -Name $GpoName -Key $fve -ValueName $k -Type DWord -Value $vals[$k] | Out-Null }
Ok "Политика BitLocker записана ($($vals.Count) параметров)"

Head '3. Кому применять (фильтр безопасности)'
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

Head '4. Загрузочный скрипт на ПК'
$id = '{' + $g.Id.ToString().ToUpper() + '}'
$sys = "\\$dns\SYSVOL\$dns\Policies\$id"
$sdir = "$sys\Machine\Scripts\Startup"
New-Item -ItemType Directory -Force -Path $sdir | Out-Null
$pc = @'
# LOTUS8: enables BitLocker on C: (TPM protector + recovery password saved to AD). Runs at computer startup as SYSTEM.
$log = "$env:windir\Temp\lotus8-bitlocker.log"
function L($m) { Add-Content -Path $log -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $m) }
try {
    $mp = $env:SystemDrive
    if (Test-Path "$mp\lotus8-bitlocker.skip") { L 'skip flag present, nothing done'; return }
    $v = Get-BitLockerVolume -MountPoint $mp -ErrorAction Stop
    if ($v.VolumeStatus -eq 'FullyEncrypted' -and $v.ProtectionStatus -eq 'Off') { Resume-BitLocker -MountPoint $mp | Out-Null; L 'protection was suspended, resumed'; return }
    if ($v.VolumeStatus -ne 'FullyDecrypted') { L "volume $($v.VolumeStatus), protection $($v.ProtectionStatus): nothing to do"; return }
    $tpm = Get-Tpm
    if (-not ($tpm.TpmPresent -and $tpm.TpmReady)) { L "TPM not ready (present=$($tpm.TpmPresent) ready=$($tpm.TpmReady)): not encrypting"; return }
    $rp = $v.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword' | Select-Object -First 1
    if (-not $rp) {
        Add-BitLockerKeyProtector -MountPoint $mp -RecoveryPasswordProtector | Out-Null
        $rp = (Get-BitLockerVolume -MountPoint $mp).KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword' | Select-Object -First 1
    }
    Backup-BitLockerKeyProtector -MountPoint $mp -KeyProtectorId $rp.KeyProtectorId -ErrorAction Stop | Out-Null
    L 'recovery password saved to AD'
    Enable-BitLocker -MountPoint $mp -EncryptionMethod XtsAes128 -UsedSpaceOnly -TpmProtector -SkipHardwareTest -ErrorAction Stop | Out-Null
    L 'BitLocker enabled (TPM protector, used space only); encryption runs in the background'
} catch { L "ERROR: $($_.Exception.Message)" }
'@
[IO.File]::WriteAllText("$sdir\lotus8-bitlocker.ps1", $pc, (New-Object Text.UTF8Encoding $true))
$ini = "[Startup]`r`n0CmdLine=powershell.exe`r`n0Parameters=-NoProfile -ExecutionPolicy Bypass -File `"$sdir\lotus8-bitlocker.ps1`"`r`n"
[IO.File]::WriteAllText("$sys\Machine\Scripts\scripts.ini", $ini, [Text.Encoding]::Unicode)
Ok "Скрипт записан: $sdir"

# регистрация расширения "Scripts" в GPO + новая версия, чтобы ПК подтянули скрипт
$ext = '[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]'
$o = Get-ADObject -Identity "CN=$id,CN=Policies,CN=System,$dn" -Properties gPCMachineExtensionNames, versionNumber
$names = [string]$o.gPCMachineExtensionNames
if (-not $names.Contains($ext)) { $names += $ext }
$ver = [int]$o.versionNumber + 1
Set-ADObject -Identity $o.DistinguishedName -Replace @{ gPCMachineExtensionNames = $names; versionNumber = $ver }
[IO.File]::WriteAllText("$sys\GPT.INI", "[General]`r`nVersion=$ver`r`n", [Text.Encoding]::ASCII)

Head '5. Проверка'
$cnt = (Get-GPRegistryValue -Name $GpoName -Key $fve).Count
Write-Host "  Параметров в политике: $cnt (ожидается $($vals.Count))"
Write-Host "  Скрипт в SYSVOL:       $(Test-Path "$sdir\lotus8-bitlocker.ps1")   scripts.ini: $(Test-Path "$sys\Machine\Scripts\scripts.ini")"
Write-Host "  Расширение Scripts:    $(([string](Get-ADObject -Identity $o.DistinguishedName -Properties gPCMachineExtensionNames).gPCMachineExtensionNames).Contains($ext))   версия: $ver"
Write-Host "  Привязка к домену:     $([bool]((Get-GPInheritance -Target $dn).GpoLinks | Where-Object DisplayName -eq $GpoName))"
Write-Host ''
Write-Host 'Дальше, на каждом ПК: gpupdate /force, затем перезагрузка (иногда две). Проверка:  manage-bde -status C:    лог: C:\Windows\Temp\lotus8-bitlocker.log' -ForegroundColor Green
Write-Host 'Ключ восстановления ПК, на DC:' -ForegroundColor Cyan
Write-Host '  Get-ADObject -SearchBase (Get-ADComputer ИМЯ_ПК).DistinguishedName -Filter ''objectClass -eq "msFVE-RecoveryInformation"'' -Properties msFVE-RecoveryPassword | select Name,msFVE-RecoveryPassword'
Write-Host 'Откат: $env:REMOVE=1 перед запуском (расшифровка на ПК: manage-bde -off C:).' -ForegroundColor Gray
