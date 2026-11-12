# No console. Start-BotComputere.vbs launches this with -WindowStyle Hidden.
# It does not change the running FadedAI checkpoint.
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:repo = (Resolve-Path (Join-Path $script:here "..\..")).Path
$script:backend = Join-Path $script:repo "backend"
$script:compose = Join-Path $script:here "compose.yaml"
$script:data = "D:\FadedAIData\bot-computers"
$script:envFile = Join-Path $script:data ".env"

function Test-NotLive([string]$path) {
    if ($path -like "*fadedai-checkpoint-20261107*" -or $path -like "*AppData\Local\SweatCaster\app*") {
        throw "Den sti er den kørende installation. Vælg en anden mappe."
    }
}

function New-HexKey {
    $bytes = New-Object byte[] 24
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([BitConverter]::ToString($bytes) -replace "-", "").ToLowerInvariant()
}

function Ensure-Data {
    Test-NotLive $script:data
    if (-not (Test-Path "D:\")) { throw "Drevet D: findes ikke. Ret stien i scriptet, før du fortsætter." }
    foreach ($name in @("adam", "eva")) {
        New-Item -ItemType Directory -Force -Path (Join-Path $script:data "desks\$name\files") | Out-Null
    }
    if (-not (Test-Path $script:envFile)) {
        @(
            "ADAM_AIO_KEY=$(New-HexKey)",
            "EVA_AIO_KEY=$(New-HexKey)",
            "FADEDAI_BOT_ROOT=$script:data",
            "FADEDAI_OLLAMA_MODEL=",
            "FADEDAI_BOT_COMPOSE=$script:compose"
        ) | Set-Content -Path $script:envFile -Encoding ascii
    }
}

function Read-EnvMap {
    $map = @{}
    if (Test-Path $script:envFile) {
        foreach ($line in Get-Content -Encoding UTF8 $script:envFile) {
            if ($line -match "^([A-Z0-9_]+)=(.*)$") { $map[$Matches[1]] = $Matches[2] }
        }
    }
    return $map
}

function Write-Model([string]$model) {
    Ensure-Data
    $map = Read-EnvMap
    $map["FADEDAI_OLLAMA_MODEL"] = $model.Trim()
    $map["FADEDAI_BOT_ROOT"] = $script:data
    $map["FADEDAI_BOT_COMPOSE"] = $script:compose
    $lines = foreach ($key in @("ADAM_AIO_KEY", "EVA_AIO_KEY", "FADEDAI_BOT_ROOT", "FADEDAI_OLLAMA_MODEL", "FADEDAI_BOT_COMPOSE")) {
        "$key=$($map[$key])"
    }
    Set-Content -Path $script:envFile -Value $lines -Encoding ascii
}

function Invoke-Compose([string[]]$composeArgs) {
    Ensure-Data
    $previous = $env:FADEDAI_BOT_ROOT
    $env:FADEDAI_BOT_ROOT = $script:data
    try {
        & docker compose --env-file $script:envFile -f $script:compose @composeArgs
        if ($LASTEXITCODE -ne 0) { throw "Docker Compose stoppede med koden $LASTEXITCODE." }
    } finally {
        if ($null -eq $previous) { Remove-Item Env:FADEDAI_BOT_ROOT -ErrorAction SilentlyContinue }
        else { $env:FADEDAI_BOT_ROOT = $previous }
    }
}

function Get-Python {
    if (Get-Command py -ErrorAction SilentlyContinue) { return "py" }
    if (Get-Command python -ErrorAction SilentlyContinue) { return "python" }
    throw "Python blev ikke fundet."
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "FadedAI-computere"
$form.ClientSize = New-Object System.Drawing.Size(540, 420)
$form.StartPosition = "CenterScreen"
$script:status = New-Object System.Windows.Forms.Label
$script:status.SetBounds(16, 16, 508, 90)
$script:status.Text = "Adam og Eva har hver sin computer. Den kørende FadedAI-installation bliver ikke ændret."
$form.Controls.Add($script:status)
$script:modelBox = New-Object System.Windows.Forms.TextBox
$script:modelBox.SetBounds(16, 130, 508, 24)
$label = New-Object System.Windows.Forms.Label
$label.SetBounds(16, 110, 508, 18)
$label.Text = "Ollama-model, som allerede er hentet"
$form.Controls.Add($label)
$form.Controls.Add($script:modelBox)

function Add-Button([string]$text, [int]$x, [int]$y, [int]$width, [scriptblock]$action) {
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $text
    $button.SetBounds($x, $y, $width, 36)
    $button.Add_Click($action)
    $form.Controls.Add($button)
}

Add-Button "Start Adam" 16 170 160 {
    try { Invoke-Compose @("--profile", "adam", "up", "-d", "adam"); $script:status.Text = "Adams computer starter." }
    catch { $script:status.Text = $_.Exception.Message }
}
Add-Button "Start Eva" 186 170 160 {
    try { Invoke-Compose @("--profile", "eva", "up", "-d", "eva"); $script:status.Text = "Evas computer starter." }
    catch { $script:status.Text = $_.Exception.Message }
}
Add-Button "Start begge" 356 170 168 {
    try {
        Invoke-Compose @("--profile", "adam", "up", "-d", "adam")
        Invoke-Compose @("--profile", "eva", "up", "-d", "eva")
        $script:status.Text = "Begge computere starter."
    } catch { $script:status.Text = $_.Exception.Message }
}
Add-Button "Stop" 16 216 160 {
    try { Invoke-Compose @("stop"); $script:status.Text = "Computerne er stoppet. Filerne ligger stadig i datamappen." }
    catch { $script:status.Text = $_.Exception.Message }
}
Add-Button "Åbn Adam" 186 216 160 { Start-Process "http://127.0.0.1:8091/vnc/index.html" }
Add-Button "Åbn Eva" 356 216 168 { Start-Process "http://127.0.0.1:8092/vnc/index.html" }
Add-Button "Mål RAM og CPU" 16 262 160 {
    try {
        Ensure-Data
        $raw = & docker stats --no-stream --format "{{.Name}}`t{{.CPUPerc}}`t{{.MemUsage}}"
        $lines = @($raw | Where-Object { $_ -like "fadedai-bot-*" })
        $text = if ($lines.Count -eq 0) { "Ingen bot-computere kørte. Start begge først." } else { $lines -join [Environment]::NewLine }
        Set-Content -Path (Join-Path $script:data "maaling.txt") -Value $text -Encoding utf8
        $script:status.Text = $text
    } catch { $script:status.Text = $_.Exception.Message }
}
Add-Button "Kør bevis" 186 262 160 {
    try {
        Write-Model $script:modelBox.Text
        $python = Get-Python
        $previous = $env:PYTHONPATH
        $env:PYTHONPATH = $script:backend
        $env:FADEDAI_BOT_ROOT = $script:data
        $env:FADEDAI_BOT_COMPOSE = $script:compose
        if ($python -eq "py") { & py -3 -m sweatcaster.bot_computers prove --root $script:data --measure --compose $script:compose }
        else { & python -m sweatcaster.bot_computers prove --root $script:data --measure --compose $script:compose }
        if ($LASTEXITCODE -ne 0) { throw "Beviset stoppede med koden $LASTEXITCODE." }
        if ($null -eq $previous) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $previous }
        $proof = Join-Path $script:data "bevis.txt"
        if (Test-Path $proof) { $script:status.Text = Get-Content -Encoding UTF8 $proof -Raw } else { $script:status.Text = "Beviset skrev ingen fil." }
    } catch { $script:status.Text = $_.Exception.Message }
}
Add-Button "Læg genvej" 356 262 168 {
    try {
        Ensure-Data
        Write-Model $script:modelBox.Text
        $desktop = [Environment]::GetFolderPath("Desktop")
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut((Join-Path $desktop "FadedAI-computere.lnk"))
        $shortcut.TargetPath = Join-Path $script:here "Start-BotComputere.vbs"
        $shortcut.WorkingDirectory = $script:here
        $shortcut.WindowStyle = 7
        $shortcut.Description = "Adam og Evas computere"
        $shortcut.Save()
        $script:status.Text = "Genvejen ligger på skrivebordet. Den kørende installation er ikke ændret."
    } catch { $script:status.Text = $_.Exception.Message }
}

[void]$form.ShowDialog()
