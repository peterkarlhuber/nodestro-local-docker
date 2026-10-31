# Nodestro Local Docker launcher for Windows (PowerShell 5.1 or 7) with Docker Desktop. Linux and macOS: ./nodestro
#
#   .\nodestro.ps1 start | stop | restart | status | open | link | logout | logs | backup [FILE] | restore FILE
#                  update | rollback | build | rotate-key | uninstall [--delete-data] | help
#
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

# Runs a native command and says whether it succeeded, with its output discarded. Windows PowerShell 5.1 turns a
# native command's error output into a terminating error under $ErrorActionPreference = "Stop"; this avoids that.
function Test-Native([scriptblock]$Block) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & $Block *> $null; return ($LASTEXITCODE -eq 0) } finally { $ErrorActionPreference = $previous }
}

function Load-State {
    if (Test-Path $StateFile) {
        foreach ($line in Get-Content $StateFile) {
            if ($line -match '^NODESTRO_IMAGE=(.+)$') { $env:NODESTRO_IMAGE = $Matches[1].Trim("'", '"') }
            if ($line -match '^NODESTRO_PREVIOUS_IMAGE=(.*)$') { $env:NODESTRO_PREVIOUS_IMAGE = $Matches[1].Trim("'", '"') }
        }
    }
    if (-not $env:NODESTRO_IMAGE) { $env:NODESTRO_IMAGE = "nodestro-local:dev" }
}

function Save-State {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    Set-Content -Path $StateFile -Value @("NODESTRO_IMAGE=$($env:NODESTRO_IMAGE)", "NODESTRO_PREVIOUS_IMAGE=$($env:NODESTRO_PREVIOUS_IMAGE)") -Encoding ascii
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
    if (-not (Test-Native { docker info })) { Fail "Docker Desktop is installed but not running. Start Docker Desktop and wait until it says it is running." }
    if (-not (Test-Native { docker compose version })) { Fail "Docker Compose v2 is missing. Update Docker Desktop." }
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
    $page = Join-Path ([System.IO.Path]::GetTempPath()) ("nodestro-open-" + [guid]::NewGuid().ToString("N") + ".html")
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
    if (-not (Test-Native { docker image inspect $env:NODESTRO_IMAGE })) { Write-Host "Building the Nodestro image from source (several minutes, once)..."; Build-Image }
    Write-Host "Starting Nodestro (image $($env:NODESTRO_IMAGE), port $($env:NODESTRO_PORT) on 127.0.0.1)..."
    try { Invoke-Compose up -d --wait --wait-timeout 300 }
    catch { Invoke-Compose logs --tail 40; Fail "Nodestro did not start. The lines above say why (a port in use: set NODESTRO_PORT)." }
    Open-Browser
}

# Runs a command line with the shell's own file redirection, which keeps binary data intact: cmd on Windows, sh on
# PowerShell 7 for Linux and macOS (used by the tests).
function Invoke-Shell([string]$Line) {
    if ($PSVersionTable.PSEdition -eq "Core" -and -not $IsWindows) { & sh -c $Line } else { cmd /c $Line }
}

function Backup-Nodestro([string]$File) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $File) | Out-Null
    # Binary-safe: docker writes the file through cmd's redirection, not PowerShell's text pipeline.
    $files = "-f `"$(Join-Path $Here 'compose.yaml')`""
    Invoke-Shell "docker compose --project-directory `"$Here`" $files exec -T nodestro nodestro-local backup > `"$File`""
    if ($LASTEXITCODE -ne 0) { Remove-Item $File -ErrorAction SilentlyContinue; return $false }
    Write-Host "Backup written to $File"
    return $true
}

function Get-Volume([string]$Name) { return "$($env:NODESTRO_PROJECT)_$Name" }

