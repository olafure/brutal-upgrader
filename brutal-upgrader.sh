#!/bin/bash
#
# brutal-upgrader.sh - remotely wipe a Raspberry Pi and reinstall the latest
# Raspberry Pi OS Lite onto the disk it is currently running from.
#
# How it works (systemd "exitrd"):
#   1. Preflight: detect model, boot disk, network, user, image; print a summary.
#   2. Stage in RAM (/run): download + verify the .img.xz, extract the image's
#      boot partition, drop cloud-init first-boot config into it (hostname, user,
#      password hash, SSH keys, static IP), build a tiny RAM root from host
#      binaries (+ optional dropbear rescue SSH).
#   3. Arm: move the RAM root to /run/initramfs and reboot. At the very end of
#      shutdown - after every process is killed and every filesystem unmounted or
#      read-only - systemd-shutdown switch_roots into /run/initramfs and execs
#      /shutdown as PID 1. That script flashes the disk, verifies it by reading
#      it back, writes the prepared boot partition and reboots.
#
# Safety nets:
#   - Nothing is written before the image, its decompressed content and the
#     prepared boot partition have been checksum-verified.
#   - Any failure *before* the first disk write reboots into the untouched old OS.
#     If /shutdown cannot even start, systemd-shutdown simply reboots normally.
#   - Once writing has started, failures are retried; if it still fails the Pi
#     stays up in RAM with the network configured and (if available) dropbear
#     SSH for root, so it can be fixed by hand. The image stays in RAM.
#   - --dry-run and --rehearsal exercise everything except the disk writes.
#   - Arming lives in tmpfs: --disarm or a power cycle cancels it.
#
# Requires: Raspberry Pi running Raspberry Pi OS / Debian 10 (buster) or later
# with systemd, root, and a wired network connection. Booting through an
# initramfs-tools initramfs (Bookworm) is fine: its fsck logs in /run/initramfs
# are kept, and /run (mounted noexec by it) is remounted exec while staging.

set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

SCRIPT_VERSION=1.0
STAGE=/run/brutal-upgrader
ROOT=$STAGE/root
MNT=$STAGE/mnt
EXITRD=/run/initramfs
MARKER=.brutal-upgrader
HOST_LOG=$STAGE/host.log
IMAGER_JSON_URL=https://downloads.raspberrypi.com/os_list_imagingutility_v4.json
DL_BASE=https://downloads.raspberrypi.com

MODE=real            # real | dry-run | rehearsal | disarm
ASSUME_YES=0
DESTROY_YES=0
IMAGE_URL=
IMAGE_SHA256=
NET_MODE=static
RESCUE_SSH=1
BACKUP=1
NEW_HOSTNAME=
NEW_USER=
KEEP_STAGING=0
REHEARSAL_WAIT=120
MAX_ATTEMPTS=3

ARMED=0
ORIG_RUN_SIZE_K=
RUN_WAS_NOEXEC=0
PLYMOUTH_UNITS="plymouth-reboot.service plymouth-poweroff.service plymouth-halt.service plymouth-kexec.service plymouth-switch-root-initramfs.service"
PLYMOUTH_MASKED=0

# ---------------------------------------------------------------- utilities --

if [ -t 1 ]; then
    C_RED=$'\e[1;31m' C_YEL=$'\e[1;33m' C_GRN=$'\e[1;32m' C_BLD=$'\e[1m' C_OFF=$'\e[0m'
else
    C_RED='' C_YEL='' C_GRN='' C_BLD='' C_OFF=''
fi

_log() { if [ -d "$STAGE" ]; then printf '%s\n' "$*" >>"$HOST_LOG" 2>/dev/null || true; fi; }
say()  { printf '%s\n' "$*"; _log "$*"; }
info() { printf '%s==>%s %s\n' "$C_GRN" "$C_OFF" "$*"; _log "==> $*"; }
warn() { printf '%sWARNING:%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; _log "WARNING: $*"; }
die()  { printf '%sERROR:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; _log "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
human() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "$1 bytes"; }

# YAML double-quoted scalar
yq() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
}

usage() {
    cat <<EOF
brutal-upgrader.sh $SCRIPT_VERSION - remote clean reinstall of Raspberry Pi OS Lite

Usage: sudo $0 [mode] [options]

Modes:
  (none)                 Real run: preflight, stage, ask for confirmation, then
                         reboot and FLASH THE BOOT DISK (destroys all data on it).
  --dry-run              Preflight + download + verify + build everything, show
                         the generated config, then clean up. Changes nothing.
  --rehearsal            Arm a harmless variant: reboot into the RAM environment,
                         bring up network + rescue SSH, verify everything, wait
                         --rehearsal-wait seconds, then reboot back into the
                         unchanged current OS. Nothing is written to the disk.
  --disarm               Cancel an armed (not yet rebooted) run.

Options:
  --yes-destroy-everything  Skip the typed confirmation of the real run.
  --yes                  Skip the confirmation of --rehearsal.
  --image-url URL        Use this .img.xz instead of the latest Lite image.
  --image-sha256 HEX     Expected sha256 of the .img.xz (default: URL.sha256).
  --dhcp                 New OS uses DHCP on ethernet instead of the current
                         address as a static IP.
  --hostname NAME        Hostname for the new OS (default: current).
  --user NAME            User to carry over (default: \$SUDO_USER).
  --no-rescue-ssh        Do not put dropbear into the RAM environment.
  --no-backup            Do not put a config backup tarball on the new bootfs.
  --keep-staging         Keep $STAGE after --dry-run (reused by a later run).
  --rehearsal-wait SEC   Seconds the rehearsal waits before rebooting (120).
  -h, --help             This help.
EOF
}

# ---------------------------------------------------------------- arguments --

while [ $# -gt 0 ]; do
    case $1 in
        --dry-run) MODE=dry-run ;;
        --rehearsal) MODE=rehearsal ;;
        --disarm) MODE=disarm ;;
        --yes) ASSUME_YES=1 ;;
        --yes-destroy-everything) DESTROY_YES=1 ;;
        --image-url) IMAGE_URL=${2:?}; shift ;;
        --image-sha256) IMAGE_SHA256=${2:?}; shift ;;
        --dhcp) NET_MODE=dhcp ;;
        --hostname) NEW_HOSTNAME=${2:?}; shift ;;
        --user) NEW_USER=${2:?}; shift ;;
        --no-rescue-ssh) RESCUE_SSH=0 ;;
        --no-backup) BACKUP=0 ;;
        --keep-staging) KEEP_STAGING=1 ;;
        --rehearsal-wait) REHEARSAL_WAIT=${2:?}; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
done

[ "$(id -u)" = 0 ] || die "must be run as root (sudo $0 ...)"

# ------------------------------------------------------------ /run handling --

run_size_k() { df -Pk /run | awk 'NR==2 {print $2}'; }

grow_run() { # $1 = KiB needed on top of what /run currently uses
    local used total want
    used=$(df -Pk /run | awk 'NR==2 {print $3}')
    total=$(run_size_k)
    want=$(( used + $1 + 65536 ))
    [ -n "$ORIG_RUN_SIZE_K" ] || ORIG_RUN_SIZE_K=$total
    if [ "$want" -gt "$total" ]; then
        mount -o remount,size=${want}k /run || die "could not grow /run to ${want}k"
    fi
}

run_noexec() { [[ ,$(findmnt -no OPTIONS /run), == *,noexec,* ]]; }

# initramfs-tools mounts /run noexec; the RAM root (and /shutdown run from it
# by systemd-shutdown via a bind mount that inherits the flag) must be executable
make_run_exec() {
    run_noexec || return 0
    mount -o remount,exec /run || die "could not remount /run exec"
    RUN_WAS_NOEXEC=1
}

