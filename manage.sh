#!/bin/bash
# ═══════════════════════════════════════════
# manage.sh — Friendly command center for unlock workflow
# ═══════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/icloud-unlock"
CONFIG_FILE="$CONFIG_DIR/session-defaults.conf"
LOG_FILE="$SCRIPT_DIR/unlock.log"
LOG_PANEL_LINES=6

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

QUEUE_SIZE=4
DEFAULT_BATCH_COUNT=4
DEFAULT_BATCH_MODELS="i6p,i6,i6,i5"
DEFAULT_BATCH_AUTO=0
DEFAULT_QUEUE_MODELS="i6p,i6,i6,i5"
DEFAULT_QUEUE_WORKFLOWS="ask,ask,ask,ask"
WORKFLOW="ask"

success() { echo -e "${GREEN}[✓]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${CYAN}[*]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; }

trim() {
    local input=$1
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
    printf '%s' "$input"
}

workflow_label() {
    case "$1" in
        unlock) printf "Unlock / Bypass" ;;
        reset) printf "Factory Reset" ;;
        ask) printf "Ask per Device" ;;
        *) printf "Ask per Device" ;;
    esac
}

workflow_label_short() {
    case "$1" in
        unlock) printf "UNL" ;;
        reset) printf "RST" ;;
        ask) printf "ASK" ;;
        *) printf "ASK" ;;
    esac
}

compact_text() {
    local text="$1"
    local max_chars="$2"

    if [ "${#text}" -le "$max_chars" ]; then
        printf '%s' "$text"
    else
        printf '%s' "${text:0:max_chars}"
    fi
}

normalize_model() {
    local model
    model="$(trim "$1")"

    case "$model" in
        i5|a6|A1429|iPhone5|I5|A6|iPhone5,*) model="i5" ;;
        i6|i6p|i6-plus|A1524|A1586|iPhone6plus|iPhone6+|iPhone6,*|a8|A8|iPhone7,*) model="i6" ;;
        i7|a10|iPhone7|A10|iPhone9,*) model="i7" ;;
        "" ) model="i5" ;;
        * ) model="i5" ;;
    esac

    printf '%s' "$model"
}

normalize_model_list() {
    local list="$1"
    local fallback_csv="$2"
    local target="${3:-$QUEUE_SIZE}"
    local -a raw=()
    local -a fallback=()
    local -a out=()
    local i=0
    local value

    IFS=',' read -r -a raw <<< "$list"
    IFS=',' read -r -a fallback <<< "$fallback_csv"

    while [ "$i" -lt "$target" ]; do
        value="$(trim "${raw[$i]:-}")"
        if [ -z "$value" ]; then
            value="$(trim "${fallback[$i]:-}")"
        fi
        if [ -z "$value" ]; then
            value="i5"
        fi

        if ! value="$(normalize_model "$value")"; then
            value="i5"
        fi

        out+=("$value")
        i=$((i + 1))
    done

    (IFS=','; printf '%s' "${out[*]}")
}

connection_count() {
    if ! command -v idevice_id &>/dev/null; then
        printf 'n/a'
        return 0
    fi
    idevice_id -l 2>/dev/null | wc -l | tr -d ' '
}

connection_has_dfu() {
    if system_profiler SPUSBDataType 2>/dev/null | grep -qi "Apple Mobile Device (DFU)\\|Apple Mobile Device (Recovery)"; then
        printf '1'
    else
        printf '0'
    fi
}

dependency_state() {
    if command -v "$1" &>/dev/null; then
        printf 'ok'
    else
        printf 'missing'
    fi
}

