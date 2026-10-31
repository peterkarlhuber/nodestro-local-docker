# Nodestro Local Docker launcher for Windows (PowerShell 5.1 or 7) with Docker Desktop. Linux and macOS: ./nodestro
#
#   .\nodestro.ps1 start | stop | restart | status | open | link | logs | backup [FILE] | restore FILE
#                  build | rotate-key | uninstall [--delete-data] | help
#
# Update and rollback are only in ./nodestro for now (run it in WSL or Git Bash).
# No param block: arguments such as --delete-data reach the script as they are typed.
$Command = if ($args.Count -gt 0) { [string]$args[0] } else { "help" }
$Rest = @(if ($args.Count -gt 1) { $args[1..($args.Count - 1)] | ForEach-Object { [string]$_ } })
$ErrorActionPreference = "Stop"
$Here = $PSScriptRoot
if (-not $env:NODESTRO_PROJECT) { $env:NODESTRO_PROJECT = "nodestro-local" }
if (-not $env:NODESTRO_PORT) { $env:NODESTRO_PORT = "8765" }
$StateDir = if ($env:NODESTRO_STATE_DIR) { $env:NODESTRO_STATE_DIR } else { Join-Path $Here ".nodestro" }
$StateFile = Join-Path $StateDir "state.env"

function Fail([string]$Message) { Write-Host "Nodestro: $Message" -ForegroundColor Red; exit 1 }

function Load-State {
    if (Test-Path $StateFile) {
        foreach ($line in Get-Content $StateFile) {
            if ($line -match '^NODESTRO_IMAGE=(.+)$') { $env:NODESTRO_IMAGE = $Matches[1].Trim("'", '"') }
        }
    }
    if (-not $env:NODESTRO_IMAGE) { $env:NODESTRO_IMAGE = "nodestro-local:dev" }
}

function Save-State {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    Set-Content -Path $StateFile -Value "NODESTRO_IMAGE=$($env:NODESTRO_IMAGE)" -Encoding ascii
}

function Invoke-Compose {
    $files = @("-f", (Join-Path $Here "compose.yaml"))
    if ($env:NODESTRO_EXTRA_CA_FILE) { $files += @("-f", (Join-Path $Here "compose.extra-ca.yaml")) }
    & docker compose --project-directory $Here @files @args
    if ($LASTEXITCODE -ne 0) { throw "docker compose $($args -join ' ') failed" }
}

function Require-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Fail "Docker is not installed. Install Docker Desktop: https://docs.docker.com/desktop/setup/install/windows-install/"
    }
    & docker info *> $null
    if ($LASTEXITCODE -ne 0) { Fail "Docker Desktop is installed but not running. Start Docker Desktop and wait until it says it is running." }
    & docker compose version *> $null
    if ($LASTEXITCODE -ne 0) { Fail "Docker Compose v2 is missing. Update Docker Desktop." }
}

function Build-Image {
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bash) { Fail "Building the image needs bash and git (Git for Windows or WSL): bash scripts/build-image.sh" }
    $tag = (& bash (Join-Path $Here "scripts/build-image.sh") | Select-Object -Last 1)
    if ($LASTEXITCODE -ne 0) { Fail "The image build failed (see above)." }
    $env:NODESTRO_IMAGE = $tag.Trim()
    Save-State
}

function Get-Link {
    $url = (& docker compose --project-directory $Here -f (Join-Path $Here "compose.yaml") exec -T nodestro nodestro-local link --port $env:NODESTRO_PORT)
    if ($LASTEXITCODE -ne 0) { Fail "Nodestro is not running (start it: .\nodestro.ps1 start)." }
    return ($url | Select-Object -Last 1).Trim()
}

function Open-Browser {
    $url = Get-Link
    # A private file forwards to the link, so the access key does not appear in a process list.
    $page = Join-Path $env:TEMP ("nodestro-open-" + [guid]::NewGuid().ToString("N") + ".html")
    Set-Content -Path $page -Value "<!doctype html><meta charset=`"utf-8`"><meta http-equiv=`"refresh`" content=`"0;url=$url`"><title>Nodestro</title>" -Encoding utf8
    Write-Host "Nodestro is running. Open it with this link (it contains your access key, keep it private):"
    Write-Host "  $url"
    if (-not $env:NODESTRO_NO_BROWSER) {
        Start-Process $page
        Start-Job -ScriptBlock { param($p) Start-Sleep 60; Remove-Item $p -ErrorAction SilentlyContinue } -ArgumentList $page | Out-Null
    } else { Remove-Item $page }
}

