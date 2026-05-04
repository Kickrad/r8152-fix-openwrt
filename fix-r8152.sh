#!/bin/bash
# =============================================================================
# r8152-fix: Universal fix for Realtek RTL8152/RTL8153 USB Ethernet adapters
# =============================================================================
# 
# These adapters (TP-Link UE300, Anker, Cable Matters, etc.) have a known
# kernel driver bug where they crash with "Tx status -71" (USB protocol error),
# disconnect from the USB bus, and require a physical unplug/replug to recover.
#
# This script:
#   1. Detects affected adapters (RTL8152/RTL8153)
#   2. Disables power saving on the USB device
#   3. Disables TCP offloads (TSO/GRO/GSO/SG) that stress the USB endpoint
#   4. Disables EEE (Energy Efficient Ethernet)
#   5. Installs a watchdog cron job for auto-recovery
#   6. Installs a udev rule for automatic fix on hotplug
#   7. Installs a systemd service for fix on boot (if systemd available)
#
# Usage:
#   sudo bash fix-r8152.sh              # Apply fixes
#   sudo bash fix-r8152.sh --status     # Check if fixes are applied
#   sudo bash fix-r8152.sh --remove     # Remove all fixes
#   sudo bash fix-r8152.sh --watchdog   # Install only the watchdog
#
# Requirements: bash, ethtool, ping, awk
# Works on: Any Linux distribution with kernel 3.x+
#
# License: MIT - https://opensource.org/licenses/MIT
# =============================================================================

set -e

# --- Configuration -----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="/tmp/r8152-fix.log"
WATCHDOG_SCRIPT="${SCRIPT_DIR}/r8152-watchdog.sh"
UDEV_RULE_FILE="/etc/udev/rules.d/99-r8152-fix.rules"
SERVICE_FILE="/etc/systemd/system/r8152-fix.service"
CRON_CMD="${SCRIPT_DIR}/r8152-watchdog.sh"
VENDOR_ID="2357"        # TP-Link
PRODUCT_ID="0601"       # UE300
DRIVER_NAME="r8152"
# Detect real user when run via sudo
REAL_USER="${SUDO_USER:-$(whoami)}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Functions ---------------------------------------------------------------

