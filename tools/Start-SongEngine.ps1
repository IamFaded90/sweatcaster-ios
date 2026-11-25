param(
    [string] $SongRoot = 'F:\FadedAI\song-studio',
    [int] $Port = 8001,
    [int] $WaitSeconds = 45
)

$ErrorActionPreference = 'Stop'
if ($Port -lt 1 -or $Port -gt 65535 -or $WaitSeconds -lt 1 -or $WaitSeconds -gt 60) { throw 'Ugyldig port eller ventetid.' }
$python = Join-Path $SongRoot 'venv\Scripts\python.exe'
$engine = Join-Path $SongRoot 'engine'
if (-not (Test-Path -LiteralPath $python -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $engine 'acestep\api_server.py') -PathType Leaf)) {
    Write-Output 'Sangmotoren er ikke installeret. Resten af FadedAI kan starte.'
    exit 1
}

function Test-SongEngine {
    try {
        $result = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2
        $health = if ($null -ne $result.data) { $result.data } else { $result }
        return $health.status -eq 'ok' -and $health.service -eq 'ACE-Step API'
    } catch { return $false }
}

function Test-SongStarting {
    # The virtualenv launcher remains alive while its Python child imports the engine.
    # Do not start a second copy merely because imports have not bound the port yet.
    $exactPython = [IO.Path]::GetFullPath($python)
    $matches = Get-CimInstance Win32_Process -Filter "name = 'python.exe'" -ErrorAction Stop | Where-Object {
        $_.ExecutablePath -and [string]::Equals($_.ExecutablePath, $exactPython, [StringComparison]::OrdinalIgnoreCase) -and
        $_.CommandLine -match '(?:^|\s)-m\s+acestep\.api_server(?:\s|$)' -and
        $_.CommandLine -match "(?:^|\s)--port\s+$Port(?:\s|$)"
    }
    return @($matches).Count -gt 0
}

$mutex = [Threading.Mutex]::new($false, "Local\FadedAI-ACE-Step-$Port")
$ownsMutex = $false
try {
    try { $ownsMutex = $mutex.WaitOne([TimeSpan]::FromSeconds(50)) }
    catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw 'En anden start af sangmotoren er stadig i gang.' }
    if (Test-SongEngine) { Write-Output 'Sangmotoren kører allerede.'; exit 0 }
    if (Test-SongStarting) { Write-Output 'Sangmotoren starter allerede. Vent et øjeblik, og opdatér Sangstudie.'; exit 0 }
    $probe = [Net.Sockets.TcpClient]::new()
    try {
        $connect = $probe.ConnectAsync('127.0.0.1', $Port)
        $portBusy = $connect.Wait(1500) -and $probe.Connected
    } catch { $portBusy = $false } finally { $probe.Dispose() }
    if ($portBusy) {
        throw "Port $Port bruges af en anden tjeneste. Den bliver ikke stoppet."
    }
    $oldInit = $env:ACESTEP_INIT_LLM
    $oldTemp = $env:TEMP
    $oldTmp = $env:TMP
    try {
        $env:ACESTEP_INIT_LLM = 'false'
        $tempDir = Join-Path $SongRoot 'tmp'
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $env:TEMP = $tempDir
        $env:TMP = $tempDir
        Start-Process -FilePath $python -WorkingDirectory $engine -WindowStyle Hidden `
            -ArgumentList @('-m', 'acestep.api_server', '--host', '127.0.0.1', '--port', "$Port", '--no-init') `
            -RedirectStandardOutput (Join-Path $SongRoot 'api-out.log') `
            -RedirectStandardError (Join-Path $SongRoot 'api-error.log') | Out-Null
    } finally {
        $env:ACESTEP_INIT_LLM = $oldInit
        $env:TEMP = $oldTemp
        $env:TMP = $oldTmp
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    do {
        Start-Sleep -Milliseconds 500
        if (Test-SongEngine) { Write-Output 'Sangmotoren er startet. Modellen indlæses, når en sang bestilles.'; exit 0 }
    } while ([DateTime]::UtcNow -lt $deadline)
    if (Test-SongStarting) { Write-Output 'Sangmotoren starter stadig. Vent et øjeblik, og opdatér Sangstudie.'; exit 0 }
    throw 'Sangmotoren kunne ikke starte. Se api-error.log i sangstudio-mappen.'
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
