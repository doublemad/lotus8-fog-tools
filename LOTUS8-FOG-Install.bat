@echo off
setlocal EnableExtensions EnableDelayedExpansion
title LOTUS8 - FOG Client Installer
color 0A

rem ===== SETTINGS =====
set "SERVER=192.168.8.3"
set "WEBROOT=/fog"
set "RETRIES=3"
set "WORKDIR=%ProgramData%\LOTUS8-FOG"
set "MSI=%WORKDIR%\FOGService.msi"
set "LOG=%WORKDIR%\install.log"
set "MSILOG=%WORKDIR%\msi.log"
set "URL=http://%SERVER%%WEBROOT%/client/download.php?newclient"
set "CHECK=http://%SERVER%%WEBROOT%/service/getversion.php"
set "QUIET=0"
if /i "%~1"=="/q" set "QUIET=1"
set "RC=0"

rem ===== RUN FROM LOCAL COPY (UNC/network paths break elevation) =====
fltmc >nul 2>&1
if errorlevel 1 set "NEEDADMIN=1"
if "%~d0"=="\\" set "NEEDLOCAL=1"
if not exist "%WORKDIR%" mkdir "%WORKDIR%" >nul 2>&1
if defined NEEDLOCAL (
    echo Network path detected, copying installer to local disk...
    copy /y "%~f0" "%WORKDIR%\LOTUS8-FOG-Install.bat" >nul
    if errorlevel 1 (
        echo ERROR: cannot copy installer to %WORKDIR%
        if "%QUIET%"=="0" pause
        exit /b 1
    )
    set "SELF=%WORKDIR%\LOTUS8-FOG-Install.bat"
) else (
    set "SELF=%~f0"
)

rem ===== AUTO-ELEVATE (UAC) =====
if defined NEEDADMIN (
    echo Requesting administrator rights...
    if "%QUIET%"=="1" (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%SELF%' -ArgumentList '/q' -Verb RunAs"
    ) else (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%SELF%' -Verb RunAs"
    )
    if errorlevel 1 (
        echo ERROR: Administrator rights were not granted.
        if "%QUIET%"=="0" pause
    )
    exit /b
)
if defined NEEDLOCAL (
    rem already admin but started from a network path: continue from local copy
    cd /d "%WORKDIR%"
    call "%SELF%" %~1
    exit /b %ERRORLEVEL%
)
cd /d "%WORKDIR%" 2>nul || cd /d "%SystemRoot%"

call :LOG "===== start %DATE% %TIME% computer=%COMPUTERNAME% server=%SERVER% ====="

echo ==========================================
echo        LOTUS8 FOG CLIENT INSTALLER
echo ==========================================
echo Computer: %COMPUTERNAME%
echo Server:   %SERVER%
echo Work dir: %WORKDIR%
echo.

rem ===== 1. SERVER CHECK =====
echo [1/6] Checking server %SERVER% ...
set "OK=0"
for /l %%i in (1,1,%RETRIES%) do (
    if "!OK!"=="0" (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest '%CHECK%' -UseBasicParsing -TimeoutSec 10 | Out-Null; exit 0 } catch { Write-Host $_.Exception.Message; exit 1 }"
        if not errorlevel 1 (set "OK=1") else (
            echo   attempt %%i/%RETRIES% failed, waiting 5 sec...
            timeout /t 5 /nobreak >nul
        )
    )
)
if "!OK!"=="0" (
    set "RC=10"
    call :LOG "server check failed"
    goto FAIL
)
echo   OK

rem ===== 2. STOP / CLEAN OLD CLIENT =====
echo.
echo [2/6] Stopping old FOG client (if any)...
sc.exe query FOGService >nul 2>&1
if not errorlevel 1 (
    call :LOG "old FOGService found, stopping"
    sc.exe stop FOGService >nul 2>&1
    timeout /t 5 /nobreak >nul
)
taskkill /f /im FOGService.exe >nul 2>&1
taskkill /f /im FOGUserService.exe >nul 2>&1
taskkill /f /im FOGTray.exe >nul 2>&1
echo   done

