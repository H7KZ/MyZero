<#
.SYNOPSIS
    Prepares a Windows PC to be woken and powered down by the Pi.

.DESCRIPTION
    Idempotent — re-running it is how you update the machine, same as the Pi's
    install.sh. It does five things:

      1. Arms the wired NIC for Wake-on-LAN (magic packet only) and stops
         Windows from powering the adapter down.
      2. Turns off Fast Startup, which explicitly disarms the NIC on shutdown.
      3. Installs and starts OpenSSH Server.
      4. Creates an unprivileged local account whose SSH key can only run
         sleep / hibernate / shutdown / status via a forced command.
      5. Prints the exact apps/pcctl/.env lines to paste on the Pi.

.PARAMETER PublicKey
    The Pi's SSH public key — either the key text itself or a path to a .pub
    file. Generate on the Pi with:  ssh-keygen -t ed25519 -f ~/.ssh/id_pcctl

.PARAMETER Adapter
    NIC name to arm. Defaults to the connected wired adapter.

.PARAMETER User
    Local account the Pi logs in as. Default: pcpower.

.PARAMETER DisableHibernation
    Also run `powercfg /hibernate off`. This makes "sleep" unambiguously S3 and
    removes Fast Startup for good, at the cost of losing hibernate and the
    hiberfil.sys disk space. Recommended if WoL-from-sleep is flaky for you.

.PARAMETER Report
    Change nothing; just print what the current state is.

.EXAMPLE
    # In an elevated PowerShell, from this folder:
    .\Setup-RemotePower.ps1 -PublicKey C:\Users\me\Downloads\id_pcctl.pub
#>
[CmdletBinding()]
param(
    [string]$PublicKey,
    [string]$Adapter,
    [string]$User = 'pcpower',
    [switch]$DisableHibernation,
    [switch]$Report
)

$ErrorActionPreference = 'Stop'
$InstallDir = 'C:\ProgramData\pcctl'

function Log-Info   { param($m) Write-Host "  [INFO]    $m" }
function Log-Ok     { param($m) Write-Host "  [  OK  ]  $m" -ForegroundColor Green }
function Log-Action { param($m) Write-Host "  [ACTION]  $m" -ForegroundColor Blue }
function Log-Warn   { param($m) Write-Host "  [WARN]    $m" -ForegroundColor Yellow }
function Log-Skip   { param($m) Write-Host "  [SKIP]    $m" -ForegroundColor DarkGray }
function Section    { param($t) Write-Host "`n=== $t ===`n" -ForegroundColor Magenta }

function Assert-Admin {
    $me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Must run from an elevated PowerShell (Run as Administrator).'
    }
}

# ── The NIC ───────────────────────────────────────────────────────────────
function Resolve-Adapter {
    if ($Adapter) { return Get-NetAdapter -Name $Adapter }

    # Wired only: Wi-Fi WoWLAN is a different, far less reliable mechanism, and
    # a USB dongle loses bus power at S5 so it can never wake the machine.
    $candidates = Get-NetAdapter -Physical |
        Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' } |
        Sort-Object -Property ifIndex

    if (-not $candidates) { throw 'No connected wired adapter found — pass -Adapter <name>.' }
    if ($candidates.Count -gt 1) {
        Log-Warn "Multiple wired adapters up; picking '$($candidates[0].Name)'. Override with -Adapter."
    }
    return $candidates[0]
}

