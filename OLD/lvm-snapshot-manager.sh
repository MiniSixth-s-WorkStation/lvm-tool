#!/bin/bash

# ==============================================================================
# Script Name: lvm-snapshot-manager.sh (v9)
# Script Name (zh_TW): lvm-snapshot-manager.sh (v9)
# Description: A comprehensive utility for managing LVM snapshots.
#              It integrates snapshot creation, restoration, listing, monitoring,
#              and deletion into a single tool.
#              v9 enhances security, robustness, and international compatibility.
# Description (zh_TW): 一個用於管理 LVM 快照的綜合工具。
#                      它整合了快照的建立、還原、列表、監控和刪除功能。
#                      v9 版本增強了安全性、穩定性和國際相容性。
# Author:      Gemini (with community improvements)
# Author (zh_TW): Gemini (並由社群改進)
# Date:        2025-09-26
# ==============================================================================

# --- Script Settings ---
# --- 腳本設定 ---
set -eo pipefail

# --- Global Variables ---
# --- 全域變數 ---
LOG_FILE="/var/log/lvm-snapshot-manager.log"
LOCK_FILE="/var/run/lvm-snapshot-manager.lock"
DRY_RUN=0
FORCE_MODE=0
SCRIPT_PID=$$
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

# --- Language and Text Functions ---
# --- 語言與文字功能 ---
load_language() {
    local lang_file
    if [[ "${LANG}" == "zh_TW"* ]]; then
        lang_file="${SCRIPT_DIR}/lang.zh_TW"
    else
        lang_file="${SCRIPT_DIR}/lang.en"
    fi

    if [[ -f "$lang_file" ]]; then
        source "$lang_file"
    else
        echo "ERROR: Language file not found: $lang_file"
        exit 1
    fi
}

# --- Color and Output Functions ---
# --- 顏色與輸出功能 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
print_info() { printf "${CYAN}[%s]${NC} %s\n" "$MSG_INFO" "$1"; }
print_success() { printf "${GREEN}[%s]${NC} %s\n" "$MSG_SUCCESS" "$1"; }
print_error() { printf "${RED}[%s]${NC} %s\n" "$MSG_ERROR" "$1"; }
print_warning() { printf "${YELLOW}[%s]${NC} %s\n" "$MSG_WARNING" "$1"; }

# Function: Initialize and check permissions for the log file.
# Function (zh_TW): 初始化並檢查日誌檔案的權限。
initialize_log() {
    if ! [[ -f "$LOG_FILE" ]]; then
        touch "$LOG_FILE" || {
            print_error "$(printf "$MSG_COULD_NOT_CREATE_LOG_FILE" "$LOG_FILE")"
            exit 1
        }
    fi
    chown root:adm "$LOG_FILE" || {
        print_warning "$MSG_COULD_NOT_SET_LOG_OWNER"
    }
    chmod 640 "$LOG_FILE" || {
        print_warning "$MSG_COULD_NOT_SET_LOG_PERMS"
    }
}

# Function: Log an action to the log file.
# Arguments: $1=Log Level (e.g., INFO, WARN, ERROR), $2=Log Message
# Arguments (zh_TW): $1=日誌級別 (例如 INFO, WARN, ERROR), $2=日誌訊息
log_action() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local user
    user=$(whoami 2>/dev/null || echo "unknown")
    local func_name="${FUNCNAME[1]}"
    echo "[$timestamp] [${level}] [${func_name}] [PID:${SCRIPT_PID}] [USER:${user}] - ${message}" >> "$LOG_FILE"
}

# Function: Display the script header.
# Function (zh_TW): 顯示腳本標頭。
print_header() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              LVM Snapshot Management Utility (v9)        ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Function: Display usage instructions.
# Function (zh_TW): 顯示使用說明。
show_usage() {
    print_header
    echo "Usage: sudo $0 [OPTIONS] [COMMAND] [ARGUMENTS...]"
    echo ""
    echo "Options:"
    echo "  -c, --config FILE   Specify a custom configuration file path."
    echo "                      Defaults to 'lvm.conf' in the script's directory."
    echo "      --dry-run       Simulate execution, showing intended actions without making changes."
    echo "      --force, --yes  Automatically answer 'yes' to confirmation prompts."
    echo ""
    echo -e "${GREEN}Main Commands:${NC}"
    echo "  config              Enter an interactive menu to manage the 'lvm.conf' file."
    echo "  create              Create a new set of snapshots for all configured LVs."
    echo "  restore <TIMESTAMP> Restore the system from a specified snapshot group."
    echo ""
    echo -e "${YELLOW}Management Commands:${NC}"
    echo "  list                List all individual snapshots and their usage."
    echo "  list-groups         List all snapshot groups by timestamp."
    echo "  monitor             Enter real-time monitoring mode for snapshot usage."
    echo "  delete <SNAP_NAME>  Delete a specific snapshot."
    echo "  delete-group <TS>   Delete an entire snapshot group by timestamp."
    echo "  check-health        Check the health status of all snapshots."
    echo "  setup-logrotate     Create a logrotate configuration file template."
    echo ""
}

