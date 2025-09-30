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
    snapshot_data=$(lvs --noheadings -o lv_name,origin,lv_size,snap_percent,lv_attr --separator=',' 2>/dev/null | awk -F',' '
        substr($5, 1, 1) == "s" {
            timestamp = $1;
            sub(/.*_'"${SNAPSHOT_PREFIX}"'_/, "", timestamp);
            printf "%s,%s,%s,%.2f,%s\n", $1, $2, $3, $4, timestamp;
        }
    ' | sort)

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
            echo ""
            echo -e "${BLUE}$MSG_SNAPSHOT_LIST_HEADER${NC}"
            echo "========================================================================================"
            printf "%-35s %-15s %-10s %-12s %-15s\n" "Snapshot Name" "Origin LV" "Size" "Usage" "Timestamp"
            echo "----------------------------------------------------------------------------------------"
            
            local formatted_output
            formatted_output=$(echo "$snapshot_data" | while IFS=, read -r name origin size usage timestamp; do
                local percent=$usage
                local color_prefix='\033[0;32m' # GREEN
                if (( $(echo "$percent > 80" | bc -l) )); then color_prefix='\033[0;31m'; fi # RED
                if (( $(echo "$percent > 50 && $percent <= 80" | bc -l) )); then color_prefix='\033[0;33m'; fi # YELLOW
                local color_suffix='\033[0m'
                printf "%-35s,%-15s,%-10s,${color_prefix}%-12s${color_suffix},%s\n" "$name" "$origin" "$size" "${usage}%" "$timestamp"
            done)

            if [[ "$HAS_COLUMN" -eq 1 ]]; then
                echo "$formatted_output" | column -t -s ','
            else
                echo "$formatted_output" | sed 's/,/\t/g'
                if [[ -z "$COLUMN_WARN_SHOWN" ]]; then
                    print_warning "$MSG_COLUMN_UTILITY_NOT_FOUND"
                    COLUMN_WARN_SHOWN=1
                fi
            fi
            echo "========================================================================================"
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