restore_run() {
    if [ "$RUN_WAS_NOEXEC" = 1 ]; then
        mount -o remount,noexec /run 2>/dev/null || warn "could not remount /run noexec again (harmless)"
    fi
    [ -n "$ORIG_RUN_SIZE_K" ] || return 0
    mount -o remount,size="${ORIG_RUN_SIZE_K}k" /run 2>/dev/null ||
        warn "could not shrink /run back to ${ORIG_RUN_SIZE_K}k (harmless)"
}

# initramfs-tools leaves fsck logs in /run/initramfs; they are not a shutdown hook
exitrd_foreign() { # print entries of $EXITRD that are not initramfs-tools leftovers
    find "$EXITRD" -mindepth 1 -maxdepth 1 ! -name fsck.log ! -name 'fsck-*' -printf '%f\n' 2>/dev/null || true
}

disarm_exitrd() { # remove our RAM root, keep initramfs-tools leftovers
    find "$EXITRD" -mindepth 1 -maxdepth 1 ! -name fsck.log ! -name 'fsck-*' -exec rm -rf {} + 2>/dev/null || true
    rmdir "$EXITRD" 2>/dev/null || true
}

# the boot splash would grab the console and follow us into $EXITRD at shutdown;
# --runtime masks live in /run/systemd and vanish at the next boot
plymouth_off() {
    systemctl cat plymouth-reboot.service >/dev/null 2>&1 || return 0
    systemctl -q mask --runtime $PLYMOUTH_UNITS || return 1
    PLYMOUTH_MASKED=1
    if pgrep -x plymouthd >/dev/null; then plymouth quit 2>/dev/null || true; fi
}
plymouth_on() { systemctl unmask --runtime $PLYMOUTH_UNITS >/dev/null 2>&1 || true; }

cleanup() {
    local rc=$?
    if mountpoint -q "$MNT" 2>/dev/null; then umount "$MNT" || umount -l "$MNT" || true; fi
    if [ "$ARMED" = 0 ]; then
        if [ "$PLYMOUTH_MASKED" = 1 ]; then plymouth_on; fi
        if [ "$KEEP_STAGING" = 1 ] && [ "$MODE" = dry-run ]; then
            say "Staging kept in $STAGE (remove with: sudo rm -rf $STAGE)"
        elif [ -d "$STAGE" ]; then
            rm -rf "$STAGE"
            restore_run
        fi
    fi
    exit $rc
}

# ------------------------------------------------------------------ disarm --

if [ "$MODE" = disarm ]; then
    plymouth_on
    if [ -f "$EXITRD/$MARKER" ]; then
        disarm_exitrd
        rm -rf "$STAGE"
        info "Disarmed: $EXITRD removed. The next reboot is a normal reboot."
    elif [ -n "$(exitrd_foreign)" ]; then
        die "$EXITRD exists but was not created by this script; not touching it"
    else
        info "Nothing armed."
    fi
    exit 0
fi

if [ -e "$EXITRD" ]; then
    if [ -f "$EXITRD/$MARKER" ]; then
        die "already armed ($EXITRD exists). Run '$0 --disarm' first."
    fi
    EXITRD_FOREIGN=$(exitrd_foreign)
    [ -z "$EXITRD_FOREIGN" ] ||
        die "$EXITRD contains '$(paste -sd' ' - <<<"$EXITRD_FOREIGN")' (dracut or another tool uses the shutdown hook); refusing"
    info "$EXITRD only holds initramfs-tools fsck logs; they will be kept"
fi

# --------------------------------------------------------------- downloads --

http_get() { # url dest
    if have curl; then
        curl -fsSL --retry 3 --connect-timeout 20 -o "$2" "$1"
    else
        wget -q -O "$2" "$1"
    fi
}

http_final_url() { # follow redirects, print final URL
    if have curl; then
        curl -fsSLI -o /dev/null -w '%{url_effective}' --connect-timeout 20 "$1"
    else
        wget -S --spider "$1" 2>&1 | awk '/^ *Location: /{u=$2} END{print u}'
    fi
}

http_size() {
    if have curl; then
        curl -fsSLI --connect-timeout 20 "$1" | tr -d '\r' |
            awk 'tolower($1)=="content-length:" {n=$2} END{print n}'
    else
        wget -S --spider "$1" 2>&1 | awk 'tolower($1)=="content-length:" {n=$2} END{print n}'
    fi
}

http_download() { # url dest (resumable, with progress)
    if have curl; then
        curl -fL --retry 5 --retry-delay 5 --connect-timeout 20 -C - --progress-bar -o "$2" "$1"
    else
        wget -c --progress=dot:giga -O "$2" "$1"
    fi
}

# =============================================================== PREFLIGHT ==

[ -d /run/systemd/system ] || die "systemd is not PID 1; the exitrd hook needs systemd"
have curl || have wget || die "need curl or wget"
for t in xz sha256sum dd lsblk findmnt ip od losetup mount umount tar ldd ldconfig chroot numfmt; do
    have "$t" || die "required tool missing: $t"
done

mkdir -p "$STAGE"
: >"$HOST_LOG"
trap cleanup EXIT
trap 'exit 130' INT TERM

info "brutal-upgrader $SCRIPT_VERSION - mode: $MODE - $(date -Is)"

# ---- system ----
. /etc/os-release
DEB_MAJOR=$(cut -d. -f1 /etc/debian_version 2>/dev/null || echo 0)
case $DEB_MAJOR in ''|*[!0-9]*) DEB_MAJOR=${VERSION_ID:-0} ;; esac
[ "${DEB_MAJOR:-0}" -ge 10 ] 2>/dev/null || warn "Debian version '$DEB_MAJOR' < 10: untested"
MODEL=$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo unknown)
case $MODEL in
    Raspberry\ Pi*) ;;
    *) die "this does not look like a Raspberry Pi (model: $MODEL)" ;;
esac
# the new image is 64-bit whenever the Pi can run it (even if the current OS is 32-bit)
USER_ARCH=$(dpkg --print-architecture 2>/dev/null || echo unknown)
case $MODEL in
    *"Pi 5"*|*"Pi 4"*|*"Pi 3"*|*"Zero 2"*|*"Compute Module 3"*|*"Compute Module 4"*|*"Compute Module 5"*)
        ARCH=arm64 ;;
    *) if [ "$(uname -m)" = aarch64 ]; then ARCH=arm64; else ARCH=armhf; fi ;;
esac
MEM_TOTAL_K=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
SYSTEMD_VER=$(systemctl --version | awk 'NR==1 {print $2}')

# ---- disk ----
ROOT_SRC=$(findmnt -no SOURCE /)
BOOT_MNT=
for m in /boot/firmware /boot; do
    if mountpoint -q "$m" && [ "$(findmnt -no FSTYPE "$m")" = vfat ]; then BOOT_MNT=$m; break; fi
done
[ -n "$BOOT_MNT" ] || die "no vfat boot partition mounted at /boot or /boot/firmware"
OLD_BOOT_PART=$(findmnt -no SOURCE "$BOOT_MNT")
[ -b "$ROOT_SRC" ] || die "root source '$ROOT_SRC' is not a block device"
DISK_NAME=$(lsblk -no PKNAME "$ROOT_SRC" | head -n1)
BOOT_DISK_NAME=$(lsblk -no PKNAME "$OLD_BOOT_PART" | head -n1)
[ -n "$DISK_NAME" ] || die "cannot find the disk holding $ROOT_SRC"
[ "$DISK_NAME" = "$BOOT_DISK_NAME" ] ||
    die "root ($ROOT_SRC) and boot ($OLD_BOOT_PART) are on different disks; unsupported"
