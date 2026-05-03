# r8152-fix

**Fix for Realtek RTL8152/RTL8153 USB Ethernet "Tx status -71" crashes on Linux**

These adapters (TP-Link UE300, Anker, Cable Matters, D-Link, and many others) have a known kernel driver bug where they randomly crash with `Tx status -71` (USB protocol error), disconnect from the USB bus, and require a physical unplug/replug to recover.

**This affects Linux users globally** — the RTL8153 chip is used in hundreds of USB Ethernet adapter brands.

## Quick Fix

```bash
sudo bash -c "$(curl -s https://raw.githubusercontent.com/OpenRoyleAl/r8152-fix/main/fix-r8152.sh)"
```

Or download and run:

```bash
git clone https://github.com/OpenRoyleAl/r8152-fix.git
cd r8152-fix
sudo bash fix-r8152.sh
```

## What it does

1. **Disables problematic TCP offloads** (TSO, GSO, GRO, SG) — these stress the USB endpoint and trigger the crash
2. **Disables EEE** (Energy Efficient Ethernet) — known to cause link instability on this chip
3. **Disables USB power saving** — prevents the USB controller from putting the device to sleep
4. **Installs a watchdog** (cron, every 2min) that auto-recovers without unplugging:
   - Detects Tx errors early → driver unbind/bind (safe restart, ~5s recovery)
   - If device disconnects from USB → hub port power cycle (~7s recovery)
   - Re-applies all fixes after recovery
5. **Installs a udev rule** — applies fixes automatically on hotplug
6. **Installs a systemd service** — applies fixes on boot

## Which adapters are affected (RTL8152/RTL8153 chip)

Any USB Ethernet adapter using the Realtek RTL8152 or RTL8153 chip is vulnerable to this bug. Common brands and models:

### Confirmed affected (use this fix)
| Brand | Model(s) | Notes |
|-------|----------|-------|
| **TP-Link** | UE300, UE306, UE330 | Most commonly reported |
| **Anker** | PowerExpand USB-C Ethernet, 3-in-1 Hub Ethernet | |
| **Cable Matters** | USB-C to Gigabit Ethernet, USB 3.0 to Gigabit | |
| **D-Link** | DUB-1312, DUB-1810 | |
| **Sabrent** | USB-C to Gigabit Ethernet (NT-SS3E) | |
| **Plugable** | USBC-E1000, USB3-E1000 | |
| **UGREEN** | USB 3.0 to Gigabit Ethernet (20256, 20257) | |
| **ORICO** | Various USB-C/USB 3.0 Ethernet adapters | |
| **StarTech** | USB31000S, USB31100S | |
| **Belkin** | USB-C to Gigabit Ethernet | |
| **AmazonBasics** | USB 3.0 to Gigabit Ethernet | |
| **Trendnet** | TU3-ETG, TU3-HUB6E | |
| **TRENDnet** | USB 3.0 to Gigabit Ethernet | |
| **IOGEAR** | GUCE6, GUC3C05 | |
| **Insignia** | USB-C to Ethernet | |
| **Lenovo** | USB-C to Ethernet Adapter | |
| **Dell** | USB-C to Ethernet Adapter (with RTL8153) | |
| **HP** | USB-C to Ethernet Adapter (with RTL8153) | |
| **Microsoft** | Surface USB-C to Ethernet Adapter | |

> **How to check your chip:** Run `lsusb` and look for `Realtek Semiconductor Corp.` with ID `0bda:8153` (RTL8153) or `0bda:8152` (RTL8152). Or run `ethtool -i eth0 | grep driver` — if it says `r8152`, you're affected.

## Why this happens

The r8152 driver interacts with the USB endpoint in a way that can cause `-EPROTO` errors under certain traffic patterns. This is a known silicon bug in the RTL8153 chip that manifests as:

```
r8152 ... enx...: Tx status -71
r8152 ... enx...: Stop submitting intr, status -71
```

