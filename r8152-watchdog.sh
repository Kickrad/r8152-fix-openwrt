#!/bin/bash
# r8152-watchdog: Auto-recovery for RTL8152/RTL8153 USB Ethernet
# Detects Tx errors and recovers without unplugging
# Designed for minimal resource usage (bash + basic tools)
#
# Recovery strategy:
#   1. Driver unbind/bind (safe, resets only the network driver)
#   2. Hub port power cycle (if device disconnected from USB bus)
#   3. Logs all events for debugging

LOG_FILE="/tmp/r8152-watchdog.log"
LOCK_FILE="/tmp/r8152-watchdog.lock"
RESTART_MARKER="/tmp/r8152-watchdog-last-restart"
DRIVER="r8152"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
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

# Get the USB device path from an interface
get_usb_dev() {
    local iface="$1"
    local bus
    bus=$(ethtool -i "$iface" 2>/dev/null | grep "bus-info:" | awk '{print $2}')
    [ -z "$bus" ] && return 1
    local usb_part="${bus#*-}"
    for dev in /sys/bus/usb/devices/*"${usb_part}"; do
        [ -d "$dev" ] 2>/dev/null && basename "$dev" && return 0
    done 2>/dev/null
    return 1
}

# Get the hub port path for a USB device
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
    ethtool -K "$iface" sg off 2>/dev/null || true
    ethtool -K "$iface" rx-vlan-offload off 2>/dev/null || true
    ethtool -K "$iface" tx-vlan-offload off 2>/dev/null || true
    ethtool -K "$iface" rx-checksum off 2>/dev/null || true
    ethtool -K "$iface" tx-checksum-ipv4 off 2>/dev/null || true
    ethtool -K "$iface" tx-checksum-ipv6 off 2>/dev/null || true
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
    local changed=0
    
    # Check if interface exists
    if [ ! -d "/sys/class/net/${iface}" ]; then
        log "Interface ${iface} is MISSING"
        
        # Find USB device by checking all devices with the right vendor/product
        for dev in /sys/bus/usb/devices/*; do
            [ -d "$dev" ] || continue
            local vid=$(cat "$dev/idVendor" 2>/dev/null)
            local pid=$(cat "$dev/idProduct" 2>/dev/null)
            [ "$vid" = "2357" ] && [ "$pid" = "0601" ] || continue
            
            local devname=$(basename "$dev")
            log "Found TP-Link UE300 at ${devname} - checking driver..."
            
            # Try to bind the driver if not already bound
            if [ ! -d "${dev}/${devname}:1.0" ] || [ ! -L "/sys/bus/usb/drivers/${DRIVER}/${devname}:1.0" ]; then
                log "Binding driver to ${devname}..."
                echo "${devname}:1.0" > "/sys/bus/usb/drivers/${DRIVER}/bind" 2>/dev/null || true
                changed=1
            fi
        done
        
        if [ "$changed" -eq 0 ]; then
            log "No TP-Link UE300 found on USB bus. Waiting for reconnection..."
        fi
        return 0
    fi
    
    # Check for recent Tx errors (also check if interface can actually transmit)
    local errors
    errors=$(journalctl -k --since "2 minutes ago" 2>/dev/null | grep -c "r8152.*Tx status -71\|r8152.*Stop submitting\|r8152.*timed out" 2>/dev/null || true)
    errors=${errors:-0}
    
    if [ "$errors" -gt 5 ]; then
        log "CRITICAL: ${errors} Tx errors detected on ${iface} in last 3 minutes"
        
        # Check if we recently restarted to avoid infinite loops
        if [ -f "$RESTART_MARKER" ] && [ "$(($(date +%s) - $(stat -c %Y "$RESTART_MARKER")))" -lt 60 ]; then
            log "  Skipping - last restart was less than 1 minute ago"
            return 0
        fi
        
        # Step 1: Try driver unbind/bind (safe, only affects this driver)
        local usb_dev
        usb_dev=$(get_usb_dev "$iface") || true
        if [ -n "$usb_dev" ] && [ -d "/sys/bus/usb/devices/${usb_dev}" ]; then
            local dev_interface="${usb_dev}:1.0"
            log "Recovery step 1: Unbinding/rebinding ${DRIVER} driver for ${dev_interface}..."
            echo "${dev_interface}" > "/sys/bus/usb/drivers/${DRIVER}/unbind" 2>/dev/null && log "  Driver unbound"
            sleep 1
            echo "${dev_interface}" > "/sys/bus/usb/drivers/${DRIVER}/bind" 2>/dev/null && log "  Driver rebound"
            sleep 3
        fi
        
        # Step 2: If interface still missing, try hub port reset
        if [ ! -d "/sys/class/net/${iface}" ]; then
            log "Recovery step 2: Interface still missing after driver rebind"
            if [ -n "$usb_dev" ]; then
                local port_path
                port_path=$(get_port_path "$usb_dev") || true
                if [ -n "$port_path" ] && [ -f "${port_path}/disable" ]; then
                    log "  Power-cycling hub port..."
                    echo 1 > "${port_path}/disable" 2>/dev/null && log "  Port disabled"
                    sleep 2
                    echo 0 > "${port_path}/disable" 2>/dev/null && log "  Port re-enabled"
                    sleep 4
                fi
            fi
        fi
        
        # Wait for interface to come back
        sleep 2
        if [ -d "/sys/class/net/${iface}" ]; then
            log "✓ Interface recovered!"
            reapply_fixes "$iface"
            log "  Fixes re-applied"
            touch "$RESTART_MARKER"
        else
            log "✗ Interface did NOT recover. Manual unplug/replug needed."
            # Try to bring it up via NetworkManager
            nmcli device connect "$iface" 2>/dev/null || true
        fi
    fi
    
    # Also check if the interface is down (no carrier)
    local carrier
    carrier=$(cat "/sys/class/net/${iface}/carrier" 2>/dev/null || echo 0)
    local operstate
    operstate=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")
    
    if [ "$carrier" -eq 0 ] || [ "$operstate" = "down" ]; then
        log "Interface ${iface} is DOWN (carrier=${carrier}, state=${operstate})"
        # Try to bring it up
        ip link set "${iface}" up 2>/dev/null || true
    fi
}

# --- Main --------------------------------------------------------------------

# Prevent concurrent runs (cron may overlap)
if [ -f "$LOCK_FILE" ] && [ "$(($(date +%s) - $(stat -c %Y "$LOCK_FILE")))" -lt 300 ]; then
    exit 0
fi
touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# Find all r8152 interfaces
IFACES=$(find_r8152_ifaces)

if [ -z "$IFACES" ]; then
    # No interfaces found - but we should still check if a TP-Link UE300 is on the bus
    log "No r8152 interfaces currently active, checking USB bus..."
    check_interface ""
    exit 0
fi

for iface in $IFACES; do
    check_interface "$iface"
done

exit 0
