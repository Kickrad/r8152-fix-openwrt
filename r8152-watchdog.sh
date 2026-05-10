#!/bin/bash
# r8152-watchdog v2: Auto-recovery for RTL8153 USB Ethernet lockups
#
# Strategy (rewritten 2026-05-10):
#   1. Detect Tx status -71 errors in kernel log
#   2. USB device DEAUTHORIZE/REAUTHORIZE (full power cycle = virtual unplug)
#   3. Falls back to hub port disable/enable if authorized fails
#   4. Re-applies offload fixes after recovery
#
# Why v2 works when v1 didn't:
#   v1 = driver unbind/bind → only resets driver, chip stays stuck
#   v2 = authorized=0/1     → full USB reset, chip re-enumerates clean
#   This is the software equivalent of physically unplugging/replugging

LOG_FILE="/tmp/r8152-watchdog.log"
LOCK_FILE="/tmp/r8152-watchdog.lock"
RESTART_MARKER="/tmp/r8152-watchdog-last-restart"
DRIVER="r8152"
VENDOR="2357"
PRODUCT="0601"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

reapply_fixes() {
    local iface="$1"
    ethtool -K "$iface" tso off gso off gro off sg off rx-vlan-offload off tx-vlan-offload off rx-checksum off tx-checksum-ipv4 off tx-checksum-ipv6 off 2>/dev/null || true
    ethtool --set-eee "$iface" eee off 2>/dev/null || true
}

find_ue300_device() {
    for dev in /sys/bus/usb/devices/*; do
        [ -d "$dev" ] || continue
        local vid=$(cat "$dev/idVendor" 2>/dev/null)
        local pid=$(cat "$dev/idProduct" 2>/dev/null)
        [ "$vid" = "$VENDOR" ] && [ "$pid" = "$PRODUCT" ] && basename "$dev" && return 0
    done
    return 1
}

usb_full_reset() {
    local usb_dev="$1"
    local auth_file="/sys/bus/usb/devices/${usb_dev}/authorized"
    if [ ! -f "$auth_file" ]; then
        log "ERROR: No authorized file at ${auth_file}"
        return 1
    fi
    log "  USB reset: deauthorizing ${usb_dev}..."
    echo 0 > "$auth_file" 2>/dev/null || { log "  ERROR: Failed to deauthorize"; return 1; }
    sleep 2
    log "  USB reset: reauthorizing ${usb_dev}..."
    echo 1 > "$auth_file" 2>/dev/null || { log "  ERROR: Failed to reauthorize"; return 1; }
    sleep 3
    return 0
}

hub_port_reset() {
    local usb_dev="$1"
    local parent="${usb_dev%.*}"
    local port_num="${usb_dev##*.}"
    local disable_file="/sys/bus/usb/devices/${parent}/${parent}:1.0/${parent}-port${port_num}/disable"
    if [ -f "$disable_file" ]; then
        log "  Hub port reset: disabling port ${port_num}..."
        echo 1 > "$disable_file" 2>/dev/null || { log "  ERROR: Failed to disable port"; return 1; }
        sleep 2
        log "  Hub port reset: re-enabling port ${port_num}..."
        echo 0 > "$disable_file" 2>/dev/null || { log "  ERROR: Failed to re-enable port"; return 1; }
        sleep 4
        return 0
    fi
    log "  ERROR: No disable file"
    return 1
}

recover_device() {
    local usb_dev="$1"
    log "=== RECOVERY START for ${usb_dev} ==="

    # Method 1: Full USB authorized reset
    if usb_full_reset "$usb_dev"; then
        sleep 3
        for iface in /sys/class/net/enx*; do
            [ -d "$iface" ] || continue
            local name=$(basename "$iface")
            local driver=$(ethtool -i "$name" 2>/dev/null | grep "driver:" | awk '{print $2}')
            if [ "$driver" = "$DRIVER" ]; then
                log "  ✓ Interface ${name} recovered via USB reset"
                reapply_fixes "$name"
                touch "$RESTART_MARKER"
                log "=== RECOVERY OK ==="
                return 0
            fi
        done
        sleep 4
    fi

    # Check if already back
    for iface in /sys/class/net/enx*; do
        [ -d "$iface" ] || continue
        local driver=$(ethtool -i "$(basename "$iface")" 2>/dev/null | grep "driver:" | awk '{print $2}')
        if [ "$driver" = "$DRIVER" ]; then
            log "  ✓ Interface already back"
            reapply_fixes "$(basename "$iface")"
            touch "$RESTART_MARKER"
            log "=== RECOVERY OK ==="
            return 0
        fi
    done

    # Method 2: Hub port power cycle
    log "  Trying hub port reset..."
    if hub_port_reset "$usb_dev"; then
        sleep 5
        for iface in /sys/class/net/enx*; do
            [ -d "$iface" ] || continue
            local name=$(basename "$iface")
            local driver=$(ethtool -i "$name" 2>/dev/null | grep "driver:" | awk '{print $2}')
            if [ "$driver" = "$DRIVER" ]; then
                log "  ✓ Interface ${name} recovered via port reset"
                reapply_fixes "$name"
                touch "$RESTART_MARKER"
                log "=== RECOVERY OK ==="
                return 0
            fi
        done
    fi

    log "  ✗ ALL recovery methods failed. Manual unplug needed."
    log "=== RECOVERY FAILED ==="
    return 1
}

# --- Main ---

[ -f "$LOCK_FILE" ] && [ "$(($(date +%s) - $(stat -c %Y "$LOCK_FILE")))" -lt 120 ] && exit 0
touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

ERRORS=$(journalctl -k --since "2 minutes ago" 2>/dev/null | grep -c "r8152.*Tx status -71" 2>/dev/null || echo 0)
ERRORS=${ERRORS:-0}

USB_DEV=$(find_ue300_device)
HAS_IFACE=false
for iface in /sys/class/net/enx*; do
    [ -d "$iface" ] || continue
    driver=$(ethtool -i "$(basename "$iface")" 2>/dev/null | grep "driver:" | awk '{print $2}')
    [ "$driver" = "$DRIVER" ] && HAS_IFACE=true
done

if [ "$ERRORS" -gt 5 ]; then
    log "ALERT: ${ERRORS} Tx errors in last 2 min"
    if [ -f "$RESTART_MARKER" ] && [ "$(($(date +%s) - $(stat -c %Y "$RESTART_MARKER")))" -lt 45 ]; then
        log "  Cooldown — skipping (last restart < 45s ago)"
        exit 0
    fi
    if [ -n "$USB_DEV" ]; then
        recover_device "$USB_DEV"
    else
        log "ERROR: UE300 not on USB bus — waiting for physical reconnect"
    fi
elif [ "$HAS_IFACE" = false ] && [ -n "$USB_DEV" ]; then
    log "ALERT: UE300 on bus but no interface — recovering"
    recover_device "$USB_DEV"
fi

exit 0
