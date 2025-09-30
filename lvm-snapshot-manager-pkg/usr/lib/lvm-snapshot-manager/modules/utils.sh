#!/bin/bash

# ==============================================================================
# Module Name: utils.sh
# Description: Contains utility commands like purge, extend, and setup-logrotate.
# Description (zh_TW): 包含 purge, extend, setup-logrotate 等工具指令。
# ==============================================================================

# --- Command Definitions ---
# --- 指令定義 ---
COMMAND_PURGE="purge"
DESCRIPTION_PURGE="Purge old snapshots based on specified criteria."
DESCRIPTION_PURGE_ZH="根據指定條件清除舊快照。"

COMMAND_EXTEND="extend"
DESCRIPTION_EXTEND="Extend the size of an existing snapshot."
DESCRIPTION_EXTEND_ZH="擴充現有快照的大小。"

COMMAND_SETUP_LOGROTATE="setup-logrotate"
DESCRIPTION_SETUP_LOGROTATE="Create a logrotate configuration file template."
DESCRIPTION_SETUP_LOGROTATE_ZH="建立 logrotate 設定檔範本。"

# --- Function: command_purge ---
# --- 功能: command_purge ---
# Description: Purge old snapshots based on command-line arguments.
# Description (zh_TW): 根據命令列參數清除舊快照。
command_purge() {
    local keep_last=""
    local older_than=""

    # Reparsing arguments passed to the module function
    local args=("$@")
    
    if [[ "${args[0]}" == "--help" ]]; then
        echo "Usage: $(basename $0) purge [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --keep-last <N>     Keep the N most recent snapshot groups."
        echo "  --older-than <AGE>  Delete snapshot groups older than AGE (e.g., 7d, 4w, 1m)."
        return
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --keep-last)
                keep_last="$2"
                shift 2
                ;;
            --older-than)
                older_than="$2"
                shift 2
                ;;
            *)
                # This case should ideally not be hit if main parser works correctly
                shift
                ;;
        esac
    done

    if [[ -z "$keep_last" && -z "$older_than" ]]; then
        print_error "Purge command requires at least one argument. Use 'purge --help' for details."
        return 1
    fi

    log_action "INFO" "Starting snapshot purge (keep-last: ${keep_last:-none}, older-than: ${older_than:-none})."
    
    local all_timestamps
    all_timestamps=$(lvs --noheadings -o lv_name 2>/dev/null | grep "_${SNAPSHOT_PREFIX}_" | sed "s/.*_${SNAPSHOT_PREFIX}_//" | sort -r | uniq)
    
    if [[ -z "$all_timestamps" ]]; then
        print_info "$MSG_NO_SNAPSHOTS_TO_PURGE"
        return
    fi

    local timestamps_to_delete=()
    local timestamps_to_keep_by_age=()

    if [[ -n "$older_than" ]]; then
        local seconds
        local unit="${older_than: -1}"
        local value="${older_than%?}"
        case "$unit" in
            d) seconds=$((value * 86400)) ;;
            w) seconds=$((value * 604800)) ;;
            m) seconds=$((value * 2592000)) ;;
            *) print_error "Invalid time unit for --older-than. Use d, w, or m."; return 1 ;;
        esac
        
        local cutoff
        cutoff=$(date -d "-$seconds seconds" +%s)
        
        while IFS= read -r ts; do
            local snap_date
            snap_date=$(echo "$ts" | sed 's/_/ /')
            local snap_time
            snap_time=$(date -d "$snap_date" +%s)
            if (( snap_time < cutoff )); then
                timestamps_to_delete+=("$ts")
            else
                timestamps_to_keep_by_age+=("$ts")
            fi
        done <<< "$all_timestamps"
    else
        timestamps_to_keep_by_age=($all_timestamps)
    fi

    if [[ -n "$keep_last" ]]; then
        local timestamps_to_keep_by_count=()
        mapfile -t timestamps_to_keep_by_count < <(printf "%s\n" "${timestamps_to_keep_by_age[@]}" | head -n "$keep_last")
        
        local temp_delete=()
        for ts in "${timestamps_to_keep_by_age[@]}"; do
            if ! [[ " ${timestamps_to_keep_by_count[*]} " =~ " ${ts} " ]]; then
                temp_delete+=("$ts")
            fi
        done
        timestamps_to_delete+=( "${temp_delete[@]}" )
    fi

    # Remove duplicates
    # 移除重複項目
    timestamps_to_delete=($(printf "%s\n" "${timestamps_to_delete[@]}" | sort -u))

    if [[ ${#timestamps_to_delete[@]} -eq 0 ]]; then
        print_success "$MSG_PURGE_NOTHING_TO_DO"
        log_action "INFO" "Purge complete. No snapshots met the criteria for deletion."
        return
    fi

    echo ""
    print_warning "$MSG_PURGE_WARNING"
    echo "--------------------------------------------------"
    for ts in "${timestamps_to_delete[@]}"; do
        echo "  - $ts"
    done
    echo "--------------------------------------------------"
    echo ""

    if [[ "$FORCE_MODE" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
        read -p "$MSG_CONTINUE_PROMPT" -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "$MSG_OPERATION_CANCELLED"
            log_action "INFO" "Snapshot purge cancelled by user."
            return
        fi
    fi

    local original_force_mode=$FORCE_MODE
    if [[ "$DRY_RUN" -eq 0 ]]; then
        FORCE_MODE=1
    fi

    # Source the delete module to use its function
    source "${LIB_DIR}/modules/delete.sh"
    for ts in "${timestamps_to_delete[@]}"; do
        command_delete_group "$ts"
    done

    FORCE_MODE=$original_force_mode

    print_success "$MSG_PURGE_COMPLETE"
}

# --- Function: command_extend ---
# --- 功能: command_extend ---
# Description: Extend the size of an existing snapshot.
# Description (zh_TW): 擴充現有快照的大小。
# Arguments: $1 - Snapshot name, $2 - Size to add (e.g., 1G)
# Arguments (zh_TW): $1 - 快照名稱, $2 - 要增加的大小 (例如 1G)
command_extend() {
    local snapshot_name="$1"
    local extend_size="$2"

    if [[ -z "$snapshot_name" || -z "$extend_size" ]]; then
        print_error "Usage: $(basename $0) extend <snapshot_name> <size>"
        return 1
    fi

    if ! check_lv_exists "${snapshot_name}"; then
        print_error "Snapshot '${snapshot_name}' does not exist."
        return 1
    fi

    print_info "Extending snapshot '${snapshot_name}' by ${extend_size}..."
    if [[ "$DRY_RUN" -eq 1 ]]; then
        print_info "[DryRun] Would run: lvextend -L+\"${extend_size}\" \"/dev/${VG_NAME}/${snapshot_name}\""
        print_success "Simulated snapshot extension complete."
        return
    fi

    if lvextend -L+"${extend_size}" "/dev/${VG_NAME}/${snapshot_name}"; then
        print_success "Snapshot '${snapshot_name}' extended successfully."
        log_action "SUCCESS" "Snapshot '${snapshot_name}' extended by ${extend_size}."
    else
        print_error "Failed to extend snapshot '${snapshot_name}'."
        log_action "ERROR" "Failed to extend snapshot '${snapshot_name}'."
        return 1
    fi
}

# --- Function: command_setup_logrotate ---
# --- 功能: command_setup_logrotate ---
# Description: Create a logrotate configuration file.
# Description (zh_TW): 建立 logrotate 設定檔。
command_setup_logrotate() {
    local logrotate_conf="/etc/logrotate.d/lvm-snapshot-manager"
    print_info "Creating logrotate configuration template..."
    
    if [[ -f "$logrotate_conf" ]]; then
        print_warning "File '$logrotate_conf' already exists."
        read -p "Overwrite? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Operation cancelled."
            return
        fi
    fi

    local content
    content=$(cat <<'EOF'
/var/log/lvm-snapshot-manager.log {
    weekly
    missingok
    rotate 4
    compress
    delaycompress
    notifempty
    create 640 root adm
}
EOF
)
    
    if echo "$content" > "$logrotate_conf"; then
        print_success "Logrotate config '$logrotate_conf' created successfully."
        print_info "Please review the file to ensure it meets your needs."
    else
        print_error "Could not write to '$logrotate_conf'. Check permissions."
    fi
}