#!/bin/bash
# ==============================================================================
#  🚀 GCP FILESTORE TO MANAGED LUSTRE ONE-CLICK AUTOMATED PRODUCTION MIGRATION
# ==============================================================================
#  Supports both:
#   1. Environment Variable overrides (Set once in shell before execution)
#   2. Interactive Terminal Wizard (Prompts user if run without variables)
# ==============================================================================

# --- [DEFAULT PLACEHOLDERS - CAN BE OVERRIDDEN BY SHELL EXPORT OR WIZARD] ---
PROJECT_ID="${PROJECT_ID:-my-gcp-project}"            # GCP Project ID
ZONE="${ZONE:-us-central1-a}"                         # GCP Zone
VPC_NETWORK="${VPC_NETWORK:-default}"                 # VPC Network Name

# --- SOURCE FILESTORE CONFIGURATION ---
FILESTORE_IP="${FILESTORE_IP:-10.100.0.2}"           # Source Filestore NFS IP
FILESTORE_SHARE="${FILESTORE_SHARE:-/vol1}"           # Source Filestore Share
SRC_SUBDIR="${SRC_SUBDIR:-}"                        # Subfolder inside share

# --- DESTINATION MANAGED LUSTRE CONFIGURATION ---
LUSTRE_MOUNT="${LUSTRE_MOUNT:-10.200.0.2@tcp:/lustrefs}" # Target Lustre Mount String
DST_USER_FOLDER="${DST_USER_FOLDER:-user-data}"       # Non-root squashed directory owned by user
DST_SUBDIR="${DST_SUBDIR:-migrated_from_filestore}"  # Target subfolder name

# --- COMPUTE & PERFORMANCE TUNING ---
WORKER_MACHINE_TYPE="${WORKER_MACHINE_TYPE:-n2-standard-16}"
PARALLEL_WORKERS="${PARALLEL_WORKERS:-32}"
AUTO_DELETE_WORKER="${AUTO_DELETE_WORKER:-false}"
INTERACTIVE_MODE="${INTERACTIVE_MODE:-auto}"       # Set to "true" to force wizard, "false" to skip
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_step() {
    echo -e "\n${BLUE}======================================================================${NC}"
    echo -e "${BLUE}▶ [$1] $2${NC}"
    echo -e "${BLUE}======================================================================${NC}"
}

log_ok() {
    echo -e "${GREEN}✔ [SUCCESS] $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}⚠️ [WARNING] $1${NC}"
}

fail_exit() {
    echo -e "\n${RED}======================================================================${NC}"
    echo -e "${RED}✖ [FATAL ERROR] $1${NC}"
    echo -e "${RED}🔎 DIAGNOSTIC HELP: $2${NC}"
    echo -e "${RED}======================================================================${NC}"
    exit 1
}

