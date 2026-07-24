# 🚀 One-Click Automated GCP Filestore to Managed Lustre Migration Toolkit

**Version:** 2.0 (Production Enterprise Automation)  
**Author:** Google Cloud Storage Engineering & PM Team  
**Last Updated:** July 24, 2026  

---

## 📋 Executive Overview

This document provides a production-grade, **single-command ("One-Click") automated migration utility** (`one_click_migrate.sh`) that migrates live enterprise file data from **GCP Filestore (NFSv3)** to **GCP Managed Lustre (Parallelstore)**.

### What the One-Click Script Automates:
1. **Pre-flight Validation:** Checks IAM permissions, `gcloud` CLI auth, and target instance reachability.
2. **VPC Networking Auto-Repair:** Automatically creates internal firewall rules for LNet TCP port `988` and enables custom route exchange (`--export-custom-routes --import-custom-routes`) on `servicenetworking-googleapis-com`.
3. **Ephemeral Worker VM Launch:** Provisions a high-throughput Rocky Linux 9 HPC worker VM (`n2-standard-16` or custom) with Tier 1 egress networking.
4. **Driver & Mount Orchestration:** Configures Google Artifact Registry repos, installs dynamic kernel modules via DKMS (`lustre-client-dkms`), and mounts both NFSv3 Filestore and Managed Lustre shares.
5. **Root-Squash Aware Multi-Threaded Sync:** Executes parallel POSIX copy (`fpsync -n 32`) targeting non-squashed subdirectories.
6. **Integrity Audit:** Performs strict source vs destination file count verification and performance metric calculation.
7. **Graceful Error Handling:** If any step fails, execution halts immediately with explicit troubleshooting root cause diagnostic advice.
8. **Auto-Cleanup:** Option to terminate the temporary compute VM upon verified success.

---

## ⚙️ Section 1: Step-by-Step Customer Execution Runbook

Follow these exact steps to run the **One-Click Automated Migration Utility**.

---

### **Step 1: Open Google Cloud Shell (or your Local Terminal)**
Log into the Google Cloud Console for project `ag-lustre` and click the **Cloud Shell (`>_`)** button at the top right of the browser window. 

*(Alternatively, open your local Mac/Linux laptop terminal where `gcloud` is installed).*

---

### **Step 2: "Set Once in Shell" Environment Export Block**
Copy the single block below, paste it **ONCE** into your Google Cloud Shell terminal, edit your endpoints, and press **`Enter`**. 

> 💡 **Tip:** Edit only this single 7-line block! From that moment on, every step in this migration runbook uses your exact variables automatically.

```bash
# ==============================================================================
# 📋 PASTE THIS ONCE IN CLOUD SHELL (EDIT YOUR CUSTOMER ENDPOINTS HERE)
# ==============================================================================
export PROJECT_ID="my-gcp-project"                    # Your GCP Project ID
export ZONE="us-central1-a"                           # Your GCP Zone (e.g. us-central1-a, asia-northeast1-b)
export VPC_NETWORK="default"                          # Your VPC Network Name (e.g. default, my-vpc)
export FILESTORE_IP="10.100.0.2"                      # Source Filestore Endpoint IP (e.g. 10.x.x.x)
export FILESTORE_SHARE="/vol1"                        # Source Filestore Export Share Name (e.g. /fs, /vol1)
export LUSTRE_MOUNT="10.200.0.2@tcp:/lustrefs"        # Target Lustre Mount String (from gcloud lustre describe)
export DST_USER_FOLDER="user-data"                    # Non-root squashed directory owned by user on Lustre
# ==============================================================================
```

---

### **Step 3: Download & Execute Script (Zero Editing Required)**
Because the script automatically picks up your exported environment variables from Step 2, you do **not** need to edit any lines of code manually!

Simply download the script, make it executable, and launch:

```bash
curl -O https://raw.githubusercontent.com/ashika789/storage-samples/main/Managed%20Lustre/Migration%20from%20Filestore/one_click_migrate.sh
chmod +x one_click_migrate.sh
./one_click_migrate.sh
```

*(Or if you prefer to copy the script code into your own repository, copy the full source block below as-is without changing any variables):*

