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
        echo "Interactive Mode"
        echo "--------------------------"
        echo "1) Snapshot Management"
        echo "2) Volume Management"
        echo "q) Quit"
        echo "--------------------------"
        read -p "Enter your choice: " choice

        case "$choice" in
            1) snapshot_menu ;;
            2) volume_menu ;;
            q) break ;;
            *) echo "Invalid choice" ;;
        esac
        read -p "Press Enter to continue..."
    done
}

snapshot_menu() {
    while true; do
        clear
        print_header
        echo "Snapshot Management"
        echo "--------------------------"
        echo "1) Create Snapshots"
        echo "2) List Snapshots"
        echo "3) Restore from Snapshot"
        echo "b) Back to main menu"
        echo "--------------------------"
        read -p "Enter your choice: " choice

        case "$choice" in
            1) command_create ;;
            2) command_list ;;
            3) read -p "Enter timestamp to restore: " ts; command_restore "$ts" ;;
            b) break ;;
            *) echo "Invalid choice" ;;
        esac
        read -p "Press Enter to continue..."
    done
}

volume_menu() {
    while true; do
        clear
        print_header
        echo "Volume Management"
        echo "--------------------------"
        echo "1) Show PVs"
        echo "2) Show VGs"
        echo "3) Show LVs"
        echo "4) Create PV"
        echo "5) Create VG"
        echo "6) Create LV"
        echo "b) Back to main menu"
        echo "--------------------------"
        read -p "Enter your choice: " choice

        case "$choice" in
            1) command_pvs ;;
            2) command_vgs ;;
            3) command_lvs ;;
            4) read -p "Enter device path for new PV: " dev; command_pv_create "$dev" ;;
            5) read -p "Enter VG name: " vg_name; read -p "Enter devices (space-separated): " devices; command_vg_create "$vg_name" $devices ;;
            6) read -p "Enter VG name: " vg_name; read -p "Enter LV name: " lv_name; read -p "Enter size: " size; command_lv_create "$vg_name" "$lv_name" "$size" ;;
            b) break ;;
            *) echo "Invalid choice" ;;
        esac
        read -p "Press Enter to continue..."
    done
}
 
# Pass all script arguments to main
main "$@"