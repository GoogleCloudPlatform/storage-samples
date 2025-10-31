# Managed-Lustre-Samples

A repository for guides and scripts to connect GCE VMs to Google Cloud Managed Lustre.

---

## Contents

This repo contains two key components:

### 1. Main Instruction Guide

* **File:** [`Auto connect to Lustre from VM.md`](./Auto%20connect%20to%20Lustre%20from%20VM.md)
* **Description:** This is the main, detailed guide. It contains the complete, step-by-step instructions for the **recommended manual setup process** (which uses the `setup_lustre_client.sh` script).

### 2. Universal Setup Script

* **File:** [`setup_lustre_client.sh`](./setup_lustre_client.sh)
* **Description:** This is the utility script referenced in the main guide. It is designed to be run **inside** a single VM to completely automate its setup (installs client packages, adds the correct repo, mounts Lustre, and makes the mount permanent).
* **Usage:** All instructions for using this script are located in the main `Auto connect to Lustre from VM.md` guide.