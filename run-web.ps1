param (
    [string]$Port = "3430",
    [string]$GatewayPort = "3425",
    [string]$WebKey = "",
    [switch]$NoOpen = $true,
    [switch]$UseProxy = $false
)

# By default, bypass HTTP proxy so Magpie connects directly to outbound APIs.
# Pass -UseProxy if you want to use the environment's HTTP_PROXY.
if (-not $UseProxy) {
    Write-Host "==> Bypassing HTTP_PROXY (direct connection mode)" -ForegroundColor DarkGray
    $env:HTTP_PROXY = ""
    $env:HTTPS_PROXY = ""
    $env:ALL_PROXY = ""
    $env:http_proxy = ""
    $env:https_proxy = ""
    $env:all_proxy = ""
    $env:NO_PROXY = "*"
    $env:no_proxy = "*"
} else {
    Write-Host "==> Using environment proxy settings" -ForegroundColor DarkGray
}
# Build this checkout once, and run that build. `go run` (what this script
# used) builds into a temporary folder Windows deletes when it exits, so
# nothing can point at it, and every run paid a full rebuild. A folder of
# the user's holds the program instead; magpie reads the settings it always
# had, and nothing beside the program makes it portable.
Write-Host "==> Building magpie (nogui) from $PSScriptRoot..." -ForegroundColor Cyan
if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    Write-Host "no go on PATH: install Go from https://go.dev/dl, which builds magpie from this checkout" -ForegroundColor Red
    exit 1
}
$BuildDir = Join-Path $env:LOCALAPPDATA "magpie-dev"
$Exe = Join-Path $BuildDir "magpie.exe"
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
Push-Location $PSScriptRoot
try {
    & go build -tags nogui -o "$Exe.new" .
    $built = $LASTEXITCODE
} finally {
    Pop-Location
}
if ($built -ne 0) {
    Remove-Item -Force "$Exe.new" -ErrorAction SilentlyContinue
    Write-Host "go build failed: nothing was replaced, $Exe is the last build that worked" -ForegroundColor Red
    exit 1
}
Move-Item -Force "$Exe.new" $Exe
# The magpie command, for this session's shells only: Settings > Command
# line is what puts it on the user's PATH for good.
if (($env:PATH -split ';') -notcontains $BuildDir) {
    $env:PATH = "$BuildDir;$env:PATH"
}
Write-Host "==> Program:             $Exe" -ForegroundColor DarkGray

# 1. Check or generate persistent Web UI key
if (-not $WebKey -and -not $env:MAGPIE_WEB_KEY) {
    # Generate a random 24-character key if none provided
    $bytes = New-Object byte[] 18
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $env:MAGPIE_WEB_KEY = [System.Convert]::ToBase64String($bytes).Replace('+', '-').Replace('/', '_').TrimEnd('=')
} elseif ($WebKey) {
    $env:MAGPIE_WEB_KEY = $WebKey
}

# 2. Bind the gateway address to 0.0.0.0
$env:MAGPIE_ADDR = "0.0.0.0:$GatewayPort"

# 3. Ensure a gateway API key exists for LAN/remote clients
Write-Host "==> Checking Gateway API keys..." -ForegroundColor Cyan
# `gateway-key list` prints a masked key per row and never a secret, so the
# header row alone means none is made yet. Looking for a key in that text
# found none it ever prints, and made one more on every run.
$existingKeys = (& $Exe gateway-key list 2>$null) | Out-String
$rows = @(($existingKeys -split "\r?\n") | Where-Object { $_.Trim() -ne "" }).Count - 1
if ($rows -lt 1) {
    Write-Host "==> Creating default gateway API key 'lan-client'..." -ForegroundColor Yellow
    & $Exe gateway-key add lan-client
} else {
    Write-Host $existingKeys
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
Write-Host " Starting Magpie Web & Gateway on 0.0.0.0" -ForegroundColor Green
Write-Host " Web UI URL:       http://0.0.0.0:$Port"
Write-Host " Gateway API URL:  http://0.0.0.0:$Port/v1 (or http://0.0.0.0:$GatewayPort/v1)"
Write-Host " Web UI Key:       $env:MAGPIE_WEB_KEY"
Write-Host " Proxy Mode:       $(if ($UseProxy) { 'Proxy' } else { 'Direct (bypassed)' })"
Write-Host "==========================================================" -ForegroundColor Green
Write-Host ""

$webArgs = @("web", "--addr", "0.0.0.0:$Port")
if ($NoOpen) {
    $webArgs += "--no-open"
}

& $Exe @webArgs