# ==============================================================================
#                           Configuration File Handling
#                           設定檔處理
# ==============================================================================

# Function: Write the current configuration to a file.
# Function (zh_TW): 將當前設定寫入檔案。
# Arguments: $1 - Target file path
# Arguments (zh_TW): $1 - 目標檔案路徑
write_config_content() {
    local target_file="$1"
    cat > "${target_file}" << 'EOF'
# ==============================================================================
#             LVM Snapshot Manager Configuration (lvm.conf)
#             LVM 快照管理器設定 (lvm.conf)
# ==============================================================================

# --- Global Settings ---
# --- 全域設定 ---

# Name of the Volume Group (VG)
# 磁碟區群組 (VG) 的名稱
# Replace "vg0" with the actual VG name on your system (find with 'sudo vgs').
# 請將 "vg0" 替換為您系統上實際的 VG 名稱 (可使用 'sudo vgs' 查詢)。
EOF
    echo "VG_NAME=\"$VG_NAME\"" >> "${target_file}"
    echo "" >> "${target_file}"
    echo "# Common prefix for all snapshots." >> "${target_file}"
    echo "# 所有快照的通用前綴。" >> "${target_file}"
    echo "SNAPSHOT_PREFIX=\"$SNAPSHOT_PREFIX\"" >> "${target_file}"
    echo "" >> "${target_file}"
    echo "# Buffer space (in MB) to reserve when checking VG free space." >> "${target_file}"
    echo "# 檢查 VG 可用空間時要保留的緩衝空間 (單位 MB)。" >> "${target_file}"
    echo "# This helps prevent snapshot creation failure due to insufficient LVM metadata space." >> "${target_file}"
    echo "# 這有助於避免因 LVM 中繼資料空間不足而導致快照建立失敗。" >> "${target_file}"
    echo "SPACE_BUFFER_MB=${SPACE_BUFFER_MB:-50}" >> "${target_file}"

    cat >> "${target_file}" << 'EOF'

# ==============================================================================
#                               Hooks
#                               掛鉤
# ==============================================================================
# Define scripts to be executed before or after specific actions.
# 定義在特定操作之前或之後要執行的腳本。
# Leave the path empty to disable a hook.
# 將路徑留空以停用掛鉤。
# Example: PRE_CREATE_HOOK="/usr/local/bin/pre-snapshot-script.sh"
# 範例: PRE_CREATE_HOOK="/usr/local/bin/pre-snapshot-script.sh"
PRE_CREATE_HOOK=""
POST_CREATE_HOOK=""
PRE_RESTORE_HOOK=""
POST_RESTORE_HOOK=""

# ==============================================================================
#                               Core LV Configuration
#                               核心 LV 設定
# ==============================================================================
# [IMPORTANT] Define the Logical Volumes (LVs) you want to manage here.
# [重要] 在此處定義您要管理的邏輯磁碟區 (LV)。
# An associative array is used to manage all LV properties centrally.
# 使用關聯陣列來集中管理所有 LV 的屬性。
#
# Format:
# 格式:
#   - Key: The name of the Logical Volume (e.g., "lv-main").
#   - 索引鍵: 邏輯磁碟區的名稱 (例如 "lv-main")。
#   - Value: A pipe-separated string with three fields:
#   - 值: 一個由管道符號 (|) 分隔的字串，包含三個欄位:
#     "SnapshotSize|MountPoint|Description"
#     "快照大小|掛載點|描述"
#
# Field Details:
# 欄位詳細說明:
#   1. SnapshotSize (Required): The size to allocate for the snapshot (e.g., "5G", "1024M").
#      1. 快照大小 (必要): 為快照分配的大小 (例如 "5G", "1024M")。
#   2. MountPoint (Optional): The system mount point for this LV. Used by the 'restore' command.
#      2. 掛載點 (可選): 此 LV 的系統掛載點。'restore' 指令會使用此設定。
#      - Use "none" for the root directory or if there is no mount point.
#      - 如果是根目錄或沒有掛載點，請使用 "none"。
#   3. Description (Optional): A brief description of the LV for reference.
#      3. 描述 (可選): LV 的簡要描述，供參考。
#
# --- Example Configuration ---
# --- 範例設定 ---
EOF
    echo "declare -A LV_CONFIG" >> "${target_file}"
    for lv_name in "${!LV_CONFIG[@]}"; do
        local value="${LV_CONFIG[$lv_name]}"
        echo "LV_CONFIG[\"$lv_name\"]=\"$value\"" >> "${target_file}"
    done
}

