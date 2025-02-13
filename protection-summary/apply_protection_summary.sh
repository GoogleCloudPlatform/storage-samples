#!/bin/bash

# Backup Plan Association Script with Dry Run and Multiple Project Handling
# This script applies a backup plan to unprotected VMs in the correct region.

# Copyright 2024 Google LLC
# Licensed under the Apache License, Version 2.0

SCRIPT_SUCCESS=true
DRY_RUN=false  # Default: apply changes

echo "Starting backup plan management script..."
echo "NOTE: The following script hits an endpoint that is only refreshed every 1 hour. If you made recent changes, they will not be refelcted below."


# Parse command-line arguments
OPTS=$(getopt \
    --options '' \
    --long projects:,backup-plan-project:,location:,backup-plan:,dry-run \
    --name "$(basename "$0")" \
    -- "$@")

if [ $? != 0 ]; then
    echo "Failed to parse options" >&2
    exit 1
fi

eval set -- "$OPTS"

# Initialize variables
PROJECTS=""
BACKUP_PLAN_PROJECT=""
LOCATION=""
BACKUP_PLAN=""

# Parse options
while true; do
    case "$1" in
        --projects)
            PROJECTS="$2"
            shift 2
            ;;
        --backup-plan-project)
            BACKUP_PLAN_PROJECT="$2"
            shift 2
            ;;
        --location)
            LOCATION="$2"
            shift 2
            ;;
        --backup-plan)
            BACKUP_PLAN="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Invalid option: $1" >&2
            exit 1
            ;;
    esac
done

# Validate required parameters
if [ -z "$PROJECTS" ] || [ -z "$BACKUP_PLAN_PROJECT" ] || [ -z "$LOCATION" ] || [ -z "$BACKUP_PLAN" ]; then
    echo "ERROR: Missing required parameters." >&2
    echo "Usage: $(basename "$0") --projects PROJECTS --backup-plan-project BACKUP_PLAN_PROJECT --location LOCATION --backup-plan BACKUP_PLAN [--dry-run]"
    exit 1
fi

# Convert comma-separated projects into an array
IFS=',' read -r -a PROJECT_ARRAY <<< "$PROJECTS"

# Step 1: Verify that the backup plan exists in the provided region
echo "Verifying that the backup plan '$BACKUP_PLAN' exists in project '$BACKUP_PLAN_PROJECT' and location '$LOCATION'..."

VALID_PLAN=$(gcloud alpha backup-dr backup-plans describe "$BACKUP_PLAN" \
    --project="$BACKUP_PLAN_PROJECT" \
    --location="$LOCATION" --format="value(name)" 2>/dev/null)

if [ -z "$VALID_PLAN" ]; then
    echo "❌ ERROR: The specified backup plan '$BACKUP_PLAN' was NOT found in project '$BACKUP_PLAN_PROJECT' and location '$LOCATION'."
    echo ""
    echo "📌 Available backup plans in '$LOCATION':"
    
    gcloud alpha backup-dr backup-plans list \
        --project="$BACKUP_PLAN_PROJECT" \
        --location="$LOCATION" \
        --format="table(name,state,description)"

    echo ""
    echo "Please specify a valid backup plan and try again."
    exit 1
fi

echo "✅ Backup plan '$BACKUP_PLAN' is valid in '$LOCATION'. Proceeding..."

# Function to fetch unprotected VMs for a given project
fetch_unprotected_vms() {
    local PROJECT_ID="$1"
    local API_URL="https://backupdr.googleapis.com/v1/projects/$PROJECT_ID/locations/$LOCATION/resourceBackupConfigs?filter=target_resource_type=%22COMPUTE_ENGINE_VM%22%20AND%20backup_configured!=true"

    # Print to stderr so it doesn't pollute stdout
    echo "Fetching unprotected VMs in project '$PROJECT_ID'..." >&2

    # Call the BackupDR API
    VM_RESPONSE=$(curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
                       -H "Content-Type: application/json" \
                       "$API_URL")

    # If resourceBackupConfigs is null or doesn't exist, return nothing
    if ! echo "$VM_RESPONSE" | jq -e '.resourceBackupConfigs' >/dev/null 2>&1; then
        return
    fi

    # Output only the jq lines (stdout) so they get captured in $RESULT
    echo "$VM_RESPONSE" | jq -r '.resourceBackupConfigs[] | "\(.targetResourceDisplayName),\(.targetResource)"'
}


