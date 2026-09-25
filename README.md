# Pi Brutal Upgrader

__Warning__: This might all go wrong. It might mess up your sdcard requiring a physical action of a fresh image write with a card reader. Me and Claude wrote this, but I'll say Claude did it if anything goes wrong.

If this works for you, as it did for me, it'll wipe a Raspberry Pi over SSH and reinstall the latest Raspberry Pi OS Lite onto the disk it is running from. No SD card swap and no physical access. The new system boots with the same hostname, user, password, SSH keys and IP address,
so you can log straight back in.

> **This erases the boot disk completely.** Anything on the Pi is will be lost. Other disks attached to the Pi are not touched.

## Why

An old release on a Pi that has been running for years might not be automatically upgradable anymore, even if it ever was. A clean install is nice, but it normally means pulling the SD card and reflashing it on another machine. This script does the reflash on the Pi itself, from RAM, during a reboot. Crazy stuff.

## Quick start

```sh
# Let's pretend your Pi has IP address 10.7.7.7 assigned, 7 is a lucky number.
scp brutal-upgrader.sh pi@10.7.7.7:
ssh pi@10.7.7.7

sudo ./brutal-upgrader.sh --help        # read this a gasp

# You might want to add --keep-staging to these, otherwise the RaspberryPi image will be downloaded in each run,

# Check everything we can, change nothing
sudo ./brutal-upgrader.sh --dry-run --keep-staging      

# Full reboot cycle, no OS write. Optional but recommended. See --help.
sudo ./brutal-upgrader.sh --rehearsal   

# The real thing. It'll get everything ready and ask you to type a confirmation. Anything but the confirmation will abort.
# --keep-staging because if you abort by mistake you'll need to download the image again
sudo ./brutal-upgrader.sh --keep-staging

```

After the real run, allow roughly 2 minutes for staging, 1–2 for shutdown,
2–6 for the flash, then a few minutes for the new OS's first boot, which may
reboot once on its own. Then:

```sh
ssh-keygen -R 10.7.7.7    # delete old cached host keys 
ssh pi@10.7.7.7
```

## Requirements

- A Raspberry Pi running Raspberry Pi OS or Debian 11 (buster) or later, with
  systemd.
- Root and boot partitions on the same disk (SD card, USB or NVMe), with the
  boot partition (FAT) mounted at `/boot` or `/boot/firmware`.
- A **wired** default route. No wireless stuff, because the new OS would come up without wireless interface,
- Enough free RAM for the compressed image plus about 400 MB (around 1 GB in total). Swap is turned off before the reboot, so it doesn't count.
- `curl` or `wget`, `xz`, and the usual coreutils/util-linux tools. `python3`
  (or `jq`) is used to read Raspberry Pi's image metadata, and `python3-yaml`,
  if present, to validate the generated config.
- The user you run it as (`$SUDO_USER`, or `--user`) needs SSH keys or a
  password.
- The target image must set itself up with cloud-init, which means Trixie
  (Raspberry Pi OS 13) or later.

The image is 64-bit (arm64) on every Pi that can run it (Pi 3, 4, 5, 400,
500, Zero 2 W, CM3/4/5), even if the current OS is 32-bit. Older models get
the 32-bitimage.

## Usage

```
sudo ./brutal-upgrader.sh [mode] [options]
```

| Mode | What it does |
|---|---|
| *(none)* | Real run: preflight, staging, typed confirmation, reboot, flash. |
| `--dry-run` | Preflight, download, verify and build everything, print the generated config, then clean up. Changes nothing. |
| `--rehearsal` | Reboot into the RAM environment exactly like a real run, bring up the network and rescue SSH, run every pre-write check, wait, then reboot into the unchanged current OS. Writes nothing to the disk. |
| `--disarm` | Cancel an armed run before the reboot happens. |

