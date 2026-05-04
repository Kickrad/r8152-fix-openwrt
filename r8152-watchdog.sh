#!/bin/bash
# r8152-watchdog: Auto-recovery for RTL8152/RTL8153 USB Ethernet
# Detects Tx errors and recovers without unplugging
# Minimal resource usage - just bash + basic tools
#
# Recovery strategy (in order):
#   1. Driver unbind/bind - safe, resets only the network driver
#   2. Hub port power cycle - forces USB re-enumeration
#
# Logs to /tmp/r8152-watchdog.log

LOG_FILE="/tmp/r8152-watchdog.log"
RESTART_MARKER="/tmp/r8152-watchdog-last-restart"
DRIVER="r8152"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

# Find all r8152 interfaces
find_r8152_ifaces() {
    for iface in /sys/class/net/*; do
        [ -d "$iface" ] || continue
        name=$(basename "$iface")
        driver=$(ethtool -i "$name" 2>/dev/null | grep "driver:" | awk '{print $2}')
        [ "$driver" = "$DRIVER" ] && echo "$name"
    done
}

# Get USB device path from interface bus-info
get_usb_dev() {
    local iface="$1"
    local bus
    bus=$(ethtool -i "$iface" 2>/dev/null | grep "bus-info:" | awk '{print $2}')
    [ -z "$bus" ] && return 1
    local usb_part="${bus#*-}"
    local pattern="/sys/bus/usb/devices/*${usb_part}"
    for dev in $pattern; do
        [ -d "$dev" ] && basename "$dev" && return 0
    done 2>/dev/null
    return 1
}

# Get hub port path for power cycling
get_port_path() {
    local usb_dev="$1"
    local parent="${usb_dev%.*}"
    local port_num="${usb_dev##*.}"
    local hub_path="/sys/bus/usb/devices/${parent}/${parent}:1.0"
    [ -d "$hub_path" ] || return 1
    for port_dir in "${hub_path}/${parent}-port"*; do
        [ -d "$port_dir" ] || continue
        local pnum="${port_dir##*-port}"
        [ "$pnum" = "$port_num" ] && echo "$port_dir" && return 0
    done
    return 1
}

# Re-apply fixes after recovery
reapply_fixes() {
    local iface="$1"
    ethtool -K "$iface" tso off 2>/dev/null || true
    ethtool -K "$iface" gso off 2>/dev/null || true
    ethtool -K "$iface" gro off 2>/dev/null || true
    ethtool -K "$iface" sg off
    ethtool -K "$iface" rx-vlan-offload off
    ethtool -K "$iface" tx-vlan-offload off
    ethtool -K "$iface" rx-checksum off
    ethtool --set-eee "$iface" eee off 2>/dev/null || true
    local usb_dev
    usb_dev=$(get_usb_dev "$iface") || true
    if [ -n "$usb_dev" ]; then
        local dev_path="/sys/bus/usb/devices/${usb_dev}"
        echo "on" > "${dev_path}/power/control" 2>/dev/null || true
        echo "0" > "${dev_path}/power/autosuspend_delay_ms" 2>/dev/null || true
    fi
}

# Check and fix one interface
check_interface() {
    local iface="$1"
    local interface_missing=0

    # If no interface name provided, scan for TP-Link UE300 on USB bus
    if [ -z "$iface" ]; then
        # Look for the device on USB bus that might need driver binding
        for dev in /sys/bus/usb/devices/*; do
            [ -d "$dev" ] || continue
            local vid=$(cat "$dev/idVendor" 2>/dev/null)
            local pid=$(cat "$dev/idProduct" 2>/dev/null)
            [ "$vid" = "2357" ] && [ "$pid" = "0601" ] || continue
            local devname=$(basename "$dev")
            # Check if driver is bound
            if [ ! -L "/sys/bus/usb/drivers/${DRIVER}/${devname}:1.0" ]; then
                log "Found TP-Link UE300 at ${devname} - binding driver..."
                echo "${devname}:1.0" > "/sys/bus/usb/drivers/${DRIVER}/bind" 2>/dev/null || true
            fi
        done
        return 0
    fi

    # Check if interface exists
    if [ ! -d "/sys/class/net/${iface}" ]; then
        log "Interface ${iface} is MISSING"
        interface_missing=1
    fi

    if [ "$interface_missing" -eq 1 ]; then
        # Try to find the USB device and bind the driver
        for dev in /sys/bus/usb/devices/*; do
            [ -d "$dev" ] || continue
            local vid=$(cat "$dev/idVendor" 2>/dev/null)
            local pid=$(cat "$dev/idProduct" 2>/dev/null)
            [ "$vid" = "2357" ] && [ "$pid" = "0601" ] || continue
            local devname=$(basename "$dev")
            log "Found TP-Link UE300 at ${devname}"
            if [ ! -L "/sys/bus/usb/drivers/${DRIVER}/${devname}:1.0" ]; then
                log "Binding r8152 driver to ${devname}:1.0..."
                echo "${devname}:1.0" > "/sys/bus/usb/drivers/${DRIVER}/bind" 2>/dev/null && log "Driver bound" || log "Bind failed"
            fi
            sleep 3
            if [ -d "/sys/class/net/${iface}" ]; then
                log "Interface recovered after driver bind!"
                reapply_fixes "$iface"
                return 0
            fi
        done
        log "Could not find TP-Link UE300 on USB bus. May need physical replug."
        return 0
    fi

    # Check for recent Tx errors - count them
    local errors
    errors=$(journalctl -k --since "2 minutes ago" 2>/dev/null | grep -c "r8152.*Tx status -71\|r8152.*Stop submitting" 2>/dev/null)
    case "$errors" in
        ''|*[!0-9]*) errors=0 ;;
    esac

    if [ "$errors" -gt 5 ] 2>/dev/null; then
        log "CRITICAL: ${errors} Tx errors detected on ${iface} in last 3 minutes"

        # Prevent infinite restart loops
        if [ -f "$RESTART_MARKER" ] && [ "$(($(date +%s) - $(stat -c %Y "$RESTART_MARKER" 2>/dev/null)))" -lt 120 ] 2>/dev/null; then
            log "Skipping - last restart was less than 2 minutes ago"
            return 0
        fi

        # Step 1: Try driver unbind/bind (safe, only affects this driver)
        local usb_dev
        usb_dev=$(get_usb_dev "$iface") || true
        if [ -n "$usb_dev" ] && [ -d "/sys/bus/usb/devices/${usb_dev}" ]; then
            local dev_interface="${usb_dev}:1.0"
            log "Recovery step 1: unbind/rebind ${DRIVER} for ${dev_interface}"
            echo "${dev_interface}" > "/sys/bus/usb/drivers/${DRIVER}/unbind" 2>/dev/null && log "Driver unbound"
            sleep 1
            echo "${dev_interface}" > "/sys/bus/usb/drivers/${DRIVER}/bind" 2>/dev/null && log "Driver rebound"
            sleep 3
        fi

        # Check if interface came back
        if [ -d "/sys/class/net/${iface}" ]; then
            log "Interface recovered after driver rebind!"
            reapply_fixes "$iface"
            touch "$RESTART_MARKER"
            return 0
        fi

        # Step 2: Try hub port power cycle
        if [ -n "$usb_dev" ]; then
            local port_path
            port_path=$(get_port_path "$usb_dev") || true
            if [ -n "$port_path" ] && [ -f "${port_path}/disable" ]; then
                log "Recovery step 2: power-cycling hub port ${port_path}"
                echo 1 > "${port_path}/disable" 2>/dev/null && log "Port disabled"
                sleep 2
                echo 0 > "${port_path}/disable" 2>/dev/null && log "Port re-enabled"
                sleep 4
            fi
        fi

        # Final check
        if [ -d "/sys/class/net/${iface}" ]; then
            log "Interface recovered after port power cycle!"
            reapply_fixes "$iface"
            touch "$RESTART_MARKER"
        else
            log "Interface did NOT recover. Manual unplug/replug needed."
        fi
    fi

    # Check if interface is down (no carrier)
    local carrier
    carrier=$(cat "/sys/class/net/${iface}/carrier" 2>/dev/null)
    case "$carrier" in
        ''|*[!0-9]*) carrier=0 ;;
    esac
    local operstate
    operstate=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")

    if [ "${carrier:-0}" -eq 0 ] || [ "$operstate" = "down" ]; then
        log "Interface ${iface} is DOWN (carrier=${carrier:-0}, state=${operstate:-unknown})"
        ip link set "${iface}" up 2>/dev/null || true
    fi
}

# --- Main --------------------------------------------------------------------

IFACES=$(find_r8152_ifaces)

if [ -z "$IFACES" ]; then
    log "No r8152 interfaces found. Checking USB bus for TP-Link UE300..."
    check_interface ""
    exit 0
fi

for iface in $IFACES; do
    check_interface "$iface"
done

exit 0
