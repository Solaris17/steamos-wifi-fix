#!/usr/bin/env bash
# It discovers Intel wireless devices that use iwlwifi and extracts
# the firmware filename requested by the running kernel.
#

set -Eeuo pipefail

FIRMWARE_DIR="/usr/lib/firmware"
UPSTREAM_BASE="https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main"

TMPDIR="$(mktemp -d)"
READONLY_CHANGED=0

cleanup() {
    rm -rf "$TMPDIR"

    if [[ "$READONLY_CHANGED" -eq 1 ]]; then
        echo
        echo "Restoring SteamOS read-only mode..."
        sudo steamos-readonly enable || true
    fi
}

trap cleanup EXIT


echo "============================================================"
echo " SteamOS Intel iwlwifi Firmware Repair"
echo "============================================================"
echo


# ------------------------------------------------------------
# System information
# ------------------------------------------------------------

if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
fi

echo "OS:      ${PRETTY_NAME:-unknown}"
echo "Build:   ${BUILD_ID:-unknown}"
echo "Kernel:  $(uname -r)"
echo


# ------------------------------------------------------------
# Find PCI devices supported by iwlwifi
# ------------------------------------------------------------

echo "Searching for PCI devices supported by iwlwifi..."
echo

declare -a IWL_DEVICES=()

