# Update a running MyInvoice.cz Docker stack to the latest code.
#
#   1. Pulls (registry mode) or rebuilds (source mode) the app image
#   2. Restarts the stack
#   3. Waits for DB health and runs pending migrations
#
# Detects mode automatically - preferuje aktualne RUNNING stack:
#   1. Pokud bezi stack z `docker-compose.production.yml` -> registry mode
#      (GHCR pull, dale pouziva `-f docker-compose.production.yml`).
#   2. Pokud bezi stack z `docker-compose.yml` a je `.git/` + `build:` blok
#      -> source mode (git pull + local build).
#   3. Fallback bez bezicího stacku - podle existujicich souboru.
#
# Idempotent — safe to re-run. Volumes (DB data) persist; backup is your responsibility.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $ProjectRoot

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "docker not found in PATH"
}
& docker compose version > $null 2>&1
if ($LASTEXITCODE -ne 0) { Write-Error "'docker compose' (v2) plugin required" }
if (-not (Test-Path .env)) { Write-Error ".env not found - run docker-install.ps1 first" }

# Load .env into hashtable
$envVars = @{}
Get-Content .env | ForEach-Object {
    if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.*)\s*$') { $envVars[$Matches[1]] = $Matches[2] }
}

# Detect mode: registry vs source build.
# Priorita 1 — který compose file ma aktualne RUNNING stack (autoritativni):
#   - docker-compose.production.yml bezi -> registry mode (GHCR pull)
#   - docker-compose.yml bezi -> source mode (local build z .git)
# Priorita 2 — fallback podle existujicich souboru:
#   - jen docker-compose.production.yml -> registry
#   - jinak -> source (default)
$composeArgs = @()
$mode = 'registry'

$prodRunning = $false
$prodPs = & docker compose -f docker-compose.production.yml ps --format json app 2>$null
if ($LASTEXITCODE -eq 0 -and $prodPs -match '"State":\s*"running"') { $prodRunning = $true }

$devRunning = $false
$devPs = & docker compose ps --format json app 2>$null
if ($LASTEXITCODE -eq 0 -and $devPs -match '"State":\s*"running"') { $devRunning = $true }

if ($prodRunning) {
    $composeArgs = @('-f', 'docker-compose.production.yml')
    $mode = 'registry'
} elseif ($devRunning -and (Test-Path .git) -and (Select-String -Path docker-compose.yml -Pattern '^\s*build:' -Quiet)) {
    $mode = 'source'
} elseif ((Test-Path docker-compose.production.yml) -and (-not (Test-Path .git))) {
    $composeArgs = @('-f', 'docker-compose.production.yml')
    $mode = 'registry'
} elseif ((Test-Path .git) -and (Select-String -Path docker-compose.yml -Pattern '^\s*build:' -Quiet)) {
    $mode = 'source'
}

$composeFileLabel = if ($composeArgs.Count -gt 0) { " (compose: $($composeArgs[1]))" } else { '' }
Write-Host "==> Mode: $mode$composeFileLabel"

# --- 1. fetch new code/image ---------------------------------------------
if ($mode -eq 'source') {
    $dirty = & git status --porcelain
    if ($dirty) {
        Write-Warning "Working tree is dirty - local changes won't be pulled."
        Write-Warning "Consider 'git stash' or commit first. Continuing in 5s..."
        Start-Sleep -Seconds 5
    }
    Write-Host "==> git pull"
    & git pull --ff-only
    if ($LASTEXITCODE -ne 0) { Write-Error "git pull failed" }
    Write-Host "==> Rebuilding app image..."
    & docker compose @composeArgs build --pull app
    if ($LASTEXITCODE -ne 0) { Write-Error "docker compose build failed" }
} else {
    Write-Host "==> Pulling latest image from registry..."
    & docker compose @composeArgs pull app
    if ($LASTEXITCODE -ne 0) { Write-Error "docker compose pull failed" }
}

# --- 2. restart ----------------------------------------------------------
Write-Host "==> Restarting stack..."
& docker compose @composeArgs up -d db app
if ($LASTEXITCODE -ne 0) { Write-Error "docker compose up failed" }

# --- 3. wait for DB + migrate -------------------------------------------
Write-Host "==> Waiting for database to become healthy..."
$ready = $false
for ($i = 1; $i -le 30; $i++) {
    $json = & docker compose @composeArgs ps --format json db 2>$null
    if ($json -match '"Health":"healthy"') { $ready = $true; Write-Host "    DB ready."; break }
    Start-Sleep -Seconds 2
}
if (-not $ready) {
    Write-Error "DB failed to become healthy in 60s. Check 'docker compose logs db'."
}

# Migrace bezi automaticky z docker-entrypoint.sh pred apache2-foreground.
# Misto druheho explicitniho migrate (= race condition s entrypointem) cekame,
# az app odpovi na /api/health (v ALLOWED_PATHS pro FirstRunLockMiddleware).
$curl = (Get-Command curl.exe -ErrorAction SilentlyContinue)?.Source
if (-not $curl) { $curl = 'C:\Windows\System32\curl.exe' }
if (-not (Test-Path $curl)) {
    Write-Error "curl.exe nenalezen (potreba na Win 10/11+). Updatuj OS nebo doinstaluj curl."
}

$port = $envVars.APP_PORT
if (-not $port) { $port = '8080' }
Write-Host "==> Waiting for app to become available (entrypoint runs migrations)..."
$appReady = $false
$lastErr = ''
for ($i = 1; $i -le 60; $i++) {
    $out = & $curl -fsS -m 3 -o NUL "http://localhost:$port/api/health" 2>&1
    if ($LASTEXITCODE -eq 0) { $appReady = $true; Write-Host "    App ready."; break }
    $lastErr = ($out | Out-String).Trim()
    Start-Sleep -Seconds 2
}
if (-not $appReady) {
    Write-Host "    Last curl error: $lastErr" -ForegroundColor Yellow
    Write-Error "App failed to respond in 120s. Check 'docker compose @composeArgs logs app'."
}

# --- 4. report -----------------------------------------------------------
Write-Host ""
Write-Host "============================================================"
Write-Host " Update complete. App: http://localhost:$port"
Write-Host ""
Write-Host " Tail logs:        docker compose logs -f app"
Write-Host " Restart only:     docker compose restart app"
Write-Host "============================================================"
