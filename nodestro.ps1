# Nodestro Local Docker launcher for Windows (PowerShell 5.1 or 7) with Docker Desktop. Linux and macOS: ./nodestro
#
#   .\nodestro.ps1 start | stop | restart | status | open | link | logout | logs | backup [FILE] | restore FILE
#                  update | rollback | build | rotate-key | vault-key | rotate-vault-key
#                  accept-new-vault-key --yes | uninstall [--delete-data] | help
#
# No param block: arguments such as --delete-data reach the script as they are typed.
$Usage = @'
Nodestro Local Docker launcher for Windows with Docker Desktop (Linux and macOS: ./nodestro). Needs Docker; build
also needs git.

Usage: .\nodestro.ps1 COMMAND

  start                       Start Nodestro (builds the image on first use) and open the studio
  stop                        Stop it; the data is kept
  restart                     Restart it and open the studio
  status                      Show the containers and whether Nodestro runs
  open                        Open the studio in the browser
  link                        Print the sign-in link (it contains the access key: keep it private)
  logout                      End every browser session
  logs                        Show the last log lines (200)
  backup [FILE]               Write a backup (default: backups/nodestro-backup-<time>.zip)
  restore FILE                Restore a backup
  update                      Back up, then switch to a new image; rolls back by itself if it does not start
  rollback                    Return to the image and the data from before the last update
  build                       Build the image from the pinned sources (needs git)
  rotate-key                  Replace the access key and open the studio with the new one
  vault-key                   Show where the key file for your secrets is (created if missing); keep a copy of it
                              somewhere safe, apart from the backups
  rotate-vault-key            Seal every stored secret with a new key file (also the copy kept for a rollback)
  accept-new-vault-key --yes  After losing the key file: remove the secrets it sealed (enter them again) and use a new key
  uninstall [--delete-data]   Remove Nodestro; the data volume is kept unless --delete-data
  help                        This text

Settings (environment variables):
  NODESTRO_PORT               Port on 127.0.0.1 (default 8765)
  NODESTRO_NO_BROWSER=1       Print the link instead of opening a browser
  NODESTRO_EXTRA_CA_FILE      Certificate bundle of a TLS-inspecting proxy
  NODESTRO_HTTPS_PROXY        Proxy for outgoing requests (model providers, packages, model downloads), as the
                              containers reach it (not 127.0.0.1); NODESTRO_NO_PROXY: more hosts to reach directly
  NODESTRO_UPDATE_IMAGE       Image for update (default: build from the pinned sources)
  NODESTRO_PROJECT            Compose project name (default nodestro-local)
  NODESTRO_STATE_DIR          Where the launcher keeps its state (default .nodestro next to it)
  NODESTRO_LOCAL_MODELS       on (default): local model server; offline: without internet (offline imports only);
                              off: none. Remembered until you set it again
  NODESTRO_IMPORT_DIR         Folder for offline model imports, /import in the studio (default: import next to this)
  NODESTRO_VAULT_KEY_FILE     The key file for provider keys, MCP tokens and connection secrets (default:
                              %LOCALAPPDATA%\nodestro-local\<project>\vault.key); never inside this folder
