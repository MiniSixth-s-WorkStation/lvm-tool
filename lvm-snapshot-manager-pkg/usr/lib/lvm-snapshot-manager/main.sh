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

load_modules() {
    for module_file in "${LIB_DIR}/modules/"*.sh; do
        if [[ -f "$module_file" ]]; then
            # Source the module to read its command definitions
            source "$module_file"
            
            # Assumes modules define COMMAND, DESCRIPTION, and DESCRIPTION_ZH
            if [[ -n "$COMMAND" ]]; then
                MODULE_COMMANDS["$COMMAND"]="command_main"
                MODULE_DESCRIPTIONS["$COMMAND"]="$DESCRIPTION"
                MODULE_DESCRIPTIONS_ZH["$COMMAND"]="$DESCRIPTION_ZH"
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
    echo -e "${GREEN}Available Commands:${NC}"
    
    # Dynamically print commands from loaded modules
    for cmd in "${!MODULE_COMMANDS[@]}"; do
        local desc
        if [[ "${LANG}" == "zh_TW"* ]]; then
            desc="${MODULE_DESCRIPTIONS_ZH[$cmd]}"
        else
            desc="${MODULE_DESCRIPTIONS[$cmd]}"
        fi
        printf "  %-20s %s\n" "$cmd" "$desc"
    done
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
    else
        print_error "Unknown command: '$COMMAND'"
        show_usage
        exit 1
    fi
}

# Pass all script arguments to main
main "$@"