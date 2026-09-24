<#
.SYNOPSIS
    Provisions a Pi Zero 2 W from Windows: SSH key setup, staged binaries,
    copies provision/ to the Pi, runs install.sh, offers a reboot.

.DESCRIPTION
    PowerShell 5.1-compatible. Uses only the Windows 11 OpenSSH client and
    tar.exe - no ssh-copy-id, sshpass, or rsync required. The Pi's default
    user/password (zero/zero) is never written to disk; ssh prompts for the
    password exactly once, to install the generated key.

.PARAMETER TargetHost
    Pi hostname or IP. Defaults to the PI_HOSTNAME from provision/pizero.conf
    (as "<PI_HOSTNAME>.local") if that file exists, else "raspberrypi.local".

.PARAMETER User
    Pi Zero 2 W default user. Default: zero.

.PARAMETER Bin
    Names of built binaries under target/aarch64-unknown-linux-gnu/release/
    to stage into provision/bin/ before copying (and their apps/<bin>/.env,
    if present, staged as provision/bin/<bin>.env).

.PARAMETER NoHarden
    Skip disabling SSH password authentication on the Pi (install.sh still
    only disables it if a key is on file - this just opts out entirely).

.PARAMETER DryRun
    Passes --dry-run through to install.sh on the Pi.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File provision/bootstrap.ps1

.EXAMPLE
    provision\bootstrap.ps1 -Bin clapper,pcctl -TargetHost 192.168.1.42
#>
[CmdletBinding()]
param(
    [string]$TargetHost,
    [string]$User = "zero",
    [string[]]$Bin = @(),
    [switch]$NoHarden,
    [switch]$DryRun
)

# "Continue", not "Stop": under Windows PowerShell 5.1, anything a native
# exe (ssh, tar) writes to stderr - even "Permanently added ... to known
# hosts" - becomes a terminating NativeCommandError with "Stop". Native calls
# are checked via $LASTEXITCODE; cmdlets opt in with -ErrorAction Stop.
$ErrorActionPreference = "Continue"

$RepoRoot     = Split-Path -Parent $PSScriptRoot
$ProvisionDir = Join-Path $RepoRoot "provision"
$KeysDir      = Join-Path $RepoRoot ".keys"
$KeyPath      = Join-Path $KeysDir "id_ed25519_pizero"
$PubKeyPath   = "$KeyPath.pub"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok   { param([string]$m) Write-Host "    [ok] $m" -ForegroundColor Green }
function Write-Note { param([string]$m) Write-Host "    $m" }
function Write-Warn2{ param([string]$m) Write-Host "    [warn] $m" -ForegroundColor Yellow }

function Fail {
    param([string]$Message)
    Write-Host ""
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

# -- Resolve target host -----------------------------------------
if (-not $TargetHost) {
    $confPath = Join-Path $ProvisionDir "pizero.conf"
    $hostname = $null
    if (Test-Path $confPath) {
        $line = Select-String -Path $confPath -Pattern '^\s*PI_HOSTNAME\s*=\s*"?([^"]+)"?' -ErrorAction SilentlyContinue
        if ($line) { $hostname = $line.Matches[0].Groups[1].Value.Trim() }
    }
    if ($hostname) { $TargetHost = "$hostname.local" } else { $TargetHost = "raspberrypi.local" }
}
$Target = "$User@$TargetHost"
Write-Host "Provisioning target: $Target" -ForegroundColor White

# =================================================================
# Stage 1: SSH keypair under .keys/
# =================================================================
Write-Step "Stage 1/6: SSH keypair"
try {
    if (-not (Test-Path $KeysDir)) {
        New-Item -ItemType Directory -Path $KeysDir -ErrorAction Stop | Out-Null
    }

    # Make sure .keys/ is gitignored (repo .gitignore should already have
    # this, but be defensive in case someone deletes the line).
    $gitignore = Join-Path $RepoRoot ".gitignore"
    if (Test-Path $gitignore) {
        $content = Get-Content $gitignore -Raw -ErrorAction SilentlyContinue
        if ($null -eq $content -or $content -notmatch '(?m)^\s*/?\.keys/?\s*$') {
            Add-Content -Path $gitignore -Value "`n/.keys/" -ErrorAction Stop
            Write-Ok "Added /.keys/ to .gitignore"
        }
    }

    if (Test-Path $KeyPath) {
        Write-Ok "Key already exists: $KeyPath"
    } else {
        if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
            Fail "ssh-keygen not found. Install the Windows OpenSSH Client optional feature."
        }
        # PowerShell 5.1 drops empty-string arguments passed to native exes,
        # which shifts every argument after -N. The documented workaround is
        # to pass a literal two-double-quote token instead of "".
        & ssh-keygen -t ed25519 -N '""' -C "pizero" -f $KeyPath
        if ($LASTEXITCODE -ne 0) { Fail "ssh-keygen failed (exit $LASTEXITCODE)" }
        if (-not (Test-Path $KeyPath) -or -not (Test-Path $PubKeyPath)) {
            Fail "ssh-keygen did not produce $KeyPath / $PubKeyPath"
        }
        Write-Ok "Generated $KeyPath"
    }
} catch {
    Fail "SSH keypair setup failed: $_"
}

