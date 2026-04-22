#!/bin/bash
# ==============================================================================
# SAP HANA GCBDR Proof of Concept (POC) Readiness Check
#
# Description:
# This is a comprehensive assessment tool for Solutions Teams to run in customer
# environments. It assesses a SAP HANA configuration for compatibility with
# Google Cloud Backup and Disaster Recovery (GCBDR).
#
# Copyright 2024 Google LLC
# ==============================================================================

# --- Color Codes for Output ---
# Check if stdout is a terminal, and if so, enable colors. Otherwise, disable them.
if [ -t 1 ]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    NC='\033[0m' # No Color
else
    GREEN=''
    RED=''
    YELLOW=''
    CYAN=''
    NC=''
fi

# --- Functions ---

# Function to print a formatted header
print_header() {
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}======================================================================${NC}"
}

# Function to check if a path is on an LVM volume
# Returns the logical volume path if true, or "N/A" if false.
get_lvm_device() {
    local path_to_check=$1
    local device

    if [ ! -d "$path_to_check" ]; then
        echo "N/A"
        return
    fi
    
    device=$(df --output=source "$path_to_check" 2>/dev/null | tail -n 1)

    # Check if the device looks like an LVM device
    if [[ "$device" == /dev/mapper/* ]] || [[ "$device" == /dev/dm-* ]]; then
        echo "$device"
    else
        echo "N/A"
    fi
}

# --- Main Script Logic ---

print_header "GCBDR for SAP HANA: Snapshot Readiness Check"
echo "This script will analyze the SAP HANA environment to ensure it is correctly"
echo "configured for reliable, snapshot-based backups with Google Cloud."
echo ""

# --- Host Information ---
print_header "Host Information"
OS_VERSION=$(grep "PRETTY_NAME" /etc/os-release 2>/dev/null | cut -d'=' -f2 | sed 's/"//g')

MEM_TOTAL_GB=""
MEM_USED_GB=""
MEM_FREE_GB=""
# Read memory info into an array for robust parsing
MEM_INFO=($(free -g 2>/dev/null | awk '/^Mem:/'))
if [ ${#MEM_INFO[@]} -gt 3 ]; then
    MEM_TOTAL="${MEM_INFO[1]}"
    MEM_USED="${MEM_INFO[2]}"
    MEM_FREE="${MEM_INFO[3]}"
    MEM_TOTAL_GB="${MEM_TOTAL} GB"
    MEM_USED_GB="${MEM_USED} GB"
    MEM_FREE_GB="${MEM_FREE} GB"
fi

echo -e "  - Operating System:        ${OS_VERSION:-Not Found}"
echo -e "  - Total Physical Memory:   ${MEM_TOTAL_GB:-Not Found}"
echo -e "  - Used Memory:             ${MEM_USED_GB:-Not Found}"
echo -e "  - Free Memory:             ${MEM_FREE_GB:-Not Found}"
echo ""


# 1. Prerequisite Checks
print_header "Step 1: Running Prerequisite Checks"
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[FAIL] This script must be run as root.${NC}"
   exit 1
fi
echo -e "${GREEN}[PASS] Running as root.${NC}"

# Find all SAP HANA instance owners (<sid>adm)
HANA_INSTANCE_OWNERS=$(ps -ef | grep '[h]dbnameserver' | awk '{print $1}' | sort -u)
if [ -z "$HANA_INSTANCE_OWNERS" ]; then
    echo -e "${YELLOW}[WARN] No running SAP HANA instances found.${NC}"
    exit 0
fi

# Loop through each discovered HANA instance
for HANA_OWNER in $HANA_INSTANCE_OWNERS; do
    HANA_SID=$(echo "$HANA_OWNER" | cut -c 1-3 | tr 'a-z' 'A-Z')
    print_header "Analyzing SAP HANA Instance: $HANA_SID ($HANA_OWNER)"

    # --- Reset variables for this instance ---
    POC_CHECKS_PASSED=0
    POC_CHECKS_TOTAL=5 # Increased number of checks
    declare -a ALL_DATA_LOG_PATHS
    declare -a ALL_DATA_LOG_LVS
    TENANT_INFO_RAW=""
    DB_SIZE=""
    RECOMMENDED_KEY=""
    RECOMMENDED_USER=""
    RECOMMENDED_PRIVS_RAW=""
    BACKINT_CONFIG="false"
    MISSING_PRIVS_MSG=""
    HANA_VERSION=""

    # 2. Retrieve HANA Configuration from global.ini
    echo "--> Step A: Discovering HANA file system layout and topology..."
    
    INSTANCE_BASE_PATH=$(su - "$HANA_OWNER" -c 'echo "$DIR_INSTANCE"' 2>/dev/null)
    if [ -z "$INSTANCE_BASE_PATH" ]; then
        echo -e "${RED}[FAIL] Could not determine instance path for user $HANA_OWNER. Skipping.${NC}"
        continue
    fi
    
    HANA_EXE_PATH="$INSTANCE_BASE_PATH/exe"
    HANA_GLOBAL_PATH=$(dirname "$INSTANCE_BASE_PATH")/SYS/global
    GLOBAL_INI_PATH="$HANA_GLOBAL_PATH/hdb/custom/config/global.ini"

    if [ ! -f "$GLOBAL_INI_PATH" ]; then
        echo -e "${RED}[FAIL] Could not find global.ini at expected path: $GLOBAL_INI_PATH. Skipping.${NC}"
        continue
    fi
    echo -e "${GREEN}[INFO] Found global.ini at: $GLOBAL_INI_PATH${NC}"
    
    INSTANCE_NUMBER=$(basename "$INSTANCE_BASE_PATH" | sed 's/HDB//')
    
    # Get HANA Version
    HANA_VERSION=$(su - "$HANA_OWNER" -c 'HDB version' 2>/dev/null | grep -i 'version:' | cut -d':' -f2 | xargs)

    # Parse global.ini for paths and log_mode
    DATA_PATH=$(grep -iw '^basepath_datavolumes' "$GLOBAL_INI_PATH" | cut -d'=' -f2 | xargs)
    LOG_PATH=$(grep -iw '^basepath_logvolumes' "$GLOBAL_INI_PATH" | cut -d'=' -f2 | xargs)
    LOG_BACKUP_PATH=$(grep -iw '^basepath_logbackup' "$GLOBAL_INI_PATH" | cut -d'=' -f2 | xargs)
    LOG_MODE=$(grep -iw '^log_mode' "$GLOBAL_INI_PATH" | cut -d'=' -f2 | xargs)
    BACKINT_CONFIG_RAW=$(grep -iw '^catalog_backup_using_backint' "$GLOBAL_INI_PATH" | cut -d'=' -f2 | xargs)
    [[ "$BACKINT_CONFIG_RAW" == "true" ]] && BACKINT_CONFIG="true"
    
    LOG_MODE_SOURCE="global.ini file"
    HANA_SHARED_PATH="/hana/shared/$HANA_SID"
    USR_SAP_PATH="/usr/sap/$HANA_SID"
    
    # Discover ALL userstore keys for the SYSTEMDB
    ALL_SYSTEMDB_KEYS=""
    if [ -x "$HANA_EXE_PATH/hdbuserstore" ]; then
        SYSTEMDB_SQL_PORT="3${INSTANCE_NUMBER}13"
        ALL_SYSTEMDB_KEYS=$(su - "$HANA_OWNER" -c "'$HANA_EXE_PATH/hdbuserstore' list" 2>/dev/null | grep -B 1 ":${SYSTEMDB_SQL_PORT}" | grep -i 'KEY' | awk '{print $2}')
    fi

    # Find the BEST userstore key that has all required privileges
    if [ -n "$ALL_SYSTEMDB_KEYS" ]; then
        REQUIRED_PRIVS=("BACKUP ADMIN" "CATALOG READ" "DATABASE BACKUP OPERATOR" "DATABASE RECOVERY OPERATOR" "DATABASE ADMIN" "DATABASE START" "DATABASE STOP")
        
        for key in $ALL_SYSTEMDB_KEYS; do
            db_user=$(su - "$HANA_OWNER" -c "'$HANA_EXE_PATH/hdbuserstore' list '$key'" 2>/dev/null | grep 'USER:' | awk '{print $2}')
            SQL_QUERY_PRIVS="SELECT PRIVILEGE FROM EFFECTIVE_PRIVILEGES WHERE USER_NAME = '$db_user' AND PRIVILEGE IN ('BACKUP ADMIN', 'CATALOG READ', 'DATABASE BACKUP OPERATOR', 'DATABASE RECOVERY OPERATOR', 'DATABASE ADMIN', 'DATABASE START', 'DATABASE STOP')"
            privs_raw=$(su - "$HANA_OWNER" -c "'$HANA_EXE_PATH/hdbsql' -U '$key' -a -x \"$SQL_QUERY_PRIVS\"" 2>/dev/null)

            ALL_PRIVS_FOUND=true
            for priv in "${REQUIRED_PRIVS[@]}"; do
                if ! echo "$privs_raw" | grep -qiw "$priv"; then
                    ALL_PRIVS_FOUND=false
                    break
                fi
            done

            if [ "$ALL_PRIVS_FOUND" = true ]; then
                RECOMMENDED_KEY=$key
                RECOMMENDED_USER=$db_user
                RECOMMENDED_PRIVS_RAW=$privs_raw
                break # Found a suitable key, no need to check others
            fi
        done
    fi

    if [ -n "$RECOMMENDED_KEY" ]; then
        echo -e "  - ${GREEN}[INFO] Found fully privileged userstore key '$RECOMMENDED_KEY' for user '$RECOMMENDED_USER'. This key will be used for SQL queries.${NC}"
    else
        echo -e "  - ${YELLOW}[WARN] No userstore key was found with all required privileges. Some checks will be skipped.${NC}"
    fi

    # Query for details ONLY if a recommended userstore key exists
    if [ -n "$RECOMMENDED_KEY" ]; then
        # Get log_mode from DB if not in file
        if [ -z "$LOG_MODE" ]; then
            SQL_QUERY_LOG_MODE="SELECT VALUE FROM M_INIFILE_CONTENTS WHERE FILE_NAME = 'global.ini' AND SECTION = 'persistence' AND KEY = 'log_mode'"
            LOG_MODE=$(su - "$HANA_OWNER" -c "'$HANA_EXE_PATH/hdbsql' -U '$RECOMMENDED_KEY' -a -x \"$SQL_QUERY_LOG_MODE\"" 2>/dev/null | xargs)
            LOG_MODE_SOURCE="live database configuration (SQL)"
        fi
        
        # Get Tenant Info
        SQL_QUERY_TENANTS="SELECT DATABASE_NAME, OS_USER, OS_GROUP FROM M_DATABASES"
        TENANT_INFO_RAW=$(su - "$HANA_OWNER" -c "'$HANA_EXE_PATH/hdbsql' -U '$RECOMMENDED_KEY' -j -a -x \"$SQL_QUERY_TENANTS\"" 2>/dev/null)

        # Get DB Size Estimate
        SQL_QUERY_DBSIZE="SELECT sum(ESTIMATED_SIZE) FROM SYS_DATABASES.M_BACKUP_SIZE_ESTIMATIONS where ENTRY_TYPE_NAME='complete data backup'"
        DB_SIZE_BYTES=$(su - "$HANA_OWNER" -c "'$HANA_EXE_PATH/hdbsql' -U '$RECOMMENDED_KEY' -a -x \"$SQL_QUERY_DBSIZE\"" 2>/dev/null | xargs)
        if [[ "$DB_SIZE_BYTES" =~ ^[0-9]+$ ]] && [ "$DB_SIZE_BYTES" -gt 0 ]; then
            DB_SIZE=$(awk -v size="$DB_SIZE_BYTES" 'BEGIN { hum[1024^3]="GB"; hum[1024^2]="MB"; hum[1024]="KB"; for (x=1024^3; x>=1024; x/=1024) if (size >= x) { printf "%.2f %s\n", size/x, hum[x]; break } }')
        fi
    fi

    # Determine HANA Topology
    IS_REPLICATION=false
    IS_SCALE_OUT=false
    WORKER_COUNT=1
    
    SR_STATE=$(su - "$HANA_OWNER" -c "'$HANA_EXE_PATH/hdbnsutil' -sr_state" 2>/dev/null | grep "operation mode:")
    [[ -n "$SR_STATE" ]] && IS_REPLICATION=true

    if [ -n "$RECOMMENDED_KEY" ]; then
        SQL_QUERY_SCALE_OUT="SELECT COUNT(DISTINCT HOST) FROM M_SERVICES WHERE SERVICE_NAME = 'indexserver' AND ACTIVE_STATUS = 'YES'"
        WORKER_COUNT_RAW=$(su - "$HANA_OWNER" -c "'$HANA_EXE_PATH/hdbsql' -U '$RECOMMENDED_KEY' -a -x \"$SQL_QUERY_SCALE_OUT\"" 2>/dev/null | xargs)
        if [[ "$WORKER_COUNT_RAW" =~ ^[0-9]+$ ]]; then WORKER_COUNT=$WORKER_COUNT_RAW; fi
    fi
    [[ "$WORKER_COUNT" -gt 1 ]] && IS_SCALE_OUT=true

    if [ "$IS_REPLICATION" = true ] && [ "$IS_SCALE_OUT" = true ]; then HANA_TOPOLOGY="Scale-out with System Replication (HA/DR)";
    elif [ "$IS_REPLICATION" = true ]; then HANA_TOPOLOGY="System Replication (HA/DR)";
    elif [ "$IS_SCALE_OUT" = true ]; then HANA_TOPOLOGY="Scale-out";
    else HANA_TOPOLOGY="Scale-up (Standalone)"; fi

    ALL_DATA_LOG_PATHS+=("$DATA_PATH" "$LOG_PATH" "$HANA_SHARED_PATH" "$USR_SAP_PATH")
    echo "Discovery complete."
    echo ""

    # 3. Perform Verifications
    print_header "Step B: Running GCBDR Readiness Checks"

    # Check 1: log_mode
    echo -e "${YELLOW}Requirement 1: Database must be in Archive Log Mode (log_mode = normal).${NC}"
    if [[ "$LOG_MODE" == "normal" ]]; then 
        LOG_MODE_PASSED=true; ((POC_CHECKS_PASSED++)); echo -e "  - ${GREEN}[PASS] Log mode is correctly set to 'normal'.${NC}"
    else 
        LOG_MODE_PASSED=false; echo -e "  - ${RED}[FAIL] Log mode is set to '${LOG_MODE:-not set}'.${NC}"
    fi

    # Check 2: LVM usage
    echo -e "${YELLOW}Requirement 2: All critical HANA paths must reside on LVM volumes.${NC}"
    PATHS_ON_LVM=true
    for path in $(echo "${ALL_DATA_LOG_PATHS[@]}" | tr ' ' '\n' | sort -u | grep -v '^$'); do
        lv=$(get_lvm_device "$path"); if [[ "$lv" == "N/A" ]]; then PATHS_ON_LVM=false; echo -e "  - ${RED}[FAIL] Path ($path) is not on an LVM device.${NC}"; else ALL_DATA_LOG_LVS+=("$lv"); fi
    done
    LOG_BACKUP_LV=$(get_lvm_device "$LOG_BACKUP_PATH"); if [[ "$LOG_BACKUP_LV" == "N/A" ]]; then PATHS_ON_LVM=false; echo -e "  - ${RED}[FAIL] Log Backup path ($LOG_BACKUP_PATH) is not on an LVM device.${NC}"; fi
    if [ "$PATHS_ON_LVM" = true ]; then ((POC_CHECKS_PASSED++)); echo -e "  - ${GREEN}[PASS] All critical HANA paths are on LVM volumes.${NC}"; fi

    # Check 3: Volume Separation
    echo -e "${YELLOW}Requirement 3: Log Backups (Archives) must be on a separate volume.${NC}"
    SEPARATION_PASSED=true
    if [ -n "$LOG_BACKUP_PATH" ] && [ "$PATHS_ON_LVM" = true ]; then
        for lv in $(echo "${ALL_DATA_LOG_LVS[@]}" | tr ' ' '\n' | sort -u); do
            if [[ "$lv" == "$LOG_BACKUP_LV" ]]; then SEPARATION_PASSED=false; break; fi
        done
        if [ "$SEPARATION_PASSED" = true ]; then ((POC_CHECKS_PASSED++)); echo -e "  - ${GREEN}[PASS] The Log Backup volume is correctly separated.${NC}"; else echo -e "  - ${RED}[FAIL] The Log Backup volume is shared.${NC}"; fi
    else
        SEPARATION_PASSED=false; echo -e "  - ${YELLOW}[SKIP] Cannot verify separation due to previous failures.${NC}"
    fi

    # Check 4: Backint Configuration
    echo -e "${YELLOW}Requirement 4: No conflicting backup tools (Backint) should be active.${NC}"
    if [ "$BACKINT_CONFIG" = "true" ]; then BACKINT_PASSED=false; echo -e "  - ${RED}[FAIL] Backint is enabled.${NC}"; else BACKINT_PASSED=true; ((POC_CHECKS_PASSED++)); echo -e "  - ${GREEN}[PASS] Backint is not enabled.${NC}"; fi

    # Check 5: Userstore Key Privileges
    echo -e "${YELLOW}Requirement 5: A userstore key must exist with all required privileges.${NC}"
    if [ -n "$RECOMMENDED_KEY" ]; then 
        PRIVS_PASSED=true; ((POC_CHECKS_PASSED++)); echo -e "  - ${GREEN}[PASS] Found suitable userstore key '$RECOMMENDED_KEY'.${NC}"
    else
        PRIVS_PASSED=false; echo -e "  - ${RED}[FAIL] No single userstore key has all required privileges.${NC}"
        MISSING_PRIVS_MSG="BACKUP ADMIN, CATALOG READ, DATABASE BACKUP OPERATOR, DATABASE RECOVERY OPERATOR, DATABASE ADMIN, DATABASE START, DATABASE STOP"
    fi
    echo ""

    # 4. Final Summary for this Instance
    print_header "GCBDR POC Readiness Report for HANA Instance: $HANA_SID"
    
    DF_OUTPUT=$(df -h); LSBLK_OUTPUT=$(lsblk)

    echo -e "${CYAN}Discovered Configuration:${NC}"
    echo "  - HANA Version:                ${HANA_VERSION:-Not Found}"
    echo "  - HANA Topology:               ${HANA_TOPOLOGY}"
    echo "  - Estimated DB Size:           ${DB_SIZE:-N/A}"
    echo "  - Data Path:                   ${DATA_PATH:-Not Found}"
    echo "  - Log Path:                    ${LOG_PATH:-Not Found}"
    echo "  - Shared Path:                 ${HANA_SHARED_PATH}"
    echo "  - USR SAP Path:                ${USR_SAP_PATH}"
    echo "  - Log Backup (Archive) Path:   ${LOG_BACKUP_PATH:-Not Configured}"
    echo "  - Active Log Mode:             ${LOG_MODE:-Not Found} (from ${LOG_MODE_SOURCE})"
    echo "  - Backint Enabled:             ${BACKINT_CONFIG}"
    echo ""

    echo -e "${CYAN}Tenant Database Information:${NC}"
    if [ -n "$TENANT_INFO_RAW" ]; then
        echo "$TENANT_INFO_RAW" | while read -r line; do
            db_name=$(echo "$line" | cut -d, -f1); os_user=$(echo "$line" | cut -d, -f2); os_group=$(echo "$line" | cut -d, -f3)
            printf "  - Tenant: %-15s OS User: %-15s OS Group: %-1s\n" "$db_name" "$os_user" "$os_group"
        done
    else echo "  - Tenant information could not be retrieved."; fi
    echo ""
    
    echo -e "${CYAN}Recommended Userstore Key for GCBDR: ${RECOMMENDED_KEY:-None Found}${NC}"
    echo -e "${CYAN}Effective Privileges for User '${RECOMMENDED_USER:-N/A}':${NC}"
    if [ -n "$RECOMMENDED_PRIVS_RAW" ]; then echo "$RECOMMENDED_PRIVS_RAW" | sed 's/^/    - /'; else echo "  - Could not retrieve privileges."; fi
    echo ""

    echo -e "${CYAN}Storage Layout Verification:${NC}"; echo "${DF_OUTPUT}" | sed 's/^/  /'; echo ""; echo "${LSBLK_OUTPUT}" | sed 's/^/  /'; echo ""

    echo -e "${CYAN}Readiness Check Results:${NC}"
    echo -n "  1. Log Mode set to 'normal':     "; if [ "$LOG_MODE_PASSED" = true ]; then echo -e "${GREEN}Ready${NC}"; else echo -e "${RED}Action Required${NC}"; fi
    echo -n "  2. All Paths on LVM:             "; if [ "$PATHS_ON_LVM" = true ]; then echo -e "${GREEN}Ready${NC}"; else echo -e "${RED}Action Required${NC}"; fi
    echo -n "  3. Log Backup Volume Separation: "; if [ "$SEPARATION_PASSED" = true ]; then echo -e "${GREEN}Ready${NC}"; else echo -e "${RED}Action Required${NC}"; fi
    echo -n "  4. Backint Disabled:             "; if [ "$BACKINT_PASSED" = true ]; then echo -e "${GREEN}Ready${NC}"; else echo -e "${RED}Action Required${NC}"; fi
    echo -n "  5. Userstore Key Privileges:     "; if [ "$PRIVS_PASSED" = true ]; then echo -e "${GREEN}Ready${NC}"; else echo -e "${RED}Action Required${NC}"; fi
    
    if [ "$PRIVS_PASSED" = false ]; then
        echo -e "    ${CYAN}Recommendation: Ensure at least one userstore key exists for a database user with ALL of the following privileges: ${MISSING_PRIVS_MSG}${NC}"
    fi

    echo ""
    echo -e "  POC Readiness Score: ${YELLOW}${POC_CHECKS_PASSED} out of ${POC_CHECKS_TOTAL}${NC} requirements met."
    echo ""
    if [ "$POC_CHECKS_PASSED" -eq "$POC_CHECKS_TOTAL" ]; then
        echo -e "  ${GREEN}Conclusion: This ${HANA_TOPOLOGY} HANA instance meets the configuration prerequisites.${NC}"
        if [ "$IS_SCALE_OUT" = true ]; then
            echo -e "  ${YELLOW}Supported Backup Methods: For the discovered ${HANA_TOPOLOGY} topology, GCBDR supports this environment with Full+Incremental backup methods. PD snapshot-based backups are not supported for Scale-out topologies.${NC}"
        else
            echo -e "  ${GREEN}Supported Backup Methods: GCBDR supports this ${HANA_TOPOLOGY} topology with PD Snapshot and Full+Incremental backup methods.${NC}"
        fi
    else
        echo -e "  ${RED}Conclusion: The configuration for this ${HANA_TOPOLOGY} HANA instance requires changes before proceeding with the POC.${NC}"
        echo -e "  ${RED}Please review the recommendations above.${NC}"
    fi
    echo "----------------------------------------------------------------------"
done


