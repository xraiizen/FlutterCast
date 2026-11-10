@echo off
echo =====================================
echo     Flutter + scrcpy (USB to WiFi)
echo =====================================

set "SCRCPY_EXE=%~dp0scrcpy-win64-v3.3.3\scrcpy.exe"
set PORT=5555

echo.
echo [CHECK] Checking dependencies...

REM Check adb
where adb >nul 2>nul
if errorlevel 1 (
    echo [ERROR] "adb" not found in PATH.
    echo Make sure Android platform-tools are installed and added to PATH.
    pause
    exit /b
)

REM Check flutter
where flutter >nul 2>nul
if errorlevel 1 (
    echo [ERROR] "flutter" not found in PATH.
    echo Make sure Flutter SDK is installed and added to PATH.
    pause
    exit /b
)

REM Check scrcpy
if not exist "%SCRCPY_EXE%" (
    echo [ERROR] scrcpy.exe not found at:
    echo         %SCRCPY_EXE%
    echo Please check SCRCPY_EXE path in this script.
    pause
    exit /b
)

echo [CHECK] All dependencies found.

echo.
echo [ADB] Starting ADB server...
adb start-server >nul

echo.
echo [ADB] Checking WiFi devices...

set WIFIID=

for /f "tokens=1" %%A in ('adb devices ^| findstr /R ":5555.*device"') do (
    set WIFIID=%%A
)

if not "%WIFIID%"=="" (
    echo [ADB] WiFi device: %WIFIID%
    set DEVICE_ID=%WIFIID%

    for /f "tokens=1 delims=:" %%B in ("%DEVICE_ID%") do set PHONE_IP=%%B

    goto WIFI_READY
)

echo [ADB] No WiFi device found. Using USB to WiFi process.

echo.
echo [ADB] Searching for USB device...

set USBID=

for /f "tokens=1" %%A in ('adb devices ^| findstr "device" ^| findstr /V ":" ^| findstr /V "List"') do (
    set USBID=%%A
)

if "%USBID%"=="" (
    echo [ERROR] No USB device detected.
    pause
    exit /b
)

echo [ADB] USB device: %USBID%

echo.
echo [ADB] Getting WiFi IP...

set PHONE_IP=

for /f "tokens=2 delims=: " %%A in ('adb -s %USBID% shell ip -f inet addr show wlan0 ^| findstr "inet " ') do (
    set PHONE_IP=%%A
)

for /f "tokens=1 delims=/" %%B in ("%PHONE_IP%") do set PHONE_IP=%%B

if "%PHONE_IP%"=="" (
    echo [ERROR] Unable to get WiFi IP.
    pause
    exit /b
)

echo [ADB] Phone IP: %PHONE_IP%

echo.
echo [ADB] Enabling TCP/IP mode...
adb -s %USBID% tcpip %PORT% >nul

echo [ADB] Connecting: adb connect %PHONE_IP%:%PORT%
adb connect %PHONE_IP%:%PORT%

set DEVICE_ID=%PHONE_IP%:%PORT%

echo.
echo Validate wireless debugging popup if shown.
echo Press ENTER when done.
pause >nul

echo.
echo [ADB] Checking WiFi connection...

set WIFI_CHECK=

for /f "tokens=1" %%A in ('adb devices ^| findstr /R "%PHONE_IP%:%PORT%.*device"') do (
    set WIFI_CHECK=%%A
)

if "%WIFI_CHECK%"=="" (
    echo [ERROR] WiFi connection failed.
    pause
    exit /b
)

echo [OK] WiFi connected.

:WIFI_READY
echo.
echo [OK] Active WiFi device: %DEVICE_ID%

echo.
echo [SCRCPY] Checking...

tasklist /FI "IMAGENAME eq scrcpy.exe" | find "scrcpy.exe" >nul
set SCRCPY_RUNNING=%ERRORLEVEL%

if "%SCRCPY_RUNNING%"=="1" (
    echo scrcpy not running. Starting...
    start "" "%SCRCPY_EXE%" -s %DEVICE_ID%
) else (
    echo scrcpy already running.
)

echo.
echo Running flutter on %DEVICE_ID% ...
flutter run -d %DEVICE_ID%

echo.
echo Flutter running. USB cable can be disconnected.
pause >nul
