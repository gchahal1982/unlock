#!/bin/bash
# ═══════════════════════════════════════════
# batch.sh — Process multiple devices sequentially
# Enhanced for guided multi-device runs with optional model mapping.
# ═══════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOTAL=4
COMPLETED=0
FAILED=0
MODEL_SEQUENCE_CSV="i6p,i6,i6,i5"
AUTO_CONTINUE=0
WAIT_TIMEOUT=240
WORKFLOW="ask"
WORKFLOW_SEQUENCE_CSV=""
QUEUE_MODE=0
LOG_FILE="$SCRIPT_DIR/unlock.log"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${CYAN}[*]${NC} $1"; }
log_event() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

usage() {
    cat <<'USAGE'
Usage: bash batch.sh [--count N] [--models m1,m2,m3...] [--workflow unlock|reset|ask] [--workflows unlock,ask,...] [--queue] [--auto] [--help]

Arguments:
  --count   Number of devices to process (default: 4)
  --models  Comma-separated expected models, one per device
            Allowed values: i5, i6, i6p
            Example: --models i6p,i6,i6,i5
  --workflow    Set mode for all devices: ask (default), unlock, reset
  --workflows   Optional per-device workflow sequence: unlock|reset|ask
  --queue       Queue mode: no failure prompts, run all slots as one pass
  --auto    Continue to next device automatically even if one fails
  --help    Show this help text

Examples:
  bash batch.sh
  bash batch.sh --count 4 --models i6p,i6,i6,i5
  bash batch.sh --count 4 --workflow reset
  bash batch.sh --models i6p,i6,i6,i5 --auto
  bash batch.sh --count 4 --models i6p,i6,i6,i5 --workflows unlock,ask,reset,ask --queue
USAGE
}

trim() {
    local input=$1
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
    printf '%s' "$input"
}

normalize_model() {
    local model
    model=$(trim "$1")
    case "$model" in
        i5|a6|A1429|iPhone5|I5|A6|iPhone5,*) model="i5" ;;
        i6|i6p|i6-plus|A1524|A1586|iPhone6plus|iPhone6+|iPhone6,*|A8|iPhone7,*) model="i6" ;;
        i7|a10|iPhone7|A10|iPhone9,*) model="i7" ;;
        "" ) model="" ;;
        * ) model="$model" ;;
    esac
    printf '%s' "$model"
}