function Enable-WakeOnLan {
    param($Nic)

    Log-Action "Arming '$($Nic.Name)' ($($Nic.InterfaceDescription)) for magic packets"

    # Magic-packet wake is the whole point, so a failure here is fatal.
    Set-NetAdapterPowerManagement -Name $Nic.Name -WakeOnMagicPacket Enabled
    Log-Ok 'WakeOnMagicPacket = Enabled'

    # Pattern wake stays disabled on purpose: it fires on ordinary broadcast
    # chatter and the PC would never stay asleep. Best-effort — plenty of
    # drivers don't expose it at all, and that's fine.
    try {
        Set-NetAdapterPowerManagement -Name $Nic.Name -WakeOnPattern Disabled -ErrorAction Stop
        Log-Ok 'WakeOnPattern = Disabled'
    } catch { Log-Skip 'WakeOnPattern not supported by this driver' }

    # Driver-level keyword, which some vendors gate independently of the above.
    foreach ($keyword in '*WakeOnMagicPacket', 'Wake on Magic Packet') {
        try {
            Set-NetAdapterAdvancedProperty -Name $Nic.Name -RegistryKeyword $keyword -RegistryValue 1 -ErrorAction Stop
            Log-Ok "advanced property '$keyword' = 1"
        } catch { Log-Skip "advanced property '$keyword' not offered by this driver" }
    }

    # Energy-Efficient Ethernet / "Green Ethernet" park the PHY at low power and
    # are a common reason a link light is dark (and WoL dead) while off.
    foreach ($keyword in '*EEE', 'EEE', 'Energy Efficient Ethernet', 'GreenEthernet', 'Green Ethernet', 'Advanced EEE') {
        try {
            Set-NetAdapterAdvancedProperty -Name $Nic.Name -RegistryKeyword $keyword -RegistryValue 0 -ErrorAction Stop
            Log-Ok "advanced property '$keyword' = 0 (disabled)"
        } catch { Log-Skip "advanced property '$keyword' not offered by this driver" }
    }

    # "Allow this device to wake the computer" — the PnP side of the switch.
    $wakeable = (powercfg /devicequery wake_programmable) -contains $Nic.InterfaceDescription
    if ($wakeable) {
        powercfg /deviceenablewake $Nic.InterfaceDescription | Out-Null
        Log-Ok "powercfg: '$($Nic.InterfaceDescription)' may wake the computer"
    } else {
        Log-Warn "powercfg does not list '$($Nic.InterfaceDescription)' as wake-programmable — check the BIOS first"
    }

    Disable-NicPowerSaving -Nic $Nic
}

function Disable-NicPowerSaving {
    param($Nic)

    # Deliberately NOT the PnPCapabilities registry value. Its bit meanings are
    # inconsistently documented, and the value most guides copy — 24 (0x18) —
    # disables the adapter's *wake* capability as well as its power-down,
    # quietly undoing everything above. This WMI class flips exactly the one
    # checkbox and nothing else.
    try {
        $pnp = (Get-CimInstance Win32_NetworkAdapter -Filter "GUID='$($Nic.InterfaceGuid)'" -ErrorAction Stop).PNPDeviceID
        if (-not $pnp) { throw 'adapter reports no PNPDeviceID' }

        $entries = @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction Stop |
            Where-Object { $_.InstanceName.StartsWith($pnp, [StringComparison]::OrdinalIgnoreCase) })
        if (-not $entries) { throw "no MSPower_DeviceEnable entry matching $pnp" }

        foreach ($entry in $entries) {
            try {
                Set-CimInstance -InputObject $entry -Property @{ Enable = $false } -ErrorAction Stop
            } catch {
                # Some driver stacks reject the CIM write but accept the older
                # WMI Put(). Only reachable on Windows PowerShell 5.1, where
                # Get-WmiObject still exists.
                if (-not (Get-Command Get-WmiObject -ErrorAction SilentlyContinue)) { throw }
                $legacy = Get-WmiObject -Namespace root\wmi -Class MSPower_DeviceEnable |
                    Where-Object { $_.InstanceName -eq $entry.InstanceName }
                $legacy.Enable = $false
                [void]$legacy.Put()
            }
        }
        Log-Ok '"Allow the computer to turn off this device to save power" unchecked'
    } catch {
        Log-Warn "Could not disable NIC power saving automatically: $($_.Exception.Message)"
        Log-Warn 'Uncheck it by hand — Device Manager -> the adapter -> Power Management ->'
        Log-Warn '  "Allow the computer to turn off this device to save power"'
    }
}

# ── Power policy ──────────────────────────────────────────────────────────
function Set-PowerPolicy {
    # Fast Startup (hybrid shutdown, S4) is the single most common reason WoL
    # "stops working after a shutdown": Windows deliberately disarms the NIC on
    # that transition, because users expect a shut-down PC to draw nothing.
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    Set-ItemProperty -Path $path -Name HiberbootEnabled -Value 0 -Type DWord
    Log-Ok 'Fast Startup disabled (HiberbootEnabled = 0)'

    if ($DisableHibernation) {
        powercfg /hibernate off
        Log-Ok 'Hibernation off — sleep is now unambiguously S3, hiberfil.sys reclaimed'
    } else {
        Log-Info 'Hibernation left as-is; pass -DisableHibernation if sleep behaves like hibernate'
    }

    # Wake timers on, so a scheduled task can also bring the machine up.
    powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1 | Out-Null
    powercfg /setactive SCHEME_CURRENT | Out-Null
    Log-Ok 'Wake timers enabled on the active AC power plan'
}