| Option | Meaning |
|---|---|
| `--yes-destroy-everything` | Skip the typed `ERASE <disk>` confirmation. |
| `--yes` | Skip the confirmation for `--rehearsal`. |
| `--image-url URL` | Flash this `.img.xz` instead of the latest Lite image. |
| `--image-sha256 HEX` | Expected sha256 of the `.img.xz` (default: fetched from `URL.sha256`). |
| `--dhcp` | New OS uses DHCP instead of the current address as a static IP. |
| `--hostname NAME` | Hostname for the new OS (default: the current one). |
| `--user NAME` | User to carry over (default: `$SUDO_USER`). |
| `--no-rescue-ssh` | Don't put the dropbear SSH server into the RAM environment. |
| `--no-backup` | Don't put the config backup onto the new boot partition. |
| `--keep-staging` | With `--dry-run`: keep the staged files in `/run` so a later run reuses the download. |
| `--rehearsal-wait SEC` | How long the rehearsal stays in RAM before rebooting (default 120). |

## New OS setup

The script writes a cloud-init configuration (`user-data`, `network-config`,
`meta-data`) into the new image's boot partition. On first boot it sets up:

- **Hostname**, timezone, and keyboard model and layout, taken from the current
  system.
- **One user** with the same name, the same password hash and every key from
  `~/.ssh/authorized_keys`. Passwordless sudo is kept if the user has it now.
  SSH password login is enabled only if it is enabled now and the user has a
  password.
- **Network** on Ethernet through NetworkManager: the current address, prefix,
  gateway, DNS servers and search domains as a static configuration, or DHCP
  with `--dhcp`. The onboard NIC is configured as `eth0`. A USB adapter is
  matched by its MAC address.
- **SSH** enabled.
- `cmdline.txt` without `splash`/`plymouth.*`, so the console stays readable.

It also puts `pre-upgrade-backup.tar.gz` on the new boot partition, unless you
pass `--no-backup` or it doesn't fit. The archive holds the old `/etc`, without
`shadow`, `gshadow` or SSH host private keys, along with the package
selections, manually installed packages, root's and the user's crontabs, the
enabled systemd units, the IP configuration, and the old `config.txt` and
`cmdline.txt`. It is there to help you rebuild the setup, not to be restored
wholesale. The boot partition is FAT and readable by anyone with the card, and
`/etc` can contain Wi-Fi passwords or other secrets, so move or delete the
file once you have what you need.

### What does not carry over

Everything else: installed packages, services, data, other users, cron jobs,
Wi-Fi and any access point setup, custom `config.txt` settings, and the SSH
host keys (you will get a host key warning). The bootloader EEPROM is not
changed. The preflight summary shows its version, so you can update it
separately if you want.

## How it works

Linux can't overwrite the disk it is running from while it is running. The
script uses a systemd feature meant for initramfs cleanup: if
`/run/initramfs/shutdown` exists, then at the very end of shutdown, after every
process has been killed and every filesystem unmounted or remounted read-only,
`systemd-shutdown` switches root into `/run/initramfs` (a tmpfs) and runs that
script as PID 1. From there the old root can be released and the whole disk
rewritten.

1. **Preflight.** Detect the model, boot disk, network, user and settings.
   Resolve the latest image and its checksums, check RAM and disk size, and
   print a summary of what will be destroyed and what the new system will look
   like.
2. **Staging, entirely in RAM (`/run`, grown as needed):**
   - Download the `.img.xz` and check its sha256.
   - Decompress the whole image once to check it against the raw-image sha256
     and size published in Raspberry Pi Imager's metadata.
   - Extract the image's boot partition, write the cloud-init config and the
     backup into it, and record its sha256.
   - Build a small root filesystem from the host's own binaries and libraries
     (bash, dd, xz, sha256sum, ip, …). If rescue SSH is enabled, add dropbear:
     it is downloaded from the package archive and unpacked, not installed, and
     it uses the current SSH host keys.
   - Self-test that root in a chroot.
