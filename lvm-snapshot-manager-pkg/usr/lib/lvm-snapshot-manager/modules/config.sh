#!/bin/bash

# ==============================================================================
# Module Name: config.sh
# Description: Handles interactive configuration management.
# Description (zh_TW): 處理互動式設定管理。
# ==============================================================================

# --- Command Definition ---
# --- 指令定義 ---
COMMAND="config"
DESCRIPTION="Enter an interactive menu to manage the 'lvm.conf' file."
DESCRIPTION_ZH="進入互動式選單以管理 'lvm.conf' 設定檔。"

# --- Function: read_input ---
# --- 功能: read_input ---
# Helper function to read user input with a default value.
# Function (zh_TW): 讀取使用者輸入的輔助功能，可帶有預設值。
# Arguments: $1=Prompt, $2=Default Value, $3=Return variable name
# Arguments (zh_TW): $1=提示訊息, $2=預設值, $3=回傳變數名稱
read_input() {
    local prompt="$1"
    local default_value="$2"
    local -n return_var="$3"
    local input
    if [[ -n "$default_value" ]]; then
        read -p "${prompt} [${default_value}]: " input
        return_var="${input:-$default_value}"
    else
        read -p "${prompt}: " input
        return_var="$input"
    fi
}

# --- Function: command_main ---
# --- 功能: command_main ---
# Description: Main loop for the interactive configuration manager.
# Description (zh_TW): 互動式設定管理員的主迴圈。
command_main() {
    # Load the config first to populate variables
    load_config "$CONFIG_FILE"

    while true; do
        clear
        print_header
        echo "$MSG_INTERACTIVE_CONFIG_HEADER"
        echo -e "$(printf "$MSG_CONFIG_FILE" "${YELLOW}${CONFIG_FILE}${NC}")"
        echo ""
        echo -e "${BLUE}${MSG_VG_NAME}${NC} $VG_NAME"
        echo -e "${BLUE}${MSG_SNAPSHOT_PREFIX}${NC} $SNAPSHOT_PREFIX"
        echo ""
        echo -e "${BLUE}${MSG_LV_SETTINGS}${NC}"
        echo "----------------------------------------------------------------------"
        printf "%-4s %-15s %-10s %-20s %s\n" "ID" "LV Name" "Snap Size" "Mount Point" "Description"
        echo "----------------------------------------------------------------------"
        
        local -a lv_keys
        mapfile -t lv_keys < <(printf "%s\n" "${!LV_CONFIG[@]}" | sort)
        
        if [[ ${#lv_keys[@]} -eq 0 ]]; then
            echo -e "${YELLOW}  $MSG_NO_LVS_CONFIGURED${NC}"
        else
            for i in "${!lv_keys[@]}"; do
                local key="${lv_keys[$i]}"
                local value="${LV_CONFIG[$key]}"
                local size mount desc
                size=$(echo "$value" | cut -d'|' -f1)
                mount=$(echo "$value" | cut -d'|' -f2)
                desc=$(echo "$value" | cut -d'|' -f3)
                printf "%-4s %-15s %-10s %-20s %s\n" "$((i+1))" "$key" "$size" "$mount" "$desc"
            done
        fi
        echo "----------------------------------------------------------------------"
        echo ""
        echo -e "${GREEN}${MSG_ACTIONS}${NC}"
        echo "  ${MSG_EDIT_VG_NAME}          ${MSG_EDIT_SNAPSHOT_PREFIX}"
        echo "  ${MSG_ADD_LV}          ${MSG_MODIFY_LV}         ${MSG_DELETE_LV}"
        echo ""
        echo "  ${MSG_SAVE_AND_EXIT}         ${MSG_QUIT_NO_SAVE}"
        echo ""
        read -p "$MSG_ENTER_CHOICE" choice

        case "$choice" in
            1) read_input "$MSG_ENTER_NEW_VG_NAME" "$VG_NAME" VG_NAME ;;
            2) read_input "$MSG_ENTER_NEW_SNAPSHOT_PREFIX" "$SNAPSHOT_PREFIX" SNAPSHOT_PREFIX ;;
            3)  # Add LV
                local new_lv new_size new_mount new_desc
                read_input "$MSG_ENTER_LV_NAME" "" new_lv
                if [[ -n "$new_lv" ]]; then
                    read_input "$MSG_SNAPSHOT_SIZE_PROMPT" "5G" new_size
                    read_input "$MSG_MOUNT_POINT_PROMPT" "none" new_mount
                    read_input "$MSG_DESCRIPTION_PROMPT" "" new_desc
                    LV_CONFIG["$new_lv"]="${new_size}|${new_mount}|${new_desc}"
                    print_success "$(printf "$MSG_LV_ADDED" "$new_lv")"
                fi
                ;;
            4)  # Modify LV
                if [[ ${#lv_keys[@]} -eq 0 ]]; then print_warning "$MSG_NO_LVS_TO_MODIFY"; sleep 1; continue; fi
                local selection
                read -p "$(printf "$MSG_ENTER_LV_ID_TO_MODIFY" "${#lv_keys[@]}")" selection
                if [[ "$selection" =~ ^[0-9]+$ && "$selection" -ge 1 && "$selection" -le "${#lv_keys[@]}" ]]; then
                    local key_to_edit="${lv_keys[$((selection-1))]}"
                    local value="${LV_CONFIG[$key_to_edit]}"
                    local old_size old_mount old_desc
                    old_size=$(echo "$value" | cut -d'|' -f1)
                    old_mount=$(echo "$value" | cut -d'|' -f2)
                    old_desc=$(echo "$value" | cut -d'|' -f3)
                    local new_size new_mount new_desc
                    read_input "$MSG_SNAPSHOT_SIZE_PROMPT" "$old_size" new_size
                    read_input "$MSG_MOUNT_POINT_PROMPT" "$old_mount" new_mount
                    read_input "$MSG_DESCRIPTION_PROMPT" "$old_desc" new_desc
                    LV_CONFIG["$key_to_edit"]="${new_size}|${new_mount}|${new_desc}"
                    print_success "$(printf "$MSG_LV_UPDATED" "$key_to_edit")"
                else
                    print_error "$MSG_INVALID_ID"
                fi
                sleep 1
                ;;
            5)  # Delete LV
                if [[ ${#lv_keys[@]} -eq 0 ]]; then print_warning "$MSG_NO_LVS_TO_DELETE"; sleep 1; continue; fi
                local selection
                read -p "$(printf "$MSG_ENTER_LV_ID_TO_DELETE" "${#lv_keys[@]}")" selection
                if [[ "$selection" =~ ^[0-9]+$ && "$selection" -ge 1 && "$selection" -le "${#lv_keys[@]}" ]]; then
                    local key_to_delete="${lv_keys[$((selection-1))]}"
                    read -p "$(printf "$MSG_CONFIRM_DELETE_LV" "$key_to_delete")" -n 1 -r confirm
                    echo
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        unset LV_CONFIG["$key_to_delete"]
                        print_success "$(printf "$MSG_LV_DELETED" "$key_to_delete")"
                    else
                        print_info "$MSG_OPERATION_CANCELLED"
                    fi
                else
                    print_error "$MSG_INVALID_ID"
                fi
                sleep 1
                ;;
            s|S)
                local backup_file="${CONFIG_FILE}.bak"
                if [[ -f "$CONFIG_FILE" ]]; then
                    cp "$CONFIG_FILE" "$backup_file"
                    print_info "$(printf "$MSG_BACKUP_CREATED" "$backup_file")"
                fi
                write_config_content "$CONFIG_FILE"
                print_success "$(printf "$MSG_CONFIG_SAVED" "$CONFIG_FILE")"
                break
                ;;
            q|Q)
                print_warning "$MSG_NO_CHANGES_SAVED"
                break
                ;;
            *)
                print_error "$MSG_INVALID_CHOICE"
                sleep 1
                ;;
        esac
    done
}