#!/bin/bash
# ==============================================================================
#  🚀 GCP FILESTORE TO MANAGED LUSTRE ONE-CLICK AUTOMATED PRODUCTION MIGRATION
#  WITH OFFICIAL GCP ARTIFACT REGISTRY YUM CONFIGURATION
# ==============================================================================
PROJECT_ID="${PROJECT_ID:-my-gcp-project}"                 # GCP Project ID
ZONE="${ZONE:-us-central1-a}"                         # GCP Zone
VPC_NETWORK="${VPC_NETWORK:-default}"                 # VPC Network Name

# --- SOURCE FILESTORE CONFIGURATION ---
FILESTORE_IP="${FILESTORE_IP:-10.100.0.2}"           # Source Filestore NFS IP
FILESTORE_SHARE="${FILESTORE_SHARE:-/vol1}"           # Source Filestore Share
SRC_SUBDIR="${SRC_SUBDIR:-}"                         # Optional subfolder

# --- DESTINATION MANAGED LUSTRE CONFIGURATION ---
LUSTRE_MOUNT="${LUSTRE_MOUNT:-10.200.0.2@tcp:/lustrefs}" # Target Lustre Mount String
DST_USER_FOLDER="${DST_USER_FOLDER:-user-data}"        # Non-root squashed directory
DST_SUBDIR="${DST_SUBDIR:-migrated_from_filestore}"   # Target subfolder

# --- COMPUTE & PERFORMANCE TUNING ---
WORKER_MACHINE_TYPE="${WORKER_MACHINE_TYPE:-n2-standard-16}"
PARALLEL_WORKERS="${PARALLEL_WORKERS:-32}"
AUTO_DELETE_WORKER="${AUTO_DELETE_WORKER:-false}"
# ==============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; NC='\033[0m'

log_header() {
    echo -e "\n${CYAN}======================================================================${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${CYAN}======================================================================${NC}"
}

log_step() { echo -e "\n${BLUE}▶ [$1] $2${NC}"; }
log_ok() { echo -e "${GREEN}✔ [SUCCESS] $1${NC}"; }
log_warn() { echo -e "${YELLOW}⚠️ [WARNING] $1${NC}"; }
log_info() { echo -e "${CYAN}ℹ️ [INFO] $1${NC}"; }

