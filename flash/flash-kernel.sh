#!/usr/bin/env bash
# ==========================================================================
# DISCLAIMER
#
# Your warranty is void. Let's be honest, it died the day you unlocked the
# bootloader.
#
# I am not responsible for bricked phones, bootloops, a phone that only boots
# on Tuesdays, you getting fired because your alarm didn't go off after
# flashing this, a dead battery on the way to the airport, or thermonuclear
# war.
#
# YOU are choosing to build and flash a custom kernel. If it goes wrong, the
# person to talk to is in the mirror. This script does a test boot first so
# you don't have to find things out the hard way. Read the README. Twice.
# ==========================================================================
#
# Puts a KernelSU Next kernel into your ROM's stock boot.img for the Xiaomi
# Mi 11 (venus), test-boots it, and flashes it only after you confirm the test
# boot worked. Linux and macOS. Needs adb, fastboot, curl and unzip.
#
#   ./flash-kernel.sh --image Image --stock-boot boot.img [--prepare-only]
#   ./flash-kernel.sh --restore boot.img
#
# Same steps as flash-kernel.ps1; see that file or the README for details.

set -euo pipefail
# Git Bash on Windows would turn device paths like /data/local/tmp into
# Windows paths. Harmless on Linux and macOS.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

DEVICE=venus
MANAGER_PKG=com.rifsxd.ksunext
REMOTE=/data/local/tmp/ksu-flash
MANAGER_URL=https://github.com/KernelSU-Next/KernelSU-Next/releases/download/v3.4.0/KernelSU_Next_v3.4.0_33294-release.apk
MAGISK_URL=https://github.com/topjohnwu/Magisk/releases/download/v31.0/Magisk-v31.0.apk

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CACHE_DIR="$SCRIPT_DIR/downloads"
SESSION="$SCRIPT_DIR/work/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$CACHE_DIR" "$SESSION"
exec > >(tee -a "$SESSION/log.txt") 2>&1

IMAGE= STOCK_BOOT= MANAGER_APK= PREPARE_ONLY=0 RESTORE= ACCEPT=0

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    [OK] %s\n' "$*"; }
note() { printf '    [!] %s\n' "$*"; }
die()  { printf '\nERROR: %s\nLog: %s\n' "$*" "$SESSION" >&2; exit 1; }
# Remove the temporary files (up to ~400 MB) from the phone when the script ends.
cleanup_phone() { [ "$(adb get-state 2>/dev/null | tr -d '\r')" = device ] && adb shell "rm -rf $REMOTE" >/dev/null 2>&1; true; }

usage() {
    cat <<EOF
Usage: $0 --image <Image|Image.gz|artifact.zip> --stock-boot <boot.img> [--prepare-only]
       $0 --restore <boot.img>
Options: --manager-apk <apk>  --manager-url <url>  --magisk-url <url>  --accept-disclaimer
EOF
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --image) IMAGE=$2; shift 2 ;;
        --stock-boot) STOCK_BOOT=$2; shift 2 ;;
        --manager-apk) MANAGER_APK=$2; shift 2 ;;
        --manager-url) MANAGER_URL=$2; shift 2 ;;
        --magisk-url) MAGISK_URL=$2; shift 2 ;;
        --prepare-only) PREPARE_ONLY=1; shift ;;
        --restore) RESTORE=$2; shift 2 ;;
        --accept-disclaimer) ACCEPT=1; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

confirm() { # confirm "question" default(y/n)
    local hint=[Y/n] answer
    [ "${2:-y}" = n ] && hint=[y/N]
    while true; do
        read -r -p "    $1 $hint " answer </dev/tty || answer=
        answer=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')
        case "$answer" in
            '') [ "${2:-y}" = y ]; return ;;
            y|yes) return 0 ;;
            n|no) return 1 ;;
        esac
    done
}

confirm_danger() {
    local answer
    printf '    %s\n' "$1"
    read -r -p '    Type YES (capitals) to continue: ' answer </dev/tty || answer=
    [ "$answer" = YES ]
}

