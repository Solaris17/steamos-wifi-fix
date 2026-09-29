#!/usr/bin/env bash
# It discovers Intel wireless devices that use iwlwifi and extracts
# the firmware filename requested by the running kernel.
# Also discovers Intel Bluetooth devices and extracts the firmware

set -Eeuo pipefail

FIRMWARE_DIR="/usr/lib/firmware"
UPSTREAM_BASE="https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main"

TMPDIR="$(mktemp -d)"
READONLY_CHANGED=0

WIFI_CHANGED=0
BT_CHANGED=0


# ============================================================
# Cleanup
# ============================================================

cleanup() {
    rm -rf "$TMPDIR"

    if [[ "$READONLY_CHANGED" -eq 1 ]]; then
        echo
        echo "Restoring SteamOS read-only mode..."
        sudo steamos-readonly enable || true
    fi
}

trap cleanup EXIT


# ============================================================
# Helpers
# ============================================================

firmware_present() {
    local rel="$1"

    [[ -s "$FIRMWARE_DIR/$rel" ]] ||
    [[ -s "$FIRMWARE_DIR/$rel.zst" ]]
}


declare -a FW_KIND=()
declare -a FW_SOURCE=()
declare -a FW_DEST=()
declare -a FW_OPTIONAL=()


queue_firmware() {
    local kind="$1"
    local source_rel="$2"
    local dest_rel="$3"
    local optional="${4:-0}"

    if firmware_present "$dest_rel"; then
        echo "Present: $FIRMWARE_DIR/$dest_rel"
        return 0
    fi

    # Avoid duplicate queue entries.
    for existing in "${FW_DEST[@]:-}"; do
        if [[ "$existing" == "$dest_rel" ]]; then
            return 0
        fi
    done

    FW_KIND+=("$kind")
    FW_SOURCE+=("$source_rel")
    FW_DEST+=("$dest_rel")
    FW_OPTIONAL+=("$optional")
}


# ============================================================
# System information
# ============================================================

echo "============================================================"
echo " SteamOS Intel Firmware Repair"
echo "============================================================"
echo

if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
fi

echo "OS:      ${PRETTY_NAME:-unknown}"
echo "Build:   ${BUILD_ID:-unknown}"
echo "Kernel:  $(uname -r)"
echo


echo "Reading kernel log..."
DMESG="$(sudo dmesg)"
echo


# ============================================================
#
#                       WI-FI
#
# ============================================================

echo "============================================================"
echo " Intel Wi-Fi"
echo "============================================================"
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

    modules="$(
        modprobe --resolve-alias "$alias" 2>/dev/null || true
    )"

    if grep -qx 'iwlwifi' <<<"$modules"; then
        bdf="$(basename "$dev")"
        IWL_DEVICES+=("$bdf")
    fi
done