3. **Arm.** Ask for confirmation, turn off swap, mask plymouth for this
   shutdown only (`systemctl mask --runtime`), move the RAM root to
   `/run/initramfs`, and reboot.
4. **Flash, as PID 1 in RAM:**
   - Bring up the network with the current IP and start rescue SSH.
   - Unmount the old root and make sure nothing on the disk is still mounted
     read-write.
   - Check that the disk still has the recorded size and model, and re-check
     the image and boot partition in RAM against their checksums.
   - Write the image with `dd`, read the whole thing back and compare its
     sha256.
   - Write the prepared boot partition and read that back too.
   - Copy the log onto the new boot partition and reboot.

## Safety nets

- Nothing touches the disk until the compressed image, the decompressed image
  and the prepared boot partition have all been checksum-verified. The copies
  in RAM are checked again right before writing.
- **Any failure before the first write reboots into the untouched old OS.** If
  `/shutdown` can't start at all, `systemd-shutdown` just carries on with a
  normal reboot.
- Only a reboot flashes. If the Pi is powered off or halted while armed, it
  just powers off and the disk is left untouched.
- Arming lives only in tmpfs: `--disarm` or a power cycle cancels it.
- The script won't arm if something else (dracut, for example) already uses
  `/run/initramfs`. On systems that boot through an initramfs-tools
  initramfs, the fsck logs it leaves in `/run/initramfs` are kept, and `/run`
  (which it mounts `noexec`) is remounted `exec`.
- An active hardware watchdog keeps being fed in the RAM environment.
- **Once writing has started, a failure is retried up to 3 times.** If it
  still fails, the Pi does *not* reboot into a half-written disk. It stays up
  in RAM with the network configured and the image still in memory, so you can
  log in and fix it.

## Watching and rescuing a flash

If rescue SSH is available (the preflight summary says so), you can log in as
root at the Pi's current IP while it is in the RAM environment. It uses the
same host key as before, so there is no warning:

```sh
ssh root@10.7.7.7 'tail -f /log'
```

Inside the RAM environment:

| | |
|---|---|
| `/log` | Flash log |
| `/progress` | `dd` progress |
| `/shutdown flash` | Retry the flash (and reboot on success) |
| `/shutdown reboot-now` | Reboot immediately |
| `/shutdown poweroff-now` | Power off immediately |

Rescue SSH accepts the carried-over user's keys and root's keys, key
authentication only.

Where the log ends up:

- After a successful flash: `/boot/firmware/brutal-upgrader.log` on the new OS.
- After a rehearsal or an aborted run: `brutal-upgrader-rehearsal.log` or
  `brutal-upgrader-real.log` on the old boot partition.

## Recommended workflow

1. Copy off everything you want to keep. The preflight summary lists the
   largest directories on the disk as a reminder.
2. If you keep the static IP, make sure your router won't hand that address to
   another device.
3. Run `--dry-run` and read the generated `user-data` and `network-config`.
4. Run `--rehearsal` once, ideally logging in over rescue SSH while it waits.
   This proves the RAM environment, network and SSH work on your hardware
   before anything is at stake.
5. Do the real run.

## Status

`--dry-run` and `--rehearsal` have been run on a Raspberry Pi 4 Model B
running Debian 11 (bullseye) from a USB disk. The flash-and-verify stage has
been tested against a scratch disk image, including a deliberately wrong
checksum. Use at your own risk.

## References

- [Cloud-init on Raspberry Pi OS](https://www.raspberrypi.com/news/cloud-init-on-raspberry-pi-os/)
- [Raspberry Pi Imager source](https://github.com/raspberrypi/rpi-imager): how Imager writes cloud-init config (`customization_generator.cpp`)
- [Imager OS list](https://downloads.raspberrypi.com/os_list_imagingutility_v4.json): the source of the raw-image checksums
- [`systemd-shutdown`](https://www.freedesktop.org/software/systemd/man/latest/systemd-shutdown.html): the `/run/initramfs/shutdown` hook