# ── SSH ───────────────────────────────────────────────────────────────────
function Install-SshServer {
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
    if ($cap.State -ne 'Installed') {
        Log-Action 'Installing OpenSSH Server'
        Add-WindowsCapability -Online -Name $cap.Name | Out-Null
    }
    Log-Ok "OpenSSH Server present ($($cap.Name))"

    Set-Service -Name sshd -StartupType Automatic
    if ((Get-Service sshd).Status -ne 'Running') { Start-Service sshd }
    Log-Ok 'sshd running, start type Automatic'

    if (-not (Get-NetFirewallRule -Name 'pcctl-sshd' -ErrorAction SilentlyContinue)) {
        # Scoped to the LAN: the Pi is the only thing that needs to reach it,
        # and this port should never be exposed to the internet.
        New-NetFirewallRule -Name 'pcctl-sshd' -DisplayName 'pcctl: OpenSSH (private networks)' `
            -Enabled True -Direction Inbound -Protocol TCP -LocalPort 22 `
            -Action Allow -Profile Private, Domain | Out-Null
        Log-Ok 'Firewall: TCP 22 allowed on private/domain profiles'
    } else {
        Log-Skip 'Firewall rule pcctl-sshd already present'
    }
}

function New-PowerAccount {
    param([string]$Name)

    if (-not (Get-LocalUser -Name $Name -ErrorAction SilentlyContinue)) {
        # A random password nobody ever learns: the account is reachable only by
        # the Pi's key, but a blank password would trip Windows' network-logon
        # policy and is worse to leave lying around.
        $bytes = [byte[]]::new(24)
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $secret = ConvertTo-SecureString ([Convert]::ToBase64String($bytes)) -AsPlainText -Force
        New-LocalUser -Name $Name -Password $secret -FullName 'pcctl remote power' `
            -Description 'Key-only account used by the Pi to sleep/shut down this PC' `
            -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
        Log-Ok "Created local account '$Name' (standard user — it keeps only the default Shut down the system right)"
    } else {
        Log-Skip "Local account '$Name' already exists"
    }

    # Keep it off the sign-in screen.
    $list = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
    if (-not (Test-Path $list)) { New-Item -Path $list -Force | Out-Null }
    Set-ItemProperty -Path $list -Name $Name -Value 0 -Type DWord
    Log-Ok "Hidden '$Name' from the sign-in screen"
}

function Install-Dispatcher {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Copy-Item -Path (Join-Path $PSScriptRoot 'pcpower.ps1') -Destination $InstallDir -Force
    # Readable by everyone (sshd runs the forced command as the Pi's account),
    # writable only by administrators — a writable dispatcher would hand that
    # account arbitrary code execution.
    icacls "$InstallDir\pcpower.ps1" /inheritance:r /grant 'BUILTIN\Administrators:F' /grant 'NT AUTHORITY\SYSTEM:F' /grant 'BUILTIN\Users:RX' | Out-Null
    Log-Ok "Dispatcher installed at $InstallDir\pcpower.ps1"
}

function Install-AuthorizedKey {
    param([string]$Name, [string]$Key)

    # A key always starts with its algorithm name; anything else is a path.
    # (Test-Path on the key text itself throws on the '/' and '+' in base64.)
    if ($Key -notmatch '^(ssh-|ecdsa-)') { $Key = Get-Content -LiteralPath $Key -Raw }
    $Key = $Key.Trim()
    if ($Key -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-\S+)\s') {
        throw "That does not look like an SSH public key: '$($Key.Substring(0, [Math]::Min(40, $Key.Length)))…'"
    }

    # The forced command is the whole security model: whatever the Pi asks for,
    # sshd runs this instead, and the dispatcher only honours four words.
    $forced = 'command="powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
              "$InstallDir\pcpower.ps1" +
              '",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding'
    $line = "$forced $Key"

    # Deliberately NOT C:\Users\<user>\.ssh: that profile folder does not exist
    # until the account first logs on, and pre-creating it makes Windows build
    # the real profile as "<user>.<HOSTNAME>" — after which sshd looks for the
    # key in a folder that no longer matches. A fixed path under ProgramData,
    # pinned by a Match block, has no such race.
    $file = Join-Path $InstallDir 'authorized_keys'
    $existing = if (Test-Path $file) { Get-Content $file } else { @() }
    $keyBody = ($Key -split '\s+')[1]
    if ($existing | Where-Object { $_ -like "*$keyBody*" }) {
        # Rewrite rather than append: the forced command may have changed.
        $existing = $existing | Where-Object { $_ -notlike "*$keyBody*" }
        Log-Info 'Key already present — rewriting its options'
    }
    # ASCII, not the UTF-8-with-BOM that Set-Content defaults to on PS 5.1:
    # sshd treats the BOM as part of the first key and silently ignores the line.
    Set-Content -Path $file -Value (@($existing) + $line | Where-Object { $_ }) -Encoding ascii

    # sshd reads this as SYSTEM and refuses a file anyone else can write.
    icacls $file /inheritance:r /grant 'BUILTIN\Administrators:F' /grant 'NT AUTHORITY\SYSTEM:F' | Out-Null
    Log-Ok "Authorized key installed at $file with a forced command"

    Add-SshdMatchBlock -Name $Name -KeyFile $file
}