# Function: Generate a default configuration file if it doesn't exist.
# Function (zh_TW): 如果設定檔不存在，則產生預設設定檔。
# Arguments: $1 - Path for the new config file
# Arguments (zh_TW): $1 - 新設定檔的路徑
generate_default_config() {
    local config_file="$1"
    print_warning "$(printf "$MSG_CONFIG_NOT_FOUND" "$config_file")"
    print_info "$MSG_CREATING_DEFAULT_CONFIG"
    
    VG_NAME="vg0"
    SNAPSHOT_PREFIX="snap"
    SPACE_BUFFER_MB=50
    
    PRE_CREATE_HOOK=""
    POST_CREATE_HOOK=""
    PRE_RESTORE_HOOK=""
    POST_RESTORE_HOOK=""
    
    declare -A LV_CONFIG
    LV_CONFIG["lv-main"]="5G|none|Root filesystem (requires Live CD for manual restore)"
    LV_CONFIG["lv-www"]="5G|/var/www|Web server data"
    LV_CONFIG["lv-mysql"]="5G|/var/lib/mysql|Database data"

    write_config_content "${config_file}"

    if [[ -f "${config_file}" ]]; then
        print_success "$(printf "$MSG_CONFIG_CREATED_SUCCESS" "$config_file")"
        print_warning "$MSG_EDIT_CONFIG_AND_RE-RUN"
        chmod 600 "${config_file}"
        print_info "$(printf "$MSG_SET_PERMISSIONS" "$config_file")"
    else
        print_error "$(printf "$MSG_COULD_NOT_CREATE_CONFIG" "$config_file")"
    fi
}

# Function: Securely parse the configuration file.
# Function (zh_TW): 安全地解析設定檔。
# This function reads the config line by line using regex to avoid code injection risks from 'source'.
# This function (zh_TW): 此功能逐行讀取設定，使用正規表示式以避免 'source' 指令可能帶來的程式碼注入風險。
# Arguments: $1 - Path to the config file
# Arguments (zh_TW): $1 - 設定檔的路徑
parse_config() {
    local config_file="$1"
    local config_regex='^\s*([a-zA-Z0-9_]+)\s*=\s*"?([^"]*)"?\s*$'
    local lv_config_regex='^\s*LV_CONFIG\["([^"]+)"\]\s*=\s*"([^"]+)"\s*$'

    VG_NAME=""
    SNAPSHOT_PREFIX=""
    SPACE_BUFFER_MB=50
    declare -gA LV_CONFIG=()
    PRE_CREATE_HOOK=""
    POST_CREATE_HOOK=""
    PRE_RESTORE_HOOK=""
    POST_RESTORE_HOOK=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^\s*#.*$ || -z "$line" ]]; then
            continue
        fi
        if [[ "$line" =~ $lv_config_regex ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            LV_CONFIG["$key"]="$value"
        elif [[ "$line" =~ $config_regex ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            case "$key" in
                VG_NAME) VG_NAME="$value" ;;
                SNAPSHOT_PREFIX) SNAPSHOT_PREFIX="$value" ;;
                SPACE_BUFFER_MB) SPACE_BUFFER_MB="$value" ;;
                PRE_CREATE_HOOK) PRE_CREATE_HOOK="$value" ;;
                POST_CREATE_HOOK) POST_CREATE_HOOK="$value" ;;
                PRE_RESTORE_HOOK) PRE_RESTORE_HOOK="$value" ;;
                POST_RESTORE_HOOK) POST_RESTORE_HOOK="$value" ;;
            esac
        fi
    done < "$config_file"
}

