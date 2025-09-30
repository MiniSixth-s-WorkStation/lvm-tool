# LVM Snapshot Manager (lvm-snapshot-manager.sh)

This document provides a comprehensive guide to the `lvm-snapshot-manager.sh` script. It is available in both Traditional Chinese and English.

- [繁體中文說明](#繁體中文說明)
- [English Documentation](#english-documentation)

---

## 繁體中文說明

### 簡介

`lvm-snapshot-manager.sh` 是一個功能強大的 Bash shell script，旨在簡化與自動化 Linux 系統上的 LVM (Logical Volume Manager) 快照管理。它將快照的建立、還原、刪除、列表與監控等常用功能整合到一個統一的命令列介面中，特別適合需要對多個邏輯卷 (LV) 進行一致性備份與還原的系統管理員。

此腳本透過一個中央設定檔 (`lvm.conf`) 來管理所有目標 LV，並以時間戳為基礎建立快照「群組」，確保了資料在特定時間點的一致性。

### 功能特色

- **集中式設定**: 透過 `lvm.conf` 檔案，輕鬆管理所有需要備份的邏輯卷 (LV)、快照大小及相關屬性。
- **互動式設定管理**: 提供 `config` 指令，讓使用者可以透過互動式選單輕鬆新增、修改或刪除 LV 設定。
- **快照群組**: 所有快照皆以時間戳命名，形成一個「快照組」，方便對同一時間點的所有 LV 進行集體操作。
- **安全的還原機制**: 還原操作前會有多重警告與確認機制，防止意外操作。對於正在使用的檔案系統（如根目錄），腳本會提供詳細的離線還原指南。
- **智慧型服務管理**: 在還原前，會自動偵測並嘗試停止正在使用相關檔案系統的服務 (如 MySQL, Apache)，確保資料一致性。
- **空間檢查與保護**: 在建立快照前，會自動計算並檢查 Volume Group (VG) 是否有足夠的剩餘空間，避免因空間不足導致操作失敗。
- **詳細的列表與監控**:
    - `list`: 顯示所有獨立快照的詳細資訊，包含使用率，並以顏色標示健康狀態。
    - `list-groups`: 以時間戳為單位，清晰地展示每個快照組。
    - `monitor`: 進入即時監控模式，動態刷新快照使用率。
- **日誌與稽核**: 所有重要操作都會記錄到 `/var/log/lvm-snapshot-manager.log`，並提供 `setup-logrotate` 功能以自動管理日誌輪替。
- **安全性**:
    - 腳本必須以 `root` 權限執行。
    - 設定檔 `lvm.conf` 具有嚴格的權限與擁有者檢查，防止未授權的修改。
- **模擬執行模式 (`--dry-run`)**: 顯示將要執行的操作，但不會對系統做任何實際變更，適合在正式執行前進行預覽。

### 相依性與前置作業

在您使用此腳本之前，請確保您的系統滿足以下要求：

1.  **作業系統**:
    一個支援 LVM2 和 systemd 的現代 Linux 發行版 (例如 Ubuntu 18.04+, CentOS 7+, Debian 9+)。

2.  **核心工具 (必要)**:
    - `lvm2`: LVM 管理工具集。
    - `gawk`: 用於文本處理。
    - `bc`: 用於數學計算。
    - `coreutils`: 提供 `stat` 等基本指令。

    在 Debian/Ubuntu 系統上，您可以使用以下指令安裝：
    ```bash
    sudo apt-get update
    sudo apt-get install lvm2 gawk bc coreutils
    ```

3.  **可選工具 (建議)**:
    - `lsof`: 用於在還原操作前，更精準地偵測正在使用掛載點的程序。
    - `bsdmainutils`: 提供 `column` 工具，可以美化 `list` 指令的輸出格式。

    安裝建議工具：
    ```bash
    sudo apt-get install lsof bsdmainutils
    ```

4.  **LVM 環境**:
    您的系統必須已經設定並使用 LVM。您需要知道您的 **Volume Group (VG)** 名稱，以及您希望管理的所有 **Logical Volume (LV)** 的名稱。您可以使用 `sudo vgs` 和 `sudo lvs` 來查詢這些資訊。

### 安裝與設定

1.  **下載腳本**:
    將 `lvm-snapshot-manager.sh` 儲存到您的伺服器上，例如 `/usr/local/sbin/`。

2.  **設定執行權限**:
    確保腳本是可執行的：
    ```bash
    chmod +x lvm-snapshot-manager.sh
    ```

3.  **產生設定檔**:
    首次執行 `config` 指令，腳本會在您指定的目錄（或腳本所在目錄）下自動建立一個 `lvm.conf` 範本檔案。
    ```bash
    sudo ./lvm-snapshot-manager.sh config
    ```

4.  **編輯設定檔**:
    打開 `lvm.conf` 並根據您的 LVM 環境進行修改。最重要的部分是 `VG_NAME` 和 `LV_CONFIG` 陣列。

    **`LV_CONFIG` 格式說明**:
    ```bash
    # 格式: LV_CONFIG["<LV名稱>"]="<快照大小>|<掛載點>|<描述>"
    LV_CONFIG["lv-www"]="5G|/var/www|Web Server Data"
    LV_CONFIG["lv-mysql"]="10G|/var/lib/mysql|Database"
    ```
    - **掛載點**: 如果是根目錄或無特定掛載點，請填 `none`。

### 使用方法

所有指令都必須以 `root` 權限執行。

```bash
sudo ./lvm-snapshot-manager.sh [選項] [指令] [參數...]
```

**全域選項**:

- `--dry-run`: 模擬執行，不進行任何實際變更。
- `--force`, `--yes`: 在需要確認的刪除或還原操作中，自動回答 'yes'。
- `-c`, `--config FILE`: 指定一個自訂的設定檔路徑。
- `--format [json|csv]`: 指定 `list` 和 `list-groups` 指令的輸出格式。

### 指令說明

#### 互動模式

- **`interactive`**:
  進入一個互動式的選單模式，讓您可以透過選單引導來執行大部分的管理任務，降低指令的記憶負擔。
  ```bash
  sudo ./lvm-snapshot-manager.sh interactive
  ```

#### 快照管理

- **`create`**:
  為 `lvm.conf` 中設定的所有 LV 建立一組新的快照。
  ```bash
  sudo ./lvm-snapshot-manager.sh create
  ```
 
- **`list`**:
  列出系統上所有由本工具管理的快照，包含其大小與目前使用率。可搭配 `--format` 選項變更輸出格式。
  ```bash
  sudo ./lvm-snapshot-manager.sh list
  sudo ./lvm-snapshot-manager.sh --format json list
  ```
 
- **`list-groups`**:
  以時間戳為單位，列出所有快照組。可搭配 `--format` 選項變更輸出格式。
  ```bash
  sudo ./lvm-snapshot-manager.sh list-groups
  ```
 
- **`restore <時間戳>`**:
  從指定的快照組還原。這是一個危險操作，請謹慎使用。
  ```bash
  sudo ./lvm-snapshot-manager.sh restore 20250926_103000
  ```
 
- **`delete <快照名稱>`**:
  刪除一個指定的快照。
  ```bash
  sudo ./lvm-snapshot-manager.sh delete lv-www_snap_20250926_103000
  ```
 
- **`delete-group <時間戳>`**:
  刪除與指定時間戳相關的所有快照。
  ```bash
  sudo ./lvm-snapshot-manager.sh delete-group 20250926_103000
  ```
 
- **`extend <快照名稱> <增加的大小>`**:
  擴充一個現有快照的儲存空間。當快照使用率過高時非常有用。
  ```bash
  sudo ./lvm-snapshot-manager.sh extend lv-www_snap_20250926_103000 1G
  ```
 
- **`purge [選項]`**:
  根據指定的條件清除舊的快照群組。
  - `--keep-last <N>`: 保留最新的 N 個快照群組。
  - `--older-than <AGE>`: 刪除早於 AGE 的快照群組 (例如 7d, 4w, 1m)。
  ```bash
  # 刪除超過兩週，但保留最新的 5 個快照群組
  sudo ./lvm-snapshot-manager.sh purge --keep-last 5 --older-than 2w
  ```
 
- **`monitor`**:
  進入即時監控模式，每 5 秒刷新一次快照狀態。
  ```bash
  sudo ./lvm-snapshot-manager.sh monitor
  ```
 
- **`check-health`**:
  檢查所有快照的健康狀態，並對使用率過高的快照提出警告。
  ```bash
  sudo ./lvm-snapshot-manager.sh check-health
  ```

#### 磁區管理

- **`pvs`**: 顯示實體磁區 (PV) 的資訊。
- **`vgs`**: 顯示磁碟區群組 (VG) 的資訊。
- **`lvs`**: 顯示邏輯磁碟區 (LV) 的資訊。
- **`pv-create <裝置路徑>`**: 在指定的裝置上建立一個 PV。
- **`vg-create <VG名稱> <裝置1> [裝置2...]`**: 使用一個或多個 PV 建立一個 VG。
- **`lv-create <VG名稱> <LV名稱> <大小>`**: 在指定的 VG 中建立一個 LV。
- **`lv-extend <LV路徑> <增加的大小>`**: 擴充一個 LV 的大小。
- **`lv-remove <LV路徑>`**: 刪除一個 LV。
- **`vg-remove <VG名稱>`**: 刪除一個 VG。
- **`pv-remove <裝置路徑>`**: 刪除一個 PV。

#### 其他指令
 
- **`config`**:
  進入互動式選單，方便地管理 `lvm.conf` 設定。
  ```bash
  sudo ./lvm-snapshot-manager.sh config
  ```
 
- **`setup-logrotate`**:
  在 `/etc/logrotate.d/` 目錄下建立一個設定檔，用於自動管理本腳本的日誌檔案。
  ```bash
  sudo ./lvm-snapshot-manager.sh setup-logrotate
  ```
 
- **`help`**:
  顯示說明訊息。
  ```bash
  sudo ./lvm-snapshot-manager.sh help
  ```

---

## English Documentation

### Introduction

`lvm-snapshot-manager.sh` is a powerful Bash shell script designed to simplify and automate LVM (Logical Volume Manager) snapshot management on Linux systems. It integrates common tasks such as creating, restoring, deleting, listing, and monitoring snapshots into a single, unified command-line interface. It is particularly useful for system administrators who need to perform consistent backups and restores across multiple Logical Volumes (LVs).

The script operates based on a central configuration file (`lvm.conf`) and creates timestamp-based snapshot "groups" to ensure data consistency at a specific point in time.

### Features

- **Centralized Configuration**: Easily manage all target Logical Volumes (LVs), snapshot sizes, and related properties through the `lvm.conf` file.
- **Interactive Configuration**: The `config` command provides an interactive menu to easily add, modify, or delete LV settings.
- **Snapshot Groups**: All snapshots are named with a timestamp, forming a "snapshot group" that facilitates collective operations on all LVs at the same point in time.
- **Safe Restore Mechanism**: The restore operation includes multiple warnings and a confirmation step to prevent accidental data loss. For in-use filesystems (like the root directory), the script provides detailed offline restore instructions.
- **Smart Service Handling**: Before a restore, the script automatically detects and attempts to stop services (e.g., MySQL, Apache) that are using the relevant filesystems to ensure data consistency.
- **Space Check & Protection**: Before creating snapshots, it automatically calculates the required space and checks if the Volume Group (VG) has enough free space, preventing failures due to insufficient capacity.
- **Detailed Listing & Monitoring**:
    - `list`: Displays detailed information for all individual snapshots, including usage percentage with color-coded health status.
    - `list-groups`: Clearly presents all snapshot groups organized by timestamp.
    - `monitor`: Enters a real-time monitoring mode that dynamically refreshes snapshot usage.
- **Logging & Auditing**: All significant actions are logged to `/var/log/lvm-snapshot-manager.log`, and a `setup-logrotate` command is provided to automate log rotation.
- **Security**:
    - The script must be run with `root` privileges.
    - The configuration file `lvm.conf` is checked for strict permissions and ownership to prevent unauthorized modifications.
- **Dry Run Mode (`--dry-run`)**: Shows the operations that would be performed without making any actual changes to the system, perfect for previewing actions.

### Dependencies and Prerequisites

Before using this script, please ensure your system meets the following requirements:

1.  **Operating System**:
    A modern Linux distribution with support for LVM2 and systemd (e.g., Ubuntu 18.04+, CentOS 7+, Debian 9+).

2.  **Core Tools (Required)**:
    - `lvm2`: The LVM toolset.
    - `gawk`: For text processing.
    - `bc`: For arbitrary precision arithmetic.
    - `coreutils`: Provides basic commands like `stat`.

    On Debian/Ubuntu systems, you can install them with:
    ```bash
    sudo apt-get update
    sudo apt-get install lvm2 gawk bc coreutils
    ```

3.  **Optional Tools (Recommended)**:
    - `lsof`: Enables more accurate detection of processes using a mount point before a restore operation.
    - `bsdmainutils`: Provides the `column` utility for a nicely formatted output of the `list` command.

    To install the recommended tools:
    ```bash
    sudo apt-get install lsof bsdmainutils
    ```

4.  **LVM Environment**:
    Your system must be configured to use LVM. You need to know your **Volume Group (VG)** name and the names of the **Logical Volumes (LVs)** you wish to manage. You can find this information using `sudo vgs` and `sudo lvs`.

### Installation and Configuration

1.  **Download the Script**:
    Save `lvm-snapshot-manager.sh` to a suitable location on your server, such as `/usr/local/sbin/`.

2.  **Set Executable Permissions**:
    Make the script executable:
    ```bash
    chmod +x lvm-snapshot-manager.sh
    ```

3.  **Generate the Configuration File**:
    The first time you run the `config` command, the script will automatically create a template `lvm.conf` file in the script's directory (or a specified path).
    ```bash
    sudo ./lvm-snapshot-manager.sh config
    ```

4.  **Edit the Configuration File**:
    Open `lvm.conf` and customize it for your LVM environment. The most important settings are `VG_NAME` and the `LV_CONFIG` array.

    **`LV_CONFIG` Format**:
    ```bash
    # Format: LV_CONFIG["<LV_NAME>"]="<SNAPSHOT_SIZE>|<MOUNT_POINT>|<DESCRIPTION>"
    LV_CONFIG["lv-www"]="5G|/var/www|Web Server Data"
    LV_CONFIG["lv-mysql"]="10G|/var/lib/mysql|Database"
    ```
    - **Mount Point**: If it's the root directory or has no specific mount point, use `none`.

### Usage

All commands must be executed with `root` privileges.

```bash
sudo ./lvm-snapshot-manager.sh [OPTIONS] [COMMAND] [ARGUMENTS...]
```

**Global Options**:

- `--dry-run`: Simulate execution without making any actual changes.
- `--force`, `--yes`: Automatically answer 'yes' to confirmation prompts during delete or restore operations.
- `-c`, `--config FILE`: Specify a custom path to the configuration file.
- `--format [json|csv]`: Specify the output format for `list` and `list-groups` commands.

### Command Reference

#### Interactive Mode

- **`interactive`**:
  Enters an interactive menu mode that guides you through most management tasks, reducing the need to memorize commands.
  ```bash
  sudo ./lvm-snapshot-manager.sh interactive
  ```

#### Snapshot Management
 
- **`create`**:
  Creates a new set of snapshots for all LVs defined in `lvm.conf`.
  ```bash
  sudo ./lvm-snapshot-manager.sh create
  ```
 
- **`list`**:
  Lists all snapshots managed by this tool on the system, including their size and current data usage. Can be used with the `--format` option to change the output.
  ```bash
  sudo ./lvm-snapshot-manager.sh list
  sudo ./lvm-snapshot-manager.sh --format json list
  ```
 
- **`list-groups`**:
  Lists all snapshot groups, organized by timestamp. Can be used with the `--format` option to change the output.
  ```bash
  sudo ./lvm-snapshot-manager.sh list-groups
  ```
 
- **`restore <TIMESTAMP>`**:
  Restores from a specified snapshot group. This is a destructive operation; use it with caution.
  ```bash
  sudo ./lvm-snapshot-manager.sh restore 20250926_103000
  ```
 
- **`delete <SNAPSHOT_NAME>`**:
  Deletes a single specified snapshot.
  ```bash
  sudo ./lvm-snapshot-manager.sh delete lv-www_snap_20250926_103000
  ```
 
- **`delete-group <TIMESTAMP>`**:
  Deletes all snapshots associated with the specified timestamp.
  ```bash
  sudo ./lvm-snapshot-manager.sh delete-group 20250926_103000
  ```
 
- **`extend <SNAPSHOT_NAME> <SIZE_TO_ADD>`**:
  Extends the storage space of an existing snapshot. This is useful when a snapshot's data usage is getting high.
  ```bash
  sudo ./lvm-snapshot-manager.sh extend lv-www_snap_20250926_103000 1G
  ```
 
- **`purge [OPTIONS]`**:
  Purges old snapshot groups based on specified criteria.
  - `--keep-last <N>`: Keep the N most recent snapshot groups.
  - `--older-than <AGE>`: Delete snapshot groups older than AGE (e.g., 7d, 4w, 1m).
  ```bash
  # Delete groups older than two weeks, but keep the 5 most recent ones
  sudo ./lvm-snapshot-manager.sh purge --keep-last 5 --older-than 2w
  ```
 
- **`monitor`**:
  Enters real-time monitoring mode, refreshing snapshot status every 5 seconds.
  ```bash
  sudo ./lvm-snapshot-manager.sh monitor
  ```
 
- **`check-health`**:
  Checks the health of all snapshots and warns about high data usage.
  ```bash
  sudo ./lvm-snapshot-manager.sh check-health
  ```

#### Volume Management

- **`pvs`**: Displays information about Physical Volumes (PVs).
- **`vgs`**: Displays information about Volume Groups (VGs).
- **`lvs`**: Displays information about Logical Volumes (LVs).
- **`pv-create <DEVICE_PATH>`**: Creates a PV on the specified device.
- **`vg-create <VG_NAME> <DEVICE_1> [DEVICE_2...]`**: Creates a VG from one or more PVs.
- **`lv-create <VG_NAME> <LV_NAME> <SIZE>`**: Creates an LV in the specified VG.
- **`lv-extend <LV_PATH> <SIZE_TO_ADD>`**: Extends the size of an LV.
- **`lv-remove <LV_PATH>`**: Removes an LV.
- **`vg-remove <VG_NAME>`**: Removes a VG.
- **`pv-remove <DEVICE_PATH>`**: Removes a PV.

#### Other Commands
 
- **`config`**:
  Enters an interactive menu to conveniently manage the `lvm.conf` settings.
  ```bash
  sudo ./lvm-snapshot-manager.sh config
  ```
 
- **`setup-logrotate`**:
  Creates a configuration file in `/etc/logrotate.d/` to automatically manage the script's log file.
  ```bash
  sudo ./lvm-snapshot-manager.sh setup-logrotate
  ```
 
- **`help`**:
  Displays the help message.
  ```bash
  sudo ./lvm-snapshot-manager.sh help