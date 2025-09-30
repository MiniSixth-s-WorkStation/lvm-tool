#!/bin/bash

# ==============================================================================
# Module Name: volume.sh
# Description: Handles LVM volume management (PV, VG, LV).
# Description (zh_TW): 處理 LVM 磁區管理 (PV, VG, LV)。
# ==============================================================================

MODULE_CATEGORY="Volume Management"

# --- Command Definitions ---
COMMAND_PVS="pvs"
DESCRIPTION_PVS="Display information about Physical Volumes (PVs)."
DESCRIPTION_PVS_ZH="顯示實體磁區 (PV) 的資訊。"

COMMAND_VGS="vgs"
DESCRIPTION_VGS="Display information about Volume Groups (VGs)."
DESCRIPTION_VGS_ZH="顯示磁碟區群組 (VG) 的資訊。"

COMMAND_LVS="lvs"
DESCRIPTION_LVS="Display information about Logical Volumes (LVs)."
DESCRIPTION_LVS_ZH="顯示邏輯磁碟區 (LV) 的資訊。"

COMMAND_PVCREATE="pv-create"
DESCRIPTION_PVCREATE="Create a Physical Volume (PV) on a device."
DESCRIPTION_PVCREATE_ZH="在裝置上建立實體磁區 (PV)。"

COMMAND_VGCREATE="vg-create"
DESCRIPTION_VGCREATE="Create a Volume Group (VG) from one or more PVs."
DESCRIPTION_VGCREATE_ZH="從一個或多個 PV 建立磁碟區群組 (VG)。"

COMMAND_LVCREATE="lv-create"
DESCRIPTION_LVCREATE="Create a Logical Volume (LV) in a VG."
DESCRIPTION_LVCREATE_ZH="在 VG 中建立邏輯磁碟區 (LV)。"

COMMAND_LVEXTEND="lv-extend"
DESCRIPTION_LVEXTEND="Extend the size of a Logical Volume (LV)."
DESCRIPTION_LVEXTEND_ZH="擴充邏輯磁碟區 (LV) 的大小。"

COMMAND_LVREMOVE="lv-remove"
DESCRIPTION_LVREMOVE="Remove a Logical Volume (LV)."
DESCRIPTION_LVREMOVE_ZH="移除邏輯磁碟區 (LV)。"

COMMAND_VGREMOVE="vg-remove"
DESCRIPTION_VGREMOVE="Remove a Volume Group (VG)."
DESCRIPTION_VGREMOVE_ZH="移除磁碟區群組 (VG)。"

COMMAND_PVREMOVE="pv-remove"
DESCRIPTION_PVREMOVE="Remove a Physical Volume (PV)."
DESCRIPTION_PVREMOVE_ZH="移除實體磁區 (PV)。"

