#!/bin/bash

# ==============================================================================
# Script Name: main.sh
# Description: Main execution logic for LVM Snapshot Manager.
#              Loads modules, parses arguments, and dispatches commands.
# Description (zh_TW): LVM 快照管理員的主執行邏輯。
#                      載入模組、解析參數並分派指令。
# ==============================================================================

# --- Setup Environment ---
# --- 設定環境 ---
LIB_DIR=$(dirname "$(readlink -f "$0")")
source "${LIB_DIR}/core.sh"

# --- Module Loading ---
# --- 模組載入 ---
declare -A MODULE_COMMANDS
declare -A MODULE_DESCRIPTIONS
declare -A MODULE_DESCRIPTIONS_ZH
declare -A MODULE_CATEGORIES
 
load_modules() {
    for module_file in "${LIB_DIR}/modules/"*.sh; do
        if [[ -f "$module_file" ]]; then
            # Source the module to read its command definitions
            source "$module_file"
            
            local category="Snapshot Management" # Default category
            if [[ -n "$MODULE_CATEGORY" ]]; then
                category="$MODULE_CATEGORY"
            fi

            # Assumes modules define COMMAND, DESCRIPTION, and DESCRIPTION_ZH
            if [[ -n "$COMMAND" ]]; then
                MODULE_COMMANDS["$COMMAND"]="command_main"
                MODULE_DESCRIPTIONS["$COMMAND"]="$DESCRIPTION"
                MODULE_DESCRIPTIONS_ZH["$COMMAND"]="$DESCRIPTION_ZH"
                MODULE_CATEGORIES["$COMMAND"]="$category"
            fi
 
            # Support for modules with multiple commands
            # e.g., list.sh has list and list-groups
            local multi_commands=$(grep -oP 'COMMAND_[A-Z_]+=' "$module_file" | sed 's/=$//')
            for cmd_var in $multi_commands; do
                local cmd_name_suffix=$(echo "$cmd_var" | sed 's/COMMAND_//' | tr '[:upper:]' '[:lower:]' | sed 's/_/-/')
                local desc_var="DESCRIPTION_${cmd_var#COMMAND_}"
                local desc_zh_var="DESCRIPTION_${cmd_var#COMMAND_}_ZH"
                
                # Dynamically get the value of the variables
                local cmd_name="${!cmd_var}"
                local desc="${!desc_var}"
                local desc_zh="${!desc_zh_var}"
                
                # Function name convention: command_subcommand
                local func_name="command_$(echo "$cmd_name_suffix" | sed 's/-/_/')"
 
                MODULE_COMMANDS["$cmd_name"]="$func_name"
                MODULE_DESCRIPTIONS["$cmd_name"]="$desc"
                MODULE_DESCRIPTIONS_ZH["$cmd_name"]="$desc_zh"
                MODULE_CATEGORIES["$cmd_name"]="$category"
            done
        fi
    done
}
 
# --- Override show_usage from core.sh to be dynamic ---
# --- 覆寫 core.sh 的 show_usage 以使其動態化 ---
show_usage() {
    print_header
    echo "Usage: sudo $(basename $0) [OPTIONS] [COMMAND] [ARGUMENTS...]"
    echo ""
    echo "Options:"
    echo "  -c, --config FILE   Specify a custom configuration file path."
    echo "                      Defaults to '${CONFIG_FILE}'."
    echo "      --dry-run       Simulate execution, showing intended actions without making changes."
    echo "      --force, --yes  Automatically answer 'yes' to confirmation prompts."
    echo "      --format FMT    Set output format for list commands (json, csv)."
    echo ""
    
    # Group commands by category
    declare -A grouped_commands
    for cmd in "${!MODULE_COMMANDS[@]}"; do
        local category="${MODULE_CATEGORIES[$cmd]:-Other}"
        grouped_commands["$category"]+="$cmd "
    done

    for category in "${!grouped_commands[@]}"; do
        echo -e "${GREEN}${category}:${NC}"
        for cmd in ${grouped_commands[$category]}; do
            local desc
            if [[ "${LANG}" == "zh_TW"* ]]; then
                desc="${MODULE_DESCRIPTIONS_ZH[$cmd]}"
            else
                desc="${MODULE_DESCRIPTIONS[$cmd]}"
            fi
            printf "  %-20s %s\n" "$cmd" "$desc"
        done
        echo ""
    done
    echo ""

    echo -e "${GREEN}Other Commands:${NC}"
    printf "  %-20s %s\n" "interactive" "Enter interactive menu mode."
    echo ""
}