if (( ${#IWL_DEVICES[@]} == 0 )); then
    echo "No PCI devices supported by iwlwifi were found."
else
    echo "Found ${#IWL_DEVICES[@]} iwlwifi-compatible PCI device(s):"

    for bdf in "${IWL_DEVICES[@]}"; do
        echo
        lspci -nnk -s "${bdf#0000:}" || true
    done
fi

echo


# ------------------------------------------------------------
# Find firmware requested by iwlwifi
# ------------------------------------------------------------

echo "Checking kernel log for missing iwlwifi firmware..."
echo

declare -a REQUIRED_WIFI_FW=()

#
# Preferred form:
#
#   iwlwifi-bz-b0-gf-a0-100 is required
#
mapfile -t REQUIRED_WIFI_FW < <(
    sed -nE \
        's/.*(iwlwifi-[A-Za-z0-9._-]+) is required.*/\1.ucode/p' \
        <<<"$DMESG" |
    sort -u
)


#
# Fallback form:
#
#   Direct firmware load for iwlwifi-foo.ucode failed with error -2
#
if (( ${#REQUIRED_WIFI_FW[@]} == 0 )); then
    mapfile -t REQUIRED_WIFI_FW < <(
        sed -nE \
            's/.*Direct firmware load for (iwlwifi-[A-Za-z0-9._-]+\.ucode) failed with error -2.*/\1/p' \
            <<<"$DMESG" |
        sort -u
    )
fi


if (( ${#REQUIRED_WIFI_FW[@]} == 0 )); then
    echo "No missing iwlwifi firmware was reported."
else
    echo "Wi-Fi firmware requested by the kernel:"

    for fw in "${REQUIRED_WIFI_FW[@]}"; do
        echo "  $fw"

        #
        # The kernel requests this at:
        #
        #   /usr/lib/firmware/iwlwifi-....ucode
        #
        # while upstream stores it under:
        #
        #   intel/iwlwifi/
        #
        queue_firmware \
            "wifi" \
            "intel/iwlwifi/$fw" \
            "$fw"
    done
fi

echo


# ============================================================
#
#                     BLUETOOTH
#
# ============================================================

echo "============================================================"
echo " Intel Bluetooth"
echo "============================================================"
echo


# ------------------------------------------------------------
# Find missing Intel Bluetooth firmware
# ------------------------------------------------------------

echo "Checking kernel log for missing Intel Bluetooth firmware..."
echo

declare -a REQUIRED_BT_FW=()

#
# Matches failures containing paths such as:
#
#   intel/ibt-0190-0041-usb.sfi
#   intel/ibt-0190-0041-usb.ddc
#
# while restricting the search to failed Bluetooth HCI messages.
#
mapfile -t REQUIRED_BT_FW < <(
    sed -nE '
        /Bluetooth: hci/ {
            /[Ff]ail/ {
                s/.*(intel\/ibt-[A-Za-z0-9._-]+\.(sfi|ddc)).*/\1/p
            }
        }
    ' <<<"$DMESG" |
    sort -u
)


if (( ${#REQUIRED_BT_FW[@]} == 0 )); then
    echo "No missing Intel Bluetooth firmware was reported."
else
    echo "Bluetooth firmware requested by the kernel:"

    for fw in "${REQUIRED_BT_FW[@]}"; do
        echo "  $fw"

        queue_firmware \
            "bluetooth" \
            "$fw" \
            "$fw"

        #
        # Intel Bluetooth commonly uses a matching .ddc file.
        #
        # The driver may not attempt the DDC until the missing
        # USB SFI has loaded successfully, so proactively queue
        # the matching DDC as an OPTIONAL companion.
        #
        if [[ "$fw" == intel/ibt-*-usb.sfi ]]; then
            ddc="${fw%.sfi}.ddc"

            if ! firmware_present "$ddc"; then
                echo "  Companion DDC: $ddc"

                queue_firmware \
                    "bluetooth" \
                    "$ddc" \
                    "$ddc" \
                    1
            fi
        fi
    done
fi

echo


# ============================================================
# Nothing to repair?
# ============================================================

if (( ${#FW_DEST[@]} == 0 )); then
    echo "============================================================"
    echo " Nothing to repair"
    echo "============================================================"
    echo
    echo "No missing Intel Wi-Fi or Bluetooth firmware was detected."
    exit 0
fi


# ============================================================
# Download firmware
# ============================================================

echo "============================================================"
echo " Download"
echo "============================================================"
echo

declare -a STAGED_INDEXES=()

for (( i=0; i<${#FW_DEST[@]}; i++ )); do

    kind="${FW_KIND[$i]}"
    source_rel="${FW_SOURCE[$i]}"
    dest_rel="${FW_DEST[$i]}"
    optional="${FW_OPTIONAL[$i]}"

    tmpfile="$TMPDIR/$dest_rel"
    url="$UPSTREAM_BASE/$source_rel"

    mkdir -p "$(dirname "$tmpfile")"

    echo "Downloading $dest_rel..."
    echo "  $url"

    if ! curl \
        --fail \
        --location \
        --show-error \
        --progress-bar \
        "$url" \
        -o "$tmpfile"
    then
        if [[ "$optional" -eq 1 ]]; then
            echo "Optional companion firmware not available upstream."
            echo "Skipping: $dest_rel"
            echo
            rm -f "$tmpfile"
            continue
        fi

        echo
        echo "ERROR: Could not download:"
        echo "  $url"
        exit 1
    fi


    if [[ ! -s "$tmpfile" ]]; then
        echo "ERROR: Downloaded firmware file is empty:"
        echo "  $dest_rel"
        exit 1
    fi


    if grep -aq -m1 -E '<!DOCTYPE html|<html' "$tmpfile"; then
        echo "ERROR: Download appears to be HTML rather than firmware:"
        echo "  $dest_rel"
        exit 1
    fi


    size="$(stat -c '%s' "$tmpfile")"

    #
    # Intel DDC files can legitimately be extremely small like 4kb!
    # Do not apply the normal firmware size sanity check to them.
    #
    if [[ "$dest_rel" != *.ddc ]] && (( size < 10000 )); then
        echo "ERROR: Downloaded firmware file is suspiciously small:"
        echo "  $dest_rel: $size bytes"
        exit 1
    fi


    echo "Downloaded:"
    ls -lh "$tmpfile"
    file "$tmpfile"
    echo

    STAGED_INDEXES+=("$i")
done


if (( ${#STAGED_INDEXES[@]} == 0 )); then
    echo "No firmware files were downloaded."
    exit 0
fi


# ============================================================
# Make SteamOS writable
# ============================================================

if command -v steamos-readonly >/dev/null 2>&1; then
    echo "Temporarily disabling SteamOS read-only mode..."
    sudo steamos-readonly disable
    READONLY_CHANGED=1
    echo
fi


# ============================================================
# Install firmware
# ============================================================

echo "============================================================"
echo " Install"
echo "============================================================"
echo

for i in "${STAGED_INDEXES[@]}"; do

    kind="${FW_KIND[$i]}"
    dest_rel="${FW_DEST[$i]}"
    tmpfile="$TMPDIR/$dest_rel"

    sudo install \
        -D \
        -o root \
        -g root \
        -m 0644 \
        "$tmpfile" \
        "$FIRMWARE_DIR/$dest_rel"

    echo "Installed: $FIRMWARE_DIR/$dest_rel"

    case "$kind" in
        wifi)
            WIFI_CHANGED=1
            ;;
        bluetooth)
            BT_CHANGED=1
            ;;
    esac
done


# ============================================================
# Restore SteamOS read-only mode
# ============================================================

if [[ "$READONLY_CHANGED" -eq 1 ]]; then
    echo
    echo "Restoring SteamOS read-only mode..."
    sudo steamos-readonly enable
    READONLY_CHANGED=0
fi


# ============================================================
#
#                   WI-FI RELOAD
#
# ============================================================

if [[ "$WIFI_CHANGED" -eq 1 ]]; then

    echo
    echo "============================================================"
    echo " Wi-Fi Reload"
    echo "============================================================"
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
                grep -qE 'state (UP|UNKNOWN)'
            then
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
        echo "Skipping automatic iwlwifi reload to avoid dropping connectivity."
        echo "The new Wi-Fi firmware will load after reboot."

    else

        echo
        echo "No active iwlwifi interfaces detected."
        echo "Reloading iwlwifi..."

        sudo modprobe -r iwlwifi || true
        sudo modprobe iwlwifi

        sleep 3

        echo
        echo "--- iwlwifi firmware messages ---"

        sudo dmesg |
            grep -iE 'iwlwifi.*(firmware|ucode|loaded)' |
            tail -30 ||
            true

        echo
        echo "--- Intel Wi-Fi interfaces ---"

        for bdf in "${IWL_DEVICES[@]}"; do

            netdir="/sys/bus/pci/devices/$bdf/net"

            if [[ -d "$netdir" ]]; then
                find "$netdir" \
                    -mindepth 1 \
                    -maxdepth 1 \
                    -printf '  %f\n'
            fi
        done
    fi
fi


# ============================================================
#
#                 BLUETOOTH STATUS
#
# ============================================================

if [[ "$BT_CHANGED" -eq 1 ]]; then

    echo
    echo "============================================================"
    echo " Bluetooth"
    echo "============================================================"
    echo

    echo "Bluetooth firmware was installed."
    echo
    echo "A reboot is recommended to fully reinitialize the FW."
    echo "It may not work at all until the system is rebooted."

    echo
    echo "Installed Intel Bluetooth firmware:"

    for i in "${STAGED_INDEXES[@]}"; do
        if [[ "${FW_KIND[$i]}" == "bluetooth" ]]; then
            echo "  $FIRMWARE_DIR/${FW_DEST[$i]}"
        fi
    done
fi


# ============================================================
# Final status
# ============================================================

echo
echo "============================================================"
echo " Final Status"
echo "============================================================"
echo

if [[ "$WIFI_CHANGED" -eq 1 ]]; then
    echo "Wi-Fi:      firmware repaired"
else
    echo "Wi-Fi:      no repair needed"
fi

if [[ "$BT_CHANGED" -eq 1 ]]; then
    echo "Bluetooth:  firmware repaired - reboot recommended"
else
    echo "Bluetooth:  no repair needed"
fi

echo

if [[ "$BT_CHANGED" -eq 1 ]]; then
    echo "Reboot with:"
    echo
    echo "  sudo reboot"
else
    echo "Repair complete."
fi