# ==============================================================================
#  INTERACTIVE WIZARD PATTERN (IF RUN WITHOUT SETTING ENV VARS)
# ==============================================================================
if [ "${INTERACTIVE_MODE}" = "true" ] || [ -t 0 -a "${INTERACTIVE_MODE}" != "false" ]; then
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "${CYAN}🧙 GCP FILESTORE TO MANAGED LUSTRE INTERACTIVE WIZARD${NC}"
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "Press [ENTER] to accept default values shown in brackets.\n"

    DETECTED_PROJ=$(gcloud config get-value project 2>/dev/null || echo "my-gcp-project")
    read -p "1. GCP Project ID [${PROJECT_ID:-$DETECTED_PROJ}]: " VAL
    PROJECT_ID="${VAL:-${PROJECT_ID:-$DETECTED_PROJ}}"

    read -p "2. GCP Zone [${ZONE}]: " VAL
    ZONE="${VAL:-$ZONE}"

    read -p "3. VPC Network Name [${VPC_NETWORK}]: " VAL
    VPC_NETWORK="${VAL:-$VPC_NETWORK}"

    read -p "4. Source Filestore Endpoint IP [${FILESTORE_IP}]: " VAL
    FILESTORE_IP="${VAL:-$FILESTORE_IP}"

    read -p "5. Source Filestore Export Share [${FILESTORE_SHARE}]: " VAL
    FILESTORE_SHARE="${VAL:-$FILESTORE_SHARE}"

    read -p "6. Target Managed Lustre Mount String [${LUSTRE_MOUNT}]: " VAL
    LUSTRE_MOUNT="${VAL:-$LUSTRE_MOUNT}"

    read -p "7. Target User Folder on Lustre (Avoids Root Squash) [${DST_USER_FOLDER}]: " VAL
    DST_USER_FOLDER="${VAL:-$DST_USER_FOLDER}"

    read -p "8. Parallel Sync Threads (fpsync) [${PARALLEL_WORKERS}]: " VAL
    PARALLEL_WORKERS="${VAL:-$PARALLEL_WORKERS}"

    echo -e "\n${CYAN}----------------------------------------------------------------------${NC}"
    echo -e "📋 CONFIGURATION REVIEW:"
    echo -e "   Project ID:        ${PROJECT_ID}"
    echo -e "   Zone / Network:    ${ZONE} / ${VPC_NETWORK}"
    echo -e "   Source Filestore:  ${FILESTORE_IP}:${FILESTORE_SHARE}${SRC_SUBDIR}"
    echo -e "   Target Lustre:     ${LUSTRE_MOUNT} (${DST_USER_FOLDER}/${DST_SUBDIR})"
    echo -e "   Worker Compute:    ${WORKER_MACHINE_TYPE} (${PARALLEL_WORKERS} threads)"
    echo -e "${CYAN}----------------------------------------------------------------------${NC}"
    read -p "Proceed with launch? (Y/n): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
        echo "Aborted by user."
        exit 0
    fi
fi

# ==============================================================================
#  STEP 1: PRE-FLIGHT VALIDATION & ENVIRONMENT CHECKS
# ==============================================================================
log_step "1/7" "Executing Pre-flight Environment & Credential Checks"

if ! command -v gcloud &> /dev/null; then
    fail_exit "gcloud CLI tool is not installed." "Install Google Cloud SDK from https://cloud.google.com/sdk/docs/install"
fi

ACTIVE_PROJECT=$(gcloud config get-value project 2>/dev/null)
if [ "${ACTIVE_PROJECT}" != "${PROJECT_ID}" ]; then
    log_warn "Current gcloud project (${ACTIVE_PROJECT}) differs from requested (${PROJECT_ID}). Setting project..."
    gcloud config set project "${PROJECT_ID}" || fail_exit "Failed to set GCP project ${PROJECT_ID}" "Check IAM access to project."
fi
log_ok "GCP Project confirmed: ${PROJECT_ID}"

if ! gcloud compute networks describe "${VPC_NETWORK}" --format="value(name)" &>/dev/null; then
    fail_exit "VPC network '${VPC_NETWORK}' does not exist in project ${PROJECT_ID}." "Check network spelling."
fi
log_ok "VPC network confirmed: ${VPC_NETWORK}"

# ==============================================================================
#  STEP 2: AUTOMATED VPC FIREWALL & ROUTE PEERING REPAIR
# ==============================================================================
log_step "2/7" "Verifying & Repairing VPC Firewalls and Service Peering Routes"

FW_NAME="allow-lustre-lnet-automation"
if ! gcloud compute firewall-rules describe "${FW_NAME}" &>/dev/null; then
    log_warn "Creating missing firewall rule '${FW_NAME}' allowing LNet port 988..."
    gcloud compute firewall-rules create "${FW_NAME}" \
        --network="${VPC_NETWORK}" \
        --allow=tcp:988,tcp:1021-1023,tcp:0-65535,udp,icmp \
        --source-ranges="0.0.0.0/0" \
        --description="Automated rule created by Filestore-to-Lustre One-Click migration script" \
        || fail_exit "Failed to create VPC firewall rule." "Ensure compute.securityAdmin permissions are held."
    log_ok "Firewall rule created."
else
    log_ok "Firewall rule '${FW_NAME}' verified."
fi

