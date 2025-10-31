# List Protection Summary for multiple project/folder/org for multiple regions

**Author:** Tarun Khemka
**Last Updated:** Mar 24, 2025  

- [Overview](#overview)  
- [Set Up and Permissions](#set-up-and-permissions)  
- [Getting Started](#getting-started)  
- [Example Command Usage](#example-command-usage)  
- [Best Practices](#best-practices)  

---

## Overview

This document shows you how to list protection summary data across **multiple projects or folders or orgs** not limited to a single region using a Bash script named `list_resource_backup_configs.sh`. This script leverages the [Backup and DR Protection Summary](https://cloud.google.com/backup-disaster-recovery/docs/backup-admin/protection-summary?_gl=1*1tsvrak*_ga*NzkzNTI2MzUuMTczOTQwNjczNQ..*_ga_WH2QY8WWF5*MTczOTQwNDU4Ni42LjEuMTczOTQwOTczNC40OC4wLjA.) feature to view protection summary for supported resources.

**Key Features**:
- **Multi-project support**: Specify one or more projects at once (e.g., `projects proj-a proj-b`).
- **Multi-folders support**: Specify one or more folders at once (e.g., `folders folder-a folder-b`).
- **Multi-organizations support**: Specify one or more organizations at once (e.g., `organizations org-a org-b`).
- **Multi-regions support**: Specify one or more regions at once (e.g., `locations us-central1 asia-east1`).
- **Filter support**: Specify filter based on your requirements (e.g., `filter "backup_configured!=true"`).

> **Note**: The BackupDR endpoint takes a couple of hours to refresh, so any mutation would take some time to reflect.

---

## Set Up and Permissions

**Roles in Each Project**  
   - **Backup and DR Backup Config Viewer** 
   - The **BackupDR API** must be enabled.

---

## Getting Started

### 1. Obtain the Script
Ensure you have the file `list_resource_backup_configs.sh` locally.

### 2. Open Google Cloud Shell
1. Navigate to [Google Cloud Console](https://console.cloud.google.com).  
2. Click the **Cloud Shell** icon to open a shell session.

### 3. Upload the Script
1. In the Cloud Shell, click the **three vertical dots** → **Upload**.  
2. Select `list_resource_backup_configs.sh` from your local machine.  
3. It will appear in your home directory (`~/`) in Cloud Shell.

### 4. Make the Script Executable
```bash
chmod +x list_resource_backup_configs.sh
```

### 5. **Run** 
```bash
./list_resource_backup_configs.sh \
  output.json \
  folders folder_name \
  locations us-central1 asia-east1 \
  filter "backup_configured!=true"
```
- **`output.json`**: Output file containg the response in json format
- **`projects`**: Space-separated list of projects 
- **`folders`**: Space-separated list of folders
- **`organizations`**: Space-separated list of organizations
- **`locations`**: Space-separated list of locations
- **`filter`**: filter string

**Expected Output**:  
- Output file containing list of resourceBackupConfig objects based on the input

---