DISK=/dev/$DISK_NAME
[ "$(lsblk -dno TYPE "$DISK")" = disk ] || die "$DISK is not a whole disk"
DISK_SIZE=$(blockdev --getsize64 "$DISK")
DISK_MODEL=$(sed 's/ *$//' "/sys/block/$DISK_NAME/device/model" 2>/dev/null || true)
DISK_DESC=$(lsblk -dno MODEL "$DISK" 2>/dev/null | sed 's/ *$//' || true)
DISK_TRAN=$(lsblk -dno TRAN "$DISK" 2>/dev/null || true)
case $DISK_NAME in
    *[0-9]) NEW_BOOT_PART=${DISK}p1 ;;
    *) NEW_BOOT_PART=${DISK}1 ;;
esac

# ---- network ----
read -r NET_IF NET_IP < <(ip -4 route get 1.1.1.1 2>/dev/null |
    awk '{for (i=1;i<NF;i++) {if ($i=="dev") d=$(i+1); if ($i=="src") s=$(i+1)}} END {print d, s}') || true
[ -n "${NET_IF:-}" ] && [ -n "${NET_IP:-}" ] || die "no IPv4 default route"
NET_GW=$(ip -4 route show default dev "$NET_IF" | awk '{print $3; exit}')
NET_PREFIX=$(ip -4 -o addr show dev "$NET_IF" | awk -v ip="$NET_IP" '{split($4,a,"/"); if (a[1]==ip) print a[2]}' | head -n1)
[ -n "$NET_GW" ] && [ -n "$NET_PREFIX" ] || die "cannot determine gateway/prefix on $NET_IF"
NET_MAC=$(cat "/sys/class/net/$NET_IF/address")
NET_DRIVER=$(basename "$(readlink -f "/sys/class/net/$NET_IF/device/driver" 2>/dev/null)" 2>/dev/null || true)
[ -d "/sys/class/net/$NET_IF/wireless" ] &&
    die "default route is via Wi-Fi ($NET_IF); the new OS would have no Wi-Fi config. Use ethernet."
NET_DNS=$(awk '$1=="nameserver" && $2 !~ /^127\./ && $2 ~ /^[0-9.]+$/ {print $2}' /etc/resolv.conf | head -n3 | paste -sd, -)
[ -n "$NET_DNS" ] || NET_DNS=$NET_GW
NET_SEARCH=$(awk '$1=="search" || $1=="domain" {for (i=2;i<=NF;i++) print $i}' /etc/resolv.conf | sort -u | paste -sd, -)
case $NET_DRIVER in
    bcmgenet|macb|smsc95xx|lan78xx) NEW_IF_MATCH=name ;;   # onboard NIC: eth0 on Pi OS
    *) NEW_IF_MATCH=mac ;;
esac

# ---- user / identity ----
NEW_USER=${NEW_USER:-${SUDO_USER:-}}
[ -n "$NEW_USER" ] && [ "$NEW_USER" != root ] || die "cannot tell which user to carry over; use --user NAME"
getent passwd "$NEW_USER" >/dev/null || die "user '$NEW_USER' does not exist"
USER_HOME=$(getent passwd "$NEW_USER" | cut -d: -f6)
PW_HASH=$(getent shadow "$NEW_USER" | cut -d: -f2)
case $PW_HASH in
    ''|'*'|'!'*) PW_HASH= ;;
esac
AUTH_KEYS=()
if [ -f "$USER_HOME/.ssh/authorized_keys" ]; then
    while IFS= read -r l; do
        case $l in ''|'#'*) continue ;; esac
        AUTH_KEYS+=("$l")
    done <"$USER_HOME/.ssh/authorized_keys"
fi
[ ${#AUTH_KEYS[@]} -gt 0 ] || [ -n "$PW_HASH" ] ||
    die "user $NEW_USER has neither SSH keys nor a password: you would be locked out"
NEW_HOSTNAME=${NEW_HOSTNAME:-$(hostname -s)}
TIMEZONE=$(cat /etc/timezone 2>/dev/null || true)
[ -n "$TIMEZONE" ] || TIMEZONE=$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')
KB_MODEL=pc105 KB_LAYOUT=
if [ -f /etc/default/keyboard ]; then
    KB_MODEL=$(. /etc/default/keyboard; echo "${XKBMODEL:-pc105}")
    KB_LAYOUT=$(. /etc/default/keyboard; echo "${XKBLAYOUT:-}")
fi
# (capture first: "cmd | grep -q" can fail under pipefail when grep exits early)
SUDO_NOPASSWD=0
SUDO_RULES=$( { have sudo && sudo -l -U "$NEW_USER"; } 2>/dev/null || true)
if grep -Eq 'NOPASSWD: *ALL' <<<"$SUDO_RULES"; then SUDO_NOPASSWD=1; fi
SSH_PWAUTH=false
SSHD_CFG=$( { have sshd && sshd -T; } 2>/dev/null || true)
if grep -qi '^passwordauthentication yes' <<<"$SSHD_CFG"; then SSH_PWAUTH=true; fi
[ -n "$PW_HASH" ] || SSH_PWAUTH=false

# ---- watchdog / eeprom ----
WDT_STATE=$(cat /sys/class/watchdog/watchdog0/state 2>/dev/null || echo none)
EEPROM_INFO=
case $MODEL in
    *"Pi 4"*|*"Pi 5"*|*"Compute Module 4"*|*"Compute Module 5"*)
        if have rpi-eeprom-update; then
            EEPROM_INFO=$(rpi-eeprom-update 2>/dev/null | awk '/BOOTLOADER:|CURRENT:/ {$1=$1; print}' | head -n2 | paste -sd';' - || true)
        fi ;;
esac

# ---- image ----
if [ -z "$IMAGE_URL" ]; then
    IMAGE_URL=$(http_final_url "$DL_BASE/raspios_lite_${ARCH}_latest") ||
        die "cannot resolve latest image URL (network?)"
fi
case $IMAGE_URL in *.img.xz) ;; *) die "image URL must point to a .img.xz: $IMAGE_URL" ;; esac
IMAGE_NAME=$(basename "$IMAGE_URL")
if [ -z "$IMAGE_SHA256" ]; then
    http_get "$IMAGE_URL.sha256" "$STAGE/image.sha256" ||
        die "cannot fetch $IMAGE_URL.sha256 (use --image-sha256)"
    IMAGE_SHA256=$(awk '{print $1; exit}' "$STAGE/image.sha256")
fi
[[ $IMAGE_SHA256 =~ ^[0-9a-f]{64}$ ]] || die "bad image sha256: '$IMAGE_SHA256'"
XZ_SIZE=$(http_size "$IMAGE_URL")
[ -n "$XZ_SIZE" ] || die "cannot get size of $IMAGE_URL"

EXTRACT_SHA256_UP='' EXTRACT_SIZE_UP='' INIT_FORMAT=''
if http_get "$IMAGER_JSON_URL" "$STAGE/os_list.json" 2>/dev/null; then
    if have python3; then
        read -r EXTRACT_SHA256_UP EXTRACT_SIZE_UP INIT_FORMAT < <(python3 - "$STAGE/os_list.json" "$IMAGE_URL" <<'PY' || true
import json, sys
d = json.load(open(sys.argv[1]))
def walk(items):
    for o in items:
        if "subitems" in o:
            r = walk(o["subitems"])
            if r:
                return r
        elif o.get("url") == sys.argv[2]:
            return o
o = walk(d.get("os_list", [])) or {}
print(o.get("extract_sha256") or "-", o.get("extract_size") or "-", o.get("init_format") or "-")
PY
) || true
    elif have jq; then
        read -r EXTRACT_SHA256_UP EXTRACT_SIZE_UP INIT_FORMAT < <(jq -r --arg u "$IMAGE_URL" \
            '[.. | objects | select(.url? == $u)][0] // {} | "\(.extract_sha256 // "-") \(.extract_size // "-") \(.init_format // "-")"' \
            "$STAGE/os_list.json" || true) || true
    fi
