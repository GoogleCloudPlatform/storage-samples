### **Automated VM Connect to Lustre (Run these steps on each new VM)**

This workflow assumes you are starting on your Mac and logging into a brand-new VM (like `VmToConnect`).

#### **1\. SSH into your New VM**

From your Mac, log into the target VM.

Bash

```
ssh user@company.com
```

#### **2\. Install Nano (Optional but Recommended)**

Run this one-time command on the new VM to install the `nano` text editor, which makes the next step easier.

Bash

```
sudo yum install -y nano
```

#### **3\. Create the Setup Script**

Once you have `nano`, create the new script file:

Bash

```
nano setup_lustre_client.sh
```

#### **4\. Paste the Script Contents**

Paste the **entire script block below** into the `nano` editor.

This script does everything: adds the repo, installs the packages, creates the directory, mounts the drive, and makes the mount permanent (so it survives a reboot).

Bash

```
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
```

#### **5\. Save and Exit**

After pasting the script, save the file and exit `nano`:

1. Press **`Ctrl+O`**  
2. Press **`Enter`**  
3. Press **`Ctrl+X`**

#### **6\. Make the Script Executable**

Run this command to give the script permission to run:

Bash

```
chmod +x setup_lustre_client.sh
```

---

### **Final Step: Run the Script and Check the Connection**

This is the last part of your workflow.

#### **1\. Run the Script**

Execute the script, passing your Lustre mount point as the one and only argument:

Bash

```
./setup_lustre_client.sh XX.XX.XX.X@tcp:/YourFileSystemName
```

The script will now run all the steps automatically.

#### **2\. Check Its Connection to Other VMs**

Once the script is finished, run this command as requested:

Bash

```
ls -l /mnt/lustre
```

This will immediately show you all the shared files from your other VMs (like `bigfile1`, `test.txt`, `vm1_test_file`, etc.), confirming the new VM is successfully connected to the shared file system.