# Step 2: Fetch the list of unprotected VMs across all projects
VM_LIST=()
TOTAL_UNPROTECTED_VMS=0

for PROJECT_ID in "${PROJECT_ARRAY[@]}"; do
    # Capture only the jq output from fetch_unprotected_vms()
    RESULT=$(fetch_unprotected_vms "$PROJECT_ID")

    # Ensure non-empty results are added
    if [[ -n "$RESULT" ]]; then
        # Add each VM entry to the array
        while IFS= read -r line; do
            [[ -n "$line" ]] && VM_LIST+=("$line")
        done <<< "$RESULT"
    fi
done

# Calculate total VMs
TOTAL_UNPROTECTED_VMS=${#VM_LIST[@]}

if [[ "$TOTAL_UNPROTECTED_VMS" -eq 0 ]]; then
    echo "No unprotected VMs found in the specified projects."
    exit 0
fi

echo "📌 The following VMs **will be affected**:"

for line in "${VM_LIST[@]}"; do
    # line looks like:
    #   "tags-test,//compute.googleapis.com/projects/12345678910/zones/asia-east1-c/instances/tags-test"
    VM_NAME="$(echo "$line" | cut -d',' -f1)"
    RESOURCE="$(echo "$line" | cut -d',' -f2)"

    # Extract project number from the resource string
    PROJECT_NUMBER="$(echo "$RESOURCE" | awk -F'/' '{print $5}')"

    # Convert project number to project ID
    PROJECT_ID="$(gcloud projects list --filter="projectNumber=$PROJECT_NUMBER" --format="value(projectId)")"

    # Print the final line in a more readable format
    echo "$VM_NAME, $PROJECT_ID"
done

echo "----------------------------------------"
echo "🛠️  Total unprotected VMs found: $TOTAL_UNPROTECTED_VMS"




# If dry-run mode is enabled, **exit before making changes**
if [ "$DRY_RUN" = true ]; then
    echo "🚀 DRY RUN: No changes will be made."
    exit 0
fi

# Function to apply a backup plan to a VM
apply_backup_plan() {
    local VM_NAME="$1"
    local VM_RESOURCE="$2"

    # Extract Project Number, Zone, and Instance Name
    PROJECT_NUMBER=$(echo "$VM_RESOURCE" | awk -F'/' '{print $5}')
    ZONE=$(echo "$VM_RESOURCE" | awk -F'/' '{print $7}')
    INSTANCE_NAME=$(echo "$VM_RESOURCE" | awk -F'/' '{print $9}')

    # Convert Project Number to Project ID
    PROJECT_ID=$(gcloud projects list --filter="projectNumber=$PROJECT_NUMBER" --format="value(projectId)")

    echo "Applying backup plan to VM: $VM_NAME (Project: $PROJECT_ID, Zone: $ZONE, Instance: $INSTANCE_NAME)..."

    # Validate extracted values
    if [[ -z "$PROJECT_ID" || -z "$ZONE" || -z "$INSTANCE_NAME" ]]; then
        echo "❌ ERROR: Unable to extract Project ID, Zone, or Instance Name for $VM_NAME. Skipping..."
        return
    fi

    # Create Backup Plan Association
    gcloud alpha backup-dr backup-plan-associations create "${INSTANCE_NAME}-backup-association" \
        --project="$PROJECT_ID" \
        --location="$LOCATION" \
        --resource="$VM_RESOURCE" \
        --backup-plan="projects/$BACKUP_PLAN_PROJECT/locations/$LOCATION/backupPlans/$BACKUP_PLAN" \
        --resource-type="compute.googleapis.com/Instance"

    if [ $? -eq 0 ]; then
        echo "✓ Successfully applied backup plan to $VM_NAME"
    else
        echo "✗ Failed to apply backup plan to $VM_NAME"
    fi
}

# Iterate over each VM and apply the backup plan
while IFS=, read -r VM_NAME VM_RESOURCE; do
    apply_backup_plan "$VM_NAME" "$VM_RESOURCE"
done <<< "$VM_LIST"

echo "🚀 Backup plan application process completed."
