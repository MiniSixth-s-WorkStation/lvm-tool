#!/bin/bash

# ==============================================================================
# Module Name: restore.sh
# Description: Handles restoring LVMs from a specified snapshot group.
# Description (zh_TW): 處理從指定的快照群組還原 LVM。
# ==============================================================================

# --- Command Definition ---
# --- 指令定義 ---
COMMAND="restore"
DESCRIPTION="Restore the system from a specified snapshot group."
DESCRIPTION_ZH="從指定的快照群組還原系統。"

# --- Function: stop_services ---
# --- 功能: stop_services ---
# Description: Stop services related to the restore targets.
# Description (zh_TW): 停止與還原目標相關的服務。
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

# --- Function: command_main ---
# --- 功能: command_main ---
# Description: Main function for the 'restore' command.
# Description (zh_TW): 'restore' 指令的主功能。
# Arguments: $1 - Timestamp
# Arguments (zh_TW): $1 - 時間戳記
command_main() {
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