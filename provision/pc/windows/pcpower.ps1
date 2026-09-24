<#
.SYNOPSIS
    Power-state dispatcher for the PC, invoked over SSH by the Pi.

.DESCRIPTION
    Installed at C:\ProgramData\pcctl\pcpower.ps1 and wired up as the forced
    command for the Pi's SSH key, so that key can do exactly these four things
    and nothing else — no shell, no file access, no lateral movement if the Pi
    is ever compromised.

    The action arrives in $env:SSH_ORIGINAL_COMMAND (what the Pi typed after the
    host name) rather than as a parameter, because sshd replaces the client's
    command with this script.

.PARAMETER Action
    sleep | hibernate | shutdown | status. Overrides SSH_ORIGINAL_COMMAND when
    the script is run by hand for testing.

.NOTES
    sleep uses SetSuspendState(hibernate:$false) rather than the usual
    `rundll32 powrprof.dll,SetSuspendState` shim, which ignores its arguments
    and hibernates whenever hibernation is enabled. The explicit P/Invoke is the
    only way to ask for S3 on a machine that also keeps hibernation available.
#>
[CmdletBinding()]
param(
    [ValidateSet('sleep', 'hibernate', 'shutdown', 'status')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'

if (-not $Action) {
    # Windows PowerShell 5.1 is what sshd launches, so no ?? / ternary here.
    $requested = ($env:SSH_ORIGINAL_COMMAND -split '\s+' | Where-Object { $_ })[0]
    if (-not $requested) { $requested = '<empty>' }
    if ($requested -notin @('sleep', 'hibernate', 'shutdown', 'status')) {
        Write-Error "refused: $requested is not one of sleep|hibernate|shutdown|status"
        exit 2
    }
    $Action = $requested
}

Add-Type -Namespace PcCtl -Name Power -MemberDefinition @'
[DllImport("powrprof.dll", SetLastError = true)]
public static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);
'@

switch ($Action) {
    'status' {
        # Printed back over SSH, so keep it to one line the Pi can log.
        $up = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        "up since $($up.ToString('s')); user=$env:USERNAME"
    }
    'sleep' {
        "entering sleep (S3)"
        # forceCritical:$true skips the "an app is blocking sleep" veto that
        # would otherwise leave the PC awake with nobody at the keyboard.
        [void][PcCtl.Power]::SetSuspendState($false, $true, $false)
    }
    'hibernate' {
        "entering hibernation (S4)"
        [void][PcCtl.Power]::SetSuspendState($true, $true, $false)
    }
    'shutdown' {
        "shutting down"
        # /f closes apps without prompting; without it a modal dialog can cancel
        # the shutdown and leave the PC running with no one to dismiss it.
        & shutdown.exe /s /f /t 5
    }
}