usage() {
    cat <<'USAGE'
Usage:
  bash manage.sh
  bash manage.sh --mode setup|unlock|batch|queue|reboot|status
  bash manage.sh --mode batch --count N --models i6p,i6,i6,i5 --auto
  bash manage.sh --mode batch --workflow unlock|reset|ask
  bash manage.sh --mode queue
  bash manage.sh --mode unlock --workflow unlock|reset|ask

Options:
  --mode     Launch a preset flow directly
            setup, unlock, batch, queue, reboot, status
  --count    Used with --batch: number of devices
  --models   Comma-separated model sequence for batch: i6p,i6,i6,i5
  --queue-models   Comma-separated model sequence for queued 4-device run
  --queue-workflows Comma-separated workflow sequence for queued run:
                  unlock,reset,ask (one per queue slot)
  --auto     Used with --batch / --mode queue: continue automatically on failures
  --workflow Choose run mode: unlock, reset, ask
             ask = prompt per device (default)
  --factory-reset   Alias for --workflow reset
  --bypass          Alias for --workflow unlock
  --help     Show this message
USAGE
}

normalize_workflow() {
    local value="$1"
    case "$value" in
        unlock|ask|reset)
            printf '%s' "$value"
            return 0
            ;;
        bypass)
            printf '%s' "unlock"
            return 0
            ;;
        full-reset|factory-reset|factory|restore)
            printf '%s' "reset"
            return 0
            ;;
        1|u|U|b|B)
            printf '%s' "unlock"
            return 0
            ;;
        2|r|R|f|F)
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

    if [ -z "$list" ]; then
        printf '%s' "ask"
        return 0
    fi

    IFS=',' read -r -a token_array <<< "$list"
    for token in "${token_array[@]}"; do
        token="$(trim "$token")"
        if [ -z "$token" ]; then
            token="ask"
        fi

        if ! normalized="$(normalize_workflow "$token")"; then
            return 1
        fi

        out+=("$normalized")
    done

    (IFS=','; printf '%s' "${out[*]}")
}

csv_value_at() {
    local csv="$1"
    local index="$2"
    local -a list=()

    IFS=',' read -r -a list <<< "$csv"
    printf '%s' "$(trim "${list[$index]:-}")"
}

pad_csv() {
    local value_csv="$1"
    local fallback_csv="$2"
    local target="${3:-$QUEUE_SIZE}"

    local -a raw=()
    local -a fallback=()
    local -a out=()
    local i=0

    IFS=',' read -r -a raw <<< "$value_csv"
    IFS=',' read -r -a fallback <<< "$fallback_csv"

    while [ "$i" -lt "$target" ]; do
        local item
        item="$(trim "${raw[$i]:-}")"
        if [ -z "$item" ]; then
            item="$(trim "${fallback[$i]:-}")"
        fi
        if [ -z "$item" ]; then
            item="i5"
        fi
        out+=("$item")
        i=$((i + 1))
    done

    (IFS=','; printf '%s' "${out[*]}")
}

load_defaults() {
    if [ ! -f "$CONFIG_FILE" ]; then
        return
    fi

    while IFS='=' read -r key value; do
        key="$(trim "$key")"
        value="$(trim "$value")"
        value="${value%%#*}"
        value="$(trim "$value")"

        [ -z "$key" ] && continue
        [[ "$key" == \#* ]] && continue

        case "$key" in
            WORKFLOW)
                if normalized_workflow="$(normalize_workflow "$value")"; then
                    WORKFLOW="$normalized_workflow"
                fi
                ;;
            DEFAULT_BATCH_COUNT)
                if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -gt 0 ]; then
                    DEFAULT_BATCH_COUNT="$value"
                fi
                ;;
            DEFAULT_BATCH_MODELS)
                if list="$(normalize_model_list "$value" "i6p,i6,i6,i5" "$DEFAULT_BATCH_COUNT")"; then
                    DEFAULT_BATCH_MODELS="$list"
                fi
                ;;
            DEFAULT_BATCH_AUTO)
                if [ "$value" = "0" ] || [ "$value" = "1" ]; then
                    DEFAULT_BATCH_AUTO="$value"
                fi
                ;;
            DEFAULT_QUEUE_MODELS)
                if list="$(normalize_model_list "$value" "$DEFAULT_BATCH_MODELS" "$QUEUE_SIZE")"; then
                    DEFAULT_QUEUE_MODELS="$list"
                fi
                ;;
            DEFAULT_QUEUE_WORKFLOWS)
                if list="$(normalize_workflow_list "$value")"; then
                    DEFAULT_QUEUE_WORKFLOWS="$list"
                fi
                ;;
        esac
    done < "$CONFIG_FILE"

    DEFAULT_QUEUE_MODELS="$(pad_csv "$DEFAULT_QUEUE_MODELS" "$DEFAULT_BATCH_MODELS" "$QUEUE_SIZE")"
    DEFAULT_QUEUE_WORKFLOWS="$(pad_csv "$DEFAULT_QUEUE_WORKFLOWS" "ask,ask,ask,ask" "$QUEUE_SIZE")"
    if list="$(normalize_workflow_list "$DEFAULT_QUEUE_WORKFLOWS")"; then
        DEFAULT_QUEUE_WORKFLOWS="$list"
    else
        DEFAULT_QUEUE_WORKFLOWS="ask,ask,ask,ask"
    fi

    if [ "$DEFAULT_BATCH_AUTO" != "0" ] && [ "$DEFAULT_BATCH_AUTO" != "1" ]; then
        DEFAULT_BATCH_AUTO=0
    fi
}

