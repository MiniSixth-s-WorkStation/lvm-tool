#!/bin/bash

# ==============================================================================
# Module Name: create.sh
# Description: Handles the creation of a new set of LVM snapshots.
# Description (zh_TW): 處理建立一組新的 LVM 快照。
# ==============================================================================

# --- Command Definition ---
# --- 指令定義 ---
COMMAND="create"
DESCRIPTION="Create a new set of snapshots for all configured LVs."
DESCRIPTION_ZH="為所有已設定的 LV 建立一組新的快照。"

# --- Function: cleanup_snapshots ---
# --- 功能: cleanup_snapshots ---
# Description: Clean up snapshots if creation fails.
# Description (zh_TW): 如果建立快照失敗，則清理快照。
# Arguments: $1 - Timestamp of the failed group
# Arguments (zh_TW): $1 - 失敗群組的時間戳記
cleanup_snapshots() {
    local ts="$1"
    local reason=${2:-"Unknown error"}
    print_warning "$(printf "$MSG_CLEANUP_SNAPSHOTS" "$reason" "$ts")"
    log_action "WARN" "Cleanup triggered for timestamp ${ts} due to: ${reason}"
    for lv_name in "${!LV_CONFIG[@]}"; do
        local snapshot_name="${lv_name}_${SNAPSHOT_PREFIX}_${ts}"
        if lvs "/dev/${VG_NAME}/${snapshot_name}" >/dev/null 2>&1; then
            print_info "Removing snapshot: ${snapshot_name}"
            if lvremove -f "/dev/${VG_NAME}/${snapshot_name}"; then
                log_action "INFO" "Snapshot '${snapshot_name}' cleaned up successfully."
            else
                log_action "ERROR" "Failed to clean up snapshot '${snapshot_name}'."
            fi
        fi
    done
}

# --- Function: command_main ---
# --- 功能: command_main ---
# Description: Main function for the 'create' command.
# Description (zh_TW): 'create' 指令的主功能。
command_main() {
    local TIMESTAMP
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    trap 'cleanup_snapshots "${TIMESTAMP}" "Creation failed"' ERR
    
    execute_hook "$PRE_CREATE_HOOK" "pre-create" "$TIMESTAMP"
    
    print_info "$(printf "$MSG_PREPARING_TO_CREATE_SNAPSHOTS" "$TIMESTAMP")"

    if ! vgs "${VG_NAME}" >/dev/null 2>&1; then
        print_error "$(printf "$MSG_VG_NOT_EXIST_ERROR" "$VG_NAME")"
        exit 1
    fi

    local TOTAL_REQUIRED_MB=0
    for lv_name in "${!LV_CONFIG[@]}"; do
        if ! check_lv_exists "${lv_name}"; then
            print_error "$(printf "$MSG_LV_NOT_EXIST_ERROR" "$lv_name")"
            exit 1
        fi
        
        local size
        size=$(echo "${LV_CONFIG[$lv_name]}" | cut -d'|' -f1)
        if [[ -z "$size" ]]; then
            print_error "$(printf "$MSG_SNAPSHOT_SIZE_UNDEFINED" "$lv_name")"
            exit 1
        fi

        local SIZE_MB
        if ! SIZE_MB=$(size_to_mb "$size"); then
            # Error message is printed inside size_to_mb
            exit 1
        fi
        TOTAL_REQUIRED_MB=$((TOTAL_REQUIRED_MB + SIZE_MB))
    done

    local VFREE_MB
    VFREE_MB=$(vgs "${VG_NAME}" --noheadings --units m -o vg_free | sed 's/[^0-9.]//g' | cut -d. -f1)
    local REQUIRED_WITH_BUFFER=$((TOTAL_REQUIRED_MB + SPACE_BUFFER_MB))

    print_info "$(printf "$MSG_SPACE_REQUIRED" "$TOTAL_REQUIRED_MB" "$SPACE_BUFFER_MB" "$REQUIRED_WITH_BUFFER" "$VFREE_MB")"
    if (( VFREE_MB < REQUIRED_WITH_BUFFER )); then
        print_error "$(printf "$MSG_INSUFFICIENT_SPACE" "$VG_NAME")"
        log_action "ERROR" "VG '${VG_NAME}' has insufficient space. Required: ${REQUIRED_WITH_BUFFER}MB, Available: ${VFREE_MB}MB."
        exit 1
    fi
    
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo "$MSG_SNAPSHOTS_TO_BE_CREATED"
    echo -e "${BLUE}==========================================${NC}"
    for lv_name in "${!LV_CONFIG[@]}"; do
        local size
        size=$(echo "${LV_CONFIG[$lv_name]}" | cut -d'|' -f1)
        echo "  ${lv_name} -> ${lv_name}_${SNAPSHOT_PREFIX}_${TIMESTAMP} (${size})"
    done
    echo -e "${BLUE}==========================================${NC}"
    echo ""
    
    if [[ "$FORCE_MODE" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
        read -p "$MSG_CONTINUE_PROMPT" -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_warning "$MSG_OPERATION_CANCELLED_BY_USER"
            log_action "INFO" "Snapshot creation cancelled by user."
            exit 0
        fi
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        print_info "--- Dry Run Mode ---"
        print_success "$MSG_SIMULATED_SNAPSHOT_CREATION_COMPLETE"
        log_action "INFO" "[DryRun] Simulated snapshot creation for timestamp ${TIMESTAMP}."
        return
    fi

    log_action "INFO" "$(printf "$MSG_STARTING_SNAPSHOT_CREATION" "$TIMESTAMP")"
    
    local SUCCESS_COUNT=0
    for lv_name in "${!LV_CONFIG[@]}"; do
        local size
        size=$(echo "${LV_CONFIG[$lv_name]}" | cut -d'|' -f1)
        local snapshot_name="${lv_name}_${SNAPSHOT_PREFIX}_${TIMESTAMP}"
        local origin_path="/dev/${VG_NAME}/${lv_name}"
        
        print_info "$(printf "$MSG_CREATING_SNAPSHOT_FOR" "$origin_path" "$snapshot_name" "$size")"
        if lvcreate -s -L "${size}" -n "${snapshot_name}" "${origin_path}"; then
            print_success "$(printf "$MSG_SNAPSHOT_CREATED_SUCCESS" "$snapshot_name")"
            log_action "SUCCESS" "Snapshot '${snapshot_name}' created successfully."
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            print_error "$(printf "$MSG_FAILED_TO_CREATE_SNAPSHOT" "$snapshot_name")"
            log_action "ERROR" "Failed to create snapshot '${snapshot_name}'."
            exit 1
        fi
    done
    
    trap - ERR

    echo ""
    echo -e "${GREEN}===========================================================${NC}"
    print_success "$MSG_SNAPSHOT_GROUP_CREATED_SUCCESS"
    echo -e "${GREEN}===========================================================${NC}"
    echo "$(printf "$MSG_TIMESTAMP" "$TIMESTAMP")"
    echo "$(printf "$MSG_SUCCESSFULLY_CREATED_COUNT" "$SUCCESS_COUNT")"
    echo ""
    echo "$MSG_SNAPSHOT_LIST"
    echo "-----------------------------------------------------------"
    lvs -o lv_name,lv_size,origin,snap_percent --units g | grep "_${SNAPSHOT_PREFIX}_${TIMESTAMP}" || true
    echo "==========================================================="
    
    execute_hook "$POST_CREATE_HOOK" "post-create" "$TIMESTAMP"
    update_completion_cache
}