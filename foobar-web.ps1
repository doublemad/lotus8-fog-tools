# LOTUS8: foobar2000 + веб-интерфейс Beefweb на сервере (музыка с флешки играет на колонку, подключённую к звуковому выходу сервера, управление из браузера).
# Запуск ОДИН раз на сервере, PowerShell от администратора:   irm <ссылка> | iex
# Что делает: скачивает foobar2000 (с сайта foobar2000.org, подпись и SHA-256 проверяются) и Beefweb (с GitHub автора, SHA-256 проверяется),
# ставит, указывает папку с музыкой (флешка или $env:MUSIC), включает веб-интерфейс на порту 8880 ТОЛЬКО для локальной сети и с паролем,
# добавляет автозапуск при входе этого пользователя. Пароль печатается в конце (запишите его).
# Параметры (необязательно, перед запуском): $env:MUSIC='D:\'  - папка с музыкой;  $env:CHECK=1 - только скачать и проверить, ничего не ставить;
#   $env:REMOVE=1 - убрать автозапуск, правило фаервола и веб-плагин (сам foobar2000 удаляется через "Программы и компоненты")
# ВАЖНО: foobar2000 играет, пока этот пользователь вошёл в Windows. Не выходите из сеанса (RDP закрывайте крестиком/Disconnect, а не Sign out).
# весь код в дочернем блоке, чтобы $ErrorActionPreference и функции не оставались в сессии после irm | iex
& {
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Ok($t)   { Write-Host "  [ OK ] $t" -ForegroundColor Green }
function Warn($t) { Write-Host "  [ !! ] $t" -ForegroundColor Yellow }
function Head($t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }
$fbUrl  = 'https://www.foobar2000.org/downloads/foobar2000-x64_v2.26.2.exe'
$fbSha  = 'FFA739F87D9C374CB030426A2AB4BFB37959D0DBB892FDC742654C14D127F795'
$bwUrl  = 'https://github.com/hyperblast/beefweb/releases/download/v0.10/foo_beefweb-0.10.fb2k-component'
$bwSha  = 'E59005E1681F70B9CA12E12B08BF2E6D30B5FBFFE6BF3D5918F39926FE8EFB47'
$port = 8880; $webUser = 'music'; $rule = 'LOTUS8 foobar2000 web'; $runName = 'LOTUS8-foobar2000'
$profile = Join-Path $env:APPDATA 'foobar2000-v2'
$comp = Join-Path $profile 'user-components-x64\foo_beefweb'
$cfgDir = Join-Path $profile 'beefweb'; $cfg = Join-Path $cfgDir 'config.json'
$check = ($env:CHECK -eq '1')
if (-not $check -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Запустите PowerShell от имени администратора.' -ForegroundColor Red; return
}

if ($env:REMOVE -eq '1') {
    Head 'Удаление'
    Get-Process foobar2000 -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $runName -ErrorAction SilentlyContinue; Ok 'Автозапуск убран'
    Remove-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue; Ok 'Правило фаервола убрано'
    if (Test-Path $comp) { Remove-Item $comp -Recurse -Force; Ok 'Веб-плагин Beefweb удалён' }
    Write-Host '  Сам foobar2000 удаляется через "Программы и компоненты".' -ForegroundColor Gray
    return
}

Head '1. Папка с музыкой'
$music = $env:MUSIC
if (-not $music) {
    foreach ($d in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2') {
        $n = @(Get-ChildItem "$($d.DeviceID)\" -Recurse -Include *.mp3, *.flac, *.wav, *.m4a, *.ogg -ErrorAction SilentlyContinue).Count
        Write-Host "  съёмный диск $($d.DeviceID): файлов с музыкой: $n"
        if ($n -gt 0 -and -not $music) { $music = "$($d.DeviceID)\" }
    }
}
if (-not $music) { Warn 'Музыка на съёмных дисках не найдена. Укажите папку: $env:MUSIC=''D:\'''; return }
Write-Host "  Будет использована: $music"
if ($check) { Write-Host '  (режим CHECK=1: ничего не устанавливается)' -ForegroundColor Yellow }
else {
    $ans = Read-Host 'Введите YES, чтобы установить foobar2000 и веб-интерфейс'
    if ($ans -cne 'YES') { Write-Host 'Отменено, ничего не изменено.' -ForegroundColor Yellow; return }
}

Head '2. Скачивание и проверка'
$work = Join-Path $env:TEMP ('lotus8-fb-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
function Get-Checked($url, $file, $sha) {
    for ($i = 1; $i -le 3; $i++) {
        try { Invoke-WebRequest -UseBasicParsing -UserAgent $ua -Uri $url -OutFile $file -TimeoutSec 240; break } catch { if ($i -eq 3) { throw }; Start-Sleep 4 }
    }
    $h = (Get-FileHash $file -Algorithm SHA256).Hash
    if ($h -ne $sha) { throw "SHA-256 не совпал для $url (получено $h). Файл не используется." }
}
$fbExe = Join-Path $work 'foobar2000-setup.exe'; $bwZip = Join-Path $work 'foo_beefweb.zip'
Get-Checked $fbUrl $fbExe $fbSha
$sig = Get-AuthenticodeSignature $fbExe
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Illustrate') { throw "Подпись установщика foobar2000 недействительна: $($sig.Status)" }
Ok "foobar2000 2.26.2: SHA-256 и подпись ($($sig.SignerCertificate.Subject.Split(',')[0])) верны"
Get-Checked $bwUrl $bwZip $bwSha
Ok 'Beefweb 0.10: SHA-256 верен'
if ($check) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue; Write-Host 'CHECK=1: готово, ничего не установлено.' -ForegroundColor Yellow; return }

Head '3. Установка'
$fbDir = Join-Path $env:ProgramFiles 'foobar2000'
if (-not (Test-Path (Join-Path $fbDir 'foobar2000.exe'))) {
    Start-Process -FilePath $fbExe -ArgumentList '/S' -Wait
    if (-not (Test-Path (Join-Path $fbDir 'foobar2000.exe'))) { throw 'foobar2000 не установился (нет foobar2000.exe).' }
    Ok 'foobar2000 установлен'
} else { Ok 'foobar2000 уже установлен' }
Get-Process foobar2000 -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 2
$ex = Join-Path $work 'bw'; Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($bwZip, $ex)
New-Item -ItemType Directory -Force -Path $comp | Out-Null
Copy-Item (Join-Path $ex 'x64\foo_beefweb.dll') $comp -Force
Copy-Item (Join-Path $ex 'beefweb.root') $comp -Recurse -Force
Ok "Веб-плагин установлен: $comp"

Head '4. Настройка веб-интерфейса'
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
$pw = $null
if (Test-Path $cfg) { try { $pw = (Get-Content $cfg -Raw | ConvertFrom-Json).authPassword } catch {} }
if (-not $pw) {
    $chars = [char[]]'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $b = New-Object byte[] 14; (New-Object Security.Cryptography.RNGCryptoServiceProvider).GetBytes($b)
    $pw = -join ($b | ForEach-Object { $chars[$_ % $chars.Length] })
}
[ordered]@{ port = $port; allowRemote = $true; musicDirs = @($music); authRequired = $true; authUser = $webUser; authPassword = $pw } | ConvertTo-Json | Set-Content -Path $cfg -Encoding UTF8
Ok "Настройки: $cfg"
Remove-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -RemoteAddress LocalSubnet -Profile Any | Out-Null
Ok "Фаервол: порт $port открыт только для локальной сети"
Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $runName -Value "`"$fbDir\foobar2000.exe`""
Ok 'Автозапуск при входе в Windows добавлен'

Head '5. Запуск и проверка'
Start-Process -FilePath (Join-Path $fbDir 'foobar2000.exe')
$auth = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${webUser}:$pw")) }
$up = $false
for ($i = 0; $i -lt 30 -and -not $up; $i++) {
    Start-Sleep 2
    try { $r = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:$port/api/player" -Headers $auth -TimeoutSec 5; if ($r.StatusCode -eq 200) { $up = $true } } catch {}
}
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '192.168.*' } | Select-Object -First 1).IPAddress
if ($up) { Ok 'Веб-интерфейс отвечает' } else { Warn 'Веб-интерфейс не ответил за 60 с. Откройте foobar2000 на экране: возможно, он ждёт ответа в окне первого запуска (нажмите там "Next/Done"), затем проверьте адрес ниже.' }
Write-Host ''
Write-Host "  Адрес:    http://${ip}:$port" -ForegroundColor Green
Write-Host "  Логин:    $webUser" -ForegroundColor Green
Write-Host "  Пароль:   $pw" -ForegroundColor Green
Write-Host '  В браузере: вкладка с файлами (Browse) покажет музыку из папки выше, "Add" добавляет в плейлист.' -ForegroundColor Gray
Write-Host '  Звук идёт на звуковой выход сервера. Не выходите из сеанса Windows (закрывайте RDP как Disconnect).' -ForegroundColor Gray
Write-Host '  Убрать: $env:REMOVE=1 и запустить этот скрипт снова.' -ForegroundColor Gray
}