save_defaults() {
    DEFAULT_BATCH_MODELS="$(normalize_model_list "$DEFAULT_BATCH_MODELS" "i6p,i6,i6,i5" "$DEFAULT_BATCH_COUNT")"
    DEFAULT_QUEUE_MODELS="$(normalize_model_list "$DEFAULT_QUEUE_MODELS" "$DEFAULT_BATCH_MODELS" "$QUEUE_SIZE")"
    if ! list="$(normalize_workflow_list "$DEFAULT_QUEUE_WORKFLOWS")"; then
        list="ask,ask,ask,ask"
    fi
    DEFAULT_QUEUE_WORKFLOWS="$list"
    if ! WORKFLOW="$(normalize_workflow "$WORKFLOW")"; then
        WORKFLOW="ask"
    fi

    mkdir -p "$CONFIG_DIR"

    cat > "$CONFIG_FILE" <<EOF
WORKFLOW=$WORKFLOW
DEFAULT_BATCH_COUNT=$DEFAULT_BATCH_COUNT
DEFAULT_BATCH_MODELS=$DEFAULT_BATCH_MODELS
DEFAULT_BATCH_AUTO=$DEFAULT_BATCH_AUTO
DEFAULT_QUEUE_MODELS=$DEFAULT_QUEUE_MODELS
DEFAULT_QUEUE_WORKFLOWS=$DEFAULT_QUEUE_WORKFLOWS
EOF

    success "Defaults saved to: $CONFIG_FILE"
}