The chip's USB 3.0 implementation has a bug that gets triggered by:
- **TCP Segmentation Offload (TSO)** creating large USB transfers
- **USB power management** transitions
- **Driver buffer management** under load

Disabling TSO/GRO/GSO/SG prevents the large USB transfers that trigger the bug.

## Recommended adapters (stable on Linux)

If you want to replace your adapter because this fix isn't enough, get one with a **different chip**. Here are alternatives sorted by reliability:

### ✅ Best — ASIX AX88179 / AX88179A
**The gold standard for Linux USB Ethernet. Mature, stable driver, zero Tx -71 issues.**

| Brand | Model(s) | Where to buy (Philippines) |
|-------|----------|---------------------------|
| **UGREEN** | USB 3.0 to Gigabit (50705, 50706) | Shopee / Lazada ~₱500-700 |
| **ORICO** | USB 3.0 to Gigabit (UE3065) | Shopee / Lazada ~₱600-800 |
| **D-Link** | DUB-1312 (check chip version) | SM / Datablitz |
| **Plugable** | USB3-E1000 (AX88179 version) | Amazon / Lazada |
| **Anker** | USB-C to Ethernet (AX88179 version) | Shopee / Lazada |
| **Generic** | Any "ASIX AX88179" USB 3.0 Ethernet | Shopee / Lazada **~₱350-500** |

Search "AX88179 USB Ethernet" on Shopee or Lazada — they're cheap and they work.

### ⚠️ OK — RTL8156B / RTL8156
Newer Realtek chips. Fewer bugs than RTL8153 but still can have issues.

| Brand | Model(s) |
|-------|----------|
| **TP-Link** | UE300 (newer revisions with RTL8156B) |
| **Cable Matters** | 2023+ USB-C Ethernet |
| **D-Link** | DUB-E250 |

### ❌ Avoid — RTL8153
This is what you have if you're reading this. Known-buggy silicon.

## Usage

```
sudo bash fix-r8152.sh install    # Apply fixes + install all components (default)
sudo bash fix-r8152.sh status     # Check current status
sudo bash fix-r8152.sh remove     # Remove all changes
sudo bash fix-r8152.sh apply      # Apply fixes to current interfaces only
sudo bash fix-r8152.sh watchdog   # Install only the watchdog cron job
```

## Requirements

- **OS:** Any Linux distribution with kernel 3.x+
- **Tools:** `bash`, `ethtool`, `ping`, `journalctl` (optional, for error detection), `sudo`
- **RAM/CPU:** Negligible — the watchdog is a 100-line bash script that runs for ~200ms every 2 minutes
- **Works with:** Pi.dev, Claude Code, OpenClaw, or any terminal — just bash commands

## The watchdog recovery strategy

When Tx errors are detected:

1. **Driver unbind/bind** — Resets only the r8152 network driver. Safe, doesn't affect other USB devices. Takes ~5 seconds.
2. **Hub port power cycle** — If the device physically disconnected from USB, power-cycles just that port on the USB hub. Forces re-enumeration. Takes ~7 seconds.
3. **Re-applies all fixes** — After recovery, offloads are re-disabled and power saving is re-disabled.

If neither works, the watchdog logs a failure message. The adapter chip may be faulty at that point.

## File layout

```
/opt/r8152-fix/           # Installation directory (or wherever you cloned)
├── fix-r8152.sh          # Main installer/uninstaller/status
├── r8152-watchdog.sh     # Auto-recovery watchdog (runs via cron every 2min)
├── README.md             # This file
└── LICENSE               # MIT

/etc/udev/rules.d/
├── 99-r8152-fix.rules    # USB power settings on hotplug
└── 99-r8152-trigger.rules # Triggers systemd service on interface add

/etc/systemd/system/
└── r8152-fix.service     # Applies fixes on boot
```

## Contributing

PRs welcome! Especially for:
- Testing on other RTL8153/RTL8152 adapters
- Testing on other Linux distros
- Better recovery strategies
- Additional chip quirks

## License

MIT — do whatever you want, share with whoever needs it.
