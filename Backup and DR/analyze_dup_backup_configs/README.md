# Analyze Duplicate Backup Configs for VMs using Protection Summary for multiple project/folder/org for multiple regions

**Author:** Tarun Khemka
**Last Updated:** Apr 24, 2025  

- [Overview](#overview)  
- [Set Up and Permissions](#set-up-and-permissions)  
- [Getting Started](#getting-started)  

---

## Overview

This document shows you how to list VMs having both BackupDR SLT and Backup Plan applied across **multiple projects or folders or orgs** not limited to a single region using a Bash script named `analyze_dup_backup_configs.sh`. This script leverages the [Backup and DR Protection Summary](https://cloud.google.com/backup-disaster-recovery/docs/backup-admin/protection-summary?_gl=1*1tsvrak*_ga*NzkzNTI2MzUuMTczOTQwNjczNQ..*_ga_WH2QY8WWF5*MTczOTQwNDU4Ni42LjEuMTczOTQwOTczNC40OC4wLjA.) feature to view protection summary for supported resources.

**Key Features**:
- **Multi-project support**: Specify one or more projects at once (e.g., `projects proj-a proj-b`).
- **Multi-folders support**: Specify one or more folders at once (e.g., `folders folder-a folder-b`).
- **Multi-organizations support**: Specify one or more organizations at once (e.g., `organizations org-a org-b`).
- **Multi-regions support**: Specify one or more regions at once (e.g., `locations us-central1 asia-east1`).

> **Note**: The BackupDR endpoint takes a couple of hours to refresh, so any mutation would take some time to reflect.

---

## Set Up and Permissions

**Roles in Each Project**  
   - **Backup and DR Backup Config Viewer** 
   - The **BackupDR API** must be enabled.

---

## Getting Started

### 1. Obtain the Script
Ensure you have the file `analyze_dup_backup_configs.sh` locally.

### 2. Open Google Cloud Shell
1. Navigate to [Google Cloud Console](https://console.cloud.google.com).  
2. Click the **Cloud Shell** icon to open a shell session.

### 3. Upload the Script
1. In the Cloud Shell, click the **three vertical dots** → **Upload**.  
2. Select `analyze_dup_backup_configs.sh` from your local machine.  
3. It will appear in your home directory (`~/`) in Cloud Shell.

### 4. Make the Script Executable
```bash
chmod +x analyze_dup_backup_configs.sh
```

### 5. **Run** 
```bash
./analyze_dup_backup_configs.sh \
  double_configs.json \
  projects project_name \
  locations us-central1 
```
- **`double_configs.json`**: Output file containg the response in json format
- **`projects`**: Space-separated list of projects 
- **`folders`**: Space-separated list of folders
- **`organizations`**: Space-separated list of organizations
- **`locations`**: Space-separated list of locations

**Expected Output**:  
- Output file containing list of GCE VMs which have double configuration in terms of GCBDR Backup Plan and GCBDR SLT

---
