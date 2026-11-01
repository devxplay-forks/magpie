<#
service.ps1 - build magpie from this checkout and run it as a Windows service.

One command does everything:

    .\service.ps1              deploy: build, swap the exe, restart, verify
    .\service.ps1 status
    .\service.ps1 logs
    .\service.ps1 restart
    .\service.ps1 stop
    .\service.ps1 start
    .\service.ps1 key          new admin key, restart, print the link
    .\service.ps1 uninstall

Why this script exists: magpie has no Windows service support of its own.
internal/daemon/daemon.go returns "unsupported" on Windows and points at
`magpie autostart on` (an HKCU Run value, which needs an interactive session)
or at WSL. So the service is NSSM's, and this script owns every NSSM setting.
That keeps the repo free of the running exe and of the service logs.

Why the exe is swapped rather than overwritten: Windows will not overwrite or
delete a running image, so `go build` onto the live path fails. The new build
is written beside the old one and renamed into place once the service stops.
magpie's own updater does the same rename (internal/update/update.go).

Why NSSM rotation is off: with AppRotateFiles on, NSSM starts a NEW log file at
every service start, so a log would be split on every deploy. This script keeps
one continuous file and rotates it by size instead, in Trim-Log.

If PowerShell refuses to run the script:
    powershell -ExecutionPolicy Bypass -File .\service.ps1
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('deploy', 'status', 'logs', 'restart', 'stop', 'start', 'key', 'uninstall')]
    [string]$Command = 'deploy',

    [string]$Service = 'MagpieWeb',
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\magpie'),
    [string]$LogDir = (Join-Path $env:LOCALAPPDATA 'magpie\logs'),
    [string]$WebAddr = '0.0.0.0:3430',
    [string]$GatewayAddr = '0.0.0.0:3425',
    [switch]$UseProxy
)

$ErrorActionPreference = 'Stop'

$ExeName = 'magpie.exe'
$NewName = 'magpie.new.exe'
$OldName = 'magpie.exe.prev'
$BuildTags = 'nogui'
$MaxLogBytes = 10MB

# Get-Nssm is the nssm.exe this machine has: on PATH, or the WinGet link.
function Get-Nssm {
    $cmd = Get-Command nssm -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\nssm.exe'
    if (Test-Path $fallback) { return $fallback }
    throw 'nssm not found: install it (winget install NSSM.NSSM) or put nssm.exe on PATH'
}

# Invoke-NssmRaw runs nssm without turning its own output into an error. nssm
# reports a normal state change ("SERVICE_START_PENDING in response to START
# control") on stderr, and PowerShell 5.1 turns a native command's stderr into a
# terminating error while $ErrorActionPreference is Stop.
function Invoke-NssmRaw {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$NssmArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & (Get-Nssm) @NssmArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ Output = (($out | Out-String).Trim()); Code = $code }
}

# Invoke-Nssm runs nssm and turns a real failure into the reason it gave.
function Invoke-Nssm {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$NssmArgs)
    $r = Invoke-NssmRaw @NssmArgs
    if ($r.Code -ne 0) {
        throw ('nssm ' + ($NssmArgs -join ' ') + ' failed: ' + $r.Output)
    }
    return $r.Output
}

function Get-ServiceState {
    if (-not (Get-Service -Name $Service -ErrorAction SilentlyContinue)) { return 'NOT_INSTALLED' }
    return (Invoke-NssmRaw status $Service).Output
}

function Test-Installed { return (Get-ServiceState) -ne 'NOT_INSTALLED' }
function Test-Running { return (Get-ServiceState) -match 'RUNNING' }

