<#
.SYNOPSIS
  Starts a local Krodin dedicated server plus headless bots that each play
  with a random simulated latency, so you can join and test a "real" match.

.DESCRIPTION
  Each bot (bin\krodin_netbot.exe) connects over TCP like a normal client,
  wanders, aims at the nearest enemy and shoots. Every packet it sends and
  receives is held for half of its simulated round trip, so the server sees
  each bot at roughly its latency (a random value between -MinLatency and
  -MaxLatency, plus a little jitter). Bots report their measured ping.

  Join from Krodin: Join -> paste  tcp://127.0.0.1:21015  (or your LAN IP for
  another PC; use -Port to change it). Press Ctrl+C here to stop everything.
  Logs go to logs\bot-test\.

.EXAMPLE
  .\tools\server-bot-test.ps1
  .\tools\server-bot-test.ps1 -Bots 7 -MinLatency 20 -MaxLatency 60 -TickRate 128
  .\tools\server-bot-test.ps1 -NoServer -HostName 192.168.1.20   # bots only, join a server elsewhere
#>
param(
    [ValidateRange(1, 15)] [int] $Bots = 6,
    # How well the bots aim: easy (default), normal or hard.
    [ValidateSet("easy", "normal", "hard")] [string] $Difficulty = "easy",
    # Input commands per second each bot sends (a player's netRate).
    [ValidateRange(1, 360)] [int] $BotRate = 64,
    [ValidateRange(0, 1000)] [int] $MinLatency = 20,
    [ValidateRange(0, 1000)] [int] $MaxLatency = 60,
    [ValidateRange(0, 200)] [int] $Jitter = 2,
    [ValidateRange(30, 128)] [int] $TickRate = 64,
    [ValidateRange(1, 65535)] [int] $Port = 21015,
    [string] $HostName = "127.0.0.1",
    [int] $Seed = 0,
    # Seconds to run before stopping on its own; 0 runs until Ctrl+C.
    [ValidateRange(0, 86400)] [int] $Duration = 0,
    # Rebuild krodin_server.exe and krodin_netbot.exe first (-o:speed).
    [switch] $Build,
    # Only start bots, against a server that is already running at -HostName.
    [switch] $NoServer
)

$ErrorActionPreference = "Stop"
if ($MaxLatency -lt $MinLatency) { throw "-MaxLatency ($MaxLatency) must be at least -MinLatency ($MinLatency)." }

$root = Split-Path -Parent $PSScriptRoot
$serverExe = Join-Path $root "bin\krodin_server.exe"
$botExe = Join-Path $root "bin\krodin_netbot.exe"
$logDir = Join-Path $root "logs\bot-test"
New-Item -ItemType Directory -Force $logDir | Out-Null

if ($Build -or -not (Test-Path $botExe) -or (-not $NoServer -and -not (Test-Path $serverExe))) {
    Push-Location $root
    try {
        if (-not $NoServer) {
            Write-Host "Building server..."
            cmd /c "call .\build.bat server speed"
            if ($LASTEXITCODE -ne 0) { throw "Server build failed." }
        }
        Write-Host "Building bots..."
        cmd /c "call .\build.bat bots speed"
        if ($LASTEXITCODE -ne 0) { throw "Bot build failed." }
    } finally { Pop-Location }
}

$random = if ($Seed -ne 0) { [System.Random]::new($Seed) } else { [System.Random]::new() }
$started = New-Object System.Collections.Generic.List[System.Diagnostics.Process]
$botInfo = @()

function Stop-Started {
    foreach ($p in $started) {
        if (-not $p.HasExited) { try { $p.Kill() } catch {} }
    }
}

function Last-Line([string] $path, [string] $pattern) {
    if (-not (Test-Path $path)) { return $null }
    $line = Select-String -Path $path -Pattern $pattern -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($line) { return $line.Line.Trim() } else { return $null }
}

function Test-Listening([string] $hostName, [int] $port) {
    $tcp = [System.Net.Sockets.TcpClient]::new()
    try { $tcp.Connect($hostName, $port); return $true } catch { return $false } finally { $tcp.Dispose() }
}