fi
[ "${EXTRACT_SHA256_UP:--}" = - ] && EXTRACT_SHA256_UP=
[ "${EXTRACT_SIZE_UP:--}" = - ] && EXTRACT_SIZE_UP=
[ "${INIT_FORMAT:--}" = - ] && INIT_FORMAT=
if [ -z "$INIT_FORMAT" ]; then
    if http_get "${IMAGE_URL%.img.xz}.info" "$STAGE/image.info" 2>/dev/null &&
        grep -Eq '^ii +cloud-init ' "$STAGE/image.info"; then
        INIT_FORMAT=cloudinit
    fi
fi
case $INIT_FORMAT in
    cloudinit*) ;;
    *) die "image first-boot format '${INIT_FORMAT:-unknown}' is not cloud-init; only Trixie-or-later images are supported" ;;
esac

# ---- sizes / RAM ----
[ -z "$EXTRACT_SIZE_UP" ] || [ "$EXTRACT_SIZE_UP" -le "$DISK_SIZE" ] ||
    die "image ($(human "$EXTRACT_SIZE_UP")) is larger than $DISK ($(human "$DISK_SIZE"))"
MEM_AVAIL_K=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
NEED_K=$(( XZ_SIZE / 1024 + 200 * 1024 ))   # image + bootfs (sparse) + RAM root
[ "$MEM_AVAIL_K" -gt $(( NEED_K + 200 * 1024 )) ] ||
    die "not enough RAM: need ~$(( NEED_K / 1024 + 200 ))MiB available, have $(( MEM_AVAIL_K / 1024 ))MiB"

# ---- summary ----
print_summary() {
    local k
    say ""
    say "${C_BLD}=================== brutal-upgrader preflight ===================${C_OFF}"
    say "Host        : $MODEL, $(( MEM_TOTAL_K / 1024 )) MiB RAM"
    say "Current OS  : ${PRETTY_NAME:-?}, kernel $(uname -r), systemd $SYSTEMD_VER, $USER_ARCH userland"
    say "Boot disk   : $DISK  $(human "$DISK_SIZE")  ${DISK_TRAN:-?}  ${DISK_DESC:-$DISK_MODEL}"
    lsblk -no NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DISK" | sed 's/^/              /' | tee -a "$HOST_LOG"
    k=$(lsblk -dno NAME,SIZE | grep -v "^$DISK_NAME " | grep -Ev '^(loop|ram|zram)' | paste -sd, - || true)
    say "Other disks : ${k:-none}${k:+ (not touched)}"
    say "Bootloader  : ${EEPROM_INFO:-n/a}"
    say "Watchdog    : $WDT_STATE"
    say ""
    say "${C_RED}EVERYTHING ON $DISK WILL BE DESTROYED.${C_OFF} Largest top-level directories:"
    timeout 300 du -xhd1 / 2>/dev/null | sort -rh | sed -n '2,9p' | sed 's/^/              /' | tee -a "$HOST_LOG" || true
    say ""
    say "New image   : $IMAGE_NAME"
    [ "$USER_ARCH" = "$ARCH" ] || say "              ($ARCH image: this Pi can run it; the current OS is $USER_ARCH)"
    say "              $(human "$XZ_SIZE") compressed, ${EXTRACT_SIZE_UP:+$(human "$EXTRACT_SIZE_UP") raw, }first boot: $INIT_FORMAT"
    say "              xz sha256  $IMAGE_SHA256"
    say "              raw sha256 ${EXTRACT_SHA256_UP:-(not published; computed locally)}"
    say ""
    say "New system  : hostname $NEW_HOSTNAME, timezone ${TIMEZONE:-default}, keyboard ${KB_LAYOUT:-default}"
    say "              user $NEW_USER: ${#AUTH_KEYS[@]} SSH key(s), password $([ -n "$PW_HASH" ] && echo "carried over (${PW_HASH:0:3}... hash)" || echo "locked"),"
    say "              sudo $([ $SUDO_NOPASSWD = 1 ] && echo "without password" || echo "with password"), SSH password login: $SSH_PWAUTH"
    if [ "$NET_MODE" = static ]; then
        k="static $NET_IP/$NET_PREFIX gw $NET_GW dns $NET_DNS"
    else
        k="DHCP"
    fi
    say "Network     : $NET_IF ($NET_DRIVER, $NET_MAC) -> $k"
    [ "$NEW_IF_MATCH" = mac ] && say "              (non-onboard NIC: new OS matches it by MAC address)"
    say "Rescue SSH  : $([ $RESCUE_SSH = 1 ] && echo "dropbear, root@$NET_IP, while flashing (if it can be fetched)" || echo disabled)"
    say "Backup      : $([ $BACKUP = 1 ] && echo "/etc (no shadow/host keys), package list, crontabs -> new bootfs/pre-upgrade-backup.tar.gz" || echo none)"
    say "RAM         : ~$(( NEED_K / 1024 )) MiB needed in /run, $(( MEM_AVAIL_K / 1024 )) MiB available"
    say ""
    say "Plan        : 1. download + verify image into RAM   2. prepare boot partition + RAM root"
    case $MODE in
        real) say "              3. reboot -> flash $DISK -> read-back verify -> write bootfs -> reboot into new OS" ;;
        rehearsal) say "              3. reboot -> RAM env, network, rescue SSH, NO WRITES -> wait ${REHEARSAL_WAIT}s -> reboot into current OS" ;;
        dry-run) say "              3. (dry run) show generated config and clean up" ;;
    esac
    say "${C_BLD}=================================================================${C_OFF}"
    say ""
}
print_summary

[ "$WDT_STATE" = active ] && warn "hardware watchdog is active; the RAM environment will keep feeding it"
[ -n "$PW_HASH" ] || warn "no usable password for $NEW_USER; only SSH keys will work"
[ ${#AUTH_KEYS[@]} -gt 0 ] || warn "no SSH keys for $NEW_USER; SSH login will be by password only"

# ================================================================= STAGING ==

mkdir -p "$ROOT/data" "$MNT"
grow_run "$NEED_K"
make_run_exec

IMG=$ROOT/data/image.img.xz
if [ -f "$IMG" ] && [ "$(sha256sum "$IMG" | cut -d' ' -f1)" = "$IMAGE_SHA256" ]; then
    info "Reusing already downloaded image"
else
    info "Downloading $IMAGE_NAME into RAM"
    http_download "$IMAGE_URL" "$IMG" || die "download failed"
    info "Verifying xz sha256"
    [ "$(sha256sum "$IMG" | cut -d' ' -f1)" = "$IMAGE_SHA256" ] || die "image sha256 mismatch"
fi

info "Test-decompressing the whole image (checks integrity, computes raw sha256)"
EXTRACT_SIZE=$(xz --robot --list "$IMG" | awk '$1=="totals" {print $5}')
EXTRACT_SHA256=$(xz -dc "$IMG" | sha256sum | cut -d' ' -f1) || die "image does not decompress cleanly"
[ -n "$EXTRACT_SIZE" ] && [ "$EXTRACT_SIZE" -gt 0 ] || die "cannot read uncompressed size"
if [ -n "$EXTRACT_SHA256_UP" ] && [ "$EXTRACT_SHA256_UP" != "$EXTRACT_SHA256" ]; then
    die "raw image sha256 $EXTRACT_SHA256 != published $EXTRACT_SHA256_UP"
fi
if [ -n "$EXTRACT_SIZE_UP" ] && [ "$EXTRACT_SIZE_UP" != "$EXTRACT_SIZE" ]; then
    die "raw image size $EXTRACT_SIZE != published $EXTRACT_SIZE_UP"
fi
[ "$EXTRACT_SIZE" -le "$DISK_SIZE" ] || die "image is larger than $DISK"
info "Raw image OK: $(human "$EXTRACT_SIZE"), sha256 $EXTRACT_SHA256"

# ---- boot partition out of the image ----
{ xz -dc "$IMG" 2>/dev/null || true; } | head -c 1048576 >"$STAGE/head.bin"
[ "$(od -An -tx1 -j510 -N2 "$STAGE/head.bin" | tr -d ' \n')" = 55aa ] || die "image has no MBR"
P1_TYPE=$(od -An -tx1 -j450 -N1 "$STAGE/head.bin" | tr -d ' \n')
case $P1_TYPE in 0b|0c|0e|06) ;; *) die "image partition 1 is not FAT (type 0x$P1_TYPE)" ;; esac
P1_START=$(od -An -tu4 -j454 -N4 "$STAGE/head.bin" | tr -d ' \n')
P1_SECTORS=$(od -An -tu4 -j458 -N4 "$STAGE/head.bin" | tr -d ' \n')
BOOT_OFFSET=$(( P1_START * 512 ))
BOOT_SIZE=$(( P1_SECTORS * 512 ))
[ "$BOOT_OFFSET" -gt 0 ] && [ $(( BOOT_OFFSET + BOOT_SIZE )) -le "$EXTRACT_SIZE" ] ||
    die "implausible partition 1 in image (start $P1_START, $P1_SECTORS sectors)"