status_check() {
    echo ""
    info "Session status"

    local normal_count
    local normal_raw
    local queue_slot=0
    local queue_model
    local queue_wf
    normal_raw=$(connection_count)
    normal_count="$normal_raw"
    if [ "$normal_raw" = "n/a" ]; then
        normal_count="N/A"
    fi
    local dfu_state
    local dfu_label="no"
    dfu_state=$(connection_has_dfu)
    [ "$dfu_state" = "1" ] && dfu_label="yes"
    local auto_label="off"
    [ "$DEFAULT_BATCH_AUTO" -eq 1 ] && auto_label="on"

    echo "  ┌──────────────────────────────────────────────┐"
    printf "  │ %-44s │\n" "iCloud Unlock Controller"
    echo "  ├──────────────────────────────────────────────┤"
    printf "  │ Workflow: %-36s │\n" "$(workflow_label "$WORKFLOW")"
    printf "  │ Batch count: %-33s │\n" "$DEFAULT_BATCH_COUNT"
    printf "  │ Batch models: %-31s │\n" "$DEFAULT_BATCH_MODELS"
    printf "  │ Batch auto-continue: %-23s │\n" "$auto_label"
    printf "  │ Queue models: %-32s │\n" "$DEFAULT_QUEUE_MODELS"
    printf "  │ Queue workflows: %-29s │\n" "$DEFAULT_QUEUE_WORKFLOWS"
    echo "  ├──────────────────────────────────────────────┤"
    printf "  │ Queue plan (4-device):                        │\n"
    while [ "$queue_slot" -lt "$QUEUE_SIZE" ]; do
        queue_model="$(csv_value_at "$DEFAULT_QUEUE_MODELS" "$queue_slot")"
        queue_wf="$(csv_value_at "$DEFAULT_QUEUE_WORKFLOWS" "$queue_slot")"
        printf "  │  [%d] %-4s %-7s %-11s │\n" \
            "$((queue_slot + 1))" \
            "$queue_model" \
            "$(workflow_label_short "$queue_wf")"
        queue_slot=$((queue_slot + 1))
    done
    echo "  ├──────────────────────────────────────────────┤"
    printf "  │ idevice_id: %-34s │\n" "$(dependency_state idevice_id)"
    printf "  │ Normal devices connected: %-18s │\n" "$normal_count"
    printf "  │ DFU/Recovery present: %-17s │\n" "$dfu_label"
    printf "  │ Script path: %-31s │\n" "$SCRIPT_DIR"
    echo "  └──────────────────────────────────────────────┘"

    if [ "$normal_raw" = "n/a" ]; then
        echo "  - connected device count unavailable (missing idevice_id)"
    elif [ "$normal_raw" -gt 0 ]; then
        echo ""
        info "Connected normal-mode devices:"
        idevice_id -l | sed 's/^/  - /'
    else
        echo "  - none in normal mode"
    fi

    [ "$dfu_state" = "1" ] && echo "  - DFU/Recovery device present"
    echo ""
}

recent_log_panel() {
    local log_file="$LOG_FILE"
    local max_lines="$LOG_PANEL_LINES"
    local count=0
    local ts="------"
    local msg=""
    local time_expr=""
    local tag="LOG"
    local raw_msg=""
    local padded_msg=""

    echo "  ┌──────────────────────────────────────────────┐"
    echo "  │ Recent run log (compact)                     │"
    echo "  ├──────────────────────────────────────────────┤"

    if [ ! -f "$log_file" ] || [ ! -s "$log_file" ]; then
        echo "  │ (no log entries yet)                        │"
        echo "  └──────────────────────────────────────────────┘"
        return
    fi

    while IFS= read -r line; do
        count=$((count + 1))
        [ "$count" -gt "$max_lines" ] && break

        ts="------"
        msg="$line"
        time_expr=""
        tag="LOG"
        if [[ "$line" =~ ^\[([0-9]{2}:[0-9]{2}:[0-9]{2})\] ]]; then
            time_expr="${BASH_REMATCH[1]}"
            raw_msg="$(printf '%s' "$line" | sed -E 's/^\[[^]]*\] //')"
            msg="$raw_msg"
        elif [[ "$line" =~ ^\[([0-9]{4}-[0-9]{2}-[0-9]{2})\ ([0-9]{2}:[0-9]{2}:[0-9]{2})\] ]]; then
            time_expr="${BASH_REMATCH[2]}"
            raw_msg="$(printf '%s' "$line" | sed -E 's/^\[[^]]*\] //')"
            msg="$raw_msg"
        fi
        [ -n "$time_expr" ] && ts="$time_expr"
        if [ -z "$msg" ] || [ "$msg" = "$line" ]; then
            msg="$line"
        fi

        case "$msg" in
            SUCCESS:*)
                tag="OK"
                msg="${msg#SUCCESS: }"
                ;;
            WARN:*)
                tag="WRN"
                msg="${msg#WARN: }"
                ;;
            FAIL:*)
                tag="ERR"
                msg="${msg#FAIL: }"
                ;;
            "=== Session started ==="|*Batch\ start*|*Batch\ end*|*batch\ start*|*batch\ end*)
                tag="RUN"
                msg="${msg#=== }"
                ;;
        esac

        padded_msg="$(compact_text "$msg" 31)"
        printf "  │ %-3s %8s %-31s │\n" "$tag" "$ts" "$padded_msg"
    done < <(tail -n "$max_lines" "$log_file")

    while [ "$count" -lt "$max_lines" ]; do
        count=$((count + 1))
        echo "  │                                            │"
    done

    echo "  └──────────────────────────────────────────────┘"
}