show_disclaimer() {
    cat <<'EOF'

  DISCLAIMER
  Your warranty is void (it died when you unlocked the bootloader). I am not
  responsible for bricked phones, bootloops, you getting fired because your
  alarm did not go off, or thermonuclear war. You chose to flash a custom
  kernel; if it goes wrong, the person to talk to is in the mirror.

EOF
    [ "$ACCEPT" = 1 ] || read -r -p '  Press Enter if you read that and accept it (Ctrl+C to quit) ' _ </dev/tty
}

# Local file path as adb/fastboot see it (only differs in Git Bash on Windows).
lp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

download() { # download url file -> prints path
    local target="$CACHE_DIR/$2"
    if [ ! -f "$target" ]; then
        info "Downloading $1" >&2
        curl -fL --retry 3 -o "$target.part" "$1"
        mv -f "$target.part" "$target"
    fi
    printf '%s' "$target"
}

# Full "Linux version ..." banner and the release (uname -r) from a kernel file.
banner_of()  { LC_ALL=C grep -a -o -m1 'Linux version [0-9][^[:cntrl:]]*' "$1" | head -n1 | sed 's/[[:space:]]*$//'; }
release_of() { banner_of "$1" | awk '{print $3}'; }
is_arm64_image() { [ "$(LC_ALL=C dd if="$1" bs=1 skip=56 count=4 2>/dev/null | od -An -c | tr -d ' \n')" = 'ARMd' ]; }

shell() { adb shell "$1"; }

wait_adb() { # timeout seconds
    local end=$(( $(date +%s) + ${1:-300} )) warned=0
    while [ "$(date +%s)" -lt "$end" ]; do
        [ "$(adb get-state 2>/dev/null | tr -d '\r')" = device ] && return 0
        if [ $warned = 0 ] && adb devices 2>/dev/null | grep -q unauthorized; then
            note 'Allow USB debugging on the phone (tick "Always allow from this computer").'; warned=1
        fi
        sleep 2
    done
    return 1
}

wait_boot() {
    wait_adb "${1:-420}" || return 1
    local end=$(( $(date +%s) + ${1:-420} ))
    while [ "$(date +%s)" -lt "$end" ]; do
        [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && return 0
        sleep 3
    done
    return 1
}

wait_fastboot() {
    while true; do
        local end=$(( $(date +%s) + ${1:-90} ))
        while [ "$(date +%s)" -lt "$end" ]; do
            fastboot devices 2>/dev/null | grep -q fastboot && return 0
            sleep 2
        done
        note 'No phone found in fastboot mode.'
        info 'On Linux you may need udev rules for Android devices (package android-sdk-platform-tools-common or similar).'
        confirm 'Try again?' || die 'Fastboot not reachable.'
    done
}

enter_fastboot() {
    fastboot devices 2>/dev/null | grep -q fastboot && return 0
    info 'Rebooting to the bootloader (fastboot)...'
    adb reboot bootloader
    wait_fastboot
    fastboot getvar product 2>&1 | grep -q "product:[[:space:]]*$DEVICE" || die 'Fastboot reports a different device.'
}

fastboot_slot() {
    fastboot getvar current-slot 2>&1 | sed -nE 's/.*current-slot:[[:space:]]*_?([ab]).*/_\1/p' | head -n1
}

flash_restore() {
    [ -f "$RESTORE" ] || die "File not found: $RESTORE"
    step "Emergency restore: flashing $RESTORE"
    if [ "$(adb get-state 2>/dev/null | tr -d '\r')" = device ]; then adb reboot bootloader
    else info 'Put the phone in fastboot: power off, then hold power + volume down.'; fi
    wait_fastboot 300
    fastboot getvar product 2>&1 | grep -q "product:[[:space:]]*$DEVICE" || die 'Fastboot reports a different device.'
    local slot; slot=$(fastboot_slot)
    [ -n "$slot" ] || die 'Could not read the active slot.'
    confirm "Overwrite boot$slot with $(basename "$RESTORE")?" || die 'Stopped.'
    fastboot flash "boot$slot" "$(lp "$RESTORE")" || die 'Flashing failed.'
    ok "boot$slot restored"
    fastboot reboot
}

# --------------------------------------------------------------------------

echo 'KernelSU Next kernel flasher for the Xiaomi Mi 11 (venus)'
show_disclaimer

for tool in adb fastboot curl unzip; do
    command -v "$tool" >/dev/null || die "$tool not found. Install Android platform-tools, curl and unzip first."
done

if [ -n "$RESTORE" ]; then flash_restore; exit 0; fi
[ -n "$IMAGE" ] && [ -n "$STOCK_BOOT" ] || usage
[ -f "$IMAGE" ] || die "File not found: $IMAGE"
[ -f "$STOCK_BOOT" ] || die "File not found: $STOCK_BOOT"
trap cleanup_phone EXIT

step 'Checking the phone'
info 'Connect the Mi 11 over USB with USB debugging on (Settings > System > Developer options).'
wait_adb 180 || die 'No phone found over adb (or more than one connected).'
DEV_DEVICE=$(shell 'getprop ro.product.device' | tr -d '\r')
DEV_SLOT=$(shell 'getprop ro.boot.slot_suffix' | tr -d '\r')
DEV_RELEASE=$(shell 'uname -r' | tr -d '\r')
info "Device:  $DEV_DEVICE  (Android $(shell 'getprop ro.build.version.release' | tr -d '\r'), slot $DEV_SLOT)"
info "ROM:     $(shell 'getprop ro.build.display.id' | tr -d '\r')"
info "Kernel:  $DEV_RELEASE"
[ "$DEV_DEVICE" = "$DEVICE" ] || die "This script is only for the Mi 11 ($DEVICE); found: $DEV_DEVICE."
case "$DEV_SLOT" in _a|_b) ;; *) die "Unexpected slot '$DEV_SLOT'." ;; esac
if adb shell pm list packages com.topjohnwu.magisk 2>/dev/null | tr -d '\r' | grep -qx 'package:com.topjohnwu.magisk'; then
    note 'The Magisk app is installed. KernelSU would run your Magisk modules from /data/adb at boot.'
    note 'Uninstall Magisk first: Magisk app > Uninstall Magisk > Complete uninstall. Then run this again.'
    die 'Stopped: Magisk is still installed. Nothing was changed.'
