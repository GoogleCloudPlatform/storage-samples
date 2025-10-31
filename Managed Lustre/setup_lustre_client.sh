#!/bin/bash
set -e # Exit immediately if any command fails

# --- 1. Check for Mount Point Argument ---
if [ -z "$1" ]; then
    echo "ERROR: You must provide the Lustre mount point as the first argument."
    echo "Usage: ./setup_lustre_client.sh 10.x.x.x@tcp:/fsname"
    exit 1
fi

LUSTRE_MOUNT_POINT=$1
MOUNT_DIR="/mnt/lustre"

echo "--- Starting Lustre Client Setup for $LUSTRE_MOUNT_POINT ---"

# --- 2. Add the Lustre Repo ---
echo "Adding Google Lustre client repository..."
gcloud beta artifacts print-settings yum \
    --repository=lustre-client-rocky-8 \
    --location=us --project=lustre-client-binaries | sudo bash

# --- 3. Install Client Packages ---
echo "Installing Lustre client packages..."
sudo yum -y --enablerepo=lustre-client-rocky-8 install kmod-lustre-client
sudo yum -y --enablerepo=lustre-client-rocky-8 install lustre-client

# --- 4. Create Mount Directory ---
echo "Creating mount directory at $MOUNT_DIR..."
sudo mkdir -p $MOUNT_DIR

# --- 5. Mount the Drive (for this session) ---
echo "Mounting Lustre file system..."
sudo mount -t lustre $LUSTRE_MOUNT_POINT $MOUNT_DIR

# --- 6. Add to /etc/fstab to make it permanent ---
echo "Adding mount to /etc/fstab to make it permanent..."
# Check if it's already in fstab to avoid duplicate entries
if ! grep -q "$LUSTRE_MOUNT_POINT" /etc/fstab; then
    # Use '_netdev' to tell the system this is a network device
    # and it should wait for the network to be up before mounting.
    echo "$LUSTRE_MOUNT_POINT $MOUNT_DIR lustre defaults,_netdev,flock 0 0" | sudo tee -a /etc/fstab
else
    echo "fstab entry already exists. Skipping."
fi

# --- 7. Verify ---
echo "--- Setup Complete! Verifying mount... ---"
df -h $MOUNT_DIR
echo ""
echo "Success! $MOUNT_DIR is now mounted and will re-mount automatically on reboot."