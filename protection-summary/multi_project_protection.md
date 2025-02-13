# Multi-Project Protection Using gCloud for Vaulted Backups

**Author:** Ashika Ganesh  
**Last Updated:** Feb 12, 2025  

- [Overview](#overview)  
- [Set Up and Permissions](#set-up-and-permissions)  
- [Getting Started](#getting-started)  
- [Example Command Usage](#example-command-usage)  
- [Best Practices](#best-practices)  

---

## Overview

This document shows you how to manage backups for your **Google Compute Engine VMs** across **multiple projects** using a Bash script named `apply_protection_summary.sh`. You can easily associate a Backup and DR **backup plan** with any unprotected VMs in your projects, ensuring a consistent level of protection.

**Key Features**:
- **Multi-project support**: Specify one or more projects at once (e.g., `--projects="proj-a,proj-b"`).  
- **Dry-run mode**: A recommended first step (`--dry-run`) to see **which VMs** will be affected without actually applying the backup plan.  
- **Straightforward setup**: Run a single script directly from **Google Cloud Shell**—no specialized environment needed.

> **Note**: The BackupDR endpoint only **refreshes hourly**, so newly protected VMs may remain listed as “unprotected” for up to an hour.

---

## Set Up and Permissions

1. **Roles in Each VM Project**  
   - **Backup and DR Backup User** (or higher, such as **Backup Admin**).  
   - The **Compute Engine API** and **BackupDR API** must be enabled.

2. **Backup Plan Project**  
   - **Backup and DR Backup User** or **Backup Admin** is required to manage or create associations.  
   - A valid **backup plan** must exist in the region you specify (e.g., `us-central1`).

3. **Vault Service Agent**  
   - The **Backup Vault Service Agent** for your chosen vault needs roles (such as `roles/backupdr.computeEngineOperator`) in **each VM project** to manage VMs on behalf of the backup service.

---

## Getting Started

### 1. Obtain the Script
Ensure you have the file `apply_protection_summary.sh` locally.

### 2. Open Google Cloud Shell
1. Navigate to [Google Cloud Console](https://console.cloud.google.com).  
2. Click the **Cloud Shell** icon to open a shell session.

### 3. Upload the Script
1. In the Cloud Shell, click the **three vertical dots** → **Upload**.  
2. Select `apply_protection_summary.sh` from your local machine.  
3. It will appear in your home directory (`~/`) in Cloud Shell.

### 4. Make the Script Executable
```bash
chmod +x apply_protection_summary.sh
```

### 5. **Dry-Run** (Recommended First Step)
```bash
./apply_protection_summary.sh \
  --projects="proj-a,proj-b" \
  --backup-plan-project="vault-project" \
  --location="us-central1" \
  --backup-plan="bp-bronze" \
  --dry-run
```
- **`--projects`**: Comma-separated list of projects containing your unprotected VMs.  
- **`--backup-plan-project`**: The project where your backup plan (`bp-bronze`) resides.  
- **`--location`**: The region of your backup plan (e.g., `us-central1`).  
- **`--backup-plan`**: The **name** of your backup plan.  
- **`--dry-run`**: Lists which VMs would be protected without applying any changes.

**Expected Output**:  
- A list of **unprotected** VMs found, plus a “No changes will be made” message.  
- **No** new associations are created in this mode.

### 6. Final Apply (Remove `--dry-run`)
```bash
./apply_protection_summary.sh \
  --projects="proj-a,proj-b" \
  --backup-plan-project="vault-project" \
  --location="us-central1" \
  --backup-plan="bp-bronze"
```
- Creates new **backup plan associations** for VMs in those projects.  
- If a VM is already protected or in a different region, it’s skipped automatically.

### 7. Verify Changes
- **Script Output**: Look for “Successfully applied backup plan…” messages.  
- **Backup & DR Console**: Check the backup plan details and the VMs list.  
- Keep in mind the **1-hour refresh delay** on `resourceBackupConfigs`.

---

## Example Command Usage

### Dry-Run Across Two Projects
```bash
./apply_protection_summary.sh \
  --projects="prod-demo-app,prod-demo-vault" \
  --backup-plan-project="prod-demo-vault" \
  --location="asia-east1" \
  --backup-plan="bp-gold" \
  --dry-run
```
**Actions**:
- Lists **unprotected** VMs from `prod-demo-app` and `prod-demo-vault`.  
- Validates `bp-gold` plan in the `prod-demo-vault` project, region `asia-east1`.  
- Shows how many VMs would be protected, but applies **no** associations.

### Final Apply
```bash
./apply_protection_summary.sh \
  --projects="prod-demo-app,prod-demo-vault" \
  --backup-plan-project="prod-demo-vault" \
  --location="asia-east1" \
  --backup-plan="bp-gold"
```
**Actions**:
- Creates backup plan associations for any remaining unprotected VMs.

---

## Best Practices

- **Always Dry-Run First**: Confirm the script’s logic before applying.  
- **Mind the One-Hour Lag**: The endpoint may not show updated protection for up to 60 minutes.  
- **IAM Verification**: Ensure you and the vault service agent have the necessary roles in each project.  

**Happy Protecting!**
