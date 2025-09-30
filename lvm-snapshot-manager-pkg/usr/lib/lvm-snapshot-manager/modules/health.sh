#!/bin/bash

# ==============================================================================
# Module Name: health.sh
# Description: Handles health checks and real-time monitoring of snapshots.
# Description (zh_TW): 處理快照的健康狀況檢查與即時監控。
# ==============================================================================

# --- Command Definition ---
# --- 指令定義 ---
COMMAND="check-health"
DESCRIPTION="Check the health status of all snapshots."
DESCRIPTION_ZH="檢查所有快照的健康狀況。"

COMMAND_MONITOR="monitor"
DESCRIPTION_MONITOR="Enter real-time monitoring mode for snapshot usage."
DESCRIPTION_MONITOR_ZH="進入快照使用率的即時監控模式。"

# --- Function: command_main (check-health) ---
# --- 功能: command_main (check-health) ---
# Description: Main function for the 'check-health' command.
# Description (zh_TW): 'check-health' 指令的主功能。
command_main() {
    echo ""
    echo -e "${BLUE}$MSG_SYSTEM_HEALTH_CHECK_HEADER${NC}"
    echo "================================================================================"
    local ERROR_COUNT=0
    local WARNING_COUNT=0

    # 1. Check VG Free Space
    # 1. 檢查 VG 可用空間
    local VFREE_MB
    VFREE_MB=$(vgs "${VG_NAME}" --noheadings --units m -o vg_free | sed 's/[^0-9.]//g' | cut -d. -f1)
    if [[ "$VFREE_MB" -lt 1024 ]]; then
        print_warning "$(printf "$MSG_VG_LOW_SPACE" "$VG_NAME" "$VFREE_MB")"
        WARNING_COUNT=$((WARNING_COUNT + 1))
    else
        print_success "$(printf "$MSG_VG_HEALTHY" "$VG_NAME" "$VFREE_MB")"
    fi

    # 2. Check LV Health
    # 2. 檢查 LV 健康狀況
    local lv_health
    lv_health=$(lvs --noheadings -o lv_name,lv_health_status 2>/dev/null)
    if [[ -n "$lv_health" ]]; then
        while read -r lv_name health_status; do
            if [[ -n "$health_status" ]]; then
                print_error "$(printf "$MSG_LV_HEALTH_ISSUE" "$lv_name" "$health_status")"
                ERROR_COUNT=$((ERROR_COUNT + 1))
            fi
        done <<< "$lv_health"
    fi

    # 3. Check Snapshot Health
    # 3. 檢查快照健康狀況
    local health_info
    health_info=$(lvs --noheadings -o lv_name,snap_percent,lv_attr --separator=',' 2>/dev/null | awk -F',' '
        substr($3, 1, 1) == "s" {
            percent = $2;
            if (percent >= 90)      { printf "ERROR,%s,%.2f\n", $1, percent; }
            else if (percent >= 70) { printf "WARN,%s,%.2f\n", $1, percent; }
            else                    { printf "OK,%s,%.2f\n", $1, percent; }
        }
    ')

    if [[ -z "$health_info" ]]; then
        echo -e "${YELLOW}$MSG_NO_SNAPSHOTS_TO_CHECK${NC}"
    else
        while IFS=, read -r status name percent; do
            case "$status" in
                ERROR)
                    echo -e "$(printf "$MSG_SNAPSHOT_DANGER" "$name" "$percent")"
                    ERROR_COUNT=$((ERROR_COUNT + 1))
                    ;;
                WARN)
                    echo -e "$(printf "$MSG_SNAPSHOT_WARNING" "$name" "$percent")"
                    WARNING_COUNT=$((WARNING_COUNT + 1))
                    ;;
                OK)
                    echo -e "$(printf "$MSG_SNAPSHOT_OK" "$name" "$percent")"
                    ;;
            esac
        done <<< "$health_info"
    fi
    
    echo "-------------------------------------------------------------------------------"
    echo "$(printf "$MSG_HEALTH_SUMMARY" "$ERROR_COUNT" "$WARNING_COUNT")"
    
    if [[ $ERROR_COUNT -gt 0 ]]; then
        echo -e "${RED}$MSG_HEALTH_RECOMMENDATION_DANGER${NC}"
    elif [[ $WARNING_COUNT -gt 0 ]]; then
        echo -e "${YELLOW}$MSG_HEALTH_RECOMMENDATION_WARNING${NC}"
    else
        echo -e "${GREEN}$MSG_HEALTH_OK${NC}"
    fi
    echo "================================================================================"
}

# --- Function: command_monitor ---
# --- 功能: command_monitor ---
# Description: Main function for the 'monitor' command.
# Description (zh_TW): 'monitor' 指令的主功能。
command_monitor() {
    echo -e "${BLUE}[Snapshot Monitor Mode]${NC} - Press Ctrl+C to exit"
    trap 'echo -e "\n${YELLOW}Monitoring stopped.${NC}"; exit 0' INT
    
    # We need to source the list module to use its main function
    # This is a temporary solution until a better way is found
    source "${LIB_DIR}/modules/list.sh"

    while true; do
        clear
        print_header
        echo -e "${CYAN}Live Snapshot Status - $(date '+%Y-%m-%d %H:%M:%S')${NC}"
        command_main # Calls the list command's main function
        echo ""
        command_main # Calls the check-health command's main function
        echo ""
        echo -e "${YELLOW}Hint: Consider extending or deleting snapshots with usage over 80%.${NC}"
        sleep 5
    done
}