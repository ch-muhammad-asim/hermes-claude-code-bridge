# run-bridge.ps1 - launcher + service installer for the Claude Code Bridge (Windows).
#
# No Docker. Runs the stdlib-only Python bridge directly against an
# already-authenticated `claude`. macOS/Linux users: see ../mac or ../ubuntu-desktop.
#
# Usage:
#   .\run-bridge.ps1                  # run in the foreground (default 127.0.0.1:18181)
#   .\run-bridge.ps1 test             # GET /health + a chat completion
#   .\run-bridge.ps1 selfcheck        # offline logic checks (no claude needed)
#   .\run-bridge.ps1 install-service  # register + start a persistent auto-start service
#   .\run-bridge.ps1 uninstall-service
#   .\run-bridge.ps1 service-status
#   .\run-bridge.ps1 logs             # tail the service log
#
# The "service" is a per-user Scheduled Task that starts at logon, restarts on
# failure, and runs hidden - so it inherits your authenticated Claude Code login.
#
# Config via environment variables (baked into the task at install):
#   BRIDGE_HOST (default 127.0.0.1)  BRIDGE_PORT (default 18181)
#   CLAUDE_CODE_BRIDGE_MODEL (default claude-opus-5)
#   CLAUDE_CODE_BRIDGE_API_KEY (empty -> unauthenticated)   CLAUDE_BIN (override claude path)
param([string]$Command = "run")

$ErrorActionPreference = "Stop"
$ScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir = Split-Path -Parent $ScriptPath
$Bridge    = Join-Path $ScriptDir "claude_code_bridge.py"
$TaskName  = "ClaudeCodeBridge"
$LogFile   = if ($env:CLAUDE_CODE_BRIDGE_LOG) { $env:CLAUDE_CODE_BRIDGE_LOG } else { Join-Path $HOME ".claude-code-bridge.log" }
$BridgeCwd = if ($env:CLAUDE_CODE_BRIDGE_CWD) { $env:CLAUDE_CODE_BRIDGE_CWD } elseif ($env:CLAUDE_CODE_PROXY_CWD) { $env:CLAUDE_CODE_PROXY_CWD } else { $HOME }
$MaxConcurrency = if ($env:CLAUDE_CODE_BRIDGE_MAX_CONCURRENCY) { $env:CLAUDE_CODE_BRIDGE_MAX_CONCURRENCY } else { "4" }
$QueueWait = if ($env:CLAUDE_CODE_BRIDGE_QUEUE_WAIT) { $env:CLAUDE_CODE_BRIDGE_QUEUE_WAIT } else { "30" }

$Py  = Get-Command python -ErrorAction SilentlyContinue
if (-not $Py) { $Py = Get-Command py -ErrorAction SilentlyContinue }
if (-not $Py) { Write-Error "python not found on PATH"; exit 1 }
$Py  = $Py.Source

$BridgeHost = if ($env:BRIDGE_HOST) { $env:BRIDGE_HOST } else { "127.0.0.1" }
$Port  = if ($env:BRIDGE_PORT) { $env:BRIDGE_PORT } else { "18181" }
$Model = if ($env:CLAUDE_CODE_BRIDGE_MODEL) { $env:CLAUDE_CODE_BRIDGE_MODEL } else { "claude-opus-5" }
$ApiKey = $env:CLAUDE_CODE_BRIDGE_API_KEY

function Bridge-Args {
  $a = @($Bridge, "--host", $BridgeHost, "--port", $Port, "--model", $Model, "--cwd", $BridgeCwd, "--max-concurrency", $MaxConcurrency, "--queue-wait", $QueueWait)
  if ($env:CLAUDE_BIN) { $a += @("--claude-bin", $env:CLAUDE_BIN) }
  if ($ApiKey)         { $a += @("--api-key", $ApiKey) }
  return $a
}

function Quote-Argument([string]$Value) {
  "'" + $Value.Replace("'", "''") + "'"
}