info "Extracting image boot partition ($(human "$BOOT_SIZE") at offset $BOOT_OFFSET)"
BOOTFS=$ROOT/data/bootfs.img
{ xz -dc "$IMG" 2>/dev/null || true; } |
    dd of="$BOOTFS" bs=4M iflag=fullblock,skip_bytes,count_bytes skip="$BOOT_OFFSET" \
        count="$BOOT_SIZE" conv=sparse status=none
truncate -s "$BOOT_SIZE" "$BOOTFS"
mount -o loop "$BOOTFS" "$MNT" || die "cannot loop-mount the image boot partition"
[ -f "$MNT/cmdline.txt" ] && [ -f "$MNT/config.txt" ] || die "image boot partition has no cmdline.txt/config.txt"

# ---- cloud-init config ----
info "Writing cloud-init first-boot configuration"
IID="brutal-upgrader-$(date +%s)"
printf 'instance-id: %s\n' "$IID" >"$MNT/meta-data"

{
    echo "#cloud-config"
    echo "# generated by brutal-upgrader.sh on $(hostname) at $(date -Is)"
    echo "manage_resolv_conf: false"
    echo
    echo "hostname: $(yq "$NEW_HOSTNAME")"
    echo "manage_etc_hosts: true"
    if [ -n "$TIMEZONE" ]; then echo "timezone: $(yq "$TIMEZONE")"; fi
    if [ -n "$KB_LAYOUT" ]; then
        echo "keyboard:"
        echo "  model: $(yq "$KB_MODEL")"
        echo "  layout: $(yq "$KB_LAYOUT")"
    fi
    echo
    echo "user:"
    echo "  name: $(yq "$NEW_USER")"
    echo "  shell: /bin/bash"
    if [ -n "$PW_HASH" ]; then
        echo "  lock_passwd: false"
        echo "  passwd: $(yq "$PW_HASH")"
    else
        echo "  lock_passwd: true"
    fi
    if [ ${#AUTH_KEYS[@]} -gt 0 ]; then
        echo "  ssh_authorized_keys:"
        for k in "${AUTH_KEYS[@]}"; do echo "    - $(yq "$k")"; done
    fi
    if [ $SUDO_NOPASSWD = 1 ]; then
        echo "  sudo: ALL=(ALL) NOPASSWD:ALL"
    else
        echo "  sudo: null"
    fi
    echo
    echo "ssh_pwauth: $SSH_PWAUTH"
    echo
    echo "runcmd:"
    echo "  - [ systemctl, enable, --now, ssh ]"
    if [ $SUDO_NOPASSWD = 1 ]; then
        echo "  - [ sh, -c, $(yq "echo '$NEW_USER ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/010_$NEW_USER-nopasswd && chmod 0440 /etc/sudoers.d/010_$NEW_USER-nopasswd") ]"
    fi
} >"$MNT/user-data"

{
    echo "network:"
    echo "  version: 2"
    echo "  renderer: NetworkManager"
    echo "  ethernets:"
    echo "    eth0:"
    if [ "$NEW_IF_MATCH" = mac ]; then
        echo "      match:"
        echo "        macaddress: $(yq "$NET_MAC")"
    fi
    if [ "$NET_MODE" = static ]; then
        echo "      dhcp4: false"
        echo "      addresses: [$NET_IP/$NET_PREFIX]"
        echo "      routes:"
        echo "        - to: default"
        echo "          via: $NET_GW"
        echo "      nameservers:"
        echo "        addresses: [$NET_DNS]"
        if [ -n "$NET_SEARCH" ]; then echo "        search: [$NET_SEARCH]"; fi
    else
        echo "      dhcp4: true"
    fi
    echo "      dhcp6: false"
} >"$MNT/network-config"

: >"$MNT/ssh"   # legacy switch, harmless where unused

# drop any old ds= and the graphical boot splash (splash, plymouth.*)
CMDLINE=$(tr -s ' \n' '\n\n' <"$MNT/cmdline.txt" | grep -Ev '^(ds=.*|splash|plymouth\..*)?$' | paste -sd' ' -)
printf '%s ds=nocloud;i=%s\n' "$CMDLINE" "$IID" >"$MNT/cmdline.txt"

if have python3 && python3 -c 'import yaml' 2>/dev/null; then
    python3 - "$MNT/user-data" "$MNT/network-config" "$MNT/meta-data" <<'PY' || die "generated cloud-init YAML does not parse"
import sys, yaml
for f in sys.argv[1:]:
    yaml.safe_load(open(f))
PY
    info "cloud-init YAML validated"
fi

# ---- config backup ----
if [ $BACKUP = 1 ]; then
    info "Creating config backup for the new boot partition"
    B=$STAGE/backup
    mkdir -p "$B"
    dpkg --get-selections >"$B/dpkg-selections.txt" 2>/dev/null || true
    { apt-mark showmanual 2>/dev/null || true; } >"$B/apt-manual.txt"
    { crontab -l -u "$NEW_USER" 2>/dev/null || true; } >"$B/crontab-$NEW_USER.txt"
    { crontab -l 2>/dev/null || true; } >"$B/crontab-root.txt"
    { systemctl list-unit-files --state=enabled 2>/dev/null || true; } >"$B/enabled-units.txt"
    { ip addr; ip route; } >"$B/network.txt" 2>/dev/null || true
    cp "$BOOT_MNT/config.txt" "$BOOT_MNT/cmdline.txt" "$B/" 2>/dev/null || true
    tar -C / -czf "$B.tar.gz" --ignore-failed-read --warning=no-file-changed \
        --exclude='etc/shadow*' --exclude='etc/gshadow*' --exclude='etc/ssh/ssh_host_*_key' \
        etc -C "$STAGE" backup 2>/dev/null || [ $? = 1 ] || warn "backup tar reported errors"
    FREE_K=$(df -Pk "$MNT" | awk 'NR==2 {print $4}')
    if [ -f "$B.tar.gz" ] && [ $(( $(stat -c %s "$B.tar.gz") / 1024 + 16384 )) -lt "$FREE_K" ]; then
        cp "$B.tar.gz" "$MNT/pre-upgrade-backup.tar.gz"
        info "Backup: $(human "$(stat -c %s "$B.tar.gz")") -> bootfs/pre-upgrade-backup.tar.gz"
    else
        warn "backup does not fit on the new boot partition; skipped"
    fi
    rm -rf "$B" "$B.tar.gz"
fi

sync
umount "$MNT"
BOOTFS_SHA256=$(sha256sum "$BOOTFS" | cut -d' ' -f1)

# ================================================================ RAM ROOT ==

info "Building RAM root"
mkdir -p "$ROOT"/{bin,lib,usr,etc,dev,proc,sys,run,tmp,mnt,oldroot,root/.ssh,etc/dropbear}
ln -sfn bin "$ROOT/sbin"
ln -sfn ../bin "$ROOT/usr/bin"
ln -sfn ../bin "$ROOT/usr/sbin"
chmod 1777 "$ROOT/tmp"
chmod 700 "$ROOT/root" "$ROOT/root/.ssh"

LIB_DIRS=()
copy_libs() { # binary [extra LD_LIBRARY_PATH] [prefix to strip]
    local bin=$1 llp=${2:-} strip=${3:-} lib dest out
    out=$(LD_LIBRARY_PATH=$llp ldd "$bin" 2>/dev/null) || return 0   # static binary
    if grep -q 'not found' <<<"$out"; then
        echo "missing libraries for $bin:" >&2
        grep 'not found' <<<"$out" >&2
        return 1
    fi
    while read -r lib; do
        [ -n "$lib" ] && [ -e "$lib" ] || continue
        dest=${lib#"$strip"}
        mkdir -p "$ROOT$(dirname "$dest")"
        [ -e "$ROOT$dest" ] || cp -L "$lib" "$ROOT$dest"
        LIB_DIRS+=("$(dirname "$dest")")
    done < <(awk '/=> \// {print $3} /^[ \t]*\// {print $1}' <<<"$out")
}

add_bin() { # name required(0/1)
    local p
    p=$(command -v "$1" 2>/dev/null) || {
        [ "$2" = 1 ] && die "RAM root: required binary '$1' not found"
        return 0
    }
    cp -L "$p" "$ROOT/bin/$1"
    copy_libs "$p" || { [ "$2" = 1 ] && die "RAM root: libraries missing for $1"; rm -f "$ROOT/bin/$1"; }
}

for b in bash dd xz sha256sum sync mount umount sleep cat blockdev ip date grep mkdir cp; do
    add_bin "$b" 1
done
for b in ls tail head rm mv ln stat df free ps dmesg sed cmp chmod touch readlink mountpoint \
    wc tr cut sort busybox; do
    add_bin "$b" 0
done
ln -sfn bash "$ROOT/bin/sh"

# glibc loads NSS modules with dlopen(); ldd does not show them
LIBC=$(ldd "$(command -v bash)" | awk '/libc\.so/ {print $3}')
for f in "$(dirname "$LIBC")"/libnss_files.so*; do
    [ -e "$f" ] && cp -L "$f" "$ROOT$(dirname "$LIBC")/"
done

cat >"$ROOT/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
EOF
printf 'root:x:0:\ntty:x:5:\n' >"$ROOT/etc/group"
printf '/bin/sh\n/bin/bash\n' >"$ROOT/etc/shells"
printf 'passwd: files\ngroup: files\nshadow: files\nhosts: files\n' >"$ROOT/etc/nsswitch.conf"
printf '127.0.0.1 localhost\n' >"$ROOT/etc/hosts"
cat >"$ROOT/root/.bashrc" <<'EOF'
export PATH=/bin
PS1='[brutal-upgrader RAM] \w # '
echo "brutal-upgrader RAM environment. Log: /log   dd progress: /progress"
echo "Commands: /shutdown flash   (retry the flash + reboot)"
echo "          /shutdown reboot-now | poweroff-now"
EOF
cp "$ROOT/root/.bashrc" "$ROOT/root/.profile"

# ---- rescue SSH (dropbear, from the Debian archive; nothing is installed) ----
DROPBEAR_ARGS=
if [ $RESCUE_SSH = 1 ]; then
    info "Fetching dropbear for rescue SSH (best effort)"
    DB=$STAGE/dropbear
    mkdir -p "$DB/debs" "$DB/x"
    fetch_dropbear() {
        local deps p
        (cd "$DB/debs" && apt-get download dropbear-bin) >/dev/null 2>&1 || return 1
        deps=$(apt-cache depends --no-recommends --no-suggests dropbear-bin 2>/dev/null |
            awk '$1=="Depends:" && $2 !~ /^</ {print $2}' | sort -u)
        for p in $deps; do
            [[ $(dpkg-query -W -f='${Status}' "$p" 2>/dev/null || true) == *"ok installed"* ]] && continue
            (cd "$DB/debs" && apt-get download "$p") >/dev/null 2>&1 || return 1
        done
    }
    if fetch_dropbear || { apt-get update -qq >/dev/null 2>&1 && fetch_dropbear; }; then
        for d in "$DB"/debs/*.deb; do dpkg -x "$d" "$DB/x"; done
        DBIN=$(find "$DB/x" -type f -name dropbear -perm -u+x | head -n1)
        DCONV=$(find "$DB/x" -type f -name dropbearconvert | head -n1)
        DLLP=$(find "$DB/x" -name '*.so*' -printf '%h\n' 2>/dev/null | sort -u | paste -sd: -)
        if [ -n "$DBIN" ] && copy_libs "$DBIN" "$DLLP" "$DB/x"; then
            cp "$DBIN" "$ROOT/bin/dropbear"
            for t in ed25519 ecdsa rsa; do
                [ -f "/etc/ssh/ssh_host_${t}_key" ] && [ -n "$DCONV" ] || continue
                if LD_LIBRARY_PATH=$DLLP "$DCONV" openssh dropbear "/etc/ssh/ssh_host_${t}_key" \
                    "$ROOT/etc/dropbear/dropbear_${t}_host_key" >/dev/null 2>&1; then
                    DROPBEAR_ARGS+=" -r /etc/dropbear/dropbear_${t}_host_key"
                fi
            done
            [ -n "$DROPBEAR_ARGS" ] || DROPBEAR_ARGS=" -R"
            {
                [ ${#AUTH_KEYS[@]} -gt 0 ] && printf '%s\n' "${AUTH_KEYS[@]}"
                [ -f /root/.ssh/authorized_keys ] && grep -Ev '^(#|$)' /root/.ssh/authorized_keys
            } >"$ROOT/root/.ssh/authorized_keys" || true
            chmod 600 "$ROOT/root/.ssh/authorized_keys"
            [ -s "$ROOT/root/.ssh/authorized_keys" ] || { warn "no SSH keys for rescue SSH; disabled"; rm -f "$ROOT/bin/dropbear"; }
        else
            warn "dropbear or its libraries unusable; rescue SSH disabled"
        fi
    else
        warn "could not download dropbear-bin from the package archive; rescue SSH disabled"
    fi
    rm -rf "$DB"
fi

# ld.so cache for the RAM root
printf '%s\n' "${LIB_DIRS[@]}" /lib /usr/lib | sort -u >"$ROOT/etc/ld.so.conf"
ldconfig -r "$ROOT" 2>/dev/null || warn "ldconfig -r failed (default search paths will be used)"

# ---- config for /shutdown (variables are read via ${!v}) ----
# shellcheck disable=SC2034
{
    for v in MODE DISK DISK_SIZE DISK_MODEL EXTRACT_SIZE EXTRACT_SHA256 IMAGE_SHA256 IMAGE_NAME \
        BOOT_OFFSET BOOT_SIZE BOOTFS_SHA256 NEW_BOOT_PART OLD_BOOT_PART NET_IF NET_IP NET_PREFIX \
        NET_GW REHEARSAL_WAIT MAX_ATTEMPTS DROPBEAR_ARGS; do
        printf '%s=%q\n' "$v" "${!v}"
    done
} >"$ROOT/config"

# ---- the PID 1 script run by systemd-shutdown ----
cat >"$ROOT/shutdown" <<'SHUTDOWN'
#!/bin/bash
# brutal-upgrader exitrd stage. Runs as PID 1 after systemd-shutdown has killed
# every process and unmounted / remounted read-only all filesystems.
# NEVER exit: PID 1 exiting panics the kernel.

export PATH=/bin HOME=/root
VERB=${1:-reboot}
. /config
LOG=/log

log() {
    local m="[$(date '+%H:%M:%S')] $*"
    echo "$m" >>"$LOG"
    echo "brutal-upgrader: $*" >/dev/console 2>/dev/null
}

hash_of() { local h; h=$(sha256sum "$1"); echo "${h%% *}"; }

disk_hash() { # offset size
    local h
    h=$(dd if="$DISK" bs=4M iflag=skip_bytes,count_bytes skip="$1" count="$2" status=none | sha256sum)
    echo "${h%% *}"
}

hang() {
    log "Staying in the RAM environment. ssh root@$NET_IP, see /log. Retry: /shutdown flash"
    while :; do sleep 3600; done
}

final() { # reboot | poweroff
    sync
    sleep 2
    if [ "$1" = poweroff ]; then echo o >/proc/sysrq-trigger; else echo b >/proc/sysrq-trigger; fi
    hang
}

abort_safe() { # nothing has been written yet: go back to the old OS
    log "ABORT before any write: $*"
    log "The disk is untouched; rebooting into the old OS."
    save_log_old_boot
    [ "$VERB" = poweroff ] || [ "$VERB" = halt ] && final poweroff
    final reboot
}

fail_after_write() {
    log "FAILED after writing started: $*"
}

setup_api() {
    [ -e /proc/self ] || mount -t proc proc /proc
    [ -d /sys/class ] || mount -t sysfs sysfs /sys
    [ -e /dev/null ] || mount -t devtmpfs devtmpfs /dev
    mkdir -p /dev/pts
    [ -e /dev/pts/ptmx ] || mount -t devpts -o gid=5,mode=620,ptmxmode=666 devpts /dev/pts
    mountpoint -q /tmp 2>/dev/null || mount -t tmpfs -o size=16m tmpfs /tmp 2>/dev/null
}

feed_watchdog() {
    local w
    for w in /sys/class/watchdog/watchdog*; do
        [ "$(cat "$w/state" 2>/dev/null)" = active ] || continue
        ( exec 3>"/dev/${w##*/}"; while :; do printf . >&3; sleep 5; done ) 2>/dev/null &
        log "hardware watchdog ${w##*/} is active: feeding it"
    done
}

net_up() {
    local i
    ip link set lo up
    ip link set "$NET_IF" up || { log "cannot bring up $NET_IF"; return 1; }
    for ((i = 0; i < 20; i++)); do
        [ "$(cat "/sys/class/net/$NET_IF/carrier" 2>/dev/null)" = 1 ] && break
        sleep 1
    done
    ip -4 addr flush dev "$NET_IF"
    ip addr add "$NET_IP/$NET_PREFIX" dev "$NET_IF"
    ip route replace default via "$NET_GW" dev "$NET_IF"
    log "network: $NET_IF $NET_IP/$NET_PREFIX gw $NET_GW (carrier=$(cat "/sys/class/net/$NET_IF/carrier" 2>/dev/null))"
}

rescue_ssh() {
    [ -x /bin/dropbear ] || { log "no rescue SSH in this RAM root"; return 0; }
    # shellcheck disable=SC2086
    dropbear -F -E -s -p 22 $DROPBEAR_ARGS -P /tmp/dropbear.pid >>/dropbear.log 2>&1 &
    log "rescue SSH: ssh root@$NET_IP (dropbear, key auth)"
}

release_oldroot() {
    if grep -q ' /oldroot' /proc/mounts; then
        umount -R /oldroot 2>>"$LOG" || umount -l /oldroot 2>>"$LOG"
    fi
    sync
    local rw
    # any block device of the target disk (or the old root, often "/dev/root") still read-write?
    rw=$(awk -v d="$DISK" '($1 ~ "^"d || $1 == "/dev/root") && $4 ~ /(^|,)rw(,|$)/' /proc/mounts)
    if [ -n "$rw" ]; then
        log "still mounted read-write: $rw"
        return 1
    fi
    log "old root released; mounts on $DISK: $(grep -c "^$DISK" /proc/mounts)"
}

save_log_old_boot() { # rehearsal / abort: leave the log on the old boot partition
    [ -b "$OLD_BOOT_PART" ] || return 0
    grep -q "^$OLD_BOOT_PART " /proc/mounts && return 0
    mkdir -p /mnt
    if mount -t vfat "$OLD_BOOT_PART" /mnt 2>/dev/null; then
        cp "$LOG" "/mnt/brutal-upgrader-$MODE.log"
        umount /mnt
        sync
    fi
}

prewrite_checks() {
    local s m
    [ -b "$DISK" ] || { echo "$DISK does not exist"; return 1; }
    s=$(blockdev --getsize64 "$DISK")
    [ "$s" = "$DISK_SIZE" ] || { echo "$DISK size $s != recorded $DISK_SIZE (wrong disk?)"; return 1; }
    m=$(cat "/sys/block/${DISK##*/}/device/model" 2>/dev/null | sed 's/ *$//')
    [ -z "$DISK_MODEL" ] || [ "$m" = "$DISK_MODEL" ] ||
        { echo "$DISK model '$m' != recorded '$DISK_MODEL' (wrong disk?)"; return 1; }
    log "verifying image in RAM"
    [ "$(hash_of /data/image.img.xz)" = "$IMAGE_SHA256" ] || { echo "image in RAM is corrupt"; return 1; }
    [ "$(hash_of /data/bootfs.img)" = "$BOOTFS_SHA256" ] || { echo "prepared bootfs in RAM is corrupt"; return 1; }
    return 0
}

flash_once() {
    local got
    log "writing $IMAGE_NAME to $DISK (progress: /progress)"
    set -o pipefail
    if ! xz -dc /data/image.img.xz | dd of="$DISK" bs=4M iflag=fullblock conv=fsync status=progress 2>/progress; then
        set +o pipefail
        log "write pipeline failed: $(tail -c 300 /progress | tr '\r' '\n' | tail -n 3)"
        return 1
    fi
    set +o pipefail
    sync
    blockdev --flushbufs "$DISK"
    echo 3 >/proc/sys/vm/drop_caches
    log "write done; reading back $EXTRACT_SIZE bytes"
    got=$(disk_hash 0 "$EXTRACT_SIZE")
    if [ "$got" != "$EXTRACT_SHA256" ]; then
        log "read-back mismatch: $got != $EXTRACT_SHA256"
        return 1
    fi
    log "read-back OK ($got)"
    log "writing prepared boot partition ($BOOT_SIZE bytes at offset $BOOT_OFFSET)"
    dd if=/data/bootfs.img of="$DISK" bs=4M seek="$BOOT_OFFSET" oflag=seek_bytes conv=fsync,notrunc status=none ||
        { log "bootfs write failed"; return 1; }
    sync
    blockdev --flushbufs "$DISK"
    echo 3 >/proc/sys/vm/drop_caches
    got=$(disk_hash "$BOOT_OFFSET" "$BOOT_SIZE")
    if [ "$got" != "$BOOTFS_SHA256" ]; then
        log "bootfs read-back mismatch: $got != $BOOTFS_SHA256"
        return 1
    fi
    log "bootfs read-back OK"
    return 0
}

flash() {
    local n
    for ((n = 1; n <= MAX_ATTEMPTS; n++)); do
        log "flash attempt $n/$MAX_ATTEMPTS"
        if flash_once; then
            log "SUCCESS: $IMAGE_NAME is on $DISK"
            blockdev --rereadpt "$DISK" 2>/dev/null
            sleep 2
            mkdir -p /mnt
            if mount -t vfat "$NEW_BOOT_PART" /mnt 2>>"$LOG"; then
                log "rebooting into the new OS (first boot takes a few minutes and may reboot itself)"
                cp "$LOG" /mnt/brutal-upgrader.log
                umount /mnt
            else
                log "could not mount $NEW_BOOT_PART to store the log (not fatal)"
            fi
            final reboot
        fi
        fail_after_write "attempt $n failed"
        sleep 5
    done
    log "all $MAX_ATTEMPTS attempts failed. NOT rebooting: the disk is probably unbootable."
    hang
}

main() {
    trap '' INT TERM HUP
    setup_api
    log "brutal-upgrader exitrd started: mode=$MODE verb=$VERB"
    feed_watchdog
    net_up || log "network setup failed (continuing)"
    rescue_ssh
    release_oldroot || abort_safe "could not release the old root filesystem"

    local why
    why=$(prewrite_checks) || abort_safe "$why"
    log "pre-write checks OK"

    case $MODE in
        rehearsal)
            log "REHEARSAL: everything is ready; a real run would now write $DISK."
            log "waiting ${REHEARSAL_WAIT}s (ssh root@$NET_IP to look around), then rebooting into the old OS"
            sleep "$REHEARSAL_WAIT"
            log "rehearsal finished"
            save_log_old_boot
            final reboot
            ;;
        real)
            if [ "$VERB" != reboot ]; then
                abort_safe "system is doing '$VERB', not reboot; not flashing"
            fi
            flash
            ;;
        *)
            abort_safe "unknown mode '$MODE'"
            ;;
    esac
}

