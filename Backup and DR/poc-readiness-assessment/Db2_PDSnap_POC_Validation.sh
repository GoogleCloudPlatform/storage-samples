#!/bin/bash
# ==============================================================================
# Db2 GCBDR Proof of Concept (POC) Readiness Check
#
# Description:
# This script is designed for Solutions Teams to run in customer environments.
# It assesses a Db2 database configuration for compatibility with snapshot-based
# backups using Google Cloud Persistent Disks (PD) and GCBDR.
#
# It verifies critical requirements for consistent database snapshots, including
# LVM usage, archive log mode, volume separation, and Db2 version.
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

# Function to find the db2profile path for a given instance owner, using multiple discovery methods.
get_db2_profile_path() {
    local db_owner=$1
    local proc_id
    local profile_path=""
    local db2_home inst_home db2_lib passwd_home

    # Find the process ID of the db2sysc process for the given owner
    proc_id=$(ps -u "$db_owner" -o pid= -o comm= | awk '/db2sysc/ {print $1}' | head -n 1)
    if [ -z "$proc_id" ]; then
        # Fallback if no process is running, check passwd file for home dir
        passwd_home=$(getent passwd "$db_owner" 2>/dev/null | cut -d: -f6)
        if [ -n "$passwd_home" ] && [ -f "$passwd_home/sqllib/db2profile" ]; then
            echo "$passwd_home/sqllib/db2profile"
        else
            echo ""
        fi
        return
    fi

    # Extract all relevant environment variables from the process
    # Use tr to handle different delimiters and grep to find the vars
    local env_vars
    env_vars=$(ps eww "$proc_id" 2>/dev/null | tr ' ' '\n')

    db2_home=$(echo "$env_vars" | grep '^DB2_HOME=' | cut -d'=' -f2)
    inst_home=$(echo "$env_vars" | grep '^INSTHOME=' | cut -d'=' -f2)
    db2_lib=$(echo "$env_vars" | grep '^DB2LIB=' | cut -d'=' -f2)

    # --- Find profile using a priority system ---

    # Method 1: Use DB2_HOME directly
    if [ -n "$db2_home" ] && [ -f "$db2_home/db2profile" ]; then
        profile_path="$db2_home/db2profile"

    # Method 2: Use INSTHOME
    elif [ -n "$inst_home" ] && [ -f "$inst_home/sqllib/db2profile" ]; then
        profile_path="$inst_home/sqllib/db2profile"

    # Method 3: Derive from DB2LIB
    elif [ -n "$db2_lib" ]; then
        local sqllib_path
        sqllib_path=$(dirname "$db2_lib")
        if [ -f "$sqllib_path/db2profile" ]; then
            profile_path="$sqllib_path/db2profile"
        fi

    # Method 4 (Final Fallback): Use home directory from system accounts
    else
        passwd_home=$(getent passwd "$db_owner" 2>/dev/null | cut -d: -f6)
        if [ -n "$passwd_home" ] && [ -f "$passwd_home/sqllib/db2profile" ]; then
            profile_path="$passwd_home/sqllib/db2profile"
        fi
    fi

    echo "$profile_path"
}


