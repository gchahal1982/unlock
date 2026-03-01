#!/bin/bash
# ═══════════════════════════════════════════
# setup.sh — Install everything needed
# Run once on your Mac before using unlock.sh
# ═══════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$SCRIPT_DIR/bin"
export PATH="$TOOLS_DIR:$PATH"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${CYAN}[*]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; }

command_is_executable() {
    local target="${1:-}"
    if [ -z "$target" ]; then
        return 1
    fi

    local path
    path="$(command -v "$target" 2>/dev/null || true)"
    if [ -z "$path" ]; then
        return 1
    fi

    [ -x "$path" ]
}

is_checkra1n_command() {
    local path
    path="$(command -v "$1" 2>/dev/null || true)"
    if [ -z "$path" ] || [ ! -x "$path" ]; then
        return 1
    fi

    if file "$path" 2>/dev/null | grep -q "Mach-O"; then
        local rc=0
        if command -v timeout >/dev/null 2>&1; then
            timeout 3 "$path" -h >/dev/null 2>&1 || rc=$?
        else
            "$path" -h >/dev/null 2>&1 || rc=$?
        fi

        if [ "$rc" -eq 124 ] || [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
            return 0
        fi
        return 1
    fi

    if head -n 1 "$path" 2>/dev/null | grep -q "^#!"; then
        if [ "$path" = "$TOOLS_DIR/checkra1n" ] && [ ! -x "$TOOLS_DIR/checkra1n.app/Contents/MacOS/checkra1n" ]; then
            return 1
        fi
        return 0
    fi

    return 1
}

build_checkra1n_launcher_from_dmg() {
    local dmg_path="${1:?}"
    local mount_point="/tmp/checkra1n-dmg"
    local candidate_path
    local app_path=""
    local app_binary
    local app_lib
    local i=0
    local paths=(
        "$mount_point/checkra1n.app"
        "$mount_point/Applications/checkra1n.app"
    )

    if mount | grep -q " on $mount_point "; then
        hdiutil detach "$mount_point" -quiet 2>/dev/null || true
    fi
    rm -rf "$TOOLS_DIR/checkra1n.app"
    rm -rf "$mount_point"
    mkdir -p "$mount_point"

    if ! hdiutil attach "$dmg_path" -nobrowse -readonly -mountpoint "$mount_point" >/dev/null 2>&1; then
        return 1
    fi

    while [ "$i" -lt "${#paths[@]}" ]; do
        candidate_path="${paths[$i]}"
        if [ -f "$candidate_path/Contents/MacOS/checkra1n" ]; then
            app_path="$candidate_path"
            break
        fi
        i=$((i + 1))
    done

    if [ -z "$app_path" ]; then
        hdiutil detach "$mount_point" -quiet 2>/dev/null || true
        return 1
    fi

    app_binary="$app_path/Contents/MacOS/checkra1n"
    app_lib="$app_path/Contents/MacOS/libfatman.dylib"

    if [ ! -f "$app_binary" ]; then
        hdiutil detach "$mount_point" -quiet 2>/dev/null || true
        return 1
    fi

    mkdir -p "$TOOLS_DIR/checkra1n.app/Contents/MacOS"
    cp -f "$app_binary" "$TOOLS_DIR/checkra1n.app/Contents/MacOS/checkra1n"
    if [ -f "$app_lib" ]; then
        cp -f "$app_lib" "$TOOLS_DIR/checkra1n.app/Contents/MacOS/libfatman.dylib"
    fi

    cat > "$TOOLS_DIR/checkra1n" <<'EOF'
#!/bin/sh
SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
"$SCRIPT_DIR/checkra1n.app/Contents/MacOS/checkra1n" "$@"
EOF

    chmod +x "$TOOLS_DIR/checkra1n"
    hdiutil detach "$mount_point" -quiet 2>/dev/null || hdiutil detach "$mount_point" -lazy -quiet 2>/dev/null || true
    rmdir "$mount_point" 2>/dev/null || true
    rm -rf "$dmg_path"
    return 0
}

check_xcode_license() {
    if ! command -v xcodebuild &>/dev/null; then
        warn "xcodebuild not found in PATH."
        warn "Install Xcode Command Line Tools first:"
        echo "  xcode-select --install"
        return 1
    fi

  if ! xcodebuild -license check &>/dev/null; then
        fail "Xcode license not accepted."
        echo "  Run (in your own terminal):"
        echo "    sudo xcodebuild -license accept"
        echo "  Then re-run: bash setup.sh"
        return 1
    fi

    return 0
}

echo ""
echo "  ═══════════════════════════════════"
echo "  Setup: iCloud Bypass Dependencies"
echo "  ═══════════════════════════════════"
echo ""

if [[ "$(uname)" != "Darwin" ]]; then
    fail "Requires macOS. checkra1n doesn't run on Windows/Linux natively."
    exit 1
fi

if ! check_xcode_license; then
    exit 1
fi

# ── Homebrew ──
info "Homebrew..."
if command -v brew &>/dev/null; then
    success "Homebrew installed."
else
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# ── libimobiledevice ──
info "libimobiledevice (device USB communication)..."
brew install libimobiledevice libusbmuxd libplist
for t in idevice_id ideviceinfo iproxy; do
    command -v "$t" &>/dev/null && success "  $t" || fail "  $t missing"
done

# ── sshpass ──
info "sshpass (automated SSH)..."
if command -v sshpass &>/dev/null; then
    success "sshpass installed."
else
    brew install hudochenkov/sshpass/sshpass || brew install sshpass || {
        warn "Tap failed. Building from source..."
        cd /tmp
        curl -sLO https://sourceforge.net/projects/sshpass/files/sshpass/1.10/sshpass-1.10.tar.gz
        tar xzf sshpass-1.10.tar.gz && cd sshpass-1.10
        ./configure && make && sudo make install
        cd /tmp && rm -rf sshpass-1.10*
    }
    command -v sshpass &>/dev/null && success "sshpass installed." || warn "sshpass failed — you can SSH manually with password: alpine"
fi

# ── Python + pyusb (for ipwndfu / iPhone 5) ──
info "Python + pyusb (for iPhone 5 exploit)..."
if command -v python3 &>/dev/null; then
    success "python3"
    pip3 install pyusb 2>/dev/null || pip3 install pyusb --break-system-packages 2>/dev/null || true
    success "pyusb"
else
    brew install python3 2>/dev/null || true
fi

# ── libusb (needed by ipwndfu) ──
info "libusb..."
brew install libusb 2>/dev/null || true
success "libusb"

# ── checkra1n (for iPhone 6 and 7) ──
info "checkra1n..."
if is_checkra1n_command checkra1n; then
    success "checkra1n found: $(which checkra1n)"
else
        mkdir -p "$TOOLS_DIR"
        CHECKRA1N_LOCAL="$TOOLS_DIR/checkra1n"
    if command -v brew &>/dev/null; then
        warn "checkra1n not available yet. Trying brew cask install..."
        if brew install --cask checkra1n; then
            success "checkra1n installed via Homebrew Cask."
        else
            warn "Cask install failed, trying direct download fallback..."
        fi
    fi

    if is_checkra1n_command checkra1n; then
        success "checkra1n found: $(which checkra1n)"
        if [ -n "$(uname -m | tr '[:upper:]' '[:lower:]')" ] && [ "$(uname -m)" = "arm64" ]; then
            warn "checkra1n is Apple-silicon compatible only via Rosetta 2 in this release."
            warn "If checkra1n fails to launch, run: softwareupdate --install-rosetta --agree-to-license"
        fi
    elif [ -f "/Applications/checkra1n.app/Contents/MacOS/checkra1n" ] && [ -x "/Applications/checkra1n.app/Contents/MacOS/checkra1n" ]; then
        mkdir -p "$TOOLS_DIR/checkra1n.app/Contents/MacOS"
        cp -f "/Applications/checkra1n.app/Contents/MacOS/checkra1n" "$TOOLS_DIR/checkra1n.app/Contents/MacOS/checkra1n"
        if [ -f "/Applications/checkra1n.app/Contents/MacOS/libfatman.dylib" ]; then
            cp -f "/Applications/checkra1n.app/Contents/MacOS/libfatman.dylib" "$TOOLS_DIR/checkra1n.app/Contents/MacOS/libfatman.dylib"
        fi
        cat > "$CHECKRA1N_LOCAL" <<'EOF'
#!/bin/sh
SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
"$SCRIPT_DIR/checkra1n.app/Contents/MacOS/checkra1n" "$@"
EOF
        chmod +x "$CHECKRA1N_LOCAL"
        success "checkra1n launcher copied into local repo: $CHECKRA1N_LOCAL"
    else
        CHECKRA1N_URL="https://assets.checkra.in/downloads/macos/754bb6ec4747b2e700f01307315da8c9c32c8b5816d0fe1e91d1bdfc298fe07b/checkra1n%20beta%200.12.4.dmg"
        info "Downloading checkra1n from checkra.in..."
        CHECKRA1N_DL="$TOOLS_DIR/.checkra1n-downloaded.dmg"
        if curl -fsSL "$CHECKRA1N_URL" -o "$CHECKRA1N_DL" 2>/dev/null; then
            if build_checkra1n_launcher_from_dmg "$CHECKRA1N_DL"; then
                success "checkra1n extracted and launcher created: $CHECKRA1N_LOCAL"
                echo "  If macOS blocks it on first run:"
                echo "  System Settings → Privacy & Security → scroll down → Allow"
            else
                rm -f "$CHECKRA1N_DL"
                warn "Could not extract checkra1n from downloaded DMG."
            fi
        else
            warn "Auto-download failed."
            echo "  Download manually: https://checkra.in"
            echo "  Then: cp ~/Downloads/checkra1n \"$CHECKRA1N_LOCAL\" && chmod +x \"$CHECKRA1N_LOCAL\""
        fi
    fi
    if is_checkra1n_command checkra1n; then
        success "checkra1n available for unlock scripts: $(command -v checkra1n)"
    else
        warn "checkra1n still not found or not executable in PATH."
    fi
fi

# ── ipwndfu (for iPhone 5) ──
info "ipwndfu (iPhone 5 BootROM exploit)..."
if [ -d "$SCRIPT_DIR/ipwndfu" ]; then
    success "ipwndfu already cloned."
else
    info "Cloning ipwndfu..."
    git clone https://github.com/axi0mX/ipwndfu.git "$SCRIPT_DIR/ipwndfu" 2>/dev/null && success "ipwndfu cloned." || warn "Clone failed — try manually: git clone https://github.com/axi0mX/ipwndfu.git"
fi

# ── SSHRD_Script (SSH ramdisk for A6-A8 devices) ──
info "SSHRD_Script (SSH ramdisk for A6-A8 devices: iPhone 5/6/6 Plus)..."
if [ -d "$SCRIPT_DIR/sshrd" ]; then
    success "SSHRD_Script already cloned."
else
    info "Cloning SSHRD_Script..."
    git clone https://github.com/verygenericname/SSHRD_Script.git "$SCRIPT_DIR/sshrd" 2>/dev/null && success "SSHRD_Script cloned." || warn "Clone failed — try manually"
fi

# ── Summary ──
echo ""
echo "  ═══════════════════════════════════"
echo "  Summary"
echo "  ═══════════════════════════════════"
echo ""

ALL=true
for cmd in idevice_id ideviceinfo iproxy sshpass python3 checkra1n; do
    if [ "$cmd" = "checkra1n" ]; then
        is_checkra1n_command "$cmd" && success "$cmd" || { fail "$cmd MISSING"; ALL=false; }
    else
        command -v "$cmd" &>/dev/null && success "$cmd" || { fail "$cmd MISSING"; ALL=false; }
    fi
done
[ -d "$SCRIPT_DIR/ipwndfu" ] && success "ipwndfu" || { warn "ipwndfu not cloned"; ALL=false; }
[ -d "$SCRIPT_DIR/sshrd" ] && success "SSHRD_Script" || { warn "SSHRD not cloned"; ALL=false; }

echo ""
if [ "$ALL" = true ]; then
    success "Ready. Plug in a device and run: bash unlock.sh"
else
    warn "Fix missing items above, then re-run setup.sh"
fi
echo ""