run_batch() {
    local count="$DEFAULT_BATCH_COUNT"
    local models="$DEFAULT_BATCH_MODELS"
    local auto=""
    local workflow="ask"
    local interactive=0
    local args=("$@")
    local i=0

    if [ "${args[0]:-}" = "ask" ]; then
        interactive=1
        args=("${args[@]:1}")
    fi

    while [ $i -lt "${#args[@]}" ]; do
        case "${args[$i]}" in
            --count)
                i=$((i + 1))
                if [ $i -ge "${#args[@]}" ]; then
                    error "Missing value for --count."
                    return 1
                fi
                count="${args[$i]}"
                ;;
            --models)
                i=$((i + 1))
                if [ $i -ge "${#args[@]}" ]; then
                    error "Missing value for --models."
                    return 1
                fi
                models="${args[$i]}"
                ;;
            --auto)
                auto="--auto"
                ;;
            --workflow)
                i=$((i + 1))
                if [ $i -ge "${#args[@]}" ]; then
                    error "Missing value for --workflow."
                    workflow="ask"
                else
                    if ! workflow="$(normalize_workflow "${args[$i]}")"; then
                        error "Invalid workflow: ${args[$i]}"
                        workflow="ask"
                    fi
                fi
                ;;
        esac
        i=$((i + 1))
    done

    if ! workflow="$(normalize_workflow "$workflow")"; then
        error "Invalid workflow: $workflow"
        workflow="ask"
    fi

    if [ "$interactive" -eq 1 ]; then
        read -r -p "  Number of devices [$count]: " input
        [ -n "${input:-}" ] && count="$input"
        read -r -p "  Model sequence [$models]: " input
        [ -n "${input:-}" ] && models="$input"
        read -r -p "  Continue on failures automatically? (y/n): " cont
        [ "${cont:-n}" = "y" ] && auto="--auto"

        local wf_default=""
        case "$workflow" in
            unlock)
                wf_default="1"
                ;;
            reset)
                wf_default="2"
                ;;
            ask)
                wf_default="ask"
                ;;
            *)
                wf_default="1"
                ;;
        esac

        read -r -p "  Flow (1=unlock,2=reset,ask=prompt each) [$wf_default]: " wf_input
        wf_input="${wf_input:-$wf_default}"
        if ! workflow="$(normalize_workflow "$wf_input")"; then
            warn "Invalid selection. Defaulting to ask."
            workflow="ask"
        fi

        read -r -p "  Save this batch setup as defaults? (y/n): " save_defaults_input
        if [ "${save_defaults_input:-n}" = "y" ]; then
            DEFAULT_BATCH_COUNT="$count"
            DEFAULT_BATCH_MODELS="$models"
            WORKFLOW="$workflow"
            if [ "$auto" = "--auto" ]; then
                DEFAULT_BATCH_AUTO=1
            else
                DEFAULT_BATCH_AUTO=0
            fi
            save_defaults
        fi
    else
        info "Workflow set to: $(workflow_label "$workflow")"
    fi

    [ -z "$count" ] && count="$DEFAULT_BATCH_COUNT"
    [ -z "$models" ] && models="$DEFAULT_BATCH_MODELS"

    if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -lt 1 ]; then
        warn "Invalid device count: $count. Using default $DEFAULT_BATCH_COUNT."
        count="$DEFAULT_BATCH_COUNT"
    fi

    info "Launching batch: count=$count, workflow=$(workflow_label "$workflow"), models=$models"
    [ "$auto" = "--auto" ] && info "Auto-continue: enabled"

    local batch_args=(bash "$SCRIPT_DIR/batch.sh" --count "$count" --models "$models" --workflow "$workflow")
    [ -n "$auto" ] && batch_args+=("$auto")
    "${batch_args[@]}"
}

