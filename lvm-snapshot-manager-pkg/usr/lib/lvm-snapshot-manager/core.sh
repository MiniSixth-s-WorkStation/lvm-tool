#!/bin/bash

# ==============================================================================
# Script Name: core.sh
# Description: Core library for LVM Snapshot Manager.
#              Contains shared functions for logging, color output, configuration,
#              and language handling.
# Description (zh_TW): LVM 快照管理員的核心函式庫。
#                      包含日誌、顏色輸出、設定和語言處理的共享功能。
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
# SCRIPT_DIR is now LIB_DIR, pointing to the library location
LIB_DIR=$(dirname "$(readlink -f "$0")")
CONFIG_FILE="/etc/lvm-snapshot-manager/lvm.conf"


# --- Language and Text Functions ---
# --- 語言與文字功能 ---
load_language() {
    local lang_file
    # The lang files will be installed to a system path
    local lang_dir="/usr/share/lvm-snapshot-manager"
    if [[ "${LANG}" == "zh_TW"* ]]; then
        lang_file="${lang_dir}/lang.zh_TW"
    else
        lang_file="${lang_dir}/lang.en"
    fi

    if [[ -f "$lang_file" ]]; then
        source "$lang_file"
    else
        echo "ERROR: Language file not found: $lang_file"
        # Provide basic English fallback if language files are missing
        MSG_ERROR="ERROR"
        MSG_INFO="INFO"
        MSG_SUCCESS="SUCCESS"
        MSG_WARNING="WARNING"
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
    # In a package, permissions should be set by the package manager
    # but we can do a courtesy check.
    chown root:adm "$LOG_FILE" 2>/dev/null || true
    chmod 640 "$LOG_FILE" 2>/dev/null || true
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
    echo "Usage: sudo $(basename $0) [OPTIONS] [COMMAND] [ARGUMENTS...]"
    echo ""
    echo "Options:"
    echo "  -c, --config FILE   Specify a custom configuration file path."
    echo "                      Defaults to '/etc/lvm-snapshot-manager/lvm.conf'."
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

    # Ensure the directory exists
    mkdir -p "$(dirname "${config_file}")"

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

# ==============================================================================
#                           Snapshot Data Functions
#                           快照資料功能
# ==============================================================================

# Function: Get raw snapshot data from LVM.
# Function (zh_TW): 從 LVM 取得原始快照資料。
core_get_snapshot_data() {
    lvs --noheadings -o lv_name,origin,lv_size,snap_percent,lv_attr --separator=',' 2>/dev/null | awk -F',' '
        substr($5, 1, 1) == "s" {
            timestamp = $1;
            sub(/.*_'"${SNAPSHOT_PREFIX}"'_/, "", timestamp);
            printf "%s,%s,%s,%.2f,%s\n", $1, $2, $3, $4, timestamp;
        }
    ' | sort
}

# Function: Display formatted snapshot data in a table.
# Function (zh_TW): 在表格中顯示格式化的快照資料。
# Arguments: $1 - Snapshot data generated by core_get_snapshot_data
# Arguments (zh_TW): $1 - 由 core_get_snapshot_data 產生的快照資料
core_display_snapshot_data() {
    local snapshot_data="$1"
    
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

    # Check for 'column' utility for table formatting
    local HAS_COLUMN=0
    if command -v column &> /dev/null; then
        HAS_COLUMN=1
    fi

    if [[ "$HAS_COLUMN" -eq 1 ]]; then
        echo "$formatted_output" | column -t -s ','
    else
        echo "$formatted_output" | sed 's/,/\t/g'
        if [[ -z "$COLUMN_WARN_SHOWN" ]]; then
            print_warning "$MSG_COLUMN_UTILITY_NOT_FOUND"
            # Set a global variable to prevent repeated warnings
            COLUMN_WARN_SHOWN=1
        fi
    fi
    echo "========================================================================================"
}

# Function: Delete all snapshots within a specific group.
# Function (zh_TW): 刪除特定群組中的所有快照。
# Arguments: $1 - Timestamp of the group to delete
# Arguments (zh_TW): $1 - 要刪除的群組的時間戳記
core_delete_snapshot_group() {
    local timestamp="$1"
    
    local snapshots
    snapshots=$(lvs --noheadings -o lv_name 2>/dev/null | grep "_${SNAPSHOT_PREFIX}_${timestamp}")
    
    if [[ -z "$snapshots" ]]; then
        print_warning "No snapshots found for timestamp '${timestamp}' to delete."
        return 1 # Indicate nothing was found
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        print_info "[DryRun] Would delete the following snapshots for group '${timestamp}':"
        for snap in $snapshots; do
            echo "  - $snap"
        done
        log_action "INFO" "[DryRun] Simulated deletion of snapshot group '${timestamp}'."
        return 0
    fi

    log_action "WARN" "Attempting to delete snapshot group with timestamp '${timestamp}'."
    local delete_count=0
    local fail_count=0
    
    for snap in $snapshots; do
        local cmd_args=()
        if [[ "$FORCE_MODE" -eq 1 ]]; then
            cmd_args+=("-f")
        fi
        
        if lvremove "${cmd_args[@]}" "/dev/${VG_NAME}/${snap}"; then
            print_success "  ✓ Deleted: ${snap}"
            log_action "SUCCESS" "Snapshot '${snap}' from group '${timestamp}' deleted."
            delete_count=$((delete_count + 1))
        else
            print_error "  ✗ Failed to delete: ${snap}"
            log_action "ERROR" "Failed to delete snapshot '${snap}' from group '${timestamp}'."
            fail_count=$((fail_count + 1))
        fi
    done
    
    print_info "Group deletion summary for '${timestamp}': Succeeded: ${delete_count}, Failed: ${fail_count}"
    
    if [[ "$fail_count" -gt 0 ]]; then
        return 1 # Indicate failure
    else
        return 0 # Indicate success
    fi
}


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