parse_args() {
    local args=("$@")
    local i=0
    while [ $i -lt ${#args[@]} ]; do
        case "${args[$i]}" in
            --count)
                i=$((i + 1))
                if [ $i -ge ${#args[@]} ]; then
                    error "Missing value for --count"; usage; exit 1
                fi
                TOTAL="${args[$i]}"
                ;;
            --models)
                i=$((i + 1))
                if [ $i -ge ${#args[@]} ]; then
                    error "Missing value for --models"; usage; exit 1
                fi
                MODEL_SEQUENCE_CSV="${args[$i]}"
                ;;
            --auto)
                AUTO_CONTINUE=1
                ;;
            --queue)
                QUEUE_MODE=1
                ;;
            --workflows)
                i=$((i + 1))
                if [ $i -ge ${#args[@]} ]; then
                    error "Missing value for --workflows"; usage; exit 1
                fi
                WORKFLOW_SEQUENCE_CSV="${args[$i]}"
                ;;
            --workflow)
                i=$((i + 1))
                if [ $i -ge ${#args[@]} ]; then
                    error "Missing value for --workflow"; usage; exit 1
                fi
                WORKFLOW="${args[$i]}"
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown argument: ${args[$i]}"
                usage
                exit 1
                ;;
        esac
        i=$((i + 1))
    done
}

normalize_workflow() {
    local value="$1"
    case "$value" in
        unlock|ask|reset)
            printf '%s' "$value"
            return 0
            ;;
        1|u|U|b|B|unlock-mode|unlock_mode)
            printf '%s' "unlock"
            return 0
            ;;
        2|r|R|reset-mode|reset_mode|factory|factory-reset|full-reset|restore)
            printf '%s' "reset"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

normalize_workflow_list() {
    local list="$1"
    local token
    local normalized
    local -a out=()
    IFS=',' read -r -a workflow_array <<< "$list"

    for token in "${workflow_array[@]}"; do
        token="$(trim "$token")"
        [ -z "$token" ] && token="ask"

        if ! normalized="$(normalize_workflow "$token")"; then
            return 1
        fi

        out+=("$normalized")
    done

    (IFS=','; printf '%s' "${out[*]}")
}

workflow_for_slot() {
    local slot="$1"
    local fallback="$2"
    local value="${fallback}"

    if [ -n "$WORKFLOW_SEQUENCE_CSV" ]; then
        IFS=',' read -r -a workflow_array <<< "$WORKFLOW_SEQUENCE_CSV"
        value="${workflow_array[$((slot - 1))]:-$fallback}"
        value="$(trim "$value")"
        [ -z "$value" ] && value="$fallback"
        if ! value="$(normalize_workflow "$value")"; then
            value="$fallback"
        fi
    else
        value="$fallback"
    fi

    printf '%s' "$value"
}

ask_workflow() {
    local slot="$1"
    local model="$2"
    local choice=""
    local normalized=""

    if [ -z "$slot" ]; then
        slot="device"
    fi

    if [ ! -t 0 ]; then
        printf '%s' "unlock"
        return 0
    fi

    echo ""
    echo "  Select flow for device #$slot:"
    [ -n "$model" ] && echo "  Model hint: $model"
    echo "  1) Activation bypass (recommended)"
    echo "  2) Full factory reset (erase + restore)"
    read -r -p "  Enter 1 or 2 [1]: " choice
    [ -z "$choice" ] && choice="1"

    if ! normalized=$(normalize_workflow "$choice"); then
        warn "Invalid selection. Defaulting to bypass."
        printf '%s' "unlock"
    else
        printf '%s' "$normalized"
    fi
}

model_sequence() {
    local model_array=()
    IFS=',' read -r -a model_array <<< "$MODEL_SEQUENCE_CSV"
    local idx=0
    while [ $idx -lt "$TOTAL" ]; do
        if [ $idx -lt "${#model_array[@]}" ]; then
            printf '%s\n' "$(normalize_model "${model_array[$idx]}")"
        else
            # Keep defaults when sequence is shorter than count.
            local fallback=("${model_array[@]}")
            local fallback_defaults=("i6p" "i6" "i6" "i5")
            if [ ${#fallback[@]} -eq 0 ]; then
                printf '%s\n' "${fallback_defaults[$((idx % 4))]}"
            else
                printf '%s\n' "$(normalize_model "${fallback[$((idx % ${#fallback[@]}))]}")"
            fi
        fi
        idx=$((idx + 1))
    done
}

wait_for_device_connection() {
    local expected_label=$1
    local elapsed=0
    local wait_msg="Waiting for next phone"
    if [ -n "$expected_label" ]; then
        wait_msg="Waiting for next phone ($expected_label)"
    fi

    info "$wait_msg..."
    while true; do
        if idevice_id -l 2>/dev/null | grep -q .; then
            success "Device detected in normal mode."
            return 0
        fi

        if system_profiler SPUSBDataType 2>/dev/null | grep -qi "Apple Mobile Device (DFU)\|Apple Mobile Device (Recovery)"; then
            success "Device detected in DFU/Recovery mode."
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
        [ $((elapsed % 20)) -eq 0 ] && echo "  ... ${elapsed}s"
        [ $elapsed -ge "$WAIT_TIMEOUT" ] && {
            error "Timed out waiting for a device."
            return 1
        }
    done
}

run_unlock() {
    local model=$1
    local workflow=$2
    local cmd=(bash "$SCRIPT_DIR/unlock.sh")
    if [ -n "$model" ]; then
        cmd+=(--model "$model")
    fi
    if [ -n "$workflow" ]; then
        cmd+=(--workflow "$workflow")
    fi

    info "Running unlock for model tag: ${model:-auto} / flow: ${workflow:-ask}"
    set +e
    "${cmd[@]}"
    local rc=$?
    set -e
    return "$rc"
}

parse_args "$@"

if [ ! -f "$SCRIPT_DIR/unlock.sh" ]; then
    error "unlock.sh is missing."
    exit 1
fi

if ! command -v idevice_id &>/dev/null; then
    warn "libimobiledevice not found. Run setup.sh first."
    exit 1
fi

if ! [[ "$TOTAL" =~ ^[0-9]+$ ]]; then
    error "Count must be a number: $TOTAL"
    exit 1
fi

if [ "$TOTAL" -lt 1 ]; then
    error "Invalid count: $TOTAL"
    exit 1
fi

if ! WORKFLOW=$(normalize_workflow "$WORKFLOW"); then
    error "Invalid workflow: $WORKFLOW"
    usage
    exit 1
fi

if [ -n "$WORKFLOW_SEQUENCE_CSV" ]; then
    if ! WORKFLOW_SEQUENCE_CSV="$(normalize_workflow_list "$WORKFLOW_SEQUENCE_CSV")"; then
        error "Invalid workflow sequence in --workflows"
        exit 1
    fi

    if [ "$QUEUE_MODE" -eq 0 ]; then
        IFS=',' read -r -a workflow_sequence_array <<< "$WORKFLOW_SEQUENCE_CSV"
        if [ "${#workflow_sequence_array[@]}" -ne "$TOTAL" ]; then
            warn "Workflow sequence has ${#workflow_sequence_array[@]} entries; missing slots will use global workflow."
        fi
    fi
fi

MODEL_SEQUENCE_ARRAY=()
while IFS= read -r model_token; do
    MODEL_SEQUENCE_ARRAY+=("$model_token")
done < <(model_sequence)

if [ "${#MODEL_SEQUENCE_ARRAY[@]}" -ne "$TOTAL" ]; then
    warn "Model sequence does not match total devices. Using available mapping."
fi

log_event "=== Batch start: devices=$TOTAL models=$MODEL_SEQUENCE_CSV workflow=$WORKFLOW workflows=${WORKFLOW_SEQUENCE_CSV:-none} queue=$QUEUE_MODE ==="

echo ""
echo "  ╔═════════════════════════════════════╗"
echo "  ║  Batch Unlock — $TOTAL Devices           ║"
echo "  ║  1x iPhone 6 Plus, 2x iPhone 6, 1x iPhone 5║"
echo "  ╚═════════════════════════════════════╝"
echo ""

for i in $(seq 1 "$TOTAL"); do
    idx=$((i - 1))
    model_for_device="${MODEL_SEQUENCE_ARRAY[$idx]}"
    WORKFLOW_FOR_DEVICE="$(workflow_for_slot "$i" "$WORKFLOW")"
    if [ "$WORKFLOW_FOR_DEVICE" = "ask" ]; then
        WORKFLOW_FOR_DEVICE="$(ask_workflow "$i" "$model_for_device")"
    fi

    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}  DEVICE $i of $TOTAL${NC}"
    if [ -n "$model_for_device" ]; then
        echo -e "${CYAN}  Expected model: $model_for_device${NC}"
    fi
    echo -e "${BOLD}═══════════════════════════════════════${NC}"

    if [ $i -gt 1 ]; then
        echo ""
        echo "  Unplug previous phone and plug in device #$i."
        echo "  Leave it in normal boot if possible."
        if [ "$QUEUE_MODE" -eq 1 ]; then
            read -p "  Press ENTER when ready (q to quit queue): " input
            [ "$input" = "q" ] && break
        else
            read -p "  Press ENTER when ready (q to quit): " input
            [ "$input" = "q" ] && break
        fi
    fi

    log_event "Device #$i queued (model=$model_for_device planned_workflow=$WORKFLOW_FOR_DEVICE)"

    if ! wait_for_device_connection "$model_for_device"; then
        FAILED=$((FAILED + 1))
        warn "No device connected for slot $i."
        log_event "Device #$i timed out waiting for connection"
        if [ "$AUTO_CONTINUE" -eq 0 ] && [ "$QUEUE_MODE" -eq 0 ]; then
            read -p "  Continue to next? (y/n): " cont
            [ "$cont" != "y" ] && break
        fi
        continue
    fi

    if run_unlock "$model_for_device" "$WORKFLOW_FOR_DEVICE"; then
        COMPLETED=$((COMPLETED + 1))
        echo -e "  ${GREEN}Device #$i: DONE${NC}"
        log_event "Device #$i result: DONE"
    else
        FAILED=$((FAILED + 1))
        echo -e "  ${RED}Device #$i: FAILED${NC}"
        log_event "Device #$i result: FAILED"
        if [ "$AUTO_CONTINUE" -eq 0 ] && [ "$QUEUE_MODE" -eq 0 ]; then
            read -p "  Continue to next? (y/n): " cont
            [ "$cont" != "y" ] && break
        fi
    fi
    echo ""
done

echo ""
echo "  ═══════════════════════════"
echo "  Done: $COMPLETED/$TOTAL    Failed: $FAILED"
echo "  ═══════════════════════════"
echo ""

log_event "=== Batch end: devices=$TOTAL done=$COMPLETED failed=$FAILED ==="
