#!/bin/bash
# ═══════════════════════════════════════════
# reboot.sh — Tethered boot for bypassed devices
#
# Use this whenever a bypassed device powers off.
# checkm8 runs from RAM, doesn't survive power cycles.
# The bypass files are still on the filesystem though,
# so we just need to re-exploit and boot.
# ═══════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo "  Tethered Boot — re-exploit a bypassed device"
echo ""
echo "  Which device?"
echo "    1) iPhone 5  (A6)  — needs tethered boot"
echo "    2) iPhone 6  (A8)  — SSHRD bypass: boots normally (no tethered boot needed)"
echo "    3) iPhone 7  (A10) — needs tethered boot"
read -p "  Enter 1, 2, or 3: " choice

if [ "$choice" = "2" ]; then
    echo ""
    echo -e "${GREEN}[✓]${NC} iPhone 6 / 6 Plus (A8) was bypassed via SSHRD."
    echo ""
    echo "  These devices boot normally — no tethered reboot needed."
    echo "  The bypass modified persistent filesystem (Setup.app, activation records)."
    echo ""
    echo "  If the device is stuck or shows Activation Lock again:"
    echo "    1. Enter DFU (Power+Home 8s, release Power, hold Home 5s)"
    echo "    2. Run: bash unlock.sh --model i6p"
    echo "    or: bash bypass.sh --sshrd"
    echo ""
    exit 0
fi

echo ""
echo "  Put device in DFU now:"
case $choice in
    1) echo "  Hold ${BOLD}POWER + HOME${NC} 8s → release POWER, keep HOME 5s" ;;
    3) echo "  Hold ${BOLD}POWER + VOL DOWN${NC} 8s → release POWER, keep VOL DOWN 5s" ;;
esac
echo ""

echo -e "${CYAN}[*]${NC} Waiting for DFU..."
while ! system_profiler SPUSBDataType 2>/dev/null | grep -qi "Apple Mobile Device (DFU)"; do
    sleep 1; echo -n "."
done
echo ""
echo -e "${GREEN}[✓]${NC} DFU detected."

case $choice in
    1)
        echo -e "${CYAN}[*]${NC} Re-exploiting via ipwndfu..."
        cd "$SCRIPT_DIR/ipwndfu"
        python3 ./ipwndfu -p 2>/dev/null || python2 ./ipwndfu -p 2>/dev/null || true
        echo -e "${CYAN}[*]${NC} Booting SSH ramdisk..."
        cd "$SCRIPT_DIR/sshrd"
        ./sshrd.sh boot 2>/dev/null || true
        cd "$SCRIPT_DIR"
        ;;
    3)
        echo -e "${CYAN}[*]${NC} Re-running checkra1n..."
        checkra1n -c -v
        ;;
esac

echo ""
echo -e "${GREEN}[✓]${NC} Done. Device should boot past Activation Lock in ~60s."
echo "  The bypass patches from the original unlock are still on-device."
echo ""
