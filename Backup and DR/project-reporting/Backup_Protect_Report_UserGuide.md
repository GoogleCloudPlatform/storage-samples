# Backup Protection Status Report Guide

Ashika Ganesh | Last Updated: Nov 25, 2024

## Table of Contents
- [Overview](#overview)
- [Set up and Permissions](#set-up-and-permissions)
- [Getting Started](#getting-started)

## Overview

This document provides a way to audit and report on backup protection status for your Google Compute Engine Virtual Machines (VMs). By using the provided script and Google Cloud Shell, you can generate comprehensive reports showing which VMs have backup protection and which ones don't, helping ensure compliance with your backup policies and identifying gaps in protection.

This guide will enable you to:
* **Audit backup coverage:** Easily identify which VMs are protected by backup plans and which ones aren't across your entire fleet.  
* **Track protection rates:** Get detailed statistics on backup protection rates per project and organization-wide.
* **Monitor compliance:** Ensure critical VMs have appropriate backup protection in place and identify any gaps in coverage.

## Set up and Permissions

**You will need the following Roles on the Projects you want to audit:**
- [Viewer](https://cloud.google.com/compute/docs/access/iam#compute.viewer)  
- [Backup and DR Viewer](https://cloud.google.com/iam/docs/understanding-roles#backupdr.viewer)

**Please ensure that:**
1. You have access to view all projects you want to audit
2. The necessary APIs are enabled:
   - Compute Engine API
   - Backup and DR API
3. You have [Google Cloud Shell](https://cloud.google.com/shell) access

## Getting Started

Follow these steps to generate your backup protection report:

1. Create and save your **backup_protection_report.sh** script.
2. **Open Google Cloud Shell**:  
   1. Navigate to [Google Cloud Console](https://console.cloud.google.com/)
   2. Open Cloud Shell by clicking the terminal icon in the top-right corner
3. **Upload the Script**:
   1. Click the three vertical dots (⋮) in the Cloud Shell window
   2. Select "Upload file"
   3. Choose the backup_protection_report.sh file from your computer
   4. The file will be uploaded to your home directory (~/)
4. Make the script executable:
   ```bash
   chmod +x backup_protection_report.sh
   ```
5. Run the script with the following **required parameters**:
   - `--projects`: (Optional) A comma-separated list of project IDs to include
   - `--folders`: (Optional) A comma-separated list of folder IDs to audit
   - `--exclude-projects`: (Optional) A comma-separated list of project IDs to exclude
   - `--output-file`: (Optional) The name of the output report file (default: backup_protection_report.txt)
   
   **Note: You must provide at least 1 project OR 1 folder**

6. Example Usage:
```bash
./backup_protection_report.sh \
--projects project1,project2,project3 \
--folders 345678901234 \
--exclude-projects excludedproject1 \
--output-file my_report.txt
```

This command will:
- Analyze backup protection status in project1, project2, project3
- Include all projects under folder 345678901234
- Exclude excludedproject1 from the analysis
- Output results to my_report.txt

The report will include:
- Overall summary with total VM count and protection rates
- Per-project breakdowns showing:
  - Protected VMs with their backup plan details
  - Unprotected VMs
  - Protection rate statistics
- ✓ and ✗ symbols to easily identify protected and unprotected VMs

The script provides real-time progress updates as it runs:
```
🔍 Initializing backup protection status report...
📋 Processing specified projects...
  → Adding project: project-1
🔄 Processing project (1/3): project-1
💻 Processing VM (1/10): vm-instance-1 in us-central1-a
...
```

Review the generated report file for a complete analysis of your backup protection status.