# =================================================================
# Stage 2: install pubkey on the Pi (one password prompt, skipped if
# key login already works)
# =================================================================
Write-Step "Stage 2/6: Install public key on the Pi"
try {
    $keyWorks = $false
    & ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new `
        -i $KeyPath $Target "true" 2>$null
    if ($LASTEXITCODE -eq 0) { $keyWorks = $true }

    if ($keyWorks) {
        Write-Ok "Key login already works - skipping password prompt"
    } else {
        Write-Note "Enter the Pi's password when prompted (default user 'zero' password is 'zero' unless you changed it)."
        $pub = Get-Content $PubKeyPath -Raw -ErrorAction Stop
        $remoteCmd = "umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys"
        # Pipe the public key into ssh's stdin - one password prompt, no
        # ssh-copy-id / sshpass needed.
        $pub | & ssh -o StrictHostKeyChecking=accept-new $Target $remoteCmd
        if ($LASTEXITCODE -ne 0) { Fail "Failed to install public key on $Target (exit $LASTEXITCODE)" }
        Write-Ok "Public key installed on $Target"
    }
} catch {
    Fail "Public key install failed: $_"
}

# =================================================================
# Stage 3: verify key login
# =================================================================
Write-Step "Stage 3/6: Verify key login"
try {
    & ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new `
        -i $KeyPath $Target "true"
    if ($LASTEXITCODE -ne 0) {
        Fail "Key login verification failed (exit $LASTEXITCODE). Aborting before touching SSH hardening."
    }
    Write-Ok "Key login verified"
} catch {
    Fail "Key login verification failed: $_"
}

