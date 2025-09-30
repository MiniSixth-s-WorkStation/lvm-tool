#!/bin/bash

# ==============================================================================
# Module Name: delete.sh
# Description: Handles deletion of single snapshots or entire snapshot groups.
# Description (zh_TW): 處理刪除單一快照或整個快照群組。
# ==============================================================================

# --- Command Definition ---
# --- 指令定義 ---
COMMAND="delete"
DESCRIPTION="Delete a specific snapshot."
DESCRIPTION_ZH="刪除指定的快照。"

COMMAND_DELETE_GROUP="delete-group"
DESCRIPTION_DELETE_GROUP="Delete an entire snapshot group by timestamp."
DESCRIPTION_DELETE_GROUP_ZH="按時間戳記刪除整個快照群組。"

# --- Function: command_main ---
# --- 功能: command_main ---
# Description: Main function for the 'delete' command.
# Description (zh_TW): 'delete' 指令的主功能。
# Arguments: $1 - Snapshot name
# Arguments (zh_TW): $1 - 快照名稱
command_main() {
    local snapshot_name="$1"
    if [[ -z "$snapshot_name" ]]; then
        print_error "Please provide a snapshot name."
        echo "Usage: sudo $(basename $0) delete <snapshot_name>"
        echo ""
        echo "Available snapshots:"
        lvs --noheadings -o lv_name 2>/dev/null | grep "_${SNAPSHOT_PREFIX}_" | sed 's/^[[:space:]]*/  /'
        return 1
    fi
    
    if ! check_lv_exists "${snapshot_name}"; then
        print_error "Snapshot '${snapshot_name}' does not exist."
        return 1
    fi
    
    echo -e "${YELLOW}Preparing to delete snapshot: ${snapshot_name}${NC}"
    echo "Snapshot details:"
    lvs -o lv_name,origin,lv_size,snap_percent "/dev/${VG_NAME}/${snapshot_name}"
    echo ""
    
    if [[ "$FORCE_MODE" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
        read -p "Confirm deletion? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Operation cancelled."
            log_action "INFO" "Deletion of snapshot '${snapshot_name}' cancelled by user."
            return
        fi
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        print_info "--- Dry Run Mode ---"
        print_success "Simulated deletion of snapshot '${snapshot_name}'."
        log_action "INFO" "[DryRun] Simulated deletion of snapshot '${snapshot_name}'."
        return
    fi

    log_action "WARN" "Attempting to delete snapshot '${snapshot_name}'."
    local cmd_args=()
    if [[ "$FORCE_MODE" -eq 1 ]]; then
        cmd_args+=("-f")
    fi

    if lvremove "${cmd_args[@]}" "/dev/${VG_NAME}/${snapshot_name}"; then
        print_success "Snapshot '${snapshot_name}' has been deleted."
        log_action "SUCCESS" "Snapshot '${snapshot_name}' deleted successfully."
    else
        print_error "Failed to delete snapshot."
        log_action "ERROR" "Failed to delete snapshot '${snapshot_name}'."
    fi
}

# --- Function: command_delete_group ---
# --- 功能: command_delete_group ---
# Description: Main function for the 'delete-group' command.
# Description (zh_TW): 'delete-group' 指令的主功能。
# Arguments: $1 - Timestamp
# Arguments (zh_TW): $1 - 時間戳記
command_delete_group() {
    local timestamp="$1"
    if [[ -z "$timestamp" ]]; then
        print_error "Please provide a timestamp."
        echo "Usage: sudo $(basename $0) delete-group <timestamp>"
        echo ""
        echo "Available timestamps:"
        lvs --noheadings -o lv_name 2>/dev/null | grep "_${SNAPSHOT_PREFIX}_" | sed "s/.*_${SNAPSHOT_PREFIX}_//" | sort -u | sed 's/^/  /'
        return 1
    fi
    
    local SNAPSHOTS
    SNAPSHOTS=$(lvs --noheadings -o lv_name 2>/dev/null | grep "_${SNAPSHOT_PREFIX}_${timestamp}")
    if [[ -z "$SNAPSHOTS" ]]; then
        print_error "No snapshots found for timestamp '${timestamp}'."
        return 1
    fi
    
    echo -e "${YELLOW}Preparing to delete entire snapshot group for timestamp: ${timestamp}${NC}"
    echo "The following snapshots will be deleted:"
    while IFS= read -r snap; do
        echo -e "  ${RED}${snap}${NC}"
    done <<< "$SNAPSHOTS"
    echo ""
    
    if [[ "$FORCE_MODE" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
        read -p "Confirm deletion of all snapshots in this group? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Operation cancelled."
            log_action "INFO" "Deletion of snapshot group '${timestamp}' cancelled by user."
            return
        fi
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        print_info "--- Dry Run Mode ---"
        print_success "Simulated deletion of snapshot group '${timestamp}'."
        log_action "INFO" "[DryRun] Simulated deletion of snapshot group '${timestamp}'."
        return
    fi

    log_action "WARN" "Attempting to delete snapshot group with timestamp '${timestamp}'."
    local DELETE_COUNT=0
    local FAIL_COUNT=0
    for snap in $SNAPSHOTS; do
        local cmd_args=()
        if [[ "$FORCE_MODE" -eq 1 ]]; then
            cmd_args+=("-f")
        fi
        if lvremove "${cmd_args[@]}" "/dev/${VG_NAME}/${snap}"; then
            echo -e "${GREEN}  ✓ Deleted: ${snap}${NC}"
            log_action "SUCCESS" "Snapshot '${snap}' from group '${timestamp}' deleted."
            DELETE_COUNT=$((DELETE_COUNT + 1))
        else
            echo -e "${RED}  ✗ Failed to delete: ${snap}${NC}"
            log_action "ERROR" "Failed to delete snapshot '${snap}' from group '${timestamp}'."
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    done
    echo ""
    print_success "Snapshot group deletion complete. Succeeded: ${DELETE_COUNT}, Failed: ${FAIL_COUNT}"
}