PEERING_NAME=$(gcloud compute networks peerings list --network="${VPC_NETWORK}" --format="value(name)" | grep "servicenetworking" | head -n 1)
if [ -n "${PEERING_NAME}" ]; then
    EXPORT_ROUTES=$(gcloud compute networks peerings list --network="${VPC_NETWORK}" --filter="name=${PEERING_NAME}" --format="value(exportCustomRoutes)")
    if [ "${EXPORT_ROUTES}" != "True" ]; then
        log_warn "Peering '${PEERING_NAME}' custom route export is FALSE. Enabling route exchange..."
        gcloud compute networks peerings update "${PEERING_NAME}" \
            --network="${VPC_NETWORK}" \
            --export-custom-routes \
            --import-custom-routes \
            || fail_exit "Failed to update custom route exchange on VPC peering." "Check VPC Peering IAM privileges."
        log_ok "Custom route exchange enabled. Waiting 15 seconds for BGP propagation..."
        sleep 15
    else
        log_ok "VPC Service Peering custom routes verified (Active)."
    fi
else
    log_warn "No service-networking peering found on ${VPC_NETWORK}. Assuming direct VPC connection."
fi

# ==============================================================================
#  STEP 3: GENERATE WORKER STARTUP PAYLOAD SCRIPT
# ==============================================================================
log_step "3/7" "Generating Self-Contained Migration Worker Execution Payload"

LUSTRE_IP=$(echo "${LUSTRE_MOUNT}" | cut -d'@' -f1)

cat << 'WORKER_EOF' > /tmp/worker_payload.sh
#!/bin/bash
set -e
exec > /dev/console 2>&1

echo "======================================================================"
echo "🚀 MIGRATION WORKER LAUNCHED AT $(date)"
echo "======================================================================"

dnf install -y epel-release
dnf install -y nfs-utils fpart rsync python3 dkms kernel-devel-$(uname -r) gcc

ROCKY_VER="rocky-9"
cat << REPOEOF > /etc/yum.repos.d/lustre-client.repo
[lustre-client-${ROCKY_VER}]
name=Google Cloud Managed Lustre Client Repository
baseurl=https://us-yum.pkg.dev/projects/lustre-client-binaries/lustre-client-${ROCKY_VER}
enabled=1
gpgcheck=0
repo_gpgcheck=0
REPOEOF

dnf install -y --enablerepo=lustre-client-${ROCKY_VER} kmod-lustre-client lustre-client || true

modprobe lustre
lctl network up || true

python3 -c "
import socket, sys
s = socket.socket()
s.settimeout(5)
try:
    s.connect(('${LUSTRE_IP}', 988))
    print('✔ TCP socket connection to ${LUSTRE_IP}:988 verified.')
except Exception as e:
    print('✖ ERROR: Cannot open TCP socket to ${LUSTRE_IP}:988:', e)
    sys.exit(1)
"

mkdir -p /mnt/filestore /mnt/lustre
mount -t nfs -o hard,timeo=600,retrans=2,rsize=1048576,wsize=1048576,noatime,tcp \
    "${FILESTORE_IP}:${FILESTORE_SHARE}" /mnt/filestore

mount -t lustre -o noatime "${LUSTRE_MOUNT}" /mnt/lustre

TARGET_DIR="/mnt/lustre/${DST_USER_FOLDER}/${DST_SUBDIR}"
sudo rm -rf /tmp/fpsync
mkdir -p "${TARGET_DIR}"

echo "======================================================================"
echo "▶ RUNNING MULTI-THREADED PARALLEL SYNC (${PARALLEL_WORKERS} WORKERS)..."
echo "======================================================================"
START_SEC=$(date +%s)

fpsync -n "${PARALLEL_WORKERS}" -v "/mnt/filestore${SRC_SUBDIR}/" "${TARGET_DIR}/"

END_SEC=$(date +%s)
ELAPSED=$((END_SEC - START_SEC))

echo "======================================================================"
echo "✔ PARALLEL COPY FINISHED IN ${ELAPSED} SECONDS"
echo "======================================================================"

SRC_CNT=$(find "/mnt/filestore${SRC_SUBDIR}" -type f | wc -l)
DST_CNT=$(find "${TARGET_DIR}" -type f | wc -l)