# Function: Load and validate the configuration file.
# Function (zh_TW): 載入並驗證設定檔。
# Arguments: $1 - Path to the config file
# Arguments (zh_TW): $1 - 設定檔的路徑
load_config() {
    local config_file="$1"
    if [[ ! -f "${config_file}" ]]; then
        generate_default_config "${config_file}"
        exit 1
    fi

    local owner_uid
    owner_uid=$(stat -c '%u' "${config_file}")
    if [[ "$owner_uid" -ne 0 ]]; then
        print_error "$(printf "$MSG_CONFIG_SECURITY_ERROR_OWNER" "$config_file")"
        log_action "ERROR" "Configuration file '$config_file' is not owned by root."
        exit 1
    fi

    local perms
    perms=$(stat -c '%a' "${config_file}")
    if [[ "$perms" != "600" ]]; then
        print_error "$(printf "$MSG_CONFIG_SECURITY_ERROR_PERMS" "$config_file" "$perms")"
        print_error "$(printf "$MSG_CONFIG_FIX_PERMS" "$config_file")"
        log_action "ERROR" "Configuration file '$config_file' has insecure permissions: $perms."
        exit 1
    fi

    parse_config "${config_file}"

    if [[ -z "$VG_NAME" || ${#LV_CONFIG[@]} -eq 0 ]]; then
        print_error "$(printf "$MSG_CONFIG_INVALID" "$config_file")"
        log_action "ERROR" "Configuration file '$config_file' is invalid or missing required settings."
        exit 1
    fi
    validate_config_values
}

# Function: Validate the values read from the configuration file.
# Function (zh_TW): 驗證從設定檔讀取的值。
validate_config_values() {
    local is_valid=1
    local valid_name_regex='^[a-zA-Z0-9_.-]+$'
    local valid_size_regex='^[0-9]+([.][0-9]+)?[gGmMkK]$'

    if ! [[ "$VG_NAME" =~ $valid_name_regex ]]; then
        print_error "$(printf "$MSG_INVALID_CHAR_IN_VG_NAME" "$VG_NAME")"
        is_valid=0
    elif ! vgs "$VG_NAME" &>/dev/null; then
        print_error "$(printf "$MSG_VG_DOES_NOT_EXIST" "$VG_NAME")"
        is_valid=0
    fi

    for lv_name in "${!LV_CONFIG[@]}"; do
        if ! [[ "$lv_name" =~ $valid_name_regex ]]; then
            print_error "$(printf "$MSG_INVALID_CHAR_IN_LV_NAME" "$lv_name")"
            is_valid=0
        elif ! lvs "/dev/${VG_NAME}/${lv_name}" &>/dev/null; then
            print_error "$(printf "$MSG_LV_DOES_NOT_EXIST" "$lv_name" "$VG_NAME")"
            is_valid=0
        fi
        local config_string="${LV_CONFIG[$lv_name]}"
        local snapshot_size
        snapshot_size=$(echo "$config_string" | cut -d'|' -f1)
        if ! [[ "$snapshot_size" =~ $valid_size_regex ]]; then
            print_error "$(printf "$MSG_INVALID_SNAPSHOT_SIZE" "$snapshot_size" "$lv_name")"
            is_valid=0
        fi
    done

    if [[ "$is_valid" -eq 0 ]]; then
        print_error "$MSG_CONFIG_VALIDATION_FAILED"
        log_action "ERROR" "Configuration value validation failed. Please check lvm.conf."
        exit 1
    fi
}

# ==============================================================================
#                       Interactive Configuration (config command)
#                       互動式設定 (config 指令)
# ==============================================================================

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

# Main loop for the interactive configuration manager.
# Function (zh_TW): 互動式設定管理員的主迴圈。
manage_config() {
    local config_file="$1"
    while true; do
        clear
        print_header
        echo "$MSG_INTERACTIVE_CONFIG_HEADER"
        echo -e "$(printf "$MSG_CONFIG_FILE" "${YELLOW}${config_file}${NC}")"
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
                local backup_file="${config_file}.bak"
                if [[ -f "$config_file" ]]; then
                    cp "$config_file" "$backup_file"
                    print_info "$(printf "$MSG_BACKUP_CREATED" "$backup_file")"
                fi
                write_config_content "$config_file"
                print_success "$(printf "$MSG_CONFIG_SAVED" "$config_file")"
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

# ==============================================================================
#                          Main Functionality (Commands)
#                          主要功能 (指令)
# ==============================================================================

# Function: Clean up snapshots if creation fails.
# Function (zh_TW): 如果建立快照失敗，則清理快照。
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

# Function: Check if a given LV exists.
# Function (zh_TW): 檢查指定的 LV 是否存在。
# Arguments: $1 - LV name
# Arguments (zh_TW): $1 - LV 名稱
check_lv_exists() {
    local lv_name="$1"
    lvs "/dev/${VG_NAME}/${lv_name}" >/dev/null 2>&1
    return $?
}

# Function: Retry a command a specified number of times with a delay.
# Function (zh_TW): 在指定的次數內重試一個指令，並帶有延遲。
# Arguments: $1=Max Retries, $2=Delay (seconds), $3...=Command and arguments
# Arguments (zh_TW): $1=最大重試次數, $2=延遲 (秒), $3...=指令與參數
retry_command() {
    local max_retries="$1"
    local delay="$2"
    shift 2
    local cmd=("$@")
    local attempt=1

    while (( attempt <= max_retries )); do
        if "${cmd[@]}"; then
            return 0
        fi

        if (( attempt < max_retries )); then
            print_warning "$(printf "$MSG_COMMAND_FAILED_RETRYING" "$delay" "$attempt" "$max_retries")"
            sleep "$delay"
        fi
        ((attempt++))
    done

    print_error "$(printf "$MSG_COMMAND_FAILED_FINAL" "$max_retries")"
    return 1
}

# Function: Stop services related to the restore targets.
# Function (zh_TW): 停止與還原目標相關的服務。
stop_services() {
    print_info "$MSG_ANALYZING_AND_STOPPING_SERVICES"
    local services_to_stop=()
    local checked_mounts=()
    local service_blacklist=("systemd" "sshd" "cron" "dbus" "network" "udev" "systemd-journald" "systemd-logind" "init")

    for lv_name in "${!LV_CONFIG[@]}"; do
        local mount_point
        mount_point=$(echo "${LV_CONFIG[$lv_name]}" | cut -d'|' -f2)
        if [[ "$mount_point" != "none" && -n "$mount_point" ]]; then
            if ! [[ " ${checked_mounts[*]} " =~ " ${mount_point} " ]]; then
                checked_mounts+=("$mount_point")
            fi
        fi
    done

    if [[ "$HAS_LSOF" -eq 1 ]]; then
        for mount in "${checked_mounts[@]}"; do
            local pids
            pids=$(lsof +D "$mount" -t -F p 2>/dev/null | sed 's/^p//' | sort -u)
            for pid in $pids; do
                local procname service
                procname=$(ps -p "$pid" -o comm=)
                service=$(grep -oP 'system.slice/[^.]+.service' "/proc/$pid/cgroup" 2>/dev/null | head -n 1 | sed 's|system.slice/||')
                if [[ -z "$service" ]]; then
                    service=$(systemctl status "$pid" 2>/dev/null | grep '●' | awk '{print $2}')
                fi

                local is_blacklisted=0
                for blacklisted in "${service_blacklist[@]}"; do
                    if [[ "$service" == "$blacklisted" || "$procname" == "$blacklisted" ]]; then
                        is_blacklisted=1
                        break
                    fi
                done

                if [[ "$is_blacklisted" -eq 1 ]]; then
                    print_warning "$(printf "$MSG_CRITICAL_SERVICE_DETECTED" "${service:-$procname}" "$mount")"
                    continue
                fi

                if [[ -n "$service" && ! " ${services_to_stop[*]} " =~ " ${service} " ]]; then
                    print_info "$(printf "$MSG_DETECTED_SERVICE" "$service" "$pid" "$procname" "$mount")"
                    services_to_stop+=("$service")
                elif [[ ! " ${services_to_stop[*]} " =~ " ${procname} " ]]; then
                    print_info "$(printf "$MSG_DETECTED_PROCESS" "$procname" "$pid" "$mount")"
                    services_to_stop+=("$procname")
                fi
            done
        done
    else
        print_warning "$MSG_LSOF_NOT_INSTALLED"
        local default_services=("mysql" "mariadb" "apache2" "nginx" "httpd" "php-fpm" "postgresql")
        print_warning "$(printf "$MSG_DEFAULT_SERVICES_TO_STOP" "${default_services[*]}")"
        if [[ "$DRY_RUN" -eq 0 && "$FORCE_MODE" -eq 0 ]]; then
            read -p "$MSG_CONTINUE_PROMPT" -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                print_info "$MSG_OPERATION_CANCELLED"
                return
            fi
        fi
        services_to_stop=("${default_services[@]}")
    fi

    if [[ ${#services_to_stop[@]} -eq 0 ]]; then
        print_info "$MSG_NO_SERVICES_TO_STOP"
        return
    fi

    print_warning "$(printf "$MSG_SERVICES_TO_BE_STOPPED" "${services_to_stop[*]}")"
    if [[ "$DRY_RUN" -eq 0 && "$FORCE_MODE" -eq 0 ]]; then
        read -p "$MSG_PROCEED_WITH_STOPPING_SERVICES" -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "$MSG_OPERATION_CANCELLED_BY_USER"
            exit 0
        fi
    fi

    for service in "${services_to_stop[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            print_info "$(printf "$MSG_STOPPING_SERVICE" "$service")"
            if [[ "$DRY_RUN" -eq 0 ]]; then
                if ! systemctl stop "$service"; then
                    print_error "$(printf "$MSG_FAILED_TO_STOP_SERVICE" "$service")"
                    exit 1
                fi
                log_action "INFO" "Service '${service}' stopped for restore operation."
            else
                print_info "[DryRun] Simulate stopping service: $service"
            fi
        fi
    done
    sleep 2
}

# Function: Convert size string (G, M, K) to MB.
# Function (zh_TW): 將大小字串 (G, M, K) 轉換為 MB。
# Arguments: $1 - Size string (e.g., "5G")
# Arguments (zh_TW): $1 - 大小字串 (例如 "5G")
size_to_mb() {
    local size_str="${1^^}"
    local num_part val
    num_part=$(echo "$size_str" | sed -e 's/[A-Z]*$//')

    if ! [[ "$num_part" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        print_error "Invalid size value: '$1' (numeric part is invalid)"
        return 1
    fi

    if [[ "$size_str" == *"G"* ]]; then
        val=$(echo "$num_part * 1024" | bc)
    elif [[ "$size_str" == *"M"* ]]; then
        val=$num_part
    elif [[ "$size_str" == *"K"* ]]; then
        val=$(echo "scale=2; $num_part / 1024" | bc)
    else
        val=$(echo "scale=2; $num_part / (1024*1024)" | bc)
    fi
    printf "%.0f\n" "$val"
}

# Function: Execute a hook script if defined and executable.
# Function (zh_TW): 如果已定義且可執行，則執行掛鉤腳本。
# Arguments: $1=Hook Path, $2=Action, $3...=Arguments for the script
# Arguments (zh_TW): $1=掛鉤路徑, $2=動作, $3...=腳本參數
execute_hook() {
    local hook_path="$1"
    local action="$2"
    shift 2
    local args=("$@")

    if [[ -n "$hook_path" && -f "$hook_path" && -x "$hook_path" ]]; then
        print_info "Executing ${action} hook: ${hook_path}"
        log_action "INFO" "Executing ${action} hook: ${hook_path}"
        if ! "$hook_path" "$action" "${args[@]}"; then
            print_error "${action} hook failed with exit code $?. Aborting."
            log_action "ERROR" "${action} hook script '${hook_path}' failed."
            exit 1
        fi
        print_success "${action} hook completed successfully."
    fi
}

# Function: Create a new set of snapshots.
# Function (zh_TW): 建立一組新的快照。
create_snapshots() {
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
}

# Function: Restore from snapshots.
# Function (zh_TW): 從快照還原。
# Arguments: $1 - Timestamp
# Arguments (zh_TW): $1 - 時間戳記
restore_from_snapshots() {
    local TIMESTAMP="$1"
    if [[ -z "$TIMESTAMP" ]]; then
        print_error "$MSG_PROVIDE_TIMESTAMP_TO_RESTORE"
        echo "$(printf "$MSG_USAGE_RESTORE" "$0")"
        echo ""
        echo "$MSG_AVAILABLE_SNAPSHOT_TIMESTAMPS"
        lvs --noheadings -o lv_name 2>/dev/null | grep "_${SNAPSHOT_PREFIX}_" | sed "s/.*_${SNAPSHOT_PREFIX}_//" | sort -u
        exit 1
    fi
    
    print_info "$(printf "$MSG_PREPARING_TO_RESTORE" "$TIMESTAMP")"

    local MISSING_SNAPSHOTS=""
    for lv_name in "${!LV_CONFIG[@]}"; do
        local snapshot_name="${lv_name}_${SNAPSHOT_PREFIX}_${TIMESTAMP}"
        if ! check_lv_exists "${snapshot_name}"; then
            MISSING_SNAPSHOTS="${MISSING_SNAPSHOTS} ${snapshot_name}"
        fi
    done
    if [[ -n "$MISSING_SNAPSHOTS" ]]; then
        print_error "$(printf "$MSG_MISSING_SNAPSHOTS" "$MISSING_SNAPSHOTS")"
        print_info "$MSG_CHECK_TIMESTAMP"
        exit 1
    fi
    print_success "$MSG_ALL_SNAPSHOTS_FOUND"
    
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                  ⚠️  $MSG_RESTORE_WARNING_HEADER ⚠️             ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}$MSG_RESTORE_WARNING_BODY_1${NC}"
    echo "$(printf "$MSG_RESTORE_WARNING_BODY_2" "$TIMESTAMP")"
    echo "$MSG_RESTORE_WARNING_BODY_3"
    echo ""
    echo -e "${YELLOW}$MSG_RESTORE_CONFIRM_PROMPT${NC}"
    if [[ "$FORCE_MODE" -eq 0 ]]; then
        read -p "> " confirmation
        if [[ "$confirmation" != "YES I UNDERSTAND" ]]; then
            print_warning "$MSG_OPERATION_CANCELLED_BY_USER"
            log_action "INFO" "Restore operation cancelled by user."
            exit 0
        fi
    else
        print_warning "$MSG_PROCEEDING_WITH_RESTORE"
    fi
    
    if [[ "$DRY_RUN" -eq 1 ]]; then
        print_info "--- Dry Run Mode ---"
        print_info "Would stop services, unmount filesystems, and run lvconvert --merge."
        print_success "$MSG_SIMULATED_RESTORE_COMPLETE"
        log_action "INFO" "[DryRun] Simulated restore from timestamp ${TIMESTAMP}."
        return
    fi

    execute_hook "$PRE_RESTORE_HOOK" "pre-restore" "$TIMESTAMP"

    log_action "WARN" "Starting restore from timestamp ${TIMESTAMP}. This is a destructive operation."
    print_info "$MSG_CONFIRMATION_RECEIVED"
    stop_services
    
    local RESTORE_SUCCESS=0
    local RESTORE_FAILED=""
    for lv_name in "${!LV_CONFIG[@]}"; do
        local config_string="${LV_CONFIG[$lv_name]}"
        local mount_point
        mount_point=$(echo "$config_string" | cut -d'|' -f2)
        
        if [[ "$mount_point" != "none" && -n "$mount_point" ]]; then
            local snapshot_name="${lv_name}_${SNAPSHOT_PREFIX}_${TIMESTAMP}"
            echo ""
            print_info "$(printf "$MSG_PROCESSING_LV" "$mount_point" "$lv_name")"
            
            if mountpoint -q "${mount_point}" 2>/dev/null; then
                print_info "$(printf "$MSG_UNMOUNTING" "$mount_point")"
                if ! retry_command 3 5 umount "${mount_point}"; then
                    print_error "$(printf "$MSG_COULD_NOT_UNMOUNT" "$mount_point")"
                    echo "$MSG_PROCESSES_USING_MOUNTPOINT"
                    if [[ "$HAS_LSOF" -eq 1 ]]; then
                        lsof +D "${mount_point}" 2>/dev/null | head -5
                    elif [[ "$HAS_FUSER" -eq 1 ]]; then
                        fuser -vm "${mount_point}"
                    else
                        print_warning "$MSG_FUSER_LSOF_NOT_INSTALLED"
                    fi
                    RESTORE_FAILED="${RESTORE_FAILED} ${lv_name}"
                    continue
                fi
            fi
            
            print_info "$(printf "$MSG_MERGING_SNAPSHOT" "$snapshot_name")"
            if lvconvert --merge "/dev/${VG_NAME}/${snapshot_name}"; then
                print_success "$(printf "$MSG_RESTORE_CMD_ISSUED" "$lv_name")"
                RESTORE_SUCCESS=$((RESTORE_SUCCESS + 1))
            else
                print_error "$(printf "$MSG_RESTORE_FAILED" "$lv_name")"
                RESTORE_FAILED="${RESTORE_FAILED} ${lv_name}"
            fi
        fi
    done
    
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║         📋 $MSG_MANUAL_RESTORE_INSTRUCTIONS_HEADER         ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "$MSG_MANUAL_RESTORE_INSTRUCTIONS_BODY_1"
    echo "$MSG_MANUAL_RESTORE_INSTRUCTIONS_BODY_2"
    echo "$MSG_MANUAL_RESTORE_INSTRUCTIONS_BODY_3"
    echo "$(printf "$MSG_MANUAL_RESTORE_INSTRUCTIONS_BODY_4" "$VG_NAME")"
    echo "$MSG_MANUAL_RESTORE_INSTRUCTIONS_BODY_5"
    for lv_name in "${!LV_CONFIG[@]}"; do
        local mount_point
        mount_point=$(echo "${LV_CONFIG[$lv_name]}" | cut -d'|' -f2)
        if [[ "$mount_point" == "none" ]]; then
            echo "$(printf "$MSG_MANUAL_RESTORE_INSTRUCTIONS_BODY_6" "$VG_NAME" "$lv_name" "$SNAPSHOT_PREFIX" "$TIMESTAMP")"
        fi
    done
    echo "$MSG_MANUAL_RESTORE_INSTRUCTIONS_BODY_7"
    
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                         $MSG_EXECUTION_SUMMARY                      ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    if [[ $RESTORE_SUCCESS -gt 0 ]]; then
        print_success "$(printf "$MSG_SUCCESSFUL_ONLINE_RESTORES" "$RESTORE_SUCCESS")"
    fi
    if [[ -n "$RESTORE_FAILED" ]]; then
        print_error "$(printf "$MSG_FAILED_RESTORES" "$RESTORE_FAILED")"
    fi

    echo ""
    read -p "$MSG_REBOOT_NOW_PROMPT" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "$MSG_SYSTEM_WILL_REBOOT"
        sleep 5
        reboot
    else
        print_info "$MSG_REMEMBER_TO_REBOOT"
    fi
    
    execute_hook "$POST_RESTORE_HOOK" "post-restore" "$TIMESTAMP"
}

# Function: List details of all snapshots.
# Function (zh_TW): 列出所有快照的詳細資訊。
list_snapshots() {
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

# Function: Check the health of the LVM environment.
# Function (zh_TW): 檢查 LVM 環境的健康狀況。
check_system_health() {
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

# Function: List snapshot groups by timestamp.
# Function (zh_TW): 按時間戳記列出快照群組。
list_snapshot_groups() {
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

# Function: Enter real-time monitoring mode.
# Function (zh_TW): 進入即時監控模式。
monitor_snapshots() {
    echo -e "${BLUE}[Snapshot Monitor Mode]${NC} - Press Ctrl+C to exit"
    trap 'echo -e "\n${YELLOW}Monitoring stopped.${NC}"; exit 0' INT
    
    while true; do
        clear
        print_header
        echo -e "${CYAN}Live Snapshot Status - $(date '+%Y-%m-%d %H:%M:%S')${NC}"
        list_snapshots
        echo ""
        check_snapshot_health
        echo ""
        echo -e "${YELLOW}Hint: Consider extending or deleting snapshots with usage over 80%.${NC}"
        sleep 5
    done
}

# Function: Delete a single snapshot.
# Function (zh_TW): 刪除單一快照。
# Arguments: $1 - Snapshot name
# Arguments (zh_TW): $1 - 快照名稱
delete_snapshot() {
    local snapshot_name="$1"
    if [[ -z "$snapshot_name" ]]; then
        print_error "Please provide a snapshot name."
        echo "Usage: sudo $0 delete <snapshot_name>"
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

# Function: Delete an entire snapshot group.
# Function (zh_TW): 刪除整個快照群組。
# Arguments: $1 - Timestamp
# Arguments (zh_TW): $1 - 時間戳記
delete_snapshot_group() {
    local timestamp="$1"
    if [[ -z "$timestamp" ]]; then
        print_error "Please provide a timestamp."
        echo "Usage: sudo $0 delete-group <timestamp>"
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

# Function: Create a logrotate configuration file.
# Function (zh_TW): 建立 logrotate 設定檔。
setup_logrotate() {
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

# Function: Purge old snapshots based on command-line arguments.
# Function (zh_TW): 根據命令列參數清除舊快照。
purge_snapshots() {
    local keep_last=""
    local older_than=""

    if [[ "$1" == "--help" ]]; then
        echo "Usage: $0 purge [OPTIONS]"
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
                print_error "Unknown argument for purge: $1"
                exit 1
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

    for ts in "${timestamps_to_delete[@]}"; do
        delete_snapshot_group "$ts"
    done

    FORCE_MODE=$original_force_mode

    print_success "$MSG_PURGE_COMPLETE"
}

# Function: Extend the size of an existing snapshot.
# Function (zh_TW): 擴充現有快照的大小。
# Arguments: $1 - Snapshot name, $2 - Size to add (e.g., 1G)
# Arguments (zh_TW): $1 - 快照名稱, $2 - 要增加的大小 (例如 1G)
extend_snapshot() {
    local snapshot_name="$1"
    local extend_size="$2"

    if [[ -z "$snapshot_name" || -z "$extend_size" ]]; then
        print_error "Usage: $0 extend <snapshot_name> <size>"
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

# ==============================================================================
#                                Main Execution Logic
#                                主執行邏輯
# ==============================================================================

# Function: Check for required command-line dependencies.
# Function (zh_TW): 檢查所需的命令列相依性。
check_dependencies() {
    local missing_cmds=()
    local core_cmds=("lvs" "vgs" "lvcreate" "lvconvert" "lvremove" "systemctl" "awk" "stat" "bc" "flock")

    for cmd in "${core_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_cmds+=("$cmd")
        fi
    done

    if [[ ${#missing_cmds[@]} -gt 0 ]]; then
        print_error "The following required commands are missing:"
        for cmd in "${missing_cmds[@]}"; do
            echo -n "  - $cmd"
            case $cmd in
                awk) echo " (Install with: sudo apt-get install gawk)" ;;
                bc) echo " (Install with: sudo apt-get install bc)" ;;
                flock) echo " (Install with: sudo apt-get install util-linux)" ;;
                systemctl) echo " (This script requires a systemd-based OS)" ;;
                stat) echo " (Provided by the 'coreutils' package)" ;;
                *) echo " (Provided by the 'lvm2' package)" ;;
            esac
        done
        exit 1
    fi
}

main() {
    load_language

    if [[ $EUID -ne 0 ]]; then
        print_error "$MSG_MUST_BE_ROOT"
        exit 1
    fi

    # Concurrency lock to prevent multiple instances from running.
    # 並行鎖，防止多個實例同時運行。
    exec 200>"$LOCK_FILE"
    flock -n 200 || {
        print_error "$MSG_ANOTHER_INSTANCE_RUNNING"
        exit 1
    }
    # The file descriptor 200 will be released, and the lock file removed, upon exit.
    # 結束時，檔案描述符 200 將被釋放，鎖定檔案也將被移除。
    trap 'rm -f "$LOCK_FILE"' EXIT
    
    initialize_log
    check_dependencies

    local CONFIG_FILE="${SCRIPT_DIR}/lvm.conf"
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
    
    if [[ "$COMMAND" != "help" && "$COMMAND" != "" && "$COMMAND" != "config" ]]; then
        log_action "EXEC" "Command: '${COMMAND}', Arguments: '${ARGS[*]}'"
    fi
    
    case "$COMMAND" in
        config)             print_header; manage_config "${CONFIG_FILE}" ;;
        create)             print_header; create_snapshots ;;
        restore)            print_header; restore_from_snapshots "${ARGS[0]}" ;;
        list)               print_header; list_snapshots ;;
        list-groups)        print_header; list_snapshot_groups ;;
        monitor)            monitor_snapshots ;;
        delete)             print_header; delete_snapshot "${ARGS[0]}" ;;
        delete-group)       print_header; delete_snapshot_group "${ARGS[0]}" ;;
        extend)             print_header; extend_snapshot "${ARGS[0]}" "${ARGS[1]}" ;;
        check-health)       print_header; check_system_health ;;
        purge)              print_header; purge_snapshots "${ARGS[@]}" ;;
        setup-logrotate)    print_header; setup_logrotate ;;
        "" | "-h" | "--help" | "help") show_usage ;;
        *)                  print_error "Unknown command: '$COMMAND'"; show_usage; exit 1 ;;
    esac
}

main "$@"