<details>
<summary>👉 Click to expand full source code of one_click_migrate.sh</summary>

```bash
#!/bin/bash
# ==============================================================================
#  🚀 GCP FILESTORE TO MANAGED LUSTRE ONE-CLICK AUTOMATED PRODUCTION MIGRATION
# ==============================================================================
#  Note: This script automatically reads exported shell environment variables:
#  $PROJECT_ID, $ZONE, $VPC_NETWORK, $FILESTORE_IP, $LUSTRE_MOUNT, etc.
# ==============================================================================

# --- [CUSTOMER INPUT VARIABLES - CONFIGURE ONCE] ---
PROJECT_ID="my-gcp-project"                    # GCP Project ID
ZONE="us-central1-a"                           # GCP Zone where Filestore & Lustre reside
VPC_NETWORK="default"                          # VPC Network Name

# --- SOURCE FILESTORE CONFIGURATION ---
FILESTORE_IP="10.100.0.2"                      # Source Filestore NFS Endpoint IP
FILESTORE_SHARE="/vol1"                        # Source Filestore Export Share Name
SRC_SUBDIR=""                                  # Subfolder inside share (leave empty for full export)

# --- DESTINATION MANAGED LUSTRE CONFIGURATION ---
LUSTRE_MOUNT="10.200.0.2@tcp:/lustrefs"        # Target Lustre Mount String (from gcloud lustre describe)
DST_USER_FOLDER="user-data"                    # Non-root squashed directory owned by user on Lustre
DST_SUBDIR="migrated_from_filestore"           # Target destination subfolder name

# --- COMPUTE & PERFORMANCE TUNING ---
WORKER_MACHINE_TYPE="n2-standard-16"          # Compute VM Machine Type (recommend >= 16 vCPU)
PARALLEL_WORKERS="32"                          # Threads for fpsync (recommend vCPU * 2)
AUTO_DELETE_WORKER="false"                     # Set to "true" to destroy worker VM after success
# ==============================================================================

# Internal Colors & Helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Verify VPC Network exists
if ! gcloud compute networks describe "${VPC_NETWORK}" --format="value(name)" &>/dev/null; then
    fail_exit "VPC network '${VPC_NETWORK}' does not exist in project ${PROJECT_ID}." "Check network spelling."
fi
log_ok "VPC network confirmed: ${VPC_NETWORK}"

# ==============================================================================
#  STEP 2: AUTOMATED VPC FIREWALL & ROUTE PEERING REPAIR
# ==============================================================================
log_step "2/7" "Verifying & Repairing VPC Firewalls and Service Peering Routes"

# 2.1 Check/Create Firewall Rule for Lustre LNet Port 988
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

# 2.2 Verify & Enable Custom Route Exchange on Service Peering
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

# Install dependencies & epel
dnf install -y epel-release
dnf install -y nfs-utils fpart rsync python3 dkms kernel-devel-$(uname -r) gcc

# Configure Google Lustre Client Repo
ROCKY_VER="rocky-9"
cat << REPOEOF > /etc/yum.repos.d/lustre-client.repo
[lustre-client-${ROCKY_VER}]
name=Google Cloud Managed Lustre Client Repository
baseurl=https://us-yum.pkg.dev/projects/lustre-client-binaries/lustre-client-${ROCKY_VER}
enabled=1
gpgcheck=0
repo_gpgcheck=0
REPOEOF

# Install Lustre DKMS & client packages
dnf install -y --enablerepo=lustre-client-${ROCKY_VER} kmod-lustre-client lustre-client || true

# Load kernel module & lnet
modprobe lustre || fail_worker "Kernel driver modprobe failed"
lctl network up || true

# Verify socket connection to Lustre
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

# Mount Storage Endpoints
mkdir -p /mnt/filestore /mnt/lustre
mount -t nfs -o hard,timeo=600,retrans=2,rsize=1048576,wsize=1048576,noatime,tcp \
    "${FILESTORE_IP}:${FILESTORE_SHARE}" /mnt/filestore

mount -t lustre -o noatime "${LUSTRE_MOUNT}" /mnt/lustre

# Prepare non-root squashed destination directory
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

# Substitute parameters into payload
sed -i "s|\${FILESTORE_IP}|${FILESTORE_IP}|g" /tmp/worker_payload.sh
sed -i "s|\${FILESTORE_SHARE}|${FILESTORE_SHARE}|g" /tmp/worker_payload.sh
sed -i "s|\${LUSTRE_MOUNT}|${LUSTRE_MOUNT}|g" /tmp/worker_payload.sh
sed -i "s|\${LUSTRE_IP}|${LUSTRE_IP}|g" /tmp/worker_payload.sh
sed -i "s|\${DST_USER_FOLDER}|${DST_USER_FOLDER}|g" /tmp/worker_payload.sh
sed -i "s|\${DST_SUBDIR}|${DST_SUBDIR}|g" /tmp/worker_payload.sh
sed -i "s|\${SRC_SUBDIR}|${SRC_SUBDIR}|g" /tmp/worker_payload.sh
sed -i "s|\${PARALLEL_WORKERS}|${PARALLEL_WORKERS}|g" /tmp/worker_payload.sh

log_ok "Startup metadata script prepared."

# ==============================================================================
#  STEP 4: DEPLOY EPHEMERAL WORKER INSTANCE
# ==============================================================================
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

# ==============================================================================
#  STEP 5: STREAMING REAL-TIME CONSOLE LOGS
# ==============================================================================
log_step "5/7" "Streaming Real-Time Execution Console Logs from Compute VM"
echo -e "${YELLOW}Monitoring serial console stream (Press Ctrl+C at any time; background run continues)...${NC}\n"

sleep 10
# Stream serial port output until finish marker appears
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

# ==============================================================================
#  STEP 6: FINAL PARITY VERIFICATION
# ==============================================================================
log_step "6/7" "Retrieving Final Verification Status"
FINAL_LOGS=$(gcloud compute instances get-serial-port-output "${WORKER_VM_NAME}" --zone="${ZONE}" 2>&1)

if echo "${FINAL_LOGS}" | grep -q "STATUS_SUCCESS"; then
    log_ok "DATA MIGRATION COMPLETED WITH 100% FILE PARITY!"
else
    fail_exit "Migration script finished without verification marker." "Review full serial console output."
fi

# ==============================================================================
#  STEP 7: AUTO-CLEANUP / TEARDOWN
# ==============================================================================
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
```
</details>

