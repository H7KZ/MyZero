# PC side (Windows)

These two scripts run on **the PC you want to wake**, not on the Pi.

| File                    | What it does                                                                        |
|-------------------------|-------------------------------------------------------------------------------------|
| `Setup-RemotePower.ps1` | One-shot, idempotent setup: arms the NIC, kills Fast Startup, installs the SSH hook |
| `pcpower.ps1`           | The dispatcher it installs to `C:\ProgramData\pcctl\` — sleep/hibernate/shutdown    |

## Run it

```powershell
# 1. On the Pi, get the public key (install.sh with INSTALL_PCCTL=yes prints it):
#      cat ~/.ssh/id_pcctl.pub
# 2. On the PC, in an ELEVATED PowerShell:

.\Setup-RemotePower.ps1 -Report                    # look before you touch anything
.\Setup-RemotePower.ps1 -PublicKey .\id_pcctl.pub  # apply
```

Useful switches:

| Switch                 | Effect                                                                                     |
|------------------------|--------------------------------------------------------------------------------------------|
| `-Report`              | Change nothing; print NIC, MAC, wake-armed devices and the `.env` lines to paste            |
| `-Adapter <name>`      | Pick the NIC by hand instead of "the connected wired one"                                   |
| `-User <name>`         | The unprivileged local account the Pi logs in as (default `pcpower`)                        |
| `-DisableHibernation`  | `powercfg /hibernate off` — makes sleep unambiguously S3 and removes Fast Startup for good  |

Re-running is the update path, same as the Pi's `install.sh`.

## What it changes

1. **NIC** — `WakeOnMagicPacket` on, `WakeOnPattern` off (pattern wake fires on ordinary broadcast traffic and the PC
   would never stay asleep), Energy-Efficient/Green Ethernet off, `powercfg /deviceenablewake`, and `PnPCapabilities`
   set so Windows may not power the adapter down.
2. **Power policy** — `HiberbootEnabled = 0`. Fast Startup is a hybrid shutdown into S4, and Windows *deliberately*
   disarms the NIC on that transition; it is the most common reason WoL "stops working after a shutdown".
3. **OpenSSH Server** — installed, set to Automatic, firewall opened on **private/domain profiles only**.
4. **A standard local account** (`pcpower`, random password, hidden from the sign-in screen) whose key is pinned to a
   **forced command**. That key can run `sleep`, `hibernate`, `shutdown`, `status` — and nothing else. No shell, no
   file access, no lateral movement if the Pi is ever compromised.

The key lives at `C:\ProgramData\pcctl\authorized_keys` with a `Match User` block in `sshd_config`, rather than in the
account's profile — `C:\Users\pcpower\` doesn't exist until first logon, and pre-creating it makes Windows build the
real profile as `pcpower.HOSTNAME`, after which sshd looks somewhere else for the key.

## Still yours to do

**In the UEFI/BIOS** — no script can reach these:

- `Wake on LAN` / `Resume by PCI-E Device` / `Power On By PCIE` → **Enabled**
- `ErP Ready` / `EuP` → **Disabled**. ErP cuts the standby rail; if the Ethernet LED is dark with the PC off, this is
  almost always the reason.

**Check the result:**

```powershell
powercfg /a                        # is "Standby (S3)" available, or only Modern Standby?
powercfg /devicequery wake_armed   # your NIC should be in this list
```

Then from the Pi: `./pcctl status` → `./pcctl sleep` → `./pcctl wake --wait`.

## Testing the dispatcher by hand

```powershell
& 'C:\ProgramData\pcctl\pcpower.ps1' -Action status
ssh -i ~/.ssh/id_pcctl pcpower@<pc-ip> status     # from the Pi — should print uptime
ssh -i ~/.ssh/id_pcctl pcpower@<pc-ip> whoami     # should be REFUSED
```

That last line failing is the security model working.

Background and the Linux equivalent: [`docs/remote-pc-control.md`](../../../docs/remote-pc-control.md).