'@
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
    $chosenModels = $env:NODESTRO_LOCAL_MODELS
    if (Test-Path $StateFile) {
        foreach ($line in Get-Content $StateFile) {
            if ($line -match '^NODESTRO_IMAGE=(.+)$') { $env:NODESTRO_IMAGE = $Matches[1].Trim("'", '"') }
            if ($line -match '^NODESTRO_PREVIOUS_IMAGE=(.*)$') { $env:NODESTRO_PREVIOUS_IMAGE = $Matches[1].Trim("'", '"') }
            if ($line -match '^NODESTRO_LOCAL_MODELS=(.+)$') { $env:NODESTRO_LOCAL_MODELS = $Matches[1].Trim("'", '"') }
        }
    }
    if (-not $env:NODESTRO_IMAGE) { $env:NODESTRO_IMAGE = "nodestro-local:dev" }
    # A value set now wins over the remembered one, and is remembered from now on.
    if ($chosenModels) { $env:NODESTRO_LOCAL_MODELS = $chosenModels }
    if (-not $env:NODESTRO_LOCAL_MODELS) { $env:NODESTRO_LOCAL_MODELS = "on" }
    if (@("on", "off", "offline") -notcontains $env:NODESTRO_LOCAL_MODELS) {
        Fail "NODESTRO_LOCAL_MODELS must be on, off or offline (not $($env:NODESTRO_LOCAL_MODELS))."
    }
    if ($chosenModels) { Save-State }
    # The folder for offline model imports; created here so that Docker does not create it itself.
    if (-not $env:NODESTRO_IMPORT_DIR) { New-Item -ItemType Directory -Force -Path (Join-Path $Here "import") | Out-Null }
}

function Save-State {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $models = if ($env:NODESTRO_LOCAL_MODELS) { $env:NODESTRO_LOCAL_MODELS } else { "on" }
    Set-Content -Path $StateFile -Value @("NODESTRO_IMAGE=$($env:NODESTRO_IMAGE)", "NODESTRO_PREVIOUS_IMAGE=$($env:NODESTRO_PREVIOUS_IMAGE)", "NODESTRO_LOCAL_MODELS=$models") -Encoding ascii
}

# ---- the key file (LD-020, docs/SECURITY.md "The key file") ----------------------------------------------------------
# Provider keys, MCP tokens and connection secrets are sealed with a key kept in a file on the host: outside this folder,
# the data volume, the images and the backups. On Windows its folder and the file carry an ACL with the current user
# only (inheritance off); on Linux and macOS (PowerShell 7) 0600 in a 0700 folder. Created once with the system's
# cryptographic random generator, and never replaced by the launcher: without it the studio does not start.
$OnWindows = ($PSVersionTable.PSEdition -ne "Core") -or $IsWindows

function Get-VaultKeyFile {
    if ($env:NODESTRO_VAULT_KEY_FILE) { return [System.IO.Path]::GetFullPath($env:NODESTRO_VAULT_KEY_FILE) }
    if ($OnWindows) { return (Join-Path $env:LOCALAPPDATA "nodestro-local\$($env:NODESTRO_PROJECT)\vault.key") }
    if ($IsMacOS) { return (Join-Path $HOME "Library/Application Support/nodestro-local/$($env:NODESTRO_PROJECT)/vault.key") }
    $config = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME ".config" }
    return (Join-Path $config "nodestro-local/$($env:NODESTRO_PROJECT)/vault.key")
}

# Windows: the current user only, inheritance off (folder: also for what is created in it).
function Protect-VaultPath([string]$Path, [bool]$Folder) {
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($Folder) {
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $inherit = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit"
    } else {
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $inherit = [System.Security.AccessControl.InheritanceFlags]::None
    }
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($user)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($user, "FullControl", $inherit, "None", "Allow")
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Test-VaultPath([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.LinkType) { return "is a link" }
    if ($OnWindows) {
        $acl = Get-Acl -LiteralPath $Path
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        if (-not $acl.AreAccessRulesProtected) { return "inherits permissions from its parent folder" }
        foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -eq "Allow" -and $rule.IdentityReference -ne $user) { return "is open to $($rule.IdentityReference)" }
        }
        return $null
    }
    $mode = [int]$item.UnixFileMode
    if ($mode -band 63) { return "is open to others (mode $($item.UnixMode))" }
    if ((& id -u) -ne (& stat -c '%u' $Path 2>$null) -and (& id -u) -ne (& stat -f '%u' $Path 2>$null)) { return "belongs to another user" }
    return $null
}

