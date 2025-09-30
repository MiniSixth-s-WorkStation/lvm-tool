#!/bin/bash

# ==============================================================================
# Module Name: list.sh
# Description: Handles listing snapshots and snapshot groups.
# Description (zh_TW): 處理列出快照與快照群組。
# ==============================================================================

# --- Command Definition ---
# --- 指令定義 ---
COMMAND="list"
DESCRIPTION="List all individual snapshots and their usage."
DESCRIPTION_ZH="列出所有獨立快照及其使用率。"

COMMAND_LIST_GROUPS="list-groups"
DESCRIPTION_LIST_GROUPS="List all snapshot groups by timestamp."
DESCRIPTION_LIST_GROUPS_ZH="按時間戳記列出所有快照群組。"


# --- Function: command_main ---
# --- 功能: command_main ---
# Description: Main function for the 'list' command.
# Description (zh_TW): 'list' 指令的主功能。
command_main() {
    local snapshot_data
    snapshot_data=$(core_get_snapshot_data)

    if [[ -z "$snapshot_data" ]]; then
        if [[ "$OUTPUT_FORMAT" == "json" ]]; then
            echo "[]"
        elif [[ "$OUTPUT_FORMAT" != "csv" ]]; then
            print_info "$MSG_NO_SNAPSHOTS_FOUND"
        fi
        return
    fi

    case "$OUTPUT_FORMAT" in
        json)
            local json="["
            while IFS=, read -r name origin size usage timestamp; do
                json+=$(printf '{"name":"%s","origin":"%s","size":"%s","usage":"%s","timestamp":"%s"},' "$name" "$origin" "$size" "$usage" "$timestamp")
            done <<< "$snapshot_data"
            json=${json%,} # Remove trailing comma
            json+="]"
            echo "$json"
            ;;
        csv)
            echo "Snapshot Name,Origin LV,Size,Usage,Timestamp"
            echo "$snapshot_data"
            ;;
        *)
            # Use the core function to display the data in a table
            core_display_snapshot_data "$snapshot_data"
            ;;
    esac
}

# --- Function: command_list_groups ---
# --- 功能: command_list_groups ---
# Description: Main function for the 'list-groups' command.
# Description (zh_TW): 'list-groups' 指令的主功能。
command_list_groups() {
    local timestamps
    timestamps=$(lvs --noheadings -o lv_name 2>/dev/null | grep "_${SNAPSHOT_PREFIX}_" | sed "s/.*_${SNAPSHOT_PREFIX}_//" | sort -u)

    if [[ -z "$timestamps" ]]; then
        if [[ "$OUTPUT_FORMAT" == "json" ]]; then
            echo "[]"
        elif [[ "$OUTPUT_FORMAT" != "csv" ]]; then
            print_info "$MSG_NO_SNAPSHOT_GROUPS_FOUND"
        fi
        return
    fi

    case "$OUTPUT_FORMAT" in
        json)
            local json="["
            while IFS= read -r timestamp; do
                local snap_list
                snap_list=$(lvs --noheadings -o lv_name 2>/dev/null | grep "_${SNAPSHOT_PREFIX}_${timestamp}" | sed "s/_${SNAPSHOT_PREFIX}_${timestamp}//" | jq -R -s -c 'split("\n") | map(select(length > 0))')
                json+=$(printf '{"timestamp":"%s","snapshots":%s},' "$timestamp" "$snap_list")
            done <<< "$timestamps"
            json=${json%,}
            json+="]"
            echo "$json"
            ;;
        csv)
            echo "Timestamp,Included Snapshots"
            while IFS= read -r timestamp; do
                local snap_list
                snap_list=$(lvs --noheadings -o lv_name 2>/dev/null | grep "_${SNAPSHOT_PREFIX}_${timestamp}" | sed "s/_${SNAPSHOT_PREFIX}_${timestamp}//" | tr '\n' ' ')
                printf '"%s","%s"\n' "$timestamp" "$snap_list"
            done <<< "$timestamps"
            ;;
        *)
            echo ""
            echo -e "${BLUE}$MSG_SNAPSHOT_GROUP_LIST_HEADER${NC}"
            echo "========================================================================"
            echo "Timestamp                Included Snapshots"
            echo "------------------------------------------------------------------------"
            while IFS= read -r timestamp; do
                local snap_list
                snap_list=$(lvs --noheadings -o lv_name 2>/dev/null | grep "_${SNAPSHOT_PREFIX}_${timestamp}" | sed "s/_${SNAPSHOT_PREFIX}_${timestamp}//" | tr '\n' ' ')
                printf "${GREEN}%s${NC}\n" "$timestamp"
                printf "  Includes: %s\n\n" "$snap_list"
            done <<< "$timestamps"
            echo "========================================================================"
            ;;
    esac
}