log() { echo -e "${GREEN}[+]${NC} $*"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" >> "$LOG_FILE"; }
error() { echo -e "${RED}[-]${NC} $*"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >> "$LOG_FILE"; }

# Auto-detect r8152 network interfaces
detect_interfaces() {
    INTERFACES=()
    for iface in /sys/class/net/*; do
        [ -d "$iface" ] || continue
        iface_name=$(basename "$iface")
        # Check if this interface is driven by r8152
        driver=$(ethtool -i "$iface_name" 2>/dev/null | grep "driver:" | awk '{print $2}')
        if [ "$driver" = "$DRIVER_NAME" ]; then
            INTERFACES+=("$iface_name")
        fi
    done
    echo "${#INTERFACES[@]}"
}

# Get USB device path for an r8152 interface
get_usb_devpath() {
    local iface="$1"
    local bus_info
    bus_info=$(ethtool -i "$iface" 2>/dev/null | grep "bus-info:" | awk '{print $2}')
    if [ -z "$bus_info" ]; then
        echo ""
        return
    fi
    # bus_info format: usb-0000:00:14.0-1.4
    # Extract the USB device part after the hyphen: 1.4
    local usb_path="${bus_info#*-}"
    # Find the USB device in sysfs
    local sys_usb
    local pattern="/sys/bus/usb/devices/*${usb_path}"
    for sys_usb in $pattern; do
        [ -d "$sys_usb" ] && echo "$(basename "$sys_usb")" && return
    done 2>/dev/null
    echo ""
}

# Find the hub port path for a USB device
get_hub_port_path() {
    local usb_dev="$1"
    # The device path: /sys/bus/usb/devices/<usb_dev>/
    local dev_path="/sys/bus/usb/devices/${usb_dev}"
    [ -d "$dev_path" ] || { echo ""; return; }
    
    # Get the parent hub (e.g., 2-1 for device 2-1.4)
    local parent="${usb_dev%.*}"
    local port_num="${usb_dev##*.}"
    
    # The hub interface path
    local hub_path="/sys/bus/usb/devices/${parent}/${parent}:1.0"
    [ -d "$hub_path" ] || { echo ""; return; }
    
    # Look for the port directory
    for port_dir in "${hub_path}/${parent}-port"*; do
        [ -d "$port_dir" ] || continue
        local port_name=$(basename "$port_dir")
        # Extract port number from name like "2-1-port4"
        local pnum="${port_name##*-port}"
        if [ "$pnum" = "$port_num" ]; then
            echo "$port_dir"
            return
        fi
    done
    echo ""
}

# Apply fixes to a specific interface
apply_fixes() {
    local iface="$1"
    local applied=0
    
    log "Applying fixes to ${iface}..."
    
    # 1. Disable USB power management
    local usb_dev
    usb_dev=$(get_usb_devpath "$iface")
    if [ -n "$usb_dev" ]; then
        local dev_path="/sys/bus/usb/devices/${usb_dev}"
        if [ -f "${dev_path}/power/control" ]; then
            echo "on" > "${dev_path}/power/control" 2>/dev/null && log "  ✓ USB power control: on" && applied=1
        fi
        if [ -f "${dev_path}/power/autosuspend_delay_ms" ]; then
            echo "0" > "${dev_path}/power/autosuspend_delay_ms" 2>/dev/null && log "  ✓ USB autosuspend: disabled"
        fi
    fi
    
    # 2. Disable TCP offloads (main fix for Tx status -71)
    for offload in tso gso gro sg rx-vlan-offload tx-vlan-offload rx-checksum tx-checksum-ipv4 tx-checksum-ipv6; do
        if ethtool -K "${iface}" "${offload}" off 2>/dev/null; then
            log "  ✓ ${offload}: disabled"
            applied=1
        fi
    done
    
    # 3. Disable EEE (Energy Efficient Ethernet)
    if ethtool --set-eee "${iface}" eee off 2>/dev/null; then
        log "  ✓ EEE: disabled"
    fi
    
    # 4. Install kernel USB quirk to force USB 2.0 on next boot (prevents RTL8153 USB 3.0 bug)
    install_usb_quirk
    
    log "Fixes applied to ${iface}"
    return 0
}

# Check if fixes are applied on an interface
check_fixes() {
    local iface="$1"
    local issues=0
    
    echo ""
    echo "--- ${iface} ---"
    
    # Check USB power
    local usb_dev
    usb_dev=$(get_usb_devpath "$iface")
    if [ -n "$usb_dev" ]; then
        local ctrl=$(cat "/sys/bus/usb/devices/${usb_dev}/power/control" 2>/dev/null)
        echo "  USB power control: ${ctrl:-unknown}"
        [ "$ctrl" != "on" ] && issues=1
    fi
    
    # Check offloads
    for offload in tcp-segmentation-offload generic-segmentation-offload generic-receive-offload scatter-gather rx-vlan-offload tx-vlan-offload tx-checksum-ipv4 tx-checksum-ipv6; do
        local state
        state=$(ethtool -k "${iface}" 2>/dev/null | grep "${offload}:" | awk '{print $2}')
        echo "  ${offload}: ${state:-unknown}"
        [ "$state" = "on" ] && issues=1
    done
    # rx-checksumming has different naming in ethtool output
    local rx_csum
    rx_csum=$(ethtool -k "${iface}" 2>/dev/null | grep "rx-checksumming:" | awk '{print $2}')
    echo "  rx-checksumming: ${rx_csum:-unknown}"
    [ "$rx_csum" = "on" ] && issues=1
    
    # Check EEE
    local eee_state
    eee_state=$(ethtool --show-eee "${iface}" 2>/dev/null | grep "EEE status:" | awk '{print $3}')
    echo "  EEE: ${eee_state:-unknown}"
    
    # Check recent errors
    local errors
    errors=$(journalctl -k --since "1 hour ago" 2>/dev/null | grep -c "r8152.*Tx status\|r8152.*Stop submitting\|r8152.*timed out" 2>/dev/null || true)
    errors=${errors:-0}
    if [ "$errors" -gt 0 ]; then
        echo -e "  ${RED}Recent Tx errors: ${errors}${NC}"
        issues=1
    else
        echo "  Recent Tx errors: 0 ✓"
    fi
    
    return $issues
}

# Add usbcore.quirks to force USB 2.0 mode (RTL8153 USB 3.0 is buggy)
install_usb_quirk() {
    local quirk="2357:0601:b"
    local grub_file="/etc/default/grub"
    
    # Try via sysfs first (runtime, only affects next re-enumeration)
    if [ -w "/sys/module/usbcore/parameters/quirks" ]; then
        local current
        current=$(cat /sys/module/usbcore/parameters/quirks 2>/dev/null)
        if echo "$current" | grep -q "2357:0601"; then
            log "  ✓ USB 2.0 quirk already set via sysfs"
        else
            local new_quirks="${current:+${current},}${quirk}"
            echo "$new_quirks" > /sys/module/usbcore/parameters/quirks 2>/dev/null && log "  ✓ USB 2.0 quirk set at runtime" || warn "  Could not set USB 2.0 quirk via sysfs"
        fi
    fi
    
    # Make it permanent via GRUB for next boot
    if [ -f "$grub_file" ] && command -v update-grub >/dev/null 2>&1; then
        local current_grub
        current_grub=$(grep "GRUB_CMDLINE_LINUX_DEFAULT" "$grub_file" 2>/dev/null | head -1)
        if echo "$current_grub" | grep -q "usbcore.quirks=.*2357:0601"; then
            log "  ✓ USB 2.0 quirk already in GRUB"
        else
            # Check if usbcore.quirks already exists
            if echo "$current_grub" | grep -q "usbcore.quirks="; then
                # Append to existing quirk string
                sed -i "s|usbcore.quirks=\([^\"]*\)|usbcore.quirks=\1,${quirk}|" "$grub_file"
            else
                # Add new quirk parameter inside the quotes
                sed -i 's|GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"|GRUB_CMDLINE_LINUX_DEFAULT="\1 usbcore.quirks=2357:0601:b"|' "$grub_file"
            fi
        fi
    fi
    # Note: run "sudo update-grub" after to apply
}

# Install udev rule
install_udev_rule() {
    log "Installing udev rule..."
    
    cat > "$UDEV_RULE_FILE" << 'EOF'
# r8152-fix: Disable power saving and offloads for Realtek RTL8152/RTL8153
# This prevents "Tx status -71" crashes that cause USB disconnection
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="2357", ATTR{idProduct}=="0601", ATTR{power/control}="on", ATTR{power/autosuspend_delay_ms}="0"
ACTION=="add", SUBSYSTEM=="net", KERNEL=="enx*", ATTR{power/control}="on"
EOF
    
    # Also add a systemd-triggering rule for the fix service
    # This is more portable and doesnt block udev
    cat > "/etc/udev/rules.d/99-r8152-trigger.rules" << 'EOF'
# Trigger r8152-fix service when r8152 network interface appears
ACTION=="add", SUBSYSTEM=="net", KERNEL=="enx*", TAG+="systemd", ENV{SYSTEMD_WANTS}="r8152-fix.service"
EOF
    
    udevadm control --reload-rules 2>/dev/null && log "  ✓ udev rules installed and reloaded" || warn "  Could not reload udev rules"
}

# Install systemd service
install_systemd_service() {
    if ! command -v systemctl >/dev/null 2>&1; then
        warn "systemd not available, skipping service installation"
        return 1
    fi
    
    log "Installing systemd service..."
    
    cat > "$SERVICE_FILE" << 'SERVICE'
[Unit]
Description=r8152-fix: Disable USB power saving and offloads for RTL8152/8153
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=/bin/sh -c 'for i in 1 2 3 4 5; do for d in /sys/class/net/enx*; do [ -d "$d" ] && ethtool -i "$(basename "$d")" 2>/dev/null | grep -q "driver: r8152" && exit 0; done; sleep 2; done'
ExecStart=/bin/sh -c '\
    for d in /sys/class/net/enx*; do \
        [ -d "$d" ] || continue; \
        iface=$(basename "$d"); \
        driver=$(ethtool -i "$iface" 2>/dev/null | grep "driver:" | awk "{print \$2}"); \
        [ "$driver" = "r8152" ] || continue; \
        echo "Applying fixes to $iface..."; \
        ethtool -K "$iface" tso off 2>/dev/null || true; \
        ethtool -K "$iface" gso off 2>/dev/null || true; \
        ethtool -K "$iface" gro off 2>/dev/null || true; \
        ethtool -K "$iface" sg off 2>/dev/null || true; \
        ethtool -K "$iface" rx-vlan-offload off 2>/dev/null || true; \
        ethtool -K "$iface" tx-vlan-offload off 2>/dev/null || true; \
        ethtool -K "$iface" rx-checksum off 2>/dev/null || true; \
        ethtool -K "$iface" tx-checksum-ipv4 off 2>/dev/null || true; \
        ethtool -K "$iface" tx-checksum-ipv6 off 2>/dev/null || true; \
        ethtool --set-eee "$iface" eee off 2>/dev/null || true; \
        bus=$(ethtool -i "$iface" 2>/dev/null | grep "bus-info:" | awk "{print \$2}"); \
        usb_path="/sys/bus/usb/devices/*${bus#*-}"; \
        for p in $usb_path; do \
            [ -d "$p" ] || continue; \
            echo on > "$p/power/control" 2>/dev/null || true; \
            echo 0 > "$p/power/autosuspend_delay_ms" 2>/dev/null || true; \
        done; \
    done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE
    
    systemctl daemon-reload 2>/dev/null
    systemctl enable r8152-fix.service 2>/dev/null
    systemctl start r8152-fix.service 2>/dev/null && log "  ✓ systemd service started" || warn "  systemd service failed to start (will retry on boot)"
}

# Create the watchdog script
create_watchdog() {
    log "Creating watchdog script..."
    
    cat > "$WATCHDOG_SCRIPT" << 'WATCHDOG'
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
WATCHDOG
    
    chmod 755 "$WATCHDOG_SCRIPT"
    log "  ✓ Watchdog script created at ${WATCHDOG_SCRIPT}"
}

# Install cron job
install_cron() {
    log "Installing watchdog cron job..."
    
    local cron_cmd="sudo ${CRON_CMD} > /dev/null 2>&1"
    local cron_line="* * * * * ${cron_cmd}  # r8152-fix watchdog"
    
    # Remove any existing r8152-fix cron entries and add the new one
    (crontab -u "${REAL_USER}" -l 2>/dev/null | grep -v "r8152-fix\|r8152-watchdog"; echo "$cron_line") | crontab -u "${REAL_USER}" - 2>/dev/null && log "  ✓ Cron job installed (every 1 minute)" || warn "  Could not install cron job"
}

# Remove all changes
remove_all() {
    log "Removing all r8152-fix changes..."
    
    # Remove cron job
    crontab -u "${REAL_USER}" -l 2>/dev/null | grep -v "r8152-fix\|r8152-watchdog" | crontab -u "${REAL_USER}" - 2>/dev/null && log "  ✓ Cron job removed"
    
    # Remove udev rules
    rm -f "$UDEV_RULE_FILE" "/etc/udev/rules.d/99-r8152-trigger.rules" 2>/dev/null
    udevadm control --reload-rules 2>/dev/null && log "  ✓ Udev rules removed"
    
    # Remove systemd service
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop r8152-fix.service 2>/dev/null || true
        systemctl disable r8152-fix.service 2>/dev/null || true
        rm -f "$SERVICE_FILE" 2>/dev/null
        systemctl daemon-reload 2>/dev/null && log "  ✓ Systemd service removed"
    fi
    
    # Remove watchdog script
    rm -f "$WATCHDOG_SCRIPT" 2>/dev/null && log "  ✓ Watchdog script removed"
    
    log "All changes removed."
}

# Show status
show_status() {
    echo ""
    echo "=== r8152-fix Status ==="
    echo ""
    
    local ifaces
    ifaces=$(detect_interfaces)
    
    if [ "$ifaces" -eq 0 ]; then
        echo "No r8152 interfaces found."
    else
        for iface in /sys/class/net/*; do
            [ -d "$iface" ] || continue
            name=$(basename "$iface")
            driver=$(ethtool -i "$name" 2>/dev/null | grep "driver:" | awk '{print $2}')
            [ "$driver" = "$DRIVER_NAME" ] || continue
            check_fixes "$name"
        done
    fi
    
    echo ""
    echo "=== Installed Components ==="
    echo -n "  Udev rule: "; [ -f "$UDEV_RULE_FILE" ] && echo "✓" || echo "✗"
    echo -n "  Systemd service: "; [ -f "$SERVICE_FILE" ] && echo "✓" || echo "✗"
    echo -n "  Watchdog script: "; [ -f "$WATCHDOG_SCRIPT" ] && echo "✓" || echo "✗"
    echo -n "  Cron job: "; crontab -u "${REAL_USER}" -l 2>/dev/null | grep -q "r8152-watchdog" && echo "✓" || echo "✗"
    
    echo ""
    echo "=== Watchdog Log (last 20 lines) ==="
    tail -20 /tmp/r8152-watchdog.log 2>/dev/null || echo "  (no log yet)"
}

# --- Main --------------------------------------------------------------------

case "${1:-install}" in
    install|--install)
        log "=== Installing r8152-fix ==="
        
        # Apply fixes to current interfaces
        NUM=$(detect_interfaces)
        if [ "$NUM" -eq 0 ]; then
            warn "No r8152 interfaces detected. Plug in your adapter and run again."
        else
            for iface in /sys/class/net/*; do
                [ -d "$iface" ] || continue
                name=$(basename "$iface")
                driver=$(ethtool -i "$name" 2>/dev/null | grep "driver:" | awk '{print $2}')
                [ "$driver" = "$DRIVER_NAME" ] || continue
                apply_fixes "$name"
            done
        fi
        
        # Create and install all components
        create_watchdog
        install_udev_rule
        install_systemd_service
        install_cron
        
        log ""
        log "=== Installation Complete ==="
        log "The fixes are now active. The watchdog will auto-recover"
        log "from Tx errors within 2 minutes without unplugging."
        log ""
        log "To check status: ${0##*/} --status"
        log "To remove:       ${0##*/} --remove"
        log "Log file:        ${LOG_FILE}"
        log "Watchdog log:    /tmp/r8152-watchdog.log"
        ;;
    
    status|--status)
        show_status
        ;;
    
    remove|--remove)
        remove_all
        ;;
    
    watchdog|--watchdog)
        create_watchdog
        install_cron
        log "Watchdog installed."
        ;;
    
    apply|--apply)
        NUM=$(detect_interfaces)
        if [ "$NUM" -eq 0 ]; then
            error "No r8152 interfaces detected."
            exit 1
        fi
        for iface in /sys/class/net/*; do
            [ -d "$iface" ] || continue
            name=$(basename "$iface")
            driver=$(ethtool -i "$name" 2>/dev/null | grep "driver:" | awk '{print $2}')
            [ "$driver" = "$DRIVER_NAME" ] || continue
            apply_fixes "$name"
        done
        ;;
    
    *)
        echo "Usage: $0 {install|status|remove|apply|watchdog}"
        echo ""
        echo "  install   Apply fixes + install all components (default)"
        echo "  status    Check current status"
        echo "  remove    Remove all changes"
        echo "  apply     Apply fixes to current interfaces only"
        echo "  watchdog  Install only the watchdog cron job"
        exit 1
        ;;
esac

exit 0