try {
    # A server already running on this port (e.g. one you started yourself)
    # would make ours fail with "address in use": add the bots to it instead.
    if (-not $NoServer -and (Test-Listening "127.0.0.1" $Port)) {
        Write-Host "A server is already running on port $Port; adding the bots to it instead of starting another."
        $NoServer = $true
        $HostName = "127.0.0.1"
    }

    if (-not $NoServer) {
        $serverLog = Join-Path $logDir "server.log"
        $serverArgs = @("--bind", "0.0.0.0", "--port", $Port, "--tick-rate", $TickRate, "--max-players", ($Bots + 2), "--stats-interval", 10)
        $server = Start-Process -FilePath $serverExe -ArgumentList $serverArgs -WorkingDirectory $root -NoNewWindow -PassThru `
            -RedirectStandardOutput $serverLog -RedirectStandardError (Join-Path $logDir "server.err.log")
        $started.Add($server)
        Write-Host ("Server started at {0} tick on port {1} (log: {2})" -f $TickRate, $Port, $serverLog)

        # Wait until it accepts connections (up to 15 s).
        $deadline = (Get-Date).AddSeconds(15)
        $ready = $false
        while ((Get-Date) -lt $deadline -and -not $server.HasExited) {
            if (Test-Listening "127.0.0.1" $Port) { $ready = $true; break }
            Start-Sleep -Milliseconds 250
        }
        if (-not $ready) { throw "The server did not start listening on port $Port. See $serverLog" }
    }

    for ($i = 1; $i -le $Bots; $i++) {
        $latency = $random.Next($MinLatency, $MaxLatency + 1)
        $name = "bot$i"
        $log = Join-Path $logDir "$name.log"
        $botArgs = @("--host", $HostName, "--port", $Port, "--latency", $latency, "--jitter", $Jitter,
            "--seed", $random.Next(1, [int]::MaxValue), "--name", $name, "--report", 10, "--difficulty", $Difficulty, "--rate", $BotRate)
        $p = Start-Process -FilePath $botExe -ArgumentList $botArgs -WorkingDirectory $root -NoNewWindow -PassThru `
            -RedirectStandardOutput $log -RedirectStandardError (Join-Path $logDir "$name.err.log")
        $started.Add($p)
        $botInfo += [pscustomobject]@{ Name = $name; Latency = $latency; Process = $p; Log = $log }
        Start-Sleep -Milliseconds 150
    }

    Write-Host ""
    Write-Host "Bots ($Difficulty, $BotRate Hz commands, simulated round-trip latency):"
    $botInfo | ForEach-Object { Write-Host ("  {0}: {1} ms" -f $_.Name, $_.Latency) }
    Write-Host ""
    Write-Host "Join from Krodin: Join -> tcp://127.0.0.1:$Port  (other PCs: tcp://<this PC's LAN IP>:$Port)"
    Write-Host "Press Ctrl+C to stop. Status every 10 s; full logs in $logDir"

    $start = Get-Date
    while ($true) {
        Start-Sleep -Seconds 10
        Write-Host ("--- {0:hh\:mm\:ss} ---" -f ((Get-Date) - $start))
        if (-not $NoServer) {
            if ($server.HasExited) { Write-Host "Server exited (code $($server.ExitCode)). See $serverLog"; break }
            $stats = Last-Line $serverLog "\[Tick\]"
            if ($stats) { Write-Host "  server: $stats" }
        }
        $alive = 0
        foreach ($b in $botInfo) {
            if ($b.Process.HasExited) { Write-Host ("  {0}: stopped (see {1})" -f $b.Name, $b.Log); continue }
            $alive++
            $status = Last-Line $b.Log "ping"
            if ($status) { Write-Host "  $status" }
        }
        if ($alive -eq 0) { Write-Host "All bots stopped."; break }
        if ($Duration -gt 0 -and ((Get-Date) - $start).TotalSeconds -ge $Duration) { Write-Host "Duration reached."; break }
    }
} finally {
    Write-Host "Stopping server and bots..."
    Stop-Started
}