function Assert-VaultKey([string]$File) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { Fail "The key file $File is not a regular file." }
    $problem = Test-VaultPath $File
    if ($problem) { Fail "The key file $File $problem; it must be readable by you only (delete and restore it with: .\nodestro.ps1 vault-key)." }
    $folder = Split-Path -Parent $File
    $problem = Test-VaultPath $folder
    if ($problem) { Fail "The folder $folder of the key file $problem; it must be open to you only." }
}

# Creates a new key file at $File unless one exists (atomically; an existing file is never replaced). $true: created.
function New-VaultKey([string]$File) {
    $root = [System.IO.Path]::GetFullPath($Here).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if ($File.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail "The key file must not be inside $Here (it would end up in copies of this folder)."
    }
    if (Test-Path -LiteralPath $File) { return $false }
    $folder = Split-Path -Parent $File
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        if ($OnWindows) { Protect-VaultPath $folder $true } else { & chmod 700 $folder; if ($LASTEXITCODE -ne 0) { Fail "chmod $folder failed." } }
    }
    # 32 bytes from the system's cryptographic random generator, base64.
    $bytes = New-Object byte[] 32
    $random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($bytes) } finally { $random.Dispose() }
    $temp = Join-Path $folder (".vault-key-" + [guid]::NewGuid().ToString("N"))
    [System.IO.File]::WriteAllText($temp, [Convert]::ToBase64String($bytes) + "`n", [System.Text.Encoding]::ASCII)
    if ($OnWindows) { Protect-VaultPath $temp $false } else { & chmod 600 $temp }
    # Move without overwrite: two launchers at once never write two keys.
    try { [System.IO.File]::Move($temp, $File) } catch { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue; return $false }
    return $true
}

function Use-VaultKey {
    $file = Get-VaultKeyFile
    if (New-VaultKey $file) {
        Write-Host "Created the key file for your secrets: $file"
        Write-Host "  Keep a copy of it somewhere safe (not with the backups): without it, stored provider keys, MCP tokens and"
        Write-Host "  connection secrets cannot be read again."
        if ((Get-Command docker -ErrorAction SilentlyContinue) -and (Test-Native { docker volume inspect (Get-Volume "data") })) {
            Write-Host "  The data volume $(Get-Volume 'data') exists already. If its secrets were sealed with an earlier key file,"
            Write-Host "  Nodestro will refuse to start: put the earlier file back at this path, or give them up: .\nodestro.ps1 accept-new-vault-key --yes"
        }
    }
    Assert-VaultKey $file
    $env:NODESTRO_VAULT_KEY_HOST_FILE = $file
    return $file
}

# Whether the image reads the key file (images before LD-020, after a rollback, do not).
function Test-VaultKeyImage([string]$Image) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { $label = & docker image inspect --format '{{ index .Config.Labels "dev.nodestro.vault-key-file" }}' $Image 2>$null }
    finally { $ErrorActionPreference = $previous }
    return ($LASTEXITCODE -eq 0 -and "$label".Trim() -eq "1")
}