fi

# magiskboot from the official Magisk APK runs as the normal shell user.
shell "rm -rf $REMOTE 2>/dev/null; mkdir -p $REMOTE"
MAGISK_APK=$(download "$MAGISK_URL" "$(basename "$MAGISK_URL")")
unzip -p "$MAGISK_APK" lib/arm64-v8a/libmagiskboot.so > "$SESSION/magiskboot"
[ -s "$SESSION/magiskboot" ] || die "No arm64 magiskboot in $MAGISK_APK"
adb push "$(lp "$SESSION/magiskboot")" "$REMOTE/magiskboot" >/dev/null
shell "chmod 755 $REMOTE/magiskboot"

step 'Checking the KernelSU kernel'
KERNEL="$SESSION/ksu-Image"
case "$IMAGE" in
    *.zip)
        if unzip -l "$IMAGE" | grep -qE '(^|[[:space:]/])Image$'; then
            unzip -p "$IMAGE" Image > "$KERNEL"
            if unzip -l "$IMAGE" | grep -q 'Image.sha256'; then
                [ "$(unzip -p "$IMAGE" Image.sha256 | cut -d' ' -f1)" = "$(sha256 "$KERNEL")" ] \
                    || die 'SHA256 of the Image does not match Image.sha256.'
                ok 'SHA256 matches Image.sha256'
            fi
        elif unzip -l "$IMAGE" | grep -q 'Image.gz'; then
            unzip -p "$IMAGE" Image.gz | gzip -dc > "$KERNEL"
        else
            die "No 'Image' or 'Image.gz' in $IMAGE."
        fi ;;
    *)
        if [ "$(basename "$IMAGE")" = Image ] && [ -f "$(dirname "$IMAGE")/Image.sha256" ]; then
            [ "$(cut -d' ' -f1 < "$(dirname "$IMAGE")/Image.sha256")" = "$(sha256 "$IMAGE")" ] \
                || die 'SHA256 of the Image does not match Image.sha256.'
            ok 'SHA256 matches Image.sha256'
        fi
        if [ "$(LC_ALL=C head -c2 "$IMAGE" | od -An -tx1 | tr -d ' \n')" = 1f8b ]; then gzip -dc < "$IMAGE" > "$KERNEL"
        else cp -f "$IMAGE" "$KERNEL"; fi ;;