run_batch_defaults() {
    local args=(--count "$DEFAULT_BATCH_COUNT" --models "$DEFAULT_BATCH_MODELS")
    [ "$DEFAULT_BATCH_AUTO" -eq 1 ] && args+=(--auto)
    [ "$WORKFLOW" != "ask" ] && args+=(--workflow "$WORKFLOW")
    run_batch "${args[@]}"
}

run_queue() {
    local models="${1:-$DEFAULT_QUEUE_MODELS}"
    local workflows="${2:-$DEFAULT_QUEUE_WORKFLOWS}"
    local force_auto="${3:-}"
    local normalized_models=""
    local queue_slot=0
    local queue_model
    local queue_wf

    if ! normalized_models="$(normalize_model_list "$models" "$DEFAULT_BATCH_MODELS" "$QUEUE_SIZE")"; then
        normalized_models="$DEFAULT_BATCH_MODELS"
    fi
    models="$normalized_models"
    workflows="$(pad_csv "$workflows" "ask,ask,ask,ask" "$QUEUE_SIZE")"

    if ! workflows="$(normalize_workflow_list "$workflows")"; then
        warn "Invalid queue workflows found. Falling back to ask for all 4."
        workflows="ask,ask,ask,ask"
    fi

    echo "  ┌──────────────────────────────────────────────┐"
    echo "  │         4-Device Queue Plan                 │"
    echo "  ├──────────────────────────────────────────────┤"
    while [ "$queue_slot" -lt "$QUEUE_SIZE" ]; do
        queue_model="$(csv_value_at "$models" "$queue_slot")"
        queue_wf="$(csv_value_at "$workflows" "$queue_slot")"
        printf "  │  Slot %d | %-4s | %s │\n" \
            "$((queue_slot + 1))" \
            "$queue_model" \
            "$(workflow_label_short "$queue_wf")"
        queue_slot=$((queue_slot + 1))
    done
    echo "  └──────────────────────────────────────────────┘"

    local batch_args=(bash "$SCRIPT_DIR/batch.sh" --count "$QUEUE_SIZE" --models "$models" --workflows "$workflows" --queue)
    if [ "$force_auto" = "--auto" ] || [ "$DEFAULT_BATCH_AUTO" -eq 1 ]; then
        batch_args+=(--auto)
        info "Auto-continue: enabled"
    fi

    info "Running queued 4-device flow: models=$models, workflows=$workflows"

    "${batch_args[@]}"
}

configure_defaults() {
    local default_workflow="$WORKFLOW"
    local default_count="$DEFAULT_BATCH_COUNT"
    local default_models="$DEFAULT_BATCH_MODELS"
    local default_auto_text="n"

    if [ "$DEFAULT_BATCH_AUTO" -eq 1 ]; then
        default_auto_text="y"
    fi

    echo ""
    info "Session defaults"
    echo "  Current defaults: $(workflow_label "$WORKFLOW") / count=$DEFAULT_BATCH_COUNT / auto=$default_auto_text"

    local input
    read -r -p "  Workflow [${WORKFLOW}]: " input
    if [ -n "$input" ]; then
        if ! default_workflow="$(normalize_workflow "$input")"; then
            warn "Invalid workflow: $input. Keeping current."
            default_workflow="$WORKFLOW"
        fi
    fi

    read -r -p "  Batch count [$DEFAULT_BATCH_COUNT]: " input
    if [ -n "$input" ]; then
        default_count="$input"
    fi
    if ! [[ "$default_count" =~ ^[0-9]+$ ]] || [ "$default_count" -lt 1 ]; then
        warn "Invalid count: $default_count. Keeping current."
        default_count="$DEFAULT_BATCH_COUNT"
    fi

    read -r -p "  Batch model sequence [$DEFAULT_BATCH_MODELS]: " input
    [ -n "$input" ] && default_models="$input"
    if ! list="$(normalize_model_list "$default_models" "i6p,i6,i6,i5" "$default_count")"; then
        list="i6p,i6,i6,i5"
    fi
    default_models="$list"

    read -r -p "  Auto-continue on failures? (y/n) [$default_auto_text]: " input
    [ -z "$input" ] && input="$default_auto_text"
    if [ "$input" = "y" ]; then
        DEFAULT_BATCH_AUTO=1
    else
        DEFAULT_BATCH_AUTO=0
    fi

    WORKFLOW="$default_workflow"
    DEFAULT_BATCH_COUNT="$default_count"
    DEFAULT_BATCH_MODELS="$default_models"

    DEFAULT_QUEUE_MODELS="$(pad_csv "$DEFAULT_QUEUE_MODELS" "$DEFAULT_BATCH_MODELS" "$QUEUE_SIZE")"
    save_defaults

    success "Defaults updated and saved."
}