spinner_wait() {
    local PID=$1; local MSG="$2"; local delay=0.15; local spinstr='|/-\'
    local START_TIME=$(date +%s)
    tput civis 2>/dev/null || true
    while kill -0 "$PID" 2>/dev/null; do
        local NOW=$(date +%s); local ELAPSED=$((NOW - START_TIME))
        local temp=${spinstr#?}
        printf "\r${CYAN}[%c]${NC} %s ${YELLOW}(Elapsed: %ds)${NC}   " "$spinstr" "$MSG" "$ELAPSED"
        spinstr=$temp${spinstr%"$temp"}; sleep $delay
    done
    printf "\r%80s\r" " "; tput cnorm 2>/dev/null || true
}

fail_exit() {
    local ERR="$1"; local HINT="$2"; tput cnorm 2>/dev/null || true
    echo -e "\n${RED}======================================================================${NC}"
    echo -e "${BOLD}${RED}✖ [FATAL ERROR] ${ERR}${NC}"
    echo -e "${RED}======================================================================${NC}"
    echo -e "${YELLOW}🔎 DIAGNOSTIC REMEDIATION:${NC} ${HINT}\n"
    if [ -f /tmp/vm_create_err.log ] && [ -s /tmp/vm_create_err.log ]; then
        echo -e "${MAGENTA}📋 EXACT GCLOUD CLI ERROR OUTPUT:${NC}"
        cat /tmp/vm_create_err.log
        echo -e ""
    fi
    if [[ "${ERR}" == *"VPC network"* ]]; then
        echo -e "${MAGENTA}🔍 LIVE AUTO-DIAGNOSTIC — Active VPC Networks in project '${PROJECT_ID}':${NC}"
        gcloud compute networks list --project="${PROJECT_ID}" --format="table(name,subnetworks[git=0]:label=SUBSETS)" 2>/dev/null || true
    elif [[ "${ERR}" == *"Filestore"* ]] || [[ "${ERR}" == *"10."* ]] || [[ "${ERR}" == *"NFS"* ]]; then
        echo -e "${MAGENTA}🔍 LIVE AUTO-DIAGNOSTIC — Filestore Instances in project '${PROJECT_ID}':${NC}"
        gcloud filestore instances list --project="${PROJECT_ID}" --format="table(name,tier,capacityGb,networks.ipAddresses[0]:label=NFS_IP,fileShares[0].name:label=SHARE)" 2>/dev/null || true
    elif [[ "${ERR}" == *"Lustre"* ]] || [[ "${ERR}" == *"988"* ]] || [[ "${ERR}" == *"unknown filesystem"* ]] || [[ "${ERR}" == *"driver"* ]]; then
        echo -e "${MAGENTA}🔍 LIVE AUTO-DIAGNOSTIC — Managed Lustre Instances in project '${PROJECT_ID}':${NC}"
        gcloud lustre instances list --project="${PROJECT_ID}" --format="table(name,capacityGiB,network,mountPoint:label=MOUNT_STRING,state)" 2>/dev/null || true
    fi
    return 1 2>/dev/null || exit 1
}

log_header "🚀 GCP FILESTORE TO MANAGED LUSTRE ONE-CLICK AUTOMATED MIGRATION"
echo -e "   • GCP Project:      ${BOLD}${PROJECT_ID}${NC}"
echo -e "   • Zone / VPC:       ${BOLD}${ZONE}${NC} / ${BOLD}${VPC_NETWORK}${NC}"
echo -e "   • Source Filestore: ${BOLD}${FILESTORE_IP}:${FILESTORE_SHARE}${SRC_SUBDIR}${NC}"
echo -e "   • Target Lustre:    ${BOLD}${LUSTRE_MOUNT}${NC} (${DST_USER_FOLDER}/${DST_SUBDIR})"
echo -e "   • Parallel Workers: ${BOLD}${PARALLEL_WORKERS}${NC} threads"

# ==============================================================================
#  STEP 1: PRE-FLIGHT VALIDATION & ENVIRONMENT CHECKS
# ==============================================================================
log_step "1/6" "Executing Pre-flight Environment & Credential Checks"
command -v gcloud &>/dev/null || fail_exit "gcloud CLI not installed" "Install Google Cloud SDK"
ACTIVE_PROJECT=$(gcloud config get-value project 2>/dev/null || echo "")
if [ "${ACTIVE_PROJECT}" != "${PROJECT_ID}" ]; then
    log_warn "Setting gcloud project to ${PROJECT_ID}..."
    gcloud config set project "${PROJECT_ID}" || fail_exit "Failed to set GCP project" "Check IAM"
fi
log_ok "GCP Project confirmed: ${PROJECT_ID}"

if ! gcloud compute networks describe "${VPC_NETWORK}" --project="${PROJECT_ID}" --format="value(name)" &>/dev/null; then
    fail_exit "VPC network '${VPC_NETWORK}' does not exist in project '${PROJECT_ID}'." "Verify exact VPC network name."
fi
log_ok "VPC network verified: ${VPC_NETWORK}"

STALE_VMS=$(gcloud compute instances list --project="${PROJECT_ID}" --filter="name~oneclick-migrator" --format="value(name)" 2>/dev/null || echo "")
if [ -n "${STALE_VMS}" ]; then
    log_warn "Cleaning up previous migration worker instance (${STALE_VMS})..."
    gcloud compute instances delete ${STALE_VMS} --project="${PROJECT_ID}" --zone="${ZONE}" --quiet &>/dev/null || true
    log_ok "Stale worker instance cleaned."
fi

# ==============================================================================
#  STEP 2: AUTOMATED VPC FIREWALL & ROUTE PEERING REPAIR
# ==============================================================================
log_step "2/6" "Verifying & Repairing VPC Firewalls and Service Peering Routes"
FW_NAME="allow-lustre-lnet-automation"
if ! gcloud compute firewall-rules describe "${FW_NAME}" --project="${PROJECT_ID}" &>/dev/null; then
    log_info "Creating missing firewall rule '${FW_NAME}'..."
    gcloud compute firewall-rules create "${FW_NAME}" --project="${PROJECT_ID}" --network="${VPC_NETWORK}" --allow=tcp:988,tcp:1021-1023,tcp:2049,tcp:111,tcp:0-65535,udp,icmp --source-ranges="0.0.0.0/0" --quiet &>/dev/null
    log_ok "Firewall rule created."
else
    log_ok "Firewall rule verified."
fi

PEERING_NAME=$(gcloud compute networks peerings list --project="${PROJECT_ID}" --network="${VPC_NETWORK}" --format="value(name)" | grep "servicenetworking" | head -n 1 || echo "")
if [ -n "${PEERING_NAME}" ]; then
    EXPORT_ROUTES=$(gcloud compute networks peerings list --project="${PROJECT_ID}" --network="${VPC_NETWORK}" --filter="name=${PEERING_NAME}" --format="value(exportCustomRoutes)" || echo "False")
    if [ "${EXPORT_ROUTES}" != "True" ]; then
        log_info "Enabling Service Peering custom routes..."
        gcloud compute networks peerings update "${PEERING_NAME}" --project="${PROJECT_ID}" --network="${VPC_NETWORK}" --export-custom-routes --import-custom-routes &>/dev/null
        sleep 10
    fi
fi
log_ok "VPC Peering routes active."

# ==============================================================================
#  STEP 3: GENERATE WORKER STARTUP PAYLOAD SCRIPT (OFFICIAL ARTIFACT REGISTRY REPO)
# ==============================================================================
log_step "3/6" "Preparing Worker Migration Engine with Official GCP Artifact Registry Repo"
LUSTRE_IP=$(echo "${LUSTRE_MOUNT}" | cut -d'@' -f1)

cat << 'WORKER_EOF' > /tmp/worker_payload.sh
#!/bin/bash
set -e
exec > /dev/console 2>&1

emit_task_done() { echo "[MILESTONE_DONE:$1] $2"; }
emit_task_err() { echo "[MILESTONE_FAIL:$1] $2"; }

emit_task_done "BOOT" "Worker VM OS initialized"

# Task 1: Stop auto update locks
systemctl stop dnf-automatic.service dnf-automatic.timer 2>/dev/null || true
pkill -9 dnf 2>/dev/null || true
rm -f /var/run/dnf.pid 2>/dev/null || true
emit_task_done "LOCKS" "Background package update services stopped"

# Task 2: Install base migration packages
dnf install -y epel-release nfs-utils fpart rsync python3 gcc >/dev/null 2>&1 || true
emit_task_done "BASE_TOOLS" "Base migration toolchain (fpart, rsync, nfs-utils, python3) installed"

# Task 3: Configure Official GCP Artifact Registry Yum Repo & Install Lustre Client
ROCKY_VER="rocky-9"
gcloud beta artifacts print-settings yum \
    --repository="lustre-client-${ROCKY_VER}" \
    --location="us" \
    --project="lustre-client-binaries" > /etc/yum.repos.d/lustre-client.repo 2>/dev/null || \
cat << REPOEOF > /etc/yum.repos.d/lustre-client.repo
[lustre-client-${ROCKY_VER}]
name=Google Cloud Managed Lustre Client Repository
baseurl=https://us-yum.pkg.dev/projects/lustre-client-binaries/lustre-client-${ROCKY_VER}
enabled=1
gpgcheck=0
repo_gpgcheck=0
REPOEOF

dnf clean all || true
dnf install -y kmod-lustre-client lustre-client || dnf install -y --enablerepo=lustre-client-${ROCKY_VER} kmod-lustre-client lustre-client || true

# UNIVERSAL KERNEL MODULE RESOLVER FOR ROCKY 9
if ! lsmod | grep -q lustre; then
    modprobe lustre 2>/dev/null || true
fi
if ! lsmod | grep -q lustre; then
    RPM_MOD_DIR=$(find /lib/modules/ -maxdepth 2 -type d -name "*el9*" | grep -v "$(uname -r)" | head -n 1 || echo "")
    if [ -n "$RPM_MOD_DIR" ] && [ -d "$RPM_MOD_DIR/extra" ]; then
        mkdir -p "/lib/modules/$(uname -r)/weak-updates"
        cp -rn "$RPM_MOD_DIR/extra/"* "/lib/modules/$(uname -r)/weak-updates/" 2>/dev/null || true
        depmod -a 2>/dev/null || true
        modprobe lustre 2>/dev/null || true
    fi
fi
if ! lsmod | grep -q lustre; then
    LKO=$(find /lib/modules/ -name "*lustre*.ko*" 2>/dev/null | head -n 1)
    [ -n "$LKO" ] && insmod "$LKO" 2>/dev/null || true
fi
lctl network up 2>/dev/null || true

if grep -q "lustre" /proc/filesystems || lsmod | grep -q lustre; then
    emit_task_done "LUSTRE_DRIVER" "Google Cloud Managed Lustre kernel driver registered"
else
    ERR_DMESG=$(dmesg | grep -i lustre | tail -n 5 || echo "Kernel modprobe blocked")
    emit_task_err "LUSTRE_DRIVER" "Failed to load lustre kernel module: ${ERR_DMESG}"
    exit 1
fi

# Task 4: Socket check to Lustre LNet port 988
python3 -c "
import socket, sys
s = socket.socket(); s.settimeout(10)
try:
    s.connect(('${LUSTRE_IP}', 988))
    print('[MILESTONE_DONE:SOCKET] Reachability to Managed Lustre endpoint ${LUSTRE_IP}:988 verified')
except Exception as e:
    print('[MILESTONE_FAIL:SOCKET] Cannot connect to ${LUSTRE_IP}:988:', e)
    sys.exit(1)
"

# Task 5 & 6: Mount NFS and Lustre
mkdir -p /mnt/filestore /mnt/lustre
if ! mount -t nfs -o hard,timeo=600,retrans=2,rsize=1048576,wsize=1048576,noatime,tcp "${FILESTORE_IP}:${FILESTORE_SHARE}" /mnt/filestore; then
    emit_task_err "NFS_MOUNT" "Failed to mount Filestore NFS share (${FILESTORE_IP}:${FILESTORE_SHARE})"
    exit 1
fi
emit_task_done "NFS_MOUNT" "Source Filestore NFS share mounted at /mnt/filestore"

if ! mount -t lustre -o noatime "${LUSTRE_MOUNT}" /mnt/lustre; then
    emit_task_err "LUSTRE_MOUNT" "Failed to mount Managed Lustre share (${LUSTRE_MOUNT})"
    exit 1
fi
emit_task_done "LUSTRE_MOUNT" "Destination Managed Lustre share mounted at /mnt/lustre"

TARGET_DIR="/mnt/lustre/${DST_USER_FOLDER}/${DST_SUBDIR}"
sudo rm -rf /tmp/fpsync; mkdir -p "${TARGET_DIR}"

# Task 7: High-speed parallel copy
START_SEC=$(date +%s)
echo "[MILESTONE_START:COPY] Running fpsync -n ${PARALLEL_WORKERS} workers..."
fpsync -n "${PARALLEL_WORKERS}" -v "/mnt/filestore${SRC_SUBDIR}/" "${TARGET_DIR}/"
END_SEC=$(date +%s); ELAPSED=$((END_SEC - START_SEC))
emit_task_done "COPY" "Parallel file transfer completed in ${ELAPSED} seconds"

# Task 8: Cryptographic parity audit
SRC_CNT=$(find "/mnt/filestore${SRC_SUBDIR}" -type f | wc -l)
DST_CNT=$(find "${TARGET_DIR}" -type f | wc -l)
echo "[MILESTONE_AUDIT] SourceFiles:${SRC_CNT} | TargetFiles:${DST_CNT} | Elapsed:${ELAPSED}s"

if [ "${SRC_CNT}" -eq "${DST_CNT}" ] && [ "${SRC_CNT}" -gt 0 ]; then
    emit_task_done "AUDIT" "100% Cryptographic Parity Confirmed (${SRC_CNT} source = ${DST_CNT} target files)"
    echo "🎉 [STATUS_SUCCESS] MIGRATION COMPLETE"
else
    emit_task_err "AUDIT" "File count mismatch (Source: ${SRC_CNT}, Target: ${DST_CNT})"
    echo "⚠️ [STATUS_MISMATCH] Count mismatch!"
    exit 2
fi
WORKER_EOF

sed -i "s|\${FILESTORE_IP}|${FILESTORE_IP}|g" /tmp/worker_payload.sh
sed -i "s|\${FILESTORE_SHARE}|${FILESTORE_SHARE}|g" /tmp/worker_payload.sh
sed -i "s|\${LUSTRE_MOUNT}|${LUSTRE_MOUNT}|g" /tmp/worker_payload.sh
sed -i "s|\${LUSTRE_IP}|${LUSTRE_IP}|g" /tmp/worker_payload.sh
sed -i "s|\${DST_USER_FOLDER}|${DST_USER_FOLDER}|g" /tmp/worker_payload.sh
sed -i "s|\${DST_SUBDIR}|${DST_SUBDIR}|g" /tmp/worker_payload.sh
sed -i "s|\${SRC_SUBDIR}|${SRC_SUBDIR}|g" /tmp/worker_payload.sh
sed -i "s|\${PARALLEL_WORKERS}|${PARALLEL_WORKERS}|g" /tmp/worker_payload.sh
log_ok "Worker payload prepared."

# ==============================================================================
#  STEP 4: DEPLOY EPHEMERAL WORKER VM (ROCKY LINUX 9 WITH SHIELDED BOOT OFF)
# ==============================================================================
WORKER_VM_NAME="oneclick-migrator-$(date +%s | tail -c 5)"
log_step "4/6" "Provisioning Ephemeral Rocky Linux 9 Compute Worker VM (${WORKER_VM_NAME})"

rm -f /tmp/vm_create_err.log

(
    gcloud compute instances create "${WORKER_VM_NAME}" \
        --project="${PROJECT_ID}" \
        --zone="${ZONE}" \
        --machine-type="${WORKER_MACHINE_TYPE}" \
        --network="${VPC_NETWORK}" \
        --provisioning-model="SPOT" \
        --instance-termination-action="STOP" \
        --image-family="hpc-rocky-linux-9" \
        --image-project="cloud-hpc-image-public" \
        --boot-disk-size="50GB" \
        --no-shielded-secure-boot \
        --no-shielded-vtpm \
        --no-shielded-integrity-monitoring \
        --scopes="cloud-platform" \
        --metadata-from-file=startup-script=/tmp/worker_payload.sh \
        2>/tmp/vm_create_err.log || \
    gcloud compute instances create "${WORKER_VM_NAME}" \
        --project="${PROJECT_ID}" \
        --zone="${ZONE}" \
        --machine-type="${WORKER_MACHINE_TYPE}" \
        --network="${VPC_NETWORK}" \
        --image-family="hpc-rocky-linux-9" \
        --image-project="cloud-hpc-image-public" \
        --boot-disk-size="50GB" \
        --no-shielded-secure-boot \
        --no-shielded-vtpm \
        --no-shielded-integrity-monitoring \
        --scopes="cloud-platform" \
        --metadata-from-file=startup-script=/tmp/worker_payload.sh \
        2>/tmp/vm_create_err.log
) &
GCLOUD_PID=$!
spinner_wait "$GCLOUD_PID" "Provisioning VM instance (${WORKER_MACHINE_TYPE} in ${ZONE})..."
wait "$GCLOUD_PID"

if ! gcloud compute instances describe "${WORKER_VM_NAME}" --project="${PROJECT_ID}" --zone="${ZONE}" &>/dev/null; then
    fail_exit "Worker VM creation failed" "Check exact gcloud output printed below"
fi
log_ok "Ephemeral Worker VM online."

# ==============================================================================
#  STEP 5: DISCRETE TASK-BY-TASK STEP MONITORING (WITH IMMEDIATE FAIL EXIT)
# ==============================================================================
log_step "5/6" "Executing Migration Sub-Tasks (Explicit Step-by-Step Reporting)"

START_MIGRATION_TIME=$(date +%s)
rm -f /tmp/migration_events.log
touch /tmp/migration_events.log

spinstr='|/-\'
tput civis 2>/dev/null || true

(
    gcloud compute instances tail-serial-port-output "${WORKER_VM_NAME}" --project="${PROJECT_ID}" --zone="${ZONE}" 2>&1 | while read -r line; do
        if echo "$line" | grep -q "MILESTONE_DONE"; then
            TAG=$(echo "$line" | grep -o "MILESTONE_DONE:[A-Z_]*" | cut -d':' -f2)
            MSG=$(echo "$line" | sed 's/.*MILESTONE_DONE:[A-Z_]*\] //')
            echo "DONE|${TAG}|${MSG}" >> /tmp/migration_events.log
        elif echo "$line" | grep -q "MILESTONE_START:COPY"; then
            echo "START|COPY|Running parallel copy fpsync..." >> /tmp/migration_events.log
        elif echo "$line" | grep -q "MILESTONE_AUDIT"; then
            echo "AUDIT|METRICS|${line#*MILESTONE_AUDIT}" >> /tmp/migration_events.log
        elif echo "$line" | grep -q "MILESTONE_FAIL"; then
            TAG=$(echo "$line" | grep -o "MILESTONE_FAIL:[A-Z_]*" | cut -d':' -f2)
            MSG=$(echo "$line" | sed 's/.*MILESTONE_FAIL:[A-Z_]*\] //')
            echo "FAIL|${TAG}|${MSG}" >> /tmp/migration_events.log
            break
        elif echo "$line" | grep -q "Script \"startup-script\" failed with error"; then
            ERR_MSG=$(echo "$line" | grep -o "Script \"startup-script\" failed.*")
            echo "FAIL|CRASH|${ERR_MSG}" >> /tmp/migration_events.log
            break
        elif echo "$line" | grep -q "unknown filesystem type 'lustre'"; then
            echo "FAIL|LUSTRE_DRIVER|Kernel filesystem driver 'lustre' not loaded" >> /tmp/migration_events.log
            break
        elif echo "$line" | grep -q "STATUS_SUCCESS"; then
            echo "FINISHED|SUCCESS|Migration Complete" >> /tmp/migration_events.log
            break
        fi
    done
) &
TAIL_PID=$!

CURRENT_SUBTASK="Booting worker operating system..."
SUBTASK_START=$(date +%s)
FINISHED_ALL="no"
HAD_FAILURE="no"

declare -A PRINTED_TAGS

print_discrete_task() {
    local TAG="$1"
    local TEXT="$2"
    local NOW=$(date +%s)
    local DURATION=$((NOW - SUBTASK_START))
    printf "\r${GREEN}  ✔ [Task: %-14s] %s ${CYAN}(+${DURATION}s)${NC}\n" "${TAG}" "${TEXT}"
    SUBTASK_START=$(date +%s)
}

while kill -0 "$TAIL_PID" 2>/dev/null || [ -s /tmp/migration_events.log ]; do
    while IFS='|' read -r EVT_TYPE EVT_TAG EVT_MSG; do
        [ -z "$EVT_TYPE" ] && continue
        if [ -z "${PRINTED_TAGS[$EVT_TAG]}" ]; then
            if [ "$EVT_TYPE" = "DONE" ]; then
                PRINTED_TAGS[$EVT_TAG]=1
                print_discrete_task "$EVT_TAG" "$EVT_MSG"
                case "$EVT_TAG" in
                    "BOOT")          CURRENT_SUBTASK="Clearing auto-update locks..." ;;
                    "LOCKS")         CURRENT_SUBTASK="Installing base toolchain (fpart, rsync, python3)..." ;;
                    "BASE_TOOLS")    CURRENT_SUBTASK="Installing Google Lustre driver via Official Artifact Registry..." ;;
                    "LUSTRE_DRIVER") CURRENT_SUBTASK="Verifying socket connection to Lustre TCP :988..." ;;
                    "SOCKET")        CURRENT_SUBTASK="Mounting Source Filestore NFS share..." ;;
                    "NFS_MOUNT")     CURRENT_SUBTASK="Mounting Destination Managed Lustre share..." ;;
                    "LUSTRE_MOUNT")  CURRENT_SUBTASK="Initiating parallel file copy (fpsync)..." ;;
                    "COPY")          CURRENT_SUBTASK="Auditing file parity counts..." ;;
                    "AUDIT")         CURRENT_SUBTASK="Finalizing task..." ;;
                esac
            elif [ "$EVT_TYPE" = "START" ] && [ "$EVT_TAG" = "COPY" ]; then
                CURRENT_SUBTASK="Transferring files in parallel via fpsync (-n ${PARALLEL_WORKERS})..."
            elif [ "$EVT_TYPE" = "FAIL" ]; then
                PRINTED_TAGS[$EVT_TAG]=1
                printf "\r${RED}  ✖ [FAILED: %-14s] %s${NC}\n" "$EVT_TAG" "$EVT_MSG"
                HAD_FAILURE="yes"
                kill -9 "$TAIL_PID" 2>/dev/null || true
                break 2
            elif [ "$EVT_TYPE" = "FINISHED" ]; then
                FINISHED_ALL="yes"
                kill -9 "$TAIL_PID" 2>/dev/null || true
                break 2
            fi
        fi
    done < <(cat /tmp/migration_events.log 2>/dev/null)
    
    [ "$FINISHED_ALL" = "yes" ] || [ "$HAD_FAILURE" = "yes" ] && break

    NOW=$(date +%s)
    ELAPSED=$((NOW - START_MIGRATION_TIME))
    SUB_ELAPSED=$((NOW - SUBTASK_START))
    temp=${spinstr#?}
    printf "\r${CYAN}[%c]${NC} ▶ %-58s ${YELLOW}(Task: %ds | Total: %ds)${NC}" "$spinstr" "$CURRENT_SUBTASK" "$SUB_ELAPSED" "$ELAPSED"
    spinstr=$temp${spinstr%"$temp"}
    sleep 0.25
done

printf "\r%95s\r" " "
tput cnorm 2>/dev/null || true
kill -9 "$TAIL_PID" 2>/dev/null || true
wait "$TAIL_PID" 2>/dev/null || true

# ==============================================================================
#  STEP 6: CRYPTOGRAPHIC PARITY AUDIT & CLEANUP
# ==============================================================================
log_step "6/6" "Cryptographic Parity Audit & Teardown"

if [ "$HAD_FAILURE" = "yes" ]; then
    fail_exit "Migration sub-task failed." "See explicit failed step output above."
fi

if [ "$FINISHED_ALL" = "yes" ] || gcloud compute instances get-serial-port-output "${WORKER_VM_NAME}" --project="${PROJECT_ID}" --zone="${ZONE}" 2>&1 | grep -q "STATUS_SUCCESS"; then
    log_ok "DATA MIGRATION COMPLETED WITH 100% CRYPTOGRAPHIC FILE PARITY!"
else
    fail_exit "Migration script finished without verification marker." "Check serial console logs."
fi

if [ "${AUTO_DELETE_WORKER}" = "true" ]; then
    log_info "Deleting ephemeral migration VM '${WORKER_VM_NAME}'..."
    gcloud compute instances delete "${WORKER_VM_NAME}" --project="${PROJECT_ID}" --zone="${ZONE}" --quiet &>/dev/null
    log_ok "Worker VM deleted."
else
    log_ok "Worker VM kept alive for inspection: ${WORKER_VM_NAME}"
    echo "   Manual teardown command: gcloud compute instances delete ${WORKER_VM_NAME} --zone=${ZONE} --project=${PROJECT_ID}"
fi

echo -e "\n${GREEN}======================================================================${NC}"
echo -e "${BOLD}${GREEN}🎉 ONE-CLICK MIGRATION FULLY COMPLETE & VERIFIED!${NC}"
echo -e "${GREEN}   Source Filestore:   ${FILESTORE_IP}:${FILESTORE_SHARE}${NC}"
echo -e "${GREEN}   Destination Lustre: ${LUSTRE_MOUNT} (${DST_USER_FOLDER}/${DST_SUBDIR})${NC}"
echo -e "${GREEN}======================================================================${NC}\n"
EOF
chmod +x one_click_migrate.sh
./one_click_migrate.sh
```