function Invoke-Compose {
    $files = @("-f", (Join-Path $Here "compose.yaml"))
    if (Test-VaultKeyImage $env:NODESTRO_IMAGE) {
        Use-VaultKey | Out-Null
        $files += @("-f", (Join-Path $Here "compose.vault-key.yaml"))
    }
    if ($env:NODESTRO_EXTRA_CA_FILE) { $files += @("-f", (Join-Path $Here "compose.extra-ca.yaml")) }
    # Before the offline file, which closes Ollama's downloads again.
    if ($env:NODESTRO_HTTPS_PROXY) { $files += @("-f", (Join-Path $Here "compose.proxy.yaml")) }
    if ($env:NODESTRO_LOCAL_MODELS -eq "off") { $files += @("-f", (Join-Path $Here "compose.local-models-off.yaml")) }
    if ($env:NODESTRO_LOCAL_MODELS -eq "offline") { $files += @("-f", (Join-Path $Here "compose.local-models-offline.yaml")) }
    # The user's own additions (README: model providers), as plain `docker compose` would read them.
    $override = Join-Path $Here "compose.override.yaml"
    if (Test-Path -LiteralPath $override -PathType Leaf) { $files += @("-f", $override) }
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
    $url = (& docker compose --project-directory $Here -f (Join-Path $Here "compose.yaml") exec -T --user 10001:10001 nodestro nodestro-local link --port $env:NODESTRO_PORT)
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
    if ($env:NODESTRO_LOCAL_MODELS -ne "off") {
        Write-Host "The first start downloads the local model server (Ollama, about 3.4 GB, once; NODESTRO_LOCAL_MODELS=off skips it)."
    }
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
    Invoke-Shell "docker compose --project-directory `"$Here`" $files exec -T --user 10001:10001 nodestro nodestro-local backup > `"$File`""
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

# `nodestro-local boot ACTION` on the data in a volume, as the studio's container runs it (root with three capabilities
# until it drops to the studio's user), without network. $Mounts: the key files.
function Invoke-Boot([string]$Volume, [string]$Action, [string[]]$Mounts) {
    & docker run --rm --network none --read-only --tmpfs /tmp --user 0:0 --cap-drop ALL `
        --cap-add DAC_READ_SEARCH --cap-add SETUID --cap-add SETGID --security-opt no-new-privileges:true `
        --entrypoint nodestro-local -v "${Volume}:/var/lib/nodestro" @Mounts $env:NODESTRO_IMAGE boot $Action
    return ($LASTEXITCODE -eq 0)
}

function Get-KeyMount([string]$File, [string]$Target) { return @("--mount", "type=bind,source=$File,target=$Target,readonly") }

function Invoke-Rekey([string]$Volume, [string]$Old, [string]$New) {
    $mounts = (Get-KeyMount $Old "/run/secrets/nodestro-vault-key") + (Get-KeyMount $New "/run/secrets/nodestro-vault-key-new")
    return (Invoke-Boot $Volume "rekey" $mounts)
}

function Update-VaultKey {
    Require-Docker; Load-State
    if (-not (Test-VaultKeyImage $env:NODESTRO_IMAGE)) { Fail "The image $($env:NODESTRO_IMAGE) has no key file support; update first (.\nodestro.ps1 update)." }
    $file = Use-VaultKey
    $new = "$file.new"
    # A new key from an interrupted rotation is used again: the data may be sealed with it already.
    if (-not (New-VaultKey $new)) { Write-Host "Continuing the rotation with $new." }
    Assert-VaultKey $new
    $data = Get-Volume "data"
    $snapshot = Get-Volume "data-before-update"
    Write-Host "Stopping Nodestro to seal its secrets with the new key..."
    Invoke-Compose stop nodestro | Out-Null
    if ((Test-Native { docker volume inspect $data }) -and -not (Invoke-Rekey $data $file $new)) {
        try { Invoke-Compose up -d --wait --wait-timeout 300 | Out-Null } catch { }
        Fail "The rotation stopped; nothing was changed and the key file stays $file."
    }
    if ((Test-Native { docker volume inspect $snapshot }) -and -not (Invoke-Rekey $snapshot $file $new)) {
        if (-not (Invoke-Rekey $data $new $file)) { Fail "The rotation failed half-way: keep both $file and $new and run .\nodestro.ps1 rotate-vault-key again." }
        try { Invoke-Compose up -d --wait --wait-timeout 300 | Out-Null } catch { }
        Fail "The copy kept for a rollback could not be sealed with the new key; nothing was changed."
    }
    Move-Item -LiteralPath $new -Destination $file -Force
    try { Invoke-Compose up -d --wait --wait-timeout 300 } catch { Fail "Nodestro did not start with the new key; see: .\nodestro.ps1 logs" }
    Write-Host "Every stored secret is sealed with the new key in $file; the old key is gone."
    Write-Host "Backups written before keep their MCP tokens and connection secrets sealed with the old key: after a restore"
    Write-Host "they count as missing and have to be entered again. Replace your safe copy of the key file with the new one."
}

function Approve-NewVaultKey {
    if ($Rest -notcontains "--yes") {
        Fail "This removes every stored provider key, MCP token and connection secret that the current key file cannot open (they have to be entered again). Only for a lost key file; if you still have it, put it back at $(Get-VaultKeyFile) instead. Confirm with: .\nodestro.ps1 accept-new-vault-key --yes"
    }
    Require-Docker; Load-State
    if (-not (Test-VaultKeyImage $env:NODESTRO_IMAGE)) { Fail "The image $($env:NODESTRO_IMAGE) has no key file support; update first (.\nodestro.ps1 update)." }
    $file = Use-VaultKey
    Invoke-Compose stop nodestro | Out-Null
    foreach ($volume in @((Get-Volume "data"), (Get-Volume "data-before-update"))) {
        if (Test-Native { docker volume inspect $volume }) {
            if (-not (Invoke-Boot $volume "discard-unreadable" (Get-KeyMount $file "/run/secrets/nodestro-vault-key"))) {
                Fail "Removing the unreadable secrets in $volume failed."
            }
        }
    }
    try { Invoke-Compose up -d --wait --wait-timeout 300 } catch { Fail "Nodestro did not start; see: .\nodestro.ps1 logs" }
    Write-Host "Nodestro uses the key file $file now; enter the removed keys and tokens again."
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
    # stop + up, not `compose restart` (parallel; a container cannot join the namespace of `network` while it restarts)
    "restart" { Require-Docker; Load-State; Invoke-Compose stop; Invoke-Compose up -d --wait --wait-timeout 300; Open-Browser }
    "status" {
        Require-Docker; Load-State; Invoke-Compose ps
        Write-Host "Key file for your secrets: $(Get-VaultKeyFile)"
        try { Invoke-Compose exec -T --user 10001:10001 nodestro nodestro-local status } catch { Write-Host "Nodestro is not running." }
    }
    "open" { Require-Docker; Load-State; Open-Browser }
    "link" { Require-Docker; Load-State; Get-Link }
    "logout" { Require-Docker; Load-State; Invoke-Compose exec -T --user 10001:10001 nodestro nodestro-local logout }
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
        Invoke-Shell "docker compose --project-directory `"$Here`" $files exec -T --user 10001:10001 nodestro nodestro-local restore < `"$($Rest[0])`""
        if ($LASTEXITCODE -ne 0) { Fail "The restore failed." }
        Write-Host "Restored $($Rest[0])."
    }
    "update" { Update-Nodestro }
    "rollback" { Undo-Update }
    "build" { Require-Docker; Load-State; Build-Image }
    "vault-key" { Write-Output (Use-VaultKey) }
    "rotate-vault-key" { Update-VaultKey }
    "accept-new-vault-key" { Approve-NewVaultKey }
    "rotate-key" { Require-Docker; Load-State; Invoke-Compose exec -T --user 10001:10001 nodestro nodestro-local rotate-key; Invoke-Compose restart nodestro; Invoke-Compose up -d --wait --wait-timeout 300; Open-Browser }
    "uninstall" {
        Require-Docker; Load-State
        if ($Rest -contains "--delete-data") {
            Invoke-Compose down -v; Test-Native { docker volume rm (Get-Volume "data-before-update") } | Out-Null
            # The key file is of no use without the data; the launcher created it, so it removes it.
            $key = Get-VaultKeyFile
            Remove-Item -LiteralPath $key, "$key.new" -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Split-Path -Parent $key) -ErrorAction SilentlyContinue
            Write-Host "Nodestro and all its data were removed, and the key file $key."
        }
        else { Invoke-Compose down; Write-Host "Nodestro was removed; its data volume is kept." }
    }
    { $_ -in "help", "-h", "--help" } { Write-Output $Usage }
    default { Fail "Unknown command $Command (see .\nodestro.ps1 help)" }
}