# --- Main Execution Logic ---
# --- 主執行邏輯 ---
main() {
    load_language
    load_modules

    if [[ $EUID -ne 0 ]]; then
        print_error "$MSG_MUST_BE_ROOT"
        exit 1
    fi

    # Concurrency lock
    exec 200>"$LOCK_FILE"
    flock -n 200 || {
        print_error "$MSG_ANOTHER_INSTANCE_RUNNING"
        exit 1
    }
    trap 'rm -f "$LOCK_FILE"' EXIT
    
    initialize_log
    check_dependencies

    local COMMAND=""
    local POSITIONAL_ARGS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)
                if [[ -n "$2" ]]; then
                    CONFIG_FILE="$2"
                    shift 2
                else
                    print_error "Error: '$1' requires a file path."
                    exit 1
                fi
                ;;
            --dry-run)
                DRY_RUN=1
                print_info "Dry Run mode enabled."
                shift
                ;;
            --force|--yes)
                FORCE_MODE=1
                print_warning "Force mode enabled. All prompts will be auto-confirmed."
                shift
                ;;
            --format)
                OUTPUT_FORMAT="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -*)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                POSITIONAL_ARGS+=("$1")
                shift
                ;;
        esac
    done

    COMMAND="${POSITIONAL_ARGS[0]:-help}"
    local -a ARGS=("${POSITIONAL_ARGS[@]:1}")

    if [[ "$COMMAND" != "config" && "$COMMAND" != "help" ]]; then
        load_config "${CONFIG_FILE}"
    fi

    HAS_LSOF=0; if command -v lsof &> /dev/null; then HAS_LSOF=1; fi
    HAS_FUSER=0; if command -v fuser &> /dev/null; then HAS_FUSER=1; fi
    HAS_COLUMN=0; if command -v column &> /dev/null; then HAS_COLUMN=1; fi
    
    if [[ "$COMMAND" != "help" && "$COMMAND" != "" ]]; then
        log_action "EXEC" "Command: '${COMMAND}', Arguments: '${ARGS[*]}'"
    fi
    
    if [[ "${MODULE_COMMANDS[$COMMAND]}" ]]; then
        local func_to_call="${MODULE_COMMANDS[$COMMAND]}"
        # Source the specific module file that defines the function
        for module_file in "${LIB_DIR}/modules/"*.sh; do
            if grep -q "function ${func_to_call}" "$module_file" || grep -q "${func_to_call}()" "$module_file"; then
                source "$module_file"
                break
            fi
        done
        
        print_header
        # Call the function with arguments
        "$func_to_call" "${ARGS[@]}"
    elif [[ "$COMMAND" == "help" ]]; then
        show_usage
    elif [[ "$COMMAND" == "interactive" ]]; then
        interactive_mode
    elif [[ "$COMMAND" == "_update_cache" ]]; then
        # Internal command for post-install script to generate initial cache
        load_config "${CONFIG_FILE}"
        update_completion_cache
    else
        print_error "Unknown command: '$COMMAND'"
        show_usage
        exit 1
    fi
}

interactive_mode() {
    while true; do
        clear
        print_header
        echo "$MSG_INTERACTIVE_MODE"
        echo "--------------------------"
        echo "$MSG_SNAPSHOT_MANAGEMENT"
        echo "$MSG_VOLUME_MANAGEMENT"
        echo "$MSG_QUIT"
        echo "--------------------------"
        read -p "$MSG_ENTER_CHOICE" choice

        case "$choice" in
            1) snapshot_menu ;;
            2) volume_menu ;;
            q) break ;;
            *) echo "Invalid choice" ;;
        esac
        read -p "Press Enter to continue..."
    done
}

# --- Function: snapshot_menu ---
# --- 功能: snapshot_menu ---
# Description: Main menu for snapshot management.
# Description (zh_TW): 快照管理的主選單。
snapshot_menu() {
    while true; do
        clear
        print_header
        echo "$MSG_SNAPSHOT_MENU_TITLE"
        echo "--------------------------"
        echo "$MSG_CREATE_SNAPSHOTS"
        echo "$MSG_LIST_SNAPSHOTS"
        echo "$MSG_RESTORE_SNAPSHOT"
        echo "$MSG_DELETE_SNAPSHOTS"
        echo "$MSG_MAINTENANCE_HEALTH"
        echo "$MSG_BACK_TO_MAIN_MENU"
        echo "--------------------------"
        read -p "$MSG_ENTER_CHOICE" choice

        case "$choice" in
            1) command_create ;;
            2) list_submenu ;;
            3) read -p "$MSG_ENTER_TIMESTAMP_TO_RESTORE" ts; command_restore "$ts" ;;
            4) delete_submenu ;;
            5) maintenance_submenu ;;
            b) break ;;
            *) echo "$MSG_INVALID_CHOICE" ;;
        esac
        [[ "$choice" != "b" ]] && read -p "$MSG_PRESS_ENTER_TO_CONTINUE"
    done
}