for dev in /sys/bus/pci/devices/*; do
    [[ -r "$dev/modalias" ]] || continue

    alias="$(cat "$dev/modalias")"

    modules="$(modprobe --resolve-alias "$alias" 2>/dev/null || true)"

    if grep -qx 'iwlwifi' <<<"$modules"; then
        bdf="$(basename "$dev")"
        IWL_DEVICES+=("$bdf")
    fi
done

if (( ${#IWL_DEVICES[@]} == 0 )); then
    echo "ERROR: No PCI devices supported by iwlwifi were found."
    exit 1
fi

echo "Found ${#IWL_DEVICES[@]} iwlwifi-compatible PCI device(s):"

for bdf in "${IWL_DEVICES[@]}"; do
    echo
    lspci -nnk -s "${bdf#0000:}" || true
done

echo


# ------------------------------------------------------------
# Inspect kernel log for missing firmware
# ------------------------------------------------------------

echo "Checking kernel log for missing iwlwifi firmware..."
echo

IWL_LOG="$(
    sudo dmesg |
        grep -i 'iwlwifi' ||
        true
)"

declare -a REQUIRED_FW=()


#
# Modern iwlwifi commonly prints:
#
#   iwlwifi-bz-b0-gf-a0-100 is required
#
# Convert that into:
#
#   iwlwifi-bz-b0-gf-a0-100.ucode
#
while IFS= read -r fw; do
    [[ -n "$fw" ]] || continue
    REQUIRED_FW+=("${fw}.ucode")
done < <(
    grep -oE 'iwlwifi-[A-Za-z0-9._-]+ is required' <<<"$IWL_LOG" |
        awk '{print $1}' |
        sort -u
)


#
# Also catch explicit failed firmware loads such as:
#
#   Direct firmware load for iwlwifi-foo-100.ucode failed
#
while IFS= read -r fw; do
    [[ -n "$fw" ]] || continue

    found=0

    for existing in "${REQUIRED_FW[@]:-}"; do
        if [[ "$existing" == "$fw" ]]; then
            found=1
            break
        fi
    done

    (( found )) || REQUIRED_FW+=("$fw")

done < <(
    grep -oE 'iwlwifi-[A-Za-z0-9._-]+\.ucode' <<<"$IWL_LOG" |
        sort -u
)


if (( ${#REQUIRED_FW[@]} == 0 )); then
    echo "No missing iwlwifi firmware requirement was found in dmesg."
    echo
    echo "Recent iwlwifi messages:"
    grep -i 'iwlwifi' <<<"$IWL_LOG" | tail -50
    echo
    echo "Nothing to repair automatically."
    exit 0
fi


echo "Firmware referenced by the running kernel:"

for fw in "${REQUIRED_FW[@]}"; do
    printf '  %s\n' "$fw"
done

echo


# ------------------------------------------------------------
# Determine which files are actually missing
# ------------------------------------------------------------

declare -a MISSING_FW=()

for fw in "${REQUIRED_FW[@]}"; do

    if [[ -s "$FIRMWARE_DIR/$fw" ]]; then
        echo "Present: $FIRMWARE_DIR/$fw"
        continue
    fi

    if [[ -s "$FIRMWARE_DIR/$fw.zst" ]]; then
        echo "Present: $FIRMWARE_DIR/$fw.zst"
        continue
    fi

    if [[ -s "$FIRMWARE_DIR/intel/iwlwifi/$fw" ]]; then
        echo "Present: $FIRMWARE_DIR/intel/iwlwifi/$fw"
        continue
    fi

    if [[ -s "$FIRMWARE_DIR/intel/iwlwifi/$fw.zst" ]]; then
        echo "Present: $FIRMWARE_DIR/intel/iwlwifi/$fw.zst"
        continue
    fi

    MISSING_FW+=("$fw")

done


if (( ${#MISSING_FW[@]} == 0 )); then
    echo
    echo "All requested firmware files already exist."
    echo
    echo "The problem may require a reboot or may not be a missing-firmware issue."
    exit 0
fi


echo
echo "Missing firmware:"

for fw in "${MISSING_FW[@]}"; do
    printf '  %s\n' "$fw"
done

echo


# ------------------------------------------------------------
# Download all missing firmware before modifying the filesystem
# ------------------------------------------------------------

for fw in "${MISSING_FW[@]}"; do

    dest="$TMPDIR/$fw"

    echo "Downloading $fw..."

    #
    # Current linux-firmware layout keeps Intel Wi-Fi firmware here:
    #
    #   intel/iwlwifi/
    #
    url="${UPSTREAM_BASE}/intel/iwlwifi/${fw}"

    if ! curl \
        --fail \
        --location \
        --show-error \
        --progress-bar \
        "$url" \
        -o "$dest"
    then
        echo
        echo "ERROR: Could not download:"
        echo "  $url"
        exit 1
    fi

    size="$(stat -c '%s' "$dest")"

    if (( size < 10000 )); then
        echo "ERROR: Downloaded file is suspiciously small:"
        echo "  $fw: $size bytes"
        exit 1
    fi

    if grep -aq -m1 -E '<!DOCTYPE html|<html' "$dest"; then
        echo "ERROR: Download appears to be HTML rather than firmware:"
        echo "  $fw"
        exit 1
    fi

    echo "Downloaded:"
    ls -lh "$dest"
    file "$dest"
    echo
done


# ------------------------------------------------------------
# Make SteamOS writable
# ------------------------------------------------------------

if command -v steamos-readonly >/dev/null 2>&1; then
    echo "Temporarily disabling SteamOS read-only mode..."
    sudo steamos-readonly disable
    READONLY_CHANGED=1
    echo
fi


# ------------------------------------------------------------
# Install firmware
# ------------------------------------------------------------

echo "Installing firmware..."

for fw in "${MISSING_FW[@]}"; do
    sudo install \
        -o root \
        -g root \
        -m 0644 \
        "$TMPDIR/$fw" \
        "$FIRMWARE_DIR/$fw"

    echo "Installed: $FIRMWARE_DIR/$fw"
done


# ------------------------------------------------------------
# Restore SteamOS read-only mode
# ------------------------------------------------------------

if [[ "$READONLY_CHANGED" -eq 1 ]]; then
    echo
    echo "Restoring SteamOS read-only mode..."
    sudo steamos-readonly enable
    READONLY_CHANGED=0
fi


# ------------------------------------------------------------
# Decide whether reloading iwlwifi is safe
# ------------------------------------------------------------

echo
echo "Checking whether iwlwifi is currently carrying network traffic..."

declare -a ACTIVE_IWL_IFACES=()

for bdf in "${IWL_DEVICES[@]}"; do
    netdir="/sys/bus/pci/devices/$bdf/net"

    [[ -d "$netdir" ]] || continue

    for ifacepath in "$netdir"/*; do
        [[ -e "$ifacepath" ]] || continue

        iface="$(basename "$ifacepath")"

        if ip link show "$iface" 2>/dev/null |
            grep -qE 'state (UP|UNKNOWN)'; then
            ACTIVE_IWL_IFACES+=("$iface")
        fi
    done
done


if (( ${#ACTIVE_IWL_IFACES[@]} > 0 )); then

    echo
    echo "iwlwifi currently owns active interface(s):"

    for iface in "${ACTIVE_IWL_IFACES[@]}"; do
        echo "  $iface"
    done

    echo
    echo "Firmware installation is complete."
    echo "Skipping automatic driver reload to avoid dropping connectivity."
    echo
    echo "Reboot the system to activate the new firmware."

    exit 0
fi


# ------------------------------------------------------------
# Reload driver
# ------------------------------------------------------------

echo
echo "No active iwlwifi interfaces detected."
echo "Reloading iwlwifi..."

sudo modprobe -r iwlwifi || true
sudo modprobe iwlwifi

sleep 3


# ------------------------------------------------------------
# Verification
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Verification"
echo "============================================================"

echo
echo "--- iwlwifi firmware messages ---"
sudo dmesg |
    grep -iE 'iwlwifi.*(firmware|ucode|loaded)' |
    tail -30 ||
    true


echo
echo "--- iwlwifi PCI devices ---"

for bdf in "${IWL_DEVICES[@]}"; do

    echo
    echo "$bdf"

    lspci -nnk -s "${bdf#0000:}" || true

    netdir="/sys/bus/pci/devices/$bdf/net"

    if [[ -d "$netdir" ]]; then
        echo "Network interface(s):"

        find "$netdir" \
            -mindepth 1 \
            -maxdepth 1 \
            -printf '  %f\n'
    else
        echo "No network interface created."
    fi

done


echo
echo "--- Wireless devices ---"
iw dev || true


echo
echo "--- NetworkManager ---"
nmcli device 2>/dev/null || true


echo
echo "============================================================"

if sudo dmesg |
    grep -qiE 'iwlwifi .*loaded firmware version'
then
    echo "SUCCESS: iwlwifi loaded firmware."
else
    echo "WARNING: No successful iwlwifi firmware load was detected."
    echo
    echo "Recent messages:"
    sudo dmesg | grep -i iwlwifi | tail -50 || true
    exit 1
fi