rem ===== 3. DOWNLOAD =====
echo.
echo [3/6] Downloading FOG Client...
set "OK=0"
for /l %%i in (1,1,%RETRIES%) do (
    if "!OK!"=="0" (
        if exist "%MSI%" del /f /q "%MSI%" >nul 2>&1
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest '%URL%' -OutFile '%MSI%' -UseBasicParsing -TimeoutSec 180; exit 0 } catch { Write-Host $_.Exception.Message; exit 1 }"
        if errorlevel 1 (
            where curl.exe >nul 2>&1
            if not errorlevel 1 curl.exe -fsSL --max-time 180 -o "%MSI%" "%URL%"
        )
        call :VERIFYMSI
        if "!MSIOK!"=="1" (set "OK=1") else (
            echo   attempt %%i/%RETRIES% failed, waiting 5 sec...
            timeout /t 5 /nobreak >nul
        )
    )
)
if "!OK!"=="0" (
    set "RC=20"
    call :LOG "download failed or file is not a valid MSI"
    goto FAIL
)
echo   OK

rem ===== 4. INSTALL =====
echo.
echo [4/6] Installing FOG Client...
set "TRY=0"
:INSTALL
set /a TRY+=1
msiexec.exe /i "%MSI%" /qn /norestart WEBADDRESS=%SERVER% WEBROOT=%WEBROOT% USETRAY=0 /L*v "%MSILOG%"
set "RC=%ERRORLEVEL%"
call :LOG "msiexec try %TRY% exit code %RC%"
echo   MSI exit code: %RC%
if "%RC%"=="0" goto INSTALLED
if "%RC%"=="3010" goto INSTALLED
if "%RC%"=="1641" goto INSTALLED
if "%RC%"=="1618" if %TRY% LSS 5 (
    echo   another installation is running, waiting 30 sec...
    timeout /t 30 /nobreak >nul
    goto INSTALL
)
goto FAIL

:INSTALLED
set "RC=0"

rem ===== 5. SERVICE =====
echo.
echo [5/6] Configuring service...
sc.exe config FOGService start= auto >nul 2>&1
sc.exe failure FOGService reset= 86400 actions= restart/60000/restart/60000/restart/60000 >nul 2>&1
sc.exe start FOGService >nul 2>&1
set "RUNNING=0"
for /l %%i in (1,1,15) do (
    if "!RUNNING!"=="0" (
        sc.exe query FOGService | find "RUNNING" >nul 2>&1
        if not errorlevel 1 (set "RUNNING=1") else (
            sc.exe start FOGService >nul 2>&1
            timeout /t 2 /nobreak >nul
        )
    )
)

rem ===== 6. VERIFY =====
echo.
echo [6/6] Verifying...
sc.exe query FOGService
sc.exe qc FOGService | findstr /i "AUTO_START DEMAND_START DISABLED"
if "!RUNNING!"=="0" (
    set "RC=30"
    call :LOG "FOGService not running"
    goto FAIL
)
if exist "C:\fog.log" (echo   client log: C:\fog.log) else echo   client log not created yet - it appears after the first service cycle

call :LOG "SUCCESS"
echo.
echo ==========================================
echo       INSTALLATION FINISHED - OK
echo ==========================================
echo Install log: %LOG%
echo MSI log:     %MSILOG%
goto END

:FAIL
echo.
echo ==========================================
echo       INSTALLATION FAILED  (code %RC%)
echo ==========================================
echo   10 = server unreachable (check network / %SERVER%)
echo   20 = download failed or file is not an MSI
echo   30 = service did not start
echo   other = msiexec error, see MSI log
echo Install log: %LOG%
echo MSI log:     %MSILOG%
call :LOG "FAILED code %RC%"

:END
echo.
if "%QUIET%"=="0" (
    echo Press any key to close this window...
    pause >nul
)
exit /b %RC%

rem ===== SUBROUTINES =====
:LOG
>>"%LOG%" echo [%TIME%] %~1
exit /b 0

:VERIFYMSI
set "MSIOK=0"
if not exist "%MSI%" exit /b 0
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$f=[IO.File]::OpenRead('%MSI%'); try { $b=New-Object byte[] 4; [void]$f.Read($b,0,4); if ($f.Length -gt 500000 -and $b[0] -eq 0xD0 -and $b[1] -eq 0xCF -and $b[2] -eq 0x11 -and $b[3] -eq 0xE0) { exit 0 } else { exit 1 } } finally { $f.Close() }"
if not errorlevel 1 set "MSIOK=1"
exit /b 0