case $VERB in
    flash) flash ;;                        # manual retry from rescue SSH
    reboot-now) sync; echo b >/proc/sysrq-trigger ;;
    poweroff-now) sync; echo o >/proc/sysrq-trigger ;;
    *) main ;;
esac
# never return from PID 1
[ "$$" = 1 ] && hang
SHUTDOWN
chmod 755 "$ROOT/shutdown"
touch "$ROOT/$MARKER"

# ---- self-test the RAM root ----
info "Self-testing the RAM root (chroot)"
chroot "$ROOT" /bin/bash -c '
    set -e
    bash -n /shutdown
    . /config
    printf abc | xz -z | xz -dc | sha256sum >/dev/null
    dd --version >/dev/null; mount --version >/dev/null; umount --version >/dev/null
    blockdev --version >/dev/null 2>&1 || blockdev -V >/dev/null 2>&1
    ip -V >/dev/null; date >/dev/null; sleep 0; grep -q . /config; mkdir -p /tmp/t; cp /config /tmp/t/
    rm -rf /tmp/t 2>/dev/null || true
' || die "RAM root self-test failed"
if [ -x "$ROOT/bin/dropbear" ]; then
    DB_VER=$(chroot "$ROOT" /bin/dropbear -V 2>&1 || true)
    if grep -qi dropbear <<<"$DB_VER"; then
        info "Rescue SSH: dropbear OK (${DB_VER%%$'\n'*})"
    else
        warn "dropbear does not run in the RAM root; rescue SSH disabled"
        rm -f "$ROOT/bin/dropbear"
    fi