esac
is_arm64_image "$KERNEL" || die "$IMAGE is not an arm64 kernel Image."
KSU_BANNER=$(banner_of "$KERNEL")
KSU_RELEASE=$(release_of "$KERNEL")
[ -n "$KSU_RELEASE" ] || die 'No "Linux version" string found in the kernel.'
info "Kernel:  $KSU_RELEASE"
LC_ALL=C grep -aq KernelSU "$KERNEL" || die 'This kernel does not contain KernelSU.'
ok 'KernelSU is in the kernel'
# Same source commit as the ROM, or the vendor modules (display, touch, audio)
# will not load. This check cannot be overridden on purpose.
if [ "$KSU_RELEASE" != "$DEV_RELEASE" ]; then
    note "This kernel ($KSU_RELEASE) is not the version your phone runs ($DEV_RELEASE)."
    note 'Build it again with kernel_version set to exactly your "adb shell uname -r".'
    die 'Stopped: kernel version does not match your ROM. Nothing was changed.'
fi
ok 'Kernel version matches your ROM exactly'
adb push "$(lp "$KERNEL")" "$REMOTE/ksu-Image" >/dev/null

step 'Checking the stock boot.img'
adb push "$(lp "$STOCK_BOOT")" "$REMOTE/stock-boot.img" >/dev/null
# "cpio test" returns a bit mask: (code & 3) == 0 means an unpatched ramdisk.
CHECK=$(shell "cd $REMOTE && rm -rf chk && mkdir chk && cd chk && ../magiskboot unpack ../stock-boot.img >/dev/null 2>&1; [ -f kernel ] || { echo NO_KERNEL; exit 0; }; ../magiskboot cpio ramdisk.cpio test >/dev/null 2>&1; [ \$((\$? & 3)) -eq 0 ] || { echo PATCHED; exit 0; }; echo STOCK_OK" | tr -d '\r')
case "$CHECK" in
    *NO_KERNEL*) die 'That file is not a usable boot.img (no kernel inside).' ;;
    *PATCHED*) die 'That boot.img is patched (Magisk or similar). Use the original boot.img from your ROM.' ;;
    *STOCK_OK*) ;;
    *) die "Could not check the boot.img: $CHECK" ;;
esac
adb pull "$REMOTE/chk/kernel" "$(lp "$SESSION/stock-kernel")" >/dev/null
STOCK_RELEASE=$(release_of "$SESSION/stock-kernel")
if [ "$STOCK_RELEASE" != "$DEV_RELEASE" ]; then
    note "The boot.img has kernel ${STOCK_RELEASE:-unknown}, your phone runs $DEV_RELEASE."
    die 'Stopped: the boot.img is from a different ROM build. Use the one from exactly your build. Nothing was changed.'
fi
ok 'Unpatched boot.img of exactly your build'

step 'Building boot-ksu.img (stock ramdisk + KernelSU kernel)'
shell "cd $REMOTE && rm -rf new && mkdir new && cd new && ../magiskboot unpack ../stock-boot.img >/dev/null 2>&1 && cp -f ../ksu-Image kernel && ../magiskboot repack ../stock-boot.img ../boot-ksu.img >/dev/null 2>&1"
# Unpacking the result must give exactly our kernel and an unpatched ramdisk.
VERIFY=$(shell "cd $REMOTE && rm -rf vfy && mkdir vfy && cd vfy && ../magiskboot unpack ../boot-ksu.img >/dev/null 2>&1 && cmp -s kernel ../ksu-Image && ../magiskboot cpio ramdisk.cpio test >/dev/null 2>&1; [ \$((\$? & 3)) -eq 0 ] && echo VERIFIED" | tr -d '\r') || true
case "$VERIFY" in *VERIFIED*) ;; *) die "Verifying boot-ksu.img failed: $VERIFY" ;; esac
BOOT_IMG="$SESSION/boot-ksu.img"
adb pull "$REMOTE/boot-ksu.img" "$(lp "$BOOT_IMG")" >/dev/null
ok 'boot-ksu.img built and verified'
info "SHA256: $(sha256 "$BOOT_IMG")"