# Replaces the contents of volume $To with those of volume $From (both must exist), in a container without network.
function Copy-Volume([string]$From, [string]$To) {
    & docker run --rm --network none --user 0:0 --entrypoint sh -v "${From}:/from:ro" -v "${To}:/to" $env:NODESTRO_IMAGE `
        -c 'find /to -mindepth 1 -maxdepth 1 -exec rm -rf {} + && cp -a /from/. /to/'
    if ($LASTEXITCODE -ne 0) { Fail "Copying the data from $From to $To failed." }
}

function Test-Running {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $files = @("-f", (Join-Path $Here "compose.yaml"))
        $services = & docker compose --project-directory $Here @files ps --status running --services 2>$null
        return (@($services) -contains "nodestro")
    } finally { $ErrorActionPreference = $previous }
}

function Update-Nodestro {
    Require-Docker; Load-State
    $previous = $env:NODESTRO_IMAGE
    $snapshot = Get-Volume "data-before-update"
    if (Test-Running) {
        $file = Join-Path $Here ("backups/before-update-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".zip")
        if (-not (Backup-Nodestro $file)) { Fail "The backup before the update failed; nothing was changed." }
    }
    if ($env:NODESTRO_UPDATE_IMAGE) {
        # An image built or loaded elsewhere.
        if (-not (Test-Native { docker image inspect $env:NODESTRO_UPDATE_IMAGE })) { Fail "The image $($env:NODESTRO_UPDATE_IMAGE) is missing." }
        $next = $env:NODESTRO_UPDATE_IMAGE
    } else {
        Build-Image
        $next = $env:NODESTRO_IMAGE
    }
    $env:NODESTRO_IMAGE = $previous
    Write-Host "Stopping Nodestro and keeping a copy of its data for a rollback..."
    Invoke-Compose stop nodestro | Out-Null
    & docker volume create $snapshot | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "Creating the volume $snapshot failed." }
    if (Test-Native { docker volume inspect (Get-Volume "data") }) { Copy-Volume (Get-Volume "data") $snapshot }
    $env:NODESTRO_PREVIOUS_IMAGE = $previous
    $env:NODESTRO_IMAGE = $next
    Save-State
    try { Invoke-Compose up -d --wait --wait-timeout 300 }
    catch {
        Write-Host "The new version did not start; going back to $previous."
        Undo-Update
        Fail "Update failed and was rolled back."
    }
    Write-Host "Updated to $next (rollback: .\nodestro.ps1 rollback)."
    Open-Browser
}

function Undo-Update {
    Require-Docker; Load-State
    if (-not $env:NODESTRO_PREVIOUS_IMAGE) { Fail "There is no earlier version to go back to." }
    $snapshot = Get-Volume "data-before-update"
    if (-not (Test-Native { docker volume inspect $snapshot })) { Fail "The copy of the data from before the update is missing." }
    try { Invoke-Compose stop nodestro | Out-Null } catch { }
    Copy-Volume $snapshot (Get-Volume "data")
    $env:NODESTRO_IMAGE = $env:NODESTRO_PREVIOUS_IMAGE
    $env:NODESTRO_PREVIOUS_IMAGE = ""
    Save-State
    try { Invoke-Compose up -d --wait --wait-timeout 300 }
    catch { Fail "The earlier version did not start either; see: .\nodestro.ps1 logs" }
    Write-Host "Back on $($env:NODESTRO_IMAGE) with the data from before the update."
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
    "logout" { Require-Docker; Load-State; Invoke-Compose exec -T nodestro nodestro-local logout }
    "logs" { Require-Docker; Load-State; Invoke-Compose logs --tail 200 }
    "backup" {
        Require-Docker; Load-State
        $file = if ($Rest.Count -gt 0) { $Rest[0] } else { Join-Path $Here ("backups/nodestro-backup-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".zip") }
        if (-not (Backup-Nodestro $file)) { Fail "The backup failed (is Nodestro running?)" }
    }
    "restore" {
        Require-Docker; Load-State
        if ($Rest.Count -lt 1 -or -not (Test-Path $Rest[0])) { Fail "Name the backup file: .\nodestro.ps1 restore FILE" }
        $files = "-f `"$(Join-Path $Here 'compose.yaml')`""
        Invoke-Shell "docker compose --project-directory `"$Here`" $files exec -T nodestro nodestro-local restore < `"$($Rest[0])`""
        if ($LASTEXITCODE -ne 0) { Fail "The restore failed." }
        Write-Host "Restored $($Rest[0])."
    }
    "update" { Update-Nodestro }
    "rollback" { Undo-Update }
    "build" { Require-Docker; Load-State; Build-Image }
    "rotate-key" { Require-Docker; Load-State; Invoke-Compose exec -T nodestro nodestro-local rotate-key; Invoke-Compose restart nodestro; Invoke-Compose up -d --wait --wait-timeout 300; Open-Browser }
    "uninstall" {
        Require-Docker; Load-State
        if ($Rest -contains "--delete-data") { Invoke-Compose down -v; Test-Native { docker volume rm (Get-Volume "data-before-update") } | Out-Null; Write-Host "Nodestro and all its data were removed." }
        else { Invoke-Compose down; Write-Host "Nodestro was removed; its data volume is kept." }
    }
    { $_ -in "help", "-h", "--help" } { Get-Content $PSCommandPath -TotalCount 6 | Select-Object -Skip 1 | ForEach-Object { $_ -replace '^# ?', '' } }
    default { Fail "Unknown command $Command (see .\nodestro.ps1 help)" }
}