# =================================================================
# Stage 4: stage binaries, then copy provision/ via tar-over-ssh
# =================================================================
Write-Step "Stage 4/6: Stage binaries and copy provision/"
try {
    $binDir = Join-Path $ProvisionDir "bin"
    if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -ErrorAction Stop | Out-Null }

    foreach ($b in $Bin) {
        $src = Join-Path $RepoRoot "target\aarch64-unknown-linux-gnu\release\$b"
        $dst = Join-Path $binDir $b
        if (Test-Path $src) {
            Copy-Item -Path $src -Destination $dst -Force -ErrorAction Stop
            Write-Ok "Staged binary: provision/bin/$b"
        } else {
            Write-Warn2 "Binary not found, skipping: $src (build it first: cross build -p $b --target aarch64-unknown-linux-gnu --release)"
        }
        $envSrc = Join-Path $RepoRoot "apps\$b\.env"
        $envDst = Join-Path $binDir "$b.env"
        if (Test-Path $envSrc) {
            Copy-Item -Path $envSrc -Destination $envDst -Force -ErrorAction Stop
            Write-Ok "Staged env: provision/bin/$b.env"
        }
    }

    $confPath = Join-Path $ProvisionDir "pizero.conf"
    if (-not (Test-Path $confPath)) {
        Write-Warn2 "provision/pizero.conf not found - install.sh will refuse to run without it."
        Write-Warn2 "Create it first: cp provision/pizero.conf.example provision/pizero.conf"
    }

    if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
        Fail "tar.exe not found. Windows 11 ships it; check your PATH."
    }

    # tar-over-ssh: fastest transfer without rsync. Extracts to a staging
    # dir on the Pi, then atomically swaps it into place.
    $remoteCopyCmd = "rm -rf ~/provision.new && mkdir -p ~/provision.new && tar -xf - -C ~/provision.new && rm -rf ~/provision && mv ~/provision.new ~/provision"
    Push-Location $ProvisionDir
    try {
        & tar -cf - -C $ProvisionDir . | & ssh -i $KeyPath $Target $remoteCopyCmd
        if ($LASTEXITCODE -ne 0) { Fail "Copy to Pi failed (exit $LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
    Write-Ok "provision/ copied to ~/provision on the Pi"
} catch {
    Fail "Copy stage failed: $_"
}

# =================================================================
# Stage 5: run install.sh on the Pi
# =================================================================
Write-Step "Stage 5/6: Run install.sh on the Pi"
try {
    $installArgs = "--no-reboot"
    if ($DryRun) { $installArgs = "$installArgs --dry-run" }

    $env:SSH_HARDEN_DISPLAY = if ($NoHarden) { "0" } else { "1" }
    $sshHardenPrefix = if ($NoHarden) { "" } else { "SSH_HARDEN=1 " }

    Write-Note "Streaming install.sh output (sudo may prompt on the Pi if zero has a sudo password)..."
    & ssh -t -i $KeyPath $Target "sudo env ${sshHardenPrefix}bash ~/provision/scripts/install.sh $installArgs"
    if ($LASTEXITCODE -ne 0) {
        Fail "install.sh exited with code $LASTEXITCODE - check the output above."
    }
    Write-Ok "install.sh completed"
} catch {
    Fail "install.sh run failed: $_"
}

# =================================================================
# Stage 6: next steps + optional reboot
# =================================================================
Write-Step "Stage 6/6: Done"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor White
Write-Host ("  Log in with the key:   ssh -i " + '"' + $KeyPath + '"' + " $Target")
Write-Host "  Copy .keys/ somewhere safe, then delete it from the repo checkout."
Write-Host "  If install.sh armed a rollback timer, confirm the config once you're"
Write-Host ("  happy with it:         ssh -i " + '"' + $KeyPath + '"' + " $Target " + '"sudo pizero-confirm"')
Write-Host ""

$reboot = Read-Host "Reboot the Pi now? [y/N]"
if ($reboot -match '^[Yy]') {
    Write-Note "Rebooting $Target ..."
    & ssh -i $KeyPath $Target "sudo reboot" 2>$null
    Write-Note "Waiting for the Pi to come back..."
    Start-Sleep -Seconds 15
    $back = $false
    for ($i = 0; $i -lt 20; $i++) {
        & ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new `
            -i $KeyPath $Target "true" 2>$null
        if ($LASTEXITCODE -eq 0) { $back = $true; break }
        Start-Sleep -Seconds 5
    }
    if ($back) {
        Write-Ok "Pi is back up - confirming rollback is not needed"
        & ssh -i $KeyPath $Target "sudo pizero-confirm" 2>$null
        Write-Ok "Provisioning complete."
    } else {
        Write-Warn2 "Could not reconnect after reboot within the timeout."
        Write-Warn2 "If WiFi/SSH broke, the Pi's rollback timer will revert it automatically."
    }
} else {
    Write-Note ("Reboot skipped. Reboot manually when ready: ssh -i " + '"' + $KeyPath + '"' + " $Target " + '"sudo reboot"')
}