# --- Function: list_submenu ---
# --- 功能: list_submenu ---
# Description: Submenu for listing snapshots and groups.
# Description (zh_TW): 列出快照與群組的子選單。
list_submenu() {
    clear
    print_header
    echo "$MSG_LIST_MENU_TITLE"
    echo "--------------------------"
    echo "$MSG_LIST_INDIVIDUAL"
    echo "$MSG_LIST_GROUPS"
    echo "--------------------------"
    read -p "$MSG_ENTER_CHOICE" choice
    case "$choice" in
        1) command_list ;;
        2) command_list_groups ;;
        *) echo "$MSG_INVALID_CHOICE" ;;
    esac
}

# --- Function: delete_submenu ---
# --- 功能: delete_submenu ---
# Description: Submenu for deleting snapshots.
# Description (zh_TW): 刪除快照的子選單。
delete_submenu() {
    clear
    print_header
    echo "$MSG_DELETE_MENU_TITLE"
    echo "--------------------------"
    echo "$MSG_DELETE_SINGLE"
    echo "$MSG_DELETE_GROUP"
    echo "--------------------------"
    read -p "$MSG_ENTER_CHOICE" choice
    case "$choice" in
        1) read -p "$MSG_ENTER_SNAPSHOT_NAME_TO_DELETE" name; command_main "$name" ;; # command_main from delete.sh
        2) read -p "$MSG_ENTER_TIMESTAMP_TO_DELETE" ts; command_delete_group "$ts" ;;
        *) echo "$MSG_INVALID_CHOICE" ;;
    esac
}

# --- Function: maintenance_submenu ---
# --- 功能: maintenance_submenu ---
# Description: Submenu for maintenance tasks like health checks and purging.
# Description (zh_TW): 維護任務（如健康檢查、清除）的子選單。
maintenance_submenu() {
    while true; do
        clear
        print_header
        echo "$MSG_MAINTENANCE_MENU_TITLE"
        echo "--------------------------"
        echo "$MSG_CHECK_HEALTH"
        echo "$MSG_PURGE_SNAPSHOTS"
        echo "$MSG_EXTEND_SNAPSHOT"
        echo "$MSG_BACK_TO_SNAPSHOT_MENU"
        echo "--------------------------"
        read -p "$MSG_ENTER_CHOICE" choice

        case "$choice" in
            1) command_main ;; # command_main from health.sh
            2) purge_submenu ;;
            3) read -p "$MSG_ENTER_SNAPSHOT_NAME_TO_EXTEND" name; read -p "$MSG_ENTER_SIZE_TO_ADD" size; command_extend "$name" "$size" ;;
            b) break ;;
            *) echo "$MSG_INVALID_CHOICE" ;;
        esac
        [[ "$choice" != "b" ]] && read -p "$MSG_PRESS_ENTER_TO_CONTINUE"
    done
}

# --- Function: purge_submenu ---
# --- 功能: purge_submenu ---
# Description: Submenu for purging old snapshots.
# Description (zh_TW): 清除舊快照的子選單。
purge_submenu() {
    clear
    print_header
    echo "$MSG_PURGE_MENU_TITLE"
    echo "--------------------------"
    echo "$MSG_PURGE_BY_COUNT"
    echo "$MSG_PURGE_BY_AGE"
    echo "--------------------------"
    read -p "$MSG_ENTER_CHOICE" choice
    case "$choice" in
        1) read -p "$MSG_ENTER_PURGE_COUNT" num; command_purge "--keep-last" "$num" ;;
        2) read -p "$MSG_ENTER_PURGE_AGE" age; command_purge "--older-than" "$age" ;;
        *) echo "$MSG_INVALID_CHOICE" ;;
    esac
}

volume_menu() {
    while true; do
        clear
        print_header
        echo "$MSG_VOLUME_MENU_TITLE"
        echo "--------------------------"
        echo "$MSG_SHOW_PVS"
        echo "$MSG_SHOW_VGS"
        echo "$MSG_SHOW_LVS"
        echo "$MSG_CREATE_PV"
        echo "$MSG_CREATE_VG"
        echo "$MSG_CREATE_LV"
        echo "$MSG_BACK_TO_MAIN_MENU"
        echo "--------------------------"
        read -p "$MSG_ENTER_CHOICE" choice

        case "$choice" in
            1) command_pvs ;;
            2) command_vgs ;;
            3) command_lvs ;;
            4) read -p "$MSG_ENTER_DEVICE_FOR_PV" dev; command_pv_create "$dev" ;;
            5) read -p "$MSG_ENTER_VG_NAME" vg_name; read -p "$MSG_ENTER_DEVICES" devices; command_vg_create "$vg_name" $devices ;;
            6) read -p "$MSG_ENTER_VG_NAME" vg_name; read -p "$MSG_ENTER_LV_NAME" lv_name; read -p "$MSG_ENTER_SIZE" size; command_lv_create "$vg_name" "$lv_name" "$size" ;;
            b) break ;;
            *) echo "$MSG_INVALID_CHOICE" ;;
        esac
        read -p "$MSG_PRESS_ENTER_TO_CONTINUE"
    done
}
 
# Pass all script arguments to main
main "$@"