# GCBDR Customer POC Readiness Assessment Tool

## Overview

The GCBDR Customer POC Readiness Assessment Tool automates the evaluation of customer configurations for database protection using Google Cloud Backup and DR (GCBDR) with Persistent Disk (PD) snapshots. It is designed for SAP HANA and Db2 databases to ensure they meet the technical requirements for snapshot-based backups.

## Key Features

The tool performs the following checks:

*   **Storage Management:** Confirms all critical database paths are on LVM volumes (required for PD snapshot storage management).
*   **Database Configuration:** Verifies correct logging modes (HANA logging mode and Db2 archive logs) for point-in-time recovery.
*   **Storage Separation:** Confirms log backup volumes are physically separate from data and active log volumes.
*   **System Topology Identification:** Automatically identifies database architecture (Scale-up, Scale-out, System Replication) to determine appropriate backup methods.

## Usage

1.  Clone the repository.
2.  Navigate to the directory: `cd "Backup and DR/poc-readiness-assessment"`
3.  Run the appropriate assessment script for your database:
    *   **SAP HANA:**
        ```bash
        bash SAPHANA_PDSnap_POC_Validation.sh
        ```
    *   **Db2:**
        ```bash
        bash Db2_PDSnap_POC_Validation.sh
        ```

## Outputs

The tool generates a customer-facing **GCBDR POC Readiness Report** identifying configuration issues and providing remediation steps.