# --- Helper Functions ---
confirm_action() {
    local prompt="$1"
    if [[ "$FORCE_MODE" -eq 1 ]]; then
        return 0
    fi
    read -p "$prompt [y/N]: " -n 1 -r
    echo
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# --- Main Command Functions ---

command_pvs() {
    print_info "$DESCRIPTION_PVS"
    if ! pvs -o+pv_used; then
        print_error "Failed to execute 'pvs' command."
        return 1
    fi
}

command_vgs() {
    print_info "$DESCRIPTION_VGS"
    if ! vgs; then
        print_error "Failed to execute 'vgs' command."
        return 1
    fi
}

command_lvs() {
    print_info "$DESCRIPTION_LVS"
    if ! lvs -o+lv_path,lv_size; then
        print_error "Failed to execute 'lvs' command."
        return 1
    fi
}

command_pv_create() {
    local device="$1"
    if [[ -z "$device" ]]; then
        print_error "Usage: $0 pv-create <device_path>"
        return 1
    fi
    if confirm_action "Are you sure you want to initialize '$device' for LVM?"; then
        print_info "Creating Physical Volume on '$device'..."
        if ! pvcreate "$device"; then
            print_error "Failed to create PV on '$device'."
            return 1
        fi
        print_success "Successfully created PV on '$device'."
    else
        print_warning "Operation cancelled."
    fi
}

command_vg_create() {
    local vg_name="$1"
    shift
    local devices=("$@")
    if [[ -z "$vg_name" || ${#devices[@]} -eq 0 ]]; then
        print_error "Usage: $0 vg-create <vg_name> <device1> [device2...]"
        return 1
    fi
    if confirm_action "Are you sure you want to create VG '$vg_name' with devices: ${devices[*]}?"; then
        print_info "Creating Volume Group '$vg_name'..."
        if ! vgcreate "$vg_name" "${devices[@]}"; then
            print_error "Failed to create VG '$vg_name'."
            return 1
        fi
        print_success "Successfully created VG '$vg_name'."
    else
        print_warning "Operation cancelled."
    fi
}

command_lv_create() {
    local vg_name="$1"
    local lv_name="$2"
    local size="$3"
    if [[ -z "$vg_name" || -z "$lv_name" || -z "$size" ]]; then
        print_error "Usage: $0 lv-create <vg_name> <lv_name> <size (e.g., 10G, 50%FREE)>"
        return 1
    fi
    if confirm_action "Are you sure you want to create LV '$lv_name' of size '$size' in VG '$vg_name'?"; then
        print_info "Creating Logical Volume '$lv_name'..."
        if ! lvcreate -n "$lv_name" -L "$size" "$vg_name"; then
            print_error "Failed to create LV '$lv_name'."
            return 1
        fi
        print_success "Successfully created LV '$lv_name' in VG '$vg_name'."
    else
        print_warning "Operation cancelled."
    fi
}

command_lv_extend() {
    local lv_path="$1"
    local size="$2"
    if [[ -z "$lv_path" || -z "$size" ]]; then
        print_error "Usage: $0 lv-extend <lv_path (e.g., /dev/vg0/lv-main)> <size_to_add (e.g., +5G, +100%FREE)>"
        return 1
    fi
    if confirm_action "Are you sure you want to extend LV '$lv_path' by '$size'?"; then
        print_info "Extending Logical Volume '$lv_path'..."
        if ! lvextend -L "$size" "$lv_path"; then
            print_error "Failed to extend LV '$lv_path'."
            return 1
        fi
        print_success "Successfully extended LV '$lv_path'."
        print_warning "Remember to resize the filesystem (e.g., resize2fs, xfs_growfs)."
    else
        print_warning "Operation cancelled."
    fi
}

command_lv_remove() {
    local lv_path="$1"
    if [[ -z "$lv_path" ]]; then
        print_error "Usage: $0 lv-remove <lv_path>"
        return 1
    fi
    if confirm_action "ARE YOU SURE you want to permanently remove LV '$lv_path'? This is irreversible."; then
        print_info "Removing Logical Volume '$lv_path'..."
        if ! lvremove -f "$lv_path"; then
            print_error "Failed to remove LV '$lv_path'."
            return 1
        fi
        print_success "Successfully removed LV '$lv_path'."
    else
        print_warning "Operation cancelled."
    fi
}

command_vg_remove() {
    local vg_name="$1"
    if [[ -z "$vg_name" ]]; then
        print_error "Usage: $0 vg-remove <vg_name>"
        return 1
    fi
    if confirm_action "ARE YOU SURE you want to permanently remove VG '$vg_name' and all its LVs?"; then
        print_info "Removing Volume Group '$vg_name'..."
        if ! vgremove -f "$vg_name"; then
            print_error "Failed to remove VG '$vg_name'."
            return 1
        fi
        print_success "Successfully removed VG '$vg_name'."
    else
        print_warning "Operation cancelled."
    fi
}

command_pv_remove() {
    local device="$1"
    if [[ -z "$device" ]]; then
        print_error "Usage: $0 pv-remove <device_path>"
        return 1
    fi
    if confirm_action "Are you sure you want to remove PV '$device' from LVM management?"; then
        print_info "Removing Physical Volume '$device'..."
        if ! pvremove "$device"; then
            print_error "Failed to remove PV '$device'."
            return 1
        fi
        print_success "Successfully removed PV '$device'."
    else
        print_warning "Operation cancelled."
    fi
}