configure_queue() {
    local queue_models="$DEFAULT_QUEUE_MODELS"
    local queue_workflows="$DEFAULT_QUEUE_WORKFLOWS"
    local -a q_models=()
    local -a q_workflows=()
    local i=0

    echo ""
    info "4-Device Queue Setup"
    echo "  Defaults apply to --mode queue runs."

    while [ "$i" -lt "$QUEUE_SIZE" ]; do
        local slot=$((i + 1))
        local model_default
        local workflow_default
        local model_input
        local workflow_input

        model_default="$(csv_value_at "$queue_models" "$i")"
        workflow_default="$(csv_value_at "$queue_workflows" "$i")"

        if [ -z "$model_default" ]; then
            model_default="$(csv_value_at "$DEFAULT_BATCH_MODELS" "$i")"
        fi
        [ -z "$workflow_default" ] && workflow_default="ask"

        read -r -p "  Device #$slot model [${model_default}]: " model_input
        if [ -n "$model_input" ]; then
            model_default="$model_input"
        fi
        model_default="$(normalize_model "$model_default")"

        read -r -p "  Device #$slot workflow (1=unlock,2=reset,ask=prompt each) [${workflow_default}]: " workflow_input
        if [ -n "$workflow_input" ]; then
            if ! workflow_default="$(normalize_workflow "$workflow_input")"; then
                warn "Invalid workflow for slot #$slot; keeping current."
            fi
        else
            if ! workflow_default="$(normalize_workflow "$workflow_default")"; then
                workflow_default="ask"
            fi
        fi

        q_models+=("$model_default")
        q_workflows+=("$workflow_default")
        i=$((i + 1))
    done

    DEFAULT_QUEUE_MODELS="$(IFS=','; printf '%s' "${q_models[*]}")"
    DEFAULT_QUEUE_WORKFLOWS="$(IFS=','; printf '%s' "${q_workflows[*]}")"

    save_defaults
    success "Queue defaults updated and saved."
}

launch_mode() {
    local mode="$1"
    local workflow="${2:-ask}"
    local common_args=()

    if [ -n "$workflow" ] && [ "$workflow" != "ask" ]; then
        common_args+=(--workflow "$workflow")
    fi

    case "$mode" in
        setup)
            bash "$SCRIPT_DIR/setup.sh"
            ;;
        unlock)
            bash "$SCRIPT_DIR/unlock.sh" "${common_args[@]}"
            ;;
        batch)
            run_batch "${common_args[@]}" ask
            ;;
        queue)
            run_queue
            ;;
        reboot)
            bash "$SCRIPT_DIR/reboot.sh"
            ;;
        status)
            status_check
            ;;
        *)
            fail "Unknown mode: $mode"
            usage
            return 1
            ;;
    esac
}