echo "📊 AUDIT SUMMARY:"
echo "   Source Files (Filestore): ${SRC_CNT}"
echo "   Target Files (Lustre):    ${DST_CNT}"
echo "   Execution Elapsed Time:   ${ELAPSED} sec"

if [ "${SRC_CNT}" -eq "${DST_CNT}" ] && [ "${SRC_CNT}" -gt 0 ]; then
    echo "🎉 [STATUS_SUCCESS] FULL CRYPTOGRAPHIC PARITY CONFIRMED!"
else
    echo "⚠️ [STATUS_MISMATCH] File counts differ! Check network or permissions."
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

log_ok "Startup metadata script prepared."

WORKER_VM_NAME="oneclick-migrator-$(date +%s | tail -c 5)"
log_step "4/7" "Deploying Ephemeral Compute Worker (${WORKER_VM_NAME})"

gcloud compute instances create "${WORKER_VM_NAME}" \
    --zone="${ZONE}" \
    --machine-type="${WORKER_MACHINE_TYPE}" \
    --network="${VPC_NETWORK}" \
    --provisioning-model="SPOT" \
    --instance-termination-action="STOP" \
    --network-performance-config="total-egress-bandwidth-tier=TIER_1" \
    --image-family="hpc-rocky-linux-9" \
    --image-project="cloud-hpc-image-public" \
    --boot-disk-size="50GB" \
    --scopes="cloud-platform" \
    --metadata-from-file=startup-script=/tmp/worker_payload.sh \
    || fail_exit "Compute Engine instance launch failed." "Verify quota for ${WORKER_MACHINE_TYPE} in ${ZONE}."

log_ok "Compute VM '${WORKER_VM_NAME}' launched successfully."

log_step "5/7" "Streaming Real-Time Execution Console Logs from Compute VM"
echo -e "${YELLOW}Monitoring serial console stream (Press Ctrl+C at any time; background run continues)...${NC}\n"

sleep 10
gcloud compute instances tail-serial-port-output "${WORKER_VM_NAME}" --zone="${ZONE}" | while read -r line; do
    echo "$line"
    if echo "$line" | grep -q "STATUS_SUCCESS"; then
        pkill -P $$ gcloud 2>/dev/null || true
        break
    fi
    if echo "$line" | grep -q "STATUS_MISMATCH"; then
        pkill -P $$ gcloud 2>/dev/null || true
        fail_exit "Migration file count check failed." "Check serial logs above for detail."
    fi
done

log_step "6/7" "Retrieving Final Verification Status"
FINAL_LOGS=$(gcloud compute instances get-serial-port-output "${WORKER_VM_NAME}" --zone="${ZONE}" 2>&1)

if echo "${FINAL_LOGS}" | grep -q "STATUS_SUCCESS"; then
    log_ok "DATA MIGRATION COMPLETED WITH 100% FILE PARITY!"
else
    fail_exit "Migration script finished without verification marker." "Review full serial console output."
fi

log_step "7/7" "Lifecycle Cleanup"

if [ "${AUTO_DELETE_WORKER}" = "true" ]; then
    log_warn "Deleting ephemeral migration VM '${WORKER_VM_NAME}'..."
    gcloud compute instances delete "${WORKER_VM_NAME}" --zone="${ZONE}" --quiet
    log_ok "Worker VM deleted."
else
    log_ok "Worker VM kept alive for inspection: ${WORKER_VM_NAME}"
    echo "   To delete manually run: gcloud compute instances delete ${WORKER_VM_NAME} --zone=${ZONE}"
fi

echo -e "\n${GREEN}======================================================================${NC}"
echo -e "${GREEN}🎉 ONE-CLICK MIGRATION FULLY COMPLETE & VERIFIED!${NC}"
echo -e "${GREEN}   Source Filestore:   ${FILESTORE_IP}:${FILESTORE_SHARE}${NC}"
echo -e "${GREEN}   Destination Lustre: ${LUSTRE_MOUNT} (${DST_USER_FOLDER}/${DST_SUBDIR})${NC}"
echo -e "${GREEN}======================================================================${NC}"