function Initialize-Dirs {
    foreach ($d in @($InstallDir, $LogDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
}

# Get-WebKey reads the key the service already has, so a deploy never changes
# the link the user has open. Empty when the service has no key yet.
function Get-WebKey {
    if (-not (Test-Installed)) { return '' }
    $raw = (Invoke-NssmRaw get $Service AppEnvironmentExtra).Output
    $m = [regex]::Match($raw, 'MAGPIE_WEB_KEY=([A-Za-z0-9._~\-]+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

# New-WebKey is 32 hex characters: magpie takes 16+ of letters, digits, - . _ ~
function New-WebKey { return [guid]::NewGuid().ToString('N') }
# The key follows run-web.bat exactly, so the two scripts never disagree about
# which key is live: MAGPIE_WEB_KEY from this shell when it is set, otherwise
# the same default that script falls back to.
$DefaultWebKey = 'magpie-web-admin-secret-key-1234'

function Resolve-WebKey {
    if ($env:MAGPIE_WEB_KEY) {
        return [pscustomobject]@{ Key = $env:MAGPIE_WEB_KEY; From = 'MAGPIE_WEB_KEY in this shell' }
    }
    return [pscustomobject]@{ Key = $DefaultWebKey; From = 'the default key' }
}

function Set-ServiceEnv {
    param([string]$Name, [string]$Value)
    Invoke-Nssm set $Service AppEnvironmentExtra ('+' + $Name + '=' + $Value) | Out-Null
}

# Initialize-Service writes every NSSM setting, every time. It creates the
# service only when it is absent, so a second run updates rather than fails,
# and a path that drifted is put back by the next deploy.
function Initialize-Service {
    param([string]$Key)
    $exe = Join-Path $InstallDir $ExeName
    if (-not (Test-Installed)) { Invoke-Nssm install $Service $exe | Out-Null }

    Invoke-Nssm set $Service Application $exe | Out-Null
    Invoke-Nssm set $Service AppDirectory $InstallDir | Out-Null
    Invoke-Nssm set $Service AppParameters ('web --addr ' + $WebAddr + ' --no-open') | Out-Null
    Invoke-Nssm set $Service AppStdout (Join-Path $LogDir 'service.log') | Out-Null
    Invoke-Nssm set $Service AppStderr (Join-Path $LogDir 'service-err.log') | Out-Null
    Invoke-Nssm set $Service AppRotateFiles 0 | Out-Null
    Invoke-Nssm set $Service AppRotateOnline 0 | Out-Null
    Invoke-Nssm set $Service AppThrottle 5000 | Out-Null
    Invoke-Nssm set $Service AppExit Default Restart | Out-Null
    Invoke-Nssm set $Service Start SERVICE_AUTO_START | Out-Null
    Invoke-Nssm set $Service ObjectName LocalSystem | Out-Null
    Invoke-Nssm set $Service DisplayName $Service | Out-Null
    Invoke-Nssm set $Service Description 'Magpie Web UI and LLM Gateway Service' | Out-Null

    # reset first so the block is rewritten, not appended to on every deploy
    Invoke-Nssm reset $Service AppEnvironmentExtra | Out-Null
    Set-ServiceEnv 'MAGPIE_ADDR' $GatewayAddr
    Set-ServiceEnv 'MAGPIE_WEB_KEY' $Key
    Set-ServiceEnv 'HOME' $env:USERPROFILE
    Set-ServiceEnv 'USERPROFILE' $env:USERPROFILE
    Set-ServiceEnv 'NO_PROXY' '*'
    Set-ServiceEnv 'no_proxy' '*'
    if (-not $UseProxy) {
        foreach ($v in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')) {
            Set-ServiceEnv $v ''
        }
    }
}

# Build-Exe writes the new build beside the installed one, never onto it: the
# installed exe is the image the service is running, and Windows holds it.
function Build-Exe {
    $out = Join-Path $InstallDir $NewName
    Push-Location $PSScriptRoot
    try {
        & go build -tags $BuildTags -o $out .
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($code -ne 0) {
        throw ('go build failed (exit ' + $code + '): the service still runs the previous version')
    }
    if (-not (Test-Path $out)) { throw ('go build wrote no file at ' + $out) }
    return $out
}

# Trim-Log rotates by size, once, before the service starts. NSSM's own
# rotation is off because it splits the log at every start.
function Trim-Log {
    foreach ($name in @('service.log', 'service-err.log')) {
        $p = Join-Path $LogDir $name
        if (-not (Test-Path $p)) { continue }
        if ((Get-Item $p).Length -lt $MaxLogBytes) { continue }
        $stamp = (Get-Date).ToString('yyyyMMddTHHmmss')
        $base = [IO.Path]::GetFileNameWithoutExtension($name)
        Move-Item -Path $p -Destination (Join-Path $LogDir ($base + '-' + $stamp + '.log')) -Force
    }
}

# Swap-Exe puts the new build in place. The previous one is kept as
# magpie.exe.prev, not magpie.exe.old: magpie deletes the .old and .old-N
# names at startup (update.RemoveOld, internal/update/update.go), so a
# backup under that name would be gone before anyone could roll back.
function Swap-Exe {
    $exe = Join-Path $InstallDir $ExeName
    $new = Join-Path $InstallDir $NewName
    $old = Join-Path $InstallDir $OldName
    if (Test-Path $old) { Remove-Item $old -Force -ErrorAction SilentlyContinue }
    if (Test-Path $exe) { Move-Item -Path $exe -Destination $old -Force }
    Move-Item -Path $new -Destination $exe -Force
}

function Stop-Magpie {
    if (-not (Test-Installed)) { return }
    if (-not (Test-Running)) { return }
    $null = Invoke-NssmRaw stop $Service
    for ($i = 0; $i -lt 120; $i++) {
        if ((Get-ServiceState) -match 'STOPPED') { return }
        Start-Sleep -Milliseconds 500
    }
    throw 'the service did not reach SERVICE_STOPPED'
}

function Start-Magpie {
    if (-not (Test-Installed)) { throw 'the service is not installed: run .\service.ps1 first' }
    if (-not (Test-Running)) { $null = Invoke-NssmRaw start $Service }
    for ($i = 0; $i -lt 120; $i++) {
        if ((Get-ServiceState) -match 'RUNNING') { return }
        Start-Sleep -Milliseconds 500
    }
    throw 'the service did not reach SERVICE_RUNNING'
}

# Wait-Healthy asks the gateway, through magpie's own healthcheck, whether the
# new build actually serves. A build that starts but cannot serve is a failure.
function Wait-Healthy {
    $exe = Join-Path $InstallDir $ExeName
    for ($i = 0; $i -lt 30; $i++) {
        & $exe healthcheck 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Show-Status {
    param([string]$KeyFrom = '')
    $key = Get-WebKey
    $port = ($WebAddr -split ':')[-1]
    Write-Host ('service    ' + $Service)
    Write-Host ('state      ' + (Get-ServiceState))
    Write-Host ('exe        ' + (Join-Path $InstallDir $ExeName))
    Write-Host ('logs       ' + $LogDir)
    if ($key) {
        $from = ''
        if ($KeyFrom) { $from = '  (' + $KeyFrom + ')' }
        Write-Host ('page       http://127.0.0.1:' + $port + '/?k=' + $key)
        Write-Host ('login key  ' + $key + $from)
        Write-Host ('gateway    http://127.0.0.1:3425/v1')
        Write-Host ('key change $env:MAGPIE_WEB_KEY=''<16+ chars>''; .\service.ps1')
        Write-Host ('           cmd: set MAGPIE_WEB_KEY=<16+ chars>  then  .\service.ps1')
    } else {
        Write-Host 'page       (no key yet: run .\service.ps1 key)'
    }
}

# Deploy builds first and stops the service second, so a build that fails
# never takes the daemon down.
function Deploy {
    Initialize-Dirs
    $null = Build-Exe

    $resolved = Resolve-WebKey
    Initialize-Service -Key $resolved.Key

    Stop-Magpie
    Trim-Log
    Swap-Exe
    Start-Magpie

    if (-not (Wait-Healthy)) {
        Write-Warning ('the gateway did not answer. The previous build is at ' + (Join-Path $InstallDir $OldName))
        Show-Status -KeyFrom $resolved.From
        return
    }
    Show-Status -KeyFrom $resolved.From
}

switch ($Command) {
    'deploy' { Deploy }
    'status' { Show-Status }
    'logs' { Get-Content (Join-Path $LogDir 'service-err.log') -Tail 40 -Wait }
    'restart' { Stop-Magpie; Start-Magpie; Show-Status }
    'stop' { Stop-Magpie; Write-Host 'stopped' }
    'start' { Start-Magpie; Show-Status }
    'key' {
        if (-not (Test-Installed)) { throw 'the service is not installed: run .\service.ps1 first' }
        Initialize-Service -Key (New-WebKey)
        Stop-Magpie
        Start-Magpie
        Show-Status -KeyFrom 'a new random key'
    }
    'uninstall' {
        if (Test-Installed) {
            Stop-Magpie
            Invoke-Nssm remove $Service confirm | Out-Null
        }
        if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
        Write-Host ('service removed. Kept: ' + $LogDir + ' and ' + (Join-Path $env:USERPROFILE '.config\magpie'))
    }
}