run_menu() {
    while true; do
        echo ""
        echo "  ╔══════════════════════════════════════════╗"
        echo "  ║      iCloud Unlock Controller          ║"
        echo "  ║      Productivity Mode                  ║"
        echo "  ╚══════════════════════════════════════════╝"

        status_check
        recent_log_panel

        echo ""
        echo "  DEVICE ACTIONS"
        echo "  1) Setup dependencies"
        echo "  2) Configure session defaults"
        echo "  3) Configure 4-device queue"
        echo "  4) Run queued workflow now"
        echo "  5) Unlock one device"
        echo "  6) Batch unlock (guided)"
        echo "  7) Batch unlock (defaults)"
        echo "  8) Reboot a bypassed device"
        echo "  9) Check connection status"
        echo "  10) Exit"
        echo ""
        read -r -p "  Select 1-10: " choice

        case "$choice" in
            1)
                bash "$SCRIPT_DIR/setup.sh"
                ;;
            2)
                configure_defaults
                ;;
            3)
                configure_queue
                ;;
            4)
                run_queue
                ;;
            5)
                local unlock_cmd=(bash "$SCRIPT_DIR/unlock.sh")
                [ -n "$WORKFLOW" ] && unlock_cmd+=(--workflow "$WORKFLOW")
                "${unlock_cmd[@]}"
                ;;
            6)
                if [ "$WORKFLOW" = "ask" ]; then
                    run_batch ask
                else
                    run_batch --workflow "$WORKFLOW"
                fi
                ;;
            7)
                run_batch_defaults
                ;;
            8)
                bash "$SCRIPT_DIR/reboot.sh"
                ;;
            9)
                status_check
                ;;
            10)
                break
                ;;
            *)
                warn "Invalid choice: $choice"
                ;;
        esac
    done
}

load_defaults

if [ "$#" -eq 0 ]; then
    if [ ! -t 0 ]; then
        status_check
        recent_log_panel
        echo ""
        warn "manage.sh requires an interactive terminal for menu mode."
        echo "  Try: bash manage.sh --mode <setup|unlock|batch|queue|reboot|status>"
        exit 1
    fi

    run_menu
    exit 0
fi

MODE=""
COUNT=""
MODELS=""
QUEUE_MODELS=""
QUEUE_WORKFLOWS=""
AUTO=""

while [ "$#" -gt 0 ]; do
    case "${1:-}" in
        --mode)
            if [ "$#" -lt 2 ]; then
                usage
                exit 1
            fi
            MODE="${2:-}"
            shift 2
            ;;
        --count)
            if [ "$#" -lt 2 ]; then
                usage
                exit 1
            fi
            COUNT="${2:-4}"
            shift 2
            ;;
        --models)
            if [ "$#" -lt 2 ]; then
                usage
                exit 1
            fi
            MODELS="${2:-}"
            shift 2
            ;;
        --queue-models)
            if [ "$#" -lt 2 ]; then
                usage
                exit 1
            fi
            QUEUE_MODELS="${2:-}"
            shift 2
            ;;
        --queue-workflows)
            if [ "$#" -lt 2 ]; then
                usage
                exit 1
            fi
            QUEUE_WORKFLOWS="${2:-}"
            shift 2
            ;;
        --auto)
            AUTO="--auto"
            shift
            ;;
        --workflow)
            if [ "$#" -lt 2 ]; then
                usage
                exit 1
            fi
            WORKFLOW="$(normalize_workflow "${2:-}")" || {
                error "Invalid workflow: ${2:-}"
                usage
                exit 1
            }
            shift 2
            ;;
        --factory-reset)
            WORKFLOW="reset"
            shift
            ;;
        --bypass)
            WORKFLOW="unlock"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

if [ -n "$MODE" ]; then
    if [ "$MODE" = "batch" ]; then
        batch_args=(bash "$SCRIPT_DIR/batch.sh")
        [ -n "$COUNT" ] && batch_args+=(--count "$COUNT")
        [ -n "$MODELS" ] && batch_args+=(--models "$MODELS")
        [ -n "$WORKFLOW" ] && batch_args+=(--workflow "$WORKFLOW")
        [ -n "$AUTO" ] && batch_args+=("$AUTO")
        "${batch_args[@]}"
    elif [ "$MODE" = "queue" ]; then
        run_queue "${QUEUE_MODELS:-$DEFAULT_QUEUE_MODELS}" "${QUEUE_WORKFLOWS:-$DEFAULT_QUEUE_WORKFLOWS}" "$AUTO"
    else
        launch_mode "$MODE" "$WORKFLOW"
    fi
    exit 0
fi

usage
