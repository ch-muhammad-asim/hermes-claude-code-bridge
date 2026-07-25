# install-claude-bridge.ps1 - one-shot Windows bootstrap for the Claude Code Bridge.
#
# Installs everything a fresh Windows 10/11 box needs to expose an
# OpenAI-compatible endpoint backed by your authenticated Claude Code CLI:
#
#   1. Node.js LTS        (via winget, if missing)
#   2. Claude Code CLI    (npm i -g @anthropic-ai/claude-code)
#   3. The bridge service (per-user Scheduled Task, auto-starts at logon)
#
# It is idempotent - safe to re-run. Nothing here needs Administrator: the
# service runs as YOU so it inherits your interactive `claude` login.
#
# Usage (from this folder, in a normal PowerShell window):
#   .\install-claude-bridge.ps1              # full install + start the service
#   .\install-claude-bridge.ps1 -NoService   # install deps only, don't register the service
#
# After install, point any OpenAI-compatible client at:
#   http://127.0.0.1:18181/v1   (model: claude-opus-4-8)
param([switch]$NoService)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Info($m) { Write-Host "[install] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[ok]      $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[warn]    $m" -ForegroundColor Yellow }

function Test-Cmd($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

# --- 1. Python (the bridge is stdlib-only; any 3.8+ works) ------------------
if (-not (Test-Cmd python) -and -not (Test-Cmd py)) {
  Info "Python not found - installing via winget..."
  if (-not (Test-Cmd winget)) { Write-Error "winget unavailable. Install Python 3 from https://python.org and re-run." }
  winget install --id Python.Python.3.12 -e --source winget --accept-package-agreements --accept-source-agreements
  $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
}
Ok "Python present"

# --- 2. Node.js LTS ---------------------------------------------------------
if (-not (Test-Cmd node)) {
  Info "Node.js not found - installing LTS via winget..."
  if (-not (Test-Cmd winget)) { Write-Error "winget unavailable. Install Node.js LTS from https://nodejs.org and re-run." }
  winget install --id OpenJS.NodeJS.LTS -e --source winget --accept-package-agreements --accept-source-agreements
  $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
}
Ok "Node $(node --version)"

# --- 3. Claude Code CLI -----------------------------------------------------
if (-not (Test-Cmd claude)) {
  Info "Installing Claude Code CLI (npm i -g @anthropic-ai/claude-code)..."
  npm install -g "@anthropic-ai/claude-code@latest"
  $env:Path += ";" + (Join-Path $env:APPDATA "npm")
}
if (-not (Test-Cmd claude)) { Write-Error "``claude`` still not on PATH after install - open a new shell and re-run." }
Ok "Claude Code CLI present"

# --- 4. Authenticate --------------------------------------------------------
Info "Verifying Claude Code is authenticated..."
$authed = $false
try { claude --version *> $null; $authed = $true } catch { $authed = $false }
if (-not $authed) {
  Warn "Claude Code is not authenticated yet."
  Write-Host "     Run:  claude   (complete the browser login), then re-run this script." -ForegroundColor Yellow
  exit 1
}
Ok "Claude Code authenticated"

# --- 5. Register the bridge service -----------------------------------------
if ($NoService) {
  Info "-NoService set: skipping service registration."
  Write-Host "     Start the bridge manually with:  .\run-bridge.ps1" -ForegroundColor Yellow
} else {
  Info "Registering the bridge as an auto-start service (Scheduled Task)..."
  & (Join-Path $ScriptDir "run-bridge.ps1") install-service
}

Ok "Done. Endpoint: http://127.0.0.1:18181/v1  (model: claude-opus-4-8)"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  .\run-bridge.ps1 test            # health check + a live completion"
Write-Host "  .\run-bridge.ps1 service-status  # service state"
Write-Host "  .\run-bridge.ps1 logs            # tail the service log"