fi

sync
ROOT_USED=$(du -sk "$ROOT" | cut -f1)
MEM_AVAIL_K=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
info "RAM root ready: $(( ROOT_USED / 1024 )) MiB in /run, $(( MEM_AVAIL_K / 1024 )) MiB RAM still available"
[ "$MEM_AVAIL_K" -gt $(( 150 * 1024 )) ] || die "too little RAM left for the flashing stage"

cp "$HOST_LOG" "$ROOT/log"

# ================================================================== FINISH ==

show_generated() {
    say ""
    say "${C_BLD}--- generated user-data (password hash masked) ---${C_OFF}"
    mount -o loop,ro "$BOOTFS" "$MNT"
    sed -E 's/^(  passwd: ).*/\1"<hash of the current password>"/' "$MNT/user-data"
    say "${C_BLD}--- generated network-config ---${C_OFF}"
    cat "$MNT/network-config"
    say "${C_BLD}--- meta-data / cmdline.txt ---${C_OFF}"
    cat "$MNT/meta-data" "$MNT/cmdline.txt"
    say "${C_BLD}--- new boot partition ---${C_OFF}"
    ls "$MNT" | paste -sd' ' - | fold -s -w 100
    umount "$MNT"
    say "${C_BLD}--- RAM root ---${C_OFF}"
    ls "$ROOT/bin" | paste -sd' ' - | fold -s -w 100
    say "rescue SSH: $([ -x "$ROOT/bin/dropbear" ] && echo "yes (dropbear$DROPBEAR_ARGS)" || echo no)"
    say ""
}
show_generated