function Print-Config {
  $claude = if ($env:CLAUDE_BIN) { $env:CLAUDE_BIN } else { (Get-Command claude -ErrorAction SilentlyContinue).Source }
  $allowed = if ($env:CLAUDE_CODE_ALLOWED_TOOLS) { $env:CLAUDE_CODE_ALLOWED_TOOLS } else { "*" }
  $disallowed = if ($env:CLAUDE_CODE_DISALLOWED_TOOLS) { $env:CLAUDE_CODE_DISALLOWED_TOOLS } else { "(empty)" }
  $mode = if ($env:CLAUDE_CODE_PERMISSION_MODE) { $env:CLAUDE_CODE_PERMISSION_MODE } else { "bypassPermissions" }
  Write-Host "[bridge] config:"
  Write-Host "  endpoint:        http://${BridgeHost}:${Port}/v1"
  Write-Host "  model:           $Model"
  Write-Host "  cwd:             $BridgeCwd"
  Write-Host "  claude:          $claude"
  Write-Host "  max concurrency: $MaxConcurrency"
  Write-Host "  queue wait:      ${QueueWait}s"
  Write-Host "  api key:         $(if ($ApiKey) { 'required' } else { 'not required' })"
  Write-Host "  tools:           allowed=$allowed disallowed=$disallowed permission_mode=$mode"
}

function Require-Claude {
  if (-not (Get-Command claude -ErrorAction SilentlyContinue) -and -not $env:CLAUDE_BIN) {
    Write-Error "``claude`` not on PATH - authenticate Claude Code first, or set CLAUDE_BIN"; exit 1
  }
}

function Show-Help {
  Get-Content -Path $ScriptPath | ForEach-Object {
    if ($_ -match '^# ?(.*)$') { $Matches[1] }
    elseif ($_ -match '^param') { break }
  }
}

switch ($Command) {
  "help" { Show-Help }

  "run" {
    Require-Claude
    Write-Host "[bridge] starting on ${BridgeHost}:${Port} (model=$Model)"
    Print-Config
    & $Py @(Bridge-Args)
  }

  "test" {
    $headers = @{}; if ($ApiKey) { $headers["Authorization"] = "Bearer $ApiKey" }
    Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -Headers $headers | ConvertTo-Json -Compress
    $body = @{ model = $Model; stream = $false
               messages = @(@{ role = "user"; content = "Reply with exactly: claude code bridge ok" }) } | ConvertTo-Json
    Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/chat/completions" -Method Post `
      -Headers $headers -ContentType "application/json" -Body $body | ConvertTo-Json -Depth 6
  }

  "selfcheck" { $env:BRIDGE_SELFCHECK = "1"; & $Py $Bridge }

  "install-service" {
    Require-Claude
    # Always launch through a hidden PowerShell wrapper so stdout/stderr go to
    # the same log file on every Windows install, including pythonw machines.
    $argLine = (Bridge-Args | ForEach-Object { Quote-Argument $_ }) -join ' '
    $exe = "powershell.exe"
    $innerCommand = '& ' + (Quote-Argument $Py) + ' ' + $argLine + ' *>> ' + (Quote-Argument $LogFile)
    # -EncodedCommand, not -Command: powershell.exe's NATIVE argument parser treats
    # only double quotes as quoting, so a single-quoted -Command payload arrives as
    # one string LITERAL — PowerShell echoes it and exits 0, the bridge never starts,
    # and the task's on-failure restarts never fire. Base64 (UTF-16LE) survives Task
    # Scheduler's command line untouched and is parsed by PowerShell itself.
    $encoded   = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($innerCommand))
    $arguments = '-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
    $action   = New-ScheduledTaskAction -Execute $exe -Argument $arguments -WorkingDirectory $ScriptDir
    $trigger  = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                  -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
                  -ExecutionTimeLimit ([TimeSpan]::Zero)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
      -Settings $settings -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "[bridge] scheduled-task service '$TaskName' registered + started"
    Write-Host "[bridge] logs: $LogFile"
    Print-Config
    # First boot can take a few seconds (interpreter start + `claude --version` probe).
    $ok = $false
    foreach ($i in 1..30) {
      try { Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2 | ConvertTo-Json -Compress; $ok = $true; break }
      catch { Start-Sleep -Milliseconds 500 }
    }
    if (-not $ok) { Write-Host "[bridge] (service installed; health not ready yet - check the log)" }
  }

  "uninstall-service" {
    Stop-ScheduledTask   -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "[bridge] scheduled-task service '$TaskName' removed"
  }

  "service-status" {
    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue |
      Get-ScheduledTaskInfo | Format-List TaskName, LastRunTime, LastTaskResult, NextRunTime
    (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue).State
  }

  "logs" { if (Test-Path $LogFile) { Get-Content -Path $LogFile -Tail 40 -Wait } else { Write-Host "no log yet: $LogFile" } }

  default { Write-Host "unknown command: $Command (use: run | test | selfcheck | install-service | uninstall-service | service-status | logs)"; exit 1 }
}