function Start-Nodestro {
    Require-Docker; Load-State
    & docker image inspect $env:NODESTRO_IMAGE *> $null
    if ($LASTEXITCODE -ne 0) { Write-Host "Building the Nodestro image from source (several minutes, once)..."; Build-Image }
    Write-Host "Starting Nodestro (image $($env:NODESTRO_IMAGE), http://127.0.0.1:$($env:NODESTRO_PORT))..."
    try { Invoke-Compose up -d --wait --wait-timeout 300 }
    catch { Invoke-Compose logs --tail 40; Fail "Nodestro did not start. The lines above say why (a port in use: set NODESTRO_PORT)." }
    Open-Browser
}

switch ($Command) {
    "start" { Start-Nodestro }
    "stop" { Require-Docker; Load-State; Invoke-Compose stop; Write-Host "Nodestro stopped. Your data is kept." }
    "restart" { Require-Docker; Load-State; Invoke-Compose restart; Invoke-Compose up -d --wait --wait-timeout 300; Open-Browser }
    "status" {
        Require-Docker; Load-State; Invoke-Compose ps
        try { Invoke-Compose exec -T nodestro nodestro-local status } catch { Write-Host "Nodestro is not running." }
    }
    "open" { Require-Docker; Load-State; Open-Browser }
    "link" { Require-Docker; Load-State; Get-Link }
    "logs" { Require-Docker; Load-State; Invoke-Compose logs --tail 200 }
    "backup" {
        Require-Docker; Load-State
        $file = if ($Rest.Count -gt 0) { $Rest[0] } else { Join-Path $Here ("backups/nodestro-backup-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".zip") }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
        # Binary-safe: docker writes the file through cmd's redirection, not PowerShell's text pipeline.
        $files = "-f `"$(Join-Path $Here 'compose.yaml')`""
        cmd /c "docker compose --project-directory `"$Here`" $files exec -T nodestro nodestro-local backup > `"$file`""
        if ($LASTEXITCODE -ne 0) { Remove-Item $file -ErrorAction SilentlyContinue; Fail "The backup failed (is Nodestro running?)" }
        Write-Host "Backup written to $file"
    }
    "restore" {
        Require-Docker; Load-State
        if ($Rest.Count -lt 1 -or -not (Test-Path $Rest[0])) { Fail "Name the backup file: .\nodestro.ps1 restore FILE" }
        $files = "-f `"$(Join-Path $Here 'compose.yaml')`""
        cmd /c "docker compose --project-directory `"$Here`" $files exec -T nodestro nodestro-local restore < `"$($Rest[0])`""
        if ($LASTEXITCODE -ne 0) { Fail "The restore failed." }
        Write-Host "Restored $($Rest[0])."
    }
    "build" { Require-Docker; Load-State; Build-Image }
    "rotate-key" { Require-Docker; Load-State; Invoke-Compose exec -T nodestro nodestro-local rotate-key; Invoke-Compose restart nodestro; Invoke-Compose up -d --wait --wait-timeout 300; Open-Browser }
    "uninstall" {
        Require-Docker; Load-State
        if ($Rest -contains "--delete-data") { Invoke-Compose down -v; & docker volume rm "$($env:NODESTRO_PROJECT)_data-before-update" *> $null; Write-Host "Nodestro and all its data were removed." }
        else { Invoke-Compose down; Write-Host "Nodestro was removed; its data volume is kept." }
    }
    { $_ -in "help", "-h", "--help" } { Get-Content $PSCommandPath -TotalCount 6 | Select-Object -Skip 1 | ForEach-Object { $_ -replace '^# ?', '' } }
    default { Fail "Unknown command $Command (see .\nodestro.ps1 help)" }
}