function Add-SshdMatchBlock {
    param([string]$Name, [string]$KeyFile)

    $config = 'C:\ProgramData\ssh\sshd_config'
    $marker = "# pcctl: key location for $Name"
    $body = @(
        '',
        $marker,
        "Match User $Name",
        "    AuthorizedKeysFile $($KeyFile -replace '\\', '/')"
    )

    $lines = if (Test-Path $config) { Get-Content $config } else { @() }
    if ($lines -contains $marker) {
        Log-Skip 'sshd_config already carries the pcctl Match block'
        return
    }
    # Match blocks run to the next Match or EOF, so this must be appended last.
    Add-Content -Path $config -Value $body -Encoding ascii
    Restart-Service sshd
    Log-Ok 'sshd_config: added Match block and restarted sshd'
}

# ── Report ────────────────────────────────────────────────────────────────
function Show-Report {
    param($Nic)

    Section 'Current state'
    $mac = $Nic.MacAddress
    $ip = (Get-NetIPAddress -InterfaceIndex $Nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
    Log-Info "Adapter:       $($Nic.Name) — $($Nic.InterfaceDescription)"
    Log-Info "MAC:           $mac"
    Log-Info "IPv4:          $ip"

    $pm = Get-NetAdapterPowerManagement -Name $Nic.Name
    Log-Info "WakeOnMagicPacket: $($pm.WakeOnMagicPacket)   WakeOnPattern: $($pm.WakeOnPattern)"

    $hiberboot = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
    Log-Info "Fast Startup:  $(if ($hiberboot -eq 0) { 'off (good)' } else { 'ON — WoL after shutdown will not work' })"
    Log-Info "Wake-armed devices:"
    powercfg /devicequery wake_armed | ForEach-Object { Write-Host "                 $_" }

    Section 'Paste into apps/pcctl/.env on the Pi'
    $prefix = if ($ip) { ($ip -split '\.')[0..2] -join '.' } else { '192.168.1' }
    Write-Host "PC_MAC=$mac"
    Write-Host "PC_HOST=$ip"
    Write-Host 'PC_PROBE_PORT=22'
    Write-Host "WOL_BROADCASTS=$prefix.255,255.255.255.255"
    Write-Host "SLEEP_COMMAND=ssh -i /home/pi/.ssh/id_pcctl -o BatchMode=yes -o ConnectTimeout=5 $User@$ip sleep"
    Write-Host "SHUTDOWN_COMMAND=ssh -i /home/pi/.ssh/id_pcctl -o BatchMode=yes -o ConnectTimeout=5 $User@$ip shutdown"
    Write-Host ''
    Log-Info "Give the PC a DHCP reservation so PC_HOST stays $ip."
}

# ── Main ──────────────────────────────────────────────────────────────────
Assert-Admin
$nic = Resolve-Adapter

if ($Report) { Show-Report -Nic $nic; return }

Section 'Wake-on-LAN'
Enable-WakeOnLan -Nic $nic

Section 'Power policy'
Set-PowerPolicy

Section 'Remote power-down over SSH'
if ($PublicKey) {
    Install-SshServer
    New-PowerAccount -Name $User
    Install-Dispatcher
    Install-AuthorizedKey -Name $User -Key $PublicKey
} else {
    Log-Skip 'No -PublicKey given — skipping SSH setup. Wake will work; sleep/shutdown will not.'
}

Show-Report -Nic $nic

Section 'Still to do by hand'
Log-Warn 'BIOS/UEFI: enable "Wake on LAN" / "Resume by PCI-E Device" / "Power On by PCIE", and set ErP/EuP Ready to Disabled.'
Log-Warn 'Some driver keyword changes only take effect after a reboot (or Restart-NetAdapter).'
Log-Warn 'Verify from the Pi:  pcctl status  ->  pcctl sleep  ->  pcctl wake --wait'