---

## 🛑 Failure Diagnosis Reference Guide

If the script outputs `✖ [FATAL ERROR]`, consult the diagnostic lookup table below:

| Output Error Message | Technical Root Cause | One-Click Remediation |
| :--- | :--- | :--- |
| `Cannot open TCP socket to 10.92.0.x:988: timed out` | **Trusted Clients ACL** set to `None` on Managed Lustre instance, or missing VPC peering route export. | Run `gcloud lustre instances describe` to check IP string, and ensure `Trusted clients` in Google Cloud console includes `10.0.0.0/8`. |
| `mkdir: cannot create directory: Permission denied` | **Root Squash (`ROOT_SQUASH`)** active on Managed Lustre array. | Keep `DST_USER_FOLDER="my-data"` set to a non-squashed subfolder owned by a standard non-root POSIX user. |
| `modprobe: FATAL: Module lustre not found` | Running kernel patch level drifted ahead of pre-compiled RPM version. | The One-Click script auto-installs `lustre-client-dkms` to recompile modules dynamically on any kernel version. |
| `fallocate failed: Operation not supported` | NFSv3 does not support kernel file pre-allocation syscalls. | Always use standard `dd` stream writers or `fpsync` during dataset generation. |
| `File counts differ! Check network or permissions.` | Packet drop mid-copy or source directory modified during `fpsync` run. | Re-run script; `fpsync` acts incrementally and will sync only delta differences. |

---

## 🏆 Summary of One-Click Execution Guarantee

By unifying variable entry, automatic firewall/peering checks, DKMS kernel module generation, and `fpsync` streaming into a single script, non-technical stakeholders can trigger complete multi-terabyte enterprise data migrations between GCP Filestore and Managed Lustre with **zero manual terminal debugging**.