if [ "$PREPARE_ONLY" = 1 ]; then
    step 'Done (--prepare-only)'
    info "boot-ksu.img is in $SESSION. Nothing was rebooted or flashed."
    exit 0
fi

step 'Test boot (nothing is flashed)'
info 'The phone boots once with the KernelSU kernel. A normal reboot brings back your current boot.'
enter_fastboot
if ! fastboot boot "$(lp "$BOOT_IMG")"; then
    note "'fastboot boot' is not supported or failed."
    fastboot reboot || true
    wait_boot || die 'The phone does not boot normally any more. Use --restore with your stock boot.img.'
    die 'The test boot could not run. Without a test boot nothing gets flashed; nothing was changed.'
fi
info 'Waiting for Android to finish booting (up to 7 minutes)...'
if ! wait_boot; then
    note 'The test boot did not finish. Nothing was flashed.'
    info 'Hold the power button for ~15 seconds; the phone then starts with your current boot.'
    info 'If the screen stayed black or touch did not work, the kernel does not match your ROM.'
    info 'If it booted but KernelSU was not detected, check hook_mode (use kprobes).'
    die 'Test boot failed.'
fi
TEST_OK=0
if [ "$(shell 'cat /proc/version' | tr -d '\r' | sed 's/[[:space:]]*$//')" = "$KSU_BANNER" ]; then
    ok 'Android is running the KernelSU kernel.'
    if [ -n "$MANAGER_APK" ]; then APK=$MANAGER_APK; else APK=$(download "$MANAGER_URL" "$(basename "$MANAGER_URL")"); fi
    if adb install -r "$(lp "$APK")" | grep -q Success; then ok 'KernelSU Next manager installed'; else note 'Installing the manager failed.'; fi
    adb shell monkey -p "$MANAGER_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
    info 'Check the phone now. KernelSU Next should say "Working" at the top.'
    confirm 'Do screen, touch, Wi-Fi and sound work, and does KernelSU Next say "Working"?' && TEST_OK=1
else
    note "Unexpected kernel after the test boot: $(shell 'cat /proc/version')"
fi
info 'Rebooting back to your current boot...'
adb reboot
wait_boot || die 'The phone does not boot normally after the test boot. Use --restore with your stock boot.img.'
[ "$TEST_OK" = 1 ] || die 'Test boot not approved; nothing was changed.'

step 'Confirm'
info "The test boot worked. Next: flash boot-ksu.img to boot$DEV_SLOT."
info "Keep your stock boot.img; it is your way back ($STOCK_BOOT)."
confirm_danger 'Flash the KernelSU boot image now?' || die 'Stopped by you; nothing was changed.'

step 'Flashing boot-ksu.img'
enter_fastboot
FB_SLOT=$(fastboot_slot)
[ "$FB_SLOT" = "$DEV_SLOT" ] || die "Fastboot reports slot ${FB_SLOT:-unknown}, Android reported $DEV_SLOT. Stopped."
fastboot flash "boot$DEV_SLOT" "$(lp "$BOOT_IMG")" || die 'Flashing failed.'
ok "boot$DEV_SLOT flashed"
fastboot reboot
info 'Waiting for Android to boot (up to 7 minutes)...'
if ! wait_boot; then
    note 'The phone does not boot.'
    info "Put it in fastboot (power + volume down) and restore: $0 --restore \"$STOCK_BOOT\""
    die 'Boot after flashing failed.'
fi
if [ "$(shell 'cat /proc/version' | tr -d '\r' | sed 's/[[:space:]]*$//')" = "$KSU_BANNER" ]; then ok 'The KernelSU kernel is running'
else note "Unexpected kernel: $(shell 'cat /proc/version')"; fi
step 'Done'
info '1. Open KernelSU Next; it should say "Working".'
info '2. Install a metamodule (e.g. meta-overlayfs) before other modules, or modules are not mounted.'
info '3. After a ROM update you lose root: build a kernel for the new uname -r and run this again.'