if [ "$MODE" = dry-run ]; then
    info "Dry run complete: everything verified, nothing armed, nothing written."
    exit 0
fi

# ---- confirmation ----
if [ "$MODE" = real ]; then
    if [ "$DESTROY_YES" != 1 ]; then
        [ -r /dev/tty ] || die "no terminal for confirmation; use --yes-destroy-everything"
        printf '%sThis ERASES %s (%s, %s) and everything on it.%s\n' "$C_RED" "$DISK" "$(human "$DISK_SIZE")" "${DISK_MODEL:-disk}" "$C_OFF"
        printf "Type 'ERASE %s' to continue: " "$DISK_NAME"
        read -r answer </dev/tty
        [ "$answer" = "ERASE $DISK_NAME" ] || die "not confirmed; nothing done"
    fi
else
    if [ "$ASSUME_YES" != 1 ]; then
        [ -r /dev/tty ] || die "no terminal for confirmation; use --yes"
        printf 'Rehearsal reboots this Pi twice (about 3-5 minutes). Continue? [y/N] '
        read -r answer </dev/tty
        case $answer in y|Y|yes) ;; *) die "not confirmed; nothing done" ;; esac
    fi
fi

# ---- arm ----
info "Disabling swap (the RAM root must stay in RAM)"
swapoff -a || die "swapoff failed; not arming"
MEM_AVAIL_K=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
[ "$MEM_AVAIL_K" -gt $(( 150 * 1024 )) ] || die "too little RAM after swapoff"

cp "$HOST_LOG" "$ROOT/log"
! run_noexec || die "/run is mounted noexec; systemd-shutdown could not run $EXITRD/shutdown"
if [ -e "$EXITRD" ]; then
    [ -z "$(exitrd_foreign)" ] || die "$EXITRD changed since preflight; not arming"
    find "$EXITRD" -mindepth 1 -maxdepth 1 -exec mv -t "$ROOT/" {} + || die "cannot move $EXITRD leftovers"
    rmdir "$EXITRD" || die "cannot remove $EXITRD"
fi
plymouth_off || die "cannot mask plymouth; not arming"
[ "$PLYMOUTH_MASKED" = 0 ] || info "Boot splash (plymouth) disabled for this shutdown"
mv "$ROOT" "$EXITRD"
ARMED=1
sync
info "ARMED ($MODE). $EXITRD/shutdown will run at the end of this reboot."
say ""
if [ "$MODE" = real ]; then
    say "What happens now:"
    say "  - This SSH session drops; the Pi shuts down its services (up to ~1-2 min)."
    say "  - The RAM environment flashes $DISK (roughly 2-6 min) and reboots."
    [ -x "$EXITRD/bin/dropbear" ] &&
        say "  - While flashing:  ssh root@$NET_IP 'tail -f /log'   (same host key as now)"
    say "  - New OS first boot takes a few minutes and may reboot once. Then:"
    say "      ssh-keygen -R $NET_IP; ssh $NEW_USER@$NET_IP"
    say "  - The flash log ends up in /boot/firmware/brutal-upgrader.log on the new OS."
else
    say "Rehearsal: after shutdown, ssh root@$NET_IP into the RAM environment (for ${REHEARSAL_WAIT}s)."
    say "The Pi then reboots into this OS; the log is saved to $BOOT_MNT/brutal-upgrader-rehearsal.log"
fi
say ""
sleep 3
systemctl reboot -i || { disarm_exitrd; plymouth_on; ARMED=0; die "systemctl reboot failed; disarmed"; }