# Function to check if a path is on an LVM volume
# Returns the logical volume path if true, or "N/A" if false.
get_lvm_device() {
    local path_to_check=$1
    local device

    # Handle cases where the path might not exist (e.g., failed mount)
    if [ ! -e "$path_to_check" ]; then
        # If it's a file, check its parent directory
        if [ -f "$path_to_check" ]; then
             path_to_check=$(dirname "$path_to_check")
        else
            echo "N/A"
            return
        fi
    fi
    # If it's a directory, use it directly
    if [ -d "$path_to_check" ]; then
        device=$(df --output=source "$path_to_check" 2>/dev/null | tail -n 1)
    else
        echo "N/A"
        return
    fi


    # Check if the device looks like an LVM device
    if [[ "$device" == /dev/mapper/* ]] || [[ "$device" == /dev/dm-* ]]; then
        echo "$device"
    else
        echo "N/A"
    fi
}


# --- Main Script Logic ---

print_header "GCBDR for Db2: Snapshot Readiness Check"
echo "This script will analyze the Db2 environment to ensure it is correctly"
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

# Determine OS for 'su' command compatibility
SU_FLAG=""
if grep -q "SLES" /etc/os-release 2>/dev/null; then
  SU_FLAG=" -m "
fi
echo -e "${GREEN}[INFO] Using 'su ${SU_FLAG}' for command execution.${NC}"

# Find all Db2 instance owners
DB2_INSTANCE_OWNERS=$(ps -ef | grep '[d]b2sysc' | awk '{print $1}' | sort -u)
if [ -z "$DB2_INSTANCE_OWNERS" ]; then
    echo -e "${YELLOW}[WARN] No running Db2 instances found.${NC}"
    exit 0
fi

# Loop through each discovered Db2 instance
for DB2_INSTANCE_OWNER in $DB2_INSTANCE_OWNERS; do
    print_header "Analyzing Instance: $DB2_INSTANCE_OWNER"

    # Automatically find the db2profile for this instance
    DB2_PROFILE_PATH=$(get_db2_profile_path "$DB2_INSTANCE_OWNER")
    if [ -z "$DB2_PROFILE_PATH" ]; then
        echo -e "${RED}[FAIL] Could not determine db2profile path for instance '$DB2_INSTANCE_OWNER'. Skipping.${NC}"
        continue
    fi
    echo -e "${GREEN}[INFO] Found db2profile at: $DB2_PROFILE_PATH${NC}"

    # Get Db2 Version for the instance and sanitize it
    DB2_VERSION_RAW=$(su $SU_FLAG "$DB2_INSTANCE_OWNER" -c ". '$DB2_PROFILE_PATH'; db2level" 2>/dev/null)
    DB2_VERSION=$(echo "$DB2_VERSION_RAW" | grep "DB2 v" | awk '{print $5}' | sed 's/^v//; s/"//g; s/,//g')
    if [ -z "$DB2_VERSION" ]; then
        DB2_VERSION="Not Found"
    fi
    echo -e "${GREEN}[INFO] Found Db2 Version: ${DB2_VERSION}${NC}"

    # Get a list of ALL cataloged databases and a list of ACTIVE databases
    ALL_DATABASES=$(su $SU_FLAG "$DB2_INSTANCE_OWNER" -c ". '$DB2_PROFILE_PATH'; db2 list db directory" | grep "Database name" | awk -F'=' '{print $2}' | xargs)
    ACTIVE_DATABASES_LIST=$(su $SU_FLAG "$DB2_INSTANCE_OWNER" -c ". '$DB2_PROFILE_PATH'; db2 list active databases" | grep 'Database name' | awk '{print $4}')

    if [ -z "$ALL_DATABASES" ]; then
        echo -e "${YELLOW}[INFO] No cataloged databases found for this instance.${NC}"
        continue
    fi
    
    echo -e "${GREEN}[INFO] Found cataloged databases: ${ALL_DATABASES}${NC}"


    # Loop through each cataloged database
    for DB_NAME in $ALL_DATABASES; do
        echo -e "\n--- Verifying Database: ${YELLOW}$DB_NAME${NC} ---\n"
        
        # Determine database status
        DB_STATUS="INACTIVE"
        if [[ "$ACTIVE_DATABASES_LIST" == *"$DB_NAME"* ]]; then
            DB_STATUS="ACTIVE"
        fi

        # If database is inactive, just report and skip detailed checks
        if [ "$DB_STATUS" == "INACTIVE" ]; then
            print_header "GCBDR POC Readiness Report for Database: $DB_NAME"
            echo -e "${CYAN}Discovered Configuration:${NC}"
            echo -e "  - Db2 Version:                 ${DB2_VERSION}"
            echo -e "  - Database Status:             ${YELLOW}INACTIVE${NC}"
            echo ""
            echo -e "  ${YELLOW}Conclusion: This database is inactive. Detailed readiness checks were skipped.${NC}"
            echo -e "  ${YELLOW}Please activate the database and re-run the script to perform a full check.${NC}"
            echo "----------------------------------------------------------------------"
            continue
        fi

        # --- Arrays to hold paths and LVs for this specific database ---
        declare -a ALL_DATA_PATHS
        declare -a ALL_DATA_LVS
        declare -a ALL_LOG_PATHS
        POC_CHECKS_PASSED=0
        POC_CHECKS_TOTAL=4

        # 2. Retrieve Db2 Configuration for the ACTIVE database
        echo "--> Step A: Discovering Db2 file system layout..."
        DB_PATHS_RAW=$(su $SU_FLAG "$DB2_INSTANCE_OWNER" -c ". '$DB2_PROFILE_PATH'; db2 connect to $DB_NAME >/dev/null; db2 -x \"SELECT type, path FROM sysibmadm.DBPATHS\"; db2 terminate >/dev/null")
        DB_CFG_RAW=$(su $SU_FLAG "$DB2_INSTANCE_OWNER" -c ". '$DB2_PROFILE_PATH'; db2 get db cfg for $DB_NAME")

        DB_DIR_PATH=$(echo "$DB_PATHS_RAW" | awk '/DBPATH/ {print $2}')
        ACTIVE_LOG_PATH=$(echo "$DB_PATHS_RAW" | awk '/LOGPATH/ {print $2}')
        STORAGE_PATHS=($(echo "$DB_PATHS_RAW" | awk '/DB_STORAGE_PATH/ {print $2}'))
        TABLESPACE_CONTAINER_PATHS=($(echo "$DB_PATHS_RAW" | awk '/TBSP_/ {print $2}'))
        TABLESPACE_PATHS=($(for p in "${TABLESPACE_CONTAINER_PATHS[@]}"; do dirname "$p"; done | sort -u))
        LOGARCHMETH1_CONFIG=$(echo "$DB_CFG_RAW" | grep 'First log archive method' | awk -F'= ' '{print $2}')
        MIRROR_LOG_PATH=$(echo "$DB_CFG_RAW" | grep 'Mirror log path' | awk -F'= ' '{print $2}')
        DB_ROLE=$(echo "$DB_CFG_RAW" | grep 'HADR database role' | awk -F'= ' '{print $2}')
        
        if [ -z "$DB_ROLE" ]; then
            DB_ROLE="STANDARD"
        fi

        ALL_DATA_PATHS+=("$DB_DIR_PATH")
        ALL_DATA_PATHS+=("${STORAGE_PATHS[@]}")
        ALL_DATA_PATHS+=("${TABLESPACE_PATHS[@]}")
        ALL_LOG_PATHS+=("$ACTIVE_LOG_PATH")
        [ "$MIRROR_LOG_PATH" != "NOT SET" ] && ALL_LOG_PATHS+=("$MIRROR_LOG_PATH")
        echo "Discovery complete."
        echo ""

        # 3. Perform Verifications
        echo "--> Step B: Running GCBDR Readiness Checks..."

        # Check 1: LOGARCHMETH1
        echo -e "${YELLOW}Requirement 1: Database must be in Archive Log Mode.${NC}"
        echo "  This is essential for point-in-time recovery, which complements PD snapshots."
        if [[ "$LOGARCHMETH1_CONFIG" == "OFF" ]] || [[ -z "$LOGARCHMETH1_CONFIG" ]]; then
            LOGARCHMETH1_PASSED=false
            ARCHIVE_LOG_PATH=""
            echo -e "  - ${RED}[FAIL] LOGARCHMETH1 is not configured.${NC}"
        else
            LOGARCHMETH1_PASSED=true
            ARCHIVE_LOG_PATH=$(echo "$LOGARCHMETH1_CONFIG" | awk -F':' '{print $2}')
            echo -e "  - ${GREEN}[PASS] LOGARCHMETH1 is configured.${NC}"
            ((POC_CHECKS_PASSED++))
        fi
        
        # Check 2: LVM usage
        echo -e "${YELLOW}Requirement 2: All Db2 paths must reside on LVM volumes.${NC}"
        echo "  This is a requirement for managing storage with Persistent Disk snapshots."
        PATHS_ON_LVM=true
        
        for path in $(echo "${ALL_DATA_PATHS[@]}" | tr ' ' '\n' | sort -u | grep -v '^$'); do
            lv=$(get_lvm_device "$path")
            if [[ "$lv" == "N/A" ]]; then
                PATHS_ON_LVM=false
            else
                ALL_DATA_LVS+=("$lv")
            fi
        done
        for path in $(echo "${ALL_LOG_PATHS[@]}" | tr ' ' '\n' | sort -u | grep -v '^$'); do
             lv=$(get_lvm_device "$path")
             if [[ "$lv" == "N/A" ]]; then
                 PATHS_ON_LVM=false
             else
                 ALL_DATA_LVS+=("$lv")
             fi
        done
        if [ "$LOGARCHMETH1_PASSED" = true ]; then
            ARCHIVE_LOG_LV=$(get_lvm_device "$ARCHIVE_LOG_PATH")
            if [[ "$ARCHIVE_LOG_LV" == "N/A" ]]; then
                PATHS_ON_LVM=false
            fi
        fi

        if [ "$PATHS_ON_LVM" = true ]; then
             echo -e "  - ${GREEN}[PASS] All discovered Db2 paths are on LVM volumes.${NC}"
             ((POC_CHECKS_PASSED++))
        else
             echo -e "  - ${RED}[FAIL] One or more Db2 paths are not on an LVM device. See details above.${NC}"
        fi

        # Check 3: Volume Separation
        echo -e "${YELLOW}Requirement 3: Archive Logs must be on a separate volume.${NC}"
        echo "  This is CRITICAL for creating consistent snapshots and managing log backups independently."
        SEPARATION_PASSED=true
        if [ "$LOGARCHMETH1_PASSED" = true ] && [ "$PATHS_ON_LVM" = true ]; then
            UNIQUE_DATA_AND_LOG_LVS=$(echo "${ALL_DATA_LVS[@]}" | tr ' ' '\n' | sort -u)
            IS_SHARED=false
            for lv in $UNIQUE_DATA_AND_LOG_LVS; do
                if [[ "$lv" == "$ARCHIVE_LOG_LV" ]]; then
                    IS_SHARED=true
                    break
                fi
            done
            
            if $IS_SHARED; then
                SEPARATION_PASSED=false
                echo -e "  - ${RED}[FAIL] The Archive Log volume ($ARCHIVE_LOG_LV) is shared with data or active logs.${NC}"
            else
                echo -e "  - ${GREEN}[PASS] The Archive Log volume is correctly separated.${NC}"
                ((POC_CHECKS_PASSED++))
            fi
        else
            SEPARATION_PASSED=false
            echo -e "  - ${YELLOW}[SKIP] Cannot verify separation. Fix previous requirements first.${NC}"
        fi
        
        # Check 4: Db2 Version
        echo -e "${YELLOW}Requirement 4: Db2 version must be 11.2 or higher.${NC}"
        echo "  This is required for compatibility with certain GCBDR features."
        VERSION_PASSED=false
        if [ "$DB2_VERSION" != "Not Found" ]; then
            MAJOR_VER=$(echo "$DB2_VERSION" | cut -d'.' -f1)
            MINOR_VER=$(echo "$DB2_VERSION" | cut -d'.' -f2)

            if [[ "$MAJOR_VER" =~ ^[0-9]+$ ]] && [[ "$MINOR_VER" =~ ^[0-9]+$ ]]; then
                if [ "$MAJOR_VER" -gt 11 ] || { [ "$MAJOR_VER" -eq 11 ] && [ "$MINOR_VER" -ge 2 ]; }; then
                    VERSION_PASSED=true
                    echo -e "  - ${GREEN}[PASS] Db2 version ${DB2_VERSION} is supported.${NC}"
                    ((POC_CHECKS_PASSED++))
                else
                    echo -e "  - ${RED}[FAIL] Db2 version ${DB2_VERSION} is not supported. Version 11.2 or higher is required.${NC}"
                fi
            else
                 echo -e "  - ${RED}[FAIL] Could not parse Db2 version string '${DB2_VERSION}'.${NC}"
            fi
        else
            echo -e "  - ${RED}[FAIL] Could not determine Db2 version.${NC}"
        fi
        echo ""

        # 4. Final Summary for this Database
        print_header "GCBDR POC Readiness Report for Database: $DB_NAME"
        
        DF_OUTPUT=$(df -h); LSBLK_OUTPUT=$(lsblk)

        echo -e "${CYAN}Discovered Configuration:${NC}"
        echo -e "  - Db2 Version:                 ${DB2_VERSION}"
        echo -e "  - Database Status:             ${GREEN}ACTIVE${NC}"
        echo -e "  - Database Role:               ${DB_ROLE}"
        echo -e "  - Database Directory:          ${DB_DIR_PATH:-N/A}"
        echo -e "  - Active Log Path:             ${ACTIVE_LOG_PATH:-N/A}"
        [ "$MIRROR_LOG_PATH" != "NOT SET" ] && echo "  - Mirror Log Path:             $MIRROR_LOG_PATH"
        echo -e "  - Automatic Storage Paths:     ${STORAGE_PATHS[*]:-N/A}"
        echo -e "  - Tablespace Directories:      ${TABLESPACE_PATHS[*]:-N/A}"
        echo -e "  - Archive Log Location:        ${ARCHIVE_LOG_PATH:-Not Configured}"
        echo ""
        
        echo -e "${CYAN}Storage Layout Verification:${NC}"; echo "${DF_OUTPUT}" | sed 's/^/  /'; echo ""; echo "${LSBLK_OUTPUT}" | sed 's/^/  /'; echo ""

        echo -e "${CYAN}Readiness Check Results:${NC}"
        echo -n "  1. Archive Log Mode Enabled:       "; if [ "$LOGARCHMETH1_PASSED" = true ]; then echo -e "${GREEN}Ready${NC}"; else echo -e "${RED}Action Required${NC}"; fi
        echo -n "  2. All Paths on LVM:               "; if [ "$PATHS_ON_LVM" = true ]; then echo -e "${GREEN}Ready${NC}"; else echo -e "${RED}Action Required${NC}"; fi
        echo -n "  3. Archive Log Volume Separation:  "; if [ "$SEPARATION_PASSED" = true ]; then echo -e "${GREEN}Ready${NC}"; else echo -e "${RED}Action Required${NC}"; fi
        echo -n "  4. Db2 Version Supported:          "; if [ "$VERSION_PASSED" = true ]; then echo -e "${GREEN}Ready${NC}"; else echo -e "${RED}Action Required${NC}"; fi
        echo ""
        echo -e "  POC Readiness Score: ${YELLOW}${POC_CHECKS_PASSED} out of ${POC_CHECKS_TOTAL}${NC} requirements met."
        echo ""
        if [ "$POC_CHECKS_PASSED" -eq "$POC_CHECKS_TOTAL" ]; then
            echo -e "  ${GREEN}Conclusion: This database is correctly configured and ready for the GCBDR snapshot backup POC.${NC}"
        else
            echo -e "  ${RED}Conclusion: The configuration for this database requires changes before proceeding with the POC.${NC}"
            if ! $LOGARCHMETH1_PASSED; then echo -e "    ${CYAN}- Recommendation: Enable LOGARCHMETH1 to allow for point-in-time recovery.${NC}"; fi
            if ! $PATHS_ON_LVM; then echo -e "    ${CYAN}- Recommendation: Migrate all listed file systems to Logical Volumes.${NC}"; fi
            if ! $SEPARATION_PASSED; then echo -e "    ${CYAN}- Recommendation: Move the archive log path to a dedicated logical volume.${NC}"; fi
            if ! $VERSION_PASSED; then echo -e "    ${CYAN}- Recommendation: Plan an upgrade of the Db2 instance to a supported version (11.2+).${NC}"; fi
        fi
        echo "----------------------------------------------------------------------"
    done
done


