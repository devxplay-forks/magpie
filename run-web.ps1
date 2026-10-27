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
$existingKeys = (go run -tags nogui . gateway-key list 2>$null) | Out-String
if ($existingKeys -notmatch "mgp-") {
    Write-Host "==> Creating default gateway API key 'lan-client'..." -ForegroundColor Yellow
    go run -tags nogui . gateway-key add lan-client
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

$webArgs = @("run", "-tags", "nogui", ".", "web", "--addr", "0.0.0.0:$Port")
if ($NoOpen) {
    $webArgs += "--no-open"
}

go @webArgs
