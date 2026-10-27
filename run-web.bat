@echo off
setlocal enabledelayedexpansion

set PORT=3430
set GATEWAY_PORT=3425

:: Default: Bypass HTTP_PROXY so outbound connections go direct.
:: Pass USE_PROXY=1 if you want to use the environment's proxy.
if not "%USE_PROXY%"=="1" (
    echo ==^> Bypassing HTTP_PROXY ^(direct connection mode^)
    set HTTP_PROXY=
    set HTTPS_PROXY=
    set ALL_PROXY=
    set http_proxy=
    set https_proxy=
    set all_proxy=
    set NO_PROXY=*
    set no_proxy=*
) else (
    echo ==^> Using environment proxy settings
)

if "%MAGPIE_WEB_KEY%"=="" (
    set MAGPIE_WEB_KEY=magpie-web-admin-secret-key-1234
)

set MAGPIE_ADDR=0.0.0.0:%GATEWAY_PORT%

echo ==^> Checking Gateway API keys...
go run -tags nogui . gateway-key list

echo.
echo ==========================================================
echo Starting Magpie Web ^& Gateway on 0.0.0.0
echo Web UI:      http://0.0.0.0:%PORT%/?k=%MAGPIE_WEB_KEY%
echo Gateway API: http://0.0.0.0:%PORT%/v1 (or http://0.0.0.0:%GATEWAY_PORT%/v1)
echo Web UI Key:  %MAGPIE_WEB_KEY%
echo Proxy Mode:  Direct ^(bypassed^)
echo ==========================================================
echo.

go run -tags nogui . web --addr 0.0.0.0:%PORT% --no-open
